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

# Guard: a relative DOCKER_ROOT would silently mount the wrong host directory
# (the daemon resolves relative paths against its own cwd, not the caller's).
if [[ "$DOCKER_ROOT" != /* ]]; then
  echo "ERROR: REPORTING_HOST_ROOT must be an absolute path (got: '$DOCKER_ROOT')" >&2
  echo "       Update .env so the Docker daemon can resolve volume mounts correctly." >&2
  exit 1
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
      # Trailing comma in the env var (a common shape with envsubst /
      # compose interpolation) produces empty array elements. Skip them
      # rather than writing duplicate or blank entries into packages.yml.
      ext_url="$(echo "${EXT_URLS[$i]}" | xargs)"
      [ -z "$ext_url" ] && continue
      local_ref="${EXT_REFS[$i]:-main}"
      cat >> "$DBT_DIR/packages.yml" <<EOF
  - git: "$ext_url"
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
      # Same skip-empty guard as the git-mode branch.
      ext_path="$(echo "${EXTENSIONS[$i]}" | xargs)"
      [ -z "$ext_path" ] && continue
      echo "  - local: /analytics/extensions/$i/dbt" >> "$DBT_DIR/packages.yml"
    done
  fi
fi

# `docker build <ctx>` tars the context on the CLI side, so the path must
# exist in the script's own filesystem (SCRIPT_ROOT), not the host filesystem
# the daemon sees (DOCKER_ROOT). When invoked from inside the airflow-scheduler
# container, SCRIPT_ROOT is /opt/reporting (the bind-mount); DOCKER_ROOT is the
# host path the daemon uses for `docker run -v` later.
echo "Building dbt Docker image..."
docker build -q -t reporting-dbt "$SCRIPT_ROOT/dbt"

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
)

# Optional seccomp profile for the dbt container. The dbt run is a bare
# `docker run` (not a compose service), so a compose security_opt override
# does not reach it. On hosts with an outdated Docker/seccomp that rejects the
# clone3 syscall (EPERM), dbt's worker threads crash; set DBT_DOCKER_SECCOMP=
# unconfined in .env there. Unset = the daemon default profile (unchanged).
if [ -n "${DBT_DOCKER_SECCOMP:-}" ]; then
  DOCKER_ARGS+=(--security-opt "seccomp=${DBT_DOCKER_SECCOMP}")
fi

DOCKER_ARGS+=(
  -e "CLICKHOUSE_PORT=${CLICKHOUSE_PORT}"
  -e "CLICKHOUSE_USER=${CLICKHOUSE_USER}"
  -e "CLICKHOUSE_PASSWORD=${CLICKHOUSE_PASSWORD}"
  # Source PG credentials for cross-system reconciliation tests
  # (reconcile_with_source generic test renders ClickHouse's postgresql()
  # table function with these values to read the live source state).
  -e "SOURCE_PG_HOST=${SOURCE_PG_HOST:-}"
  -e "SOURCE_PG_PORT=${SOURCE_PG_PORT:-5432}"
  -e "SOURCE_PG_DB=${SOURCE_PG_DB:-}"
  -e "SOURCE_PG_USER=${SOURCE_PG_USER:-}"
  -e "SOURCE_PG_PASSWORD=${SOURCE_PG_PASSWORD:-}"
)

# In local mode, mount package directories into the container.
# In Git mode, dbt deps fetches from Git — no mounts needed,
# but file:// URLs need the host path mounted for local Git testing.
if [ -n "$GIT_MODE" ]; then
  for git_url in "$ANALYTICS_CORE_GIT_URL" $(echo "${ANALYTICS_EXTENSION_GIT_URLS:-}" | tr ',' ' '); do
    if [[ "$git_url" == file://* ]]; then
      local_path="${git_url#file://}"
      DOCKER_ARGS+=(-v "$local_path:$local_path:ro")
    fi
  done
elif [ -z "$GIT_MODE" ]; then
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
