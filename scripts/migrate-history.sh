#!/usr/bin/env bash
# migrate-history.sh
#
# 把 ems-dev 在「ems-v2 開始收資料之前」的歷史資料搬進 ems-v2，
# 避免跟 v2 現有資料在重疊時間段裡重複。
#
# 策略：對每張表，抓 v2 該表的 min(time) 當切點，只搬 ems-dev 裡
# time < 切點 的資料。
#
# 執行前建議先備份 v2 現有資料庫（見腳本最後的提醒）。

set -euo pipefail

DEV_CONTAINER=ems-timescaledb
DEV_USER=admin
DEV_DB=ems

V2_CONTAINER=ems-v2-timescaledb
V2_USER=admin
V2_DB=ems

TABLES=(realtime_electricity realtime_water realtime_steam accumulator_electricity accumulator_water collector_heartbeat gateway_connection_status)

mkdir -p /tmp/ems-migrate

for T in "${TABLES[@]}"; do
  echo "=== $T ==="

  CUTOFF=$(docker exec "$V2_CONTAINER" psql -U "$V2_USER" -d "$V2_DB" -t -A -c "SELECT min(time) FROM $T;")
  if [ -z "$CUTOFF" ]; then
    echo "  v2 這張表還沒有資料，無法自動判斷切點，略過，請人工確認要不要整表搬"
    continue
  fi
  echo "  cutoff (v2 min time) = $CUTOFF"

  OUT="/tmp/ems-migrate/${T}.csv"

  if [ "$T" = "realtime_electricity" ]; then
    # dev 多一個 可補筆數 欄位，v2 沒有，明確指定欄位清單排除它
    docker exec "$DEV_CONTAINER" psql -U "$DEV_USER" -d "$DEV_DB" -c \
      "\copy (SELECT time, meter_id, power_kw, voltage, current_a, power_factor FROM realtime_electricity WHERE time < '${CUTOFF}') TO STDOUT" \
      > "$OUT"
  else
    docker exec "$DEV_CONTAINER" psql -U "$DEV_USER" -d "$DEV_DB" -c \
      "\copy (SELECT * FROM ${T} WHERE time < '${CUTOFF}') TO STDOUT" \
      > "$OUT"
  fi

  ROWS=$(wc -l < "$OUT")
  echo "  抓出 ${ROWS} 筆，寫入 v2..."

  if [ "$ROWS" -eq 0 ]; then
    echo "  這張表沒有需要搬的資料（切點以前沒資料），略過寫入"
    continue
  fi

  if [ "$T" = "realtime_electricity" ]; then
    docker exec -i "$V2_CONTAINER" psql -U "$V2_USER" -d "$V2_DB" -c \
      "\copy realtime_electricity (time, meter_id, power_kw, voltage, current_a, power_factor) FROM STDIN" \
      < "$OUT"
  else
    docker exec -i "$V2_CONTAINER" psql -U "$V2_USER" -d "$V2_DB" -c \
      "\copy ${T} FROM STDIN" \
      < "$OUT"
  fi

  echo "  done."
  echo
done

echo "全部完成。建議跑下面這行驗證 v2 每張表的 min(time) 有沒有往前延伸到 dev 的歷史範圍："
echo
for T in "${TABLES[@]}"; do
  echo "  docker exec ${V2_CONTAINER} psql -U ${V2_USER} -d ${V2_DB} -c \"SELECT min(time), max(time), count(*) FROM ${T};\""
done