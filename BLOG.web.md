# Stop torturing PostgreSQL

### Why your PostgreSQL database needs a ClickHouse sidekick, and six ways to feed it, from a CSV file to logical decoding, without a single pay-per-query invoice

> All scripts in this post live in the companion repository [dkrautschick/pg_clickhouse_integration](https://github.com/dkrautschick/pg_clickhouse_integration). Every section names a numbered script. Run it against Docker on your laptop, against a native PostgreSQL and ClickHouse, or against your own servers (`scripts/setup.sh` asks which and notices what already runs on your ports). The `listings/` folder has every step as a standalone snippet. The demo table is `beer_sales`, because the only honest way to compare two databases is to make both of them count beer.

## The short version

- A row store reads whole rows, a column store reads only the columns it needs, compressed, on all cores. Same data, opposite strengths.
- PostgreSQL stays the source of truth. The ClickHouse sidekick takes the scans. The point lookup stays in PostgreSQL, where it is 120× faster.
- There are six ways to feed the sidekick, from a CSV file to logical decoding. The fresher the data, the more you have to run.
- "Materialized view" means a snapshot in PostgreSQL and a trigger in ClickHouse. Refreshable materialized views are the snapshot kind and need no scheduler.
- CDC targets are `ReplacingMergeTree` tables: updates are versions, deletes are flags, `FINAL` is the price of deduplication, and the replication slot must stay consumed.
- Everything except path 5 runs on your laptop: clone the repository, run `scripts/setup.sh` (Docker or local, your choice), then `scripts/run_all.sh`. The beer is not included.

## The analytical wall

Once upon a time, being a PostgreSQL person was simple. OLTP and OLAP lived in one box with one engine, and "PostgreSQL is the everything database" was mostly true. It still is, for a long way.

Then the dashboards arrive, and the BI tool, and the event pipeline, and the colleague who wants a feature table for a model. The data grows faster than the maintenance window. One day `SELECT count(*)` takes minutes and your indexes use more disk than your data.

You do what we all do first: more indexes (BRIN, GIN, covering), materialized views, partitioning, parallel workers, a bigger box. Do that, it buys years. But every index is a promise to slow down your next INSERT, `REFRESH MATERIALIZED VIEW` recomputes the whole thing, and "more hardware" is a linear answer to a curve. Eventually the plan looks like this, and the plan is not wrong:

```
HashAggregate  (cost=8231409.12..8231409.44 rows=32)
  Group Key: country
  ->  Seq Scan on beer_sales  (rows=2100000000)
Execution Time: 214532.880 ms      <-- 3.5 minutes, and counting
```

A row store keeps all columns of a row together on disk. That is perfect for `UPDATE beer_sales SET liters = 0.5 WHERE id = 4711`: one row, one place, done. It is a poor fit for `SELECT country, sum(liters) FROM beer_sales GROUP BY country` over two billion rows, because the database has to read every row in full to use just two of its columns.

The traditional answer is a closed-source, pay-per-query cloud warehouse, where you stop refreshing the dashboard because every refresh costs money. The alternative keeps PostgreSQL for what it does best and adds an open-source column store next to it. PostgreSQL handles the mission-critical writes, the sidekick handles the heavy reads.

This post is about the sidekick, ClickHouse, and mostly about the one question every DBA asks next: *how do my PostgreSQL data get in there?*

## Meet the sidekick (not your mouse click history)

ClickHouse is a column-oriented database for real-time analytics. It started as an internal project at Yandex in 2009, went open source under the Apache 2.0 licence in 2016, and has been developed by ClickHouse, Inc. since 2021. (Apache-*licensed*, not Apache-*governed*. Confusing enough? Good, let's move on.) It is written in C++, ships a release every month, and is built for exactly the query above: it reads two columns instead of every row.

Three ideas explain most of it. `scripts/80_basics.sh` shows all three on a real server.

### Columns, not rows

Every column is its own file. `sum(liters) GROUP BY country` opens `country.bin` and `liters.bin` and never touches `beer_name.bin`. Similar values sit next to each other, so each column compresses on its own. In the demo table `country` shrinks 221×, `beer_name` 7.7×.

### Parts and merges, not pages

There is no "change this 8 kB page in place". An `INSERT` sorts its rows by the table's `ORDER BY` key and writes them as an immutable *part*: a directory with one file per column plus a sparse index. Background merges combine small parts into bigger ones. It is like `VACUUM` tidying up in PostgreSQL, with the opposite philosophy: write new, merge later, never edit.

Consequence number one: batch your inserts. A thousand single-row inserts are a thousand parts to merge. Recent versions switch on *asynchronous inserts* by default, which buffers small inserts for you; the script turns them off for exactly three statements so you can see three parts appear.

### A sparse index, one entry per granule

Rows are grouped into granules of about 8,192 rows, and `primary.idx` remembers only the first key of each granule. For `WHERE country = 'DE'` on a table sorted by `(country, sold_at)`, ClickHouse binary-searches that tiny index, reads the three granules that can contain DE rows and skips the other seven. `EXPLAIN indexes = 1` prints exactly that: `Granules: 42/245`. The whole index for two million rows is 3.36 KiB and lives in RAM.

Put together: one query uses all cores of one process, reads two of four columns and a fraction of the granules, all compressed. That is the difference between 3.5 minutes and a blink.

## A short history

ClickHouse did not appear out of nowhere either, and the dates matter when someone says "that is a young project".

- **2009:** internal project at Yandex for web analytics (Yandex.Metrica). The name is literally *Clickstream Data Warehouse*.
- **June 2016:** open source under the Apache 2.0 licence.
- **September 2021:** ClickHouse, Inc. is founded as an independent company; ClickHouse Cloud follows. The server keeps a monthly release cadence with two long-term-support releases a year. Check the releases page before you quote an LTS number.
- **2024:** ClickHouse acquires PeerDB, the Postgres-first CDC tool. In the cloud product it becomes ClickPipes Postgres CDC (path 6).
- **December 2025:** `pg_clickhouse`, an official PostgreSQL extension that queries ClickHouse through a foreign data wrapper, replaces the community `clickhouse_fdw` (path 2b).
- **September 2026:** WalShadow, replication from the *physical* PostgreSQL WAL straight into ClickHouse, announced as open source and as a private preview on ClickHouse's managed Postgres (path 7).

Look at the direction of the last three items: ClickHouse has spent the last two years building bridges to PostgreSQL. The sidekick pattern is not a hack a DBA invented at 3 a.m. (although that is how I came to it). It is where the vendor is heading too.

## Two machineries, one query: processes versus threads

The talk has a slide where an orange dot travels down two stacks. This is the long version, because "ClickHouse is multi-threaded" is true and explains nothing. `85_architecture_tour.sh` prints everything below from your own servers.

### PostgreSQL: one waiter per guest

- **Connections:** The *postmaster* listens on the port and forks a *backend process* for every connection. Ten thousand idle connections are ten thousand processes, which is why a pooler sits in front of every busy PostgreSQL.
- **Storage:** A table is a file of 8 kB *pages*, each holding whole row tuples, read through `shared_buffers` (128 MB by default) on top of the OS page cache.
- **Big scans:** The backend becomes a *leader* and starts up to `max_parallel_workers_per_gather` (default 2) workers. It helps, and the unit of work is still a page full of whole rows.
- **Writes:** WAL first, then the page changes in shared memory. The *background writer* and the *checkpointer* write dirty pages later (every `checkpoint_timeout` = 5 minutes or `max_wal_size` = 1 GB). After a crash PostgreSQL replays the WAL. The same WAL feeds streaming replication and logical decoding (paths 4 and 6), so the diary of your database is also its export format.
- **Housekeeping:** MVCC means an `UPDATE` writes a new row version and leaves the old one for autovacuum (a launcher plus up to 3 workers). `ps` shows the whole family: postmaster, background writer, checkpointer, walwriter, autovacuum launcher, logical replication launcher, and one `client backend` per connection.

### ClickHouse: one brewery, many hands

There is one server process, and the work is done by threads from bounded pools.

- **Query execution:** The global thread pool (`max_thread_pool_size`, default 10,000) serves queries. A query becomes a *pipeline* of processors, and data flows through it in blocks of up to 65,409 rows. Every processor works on whole columns of such a block. That is vectorized execution: the "what do I do next" cost is paid once per block, not once per row.
- **Parallelism:** The pipeline is cloned into parallel *lanes*, one per thread. `max_threads` defaults to the number of CPU cores, and `EXPLAIN PIPELINE` shows the lanes as `× N`. Each lane reads its own granule ranges and builds a partial aggregate, and a final step merges the partials. One query, one process, all cores.
- **Background work** has its own pools, so housekeeping and queries do not starve each other. Defaults of the ClickHouse 26.10 build used for the repository reports:
  - `background_pool_size` = 16: merges and mutations of MergeTree tables.
  - `background_fetches_pool_size` = 16: fetching parts from other replicas.
  - `background_move_pool_size` = 8: moving parts between disks.
  - `background_common_pool_size` = 8: clean-up, mostly garbage collection of old parts.
  - `background_schedule_pool_size` = 512: replication of replicated tables, Kafka streaming, DNS cache.
  - `background_message_broker_schedule_pool_size` = 16: Kafka and other message-engine consumers.
  - `background_distributed_schedule_pool_size` = 16: sends of Distributed tables.
  - `max_io_thread_pool_size` = 100: blocking IO, for example S3.

Why a DBA should care: "ClickHouse got slow after we added two hundred Kafka tables" is almost never a bad query. It is a full pool. `system.metrics` shows `BackgroundMergesAndMutationsPoolTask` and `BackgroundSchedulePoolTask` live. You can raise `background_pool_size` at runtime; lowering it needs a restart.

### Side by side

| Moment | PostgreSQL | ClickHouse |
|---|---|---|
| A client connects | postmaster forks a process | a thread from the global pool |
| One query runs | one backend + up to 2 workers | `max_threads` lanes in one process |
| Unit of reading | 8 kB page, whole rows | granule (~8,192 rows) of the needed columns |
| Write path | WAL, change the page, flush later | sort, write an immutable part, merge later |
| Housekeeping | autovacuum, checkpointer | background merges, fetch/move/schedule pools |
| Index | B-tree, one entry per row | sparse, one entry per granule |
| After a crash | replay the WAL | discard unfinished parts |

> Everything that makes PostgreSQL a great transactional database (a session per client, row locks, MVCC, WAL before everything, in-place page changes) makes a full scan over two billion rows expensive. Everything that makes ClickHouse scan fast (columns, immutable parts, all cores per query, background merges) makes a single-row update or a thousand tiny inserts per second awkward. Neither is better. That sentence is the whole talk.

## The engine is the personality of the table

`CREATE TABLE ... ENGINE = ?` decides how a ClickHouse table stores, reads, indexes and replicates. Four families cover what you will meet, and `60_engines.sh` runs the interesting ones.

- **MergeTree family:** sorted, immutable parts, merged in the background. `MergeTree` is the default for almost every table. Its siblings change what happens *during the merge*:
  - `ReplacingMergeTree` keeps one row per sorting key (the last inserted, or the highest version).
  - `SummingMergeTree` adds up the numeric columns of rows with the same key.
  - `AggregatingMergeTree` keeps partial aggregate states (`sumState` in, `sumMerge` out), usually fed by a materialized view.

  These are merge-time behaviours, not constraints. The script shows it: insert two rows, then a second insert that "updates" row 1. A plain `count()` on a `ReplacingMergeTree` returns 3, `count()` with `FINAL` returns 2, and after `OPTIMIZE TABLE ... FINAL` the table holds 2. The prefix `Replicated` adds replication to any of them, coordinated through ClickHouse Keeper.
- **Integration engines** talk to other systems: `PostgreSQL`, `MySQL`, `MongoDB`, `Kafka`, `RabbitMQ`, `S3`, `Iceberg`, `DeltaLake`, `ODBC`, `JDBC` and more. The data stays where it is unless you copy it with `INSERT ... SELECT` or consume it through a materialized view. Two of them carry this post: `PostgreSQL` (paths 2 and 3) and `Kafka` (path 4).
- **Special engines** glue things together. `Distributed` is a view over the shards and stores nothing. `Null` drops writes, which sounds useless until a materialized view on it consumes the rows: a transformation sink. `Memory` lives in RAM only. `Merge` reads several tables as one.
- **Log family** (`TinyLog`, `StripeLog`, `Log`): for many small write-once tables, up to about a million rows. Despite the name it is not for log data.

Rule of thumb, an opinion rather than documentation: start with `MergeTree`; use `ReplacingMergeTree` when CDC updates must replace old rows; `Summing` or `Aggregating` behind a materialized view for roll-ups; `Replicated*` and `Distributed` when you scale out; `Kafka`, `PostgreSQL` or `S3` to reach the outside world. Ignore the rest until you have a reason.

## Same table, same SQL, both systems

*Script: `70_benchmark.sh`*

A sanity check before the integration paths. The script creates the same `beer_sales` table in both systems, generates two million rows in PostgreSQL and copies exactly those rows over. PostgreSQL gets a primary key and the index a sensible DBA would add (`(country, sold_at)`, the counterpart of ClickHouse's `ORDER BY`). The script checks that row counts and sums match, then sends the *same SQL text* to both. One warm-up, best of three, one CPU, default settings, warm caches: a first impression, not a lab.

| Query | PostgreSQL | ClickHouse |
|---|---|---|
| `count(*)` | 98 ms | 1 ms |
| `sum(liters), avg(price_eur)` | 223 ms | 35 ms |
| top 5 countries | 349 ms | 53 ms |
| revenue per month | 767 ms | 44 ms |
| `country = 'DE'`, last 30 days | 23.5 ms | 8 ms |
| top 5 customers | 1217 ms | 81 ms |
| **point lookup by id** | **0.03 ms** | 4 ms |

Notes: ClickHouse answers `count(*)` from part metadata. In the `country = 'DE'` row PostgreSQL uses its index and ClickHouse skips granules. Disk: 166 MB table + 103 MB indexes in PostgreSQL, 50 MiB in ClickHouse.

> Read the last row twice. A single row by primary key is PostgreSQL's home turf, and PostgreSQL wins it by 120×. Nothing in this post suggests replacing it. Analytics over millions of rows is ClickHouse's home turf. The art is to put each where it is strong and to move the data between them.

## The menu: six ways from A to B

- **Path 1, the caveman way:** COPY out, COPY in. Stale on arrival.
- **Path 2, query federation:** ClickHouse reads PostgreSQL live.
- **Path 2b, reverse federation:** PostgreSQL queries ClickHouse (`pg_clickhouse`).
- **Path 3, refreshable materialized view:** ClickHouse keeps a copy in sync.
- **Path 4, Kafka CDC:** Debezium reads the WAL, row by row.
- **Path 5, the lazy way:** Aiven's built-in integrations, including native CDC (limited availability).
- **Path 6, supplement:** PeerDB / ClickPipes.

Every path trades freshness against effort and operational risk. A comparison table at the end saves you from memorising anything. First, the data: `scripts/01_seed.sh` creates `beerdb`, the table, a read-only role for ClickHouse and 200,000 random but repeatable beer sales. It also checks `wal_level`, because path 4 needs `logical`.

## Path 1: the caveman way

*Script: `10_path1_csv.sh`*

```sql
\copy (SELECT * FROM beer_sales ORDER BY id) TO 'beer_sales.csv' CSV HEADER
```

```bash
clickhouse client --date_time_input_format=best_effort \
  --query "INSERT INTO beer.p1_csv FORMAT CSVWithNames" < beer_sales.csv
```

Dead simple, no infrastructure, and the script confirms that both sides hold 200,000 rows afterwards. Then it inserts five more rows into PostgreSQL and confirms the other thing: ClickHouse has seen none of them. The copy was stale the moment you pressed Enter. Fine for a one-off migration or a weekend analysis, terrible for anything live.

`best_effort` is there because PostgreSQL writes `2026-10-31 12:00:00.123456+00` and ClickHouse's strict parser does not love the `+00`.

## Path 2: query federation

*Script: `20_path2_federation.sh`*

ClickHouse can read PostgreSQL at query time, three ways. The table function is for ad hoc queries:

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

The script inserts a row into PostgreSQL and reads it through the engine table a moment later: it is there, no copy involved. Then it times the same aggregation against the federated table and against the local MergeTree copy from path 1: 187 ms versus 81 ms on the test box, with only 200,000 rows.

The gap grows with the table, because the aggregation happens in ClickHouse but every row of the filtered columns travels over the wire. Every query is a round trip to PostgreSQL. That is great for exploration, joins with small lookup tables and proofs of concept. At scale you are back to running analytics on your OLTP system, with an extra hop. Mitigations: point it at a read replica, use a read-only role, and keep the password out of the DDL on a real system (named collections exist for that).

## Path 2b: the mirror image, pg_clickhouse

*Script: `25_path2b_pg_clickhouse.sh`*

PostgreSQL people think "foreign data wrapper". For years there was only a community `clickhouse_fdw`. In December 2025 ClickHouse released `pg_clickhouse` (Apache 2.0), an official extension built on that code. PostgreSQL asks, ClickHouse answers, and aggregates and semi-joins are pushed down.

Setup is five statements, once:

```sql
CREATE EXTENSION pg_clickhouse;
CREATE SERVER beer_ch FOREIGN DATA WRAPPER clickhouse_fdw OPTIONS (driver 'binary', host 'ch-host', port '9000', dbname 'beer');
CREATE USER MAPPING FOR CURRENT_USER SERVER beer_ch OPTIONS (user 'default');
CREATE SCHEMA ch;
IMPORT FOREIGN SCHEMA "beer" FROM SERVER beer_ch INTO ch;
```

From then on it is just SQL. The simplest possible example is the same query twice, where only the schema name differs (`sql/27_pg_p2b_simple.sql`):

```sql
SELECT country, sum(liters) FROM public.beer_sales GROUP BY country;   -- answered by PostgreSQL
SELECT country, sum(liters) FROM ch.p1_csv         GROUP BY country;   -- answered by ClickHouse
```

Same result, but the second query never scans a PostgreSQL heap page. `EXPLAIN (VERBOSE)` shows a single `Foreign Scan`, and ClickHouse does the aggregation. Existing dashboards and ORMs keep talking to PostgreSQL and do not notice that the heavy lifting moved.

> This path moves *queries*, not data. The data still has to get into ClickHouse by one of the other paths.

The script skips politely if the extension is not installed and tells you how to get it (there is an official container image: the PostgreSQL image plus the extension).

## A word about the word "materialized view"

The same words mean three different things:

- **PostgreSQL `MATERIALIZED VIEW`:** a stored snapshot of a query result. It runs on `REFRESH MATERIALIZED VIEW`, and it is good for precomputed reports.
- **ClickHouse materialized view:** an insert **trigger**. `CREATE MATERIALIZED VIEW ... TO target AS SELECT ... FROM source` runs its SELECT on every block inserted into *source* and writes the result into *target*. It only sees ClickHouse inserts, so a materialized view over a `PostgreSQL`-engine table does nothing: nothing is ever inserted into that table from the ClickHouse side. It is good for streaming transforms (Kafka → MergeTree) and roll-ups into `AggregatingMergeTree`.
- **ClickHouse *refreshable* materialized view:** a snapshot again. ClickHouse rebuilds it on a schedule (`REFRESH EVERY ...`, or `SYSTEM REFRESH VIEW`), and the SELECT can read anything, including a `PostgreSQL`-engine table. It is good for pulling a copy from an external source.

The trigger kind is the workhorse of path 4 (parse the Debezium JSON as it arrives) and of every roll-up. The refreshable kind is path 3. By default a refresh replaces the whole target atomically. `APPEND` adds rows instead; then filter on a watermark column so the same row does not arrive twice.

## Path 3: ClickHouse keeps its own copy

*Script: `30_path3_refreshable_mv.sh`*

```sql
CREATE TABLE beer.p3_copy (...) ENGINE = MergeTree ORDER BY (country, sold_at);

CREATE MATERIALIZED VIEW beer.p3_refresh
REFRESH EVERY 10 SECOND
TO beer.p3_copy AS
SELECT * FROM beer.p2_pg_beer_sales;
```

ClickHouse runs the schedule itself: no cron, no Airflow, no dbt. Every refresh pulls the table through the `PostgreSQL` engine and replaces the target atomically (readers see the old copy or the new one, never half). Dashboards read the local MergeTree copy, and PostgreSQL is bothered once per interval instead of once per query.

The script checks row count and `sum(liters)` on both sides after the first refresh. Then it inserts three rows into PostgreSQL, triggers a refresh and checks again; `system.view_refreshes` tells you when the next one is due. Ten seconds keeps the demo watchable; five minutes is a realistic interval, and the interval is your freshness SLA. For anything fresher, you need to stop pulling and start listening.

## An aside: scaling out, because somebody always asks

**PostgreSQL scales reads by copying.** The application writes to one primary, the WAL streams to read-only standbys, and SELECTs are spread over them with a pooler or `target_session_attrs`. Streaming replication is asynchronous by default (a standby can be a moment behind) and synchronous if you pay the commit latency. Writes do not scale out that way: beyond one primary you partition, use `postgres_fdw`, or reach for an extension such as Citus. Failover lives outside the core (Patroni, repmgr, or your managed service).

**ClickHouse combines shards and replicas.** A *shard* holds a slice of the data. The *replicas* of a shard hold copies of that slice, every replica accepts INSERTs, and the others fetch the new parts a moment later (asynchronous, multi-master, coordinated through ClickHouse Keeper). A `Distributed` table is the view over the shards: a SELECT fans out to one replica of every shard and merges the partial results, and an INSERT is split by the sharding key.

Adding a replica is easy: create the replicated table on the new node and it catches up. Adding a shard changes where new data goes. ClickHouse does not rebalance existing data automatically, so choose the sharding key as if you had to live with it, because you do. A sensible start is one shard with replicas for availability; add shards when one node can no longer hold or scan the data.

**On Aiven:** PostgreSQL offers read replicas and standby nodes. Aiven for ClickHouse is a single node, one shard of three nodes, or several shards of three. Every MergeTree table is replicated across the nodes of a shard, and a `Distributed` table on top reads across shards. The repository's scripts use `ReplicatedMergeTree()` on Aiven and `MergeTree` locally, which is the only line that differs.

## Path 4: real streaming with Kafka and Debezium

*Script: `40_path4_kafka_cdc.sh`*

Debezium reads the PostgreSQL write-ahead log through logical decoding (`wal_level = logical`, a replication slot, the built-in `pgoutput` plugin) and publishes every row change as an event on a Kafka topic, one topic per table. ClickHouse consumes the topic with a table of the `Kafka` engine, and here the trigger-style materialized view is exactly the right tool.

### The ClickHouse side

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

CREATE VIEW beer.p4_current AS
SELECT * EXCEPT (_version, _is_deleted) FROM beer.p4_cdc FINAL WHERE _is_deleted = 0;
```

### Why it looks like this

ClickHouse does not update rows. An UPDATE arrives as a new row with a higher version (the WAL position), a DELETE as a new row with `_is_deleted = 1`, and the old versions disappear when parts merge. Until then you query with `FINAL`, which the `p4_current` view does.

### What the repository does

The Docker stack adds a single-node Kafka (KRaft, no ZooKeeper) and Debezium Connect. The script registers the connector, waits for the initial snapshot, then does an INSERT, an UPDATE and a DELETE in PostgreSQL and waits for each to appear (or disappear) in ClickHouse. `41_test_cdc_transform.sh` runs the same consumer SQL against hand-written Debezium events, so you can test the parsing without Kafka at all.

> The cost: you run Kafka, Debezium and a replication slot. The slot is the one to watch. A slot nobody consumes makes PostgreSQL keep WAL until the disk is full. The cleanup script drops it and checks that none is left.

## Path 5: let the platform do the wiring

*Script: `50_path5_aiven.sh`*

Transparency first: I work at Aiven, and everything before this section runs anywhere. On Aiven the plumbing is a product feature.

### Two native integrations

- `clickhouse_postgresql` gives ClickHouse a database that mirrors the PostgreSQL schema (`service_<pg>_<db>_<schema>`).
- `clickhouse_kafka` does the same for Kafka topics.

No connector JSON, no Kafka-engine DDL.

```bash
avn service create beer-pg -t pg --plan startup-4 --cloud google-europe-west1
avn service create beer-clickhouse -t clickhouse --plan startup-16 --cloud google-europe-west1
avn service integration-create -t clickhouse_postgresql -s beer-pg -d beer-clickhouse \
  --user-config-json '{"databases":[{"database":"defaultdb","schema":"public"}]}'
```

The script does this with checks, reads the seeded table through the integration database, and adds the refreshable copy of path 3 on top, now on a replicated cluster. Weigh it the way you weigh any managed platform: operational effort against control. And terminate the services afterwards, because they cost money while they run.

**What the platform does for you:** it creates the integration database, keeps credentials out of your DDL, replicates every table across the nodes of the ClickHouse service, and for `clickhouse_kafka` it maps topics to tables with the format and columns you declare, so there is no `ENGINE = Kafka` statement to maintain.

**What it does not do:** change the physics. `clickhouse_postgresql` is query federation (path 2), so every query still travels to PostgreSQL, and the refreshable copy on top is the same good idea as anywhere else. The Kafka integration still needs something that produces the events; Debezium on Aiven for Apache Kafka Connect does that, with the same replication slot and `wal_level = logical` as in path 4.

### The same in Terraform

```hcl
resource "aiven_pg"          "shop"     { project = var.project  service_name = "beer-pg"          plan = "startup-4"  cloud_name = var.cloud }
resource "aiven_clickhouse"  "sidekick" { project = var.project  service_name = "beer-clickhouse"  plan = "startup-16" cloud_name = var.cloud }

resource "aiven_service_integration" "pg_to_ch" {
  project                  = var.project
  integration_type         = "clickhouse_postgresql"
  source_service_name      = aiven_pg.shop.service_name
  destination_service_name = aiven_clickhouse.sidekick.service_name
  clickhouse_postgresql_user_config {
    databases { database = "defaultdb"  schema = "public" }
  }
}
```

`terraform/` in the repository has the full version, with Kafka and the `clickhouse_kafka` integration behind `var.with_kafka`.

### Even lazier: native CDC straight from the WAL (limited availability)

Aiven has added a third integration that is exactly what path 4 builds by hand, minus the parts you had to run: **PostgreSQL to ClickHouse change data capture**. In the console it is *Replicate to ClickHouse (CDC)*, and the integration type is `postgresql_clickhouse_cdc`. It copies the selected tables once, then follows the PostgreSQL write-ahead log and replays inserts, updates and deletes. No Kafka, no Debezium, no Kafka-engine SQL. The documentation quotes about 10 seconds until changes show up in ClickHouse.

> It is in **limited availability**. Your project needs CDC access, which you request through your account team. Check the status before you promise it to anybody.

```bash
curl --request POST --url "https://api.aiven.io/v1/project/$PROJECT/integration" \
  --header "Authorization: Bearer $TOKEN" --header "Content-Type: application/json" --data '{
    "integration_type": "postgresql_clickhouse_cdc",
    "source_service": "beer-pg", "dest_service": "beer-clickhouse",
    "user_config": { "pipelines": [ { "source_database": "defaultdb", "destination_database": "beer",
        "tables": [ {"schema": "public", "table": "beer_sales"} ] } ] } }'
```

**What arrives** is path 4's target table, built for you. For each source table there is a `ReplicatedReplacingMergeTree` ordered by the primary key, with the columns `_etl_version` (position in the stream) and `_etl_deleted` (1 = deleted). A view with the suffix `__current` returns one row per key and hides deleted rows. Names are `schema_table` with every underscore doubled, so `public.beer_sales` becomes `public_beer__sales` and you read `public_beer__sales__current`. `numeric` and `money` arrive as `String`; cast them before you add them up. The listing is `listings/50_aiven_cdc_api.sh`.

**The fine print from the documentation:**

- Only Aiven for PostgreSQL to Aiven for ClickHouse; an external PostgreSQL does not work.
- Every table needs a primary key, and one integration covers 1 to 400 tables.
- No column selection, and replication cannot be paused.
- Renaming a column or changing a type stops that table until you resynchronise it.
- Replication shares CPU and memory with the ClickHouse service.
- It keeps a replication slot on your PostgreSQL, so the rule from path 4 stands: a stalled replication holds WAL, and the WAL metric is the one to alert on.

The repository's scripts do not run this one, because it needs a project with CDC access. The listing is the call as the documentation shows it.

## Path 6, the supplement: PeerDB

Not one of the five paths of the talk, but the question that came up most afterwards. PeerDB is an open-source, Postgres-first CDC tool that ClickHouse acquired in 2024; inside ClickHouse Cloud it runs as ClickPipes Postgres CDC. It uses the same logical decoding as Debezium, but as a purpose-built pipeline from PostgreSQL to ClickHouse: initial snapshot in parallel partitions, continuous sync from the slot, staging, batch loads.

What lands in ClickHouse is a `ReplacingMergeTree(_peerdb_version)` table with `_peerdb_is_deleted` and `_peerdb_synced_at`, which is path 4's target table with nicer names. `65_peerdb_pattern.sh` rebuilds that shape by hand, and `docs/path6_peerdb.md` has the details and the licence note (AGPL v3 for the self-run version).

## Path 7, the outlook: WalShadow

Every path so far that wants row-level freshness (4, 5 with Kafka or native CDC, 6) uses *logical decoding*: PostgreSQL decodes the WAL into row changes through an output plugin, behind a replication slot. WalShadow, announced by ClickHouse on 10 September 2026, skips that layer.

- It consumes the *physical* WAL, the same stream a hot standby replays, and decodes the heap records itself (outside PostgreSQL, in parallel, in Rust).
- It replays catalog changes into a schema-only shadow Postgres, so it always knows the current table layout.
- It builds ClickHouse-native blocks and inserts them in parallel. Every row carries its WAL position as `_lsn`, ClickHouse keeps the latest version per key, and schema changes act as barriers.
- No output plugin, no slot, no Kafka, no JSON.

The announcement's own benchmark (one table, one region, vendor numbers) measured about 200 ms from commit to visible in ClickHouse, against about 10 seconds for PeerDB in the same setup, and 289,000 rows/s sustained.

The catch is the word *physical*: WalShadow needs access to the raw WAL, and most managed PostgreSQL services do not hand that out. Today it is an option for self-managed PostgreSQL and for ClickHouse's own managed Postgres (private preview), and a thing to watch everywhere else. `docs/path7_walshadow.md` has the links; a script will follow when there is something a normal person can run.

## Which path, when?

| Path | Latency and effort | Pick it when |
|---|---|---|
| 1 CSV | hours or days; manual every time | one-off load, migration, "just let me look at it" |
| 2 federation | live; low, but slow at scale | exploration, small tables, proofs of concept |
| 2b `pg_clickhouse` | live; one extension | existing SQL must keep hitting PostgreSQL |
| 3 refreshable MV | seconds to minutes; low | dashboards that can be five minutes old |
| 4 Kafka CDC | sub-second to seconds; high (Kafka + Debezium) | events, row-level freshness, you already run Kafka |
| 5 Aiven integrations | live plus copy, about 10 s with native CDC; low | you would rather not run Kafka (CDC: limited availability) |
| 6 PeerDB | tens of seconds; medium, or ClickHouse Cloud | CDC without Kafka, Postgres-first |

Start with query federation, graduate to a refreshable copy when PostgreSQL feels the queries, and graduate to CDC when the refresh interval hurts. Pick the path that matches the latency you actually need, not the coolest one. The coolest one is rarely the cheapest at 3 a.m.

## When the table is big: notes before you start

The repository moves 200,000 rows, and the benchmark two million. The procedure does not change for two billion; the things around it do.

- **Choose `ORDER BY` as carefully as a primary key in PostgreSQL.** It is the physical sort order *and* the sparse index. Lead with the columns your WHERE clauses filter on, low cardinality first, time last (`(country, sold_at)` in the demo). A wrong `ORDER BY` is a rewrite, not an `ALTER`.
- **Decide how updates and deletes land before the first byte arrives.** Paths 1 to 3 replace the whole copy and have no problem. Paths 4, 6 and 7 deliver changes, and the target must be a `ReplacingMergeTree` with a version column and a delete flag, read with `FINAL` or through a view. The WAL position (`source.lsn` in Debezium, `_peerdb_version`, `_lsn`) is monotonic and free as a version. `updated_at` from the application is not, if two updates land in the same millisecond.
- **Batch the inserts.** The Kafka engine and the refreshable view already do. If you write your own loader, aim for tens of thousands of rows per INSERT or let asynchronous inserts do it. Watch `system.parts`: a table approaching `parts_to_delay_insert` (1,000 by default) is telling you something.
- **Monitor the slot.** Paths 4 and 6 keep a replication slot on your PostgreSQL. `pg_replication_slots` with `pg_wal_lsn_diff(pg_current_wal_lsn(), restart_lsn)` tells you how much WAL it holds back. Alert on it. A connector that died on Friday evening is a full disk on Monday.
- **Plan for schema changes.** A new column in PostgreSQL shows up in Debezium events (the JSON extraction in the view ignores it until you add it), is picked up by PeerDB and WalShadow under their own rules, and silently breaks a `PostgreSQL`-engine table whose column list is outdated. Re-create it, or use the database engine that reads the schema at query time. Freeze DDL during an initial load.
- **Mind the types.** `timestamptz` arrives as `DateTime64(6, 'UTC')`. `numeric` is best handled as a string by Debezium (`decimal.handling.mode = string`) and cast in ClickHouse. `double precision` is `Float64`, and sums match to the last digit. The repository's first version used `Float32` and the sums did not match, which is why the tables now say `Float64`.
- **Use a read replica.** Point federation (path 2) and the refreshable view (path 3) at a standby, not at the primary. Analytics are the roommates your OLTP primary did not ask for.

## Questions I got after the talk

**Is ClickHouse a replacement for PostgreSQL?** No. There are no multi-statement OLTP transactions the way you know them and no foreign keys, and updates and deletes are background rewrites. It complements. The point lookup in the benchmark is 120× faster in PostgreSQL for a reason.

**How do I handle updates and deletes?** `ReplacingMergeTree` with a version column and an `is_deleted` flag, `FINAL` on read, and a view or a row policy to hide the flagged rows. Every CDC tool in this post lands its data that way, PeerDB and WalShadow included.

**Can I join ClickHouse tables with PostgreSQL tables?** Yes, in both directions. In ClickHouse the `PostgreSQL` engine table joins like any other (pull the small table, not the big one). In PostgreSQL, `pg_clickhouse` gives you foreign tables with pushdown.

**What about the Kafka engine when nobody reads from it?** Nothing happens. It is a consumer, and the materialized view behind it does the reading. Do not `SELECT` from a `Kafka`-engine table casually, because that consumes messages for the consumer group.

**Why not just more PostgreSQL?** Often the right answer, for a long time. BRIN, covering indexes, partitioning and parallel workers buy years. The sidekick is for the day the maintenance window stops growing with the data.

**Debezium or PeerDB or WalShadow?** Debezium if you already run Kafka and want the events for more than ClickHouse. PeerDB if you want CDC into ClickHouse with fewer moving parts and can live with the AGPL or use ClickHouse Cloud. WalShadow when you can give it the physical WAL and it has left preview. Refreshable materialized views if "five minutes old" is fine, which is true for more dashboards than anyone admits.

## Try it yourself

The scripts in this post are open source and run on your laptop; path 5 needs an Aiven account. Clone [the repository](https://github.com/dkrautschick/pg_clickhouse_integration), run `scripts/setup.sh` (Docker or local, your choice), then `scripts/run_all.sh --demo` to see every statement before it runs. The beer is not included.
