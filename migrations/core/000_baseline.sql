-- =============================================
-- core/000_baseline.sql
--
-- 這是「ECI 現場既有 DB」的狀態：01_init.sql (schema v0.3) + 02_monitoring.sql，
-- 內容原樣搬入，只做兩處調整：
--   1. 移除 ECI 錶主檔的 INSERT（站點資料，改放 sites/eci/migrations/000_seed_meters.sql）
--   2. 用 psql 變數 retention_days（由 migrate.sh 傳入），未提供時預設 180
--
-- 已在跑的現場 DB：不要執行這支，用 `migrate.sh adopt` 登記為已套用，
-- 並先用 scripts/verify-baseline.sh 確認兩邊 schema 一致。
-- =============================================

\if :{?retention_days}
\else
  \set retention_days 180
\endif

-- =============================================
-- EMS Database Schema v0.3
-- TimescaleDB (PostgreSQL)
--
-- v0.3 變更摘要（vs v0.2）：
--   1. meters 主檔重寫，對齊 config.js 真實接線（26 電 + 4 水 + 3 蒸氣 = 33 支）
--   2. 移除 accumulator 的 delta 欄位（用量改由 continuous aggregate 即時算）
--   3. building 與 gateway 拆分：gateway 存 OTPanel，building 留 NULL 待業主回填棟別
--   4. meter_type 註解標明未來擴充值（solar / bess / ev），純註解零成本預留
--   5. 多租戶：不加 tenant_id 實體欄位（v1.0 單站單 IPC，加了是死欄位），僅留註解
--   6. meters 初始資料採用現場真實資料（Terry 提供，2026-04-21 匯入）
--
-- 設定：原始資料保留 :retention_days 天 (預設 180 天)
-- =============================================

CREATE EXTENSION IF NOT EXISTS timescaledb;

-- =============================================
-- 錶頭主檔（設備清冊）
-- =============================================
-- 多租戶預留說明：
--   v1.0 採「每案場一台 IPC、各跑各的 DB」，多租戶發生在「部署層」而非「schema 層」，
--   單站部署下 tenant_id 永遠同值，屬死欄位，故 v1.0 不加。
--   未來若改雲端集中部署需多租戶，於此表加 tenant_id TEXT NOT NULL，
--   時序表「不需」加 tenant_id（meter_id 可 join 回此表推導租戶）。
-- =============================================
CREATE TABLE IF NOT EXISTS meters (
    -- 通用屬性（所有錶頭都必填）
    meter_id    TEXT        PRIMARY KEY,
    -- meter_type 目前值：'electricity' / 'water' / 'steam'
    -- 未來模塊擴充值（架構預留，資料接入後啟用）：'solar' / 'bess' / 'ev'
    meter_type  TEXT        NOT NULL,
    -- building：真正的棟別（如 'B01'）。目前場域尚未提供，留空（NULL），待業主回填。
    building    TEXT,
    -- gateway：此錶掛在哪個 Modbus Gateway / OTPanel（如 'OTPanel_01.1'）。
    --   來源 config.js 的 gateway.name，排查斷線時可一眼定位是哪個盤。
    gateway     TEXT        NOT NULL,
    -- zone：功能分區（中文），前端可 GROUP BY zone 出各製程能耗佔比
    zone        TEXT        NOT NULL,
    is_main     BOOLEAN     NOT NULL DEFAULT FALSE,
    description TEXT        NOT NULL,

    -- 特殊屬性（彈性擴充，選填）—— 未來太陽能/儲能的設備規格（容量、廠牌等）可放這
    tags        JSONB       DEFAULT '{}',

    created_at  TIMESTAMPTZ DEFAULT NOW()
);

-- =============================================
-- 電錶即時值
-- =============================================
CREATE TABLE IF NOT EXISTS realtime_electricity (
    time         TIMESTAMPTZ      NOT NULL,
    meter_id     TEXT             NOT NULL REFERENCES meters(meter_id),
    power_kw     DOUBLE PRECISION NOT NULL,
    voltage      DOUBLE PRECISION NOT NULL,
    current_a    DOUBLE PRECISION NOT NULL,
    power_factor DOUBLE PRECISION NOT NULL
);
SELECT create_hypertable('realtime_electricity', 'time', if_not_exists => TRUE);
CREATE INDEX IF NOT EXISTS idx_realtime_elec_meter_time
    ON realtime_electricity (meter_id, time DESC);

