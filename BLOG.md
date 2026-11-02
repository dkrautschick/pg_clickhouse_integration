# Stop torturing PostgreSQL

### Why your PostgreSQL database needs a ClickHouse sidekick, and six ways to feed it, from a CSV file to logical decoding, without a single pay-per-query invoice

*All scripts in this post live in the companion repository [dkrautschick/pg_clickhouse_integration](https://github.com/dkrautschick/pg_clickhouse_integration).
Every section references a numbered script you can run against a Docker stack on your laptop or against your own servers, and the `listings/`
folder has each step as a standalone snippet. The demo table is `beer_sales`, because the only honest way to compare two databases is to make
both of them count beer.*

## The analytical wall

Once upon a time, being a PostgreSQL person was simple. OLTP and OLAP lived in one box with one engine, and "PostgreSQL is the everything
database" was mostly true. It still is, for a long way. Then the dashboards arrive, and the BI tool, and the event pipeline, and the colleague
who wants a feature table for a model, and the data grows faster than the maintenance window. One day `SELECT count(*)` takes minutes and your
indexes use more disk than your data.

You do what we all do first: more indexes (BRIN, GIN, covering), materialized views, partitioning, parallel workers, a bigger box. Do that,
it buys years. But every index is a promise to slow down your next INSERT, `REFRESH MATERIALIZED VIEW` recomputes the whole thing, and
"more hardware" is a linear answer to a curve. Eventually the plan looks like this, and the plan is not wrong:

```
HashAggregate  (cost=8231409.12..8231409.44 rows=32)
  Group Key: country
  ->  Seq Scan on beer_sales  (rows=2100000000)
Execution Time: 214532.880 ms      <-- 3.5 minutes, and counting
```

A row store reads whole rows to sum one column. That is what it does for a living, and it is the right thing to do for `UPDATE beer_sales SET
liters = 0.5 WHERE id = 4711`. It is the wrong thing for `SELECT country, sum(liters) FROM beer_sales GROUP BY country` over two billion rows.

The traditional answer is to move analytics into a closed-source, pay-per-query cloud warehouse and to stop refreshing the dashboard because
every refresh costs money. The better answer keeps PostgreSQL for what it is great at and adds an open-source column store next to it: PostgreSQL
handles the mission-critical writes, the sidekick handles the heavy reads. This post is about the sidekick, ClickHouse, and mostly about the
one question every DBA asks next: *how do my PostgreSQL data get in there?*

## Meet the sidekick (not your mouse click history)

ClickHouse is a column-oriented database for real-time analytics. It started as an internal project at Yandex in 2009, went open source under the
Apache 2.0 licence in 2016 (Apache-*licensed*, not Apache-*governed*; confusing enough? good, let's move on), and has been developed by ClickHouse,
Inc. since 2021. It is written in C++, it ships a release every month, and it is very, very good at exactly the query above.

Three ideas explain most of it. The repository shows all three on a real server with `scripts/80_basics.sh`.

**Columns, not rows.** Every column is its own file. `sum(liters) GROUP BY country` opens `country.bin` and `liters.bin` and never touches
`beer_name.bin`. Similar values sit next to each other, so each column compresses on its own: in the demo table `country` shrinks 221×, `beer_name` 7.7×.

**Parts and merges, not pages.** There is no "change this 8 kB page in place". An `INSERT` sorts its rows by the table's `ORDER BY` key and writes
them as an immutable *part*, a directory with one file per column plus a sparse index. Background merges combine small parts into bigger ones,
the way `VACUUM` tidies up in PostgreSQL, only with the opposite philosophy: write new, merge later, never edit. Consequence number one: batch your
inserts; a thousand single-row inserts are a thousand parts to merge. (Recent versions switch on *asynchronous inserts* by default, which buffers
small inserts for you. The script turns them off for exactly three statements, so you can see three parts appear.)

**A sparse index, one entry per granule.** Rows are grouped into granules of about 8,192 rows, and `primary.idx` remembers only the first key of
each granule. For `WHERE country = 'DE'` on a table sorted by `(country, sold_at)` ClickHouse binary-searches that tiny index, reads the three
granules that can contain DE rows and skips the other seven. `EXPLAIN indexes = 1` prints exactly that: `Granules: 42/245`. The whole index for
two million rows is 3.36 KiB and lives in RAM.

Put together: one query uses all cores of one process (ClickHouse has a thread pool, not a process per connection; `docs/architecture.md` in the
repository goes through both machineries side by side), reads two of four columns, a fraction of the granules, all compressed. That is the
difference between 3.5 minutes and a blink.

## Same table, same SQL, both systems (`70_benchmark.sh`)

Before the integration paths, a sanity check. The script creates the same `beer_sales` table in both systems, generates two million rows in
PostgreSQL, copies exactly those rows over with `INSERT ... SELECT FROM postgresql(...)`, gives PostgreSQL a primary key and the index a
sensible DBA would add (`(country, sold_at)`, the counterpart of ClickHouse's `ORDER BY`), checks that the row counts and sums match, and then
sends the *same SQL text* to both. One warm-up, best of three, timings taken by `psql \timing` and `clickhouse-client --time`. One CPU, default
settings, warm caches: a first impression, not a lab.

| Query | PostgreSQL | ClickHouse | |
|---|---|---|---|
| `count(*)` | 98 ms | 1 ms | ClickHouse answers from part metadata |
| `sum(liters), avg(price_eur)` | 223 ms | 35 ms | |
| top 5 countries | 349 ms | 53 ms | |
| revenue per month | 767 ms | 44 ms | |
| `country = 'DE'`, last 30 days | 23.5 ms | 8 ms | PostgreSQL uses the index, ClickHouse skips granules |
| top 5 customers | 1217 ms | 81 ms | |
| **point lookup by id** | **0.03 ms** | 4 ms | PostgreSQL wins by 120× |

Disk: 166 MB table + 103 MB indexes in PostgreSQL, 50 MiB in ClickHouse.

Read the last row twice. A single row by primary key is PostgreSQL's home turf, and nothing in this post suggests replacing it. Analytics over
millions of rows is ClickHouse's home turf. The art is to put each where it is strong and to move the data between them. Which brings us to the
menu.

## The menu: six ways from A to B

| Path | | Freshness | Who runs what |
|---|---|---|---|
| 1 | The caveman way: COPY out, COPY in | stale on arrival | you, every time |
| 2 | Query federation: ClickHouse reads PostgreSQL live | live | nothing to run, but PostgreSQL pays per query |
| 2b | Reverse federation: PostgreSQL queries ClickHouse (`pg_clickhouse`) | live | an extension |
| 3 | Refreshable materialized view: ClickHouse keeps a copy in sync | refresh interval | ClickHouse schedules it |
| 4 | Kafka CDC: Debezium reads the WAL, row by row | seconds | Kafka + Debezium |
| 5 | The lazy way: Aiven's built-in integrations | live (+ copy) | the platform |
| 6 | Supplement: PeerDB / ClickPipes | tens of seconds | PeerDB or ClickHouse Cloud |

Every path has a trade-off between freshness, effort and operational risk, and there is a comparison table at the end so you do not have to
memorise anything. First, the data: `scripts/01_seed.sh` creates `beerdb`, the table, a read-only role for ClickHouse and 200,000 random but
repeatable beer sales. It also checks `wal_level`, because path 4 will need `logical`.

## Path 1: the caveman way (`10_path1_csv.sh`)

```sql
\copy (SELECT * FROM beer_sales ORDER BY id) TO 'beer_sales.csv' CSV HEADER
```

```bash
clickhouse client --date_time_input_format=best_effort \
  --query "INSERT INTO beer.p1_csv FORMAT CSVWithNames" < beer_sales.csv
```

Dead simple, no infrastructure, and the script confirms that both sides hold 200,000 rows afterwards. Then it inserts five more rows into
PostgreSQL and confirms the other thing: ClickHouse has seen none of them. The copy was stale the moment you pressed Enter. Fine for a one-off
migration or a weekend analysis, terrible for anything live. `best_effort` is there because PostgreSQL writes `2026-10-31 12:00:00.123456+00`
and ClickHouse's strict parser does not love the `+00`.

## Path 2: query federation (`20_path2_federation.sh`)

ClickHouse can read PostgreSQL at query time, three ways. The table function is for ad hoc:

```sql
SELECT country, round(sum(liters)) AS liters, count() AS sales
FROM postgresql('pg-host:5432', 'beerdb', 'beer_sales', 'ch_reader', 'secret')
GROUP BY country ORDER BY liters DESC LIMIT 5;
```

The `PostgreSQL` table engine makes it permanent, and the `PostgreSQL` *database* engine maps a whole schema at once, no DDL per table:

```sql
CREATE TABLE beer.p2_pg_beer_sales (...) ENGINE = PostgreSQL('pg-host:5432', 'beerdb', 'beer_sales', 'ch_reader', 'secret');
CREATE DATABASE beer_pg ENGINE = PostgreSQL('pg-host:5432', 'beerdb', 'ch_reader', 'secret', 'public');
```

The script inserts a row into PostgreSQL and reads it through the engine table a moment later: it is there, no copy involved. Then it times the
same aggregation against the federated table and against the local MergeTree copy from path 1: 187 ms versus 81 ms on the test box, with
200,000 rows. The gap grows with the table, because the aggregation happens in ClickHouse but every row of the filtered columns travels over the
wire. Every query is a round trip to PostgreSQL. Great for exploration, joins with small lookup tables and proofs of concept; at scale you are
back to running analytics on your OLTP system, only with an extra hop. Mitigations: point it at a read replica, use a read-only role, and
keep the password out of the DDL on a real system (named collections exist for that).

## Path 2b: the mirror image, `pg_clickhouse` (`25_path2b_pg_clickhouse.sh`)

PostgreSQL people think "foreign data wrapper". For years there was only a community `clickhouse_fdw`; in December 2025 ClickHouse released
`pg_clickhouse` (Apache 2.0), an official PostgreSQL extension built on that code. PostgreSQL asks, ClickHouse answers, aggregates and semi-joins
are pushed down:

```sql
CREATE EXTENSION pg_clickhouse;
CREATE SERVER beer_ch FOREIGN DATA WRAPPER clickhouse_fdw OPTIONS (driver 'binary', host 'ch-host', port '9000', dbname 'beer');
CREATE USER MAPPING FOR CURRENT_USER SERVER beer_ch OPTIONS (user 'default');
CREATE SCHEMA ch;
IMPORT FOREIGN SCHEMA "beer" FROM SERVER beer_ch INTO ch;

EXPLAIN (VERBOSE) SELECT country, sum(liters) FROM ch.p1_csv GROUP BY country;   -- one Foreign Scan
```

Existing dashboards and ORMs keep talking to PostgreSQL and do not notice that the heavy lifting moved. Important: this path moves *queries*, not
data. The data still have to get into ClickHouse by one of the other paths. The script skips politely if the extension is not installed and tells
you how to get it (there is an official container image: the PostgreSQL image plus the extension).

## A word about the word "materialized view"

In PostgreSQL a materialized view is a stored snapshot you refresh on demand. In ClickHouse a `CREATE MATERIALIZED VIEW ... TO target AS SELECT ... FROM source`
is a **trigger**: its SELECT runs on every block inserted into *source* and writes the result into *target*. It never notices changes that happen
somewhere else, so a plain materialized view over a `PostgreSQL`-engine table does nothing at all, because nothing is ever inserted into that
table from the ClickHouse side. Same words, completely different execution model. ClickHouse also has *refreshable* materialized views, and those
are the snapshot kind. That is path 3.

## Path 3: ClickHouse keeps its own copy (`30_path3_refreshable_mv.sh`)

```sql
CREATE TABLE beer.p3_copy (...) ENGINE = MergeTree ORDER BY (country, sold_at);

CREATE MATERIALIZED VIEW beer.p3_refresh
REFRESH EVERY 10 SECOND
TO beer.p3_copy AS
SELECT * FROM beer.p2_pg_beer_sales;
```

ClickHouse runs the schedule itself. No cron, no Airflow, no dbt. Every refresh pulls the table through the `PostgreSQL` engine and replaces the
target atomically (readers see the old copy or the new one, never half). Dashboards read the local MergeTree copy, PostgreSQL is bothered once per
interval instead of once per query. The script checks row count and `sum(liters)` on both sides after the first refresh, inserts three rows into
PostgreSQL, triggers a refresh (`SYSTEM REFRESH VIEW`) and checks again; `system.view_refreshes` tells you when the next one is due. Ten seconds
keeps the demo watchable; five minutes is a realistic interval, and the interval is your freshness SLA. For anything that must be fresher, you need
to stop pulling and start listening.

## Path 4: real streaming with Kafka and Debezium (`40_path4_kafka_cdc.sh`)

Debezium reads the PostgreSQL write-ahead log through logical decoding (`wal_level = logical`, a replication slot, the built-in `pgoutput` plugin)
and publishes every row change as an event on a Kafka topic, one topic per table. ClickHouse consumes the topic with a table of the `Kafka`
engine, and here the trigger-style materialized view is exactly the right tool:

```sql
CREATE TABLE beer.p4_queue (payload String) ENGINE = Kafka
SETTINGS kafka_broker_list = 'kafka:19092', kafka_topic_list = 'cdc.public.beer_sales',
         kafka_group_name = 'clickhouse-beer', kafka_format = 'JSONAsString';

CREATE TABLE beer.p4_cdc (..., _version UInt64, _is_deleted UInt8)
ENGINE = ReplacingMergeTree(_version, _is_deleted) ORDER BY id;

CREATE MATERIALIZED VIEW beer.p4_consumer TO beer.p4_cdc AS
SELECT if(op = 'd', JSONExtractInt(payload, 'before', 'id'), JSONExtractInt(payload, 'after', 'id')) AS id,
       ..., JSONExtractUInt(payload, 'source', 'lsn') AS _version, toUInt8(op = 'd') AS _is_deleted
FROM (SELECT payload, JSONExtractString(payload, 'op') AS op FROM beer.p4_queue);

CREATE VIEW beer.p4_current AS SELECT * EXCEPT (_version, _is_deleted) FROM beer.p4_cdc FINAL WHERE _is_deleted = 0;
```

The target is a `ReplacingMergeTree`, because ClickHouse does not update rows: an UPDATE arrives as a new row with a higher version (the WAL
position), a DELETE as a new row with `_is_deleted = 1`, and the old versions disappear when parts merge. Until then you query with `FINAL`,
which the `p4_current` view does. The repository's Docker stack adds a single-node Kafka (KRaft, no ZooKeeper) and Debezium Connect; the script
registers the connector, waits for the initial snapshot and then does an INSERT, an UPDATE and a DELETE in PostgreSQL and waits for each to appear
(or disappear) in ClickHouse. `41_test_cdc_transform.sh` runs the same consumer SQL against hand-written Debezium events, so you can test the
parsing without Kafka at all.

The cost is on the right side of the table: you run Kafka, Debezium and the replication slot. The slot is the one to watch. A slot nobody consumes
makes PostgreSQL keep WAL until the disk is full; the cleanup script drops it and checks that none is left.

## Path 5: let the platform do the wiring (`50_path5_aiven.sh`)

Transparency first: I work at Aiven, and everything before this section runs anywhere. On Aiven the plumbing is a product feature: an integration
of type `clickhouse_postgresql` between an Aiven for PostgreSQL and an Aiven for ClickHouse service gives ClickHouse a database that mirrors the
PostgreSQL schema (`service_<pg>_<db>_<schema>`), and `clickhouse_kafka` does the same for Kafka topics. No connector JSON, no Kafka-engine DDL.

```bash
avn service create beer-pg -t pg --plan startup-4 --cloud google-europe-west1
avn service create beer-clickhouse -t clickhouse --plan startup-16 --cloud google-europe-west1
avn service integration-create -t clickhouse_postgresql -s beer-pg -d beer-clickhouse \
  --user-config-json '{"databases":[{"database":"defaultdb","schema":"public"}]}'
```

The script does that with checks, reads the seeded table through the integration database, and adds the refreshable copy of path 3 on top,
now on a replicated cluster (on Aiven every MergeTree table is replicated across the nodes of the service). `terraform/` has the same as four
resources. Weigh it the way you weigh every managed service: operational effort against control. And terminate the services afterwards; they
cost money while they run.

## Path 6, the supplement: PeerDB

Not one of the five paths of the talk, but the question that came up most afterwards. PeerDB is an open-source, Postgres-first CDC tool that
ClickHouse acquired in 2024; inside ClickHouse Cloud it runs as ClickPipes Postgres CDC. It uses the same logical decoding as Debezium, but as a
purpose-built pipeline from PostgreSQL to ClickHouse: initial snapshot in parallel partitions, continuous sync from the slot, staging, batch loads.
What lands in ClickHouse is a `ReplacingMergeTree(_peerdb_version)` table with `_peerdb_is_deleted` and `_peerdb_synced_at`, which is path 4's
target table with nicer names. `65_peerdb_pattern.sh` rebuilds that shape by hand, `docs/path6_peerdb.md` has the details and the licence note
(AGPL v3 for the self-run version). And the next thing on the horizon, WalShadow, drops logical decoding altogether and reads the physical WAL
like a standby would; `docs/path7_walshadow.md` keeps the notes until there is something to run.

## Which path, when?

| Path | Latency | Ops effort | Pick it when |
|---|---|---|---|
| 1 CSV | hours or days | low, manual every time | one-off load, migration, "just let me look at it" |
| 2 federation | live | low, slow at scale | exploration, small tables, proofs of concept |
| 2b `pg_clickhouse` | live | one extension | existing SQL must keep hitting PostgreSQL |
| 3 refreshable MV | seconds to minutes | low, ClickHouse refreshes itself | dashboards that can be five minutes old (most can) |
| 4 Kafka CDC | sub-second to seconds | high, Kafka + Debezium | events, row-level freshness, you already run Kafka |
| 5 Aiven integrations | live, plus copy | low, the platform runs it | you would rather not run Kafka |
| 6 PeerDB | tens of seconds | medium, or ClickHouse Cloud | CDC without Kafka, Postgres-first |

Start with query federation, graduate to a refreshable copy when PostgreSQL feels the queries, graduate to CDC when the refresh interval hurts.
Pick the path that matches the latency you actually need, not the coolest one. The coolest one is rarely the cheapest at 3 a.m.

## The two-minute version for your next architecture call

- A row store reads whole rows; a column store reads the columns it needs, compressed, with all cores. Same data, opposite layouts, opposite strengths.
- PostgreSQL stays the source of truth. The sidekick takes the scans. The point lookup stays where it is 120× faster.
- Six ways to feed the sidekick, from a CSV to logical decoding; freshness goes up, so does the number of things you run.
- "Materialized view" means a snapshot in PostgreSQL and a trigger in ClickHouse. Refreshable materialized views are the snapshot kind and need no scheduler.
- CDC targets are `ReplacingMergeTree` tables: updates are versions, deletes are flags, `FINAL` is the price of eventual deduplication, and the replication slot must stay consumed.
- Everything in this post is open source and runs on your laptop: clone the repository, `docker compose up`, `scripts/run_all.sh`. The beer is not included.
