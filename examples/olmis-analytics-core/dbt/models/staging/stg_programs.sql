{{
  config(
    materialized='view'
  )
}}

-- Current-state reconstruction for referencedata.programs.

with ranked as (
  select
    *,
    row_number() over (
      partition by JSONExtractString(after, 'id')
      order by ts_ms desc, _ingested_at desc
    ) as _rn
  from raw.events_openlmis_referencedata_programs
  where op != 'd'
    and JSONExtractString(after, 'id') != ''
)

select
  toUUID(JSONExtractString(after, 'id'))    as id,
  JSONExtractString(after, 'code')          as code,
  JSONExtractString(after, 'name')          as name,
  JSONExtractBool(after, 'active')          as active,
  JSONExtractBool(after, 'periodsskippable')  as periods_skippable,
  JSONExtractBool(after, 'shownonfullsupplytab') as show_non_full_supply_tab
from ranked
where _rn = 1
