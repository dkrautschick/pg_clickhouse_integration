#!/usr/bin/env bash
# Path 4: Debezium reads the WAL, Kafka carries the events, the ClickHouse Kafka engine consumes them.
# Needs Docker: START_STACK=yes brings up docker/compose.yml + docker/compose.kafka.yml for you.
# Run 01_seed.sh first (the connector snapshots the existing rows), with PG_ADDR_FROM_CH=postgres:5432 and
# CH_*/PG_* pointing at the compose containers (see README).
# Double-checks: connector task RUNNING, snapshot rows arrive, INSERT / UPDATE / DELETE in PostgreSQL show up in ClickHouse
# (current view uses FINAL), and the replication slot is active.
source "$(dirname "${BASH_SOURCE[0]}")/00_lib.sh"
need curl; need jq

if [[ "${START_STACK:-no}" == "yes" ]]; then
  need docker
  log "Path 4: starting PostgreSQL, ClickHouse, Kafka and Debezium Connect"
  docker compose --env-file "$ENV_FILE" -f "$REPO/docker/compose.yml" -f "$REPO/docker/compose.kafka.yml" up -d --wait
fi

log "Path 4: wait for Kafka Connect, register the Debezium connector"
wait_until 120 "Kafka Connect REST API answers" curl -sf "$CONNECT_URL/connectors"
jq --arg host "${CDC_PG_HOST:-postgres}" --arg port "${CDC_PG_PORT:-5432}" --arg user "$PG_USER" --arg pw "$PG_PASSWORD" --arg db "$PG_DB" \
   '.config["database.hostname"]=$host | .config["database.port"]=$port | .config["database.user"]=$user
    | .config["database.password"]=$pw | .config["database.dbname"]=$db' "$REPO/docker/debezium/pg-connector.json" \
  | curl -sf -X PUT -H 'Content-Type: application/json' --data @- "$CONNECT_URL/connectors/beerdb-connector/config" >/dev/null
wait_for 60 "connector task is RUNNING" '[[ "$(curl -s "$CONNECT_URL/connectors/beerdb-connector/status" | jq -r ".tasks[0].state")" == RUNNING ]]'
ok "replication slot: $(pgv "SELECT slot_name || ' active=' || active FROM pg_replication_slots WHERE slot_name = 'debezium_beer'")"

log "Path 4: Kafka engine table, consumer, target table (ReplacingMergeTree), current view"
chfile "$REPO/sql/41_ch_p4_kafka_queue.sql"
chfile "$REPO/sql/40_ch_p4_target.sql"

cur="${CH_DB}.${P4_PREFIX}_current"

log "Path 4: the snapshot arrives"
wait_for 120 "snapshot rows are in ClickHouse" '[[ "$(chv "SELECT count() FROM $cur")" -gt 0 ]]'
ok "current view: $(chv "SELECT count() FROM $cur") rows (PostgreSQL has $(pgv 'SELECT count(*) FROM beer_sales'))"

log "Path 4: INSERT, UPDATE, DELETE in PostgreSQL"
id="$(pgv "INSERT INTO beer_sales (country, beer_name, channel, customer_id, liters, price_eur) VALUES ('BE', 'CDC test beer', 'bar', 1, 10, 5) RETURNING id" | head -1)"
wait_for 60 "INSERT arrived (id $id)" '[[ "$(chv "SELECT count() FROM $cur WHERE id = $id")" == 1 ]]'
pgc -c "UPDATE beer_sales SET liters = 99, updated_at = now() WHERE id = $id"
wait_for 60 "UPDATE arrived (liters = 99)" '[[ "$(chv "SELECT liters FROM $cur WHERE id = $id")" == 99 ]]'
chq "SELECT id, liters, _version, _is_deleted FROM ${CH_DB}.${P4_PREFIX}_cdc WHERE id = $id ORDER BY _version FORMAT PrettyCompact"
pgc -c "DELETE FROM beer_sales WHERE id = $id"
wait_for 60 "DELETE arrived (row gone from the current view)" '[[ "$(chv "SELECT count() FROM $cur WHERE id = $id")" == 0 ]]'
warn "An UPDATE is an INSERT with a newer version. Query with FINAL (the view does) or merges have not run yet. Keep the slot consumed."
