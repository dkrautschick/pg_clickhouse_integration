# Path 5: the Aiven way, command by command (scripts/50_path5_aiven.sh strings these together with checks).
avn user login <EMAIL>                                    # or: --token
avn service create <AVN_PG_NAME> -t pg         --plan startup-4  --cloud <AVN_CLOUD> --project <AVN_PROJECT> --no-fail-if-exists
avn service create <AVN_CH_NAME> -t clickhouse --plan startup-16 --cloud <AVN_CLOUD> --project <AVN_PROJECT> --no-fail-if-exists
avn service wait <AVN_PG_NAME> <AVN_CH_NAME> --project <AVN_PROJECT>

# one integration, type clickhouse_postgresql: ClickHouse gets a database service_<pg>_<db>_<schema>
avn service integration-create --project <AVN_PROJECT> -t clickhouse_postgresql -s <AVN_PG_NAME> -d <AVN_CH_NAME> \
  --user-config-json '{"databases":[{"database":"defaultdb","schema":"public"}]}'
avn service integration-list <AVN_CH_NAME> --project <AVN_PROJECT>

# connect (native protocol over TLS; host, user, password and the port of the "clickhouse" component are in the service JSON)
avn service get <AVN_CH_NAME> --project <AVN_PROJECT> --json | jq '.service_uri_params, [.components[] | select(.component=="clickhouse")]'
clickhouse client --host <HOST> --port <NATIVE_TLS_PORT> --user <USER> --password '<PASSWORD>' --secure
#   Newer clients may print "Unknown settings: allow_non_default_profile, skipping": Aiven adds a server setting of its own. Harmless.
#   Dashes in the integration database name need backticks:  SELECT count() FROM `service_beer-pg_defaultdb_public`.beer_sales;

# Kafka as the second integration type (clickhouse_kafka): see terraform/ (var.with_kafka = true) or
# https://aiven.io/docs/products/clickhouse/howto/integrate-kafka

# the same as code
#   cd terraform && cp terraform.tfvars.example terraform.tfvars && terraform init && terraform apply
# clean up (the services cost money while they run):
avn service terminate --force <AVN_PG_NAME> --project <AVN_PROJECT>
avn service terminate --force <AVN_CH_NAME> --project <AVN_PROJECT>
