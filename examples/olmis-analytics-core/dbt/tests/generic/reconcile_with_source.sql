{#
  reconcile_with_source — cross-system reconciliation test.

  Compares a curated mart against its source PostgreSQL state on two
  dimensions:

    - row count
    - sum of cityHash64(primary_key) across all rows

  The row-count check catches missing/extra rows. The PK-hash check
  additionally catches "right count, wrong rows" scenarios — a row that
  was deleted in source but re-introduced from a stale snapshot in the
  mart, or vice versa.

  The test reads the live source state via ClickHouse's postgresql()
  table function (no precomputed baseline needed). For this to work,
  the ClickHouse container must be on the same Docker network as the
  source DB (compose: clickhouse joins reporting-shared).

  Returns failure rows when source and target diverge. dbt treats any
  returned row as a test failure.

  Args:
    source_table     "<schema>.<table>" in PG. Used both for documentation
                     and, in the simple form, to drive the postgresql()
                     table-function call. Example: "referencedata.facilities".
    source_pk        Column in the source table used for the PK hash.
                     Ignored when source_query is supplied. Example: "id".
    target_pk        Column in the target mart used for the PK hash.
                     Example: "facility_id".
    source_filter    Optional PG SQL WHERE-clause snippet for source rows
                     (e.g., "deleted IS FALSE"). Ignored when source_query
                     is supplied. Default: "1 = 1" (no filter).
    target_filter    Optional ClickHouse WHERE-clause snippet for target rows.
                     Default: "1 = 1" (no filter).
    source_query     Optional. Full SELECT producing two columns —
                     `row_count` and `pk_hash` — that captures the source
                     side. Use this when the mart joins/filters across
                     multiple PG tables (e.g., a 3-year rolling window on
                     `requisitions.created_date` for line-item marts) and
                     a single-table source_filter cannot express the shape.
                     Compose with the source_pg() macro.
    tolerance_rows   Optional. Absolute row-count delta to tolerate without
                     failing. Default: 0 (strict). When > 0, the pk_hash
                     check is also skipped — any drift in rows produces a
                     mismatched hash, so the two checks are coupled.
                     Use for time-windowed marts where mart-build vs
                     test-run clock drift and incremental-refresh aging
                     produce a small, slowly-growing delta that does not
                     reflect a real data quality issue.

  Example — simple form (no joins, no window):

    - name: mart_facility_directory
      data_tests:
        - reconcile_with_source:
            arguments:
              source_table: referencedata.facilities
              source_pk: id
              target_pk: facility_id
            config:
              tags: [reconcile]

  Example — multi-table source query with tolerance for a 3-year window:

    - name: mart_stock_status
      data_tests:
        - reconcile_with_source:
            arguments:
              source_table: requisition.requisition_line_items
              source_pk: id
              target_pk: line_item_id
              tolerance_rows: 10000
              source_query: |
                select
                  count() as row_count,
                  sum(cityHash64(li.id)) as pk_hash
                from {{ source_pg('requisition', 'requisition_line_items') }} li
                inner join {{ source_pg('requisition', 'requisitions') }} r
                  on li.requisitionid = r.id
                where r.createddate >= now() - interval 3 year
            config:
              tags: [reconcile]
#}

{% test reconcile_with_source(model, source_table, source_pk=none, target_pk=none,
                              source_filter='1 = 1', target_filter='1 = 1',
                              source_query=none, tolerance_rows=0) %}

{%- if source_query is none -%}
  {%- if source_pk is none -%}
    {{ exceptions.raise_compiler_error("source_pk is required when source_query is not supplied") }}
  {%- endif -%}
  {%- set parts = source_table.split('.') -%}
  {%- if parts | length != 2 -%}
    {{ exceptions.raise_compiler_error("source_table must be schema.table, got: " ~ source_table) }}
  {%- endif -%}
  {%- set source_schema = parts[0] -%}
  {%- set source_relname = parts[1] -%}
{%- endif -%}

with source_state as (
{%- if source_query is not none %}
  {{ source_query }}
{%- else %}
  select
    count() as row_count,
    sum(cityHash64({{ source_pk }})) as pk_hash
  from {{ source_pg(source_schema, source_relname) }}
  where {{ source_filter }}
{%- endif %}
),
target_state as (
  select
    count() as row_count,
    sum(cityHash64({{ target_pk }})) as pk_hash
  from {{ model }}
  where {{ target_filter }}
),
diff as (
  select
    'row_count' as metric,
    toString(s.row_count) as source_value,
    toString(t.row_count) as target_value,
    toInt64(t.row_count) - toInt64(s.row_count) as delta
  from source_state s cross join target_state t
  where abs(toInt64(t.row_count) - toInt64(s.row_count)) > {{ tolerance_rows }}

{%- if tolerance_rows == 0 %}

  union all

  select
    'pk_hash' as metric,
    toString(s.pk_hash) as source_value,
    toString(t.pk_hash) as target_value,
    cast(0 as Int64) as delta
  from source_state s cross join target_state t
  where s.pk_hash != t.pk_hash
{%- endif %}
)
select * from diff

{% endtest %}
