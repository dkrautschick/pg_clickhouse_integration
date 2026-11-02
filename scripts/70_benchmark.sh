#!/usr/bin/env bash
# The same table and the same SELECTs in PostgreSQL and ClickHouse, milliseconds for each.
# A first impression, not a lab benchmark: one machine, default settings, warm caches, best of BENCH_ROUNDS runs.
# Database 'beerbench' in PostgreSQL and '${CH_DB}_bench' in ClickHouse are recreated on every run.
# Double-checks: identical row counts and identical sums after the load, then 7 queries timed on both sides.
source "$(dirname "${BASH_SOURCE[0]}")/00_lib.sh"
ROWS_B="${1:-$BENCH_ROWS}"
BENCH_PG_DB=beerbench

log "Benchmark: $ROWS_B rows into PostgreSQL ($BENCH_PG_DB)"
pg_admin -c "DROP DATABASE IF EXISTS $BENCH_PG_DB" -c "CREATE DATABASE $BENCH_PG_DB"
bpg() { PGPASSWORD="$PG_PASSWORD" psql -X -q -v ON_ERROR_STOP=1 -h "$PG_HOST" -p "$PG_PORT" -U "$PG_USER" -d "$BENCH_PG_DB" "$@"; }
bpg -f "$REPO/sql/70_bench_pg_schema.sql"
t0=$(date +%s); bpg -v rows="$ROWS_B" -f "$REPO/sql/71_bench_pg_load.sql"; t1=$(date +%s)
bpg -f "$REPO/sql/72_bench_pg_index.sql"; t2=$(date +%s)
bpg -c "GRANT SELECT ON beer_sales TO $PG_RO_USER"
ok "PostgreSQL: load $((t1 - t0)) s, primary key + index + vacuum analyze $((t2 - t1)) s"

log "Benchmark: the same rows into ClickHouse (INSERT ... SELECT FROM postgresql(...))"
chfile "$REPO/sql/73_bench_ch.sql"
t0=$(date +%s); chfile "$REPO/sql/74_bench_ch_load.sql"; t1=$(date +%s)
ok "ClickHouse: load $((t1 - t0)) s"

pg_n="$(bpg -tA -c 'SELECT count(*) FROM beer_sales')"; pg_s="$(bpg -tA -c 'SELECT round(sum(liters)::numeric)::bigint FROM beer_sales')"
check "rows" "$pg_n" "$(chv "SELECT count() FROM ${CH_DB}_bench.beer_sales")"
check "sum(liters)" "$pg_s" "$(chv "SELECT toInt64(round(sum(liters))) FROM ${CH_DB}_bench.beer_sales")"
echo "size on disk: PostgreSQL table $(bpg -tA -c "SELECT pg_size_pretty(pg_table_size('beer_sales'))") + indexes $(bpg -tA -c "SELECT pg_size_pretty(pg_indexes_size('beer_sales'))") | ClickHouse $(chv "SELECT formatReadableSize(sum(bytes_on_disk)) FROM system.parts WHERE database = '${CH_DB}_bench' AND table = 'beer_sales' AND active")"

D30="$(date -d '30 days ago' +%F 2>/dev/null || date -v-30d +%F)"; MID=$((ROWS_B / 2))
NAMES=("count rows" "sum and avg" "top 5 countries" "revenue per month" "DE, last 30 days" "top 5 customers" "point lookup by id")
SQLS=(
"SELECT count(*) FROM beer_sales"
"SELECT sum(liters), avg(price_eur) FROM beer_sales"
"SELECT country, count(*) AS sales, round(sum(liters)) AS liters FROM beer_sales GROUP BY country ORDER BY liters DESC LIMIT 5"
"SELECT date_trunc('month', sold_at) AS month, round(sum(price_eur)) AS revenue FROM beer_sales GROUP BY month ORDER BY month"
"SELECT beer_name, round(sum(liters)) AS liters FROM beer_sales WHERE country = 'DE' AND sold_at >= '$D30' GROUP BY beer_name ORDER BY liters DESC LIMIT 5"
"SELECT customer_id, count(*) AS orders, round(sum(price_eur)) AS spent FROM beer_sales GROUP BY customer_id ORDER BY orders DESC, customer_id LIMIT 5"
"SELECT * FROM beer_sales WHERE id = $MID")

time_pg() { # best of BENCH_ROUNDS after one warm-up, from psql's own \timing (round trip, no process start)
  { printf '\\timing on\n'; for _ in $(seq 0 "$BENCH_ROUNDS"); do printf '%s;\n' "$1"; done; } |
    PGPASSWORD="$PG_PASSWORD" psql -X -q -h "$PG_HOST" -p "$PG_PORT" -U "$PG_USER" -d "$BENCH_PG_DB" -o /dev/null 2>&1 |
    grep -oE 'Time: [0-9.]+' | tail -n "$BENCH_ROUNDS" | awk '{print $2}' | sort -n | head -n1
}
time_ch() { # same for clickhouse-client --time (seconds, converted to ms)
  local q="" i; for i in $(seq 0 "$BENCH_ROUNDS"); do q="$q$1 FORMAT Null;"$'\n'; done
  chc --database "${CH_DB}_bench" --multiquery --time --query "$q" 2>&1 >/dev/null |
    grep -E '^[0-9]+(\.[0-9]+)?$' | tail -n "$BENCH_ROUNDS" | sort -n | head -n1 | awk '{printf "%.3f", $1 * 1000}'
}
fmt() { awk -v v="$1" 'BEGIN { if (v < 10) printf "%.2f ms", v; else if (v < 1000) printf "%.1f ms", v; else printf "%.0f ms", v }'; }

log "Benchmark: the race (best of $BENCH_ROUNDS, one warm-up run)"
mkdir -p "$REPO/results"; OUT="$REPO/results/benchmark.csv"; echo "query,postgresql_ms,clickhouse_ms" > "$OUT"
printf '\n  %-3s %-20s %14s %14s   %s\n  %s\n' "#" "query" "PostgreSQL" "ClickHouse" "who wins" "---------------------------------------------------------------------------"
for i in "${!SQLS[@]}"; do
  p="$(time_pg "${SQLS[$i]}")"; c="$(time_ch "${SQLS[$i]}")"
  [[ -n "$p" && -n "$c" ]] || { printf '  %-3s %-20s (measurement failed)\n' "$((i + 1))" "${NAMES[$i]}"; continue; }
  v="$(awk -v p="$p" -v c="$c" 'BEGIN { if (c < 0.001) c = 0.001; if (p < 0.001) p = 0.001; if (c <= p) printf "ClickHouse %.1fx faster", p / c; else printf "PostgreSQL %.1fx faster", c / p }')"
  printf '  %-3s %-20s %14s %14s   %s\n' "$((i + 1))" "${NAMES[$i]}" "$(fmt "$p")" "$(fmt "$c")" "$v"
  echo "\"${NAMES[$i]}\",$p,$c" >> "$OUT"
done
echo; ok "numbers saved to $OUT"
warn "Same SQL text, default settings, warm caches, one machine. The point lookup is in on purpose: it is where PostgreSQL wins."
