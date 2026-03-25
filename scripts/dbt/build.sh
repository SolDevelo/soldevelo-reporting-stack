#!/usr/bin/env bash
# =============================================================================
# Run dbt build using Docker.
#
# Builds the dbt Docker image, generates packages.yml from env vars,
# then runs dbt deps + dbt build.
#
# Configuration:
#   ANALYTICS_CORE_PATH       path to core analytics package (default: examples/olmis-analytics-core)
#   ANALYTICS_EXTENSIONS_PATHS  comma-separated extension package paths (optional)
#   CLICKHOUSE_HOST           ClickHouse hostname for dbt (default: clickhouse)
#   CLICKHOUSE_PORT           ClickHouse HTTP port (default: 8123)
#   CLICKHOUSE_USER           ClickHouse user (default: default)
#   CLICKHOUSE_PASSWORD       ClickHouse password (default: changeme)
#   DBT_ARGS                  additional arguments passed to dbt build (optional)
# =============================================================================
set -euo pipefail
REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"

if [ -f "$REPO_ROOT/.env" ]; then
  set -a; source "$REPO_ROOT/.env"; set +a
fi

ANALYTICS_CORE_PATH="${ANALYTICS_CORE_PATH:-examples/olmis-analytics-core}"
ANALYTICS_EXTENSIONS_PATHS="${ANALYTICS_EXTENSIONS_PATHS:-}"
CLICKHOUSE_HOST="${CLICKHOUSE_HOST:-clickhouse}"
CLICKHOUSE_PORT="${CLICKHOUSE_PORT:-8123}"
CLICKHOUSE_USER="${CLICKHOUSE_USER:-default}"
CLICKHOUSE_PASSWORD="${CLICKHOUSE_PASSWORD:-changeme}"
DBT_ARGS="${DBT_ARGS:-}"

DBT_DIR="$REPO_ROOT/dbt"

# Generate packages.yml from env vars
echo "Generating packages.yml..."
PACKAGES_FILE="$DBT_DIR/packages.yml"
cat > "$PACKAGES_FILE" <<EOF
packages:
  - local: /analytics/core/dbt
EOF

if [ -n "$ANALYTICS_EXTENSIONS_PATHS" ]; then
  IFS=',' read -ra EXTENSIONS <<< "$ANALYTICS_EXTENSIONS_PATHS"
  for i in "${!EXTENSIONS[@]}"; do
    echo "  - local: /analytics/extensions/$i/dbt" >> "$PACKAGES_FILE"
  done
fi

echo "Building dbt Docker image..."
docker build -q -t reporting-dbt "$DBT_DIR"

# Build volume mounts: dbt project + analytics packages
COMPOSE_PROJECT="${COMPOSE_PROJECT_NAME:-soldevelo-reporting-stack}"

# Resolve absolute vs relative paths for analytics packages
resolve_path() {
  if [[ "$1" = /* ]]; then
    echo "$1"
  else
    echo "$REPO_ROOT/$1"
  fi
}

CORE_ABS=$(resolve_path "$ANALYTICS_CORE_PATH")

DOCKER_ARGS=(
  --rm
  --network "${COMPOSE_PROJECT}_reporting"
  -e "CLICKHOUSE_HOST=${CLICKHOUSE_HOST}"
  -e "CLICKHOUSE_PORT=${CLICKHOUSE_PORT}"
  -e "CLICKHOUSE_USER=${CLICKHOUSE_USER}"
  -e "CLICKHOUSE_PASSWORD=${CLICKHOUSE_PASSWORD}"
  -v "$CORE_ABS:/analytics/core:ro"
)

# Mount extensions if configured
if [ -n "$ANALYTICS_EXTENSIONS_PATHS" ]; then
  IFS=',' read -ra EXTENSIONS <<< "$ANALYTICS_EXTENSIONS_PATHS"
  for i in "${!EXTENSIONS[@]}"; do
    ext_abs=$(resolve_path "${EXTENSIONS[$i]}")
    DOCKER_ARGS+=(-v "$ext_abs:/analytics/extensions/$i:ro")
  done
fi

echo "Running dbt deps + build..."
# Run deps and build in the same container so dbt_packages persists
# shellcheck disable=SC2086
docker run "${DOCKER_ARGS[@]}" --entrypoint bash reporting-dbt -c \
  "dbt deps --profiles-dir /dbt && dbt build --profiles-dir /dbt $DBT_ARGS"

echo ""
echo "dbt build complete."
