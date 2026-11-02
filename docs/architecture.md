# Two architectures, one query

What actually happens when you run this in PostgreSQL and in ClickHouse, and why the same query costs so different amounts?

```sql
SELECT country, sum(liters) FROM beer_sales GROUP BY country;
```

Think of PostgreSQL as a pub with **one waiter per guest** who keeps every order slip (a whole row) in a filing cabinet,
and ClickHouse as a brewery with an **assembly line**: one building, many workers, and every ingredient (column) in its own crate.
Both are good at what they were built for. This page walks through the machinery, with the settings you can look at yourself
(`scripts/85_architecture_tour.sh` prints them from your own servers).

## PostgreSQL: a process per connection

**1. Connect.** PostgreSQL uses a "process per user" model: a supervisor called the *postmaster* listens on the port and
forks a new *backend process* for every connection. Backends talk to each other through shared memory and semaphores.
Ten thousand idle connections are ten thousand processes, which is why a connection pooler sits in front of busy systems.

**2. Parse, plan, execute.** The SQL text goes to the backend as plain text. It parses it, builds an execution plan
(that is what `EXPLAIN` shows), runs the plan and streams rows back over the same connection.

**3. Pages and `shared_buffers`.** A table is a file of 8 kB *pages*, each page holds *row tuples* with all their columns together.
Pages are read through `shared_buffers`, a cache in shared memory (128 MB by default) on top of the operating system's page cache.
Summing one column therefore pulls whole rows (country, beer name, channel, ...) through the cache. That is the "reads far more than it needs" of the talk.

**4. Parallel query.** For big scans the backend becomes a *leader* and starts background *worker processes*
(`max_parallel_workers_per_gather`, default 2). They scan different parts of the table and the leader gathers the partial results.
It helps a lot, but the unit of work is still the row page.

**5. Writes: the log first.** A change is first written to the *write-ahead log* (WAL) and only then applied to the page in `shared_buffers`.
The dirty page reaches the data file later, written by the *background writer* and the *checkpointer*
(a checkpoint happens every `checkpoint_timeout` = 5 minutes or when `max_wal_size` = 1 GB of WAL is used up, whichever comes first).
The `walwriter` flushes WAL in the background. After a crash PostgreSQL replays the WAL, which is why the log is the source of truth.
The same log is what streaming replication ships and what logical decoding (Debezium, PeerDB, paths 4 and 6) reads.

**6. Updates leave dead rows.** MVCC means an `UPDATE` writes a *new* row version and the old one stays until nobody can see it any more.
The *autovacuum launcher* starts *autovacuum workers* that clean up, so a PostgreSQL that is busy with analytics and updates also pays in vacuum work.

What you see with `ps` or `pg_stat_activity`: one `postgres` supervisor, `background writer`, `checkpointer`, `walwriter`,
`autovacuum launcher`, `logical replication launcher`, and one `client backend` per connection.

## ClickHouse: one server, many threads

**1. Connect.** There is one server process. Clients talk the native protocol (port 9000) or HTTP (8123).
Work is done by *threads*, taken from bounded pools. The global thread pool (`max_thread_pool_size`, default 10,000 threads)
is where query work comes from: if no idle thread is available a new one is created, up to the cap. `max_connections` defaults to 4096.

**2. Plan and pipeline.** The query becomes a *pipeline* of processors. Data flows through it in *blocks* (up to `max_block_size` = 65,409 rows by default),
and every processor works on whole columns of such a block at once. That is *vectorized execution*: the cost of "which operation is next" is paid per block, not per row.

**3. Lanes.** The pipeline is cloned into parallel *lanes*, one per thread. `max_threads` defaults to the number of CPU cores, so one query uses all cores.
`EXPLAIN PIPELINE` shows it as `× N`. Each lane reads its own ranges of granules, filters, aggregates a partial result, and a final step merges the partials.
This is parallelism *inside one query*, in one process, with no coordination between processes.

