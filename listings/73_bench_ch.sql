-- ClickHouse: same columns, ORDER BY is the index. Data arrives via INSERT ... SELECT from PostgreSQL (below).
CREATE DATABASE IF NOT EXISTS <CH_DB>_bench;
DROP TABLE IF EXISTS <CH_DB>_bench.beer_sales SYNC;
CREATE TABLE <CH_DB>_bench.beer_sales
(
    id          Int64,
    sold_at     DateTime,
    country     String,
    beer_name   String,
    channel     String,
    customer_id Int32,
    liters      Float64,
    price_eur   Float64
)
ENGINE = MergeTree
ORDER BY (country, sold_at);
