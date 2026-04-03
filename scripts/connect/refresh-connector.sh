#!/usr/bin/env bash
set -euo pipefail

# =============================================================================
# Refresh CDC connector with a fresh snapshot
# =============================================================================
# Use this when adding new tables to the allowlist. A simple re-register
# (make register-connector) only updates the connector config — it does NOT
# snapshot existing data in newly added tables, because Debezium's stored
# offset tells it the initial snapshot already completed.
#
# This script:
#   1. Stops the connector (required before offset reset)
#   2. Resets stored offsets (so Debezium treats this as a fresh start)
#   3. Deletes and re-registers the connector (triggers a new snapshot)
#   4. Re-initializes ClickHouse raw landing (creates tables for new topics)
#   5. Waits for the snapshot to complete
#
# Existing data in ClickHouse is NOT lost — raw tables are append-only.
# The snapshot will produce duplicate rows for tables that were already
# captured, but the dbt staging views deduplicate via row_number().
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
source "$REPO_ROOT/.env"

CONNECT_URL="http://localhost:${CONNECT_PORT:-8083}"
CONNECTOR_NAME="openlmis-postgres-cdc"

echo "=== Refreshing CDC connector (with fresh snapshot) ==="
echo ""

# 1. Check connector exists
if ! curl -sf "$CONNECT_URL/connectors/$CONNECTOR_NAME/status" > /dev/null 2>&1; then
  echo "Connector '$CONNECTOR_NAME' not found. Use 'make register-connector' for first-time setup."
  exit 1
fi

# 2. Stop the connector (required before offset reset)
echo "Stopping connector..."
curl -sf -X PUT "$CONNECT_URL/connectors/$CONNECTOR_NAME/stop" > /dev/null
sleep 2

# 3. Reset offsets
echo "Resetting connector offsets..."
RESET_RESPONSE=$(curl -sf -X DELETE "$CONNECT_URL/connectors/$CONNECTOR_NAME/offsets" 2>&1) || {
  echo "WARNING: Offset reset failed (Connect may not support it). Falling back to delete + recreate."
  echo "  Response: $RESET_RESPONSE"
}
sleep 1

# 4. Delete the connector
echo "Deleting connector..."
curl -sf -X DELETE "$CONNECT_URL/connectors/$CONNECTOR_NAME" > /dev/null
sleep 2

# 5. Re-register (triggers snapshot because offsets are cleared)
echo "Re-registering connector..."
bash "$SCRIPT_DIR/register-connector.sh"

# 6. Re-init ClickHouse (creates tables for any new topics)
echo ""
echo "Re-initializing ClickHouse raw landing..."
bash "$REPO_ROOT/scripts/clickhouse/init.sh"

# 7. Wait for snapshot
WAIT_SECS=30
echo ""
echo "Waiting ${WAIT_SECS}s for snapshot to complete..."
sleep "$WAIT_SECS"

# 8. Verify
echo ""
echo "Verifying ingestion..."
bash "$REPO_ROOT/scripts/verify/ingestion.sh"

echo ""
echo "=== Connector refresh complete ==="
echo "Next steps:"
echo "  make dbt-build        # rebuild dbt models with new data"
echo "  make superset-import  # re-import dashboards if assets changed"
