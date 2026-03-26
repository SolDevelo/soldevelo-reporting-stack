# olmis-analytics-core

Reference **analytics-core** package for OpenLMIS/OLMIS. This is a permanent example that ships with the reporting-stack platform repository.

In production, each adopter maintains their own analytics-core package in a separate repository. This example demonstrates the expected structure and serves as a development/testing reference.

## Directory structure

```
olmis-analytics-core/
  connect/
    openlmis-postgres-cdc.json    # Debezium connector config template
  dbt/
    dbt_project.yml               # dbt package config
    models/
      staging/
        stg_facilities.sql        # Current-state: referencedata.facilities
        stg_programs.sql          # Current-state: referencedata.programs
        stg_geographic_zones.sql  # Current-state: referencedata.geographic_zones
        stg_requisitions.sql      # Current-state: requisition.requisitions
        schema.yml                # Tests for all staging models
      marts/
        mart_facility_directory.sql    # Facilities + geographic zone hierarchy
        mart_requisition_summary.sql   # Requisitions + facility/program/zone names
        schema.yml                     # Tests for all mart models
  superset/
    assets/
      metadata.yaml                              # Bundle metadata
      databases/reporting_clickhouse.yaml        # ClickHouse connection (no password)
      datasets/reporting_clickhouse/
        mart_requisition_summary.yaml            # Dataset on the requisition mart
      charts/requisitions_by_status.yaml         # Pie chart: requisitions by status
      dashboards/olmis_requisition_overview.yaml # Dashboard with the chart
```

## Connector config

`connect/openlmis-postgres-cdc.json` is a Debezium PostgreSQL connector template. Environment variables (`${SOURCE_PG_HOST}`, `${SOURCE_PG_PASSWORD}`, `${DEBEZIUM_TOPIC_PREFIX}`, etc.) are substituted at registration time via `envsubst`.

Key settings:
- **JSON converters** for ClickHouse compatibility
- **Initial snapshot** enabled — captures existing data on first start
- **Heartbeat** every 10 seconds to `public.reporting_heartbeat`
- **Table allowlist** from `${SOURCE_PG_TABLE_ALLOWLIST}`

To customize for your system: copy this file, change the table allowlist and topic prefix, adjust decimal/time handling if needed.

## dbt models

### Staging models (views)

Each staging model reconstructs **current state** from the append-only CDC event stream using a ranked CTE pattern:

1. Partition by primary key (from JSON `after` payload)
2. Order by `ts_ms desc, _ingested_at desc` (latest event wins)
3. Filter out deletes (`op != 'd'`)
4. Extract typed columns with `JSONExtractString`, `JSONExtractBool`, `toUUID`

| Model | Source table | Primary key |
|---|---|---|
| `stg_facilities` | `referencedata.facilities` | `id` (UUID) |
| `stg_programs` | `referencedata.programs` | `id` (UUID) |
| `stg_geographic_zones` | `referencedata.geographic_zones` | `id` (UUID), with `parent_id` self-join |
| `stg_requisitions` | `requisition.requisitions` | `id` (UUID), with FK to facilities and programs |

### Mart models (tables)

Marts join staging views into analytics-ready ClickHouse MergeTree tables:

| Model | Description | Key joins |
|---|---|---|
| `mart_facility_directory` | Facilities enriched with geographic zone hierarchy | `stg_facilities` → `stg_geographic_zones` (zone + parent zone) |
| `mart_requisition_summary` | Requisitions with facility, program, and zone names | `stg_requisitions` → `stg_facilities` → `stg_geographic_zones` + `stg_programs` |

### Tests

All models have tests in their respective `schema.yml`:
- **Integrity**: `not_null` + `unique` on primary keys
- **Relationships**: foreign keys validated (e.g., `facility_id` → `stg_facilities.id`)
- **Accepted values**: enumeration fields (e.g., requisition status)

## Superset assets

The `superset/assets/` directory contains a complete asset bundle:

- **Database**: ClickHouse connection to the `curated` schema (password omitted per secrets policy — patched at import time from env vars)
- **Dataset**: `mart_requisition_summary` with typed columns and a `COUNT(*)` metric
- **Chart**: "Requisitions by Status" pie chart
- **Dashboard**: "OLMIS Requisition Overview" containing the chart

Assets use stable UUIDs for idempotent re-imports. Import with `make superset-import`.

## Customizing for your project

To create a core package for a different adopter system:

1. **Copy this directory** as a starting point
2. **Update the connector config**: change the table allowlist, topic prefix, and database connection settings
3. **Replace the staging models**: one per source table, using the ranked CTE pattern for current-state reconstruction
4. **Design your marts**: join staging models into the tables your dashboards need
5. **Add tests**: `not_null`/`unique` on PKs, `relationships` on FKs, `accepted_values` on enums
6. **Create Superset assets**: author charts/dashboards in the UI, export as YAML, commit to `superset/assets/`
7. **Set `ANALYTICS_CORE_PATH`** in `.env` to point to your package

For detailed guidance on each step, see [docs/usage-guide.md](../../docs/usage-guide.md).

## Usage

Set `ANALYTICS_CORE_PATH=examples/olmis-analytics-core` in the platform's `.env` (this is the default).
