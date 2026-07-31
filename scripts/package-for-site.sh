#!/bin/bash
# 用法: ./package-for-site.sh <該場站對外host:port> <輸出檔名前綴，可省略>
# 範例: ./package-for-site.sh 192.168.61.22:8080 eci

set -euo pipefail

if [ -z "${1:-}" ]; then
  echo "用法: $0 <host:port> [輸出檔名前綴]"
  echo "範例: $0 192.168.61.22:8080 eci"
  exit 1
fi

TARGET_HOST="$1"
SITE_NAME="${2:-site}"
DEV_HOST="192.168.2.127:8080"   # 開發機的 host，之後如果換開發機記得改這裡

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
EMS_DIR="$(dirname "$SCRIPT_DIR")"
STAGING_DIR="/tmp/ems-package-staging"
OUTPUT_FILE="$HOME/ems-deploy-${SITE_NAME}-$(date +%Y%m%d-%H%M).tar.gz"

echo "=== 打包目標: $TARGET_HOST ==="

rm -rf "$STAGING_DIR"
mkdir -p "$STAGING_DIR"

# 複製整個專案到暫存區，排除不需要的東西
rsync -a \
  --exclude='node_modules' \
  --exclude='.git' \
  --exclude='.env' \
  --exclude='collector/.env' \
  "$EMS_DIR/" "$STAGING_DIR/ems/"

# 只在暫存區裡替換 host，原始檔案完全不動
DASH_DIR="$STAGING_DIR/ems/infra/grafana/dashboards/custom/ECI"
for f in "$DASH_DIR"/*.json; do
  if grep -q "$DEV_HOST" "$f"; then
    sed -i "s|http://${DEV_HOST}|http://${TARGET_HOST}|g" "$f"
    echo "已在暫存副本套用 $TARGET_HOST：$(basename "$f")"
  fi
done

# 打包
tar czf "$OUTPUT_FILE" -C "$STAGING_DIR" ems/
rm -rf "$STAGING_DIR"

echo "=== 打包完成：$OUTPUT_FILE ==="
ls -lh "$OUTPUT_FILE"
