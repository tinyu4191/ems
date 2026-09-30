# 2026-09 Core 重構：專案小結

給之後接手這個專案的人看，記錄這次重構做了什麼、為什麼做、過程中踩過什麼坑。

## 背景與目標

ECI 越南紡織廠是這套 EMS 的第一個驗證場域，2026 年 7 月上線後持續運作。上線後才發現的問題（見下）加上「要能快速複製到第二個場域」這個產品化需求，促成了這次重構。

目標：把已經在跑的 ECI 系統，抽離重構成 core（所有站點共用）+ site（各站專屬）的架構，同時修掉上線後發現的資料正確性問題。

## 起點：整體評估

重構開始前，先對當時的專案做了一次全面評估（分 A/B/C 三級），重點問題：

- **用量計算會少算**：`MAX(累計值) - MIN(累計值)` 逐桶計算用量，斷線期間的用量會完全消失，不屬於任何一個桶。
- **報表時區沒對齊**：Grafana 的日/週/月分桶沒指定時區，實際以 UTC 對齊，導致每日報表切在當地時間早上 7 點，跟 Excel 報表（API，已用對時區）對不起來。
- **沒有 schema migration 機制**：資料庫結構只有 `01_init.sql`，只在空 DB 首次啟動時執行，改結構只能手動連進去下 SQL，現場 DB 容易跟 repo 分岔。
- **沒有排程備份**、監控表沒有 retention（已長到數百 MB）、5 個 continuous aggregate 建了但整個 repo 零引用。
- **site 相關設定散落多處**：`config.js`、`01_init.sql` 的 seed、`add-meter-links.py` 三份錶清單各自維護。

完整評估過程還包含一次上傳失敗的插曲（tar 檔案損毀重傳兩次才成功），提醒之後打包/傳輸這類操作要養成先驗證檔案大小的習慣。

## 開發模式：東昌先驗證，才推 ECI

Terry 在東昌（公司內）維護一套完整的平行 EMS 實例，跟 ECI 一樣的程式碼，透過 SSH tunnel 獨立連到 ECI 現場的同一批電表在採值，比 ECI 自己的實例更早開始運作。這套機制原本就是「東昌先確定沒問題，才更新到 ECI」的驗證站，這次重構的每一步都遵循這個流程：在東昌的分支上做、在東昌的真實環境驗證、確認無誤才打包送 ECI。

所有改動都在獨立分支 `refactor/core-base` 上進行，`master` 完全沒動，過程中隨時可以退回起點（`git tag eci-baseline-2026-09-28`）。

## 做了什麼：15 個 step

（完整 commit 訊息見 `git log --oneline 5130548..593a0ca`）

| Step | 內容 |
|---|---|
| 1 | migration runner（`scripts/migrate.sh`）+ baseline + `verify-baseline.sh` 驗證工具 |
| 2 | Grafana dashboard 時區修正（日分桶對齊當地午夜）+ 記錄 retention 暫停狀態 |
| 3 | 修 `dev-apply-host.sh`：改成同步內容而非刪除重建資料夾（避免弄壞 Grafana 的 bind mount） |
| 4 | `report-electricity` 報表範圍起訖也改用當地時區計算（step2 只修了分桶對齊，範圍起訖當時漏了） |
| 5 | 刪除兩個未使用的測試產物 dashboard |
| 6 | **A2 核心修正**：新增 `consumption_kwh`/`consumption_m3` SQL function（用「這桶最後一筆減上一桶最後一筆」取代會漏算的逐桶 MAX-MIN），接上 `energy-overview`、`power-meter-detail` |
| 7 | 10 年趨勢保留（`hourly_last_electricity`/`hourly_last_water` continuous aggregate）+ raw 保留期改 360 天 + 30 天後壓縮，同時移除 5 個未使用的舊 continuous aggregate |
| 8 | 本機備份腳本（`pg_dump`，保留 14 天，可選離場暫存路徑） |
| 9 | 備份/還原文件（含實際演練發現的兩個 TimescaleDB 還原陷阱：`--no-owner`、外鍵 `ONLY` 語法問題） |
| 10 | `report-electricity` 也接上 `consumption_kwh`（跟 step6 用同一套邏輯，三張表統一） |
| 11 | 現場部署腳本 `scripts/deploy-site.sh`（備份→重建容器→套用 migration→驗證，且不會自動 adopt，強制人工先跑 `verify-baseline.sh` 確認） |
| 12 | 版本清單機制（`releases/core-1.0.0.env` + `sites/eci/site.env`），collector/api/timescaledb/grafana/nginx 五個服務各自可獨立標版本 |
| 13 | 修 `verify-baseline.sh` 的版本解析（step12 改了 `docker-compose.yml` 寫法後，舊的 grep/awk 解析方式失效） |
| 14 | 修 nginx 502：容器重建後 IP 改變，nginx 沒重啟導致轉發失敗（改用 `resolver` 動態解析 + `deploy-site.sh` 加保險重建） |
| 15 | 修 nginx `/api/` 轉發丟路徑：變數形式的 `proxy_pass` 若後面接固定路徑，會把使用者請求的子路徑整個丟掉 |

