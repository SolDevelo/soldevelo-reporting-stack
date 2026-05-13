#!/usr/bin/env bash
# =============================================================================
# Export source-PostgreSQL data to NDJSON for bootstrap import into ClickHouse.
#
# Use case: bulk-load a new deployment without going through Debezium's
# initial snapshot (faster for large datasets), or targeted backfill of
# specific tables after a dbt model fix.
#
# Output:
#   .bootstrap/export-<TIMESTAMP>/
#     manifest.json         export metadata (lsn, timestamp, tables, row counts)
#     <schema>.<table>.ndjson  one JSON object per source row
#
# The companion script scripts/bootstrap/import.sh consumes this directory and
# wraps each row in a synthetic CDC envelope before inserting into ClickHouse
# raw.events_<topic> tables.
#
# Usage:
#   make bootstrap-export                                # all tables in allowlist
#   TABLES=schema.t1,schema.t2 make bootstrap-export    # selected tables
#   OUTPUT_DIR=/tmp/my-export make bootstrap-export      # custom output dir
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

if [ -f "$REPO_ROOT/.env" ]; then
  set -a; source "$REPO_ROOT/.env"; set +a
fi

SOURCE_PG_HOST="${SOURCE_PG_HOST:?SOURCE_PG_HOST not set — source .env first}"
SOURCE_PG_PORT="${SOURCE_PG_PORT:-5432}"
SOURCE_PG_DB="${SOURCE_PG_DB:?SOURCE_PG_DB not set}"
SOURCE_PG_USER="${SOURCE_PG_USER:?SOURCE_PG_USER not set}"
SOURCE_PG_PASSWORD="${SOURCE_PG_PASSWORD:?SOURCE_PG_PASSWORD not set}"
POSTGRES_IMAGE="${POSTGRES_IMAGE:-postgres:17-alpine}"

# Default to the live CDC allowlist (minus the signal table, which is not
# user data and would re-trigger Debezium signal processing).
SIGNAL_TABLE="public.debezium_signal"
DEFAULT_TABLES=$(echo "${SOURCE_PG_TABLE_ALLOWLIST:-}" \
  | tr ',' '\n' | grep -vx "$SIGNAL_TABLE" | grep -v '^$' | paste -sd, -)
TABLES="${TABLES:-$DEFAULT_TABLES}"

if [ -z "$TABLES" ]; then
  echo "ERROR: TABLES is empty and SOURCE_PG_TABLE_ALLOWLIST is unset." >&2
  echo "       Pass TABLES=schema.t1,schema.t2 or configure your .env." >&2
  exit 2
fi

# Validate table list format.
IFS=',' read -ra TABLE_ARR <<< "$TABLES"
for t in "${TABLE_ARR[@]}"; do
  t="$(echo "$t" | xargs)"
  if [[ ! "$t" =~ ^[a-zA-Z_][a-zA-Z0-9_]*\.[a-zA-Z_][a-zA-Z0-9_]*$ ]]; then
    echo "ERROR: invalid table name '$t' — expected schema.table form" >&2
    exit 2
  fi
done

TIMESTAMP="$(date -u +%Y%m%dT%H%M%SZ)"
OUTPUT_DIR="${OUTPUT_DIR:-$REPO_ROOT/.bootstrap/export-$TIMESTAMP}"

echo "=== Bootstrap export ==="
echo "Source:    $SOURCE_PG_HOST:$SOURCE_PG_PORT/$SOURCE_PG_DB"
echo "Tables:    $TABLES"
echo "Output:    $OUTPUT_DIR"
echo "Timestamp: $TIMESTAMP"
echo ""

mkdir -p "$OUTPUT_DIR"

# -----------------------------------------------------------------------------
# Single psql helper that joins reporting-shared so SOURCE_PG_HOST resolves.
# All queries in this script reuse this image once it's pulled.
# -----------------------------------------------------------------------------
run_psql() {
  docker run --rm -i \
    --network reporting-shared \
    -e PGPASSWORD="$SOURCE_PG_PASSWORD" \
    "$POSTGRES_IMAGE" \
    psql --host="$SOURCE_PG_HOST" --port="$SOURCE_PG_PORT" \
         --username="$SOURCE_PG_USER" --dbname="$SOURCE_PG_DB" \
         --no-psqlrc --tuples-only --no-align --quiet \
         --set=ON_ERROR_STOP=1 \
         -c "$1"
}

# -----------------------------------------------------------------------------
# Record the LSN at the start of the export. Used by import.sh as the synthetic
# source.lsn for every emitted CDC envelope, and useful for downstream
# audit/reconciliation against the connector's confirmed_flush_lsn.
# -----------------------------------------------------------------------------
echo "Recording starting LSN..."
START_LSN=$(run_psql "SELECT pg_current_wal_lsn()" | tr -d '[:space:]')
if [ -z "$START_LSN" ]; then
  echo "ERROR: failed to read pg_current_wal_lsn()" >&2
  exit 1
