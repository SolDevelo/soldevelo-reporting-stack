{#
  source_pg — render a ClickHouse postgresql() table-function call that
  exposes a single PostgreSQL table from the configured source DB.

  Centralises the SOURCE_PG_* env_var lookups so generic tests and YAML
  test arguments can compose multi-table source queries (joins, filters)
  without repeating connection boilerplate.

  Args:
    schema  PG schema name (e.g., "requisition", "referencedata")
    table   PG table name (e.g., "requisition_line_items")

  Usage:
    select * from {{ source_pg('requisition', 'requisitions') }}
#}

{% macro source_pg(schema, table) -%}
postgresql(
  '{{ env_var("SOURCE_PG_HOST") }}:{{ env_var("SOURCE_PG_PORT", "5432") }}',
  '{{ env_var("SOURCE_PG_DB") }}',
  '{{ table }}',
  '{{ env_var("SOURCE_PG_USER") }}',
  '{{ env_var("SOURCE_PG_PASSWORD") }}',
  '{{ schema }}'
)
{%- endmacro %}
