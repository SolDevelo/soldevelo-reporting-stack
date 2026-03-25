{% macro generate_schema_name(custom_schema_name, node) -%}
  {#
    Override the default schema name generation.
    If a model specifies +schema, use it directly (not prefixed with target schema).
    Otherwise fall back to the target schema.
  #}
  {%- if custom_schema_name is not none -%}
    {{ custom_schema_name | trim }}
  {%- else -%}
    {{ target.schema | trim }}
  {%- endif -%}
{%- endmacro %}
