# Path 4: register the Debezium PostgreSQL connector with Kafka Connect (REST API on port 8083).
# <CONNECT_URL> is http://127.0.0.1:8083 with docker/compose.kafka.yml. The JSON is docker/debezium/pg-connector.json.
curl -sf -X PUT -H 'Content-Type: application/json' "<CONNECT_URL>/connectors/beerdb-connector/config" --data '{
  "connector.class": "io.debezium.connector.postgresql.PostgresConnector",
  "plugin.name": "pgoutput",
  "database.hostname": "<PG_HOST_AS_SEEN_BY_CONNECT>", "database.port": "5432",
  "database.user": "<PG_USER>", "database.password": "<PG_PASSWORD>", "database.dbname": "<PG_DB>",
  "topic.prefix": "cdc",
  "table.include.list": "public.beer_sales",
  "slot.name": "debezium_beer", "publication.name": "dbz_beer", "publication.autocreate.mode": "filtered",
  "snapshot.mode": "initial",
  "decimal.handling.mode": "string",
  "tombstones.on.delete": "false",
  "key.converter": "org.apache.kafka.connect.json.JsonConverter", "key.converter.schemas.enable": "false",
  "value.converter": "org.apache.kafka.connect.json.JsonConverter", "value.converter.schemas.enable": "false"
}'
# Status, and delete when you are done (then drop the slot, see 40_pg_prereqs.sql):
curl -s "<CONNECT_URL>/connectors/beerdb-connector/status" | jq
curl -X DELETE "<CONNECT_URL>/connectors/beerdb-connector"
