#!/usr/bin/env bash
# =============================================================================
# Register (create or update) the Debezium PostgreSQL CDC connector.
#
# Reads the connector JSON template from the analytics-core package,
# substitutes environment variables, and PUTs the config to Kafka Connect
# REST API.
#
# Usage:
#   ./scripts/connect/register-connector.sh          # uses .env defaults
#   SOURCE_PG_HOST=mydb ./scripts/connect/register-connector.sh
# =============================================================================
set -euo pipefail
REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"

# Source .env if present
if [ -f "$REPO_ROOT/.env" ]; then
  set -a; source "$REPO_ROOT/.env"; set +a
fi

CONNECT_PORT="${CONNECT_PORT:-8083}"
CONNECT_URL="${CONNECT_URL:-http://localhost:${CONNECT_PORT}}"
ANALYTICS_CORE_PATH="${ANALYTICS_CORE_PATH:-examples/olmis-analytics-core}"

# Default to when_needed (robust under stale Connect-side offsets). Override
# to no_data for initial-load workflows that bootstrap data via
# scripts/bootstrap/import.sh — Debezium then records the LSN baseline only,
# without re-snapshotting tables.
DEBEZIUM_SNAPSHOT_MODE="${DEBEZIUM_SNAPSHOT_MODE:-when_needed}"
export DEBEZIUM_SNAPSHOT_MODE

