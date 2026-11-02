#!/usr/bin/env bash
# Path 1: the caveman way. COPY out of PostgreSQL, INSERT into ClickHouse, and watch the copy go stale.
# Double-checks: row counts equal right after the load, difference equals the rows added afterwards (stale on purpose).
source "$(dirname "${BASH_SOURCE[0]}")/00_lib.sh"
FILE="${TMPDIR:-/tmp}/beer_sales.csv"

log "Path 1: export from PostgreSQL ($FILE)"
pgc -c "\copy (SELECT * FROM beer_sales ORDER BY id) TO '$FILE' CSV HEADER"
ok "$(($(wc -l < "$FILE") - 1)) rows exported, $(du -h "$FILE" | cut -f1)"

log "Path 1: import into ClickHouse"
chfile "$REPO/sql/10_ch_p1_csv.sql"
chq "TRUNCATE TABLE ${CH_DB}.p1_csv"
# best_effort because PostgreSQL writes timestamps like 2026-10-31 12:00:00.123456+00
chc --date_time_input_format=best_effort --query "INSERT INTO ${CH_DB}.p1_csv FORMAT CSVWithNames" < "$FILE"
pg_rows="$(pgv 'SELECT count(*) FROM beer_sales')"
check "rows after the load (PostgreSQL = ClickHouse)" "$pg_rows" "$(chv "SELECT count() FROM ${CH_DB}.p1_csv")"

log "Path 1: the stale-the-moment-you-press-Enter part"
pgc -c "INSERT INTO beer_sales (country, beer_name, channel, customer_id, liters, price_eur)
        SELECT 'BE', 'Westvleteren 12', 'bar', i, 33, 12.5 FROM generate_series(1, 5) AS i"
echo "PostgreSQL: $(pgv 'SELECT count(*) FROM beer_sales') rows | ClickHouse: $(chv "SELECT count() FROM ${CH_DB}.p1_csv") rows"
check "rows ClickHouse has not seen" 5 "$(( $(pgv 'SELECT count(*) FROM beer_sales') - $(chv "SELECT count() FROM ${CH_DB}.p1_csv") ))"
warn "That is the whole trade-off: simple, but you re-run it by hand and it moves everything every time."
rm -f "$FILE"
