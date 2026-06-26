{{
  config(
    materialized='incremental',
    incremental_strategy='delete_insert',
    unique_key='adjustment_id',
    engine='MergeTree()',
    order_by='(reason_name, status_change_date, requisition_id)',
    settings={'allow_nullable_key': 1}
  )
}}

-- One row per stock_adjustment. Replaces the legacy `adjustments`
-- materialized view. Joins each adjustment to its line item, requisition,
-- facility/program/period dimensions, the AUTHORIZED+ status_change
-- (used as the "adjustment timestamp" by the legacy charts), and the
-- adjustment reason.
--
-- Differences from legacy:
--   - Legacy used DISTINCT ON (requisition_line_item_id) which silently
--     dropped all but one adjustment per line item — counts in legacy
--     "Top Adjustment Reasons" / "Most Adjusted Reason" charts were
--     therefore lower than reality. We keep every adjustment.
--   - Legacy joined stock_adjustment_reasons via sar.id = al.reasonid;
--     our test data shows that resolution only matches ~6/14 rows in
--     mw-distro because modern OpenLMIS uses sar.reasonid (global FK)
--     as the join key. We join via reason_id (FK).
-- Rolling 3-year window on requisition.created_date (matches legacy).
--
-- Incremental design: same shape as mart_stock_status. unique_key=
-- adjustment_id, watermark on stg_stock_adjustments._cdc_ts. Dimension
-- drift and 3-year-window drift require periodic --full-refresh.

with status_changes_filtered as (
  select
    requisition_id    as requisition_id,
    status            as status,
    created_date      as created_date
  from {{ ref('stg_status_changes') }}
  where status not in ('SKIPPED', 'INITIATED', 'SUBMITTED')
),

submitted_or_later as (
  -- Latest non-skipped/initiated/submitted status_change per requisition
  -- = legacy "status_history_created_date" (when the requisition was
  -- authorized/approved/released).
  select
    requisition_id                   as requisition_id,
    argMax(status, created_date)     as latest_status,
    max(created_date)                as status_change_date
  from status_changes_filtered
  group by requisition_id
)

select
  sa.id                              as adjustment_id,
  sa.quantity                        as adjustment_quantity,

  -- requisition + line item
  li.id                              as line_item_id,
  li.requisition_id                  as requisition_id,
  r.created_date                     as requisition_created_date,

  -- facility
  f.id                               as facility_id,
  f.code                             as facility_code,
  f.name                             as facility_name,
  f.active                           as facility_active,
  ft.name                            as facility_type_name,

  -- geography
  gz.name                            as zone_name,
  parent_gz.name                     as parent_zone_name,

  -- program
  p.name                             as program_name,
  p.code                             as program_code,

  -- period
  pp.name                            as period_name,
  pp.start_date                      as period_start_date,
  pp.end_date                        as period_end_date,

  -- product
  o.id                               as orderable_id,
  o.code                             as product_code,
  o.full_product_name                as product_name,

  -- status change (legacy time anchor)
  sl.latest_status                   as status_change_status,
  sl.status_change_date              as status_change_date,

  -- reason
  sa.reason_id                       as reason_id,
  sar.name                           as reason_name,
  sar.reason_type                    as reason_type,
  sar.reason_category                as reason_category,

  -- signed quantity: CREDIT adds, DEBIT subtracts
  case when sar.reason_type = 'CREDIT' then sa.quantity
       when sar.reason_type = 'DEBIT'  then -sa.quantity
       else sa.quantity
  end                                as signed_quantity,

  -- CDC watermark: timestamp of the latest stock_adjustment event that
  -- produced this row.
  sa._cdc_ts                         as _cdc_ts

from {{ ref('stg_stock_adjustments') }} sa
inner join {{ ref('stg_requisition_line_items') }} li
  on sa.requisition_line_item_id = li.id
inner join {{ ref('stg_requisitions') }} r
  on li.requisition_id = r.id
left join {{ ref('stg_facilities') }} f
  on r.facility_id = f.id
left join {{ ref('stg_facility_types') }} ft
  on f.type_id = ft.id
left join {{ ref('stg_geographic_zones') }} gz
  on f.geographic_zone_id = gz.id
left join {{ ref('stg_geographic_zones') }} parent_gz
  on gz.parent_id = parent_gz.id
left join {{ ref('stg_programs') }} p
  on r.program_id = p.id
left join {{ ref('stg_processing_periods') }} pp
  on r.processing_period_id = pp.id
left join {{ ref('stg_orderables') }} o
  on li.orderable_id = o.id
left join submitted_or_later sl
  on sl.requisition_id = r.id
left join {{ ref('stg_stock_adjustment_reasons') }} sar
  on sar.reason_id = sa.reason_id
where r.created_date >= now() - interval 3 year
{% if is_incremental() %}
  and sa._cdc_ts > (select coalesce(max(_cdc_ts), toDateTime64(0, 3)) from {{ this }})
{% endif %}
