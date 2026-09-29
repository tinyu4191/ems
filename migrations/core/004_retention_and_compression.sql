-- =============================================
-- core/004_retention_and_compression.sql
--
-- 原始資料保留期 180 天 → 360 天，並加上壓縮（30 天後自動壓縮，依 meter_id 分段）。
--
-- 注意：這支 migration 執行後，retention 會恢復自動運作。
-- 2026-09-28 曾因為保留天數尚未決定，手動將 5 個 retention job 暫停
-- （scheduled = false，見 docs/migrations.md「現場狀態備註」）。
-- remove_retention_policy 會整個移除舊 job（不論當時是否暫停），
-- add_retention_policy 建立的新 job 預設是啟用狀態 —— 等於用「360 天」正式取代先前的暫停狀態。
-- =============================================

-- ── Retention：180 天 → 360 天 ──────────────
SELECT remove_retention_policy('realtime_electricity', if_exists => true);
SELECT remove_retention_policy('realtime_water', if_exists => true);
SELECT remove_retention_policy('realtime_steam', if_exists => true);
SELECT remove_retention_policy('accumulator_electricity', if_exists => true);
SELECT remove_retention_policy('accumulator_water', if_exists => true);

SELECT add_retention_policy('realtime_electricity', INTERVAL '360 days', if_not_exists => true);
SELECT add_retention_policy('realtime_water', INTERVAL '360 days', if_not_exists => true);
SELECT add_retention_policy('realtime_steam', INTERVAL '360 days', if_not_exists => true);
SELECT add_retention_policy('accumulator_electricity', INTERVAL '360 days', if_not_exists => true);
SELECT add_retention_policy('accumulator_water', INTERVAL '360 days', if_not_exists => true);

-- ── 壓縮：30 天後自動壓縮，依 meter_id 分段 ──────────────
ALTER TABLE realtime_electricity SET (
  timescaledb.compress, timescaledb.compress_segmentby = 'meter_id', timescaledb.compress_orderby = 'time DESC');
ALTER TABLE realtime_water SET (
  timescaledb.compress, timescaledb.compress_segmentby = 'meter_id', timescaledb.compress_orderby = 'time DESC');
ALTER TABLE realtime_steam SET (
  timescaledb.compress, timescaledb.compress_segmentby = 'meter_id', timescaledb.compress_orderby = 'time DESC');
ALTER TABLE accumulator_electricity SET (
  timescaledb.compress, timescaledb.compress_segmentby = 'meter_id', timescaledb.compress_orderby = 'time DESC');
ALTER TABLE accumulator_water SET (
  timescaledb.compress, timescaledb.compress_segmentby = 'meter_id', timescaledb.compress_orderby = 'time DESC');

SELECT add_compression_policy('realtime_electricity', INTERVAL '30 days', if_not_exists => true);
SELECT add_compression_policy('realtime_water', INTERVAL '30 days', if_not_exists => true);
SELECT add_compression_policy('realtime_steam', INTERVAL '30 days', if_not_exists => true);
SELECT add_compression_policy('accumulator_electricity', INTERVAL '30 days', if_not_exists => true);
SELECT add_compression_policy('accumulator_water', INTERVAL '30 days', if_not_exists => true);
