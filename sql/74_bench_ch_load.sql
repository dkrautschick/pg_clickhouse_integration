INSERT INTO ${CH_DB}_bench.beer_sales
SELECT * FROM postgresql('${PG_ADDR_FROM_CH}', 'beerbench', 'beer_sales', '${PG_RO_USER}', '${PG_RO_PASSWORD}');
