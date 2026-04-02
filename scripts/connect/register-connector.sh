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

# Substitute only the known connector env vars (prevents mangling passwords
# or values containing $ signs)
ENVSUBST_VARS='${SOURCE_PG_HOST} ${SOURCE_PG_PORT} ${SOURCE_PG_DB} ${SOURCE_PG_USER} ${SOURCE_PG_PASSWORD} ${DEBEZIUM_TOPIC_PREFIX} ${SOURCE_PG_SLOT_NAME} ${SOURCE_PG_PUBLICATION} ${SOURCE_PG_TABLE_ALLOWLIST}'
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
