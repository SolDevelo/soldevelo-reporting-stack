#!/usr/bin/env bash
# =============================================================================
# Fetch analytics packages from Git repositories.
#
# Clones the core package and any extension packages to .packages/ under the
# repo root. After fetching, sets ANALYTICS_CORE_PATH and
# ANALYTICS_EXTENSIONS_PATHS so downstream scripts (register-connector,
# superset-import) find the right files.
#
# This script handles the non-dbt parts of packages (connector config,
# Superset assets). dbt has its own Git loading via packages.yml — see
# scripts/dbt/run.sh.
#
# Usage:
#   source scripts/packages/fetch.sh   # sets env vars for current shell
#   bash scripts/packages/fetch.sh     # prints env vars to stdout
#
# Env vars:
#   ANALYTICS_CORE_GIT_URL       Git URL for the core package (required)
#   ANALYTICS_CORE_GIT_REF       Git ref (tag/branch/sha, default: main)
#   ANALYTICS_EXTENSION_GIT_URLS Comma-separated Git URLs for extensions
#   ANALYTICS_EXTENSION_GIT_REFS Comma-separated Git refs (matched by index)
#   GIT_TOKEN                    Optional token for private repos (used as
#                                https://<token>@github.com/...)
# =============================================================================
set -euo pipefail
REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"

if [ -f "$REPO_ROOT/.env" ]; then
  set -a; source "$REPO_ROOT/.env"; set +a
fi

ANALYTICS_CORE_GIT_URL="${ANALYTICS_CORE_GIT_URL:-}"
ANALYTICS_CORE_GIT_REF="${ANALYTICS_CORE_GIT_REF:-main}"
ANALYTICS_EXTENSION_GIT_URLS="${ANALYTICS_EXTENSION_GIT_URLS:-}"
ANALYTICS_EXTENSION_GIT_REFS="${ANALYTICS_EXTENSION_GIT_REFS:-}"
GIT_TOKEN="${GIT_TOKEN:-}"

PACKAGES_DIR="$REPO_ROOT/.packages"

if [ -z "$ANALYTICS_CORE_GIT_URL" ]; then
  echo "ANALYTICS_CORE_GIT_URL is not set — skipping Git fetch." >&2
  echo "Using local paths (ANALYTICS_CORE_PATH=${ANALYTICS_CORE_PATH:-examples/olmis-analytics-core})" >&2
  exit 0
fi

# Insert token into Git URL for private repos
auth_url() {
  local url="$1"
  if [ -n "$GIT_TOKEN" ]; then
    echo "$url" | sed "s|https://|https://${GIT_TOKEN}@|"
  else
    echo "$url"
  fi
}

# Clone a repo to a target directory (shallow, pinned ref)
clone_package() {
  local url="$1"
  local ref="$2"
  local target="$3"

  rm -rf "$target"
  mkdir -p "$(dirname "$target")"

  local auth_git_url
  auth_git_url=$(auth_url "$url")

  echo "  Cloning $(basename "$url" .git) @ $ref..."
  git clone --depth 1 --branch "$ref" --single-branch -q \
    "$auth_git_url" "$target" 2>&1 || {
      echo "ERROR: failed to clone $url @ $ref" >&2
      exit 1
    }
  # Remove .git to save space — we only need the files
  rm -rf "$target/.git"
}

echo "=== Fetching analytics packages ==="

# 1. Core package
echo "Core package:"
clone_package "$ANALYTICS_CORE_GIT_URL" "$ANALYTICS_CORE_GIT_REF" "$PACKAGES_DIR/core"
ANALYTICS_CORE_PATH="$PACKAGES_DIR/core"

# 2. Extension packages
EXTENSIONS_LIST=""
if [ -n "$ANALYTICS_EXTENSION_GIT_URLS" ]; then
  echo "Extension packages:"
  IFS=',' read -ra EXT_URLS <<< "$ANALYTICS_EXTENSION_GIT_URLS"
  IFS=',' read -ra EXT_REFS <<< "$ANALYTICS_EXTENSION_GIT_REFS"
  for i in "${!EXT_URLS[@]}"; do
    ext_url="$(echo "${EXT_URLS[$i]}" | xargs)"
    ext_ref="$(echo "${EXT_REFS[$i]:-main}" | xargs)"
    ext_name="$(basename "$ext_url" .git)"
    clone_package "$ext_url" "$ext_ref" "$PACKAGES_DIR/extensions/$ext_name"

    if [ -n "$EXTENSIONS_LIST" ]; then
      EXTENSIONS_LIST="$EXTENSIONS_LIST,"
    fi
    EXTENSIONS_LIST="${EXTENSIONS_LIST}${PACKAGES_DIR}/extensions/$ext_name"
  done
fi
ANALYTICS_EXTENSIONS_PATHS="$EXTENSIONS_LIST"

echo ""
echo "Packages fetched to: $PACKAGES_DIR"
echo "  ANALYTICS_CORE_PATH=$ANALYTICS_CORE_PATH"
if [ -n "$ANALYTICS_EXTENSIONS_PATHS" ]; then
  echo "  ANALYTICS_EXTENSIONS_PATHS=$ANALYTICS_EXTENSIONS_PATHS"
fi

# Export for downstream scripts when sourced
export ANALYTICS_CORE_PATH
export ANALYTICS_EXTENSIONS_PATHS
