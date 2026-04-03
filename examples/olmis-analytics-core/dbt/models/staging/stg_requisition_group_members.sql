{{
  config(
    materialized='view'
  )
}}

-- Current-state reconstruction for referencedata.requisition_group_members.
-- Composite PK: (requisitiongroupid, facilityid) — no single id column.

with ranked as (
  select
    *,
    row_number() over (
      partition by
        JSONExtractString(after, 'requisitiongroupid'),
        JSONExtractString(after, 'facilityid')
      order by ts_ms desc, _ingested_at desc
    ) as _rn
  from raw.events_openlmis_referencedata_requisition_group_members
  where op != 'd'
    and JSONExtractString(after, 'requisitiongroupid') != ''
    and JSONExtractString(after, 'facilityid') != ''
)

select
  toUUIDOrNull(JSONExtractString(after, 'requisitiongroupid'))  as requisition_group_id,
  toUUIDOrNull(JSONExtractString(after, 'facilityid'))          as facility_id
from ranked
where _rn = 1
