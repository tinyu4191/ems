#!/bin/bash
# 用法: ./package-for-site.sh <該場站對外host:port> <輸出檔名前綴>
# 範例: ./package-for-site.sh 192.168.61.22:8080 eci

set -euo pipefail

if [ -z "${1:-}" ]; then
  echo "用法: $0 <host:port> [輸出檔名前綴]"
  exit 1
fi

TARGET_HOST="$1"
SITE_NAME="${2:-site}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
EMS_DIR="$(dirname "$SCRIPT_DIR")"
STAGING_DIR="/tmp/ems-package-staging"
OUTPUT_FILE="$HOME/ems-deploy-${SITE_NAME}-$(date +%Y%m%d-%H%M).tar.gz"

echo "=== 打包目標: $TARGET_HOST ==="

rm -rf "$STAGING_DIR"
mkdir -p "$STAGING_DIR/ems"

rsync -a \
  --exclude='node_modules' \
  --exclude='.git' \
  --exclude='.env' \
  --exclude='collector/.env' \
  --exclude='infra/grafana/dashboards/' \
  --exclude='.dev-host' \
  --exclude='infra/grafana/dashboards-src/' \
  "$EMS_DIR/" "$STAGING_DIR/ems/"

# 從 dashboards-src 生成部署版 dashboards（給業主端用的最終資料夾名稱一樣叫 dashboards）
cp -r "$EMS_DIR/infra/grafana/dashboards-src" "$STAGING_DIR/ems/infra/grafana/dashboards"

DASH_DIR="$STAGING_DIR/ems/infra/grafana/dashboards/custom/ECI"
for f in "$DASH_DIR"/*.json; do
  sed -i "s|__GRAFANA_HOST__|http://${TARGET_HOST}|g" "$f"
  echo "已套用 $TARGET_HOST：$(basename "$f")"
done

tar czf "$OUTPUT_FILE" -C "$STAGING_DIR" ems/
rm -rf "$STAGING_DIR"

echo "=== 打包完成：$OUTPUT_FILE ==="
ls -lh "$OUTPUT_FILE"
