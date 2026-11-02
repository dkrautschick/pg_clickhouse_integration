-- PostgreSQL: the demo table. One fact table is enough to show every path.
CREATE TABLE IF NOT EXISTS beer_sales (
    id          bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    sold_at     timestamptz      NOT NULL DEFAULT now(),
    country     text             NOT NULL,
    beer_name   text             NOT NULL,
    channel     text             NOT NULL,
    customer_id int              NOT NULL,
    liters      double precision NOT NULL,
    price_eur   double precision NOT NULL,
    updated_at  timestamptz      NOT NULL DEFAULT now()
);
