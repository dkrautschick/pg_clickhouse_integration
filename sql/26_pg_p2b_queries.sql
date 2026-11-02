-- Path 2b: the query runs in ClickHouse, only the result comes back. Look for ONE Foreign Scan in the plan.
EXPLAIN (VERBOSE, COSTS OFF)
SELECT country, round(sum(liters)::numeric) AS liters FROM ch.p1_csv GROUP BY country ORDER BY liters DESC LIMIT 3;

SELECT country, round(sum(liters)::numeric) AS liters FROM ch.p1_csv GROUP BY country ORDER BY liters DESC LIMIT 3;
