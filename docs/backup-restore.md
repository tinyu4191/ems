# 備份與還原

## 備份

排程執行 `scripts/backup.sh`（用法、環境變數、Windows 工作排程器設定見腳本開頭的註解）。

備份用 `pg_dump -Fc`（自訂格式），跑的時候會看到三則 `circular foreign-key constraints` 警告：

```
pg_dump: warning: there are circular foreign-key constraints on this table:
pg_dump: detail: hypertable / chunk / continuous_agg
```

這是 **TimescaleDB 的已知行為**（它的內部系統表互相參照），不是資料或腳本有問題，可以忽略。

## 還原（已於 2026-09-29 實際演練驗證過）

**永遠先在拋棄式測試容器上還原，不要直接對正式容器動手。**

```bash
# 1. 開一個獨立、跟正式環境同版本的 TimescaleDB 容器
docker run -d --name ems-restore-test -e POSTGRES_PASSWORD=test timescale/timescaledb:2.26.3-pg16
sleep 10

# 2. 建立空的測試資料庫（TimescaleDB 官方 image 的 template1 已內建擴充功能，
#    新建的資料庫會自動繼承，不需要再手動 CREATE EXTENSION）
docker exec ems-restore-test psql -U postgres -c "CREATE DATABASE ems_test"

# 3. 把備份檔案複製進容器（pg_restore 在容器裡執行，備份檔案要先送進去）
docker cp <備份檔案路徑> ems-restore-test:/tmp/backup.dump

# 4. 還原（--no-owner：目標環境不一定有 admin 這個帳號，
#    加這個參數讓還原後的擁有者直接算作目前執行還原的帳號，不嘗試恢復原本的 admin）
docker exec ems-restore-test pg_restore -U postgres -d ems_test --no-owner /tmp/backup.dump
```

**這一步只執行一次，不要重複執行或中途按 Ctrl+C。** 這些時序資料表沒有主鍵防重複，
如果對同一個資料庫重複跑 `pg_restore`，資料会被重複貼上去，筆數會不斷疊加，
之後任何驗證都會失真——上次演練時就因為操作失誤跑了兩次，筆數從 674 萬跳到 1682 萬，
排查了一輪才確認是操作問題、不是備份本身壞掉。

跑完預期看到以下訊息，都可以忽略：

```
pg_restore: error: COPY failed for table "bgw_job": ERROR:  role "admin" does not exist
```
TimescaleDB 內部的排程任務記錄表，找不到 `admin` 這個帳號寫入擁有者欄位。
不影響任何實際資料；這些排程任務（retention/compression/continuous aggregate 刷新）
還原後不會恢復，之後跑一次 `MIGRATE_DIRS="migrations/core sites/eci/migrations" scripts/migrate.sh up`
會重新建立它們。

```
pg_restore: error: could not execute query: ERROR:  ONLY option not supported on hypertable operations
Command was: ALTER TABLE ONLY public.accumulator_electricity
    ADD CONSTRAINT accumulator_electricity_meter_id_fkey FOREIGN KEY ...
```
**這是需要手動補救的部分。** `pg_dump` 匯出一般 PostgreSQL 表的外鍵約束語法帶 `ONLY`，
但 TimescaleDB 的 hypertable（底層切成很多 chunk）不支援 `ONLY`，所以這幾個外鍵約束
不會被還原回來。資料本身沒有受影響，只是「meter_id 一定要對得到 meters 表」這個保護
暫時不存在。用不帶 `ONLY` 的語法手動補上（表名依還原時的錯誤訊息調整，以下是目前 5 張
會用到這個外鍵的表）：

```bash
docker exec ems-restore-test psql -U postgres -d ems_test -c "
ALTER TABLE accumulator_electricity ADD CONSTRAINT accumulator_electricity_meter_id_fkey FOREIGN KEY (meter_id) REFERENCES meters(meter_id);
ALTER TABLE accumulator_water ADD CONSTRAINT accumulator_water_meter_id_fkey FOREIGN KEY (meter_id) REFERENCES meters(meter_id);
ALTER TABLE realtime_electricity ADD CONSTRAINT realtime_electricity_meter_id_fkey FOREIGN KEY (meter_id) REFERENCES meters(meter_id);
ALTER TABLE realtime_steam ADD CONSTRAINT realtime_steam_meter_id_fkey FOREIGN KEY (meter_id) REFERENCES meters(meter_id);
ALTER TABLE realtime_water ADD CONSTRAINT realtime_water_meter_id_fkey FOREIGN KEY (meter_id) REFERENCES meters(meter_id);
"
```

## 驗證還原是否成功

```bash
docker exec ems-restore-test psql -U postgres -d ems_test -c "SELECT count(*) FROM meters"
docker exec ems-restore-test psql -U postgres -d ems_test -c "SELECT count(*) FROM accumulator_electricity"
docker exec ems-restore-test psql -U postgres -d ems_test -c "SELECT count(*) FROM hourly_last_electricity"
```

`meters` 應為 33。`accumulator_electricity` 應接近（但通常略少於，因為備份之後系統仍持續
寫入新資料）正式環境同一時間點跑 `SELECT count(*) FROM accumulator_electricity` 的結果——
差距可以用 collector 輪詢間隔換算成時間，判斷是否合理（2026-09-29 演練：備份後約 22 分鐘
的差距，換算筆數與時間差完全吻合）。`hourly_last_electricity` 應與正式環境一致（這是
continuous aggregate 的物化資料，不受備份時間點的新資料影響太大）。

## 清理

演練完成後刪除測試容器，不要留著：

```bash
docker rm -f ems-restore-test
```
