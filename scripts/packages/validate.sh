#!/usr/bin/env bash
# =============================================================================
# Validate analytics packages: enforce the extend-only rule for extensions.
#
# Checks:
#   1. Extensions must not include a connect/ directory (ingestion is core-only)
#   2. Extension dbt model names must not collide with core model names
#   3. Extension Superset asset UUIDs must not collide with core UUIDs
#
# Usage:
#   scripts/packages/validate.sh
#
# Reads ANALYTICS_CORE_PATH and ANALYTICS_EXTENSIONS_PATHS from .env.
# Exits 0 if valid, 1 if any violation is found.
# =============================================================================
set -euo pipefail
REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"

if [ -f "$REPO_ROOT/.env" ]; then
  set -a; source "$REPO_ROOT/.env"; set +a
fi

ANALYTICS_CORE_PATH="${ANALYTICS_CORE_PATH:-examples/olmis-analytics-core}"
ANALYTICS_EXTENSIONS_PATHS="${ANALYTICS_EXTENSIONS_PATHS:-}"

# Resolve relative paths
if [[ "$ANALYTICS_CORE_PATH" != /* ]]; then
  ANALYTICS_CORE_PATH="$REPO_ROOT/$ANALYTICS_CORE_PATH"
fi

if [ -z "$ANALYTICS_EXTENSIONS_PATHS" ]; then
  echo "No extension packages configured — nothing to validate."
  exit 0
fi

ERRORS=0

error() {
  echo "  FAIL  $1" >&2
  ERRORS=$((ERRORS + 1))
}

pass() {
  echo "  PASS  $1"
}

echo "Validate: analytics packages"
echo "-------------------------------"
echo "Core: $ANALYTICS_CORE_PATH"

# Collect core dbt model names (filenames without .sql extension)
CORE_MODELS=""
if [ -d "$ANALYTICS_CORE_PATH/dbt/models" ]; then
  CORE_MODELS=$(find "$ANALYTICS_CORE_PATH/dbt/models" -name '*.sql' -exec basename {} .sql \; | sort)
fi

# Collect core Superset UUIDs
CORE_UUIDS=""
if [ -d "$ANALYTICS_CORE_PATH/superset/assets" ]; then
  CORE_UUIDS=$(grep -rh '^uuid:' "$ANALYTICS_CORE_PATH/superset/assets/" 2>/dev/null \
    | sed 's/^uuid:[[:space:]]*//' | tr -d '"' | sort)
fi

# Validate each extension
IFS=',' read -ra EXT_PATHS <<< "$ANALYTICS_EXTENSIONS_PATHS"
for ext_path in "${EXT_PATHS[@]}"; do
  ext_path="$(echo "$ext_path" | xargs)"
  if [[ "$ext_path" != /* ]]; then
    ext_path="$REPO_ROOT/$ext_path"
  fi

  ext_name="$(basename "$ext_path")"
  echo ""
  echo "Extension: $ext_name ($ext_path)"

  # Check 1: no connect/ directory
  if [ -d "$ext_path/connect" ]; then
    error "$ext_name: contains connect/ directory (extensions must not change ingestion)"
  else
    pass "$ext_name: no connect/ directory"
  fi

  # Check 2: no dbt model name collisions
  if [ -d "$ext_path/dbt/models" ]; then
    EXT_MODELS=$(find "$ext_path/dbt/models" -name '*.sql' -exec basename {} .sql \; | sort)
    if [ -n "$CORE_MODELS" ] && [ -n "$EXT_MODELS" ]; then
      COLLISIONS=$(comm -12 <(printf '%s\n' "$CORE_MODELS") <(printf '%s\n' "$EXT_MODELS"))
      if [ -n "$COLLISIONS" ]; then
        error "$ext_name: dbt model name collision with core: $(echo "$COLLISIONS" | tr '\n' ', ' | sed 's/,$//')"
      else
        pass "$ext_name: no dbt model name collisions"
      fi
    else
      pass "$ext_name: no dbt model name collisions"
    fi
  else
    pass "$ext_name: no dbt models (nothing to check)"
  fi

  # Check 3: no Superset UUID collisions
  if [ -d "$ext_path/superset/assets" ]; then
    EXT_UUIDS=$(grep -rh '^uuid:' "$ext_path/superset/assets/" 2>/dev/null \
      | sed 's/^uuid:[[:space:]]*//' | tr -d '"' | sort || true)
    if [ -n "$EXT_UUIDS" ] && [ -n "$CORE_UUIDS" ]; then
      UUID_COLLISIONS=$(comm -12 <(printf '%s\n' "$CORE_UUIDS") <(printf '%s\n' "$EXT_UUIDS"))
      if [ -n "$UUID_COLLISIONS" ]; then
        error "$ext_name: Superset UUID collision with core: $(echo "$UUID_COLLISIONS" | tr '\n' ', ' | sed 's/,$//')"
      else
        pass "$ext_name: no Superset UUID collisions"
      fi
    else
      pass "$ext_name: no Superset UUIDs to check"
    fi
  else
    pass "$ext_name: no Superset assets (nothing to check)"
  fi
done

echo ""
echo "-------------------------------"
if [ "$ERRORS" -gt 0 ]; then
  echo "Validation FAILED: $ERRORS error(s) found"
  exit 1
else
  echo "Validation passed"
fi
