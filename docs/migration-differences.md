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
- No new dbt model needed for the five charts on `mart_stock_status`. `mart_logistics_summary` was added because Superset 6 blocks subqueries in adhoc_filters.
- Legacy `time_range` defaults preserved on three charts (Consumption Trend → Last 6 months, Consumption per District → Last 12 months, Most Consumed Products → Last month). All three are `today()`-relative — they resolve correctly against live data and approximately correctly against the time-shifted mw-distro test data (Dec 2024 → Dec 2025).

## Phase 5: Adjustments

### CDC pipeline changes

Two new tables added to the source PostgreSQL publication and the Debezium allowlist:
- `requisition.stock_adjustments`
- `requisition.stock_adjustment_reasons`

Required a clean reset (`make reset && make up && make setup`) because the existing connector offset prevented Debezium from re-snapshotting the new tables. With the offsets cleared, all 17 raw landing tables populate (previous 13 plus the two new ones plus a regenerated heartbeat / etc).

### New dbt models

- `stg_stock_adjustments` — current-state view, one row per adjustment (id, line_item_id, reason_id, quantity)
- `stg_stock_adjustment_reasons` — current-state view, **deduplicated by global `reason_id`** because the source table holds one row per (requisition × allowed reason) and we only need one canonical (name, type) per reason
- `mart_adjustments` — one row per adjustment, joined to facility/program/period/product dimensions, latest non-INITIATED/SUBMITTED/SKIPPED status_change, and the reason

### Core dashboard — `OLMIS Adjustments` (slug: `olmis-adjustments`)

| Legacy chart | Migrated chart | Status | Notes |
|---|---|---|---|
| Adjustments Filter (filter_box) | Native horizontal filter bar (Program · Region · District · Period · Facility · Reason) | 📝 Modernization | Same as Phases 1–4 |
| Adjustment Summary (table) | `adjustment_summary.yaml` | ✅ Equivalent | groupby facility/period/reason, COUNT + SUM(quantity). Filter `time_range: Last month` matches legacy |
| % of Adjustments By Reason (dist_bar) | `adjustments_by_reason.yaml` (pie) | 📝 Modernization | Legacy used 11 hardcoded `SUM(CASE WHEN reason = '<name>' THEN 1 ELSE 0 END)` metrics — one per known reason. Migrated chart groupby `reason_name` with a single COUNT metric. New reasons added in OpenLMIS will appear automatically; legacy chart would silently miss them. Switched viz to pie because percentage-by-category is more naturally shown that way; users can switch to bar in Superset if preferred |
| Top Adjustment Reasons (table) | `top_adjustment_reasons.yaml` | ✅ Equivalent | groupby reason_name + reason_type, COUNT + SUM(quantity), sort desc |
| Top Districts With Adjustments (table) | `top_districts_with_adjustments.yaml` | ✅ Equivalent | groupby zone_name + parent_zone_name, COUNT + SUM(quantity) |
| Most Adjusted Reason (table) | `most_adjusted_reason.yaml` | ✅ Equivalent | groupby reason_name + program_name, SUM(quantity) |
| Mathematical Error Trends (line) | `mathematical_error_trends.yaml` | ✅ Equivalent | x=status_change_date, groupby reason_name, filter `lower(reason_name) IN ('positive mathematical error', 'negative mathematical error')`. time_range "Last 11 months" matches legacy |

### Two metric corrections (🔧 bug fix from legacy)

1. **Legacy `adjustments` MV used `DISTINCT ON (li.requisition_line_item_id)`**, which silently dropped all but one adjustment per line item. So legacy "Top Adjustment Reasons" / "Most Adjusted Reason" undercounted: a line item with 3 adjustments showed up as 1. The migration keeps every adjustment row.
2. **Legacy joined `stock_adjustment_reasons sar ON sar.id = al.reasonid`**. Modern OpenLMIS uses `sar.reasonid` (the global FK) as the join key, not `sar.id`. Verified against mw-distro: the legacy join only matches 6 of 14 adjustment rows, leaving 8 with NULL reason names. We join via `reason_id` (FK), matching all 14.

Both corrections produce more accurate counts. Numbers will differ from legacy charts in any deployment where line items have multiple adjustments or where the schema changed since the MV was authored.

### Test-data caveat

