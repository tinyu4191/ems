require('dotenv').config({ path: __dirname + '/.env' });

const REGISTER_E = {
  VOLTAGE:      { address: 40263 - 40001, count: 2 },
  CURRENT:      { address: 40295 - 40001, count: 2 },
  POWER_FACTOR: { address: 40307 - 40001, count: 2 },
  ACTIVE_POWER: { address: 40325 - 40001, count: 2 },
  ENERGY_KWH:   { address: 40349 - 40001, count: 2 },
};

const REGISTER_W = {
  FLOW_RATE:      { address: 40099 - 40001, count: 2 }, 
  TOTAL_FLOW_FWD: { address: 40091 - 40001, count: 2 }, 
  TOTAL_FLOW_REV: { address: 40093 - 40001, count: 2 }, 
};

const REGISTER_S = {
  TEMPERATURE: { address: 40001 - 40001, count: 2 },
  PRESSURE:    { address: 40003 - 40001, count: 2 },
  FLOW_RATE:   { address: 40007 - 40001, count: 2 },
  TOTAL_100:   { address: 40009 - 40001, count: 2 },
  TOTAL_10:    { address: 40011 - 40001, count: 2 },
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
  REGISTER_E, REGISTER_W, REGISTER_S,
  GATEWAYS_ELECTRICITY, GATEWAYS_WATER, GATEWAYS_STEAM,
};