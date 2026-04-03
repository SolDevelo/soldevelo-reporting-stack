{{
  config(
    materialized='view'
  )
}}

-- Current-state reconstruction for referencedata.requisition_group_program_schedules.

with ranked as (
  select
    *,
    row_number() over (
      partition by JSONExtractString(after, 'id')
      order by ts_ms desc, _ingested_at desc
    ) as _rn
  from raw.events_openlmis_referencedata_requisition_group_program_schedules
  where op != 'd'
    and JSONExtractString(after, 'id') != ''
)

select
  toUUID(JSONExtractString(after, 'id'))                           as id,
  toUUIDOrNull(JSONExtractString(after, 'requisitiongroupid'))     as requisition_group_id,
  toUUIDOrNull(JSONExtractString(after, 'programid'))              as program_id,
  toUUIDOrNull(JSONExtractString(after, 'processingscheduleid'))   as processing_schedule_id,
  JSONExtractBool(after, 'directdelivery')                         as direct_delivery
from ranked
where _rn = 1
