#!/usr/bin/env bash
# =============================================================================
# Run a dbt command using Docker.
#
# Usage:
#   scripts/dbt/run.sh build [extra dbt args]
#   scripts/dbt/run.sh test [extra dbt args]
#
# Builds the dbt Docker image, generates packages.yml, then runs
# dbt deps + the specified command in a single container.
#
# Configuration:
#   ANALYTICS_CORE_PATH         path to core analytics package (default: examples/olmis-analytics-core)
#   ANALYTICS_EXTENSIONS_PATHS  comma-separated extension package paths (optional)
#   CLICKHOUSE_HOST             ClickHouse hostname for dbt (default: clickhouse)
#   CLICKHOUSE_PORT             ClickHouse HTTP port (default: 8123)
#   CLICKHOUSE_USER             ClickHouse user (default: default)
#   CLICKHOUSE_PASSWORD         ClickHouse password (default: changeme)
#   REPORTING_HOST_ROOT         host path override for Docker-in-Docker (Airflow)
# =============================================================================
set -euo pipefail

DBT_CMD="${1:-build}"
shift || true
DBT_EXTRA_ARGS="$*"

# SCRIPT_ROOT is always the real filesystem path (container or host).
# DOCKER_ROOT is the path Docker daemon uses for volume mounts (always host).
SCRIPT_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"

if [ -f "$SCRIPT_ROOT/.env" ]; then
  set -a; source "$SCRIPT_ROOT/.env"; set +a
fi

# When invoked from inside a Docker container (e.g., Airflow) via socket bind-mount,
# docker build/run paths are resolved by the HOST daemon, not the container filesystem.
if [ -f "/.dockerenv" ] && [ -n "${REPORTING_HOST_ROOT:-}" ]; then
  DOCKER_ROOT="$REPORTING_HOST_ROOT"
else
  DOCKER_ROOT="$SCRIPT_ROOT"
fi

ANALYTICS_CORE_PATH="${ANALYTICS_CORE_PATH:-examples/olmis-analytics-core}"
ANALYTICS_EXTENSIONS_PATHS="${ANALYTICS_EXTENSIONS_PATHS:-}"
CLICKHOUSE_HOST="${CLICKHOUSE_HOST:-clickhouse}"
CLICKHOUSE_PORT="${CLICKHOUSE_PORT:-8123}"
CLICKHOUSE_USER="${CLICKHOUSE_USER:-default}"
CLICKHOUSE_PASSWORD="${CLICKHOUSE_PASSWORD:-changeme}"

# Determine loading mode: Git (production) vs local (development)
ANALYTICS_CORE_GIT_URL="${ANALYTICS_CORE_GIT_URL:-}"
ANALYTICS_CORE_GIT_REF="${ANALYTICS_CORE_GIT_REF:-main}"
ANALYTICS_EXTENSION_GIT_URLS="${ANALYTICS_EXTENSION_GIT_URLS:-}"
ANALYTICS_EXTENSION_GIT_REFS="${ANALYTICS_EXTENSION_GIT_REFS:-}"
GIT_MODE=""
if [ -n "$ANALYTICS_CORE_GIT_URL" ]; then
  GIT_MODE=1
fi

# Generate packages.yml
DBT_DIR="$SCRIPT_ROOT/dbt"

if [ -n "$GIT_MODE" ]; then
  # Git mode: dbt fetches packages directly from Git
  cat > "$DBT_DIR/packages.yml" <<EOF
packages:
  - git: "${ANALYTICS_CORE_GIT_URL}"
    revision: "${ANALYTICS_CORE_GIT_REF}"
    subdirectory: "dbt"
EOF

  if [ -n "$ANALYTICS_EXTENSION_GIT_URLS" ]; then
    IFS=',' read -ra EXT_URLS <<< "$ANALYTICS_EXTENSION_GIT_URLS"
    IFS=',' read -ra EXT_REFS <<< "$ANALYTICS_EXTENSION_GIT_REFS"
    for i in "${!EXT_URLS[@]}"; do
      local_ref="${EXT_REFS[$i]:-main}"
      cat >> "$DBT_DIR/packages.yml" <<EOF
  - git: "$(echo "${EXT_URLS[$i]}" | xargs)"
    revision: "$(echo "$local_ref" | xargs)"
    subdirectory: "dbt"
EOF
    done
  fi
else
  # Local mode: mount packages as Docker volumes
  cat > "$DBT_DIR/packages.yml" <<EOF
packages:
  - local: /analytics/core/dbt
EOF

  if [ -n "$ANALYTICS_EXTENSIONS_PATHS" ]; then
    IFS=',' read -ra EXTENSIONS <<< "$ANALYTICS_EXTENSIONS_PATHS"
    for i in "${!EXTENSIONS[@]}"; do
      echo "  - local: /analytics/extensions/$i/dbt" >> "$DBT_DIR/packages.yml"
    done
  fi
fi

# Docker build uses DOCKER_ROOT (host path for daemon to find build context)
echo "Building dbt Docker image..."
docker build -q -t reporting-dbt "$DOCKER_ROOT/dbt"

COMPOSE_PROJECT="${COMPOSE_PROJECT_NAME:-soldevelo-reporting-stack}"

resolve_path() {
  if [[ "$1" = /* ]]; then
    echo "$1"
  else
    echo "$DOCKER_ROOT/$1"
  fi
}

DOCKER_ARGS=(
  --rm
  --network "${COMPOSE_PROJECT}_reporting"
  -e "CLICKHOUSE_HOST=${CLICKHOUSE_HOST}"
  -e "CLICKHOUSE_PORT=${CLICKHOUSE_PORT}"
  -e "CLICKHOUSE_USER=${CLICKHOUSE_USER}"
  -e "CLICKHOUSE_PASSWORD=${CLICKHOUSE_PASSWORD}"
)

# In local mode, mount package directories into the container.
# In Git mode, dbt deps fetches from Git — no mounts needed.
if [ -z "$GIT_MODE" ]; then
  CORE_ABS=$(resolve_path "$ANALYTICS_CORE_PATH")
  DOCKER_ARGS+=(-v "$CORE_ABS:/analytics/core:ro")

  if [ -n "$ANALYTICS_EXTENSIONS_PATHS" ]; then
    IFS=',' read -ra EXTENSIONS <<< "$ANALYTICS_EXTENSIONS_PATHS"
    for i in "${!EXTENSIONS[@]}"; do
      ext_abs=$(resolve_path "$(echo "${EXTENSIONS[$i]}" | xargs)")
      DOCKER_ARGS+=(-v "$ext_abs:/analytics/extensions/$i:ro")
    done
  fi
fi

echo "Running dbt deps + ${DBT_CMD}..."
# shellcheck disable=SC2086
docker run "${DOCKER_ARGS[@]}" --entrypoint bash reporting-dbt -c \
  "dbt deps --profiles-dir /dbt && dbt ${DBT_CMD} --profiles-dir /dbt $DBT_EXTRA_ARGS"

echo ""
echo "dbt ${DBT_CMD} complete."
