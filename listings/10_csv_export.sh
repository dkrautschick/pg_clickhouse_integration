# Path 1, step 1: PostgreSQL -> CSV. \copy runs on the client (the file lands on YOUR machine, no server file access needed).
psql "<PG_URI>" -c "\copy (SELECT * FROM beer_sales ORDER BY id) TO 'beer_sales.csv' CSV HEADER"
