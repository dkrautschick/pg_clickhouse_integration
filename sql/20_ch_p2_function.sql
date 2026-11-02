-- Path 2a: the postgresql() table function. One-off, ad hoc, credentials inline.
SELECT country, round(sum(liters)) AS liters, count() AS sales
FROM postgresql('${PG_ADDR_FROM_CH}', '${PG_DB}', 'beer_sales', '${PG_RO_USER}', '${PG_RO_PASSWORD}')
GROUP BY country ORDER BY liters DESC LIMIT 5;
