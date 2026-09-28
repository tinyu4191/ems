-- 監控基礎建設：collector 心跳 + gateway 連線狀態
-- 收斂自 ems-dev，對應 collector.js 的 gatewayStatusQuery / heartbeatQuery

CREATE TABLE collector_heartbeat (
    time               TIMESTAMPTZ NOT NULL,
    round_duration_ms  INTEGER,
    meters_success     INTEGER,
    meters_failed      INTEGER
);
SELECT create_hypertable('collector_heartbeat', 'time');

CREATE TABLE gateway_connection_status (
    time             TIMESTAMPTZ NOT NULL,
    gateway_name     TEXT NOT NULL,
    connection_type  TEXT NOT NULL,
    is_connected     BOOLEAN NOT NULL,
    error_message    TEXT
);
SELECT create_hypertable('gateway_connection_status', 'time');
