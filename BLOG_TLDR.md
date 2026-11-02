# TL;DR: Stop torturing PostgreSQL

- **The problem:** PostgreSQL is a row store. Summing one column over hundreds of millions of rows reads every row, and more indexes, materialized views and hardware only move the wall.
- **The sidekick:** ClickHouse, an open-source (Apache 2.0) column store. Same table, same SQL, one CPU: `count(*)` 98 ms vs 1 ms, top customers 1.2 s vs 81 ms; the point lookup by primary key 0.03 ms vs 4 ms, so PostgreSQL stays the source of truth.
- **Six ways to feed it:** CSV (stale on arrival), query federation (live, PostgreSQL pays per query), `pg_clickhouse` (PostgreSQL queries ClickHouse), refreshable materialized view (ClickHouse pulls a copy on its own schedule, no cron), Kafka CDC with Debezium (row-level, you run Kafka), Aiven's built-in integrations (the platform runs it). Supplement: PeerDB / ClickPipes.
- **The traps:** "materialized view" is a trigger in ClickHouse and a snapshot in PostgreSQL; CDC targets are `ReplacingMergeTree` tables that need `FINAL`; an unconsumed replication slot fills your disk; tiny INSERTs make tiny parts.
- **The rule:** start with federation, graduate to a refreshable copy, graduate to CDC when the refresh interval hurts. Every script is in [dkrautschick/pg_clickhouse_integration](https://github.com/dkrautschick/pg_clickhouse_integration) and checks its own result.
