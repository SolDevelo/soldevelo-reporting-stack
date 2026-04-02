#!/usr/bin/env bash
# =============================================================================
# Connector watchdog — polls Kafka Connect and auto-heals failures.
#
# Runs in a loop (default 30s interval). On each tick:
#   1. If Kafka Connect is unreachable, waits and retries.
#   2. If the connector is missing, re-registers it.
#   3. If any connector task is FAILED, restarts it.
#
# Environment variables:
#   WATCHDOG_INTERVAL      — seconds between checks (default: 30)
#   CONNECT_URL            — Kafka Connect REST URL (default: http://kafka-connect:8083)
#   CONNECTOR_NAME         — connector to watch (default: from .env or openlmis-postgres-cdc)
#
# Designed to run as a sidecar container alongside kafka-connect.
# =============================================================================
set -euo pipefail

# Resolve repo root — works both on host and inside the container
REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
if [ -f "$REPO_ROOT/.env" ]; then
  set -a; source "$REPO_ROOT/.env"; set +a
elif [ -f "/opt/.env" ]; then
  REPO_ROOT="/opt"
  set -a; source "$REPO_ROOT/.env"; set +a
fi

WATCHDOG_INTERVAL="${WATCHDOG_INTERVAL:-30}"
CONNECT_URL="${CONNECT_URL:-http://kafka-connect:8083}"
CONNECTOR_NAME="${DEBEZIUM_CONNECTOR_NAME:-openlmis-postgres-cdc}"

log() {
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"
}

wait_for_connect() {
  local max_wait=300
  local elapsed=0
  while [ $elapsed -lt $max_wait ]; do
    if curl -sf "${CONNECT_URL}/connectors" > /dev/null 2>&1; then
      return 0
    fi
    sleep 5
    elapsed=$((elapsed + 5))
  done
  return 1
}

register_connector() {
  log "Registering connector '${CONNECTOR_NAME}'..."
  if bash "$REPO_ROOT/scripts/connect/register-connector.sh" 2>&1; then
    log "Connector registered successfully."
  else
    log "WARN: Connector registration failed (source DB may not be reachable yet)."
  fi
}

check_and_heal() {
  # Check if Connect API is reachable
  if ! curl -sf "${CONNECT_URL}/connectors" > /dev/null 2>&1; then
    log "WARN: Kafka Connect unreachable at ${CONNECT_URL}. Will retry."
    return
  fi

  # Check if connector exists
  local http_code
  http_code=$(curl -s -o /dev/null -w "%{http_code}" \
    "${CONNECT_URL}/connectors/${CONNECTOR_NAME}/status" 2>/dev/null || echo "000")

  if [ "$http_code" = "404" ]; then
    log "Connector '${CONNECTOR_NAME}' not found. Attempting registration..."
    register_connector
    return
  fi

  if [ "$http_code" != "200" ]; then
    log "WARN: Unexpected status code $http_code from connector status endpoint."
    return
  fi

  # Connector exists — check for failed tasks
  local status_json
  status_json=$(curl -sf "${CONNECT_URL}/connectors/${CONNECTOR_NAME}/status")

  local failed_tasks
  failed_tasks=$(echo "$status_json" | python3 -c "
import sys, json
status = json.load(sys.stdin)
failed = [t for t in status.get('tasks', []) if t['state'] == 'FAILED']
for t in failed:
    print(t['id'])
" 2>/dev/null)

  if [ -n "$failed_tasks" ]; then
    for task_id in $failed_tasks; do
      log "Task $task_id is FAILED. Restarting..."
      curl -s -X POST "${CONNECT_URL}/connectors/${CONNECTOR_NAME}/tasks/${task_id}/restart" > /dev/null
      log "Task $task_id restart requested."
    done
  fi
}

# --- Main loop ---
log "Connector watchdog starting (interval=${WATCHDOG_INTERVAL}s, connector=${CONNECTOR_NAME})"
log "Waiting for Kafka Connect at ${CONNECT_URL}..."

if ! wait_for_connect; then
  log "ERROR: Kafka Connect not reachable after 300s. Exiting."
  exit 1
fi

log "Kafka Connect is reachable. Starting health checks."

while true; do
  check_and_heal || true
  sleep "$WATCHDOG_INTERVAL"
done
