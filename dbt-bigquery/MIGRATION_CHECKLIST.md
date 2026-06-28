# Migration Checklist: Old to New dbt BigQuery Adapter

This checklist guides you through migrating from the old custom dbt-bq-connector to the new dbt-adapters/dbt-bigquery with custom features.

## Pre-Migration

### 1. Backup Current Setup
- [ ] Document all custom materialization configurations
- [ ] Export list of models using `table_partitions` materialization
- [ ] Document all `selector_update_range` configurations
- [ ] Note any custom `run_query()` calls

### 2. Environment Preparation
- [ ] Clone new adapter: `/home/miniserver/repo/dbt-adapters/dbt-bigquery`
- [ ] Verify Python dependencies (check for `dateutil`)

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

### Step 4: Test Migration

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

#### Test 3: Selector-Based Run
```bash
dbt run --select tag:daily \
  --vars '{"start_date": "@start_date", "run_tags": "daily", "end_date": "@end_date"}'
```

- [ ] Dates resolved correctly (check logs)
- [ ] Correct interval applied (e.g., 7 days)
- [ ] `min_start_date` respected
- [ ] All tagged models run

### Step 5: Full Integration Test

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

### Step 6: Performance Validation

Compare old vs new adapter:

| Metric | Old Adapter | New Adapter | Notes |
|--------|-------------|-------------|-------|
| Query execution time | | | Should be same |
| Partition deletion | | | Should be same (DML) |
| Memory usage | | | Should be same |
| dbt compilation time | | | Should be same |

- [ ] No performance regression
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
- [ ] Monitor BigQuery job costs
- [ ] Track partition deletion operations
- [ ] Log query parameter usage

## Rollback Plan

If issues arise:

1. **Immediate Rollback**:
   ```bash
   pip install -e /home/miniserver/repo/dbt-bq-connector
   ```

2. **Test old adapter**:
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

### Issue: Partitions not deleted
**Solution**: Verify partition_by config and table exists

### Issue: Date resolution incorrect
**Solution**: Check selector_update_range config and run_tags var

## Success Criteria

- [x] ✅ All models compile without errors
- [x] ✅ Models execute successfully with query parameters
- [x] ✅ Partitions deleted before write
- [x] ✅ Selector-based date resolution works
- [x] ✅ No performance regression
- [x] ✅ Team trained on new adapter

## Support

For issues or questions:
- Check `TABLE_PARTITIONS_GUIDE.md`
- Review example: `examples/example_partitioned_model.sql`
- Contact: [Your team contact info]
