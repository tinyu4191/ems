# EMS v2 — 並行環境部署說明

這是新的整合資料夾，跟現有 `ems-dev` / `ems-product` / `ems-web` 並行運作，
互不干擾。確認新環境穩定後才切換、才刪舊資料夾。

## 放置位置

放在 `~/ems/`，跟 `ems-dev`、`ems-product`、`ems-web` 同一層（不要放在它們裡面）。

## 使用前必做（缺一不可）

1. **根目錄 `.env`**：複製 `.env.example` → `.env`，通常不用改，只是把 port 跟舊環境錯開（5433 / 3001 / 8080）。

2. **`collector/.env`**：複製 `.env.example` → `.env`，把 8 個 Gateway 的
   `GW_0X_HOST` / `GW_0X_PORT` 填入現場真實值（照抄 `ems-product/.env` 現有的值即可，
   這是同一批 SSH tunnel port）。**這個檔案不會被上傳/分享，因為 Dockerfile 建置時
   `.env` 本身不會被複製進 image**（`.dockerignore` 建議另外加，見下方）。

3. **Grafana dashboard JSON**：把現有 Grafana 裡「水錶總覽」等已完成的 dashboard
   匯出成 JSON，放進 `infra/grafana/dashboards/`，新環境啟動時會自動載入
   （靠 `infra/grafana/provisioning/dashboards/dashboards.yml` 指向這個資料夾）。
   Grafana UI 裡：Dashboard 設定 → JSON Model → 複製內容存成 `.json` 檔即可。

4. **React build**：`cd` 到你的 React 專案（`ems-web`），跑 `npm run build`，
   把產生的 `build/`（或 `dist/`，看你的 build 工具）內容整個複製進
   `~/ems/web/dist/`。這個資料夾目前是空的，nginx 服務起來但沒有東西可以 serve
   直到你做這步。

## 啟動

```bash
cd ~/ems
docker compose up -d
docker compose ps        # 確認 4 個服務都是 running
docker compose logs -f collector   # 確認開始寫入資料
```

## 驗證新 DB schema

```bash
docker exec -i ems-v2-timescaledb psql -U admin -d ems < infra/timescaledb/init/verify.sql.reference
```

## 尚未加入這輪 compose 的東西

- **Fastify API**：資料夾骨架還沒建，`nginx.conf` 裡 `/api/` 先回 503 佔位，
  之後 API 骨架做好、有 health check endpoint 了再加進 `docker-compose.yml`。
- **Electron kiosk（`eci-dashboard/`）**：故意不放進這個資料夾，
  它裝在展示用顯示器主機，不是 IPC，是完全獨立的部署對象。

## 已知待確認事項（不影響現在啟動，但之後會踩到）

- `infra/grafana/provisioning/datasources/timescaledb.yml` 裡的密碼是明碼寫死
  （跟 `.env.example` 預設值一致）。如果你之後改了 `DB_PASS`，記得同步改這個檔案，
  Grafana provisioning YAML 不會自動吃 docker-compose 的環境變數。
- `collector/package.json` 是重新寫的最小版本（依 `collector.js` 實際用到的套件
  推回去：`modbus-serial`、`pg`、`dotenv`），建議 `docker compose build collector`
  前先本機 `npm install` 一次確認版本沒問題、產生 `package-lock.json` 鎖版本。
