#!/usr/bin/env bash
# =============================================================================
# Import all Superset assets in the correct order:
#   1. Platform assets (superset/assets/, optional)
#   2. Core package assets (ANALYTICS_CORE_PATH/superset/assets/)
#   3. Extension package assets (ANALYTICS_EXTENSIONS_PATHS/*/superset/assets/)
#
# Idempotent — assets are upserted by UUID.
# =============================================================================
set -euo pipefail
REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"

if [ -f "$REPO_ROOT/.env" ]; then
  set -a; source "$REPO_ROOT/.env"; set +a
fi

IMPORT_SCRIPT="$REPO_ROOT/scripts/superset/import-assets.sh"
IMPORTED=0

# 1. Platform assets (optional)
PLATFORM_ASSETS="$REPO_ROOT/superset/assets"
if [ -d "$PLATFORM_ASSETS" ] && [ -f "$PLATFORM_ASSETS/metadata.yaml" ]; then
  echo "=== Importing platform assets ==="
  bash "$IMPORT_SCRIPT" "$PLATFORM_ASSETS"
  IMPORTED=$((IMPORTED + 1))
  echo ""
fi

# 2. Core package assets
ANALYTICS_CORE_PATH="${ANALYTICS_CORE_PATH:-examples/olmis-analytics-core}"
if [[ "$ANALYTICS_CORE_PATH" != /* ]]; then
  ANALYTICS_CORE_PATH="$REPO_ROOT/$ANALYTICS_CORE_PATH"
fi

CORE_ASSETS="$ANALYTICS_CORE_PATH/superset/assets"
if [ -d "$CORE_ASSETS" ] && [ -f "$CORE_ASSETS/metadata.yaml" ]; then
  echo "=== Importing core package assets ==="
  bash "$IMPORT_SCRIPT" "$CORE_ASSETS"
  IMPORTED=$((IMPORTED + 1))
  echo ""
else
  echo "WARN: Core package Superset assets not found at $CORE_ASSETS" >&2
fi

# 3. Extension package assets
ANALYTICS_EXTENSIONS_PATHS="${ANALYTICS_EXTENSIONS_PATHS:-}"
if [ -n "$ANALYTICS_EXTENSIONS_PATHS" ]; then
  IFS=',' read -ra EXT_PATHS <<< "$ANALYTICS_EXTENSIONS_PATHS"
  for ext_path in "${EXT_PATHS[@]}"; do
    ext_path="$(echo "$ext_path" | xargs)"  # trim whitespace
    if [[ "$ext_path" != /* ]]; then
      ext_path="$REPO_ROOT/$ext_path"
    fi
    EXT_ASSETS="$ext_path/superset/assets"
    if [ -d "$EXT_ASSETS" ] && [ -f "$EXT_ASSETS/metadata.yaml" ]; then
      echo "=== Importing extension assets: $(basename "$ext_path") ==="
      bash "$IMPORT_SCRIPT" "$EXT_ASSETS"
      IMPORTED=$((IMPORTED + 1))
      echo ""
    fi
  done
fi

# Patch ClickHouse database connection credentials.
# Runs once after all bundles are imported (not per-bundle).
# The YAML assets in Git intentionally omit passwords (secrets policy).
if [ "$IMPORTED" -gt 0 ]; then
  COMPOSE_CMD="docker compose --env-file $REPO_ROOT/.env -f $REPO_ROOT/compose/docker-compose.yml"
  CLICKHOUSE_PASSWORD="${CLICKHOUSE_PASSWORD:-changeme}"
  CLICKHOUSE_USER="${CLICKHOUSE_USER:-default}"
  CLICKHOUSE_HOST="${CLICKHOUSE_HOST:-clickhouse}"
  CH_URI="clickhousedb+connect://${CLICKHOUSE_USER}:${CLICKHOUSE_PASSWORD}@${CLICKHOUSE_HOST}:8123/curated"

  echo "Patching ClickHouse database connection credentials..."
  $COMPOSE_CMD exec -T superset-db psql -U superset -d superset -c \
    "UPDATE dbs SET sqlalchemy_uri = '${CH_URI}' WHERE LOWER(sqlalchemy_uri) LIKE '%clickhouse%';" \
    > /dev/null
  echo "  Password patch complete."

  # Fix dashboard chart references: import-dashboards resolves chartId
  # within a single bundle, but cross-bundle references (e.g., extension
  # charts) are left as chartId: 0. Patch by matching UUIDs to slice IDs.
  # Loop because each UPDATE fixes one chart per dashboard — dashboards
  # with multiple unresolved charts need multiple passes.
  echo "Patching dashboard chart references..."
  $COMPOSE_CMD exec -T superset-db psql -U superset -d superset -c "
    DO \$\$
    DECLARE
      _fixed int;
    BEGIN
      LOOP
        UPDATE dashboards d
        SET position_json = replace(
          d.position_json,
          '\"chartId\": 0, \"height\"',
          '\"chartId\": ' || s.id || ', \"height\"'
        )
        FROM dashboard_slices ds
        JOIN slices s ON ds.slice_id = s.id
        WHERE ds.dashboard_id = d.id
          AND d.position_json LIKE '%\"chartId\": 0%'
          AND d.position_json LIKE '%' || s.uuid::text || '%';
        GET DIAGNOSTICS _fixed = ROW_COUNT;
        EXIT WHEN _fixed = 0;
      END LOOP;
    END \$\$;
  " > /dev/null
  echo "  Chart references patched."
  echo ""
fi

echo "=== Import complete: $IMPORTED bundle(s) imported ==="
