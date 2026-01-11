{% materialization table_default, adapter='bigquery', supported_languages=['sql']-%}

  {%- set language = model['language'] -%}

  {# Only support SQL models #}
  {%- if language != 'sql' -%}
    {{ exceptions.raise_compiler_error("table_default materialization only supports SQL models.") }}
  {%- endif -%}

  {# Relation setup #}
  {%- set identifier = model['alias'] -%}
  {%- set old_relation = adapter.get_relation(database=database, schema=schema, identifier=identifier) -%}
  {%- set exists_not_as_table = (old_relation is not none and not old_relation.is_table) -%}
  {%- set target_relation = api.Relation.create(database=database, schema=schema, identifier=identifier, type='table') -%}

  {# Configuration - no partition_by, only cluster_by #}
  {%- set grant_config = config.get('grants') -%}
  {%- set cluster_by = config.get('cluster_by', none) -%}
  {%- set dry_run = var("dry_run", false) -%}

  {# Pre-execution #}
  {{ run_hooks(pre_hooks) }}

  {# Drop if exists but not as table (e.g., was a view) #}
  {%- if exists_not_as_table -%}
    {{ adapter.drop_relation(old_relation) }}
  {%- endif -%}

  {# Check replaceability (cluster config changes) #}
  {% if old_relation is not none and not adapter.is_replaceable(old_relation, none, cluster_by) %}
    {% do log("Hard refreshing " ~ old_relation ~ " because cluster config changed", info=True) %}
    {% do adapter.drop_relation(old_relation) %}
    {%- set old_relation = none -%}
  {% endif %}

  {# WRITE_TRUNCATE semantics: always drop and recreate #}
  {%- if old_relation is not none -%}
    {{ log("Dropping existing table " ~ old_relation ~ " for full refresh", info=True) }}
    {% do adapter.drop_relation(old_relation) %}
  {%- endif -%}

  {# Set callback context for web UI status display #}
  {%- set unique_id = model.unique_id -%}
  {% do adapter.set_query_callback_context(unique_id, none, none, dry_run) %}

  {# Create new table #}
  {{ log("Creating table " ~ target_relation, info=True) }}
  {%- call statement('main', language=language) -%}
    {{ create_table_as(False, target_relation, compiled_code, language) }}
  {%- endcall -%}

  {# Clear callback context #}
  {% do adapter.clear_query_callback_context() %}

  {# Post-execution #}
  {{ run_hooks(post_hooks) }}

  {# Apply grants #}
  {% set should_revoke = should_revoke(old_relation, full_refresh_mode=True) %}
  {% do apply_grants(target_relation, grant_config, should_revoke) %}

  {# Persist documentation #}
  {% do persist_docs(target_relation, model) %}

  {{ return({'relations': [target_relation]}) }}

{% endmaterialization %}
