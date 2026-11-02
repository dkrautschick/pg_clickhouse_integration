-- The indexes a sensible PostgreSQL setup has: primary key plus (country, sold_at), the counterpart of ORDER BY in ClickHouse.
ALTER TABLE beer_sales ADD PRIMARY KEY (id);
CREATE INDEX beer_sales_country_sold_at ON beer_sales (country, sold_at);
VACUUM ANALYZE beer_sales;
