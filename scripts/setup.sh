#!/usr/bin/env bash
# Choose how PostgreSQL and ClickHouse run, detect what already runs, and write the result to .env.
#
#   scripts/setup.sh [up]      decide + start + verify          (default)
#   scripts/setup.sh check     only look: tools, ports, running servers; changes nothing
#   scripts/setup.sh status    what is configured and reachable right now
#   scripts/setup.sh down      stop what 'up' started (docker: compose down -v; local: our own instances only)
#
# Run mode (one question, two answers):
#   MODE=docker   both servers as containers (docker/compose.yml). Needs only Docker + a psql client.
#   MODE=local    both servers on this machine, "from scratch": PostgreSQL from the packages / PG_BIN,
#                 ClickHouse as the single binary or packages. If nothing is installed for ClickHouse, the script offers
#                 to download the single binary into .local/bin. Own instances live in .local/ (data, logs, pid files).
#   MODE unset    interactive: asked once; non-interactive: docker if the Docker daemon answers, otherwise local.
#   PG_MODE / CH_MODE override a single side (mixed setups work: ClickHouse in Docker, PostgreSQL on the host).
#
# Something already running on the ports (a local PostgreSQL on 5432, a ClickHouse on 9000/8123, a foreign container)?
# That is detected before anything is started, and you decide (ON_CONFLICT=ask|reuse|own|abort):
#   reuse   use the running server (needs working credentials; demo objects are created in it: databases beerdb/beerbench,
#           role ch_reader, ClickHouse databases beer*, nothing else, see 99_cleanup.sh)
#   own     leave it alone, start our own instance on the next free port(s)
#   abort   stop here
# Default when asked nothing (no terminal): docker mode -> own, local mode -> reuse if usable, otherwise own.
#
# What it writes to .env: PG_PORT, CH_PORT, CH_HTTP_PORT, PG_ADDR_FROM_CH, CDC_PG_HOST/CDC_PG_PORT, CH_CLIENT, CH_PASSWORD (own
# local ClickHouse: empty, it listens on 127.0.0.1 only), PG_LISTEN. Re-running is safe.
export SETUP_RUNNING=1
source "$(dirname "${BASH_SOURCE[0]}")/00_lib.sh"

CMD="${1:-up}"
LOCAL_DIR="$REPO/.local"
COMPOSE=(docker compose --env-file "$ENV_FILE" -f "$REPO/docker/compose.yml")
PG_CONTAINER=pgch-postgres
CH_CONTAINER=pgch-clickhouse
INTERACTIVE=no; [[ -t 0 && -t 1 ]] && INTERACTIVE=yes

# ---------------------------------------------------------------------------------------- helpers
touch "$ENV_FILE"
set_env() {   # set_env KEY VALUE: replace the line KEY=... in .env or append it
  local k="$1" v="$2" tmp; tmp="$(mktemp)"
  grep -v -E "^${k}=" "$ENV_FILE" > "$tmp" || true
  printf '%s=%s\n' "$k" "$v" >> "$tmp"
  cat "$tmp" > "$ENV_FILE"; rm -f "$tmp"
}
port_busy()  { (exec 3<>"/dev/tcp/127.0.0.1/$1") 2>/dev/null; }
port_owner() { lsof -nP -iTCP:"$1" -sTCP:LISTEN 2>/dev/null | awk 'NR==2 {print $1 " (pid " $2 ")"}' || true; }
free_port()  { local p="$1"; while port_busy "$p"; do p=$((p + 1)); done; echo "$p"; }
ask() {       # ask "question" default-answer choices-hint -> echoes the answer; non-interactive: the default
  local q="$1" def="$2" hint="$3" a=""
  if [[ "$INTERACTIVE" == yes ]]; then read -r -p "  $q [$hint, Enter = $def] " a || true; fi
  echo "${a:-$def}"
}
docker_ok()  { command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1; }
container_running() { [[ "$(docker inspect -f '{{.State.Running}}' "$1" 2>/dev/null || true)" == true ]]; }

