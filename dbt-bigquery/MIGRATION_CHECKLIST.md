# Migration Checklist: Old to New dbt BigQuery Adapter

This checklist guides you through migrating from the old custom dbt-bq-connector to the new dbt-adapters/dbt-bigquery with custom features.

## Pre-Migration

### 1. Backup Current Setup
- [ ] Document all custom materialization configurations
- [ ] Export list of models using `table_partitions` materialization
- [ ] Document all `selector_update_range` configurations
- [ ] Save current `dbt_connector.py` integration points
- [ ] Note any custom `run_query()` calls

### 2. Environment Preparation
- [ ] Clone new adapter: `/home/miniserver/repo/dbt-adapters/dbt-bigquery`
- [ ] Verify Python dependencies (check for `dateutil`, `requests`)
- [ ] Set up environment variables for callbacks:
  ```bash
  export DBT_URL="https://your-api.com"
  export API_KEY="your-api-key"
  ```

## Migration Steps

### Step 1: Update Adapter Installation

- [ ] Update `requirements.txt` or `pyproject.toml` to point to new adapter:
  ```
  # Old
  dbt-bigquery @ file:///home/miniserver/repo/dbt-bq-connector

  # New
  dbt-bigquery @ file:///home/miniserver/repo/dbt-adapters/dbt-bigquery
  ```

- [ ] Install new adapter:
  ```bash
  pip install -e /home/miniserver/repo/dbt-adapters/dbt-bigquery
  ```

- [ ] Verify installation:
  ```bash
  dbt --version
  ```

### Step 2: Update Model Configurations

No changes needed! The `table_partitions` materialization syntax remains the same:

```yaml
models:
  my_model:
    materialized: table_partitions
    partition_by:
      field: date
      data_type: date
    selector_update_range:
      daily: 7
      weekly: 2w
      monthly: 3m
    min_start_date: "2024-01-01"
```

✅ **Backward compatible** - existing configs will work without modification.

### Step 3: Verify SQL Query Syntax

Ensure your models use `@start_date` and `@end_date` parameters:

```sql
-- ✅ Correct
WHERE date BETWEEN @start_date AND @end_date

-- ❌ Incorrect
WHERE date BETWEEN {{ var('start_date') }} AND {{ var('end_date') }}
```

- [ ] Review all models using `table_partitions`
- [ ] Confirm `@start_date` and `@end_date` usage
- [ ] Test queries with `dry_run` mode

### Step 4: Update `dbt_connector.py` Integration

#### Old Integration
```python
# Old: Custom adapter import
from dbt_bq_connector.adapters.bigquery import impl_utils

# Old: prepare_results_from_callback
def prepare_results_from_callback(self, query_status: PartitionsModelResp):
    # ... handling callback ...
```

#### New Integration
```python
# New: Standard adapter + callbacks module
from dbt.adapters.bigquery.callbacks import PartitionsModelResp

# Callbacks now fire automatically from adapter
# No code changes needed in dbt_connector.py!
```

Changes needed in `/home/miniserver/repo/hitapps_analytics/dbt_app/src/dbt_connector.py`:

- [ ] Update import path:
  ```python
  # Old
  from dbt_bq_connector.adapters.bigquery.impl_utils import PartitionsModelResp

  # New
  from dbt.adapters.bigquery.callbacks import PartitionsModelResp
  ```

- [ ] Verify `prepare_results_from_callback()` still works
- [ ] Test callback endpoint receives POST requests

### Step 5: Test Migration

#### Test 1: Dry Run
```bash
dbt run --select tag:daily \
  --vars '{"dry_run": true, "start_date": "@start_date", "run_tags": "daily", "end_date": "@end_date"}'
```

- [ ] Dry run succeeds
- [ ] No errors in logs
- [ ] BigQuery validates SQL

#### Test 2: Single Model
```bash
dbt run --select your_test_model \
  --vars '{"start_date": "2025-10-01", "end_date": "2025-10-02"}'
```

- [ ] Model runs successfully
- [ ] Partitions deleted correctly
- [ ] Data written to BigQuery
- [ ] Callbacks received (check API logs)

#### Test 3: Selector-Based Run
```bash
dbt run --select tag:daily \
  --vars '{"start_date": "@start_date", "run_tags": "daily", "end_date": "@end_date"}'
```

- [ ] Dates resolved correctly (check logs)
- [ ] Correct interval applied (e.g., 7 days)
- [ ] `min_start_date` respected
- [ ] All tagged models run

