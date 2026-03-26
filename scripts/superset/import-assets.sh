#!/usr/bin/env bash
# =============================================================================
# Import a single Superset asset bundle (unzipped YAML directory).
#
# Usage: import-assets.sh <asset_path>
#
# The asset path should contain a metadata.yaml at its root and subdirectories
# for databases/, datasets/, charts/, dashboards/.
#
# Assets are stored as plain YAML in Git (diffable, reviewable) and ZIPped at
# runtime for the Superset import-dashboards CLI.
# Database passwords are NOT stored in Git — they are patched after import
# using environment variables.
# =============================================================================
set -euo pipefail
REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"

if [ -f "$REPO_ROOT/.env" ]; then
  set -a; source "$REPO_ROOT/.env"; set +a
fi

ASSET_PATH="${1:?Usage: import-assets.sh <asset_path>}"

# Resolve relative paths from repo root
if [[ "$ASSET_PATH" != /* ]]; then
  ASSET_PATH="$REPO_ROOT/$ASSET_PATH"
fi

if [ ! -f "$ASSET_PATH/metadata.yaml" ]; then
  echo "ERROR: $ASSET_PATH/metadata.yaml not found. Not a valid asset bundle." >&2
  exit 1
fi

COMPOSE_CMD="docker compose --env-file $REPO_ROOT/.env -f $REPO_ROOT/compose/docker-compose.yml"

echo "Importing assets from: $ASSET_PATH"

# Create a temporary ZIP from the asset directory.
# The ZIP must have a root directory because Superset's import strips the
# first path component (remove_root).
TMPZIP=$(mktemp /tmp/superset-assets-XXXXXX.zip)
rm -f "$TMPZIP"
trap 'rm -f "$TMPZIP"' EXIT

ASSET_DIRNAME="$(basename "$ASSET_PATH")"
(cd "$(dirname "$ASSET_PATH")" && zip -r "$TMPZIP" "$ASSET_DIRNAME/" -x '*/.*' '.*' > /dev/null)

# Copy ZIP into the container and import
$COMPOSE_CMD cp "$TMPZIP" superset:/tmp/assets-import.zip
$COMPOSE_CMD exec -T superset superset import-dashboards \
  -p /tmp/assets-import.zip -u "${SUPERSET_ADMIN_USER:-admin}"
$COMPOSE_CMD exec -T -u root superset rm -f /tmp/assets-import.zip

echo "  Import complete."