# Probe PostgreSQL: prints ok:<wal_level> (we can log in), auth (a server answers, our credentials fail), none.
pg_probe() {
  local out rc=0
  out="$(PGPASSWORD="$PG_PASSWORD" PGCONNECT_TIMEOUT=3 psql -X -h "$1" -p "$2" -U "$PG_USER" -d postgres -w -tAc 'SHOW wal_level' 2>&1)" || rc=$?
  if [[ $rc -eq 0 ]]; then echo "ok:$out"
  elif grep -qiE 'FATAL|password|authentication|pg_hba' <<<"$out"; then echo auth
  else echo none; fi
}
# Probe ClickHouse: ok (HTTP ping + login works), auth (a ClickHouse answers, login fails), none.
ch_probe() {
  curl -sf -m 3 "http://$CH_HOST:$1/ping" 2>/dev/null | grep -q 'Ok' || { echo none; return; }
  if CH_PORT="$2" chc --query 'SELECT 1' >/dev/null 2>&1; then echo ok; else echo auth; fi
}

find_pg_bin() {   # directory with initdb + pg_ctl + postgres
  local d
  if [[ -n "${PG_BIN:-}" ]]; then echo "$PG_BIN"; return; fi
  if command -v pg_ctl >/dev/null && command -v initdb >/dev/null; then dirname "$(command -v pg_ctl)"; return; fi
  for d in /usr/lib/postgresql/*/bin /usr/pgsql-*/bin /opt/homebrew/opt/postgresql@*/bin /usr/local/opt/postgresql@*/bin /Library/PostgreSQL/*/bin; do
    [[ -x "$d/initdb" && -x "$d/pg_ctl" ]] && last="$d"
  done
  echo "${last:-}"
}
find_ch_client() {   # prints a CH_CLIENT command or nothing
  if [[ -n "${CH_CLIENT_FORCED:-}" ]]; then echo "$CH_CLIENT_FORCED"; return; fi
  if command -v clickhouse-client >/dev/null; then echo clickhouse-client
  elif command -v clickhouse >/dev/null; then echo "clickhouse client"
  elif [[ -x "$LOCAL_DIR/bin/clickhouse" ]]; then echo "$LOCAL_DIR/bin/clickhouse client"; fi
}
find_ch_server() {   # prints a command that starts the server, or nothing
  if command -v clickhouse-server >/dev/null; then echo clickhouse-server
  elif command -v clickhouse >/dev/null; then echo "clickhouse server"
  elif [[ -x "$LOCAL_DIR/bin/clickhouse" ]]; then echo "$LOCAL_DIR/bin/clickhouse server"; fi
}
download_ch() {
  mkdir -p "$LOCAL_DIR/bin"
  warn "no ClickHouse binary found. The official single binary (about 200 to 500 MB) goes to $LOCAL_DIR/bin (curl https://clickhouse.com/ | sh)."
  [[ "$(ask 'Download it now?' y 'y/n')" == y ]] || die "Install ClickHouse first (packages: see README) or run MODE=docker scripts/setup.sh"
  need curl
  ( cd "$LOCAL_DIR/bin" && curl -fsSL https://clickhouse.com/ | sh ) || die "download failed"
  [[ -x "$LOCAL_DIR/bin/clickhouse" ]] || die "download finished but $LOCAL_DIR/bin/clickhouse is missing"
}

# ---------------------------------------------------------------------------------------- decisions
# PG_PLAN / CH_PLAN: docker-new | docker-reuse | local-new | local-reuse | local-own (own instance in .local/)
decide_mode() {
  local m="${MODE:-}"
  if [[ -z "$m" ]]; then
    local def=local; docker_ok && def=docker
    echo "  Run PostgreSQL and ClickHouse ..."
    echo "    docker : all in containers (docker/compose.yml), nothing installed on your machine"
    echo "    local  : natively on this machine, from scratch (own instances in .local/, or reuse running ones)"
    m="$(ask 'Mode?' "$def" 'docker/local')"
  fi
  [[ "$m" == docker || "$m" == local ]] || die "MODE must be docker or local, got '$m'"
  PG_MODE="${PG_MODE:-$m}"; CH_MODE="${CH_MODE:-$m}"
  [[ "$PG_MODE" == docker || "$CH_MODE" == docker ]] && { docker_ok || die "Docker mode needs a running Docker daemon (docker info failed). Start Docker, or use MODE=local."; }
  return 0
}

# conflict <what> <port> <state:ok|auth> <mode>  -> echoes reuse | own | abort
conflict() {
  local what="$1" port="$2" state="$3" mode="$4" def owner; owner="$(port_owner "$port")"
  warn "$what already answers on port $port${owner:+ ($owner)}; login with the configured credentials: $([[ $state == ok* || $state == ok ]] && echo works || echo FAILS)" >&2
  if [[ "${ON_CONFLICT:-ask}" != ask ]]; then echo "$ON_CONFLICT"; return; fi
  if [[ "$mode" == local && ( $state == ok* ) ]]; then def=reuse; else def=own; fi
  if [[ "$INTERACTIVE" == yes ]]; then
    echo "    reuse : use that $what (demo objects get created inside it)" >&2
    echo "    own   : leave it alone, start our own on the next free port" >&2
    echo "    abort : stop here" >&2
  fi
  ask "$what: what now?" "$def" 'reuse/own/abort'
}

plan_pg() {
  PG_PLAN=""
  if [[ "$PG_MODE" == docker ]]; then
    if container_running "$PG_CONTAINER"; then PG_PLAN=docker-reuse; ok "PostgreSQL container $PG_CONTAINER already runs (our stack): reusing it"; return; fi
    PG_PLAN=docker-new
  else
    [[ -f "$LOCAL_DIR/pg/postmaster.pid" ]] && kill -0 "$(head -1 "$LOCAL_DIR/pg/postmaster.pid")" 2>/dev/null && { PG_PLAN=local-own; ok "our own local PostgreSQL ($LOCAL_DIR/pg) already runs"; return; }
    PG_PLAN=local-new
  fi
  if port_busy "$PG_PORT"; then
    local st c; st="$(pg_probe "$PG_HOST" "$PG_PORT")"
    if [[ "$st" == none ]]; then
      warn "port $PG_PORT is taken by something that is not a PostgreSQL we can talk to${PG_PORT:+ ($(port_owner "$PG_PORT"))}: moving to a free port"
      PG_PORT="$(free_port $((PG_PORT + 1)))"
    else
      c="$(conflict PostgreSQL "$PG_PORT" "$st" "$PG_MODE")"
      case "$c" in
        reuse) [[ "$st" == ok* ]] || die "cannot reuse: login failed. Set PG_USER/PG_PASSWORD in .env for that server."
               PG_PLAN=local-reuse ;;
        own)   PG_PORT="$(free_port $((PG_PORT + 1)))"; ok "own PostgreSQL will use port $PG_PORT" ;;
        *)     die "aborted" ;;
      esac
    fi
  fi
}

plan_ch() {
  CH_PLAN=""
  if [[ "$CH_MODE" == docker ]]; then
    if container_running "$CH_CONTAINER"; then CH_PLAN=docker-reuse; ok "ClickHouse container $CH_CONTAINER already runs (our stack): reusing it"; return; fi
    CH_PLAN=docker-new
  else
    [[ -f "$LOCAL_DIR/clickhouse/pid" ]] && kill -0 "$(cat "$LOCAL_DIR/clickhouse/pid")" 2>/dev/null && { CH_PLAN=local-own; ok "our own local ClickHouse ($LOCAL_DIR/clickhouse) already runs"; return; }
    CH_PLAN=local-new
  fi
  if port_busy "$CH_PORT" || port_busy "$CH_HTTP_PORT"; then
    local st c; st="$(ch_probe "$CH_HTTP_PORT" "$CH_PORT")"
    if [[ "$st" == none ]]; then
      warn "port $CH_PORT or $CH_HTTP_PORT is taken by something that is not a ClickHouse we can talk to: moving both to free ports"
      CH_PORT="$(free_port $((CH_PORT + 1)))"; CH_HTTP_PORT="$(free_port $((CH_HTTP_PORT + 1)))"
    else
      c="$(conflict ClickHouse "$CH_HTTP_PORT" "$st" "$CH_MODE")"
      case "$c" in
        reuse) [[ "$st" == ok ]] || die "cannot reuse: login failed. Set CH_USER/CH_PASSWORD in .env for that server."
               CH_PLAN=local-reuse ;;
        own)   CH_PORT="$(free_port $((CH_PORT + 1)))"; CH_HTTP_PORT="$(free_port $((CH_HTTP_PORT + 1)))"
               ok "own ClickHouse will use ports $CH_PORT / $CH_HTTP_PORT" ;;
        *)     die "aborted" ;;
      esac
    fi
  fi
}

# ---------------------------------------------------------------------------------------- derived settings
derive() {
  # Where does ClickHouse find PostgreSQL, and where does Debezium (always a container)?
  if [[ "$CH_PLAN" == docker-* && "$PG_PLAN" == docker-* ]]; then
    PG_ADDR_FROM_CH="postgres:5432"; CDC_PG_HOST=postgres; CDC_PG_PORT=5432
  elif [[ "$CH_PLAN" == docker-* ]]; then       # container -> PostgreSQL on the host
    PG_ADDR_FROM_CH="host.docker.internal:$PG_PORT"; CDC_PG_HOST=host.docker.internal; CDC_PG_PORT=$PG_PORT
    [[ "$PG_PLAN" == local-new || "$PG_PLAN" == local-own ]] && PG_LISTEN='*'
  else                                           # ClickHouse on the host
    PG_ADDR_FROM_CH="127.0.0.1:$PG_PORT"
    if [[ "$PG_PLAN" == docker-* ]]; then CDC_PG_HOST=postgres; CDC_PG_PORT=5432; else CDC_PG_HOST=host.docker.internal; CDC_PG_PORT=$PG_PORT; fi
  fi
  PG_LISTEN="${PG_LISTEN:-127.0.0.1}"
  # Kafka runs in Docker: ClickHouse in a container uses the internal listener, ClickHouse on the host the published one.
  if [[ "$CH_PLAN" == docker-* ]]; then KAFKA_BROKER_FROM_CH=kafka:19092; else KAFKA_BROKER_FROM_CH=127.0.0.1:9092; fi
  # ClickHouse client: a host binary, or the one inside our container
  if [[ "$CH_PLAN" == docker-* ]]; then
    CH_CLIENT_FORCED=""
    if [[ -n "$(find_ch_client)" ]]; then CH_CLIENT="$(find_ch_client)"; else CH_CLIENT="docker exec -i $CH_CONTAINER clickhouse-client"; fi
    CH_PASSWORD="${CH_PASSWORD:-beer}"
  else
    if [[ -z "$(find_ch_client)" ]]; then
      [[ "$CH_PLAN" == local-reuse ]] && die "ClickHouse answers, but no client binary is installed. Install clickhouse-client or set CH_CLIENT in .env."
      download_ch
    fi
    CH_CLIENT="$(find_ch_client)"
    [[ "$CH_PLAN" == local-new || "$CH_PLAN" == local-own ]] && CH_PASSWORD=""
  fi
}

write_env() {
  set_env PG_MODE "$PG_MODE"; set_env CH_MODE "$CH_MODE"
  set_env PG_USER "$PG_USER"; set_env PG_PASSWORD "$PG_PASSWORD"; set_env CH_USER "$CH_USER"
  set_env PG_HOST 127.0.0.1; set_env PG_PORT "$PG_PORT"; set_env PG_LISTEN "$PG_LISTEN"
  set_env CH_HOST 127.0.0.1; set_env CH_PORT "$CH_PORT"; set_env CH_HTTP_PORT "$CH_HTTP_PORT"
  set_env PG_ADDR_FROM_CH "$PG_ADDR_FROM_CH"; set_env CDC_PG_HOST "$CDC_PG_HOST"; set_env CDC_PG_PORT "$CDC_PG_PORT"
  set_env KAFKA_BROKER_FROM_CH "$KAFKA_BROKER_FROM_CH"
  set_env CH_CLIENT "\"$CH_CLIENT\""; set_env CH_PASSWORD "$CH_PASSWORD"
  export PG_PORT CH_PORT CH_HTTP_PORT PG_ADDR_FROM_CH CH_PASSWORD CH_CLIENT CH_HOST=127.0.0.1 PG_HOST=127.0.0.1
}

# ---------------------------------------------------------------------------------------- start
start_pg_docker() {
  log "PostgreSQL: container $PG_CONTAINER (host port $PG_PORT)"
  "${COMPOSE[@]}" up -d --wait postgres
}
start_ch_docker() {
  log "ClickHouse: container $CH_CONTAINER (host ports $CH_PORT / $CH_HTTP_PORT)"
  "${COMPOSE[@]}" up -d --wait clickhouse
}
start_pg_local() {
  local bin; bin="$(find_pg_bin)"
  [[ -n "$bin" && -x "$bin/initdb" ]] || die "No PostgreSQL server binaries found (initdb, pg_ctl). Install the server package (postgresql-server / postgresql-NN), set PG_BIN=/path/to/bin, or use MODE=docker."
  local d="$LOCAL_DIR/pg"; mkdir -p "$LOCAL_DIR"
  log "PostgreSQL: own local instance ($("$bin/postgres" --version)), port $PG_PORT, data in $d"
  if [[ ! -f "$d/PG_VERSION" ]]; then
    local pw; pw="$(mktemp)"; printf '%s' "$PG_PASSWORD" > "$pw"
    "$bin/initdb" -D "$d" -U "$PG_USER" --auth=scram-sha-256 --pwfile="$pw" -E UTF8 >/dev/null; rm -f "$pw"
    {
      echo "wal_level = logical"; echo "max_wal_senders = 10"; echo "max_replication_slots = 10"
      echo "listen_addresses = '$PG_LISTEN'"; echo "unix_socket_directories = '$d'"
    } >> "$d/postgresql.conf"
    if [[ "$PG_LISTEN" == '*' ]]; then   # containers reach the host from private ranges (docker bridge, Docker Desktop VM)
      printf 'host all all 172.16.0.0/12 scram-sha-256\nhost all all 192.168.0.0/16 scram-sha-256\nhost all all 10.0.0.0/8 scram-sha-256\n' >> "$d/pg_hba.conf"
    fi
  fi
  "$bin/pg_ctl" -D "$d" -o "-p $PG_PORT" -l "$LOCAL_DIR/pg.log" -w -t 60 start >/dev/null || { tail -20 "$LOCAL_DIR/pg.log" >&2; die "PostgreSQL did not start (log: $LOCAL_DIR/pg.log)"; }
}
start_ch_local() {
  local srv; srv="$(find_ch_server)"
  if [[ -z "$srv" ]]; then download_ch; srv="$(find_ch_server)"; fi
  local d="$LOCAL_DIR/clickhouse"; mkdir -p "$d/data" "$d/tmp" "$d/user_files" "$d/format_schemas"
  log "ClickHouse: own local instance, ports $CH_PORT / $CH_HTTP_PORT, data in $d"
  local p9004 p9005 p9009
  p9004="$(free_port 9004)"; p9005="$(free_port 9005)"; p9009="$(free_port 9009)"
  [[ "$p9005" == "$p9004" ]] && p9005="$(free_port $((p9004 + 1)))"
  # exec inside the subshell: $! is the server itself (no watchdog), stdin/stdout/stderr are detached so callers do not hang on a pipe.
  # shellcheck disable=SC2086
  ( cd "$d" && exec env CLICKHOUSE_WATCHDOG_ENABLE=0 $srv -- --path="$d/data/" --tmp_path="$d/tmp/" --user_files_path="$d/user_files/" \
      --format_schema_path="$d/format_schemas/" --listen_host=127.0.0.1 --tcp_port="$CH_PORT" --http_port="$CH_HTTP_PORT" \
      --interserver_http_port="$p9009" --mysql_port="$p9004" --postgresql_port="$p9005" \
      --logger.log="$d/server.log" --logger.errorlog="$d/server.err.log" --logger.console=0 \
      </dev/null >"$d/stdout.log" 2>&1 ) &
  echo $! > "$d/pid"
  wait_for 90 "ClickHouse answers on $CH_HTTP_PORT" 'curl -sf -m 2 "http://127.0.0.1:$CH_HTTP_PORT/ping" | grep -q Ok' \
    || { tail -20 "$d/server.err.log" "$d/stdout.log" >&2 2>/dev/null; die "ClickHouse did not start"; }
}

verify() {
  log "Verify"
  local st; st="$(pg_probe 127.0.0.1 "$PG_PORT")"
  [[ "$st" == ok:* ]] || die "PostgreSQL on 127.0.0.1:$PG_PORT: login failed (state: $st). Check PG_USER/PG_PASSWORD in .env."
  ok "PostgreSQL 127.0.0.1:$PG_PORT reachable, wal_level=${st#ok:}"
  [[ "${st#ok:}" == logical ]] || warn "wal_level is '${st#ok:}': fine for paths 1-3, path 4 (Debezium) needs wal_level=logical + restart."
  [[ "$(ch_probe "$CH_HTTP_PORT" "$CH_PORT")" == ok ]] || die "ClickHouse on 127.0.0.1:$CH_PORT: login failed. Check CH_USER/CH_PASSWORD/CH_CLIENT in .env."
  ok "ClickHouse 127.0.0.1:$CH_PORT reachable ($(CH_PORT="$CH_PORT" chv 'SELECT version()'))"
  # The classic pitfall: ClickHouse cannot reach PostgreSQL under the address it is given.
  if CH_PORT="$CH_PORT" chc --query "SELECT count() FROM postgresql('$PG_ADDR_FROM_CH', 'postgres', 'pg_database', '$PG_USER', '$PG_PASSWORD', 'pg_catalog')" >/dev/null 2>&1; then
    ok "ClickHouse reaches PostgreSQL as $PG_ADDR_FROM_CH"
  else
    warn "ClickHouse can NOT reach PostgreSQL as $PG_ADDR_FROM_CH (paths 2, 3, 4 will fail). Container -> host needs PostgreSQL listening beyond 127.0.0.1 and pg_hba.conf to allow the container network; see README, 'Mixed setups'."
  fi
}

# ---------------------------------------------------------------------------------------- commands
cmd_check() {
  log "Tools"
  for t in psql envsubst curl jq; do if command -v "$t" >/dev/null; then ok "$t"; else warn "$t missing"; fi; done
  if docker_ok; then ok "docker daemon answers ($(docker --version | cut -d, -f1))"; else warn "docker: not available (docker mode is not possible)"; fi
  local b; b="$(find_pg_bin)"; if [[ -n "$b" ]]; then ok "PostgreSQL server binaries: $b"; else warn "PostgreSQL server binaries: none (local mode would reuse a running server)"; fi
  if [[ -n "$(find_ch_client)" ]]; then ok "ClickHouse client: $(find_ch_client)"; else warn "ClickHouse client: none (local mode would offer the download)"; fi
  [[ -n "$(find_ch_server)" ]] && ok "ClickHouse server: $(find_ch_server)"
  log "What already runs"
  local p st
  for p in "$PG_PORT"; do
    if port_busy "$p"; then st="$(pg_probe "$PG_HOST" "$p")"; echo "  port $p: taken by $(port_owner "$p"), PostgreSQL probe: ${st%%:*}"; else echo "  port $p: free"; fi
  done
  for p in "$CH_PORT" "$CH_HTTP_PORT"; do
    if port_busy "$p"; then echo "  port $p: taken by $(port_owner "$p")"; else echo "  port $p: free"; fi
  done
  if port_busy "$CH_HTTP_PORT"; then echo "  ClickHouse probe on $CH_HTTP_PORT: $(ch_probe "$CH_HTTP_PORT" "$CH_PORT")"; fi
  if docker_ok; then
    for c in "$PG_CONTAINER" "$CH_CONTAINER"; do container_running "$c" && echo "  container $c: running"; done
  fi
  [[ -f "$LOCAL_DIR/pg/postmaster.pid" ]] && echo "  own local PostgreSQL: $LOCAL_DIR/pg (pid $(head -1 "$LOCAL_DIR/pg/postmaster.pid"))"
  [[ -f "$LOCAL_DIR/clickhouse/pid" ]] && echo "  own local ClickHouse: $LOCAL_DIR/clickhouse (pid $(cat "$LOCAL_DIR/clickhouse/pid"))"
  return 0
}

cmd_status() {
  echo "  PG_MODE=${PG_MODE:-unset} CH_MODE=${CH_MODE:-unset}  PG 127.0.0.1:$PG_PORT  CH 127.0.0.1:$CH_PORT/$CH_HTTP_PORT  PG_ADDR_FROM_CH=$PG_ADDR_FROM_CH"
  echo "  PostgreSQL: $(pg_probe "$PG_HOST" "$PG_PORT" | cut -d: -f1)   ClickHouse: $(ch_probe "$CH_HTTP_PORT" "$CH_PORT")   (ok = reachable and login works)"
}

cmd_up() {
  decide_mode
  plan_pg; plan_ch
  derive; write_env
  case "$PG_PLAN" in docker-new) start_pg_docker ;; local-new) start_pg_local ;; esac
  case "$CH_PLAN" in docker-new) start_ch_docker ;; local-new) start_ch_local ;; esac
  verify
  log "Ready. Settings are in .env. Next: scripts/01_seed.sh, then the path scripts (or scripts/run_all.sh)."
}

cmd_down() {
  if command -v docker >/dev/null && docker info >/dev/null 2>&1; then
    for c in "$PG_CONTAINER" "$CH_CONTAINER"; do
      if docker inspect "$c" >/dev/null 2>&1; then
        log "docker compose down -v (both compose files)"
        "${COMPOSE[@]}" -f "$REPO/docker/compose.kafka.yml" down -v; break
      fi
    done
  fi
  if [[ -f "$LOCAL_DIR/clickhouse/pid" ]]; then
    log "stopping our own local ClickHouse"; kill "$(cat "$LOCAL_DIR/clickhouse/pid")" 2>/dev/null || true; rm -f "$LOCAL_DIR/clickhouse/pid"
  fi
  if [[ -f "$LOCAL_DIR/pg/postmaster.pid" ]]; then
    log "stopping our own local PostgreSQL"; "$(find_pg_bin)/pg_ctl" -D "$LOCAL_DIR/pg" -m fast stop >/dev/null || true
  fi
  if [[ "${PURGE:-no}" == yes ]]; then log "removing $LOCAL_DIR"; rm -rf "$LOCAL_DIR"; fi
  ok "done (running servers that were not started by this script were left alone; PURGE=yes also deletes .local/)"
}

case "$CMD" in
  up)     cmd_up ;;
  check)  cmd_check ;;
  status) cmd_status ;;
  down)   cmd_down ;;
  *)      sed -n '2,31p' "$0" | sed 's/^# \{0,1\}//'; exit 2 ;;
esac