fi
# LSN is reported as e.g. '0/9D012E8'. Convert to numeric for source envelope.
START_LSN_NUMERIC=$(run_psql "SELECT pg_wal_lsn_diff('$START_LSN', '0/0')::bigint" | tr -d '[:space:]')
echo "  LSN: $START_LSN  (numeric: $START_LSN_NUMERIC)"
echo ""

# -----------------------------------------------------------------------------
# Per-table export.
# Using COPY (SELECT row_to_json(t) FROM "schema"."table" t) TO STDOUT produces
# one JSON object per output line — perfect for streaming line-by-line into
# the import script. JSON encoding handles UUID, timestamps, booleans, nulls,
# numerics, arrays, and nested objects uniformly. We skip jsonb's behaviour
# around key ordering — row_to_json preserves column order from the SELECT,
# which is enough for our purposes (downstream uses fields by name).
# -----------------------------------------------------------------------------

EXPORTED_TABLES=()
EXPORTED_COUNTS=()

for t in "${TABLE_ARR[@]}"; do
  t="$(echo "$t" | xargs)"
  schema="${t%%.*}"
  table="${t##*.}"
  outfile="$OUTPUT_DIR/${schema}.${table}.ndjson"

  echo "Exporting $t ..."
  docker run --rm \
    --network reporting-shared \
    -e PGPASSWORD="$SOURCE_PG_PASSWORD" \
    "$POSTGRES_IMAGE" \
    psql --host="$SOURCE_PG_HOST" --port="$SOURCE_PG_PORT" \
         --username="$SOURCE_PG_USER" --dbname="$SOURCE_PG_DB" \
         --no-psqlrc --tuples-only --no-align --quiet \
         --set=ON_ERROR_STOP=1 \
         -c "COPY (SELECT row_to_json(t) FROM \"$schema\".\"$table\" t) TO STDOUT" \
    > "$outfile"

  rows=$(wc -l < "$outfile" | tr -d '[:space:]')
  echo "  $rows rows → $outfile"
  EXPORTED_TABLES+=("$t")
  EXPORTED_COUNTS+=("$rows")
done

# -----------------------------------------------------------------------------
# Manifest. Consumed by import.sh and useful for audit.
# -----------------------------------------------------------------------------
echo ""
echo "Writing manifest..."

python3 - "$OUTPUT_DIR/manifest.json" "$TIMESTAMP" "$START_LSN" "$START_LSN_NUMERIC" "${EXPORTED_TABLES[@]}" -- "${EXPORTED_COUNTS[@]}" <<'PY'
import json, sys
out_path, timestamp, lsn, lsn_numeric, *rest = sys.argv[1:]
sep = rest.index('--')
tables = rest[:sep]
counts = [int(c) for c in rest[sep+1:]]
manifest = {
    "schema_version": 1,
    "exported_at": timestamp,
    "lsn": lsn,
    "lsn_numeric": int(lsn_numeric),
    "ts_ms": None,  # filled below from timestamp
    "tables": [
        {"name": t, "rows": c, "ndjson": f"{t}.ndjson"}
        for t, c in zip(tables, counts)
    ],
}
# Compute export ts_ms (UTC) from the directory timestamp so import.sh can
# use a deterministic value across re-runs of the same export.
import datetime
dt = datetime.datetime.strptime(timestamp, "%Y%m%dT%H%M%SZ").replace(tzinfo=datetime.timezone.utc)
manifest["ts_ms"] = int(dt.timestamp() * 1000)
with open(out_path, 'w') as f:
    json.dump(manifest, f, indent=2)
print(f"  ts_ms: {manifest['ts_ms']}")
print(f"  manifest: {out_path}")
PY

# -----------------------------------------------------------------------------
# Symlink "latest" so import.sh can default to the most recent export.
# -----------------------------------------------------------------------------
ln -sfn "$(basename "$OUTPUT_DIR")" "$REPO_ROOT/.bootstrap/latest"

TOTAL=0
for c in "${EXPORTED_COUNTS[@]}"; do TOTAL=$((TOTAL + c)); done

echo ""
echo "=== Export complete ==="
echo "  Tables:  ${#EXPORTED_TABLES[@]}"
echo "  Rows:    $TOTAL"
echo "  Dir:     $OUTPUT_DIR"
echo "  Latest:  $REPO_ROOT/.bootstrap/latest -> $(readlink "$REPO_ROOT/.bootstrap/latest")"
echo ""
echo "Next: make bootstrap-import"
