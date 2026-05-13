# olmis-analytics-malawi

Reference **analytics-extension** package for OpenLMIS Malawi. This ships with the reporting-stack platform repository as a permanent example of what a country-specific extension looks like in practice.

Extensions are additive only — they add new dbt marts and Superset dashboards but must not modify core models/dashboards or change ingestion contracts.

## Directory structure

```
olmis-analytics-malawi/
  manifest.yaml                          # Package metadata (type: extension)

  dbt/
    dbt_project.yml
    seeds/
      malawi_program_products.csv        # Static reference list: programs × products
                                         # marked as essential in Malawi
    models/
      marts/
        mart_malawi_requisition_by_region.sql
        mart_malawi_stock_status.sql
        schema.yml

  superset/
    assets/
      metadata.yaml
      databases/reporting_clickhouse.yaml
      datasets/reporting_clickhouse/
        mart_malawi_requisition_by_region.yaml
        mart_malawi_stock_status.yaml
      charts/                            # 10 charts covering stockouts, stock levels,
                                         # requisitions by region, programmatic snapshots
        malawi_district_stockout_treemap.yaml
        malawi_product_stockout_12mo.yaml
        malawi_program_inventory_snapshot.yaml
        malawi_program_stockout_trend.yaml
        malawi_programmatic_stockout_pivot.yaml
        malawi_requisitions_by_region.yaml
        malawi_stock_levels_by_program.yaml
        malawi_stockout_by_district.yaml
        malawi_stockout_by_product.yaml
        malawi_stockout_by_program.yaml
      dashboards/
        malawi_stockouts.yaml            # Stockout focus across products/districts/programs
        malawi_stock_levels.yaml         # Stock-on-hand by program
        malawi_regional_overview.yaml    # Requisition counts by region/status
        malawi_summary.yaml              # Master Malawi dashboard: treemap + pivot
                                         # + 12-month trends
```

Note: extension packages do **not** include `connect/` or top-level `databases/` — ingestion configuration is owned by the core package. The `superset/assets/databases/reporting_clickhouse.yaml` here only re-declares the database for asset-import purposes; it must match the core package's UUID.

## dbt models

### Seed: `malawi_program_products`

Static CSV listing the program × product pairs that are considered essential for Malawi reporting. Used by `mart_malawi_stock_status` to filter down to the country's vital-medicines basket. To customise for a different country, replace the rows in this CSV.

### Mart: `mart_malawi_requisition_by_region`

Aggregates the core `mart_requisition_summary` by geographic region and program × status. One row per (region, program, status) tuple with counts of total and emergency requisitions. This is the data behind the "Requisitions by Region" charts.

### Mart: `mart_malawi_stock_status`

Computes stock status (STOCKOUT, LOW, ADEQUATE, OVERSTOCK) per (facility, program, product, period) using the essential-products seed for filtering. Backs every stockout/stock-level dashboard in the extension.

## Superset dashboards

| Dashboard | What it shows |
|---|---|
| Malawi Stockouts | Stockout rate by product / district / program; 12-month trend; programmatic pivot |
| Malawi Stock Levels | Stock-on-hand distribution by program × facility |
| Malawi Regional Overview | Requisition activity heatmap by region and status |
| Malawi Summary | Master dashboard combining the treemap, programmatic pivot, and 12-month stockout trend in one view |

These dashboards demonstrate three extension patterns: aggregating core marts (regional overview), introducing country-specific reference data via a seed (stock status), and composing multiple chart types into a master view (summary). When migrating dashboards from a country's legacy stack, see `docs/migration-differences.md` for the conventions used.

## Usage

Set the extension path in the platform's `.env`:

```env
ANALYTICS_CORE_PATH=examples/olmis-analytics-core
ANALYTICS_EXTENSIONS_PATHS=examples/olmis-analytics-malawi
```

Then run `make verify-packages` to validate, build, import, and verify.

## Customising for your country

To create an extension for a different country:

1. Copy this directory as a starting point — rename `manifest.yaml.name`, the dbt project name, and the asset UUIDs (UUIDs must be unique across packages).
2. Replace `seeds/malawi_program_products.csv` with your country's reference data, or remove the seed entirely if you don't need country-specific filtering.
3. Adjust the dbt marts to your country's reporting needs. Read from core marts (`{{ ref('mart_requisition_summary') }}`, etc.) rather than directly from the raw layer.
4. Replace the Superset charts and dashboards: author in the UI against your country's data, export with the import script, commit the YAML.
5. Run `make package-validate` to ensure no UUID collisions with core.

For detailed guidance, see [docs/usage-guide.md](../../docs/usage-guide.md).
