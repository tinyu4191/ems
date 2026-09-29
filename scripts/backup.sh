#!/usr/bin/env bash
# 資料庫備份：本機排程執行，保留最近 N 天，另外把最新一份放到「離場暫存資料夾」
# 供之後 scp 拉回東昌（或任何你設定的第二個位置）。
#
# 用法（手動測試）：
#   scripts/backup.sh
#
# 排程（Windows 工作排程器，動作設為執行下面這行，每天一次）：
#   wsl.exe -d Ubuntu-24.04 -- bash -lc "cd ~/ems && scripts/backup.sh >> ~/ems/logs/backup.log 2>&1"
#   （發行版名稱請用 `wsl -l -v` 確認，不一定是 Ubuntu-24.04）
#
# 環境變數（皆可省略，預設讀根目錄 .env）：
#   DB_CONTAINER   預設 ems-timescaledb
#   BACKUP_DIR     本機保留備份的資料夾，預設 ~/ems-backups
#   KEEP_DAYS      本機保留天數，預設 14
#   OFFSITE_DIR    離場暫存資料夾（例如 /mnt/c/Users/AIOT/ems-backups），
#                  留空則跳過這一步，只做本機備份
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
env_get() { { [ -f "$ROOT/.env" ] && grep -E "^$1=" "$ROOT/.env" | tail -1 | cut -d= -f2- | tr -d '\r"'; } || true; }

DB_CONTAINER="${DB_CONTAINER:-ems-timescaledb}"
DB_USER="${DB_USER:-$(env_get DB_USER)}"
DB_NAME="${DB_NAME:-$(env_get DB_NAME)}"
BACKUP_DIR="${BACKUP_DIR:-$HOME/ems-backups}"
KEEP_DAYS="${KEEP_DAYS:-14}"
OFFSITE_DIR="${OFFSITE_DIR:-}"

[ -n "$DB_USER" ] && [ -n "$DB_NAME" ] || { echo "找不到 DB_USER / DB_NAME（.env）" >&2; exit 1; }

mkdir -p "$BACKUP_DIR"
STAMP="$(date +%Y%m%d-%H%M%S)"
FILE="$BACKUP_DIR/ems-${STAMP}.dump"
TMP_FILE="${FILE}.tmp"

echo "[$(date '+%F %T')] 開始備份 → $FILE"

# -Fc：pg_dump 自訂格式，比純文字小、還原時可以只挑單一張表，也支援平行還原。
# 先寫到 .tmp，成功才 rename，避免半成品被誤當成完整備份。
if docker exec "$DB_CONTAINER" pg_dump -U "$DB_USER" -d "$DB_NAME" -Fc > "$TMP_FILE"; then
  mv "$TMP_FILE" "$FILE"
  echo "[$(date '+%F %T')] 備份完成：$(du -h "$FILE" | cut -f1)"
else
  rm -f "$TMP_FILE"
  echo "[$(date '+%F %T')] 備份失敗（pg_dump 非 0 結束碼）" >&2
  exit 1
fi

# 保留最近 KEEP_DAYS 天，其餘刪除
find "$BACKUP_DIR" -name 'ems-*.dump' -mtime "+$KEEP_DAYS" -print -delete

if [ -n "$OFFSITE_DIR" ]; then
  mkdir -p "$OFFSITE_DIR"
  cp "$FILE" "$OFFSITE_DIR/"
  # 離場暫存資料夾只留「最新一份」，不無限累積（之後拉回東昌的人自己決定要保留幾份）
  find "$OFFSITE_DIR" -name 'ems-*.dump' -not -name "$(basename "$FILE")" -print -delete
  echo "[$(date '+%F %T')] 已複製到離場暫存資料夾：$OFFSITE_DIR"
else
  echo "[$(date '+%F %T')] 未設定 OFFSITE_DIR，本次只做本機備份"
fi

echo "[$(date '+%F %T')] 目前本機備份列表："
ls -lh "$BACKUP_DIR"/ems-*.dump 2>/dev/null || echo "（無）"
