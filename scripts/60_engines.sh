#!/usr/bin/env bash
# Table engines in action: ReplacingMergeTree (CDC updates), SummingMergeTree, AggregatingMergeTree behind a
# materialized view, and Null as a sink. Each block creates its own e_* tables, so it is re-runnable.
# Double-checks: before the merge the old versions are still there, FINAL / -Merge give the right answer, Null stays empty.
source "$(dirname "${BASH_SOURCE[0]}")/00_lib.sh"
chfile "$REPO/sql/02_ch_schema.sql"

log "ReplacingMergeTree: an update is an insert with a newer version"
chfile "$REPO/sql/60_replacing.sql"
check "rows without FINAL (old version not merged away yet)" 3 "$(chv "SELECT count() FROM ${CH_DB}.e_replacing")"
check "rows with FINAL (latest version per key)" 2 "$(chv "SELECT count() FROM ${CH_DB}.e_replacing FINAL")"
check "liters of id 1 with FINAL" 13 "$(chv "SELECT liters FROM ${CH_DB}.e_replacing FINAL WHERE id = 1")"
chq "OPTIMIZE TABLE ${CH_DB}.e_replacing FINAL"
check "rows after OPTIMIZE ... FINAL (the merge ran)" 2 "$(chv "SELECT count() FROM ${CH_DB}.e_replacing")"

log "SummingMergeTree: roll-up by key at merge time"
chfile "$REPO/sql/61_summing.sql"
chq "OPTIMIZE TABLE ${CH_DB}.e_summing FINAL"
check "BE liters after the merge" 15 "$(chv "SELECT liters FROM ${CH_DB}.e_summing WHERE country = 'BE'")"

log "AggregatingMergeTree behind a materialized view: sumState on write, sumMerge on read"
chfile "$REPO/sql/62_aggregating.sql"
chq "SELECT country, sumMerge(liters) AS liters FROM ${CH_DB}.e_agg GROUP BY country ORDER BY country FORMAT PrettyCompact"
check "BE liters via sumMerge" 47.5 "$(chv "SELECT sumMerge(liters) FROM ${CH_DB}.e_agg WHERE country = 'BE'")"

log "Null engine as a sink for a materialized view"
chfile "$REPO/sql/63_null_mv.sql"
check "rows stored in the Null table" 0 "$(chv "SELECT count() FROM ${CH_DB}.e_null_raw")"
check "rows the view parsed into MergeTree" 3 "$(chv "SELECT count() FROM ${CH_DB}.e_null_parsed")"
