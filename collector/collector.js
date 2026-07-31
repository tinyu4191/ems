require('dotenv').config({ path: __dirname + '/.env' });
const ModbusRTU = require('modbus-serial');
const { Pool } = require('pg');
const fs = require('fs');
const path = require('path');
const {
  REGISTER_E_BLOCK, REGISTER_E_OFFSETS,
  REGISTER_W_BLOCK, REGISTER_W_OFFSETS,
  REGISTER_S_BLOCK, REGISTER_S_OFFSETS,
  GATEWAYS_ELECTRICITY, GATEWAYS_WATER, GATEWAYS_STEAM,
} = require('./config');

// ── DB 連線池 ─────────────────────────────────────
const pool = new Pool({
  host:     process.env.DB_HOST,
  port:     parseInt(process.env.DB_PORT),
  database: process.env.DB_NAME,
  user:     process.env.DB_USER,
  password: process.env.DB_PASS,
  max: 5,
  idleTimeoutMillis: 30000,
  connectionTimeoutMillis: 5000,
});

// ★ 監控用 SQL
const gatewayStatusQuery = `
  INSERT INTO gateway_connection_status (time, gateway_name, connection_type, is_connected, error_message)
  VALUES (NOW(), $1, $2, $3, $4)`;

const heartbeatQuery = `
  INSERT INTO collector_heartbeat (time, round_duration_ms, meters_success, meters_failed)
  VALUES (NOW(), $1, $2, $3)`;

// ── Log 系統 ──────────────────────────────────────
const LOG_DIR = path.join(__dirname, 'logs');
if (!fs.existsSync(LOG_DIR)) fs.mkdirSync(LOG_DIR, { recursive: true });

function getLogFile() {
  const date = new Date().toISOString().slice(0, 10);
  return path.join(LOG_DIR, `collector-${date}.log`);
}

function log(level, message) {
  const ts = new Date().toISOString();
  const line = `[${ts}] [${level}] ${message}`;
  console.log(line);
  fs.appendFileSync(getLogFile(), line + '\n');
}

// ── 採集統計 ──────────────────────────────────────
const stats = {
  totalPolls: 0,
  successCount: 0,
  errorCount: 0,
  skippedCount: 0,
  gatewayErrors: {},
};

// ── Float 工具函數 ────────────────────────────────
// 從一次讀回的整段 register 陣列中，取某個 offset 的 float
function floatAt(data, offset, byteOrder = 'ABCD') {
  const buf = Buffer.allocUnsafe(4);
  if (byteOrder === 'CDAB') {
    buf.writeUInt16BE(data[offset + 1], 0);
    buf.writeUInt16BE(data[offset], 2);
  } else {
    buf.writeUInt16BE(data[offset], 0);
    buf.writeUInt16BE(data[offset + 1], 2);
  }
  return buf.readFloatBE(0);
}

function isValidFloat(val) {
  return typeof val === 'number' && isFinite(val) && !isNaN(val);
}

// ── 電錶：原本 5 次讀取 → 現在 1 次 ────────────────────────
async function readElecMeter(client, slaveId, meterId) {
  client.setID(slaveId);
  try {
    const result = await client.readHoldingRegisters(
      REGISTER_E_BLOCK.address,
      REGISTER_E_BLOCK.count
    );
    const data = result.data;

    const voltage     = floatAt(data, REGISTER_E_OFFSETS.VOLTAGE);
    const current      = floatAt(data, REGISTER_E_OFFSETS.CURRENT);
    const powerFactor = floatAt(data, REGISTER_E_OFFSETS.POWER_FACTOR);
    const activePower = floatAt(data, REGISTER_E_OFFSETS.ACTIVE_POWER) / 1000;
    const energyKwh   = floatAt(data, REGISTER_E_OFFSETS.ENERGY_KWH);

    if (!isValidFloat(activePower) || !isValidFloat(energyKwh)) {
      log('WARN', `[${meterId}] 異常數值被過濾: kW=${activePower}, kWh=${energyKwh}`);
      stats.errorCount++;
      return;
    }

    log('INFO', `[${meterId}] kW: ${activePower.toFixed(2)}, kWh: ${energyKwh.toFixed(2)}`);

    await pool.query(
      `INSERT INTO realtime_electricity (time, meter_id, power_kw, voltage, current_a, power_factor)
       VALUES (NOW(), $1, $2, $3, $4, $5)`,
      [meterId, activePower, voltage, current, powerFactor]
    );
    await pool.query(
      `INSERT INTO accumulator_electricity (time, meter_id, total_kwh)
       VALUES (NOW(), $1, $2)`,
      [meterId, energyKwh]
    );
    stats.successCount++;
  } catch (err) {
    log('ERROR', `[${meterId}] 讀取失敗: ${err.message}`);
    stats.errorCount++;
  }
}

