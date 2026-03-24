#!/usr/bin/env bash
# =============================================================================
# Verify platform services are healthy.
# Checks that Kafka, Kafka Connect, Apicurio, and Kafka UI are reachable.
# =============================================================================
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"

# Source .env if present (for port overrides)
if [ -f "$REPO_ROOT/.env" ]; then
  set -a; source "$REPO_ROOT/.env"; set +a
fi

# Load ports from .env or fall back to defaults
KAFKA_EXTERNAL_PORT="${KAFKA_EXTERNAL_PORT:-9094}"
CONNECT_PORT="${CONNECT_PORT:-8083}"
APICURIO_PORT="${APICURIO_PORT:-8085}"
KAFKA_UI_PORT="${KAFKA_UI_PORT:-9080}"

PASS=0
FAIL=0

check() {
  local name="$1"
  local cmd="$2"
  if eval "$cmd" > /dev/null 2>&1; then
    echo "  PASS  $name"
    PASS=$((PASS + 1))
  else
    echo "  FAIL  $name"
    FAIL=$((FAIL + 1))
  fi
}

echo "Verify: Platform services"
echo "-------------------------------"

check "Kafka broker (external listener)" \
  "kafka-broker-api-versions.sh --bootstrap-server localhost:${KAFKA_EXTERNAL_PORT} 2>/dev/null || docker compose --env-file \"$REPO_ROOT/.env\" -f \"$REPO_ROOT/compose/docker-compose.yml\" exec -T kafka kafka-broker-api-versions.sh --bootstrap-server localhost:9092 2>/dev/null"

check "Kafka Connect REST API" \
  "curl -sf http://localhost:${CONNECT_PORT}/connectors"

check "Apicurio Registry health" \
  "curl -sf http://localhost:${APICURIO_PORT}/health"

check "Kafka UI" \
  "curl -sf http://localhost:${KAFKA_UI_PORT}/"

echo "-------------------------------"
echo "Results: ${PASS} passed, ${FAIL} failed"

if [ "$FAIL" -gt 0 ]; then
  exit 1
fi
