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

rm -rf "$EMS_DIR/infra/grafana/dashboards"
cp -r "$EMS_DIR/infra/grafana/dashboards-src" "$EMS_DIR/infra/grafana/dashboards"

DASH_DIR="$EMS_DIR/infra/grafana/dashboards/custom/ECI"
for f in "$DASH_DIR"/*.json; do
  sed -i "s|__GRAFANA_HOST__|http://${DEV_HOST}|g" "$f"
done

echo "已生成本機開發版 dashboards，套用 host: $DEV_HOST"
