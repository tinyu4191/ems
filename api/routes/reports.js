// routes/reports.js
import ExcelJS from 'exceljs';

// 顯示名稱例外：zone 欄位原值 → 報表要顯示的分類名稱
// 目前只有 ATS-1/ATS-2 需要轉換，其餘分類直接使用 meters.zone 的值
const CATEGORY_DISPLAY_OVERRIDE = {
  'ATS1配電站': 'ATS-1',
  'ATS2配電站': 'ATS-2',
};

const ACCUMULATOR_CONFIG = {
  electricity: {
    table: 'accumulator_electricity',
    valueColumn: 'total_kwh',
    unit: 'kWh',
  },
  water: {
    table: 'accumulator_water',
    valueColumn: 'total_m3',
    unit: 'm³',
  },
};

function displayCategory(zone) {
  return CATEGORY_DISPLAY_OVERRIDE[zone] || zone;
}

// 依查詢區間長度決定顆粒度：< 3 天用小時、>= 3 天用日
function decideBucket(fromDate, toExclusiveDate) {
  const msPerDay = 24 * 60 * 60 * 1000;
  const dayCount = Math.round((toExclusiveDate - fromDate) / msPerDay);
  return dayCount < 3
    ? { interval: '1 hour', jsStepMs: 60 * 60 * 1000, label: 'hour' }
    : { interval: '1 day', jsStepMs: 24 * 60 * 60 * 1000, label: 'day' };
}

function formatBucketLabel(date, bucketLabel) {
  const pad = (n) => String(n).padStart(2, '0');
  // 明確用越南時區（UTC+7）計算，不依賴容器本身的系統時區設定
  const shifted = new Date(date.getTime() + 7 * 60 * 60 * 1000);
  const y = shifted.getUTCFullYear();
  const m = pad(shifted.getUTCMonth() + 1);
  const d = pad(shifted.getUTCDate());
  if (bucketLabel === 'day') return `${y}-${m}-${d}`;
  const h = pad(shifted.getUTCHours());
  return `${y}-${m}-${d} ${h}:00`;
}

function generateBuckets(fromDate, toExclusiveDate, stepMs) {
  const buckets = [];
  let cursor = new Date(fromDate);
  while (cursor < toExclusiveDate) {
    buckets.push(new Date(cursor));
    cursor = new Date(cursor.getTime() + stepMs);
  }
  return buckets;
}

