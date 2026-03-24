#!/usr/bin/env bash
# =============================================================================
# Step 3 Verification: ClickHouse raw landing ingestion
# Runs init (idempotent), then verifies tables exist and have rows.
# =============================================================================
set -euo pipefail
REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"

echo "Step 3: ClickHouse raw landing"
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
