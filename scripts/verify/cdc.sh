#!/usr/bin/env bash
# =============================================================================
# Verify Debezium CDC connector.
# Checks that the connector is RUNNING and at least one CDC topic exists.
# =============================================================================
set -euo pipefail
REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"

if [ -f "$REPO_ROOT/.env" ]; then
  set -a; source "$REPO_ROOT/.env"; set +a
fi

CONNECT_PORT="${CONNECT_PORT:-8083}"
CONNECT_URL="http://localhost:${CONNECT_PORT}"
CONNECTOR_NAME="openlmis-postgres-cdc"
DEBEZIUM_TOPIC_PREFIX="${DEBEZIUM_TOPIC_PREFIX:-openlmis}"

PASS=0
FAIL=0

check() {
  local name="$1"
  shift
  if "$@" > /dev/null 2>&1; then
    echo "  PASS  $name"
    PASS=$((PASS + 1))
  else
    echo "  FAIL  $name"
    FAIL=$((FAIL + 1))
  fi
}

echo "Verify: CDC connector"
echo "-------------------------------"

# --- Check 1: connector exists and is RUNNING ---
check_connector_running() {
  local status
  status=$(curl -sf "${CONNECT_URL}/connectors/${CONNECTOR_NAME}/status")
  local conn_state
  conn_state=$(echo "$status" | python3 -c "import sys,json; print(json.load(sys.stdin)['connector']['state'])")
  # On single-node Connect, connector state can be UNASSIGNED while tasks run fine
  if [ "$conn_state" != "RUNNING" ] && [ "$conn_state" != "UNASSIGNED" ]; then
    echo "    connector state: $conn_state (expected RUNNING or UNASSIGNED)" >&2
    return 1
  fi
  # Check that at least one task is RUNNING
  local running_tasks
  running_tasks=$(echo "$status" | python3 -c "
import sys, json
tasks = json.load(sys.stdin).get('tasks', [])
print(sum(1 for t in tasks if t['state'] == 'RUNNING'))
")
  if [ "$running_tasks" -lt 1 ]; then
    echo "    no RUNNING tasks found" >&2
    return 1
  fi
  return 0
}
check "Connector '${CONNECTOR_NAME}' is RUNNING" check_connector_running

# --- Check 2: at least one CDC topic exists ---
check_cdc_topics() {
  local topics
  topics=$(docker compose --env-file "$REPO_ROOT/.env" -f "$REPO_ROOT/compose/docker-compose.yml" exec -T kafka \
    kafka-topics.sh --bootstrap-server localhost:9092 --list 2>/dev/null)
  local cdc_count
  cdc_count=$(echo "$topics" | grep -c "^${DEBEZIUM_TOPIC_PREFIX}\." || true)
  if [ "$cdc_count" -lt 1 ]; then
    echo "    no topics matching '${DEBEZIUM_TOPIC_PREFIX}.*' found" >&2
    echo "    existing topics:" >&2
    echo "$topics" | sed 's/^/      /' >&2
    return 1
  fi
  echo "    found $cdc_count CDC topic(s)" >&2
  return 0
}
check "At least one CDC topic exists (prefix: ${DEBEZIUM_TOPIC_PREFIX})" check_cdc_topics

echo "-------------------------------"
echo "Results: ${PASS} passed, ${FAIL} failed"

if [ "$FAIL" -gt 0 ]; then
  exit 1
fi
