-- Path 2b: a permanent table with ENGINE = PostgreSQL. Looks like any table, stores nothing.
CREATE TABLE IF NOT EXISTS ${CH_DB}.p2_pg_beer_sales
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
ENGINE = PostgreSQL('${PG_ADDR_FROM_CH}', '${PG_DB}', 'beer_sales', '${PG_RO_USER}', '${PG_RO_PASSWORD}');
