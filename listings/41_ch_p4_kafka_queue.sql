-- Path 4: the Kafka engine table. It stores nothing, it is a consumer. JSONAsString puts each whole message
-- into the single String column `payload`, the materialized view in 40_ch_p4_target.sql picks it apart.
CREATE TABLE IF NOT EXISTS <CH_DB>.<P4_PREFIX>_queue
(
    payload String
)
ENGINE = Kafka
SETTINGS
    kafka_broker_list = '<KAFKA_BROKER_FROM_CH>',
    kafka_topic_list  = 'cdc.public.beer_sales',
    kafka_group_name  = 'clickhouse-beer',
    kafka_format      = 'JSONAsString',
    kafka_num_consumers = 1;
