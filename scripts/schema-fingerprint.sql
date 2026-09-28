-- schema 指紋：只輸出「結構」（欄位、索引、約束、hypertable、CAGG、policy job），不含資料。
-- 由 scripts/verify-baseline.sh 對「現場 DB」與「由 migrations 新建的 DB」各跑一次再 diff。
-- 輸出未排序（不同 DB 的排序規則可能不同），由呼叫端用 LC_ALL=C sort 統一排序。

SELECT 'col   | ' || table_name || ' | ' || column_name || ' | ' || data_type
       || ' | ' || is_nullable || ' | ' || coalesce(column_default, '')
FROM information_schema.columns
WHERE table_schema = 'public' AND table_name <> 'schema_migrations';

SELECT 'idx   | ' || tablename || ' | ' || indexdef
FROM pg_indexes
WHERE schemaname = 'public' AND tablename <> 'schema_migrations';

SELECT 'con   | ' || conrelid::regclass::text || ' | ' || conname || ' | ' || pg_get_constraintdef(oid)
FROM pg_constraint
WHERE connamespace = 'public'::regnamespace AND conrelid <> 0
  AND conrelid::regclass::text <> 'schema_migrations';

SELECT 'ht    | ' || hypertable_name || ' | dims=' || num_dimensions
       || ' | compression=' || compression_enabled
FROM timescaledb_information.hypertables;

SELECT 'dim   | ' || hypertable_name || ' | ' || column_name || ' | ' || coalesce(time_interval::text, '')
FROM timescaledb_information.dimensions;

SELECT 'cagg  | ' || view_name || ' | materialized_only=' || materialized_only
       || ' | ' || regexp_replace(view_definition, '\s+', ' ', 'g')
FROM timescaledb_information.continuous_aggregates;

-- job id / hypertable id 在不同 DB 可能不同，比對時剔除
SELECT 'job   | ' || proc_name || ' | ' || coalesce(hypertable_name, '') || ' | '
       || (config - 'mat_hypertable_id' - 'hypertable_id')::text
       || ' | ' || schedule_interval::text
FROM timescaledb_information.jobs
WHERE proc_name IN ('policy_retention', 'policy_refresh_continuous_aggregate', 'policy_compression');
