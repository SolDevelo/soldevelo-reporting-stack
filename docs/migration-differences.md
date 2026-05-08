# Dashboard Migration Differences

This document tracks every known deviation between the legacy mw-distro
dashboards and the migrated reporting-stack dashboards. It is the
authoritative record of "what changed and why" for the migration.

## Reference

The legacy dashboards used as the comparison baseline live in:

```
mw-distro/reporting/config/services/superset/dashboards/openlmis_uat_dashboards.zip
```

- Exported **2024-11-28T09:41:05 UTC**
- 86 files, **9 dashboards**: Adjustments, Administrative, Consumption,
  Master, Orders, Reporting Rate and Timeliness, Reports, Stockouts,
  Stock Status
- This is the production Malawi state — what users actually saw before
  migration

The ref-distro repo contains a smaller, older export (2024-10-07, 30 files)
that is missing Master and Reports dashboards. It is **not** the
authoritative reference; mw-distro's export is.

## Status legend

| Symbol | Meaning |
|---|---|
| ✅ Equivalent | Same metric, same data, possibly modernized rendering (e.g. table → paginated table, filter_box → native filter bar) |
| 🔧 Bug fix | Legacy was incorrect; new chart fixes it. Values will differ from legacy |
| 🆕 Addition | New chart with no legacy counterpart |
| 📝 Modernization | Same data, different shape (e.g. 5 per-program charts → 1 chart with program filter) |
| ⚠️ Gap | Legacy chart that has not yet been migrated |

---

## Phase 1: Stockouts

### Core dashboard — `OLMIS Stockouts` (slug: `olmis-stockouts`)

| Legacy chart | Migrated chart | Status | Notes |
|---|---|---|---|
| Stock Filter (filter_box) | Native horizontal filter bar (Program · Region · District · Period · Facility · Product · Stock Status) | 📝 Modernization | filter_box widget was deprecated in Superset 1.x; replaced with native_filter_configuration which is the only supported pattern in 6.x |
| Most Stocked Out Facilities (table) | `most_stocked_out_facilities.yaml` (table) | 🔧 Bug fix | Legacy used the metric `No. Of Stocked Out Products` defined as `SUM(CASE WHEN combined_stockout = 0 THEN 1 END)`. Since `combined_stockout = 1` means "is stocked out" in the source MV, the legacy metric counted **non-stockout** items despite its name, ranking facilities by *most well-stocked* under a label of "Most Stocked Out". Migrated chart uses `SUM(combined_stockout)` (counts actual stockouts), matching what the chart name implies. **Numbers will differ from legacy.** Same fix applied to Most Stocked Out Products and Most Stocked Out Districts |
| Most Stocked Out Products (table) | `most_stocked_out_products.yaml` (table) | 🔧 Bug fix | See above |
| Most Stocked Out District (table) | `most_stocked_out_districts.yaml` (table) | 🔧 Bug fix | Renamed plural for grammatical consistency. Same metric fix |
| Non Reporting Facilities (table) | `non_reporting_facilities.yaml` (table) | ✅ Equivalent | Migrated mart `mart_non_reporting_facilities` reproduces the legacy `reporting_rate_and_timeliness` filter (active facilities × required programs minus actual reporters per period). `row_limit=10000`, `page_length=0` matches legacy "show all, no pagination" |
| District Stockout Rates over Time × 5 (Malaria, Maternal/RH, HIV, TB, Essential Medicines) | (moved to Malawi extension) | 📝 Modernization | These were Malawi-specific (hardcoded product subsets per program). Per the platform/extension contract, anything Malawi-specific belongs in `olmis-analytics-malawi`, not the core. Replaced by a 3-chart consolidated view in the Malawi extension dashboard — see below |
| — | `stock_status_overview.yaml` (pie) | 🆕 Addition | Distribution of line items by `stock_status` category (Stocked Out / Understocked / Adequately stocked / Overstocked / Unknown). Not present in legacy Stockouts dashboard. Adds a top-level summary that the legacy lacked |

#### Implementation-level changes (no user-visible data impact)

- `cross_filters_enabled: true` — enabled Superset 6's cross-filter linking
  (clicking a slice filters other charts). Not available in legacy 1.x.
- `row_limit: 10000` and `page_length: 10` on the three Most Stocked Out
  tables — matches legacy.
- `mart_stock_status` dbt model replaces the legacy
  `stock_status_and_consumption` materialized view. The `combined_stockout`
  and `stock_status` CASE expressions are byte-for-byte equivalent (verified
  against `OlmisCreateTableStatements.sql`). The 3-year `created_date`
  filter is preserved.

### Extension dashboard — `Malawi Stockout Trends` (slug: `malawi-stockouts`)