// ── 水錶：原本 2 次讀取 → 現在 1 次 ────────────────────────
async function readWaterMeter(client, slaveId, meterId) {
  client.setID(slaveId);
  try {
    const result = await client.readHoldingRegisters(
      REGISTER_W_BLOCK.address,
      REGISTER_W_BLOCK.count
    );
    const data = result.data;

    const totalM3  = floatAt(data, REGISTER_W_OFFSETS.TOTAL_FLOW_FWD);
    const flowRate = floatAt(data, REGISTER_W_OFFSETS.FLOW_RATE);

    if (!isValidFloat(flowRate) || !isValidFloat(totalM3)) {
      log('WARN', `[${meterId}] 異常數值被過濾: flow=${flowRate}, total=${totalM3}`);
      stats.errorCount++;
      return;
    }

    log('INFO', `[${meterId}] flow: ${flowRate.toFixed(3)} m³/h, total: ${totalM3.toFixed(2)} m³`);

    await pool.query(
      `INSERT INTO realtime_water (time, meter_id, flow_rate_m3h)
       VALUES (NOW(), $1, $2)`,
      [meterId, flowRate]
    );
    await pool.query(
      `INSERT INTO accumulator_water (time, meter_id, total_m3)
       VALUES (NOW(), $1, $2)`,
      [meterId, totalM3]
    );
    stats.successCount++;
  } catch (err) {
    log('ERROR', `[${meterId}] 讀取失敗: ${err.message}`);
    stats.errorCount++;
  }
}

// ── 蒸氣錶：原本 5 次讀取 → 現在 1 次 ──────────────────────
// 注意：蒸氣錶原本全部欄位都是用 CDAB 解碼，這裡沿用同樣的 byteOrder
async function readSteamMeter(client, slaveId, meterId) {
  client.setID(slaveId);
  try {
    const result = await client.readHoldingRegisters(
      REGISTER_S_BLOCK.address,
      REGISTER_S_BLOCK.count
    );
    const data = result.data;

    const temperature = floatAt(data, REGISTER_S_OFFSETS.TEMPERATURE, 'CDAB');
    const pressure    = floatAt(data, REGISTER_S_OFFSETS.PRESSURE, 'CDAB');
    const flowRate    = floatAt(data, REGISTER_S_OFFSETS.FLOW_RATE, 'CDAB');
    const total100    = floatAt(data, REGISTER_S_OFFSETS.TOTAL_100, 'CDAB');
    const total10     = floatAt(data, REGISTER_S_OFFSETS.TOTAL_10, 'CDAB');
    const totalFlow = total100 * 100 + total10 * 10; // 保留原邏輯，目前未寫入 DB

    if (!isValidFloat(temperature) || !isValidFloat(pressure) || !isValidFloat(flowRate)) {
      log('WARN', `[${meterId}] 異常數值被過濾: temp=${temperature}, press=${pressure}, flow=${flowRate}`);
      stats.errorCount++;
      return;
    }

    log('INFO', `[${meterId}] flow: ${flowRate.toFixed(2)} kg/h, temp: ${temperature.toFixed(1)}°C, press: ${pressure.toFixed(3)} bar`);

    await pool.query(
      `INSERT INTO realtime_steam (time, meter_id, flow_rate_kgh, pressure_bar, temperature_c)
       VALUES (NOW(), $1, $2, $3, $4)`,
      [meterId, flowRate, pressure, temperature]
    );
    stats.successCount++;
  } catch (err) {
    log('ERROR', `[${meterId}] 讀取失敗: ${err.message}`);
    stats.errorCount++;
  }
}

// ── Gateway 輪詢 ──────────────────────────────────
async function pollGateway(gateway, readFn) {
  const client = new ModbusRTU();
  let connected = false;
  let errorMsg = null;

  try {
    await client.connectTCP(gateway.host, { port: gateway.port, timeout: 1500 });
    client.setTimeout(1500);
    connected = true;
    log('INFO', `✓ 連線成功: ${gateway.name}`);
    for (const meter of gateway.meters) {
      await readFn(client, meter.slaveId, meter.meterId);
    }
  } catch (err) {
    errorMsg = err.message;
    log('WARN', `✗ Gateway 連線失敗: ${gateway.name} — ${err.message}`);
    stats.gatewayErrors[gateway.name] = (stats.gatewayErrors[gateway.name] || 0) + 1;
  } finally {
    // ★ 寫入連線狀態（失敗不影響採集主流程）
    try {
      await pool.query(gatewayStatusQuery, [gateway.name, 'modbus', connected, errorMsg]);
    } catch (dbErr) {
      log('ERROR', `寫入 gateway_connection_status 失敗: ${dbErr.message}`);
    }

    // ★ 原本的 socket 清理邏輯，維持不變
    try {
      const sock = client._port?._client;
      if (sock && !sock.destroyed) sock.destroy();
    } catch (_) {}
    await new Promise((resolve) => {
      try { client.close(resolve); } catch { resolve(); }
    });
  }
}

