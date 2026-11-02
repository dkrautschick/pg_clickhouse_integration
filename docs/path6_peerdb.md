# Path 6 (supplement): PeerDB and ClickPipes Postgres CDC

Not one of the five paths of the talk, but the question that came up most in the Q&A: *"What about PeerDB?"*

**What it is.** PeerDB is an open-source ETL/ELT tool built for PostgreSQL ([repository](https://github.com/PeerDB-io/peerdb),
[docs](https://docs.peerdb.io)). ClickHouse acquired the company in 2024. Its CDC mirror reads the PostgreSQL WAL through a logical replication
slot, so it is the same Postgres feature as Debezium (path 4), but as a purpose-built pipeline from PostgreSQL to ClickHouse instead of
Debezium + Kafka + Kafka engine + materialized view. Inside ClickHouse Cloud the same engine runs as **ClickPipes Postgres CDC**.
Per its README the actively maintained destinations are ClickHouse (including ClickHouse Cloud) and PostgreSQL; the other destination
connectors (Snowflake, BigQuery, Kafka, ...) are marked deprecated. Check the README for the current state before you rely on it.

**How it works** (following the PeerDB docs for a Postgres to ClickHouse CDC mirror):

1. You define a *source peer* (PostgreSQL) and a *destination peer* (ClickHouse) and create a *mirror*.
2. **Initial snapshot** of the selected tables, in parallel partitions if you want (default 500,000 rows per partition).
3. **Continuous sync** from the WAL: a publication and a replication slot (PeerDB can create both). The slot is consumed continuously,
   because a slot nobody reads makes PostgreSQL keep WAL until the disk is full (same warning as for Debezium).
4. Changes are **staged** (S3, MinIO in the docker compose setup) and **applied to ClickHouse in batches**; the sync interval defaults to 60 seconds in the open-source docs.
5. The open-source stack runs as containers (a Postgres catalog, Temporal, the PeerDB server, flow API and workers, a UI) and has a PostgreSQL-compatible SQL interface for peers and mirrors.

**What lands in ClickHouse.** Each source table becomes a `ReplacingMergeTree(_peerdb_version)` table ordered by the Postgres primary key, with the
columns `_peerdb_version`, `_peerdb_is_deleted` and `_peerdb_synced_at`. An `UPDATE` is an insert with a higher version, a `DELETE` an insert with `_peerdb_is_deleted = 1`.
Old versions disappear when parts merge, so queries use `FINAL` and filter `_peerdb_is_deleted = 0`, usually hidden behind a view or a row policy.
`scripts/65_peerdb_pattern.sh` rebuilds exactly that table shape by hand so you can try the queries without running PeerDB.

**Two ways to run it.** Self-run open source (the repository carries the GNU AGPL v3 licence; ClickHouse itself is Apache-2.0, so have your legal team look at the terms if you modify
it or offer it as a service), or ClickPipes Postgres CDC in ClickHouse Cloud.

**Where it fits.**

| | Path 3 refreshable MV | Path 4 Debezium + Kafka | Path 6 PeerDB | Path 5 Aiven integration |
|---|---|---|---|---|
| Freshness | refresh interval | seconds or less | tens of seconds (vendor claim) | query time (live) |
| Moving parts | none | PostgreSQL, Debezium, Kafka, ClickHouse | PostgreSQL, PeerDB (several containers), ClickHouse | managed |
| Updates and deletes | full copy replaces everything | you model them (ReplacingMergeTree) | versions + delete flag built in | live reads, nothing to model |

The ClickHouse announcement of WalShadow measured PeerDB at around 10 seconds from commit to visible and about 120,000 rows/s in its own benchmark
(vendor numbers, one setup). See `docs/path7_walshadow.md`.

Links: [PeerDB README](https://github.com/PeerDB-io/peerdb) · [CDC mirror docs](https://docs.peerdb.io/mirror/cdc-pg-clickhouse) ·
[ClickPipes Postgres](https://clickhouse.com/docs/integrations/clickpipes/postgres) ·
[deduplication strategies](https://clickhouse.com/docs/integrations/clickpipes/postgres/deduplication) ·
[data modeling tips](https://clickhouse.com/blog/postgres-to-clickhouse-data-modeling-tips-v2)
