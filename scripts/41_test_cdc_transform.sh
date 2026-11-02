#!/usr/bin/env bash
# Path 4, the part you can test without Kafka: feed hand-written Debezium events through the SAME consumer SQL
# (40_ch_p4_target.sql) using a Memory table as a stand-in for the Kafka engine table, same JSONAsString format.
# Events: two creates, an update of row 1, a delete of row 2, a snapshot read ("r") of row 3.
# Double-checks: raw table keeps all versions, FINAL/current view shows the latest state, deleted rows are gone.
source "$(dirname "${BASH_SOURCE[0]}")/00_lib.sh"
export P4_PREFIX=p4t   # leaves your real p4_* objects alone

log "Path 4: stand-in queue (Memory) + the real consumer SQL"
chq "DROP VIEW IF EXISTS ${CH_DB}.${P4_PREFIX}_current; DROP VIEW IF EXISTS ${CH_DB}.${P4_PREFIX}_consumer;
     DROP TABLE IF EXISTS ${CH_DB}.${P4_PREFIX}_cdc; DROP TABLE IF EXISTS ${CH_DB}.${P4_PREFIX}_queue"
chq "CREATE TABLE ${CH_DB}.${P4_PREFIX}_queue (payload String) ENGINE = Memory"
chfile "$REPO/sql/40_ch_p4_target.sql"

ev() { # op id lsn liters  (shape follows the Debezium PostgreSQL connector, JSON without schema)
  local op="$1" id="$2" lsn="$3" liters="$4" row
  row="$(printf '{"id":%s,"sold_at":"2026-10-31T12:00:00.123456Z","country":"BE","beer_name":"Orval","channel":"bar","customer_id":7,"liters":%s,"price_eur":9.9,"updated_at":"2026-10-31T12:00:01.5Z"}' "$id" "$liters")"
  case "$op" in
    c|r|u) printf '{"before":null,"after":%s,"source":{"connector":"postgresql","lsn":%s},"op":"%s","ts_ms":1762000000000}\n' "$row" "$lsn" "$op" ;;
    d)     printf '{"before":{"id":%s},"after":null,"source":{"connector":"postgresql","lsn":%s},"op":"d","ts_ms":1762000002000}\n' "$id" "$lsn" ;;
  esac
}
# One INSERT per event, like separate Kafka batches. (Rows of the SAME insert block are already collapsed on
# insert because optimize_on_insert = 1 - one more reason the raw table can hold fewer rows than events.)
for e in "c 1 100 25.0" "c 2 110 12.5" "u 1 120 30.0" "d 2 130 0" "r 3 90 8.0"; do
  # shellcheck disable=SC2086
  ev $e | chc --query "INSERT INTO ${CH_DB}.${P4_PREFIX}_queue FORMAT JSONAsString"
done

check "raw versions kept in the target table (before merges)" 5 "$(chv "SELECT count() FROM ${CH_DB}.${P4_PREFIX}_cdc")"
check "rows in the current view (row 1 latest, row 2 deleted, row 3 from the snapshot)" 2 "$(chv "SELECT count() FROM ${CH_DB}.${P4_PREFIX}_current")"
check "liters of row 1 after the update" 30 "$(chv "SELECT liters FROM ${CH_DB}.${P4_PREFIX}_current WHERE id = 1")"
check "row 2 is gone" 0 "$(chv "SELECT count() FROM ${CH_DB}.${P4_PREFIX}_current WHERE id = 2")"
check "timestamp parsed" "2026-10-31 12:00:00.123456" "$(chv "SELECT sold_at FROM ${CH_DB}.${P4_PREFIX}_current WHERE id = 1")"
chq "SELECT id, liters, _version, _is_deleted FROM ${CH_DB}.${P4_PREFIX}_cdc ORDER BY id, _version FORMAT PrettyCompact"
chq "DROP VIEW ${CH_DB}.${P4_PREFIX}_current; DROP VIEW ${CH_DB}.${P4_PREFIX}_consumer;
     DROP TABLE ${CH_DB}.${P4_PREFIX}_cdc; DROP TABLE ${CH_DB}.${P4_PREFIX}_queue"
