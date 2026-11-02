-- Path 4 (the ClickHouse half): the target table, the consumer and a view with the current state.
-- <P4_PREFIX>_queue is the Kafka engine table from 41_ch_p4_kafka_queue.sql (or a stand-in in the transform test).

-- ReplacingMergeTree(version, is_deleted): an UPDATE is an INSERT with a higher version (the WAL position,
-- source.lsn), a DELETE is an INSERT with is_deleted = 1. Old versions disappear when parts merge.
CREATE TABLE IF NOT EXISTS <CH_DB>.<P4_PREFIX>_cdc
(
    id          Int64,
    sold_at     DateTime64(6, 'UTC'),
    country     String,
    beer_name   String,
    channel     String,
    customer_id Int32,
    liters      Float64,
    price_eur   Float64,
    updated_at  DateTime64(6, 'UTC'),
    _version    UInt64,
    _is_deleted UInt8
)
ENGINE = ReplacingMergeTree(_version, _is_deleted)
ORDER BY id;

-- The consumer: parse the Debezium envelope {"before":..,"after":..,"source":{"lsn":..},"op":"c|u|d|r"}.
-- Deletes carry the key in "before" (replica identity = primary key), everything else in "after".
CREATE MATERIALIZED VIEW IF NOT EXISTS <CH_DB>.<P4_PREFIX>_consumer
TO <CH_DB>.<P4_PREFIX>_cdc AS
SELECT
    if(op = 'd', JSONExtractInt(payload, 'before', 'id'), JSONExtractInt(payload, 'after', 'id'))     AS id,
    parseDateTime64BestEffortOrZero(JSONExtractString(payload, 'after', 'sold_at'), 6, 'UTC')           AS sold_at,
    JSONExtractString(payload, 'after', 'country')                                                      AS country,
    JSONExtractString(payload, 'after', 'beer_name')                                                    AS beer_name,
    JSONExtractString(payload, 'after', 'channel')                                                      AS channel,
    JSONExtractInt(payload, 'after', 'customer_id')                                                     AS customer_id,
    JSONExtractFloat(payload, 'after', 'liters')                                                        AS liters,
    JSONExtractFloat(payload, 'after', 'price_eur')                                                     AS price_eur,
    parseDateTime64BestEffortOrZero(JSONExtractString(payload, 'after', 'updated_at'), 6, 'UTC')        AS updated_at,
    JSONExtractUInt(payload, 'source', 'lsn')                                                           AS _version,
    toUInt8(op = 'd')                                                                                   AS _is_deleted
FROM
(
    SELECT payload, JSONExtractString(payload, 'op') AS op FROM <CH_DB>.<P4_PREFIX>_queue
)
WHERE op IN ('c', 'u', 'd', 'r');

-- What an application reads: the latest version of every row that is not deleted.
CREATE VIEW IF NOT EXISTS <CH_DB>.<P4_PREFIX>_current AS
SELECT * EXCEPT (_version, _is_deleted) FROM <CH_DB>.<P4_PREFIX>_cdc FINAL WHERE _is_deleted = 0;
