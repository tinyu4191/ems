#!/usr/bin/env bash
# scripts/sync-dashboard.sh
#
# 把從 Grafana UI 匯出的 dashboard JSON（因為 provisioned，UI 無法直接 Save，
# 只能用 "Save JSON to file" 匯出）正規化後寫回 dashboards-src/，方便 git 版控。
#
# 這是手動匯出這一步唯一可靠的做法：Grafana API 對 provisioned dashboard
# 回傳的是「上次 provisioning 載入的版本」，不會反映 UI 上還沒儲存的即時編輯，
# 所以不能用 API pull 取代這個匯出動作。
#
# Usage:
#   DEV_HOST=localhost:3000 ./sync-dashboard.sh <exported-json-path> <dest-relative-path>
#
# Example:
#   DEV_HOST=localhost:3000 ./sync-dashboard.sh \
#     ~/Downloads/eci-layout-electricity-1234567890.json \
#     custom/ECI/eci-layout-electricity.json

set -euo pipefail

SRC_FILE="${1:?Usage: sync-dashboard.sh <exported-json-path> <dest-relative-path>}"
DEST_REL="${2:?Usage: sync-dashboard.sh <exported-json-path> <dest-relative-path>}"
DEV_HOST="${DEV_HOST:?請設定 DEV_HOST，例如 localhost:3000（要跟 dev-apply-host.sh 套用時用的 host 完全一致）}"

REPO_ROOT="$(git rev-parse --show-toplevel)"
# 假設路徑，若你實際的 dashboards-src 不在這裡，改這一行就好
SRC_DIR="${REPO_ROOT}/infra/grafana/dashboards-src"
DEST_PATH="${SRC_DIR}/${DEST_REL}"

if [ ! -f "$SRC_FILE" ]; then
  echo "ERROR: 找不到匯出的檔案 $SRC_FILE" >&2
  exit 1
fi

command -v jq >/dev/null || { echo "ERROR: 需要 jq，跑: sudo apt install jq" >&2; exit 1; }

mkdir -p "$(dirname "$DEST_PATH")"

# 注意：UI 匯出的檔案本身就是 dashboard JSON 本體（沒有像 API response 那樣
# 多包一層 .dashboard），所以這裡直接處理最外層
jq '.id = null' "$SRC_FILE" \
  | sed "s#http://${DEV_HOST}#__GRAFANA_HOST__#g" \
  > "$DEST_PATH"

echo "==> 已寫入 $DEST_PATH"
echo
echo "==> git diff:"
cd "$REPO_ROOT" && git --no-pager diff -- "infra/grafana/dashboards-src/${DEST_REL}" || true

echo
echo "確認 diff 沒問題後："
echo "  git add infra/grafana/dashboards-src/${DEST_REL}"
echo "  git commit -m 'chore(grafana): sync ${DEST_REL} from dev'"