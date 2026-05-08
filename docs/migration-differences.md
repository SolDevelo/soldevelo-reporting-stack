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

### Core dashboard — `OLMIS Stock Status` (slug: `olmis-stock-status`)

| Legacy chart | Migrated chart | Status | Notes |
|---|---|---|---|
| Stock Filter (filter_box, file `Stock_Filter_218.yaml`) | Native horizontal filter bar (Program · Region · District · Period · Facility · Product) | 📝 Modernization | Same as Phase 1 — `filter_box` is deprecated in Superset 6 |
| Stockout Rate Over Time (line, `Stockout_Rate_Over_Time_15.yaml`) | `stockout_rate_over_time.yaml` | 🔧 Bug fix | Legacy metric: `COUNT(CASE WHEN stock_on_hand = 0 THEN facility_id END) / COUNT(facility_id)` — only counts SOH=0 cases. Migrated metric: `AVG(combined_stockout)` — uses the broader `combined_stockout` flag (SOH=0 OR stockout_days>0 OR begin_bal=0 OR MoS=0) which matches the source MV's documented stockout definition. **Numbers will differ from legacy** when there are line items with stockout_days>0 or begin_bal=0 but SOH>0. Legacy chart was internally inconsistent: the same MV defines `combined_stockout` broadly but this chart uses the narrow SOH=0 alternative |
| Months of Stock (line, `Months_of_Stock_17.yaml`) | `months_of_stock_over_time.yaml` | 🔧 Bug fix | Legacy aggregation: `SUM(max_periods_of_stock)` grouped by `district_name`. Summing a "max periods of stock" per line item across all line items in a district produces an unintelligible total — almost certainly a legacy bug (intended AVG, used SUM). Migrated uses `AVG(months_of_stock)` where `months_of_stock = round(stock_on_hand / average_consumption, 1)` — the standard months-of-stock formula. **Numbers will differ from legacy** but reflect what the chart name implies |
| Stock Status over Time (stacked bar, `Stock_Status_over_Time_16.yaml`) | `stock_status_distribution.yaml` | ✅ Equivalent | Migrated chart preserves: `bar_stacked: true` (now `stack: stack`), groupby `stock_status`, metric `COUNT_DISTINCT(facility_id)`, filter `stock_status IS NOT NULL`. Renamed for grammar ("over Time" → "Distribution Over Time"). viz_type updated from legacy `bar` to `echarts_timeseries_bar` (Superset 6 native time-series renderer) |
| Non Reporting Facilities (table, shared with Stockouts) | reused `non_reporting_facilities.yaml` | ✅ Equivalent | Same chart referenced from Stockouts dashboard — the shared chart pattern reduces duplication |

### Extension dashboard — `Malawi Stock Levels` (slug: `malawi-stock-levels`)

