-- Path 2b, the simplest possible example. Run this IN POSTGRESQL (psql).
-- The SAME aggregate twice: first answered by PostgreSQL itself, then by ClickHouse through the foreign table in schema ch.
-- Nothing in the second query tells you that it leaves PostgreSQL, only the schema name differs.
SELECT country, round(sum(liters)::numeric) AS liters FROM public.beer_sales GROUP BY country ORDER BY liters DESC LIMIT 3;  -- PostgreSQL
SELECT country, round(sum(liters)::numeric) AS liters FROM ch.p1_csv         GROUP BY country ORDER BY liters DESC LIMIT 3;  -- ClickHouse
