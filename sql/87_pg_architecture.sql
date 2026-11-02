-- PostgreSQL: who is running? One backend per connection plus the housekeeping processes.
SELECT backend_type, count(*) FROM pg_stat_activity GROUP BY backend_type ORDER BY backend_type;

-- The knobs behind the pictures: page cache, parallel query, checkpoints.
SELECT name, setting, unit FROM pg_settings
WHERE name IN ('shared_buffers', 'max_parallel_workers_per_gather', 'max_worker_processes', 'wal_level',
               'checkpoint_timeout', 'max_wal_size', 'autovacuum', 'autovacuum_max_workers', 'max_connections')
ORDER BY name;

-- Dead row versions (MVCC) waiting for autovacuum.
SELECT relname, n_live_tup, n_dead_tup, last_autovacuum FROM pg_stat_user_tables WHERE relname = 'beer_sales';
