-- ReplacingMergeTree: one row per sorting key, the one with the highest version. Deduplication happens during merges.
DROP TABLE IF EXISTS <CH_DB>.e_replacing SYNC;
CREATE TABLE <CH_DB>.e_replacing (id UInt64, beer_name String, liters Float32, version UInt64)
ENGINE = ReplacingMergeTree(version) ORDER BY id;

INSERT INTO <CH_DB>.e_replacing VALUES (1, 'Chimay', 12.5, 1), (2, 'Duvel', 15, 1);
INSERT INTO <CH_DB>.e_replacing VALUES (1, 'Chimay', 13.0, 2);   -- the "update": same key, higher version
