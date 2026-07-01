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
CONNECTOR_NAME="${DEBEZIUM_CONNECTOR_NAME:-openlmis-postgres-cdc}"
DEBEZIUM_TOPIC_PREFIX="${DEBEZIUM_TOPIC_PREFIX:-openlmis}"

PASS=0
FAIL=0

check() {
  local name="$1"
  shift
  # Show the check's output only on failure.
  local out
  if out=$("$@" 2>&1); then
    echo "  PASS  $name"
    PASS=$((PASS + 1))
  else
    echo "  FAIL  $name"
    FAIL=$((FAIL + 1))
    if [ -n "$out" ]; then
      echo "$out" | sed 's/^/      /'
    fi
  fi
  # Always succeed so a failed check doesn't trip `set -e`; FAIL drives the exit.
  return 0
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
# Topics are created lazily as Debezium emits the first event for each table,
# so on a first registration they may not exist for several seconds after the
# connector reports RUNNING. Poll up to TOPIC_WAIT_SECONDS.
TOPIC_WAIT_SECONDS="${TOPIC_WAIT_SECONDS:-60}"
check_cdc_topics() {
  local topics cdc_count elapsed=0
  while [ "$elapsed" -lt "$TOPIC_WAIT_SECONDS" ]; do
    topics=$(docker compose --env-file "$REPO_ROOT/.env" -f "$REPO_ROOT/compose/docker-compose.yml" exec -T kafka \
      /opt/kafka/bin/kafka-topics.sh --bootstrap-server localhost:9092 --list 2>/dev/null)
    cdc_count=$(echo "$topics" | grep -c "^${DEBEZIUM_TOPIC_PREFIX}\." || true)
    if [ "$cdc_count" -ge 1 ]; then
      echo "    found $cdc_count CDC topic(s) (after ${elapsed}s)" >&2
      return 0
    fi
    sleep 3
    elapsed=$((elapsed + 3))
  done
  echo "    no topics matching '${DEBEZIUM_TOPIC_PREFIX}.*' found after ${TOPIC_WAIT_SECONDS}s" >&2
  echo "    existing topics:" >&2
  echo "$topics" | sed 's/^/      /' >&2
  return 1
}
check "At least one CDC topic exists (prefix: ${DEBEZIUM_TOPIC_PREFIX})" check_cdc_topics

# --- Check 3: CDC streaming is active (heartbeat offset advancing) ---
# The connector only emits heartbeats once it leaves the initial snapshot, which
# can take minutes on a fresh deploy. Poll up to STREAMING_WAIT_SECONDS for the
# heartbeat topic to appear and its offset to advance — proof that WAL →
# Debezium → Kafka works. Fails on a real stall once the budget is exhausted.
COMPOSE_CMD="docker compose --env-file $REPO_ROOT/.env -f $REPO_ROOT/compose/docker-compose.yml"
HEARTBEAT_TOPIC="__debezium-heartbeat.${DEBEZIUM_TOPIC_PREFIX}"
STREAMING_WAIT_SECONDS="${STREAMING_WAIT_SECONDS:-300}"

heartbeat_offset() {
  $COMPOSE_CMD exec -T kafka \
    /opt/kafka/bin/kafka-get-offsets.sh --bootstrap-server localhost:9092 \
    --topic "$HEARTBEAT_TOPIC" 2>/dev/null | cut -d: -f3
}

check_cdc_streaming() {
  local baseline="" current="" elapsed=0

  # Wait for the topic to appear (baseline), then for its offset to move.
  while [ "$elapsed" -lt "$STREAMING_WAIT_SECONDS" ]; do
    current=$(heartbeat_offset)
    if [ -n "$current" ]; then
      if [ -z "$baseline" ]; then
        baseline="$current"
      elif [ "$current" -gt "$baseline" ] 2>/dev/null; then
        echo "    heartbeat offset advancing: $baseline → $current (after ${elapsed}s)" >&2
        return 0
      fi
    fi
    sleep 6
    elapsed=$((elapsed + 6))
  done

  if [ -z "$baseline" ]; then
    echo "    heartbeat topic '$HEARTBEAT_TOPIC' never appeared within ${STREAMING_WAIT_SECONDS}s" >&2
    echo "    connector is likely still running its initial snapshot — check connector status/logs" >&2
  else
    echo "    heartbeat offset stuck at $baseline after ${STREAMING_WAIT_SECONDS}s" >&2
    echo "    check: connector DB connection, replication slot, publication tables" >&2
  fi
  return 1
}
check "CDC streaming active (heartbeat advancing)" check_cdc_streaming

echo "-------------------------------"
echo "Results: ${PASS} passed, ${FAIL} failed"

if [ "$FAIL" -gt 0 ]; then
  exit 1
fi