// 共用邏輯：驗證參數、查資料庫、整理成 { buckets, zoneOrder, metersByZone, valueMap, bucket, config }
// xlsx 匯出跟 JSON 預覽都吃這份整理好的資料，確保兩邊數字保證一致
async function loadReportData(fastify, { energyType, from, to, categories }) {
  if (!['electricity', 'water'].includes(energyType)) {
    return { error: { code: 400, message: 'energyType 必須是 electricity 或 water' } };
  }
  if (!from || !to || !/^\d{4}-\d{2}-\d{2}$/.test(from) || !/^\d{4}-\d{2}-\d{2}$/.test(to)) {
    return { error: { code: 400, message: 'from/to 需為 YYYY-MM-DD 格式' } };
  }

  const fromDate = new Date(`${from}T00:00:00+07:00`);
  const toExclusiveDate = new Date(`${to}T00:00:00+07:00`);
  toExclusiveDate.setDate(toExclusiveDate.getDate() + 1);

  if (toExclusiveDate <= fromDate) {
    return { error: { code: 400, message: 'to 必須晚於或等於 from' } };
  }

  const bucket = decideBucket(fromDate, toExclusiveDate);
  const config = ACCUMULATOR_CONFIG[energyType];

  const meterListResult = await fastify.pg.query(
    `SELECT meter_id, zone, description FROM meters WHERE meter_type = $1 ORDER BY zone, meter_id`,
    [energyType]
  );
  const allMeters = meterListResult.rows;

  if (allMeters.length === 0) {
    return { error: { code: 404, message: `找不到 meter_type = ${energyType} 的電表資料` } };
  }

  let selectedZones;
  if (!categories || categories === 'all') {
    selectedZones = [...new Set(allMeters.map((m) => m.zone))];
  } else {
    const requestedDisplay = categories.split(',').map((c) => c.trim());
    const zoneByDisplay = {};
    allMeters.forEach((m) => {
      zoneByDisplay[displayCategory(m.zone)] = m.zone;
    });
    selectedZones = requestedDisplay.map((d) => zoneByDisplay[d]).filter(Boolean);
  }

  if (selectedZones.length === 0) {
    return { error: { code: 400, message: '沒有符合的分類，請確認 categories 參數' } };
  }

  const meters = allMeters.filter((m) => selectedZones.includes(m.zone));

  const sql = `
    SELECT
      time_bucket($1::interval, r.time, 'Asia/Ho_Chi_Minh') AS bucket,
      r.meter_id,
      MAX(r.${config.valueColumn}) - MIN(r.${config.valueColumn}) AS value
    FROM ${config.table} r
    WHERE r.time >= $2 AND r.time < $3
      AND r.meter_id = ANY($4)
    GROUP BY bucket, r.meter_id
    ORDER BY bucket, r.meter_id
  `;
  const meterIds = meters.map((m) => m.meter_id);
  const dataResult = await fastify.pg.query(sql, [
    bucket.interval,
    fromDate.toISOString(),
    toExclusiveDate.toISOString(),
    meterIds,
  ]);

  const valueMap = {};
  dataResult.rows.forEach((row) => {
    const key = new Date(row.bucket).toISOString();
    if (!valueMap[key]) valueMap[key] = {};
    valueMap[key][row.meter_id] = parseFloat(row.value);
  });

  const buckets = generateBuckets(fromDate, toExclusiveDate, bucket.jsStepMs);

  const metersByZone = {};
  meters.forEach((m) => {
    if (!metersByZone[m.zone]) metersByZone[m.zone] = [];
    metersByZone[m.zone].push(m);
  });
  const zoneOrder = Object.keys(metersByZone).sort((a, b) =>
    displayCategory(a).localeCompare(displayCategory(b), 'zh-Hant')
  );

  return { buckets, zoneOrder, metersByZone, valueMap, bucket, config, from, to };
}

// 計算 rows 陣列中某個 key 欄位的加總，只加總數字型的值，忽略 '' / undefined
// 若該欄位完全沒有數值（例如整段區間都沒資料），回傳 ''，維持跟其他欄位一致的呈現方式
function sumColumn(rows, key) {
  let sum = null;
  rows.forEach((row) => {
    const v = row[key];
    if (typeof v === 'number') sum = (sum ?? 0) + v;
  });
  return sum === null ? '' : Math.round(sum * 100) / 100;
}

// 在 rows 的最後加上一列「總計」，每個 key 都往下加總；time 欄位固定顯示「總計」
function buildTotalRow(rows, keys) {
  const totalRow = { time: '總計' };
  keys.forEach((key) => {
    totalRow[key] = sumColumn(rows, key);
  });
  return totalRow;
}

