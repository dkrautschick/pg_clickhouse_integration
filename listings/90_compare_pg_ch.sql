-- Does the copy match the original? Run the PostgreSQL half in psql, the ClickHouse half in clickhouse-client, compare the output.
-- PostgreSQL:
SELECT count(*) AS rows, round(sum(liters)::numeric, 1) AS liters, round(sum(price_eur)::numeric, 1) AS eur FROM beer_sales;
-- ClickHouse (use FINAL for the CDC table of path 4, plain table for paths 1 and 3):
-- SELECT count() AS rows, round(sum(liters), 1) AS liters, round(sum(price_eur), 1) AS eur FROM <CH_DB>.p3_copy;
