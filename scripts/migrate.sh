#!/usr/bin/env bash
# 最小 migration runner：只需要 bash + docker，不需要任何套件。
#
# 用法：
#   scripts/migrate.sh status                  顯示每個 migration 的狀態
#   scripts/migrate.sh up                      套用尚未套用的 migration
#   scripts/migrate.sh adopt <version>...      只登記為「已套用」、不執行（給已在跑的現場 DB）
#
# 環境變數（皆可省略）：
#   MIGRATE_DIRS    要套用的目錄（相對 repo 根目錄，空白分隔，依序執行）
#                   預設 "migrations/core"；ECI 用 "migrations/core sites/eci/migrations"
#   DB_CONTAINER    預設 ems-timescaledb
#   DB_USER/DB_NAME 預設讀根目錄 .env
#   MIGRATE_UNTIL   套用到指定版本就停（含該版本），例如驗證 baseline 時使用
#   RETENTION_DAYS  傳給 migration 的 psql 變數 retention_days，預設讀 .env，再預設 180
#   PSQL_CMD        完整覆寫 psql 呼叫方式（測試或非 docker 環境用）
#
# 規則：
#   - 檔名必須是 NNN_name.sql；版本識別 = "<目錄>/<檔名去掉.sql>"
#   - 已套用的檔案不可再修改（會以 sha256 偵測），要改請新增下一號 migration
#   - 每個檔案不包在單一 transaction 裡：Timescale 的 continuous aggregate 不能在
#     transaction 內建立。需要原子性的檔案，自己在檔內寫 BEGIN; ... COMMIT;
#   - 失敗的 migration 不會被登記，修好後重跑 `up` 即可（所以請寫成可重跑：IF NOT EXISTS）
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

env_get() { { [ -f "$ROOT/.env" ] && grep -E "^$1=" "$ROOT/.env" | tail -1 | cut -d= -f2- | tr -d '\r"'; } || true; }

MIGRATE_DIRS="${MIGRATE_DIRS:-migrations/core}"
DB_CONTAINER="${DB_CONTAINER:-ems-timescaledb}"
RETENTION_DAYS="${RETENTION_DAYS:-$(env_get RETENTION_DAYS)}"
RETENTION_DAYS="${RETENTION_DAYS:-180}"

if [ -z "${PSQL_CMD:-}" ]; then
  DB_USER="${DB_USER:-$(env_get DB_USER)}"
  DB_NAME="${DB_NAME:-$(env_get DB_NAME)}"
  if [ -z "$DB_USER" ] || [ -z "$DB_NAME" ]; then
    echo "找不到 DB_USER / DB_NAME（請確認根目錄 .env 或設定環境變數）" >&2
    exit 1
  fi
  PSQL_CMD="docker exec -i $DB_CONTAINER psql -U $DB_USER -d $DB_NAME -X -q -v ON_ERROR_STOP=1"
fi

# q 一律吃 /dev/null：避免 docker exec -i 把迴圈的 stdin（檔案清單）吞掉
q()        { $PSQL_CMD -t -A -c "$1" < /dev/null; }
run_file() { $PSQL_CMD -v "retention_days=$RETENTION_DAYS" -f - < "$1"; }
sha()      { sha256sum "$1" | cut -d' ' -f1; }
has_table() { [ "$(q "SELECT to_regclass('public.$1') IS NOT NULL")" = "t" ]; }

ensure_table() {
  q "SET client_min_messages = warning;
     CREATE TABLE IF NOT EXISTS schema_migrations (
       version    text        PRIMARY KEY,
       checksum   text        NOT NULL,
       applied_at timestamptz NOT NULL DEFAULT now())" > /dev/null
}

# 既有資料庫（有 meters、沒有 schema_migrations）：拒絕直接 up，避免重跑 baseline
guard_existing_db() {
  if ! has_table schema_migrations && has_table meters; then
    {
      echo "偵測到既有資料庫（有 meters 表，但沒有 schema_migrations）。"
      echo "請先用 scripts/verify-baseline.sh 確認 schema 與 baseline 一致，再執行："
      echo "  scripts/migrate.sh adopt <已存在的 migration version>..."
    } >&2
    exit 2
  fi
}

