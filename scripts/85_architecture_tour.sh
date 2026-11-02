#!/usr/bin/env bash
# See the architecture comparison of the talk on your own servers: processes and settings in PostgreSQL, thread pools
# and the query pipeline in ClickHouse. Read-only. See docs/architecture.md for what each line means.
source "$(dirname "${BASH_SOURCE[0]}")/00_lib.sh"

log "PostgreSQL: a process per connection, plus housekeeping processes"
render "$REPO/sql/87_pg_architecture.sql" | pgc

log "ClickHouse: one server process, work is done by threads from pools"
chfile "$REPO/sql/85_ch_architecture.sql"

log "ClickHouse: the query pipeline of a GROUP BY (xN = parallel lanes = max_threads)"
chq "SELECT name, value FROM system.settings WHERE name = 'max_threads' FORMAT TSVRaw" >/dev/null
chfile "$REPO/sql/86_ch_pipeline.sql"
warn "On a laptop with 8 cores the same plan reads xN with N = 8: one lane per core, each lane works on its own granules."
