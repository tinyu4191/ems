# DB Migration 使用說明

schema 的唯一來源是 migration 檔，不再靠 `01_init.sql` 首次啟動執行。

## 目錄

```
migrations/core/            所有站點共用（表結構、policy）
  000_baseline.sql          ECI 現場既有 DB 的狀態（不含錶主檔資料）
  001_monitoring_retention.sql
sites/<siteId>/migrations/  只屬於該站點的內容
  000_seed_meters.sql       ECI 33 支錶主檔（過渡用，A7 之後由 site.json 取代）
scripts/
  migrate.sh                runner：status / up / adopt
  verify-baseline.sh        比對 baseline 與現場 DB 的 schema
  schema-fingerprint.sql    verify-baseline 用的結構指紋查詢
```

## 日常

```bash
scripts/migrate.sh status                      # 看哪些 pending
MIGRATE_DIRS="migrations/core sites/eci/migrations" scripts/migrate.sh up
```

新增 schema 變更：建立下一號檔案 `migrations/core/002_xxx.sql`，寫成可重跑（`IF NOT EXISTS`），
commit 後在每個站點執行 `up`。**已套用的檔案不要再改**（runner 會用 sha256 偵測並拒絕），要改就新增下一號。

## ECI 現場（已在跑的 DB）第一次採用

**不可以直接 `up`**（會重跑 baseline）。runner 也會擋：偵測到 `meters` 表但沒有 `schema_migrations` 時 exit 2。

1. 在跑著現場 DB 的機器上：`scripts/verify-baseline.sh`
   - 顯示 `✓ schema 一致` → 繼續。
   - 顯示差異 → 停，把 diff 給我，修正 baseline 後再驗證。
2. 登記既有內容為「已套用」（不執行任何 SQL）：
   ```bash
   scripts/migrate.sh adopt migrations/core/000_baseline sites/eci/migrations/000_seed_meters
   ```
3. 套用新的 migration：
   ```bash
   MIGRATE_DIRS="migrations/core sites/eci/migrations" scripts/migrate.sh up
   ```
   目前只會套用 `001_monitoring_retention`（兩張監控表補 90 天 retention）。

## 全新站點 / 全新 DB

```bash
docker volume create ems_pgdata ems_grafana-data
docker compose up -d timescaledb
MIGRATE_DIRS="migrations/core sites/<id>/migrations" scripts/migrate.sh up
docker compose up -d
```

`docker-compose.yml` 已移除 `/docker-entrypoint-initdb.d` 掛載；
**部署到現場時 timescaledb 容器會因 compose 設定變更而重建一次**（約 10~20 秒，collector 會缺少這段資料），請挑時段，
最好和其他需要重建 DB 容器的變更（logging 上限、port 綁定）一次做完。

## 已知限制

- migration 不包在單一 transaction（Timescale 的 continuous aggregate 不能在 transaction 內建立）；
  失敗的 migration 不會被登記，修正後重跑 `up`，所以每個檔案請寫成可重跑。
- 沒有 rollback。要回復就寫新的 migration。
- 沒有並行鎖；不要同時在同一個 DB 跑兩個 `up`。
- `retention_days` 由 `.env` 的 `RETENTION_DAYS` 傳入 baseline（預設 180）；已採用的現場 DB 不受影響，
  現場 retention 要改請寫新的 migration。

## 現場狀態備註（尚未寫入 migration 的手動變更）

- **2026-09-28：** ECI 現場的 5 個 raw 表 retention job（job_id 1005~1009，180 天）已手動暫停（`scheduled = false`）。
  原因：最早資料為 2026-04-21，依 7 天 chunk 推算，最舊的 chunk 最早會在 2026-10-20 被刪除，而客戶要保留多久尚未決定。
  最終保留期與壓縮策略決定後，用 migration 統一處理（`remove_retention_policy` + `add_retention_policy`，
  或 `alter_job(..., scheduled => true)`），並更新此段落。
  注意：`verify-baseline.sh` 只比對 job 的設定（不含 scheduled 旗標），不會偵測到這個暫停狀態。
