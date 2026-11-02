#!/usr/bin/env bash
# Path 3: a refreshable materialized view. ClickHouse pulls from PostgreSQL on its own schedule into a local copy.
# Double-checks: after the first refresh both sides have the same row count and the same sum(liters);
# rows added in PostgreSQL arrive with the next refresh (we trigger it, you can also just wait 10 seconds).
source "$(dirname "${BASH_SOURCE[0]}")/00_lib.sh"

log "Path 3: prerequisites (the PostgreSQL-engine table from path 2) and the refreshable view"
chfile "$REPO/sql/21_ch_p2_engine.sql"
chq "DROP VIEW IF EXISTS ${CH_DB}.p3_refresh SYNC; DROP TABLE IF EXISTS ${CH_DB}.p3_copy SYNC"
chfile "$REPO/sql/30_ch_p3_refreshable.sql"
chq "SYSTEM WAIT VIEW ${CH_DB}.p3_refresh"

sum_pg() { pgv 'SELECT round(sum(liters)::numeric, 1) FROM beer_sales'; }
sum_ch() { chv "SELECT round(sum(liters), 1) FROM ${CH_DB}.p3_copy"; }
check "rows after the first refresh" "$(pgv 'SELECT count(*) FROM beer_sales')" "$(chv "SELECT count() FROM ${CH_DB}.p3_copy")"
check "sum(liters) after the first refresh" "$(sum_pg)" "$(sum_ch)"

log "Path 3: new rows in PostgreSQL arrive with the next refresh"
pgc -c "INSERT INTO beer_sales (country, beer_name, channel, customer_id, liters, price_eur)
        SELECT 'BE', 'Rochefort 10', 'bar', i, 20, 8.5 FROM generate_series(1, 3) AS i"
echo "PostgreSQL: $(pgv 'SELECT count(*) FROM beer_sales') rows | copy before the refresh: $(chv "SELECT count() FROM ${CH_DB}.p3_copy") rows"
chq "SYSTEM REFRESH VIEW ${CH_DB}.p3_refresh; SYSTEM WAIT VIEW ${CH_DB}.p3_refresh"
check "rows after the next refresh" "$(pgv 'SELECT count(*) FROM beer_sales')" "$(chv "SELECT count() FROM ${CH_DB}.p3_copy")"
check "sum(liters) after the next refresh" "$(sum_pg)" "$(sum_ch)"

log "Path 3: what the timer says"
chfile "$REPO/sql/31_ch_p3_status.sql"
warn "Freshness = refresh interval. Seconds to minutes, not real time. For real time see paths 4 to 6."
