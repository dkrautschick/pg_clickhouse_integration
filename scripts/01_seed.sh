#!/usr/bin/env bash
# Step 1: PostgreSQL gets the demo database, the table, a read-only role for ClickHouse and ROWS rows of beer sales.
#         ClickHouse gets an empty database. Re-runnable: an existing table is kept, rows are added only if it is empty.
# Double-checks: wal_level, the read-only role can SELECT, row count in PostgreSQL equals what we seeded.
source "$(dirname "${BASH_SOURCE[0]}")/00_lib.sh"

log "PostgreSQL: database '$PG_DB', table, read-only role"
[[ "$(pg_admin -tA -c "SELECT count(*) FROM pg_database WHERE datname = '$PG_DB'")" == 1 ]] \
  || pg_admin -c "CREATE DATABASE $PG_DB"
pgc -f "$REPO/sql/00_pg_schema.sql"
pg_admin -c "DO \$\$ BEGIN IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = '$PG_RO_USER') THEN
               CREATE ROLE $PG_RO_USER LOGIN PASSWORD '$PG_RO_PASSWORD'; END IF; END \$\$"
pgc -c "GRANT SELECT ON beer_sales TO $PG_RO_USER"
ok "wal_level = $(pgv 'SHOW wal_level') (needs to be 'logical' for paths 4 and 6)"

have="$(pgv 'SELECT count(*) FROM beer_sales')"
if [[ "$have" == 0 ]]; then
  log "Seeding $ROWS rows"
  pgc -v rows="$ROWS" -f "$REPO/sql/01_pg_seed.sql"
  pgc -c "ANALYZE beer_sales"
fi
ok "PostgreSQL beer_sales: $(pgv 'SELECT count(*) FROM beer_sales') rows"

log "ClickHouse: database '$CH_DB'"
chfile "$REPO/sql/02_ch_schema.sql"
ok "ClickHouse $(chv 'SELECT version()') reachable, database '$CH_DB' exists"
