-- One-off repair for MISO market_intervals written before the operating-date fix.
-- Old rows used the UTC date and "America/Chicago"; MISO operating days are EST (UTC-5).
-- Rows touched by a new ingest are corrected automatically; this fixes the rest.
-- TIMESTAMP values convert through the session zone; pin it to UTC.
SET time_zone = '+00:00';

UPDATE market_intervals
SET operatingDate = DATE_FORMAT(DATE_SUB(intervalStartUtc, INTERVAL 5 HOUR), '%Y-%m-%d'),
    timezone = 'Etc/GMT+5'
WHERE market = 'MISO';
