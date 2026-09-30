#!/usr/bin/env bash
# 驗證 migrations/core/000_baseline.sql 與「現場 DB」的 schema 是否一致。
# 在「跑著現場 DB 容器的那台機器」上執行（dev 機或 ECI IPC 都可以）。
#
# 做法：
#   1. 用同版 timescaledb image 開一個拋棄式容器
#   2. 只套用到 baseline（MIGRATE_UNTIL），不含 001 之後的 migration
#   3. 對「拋棄式 DB」與「現場 DB」各跑 scripts/schema-fingerprint.sql，排序後 diff
#
# 一致 → 可以放心執行 `scripts/migrate.sh adopt migrations/core/000_baseline`
# 不一致 → 差異就是 baseline 需要修正（或現場 DB 被手動改過）的地方；請把 diff 貼給我
#
# 環境變數（皆可省略）：
#   LIVE_CONTAINER  現場 DB 容器名稱，預設 ems-timescaledb
#   IMAGE           強制指定 timescale image，跳過下面的自動解析
#   SITE_DIR        站點目錄，內含 site.env（讀取 CORE_RELEASE），預設 sites/eci
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
env_get() { { [ -f "$ROOT/.env" ] && grep -E "^$1=" "$ROOT/.env" | tail -1 | cut -d= -f2- | tr -d '\r"'; } || true; }

DB_USER="${DB_USER:-$(env_get DB_USER)}"
DB_NAME="${DB_NAME:-$(env_get DB_NAME)}"
LIVE_CONTAINER="${LIVE_CONTAINER:-ems-timescaledb}"

# 版本清單（跟 deploy-site.sh 讀取同一份，確保這裡驗證用的版本跟實際會部署的版本一致）
SITE_DIR="${SITE_DIR:-sites/eci}"
if [ -z "${IMAGE:-}" ] && [ -f "$ROOT/$SITE_DIR/site.env" ]; then
  CORE_RELEASE="$(grep -E '^CORE_RELEASE=' "$ROOT/$SITE_DIR/site.env" | tail -1 | cut -d= -f2- | tr -d '\r"')"
  RELEASE_FILE="${RELEASE_FILE:-$ROOT/releases/${CORE_RELEASE}.env}"
  [ -f "$RELEASE_FILE" ] && { set -a; source "$RELEASE_FILE"; set +a; }
fi
# 不要用 grep/awk 土法解析 docker-compose.yml 的原始文字（裡面可能是 ${VAR:-default} 這種
# 尚未代換的變數，直接抓出來會是一串帶 $ { } 符號的無效字串）。改讓 docker compose 自己
# 解析、代換完變數後，我們只讀它算出來的最終結果 —— 這樣永遠跟 deploy-site.sh 實際部署
# 的版本一致，不會分岔。
IMAGE="${IMAGE:-$(cd "$ROOT" && docker compose config 2>/dev/null \
  | awk '/^  timescaledb:/{f=1} f && /^    image:/{print $2; exit}')}"
VERIFY_CONTAINER="ems-verify-db"
WORK="$(mktemp -d)"

[ -n "$DB_USER" ] && [ -n "$DB_NAME" ] || { echo "找不到 DB_USER / DB_NAME（.env）" >&2; exit 1; }
[ -n "$IMAGE" ] || { echo "找不到 timescale image（docker-compose.yml）" >&2; exit 1; }

cleanup() { docker rm -fv "$VERIFY_CONTAINER" >/dev/null 2>&1 || true; rm -rf "$WORK"; }
trap cleanup EXIT
cleanup_old() { docker rm -fv "$VERIFY_CONTAINER" >/dev/null 2>&1 || true; }
cleanup_old

echo "→ 啟動拋棄式容器（$IMAGE）"
docker run -d --name "$VERIFY_CONTAINER" \
  -e POSTGRES_USER="$DB_USER" -e POSTGRES_PASSWORD=verify -e POSTGRES_DB="$DB_NAME" \
  "$IMAGE" >/dev/null

PSQL_VERIFY="docker exec -i $VERIFY_CONTAINER psql -U $DB_USER -d $DB_NAME -X -q -v ON_ERROR_STOP=1"

# 官方 image 首次啟動會先開一個暫時的 server 跑 init，再重啟；
# 要等到 "init process complete" 之後、且 psql 連得上才算真的好了
echo -n "→ 等待資料庫就緒"
for _ in $(seq 1 90); do
  if docker logs "$VERIFY_CONTAINER" 2>&1 | grep -q "PostgreSQL init process complete" \
     && $PSQL_VERIFY -t -A -c "SELECT 1" </dev/null >/dev/null 2>&1; then
    break
  fi
  echo -n "."; sleep 1
done
echo
$PSQL_VERIFY -t -A -c "SELECT 1" </dev/null >/dev/null 2>&1 || { echo "拋棄式資料庫沒有起來" >&2; docker logs "$VERIFY_CONTAINER" | tail -20 >&2; exit 1; }

echo "→ 只套用到 baseline"
PSQL_CMD="$PSQL_VERIFY" MIGRATE_DIRS="migrations/core" MIGRATE_UNTIL="migrations/core/000_baseline" \
  "$ROOT/scripts/migrate.sh" up

echo "→ 取得兩邊的 schema 指紋"
LC_ALL=C
export LC_ALL
docker exec -i "$VERIFY_CONTAINER" psql -U "$DB_USER" -d "$DB_NAME" -X -q -t -A -f - \
  < "$ROOT/scripts/schema-fingerprint.sql" | sort > "$WORK/fresh.txt"
docker exec -i "$LIVE_CONTAINER" psql -U "$DB_USER" -d "$DB_NAME" -X -q -t -A -f - \
  < "$ROOT/scripts/schema-fingerprint.sql" | sort > "$WORK/live.txt"

echo "   拋棄式 DB：$(wc -l < "$WORK/fresh.txt") 行；現場 DB：$(wc -l < "$WORK/live.txt") 行"

if diff -u "$WORK/live.txt" "$WORK/fresh.txt" > "$WORK/diff.txt"; then
  echo "✓ schema 一致。可以執行："
  echo "    scripts/migrate.sh adopt migrations/core/000_baseline"
else
  echo "✗ 有差異（'-' 是現場 DB 有、baseline 沒有；'+' 是 baseline 有、現場沒有）："
  echo "----------------------------------------------------------------"
  cat "$WORK/diff.txt"
  echo "----------------------------------------------------------------"
  cp "$WORK/diff.txt" "$ROOT/baseline-diff.txt" && echo "（已另存 baseline-diff.txt）"
  exit 1
fi
