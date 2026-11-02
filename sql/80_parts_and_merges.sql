-- Every (synchronous) INSERT creates a part. Merges (here: stopped, then forced) combine them.
-- async_insert = 0 keeps the demo honest: with asynchronous inserts (the default in recent versions) ClickHouse may
-- buffer several small INSERTs and write them as ONE part.
DROP TABLE IF EXISTS ${CH_DB}.b_sales SYNC;
CREATE TABLE ${CH_DB}.b_sales (beer_name String, country String, liters Float32, sold_at DateTime)
ENGINE = MergeTree ORDER BY (country, sold_at);

SYSTEM STOP MERGES ${CH_DB}.b_sales;
INSERT INTO ${CH_DB}.b_sales SETTINGS async_insert = 0 VALUES ('Chimay', 'BE', 12.5, now());
INSERT INTO ${CH_DB}.b_sales SETTINGS async_insert = 0 VALUES ('Leffe bruin', 'BE', 9.0, now());
INSERT INTO ${CH_DB}.b_sales SETTINGS async_insert = 0 VALUES ('Duvel', 'BE', 15.0, now());
