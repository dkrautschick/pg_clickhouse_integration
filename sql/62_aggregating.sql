-- AggregatingMergeTree: stores partial aggregate states (sumState) that are combined at merge and query time (sumMerge).
-- Fed by a materialized view, so the roll-up is maintained on every INSERT into the raw table.
DROP VIEW  IF EXISTS ${CH_DB}.e_agg_mv SYNC;
DROP TABLE IF EXISTS ${CH_DB}.e_agg SYNC;
DROP TABLE IF EXISTS ${CH_DB}.e_agg_raw SYNC;
CREATE TABLE ${CH_DB}.e_agg_raw (beer_name String, country String, liters Float32, sold_at DateTime)
ENGINE = MergeTree ORDER BY (country, sold_at);
CREATE TABLE ${CH_DB}.e_agg (country String, liters AggregateFunction(sum, Float32))
ENGINE = AggregatingMergeTree ORDER BY country;
CREATE MATERIALIZED VIEW ${CH_DB}.e_agg_mv TO ${CH_DB}.e_agg AS
SELECT country, sumState(liters) AS liters FROM ${CH_DB}.e_agg_raw GROUP BY country;

INSERT INTO ${CH_DB}.e_agg_raw VALUES ('Chimay', 'BE', 12.5, now()), ('Duvel', 'BE', 15, now()), ('Weizen', 'DE', 9, now());
INSERT INTO ${CH_DB}.e_agg_raw VALUES ('Orval', 'BE', 20, now());
