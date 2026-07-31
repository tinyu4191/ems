#!/bin/bash
# 用法: ./set-site-host.sh <該場站對外IP:Port>
# 範例: ./set-site-host.sh 192.168.61.22:8080

if [ -z "$1" ]; then
  echo "用法: $0 <host:port>  例如: $0 192.168.61.22:8080"
  exit 1
fi

HOST="$1"
DASH_DIR="$(dirname "$0")/../infra/grafana/dashboards/custom/ECI"

for f in "$DASH_DIR"/*.json; do
  if grep -q "__GRAFANA_HOST__" "$f"; then
    sed -i "s|__GRAFANA_HOST__|http://${HOST}|g" "$f"
    echo "已套用 $HOST 到 $f"
  else
    echo "跳過 $f（沒有找到佔位字串，可能已經套用過）"
  fi
done
