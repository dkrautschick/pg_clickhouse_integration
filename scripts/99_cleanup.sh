#!/usr/bin/env bash
# Remove what the scripts created. Safe by default: only ClickHouse objects. Opt in to more:
#   DROP_PG=yes       drop the PostgreSQL databases (demo + benchmark) after removing the Debezium connector and its slot
#   STOP_STACK=yes    docker compose down -v (both compose files)
#   TERMINATE=yes     terminate the Aiven services of path 5 (they cost money while they run)
# Double-checks: no replication slot left behind on the PostgreSQL side (an inactive slot keeps WAL forever).
source "$(dirname "${BASH_SOURCE[0]}")/00_lib.sh"

log "ClickHouse: dropping databases ${CH_DB}, ${CH_DB}_pg, ${CH_DB}_bench"
chq "DROP DATABASE IF EXISTS ${CH_DB} SYNC; DROP DATABASE IF EXISTS ${CH_DB}_pg SYNC; DROP DATABASE IF EXISTS ${CH_DB}_bench SYNC"

if [[ "${DROP_PG:-no}" == "yes" ]]; then
  log "Debezium connector and replication slot"
  if curl -sf -X DELETE "$CONNECT_URL/connectors/beerdb-connector" >/dev/null 2>&1; then ok "connector deleted"; fi
  pg_admin -tA -c "SELECT pg_drop_replication_slot(slot_name) FROM pg_replication_slots WHERE slot_name = 'debezium_beer'" >/dev/null 2>&1 || true
  log "PostgreSQL: dropping databases $PG_DB and beerbench"
  pg_admin -c "DROP DATABASE IF EXISTS $PG_DB WITH (FORCE)" -c "DROP DATABASE IF EXISTS beerbench WITH (FORCE)"
  left="$(pg_admin -tA -c "SELECT count(*) FROM pg_replication_slots WHERE slot_name LIKE 'debezium%'")"
  check "orphaned replication slots" 0 "$left"
fi
if [[ "${STOP_STACK:-no}" == "yes" ]]; then
  need docker
  docker compose --env-file "$ENV_FILE" -f "$REPO/docker/compose.yml" -f "$REPO/docker/compose.kafka.yml" down -v
fi
if [[ "${TERMINATE:-no}" == "yes" ]]; then
  need avn; : "${AVN_PROJECT:?}"
  for s in "${AVN_PG_NAME:-beer-pg}" "${AVN_CH_NAME:-beer-clickhouse}"; do
    if avn --project "$AVN_PROJECT" service terminate --force "$s" 2>/dev/null; then ok "terminated $s"; fi
  done
fi
ok "done"
