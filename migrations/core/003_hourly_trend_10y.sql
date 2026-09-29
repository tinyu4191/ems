-- =============================================
-- core/003_hourly_trend_10y.sql
--
-- 長期趨勢資料：只存「每小時最後一筆累計值」，保留 10 年。
-- 資料量小（33 支錶 × 24 小時 × 365 天 × 10 年 ≈ 290 萬列），
-- 用量（差值）不需要另外長期保留，之後要算時直接對這個小表做 LAG，
-- 不用重新掃過 10 年份的原始資料。
--
-- 同時：baseline 裡的 5 個 continuous aggregate（hourly_electricity 等）
-- 整個 repo 零引用（已用 grep 全 repo 確認過），這次一併移除，
-- 換成本檔的設計。hourly_consumption_electricity / hourly_consumption_water
-- 這兩個名字沿用，但底層從「materialized view 存 MAX-MIN」
-- 換成「plain view 對 hourly_last_* 做 LAG 差值」（002 已驗證這個公式正確）。
--
-- 注意：CALL refresh_continuous_aggregate(...) 會立即回填現有全部歷史，
-- 依現場資料量（目前約 5 個月）應該很快，但仍建議挑離峰時段執行本檔。
-- =============================================

-- ── 移除未使用的舊 continuous aggregate ──────────────
SELECT remove_continuous_aggregate_policy('hourly_electricity', if_exists => true);
SELECT remove_continuous_aggregate_policy('hourly_water', if_exists => true);
SELECT remove_continuous_aggregate_policy('hourly_steam', if_exists => true);
SELECT remove_continuous_aggregate_policy('hourly_consumption_electricity', if_exists => true);
SELECT remove_continuous_aggregate_policy('hourly_consumption_water', if_exists => true);

DROP MATERIALIZED VIEW IF EXISTS hourly_electricity;
DROP MATERIALIZED VIEW IF EXISTS hourly_water;
DROP MATERIALIZED VIEW IF EXISTS hourly_steam;
DROP MATERIALIZED VIEW IF EXISTS hourly_consumption_electricity;
DROP MATERIALIZED VIEW IF EXISTS hourly_consumption_water;

-- ── 新的每小時趨勢（只存最後一筆值）──────────────
CREATE MATERIALIZED VIEW IF NOT EXISTS hourly_last_electricity
WITH (timescaledb.continuous) AS
SELECT
  time_bucket('1 hour', time, 'Asia/Ho_Chi_Minh') AS bucket,
  meter_id,
  last(total_kwh, time) AS total_kwh
FROM accumulator_electricity
GROUP BY 1, 2
WITH NO DATA;

CREATE MATERIALIZED VIEW IF NOT EXISTS hourly_last_water
WITH (timescaledb.continuous) AS
SELECT
  time_bucket('1 hour', time, 'Asia/Ho_Chi_Minh') AS bucket,
  meter_id,
  last(total_m3, time) AS total_m3
FROM accumulator_water
GROUP BY 1, 2
WITH NO DATA;

SELECT add_continuous_aggregate_policy('hourly_last_electricity',
  start_offset => INTERVAL '3 hours', end_offset => INTERVAL '1 hour', schedule_interval => INTERVAL '1 hour');
SELECT add_continuous_aggregate_policy('hourly_last_water',
  start_offset => INTERVAL '3 hours', end_offset => INTERVAL '1 hour', schedule_interval => INTERVAL '1 hour');

-- 回填現有全部歷史（第一次執行才需要，之後靠上面的 policy 自動每小時刷新）
CALL refresh_continuous_aggregate('hourly_last_electricity', NULL, NULL);
CALL refresh_continuous_aggregate('hourly_last_water', NULL, NULL);

-- 保留 10 年（這是本檔的目的：raw 只留 360 天，這個小表留 10 年）
SELECT add_retention_policy('hourly_last_electricity', INTERVAL '10 years', if_not_exists => true);
SELECT add_retention_policy('hourly_last_water', INTERVAL '10 years', if_not_exists => true);

-- ── 用量（差值）：plain view 對 hourly_last_* 做 LAG，資料量小，即時算免另建 cagg ──
CREATE OR REPLACE VIEW hourly_consumption_electricity AS
SELECT
  bucket, meter_id,
  GREATEST(total_kwh - LAG(total_kwh) OVER (PARTITION BY meter_id ORDER BY bucket), 0) AS kwh
FROM hourly_last_electricity;

CREATE OR REPLACE VIEW hourly_consumption_water AS
SELECT
  bucket, meter_id,
  GREATEST(total_m3 - LAG(total_m3) OVER (PARTITION BY meter_id ORDER BY bucket), 0) AS m3
FROM hourly_last_water;