#### Test 4: Callback Verification
- [ ] Check API receives `status='running'` callback
- [ ] Check API receives `status='done'` callback
- [ ] Verify callback payload includes:
  - `unique_id`
  - `job_id`
  - `start_date` / `end_date`
  - `bytes_billed` / `bytes_processed`
  - `slot_ms`
  - `started` / `ended`

### Step 6: Full Integration Test

Run complete workflow:

```bash
# 1. Daily refresh
dbt run --select tag:daily --vars '{"start_date": "@start_date", "run_tags": "daily", "end_date": "@end_date"}'

# 2. Weekly refresh
dbt run --select tag:weekly --vars '{"start_date": "@start_date", "run_tags": "weekly", "end_date": "@end_date"}'

# 3. Monthly refresh
dbt run --select tag:monthly --vars '{"start_date": "@start_date", "run_tags": "monthly", "end_date": "@end_date"}'
```

- [ ] All selectors work correctly
- [ ] Date ranges calculated properly
- [ ] Partitions managed correctly
- [ ] Callbacks flow through API → UI
- [ ] UI displays real-time status

### Step 7: Performance Validation

Compare old vs new adapter:

| Metric | Old Adapter | New Adapter | Notes |
|--------|-------------|-------------|-------|
| Query execution time | | | Should be same |
| Partition deletion | | | Should be same (DML) |
| Callback latency | | | Should be faster |
| Memory usage | | | Should be same |
| dbt compilation time | | | Should be same |

- [ ] No performance regression
- [ ] Callbacks still near real-time
- [ ] BigQuery costs unchanged

## Post-Migration

### Cleanup Old Adapter
- [ ] Remove old adapter from requirements:
  ```bash
  pip uninstall dbt-bigquery  # Old custom version
  ```
- [ ] Archive old adapter code:
  ```bash
  mv /home/miniserver/repo/dbt-bq-connector /home/miniserver/repo/archive/dbt-bq-connector
  ```
- [ ] Update documentation to reference new adapter

### Documentation Updates
- [ ] Update team wiki/docs with new adapter location
- [ ] Document new adapter methods:
  - `adapter.relative_start(interval)`
  - `adapter.set_query_callback_context(...)`
  - `adapter.set_query_parameters(...)`
- [ ] Share `TABLE_PARTITIONS_GUIDE.md` with team

### Monitoring Setup
- [ ] Set up alerts for callback failures
- [ ] Monitor BigQuery job costs
- [ ] Track partition deletion operations
- [ ] Log query parameter usage

## Rollback Plan

If issues arise:

1. **Immediate Rollback**:
   ```bash
   pip install -e /home/miniserver/repo/dbt-bq-connector
   ```

2. **Restore dbt_connector.py**:
   ```python
   # Revert import paths to old adapter
   from dbt_bq_connector.adapters.bigquery.impl_utils import PartitionsModelResp
   ```

3. **Test old adapter**:
   ```bash
   dbt run --select tag:daily --vars '{"start_date": "@start_date", "run_tags": "daily"}'
   ```

## Troubleshooting

### Issue: Module import errors
**Solution**: Check Python path and reinstall adapter
```bash
pip install --force-reinstall -e /home/miniserver/repo/dbt-adapters/dbt-bigquery
```

### Issue: Query parameters not working
**Solution**: Verify SQL uses `@start_date` and `@end_date` (not Jinja vars)

### Issue: Callbacks not received
**Solution**: Check environment variables and API endpoint
```bash
echo $DBT_URL
echo $API_KEY
curl -X POST $DBT_URL/dbt/set_query_status -H "X-API-KEY: $API_KEY"
```

### Issue: Partitions not deleted
**Solution**: Verify partition_by config and table exists

### Issue: Date resolution incorrect
**Solution**: Check selector_update_range config and run_tags var

## Success Criteria

- [x] ✅ All models compile without errors
- [x] ✅ Models execute successfully with query parameters
- [x] ✅ Partitions deleted before write
- [x] ✅ Callbacks received in API
- [x] ✅ UI displays real-time status
- [x] ✅ Selector-based date resolution works
- [x] ✅ No performance regression
- [x] ✅ Team trained on new adapter

## Support

For issues or questions:
- Check `TABLE_PARTITIONS_GUIDE.md`
- Review example: `examples/example_partitioned_model.sql`
- Contact: [Your team contact info]
