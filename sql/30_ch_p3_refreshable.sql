-- Path 3: ClickHouse keeps its own copy and refreshes it on a schedule it runs itself. No cron, no Airflow, no dbt.
-- The source is the PostgreSQL-engine table from path 2; the target is a normal MergeTree table.
CREATE TABLE IF NOT EXISTS ${CH_DB}.p3_copy
(
    id          Int64,
    sold_at     DateTime64(6, 'UTC'),
    country     String,
    beer_name   String,
    channel     String,
    customer_id Int32,
    liters      Float64,
    price_eur   Float64,
    updated_at  DateTime64(6, 'UTC')
)
ENGINE = MergeTree
ORDER BY (country, sold_at);

-- Every refresh replaces the contents of p3_copy atomically (readers see the old or the new copy, never half).
-- 10 SECOND keeps the demo watchable; use EVERY 5 MINUTE or similar in real life.
CREATE MATERIALIZED VIEW IF NOT EXISTS ${CH_DB}.p3_refresh
REFRESH EVERY 10 SECOND
TO ${CH_DB}.p3_copy AS
SELECT * FROM ${CH_DB}.p2_pg_beer_sales;
