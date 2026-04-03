{{
  config(
    materialized='table',
    engine='MergeTree()',
    order_by='(requisition_id, line_item_id)',
    settings={'allow_nullable_key': 1}
  )
}}

-- Stock status per requisition line item: the primary mart for stockout
-- and stock level dashboards. Joins line items with all dimension tables
-- to produce a single denormalized table for BI queries.
--
-- Logic matches the legacy stock_status_and_consumption materialized view:
--   combined_stockout: 1 if SOH=0 OR stockout_days>0 OR beginning_balance=0 OR MoS=0
--   stock_status: Overstocked (MoS>6), Stocked Out (MoS<3 AND stockout signal),
--                 Understocked (MoS<3 AND no stockout signal), Unknown (MoS=0 AND no signal),
--                 Adequately stocked (else)
-- Rolling 3-year window on requisition created_date.
-- No requisition status filter (matches old view which included all statuses).

select
  -- line item identifiers
  li.id                         as line_item_id,
  li.requisition_id,

  -- facility
  f.id                          as facility_id,
  f.code                        as facility_code,
  f.name                        as facility_name,
  f.active                      as facility_active,
  f.enabled                     as facility_enabled,
  ft.name                       as facility_type_name,

  -- geography (zone → parent = district → region in most deployments)
  gz.name                       as zone_name,
  parent_gz.name                as parent_zone_name,

  -- program
  p.name                        as program_name,
  p.code                        as program_code,

  -- period
  pp.name                       as period_name,
  pp.start_date                 as period_start_date,
  pp.end_date                   as period_end_date,
  ps.name                       as schedule_name,

  -- product
  o.id                          as orderable_id,
  o.code                        as product_code,
  o.full_product_name           as product_name,

  -- stock quantities
  li.beginning_balance,
  li.total_received_quantity,
  li.total_consumed_quantity,
  li.total_losses_and_adjustments,
  li.stock_on_hand,
  li.total_stockout_days,
  li.average_consumption,
  li.adjusted_consumption,
  li.max_periods_of_stock,
  li.calculated_order_quantity,
  li.requested_quantity,
  li.approved_quantity,
  li.packs_to_ship,
  li.price_per_pack,
  li.total_cost,

  -- computed: months of stock
  case
    when li.average_consumption > 0
    then round(li.stock_on_hand / li.average_consumption, 1)
    else 0
  end                           as months_of_stock,

  -- computed: stockout flag (matches legacy combined_stockout logic)
  case
    when li.stock_on_hand = 0
      or li.total_stockout_days > 0
      or li.beginning_balance = 0
      or li.max_periods_of_stock = 0
    then 1
    else 0
  end                           as combined_stockout,

  -- computed: stock status category (matches legacy evaluation order)
  case
    when li.max_periods_of_stock > 6
      then 'Overstocked'
    when li.max_periods_of_stock < 3
      and (li.stock_on_hand = 0 or li.total_stockout_days > 0
           or li.beginning_balance = 0 or li.max_periods_of_stock = 0)
      then 'Stocked Out'
    when li.max_periods_of_stock < 3
      and li.max_periods_of_stock > 0
      and not (li.stock_on_hand = 0 or li.total_stockout_days > 0
               or li.beginning_balance = 0 or li.max_periods_of_stock = 0)
      then 'Understocked'
    when li.max_periods_of_stock = 0
      and not (li.stock_on_hand = 0 or li.total_stockout_days > 0
               or li.beginning_balance = 0)
      then 'Unknown'
    else 'Adequately stocked'
  end                           as stock_status

from {{ ref('stg_requisition_line_items') }} li
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
left join {{ ref('stg_processing_schedules') }} ps
  on pp.processing_schedule_id = ps.id
left join {{ ref('stg_orderables') }} o
  on li.orderable_id = o.id
where r.created_date >= now() - interval 3 year
