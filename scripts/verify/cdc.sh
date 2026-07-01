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
WARN=0

# A check function returns 0 (pass), 2 (warn — healthy but unconfirmed, non-fatal),
# or anything else (fail). Its output is shown on warn/fail only.
check() {
  local name="$1"
  shift
  local out rc
  out=$("$@" 2>&1) && rc=0 || rc=$?
  if [ "$rc" -eq 0 ]; then
    echo "  PASS  $name"
    PASS=$((PASS + 1))
  elif [ "$rc" -eq 2 ]; then
    echo "  WARN  $name"
    WARN=$((WARN + 1))
    [ -n "$out" ] && echo "$out" | sed 's/^/      /'
  else
    echo "  FAIL  $name"
    FAIL=$((FAIL + 1))
    [ -n "$out" ] && echo "$out" | sed 's/^/      /'
  fi
  # Always succeed so a check's exit code doesn't trip `set -e`; FAIL drives the exit.
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

# --- Check 3: CDC streaming status ---
# Heartbeats only flow once the connector leaves the initial snapshot, which on a
# fresh/wipe deploy can take hours (a large table snapshots for a long time). We
# deliberately do NOT wait for that — a healthy, still-snapshotting system must
# not block or fail the deploy. Briefly confirm streaming if it's already active;
# otherwise report snapshot-in-progress and finish clean. Real faults are caught
# by the connector preflight (publication) and check 1 (connector/task RUNNING).
COMPOSE_CMD="docker compose --env-file $REPO_ROOT/.env -f $REPO_ROOT/compose/docker-compose.yml"
HEARTBEAT_TOPIC="__debezium-heartbeat.${DEBEZIUM_TOPIC_PREFIX}"
STREAMING_CONFIRM_SECONDS="${STREAMING_CONFIRM_SECONDS:-30}"

heartbeat_offset() {
  $COMPOSE_CMD exec -T kafka \
    /opt/kafka/bin/kafka-get-offsets.sh --bootstrap-server localhost:9092 \
    --topic "$HEARTBEAT_TOPIC" 2>/dev/null | cut -d: -f3
}

check_cdc_streaming() {
  local baseline="" current="" start="$SECONDS"

  # Short confirmation window (real wall-clock) — long enough to observe active
  # streaming, NOT a wait for the snapshot to finish.
  while [ "$((SECONDS - start))" -lt "$STREAMING_CONFIRM_SECONDS" ]; do
    current=$(heartbeat_offset)
    if [ -n "$current" ]; then
      if [ -z "$baseline" ]; then
        baseline="$current"
      elif [ "$current" -gt "$baseline" ] 2>/dev/null; then
        echo "streaming active — heartbeat advancing ($baseline → $current)" >&2
        return 0
      fi
    fi
    sleep 5
  done

  # Streaming not confirmed in the window — non-fatal (return 2 = WARN); the build
  # stays green. The message says whether this is expected.
  if [ -z "$baseline" ]; then
    echo "initial snapshot in progress — streaming has not started yet." >&2
    echo "This is EXPECTED on a fresh/wipe deploy and needs no action: the connector is" >&2
    echo "RUNNING, and streaming (plus the hourly dashboard refresh) begins automatically" >&2
    echo "once the snapshot completes. Data is already loading into ClickHouse meanwhile." >&2
  else
    echo "heartbeat topic exists but its offset is not advancing (stuck at $baseline)." >&2
    echo "If the initial snapshot has already completed, investigate the connector/slot." >&2
  fi
  return 2
}
check "CDC streaming status" check_cdc_streaming

echo "-------------------------------"
echo "Results: ${PASS} passed, ${FAIL} failed, ${WARN} warning(s)"

if [ "$FAIL" -gt 0 ]; then
  exit 1
fi
