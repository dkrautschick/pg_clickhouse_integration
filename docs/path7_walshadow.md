# Path 7 (outlook): WalShadow

Nothing in this repository runs it yet, which is the honest part. WalShadow is an open-source engine (AGPL v3, development preview, v0.1.x as of the 28 September 2026 release) from ClickHouse that replicates PostgreSQL data from the
**physical** WAL (the stream a standby consumes) into ClickHouse-native blocks: no logical decoding output plugin, no replication slot, no Kafka, no JSON.
[Announcement (10 September 2026)](https://clickhouse.com/blog/introducing-walshadow), [repository](https://github.com/ClickHouse/walshadow),
[private preview on ClickHouse Managed Postgres](https://clickhouse.com/cloud/postgres/walshadow).

- Four stages: track the live schema through a schema-only shadow Postgres, decode heap records in parallel (Rust), build ClickHouse-native blocks, insert in parallel.
- Every row carries its source WAL position (`_lsn`), ClickHouse keeps the latest version per key (the same `ReplacingMergeTree` idea as in `sql/40_ch_p4_target.sql`).
- Vendor benchmark from the announcement (one table, one region, results vary): about 200 ms from commit to visible, 289,000 rows/s sustained.
- The catch: it needs the physical WAL, and most managed PostgreSQL services do not expose that to customers.
- It still needs `wal_level = logical` and a usable replica identity on every replicated table, and a shadow Postgres of the same major version as the source. Sequence values are not replicated, and unplanned primary promotion is not supported (limitations as documented in the repository and discussed in the community; check the repository's limitations doc before you plan).
- The repository ships release binaries (Linux x86_64 and aarch64) and a container image; start with its quickstart document.

Check the status before you plan around it. When it becomes something you can run, a `scripts/70_...` style script and listing will land here.
