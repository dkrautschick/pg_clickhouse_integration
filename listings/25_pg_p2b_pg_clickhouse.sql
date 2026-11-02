-- Path 2b: pg_clickhouse. Run this IN POSTGRESQL (psql), not in ClickHouse. Postgres asks, ClickHouse answers.
-- Syntax follows the official tutorial: https://github.com/ClickHouse/pg_clickhouse/blob/main/doc/tutorial.md
CREATE EXTENSION IF NOT EXISTS pg_clickhouse;

-- 'binary' = ClickHouse native protocol (port 9000), 'http' = HTTP interface (port 8123)
CREATE SERVER IF NOT EXISTS beer_ch FOREIGN DATA WRAPPER clickhouse_fdw
    OPTIONS (driver 'binary', host '<CH_HOST>', port '<CH_PORT>', dbname '<CH_DB>');

CREATE USER MAPPING IF NOT EXISTS FOR CURRENT_USER SERVER beer_ch OPTIONS (user '<CH_USER>');

CREATE SCHEMA IF NOT EXISTS ch;
IMPORT FOREIGN SCHEMA "<CH_DB>" FROM SERVER beer_ch INTO ch;
