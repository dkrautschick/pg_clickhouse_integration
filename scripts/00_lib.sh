#!/usr/bin/env bash
# Shared helpers. Source this file, do not run it.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/.." && pwd)"
ENV_FILE="${ENV_FILE:-$REPO/.env}"
# shellcheck disable=SC1090
[[ -f "$ENV_FILE" ]] && source "$ENV_FILE"

: "${PG_HOST:=127.0.0.1}" "${PG_PORT:=5432}" "${PG_USER:=postgres}" "${PG_PASSWORD:=beer}" "${PG_DB:=beerdb}"
: "${PG_ADDR_FROM_CH:=127.0.0.1:5432}" "${PG_RO_USER:=ch_reader}" "${PG_RO_PASSWORD:=ch_reader_pw}"
: "${CH_HOST:=127.0.0.1}" "${CH_PORT:=9000}" "${CH_HTTP_PORT:=8123}" "${CH_USER:=default}" "${CH_PASSWORD:=}"
: "${CH_SECURE:=false}" "${CH_DB:=beer}" "${CH_CLIENT:=clickhouse client}"
: "${ROWS:=200000}" "${BENCH_ROWS:=2000000}" "${BENCH_ROUNDS:=3}"
: "${KAFKA_BROKER_FROM_CH:=kafka:19092}" "${CONNECT_URL:=http://127.0.0.1:8083}" "${P4_PREFIX:=p4}"
export PG_HOST PG_PORT PG_USER PG_PASSWORD PG_DB PG_ADDR_FROM_CH PG_RO_USER PG_RO_PASSWORD
export CH_HOST CH_PORT CH_HTTP_PORT CH_USER CH_PASSWORD CH_SECURE CH_DB ROWS BENCH_ROWS BENCH_ROUNDS
export KAFKA_BROKER_FROM_CH CONNECT_URL P4_PREFIX
export AIVEN_SRC="${AIVEN_SRC:-}"

log()  { printf '\n\033[1;34m==> %s\033[0m\n' "$*"; }
ok()   { printf '\033[1;32m  OK  %s\033[0m\n' "$*"; }
warn() { printf '\033[1;33m  !!  %s\033[0m\n' "$*"; }
die()  { printf '\033[1;31mERROR: %s\033[0m\n' "$*" >&2; exit 1; }
need() { command -v "$1" >/dev/null 2>&1 || die "'$1' not found in PATH"; }

need psql; need envsubst

# --- PostgreSQL ------------------------------------------------------------------------------
# pg_admin: connect to the maintenance database; pgc: connect to the demo database.
pg_admin() { PGPASSWORD="$PG_PASSWORD" psql -X -q -v ON_ERROR_STOP=1 -h "$PG_HOST" -p "$PG_PORT" -U "$PG_USER" -d postgres "$@"; }
pgc()      { PGPASSWORD="$PG_PASSWORD" psql -X -q -v ON_ERROR_STOP=1 -h "$PG_HOST" -p "$PG_PORT" -U "$PG_USER" -d "$PG_DB" "$@"; }
pgv()      { pgc -tA -c "$1"; }                       # one value to stdout

# --- ClickHouse ------------------------------------------------------------------------------
# Intentionally word-split: CH_CLIENT may be "clickhouse client" (one binary) or "clickhouse-client".
chc() {
  local secure=(); [[ "$CH_SECURE" == "true" ]] && secure=(--secure)
  # shellcheck disable=SC2086
  $CH_CLIENT --host "$CH_HOST" --port "$CH_PORT" --user "$CH_USER" \
    ${CH_PASSWORD:+--password "$CH_PASSWORD"} "${secure[@]}" "$@" \
    2> >(grep -v -E 'Unknown settings?: .*skipping' >&2)
}
chq() { chc --multiquery --query "$1"; }              # run SQL, print result
chv() { chc --format TSVRaw --query "$1"; }           # one value to stdout
# render: fill ${VAR} placeholders of a SQL template from the environment, nothing else.
render() { envsubst '${PG_ADDR_FROM_CH} ${PG_DB} ${PG_RO_USER} ${PG_RO_PASSWORD} ${CH_DB} ${KAFKA_BROKER_FROM_CH} ${P4_PREFIX} ${AIVEN_SRC}' < "$1"; }
chfile() { render "$1" | chc --multiquery; }          # run a SQL template file

# check <description> <expected> <actual>: compare two values and say so
check() {
  if [[ "$2" == "$3" ]]; then ok "$1: $2"; else die "$1: expected $2, got $3"; fi
}

# wait_until <seconds> <description> <command...>: poll a command until it succeeds
wait_until() {
  local t="$1" what="$2"; shift 2
  local i; for ((i = 0; i < t; i++)); do "$@" >/dev/null 2>&1 && { ok "$what"; return 0; }; sleep 1; done
  die "timeout after ${t}s: $what"
}

# wait_for <seconds> <description> '<shell expression>': like wait_until, but evaluates the expression in the
# current shell, so helper functions (chv, pgv, ...) are available. Quote the expression with single quotes.
wait_for() {
  local t="$1" what="$2" expr="$3" i
  for ((i = 0; i < t; i++)); do if eval "$expr" >/dev/null 2>&1; then ok "$what"; return 0; fi; sleep 1; done
  die "timeout after ${t}s: $what"
}
