# Path 1, step 2: CSV -> ClickHouse (table from 10_ch_p1_csv.sql). best_effort parses PostgreSQL's "2026-10-31 12:00:00.123456+00".
clickhouse client --host <CH_HOST> --port <CH_PORT> --user <CH_USER> --password '<CH_PASSWORD>' \
  --date_time_input_format=best_effort \
  --query "INSERT INTO <CH_DB>.p1_csv FORMAT CSVWithNames" < beer_sales.csv
