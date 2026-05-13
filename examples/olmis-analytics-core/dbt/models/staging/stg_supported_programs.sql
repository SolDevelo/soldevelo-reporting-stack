{{
  config(
    materialized='view'
  )
}}

-- Current-state reconstruction for referencedata.supported_programs.
-- Composite PK: (facilityid, programid) — no single id column.

with ranked as (
  select
    *,
    row_number() over (
      partition by
        coalesce(
        nullIf(JSONExtractString(after,  'facilityid'), ''),
        nullIf(JSONExtractString(before, 'facilityid'), '')
      ),
        coalesce(
        nullIf(JSONExtractString(after,  'programid'), ''),
        nullIf(JSONExtractString(before, 'programid'), '')
      )
      order by ts_ms desc, _ingested_at desc
    ) as _rn
  from raw.events_openlmis_referencedata_supported_programs
  where coalesce(
        nullIf(JSONExtractString(after,  'facilityid'), ''),
        nullIf(JSONExtractString(before, 'facilityid'), '')
      ) != ''
    and coalesce(
        nullIf(JSONExtractString(after,  'programid'), ''),
        nullIf(JSONExtractString(before, 'programid'), '')
      ) != ''
)

select
  toUUIDOrNull(JSONExtractString(after, 'facilityid'))  as facility_id,
  toUUIDOrNull(JSONExtractString(after, 'programid'))   as program_id,
  JSONExtractBool(after, 'active')                      as active,
  JSONExtractBool(after, 'locallyfulfilled')             as locally_fulfilled
from ranked
where _rn = 1
  and op != 'd'
