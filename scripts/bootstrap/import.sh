#!/usr/bin/env bash
# =============================================================================
# Import a bootstrap export into ClickHouse raw landing.
#
# Reads NDJSON files produced by scripts/bootstrap/export.sh, wraps each
# source row in a synthetic Debezium CDC envelope, and inserts into the
# corresponding raw.events_<topic> table via the ClickHouse HTTP API.
#
# Each emitted event has:
#   op        = 'r'                          (read = snapshot semantics)
#   ts_ms     = manifest.ts_ms               (export wall-clock, UTC)
#   before    = ''                           (snapshot rows have no prior state)
#   after     = <row JSON, escaped as a String>
#   source    = synthetic JSON with:
#                snapshot='bootstrap', lsn=<manifest.lsn_numeric>,
#                schema=<from table name>, table=<from table name>
#   transaction = ''
#
# Idempotency: rows from a re-run land in the append-only raw table; dbt
# staging deduplicates by (primary key) order by (ts_ms desc, _ingested_at desc),
# so the latest re-import wins — matching the dbt semantics already used for
# CDC events.
#
# Usage:
#   make bootstrap-import                           # uses .bootstrap/latest
#   INPUT_DIR=/path/to/export-... make bootstrap-import
#   TABLES=schema.t1,schema.t2 make bootstrap-import  # import a subset
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

if [ -f "$REPO_ROOT/.env" ]; then
  set -a; source "$REPO_ROOT/.env"; set +a
fi

CLICKHOUSE_HOST="${CLICKHOUSE_HOST_EXTERNAL:-localhost}"
CLICKHOUSE_PORT="${CLICKHOUSE_PORT:-8123}"
CLICKHOUSE_USER="${CLICKHOUSE_USER:-default}"
CLICKHOUSE_PASSWORD="${CLICKHOUSE_PASSWORD:-changeme}"
DEBEZIUM_TOPIC_PREFIX="${DEBEZIUM_TOPIC_PREFIX:-openlmis}"
# Used only in the synthetic source.db field of emitted CDC envelopes; default
# to a marker so re-runs without .env still produce well-formed JSON.
SOURCE_PG_DB="${SOURCE_PG_DB:-unknown}"

INPUT_DIR="${INPUT_DIR:-$REPO_ROOT/.bootstrap/latest}"
if [ ! -d "$INPUT_DIR" ]; then
  echo "ERROR: input dir not found: $INPUT_DIR" >&2
  echo "       Run 'make bootstrap-export' first or pass INPUT_DIR=..." >&2
  exit 1
fi
MANIFEST="$INPUT_DIR/manifest.json"
if [ ! -f "$MANIFEST" ]; then
  echo "ERROR: manifest.json not found in $INPUT_DIR" >&2
  exit 1
fi

echo "=== Bootstrap import ==="
echo "Input:     $INPUT_DIR"
echo "Target CH: $CLICKHOUSE_HOST:$CLICKHOUSE_PORT"
echo ""

# Resolve manifest into shell variables.
read -r EXPORT_TS_MS EXPORT_LSN EXPORT_LSN_NUMERIC <<<"$(python3 - "$MANIFEST" <<'PY'
import json, sys
m = json.load(open(sys.argv[1]))
print(m["ts_ms"], m["lsn"], m["lsn_numeric"])
PY
)"
echo "Export ts_ms: $EXPORT_TS_MS"
echo "Export LSN:   $EXPORT_LSN  (numeric: $EXPORT_LSN_NUMERIC)"
echo ""

# -----------------------------------------------------------------------------
# Helper: post a ClickHouse query (body may be inline or piped via stdin).
# We use the HTTP API for parity with scripts/clickhouse/init.sh.
# -----------------------------------------------------------------------------
ch_post() {
  local query="$1"
  curl -sf "http://${CLICKHOUSE_HOST}:${CLICKHOUSE_PORT}/?query=$(python3 -c "import urllib.parse,sys; print(urllib.parse.quote(sys.argv[1]))" "$query")" \
    --user "${CLICKHOUSE_USER}:${CLICKHOUSE_PASSWORD}" \
    --data-binary @-
}

ch_query() {
  curl -sf "http://${CLICKHOUSE_HOST}:${CLICKHOUSE_PORT}/" \
    --user "${CLICKHOUSE_USER}:${CLICKHOUSE_PASSWORD}" \
    --data-binary "$1"
}

# -----------------------------------------------------------------------------
# Filter the manifest's table list against an optional TABLES override.
# -----------------------------------------------------------------------------
SELECTED_TABLES_JSON=$(python3 - "$MANIFEST" "${TABLES:-}" <<'PY'
import json, sys
m = json.load(open(sys.argv[1]))
override = [t.strip() for t in sys.argv[2].split(',') if t.strip()] if sys.argv[2] else []
out = []
for entry in m["tables"]:
    if not override or entry["name"] in override:
        out.append(entry)
print(json.dumps(out))
PY
)