| Legacy chart | Migrated chart | Status | Notes |
|---|---|---|---|
| District Stockout Rates over Time - Malaria (line, 4 hardcoded products: AA039600, AA040500, DN002900, DN101000) | `malawi_stockout_by_program.yaml` filtered to "National Malaria Control Program" + `malawi_stockout_by_product.yaml` | 📝 Modernization with caveat | Legacy chart was a per-product line series with **hardcoded** 4-product subsets. New "by Program" chart shows program-level stockout, "by Product" chart shows all products. The Malawi seed (`malawi_program_products.csv`) maps 10 products to Malaria, not 4. **Differs from legacy:** new chart will show stockout for 10 Malaria products vs legacy 4. Pros: includes products legacy chart skipped. Con: not byte-identical. Mitigated by Health Program filter to slice further |
| District Stockout Rates over Time - Maternal and RH (4 hardcoded products: FP004500, GF0096, BB049500, BB059400) | Same as above (Reproductive Health filter) | 📝 Modernization with caveat | Seed has 14 Reproductive Health products vs legacy 4. Same caveat as Malaria |
| District Stockout Rates over Time - HIV (2 hardcoded: ST010900, GF0221) | Same as above (HIV/AIDS filter) | 📝 Modernization with caveat | Seed has 7 HIV products vs legacy 2 |
| District Stockout Rates over Time - TB (3 hardcoded: TB001300, TB042600, TB004400) | Same as above (TB filter) | 📝 Modernization with caveat | Seed has 9 TB products vs legacy 3. **Note:** legacy referenced `TB042600`; seed has `TB042500`. Possibly a legacy typo or the source DB had different codes — needs Malawi data team confirmation |
| District Stockout Rates over Time - Essential Medicines (≥6 hardcoded products: EE002700, EE033900, EE048300, ST009700, FD100000, FD251000, ...) | Closest analog: `malawi_stockout_by_product.yaml` filtered by Health Program | 📝 Modernization with caveat | "Essential Medicines" wasn't a single seed category — the products are spread across IMCI, HSSP Tracer Items, and Tablets/Capsules in the seed. No single filter selects exactly the legacy product set |
| — | `malawi_stockout_by_program.yaml` (line) | 🆕 Addition | Cross-program stockout view (one line per Malawi program). Not in legacy. Replaces the per-program chart pattern with a single comparison chart |
| — | `malawi_stockout_by_district.yaml` (line) | 🆕 Addition | Per-district stockout view (one line per district). Not in legacy. Combined with the Health Program filter, lets users see per-district trends within any program — covering the "District" intent that the legacy chart names implied but didn't actually show (legacy charts grouped by `full_product_name`, not district) |

#### Filter and dashboard-config notes

- 7 native filters (Health Program · Program · Region · District · Period
  · Facility · Product). Legacy Stockouts had a single filter_box with a
  comparable set of fields.
- `filter_bar_orientation: HORIZONTAL` — filters appear at the top of the
  dashboard. Default in Superset 6 is vertical/sidebar; setting horizontal
  matches the legacy filter_box visual layout.
- `cross_filters_enabled: true` — same rationale as core.

### Data-model differences (impact on values)

| Aspect | Legacy | Migrated | Impact |
|---|---|---|---|
| `combined_stockout` formula | `SOH=0 OR stockout_days>0 OR begin_bal=0 OR MoS=0` | identical | None |
| `stock_status` formula | 5 categories with same priority order | identical | None |
| `malawi_program` mapping | hardcoded CASE in MV (10 categories, ~126 products with first-match-wins) | seed CSV (10 categories, 113 unique products with single mapping per code) | The CSV uses the same first-match priority, so each product maps to one program identically. Total product count differs because MV had duplicate products in lower-priority categories that we deduplicated; total **unique** product count differs by a small margin (legacy had some products listed redundantly; deduped count is comparable) |
| 3-year `created_date` filter | Yes | Yes | None — same filter window |
| Aggregation level | per requisition_line_item | per requisition_line_item | None — same grain |

---

## Phase 2: Stock Status

⚠️ Pending. Will be filled in as that phase is migrated.

## Phase 3: Reporting Rate and Timeliness

⚠️ Pending.

## Phase 4: Consumption

⚠️ Pending.

## Phase 5: Adjustments

⚠️ Pending.

## Phase 6: Orders

⚠️ Pending.

## Phase 7: Administrative + Master

⚠️ Pending.

## Master and Reports dashboards

The legacy Master dashboard and Reports dashboard are composites that
duplicate charts from the program-specific dashboards. The migration plan
classifies Reports as "do not migrate as a separate dashboard" (its unique
charts are absorbed elsewhere). Master will be migrated as a curated
executive summary in Phase 7. Specific deviations will be documented when
that phase begins.

---

## Verification methodology

For every chart marked anything other than ✅ Equivalent, the diff is
backed by direct comparison against the corresponding YAML in the legacy
ZIP. The procedure used (and to be repeated for Phase 2+):

1. Match each migrated chart to its legacy counterpart by `slice_name` in
   the relevant `dashboards/<name>.yaml` of the legacy export.
2. For each pair, diff: `viz_type`, `metrics`/`metric` definitions
   (resolving named metrics via the dataset YAML), `groupby`, `adhoc_filters`
   (especially hardcoded WHERE clauses on product_code or other fields),
   `row_limit`, `page_length`, `granularity_sqla`.
3. Resolve any metric name to its full SQL expression by reading the
   matching dataset YAML in `legacy-export/datasets/main/`.
4. Cross-check the SQL semantics against the source MV in
   `mw-distro/reporting/db/docker-entrypoint-initdb.d/templates/OlmisCreateTableStatements.sql`.
5. Document each deviation in this file before merging.
