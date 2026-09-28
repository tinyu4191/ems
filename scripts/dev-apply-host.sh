#!/bin/bash
# 從 dashboards-src（含佔位字串）生成本機開發用的 dashboards（套用 .dev-host 裡的值）
# 每次改了 dashboards-src 內容後，重跑這個腳本同步到本機掛載版本

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
EMS_DIR="$(dirname "$SCRIPT_DIR")"
DEV_HOST_FILE="$EMS_DIR/.dev-host"

if [ ! -f "$DEV_HOST_FILE" ]; then
  echo "找不到 $DEV_HOST_FILE，請先建立，內容填你的開發機 host:port，例如："
  echo "  echo '192.168.2.127:8080' > $DEV_HOST_FILE"
  exit 1
fi

DEV_HOST="$(cat "$DEV_HOST_FILE" | tr -d '[:space:]')"

command -v rsync >/dev/null || { echo "需要 rsync：sudo apt install rsync" >&2; exit 1; }

# 注意：infra/grafana/dashboards 是 Grafana 容器的 bind mount 來源（docker-compose.yml）。
# 不能整個刪掉重建 —— 容器會繼續指向被刪掉的舊資料夾（看不到新檔案），
# 而且重啟時會報 "mounting ... no such file or directory"。
# 這裡用 rsync 只同步「內容」，資料夾本身保持不變。
mkdir -p "$EMS_DIR/infra/grafana/dashboards"
rsync -a --delete "$EMS_DIR/infra/grafana/dashboards-src/" "$EMS_DIR/infra/grafana/dashboards/"

DASH_DIR="$EMS_DIR/infra/grafana/dashboards/custom/ECI"
for f in "$DASH_DIR"/*.json; do
  sed -i "s|__GRAFANA_HOST__|http://${DEV_HOST}|g" "$f"
done

echo "已生成本機開發版 dashboards，套用 host: $DEV_HOST"
