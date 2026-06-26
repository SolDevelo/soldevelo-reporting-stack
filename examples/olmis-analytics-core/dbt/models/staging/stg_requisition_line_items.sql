{{
  config(
    materialized='incremental',
    incremental_strategy='delete_insert',
    unique_key='id',
    engine='MergeTree()',
    order_by='id',
    settings={'allow_nullable_key': 1}
  )
}}

-- Current-state reconstruction for requisition.requisition_line_items.
-- Incremental: only re-ranks ids whose raw events arrived after the
-- materialized watermark. See stg_requisitions for the full pattern.

with touched_ids as (
  select distinct coalesce(
    nullIf(JSONExtractString(after,  'id'), ''),
    nullIf(JSONExtractString(before, 'id'), '')
  ) as id_str
  from raw.events_openlmis_requisition_requisition_line_items
  where coalesce(
        nullIf(JSONExtractString(after,  'id'), ''),
        nullIf(JSONExtractString(before, 'id'), '')
      ) != ''
  {% if is_incremental() %}
    and ts_ms > (select coalesce(max(_cdc_ts_ms), 0) from {{ this }})
  {% endif %}
),

ranked as (
  select
    e.*,
    row_number() over (
      partition by coalesce(
        nullIf(JSONExtractString(e.after,  'id'), ''),
        nullIf(JSONExtractString(e.before, 'id'), '')
      )
      order by e.ts_ms desc, e._ingested_at desc
    ) as _rn
  from raw.events_openlmis_requisition_requisition_line_items e
  inner join touched_ids t
    on coalesce(
         nullIf(JSONExtractString(e.after,  'id'), ''),
         nullIf(JSONExtractString(e.before, 'id'), '')
       ) = t.id_str
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
  JSONExtractBool(after, 'nonfullsupply')                 as non_full_supply,

  -- CDC watermark columns
  ts_ms                                                   as _cdc_ts_ms,
  toDateTime64(ts_ms / 1000, 3)                           as _cdc_ts,
  op                                                      as _cdc_op
from ranked
where _rn = 1
  and op != 'd'
