{{
  config(
    materialized='table',
    engine='MergeTree()',
    order_by='(malawi_program, period_end_date, product_code)'
  )
}}

-- Malawi stock status: extends the core mart_stock_status with
-- Malawi-specific health program classification per product.
-- Only includes products mapped to a Malawi program.

select
  s.line_item_id,
  s.requisition_id,
  s.facility_id,
  s.facility_code,
  s.facility_name,
  s.facility_active,
  s.facility_enabled,
  s.facility_type_name,
  s.zone_name,
  s.parent_zone_name,
  s.program_name,
  s.program_code,
  s.period_name,
  s.period_start_date,
  s.period_end_date,
  s.schedule_name,
  s.orderable_id,
  s.product_code,
  s.product_name,
  s.beginning_balance,
  s.total_received_quantity,
  s.total_consumed_quantity,
  s.total_losses_and_adjustments,
  s.stock_on_hand,
  s.total_stockout_days,
  s.average_consumption,
  s.adjusted_consumption,
  s.max_periods_of_stock,
  s.calculated_order_quantity,
  s.requested_quantity,
  s.approved_quantity,
  s.packs_to_ship,
  s.price_per_pack,
  s.total_cost,
  s.months_of_stock,
  s.combined_stockout,
  s.stock_status,
  mp.malawi_program
from {{ ref('mart_stock_status') }} s
inner join {{ ref('malawi_program_products') }} mp
  on s.product_code = mp.product_code
