#!/usr/bin/env bash
# =============================================================================
# Recover a broken pipeline.
#
# Checks service health, restarts any failed connector tasks, re-registers
# the connector if missing, and verifies CDC is streaming.
#
# Usage: make recover
# Idempotent — safe to run any time.
# =============================================================================
set -euo pipefail
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"

if [ -f "$REPO_ROOT/.env" ]; then
  set -a; source "$REPO_ROOT/.env"; set +a
fi

CONNECT_PORT="${CONNECT_PORT:-8083}"
CONNECT_URL="http://localhost:${CONNECT_PORT}"
CONNECTOR_NAME="${DEBEZIUM_CONNECTOR_NAME:-openlmis-postgres-cdc}"

echo "=== Pipeline Recovery ==="
echo ""

# Step 1: Verify core services are healthy
echo "--- Step 1: Verify services ---"
bash "$REPO_ROOT/scripts/verify/services.sh" || {
  echo "FAIL: Services are not healthy. Run 'make up' first." >&2
  exit 1
}
echo ""

# Step 2: Check connector, restart failed tasks or re-register if missing
echo "--- Step 2: Check connector ---"
HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" \
  "${CONNECT_URL}/connectors/${CONNECTOR_NAME}/status" 2>/dev/null || echo "000")

if [ "$HTTP_CODE" = "404" ] || [ "$HTTP_CODE" = "000" ]; then
  echo "Connector '$CONNECTOR_NAME' not found. Re-registering..."
  bash "$REPO_ROOT/scripts/connect/register-connector.sh"
  echo "Waiting 10s for connector to start..."
  sleep 10
else
  # Connector exists — check for failed tasks
  STATUS_JSON=$(curl -sf "${CONNECT_URL}/connectors/${CONNECTOR_NAME}/status")
  FAILED_TASKS=$(echo "$STATUS_JSON" | python3 -c "
import sys, json
status = json.load(sys.stdin)
failed = [t for t in status.get('tasks', []) if t['state'] == 'FAILED']
for t in failed:
    print(t['id'])
" 2>/dev/null)

  if [ -n "$FAILED_TASKS" ]; then
    echo "Found failed tasks: $FAILED_TASKS"
    for TASK_ID in $FAILED_TASKS; do
      echo "  Restarting task $TASK_ID..."
      curl -s -X POST "${CONNECT_URL}/connectors/${CONNECTOR_NAME}/tasks/${TASK_ID}/restart" > /dev/null
    done
    echo "Waiting 5s for tasks to restart..."
    sleep 5
  else
    CONNECTOR_STATE=$(echo "$STATUS_JSON" | python3 -c "
import sys, json; print(json.load(sys.stdin)['connector']['state'])" 2>/dev/null)
    echo "Connector '$CONNECTOR_NAME' is $CONNECTOR_STATE with no failed tasks."
  fi
fi
echo ""

# Step 3: Verify CDC is streaming
echo "--- Step 3: Verify CDC ---"
bash "$REPO_ROOT/scripts/verify/cdc.sh" || {
  echo ""
  echo "WARN: CDC verification failed. The connector may need more time to connect." >&2
  echo "      If source DB was recently restarted, wait a minute and re-run 'make recover'." >&2
  exit 1
}
echo ""

# Step 4: Check ClickHouse Kafka consumers are active
echo "--- Step 4: Check ClickHouse Kafka consumers ---"
COMPOSE_CMD="docker compose --env-file $REPO_ROOT/.env -f $REPO_ROOT/compose/docker-compose.yml"
CLICKHOUSE_USER="${CLICKHOUSE_USER:-default}"
CLICKHOUSE_PASSWORD="${CLICKHOUSE_PASSWORD:-changeme}"

ch_query() {
  $COMPOSE_CMD exec -T clickhouse clickhouse-client \
    --user "$CLICKHOUSE_USER" \
    --password "$CLICKHOUSE_PASSWORD" \
    "$@"
}

# First check if ClickHouse is reachable
if ! ch_query --query "SELECT 1" > /dev/null 2>&1; then
  echo "  ClickHouse unreachable. Restarting..."
  $COMPOSE_CMD restart clickhouse > /dev/null 2>&1
  echo "  Waiting 30s for ClickHouse to recover..."
  sleep 30
else
  # Check if any Kafka consumer has a transport error
  ERRORS=$(ch_query --query "
    SELECT count()
    FROM system.kafka_consumers
    WHERE database = 'raw'
      AND length(last_exception) > 0
      AND last_exception LIKE '%transport%'
  " 2>/dev/null || echo "0")

  if [ "$ERRORS" -gt 0 ]; then
    echo "  Found $ERRORS Kafka consumer(s) with transport errors. Restarting ClickHouse..."
    $COMPOSE_CMD restart clickhouse > /dev/null 2>&1
    echo "  Waiting 30s for ClickHouse to recover..."
    sleep 30
    echo "  ClickHouse restarted."
  else
    echo "  Kafka consumers healthy."
  fi
fi
echo ""

# Step 5: Quick ingestion check
echo "--- Step 5: Verify ingestion ---"
bash "$REPO_ROOT/scripts/verify/ingestion.sh" || {
  echo ""
  echo "WARN: Ingestion verification failed. ClickHouse may need time to catch up." >&2
}
echo ""

echo "=== Recovery complete ==="
