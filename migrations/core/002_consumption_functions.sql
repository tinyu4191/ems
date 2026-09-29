-- =============================================
-- core/002_consumption_functions.sql
--
-- A2：用量計算的單一來源，取代散落在各 dashboard 裡各自寫的「每桶 MAX(total)-MIN(total)」。
--
-- 問題：分桶後逐桶 MAX-MIN，斷線期間的用量會完全消失，不屬於任何一個桶。
-- 已用合成資料驗證：6 小時內斷線 90 分鐘，真實用量 60kWh，
--   舊算法（逐小時 MAX-MIN 加總）= 44.86（少 25%）
--   新算法（本檔）             = 60（完全正確）
--
-- 做法：不用「這一桶自己的 MAX-MIN」，改成「這一桶最後一筆的值，減掉上一桶最後一筆的值」。
--   任何時候的累計差都連續，斷線只會讓某一桶的漲幅看起來大一點（恢復時一次補上），
--   但總量永遠正確，不會憑空消失。
--
-- 使用方式：
--   SELECT * FROM consumption_kwh('2026-09-01', '2026-10-01', interval '1 day', 'Asia/Ho_Chi_Minh');
--   → 回傳 (bucket, meter_id, kwh)，每個 meter_id 每個時間桶一列。
--   water 版本是 consumption_m3，參數與回傳形狀相同（欄位叫 m3）。
--
-- 注意事項（SQL 寫法上的坑，這裡刻意避開）：
--   WHERE 篩選查詢範圍「不可以」跟計算 LAG() 放在同一層 SELECT，
--   否則 PostgreSQL 會先套用 WHERE 篩掉基準桶，才計算 LAG，導致第一個桶的差值變成 NULL。
--   必須先在內層算完 LAG（涵蓋範圍起點前一桶當基準），再用外層 WHERE 篩選要回傳的範圍。
-- =============================================

CREATE OR REPLACE FUNCTION consumption_kwh(
  p_from   timestamptz,
  p_to     timestamptz,
  p_bucket interval,
  p_tz     text DEFAULT 'Asia/Ho_Chi_Minh'
)
RETURNS TABLE (bucket timestamptz, meter_id text, kwh double precision)
LANGUAGE sql STABLE AS $$
  WITH h AS (
    SELECT
      time_bucket(p_bucket, a.time, p_tz) AS bucket,
      a.meter_id,
      last(a.total_kwh, a.time) AS v
    FROM accumulator_electricity a
    -- 往前多抓一桶當基準（range 起點前那一桶的最後一筆值），否則第一桶無從比較
    WHERE a.time >= p_from - p_bucket AND a.time < p_to
    GROUP BY 1, 2
  ), d AS (
    SELECT
      bucket, meter_id,
      GREATEST(v - lag(v) OVER (PARTITION BY meter_id ORDER BY bucket), 0) AS kwh
    FROM h
  )
  -- 篩選放在最外層：LAG 必須算完（涵蓋基準桶）才能篩，不能提前篩掉基準桶
  SELECT bucket, meter_id, kwh
  FROM d
  WHERE bucket >= time_bucket(p_bucket, p_from, p_tz);
$$;

CREATE OR REPLACE FUNCTION consumption_m3(
  p_from   timestamptz,
  p_to     timestamptz,
  p_bucket interval,
  p_tz     text DEFAULT 'Asia/Ho_Chi_Minh'
)
RETURNS TABLE (bucket timestamptz, meter_id text, m3 double precision)
LANGUAGE sql STABLE AS $$
  WITH h AS (
    SELECT
      time_bucket(p_bucket, a.time, p_tz) AS bucket,
      a.meter_id,
      last(a.total_m3, a.time) AS v
    FROM accumulator_water a
    WHERE a.time >= p_from - p_bucket AND a.time < p_to
    GROUP BY 1, 2
  ), d AS (
    SELECT
      bucket, meter_id,
      GREATEST(v - lag(v) OVER (PARTITION BY meter_id ORDER BY bucket), 0) AS m3
    FROM h
  )
  SELECT bucket, meter_id, m3
  FROM d
  WHERE bucket >= time_bucket(p_bucket, p_from, p_tz);
$$;
