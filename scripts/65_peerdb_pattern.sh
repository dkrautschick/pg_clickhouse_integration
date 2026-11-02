#!/usr/bin/env bash
# Path 6 (supplement, not one of the five paths): the table shape PeerDB / ClickPipes Postgres CDC produces in
# ClickHouse, rebuilt by hand. PeerDB itself is not started here, see docs/path6_peerdb.md.
# Double-checks: raw table keeps every version, the view shows the latest non-deleted state.
source "$(dirname "${BASH_SOURCE[0]}")/00_lib.sh"
chfile "$REPO/sql/02_ch_schema.sql"
log "PeerDB-style target table: versions in, current state out"
chfile "$REPO/sql/65_peerdb_pattern.sql"
check "raw rows (every version)" 4 "$(chv "SELECT count() FROM ${CH_DB}.e_peerdb_beer_sales")"
check "rows in the current view" 1 "$(chv "SELECT count() FROM ${CH_DB}.e_peerdb_beer_sales_current")"
check "liters of id 1 after the update" 30 "$(chv "SELECT liters FROM ${CH_DB}.e_peerdb_beer_sales_current WHERE id = 1")"
chq "SELECT id, liters, _peerdb_version, _peerdb_is_deleted FROM ${CH_DB}.e_peerdb_beer_sales ORDER BY id, _peerdb_version FORMAT PrettyCompact"
