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
        coalesce(
        nullIf(JSONExtractString(after,  'requisitiongroupid'), ''),
        nullIf(JSONExtractString(before, 'requisitiongroupid'), '')
      ),
        coalesce(
        nullIf(JSONExtractString(after,  'facilityid'), ''),
        nullIf(JSONExtractString(before, 'facilityid'), '')
      )
      order by ts_ms desc, _ingested_at desc
    ) as _rn
  from raw.events_openlmis_referencedata_requisition_group_members
  where coalesce(
        nullIf(JSONExtractString(after,  'requisitiongroupid'), ''),
        nullIf(JSONExtractString(before, 'requisitiongroupid'), '')
      ) != ''
    and coalesce(
        nullIf(JSONExtractString(after,  'facilityid'), ''),
        nullIf(JSONExtractString(before, 'facilityid'), '')
      ) != ''
)

select
  toUUIDOrNull(JSONExtractString(after, 'requisitiongroupid'))  as requisition_group_id,
  toUUIDOrNull(JSONExtractString(after, 'facilityid'))          as facility_id
from ranked
where _rn = 1
  and op != 'd'
