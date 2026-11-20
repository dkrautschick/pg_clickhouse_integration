#!/usr/bin/env bash
# Path 5, native CDC: Aiven for PostgreSQL -> Aiven for ClickHouse straight from the WAL, no Kafka, no Debezium.
# LIMITED AVAILABILITY: your Aiven project needs CDC access (ask your account team). Not run by run_all.sh.
# Docs: https://aiven.io/docs/products/clickhouse/howto/replicate-postgresql-cdc
# Needs: both services in the same project, ClickHouse on Startup or higher, a primary key on every table.
# Placeholders: <AVN_PROJECT>, <API_TOKEN>, <PG_SERVICE>, <CH_SERVICE>, <PG_DB>, <CH_DB>
set -euo pipefail

curl --request POST \
  --url "https://api.aiven.io/v1/project/<AVN_PROJECT>/integration" \
  --header "Authorization: Bearer <API_TOKEN>" \
  --header "Content-Type: application/json" \
  --data '{
    "integration_type": "postgresql_clickhouse_cdc",
    "source_service": "<PG_SERVICE>",
    "dest_service": "<CH_SERVICE>",
    "user_config": {
      "pipelines": [
        {
          "source_database": "<PG_DB>",
          "destination_database": "<CH_DB>",
          "tables": [ {"schema": "public", "table": "beer_sales"} ]
        }
      ]
    }
  }'

# Console alternative: PostgreSQL service > Integrations > "Replicate to ClickHouse (CDC)".
# Wait until the table shows "Streaming", then in ClickHouse read the CURRENT view, not the base table:
#   SELECT country, round(sum(liters)) FROM <CH_DB>.public_beer__sales__current GROUP BY country;
# Naming: schema_table, and every underscore inside a name is doubled (public.beer_sales -> public_beer__sales).
# Extra columns on the base table: _etl_version (position in the stream), _etl_deleted (1 = deleted).
# numeric/money arrive as String: cast before doing math.
# Watch the WAL metric of the PostgreSQL service: a stalled replication keeps WAL, like any unconsumed slot.
