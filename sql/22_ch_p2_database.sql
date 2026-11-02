-- Path 2c: the PostgreSQL database engine. Every table of the schema shows up, no DDL per table.
CREATE DATABASE IF NOT EXISTS ${CH_DB}_pg
ENGINE = PostgreSQL('${PG_ADDR_FROM_CH}', '${PG_DB}', '${PG_RO_USER}', '${PG_RO_PASSWORD}', 'public');