-- =============================================
-- 水錶即時值
-- =============================================
CREATE TABLE IF NOT EXISTS realtime_water (
    time          TIMESTAMPTZ      NOT NULL,
    meter_id      TEXT             NOT NULL REFERENCES meters(meter_id),
    flow_rate_m3h DOUBLE PRECISION NOT NULL
);
SELECT create_hypertable('realtime_water', 'time', if_not_exists => TRUE);
CREATE INDEX IF NOT EXISTS idx_realtime_water_meter_time
    ON realtime_water (meter_id, time DESC);

-- =============================================
-- 蒸氣錶即時值
-- =============================================
CREATE TABLE IF NOT EXISTS realtime_steam (
    time          TIMESTAMPTZ      NOT NULL,
    meter_id      TEXT             NOT NULL REFERENCES meters(meter_id),
    flow_rate_kgh DOUBLE PRECISION NOT NULL,
    pressure_bar  DOUBLE PRECISION NOT NULL,
    temperature_c DOUBLE PRECISION NOT NULL
);
SELECT create_hypertable('realtime_steam', 'time', if_not_exists => TRUE);
CREATE INDEX IF NOT EXISTS idx_realtime_steam_meter_time
    ON realtime_steam (meter_id, time DESC);

-- =============================================
-- 電錶累計值
-- v0.3：移除 delta_kwh —— 用量由 hourly_consumption_electricity (MAX-MIN) 算
-- =============================================
CREATE TABLE IF NOT EXISTS accumulator_electricity (
    time      TIMESTAMPTZ      NOT NULL,
    meter_id  TEXT             NOT NULL REFERENCES meters(meter_id),
    total_kwh DOUBLE PRECISION NOT NULL
);
SELECT create_hypertable('accumulator_electricity', 'time', if_not_exists => TRUE);
CREATE INDEX IF NOT EXISTS idx_acc_elec_meter_time
    ON accumulator_electricity (meter_id, time DESC);

-- =============================================
-- 水錶累計值
-- v0.3：移除 delta_m3 —— 用量由 hourly_consumption_water (MAX-MIN) 算
-- =============================================
CREATE TABLE IF NOT EXISTS accumulator_water (
    time     TIMESTAMPTZ      NOT NULL,
    meter_id TEXT             NOT NULL REFERENCES meters(meter_id),
    total_m3 DOUBLE PRECISION NOT NULL
);
SELECT create_hypertable('accumulator_water', 'time', if_not_exists => TRUE);
CREATE INDEX IF NOT EXISTS idx_acc_water_meter_time
    ON accumulator_water (meter_id, time DESC);


-- ── Continuous Aggregate：每小時聚合（電錶）──────────────
CREATE MATERIALIZED VIEW IF NOT EXISTS hourly_electricity
WITH (timescaledb.continuous) AS
SELECT
  time_bucket('1 hour', time) AS bucket,
  meter_id,
  AVG(power_kw)   AS avg_kw,
  MAX(power_kw)   AS max_kw,
  MIN(power_kw)   AS min_kw,
  AVG(voltage)    AS avg_voltage,
  AVG(power_factor) AS avg_pf
FROM realtime_electricity
GROUP BY time_bucket('1 hour', time), meter_id;

-- Continuous Aggregate：每小時聚合（水錶）
CREATE MATERIALIZED VIEW IF NOT EXISTS hourly_water
WITH (timescaledb.continuous) AS
SELECT
  time_bucket('1 hour', time) AS bucket,
  meter_id,
  AVG(flow_rate_m3h) AS avg_flow,
  MAX(flow_rate_m3h) AS max_flow
FROM realtime_water
GROUP BY time_bucket('1 hour', time), meter_id;

