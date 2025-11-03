{% materialization table_partitions, adapter='bigquery', supported_languages=['sql']-%}

  {%- set language = model['language'] -%}

  {# Only support SQL models #}
  {%- if language != 'sql' -%}
    {{ exceptions.raise_compiler_error("table_partitions materialization only supports SQL models. Use 'table' materialization for Python models.") }}
  {%- endif -%}

  {%- set identifier = model['alias'] -%}
  {%- set old_relation = adapter.get_relation(database=database, schema=schema, identifier=identifier) -%}
  {%- set exists_not_as_table = (old_relation is not none and not old_relation.is_table) -%}
  {%- set target_relation = api.Relation.create(database=database, schema=schema, identifier=identifier, type='table') -%}

  -- Configuration
  {%- set grant_config = config.get('grants') -%}
  {%- set selector_update_range = config.get('selector_update_range', default={}) -%}
  {%- set min_start_date = config.get('min_start_date', none) -%}
  {%- set default_start_date = config.get('default_start_date', none) -%}
  {%- set raw_partition_by = config.get('partition_by', none) -%}
  {%- set partition_by = adapter.parse_partition_by(raw_partition_by) -%}
  {%- set cluster_by = config.get('cluster_by', none) -%}

  {# Validate partition_by is set #}
  {%- if not partition_by -%}
    {{ exceptions.raise_compiler_error("table_partitions materialization requires 'partition_by' config to be set") }}
  {%- endif -%}

  {# Get partition field name #}
  {%- set partition_field = partition_by.field -%}

  {# ============================================ #}
  {# Date Resolution Logic                       #}
  {# ============================================ #}

  {# Resolve start_date with correct precedence (matching original implementation) #}
  {%- set start_date_var = var("start_date", none) -%}
  {%- set run_tags = var("run_tags", none) -%}

  {# Priority 1: default_start_date from config (overrides everything) #}
  {%- if default_start_date is not none %}
    {%- set start_date = modules.datetime.datetime.strptime(default_start_date, '%Y-%m-%d').date() -%}
    {{ log("Using default_start_date from config: " ~ start_date, info=True) }}

  {# Priority 2: @start_date dynamic resolution via selector #}
  {%- elif start_date_var == '@start_date' %}
    {%- set interval = selector_update_range.get(run_tags, 0) -%}
    {%- set start_date = adapter.relative_start(interval) -%}
    {{ log("Resolved @start_date with selector '" ~ run_tags ~ "' (interval: " ~ interval ~ ") to " ~ start_date, info=True) }}

  {# Priority 3: Explicit date string from runtime var #}
  {%- elif start_date_var -%}
    {%- set start_date = modules.datetime.datetime.strptime(start_date_var, '%Y-%m-%d').date() -%}
    {{ log("Using explicit start_date: " ~ start_date, info=True) }}

  {%- else -%}
    {%- set start_date = none -%}
  {%- endif -%}

  {# Apply min_start_date boundary AFTER resolution #}
  {%- if start_date is not none and min_start_date is not none -%}
    {%- set min_date_obj = modules.datetime.datetime.strptime(min_start_date, '%Y-%m-%d').date() -%}
    {%- if start_date < min_date_obj -%}
      {{ log("Adjusting start_date from " ~ start_date ~ " to min_start_date " ~ min_date_obj, info=True) }}
      {%- set start_date = min_date_obj -%}
    {%- endif -%}
  {%- endif -%}

  {# Resolve end_date from runtime var #}
  {%- set end_date_var = var("end_date", none) -%}

  {%- if end_date_var == '@end_date' %}
    {# Default to today #}
    {%- set end_date = modules.datetime.date.today() -%}
    {{ log("Resolved @end_date to today: " ~ end_date, info=True) }}
  {%- elif end_date_var -%}
    {# Explicit date string - parse it #}
    {%- set end_date = modules.datetime.datetime.strptime(end_date_var, '%Y-%m-%d').date() -%}
    {{ log("Using explicit end_date: " ~ end_date, info=True) }}
  {%- else -%}
    {%- set end_date = modules.datetime.date.today() -%}
  {%- endif -%}

  {# Get dry_run flag #}
  {%- set dry_run = var("dry_run", false) -%}

  {{ log("Date range: " ~ start_date ~ " to " ~ end_date ~ " (dry_run: " ~ dry_run ~ ")", info=True) }}

  {# ============================================ #}
  {# Pre-execution Setup                         #}
  {# ============================================ #}

  {{ run_hooks(pre_hooks) }}

  {# Drop if exists but not as table #}
  {%- if exists_not_as_table -%}
      {{ adapter.drop_relation(old_relation) }}
  {%- endif -%}

  {# Check if relation is replaceable based on partition/cluster config #}
  {% if not adapter.is_replaceable(old_relation, partition_by, cluster_by) %}
    {% do log("Hard refreshing " ~ old_relation ~ " because it is not replaceable", info=True) %}
    {% do adapter.drop_relation(old_relation) %}
    {%- set old_relation = none -%}
  {% endif %}

  {# ============================================ #}
  {# Main Query Execution                        #}
  {# ============================================ #}

  {# Set callback context for real-time status updates #}
  {%- set unique_id = model.unique_id -%}
  {% do adapter.set_query_callback_context(unique_id, start_date, end_date, dry_run) %}

  {# Prepare query parameters to inject into BigQuery query #}
  {%- if start_date and end_date -%}
    {%- set query_params = [
        {'name': 'start_date', 'type': 'DATE', 'value': start_date},
        {'name': 'end_date', 'type': 'DATE', 'value': end_date}
    ] -%}
    {% do adapter.set_query_parameters(query_params) %}
  {%- endif -%}

  {# Decide between CREATE TABLE AS vs DELETE + INSERT #}
  {%- if old_relation is none or not old_relation.is_table -%}

    {# Table doesn't exist: CREATE TABLE AS SELECT #}
    {{ log("Creating new table " ~ target_relation, info=True) }}
    {%- call statement('main', language=language) -%}
      {{ create_table_as(False, target_relation, compiled_code, language) }}
    {%- endcall -%}

  {%- else -%}

    {# Table exists: Use multi-statement DELETE + INSERT #}
    {{ log("Table exists, using DELETE + INSERT for partitions: " ~ start_date ~ " to " ~ end_date, info=True) }}

    {%- set multi_statement_sql -%}
-- Delete existing partitions in range
DELETE FROM `{{ target_relation.database }}.{{ target_relation.schema }}.{{ target_relation.identifier }}`
WHERE {{ partition_field }} BETWEEN @start_date AND @end_date;

-- Insert new data for the same range
INSERT INTO `{{ target_relation.database }}.{{ target_relation.schema }}.{{ target_relation.identifier }}`
{{ compiled_code }};
    {%- endset -%}

    {%- call statement('main', language=language) -%}
      {{ multi_statement_sql }}
    {%- endcall -%}

  {%- endif -%}

  {# Clear query parameters and callback context #}
  {% do adapter.clear_query_parameters() %}
  {% do adapter.clear_query_callback_context() %}

  {# ============================================ #}
  {# Post-execution                              #}
  {# ============================================ #}

  {{ run_hooks(post_hooks) }}

  {# Apply grants #}
  {% set should_revoke = should_revoke(old_relation, full_refresh_mode=True) %}
  {% do apply_grants(target_relation, grant_config, should_revoke) %}

  {# Persist documentation #}
  {% do persist_docs(target_relation, model) %}

  {{ return({'relations': [target_relation]}) }}

{% endmaterialization %}
