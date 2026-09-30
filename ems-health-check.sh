#!/usr/bin/env bash
# EMS 現場健康檢查腳本
# 用法: cd ~/ems && bash ems-health-check.sh
# 用法(查特定日期範圍的 collector log): bash ems-health-check.sh --since 2026-08-18T00:00:00 --until 2026-08-20T00:00:00

set -uo pipefail

SINCE=""
UNTIL=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --since) SINCE="$2"; shift 2 ;;
    --until) UNTIL="$2"; shift 2 ;;
    *) shift ;;
  esac
done

# 讀取 .env 取得 DB 帳密（若存在）
# 注意：這裡讀的是 DB_USER/DB_NAME，跟 migrate.sh / backup.sh / verify-baseline.sh /
# deploy-site.sh 用的是同一組變數名稱（.env 裡實際存在的是這兩個，不是
# POSTGRES_USER/POSTGRES_DB —— 這支腳本原本讀的是後者，.env 裡沒有這兩個變數，
# 一直是靠 postgres 官方 image 內建的 postgres 超級使用者這個巧合在運作，
# 不是真的有讀到設定值；這裡順手對齊成跟其他腳本一致的讀法）。
if [[ -f .env ]]; then
  set -a
  source .env
  set +a
fi
PGUSER_="${DB_USER:-admin}"
PGDB_="${DB_NAME:-ems}"
DB_CONTAINER="${DB_CONTAINER:-ems-timescaledb}"

sep() { echo; echo "===== $1 ====="; }

sep "1. Docker Daemon 狀態"
systemctl is-active docker 2>/dev/null || echo "⚠ docker daemon 未啟動"

sep "2. 容器狀態"
docker ps -a --format 'table {{.Names}}\t{{.Status}}\t{{.RunningFor}}'

sep "3. 容器 Restart 次數（若 =0 但資料有斷點，代表問題出在容器內部程式，不是容器被重啟）"
for c in "$DB_CONTAINER" ems-grafana ems-collector ems-nginx; do
  rc=$(docker inspect --format='{{.RestartCount}}' "$c" 2>/dev/null || echo "N/A")
  started=$(docker inspect --format='{{.State.StartedAt}}' "$c" 2>/dev/null || echo "N/A")
  echo "$c: RestartCount=$rc, StartedAt=$started"
done

sep "4. Volumes"
docker volume ls | grep -i ems || echo "找不到 ems 相關 volume"

sep "5. 磁碟空間（滿了會導致 DB 寫入失敗）"
df -h / /var/lib/docker 2>/dev/null

sep "6. 各資料表最新時間戳（找出實際斷點在哪一張表）"
docker exec "$DB_CONTAINER" psql -U "$PGUSER_" -d "$PGDB_" -c "
SELECT 'realtime_electricity' AS table_name, MAX(time) AS latest, COUNT(*) AS rows FROM realtime_electricity
UNION ALL
SELECT 'realtime_water', MAX(time), COUNT(*) FROM realtime_water
UNION ALL
SELECT 'realtime_steam', MAX(time), COUNT(*) FROM realtime_steam;
" 2>&1

sep "7. Collector 最近 50 行 log"
docker logs --tail 50 ems-collector 2>&1

sep "8. Collector log 中的錯誤關鍵字（最近 500 行）"
docker logs --tail 500 ems-collector 2>&1 | grep -iE "error|fail|exception|timeout|econnrefused|etimedout" || echo "最近 500 行內沒有找到錯誤關鍵字"

if [[ -n "$SINCE" ]]; then
  sep "9. 指定時間範圍的 Collector log ($SINCE ~ ${UNTIL:-now})"
  if [[ -n "$UNTIL" ]]; then
    docker logs --since "$SINCE" --until "$UNTIL" ems-collector 2>&1
  else
    docker logs --since "$SINCE" ems-collector 2>&1
  fi
fi

sep "健康檢查完成"
