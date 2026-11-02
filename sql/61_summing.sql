-- SummingMergeTree: rows with the same sorting key become one row with the numeric columns summed (at merge time).
DROP TABLE IF EXISTS ${CH_DB}.e_summing SYNC;
CREATE TABLE ${CH_DB}.e_summing (day Date, country String, liters Float64)
ENGINE = SummingMergeTree ORDER BY (country, day);

INSERT INTO ${CH_DB}.e_summing VALUES ('2026-10-01', 'BE', 10), ('2026-10-01', 'BE', 5), ('2026-10-01', 'DE', 7);
