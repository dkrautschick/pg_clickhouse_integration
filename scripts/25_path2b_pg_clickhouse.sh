#!/usr/bin/env bash
# Path 2b: pg_clickhouse, the mirror image of path 2. PostgreSQL gets a foreign schema `ch` that points at ClickHouse.
# It moves QUERIES, not data: the table it reads here is the copy path 1 (or 3) filled.
# Skips cleanly (exit 0) when the extension is not installed in your PostgreSQL.
# Double-checks: extension available, plan shows a Foreign Scan, aggregate result equals the one from PostgreSQL itself.
source "$(dirname "${BASH_SOURCE[0]}")/00_lib.sh"

have="$(pg_admin -tA -c "SELECT count(*) FROM pg_available_extensions WHERE name = 'pg_clickhouse'")"
if [[ "$have" != 1 ]]; then
  warn "pg_clickhouse is not installed in this PostgreSQL, skipping path 2b."
  cat <<'TXT'
  Get it in one of three ways (PostgreSQL 13+, ClickHouse 23.3+):
    1) docker run -d --network host --name pg_clickhouse -e POSTGRES_PASSWORD=beer ghcr.io/clickhouse/pg_clickhouse:18
       (the image is the official PostgreSQL image plus the extension; --network host lets it reach ClickHouse on localhost)
    2) pgxn install pg_clickhouse                  (builds from source, needs a C++ toolchain)
    3) build from https://github.com/ClickHouse/pg_clickhouse
  Then point PG_HOST/PG_PORT in .env at that instance, run 01_seed.sh and 10_path1_csv.sh against it, and re-run this script.
TXT
  exit 0
fi

log "Path 2b: foreign server, user mapping, IMPORT FOREIGN SCHEMA"
render "$REPO/sql/25_pg_p2b_pg_clickhouse.sql" | pgc
[[ "$(pgv "SELECT count(*) FROM information_schema.foreign_tables WHERE foreign_table_schema = 'ch'")" -ge 1 ]] \
  && ok "foreign tables imported: $(pgv "SELECT string_agg(foreign_table_name, ', ') FROM information_schema.foreign_tables WHERE foreign_table_schema = 'ch'")"

log "Path 2b: the plan and the answer"
plan="$(pgc -tA -c "EXPLAIN (VERBOSE, COSTS OFF) SELECT country, sum(liters) FROM ch.p1_csv GROUP BY country")"
echo "$plan"
if grep -q 'Foreign Scan' <<<"$plan"; then ok "plan contains a Foreign Scan (the work happens in ClickHouse)"; else warn "no Foreign Scan in the plan"; fi
pgc -f "$REPO/sql/26_pg_p2b_queries.sql"