# 輸出 "<version><TAB><path>"，依 MIGRATE_DIRS 順序、目錄內依檔名排序
list_files() {
  local d f
  for d in $MIGRATE_DIRS; do
    d="${d%/}"
    [ -d "$ROOT/$d" ] || { echo "找不到目錄：$d" >&2; exit 1; }
    for f in $(cd "$ROOT/$d" && LC_ALL=C ls | grep -E '^[0-9]{3}_[A-Za-z0-9_]+\.sql$' || true); do
      printf '%s\t%s\n' "$d/${f%.sql}" "$ROOT/$d/$f"
    done
  done
}

# 只在啟動時提醒一次：有 .sql 檔但檔名不符規則（會被忽略）
lint_files() {
  local d f
  for d in $MIGRATE_DIRS; do
    d="${d%/}"
    [ -d "$ROOT/$d" ] || { echo "找不到目錄：$d" >&2; exit 1; }
    for f in $(cd "$ROOT/$d" && LC_ALL=C ls | grep -E '\.sql$' | grep -vE '^[0-9]{3}_[A-Za-z0-9_]+\.sql$' || true); do
      echo "略過（檔名不符 NNN_name.sql）：$d/$f" >&2
    done
  done
}

declare -A APPLIED
load_applied() {
  has_table schema_migrations || return 0
  local v c
  while IFS='|' read -r v c; do
    if [ -n "$v" ]; then APPLIED["$v"]="$c"; fi
  done < <(q "SELECT version || '|' || checksum FROM schema_migrations ORDER BY version")
}

cmd_status() {
  load_applied
  local v path s
  while IFS=$'\t' read -r v path; do
    if [ -z "${APPLIED[$v]:-}" ]; then s="pending"
    elif [ "${APPLIED[$v]}" != "$(sha "$path")" ]; then s="CHANGED"
    else s="applied"; fi
    printf '%-8s %s\n' "$s" "$v"
  done < <(list_files)
}

cmd_up() {
  guard_existing_db
  ensure_table
  load_applied

  local v path bad=0 n=0
  while IFS=$'\t' read -r v path; do
    if [ -n "${APPLIED[$v]:-}" ] && [ "${APPLIED[$v]}" != "$(sha "$path")" ]; then
      echo "✗ 已套用的 migration 被修改：$v（請新增下一號 migration，不要改舊檔）" >&2
      bad=1
    fi
  done < <(list_files)
  [ "$bad" -eq 0 ] || exit 3

  while IFS=$'\t' read -r v path; do
    if [ -n "${APPLIED[$v]:-}" ]; then continue; fi
    echo "→ 套用 $v"
    run_file "$path"
    q "INSERT INTO schema_migrations (version, checksum) VALUES ('$v', '$(sha "$path")')" > /dev/null
    n=$((n + 1))
    if [ "$v" = "${MIGRATE_UNTIL:-}" ]; then echo "已到 MIGRATE_UNTIL=$v，停止"; break; fi
  done < <(list_files)
  echo "完成：套用 $n 個 migration"
}

cmd_adopt() {
  [ "$#" -gt 0 ] || { echo "用法：migrate.sh adopt <version>..." >&2; exit 1; }
  ensure_table
  load_applied
  local v path
  for v in "$@"; do
    path="$(list_files | awk -F'\t' -v v="$v" '$1 == v { print $2 }')"
    [ -n "$path" ] || { echo "找不到 migration：$v" >&2; exit 1; }
    if [ -n "${APPLIED[$v]:-}" ]; then echo "已登記過：$v"; continue; fi
    q "INSERT INTO schema_migrations (version, checksum) VALUES ('$v', '$(sha "$path")')" > /dev/null
    echo "已登記為已套用（未執行）：$v"
  done
}

lint_files

case "${1:-status}" in
  status) cmd_status ;;
  up)     cmd_up ;;
  adopt)  shift; cmd_adopt "$@" ;;
  *)      sed -n '2,12p' "$0" >&2; exit 1 ;;
esac
