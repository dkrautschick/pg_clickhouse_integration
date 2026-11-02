-- The query pipeline: lanes (the xN) are parallel threads working on different granule ranges. N = max_threads = cores by default.
SELECT name, value FROM system.settings WHERE name IN ('max_threads', 'max_block_size', 'max_insert_block_size');
EXPLAIN PIPELINE SELECT country, sum(liters) FROM <CH_DB>.p1_csv GROUP BY country;
