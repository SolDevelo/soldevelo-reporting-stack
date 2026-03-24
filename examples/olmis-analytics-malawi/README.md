# olmis-analytics-malawi

Reference **analytics-extension** package for OpenLMIS Malawi. This is a permanent example that ships with the reporting-stack platform repository.

Extensions are additive only — they add new dbt marts and Superset dashboards but must not modify core models/dashboards or change ingestion contracts.

## Contents

| Directory | Purpose |
|---|---|
| `dbt/` | Additional dbt models and tests for Malawi-specific reporting |
| `superset/` | Additional Superset dashboards and charts |

Note: extension packages do **not** include `connect/` — ingestion configuration is owned by the core package.
