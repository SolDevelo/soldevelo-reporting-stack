#!/usr/bin/env bash
# =============================================================================
# Show status of the Debezium CDC connector and its tasks.
#
# Usage:
#   ./scripts/connect/status.sh                          # default connector
#   ./scripts/connect/status.sh my-other-connector       # named connector
# =============================================================================
set -euo pipefail
REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"

if [ -f "$REPO_ROOT/.env" ]; then
  set -a; source "$REPO_ROOT/.env"; set +a
fi

CONNECT_PORT="${CONNECT_PORT:-8083}"
CONNECT_URL="http://localhost:${CONNECT_PORT}"
CONNECTOR_NAME="${1:-openlmis-postgres-cdc}"

echo "Connector: $CONNECTOR_NAME"
echo "Connect URL: $CONNECT_URL"
echo "---"

RESPONSE=$(curl -sf "${CONNECT_URL}/connectors/${CONNECTOR_NAME}/status" 2>&1) || {
  echo "ERROR: could not reach connector status endpoint." >&2
  echo "Check that Kafka Connect is running and the connector exists." >&2
  echo "Available connectors:"
  curl -sf "${CONNECT_URL}/connectors" 2>/dev/null || echo "  (Connect unreachable)"
  exit 1
}

echo "$RESPONSE" | python3 -m json.tool
