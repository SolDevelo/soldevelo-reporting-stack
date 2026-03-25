#!/usr/bin/env bash
# Run dbt build (models + tests). Delegates to run.sh.
exec "$(dirname "$0")/run.sh" build "$@"
