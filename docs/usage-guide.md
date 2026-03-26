# Usage Guide

Practical how-to guides for developers building reporting on this platform. These guides assume the platform is running and the [Getting Started](../README.md#getting-started) steps are complete.

For architecture principles and design rationale, see [architecture.md](architecture.md). For platform debugging and verification, see [development.md](development.md).

## Add a new source table end-to-end

This walks through adding a new PostgreSQL table to the full pipeline: CDC ingestion → ClickHouse raw landing → dbt staging → dbt mart → Superset dashboard.

**Example**: adding the `referencedata.orderable_display_categories` table.

### 1. Add the table to the PostgreSQL publication

On the source database, add the table to the CDC publication:

```sql
ALTER PUBLICATION dbz_publication ADD TABLE referencedata.orderable_display_categories;
```

See [source-db-setup.md](source-db-setup.md) for initial publication setup.

### 2. Add the table to the allowlist

In `.env`, append the table to `SOURCE_PG_TABLE_ALLOWLIST`:

```env
SOURCE_PG_TABLE_ALLOWLIST=referencedata.facilities,...,referencedata.orderable_display_categories
```

### 3. Re-register the CDC connector

```bash
make register-connector
```

This updates the Debezium connector config with the new table. The connector will begin capturing changes and produce a new Kafka topic (e.g., `openlmis.referencedata.orderable_display_categories`).

### 4. Re-initialize ClickHouse raw landing

```bash
make clickhouse-init
```

This creates the Kafka engine table, MergeTree storage table, and Materialized View for the new topic. Existing tables are not affected (idempotent).

### 5. Verify data arrives

Wait a few seconds for Debezium's initial snapshot, then check:

```bash
make verify-ingestion
```

Or query ClickHouse directly:

```bash
curl -s "http://localhost:8123/" --user "default:changeme" \
  --data-binary "SELECT count() FROM raw.events_openlmis_referencedata_orderable_display_categories"
```

### 6. Create a dbt staging model

Create a new file in your analytics package's `dbt/models/staging/` directory. See [Add a dbt model](#add-a-dbt-model) below for the pattern.

### 7. Add tests

Add the model to `dbt/models/staging/schema.yml` with at minimum `not_null` and `unique` on the primary key. See [Required tests](#required-tests) below.

### 8. Create or update a mart model

If the new table feeds an existing mart, update it to join the new staging model. If it's a new reporting domain, create a new mart in `dbt/models/marts/`. See [Mart models](#mart-models) below.

### 9. Build and verify

```bash
make dbt-build
make verify-dbt
```

### 10. Add a Superset visualization (optional)

Create a dataset, chart, and/or dashboard for the new data. See [Add a Superset chart/dashboard](#add-a-superset-chartdashboard) below.

```bash
make superset-import
make verify-superset
```

## Add a dbt model

All dbt models live in the analytics package (e.g., `examples/olmis-analytics-core/dbt/`). The platform provides the runner project and generic macros; packages provide the domain-specific models.

### Staging models

Staging models reconstruct **current state** from the append-only CDC event stream. Each staging model reads from one raw landing table.

The pattern uses a ranked CTE to select the latest event per primary key, excluding deletes:

```sql
{{
  config(
    materialized='view'
  )
}}

with ranked as (
  select
    *,
    row_number() over (
      partition by JSONExtractString(after, 'id')
      order by ts_ms desc, _ingested_at desc
    ) as _rn
  from raw.events_openlmis_referencedata_facilities
  where op != 'd'
    and JSONExtractString(after, 'id') != ''
)

select
  toUUID(JSONExtractString(after, 'id'))    as id,
  JSONExtractString(after, 'code')           as code,
  JSONExtractString(after, 'name')           as name,
  JSONExtractBool(after, 'active')           as active
from ranked
where _rn = 1
```

Key points:

- **`partition by`** on the primary key column (extracted from the `after` JSON payload)
- **`order by ts_ms desc, _ingested_at desc`** ensures the latest event wins
- **`where op != 'd'`** excludes deletes (deleted rows disappear from the view)
- **`JSONExtractString(after, 'id') != ''`** filters out events with empty payloads (e.g., tombstones)
- **JSON extraction functions**: `JSONExtractString`, `JSONExtractBool`, `JSONExtractInt`, `JSONExtractFloat` for typed access to the CDC payload
- **Type casting**: `toUUID()` / `toUUIDOrNull()` for UUID columns, standard ClickHouse cast functions for others
- **Materialized as `view`** — staging models are lightweight and always read current data

See `examples/olmis-analytics-core/dbt/models/staging/stg_facilities.sql` for a complete working example.

### Mart models

Mart models join staging views into analytics-ready tables. They are the stable **BI contract** — dashboards query only these, never raw tables.

```sql
{{
  config(
    materialized='table',
    engine='MergeTree()',
    order_by='(program_name, facility_name, status)'
  )
}}

select
  r.id              as requisition_id,
  r.status          as status,
  f.name            as facility_name,
  p.name            as program_name
from {{ ref('stg_requisitions') }} r
left join {{ ref('stg_facilities') }} f on r.facility_id = f.id
left join {{ ref('stg_programs') }} p on r.program_id = p.id
```

Key points:

- **Materialized as `table`** with `MergeTree()` engine for query performance
- **`order_by`** should match common query patterns (filter/group columns first)
- Use `{{ ref('stg_...') }}` to reference staging models (dbt manages dependencies)
- Column names in marts are the public contract — renaming is a breaking change

See `examples/olmis-analytics-core/dbt/models/marts/mart_requisition_summary.sql` for a complete example.

### Required tests

Every model must have tests in the corresponding `schema.yml`. Minimum requirements per [architecture principles](architecture.md):

| Test type | Purpose | Example |
|---|---|---|
| `not_null` | Integrity — required columns have values | Primary keys, foreign keys, status fields |
| `unique` | Integrity — no duplicate rows per key | Primary key column |
| `relationships` | Referential — foreign keys point to valid records | `facility_id` references `stg_facilities.id` |
| `accepted_values` | Enumerations — status fields have known values | Requisition status in `[INITIATED, SUBMITTED, ...]` |

Example `schema.yml` entry:

```yaml
models:
  - name: stg_requisitions
    columns:
      - name: id
        tests:
          - not_null
          - unique
      - name: status
        tests:
          - not_null
          - accepted_values:
              arguments:
                values: [INITIATED, SUBMITTED, AUTHORIZED, APPROVED, RELEASED]
      - name: facility_id
        tests:
          - not_null
          - relationships:
              arguments:
                to: ref('stg_facilities')
                field: id
```

See `examples/olmis-analytics-core/dbt/models/staging/schema.yml` for a full example.

### File placement

```
your-analytics-package/
  dbt/
    dbt_project.yml
    models/
      staging/
        stg_your_table.sql       # one per source table
        schema.yml               # tests for all staging models
      marts/
        mart_your_report.sql     # joins staging models
        schema.yml               # tests for all mart models
```

### Build and verify

```bash
make dbt-build      # run dbt deps + build (models + tests)
make dbt-test       # run tests only (faster, no model rebuild)
make verify-dbt     # build + verify curated marts have data
```

## Add a Superset chart/dashboard

Superset assets are managed as code: YAML files in Git are the source of truth, imported into Superset at deploy time.

### Workflow

1. **Author in the Superset UI** — create or edit charts and dashboards interactively at `http://localhost:8088`
2. **Export** — download as ZIP from the Superset UI (Dashboard → `...` menu → Export) or via the API
3. **Unzip and commit** — extract the YAML files into your analytics package's `superset/assets/` directory
4. **Import** — run `make superset-import` on target environments

### Asset directory structure

```
your-analytics-package/
  superset/
    assets/
      metadata.yaml                              # bundle metadata (required)
      databases/
        reporting_clickhouse.yaml                # ClickHouse connection
      datasets/
        reporting_clickhouse/
          mart_requisition_summary.yaml          # dataset on a curated mart
      charts/
        requisitions_by_status.yaml              # chart definition
      dashboards/
        olmis_requisition_overview.yaml          # dashboard layout + chart refs
```

### metadata.yaml

Every asset bundle requires a `metadata.yaml` at its root:

```yaml
version: "1.0.0"
type: Dashboard
timestamp: "2026-01-01T00:00:00+00:00"
```

The `type` must be `Dashboard` (this is what Superset's `import-dashboards` CLI expects). The `version` must be `"1.0.0"`.

### UUIDs

Every Superset asset (database, dataset, chart, dashboard) has a `uuid` field. These are stable identifiers that enable **idempotent re-imports** — importing the same UUID updates the existing asset rather than creating a duplicate.

When you export from the Superset UI, UUIDs are already assigned. If creating YAML files manually, generate UUIDs with:

```bash
python3 -c "import uuid; print(uuid.uuid4())"
```

### Secrets policy

**Database credentials must never be stored in Git.** The database YAML contains the connection URI without a password:

```yaml
sqlalchemy_uri: "clickhousedb+connect://default@clickhouse:8123/curated"
```

The import script (`scripts/superset/import-assets.sh`) patches the password from environment variables (`CLICKHOUSE_USER`, `CLICKHOUSE_PASSWORD`, `CLICKHOUSE_HOST`) after import.

### Datasets connect to curated marts only

Datasets must reference tables in the `curated` ClickHouse database (dbt marts). Never create datasets on `raw` tables — they contain append-only CDC events, not current-state data.

### Import and verify

```bash
make superset-import    # imports platform → core → extension assets
make verify-superset    # checks health + dashboard exists
```

See `examples/olmis-analytics-core/superset/assets/` for a complete working asset bundle.

## Author an analytics package

An analytics package provides domain-specific reporting logic for a particular adopter system. The platform loads packages at runtime via environment variables.

### Package types

| Type | Purpose | Includes |
|---|---|---|
| **Core** (required) | Baseline ingestion config + models + dashboards | `connect/` + `dbt/` + `superset/` |
| **Extension** (optional) | Additional models and dashboards | `dbt/` + `superset/` only |

Extensions follow the **extend-only rule**: they may add new models and dashboards but must not modify core assets or change ingestion configuration. Extensions must not include a `connect/` directory.

### Directory structure

```
your-analytics-core/
  manifest.yaml                  # package metadata (required)
  connect/
    your-connector.json          # Debezium connector config (core only)
  dbt/
    dbt_project.yml              # dbt package config
    models/
      staging/                   # current-state views from raw CDC events
      marts/                     # analytics-ready tables (BI contract)
  superset/
    assets/                      # Superset YAML bundle (see above)
  README.md
```

See `examples/olmis-analytics-core/` for a complete reference implementation.

### manifest.yaml

Every package must include a `manifest.yaml`:

```yaml
name: your-analytics-core
type: core                   # core or extension
platform_version: ">=1.0.0"  # platform compatibility constraint
description: "Your package description"
includes:                    # which components the package provides
  - connect                  # core only
  - dbt
  - superset
```

### Connector config (core only)

The connector JSON template in `connect/` uses `envsubst` for variable substitution at registration time. Environment variables like `${SOURCE_PG_HOST}`, `${SOURCE_PG_PASSWORD}`, `${DEBEZIUM_TOPIC_PREFIX}` are replaced with values from `.env`.

See `examples/olmis-analytics-core/connect/openlmis-postgres-cdc.json` for the full template.

### dbt project config

The dbt package needs a `dbt_project.yml`:

```yaml
name: your_analytics_core
version: "1.0.0"
config-version: 2

model-paths: ["models"]
test-paths: ["tests"]
seed-paths: ["seeds"]
```

The platform runner (`dbt/`) loads this as a local package in development or fetches it from Git in production — the model paths are resolved automatically.

### Loading: local mode (development)

Set filesystem paths in `.env`:

```env
ANALYTICS_CORE_PATH=path/to/your-analytics-core
# Extensions (optional, comma-separated)
ANALYTICS_EXTENSIONS_PATHS=path/to/extension-a,path/to/extension-b
```

### Loading: Git mode (production)

Set Git URLs in `.env`:

```env
ANALYTICS_CORE_GIT_URL=https://github.com/org/your-analytics-core.git
ANALYTICS_CORE_GIT_REF=v1.0.0
# Extensions (optional, comma-separated)
ANALYTICS_EXTENSION_GIT_URLS=https://github.com/org/extension-a.git
ANALYTICS_EXTENSION_GIT_REFS=v1.0.0
# GIT_TOKEN=ghp_xxxx  # for private repos
```

Then fetch non-dbt components (connector config, Superset assets):

```bash
make package-fetch   # clones to .packages/, sets paths for downstream scripts
```

dbt fetches its own packages directly from Git during `make dbt-build` — no manual fetch needed for dbt models.

### Validate extensions

Run validation before deploying to catch extend-only rule violations:

```bash
make package-validate
```

This checks that extensions don't include `connect/`, don't collide on dbt model names, and don't reuse core Superset UUIDs.

### Test the package

```bash
make package-validate     # validate extension rules (if extensions configured)
make register-connector   # register CDC connector from core package
make clickhouse-init      # create raw landing tables
make dbt-build            # build dbt models
make superset-import      # import Superset assets
make verify-dbt           # verify curated marts have data
make verify-superset      # verify dashboards imported
```

Or run the full pipeline in one command:

```bash
make verify-packages      # validate + build + import + check dashboards
```

### Create an extension package

Extension packages add country-specific or domain-specific reports on top of a core package. See `examples/olmis-analytics-malawi/` for a complete working example.

Key rules:
- **No `connect/` directory** — ingestion is owned by the core package
- **No `databases/` in Superset assets** — the database connection is imported by core
- **No model name collisions** — your dbt model names must be unique (prefix with your country/domain)
- **No UUID collisions** — Superset asset UUIDs must be unique across core and all extensions

A typical extension contains:
1. **A dbt mart** that reads from core marts (via `{{ ref('mart_...') }}`) and adds an aggregation or filter
2. **Superset assets** with a dataset on the new mart, a chart, and a dashboard
3. **Tests** in `schema.yml` — same requirements as core (not_null, accepted_values, etc.)

To test your extension locally:

```env
ANALYTICS_CORE_PATH=examples/olmis-analytics-core
ANALYTICS_EXTENSIONS_PATHS=path/to/your-extension
```

Then `make verify-packages` runs validation, dbt build, Superset import, and checks that your dashboard appears.