TOTAL_IMPORTED=0
mapfile -t TABLE_LINES < <(python3 -c "import json,sys; [print(f'{t[\"name\"]}|{t[\"ndjson\"]}|{t[\"rows\"]}') for t in json.loads(sys.argv[1])]" "$SELECTED_TABLES_JSON")

if [ "${#TABLE_LINES[@]}" -eq 0 ]; then
  echo "WARNING: no tables matched TABLES filter; nothing to import." >&2
  exit 0
fi

for line in "${TABLE_LINES[@]}"; do
  IFS='|' read -r table_name ndjson_filename row_count <<<"$line"
  schema="${table_name%%.*}"
  table="${table_name##*.}"
  topic="${DEBEZIUM_TOPIC_PREFIX}.${schema}.${table}"
  ch_table="raw.events_$(echo "${DEBEZIUM_TOPIC_PREFIX}.${schema}.${table}" | tr '.' '_')"
  input_file="$INPUT_DIR/$ndjson_filename"

  echo "Importing $table_name ($row_count rows) → $ch_table ..."

  # Verify CH table exists.
  exists=$(ch_query "SELECT count() FROM system.tables WHERE database='raw' AND name='events_$(echo "${DEBEZIUM_TOPIC_PREFIX}.${schema}.${table}" | tr '.' '_')'")
  if [ "$exists" != "1" ]; then
    echo "  ERROR: $ch_table does not exist. Run 'make clickhouse-init' first." >&2
    exit 1
  fi

  # Transform NDJSON rows into the synthetic CDC envelope and stream into CH.
  # Done in python because we need JSON-encoded strings inside JSON objects.
  # The heredoc must attach to python3, NOT to ch_post — that's why the
  # `<<'PY' ... PY` block precedes the pipe (`| ch_post ...`). The pipe
  # binds ch_post's stdin to python3's stdout.
  python3 - "$input_file" "$EXPORT_TS_MS" "$EXPORT_LSN_NUMERIC" "$schema" "$table" "$SOURCE_PG_DB" <<'PY' \
    | ch_post "INSERT INTO $ch_table (op, ts_ms, before, after, source, transaction) FORMAT JSONEachRow"
import json, sys

in_path, ts_ms_str, lsn_str, schema, table, db_name = sys.argv[1:]
ts_ms = int(ts_ms_str)
lsn_numeric = int(lsn_str)

source_template = {
    "version": "bootstrap",
    "connector": "postgresql",
    "name": "bootstrap-import",
    "ts_ms": ts_ms,
    "snapshot": "bootstrap",
    "db": db_name,
    "sequence": None,
    "schema": schema,
    "table": table,
    "txId": None,
    "lsn": lsn_numeric,
    "xmin": None,
}

with open(in_path, encoding="utf-8") as f:
    for line in f:
        line = line.strip()
        if not line:
            continue
        envelope = {
            "op": "r",
            "ts_ms": ts_ms,
            "before": "",
            "after": line,
            "source": json.dumps(source_template, separators=(",", ":")),
            "transaction": "",
        }
        sys.stdout.write(json.dumps(envelope, separators=(",", ":")))
        sys.stdout.write("\n")
PY

  # Recently-imported rows may not be queryable immediately if there's any
  # async settle; clickhouse INSERT FORMAT JSONEachRow is synchronous though,
  # so the count below should be accurate.
  after_count=$(ch_query "SELECT count() FROM $ch_table WHERE op='r' AND ts_ms=$EXPORT_TS_MS")
  echo "  Rows now in $ch_table at ts_ms=$EXPORT_TS_MS: $after_count"
  TOTAL_IMPORTED=$((TOTAL_IMPORTED + row_count))
done

# Stamp the manifest so re-runs can audit history.
python3 - "$MANIFEST" <<'PY'
import json, sys, datetime
p = sys.argv[1]
m = json.load(open(p))
m.setdefault("imports", []).append({
    "at": datetime.datetime.now(datetime.timezone.utc).strftime("%Y%m%dT%H%M%SZ"),
})
json.dump(m, open(p, "w"), indent=2)
PY

echo ""
echo "=== Import complete ==="
echo "  Tables imported: ${#TABLE_LINES[@]}"
echo "  Rows imported:   $TOTAL_IMPORTED"
echo ""
echo "Next steps:"
echo "  - If this is a new-deployment initial-load:"
echo "      DEBEZIUM_SNAPSHOT_MODE=no_data make register-connector"
echo "  - If this is a targeted backfill (connector already running):"
echo "      make dbt-build"
