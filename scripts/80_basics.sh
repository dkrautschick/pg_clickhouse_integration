#!/usr/bin/env bash
# ClickHouse basics from the talk: parts, merges, granules, the sparse index, compression.
# Double-checks: three tiny INSERTs = three parts, OPTIMIZE ... FINAL leaves one active part, EXPLAIN reads a fraction of the granules.
source "$(dirname "${BASH_SOURCE[0]}")/00_lib.sh"
chfile "$REPO/sql/02_ch_schema.sql"
parts() { chv "SELECT count() FROM system.parts WHERE database = '${CH_DB}' AND table = 'b_sales' AND active"; }

log "Three INSERTs, merges stopped: three parts"
chfile "$REPO/sql/80_parts_and_merges.sql"
check "active parts after 3 INSERTs" 3 "$(parts)"
chq "SELECT name, rows, part_type FROM system.parts WHERE database = '${CH_DB}' AND table = 'b_sales' AND active ORDER BY name FORMAT PrettyCompact"

log "One bulk INSERT of 2,000,000 rows"
chfile "$REPO/sql/81_bulk_insert.sql"
# 2,000,000 rows are cut into blocks of max_insert_block_size (about 1 million rows), one part per block:
# a bulk INSERT makes a handful of big parts, not a million small ones.
np="$(parts)"
if [[ "$np" -ge 4 ]]; then ok "active parts after the bulk INSERT: $np (3 tiny ones + $((np - 3)) from the bulk insert)"; else die "expected at least 4 parts, got $np"; fi

log "Start the merges again and force one: parts become one"
chq "SYSTEM START MERGES ${CH_DB}.b_sales; OPTIMIZE TABLE ${CH_DB}.b_sales FINAL"
check "active parts after OPTIMIZE FINAL" 1 "$(parts)"
chq "SELECT name, active, level, rows FROM system.parts WHERE database = '${CH_DB}' AND table = 'b_sales' ORDER BY active DESC, min_block_number FORMAT PrettyCompact"

log "Granules, compression and what a filtered query reads"
chfile "$REPO/sql/82_granules.sql"
