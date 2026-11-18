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
: "${CDC_PG_HOST:=postgres}" "${CDC_PG_PORT:=5432}"
: "${KAFKA_BROKER_FROM_CH:=kafka:19092}" "${CONNECT_URL:=http://127.0.0.1:8083}" "${P4_PREFIX:=p4}"
export PG_HOST PG_PORT PG_USER PG_PASSWORD PG_DB PG_ADDR_FROM_CH PG_RO_USER PG_RO_PASSWORD
export CH_HOST CH_PORT CH_HTTP_PORT CH_USER CH_PASSWORD CH_SECURE CH_DB ROWS BENCH_ROWS BENCH_ROUNDS
export KAFKA_BROKER_FROM_CH CONNECT_URL P4_PREFIX CDC_PG_HOST CDC_PG_PORT
export AIVEN_SRC="${AIVEN_SRC:-}"

log()  { printf '\n\033[1;34m==> %s\033[0m\n' "$*"; }
ok()   { printf '\033[1;32m  OK  %s\033[0m\n' "$*"; }
warn() { printf '\033[1;33m  !!  %s\033[0m\n' "$*"; }
die()  { printf '\033[1;31mERROR: %s\033[0m\n' "$*" >&2; exit 1; }
need() { command -v "$1" >/dev/null 2>&1 || die "'$1' not found in PATH"; }

need psql; need envsubst

# --- Demo mode -------------------------------------------------------------------------------
# DEMO=yes (or run_all.sh --demo): before every statement that goes to PostgreSQL or ClickHouse, print it and wait for a key,
# then run it, so the audience sees the statement first and the result second.
#   [Enter] run it   [c] no more pauses (statements are still printed)   [q] quit
# DEMO=full also shows the one-value queries behind the checks. Without a terminal nothing waits (statements are printed only).
export DEMO="${DEMO:-no}"
[[ -z "${SETUP_RUNNING:-}" ]] || DEMO=no   # setup.sh probes the servers a lot; the pauses belong to the demo scripts
[[ "$DEMO" == no ]] || export DEMO_NOPAUSE_FILE="${DEMO_NOPAUSE_FILE:-$(mktemp -u)}"
_tty_ok() { { : </dev/tty; } 2>/dev/null; }
demo_show() {   # demo_show <label> <text>
  [[ "$DEMO" == no || -n "${_QUIET:-}" ]] && return 0
  if _tty_ok; then printf '\n\033[1;36m%s\033[0m\n\033[0;36m%s\033[0m\n' "$1" "$2" > /dev/tty
  else printf '\n\033[1;36m%s\033[0m\n\033[0;36m%s\033[0m\n' "$1" "$2" >&2; fi   # >&2, not > /dev/stderr: that would truncate a redirected log
  if [[ ! -e "$DEMO_NOPAUSE_FILE" ]] && _tty_ok; then
    local k=""; printf '\033[2m  [Enter] run   [c] stop pausing   [q] quit \033[0m' > /dev/tty
    read -r -n1 -s k < /dev/tty || true; printf '\n' > /dev/tty
    case "$k" in c|C) : > "$DEMO_NOPAUSE_FILE" ;; q|Q) kill -TERM "$$" ;; esac
  fi
  return 0
}

