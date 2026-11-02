-- Null: writes are dropped, reads return nothing. With a materialized view it is a transformation sink:
-- the raw rows are consumed by the view, only the parsed result is stored.
DROP VIEW  IF EXISTS ${CH_DB}.e_null_mv SYNC;
DROP TABLE IF EXISTS ${CH_DB}.e_null_parsed SYNC;
DROP TABLE IF EXISTS ${CH_DB}.e_null_raw SYNC;
CREATE TABLE ${CH_DB}.e_null_raw (payload String) ENGINE = Null;
CREATE TABLE ${CH_DB}.e_null_parsed (n UInt32) ENGINE = MergeTree ORDER BY n;
CREATE MATERIALIZED VIEW ${CH_DB}.e_null_mv TO ${CH_DB}.e_null_parsed AS SELECT toUInt32(payload) AS n FROM ${CH_DB}.e_null_raw;

INSERT INTO ${CH_DB}.e_null_raw VALUES ('1'), ('2'), ('3');
