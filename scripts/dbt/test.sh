#!/usr/bin/env bash
# Run dbt test (data quality tests only). Delegates to run.sh.
exec "$(dirname "$0")/run.sh" test "$@"
