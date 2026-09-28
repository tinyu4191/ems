# legacy-init（已停用，僅供參考）

原本由 docker-compose 掛載到 `/docker-entrypoint-initdb.d`，只在「空的 volume 第一次啟動」時執行。
schema 現在改由 `migrations/`（+ `sites/<id>/migrations/`）搭配 `scripts/migrate.sh` 管理，
`migrations/core/000_baseline.sql` 即由這裡的 01_init.sql + 02_monitoring.sql 整理而來。
