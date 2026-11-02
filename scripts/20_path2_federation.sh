#!/usr/bin/env bash
# Path 2: query federation. ClickHouse reads PostgreSQL at query time: table function, table engine, database engine.
# Double-checks: a row inserted into PostgreSQL is visible in ClickHouse immediately (no copy), and every query
# is a round trip (the federated aggregation is timed against the local MergeTree copy from path 1).
source "$(dirname "${BASH_SOURCE[0]}")/00_lib.sh"

log "Path 2a: postgresql() table function (top 5 countries by liters, computed in ClickHouse)"
chfile "$REPO/sql/20_ch_p2_function.sql"

log "Path 2b: ENGINE = PostgreSQL table, and 2c: the PostgreSQL database engine"
chfile "$REPO/sql/21_ch_p2_engine.sql"
chfile "$REPO/sql/22_ch_p2_database.sql"
chq "SHOW CREATE TABLE ${CH_DB}.p2_pg_beer_sales FORMAT TSVRaw" | sed -E "s/'${PG_RO_PASSWORD}'/'[HIDDEN]'/"
echo "tables visible through the database engine: $(chv "SELECT arrayStringConcat(groupArray(name), ', ') FROM system.tables WHERE database = '${CH_DB}_pg'")"

log "Live, not copied: insert a row in PostgreSQL, read it from ClickHouse a moment later"
before="$(chv "SELECT count() FROM ${CH_DB}.p2_pg_beer_sales")"
pgc -c "INSERT INTO beer_sales (country, beer_name, channel, customer_id, liters, price_eur) VALUES ('BE', 'Orval', 'bar', 7, 25, 9.9)"
check "rows visible in ClickHouse right away" "$((before + 1))" "$(chv "SELECT count() FROM ${CH_DB}.p2_pg_beer_sales")"

log "Every query is a round trip: the same aggregation, federated versus local copy"
q='SELECT country, round(sum(liters)) AS liters FROM %s GROUP BY country ORDER BY liters DESC LIMIT 3 FORMAT Null'
ms() { local s e; s=$(date +%s%N); chc --query "$1" >/dev/null; e=$(date +%s%N); echo $(( (e - s) / 1000000 )); }
# shellcheck disable=SC2059  # $q is a printf template on purpose
for run in 1 2; do
  fed=$(ms "$(printf "$q" "${CH_DB}.p2_pg_beer_sales")"); loc=$(ms "$(printf "$q" "${CH_DB}.p1_csv")")
  echo "run $run: PostgreSQL engine ${fed} ms | local MergeTree ${loc} ms (includes client start-up)"
done
warn "Great for exploration and small lookups, rough at scale: every row of every query travels over the wire."
