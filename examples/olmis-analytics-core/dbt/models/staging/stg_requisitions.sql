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

-- Current-state reconstruction for requisition.requisitions.
--
-- Incremental: on each run, we identify the set of requisition ids that
-- have at least one CDC event newer than the watermark (max(_cdc_ts_ms)
-- already in this table). For those ids only, we re-rank across the full
-- raw event history and emit the latest non-deleted state. The
-- delete_insert strategy then replaces existing rows for those ids.
--
-- Source-delete limitation: hard-deletes in source leave the latest CDC
-- event as op='d', which is filtered out below. The stale row stays in
-- staging. Reconcile via `dbt run --full-refresh` when source deletes
-- are suspected. In OpenLMIS this is extremely rare for requisitions.

with touched_ids as (
  select distinct coalesce(
    nullIf(JSONExtractString(after,  'id'), ''),
    nullIf(JSONExtractString(before, 'id'), '')
  ) as id_str
  from raw.events_openlmis_requisition_requisitions
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
  from raw.events_openlmis_requisition_requisitions e
  inner join touched_ids t
    on coalesce(
         nullIf(JSONExtractString(e.after,  'id'), ''),
         nullIf(JSONExtractString(e.before, 'id'), '')
       ) = t.id_str
)

select
  toUUID(JSONExtractString(after, 'id'))                  as id,
  JSONExtractString(after, 'status')                      as status,
  JSONExtractBool(after, 'emergency')                     as emergency,
  toUUIDOrNull(JSONExtractString(after, 'facilityid'))    as facility_id,
  toUUIDOrNull(JSONExtractString(after, 'programid'))     as program_id,
  toUUIDOrNull(JSONExtractString(after, 'processingperiodid'))  as processing_period_id,
  toUUIDOrNull(JSONExtractString(after, 'supervisorynodeid'))   as supervisory_node_id,
  JSONExtractInt(after, 'numberofmonthsinperiod')         as number_of_months_in_period,
  parseDateTimeBestEffortOrNull(JSONExtractString(after, 'createddate'))   as created_date,
  parseDateTimeBestEffortOrNull(JSONExtractString(after, 'modifieddate'))  as modified_date,

  -- CDC watermark columns
  ts_ms                                                   as _cdc_ts_ms,
  toDateTime64(ts_ms / 1000, 3)                           as _cdc_ts,
  op                                                      as _cdc_op
from ranked
where _rn = 1
  and op != 'd'
