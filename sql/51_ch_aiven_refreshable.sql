-- Path 5 on Aiven: the integration database ${AIVEN_SRC} mirrors the PostgreSQL schema inside ClickHouse.
-- Querying it works like path 2; this adds a refreshable local copy like path 3. Aiven ClickHouse replicates
-- every MergeTree table across the nodes of the service, ReplicatedMergeTree() is the explicit spelling.
CREATE TABLE IF NOT EXISTS ${CH_DB}.p5_copy
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
ENGINE = ReplicatedMergeTree()
ORDER BY (country, sold_at);

CREATE MATERIALIZED VIEW IF NOT EXISTS ${CH_DB}.p5_refresh
REFRESH EVERY 30 SECOND
TO ${CH_DB}.p5_copy AS
SELECT * FROM `${AIVEN_SRC}`.beer_sales;
