{{
  config(
    materialized='view'
  )
}}

-- Current-state reconstruction for requisition.status_changes.

with ranked as (
  select
    *,
    row_number() over (
      partition by JSONExtractString(after, 'id')
      order by ts_ms desc, _ingested_at desc
    ) as _rn
  from raw.events_openlmis_requisition_status_changes
  where op != 'd'
    and JSONExtractString(after, 'id') != ''
)

select
  toUUID(JSONExtractString(after, 'id'))                         as id,
  toUUIDOrNull(JSONExtractString(after, 'requisitionid'))        as requisition_id,
  JSONExtractString(after, 'status')                             as status,
  toUUIDOrNull(JSONExtractString(after, 'authorid'))             as author_id,
  parseDateTimeBestEffortOrNull(JSONExtractString(after, 'createddate'))   as created_date,
  toUUIDOrNull(JSONExtractString(after, 'supervisorynodeid'))    as supervisory_node_id
from ranked
where _rn = 1
