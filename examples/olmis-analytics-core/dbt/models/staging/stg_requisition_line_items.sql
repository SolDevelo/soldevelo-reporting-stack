{{
  config(
    materialized='view'
  )
}}

-- Current-state reconstruction for requisition.requisition_line_items.

with ranked as (
  select
    *,
    row_number() over (
      partition by JSONExtractString(after, 'id')
      order by ts_ms desc, _ingested_at desc
    ) as _rn
  from raw.events_openlmis_requisition_requisition_line_items
  where op != 'd'
    and JSONExtractString(after, 'id') != ''
)

select
  toUUID(JSONExtractString(after, 'id'))                  as id,
  toUUIDOrNull(JSONExtractString(after, 'requisitionid')) as requisition_id,
  toUUIDOrNull(JSONExtractString(after, 'orderableid'))   as orderable_id,
  JSONExtractInt(after, 'orderableversionnumber')         as orderable_version_number,
  JSONExtractInt(after, 'beginningbalance')               as beginning_balance,
  JSONExtractInt(after, 'totalreceivedquantity')          as total_received_quantity,
  JSONExtractInt(after, 'totalconsumedquantity')          as total_consumed_quantity,
  JSONExtractInt(after, 'totallossesandadjustments')      as total_losses_and_adjustments,
  JSONExtractInt(after, 'stockonhand')                    as stock_on_hand,
  JSONExtractInt(after, 'totalstockoutdays')              as total_stockout_days,
  JSONExtractInt(after, 'averageconsumption')             as average_consumption,
  JSONExtractInt(after, 'adjustedconsumption')            as adjusted_consumption,
  JSONExtractFloat(after, 'maxperiodsofstock')            as max_periods_of_stock,
  JSONExtractInt(after, 'calculatedorderquantity')        as calculated_order_quantity,
  JSONExtractInt(after, 'requestedquantity')              as requested_quantity,
  JSONExtractInt(after, 'approvedquantity')               as approved_quantity,
  JSONExtractInt(after, 'packstoship')                    as packs_to_ship,
  JSONExtractFloat(after, 'priceperpack')                 as price_per_pack,
  JSONExtractFloat(after, 'totalcost')                    as total_cost,
  JSONExtractBool(after, 'skipped')                       as skipped,
  JSONExtractBool(after, 'nonfullsupply')                 as non_full_supply
from ranked
where _rn = 1