// ── 每日統計報告 ──────────────────────────────────
function printDailyStats() {
  log('STATS', '=== 每日採集統計 ===');
  log('STATS', `總採集輪次: ${stats.totalPolls}`);
  log('STATS', `成功筆數: ${stats.successCount}`);
  log('STATS', `失敗筆數: ${stats.errorCount}`);
  log('STATS', `跳過輪次: ${stats.skippedCount}`);
  if (Object.keys(stats.gatewayErrors).length > 0) {
    log('STATS', 'Gateway 失敗統計:');
    for (const [gw, count] of Object.entries(stats.gatewayErrors)) {
      log('STATS', `  ${gw}: ${count} 次`);
    }
  }
  stats.totalPolls = 0;
  stats.successCount = 0;
  stats.errorCount = 0;
  stats.skippedCount = 0;
  stats.gatewayErrors = {};
}

// ── 主迴圈 ────────────────────────────────────────
// ★ 整輪超時：55 秒（比 setInterval 60s 留 5 秒緩衝）
const POLL_TIMEOUT_MS = 8 * 1000;    // 10 秒一輪，留 2 秒緩衝

async function startCollector() {
  log('INFO', '=== ECI Modbus 採集程式啟動 ===');

  let isPolling = false;

  const poll = async () => {
    if (isPolling) {
      log('WARN', '上一輪採集尚未完成，跳過本次');
      stats.skippedCount++;
      return;
    }

    isPolling = true;
    stats.totalPolls++;

    // ★ 本輪起訖用的量測基準點
    const roundStart = Date.now();
    const successBefore = stats.successCount;
    const errorBefore = stats.errorCount;

    const collectAll = async () => {
      log('INFO', `開始第 ${stats.totalPolls} 輪採集...`);
      for (const gw of GATEWAYS_ELECTRICITY) await pollGateway(gw, readElecMeter);
      for (const gw of GATEWAYS_WATER)       await pollGateway(gw, readWaterMeter);
      for (const gw of GATEWAYS_STEAM)       await pollGateway(gw, readSteamMeter);
      log('INFO', '採集完成');
    };

    try {
      await Promise.race([
        collectAll(),
        new Promise((_, reject) =>
          setTimeout(() => reject(new Error(`整輪採集超時 (${POLL_TIMEOUT_MS / 1000}s)`)), POLL_TIMEOUT_MS)
        ),
      ]);
    } catch (err) {
      log('ERROR', `採集主迴圈異常: ${err.message}`);
    } finally {
      isPolling = false;

      // ★ 寫入本輪 heartbeat
      const roundDuration = Date.now() - roundStart;
      const roundSuccess = stats.successCount - successBefore;
      const roundError = stats.errorCount - errorBefore;
      try {
        await pool.query(heartbeatQuery, [roundDuration, roundSuccess, roundError]);
      } catch (dbErr) {
        log('ERROR', `寫入 collector_heartbeat 失敗: ${dbErr.message}`);
      }
    }
  };

  await poll();
  setInterval(poll, 10 * 1000);

  // 每天 00:00 印出統計報告
  const now = new Date();
  const midnight = new Date(now);
  midnight.setHours(24, 0, 0, 0);
  const msToMidnight = midnight - now;

  setTimeout(() => {
    printDailyStats();
    setInterval(printDailyStats, 24 * 60 * 60 * 1000);
  }, msToMidnight);
}

// ── 未捕獲的例外處理 ─────────────────────────────
process.on('uncaughtException', (err) => {
  log('FATAL', `未捕獲的例外: ${err.message}\n${err.stack}`);
});

process.on('unhandledRejection', (reason, promise) => {
  // ECONNRESET 是 modbus-serial close() 的正常殘留，過濾掉
  if (reason?.message?.includes('ECONNRESET')) return;
  log('FATAL', `未處理的 Promise 拒絕: ${reason}`);
});

startCollector().catch((err) => {
  log('FATAL', `啟動失敗: ${err.message}`);
  process.exit(1);
});