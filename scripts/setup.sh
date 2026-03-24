#!/usr/bin/env bash
# =============================================================================
# One-shot setup: waits for services, registers the CDC connector, and
# initializes ClickHouse raw landing tables.
#
# Run after 'make up' to complete the platform configuration.
# Idempotent — safe to run multiple times.
# =============================================================================
set -euo pipefail
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"

if [ -f "$REPO_ROOT/.env" ]; then
  set -a; source "$REPO_ROOT/.env"; set +a
fi

CONNECT_PORT="${CONNECT_PORT:-8083}"
CONNECT_URL="http://localhost:${CONNECT_PORT}"
MAX_WAIT=180
INTERVAL=5

echo "=== Reporting Stack Setup ==="
echo ""

# Step 1: Wait for Kafka Connect to be healthy
echo "Waiting for Kafka Connect to be ready..."
elapsed=0
until curl -sf "${CONNECT_URL}/connectors" > /dev/null 2>&1; do
  if [ "$elapsed" -ge "$MAX_WAIT" ]; then
    echo "ERROR: Kafka Connect not ready after ${MAX_WAIT}s" >&2
    echo "Check: docker compose --env-file .env -f compose/docker-compose.yml logs kafka-connect" >&2
    exit 1
  fi
  sleep "$INTERVAL"
  elapsed=$((elapsed + INTERVAL))
  printf "\r  waiting... %ds" "$elapsed"
done
echo ""
echo "  Kafka Connect ready (${elapsed}s)"
echo ""

# Step 2: Register CDC connector
# If a connector already exists, re-register it (idempotent PUT).
# The register script uses PUT which creates or updates.
echo "Registering Debezium CDC connector..."
bash "$REPO_ROOT/scripts/connect/register-connector.sh"
echo ""

# Step 3: Wait for connector to start producing
echo "Waiting 10s for connector to start..."
sleep 10

# Step 4: Initialize ClickHouse
echo "Initializing ClickHouse raw landing tables..."
bash "$REPO_ROOT/scripts/clickhouse/init.sh"
echo ""

# Step 5: Wait for ingestion (Debezium snapshot + ClickHouse consumer lag)
echo "Waiting for initial data ingestion..."
CLICKHOUSE_HOST="${CLICKHOUSE_HOST_EXTERNAL:-localhost}"
CLICKHOUSE_PORT="${CLICKHOUSE_PORT:-8123}"
CLICKHOUSE_USER="${CLICKHOUSE_USER:-default}"
CLICKHOUSE_PASSWORD="${CLICKHOUSE_PASSWORD:-changeme}"

ingest_elapsed=0
ingest_max=120
while [ "$ingest_elapsed" -lt "$ingest_max" ]; do
  row_count=$(curl -sf "http://${CLICKHOUSE_HOST}:${CLICKHOUSE_PORT}/" \
    --user "${CLICKHOUSE_USER}:${CLICKHOUSE_PASSWORD}" \
    --data-binary "SELECT sum(total_rows) FROM system.tables WHERE database = 'raw' AND name LIKE 'events_%'" 2>/dev/null || echo "0")
  if [ "$row_count" -gt 0 ] 2>/dev/null; then
    echo "  Data detected (${row_count} rows after ${ingest_elapsed}s)"
    # Give a few more seconds for remaining topics
    sleep 5
    break
  fi
  sleep "$INTERVAL"
  ingest_elapsed=$((ingest_elapsed + INTERVAL))
  printf "\r  waiting... %ds" "$ingest_elapsed"
done
echo ""

# Step 6: Quick verification
echo "Verifying..."
echo ""
bash "$REPO_ROOT/scripts/verify/step1.sh"
echo ""
bash "$REPO_ROOT/scripts/verify/step2.sh"
echo ""
bash "$REPO_ROOT/scripts/clickhouse/verify-ingestion.sh"
echo ""
echo "=== Setup complete ==="
