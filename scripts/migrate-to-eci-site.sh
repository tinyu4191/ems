#!/usr/bin/env bash
# migrate-to-eci-site.sh
#
# 把本地 ems 的歷史資料（現場站開始收資料之前的部分）直接透過網路
# 串流送到 ECI 現場站，中間不落地任何檔案。
#
# 前提：現場站的 5433 port 已透過 netsh portproxy + 防火牆對外開放，
# 且已經跑過 pg_dump 備份現場站現有資料。

set -euo pipefail

LOCAL_CONTAINER=ems-timescaledb
LOCAL_USER=admin
LOCAL_DB=ems

SITE_HOST=10.14.118.87
SITE_PORT=5433
SITE_USER=admin
SITE_DB=ems

# 每張表各自的切點，取自現場站 min(time)（08-11 查到的結果）
declare -A CUTOFFS=(
  [realtime_electricity]="2026-07-31 05:08:07.638394+00"
  [realtime_water]="2026-07-31 05:07:09.122547+00"
  [realtime_steam]="2026-07-31 05:07:09.484575+00"
  [accumulator_electricity]="2026-07-31 05:08:07.664887+00"
  [accumulator_water]="2026-07-31 05:07:09.147058+00"
  [collector_heartbeat]="2026-07-31 07:16:38.610155+00"
  [gateway_connection_status]="2026-07-31 07:16:37.495826+00"
)

export PGPASSWORD_SITE="${SITE_DB_PASS:?請先 export SITE_DB_PASS=<現場admin密碼>}"

for T in "${!CUTOFFS[@]}"; do
  CUTOFF="${CUTOFFS[$T]}"
  echo "=== $T (cutoff: $CUTOFF) ==="

  # 用 docker exec 從本地容器讀出資料，直接 pipe 給遠端 psql 寫入
  # 這裡不落地任何暫存檔案，資料在記憶體/網路 buffer 中流動
  docker exec "$LOCAL_CONTAINER" psql -U "$LOCAL_USER" -d "$LOCAL_DB" -c \
    "\copy (SELECT * FROM ${T} WHERE time < '${CUTOFF}') TO STDOUT" \
  | PGPASSWORD="$PGPASSWORD_SITE" psql -h "$SITE_HOST" -p "$SITE_PORT" -U "$SITE_USER" -d "$SITE_DB" -c \
    "\copy ${T} FROM STDIN"

  echo "  done."
  echo
done

echo "全部完成，建議跑下面這行到現場站驗證每張表的 min(time)："
echo
for T in "${!CUTOFFS[@]}"; do
  echo "  PGPASSWORD=\$SITE_DB_PASS psql -h ${SITE_HOST} -p ${SITE_PORT} -U ${SITE_USER} -d ${SITE_DB} -c \"SELECT min(time), max(time), count(*) FROM ${T};\""
done