# Stop torturing PostgreSQL: a ClickHouse sidekick, every path, as code

Companion repository for the talk *"Stop Torturing PostgreSQL: Why Your PostgreSQL Database Needs a ClickHouse Sidekick"*
(PGConf.EU Valencia 2026, DOAG K+A Nürnberg 2026) and the blog post in [`BLOG.md`](BLOG.md).

PostgreSQL stays the source of truth. ClickHouse takes the analytical scans that make the elephant sweat. The open question is how the
data gets from A to B, and this repository has a numbered, self-checking script for every answer the talk gives, plus the same steps as
copy-paste listings with placeholders, the Docker stack to run it all on a laptop, Terraform for the managed variant, and a benchmark
that puts the same table and the same SELECTs in both systems and prints milliseconds.

The demo table is `beer_sales` (who sold how many liters of which beer where), because every example database should contain at least one Trappist.

| Path | What it is | Freshness | Script |
|---|---|---|---|
| 1 | **The caveman way:** `\copy` out, `INSERT ... FORMAT CSVWithNames` in | stale the moment you press Enter | `10_path1_csv.sh` |
| 2 | **Query federation:** `postgresql()` table function, `ENGINE = PostgreSQL` table, PostgreSQL database engine | live, one round trip per query | `20_path2_federation.sh` |
| 2b | **Reverse federation:** `pg_clickhouse`, PostgreSQL queries ClickHouse through an FDW with pushdown | live | `25_path2b_pg_clickhouse.sh` |
| 3 | **Refreshable materialized view:** ClickHouse pulls a local copy on its own schedule | refresh interval | `30_path3_refreshable_mv.sh` |
| 4 | **Kafka CDC:** Debezium reads the WAL, Kafka carries events, the Kafka engine + a materialized view land them in `ReplacingMergeTree` | seconds | `40_path4_kafka_cdc.sh` (`41_test_cdc_transform.sh` without Kafka) |
| 5 | **The lazy way:** Aiven for PostgreSQL + Aiven for ClickHouse + one `clickhouse_postgresql` integration | live, plus an optional refreshable copy | `50_path5_aiven.sh` |
| 6 | **Supplement:** PeerDB / ClickPipes Postgres CDC, the table shape it produces | tens of seconds (vendor) | `65_peerdb_pattern.sh`, [`docs/path6_peerdb.md`](docs/path6_peerdb.md) |
| 7 | **Outlook:** WalShadow, physical WAL straight into ClickHouse | sub-second (vendor) | [`docs/path7_walshadow.md`](docs/path7_walshadow.md) |

Around the paths: `60_engines.sh` (table engines in action), `70_benchmark.sh` (PostgreSQL vs. ClickHouse, same SQL), `80_basics.sh`
(parts, merges, granules, compression), `85_architecture_tour.sh` (processes vs. thread pools, see [`docs/architecture.md`](docs/architecture.md)).

## Prerequisites

- `psql` (any recent PostgreSQL client package), `jq`, `envsubst` (package `gettext-base` on Debian/Ubuntu, `gettext` elsewhere)
- A ClickHouse client. The single binary does everything: `curl https://clickhouse.com/ | sh` gives you `./clickhouse`; set `CH_CLIENT="./clickhouse client"` in `.env`
  (the packages install `clickhouse-client`, then `CH_CLIENT=clickhouse-client`).
