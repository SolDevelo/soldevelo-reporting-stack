#!/usr/bin/env bash
# =============================================================================
# Import a single Superset asset bundle (unzipped YAML directory).
#
# Usage: import-assets.sh <asset_path>
#
# The asset path should contain a metadata.yaml at its root and subdirectories
# for databases/, datasets/, charts/, dashboards/.
#
# Assets are stored as plain YAML in Git (diffable, reviewable) and copied
# into the Superset container for the import-directory CLI with --overwrite,
# so re-imports actually replace existing entities (the legacy
# import-dashboards CLI takes a ZIP but won't overwrite existing dataset
# column lists, so YAML edits to add/remove columns wouldn't propagate).
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

# Copy the asset directory into the container and run import-directory -o.
TARGET="/tmp/superset-assets-$(basename "$ASSET_PATH")-$$"
trap '$COMPOSE_CMD exec -T -u root superset rm -rf "$TARGET" 2>/dev/null || true' EXIT

$COMPOSE_CMD cp "$ASSET_PATH" "superset:$TARGET"
$COMPOSE_CMD exec -T superset superset import-directory -o "$TARGET"

echo "  Import complete."