export function registerReportsRoute(fastify) {
  // ---- 分類清單（給前端畫勾選框用）----
  fastify.get('/api/reports/categories', async (request, reply) => {
    const { energyType } = request.query;
    if (!['electricity', 'water'].includes(energyType)) {
      return reply.code(400).send({ error: 'energyType 必須是 electricity 或 water' });
    }
    const result = await fastify.pg.query(
      `SELECT zone, COUNT(*) AS meter_count FROM meters WHERE meter_type = $1 GROUP BY zone ORDER BY zone`,
      [energyType]
    );
    const categories = result.rows
      .map((r) => ({ value: displayCategory(r.zone), meterCount: parseInt(r.meter_count, 10) }))
      .sort((a, b) => a.value.localeCompare(b.value, 'zh-Hant'));
    reply.send({ categories });
  });

  // ---- 報表主端點：預設回傳 xlsx；帶 format=json 回傳畫面預覽用的結構化資料 ----
  fastify.get('/api/reports/energy', async (request, reply) => {
    const { energyType, from, to, categories, format } = request.query;
    const data = await loadReportData(fastify, { energyType, from, to, categories });

    if (data.error) {
      return reply.code(data.error.code).send({ error: data.error.message });
    }

    const { buckets, zoneOrder, metersByZone, valueMap, bucket, config } = data;

    if (format === 'json') {
      const overview = buckets.map((bucketDate) => {
        const key = bucketDate.toISOString();
        const row = { time: formatBucketLabel(bucketDate, bucket.label) };
        zoneOrder.forEach((zone) => {
          let sum = null;
          metersByZone[zone].forEach((m) => {
            const v = valueMap[key]?.[m.meter_id];
            if (v !== undefined) sum = (sum ?? 0) + v;
          });
          row[displayCategory(zone)] = sum === null ? null : Math.round(sum * 100) / 100;
        });
        return row;
      });

      return reply.send({
        energyType,
        from,
        to,
        granularity: bucket.label,
        unit: config.unit,
        categories: zoneOrder.map(displayCategory),
        overview,
      });
    }

    // ---- xlsx 匯出 ----
    const workbook = new ExcelJS.Workbook();
    workbook.creator = 'Tectiiko EMS';
    workbook.created = new Date();

    const overviewSheet = workbook.addWorksheet('Overview');
    overviewSheet.columns = [
      { header: '時間', key: 'time', width: 18 },
      ...zoneOrder.map((zone) => ({
        header: `${displayCategory(zone)} (${config.unit})`,
        key: zone,
        width: 16,
      })),
    ];
    overviewSheet.getRow(1).font = { bold: true };

    const overviewRows = buckets.map((bucketDate) => {
      const key = bucketDate.toISOString();
      const row = { time: formatBucketLabel(bucketDate, bucket.label) };
      zoneOrder.forEach((zone) => {
        let sum = null;
        metersByZone[zone].forEach((m) => {
          const v = valueMap[key]?.[m.meter_id];
          if (v !== undefined) sum = (sum ?? 0) + v;
        });
        row[zone] = sum === null ? '' : Math.round(sum * 100) / 100;
      });
      return row;
    });
    overviewRows.forEach((row) => overviewSheet.addRow(row));

    const overviewTotalRow = overviewSheet.addRow(buildTotalRow(overviewRows, zoneOrder));
    overviewTotalRow.font = { bold: true };

    zoneOrder.forEach((zone) => {
      const metersInZone = metersByZone[zone];
      const sheetName = displayCategory(zone).slice(0, 31);
      const sheet = workbook.addWorksheet(sheetName);
      sheet.columns = [
        { header: '時間', key: 'time', width: 18 },
        ...metersInZone.map((m) => ({
          header: `${m.description} (${config.unit})`,
          key: m.meter_id,
          width: 18,
        })),
      ];
      sheet.getRow(1).font = { bold: true };

      const zoneRows = buckets.map((bucketDate) => {
        const key = bucketDate.toISOString();
        const row = { time: formatBucketLabel(bucketDate, bucket.label) };
        metersInZone.forEach((m) => {
          const v = valueMap[key]?.[m.meter_id];
          row[m.meter_id] = v === undefined ? '' : Math.round(v * 100) / 100;
        });
        return row;
      });
      zoneRows.forEach((row) => sheet.addRow(row));

      const zoneMeterIds = metersInZone.map((m) => m.meter_id);
      const zoneTotalRow = sheet.addRow(buildTotalRow(zoneRows, zoneMeterIds));
      zoneTotalRow.font = { bold: true };
    });

    const buf = await workbook.xlsx.writeBuffer();
    const energyLabel = energyType === 'electricity' ? '電力' : '水';
    const filename = `ECI${energyLabel}用量報表_${from}_${to}.xlsx`;

    reply
      .header('Content-Type', 'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet')
      .header('Content-Disposition', `attachment; filename*=UTF-8''${encodeURIComponent(filename)}`)
      .send(buf);
  });
}