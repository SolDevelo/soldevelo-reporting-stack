#!/usr/bin/env bash
# =============================================================================
# ClickHouse initialization: creates databases and raw landing tables.
#
# For each CDC topic, creates:
#   - raw.kafka_<safe_name>    Kafka engine table (consumer)
#   - raw.events_<safe_name>   MergeTree storage table (append-only landing)
#   - raw.mv_<safe_name>       Materialized View (Kafka → MergeTree)
#
# Idempotent — safe to run multiple times.
#
# Configuration:
#   RAW_KAFKA_TOPICS   comma-separated list of Kafka topic names
#                      (default: reads from SOURCE_PG_TABLE_ALLOWLIST + DEBEZIUM_TOPIC_PREFIX)
#   CLICKHOUSE_HOST    ClickHouse hostname (default: localhost)
#   CLICKHOUSE_PORT    ClickHouse HTTP port (default: 8123)
#   CLICKHOUSE_USER    ClickHouse user (default: default)
#   CLICKHOUSE_PASSWORD ClickHouse password (default: changeme)
#   KAFKA_BOOTSTRAP_SERVERS  Kafka broker list (default: kafka:9092)
# =============================================================================
set -euo pipefail
REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"

if [ -f "$REPO_ROOT/.env" ]; then
  set -a; source "$REPO_ROOT/.env"; set +a
fi

# When running from the host, ClickHouse is accessible on localhost.
# The .env may have CLICKHOUSE_HOST=clickhouse (for inter-container use).
# Override to localhost for host-side scripts.
CLICKHOUSE_HOST="${CLICKHOUSE_HOST_EXTERNAL:-localhost}"
CLICKHOUSE_PORT="${CLICKHOUSE_PORT:-8123}"
CLICKHOUSE_USER="${CLICKHOUSE_USER:-default}"
CLICKHOUSE_PASSWORD="${CLICKHOUSE_PASSWORD:-changeme}"
KAFKA_BOOTSTRAP_SERVERS="${KAFKA_BOOTSTRAP_SERVERS:-kafka:9092}"
DEBEZIUM_TOPIC_PREFIX="${DEBEZIUM_TOPIC_PREFIX:-openlmis}"

# Build topic list from TABLE_ALLOWLIST if RAW_KAFKA_TOPICS not set
if [ -z "${RAW_KAFKA_TOPICS:-}" ]; then
  TABLE_ALLOWLIST="${SOURCE_PG_TABLE_ALLOWLIST:-}"
  if [ -z "$TABLE_ALLOWLIST" ]; then
    echo "ERROR: RAW_KAFKA_TOPICS or SOURCE_PG_TABLE_ALLOWLIST must be set" >&2
    exit 1
  fi
  # Convert schema.table to topic prefix.schema.table
  RAW_KAFKA_TOPICS=""
  IFS=',' read -ra TABLES <<< "$TABLE_ALLOWLIST"
  for table in "${TABLES[@]}"; do
    topic="${DEBEZIUM_TOPIC_PREFIX}.${table}"
    RAW_KAFKA_TOPICS="${RAW_KAFKA_TOPICS:+${RAW_KAFKA_TOPICS},}${topic}"
  done
fi

echo "ClickHouse init: ${CLICKHOUSE_HOST}:${CLICKHOUSE_PORT}"
echo "Topics: ${RAW_KAFKA_TOPICS}"

ch_query() {
  curl -sf "http://${CLICKHOUSE_HOST}:${CLICKHOUSE_PORT}/" \
    --user "${CLICKHOUSE_USER}:${CLICKHOUSE_PASSWORD}" \
    --data-binary "$1"
}

# Step 1: Create databases
echo "Creating databases..."
for sql_file in "$REPO_ROOT/clickhouse/init/"*.sql; do
  echo "  Running: $(basename "$sql_file")"
  # Split on semicolons, skip empty/comment-only statements
  while IFS= read -r stmt; do
    stmt=$(echo "$stmt" | sed 's/--.*//g' | xargs)
    if [ -n "$stmt" ]; then
      ch_query "$stmt"
    fi
  done < <(sed 's/--.*//g' "$sql_file" | tr '\n' ' ' | sed 's/;/;\n/g')
done

# Step 2: For each topic, create Kafka engine + MergeTree + MV
IFS=',' read -ra TOPICS <<< "$RAW_KAFKA_TOPICS"
for topic in "${TOPICS[@]}"; do
  # Convert topic name to safe ClickHouse identifier: dots → underscores
  safe_name=$(echo "$topic" | tr '.' '_')
  consumer_group="clickhouse_raw_${safe_name}"

  echo "Setting up raw landing for topic: $topic (table: $safe_name)"

  # Kafka engine table (consumer) — reads JSON CDC events
  ch_query "
    CREATE TABLE IF NOT EXISTS raw.kafka_${safe_name} (
      before String,
      after String,
      source String,
      op String,
      ts_ms Int64,
      ts_us Int64,
      ts_ns Int64,
      transaction String
    ) ENGINE = Kafka()
    SETTINGS
      kafka_broker_list = '${KAFKA_BOOTSTRAP_SERVERS}',
      kafka_topic_list = '${topic}',
      kafka_group_name = '${consumer_group}',
      kafka_format = 'JSONEachRow',
      kafka_num_consumers = 1,
      kafka_handle_error_mode = 'stream';
  "

  # MergeTree storage table (append-only landing)
  ch_query "
    CREATE TABLE IF NOT EXISTS raw.events_${safe_name} (
      _topic String DEFAULT '${topic}',
      _ingested_at DateTime64(3) DEFAULT now64(3),
      op String,
      ts_ms Int64,
      before String COMMENT 'JSON: row state before change (null for inserts)',
      after String COMMENT 'JSON: row state after change (null for deletes)',
      source String COMMENT 'JSON: Debezium source metadata (schema, table, lsn, txId)',
      transaction String COMMENT 'JSON: transaction metadata'
    ) ENGINE = MergeTree()
    ORDER BY (_topic, ts_ms, _ingested_at)
    TTL toDateTime(_ingested_at) + INTERVAL 90 DAY
    COMMENT 'Append-only CDC event landing for ${topic}. TTL: 90 days (adjust per deployment).';
  "

  # Materialized View: Kafka → MergeTree
  ch_query "
    CREATE MATERIALIZED VIEW IF NOT EXISTS raw.mv_${safe_name}
    TO raw.events_${safe_name} AS
    SELECT
      op,
      ts_ms,
      before,
      after,
      source,
      transaction
    FROM raw.kafka_${safe_name}
    WHERE length(_error) = 0;
  "

  echo "  ✓ kafka_${safe_name} → mv_${safe_name} → events_${safe_name}"
done

echo ""
echo "ClickHouse init complete. ${#TOPICS[@]} topic(s) configured."
