-- Path 1: a plain MergeTree table that receives the CSV. Nothing keeps it in sync.
CREATE TABLE IF NOT EXISTS <CH_DB>.p1_csv
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
ENGINE = MergeTree
ORDER BY (country, sold_at);
