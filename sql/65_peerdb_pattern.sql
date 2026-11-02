-- The shape of a table that PeerDB (or ClickPipes Postgres CDC) creates in ClickHouse, rebuilt by hand so you can
-- play with it without running PeerDB. See docs/path6_peerdb.md.
-- An UPDATE arrives as a new row with a higher _peerdb_version, a DELETE as a new row with _peerdb_is_deleted = 1.
DROP VIEW  IF EXISTS ${CH_DB}.e_peerdb_beer_sales_current;
DROP TABLE IF EXISTS ${CH_DB}.e_peerdb_beer_sales SYNC;
CREATE TABLE ${CH_DB}.e_peerdb_beer_sales
(
    id                 Int64,
    country            String,
    beer_name          String,
    liters             Float64,
    _peerdb_synced_at  DateTime64(9) DEFAULT now64(),
    _peerdb_is_deleted Int8,
    _peerdb_version    Int64
)
ENGINE = ReplacingMergeTree(_peerdb_version)
PRIMARY KEY id
ORDER BY id;

-- one INSERT per "sync batch", like the real pipeline
INSERT INTO ${CH_DB}.e_peerdb_beer_sales (id, country, beer_name, liters, _peerdb_is_deleted, _peerdb_version) VALUES (1, 'BE', 'Orval', 25, 0, 1), (2, 'BE', 'Chimay', 12.5, 0, 1);
INSERT INTO ${CH_DB}.e_peerdb_beer_sales (id, country, beer_name, liters, _peerdb_is_deleted, _peerdb_version) VALUES (1, 'BE', 'Orval', 30, 0, 2);   -- UPDATE of id 1
INSERT INTO ${CH_DB}.e_peerdb_beer_sales (id, country, beer_name, liters, _peerdb_is_deleted, _peerdb_version) VALUES (2, 'BE', 'Chimay', 12.5, 1, 2); -- DELETE of id 2

-- "Query it like Postgres": FINAL + filter out the deletes. A view hides the pattern from analysts.
-- (A row policy does the same without a view: CREATE ROW POLICY cdc_policy ON t FOR SELECT USING _peerdb_is_deleted = 0 TO ALL;)
CREATE VIEW ${CH_DB}.e_peerdb_beer_sales_current AS
SELECT * FROM ${CH_DB}.e_peerdb_beer_sales FINAL WHERE _peerdb_is_deleted = 0;
