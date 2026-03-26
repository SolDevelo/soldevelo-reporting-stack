#!/usr/bin/env bash
# =============================================================================
# Initialize Superset: run DB migrations and create admin user.
#
# This runs the same steps as the superset-init container, but can be used
# ad-hoc (e.g., after a reset). Idempotent — safe to run multiple times.
# =============================================================================
set -euo pipefail
REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"

if [ -f "$REPO_ROOT/.env" ]; then
  set -a; source "$REPO_ROOT/.env"; set +a
fi

COMPOSE_CMD="docker compose --env-file $REPO_ROOT/.env -f $REPO_ROOT/compose/docker-compose.yml"

echo "Initializing Superset..."

$COMPOSE_CMD exec -T superset bash -c '
  superset db upgrade
  superset fab list-users 2>/dev/null | grep -qw "${SUPERSET_ADMIN_USER:-admin}" || \
    superset fab create-admin \
      --username "${SUPERSET_ADMIN_USER:-admin}" \
      --password "${SUPERSET_ADMIN_PASSWORD:-changeme}" \
      --firstname Admin --lastname User \
      --email admin@example.com
  superset init
'

echo "Superset init complete."
