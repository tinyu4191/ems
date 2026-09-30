# 現場更新流程（Runbook）

給之後要更新 ECI（或未來新場域）系統的人看。這是實際操作過、驗證過的流程，不是理論上的設計。

相關文件：`docs/migrations.md`（migration 機制細節）、`docs/backup-restore.md`（備份/還原）、`docs/2026-09-refactor-summary.md`（這次重構的完整脈絡）。

## 開發原則：先在東昌驗證，才推 ECI

東昌（`TCEM-PC191`）跑著一套完整的平行 EMS 實例，跟 ECI 用同一份程式碼，獨立採集同一批電表的資料。**任何改動都先在東昌的分支上做、在東昌驗證過，才打包送 ECI**，不要跳過這一步直接改 ECI。

## 日常改動（不改資料庫結構）

例如：修 dashboard 查詢、改 nginx 設定、調整 collector 邏輯。

1. 在東昌改程式碼，測試確認正常。
2. `scripts/deploy-site.sh` 在東昌自己跑一次，確認容器重建、行為都正常（東昌也是一套真實運作的環境，這一步就是實戰驗證，不是形式）。
3. 打包：`scripts/package-for-site.sh <ECI 現場內網 host:port> eci`
   - host:port 要填 **ECI 現場的內網位址**（不是 ZeroTier IP），這是給 Grafana dashboard 內嵌圖片連結用的。查法：ECI 現場執行
     `grep -o 'http://[0-9.]*:[0-9]*/grafana' ~/ems/infra/grafana/dashboards/custom/ECI/eci-layout-electricity.json | head -1`
4. 傳輸：用 ZeroTier IP（不是內網 IP），走 Windows 原生 OpenSSH：
   `scp ~/ems-deploy-eci-*.tar.gz AIOT@<ECI ZeroTier IP>:ems-deploy-eci-*.tar.gz`
   （路徑不加任何斜線，會直接放在 `C:\Users\AIOT\` 下）
5. **在 ECI 解壓縮前，先看一眼 ECI 自己的 git 狀態**（見下方「ECI 現場的 git」），避免又有東昌不知道的客製化被無聲蓋掉。
6. ECI 現場解壓縮：
   `tar xzf /mnt/c/Users/AIOT/ems-deploy-eci-*.tar.gz -C ~/ems --strip-components=1`
7. ECI 執行 `scripts/deploy-site.sh`（會自動：備份 → 重建容器 → 套用 migration，此時應無新 migration 可套 → 驗證）。
8. 瀏覽器實測：主畫面、Grafana、歷史報告（API），確認正常。

## 有資料庫結構變更（新增/修改 migration 檔）

在「日常改動」的基礎上，多這幾步：

1. 在 `migrations/core/`（或 `sites/eci/migrations/`）新增下一號 migration 檔（`NNN_name.sql`），寫成可重跑（`IF NOT EXISTS` 之類）。**不要修改已經套用過的舊檔案**，`migrate.sh` 會用 checksum 擋下這種修改。
2. 東昌執行 `MIGRATE_DIRS="migrations/core sites/eci/migrations" scripts/migrate.sh up`，實際驗證新 migration 能跑。
3. 按「日常改動」流程打包、傳輸。
4. ECI 執行 `scripts/deploy-site.sh` 時，這次 `migrate.sh up` 會真的套用新 migration，注意看輸出有沒有錯誤。

## 全新場域（第一次導入這套機制）

僅供未來新場域的第一次部署參考，ECI 已經走過這一步，不需要重做：

1. 建立 `sites/<siteId>/`（migrations、site.env）。
2. 全新空 DB：直接 `MIGRATE_DIRS="migrations/core sites/<siteId>/migrations" scripts/migrate.sh up`。
3. **既有 DB（現場已經在跑、要導入這套機制）**：
   a. 打包 `migrations/core/000_baseline.sql` 要先根據該站點既有的 schema 調整（不能直接套用 ECI 那份）。
   b. 現場執行 `scripts/verify-baseline.sh`，確認 baseline 跟現場 schema 完全一致（用拋棄式容器比對，不會動現場資料）。
   c. 一致才能執行 `scripts/migrate.sh adopt migrations/core/000_baseline <該站的 seed migration>`（只登記，不執行 SQL）。
   d. 之後才是正常的 `scripts/deploy-site.sh` 流程。

## ECI 現場的 git

`~/ems`（ECI 現場）本身是一個獨立的 git repo（跟東昌的 repo 沒有共用歷史），git 身份設定是 `Terry <tectiikoa0151@tectiiko.com.vn>`。這不是部署機制的一部分（部署完全靠 tar），單純是一份**本機稽核紀錄**，方便事後追溯「這台機器上到底發生過什麼」。

**每次要在 ECI 解壓縮新版本之前，養成習慣先看一眼：**

```bash
git -C ~/ems log --oneline -3
git -C ~/ems status --short
```

如果看到東昌這邊完全沒有的 commit，或有未 commit 的修改，**先停下來查清楚內容再繼續**，不要直接蓋過去。2026-09-30 這次重構部署時，就是靠這個習慣才發現 ECI 藏著一個從 7 月就沒同步過、東昌完全不知道的客製化（見 `docs/2026-09-refactor-summary.md`）。

解壓縮蓋上新檔案之後，記得也 commit 一次，讓 ECI 的 git 誠實反映現況：

```bash
cd ~/ems
git add -A
git commit -m "deploy: <簡述這次更新內容，例如 step16>"
```

## 常見錯誤與修法（已踩過的坑）

| 症狀 | 原因 | 修法 |
|---|---|---|
| `docker compose restart <service>` 報 `error mounting ... no such file or directory` | bind mount 的檔案被 `git apply`/`tar` 覆蓋（產生新檔案），容器原本的掛載參照失效 | 改用 `docker compose up -d --force-recreate <service>` |
| nginx 出現 502 | `api`/`grafana` 容器重建後換了新 IP，nginx 沒有重新解析 | `nginx.conf` 已用 `resolver` 動態解析；若仍發生，手動 `docker compose up -d --force-recreate nginx` |
| nginx 出現子路徑 404（例如 `/api/reports/xxx` 變成 `/api/`） | `proxy_pass` 用變數時，變數後面接了固定路徑片段，會把使用者的子路徑整段丟掉 | 變數後面不接任何路徑，讓完整原始路徑透傳（參考 `nginx.conf` 現有的 `/api/`、`/grafana/` 兩段寫法） |
| 手動下 `docker compose` 指令，build 出來的 image tag 是 `dev` 不是預期的版本號 | 版本清單只在 `deploy-site.sh` 執行的當下生效，不會留在互動式 shell | 手動操作前先 `set -a; source releases/<release>.env; set +a` |
| `scp` 到 `10.14.118.87`／`192.168.61.22` 逾時或連不上 | 兩個 IP 用途不同：內網 IP（`192.168.61.22`）只有在 ECI 現場區網內才連得到；ZeroTier IP（`10.14.118.87`）才是東昌連過去要用的 | 打包用內網 IP，`scp` 傳輸用 ZeroTier IP |
| `scp` 目的地寫 `/mnt/c/Users/AIOT/` 卻報路徑不存在 | Windows 原生 OpenSSH 的家目錄語法跟 WSL 的 `/mnt/c/...` 不是同一套 | 路徑不加斜線，直接檔名即可，會落在 `C:\Users\AIOT\` |