## 部署過程中的意外與教訓

這次部署（含東昌驗證與 ECI 正式上線）遇到的問題，全部記錄在 `docs/operational-gotchas.md`（若尚未建立，建議把下面幾點併入）：

1. **`docker compose restart` 對「檔案被覆蓋（而非原地修改）的 bind mount」會失敗**——`git apply`、`tar` 解壓縮都是「產生新檔案覆蓋舊檔案」，容器原本記住的掛載參照會失效，報 `error mounting ... no such file or directory`。修法：用 `docker compose up -d --force-recreate <service>`，不要用 `restart`。這個坑在 Grafana、nginx 各踩過一次。
2. **nginx `proxy_pass` 用變數（動態解析必須）時，變數後面不能接任何固定路徑片段**——會把使用者請求的子路徑整段丟掉，只留下寫死的那段。要嘛完全不接路徑（讓完整原始路徑透傳），要嘛用其他方式處理路徑重寫。
3. **版本清單只在腳本執行的當下生效**——`deploy-site.sh` 內部 `source` 版本清單，但這不會留在互動式 shell 裡。手動下 `docker compose` 指令前，要先自己 `source releases/<release>.env`，不然 build 出來的 image 版本標籤會退回預設值。
4. **ECI 現場其實有自己獨立的 git repo**，過去完全沒被東昌注意到，最後一筆 commit 停在 2026-07-24，藏著一個東昌不知道的客製化（`/grafana-dev/` nginx 轉發，連到跑在 Windows 主機上的另一個 Grafana）。這次順手把它同步進主線、確認客製化已淘汰不需要。這也是「tar 覆蓋式部署」的固有風險：ECI 現場任何沒有回報的手動修改，都可能在下次部署時被無聲蓋掉，而且不會有任何錯誤訊息告訴你。

## 目前狀態（2026-09-30）

- ECI 現場已完整部署 step1~15，經過驗證：A2 用量修正、時區修正、migration 機制、10 年趨勢、備份/還原演練、版本清單、nginx 修正全數生效。
- 東昌 `refactor/core-base` 已（或即將）合併回 `master`。
- `docs/migrations.md`、`docs/backup-restore.md`、本檔、以及更新流程文件（見 `docs/update-runbook.md`）是這次重構留下的主要文件資產。

## 還沒做、之後可以考慮的方向

- **`site.json` + `profiles.js`**：這是這次重構最初設定的下一階段目標——把 `config.js`、SQL seed、`add-meter-links.py` 三份錶清單統一成單一設定檔，並抽出型號 register map，讓新場域能透過設定檔複製，不用改程式碼。目前 `sites/eci/` 只有 migration 和 release 指標，還沒走到這一步。
- **離場備份**：東昌本身已是強保護（獨立、更早開始採集的平行實例），ECI 本機備份也已建立，「把 ECI 備份 scp 拉回東昌」這條路徑目前只留了接口（`OFFSITE_DIR`），沒有實際啟用，優先度不高。
- **ECI 獨立 git repo 的長期處理方式**：目前只是同步了一次，沒有真正整併或建立固定的定期比對流程，見 `docs/update-runbook.md` 的建議。
- **第二個客戶的設備協定**：若非全 Modbus TCP，profile 設計需要多一層 transport 抽象，及早確認可以少走彎路。