# --- PostgreSQL ------------------------------------------------------------------------------
# pg_admin: connect to the maintenance database; pgc: connect to the demo database.
_pg_sql() {   # the SQL a psql call is going to run: -c strings and -f files
  local a prev="" out=""
  for a in "$@"; do
    case "$prev" in -c|--command) out+="$a"$'\n' ;; -f|--file) out+="$(cat "$a")"$'\n' ;; esac
    prev="$a"
  done
  printf '%s' "$out"
}
_pg() {
  local db="$1"; shift
  local sql stdin_data="" have_stdin=no; sql="$(_pg_sql "$@")"
  if [[ -z "$sql" && ! -t 0 ]]; then stdin_data="$(cat)"; have_stdin=yes; sql="$stdin_data"; fi
  if [[ "$DEMO" == full || " $* " != *" -tA "* && " $* " != *" -t "* ]]; then demo_show "PostgreSQL  ($db)" "$sql"; fi
  if [[ "$have_stdin" == yes ]]; then
    printf '%s\n' "$stdin_data" | PGPASSWORD="$PG_PASSWORD" psql -X -q -v ON_ERROR_STOP=1 -h "$PG_HOST" -p "$PG_PORT" -U "$PG_USER" -d "$db" "$@"
  else
    PGPASSWORD="$PG_PASSWORD" psql -X -q -v ON_ERROR_STOP=1 -h "$PG_HOST" -p "$PG_PORT" -U "$PG_USER" -d "$db" "$@"
  fi
}
pg_admin() { _pg postgres "$@"; }
pgc()      { _pg "$PG_DB" "$@"; }
pgv()      { if [[ "$DEMO" == full ]]; then pgc -tA -c "$1"; else _QUIET=1 pgc -tA -c "$1"; fi; }   # one value to stdout

# --- ClickHouse ------------------------------------------------------------------------------
# Intentionally word-split: CH_CLIENT may be "clickhouse client" (one binary) or "clickhouse-client".
_ch() {
  local secure=() host="$CH_HOST" port="$CH_PORT"; [[ "$CH_SECURE" == "true" ]] && secure=(--secure)
  # setup.sh falls back to the client inside our container when the host has none: there the server is on 127.0.0.1:9000
  [[ "$CH_CLIENT" == "docker exec"* ]] && { host=127.0.0.1; port=9000; }
  # shellcheck disable=SC2086
  $CH_CLIENT --host "$host" --port "$port" --user "$CH_USER" \
    ${CH_PASSWORD:+--password "$CH_PASSWORD"} "${secure[@]}" "$@" \
    2> >(grep -v -E 'Unknown settings?: .*skipping' >&2)
}
chc() {
  local q="" prev="" a stdin_data="" have_stdin=no
  for a in "$@"; do [[ "$prev" == --query || "$prev" == -q ]] && q="$a"; prev="$a"; done
  if [[ -z "$q" && ! -t 0 ]]; then stdin_data="$(cat)"; have_stdin=yes; q="$stdin_data"; fi
  demo_show "ClickHouse" "$q"
  if [[ "$have_stdin" == yes ]]; then printf '%s\n' "$stdin_data" | _ch "$@"; else _ch "$@"; fi
}
chq() { chc --multiquery --query "$1"; }              # run SQL, print result
chv() { if [[ "$DEMO" == full ]]; then chc --format TSVRaw --query "$1"; else _QUIET=1 chc --format TSVRaw --query "$1"; fi; }   # one value to stdout
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

# --- Preflight: are the servers there? ---------------------------------------------------------------------
# Every script sources this file, so a missing server is reported once, in one place, with the way out.
# Skipped by setup.sh itself and by scripts that do not need the local pair (NEED_SERVERS=no before sourcing).
preflight() {
  local bad=0
  if ! _QUIET=1 PGCONNECT_TIMEOUT=3 pg_admin -tA -c 'SELECT 1' >/dev/null 2>&1; then
    warn "PostgreSQL is not reachable on $PG_HOST:$PG_PORT as $PG_USER (or the credentials in .env are wrong)."; bad=1
  fi
  if ! _QUIET=1 chc --query 'SELECT 1' >/dev/null 2>&1; then
    warn "ClickHouse is not reachable on $CH_HOST:$CH_PORT as $CH_USER with '$CH_CLIENT' (or the credentials in .env are wrong)."; bad=1
  fi
  if [[ $bad -ne 0 ]]; then
    die "Run scripts/setup.sh first: it asks docker or local, detects servers that already run (e.g. a local PostgreSQL on 5432), picks free ports and writes .env. 'scripts/setup.sh check' only looks."
  fi
}
if [[ -z "${SETUP_RUNNING:-}" && "${NEED_SERVERS:-yes}" == yes ]]; then preflight; fi
