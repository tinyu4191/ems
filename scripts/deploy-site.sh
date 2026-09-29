#!/usr/bin/env bash
# 現場更新腳本：在「已經把新版 tar.gz 解壓縮蓋上去」之後，於現場機器上執行本檔。
#
# 完整流程（在現場機器上）：
#   1. 把 package-for-site.sh 打包出的 tar.gz 傳到現場（scp / USB 都可以）
#   2. tar xzf ems-deploy-eci-XXXXXXXX.tar.gz -C ~/ems --strip-components=1
#      （tar 內容不含 .env / collector.env / api/.env / .dev-host，
#       這些檔案不會被覆蓋，其餘檔案含新版 scripts/、migrations/、dashboards/ 會被換成新的）
#   3. cd ~/ems && scripts/deploy-site.sh
#
# 本檔只負責「解壓縮之後」的部分：備份 → 重建容器 → 套用 migration → 驗證。
# 不會自動 adopt——adopt 需要人工先確認 verify-baseline.sh 通過，這是刻意的，
# 避免腳本在沒人看過差異的情況下，把可能不一致的 baseline 直接登記為「已套用」。
#
# 環境變數：
#   MIGRATE_DIRS   預設 "migrations/core sites/eci/migrations"
#   SKIP_BACKUP    設為 1 可跳過備份（不建議，僅供已經手動備份過的情況）
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

MIGRATE_DIRS="${MIGRATE_DIRS:-migrations/core sites/eci/migrations}"
export MIGRATE_DIRS

echo "=============================================="
echo " EMS 現場更新　$(date '+%F %T')"
echo " 工作目錄：$ROOT"
echo "=============================================="

# ── 1. 備份（除非明確跳過）──────────────
if [ "${SKIP_BACKUP:-0}" = "1" ]; then
  echo "→ [1/5] 略過備份（SKIP_BACKUP=1）"
else
  echo "→ [1/5] 更新前備份"
  scripts/backup.sh
fi

# ── 2. 確認這是全新站點還是既有站點 ──────────────
# 既有站點（已在跑）：DB 裡已經有 meters 表，但可能還沒有 schema_migrations（第一次採用這套機制）
# 這種情況不能直接 up，必須先讓人確認 verify-baseline.sh 通過、手動 adopt，腳本在此停下不繼續
DB_CONTAINER="${DB_CONTAINER:-ems-timescaledb}"
if docker ps --format '{{.Names}}' | grep -qx "$DB_CONTAINER"; then
  DB_USER="$(grep -E '^DB_USER=' .env | tail -1 | cut -d= -f2- | tr -d '\r"')"
  DB_NAME="$(grep -E '^DB_NAME=' .env | tail -1 | cut -d= -f2- | tr -d '\r"')"
  HAS_METERS="$(docker exec "$DB_CONTAINER" psql -U "$DB_USER" -d "$DB_NAME" -tAc "SELECT to_regclass('public.meters') IS NOT NULL" 2>/dev/null || echo f)"
  HAS_MIGTABLE="$(docker exec "$DB_CONTAINER" psql -U "$DB_USER" -d "$DB_NAME" -tAc "SELECT to_regclass('public.schema_migrations') IS NOT NULL" 2>/dev/null || echo f)"
  if [ "$HAS_METERS" = "t" ] && [ "$HAS_MIGTABLE" != "t" ]; then
    cat >&2 <<EOF

✗ 偵測到既有資料庫（有 meters 表，但沒有 schema_migrations）。
  這是這套機制第一次套用到這個站點，不能自動繼續。

  請先手動執行：
    scripts/verify-baseline.sh
  顯示「✓ schema 一致」之後，再手動執行：
    scripts/migrate.sh adopt migrations/core/000_baseline sites/eci/migrations/000_seed_meters
  完成後重新執行本腳本（這次會走 migrate.sh up 的路徑）。
EOF
    exit 2
  fi
else
  echo "→ [2/5] DB 容器尚未啟動，視為全新部署，continue"
fi
echo "→ [2/5] 站點狀態確認完成"

# ── 3. 重建有變動的容器 ──────────────
echo "→ [3/5] 重建容器（--build 讓程式碼變動生效；DB/nginx 只有設定變動也會一併套用）"
docker compose up -d --build

echo "→ 等待 timescaledb 就緒"
for _ in $(seq 1 30); do
  docker compose ps timescaledb --format '{{.Health}}' 2>/dev/null | grep -qx healthy && break
  sleep 2
done

# ── 4. 套用 migration ──────────────
echo "→ [4/5] 套用 migration"
scripts/migrate.sh up

# ── 5. 驗證 ──────────────
echo "→ [5/5] 驗證"
echo "-- migrate.sh status（不應有 pending）--"
scripts/migrate.sh status
echo "-- 容器狀態 --"
docker compose ps
echo "-- collector 最近一輪心跳（應是幾秒到幾十秒前）--"
DB_USER="$(grep -E '^DB_USER=' .env | tail -1 | cut -d= -f2- | tr -d '\r"')"
DB_NAME="$(grep -E '^DB_NAME=' .env | tail -1 | cut -d= -f2- | tr -d '\r"')"
docker exec "$DB_CONTAINER" psql -U "$DB_USER" -d "$DB_NAME" -c \
  "SELECT time, round(round_duration_ms::numeric) AS ms, meters_success, meters_failed FROM collector_heartbeat ORDER BY time DESC LIMIT 3"

echo "=============================================="
echo " 完成。請確認上面「migrate.sh status」沒有 pending、"
echo " 容器都是 running/healthy、collector 心跳時間夠新。"
echo "=============================================="
