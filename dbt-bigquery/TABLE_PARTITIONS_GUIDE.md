# Custom Table Partitions Materialization Guide

This guide documents the custom `table_partitions` materialization and related features added to the dbt BigQuery adapter.

## Overview

The `table_partitions` materialization extends the standard `table` materialization with the following features:

1. **Query Parameters**: Inject runtime parameters (`@start_date`, `@end_date`) into BigQuery queries
2. **Dynamic Date Resolution**: Calculate date ranges based on selectors and relative intervals
3. **Automatic Partition Deletion**: Delete existing partitions before writing new data (zero-cost in BigQuery)
4. **Dry Run Support**: Test queries without executing them

## Features

### 1. Query Parameters

Inject runtime query parameters into your BigQuery SQL using `@start_date` and `@end_date`:

```sql
-- models/my_partitioned_model.sql
{{ config(
    materialized='table_partitions',
    partition_by={
        'field': 'date',
        'data_type': 'date'
    }
) }}

SELECT
    date,
    user_id,
    event_type,
    COUNT(*) as event_count
FROM {{ source('raw', 'events') }}
WHERE date BETWEEN @start_date AND @end_date
GROUP BY 1, 2, 3
```

### 2. Dynamic Date Resolution

#### Using `selector_update_range`

Configure relative date intervals based on selector names:

```yaml
# dbt_project.yml or model config
models:
  my_project:
    my_partitioned_model:
      materialized: table_partitions
      partition_by:
        field: date
        data_type: date
      selector_update_range:
        daily: 7        # 7 days back
        weekly: 2w      # 2 weeks back
        monthly: 3m     # 3 months back (to 1st of that month)
```

Run with selector:

```bash
# Processes last 7 days of data
dbt run --select tag:daily --vars '{"start_date": "@start_date", "run_tags": "daily"}'

# Processes last 2 weeks of data
dbt run --select tag:weekly --vars '{"start_date": "@start_date", "run_tags": "weekly"}'

# Processes last 3 months of data (from 1st of month)
dbt run --select tag:monthly --vars '{"start_date": "@start_date", "run_tags": "monthly"}'
```

#### Explicit Date Ranges

Provide explicit dates via vars:

```bash
dbt run --select my_model --vars '{"start_date": "2025-10-01", "end_date": "2025-10-31"}'
```

#### Date Boundaries

Set minimum and default dates:

```yaml
models:
  my_partitioned_model:
    materialized: table_partitions
    partition_by:
      field: date
      data_type: date
    min_start_date: "2024-01-01"      # Never go before this date
    default_start_date: "2025-01-01"  # Use if no start_date provided
```

### 3. Automatic Partition Deletion

The materialization automatically deletes partitions in the date range before writing new data:

```
Deleting partitions in range: 2025-10-01 to 2025-10-31
Deleted 50000 rows from partitions
```

This is a **zero-cost operation** in BigQuery when deleting entire partitions using DML with `@start_date` and `@end_date` parameters.

#### Partition Granularity Support

The materialization automatically handles different partition granularities (`DAY`, `MONTH`, `YEAR`, `HOUR`) to ensure zero-cost partition deletion:

**Day granularity** (default):
```yaml
partition_by:
  field: date
  data_type: date
  granularity: day  # Default
```

**Month granularity**:
```yaml
partition_by:
  field: date
  data_type: date
  granularity: month  # Partitioned by month
```

**Hour granularity** (requires TIMESTAMP):
```yaml
partition_by:
  field: event_timestamp
  data_type: timestamp
  granularity: hour  # Partitioned by hour
```

The DELETE statement automatically uses the correct truncation function:
- For `DATE` partitions: `DATE_TRUNC(field, GRANULARITY)`
- For `TIMESTAMP` partitions: `TIMESTAMP_TRUNC(field, GRANULARITY)`

**Why this matters**: Without proper truncation, BigQuery charges for scanning partitions when granularity is not `DAY`. The materialization handles this automatically to maintain zero-cost deletion.

### 4. Dry Run Support

Test queries without executing them:

```bash
dbt run --select my_model --vars '{"dry_run": true, "start_date": "2025-10-01", "end_date": "2025-10-31"}'
```

