{{
  config(
    materialized='table',
    engine='MergeTree()',
    order_by='(program_name, facility_name, status)'
  )
}}

-- Requisition summary: requisitions enriched with facility and program names.
-- Groups by status for reporting dashboards.

select
  r.id              as requisition_id,
  r.status          as status,
  r.emergency       as emergency,
  r.created_date    as created_date,
  r.modified_date   as modified_date,
  f.code            as facility_code,
  f.name            as facility_name,
  gz.name           as geographic_zone_name,
  p.code            as program_code,
  p.name            as program_name
from {{ ref('stg_requisitions') }} r
left join {{ ref('stg_facilities') }} f
  on r.facility_id = f.id
left join {{ ref('stg_geographic_zones') }} gz
  on f.geographic_zone_id = gz.id
left join {{ ref('stg_programs') }} p
  on r.program_id = p.id
