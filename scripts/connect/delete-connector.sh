#!/usr/bin/env bash
# =============================================================================
# Delete the Debezium CDC connector.
#
# Usage:
#   ./scripts/connect/delete-connector.sh                    # default connector
#   ./scripts/connect/delete-connector.sh my-other-connector # named connector
# =============================================================================
set -euo pipefail
REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"

if [ -f "$REPO_ROOT/.env" ]; then
  set -a; source "$REPO_ROOT/.env"; set +a
fi

CONNECT_PORT="${CONNECT_PORT:-8083}"
CONNECT_URL="http://localhost:${CONNECT_PORT}"
CONNECTOR_NAME="${1:-openlmis-postgres-cdc}"

echo "Deleting connector: $CONNECTOR_NAME"

HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" \
  -X DELETE \
  "${CONNECT_URL}/connectors/${CONNECTOR_NAME}")

if [ "$HTTP_CODE" = "204" ]; then
  echo "Connector deleted successfully."
elif [ "$HTTP_CODE" = "404" ]; then
  echo "Connector not found (already deleted or never created)."
else
  echo "Unexpected response: HTTP $HTTP_CODE" >&2
  exit 1
fi