| Legacy charts | Migrated chart | Status | Notes |
|---|---|---|---|
| HIV Stock Levels, TB Stock Levels, Malaria Stock Levels, Essential Meds Stock Levels, Nutrition Stock Levels, RH Stock Levels (six dist_bar charts, each filtered by `program_name = '<one program>'`) | `malawi_stock_levels_by_program.yaml` (single stacked bar with Health Program filter) | 📝 Modernization | Six near-identical legacy charts with hardcoded `program_name` filters consolidated into one chart filterable by Health Program (uses `malawi_program` column from the seed). Same metric (`COUNT_DISTINCT(facility_id)` per `stock_status`) and same time grain. **Important data note:** legacy filtered by `program_name` (the OpenLMIS program string, e.g. "HIV", "Malaria"); migrated filters by `malawi_program` (our seed's classification, e.g. "HIV/AIDS", "National Malaria Control Program"). The product subsets per program will differ — see the Malawi seed coverage notes in Phase 1. To restore exact-legacy filtering, switch the dashboard's default filter to `program_name = '<value>'` — both columns are exposed |
| Stockout Trend - Malaria Program, Stockout Trends - Malaria Program, Stockout Trends - HIV Program, Stockout Trends - RH Program × 2 (4–5 line charts, hardcoded product code filters) | (already covered by Phase 1 `malawi_stockout_by_program.yaml` + `malawi_stockout_by_district.yaml`) | 📝 Modernization | These charts overlap with the Stockouts dashboard's "District Stockout Rates over Time" charts, just with slightly different metric (`SUM(CASE WHEN stock_on_hand = 0 ...)` vs `AVG(combined_stockout)`) and an extra `amc IS NOT NULL` filter. Phase 1 consolidation covers the same intent. The legacy duplicate-name chart (`Stockout Trend - Malaria Program` singular vs plural) and the two RH copies (`_10.yaml`, `_11.yaml`) suggest these were dashboard-specific clones rather than meaningfully distinct — treating them as one logical chart is the right call |

#### Implementation notes

- Both Phase 2 dashboards reuse the existing `mart_stock_status` and `mart_malawi_stock_status` marts — no new dbt models required.
- Three new columns exposed on `mart_stock_status` Superset dataset: `facility_id` (for `COUNT_DISTINCT`), `period_start_date`, `max_periods_of_stock`. `facility_id` also exposed on `mart_malawi_stock_status`.
- All legacy `row_limit: 10000` settings preserved.
- All four new charts verified to return data against mw-distro after the Phase 1 test-data redistribution: 9 distinct months × multiple districts × 4 stock-status categories.

#### Known caveats specific to mw-distro test data

- Legacy charts had `time_range: "Last year"` defaults. New charts don't set a default time range, so they show all data in the mart (3-year window). Easy adjustment if needed.
- `Stock Status Distribution Over Time` shows mostly "Stocked Out" status because the synthetic test data we redistributed in Phase 1 (`UPDATE referencedata.processing_periods` to spread requisitions across 2025) preserves the stock-empty state of the legacy 2017 line items. Real Malawi data will show a more balanced distribution.

## Phase 3: Reporting Rate and Timeliness

### Core dashboard — `OLMIS Reporting Rate` (slug: `olmis-reporting-rate`)

| Legacy chart | Migrated chart | Status | Notes |
|---|---|---|---|
| Reporting Rate Indicator Filter (filter_box) | Native horizontal filter bar (Program · Region · District · Period · Facility) | 📝 Modernization | Same as Phase 1/2 — filter_box widget replaced |
| Reporting Rate (pie) | `reporting_rate_pie.yaml` | ✅ Equivalent | groupby `reporting_status`, COUNT of facility_id. Legacy used `COUNT(reporting_timeliness)` on the same column; semantically the same outcome |
| Reporting Rate Trend (line) | `reporting_rate_trend.yaml` | ✅ Equivalent | groupby `program_name`, x-axis `period_end_date`, metric `AVG(reported)`. Legacy used the named metric `Reporting rate` defined as `sum(case when reporting_timeliness='Did not report' then 0.0 else 1.0 end) / count(*)` — same expression rewritten with our `reporting_status` column. Numbers will match for any deployment that has both 'Reported' and 'Did not report' rows |
| Reporting Timeliness By Week (dist_bar) | `reporting_timeliness_by_week.yaml` | 🔧 Bug fix + 📝 reshape | **Metric semantics — bug fix:** legacy used 5 named metrics (`week1`–`week5`) each computed by an opaque `extract('day' from date_trunc('week', modified_date) - date_trunc('week', date_trunc('month', modified_date))) / 7 + 1 = N` expression to bucket the requisition's `modified_date` into "week 1 of month" through "week 5". Migrated mart computes a `submitted_week_of_month` column directly (1–5) using `toDayOfMonth(submitted_date)` floor-div 7 + 1. Two metric differences: (a) we use `submitted_date` (the SUBMITTED status_change timestamp) rather than `modified_date` (the last edit timestamp) — `submitted_date` is the actual submission moment, not subsequent edits; (b) our buckets are calendar week-of-month (days 1–7 → week 1, 8–14 → week 2, …, day 29+ → week 5), close to legacy intent but explicit. **Chart shape — reshape:** legacy chart was `dist_bar` with `groupby: district` and 5 separate metrics, producing 5 grouped bars per district per period. Migrated chart is a stacked time-series bar with `groupby: submitted_week_of_month` and one COUNT metric, producing 5 stacked segments per period (no per-district axis). Same underlying data; users can filter to a specific district via the District filter to recover the legacy per-district breakdown |
| Non Reporting Facilities (table) | reused `non_reporting_facilities.yaml` from Phase 1 | ✅ Equivalent | Same chart, references existing `mart_non_reporting_facilities` |
| Expected Number Facilities to Report (table) | `expected_facilities.yaml` | ✅ Equivalent | groupby `zone_name`, `period_name`, `program_name`; metric `COUNT_DISTINCT(facility_id)`. Legacy was `COUNT_DISTINCT(facility_id)` over the `reporting_rate_and_timeliness` MV grouped by district + period — same shape. Added `program_name` to the groupby for finer breakdown; collapse via filter to match legacy single-column view |

### New mart introduced

`mart_reporting_status` is a superset of `mart_non_reporting_facilities`. Both marts coexist:
- `mart_non_reporting_facilities` is filtered to `reporting_status = 'Did not report'` rows only — used by the existing Non Reporting Facilities chart on Stockouts and Reporting Rate dashboards
- `mart_reporting_status` includes both 'Reported' and 'Did not report' rows plus `submitted_date` and `submitted_week_of_month` columns — used by the new Phase 3 charts that need the broader view

The reporting-status logic in both marts is byte-equivalent to the legacy `reporting_rate_and_timeliness` MV's CASE expression for `reporting_timeliness`, verified against `OlmisCreateTableStatements.sql`.

### Implementation-level changes (no user-visible data impact)

- `submitted_date`: derived from the earliest `SUBMITTED` `requisition_status_changes` row per (facility, program, period). Legacy used `requisitions.modified_date` for week bucketing — see the bug-fix note above.
- The 3-year window is on `processing_period.end_date` rather than legacy's `requisitions.created_date` — needed because we want every expected period included (even if no requisition was created), not just periods that had a requisition. Both windows resolve to roughly the same set of recent periods.
- `enableEmptyFilter: false` on every filter (optional filters), `searchAllOptions: false` (Superset UI default), `NATIVE_FILTER-` underscore IDs, `defaultDataMask.filterState: {value: null}` — same as Phase 1/2 dashboards. These are the runtime conditions Superset needs for native filters to work in 6.1.0rc3.

## Phase 4: Consumption

### Core dashboard — `OLMIS Consumption` (slug: `olmis-consumption`)

| Legacy chart | Migrated chart | Status | Notes |
|---|---|---|---|
| Stock Filter (filter_box) | Native horizontal filter bar (Program · Region · District · Period · Facility · Product) | 📝 Modernization | Same as Phase 1–3 |
| Consumption Trend (line) | `consumption_trend.yaml` | ✅ Equivalent | `SUM(adjusted_consumption)` over time, no groupby. Legacy used the named metric `Adjusted Consumption` defined as `SUM(adjusted_consumption)`. Same expression |
| Total Adjusted Consumption per District (line) | `consumption_per_district.yaml` (renamed "Consumption per District") | 🔧 Bug fix | Legacy chart had hardcoded `program_name = 'Malaria'` filter despite a generic chart name. Migrated chart drops the hardcoded filter and exposes Program in the dashboard filter bar — users select Malaria themselves to match legacy view. **Numbers match legacy when filtered to Program=Malaria.** Metric expression preserved: `CASE WHEN SUM(adjusted_consumption) != 0 THEN SUM(consumption)/SUM(adjusted_consumption) ELSE 0 END` (rewritten with our `total_consumed_quantity` column name) |
| Consumption in Current Year (line) | `consumption_current_year.yaml` (renamed "Consumption — Current 12 Months") | 🔧 Bug fix | Legacy was named "Current Year" but actually filtered to *last 12 months* from `current_date`, with hardcoded `program_name = 'Malaria'`. Migrated chart drops the Malaria filter (same rationale as above) and uses an explicit time filter `period_end_date >= toStartOfMonth(today()) - INTERVAL 12 MONTH`. Renamed for clarity ("Current 12 Months" instead of misleading "Current Year") |
| Consumption in Last Year (line) | `consumption_last_year.yaml` (renamed "Consumption — Previous 12 Months") | 🔧 Bug fix | Same pair as above — months 13–24 ago, hardcoded Malaria filter dropped, renamed for clarity |
| Most Consumed Product (table) | `most_consumed_products.yaml` | ✅ Equivalent | groupby `product_name`, `product_code`; metric `SUM(adjusted_consumption)`. Legacy was groupby `full_product_name`, `product_code`. Same data. Renamed plural for grammar |
| Logistics Summary Report (table) | `logistics_summary.yaml` (backed by new `mart_logistics_summary` mart) | 📝 Modernization | Wide table with facility × product × period × stock columns, filtered to the top 5 most-consumed products in the latest reporting month. Legacy implemented this with a subquery in the chart's `adhoc_filter`; Superset 6 blocks subqueries in ad-hoc SQL ("Custom SQL fields cannot contain sub-queries"), so the top-5 selection is materialized as a small dedicated dbt model `mart_logistics_summary` that filters `mart_stock_status` to the top-5 products by total consumption in the latest month present in the data. Refreshed on every dbt build. **Anchored to the latest period in the data** rather than `today()` so the chart isn't blank when querying static or lagged datasets — for live deployments with current-month rows, the two anchors resolve to the same set |

### Hardcoded `program_name = 'Malaria'` filter — design decision

Three legacy charts (Total Adjusted Consumption per District, Consumption in Current Year, Consumption in Last Year) had `program_name = 'Malaria'` as an `adhoc_filter`, despite having generic chart names. This appears to be Malawi-specific configuration that the original dashboard authors hardcoded into the chart rather than parameterized via filters.

The migration plan explicitly classified Phase 4 as "core, no Malawi-specific" content, and the chart names imply program-agnostic visualizations. The migrated charts therefore drop the hardcoded filter; users replicate the legacy view by setting Program=Malaria in the dashboard filter bar. This is documented as a 🔧 bug fix in the table above. **Numerical impact:** when no Program filter is selected, migrated charts show consumption across all programs (more data than legacy); when Program=Malaria is selected, numbers match legacy exactly.

### Implementation-level changes (no user-visible data impact)

- Added `total_consumed_quantity` and `adjusted_consumption` columns to the `mart_stock_status` Superset dataset YAML, plus two new metrics (`consumption` = `SUM(total_consumed_quantity)`, `adjusted_consumption_total` = `SUM(adjusted_consumption)`) so charts can reference them by name. The mart itself already had these as raw columns from the staging layer.
- All filter / dashboard config conventions match Phase 1–3: `NATIVE_FILTER-` underscore IDs, `searchAllOptions: false`, `defaultDataMask.filterState: {value: null}`, `filter_bar_orientation: HORIZONTAL`.
- No new dbt model needed — Phase 4 is the cheapest phase per the migration plan, exactly as predicted.

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
