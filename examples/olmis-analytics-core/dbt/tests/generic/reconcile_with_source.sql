{#
  reconcile_with_source — cross-system reconciliation test.

  Compares a curated mart against its source PostgreSQL table on two
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
    source_table   "<schema>.<table>" in PG. Example: "referencedata.facilities".
    source_pk      Column in the source table used for the hash. Example: "id".
    target_pk      Column in the target mart used for the hash. Example: "facility_id".
    source_filter  Optional PG SQL WHERE-clause snippet for source rows
                   (e.g., "deleted IS FALSE"). Default: "1 = 1" (no filter).
    target_filter  Optional ClickHouse WHERE-clause snippet for target rows.
                   Default: "1 = 1" (no filter). Use when the mart contains
                   columns the source doesn't (e.g., bootstrap markers) and
                   you want to exclude them.

  Example usage in schema.yml:

    - name: mart_facility_directory
      data_tests:
        - reconcile_with_source:
            arguments:
              source_table: referencedata.facilities
              source_pk: id
              target_pk: facility_id
            config:
              tags: [reconcile]

  When the mart contains rows the source doesn't (synthetic rows, computed
  unions), use target_filter to exclude them — e.g. for a "non reporting
  facilities" mart that synthesises one row per missing report:

    - name: mart_non_reporting_facilities
      data_tests:
        - reconcile_with_source:
            arguments:
              source_table: referencedata.facilities
              source_pk: id
              target_pk: facility_id
              target_filter: "reporting_status != 'synthetic'"
            config:
              tags: [reconcile]
#}

{% test reconcile_with_source(model, source_table, source_pk, target_pk,
                              source_filter='1 = 1', target_filter='1 = 1') %}

{%- set parts = source_table.split('.') -%}
{%- if parts | length != 2 -%}
  {{ exceptions.raise_compiler_error("source_table must be schema.table, got: " ~ source_table) }}
{%- endif -%}
{%- set source_schema = parts[0] -%}
{%- set source_relname = parts[1] -%}

with source_state as (
  select
    count() as row_count,
    sum(cityHash64({{ source_pk }})) as pk_hash
  from postgresql(
    concat('{{ env_var("SOURCE_PG_HOST") }}', ':', '{{ env_var("SOURCE_PG_PORT", "5432") }}'),
    '{{ env_var("SOURCE_PG_DB") }}',
    '{{ source_relname }}',
    '{{ env_var("SOURCE_PG_USER") }}',
    '{{ env_var("SOURCE_PG_PASSWORD") }}',
    '{{ source_schema }}'
  )
  where {{ source_filter }}
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
  where s.row_count != t.row_count

  union all

  select
    'pk_hash' as metric,
    toString(s.pk_hash) as source_value,
    toString(t.pk_hash) as target_value,
    cast(0 as Int64) as delta
  from source_state s cross join target_state t
  where s.pk_hash != t.pk_hash
)
select * from diff

{% endtest %}
