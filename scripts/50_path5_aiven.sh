#!/usr/bin/env bash
# Path 5: let the platform do the wiring. Aiven for PostgreSQL + Aiven for ClickHouse + one integration of type
# clickhouse_postgresql, then the same checks as paths 2 and 3 against the integration database.
# Costs money while the services run (two small services for an afternoon: a few euros). 99_cleanup.sh TERMINATE=yes removes them.
# Prerequisites: Aiven CLI logged in (`avn user login`), AVN_PROJECT in .env, jq, psql, a ClickHouse client binary.
# Double-checks: services RUNNING, seeded rows in Aiven PostgreSQL, integration exists, ClickHouse sees the same
# row count through the integration database and through the refreshable local copy.
source "$(dirname "${BASH_SOURCE[0]}")/00_lib.sh"
need avn; need jq
: "${AVN_PROJECT:?Set AVN_PROJECT in .env}"
: "${AVN_CLOUD:=google-europe-west1}" "${AVN_PG_PLAN:=startup-4}" "${AVN_CH_PLAN:=startup-16}"
: "${AVN_PG_NAME:=beer-pg}" "${AVN_CH_NAME:=beer-clickhouse}" "${AVN_PG_DATABASE:=defaultdb}"
export AIVEN_SRC="service_${AVN_PG_NAME}_${AVN_PG_DATABASE}_public"
avn() { command avn --project "$AVN_PROJECT" "$@"; }

log "Path 5: two services (about 5 to 10 minutes the first time)"
avn service create "$AVN_PG_NAME" -t pg         --plan "$AVN_PG_PLAN" --cloud "$AVN_CLOUD" --no-fail-if-exists
avn service create "$AVN_CH_NAME" -t clickhouse --plan "$AVN_CH_PLAN" --cloud "$AVN_CLOUD" --no-fail-if-exists
avn service wait "$AVN_PG_NAME" "$AVN_CH_NAME"
check "PostgreSQL service state" RUNNING "$(avn service get "$AVN_PG_NAME" --format '{state}')"
check "ClickHouse service state" RUNNING "$(avn service get "$AVN_CH_NAME" --format '{state}')"

log "Path 5: seed Aiven for PostgreSQL ($ROWS rows)"
PG_URI="$(avn service get "$AVN_PG_NAME" --format '{service_uri}')"
psql -X -q -v ON_ERROR_STOP=1 "$PG_URI" -f "$REPO/sql/00_pg_schema.sql"
if [[ "$(psql -X -tA "$PG_URI" -c 'SELECT count(*) FROM beer_sales')" == 0 ]]; then
  psql -X -q -v ON_ERROR_STOP=1 "$PG_URI" -v rows="$ROWS" -f "$REPO/sql/01_pg_seed.sql"
fi
pg_rows="$(psql -X -tA "$PG_URI" -c 'SELECT count(*) FROM beer_sales')"; ok "Aiven PostgreSQL beer_sales: $pg_rows rows"

log "Path 5: the integration (type clickhouse_postgresql, no connector, no Kafka)"
have="$(avn service integration-list "$AVN_CH_NAME" --json | jq -r '[.[] | select(.integration_type == "clickhouse_postgresql")] | length')"
if [[ "$have" == 0 ]]; then
  avn service integration-create -t clickhouse_postgresql -s "$AVN_PG_NAME" -d "$AVN_CH_NAME" \
    --user-config-json "{\"databases\":[{\"database\":\"$AVN_PG_DATABASE\",\"schema\":\"public\"}]}"
fi
avn service integration-list "$AVN_CH_NAME"

log "Path 5: ClickHouse over TLS, read through the integration database"
json="$(avn service get "$AVN_CH_NAME" --json)"
CH_HOST="$(jq -r '.service_uri_params.host' <<<"$json")"; CH_USER="$(jq -r '.service_uri_params.user' <<<"$json")"
CH_PASSWORD="$(jq -r '.service_uri_params.password' <<<"$json")"; CH_SECURE=true
CH_PORT="$(jq -r '[.components[]? | select(.component == "clickhouse") | .port][0] // 9440' <<<"$json")"
export CH_HOST CH_USER CH_PASSWORD CH_SECURE CH_PORT
export CH_DB=default
check "rows through the integration database" "$pg_rows" "$(chv "SELECT count() FROM \`$AIVEN_SRC\`.beer_sales")"
chq "SELECT country, round(sum(liters)) AS liters FROM \`$AIVEN_SRC\`.beer_sales GROUP BY country ORDER BY liters DESC LIMIT 3"

log "Path 5: plus a refreshable, replicated local copy"
chfile "$REPO/sql/51_ch_aiven_refreshable.sql"
chq "SYSTEM WAIT VIEW ${CH_DB}.p5_refresh"
check "rows in the local copy" "$pg_rows" "$(chv "SELECT count() FROM ${CH_DB}.p5_copy")"
warn "Services keep running (and costing money) until: TERMINATE=yes scripts/99_cleanup.sh"
