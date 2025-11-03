
{% macro bigquery__handle_existing_table(full_refresh, old_relation) %}
    {%- if full_refresh -%}
      {{ adapter.drop_relation(old_relation) }}
    {%- else -%}
      {{ exceptions.relation_wrong_type(old_relation, 'view') }}
    {%- endif -%}
{% endmacro %}


{% materialization view, adapter='bigquery' -%}
    -- grab current tables grants config for comparision later on
    {% set grant_config = config.get('grants') %}

    {# Enable dry_run support #}
    {%- set dry_run = var("dry_run", false) -%}
    {% do adapter.set_query_callback_context(model.unique_id, dry_run=dry_run) %}

    {% set to_return = bigquery__create_or_replace_view() %}

    {# Clear callback context #}
    {% do adapter.clear_query_callback_context() %}

    {% set target_relation = this.incorporate(type='view') %}

    {% do persist_docs(target_relation, model) %}

    {% if config.get('grant_access_to') %}
      {% for grant_target_dict in config.get('grant_access_to') %}
        {% do adapter.grant_access_to(this, 'view', None, grant_target_dict) %}
      {% endfor %}
    {% endif %}

    {% do return(to_return) %}

{%- endmaterialization %}