# Resolve connector template from analytics-core package
# Look for the first .json file in the package's connect/ directory
if [[ "$ANALYTICS_CORE_PATH" = /* ]]; then
  CONNECT_DIR="$ANALYTICS_CORE_PATH/connect"
else
  CONNECT_DIR="$REPO_ROOT/$ANALYTICS_CORE_PATH/connect"
fi
if [ ! -d "$CONNECT_DIR" ]; then
  echo "ERROR: connector directory not found: $CONNECT_DIR" >&2
  exit 1
fi

TEMPLATE=$(find "$CONNECT_DIR" -maxdepth 1 -name '*.json' | head -1)
if [ -z "$TEMPLATE" ]; then
  echo "ERROR: no connector JSON template found in $CONNECT_DIR" >&2
  exit 1
fi

echo "Using connector template: $TEMPLATE"

# Append the Debezium signal table to the user's allowlist if not already present.
# The signal table is required by the source signal channel (used for incremental
# snapshots) and must appear in table.include.list. Doing this here keeps it
# invisible to users — they only manage SOURCE_PG_TABLE_ALLOWLIST.
SIGNAL_TABLE="public.debezium_signal"
if [[ ",${SOURCE_PG_TABLE_ALLOWLIST}," != *",${SIGNAL_TABLE},"* ]]; then
  SOURCE_PG_TABLE_ALLOWLIST="${SOURCE_PG_TABLE_ALLOWLIST},${SIGNAL_TABLE}"
  export SOURCE_PG_TABLE_ALLOWLIST
fi

# -----------------------------------------------------------------------------
# Preflight: every table in table.include.list must also be in the publication.
# -----------------------------------------------------------------------------
# Background: PostgreSQL logical replication only streams changes for tables
# that are in the publication. A table can be in the connector's
# table.include.list and get an initial snapshot (Debezium reads via SELECT)
# but then receive NO ongoing CDC if it isn't in the publication. The data
# ends up frozen at first-register time. This is silent — no errors, no logs.
#
# We catch it here by querying pg_publication_tables and diffing against
# table.include.list (which already includes the signal table via the append
# above).
#
# Bypass with SKIP_PREFLIGHT=1 if you know what you're doing (e.g., temporary
# CI fixture where the publication is set up after register).
# -----------------------------------------------------------------------------
preflight_publication_membership() {
  if [ "${SKIP_PREFLIGHT:-0}" = "1" ]; then
    echo "Publication preflight: skipped (SKIP_PREFLIGHT=1)"
    return 0
  fi

  if [ -z "${SOURCE_PG_HOST:-}" ] || [ -z "${SOURCE_PG_PUBLICATION:-}" ]; then
    echo "Publication preflight: skipped (SOURCE_PG_HOST or SOURCE_PG_PUBLICATION not set)"
    return 0
  fi

  if ! docker network inspect reporting-shared >/dev/null 2>&1; then
    echo "Publication preflight: skipped (reporting-shared network not available)"
    return 0
  fi

  local pub_tables_file
  pub_tables_file=$(mktemp)
  if ! docker run --rm \
        --network reporting-shared \
        -e PGPASSWORD="${SOURCE_PG_PASSWORD:-}" \
        "${POSTGRES_IMAGE:-postgres:17-alpine}" \
        psql --host="$SOURCE_PG_HOST" --port="${SOURCE_PG_PORT:-5432}" \
             --username="${SOURCE_PG_USER:-postgres}" --dbname="${SOURCE_PG_DB:-postgres}" \
             --no-psqlrc --tuples-only --no-align --quiet --set=ON_ERROR_STOP=1 \
             -c "SELECT schemaname || '.' || tablename FROM pg_publication_tables WHERE pubname='$SOURCE_PG_PUBLICATION' ORDER BY 1" \
        > "$pub_tables_file" 2>/dev/null; then
    echo "Publication preflight: skipped (could not query source DB at $SOURCE_PG_HOST)"
    rm -f "$pub_tables_file"
    return 0
  fi

  local missing
  missing=$(python3 - "$SOURCE_PG_TABLE_ALLOWLIST" "$pub_tables_file" <<'PY'
import sys
allowlist = {t.strip() for t in sys.argv[1].split(',') if t.strip()}
with open(sys.argv[2]) as f:
    published = {l.strip() for l in f if l.strip()}
missing = sorted(allowlist - published)
print(",".join(missing))
PY
)
  rm -f "$pub_tables_file"

  if [ -z "$missing" ]; then
    local count
    count=$(echo "$SOURCE_PG_TABLE_ALLOWLIST" | tr ',' '\n' | wc -l)
    echo "Publication preflight: all $count tables in allowlist are in publication '$SOURCE_PG_PUBLICATION' ✓"
    return 0
  fi

  # Special case: if public.debezium_signal is among the missing tables, the
  # user is likely upgrading from a pre-Phase-9.1 deployment where the signal
  # table doesn't exist yet. Hint about the CREATE TABLE step, since ALTER
  # PUBLICATION alone would fail with "relation does not exist".
  local upgrade_hint=""
  if [[ ",$missing," == *",public.debezium_signal,"* ]]; then
    upgrade_hint=$'\n\nUPGRADE PATH: public.debezium_signal is missing — you are likely upgrading\nfrom a version before Phase 9.1. The signal table must be CREATED first, not\njust added to the publication. Re-run the source DB init SQL (it is idempotent\nand handles both the CREATE TABLE and the publication update):\n\n  - mw-distro:  bring up the stack with the reporting-stack overlay\n  - ref-distro: same\n  - production: apply the equivalent of reporting-stack/init-db.sql to your DB\n\nThen re-run this command.'
  fi

  cat >&2 <<EOF

ERROR: publication preflight failed.

The following tables are in SOURCE_PG_TABLE_ALLOWLIST but NOT in publication
'$SOURCE_PG_PUBLICATION' on $SOURCE_PG_HOST:

  $missing

Without publication membership, these tables get an initial snapshot but NO
ongoing CDC — their data will become stale after first registration. This is
silent in connector logs.$upgrade_hint

Fix:

  1. Add the tables on the live source DB:

       ALTER PUBLICATION $SOURCE_PG_PUBLICATION ADD TABLE $missing;

  2. Persist the change in the source DB's init SQL so the next fresh init
     doesn't drift again. For mw-distro / ref-distro:

       ../mw-distro/reporting-stack/init-db.sql
       ../openlmis-ref-distro/reporting-stack/init-db.sql

  3. Re-run this command. After it succeeds, backfill rows added since the
     gap with an incremental snapshot:

       make snapshot-tables TABLES=$missing

To bypass this check (not recommended), set SKIP_PREFLIGHT=1.
EOF
  exit 1
}

preflight_publication_membership

# Substitute only the known connector env vars (prevents mangling passwords
# or values containing $ signs)
ENVSUBST_VARS='${SOURCE_PG_HOST} ${SOURCE_PG_PORT} ${SOURCE_PG_DB} ${SOURCE_PG_USER} ${SOURCE_PG_PASSWORD} ${DEBEZIUM_TOPIC_PREFIX} ${SOURCE_PG_SLOT_NAME} ${SOURCE_PG_PUBLICATION} ${SOURCE_PG_TABLE_ALLOWLIST} ${DEBEZIUM_SNAPSHOT_MODE}'
RENDERED=$(envsubst "$ENVSUBST_VARS" < "$TEMPLATE")

# Extract connector name from the rendered JSON
CONNECTOR_NAME=$(echo "$RENDERED" | python3 -c "import sys,json; print(json.load(sys.stdin)['name'])")
if [ -z "$CONNECTOR_NAME" ]; then
  echo "ERROR: failed to extract connector name from template" >&2
  exit 1
fi

# Extract only the "config" block for the PUT endpoint
CONFIG_JSON=$(echo "$RENDERED" | python3 -c "import sys,json; print(json.dumps(json.load(sys.stdin)['config'], indent=2))")

echo "Registering connector: $CONNECTOR_NAME"
echo "Connect URL: $CONNECT_URL"

# Use a temp file for the response (cleaned up on exit)
TMPFILE=$(mktemp)
trap "rm -f $TMPFILE" EXIT

HTTP_CODE=$(curl -s -o "$TMPFILE" -w "%{http_code}" \
  -X PUT \
  -H "Content-Type: application/json" \
  -d "$CONFIG_JSON" \
  "${CONNECT_URL}/connectors/${CONNECTOR_NAME}/config")

echo "HTTP $HTTP_CODE"
cat "$TMPFILE"
echo

if [ "$HTTP_CODE" -ge 200 ] && [ "$HTTP_CODE" -lt 300 ]; then
  echo "Connector registered successfully."
else
  echo "ERROR: failed to register connector (HTTP $HTTP_CODE)" >&2
  exit 1
fi
