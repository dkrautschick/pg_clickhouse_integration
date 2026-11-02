-- ClickHouse: the thread pools and the current thread usage. Defaults and descriptions come from the server itself.
SELECT name, value, default, changed
FROM system.server_settings
WHERE name IN ('max_thread_pool_size', 'max_io_thread_pool_size', 'background_pool_size',
               'background_merges_mutations_concurrency_ratio', 'background_schedule_pool_size',
               'background_fetches_pool_size', 'background_move_pool_size', 'background_common_pool_size',
               'background_message_broker_schedule_pool_size', 'background_distributed_schedule_pool_size', 'max_connections')
ORDER BY name;

-- Live numbers: threads in the global pool, merge/mutation tasks, schedule-pool tasks, open connections.
SELECT metric, value FROM system.metrics
WHERE metric IN ('GlobalThread', 'GlobalThreadActive', 'BackgroundMergesAndMutationsPoolTask', 'BackgroundMergesAndMutationsPoolSize',
                 'BackgroundSchedulePoolTask', 'BackgroundSchedulePoolSize', 'TCPConnection', 'HTTPConnection')
ORDER BY metric;
