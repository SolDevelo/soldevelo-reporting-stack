# olmis-analytics-malawi

Reference **analytics-extension** package for OpenLMIS Malawi. This is a permanent example that ships with the reporting-stack platform repository.

Extensions are additive only — they add new dbt marts and Superset dashboards but must not modify core models/dashboards or change ingestion contracts.

## Directory structure

```
olmis-analytics-malawi/
  manifest.yaml                                       # Package metadata (type: extension)
  dbt/
    dbt_project.yml                                   # dbt package config
    models/
      marts/
        mart_malawi_requisition_by_region.sql         # Regional requisition summary
        schema.yml                                    # Tests for Malawi marts
  superset/
    assets/
      metadata.yaml                                   # Bundle metadata
      datasets/reporting_clickhouse/
        mart_malawi_requisition_by_region.yaml        # Dataset on the Malawi mart
      charts/malawi_requisitions_by_region.yaml       # Bar chart: requisitions by region
      dashboards/malawi_regional_overview.yaml        # Malawi dashboard
```

Note: extension packages do **not** include `connect/` or `databases/` — ingestion configuration and database connections are owned by the core package.

## dbt model

`mart_malawi_requisition_by_region` aggregates the core package's `mart_requisition_summary` and `mart_facility_directory` by geographic region:

| Column | Description |
|---|---|
| `region` | Geographic region (parent zone, or zone if no parent) |
| `program_name` | Program name |
| `status` | Requisition workflow status |
| `requisition_count` | Number of requisitions |
| `emergency_count` | Number of emergency requisitions |

This demonstrates the extension pattern: reading from core marts without modifying them, adding a new aggregated view.

## Superset dashboard

The **Malawi Regional Overview** dashboard contains a bar chart showing requisition counts per region, broken down by status.

## Usage

Set extension path in the platform's `.env`:

```env
ANALYTICS_CORE_PATH=examples/olmis-analytics-core
ANALYTICS_EXTENSIONS_PATHS=examples/olmis-analytics-malawi
```

Then run `make verify-packages` to validate, build, import, and verify.

## Customizing for your country

To create an extension for a different country:

1. Copy this directory as a starting point
2. Replace the dbt mart with your country-specific aggregation
3. Update tests in `schema.yml`
4. Create Superset assets: author in the UI, export, commit to `superset/assets/`
5. Run `make package-validate` to ensure no collisions with core

For detailed guidance, see [docs/usage-guide.md](../../docs/usage-guide.md).
