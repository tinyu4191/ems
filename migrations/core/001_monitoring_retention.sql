-- 監控表原本沒有 retention：gateway_connection_status 每天約 6.9 萬列（現場已 400MB+）。
-- 告警查詢只看最近 5~10 分鐘，90 天足夠除錯用。
SELECT add_retention_policy('collector_heartbeat',        INTERVAL '90 days', if_not_exists => true);
SELECT add_retention_policy('gateway_connection_status',  INTERVAL '90 days', if_not_exists => true);
