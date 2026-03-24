#!/usr/bin/env bash
# =============================================================================
# Verify ClickHouse raw landing ingestion.
# Runs init (idempotent), then verifies tables exist and have rows.
# =============================================================================
set -euo pipefail
REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"

echo "Verify: ClickHouse ingestion"
echo "-------------------------------"
echo ""

# Run init (idempotent)
echo "Running ClickHouse init..."
bash "$REPO_ROOT/scripts/clickhouse/init.sh"
echo ""

# Wait a bit for Kafka consumers to start ingesting
echo "Waiting 15s for Kafka consumers to ingest data..."
sleep 15

# Verify
bash "$REPO_ROOT/scripts/clickhouse/verify-ingestion.sh"