**4. Read only what is needed.** A table is a set of *parts*. The sparse primary index (one entry per granule of about 8,192 rows) tells the server which granule ranges can contain matches,
and only the files of the columns the query touches are opened (`country.bin` and `liters.bin`, not `beer_name.bin`). Everything is stored compressed, per column.

**5. Writes: build a part, never edit one.** An `INSERT` forms blocks (up to `max_insert_block_size` of about 1 million rows), sorts them by the `ORDER BY` key and writes each block as an *immutable part*.
There is no "change a page in place". That is why bulk inserts are cheap and tiny inserts are not: every part has to be merged later.
Recent versions have *asynchronous inserts* switched on by default (check `system.settings`); the server then buffers small inserts and writes them together.

**6. Background work lives in pools.** Merging parts together, applying mutations, fetching parts from replicas and moving data between disks all run in the background, each with its own pool so that housekeeping cannot starve queries (or the other way round):

| Pool (server setting) | Default | What the threads do |
|---|---|---|
| `background_pool_size` | 16 | merges and mutations of MergeTree tables (times `background_merges_mutations_concurrency_ratio` = 2 tasks per thread) |
| `background_fetches_pool_size` | 16 | fetch data parts from another replica |
| `background_move_pool_size` | 8 | move parts to another disk or volume |
| `background_common_pool_size` | 8 | various clean-up work for MergeTree tables, mostly garbage collection |
| `background_schedule_pool_size` | 512 | lightweight periodic tasks: replication of replicated tables, Kafka streaming, DNS cache updates, ... (threads are created on demand) |
| `background_message_broker_schedule_pool_size` | 16 | background work of the Kafka and other message-streaming engines |
| `background_distributed_schedule_pool_size` | 16 | sends of Distributed tables |
| `max_io_thread_pool_size` | 100 | blocking IO such as talking to S3 |

The defaults are the ones of the ClickHouse 26.10 build used to test this repository (`system.server_settings`); the server may lower some of them on small machines.
You can raise `background_pool_size` at runtime, lowering it needs a restart. Why care: when "ClickHouse is slow after we added 200 Kafka tables" the answer is often a pool that is full, not a query that is bad.

## Side by side

| Moment | PostgreSQL | ClickHouse |
|---|---|---|
| A client connects | postmaster forks a **process** | a **thread** from the global pool serves it |
| One query runs | one backend, plus up to `max_parallel_workers_per_gather` worker processes | `max_threads` (= cores) lanes inside one process |
| Unit of reading | 8 kB page with whole rows | granule (about 8,192 rows) of the needed columns only |
| Cache | `shared_buffers` + OS page cache | OS page cache + ClickHouse's own caches for marks and decompressed blocks |
| Write path | WAL first, then change the page in memory, flush later | build a sorted immutable part, merge later |
| Housekeeping | autovacuum (launcher + workers), checkpointer, background writer | background merges and mutations, plus fetch/move/schedule pools |
| Index | B-tree: one entry per row | sparse: one entry per granule |
| After a crash | replay the WAL | parts are immutable, unfinished parts are discarded |
| Replication | stream the WAL (physical) or decode it (logical) | `Replicated*` tables, coordinated through ClickHouse Keeper |

## Why this matters for the sidekick

The things PostgreSQL does to be a great transactional database (a process of its own per session, row locks, MVCC, WAL before everything, in-place page changes) are the same things that make
a full scan over hundreds of millions of rows expensive. The things ClickHouse does to scan fast (columns, immutable parts, one process with all cores per query, background merges) are the
same things that make a single-row update or a thousand tiny inserts per second awkward. Neither is "better". Put each where it is strong and move the data between them: that is paths 1 to 6.

## See it yourself

```bash
scripts/85_architecture_tour.sh
```

prints the housekeeping processes and key settings of PostgreSQL, the thread pool settings and live thread counts of ClickHouse, and the query pipeline of a `GROUP BY`
(on a machine with 8 cores you will see `× 8`).