## Complete Example

```sql
-- models/daily_events.sql
{{
  config(
    materialized='table_partitions',
    partition_by={
      'field': 'date',
      'data_type': 'date',
      'granularity': 'day'
    },
    cluster_by=['user_id', 'event_type'],
    selector_update_range={
      'daily': 7,
      'weekly': '2w',
      'monthly': '3m'
    },
    min_start_date='2024-01-01',
    default_start_date='2025-01-01'
  )
}}

SELECT
    DATE(timestamp) as date,
    user_id,
    event_type,
    COUNT(*) as event_count,
    SUM(revenue) as total_revenue
FROM {{ source('raw', 'events') }}
WHERE DATE(timestamp) BETWEEN @start_date AND @end_date
GROUP BY 1, 2, 3
```

Run scenarios:

```bash
# Daily refresh (last 7 days)
dbt run --select tag:daily --vars '{"start_date": "@start_date", "run_tags": "daily", "end_date": "@end_date"}'

# Weekly refresh (last 2 weeks)
dbt run --select tag:weekly --vars '{"start_date": "@start_date", "run_tags": "weekly", "end_date": "@end_date"}'

# Monthly refresh (last 3 months from 1st)
dbt run --select tag:monthly --vars '{"start_date": "@start_date", "run_tags": "monthly", "end_date": "@end_date"}'

# Custom date range
dbt run --select daily_events --vars '{"start_date": "2025-10-15", "end_date": "2025-10-20"}'

# Dry run test
dbt run --select daily_events --vars '{"dry_run": true, "start_date": "2025-10-01", "end_date": "2025-10-31"}'
```

## Migration from Old Adapter

If you're migrating from the old custom adapter, here are the key differences:

### Old Approach
```jinja
{# Old custom run_query() method #}
{%- set response = adapter.run_query(
    query=sql_string,
    dataset_name=dataset_name,
    table_name=table_name,
    write=write_method,
    partition_by=partition_by,
    clusters=cluster_by,
    start_date=start_date,
    end_date=end_date,
    dry_run=var("dry_run"),
    job_id=job_id,
    unique_id=unique_id
) %}
```

### New Approach
```jinja
{# New standard statement() with automatic parameter injection #}
{% do adapter.set_query_callback_context(unique_id, start_date, end_date, dry_run) %}
{% do adapter.set_query_parameters(query_params) %}

{%- call statement('main', language=language) -%}
    {{ create_table_as(False, target_relation, compiled_code, language) }}
{%- endcall -%}

{% do adapter.clear_query_parameters() %}
{% do adapter.clear_query_callback_context() %}
```

### Benefits of New Approach

1. ✅ **Standard dbt flow**: Uses `statement()` instead of custom `run_query()`
2. ✅ **Works with all materializations**: Can extend to incremental, views, etc.
3. ✅ **Cleaner separation**: Adapter handles execution, materialization handles logic
4. ✅ **Better compatibility**: Easier to maintain and upgrade with new dbt versions

## Adapter Methods

### `adapter.relative_start(interval)`

Calculate relative start date:

- `adapter.relative_start(7)` → 7 days ago
- `adapter.relative_start('2w')` → 2 weeks ago
- `adapter.relative_start('3m')` → 3 months ago (to 1st of that month)

### `adapter.set_query_callback_context(unique_id, start_date, end_date, dry_run)`

Set the per-thread execution context (notably the `dry_run` flag) that the adapter
reads when executing the model's queries.

### `adapter.set_query_parameters(query_params)`

Set query parameters for next execution.

## Troubleshooting

### Query parameters not working

Ensure you're using `@start_date` and `@end_date` in your SQL (with `@` prefix).

### Partitions not being deleted

Ensure:
1. Table exists
2. `partition_by` config is set
3. `start_date` and `end_date` are provided

## Performance Tips

1. **Use partition pruning**: Always filter on partition field with `@start_date` and `@end_date`
2. **Cluster wisely**: Add clustering on frequently filtered columns
3. **Test with dry_run**: Validate query cost before executing

## License

This feature set extends the official dbt BigQuery adapter with custom functionality for partition management.
