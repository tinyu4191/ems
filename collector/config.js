require('dotenv').config({ path: __dirname + '/.env' });

// ── 電錶：40263 ~ 40350，共 88 個暫存器，一次讀完 ──────────
const REGISTER_E_BLOCK = { address: 40263 - 40001, count: 88 };
const REGISTER_E_OFFSETS = {
  VOLTAGE:      0,   // 40263
  CURRENT:      32,  // 40295
  POWER_FACTOR: 44,  // 40307
  ACTIVE_POWER: 62,  // 40325
  ENERGY_KWH:   86,  // 40349
};

// ── 水錶：40091 ~ 40100，共 10 個暫存器，一次讀完 ──────────
// （涵蓋 TOTAL_FLOW_FWD 40091 與 FLOW_RATE 40099；
//   TOTAL_FLOW_REV 40093 目前沒在用，但已經包含在區塊內）
const REGISTER_W_BLOCK = { address: 40091 - 40001, count: 10 };
const REGISTER_W_OFFSETS = {
  TOTAL_FLOW_FWD: 0,  // 40091
  TOTAL_FLOW_REV: 2,  // 40093（保留，目前未使用）
  FLOW_RATE:      8,  // 40099
};

// ── 蒸氣錶：40001 ~ 40012，共 12 個暫存器，一次讀完 ────────
const REGISTER_S_BLOCK = { address: 40001 - 40001, count: 12 };
const REGISTER_S_OFFSETS = {
  TEMPERATURE: 0,   // 40001
  PRESSURE:    2,   // 40003
  FLOW_RATE:   6,   // 40007
  TOTAL_100:   8,   // 40009
  TOTAL_10:    10,  // 40011
};

const e = process.env;

const GATEWAYS_ELECTRICITY = [
  {
    name: 'OTPanel_01.1', host: e.GW_01_HOST, port: parseInt(e.GW_01_PORT),
    meters: [
      { slaveId: 1, meterId: 'E-FIBAC', desc: '織造冷氣' },
      { slaveId: 2, meterId: 'E-WH',    desc: '原料倉' },
      { slaveId: 3, meterId: 'E-OFF',   desc: '辦公室' },
      { slaveId: 4, meterId: 'E-CRANE', desc: '天車' },
      { slaveId: 5, meterId: 'E-PRINT', desc: '網印' },
      { slaveId: 6, meterId: 'E-EXH1',  desc: '染整區抽風扇' },
      { slaveId: 7, meterId: 'E-ELV2',  desc: '纖造電梯2' },
      { slaveId: 8, meterId: 'E-SEC',   desc: '保衛室' },
      { slaveId: 9, meterId: 'E-EXH2',  desc: '電站1抽風扇' },
    ],
  },
  {
    name: 'OTPanel_01.2', host: e.GW_02_HOST, port: parseInt(e.GW_02_PORT),
    meters: [
      { slaveId: 1, meterId: 'E-ATS1', desc: 'ATS1市電進線' },
      { slaveId: 2, meterId: 'E-PRO1', desc: '加工+電梯1' },
      { slaveId: 3, meterId: 'E-DYE3', desc: '連染' },
      { slaveId: 4, meterId: 'E-FIB1', desc: '纖造' },
      { slaveId: 5, meterId: 'E-AIR',  desc: '空壓機' },
    ],
  },
  {
    name: 'OTPanel_02.1', host: e.GW_03_HOST, port: parseInt(e.GW_03_PORT),
    meters: [
      { slaveId: 1, meterId: 'E-WASTE', desc: '廢水處理+食堂+軟水' },
      { slaveId: 2, meterId: 'E-QAHB',  desc: '品保+熱縮' },
      { slaveId: 3, meterId: 'E-FIRE',  desc: '消防系統' },
      { slaveId: 4, meterId: 'E-RSV1',  desc: '預留迴路1' },
      { slaveId: 5, meterId: 'E-RSV2',  desc: '預留迴路2' },
      { slaveId: 6, meterId: 'E-SOC2',  desc: '電站2插座' },
      { slaveId: 7, meterId: 'E-ELV3',  desc: '電梯3' },
    ],
  },
  {
    name: 'OTPanel_02.2', host: e.GW_04_HOST, port: parseInt(e.GW_04_PORT),
    meters: [
      { slaveId: 1, meterId: 'E-BOIL', desc: '鍋爐' },
      { slaveId: 2, meterId: 'E-RSV3', desc: '預留迴路3' },
      { slaveId: 3, meterId: 'E-DYE1', desc: '浸染區+化料+染料' },
      { slaveId: 4, meterId: 'E-DYE2', desc: '浸染+滴定' },
      { slaveId: 5, meterId: 'E-ATS2', desc: 'ATS2市電進線' },
    ],
  },
];

const GATEWAYS_WATER = [
  {
    name: 'OTPanel_03.2', host: e.GW_05_HOST, port: parseInt(e.GW_05_PORT),
    meters: [
      { slaveId: 1, meterId: 'W-DYE1', desc: '染紗區入水口' },
      { slaveId: 2, meterId: 'W-DYE2', desc: '連染區入水口' },
    ],
  },
  {
    name: 'OTPanel_04', host: e.GW_06_HOST, port: parseInt(e.GW_06_PORT),
    meters: [
      { slaveId: 1, meterId: 'W-IN2', desc: '管水系統進水口2' },
    ],
  },
  {
    name: 'OTPanel_05', host: e.GW_07_HOST, port: parseInt(e.GW_07_PORT),
    meters: [
      { slaveId: 1, meterId: 'W-IN1', desc: '管水系統進水口1' },
    ],
  },
];

const GATEWAYS_STEAM = [
  {
    name: 'OTPanel_03.1', host: e.GW_08_HOST, port: parseInt(e.GW_08_PORT),
    meters: [
      { slaveId: 1, meterId: 'S-DYE1', desc: '染紗區蒸氣' },
      { slaveId: 2, meterId: 'S-BOIL', desc: '鍋爐蒸氣' },
      { slaveId: 3, meterId: 'S-DYE2', desc: '連染區蒸氣' },
    ],
  },
];

module.exports = {
  REGISTER_E_BLOCK, REGISTER_E_OFFSETS,
  REGISTER_W_BLOCK, REGISTER_W_OFFSETS,
  REGISTER_S_BLOCK, REGISTER_S_OFFSETS,
  GATEWAYS_ELECTRICITY, GATEWAYS_WATER, GATEWAYS_STEAM,
};