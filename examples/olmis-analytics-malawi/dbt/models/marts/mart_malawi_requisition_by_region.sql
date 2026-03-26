{{
  config(
    materialized='table',
    engine='MergeTree()',
    order_by='(region, program_name, status)'
  )
}}

-- Malawi regional requisition summary: aggregates core requisition data
-- by geographic region. Demonstrates an extension mart that reads from
-- the core package's mart without modifying it.

with requisitions as (
  select * from {{ ref('mart_requisition_summary') }}
),

facilities as (
  select * from {{ ref('mart_facility_directory') }}
)

select
  coalesce(f.parent_zone_name, f.geographic_zone_name) as region,
  r.program_name,
  r.status,
  count()                as requisition_count,
  countIf(r.emergency)   as emergency_count
from requisitions r
left join facilities f
  on r.facility_code = f.facility_code
group by
  region,
  r.program_name,
  r.status