- A PostgreSQL and a ClickHouse to talk to. The quickest pair is the Docker stack below; your own servers work too.
- Path 4 needs Docker. Path 5 needs an Aiven account and the [Aiven CLI](https://aiven.io/docs/tools/cli) (`pip install aiven-client`, `avn user login`).

## Quick start

```bash
git clone https://github.com/dkrautschick/pg_clickhouse_integration && cd pg_clickhouse_integration
chmod +x scripts/*.sh                                  # GitHub's web upload drops the executable bits
cp .env.example .env                                   # defaults match the Docker stack
docker compose --env-file .env -f docker/compose.yml up -d --wait   # PostgreSQL 18 (wal_level=logical) + ClickHouse
# ClickHouse inside the stack reaches PostgreSQL as postgres:5432:
echo 'PG_ADDR_FROM_CH=postgres:5432' >> .env

scripts/01_seed.sh                   # database, table, read-only role, 200,000 rows
scripts/10_path1_csv.sh              # path 1: COPY out, INSERT in, watch it go stale
scripts/20_path2_federation.sh       # path 2: three ways to read PostgreSQL live from ClickHouse
scripts/30_path3_refreshable_mv.sh   # path 3: a local copy that refreshes itself
scripts/41_test_cdc_transform.sh     # path 4 without Kafka: Debezium events through the real consumer SQL
scripts/60_engines.sh                # ReplacingMergeTree, SummingMergeTree, AggregatingMergeTree, Null
scripts/80_basics.sh                 # parts, merges, granules, what a query reads
scripts/85_architecture_tour.sh      # processes and settings vs. thread pools and the pipeline
scripts/70_benchmark.sh              # the race: 7 queries, milliseconds, both systems (BENCH_ROWS, default 2,000,000)

scripts/run_all.sh                   # everything above except the benchmark; RUN_BENCH=yes adds it
scripts/99_cleanup.sh                # ClickHouse objects; DROP_PG=yes also the databases; STOP_STACK=yes docker compose down -v
```

### Path 4: Kafka and Debezium

```bash
docker compose --env-file .env -f docker/compose.yml -f docker/compose.kafka.yml up -d --wait
scripts/01_seed.sh                   # if not done yet
scripts/40_path4_kafka_cdc.sh        # registers the connector, waits for the snapshot, then INSERT / UPDATE / DELETE round trips
```

One single-node Kafka (KRaft, no ZooKeeper, `apache/kafka`), Debezium Connect (`quay.io/debezium/connect`), the connector JSON is in
`docker/debezium/pg-connector.json`. The ClickHouse side (`sql/40_ch_p4_target.sql`) parses the Debezium envelope into a
`ReplacingMergeTree(_version, _is_deleted)` table with `_version = source.lsn`; the view `p4_current` is what an application reads.

### Path 5: Aiven

```bash
echo 'AVN_PROJECT=my-project' >> .env
scripts/50_path5_aiven.sh            # two services, seed, one integration, read through it, add a refreshable copy
TERMINATE=yes scripts/99_cleanup.sh  # the services cost money while they run
```

`listings/50_aiven_cli.sh` has the `avn` commands one by one, `terraform/` the same as code (`var.with_kafka = true` adds Kafka and the
`clickhouse_kafka` integration).

### Path 2b: pg_clickhouse

Needs the extension in your PostgreSQL. Easiest: `docker run -d --network host --name pg_clickhouse -e POSTGRES_PASSWORD=beer ghcr.io/clickhouse/pg_clickhouse:18`
(the official PostgreSQL image plus the extension), point `PG_HOST/PG_PORT` at it, run `01_seed.sh` and `10_path1_csv.sh`, then
`25_path2b_pg_clickhouse.sh`. Without the extension the script explains that and exits 0.

## Listings: every step as a copy-paste snippet

`listings/` holds the same steps taken apart, one file per statement block, with placeholders (`<CH_DB>`, `<PG_ADDR_FROM_CH>`, `<AVN_PROJECT>`, ...)
instead of variables and no dependency on `00_lib.sh` or `.env`. The SQL files are generated from `sql/` by `scripts/build_listings.sh`, so a
listing is exactly the statement the scripts run; the shell listings (`10_csv_*.sh`, `40_*.sh`, `50_aiven_cli.sh`) are written by hand. Use them to
try one step in your own `psql` or `clickhouse-client`, or to understand what a script does before you trust it.

## What each script double-checks

| Script | Checks |
|---|---|
| `01_seed.sh` | `wal_level`, read-only role, row count equals the seed, ClickHouse reachable |
| `10_path1_csv.sh` | row count PostgreSQL = ClickHouse after the load; exactly the rows added afterwards are missing |
| `20_path2_federation.sh` | a row inserted in PostgreSQL is visible through the PostgreSQL engine immediately; federated vs. local timing |
| `25_path2b_pg_clickhouse.sh` | extension available, foreign tables imported, the plan contains a `Foreign Scan` |
| `30_path3_refreshable_mv.sh` | row count and `sum(liters)` equal after the first and after the next refresh, `system.view_refreshes` healthy |
| `40_path4_kafka_cdc.sh` | connector task `RUNNING`, slot active, snapshot arrives, INSERT / UPDATE / DELETE each show up in the current view |
| `41_test_cdc_transform.sh` | all versions kept in the raw table, `FINAL` view shows the latest state, deletes gone, timestamps parsed to the microsecond |
| `50_path5_aiven.sh` | services `RUNNING`, integration present, row count equal through the integration database and the local copy |
| `60_engines.sh` | duplicates before the merge, correct answers with `FINAL` / `-Merge`, Null table stays empty |
| `70_benchmark.sh` | identical row counts and sums before the race |
| `80_basics.sh` | 3 INSERTs = 3 parts (with `async_insert = 0`), `OPTIMIZE FINAL` leaves one part, `EXPLAIN indexes = 1` skips granules |
| `99_cleanup.sh` | no orphaned replication slot on the PostgreSQL side |

## Test status, honestly

Run from scratch against PostgreSQL 16 and ClickHouse 26.10 on one small machine: `run_all.sh` (paths 1, 2, 3, the path 4 transform
test, engines, basics, architecture tour) and the benchmark with 300,000 and 2,000,000 rows, all checks green, `shellcheck` clean.
Not run end to end: path 2b (no `pg_clickhouse` build at hand; syntax follows the official tutorial), path 4 with the real Kafka and Debezium
containers (compose files validated, the ClickHouse half tested with synthetic Debezium events), and path 5 (needs an Aiven account; the
`avn` calls and Terraform are the ones used for the talk's demo). Issues welcome.

## The benchmark, as a teaser

2,000,000 rows, one CPU, default settings of both systems, best of three warm runs, measured by the clients themselves (`psql \timing`,
`clickhouse-client --time`). Your hardware will give different numbers; the shape will not change much.

| Query | PostgreSQL | ClickHouse |
|---|---|---|
| `count(*)` | 98 ms | 1 ms |
| top 5 countries | 349 ms | 53 ms |
| revenue per month | 767 ms | 44 ms |
| top 5 customers | 1217 ms | 81 ms |
| indexed filter (`country = 'DE'`, last 30 days) | 23.5 ms | 8 ms |
| point lookup by primary key | 0.03 ms | 4 ms |

The last row is the point of the whole talk. PostgreSQL wins it by two orders of magnitude, and nobody is proposing to replace it.
Disk: 166 MB table + 103 MB indexes in PostgreSQL, 50 MiB in ClickHouse.

## Layout

```
scripts/     numbered bash scripts, all source scripts/00_lib.sh; run_all.sh for the tour, 99_cleanup.sh to undo
sql/         templates with ${VAR} placeholders, filled from .env by the scripts (envsubst)
listings/    every step standalone with <VAR> placeholders (SQL generated from sql/, shell by hand)
docker/      compose.yml (PostgreSQL + ClickHouse), compose.kafka.yml (adds Kafka + Debezium Connect), debezium/pg-connector.json
terraform/   path 5 as code: aiven_pg, aiven_clickhouse, aiven_service_integration (+ optional Kafka)
docs/        architecture.md (processes vs. threads), path6_peerdb.md, path7_walshadow.md
BLOG.md      the blog post; BLOG_TLDR.md its five bullets
```

## Notes and gotchas

- **`async_insert` is on by default in recent ClickHouse versions.** Then several small INSERTs may become one part, which is good for you and bad for the
  "every INSERT is a part" demo, so `80_basics.sh` switches it off for its three tiny inserts. Check `SELECT * FROM system.settings WHERE name = 'async_insert'`.
- **A bulk INSERT is not one part.** 2,000,000 rows arrive as blocks of `max_insert_block_size` (about 1,048,000 rows), one part per block. Merges take it from there.
- **`ReplacingMergeTree` deduplicates at merge time, not at insert time.** Query with `FINAL` (the `*_current` views do) or accept duplicates until the merge ran. That holds for path 4, PeerDB and WalShadow alike.
- **A refreshable materialized view replaces the whole target on every refresh** (atomically). `APPEND` mode adds instead; then filter on a watermark.
- **Debezium needs `wal_level = logical`**, a role with `REPLICATION`, and the slot must be consumed: an abandoned slot keeps WAL forever. `99_cleanup.sh` drops it.
- **The PostgreSQL engine in ClickHouse pulls every row** of the filtered columns over the wire; aggregation happens in ClickHouse. Point it at a read replica for anything beyond exploration.
- **Passwords in DDL** (`ENGINE = PostgreSQL(... 'password')`) are hidden in `SHOW CREATE TABLE` but still in your SQL history. Use named collections on a real system.
- **Aiven ClickHouse** replicates every MergeTree table across the nodes of the service; `ReplicatedMergeTree()` is the explicit spelling. Newer clients print
  `Unknown settings: allow_non_default_profile, skipping` when connecting: harmless, `00_lib.sh` filters it.
- **Debezium's container images live on quay.io** (`quay.io/debezium/connect`), the Docker Hub repositories only point there.

## License

MIT. Use, copy, break, improve. Drink responsibly.
