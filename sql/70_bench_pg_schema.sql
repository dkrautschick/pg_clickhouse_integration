-- Benchmark: the same table in PostgreSQL and ClickHouse (types as close as the two systems allow).
CREATE TABLE beer_sales (
    id          bigint           NOT NULL,
    sold_at     timestamp        NOT NULL,
    country     text             NOT NULL,
    beer_name   text             NOT NULL,
    channel     text             NOT NULL,
    customer_id int              NOT NULL,
    liters      double precision NOT NULL,
    price_eur   double precision NOT NULL
);
