-- What a part looks like and what a query really reads.
SELECT name AS part, rows, marks AS granules, round(rows / marks) AS rows_per_granule,
       formatReadableSize(primary_key_bytes_in_memory) AS index_in_ram
FROM system.parts WHERE database = '<CH_DB>' AND table = 'b_sales' AND active;

SELECT name AS column, formatReadableSize(data_uncompressed_bytes) AS raw, formatReadableSize(data_compressed_bytes) AS compressed,
       round(data_uncompressed_bytes / data_compressed_bytes, 1) AS ratio
FROM system.columns WHERE database = '<CH_DB>' AND table = 'b_sales';

-- Granules: x/y shows how much the sparse index skips when WHERE hits the ORDER BY key.
EXPLAIN indexes = 1 SELECT sum(liters) FROM <CH_DB>.b_sales WHERE country = 'DE';
