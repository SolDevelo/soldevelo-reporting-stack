{{
  config(
    materialized='table',
    engine='MergeTree()',
    order_by='(product_code, period_end_date, facility_name)',
    settings={'allow_nullable_key': 1}
  )
}}

-- Logistics summary: rows of mart_stock_status filtered to the top 5
-- products by total consumption in the latest reporting month. Replicates
-- the legacy "Logistics Summary Report" chart's subquery filter
-- (Superset blocks subqueries in adhoc_filters, so we materialize the
-- selection as its own mart). Refreshed on every dbt build.

with latest_month as (
  -- Anchor the "current month" to the most recent month present in the
  -- mart so this mart isn't blank when querying static / lagged data.
  -- Real production deployments will have current-month rows so this
  -- resolves to today's month naturally.
  select toStartOfMonth(max(period_end_date)) as month_start
  from {{ ref('mart_stock_status') }}
),

top_products as (
  select product_name
  from {{ ref('mart_stock_status') }}
  cross join latest_month
  where period_end_date >= latest_month.month_start
    and total_consumed_quantity is not null
  group by product_name
  order by sum(total_consumed_quantity) desc
  limit 5
)

select s.*
from {{ ref('mart_stock_status') }} s
inner join top_products tp on s.product_name = tp.product_name
