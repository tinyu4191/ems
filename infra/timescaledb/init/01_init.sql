\set retention_days 180

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

-- =============================================
-- 錶頭主檔初始資料（ECI 場域）—— v0.3 採用現場真實資料（Terry 提供）
-- =============================================
-- 說明：
--   gateway = OTPanel 名稱（Modbus 盤），building 留 NULL 待業主回填棟別，zone = 中文功能分區
--   is_main = TRUE 共 4 支：E-ATS1 / E-ATS2（電進線）、W-IN1 / W-IN2（總進水）
--   電 26 + 水 4 + 蒸氣 3 = 33 支，與 config.js / collector 採集清單完全一致
-- =============================================
INSERT INTO meters (meter_id, meter_type, gateway, zone, is_main, description) VALUES
    -- ── 電錶 ──────────────────────────────────────────────
    ('E-WH',    'electricity', 'OTPanel_01.1', '倉庫',       FALSE, '原料倉'),
    ('E-EXH1',  'electricity', 'OTPanel_01.1', '抽風扇系統', FALSE, '染整區抽風扇'),
    ('E-EXH2',  'electricity', 'OTPanel_01.1', '抽風扇系統', FALSE, '電站1抽風扇'),
    ('E-ELV2',  'electricity', 'OTPanel_01.1', '電梯',       FALSE, '纖造電梯2'),
    ('E-ELV3',  'electricity', 'OTPanel_02.1', '電梯',       FALSE, '電梯3'),
    ('E-QAHB',  'electricity', 'OTPanel_02.1', '品保',       FALSE, '品保+熱縮'),
    ('E-FIRE',  'electricity', 'OTPanel_02.1', '消防系統',   FALSE, '消防系統'),
    ('E-WASTE', 'electricity', 'OTPanel_02.1', '廢水',       FALSE, '廢水處理+食堂+軟水'),
    ('E-CRANE', 'electricity', 'OTPanel_01.1', '浸染',       FALSE, '天車'),
    ('E-DYE3',  'electricity', 'OTPanel_01.2', '連染',       FALSE, '連染'),
    ('E-DYE1',  'electricity', 'OTPanel_02.2', '浸染',       FALSE, '浸染區+化料+染料'),
    ('E-DYE2',  'electricity', 'OTPanel_02.2', '浸染',       FALSE, '浸染+滴定'),
    ('E-FIBAC', 'electricity', 'OTPanel_01.1', '冷氣',       FALSE, '織造冷氣'),
    ('E-PRO1',  'electricity', 'OTPanel_01.2', '加工',       FALSE, '加工+電梯1'),
    ('E-FIB1',  'electricity', 'OTPanel_01.2', '織造',       FALSE, '纖造'),
    ('E-BOIL',  'electricity', 'OTPanel_02.2', '鍋爐',       FALSE, '鍋爐'),
    ('E-PRINT', 'electricity', 'OTPanel_01.1', '網印',       FALSE, '網印'),
    ('E-OFF',   'electricity', 'OTPanel_01.1', '其他',       FALSE, '辦公室'),
    ('E-RSV1',  'electricity', 'OTPanel_02.1', '其他',       FALSE, '預留迴路1'),
    ('E-RSV2',  'electricity', 'OTPanel_02.1', '其他',       FALSE, '預留迴路2'),
    ('E-RSV3',  'electricity', 'OTPanel_02.2', '其他',       FALSE, '預留迴路3'),
    ('E-SEC',   'electricity', 'OTPanel_01.1', '其他',       FALSE, '保衛室'),
    ('E-ATS1',  'electricity', 'OTPanel_01.2', 'ATS1配電站', TRUE,  'ATS1市電進線'),
    ('E-ATS2',  'electricity', 'OTPanel_02.2', 'ATS2配電站', TRUE,  'ATS2市電進線'),
    ('E-AIR',   'electricity', 'OTPanel_01.2', '空壓機',     FALSE, '空壓機'),
    ('E-SOC2',  'electricity', 'OTPanel_02.1', '其他',       FALSE, '電站2插座'),
    -- ── 水錶 ──────────────────────────────────────────────
    ('W-DYE1',  'water', 'OTPanel_03.2', '染紗區', FALSE, '染紗區入水口'),
    ('W-DYE2',  'water', 'OTPanel_03.2', '連染區', FALSE, '連染區入水口'),
    ('W-IN2',   'water', 'OTPanel_04',   '進水',   TRUE,  '管水系統進水口2'),
    ('W-IN1',   'water', 'OTPanel_05',   '進水',   TRUE,  '管水系統進水口1'),
    -- ── 蒸氣錶 ────────────────────────────────────────────
    ('S-DYE1',  'steam', 'OTPanel_03.1', '染紗區', FALSE, '染紗區蒸氣'),
    ('S-BOIL',  'steam', 'OTPanel_03.1', '鍋爐',   FALSE, '鍋爐蒸氣'),
    ('S-DYE2',  'steam', 'OTPanel_03.1', '連染區', FALSE, '連染區蒸氣')
ON CONFLICT (meter_id) DO NOTHING;

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