`status_changes` for the time-shifted requisitions (the rows we backdated from 2017–2018 into 2024–2026 to fill the rolling 3-year window) had to be shifted independently — the original status_changes timestamps were still 2017–2018, which made every Phase 5 chart with `time_range: "Last month"` return zero rows in mw-distro. The runtime fix (in mw-distro DB only, not committed): `UPDATE requisition.status_changes SET createddate = createddate + INTERVAL '14 months' FROM requisition.requisitions WHERE …` to push them into March–October 2026. The shift does not affect any earlier mart's data because no other Phase used `status_changes.created_date` as a chart time anchor.

## Phase 6: Orders

### Core dashboard — `OLMIS Orders` (slug: `olmis-orders`)

| Legacy chart | Migrated chart | Status | Notes |
|---|---|---|---|
| Orders Filter (filter_box) | Native horizontal filter bar (Program · Region · District · Period · Facility · Emergency) | 📝 Modernization | Same as Phases 1–5 |
| Reporting Rate (pie, shared) | (not duplicated; users navigate to OLMIS Reporting Rate dashboard) | 📝 Modernization | Legacy duplicated the pie on every dashboard. Migration consolidates the Reporting Rate chart on its own dedicated dashboard (Phase 3) instead of repeating it. Cross-dashboard navigation is one click via the Superset dashboard menu |
| Non Reporting Facilities (table, shared) | reused `non_reporting_facilities.yaml` | ✅ Equivalent | Same chart, references existing `mart_non_reporting_facilities` |
| Emergency v. Regular Orders (pie) | `emergency_vs_regular_orders.yaml` | ✅ Equivalent | groupby `emergency`, `COUNT_DISTINCT(requisition_id)`, filter `total_received_quantity > 0`. time_range "Last 10 years" matches legacy. Renamed from "v." to "vs" for grammar |
| Total Cost of Orders (table) | `total_cost_of_orders.yaml` | ✅ Equivalent | Raw-mode table showing facility/product/period/total_cost rows. Sorted by total_cost desc. Server-paginated (legacy was unpaginated `page_length: null`); switched because mw-distro data has 175 rows that DOM-bombed in prior phases. Friendly column labels via `column_config.customColumnName` |
| Estimated Order Value (dist_bar) | `estimated_order_value.yaml` | 🔧 Bug fix | Legacy chart was hardcoded to `program_name = 'Essential Meds'` despite a generic chart name — same Malaria-only-style hardcoding we corrected in Phase 4. Migration drops the hardcoded program filter and exposes Program in the dashboard filter bar. Numbers match legacy when Program=Essential Meds is selected |
| Order Timeliness (pie) | `order_timeliness.yaml` | 🔧 Bug fix | Legacy chart was hardcoded to `program_name = 'Essential Meds'`. Migration drops the hardcoded filter, same rationale as Estimated Order Value. groupby is the new computed column `order_timeliness`. Legacy expression (Postgres) used `extract('day' from date_trunc('day', modified_date) - date_trunc('month', modified_date)) + 1` to bucket day-of-month; migrated mart computes it with ClickHouse-native `toDayOfMonth(requisition_modified_date)` directly. Output buckets ("Before 10th", "Between 10th - 20th", "After 20th") are identical |

### mart_stock_status extensions

Three new columns added to `mart_stock_status` (no new mart needed):
- `emergency` (UInt8) — from `requisitions.emergency`
- `requisition_modified_date` (DateTime, nullable) — from `requisitions.modified_date`
- `order_timeliness` (String) — computed from `toDayOfMonth(requisition_modified_date)` into the three legacy buckets

All exposed in the Superset dataset YAML so charts can group/filter on them.

### Two `program_name = 'Essential Meds'` hardcoded filters dropped

Mirrors the Phase 4 pattern: Estimated Order Value and Order Timeliness charts in legacy were hardcoded to one specific program despite generic chart names. Migration drops those filters and exposes Program in the filter bar — users replicate the legacy view by selecting Program=Essential Meds.

### Test-data caveats

- **Estimated Order Value** uses `time_range: "Last quarter"`. mw-distro test data ends Dec 2025; today is May 2026; "Last quarter" resolves to Jan–Mar 2026. Chart will be empty in mw-distro. Works on live data.
- **Order Timeliness** uses `time_range: "Last month"`. Required time-shifting `requisitions.modifieddate` forward into early 2026 so the filter catches anything (same DB-only fix pattern we applied for status_changes in Phase 5). After the shift, ~18 rows fall in April 2026 with `order_timeliness = 'After 20th'` (single pie slice). Live deployments would have varied date-of-month values and a more balanced 3-slice pie.

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