-- Continuous Aggregate：每小時聚合（蒸氣錶）
CREATE MATERIALIZED VIEW IF NOT EXISTS hourly_steam
WITH (timescaledb.continuous) AS
SELECT
  time_bucket('1 hour', time) AS bucket,
  meter_id,
  AVG(flow_rate_kgh)  AS avg_flow,
  AVG(temperature_c)  AS avg_temp,
  AVG(pressure_bar)   AS avg_pressure
FROM realtime_steam
GROUP BY time_bucket('1 hour', time), meter_id;

-- Continuous Aggregate：每小時用電量（累計差值）
-- v0.3：這就是「用量」的唯一真相來源，取代逐筆 delta_kwh
-- 注意：MAX-MIN 在累計值歸零（換錶/溢位 reset）時會算出負值或暴衝，
--       v1.0 不處理，TODO 未來加 reset 偵測（LAG 比對前一筆，負值歸零）
CREATE MATERIALIZED VIEW IF NOT EXISTS hourly_consumption_electricity
WITH (timescaledb.continuous) AS
SELECT
  time_bucket('1 hour', time) AS bucket,
  meter_id,
  MAX(total_kwh) - MIN(total_kwh) AS kwh_consumed
FROM accumulator_electricity
GROUP BY time_bucket('1 hour', time), meter_id;

-- Continuous Aggregate：每小時用水量（累計差值）
CREATE MATERIALIZED VIEW IF NOT EXISTS hourly_consumption_water
WITH (timescaledb.continuous) AS
SELECT
  time_bucket('1 hour', time) AS bucket,
  meter_id,
  MAX(total_m3) - MIN(total_m3) AS m3_consumed
FROM accumulator_water
GROUP BY time_bucket('1 hour', time), meter_id;

-- ── 自動刷新策略 ─────────────────────────────────────────
SELECT add_continuous_aggregate_policy('hourly_electricity',
  start_offset => INTERVAL '3 hours',
  end_offset   => INTERVAL '1 hour',
  schedule_interval => INTERVAL '1 hour');

SELECT add_continuous_aggregate_policy('hourly_water',
  start_offset => INTERVAL '3 hours',
  end_offset   => INTERVAL '1 hour',
  schedule_interval => INTERVAL '1 hour');

SELECT add_continuous_aggregate_policy('hourly_steam',
  start_offset => INTERVAL '3 hours',
  end_offset   => INTERVAL '1 hour',
  schedule_interval => INTERVAL '1 hour');

SELECT add_continuous_aggregate_policy('hourly_consumption_electricity',
  start_offset => INTERVAL '3 hours',
  end_offset   => INTERVAL '1 hour',
  schedule_interval => INTERVAL '1 hour');

SELECT add_continuous_aggregate_policy('hourly_consumption_water',
  start_offset => INTERVAL '3 hours',
  end_offset   => INTERVAL '1 hour',
  schedule_interval => INTERVAL '1 hour');

-- ── Data Retention：原始資料保留 180 天 ───────────────────
SELECT add_retention_policy('realtime_electricity', (:'retention_days' || ' days')::INTERVAL);
SELECT add_retention_policy('realtime_water',       (:'retention_days' || ' days')::INTERVAL);
SELECT add_retention_policy('realtime_steam',       (:'retention_days' || ' days')::INTERVAL);
SELECT add_retention_policy('accumulator_electricity', (:'retention_days' || ' days')::INTERVAL);
SELECT add_retention_policy('accumulator_water',    (:'retention_days' || ' days')::INTERVAL);

-- ===== 以下原 02_monitoring.sql =====
-- 監控基礎建設：collector 心跳 + gateway 連線狀態
-- 收斂自 ems-dev，對應 collector.js 的 gatewayStatusQuery / heartbeatQuery

CREATE TABLE collector_heartbeat (
    time               TIMESTAMPTZ NOT NULL,
    round_duration_ms  INTEGER,
    meters_success     INTEGER,
    meters_failed      INTEGER
);
SELECT create_hypertable('collector_heartbeat', 'time');

CREATE TABLE gateway_connection_status (
    time             TIMESTAMPTZ NOT NULL,
    gateway_name     TEXT NOT NULL,
    connection_type  TEXT NOT NULL,
    is_connected     BOOLEAN NOT NULL,
    error_message    TEXT
);
SELECT create_hypertable('gateway_connection_status', 'time');
