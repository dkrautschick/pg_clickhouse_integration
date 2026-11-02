#!/usr/bin/env bash
# The quick tour: everything that runs against a plain PostgreSQL + ClickHouse pair (no Docker, no cloud account).
#   scripts/run_all.sh            paths 1, 2, 3, the path 4 transform test, engines, basics, the PeerDB pattern
#   RUN_BENCH=yes scripts/run_all.sh   adds the benchmark (BENCH_ROWS rows)
# Not included because they need more than two servers: 25 (pg_clickhouse extension), 40 (Kafka + Debezium), 50 (Aiven).
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
for s in 01_seed 10_path1_csv 20_path2_federation 30_path3_refreshable_mv 41_test_cdc_transform 60_engines 65_peerdb_pattern 80_basics 85_architecture_tour; do
  "$HERE/$s.sh"
done
[[ "${RUN_BENCH:-no}" == "yes" ]] && "$HERE/70_benchmark.sh"
printf '\n\033[1;32mAll steps passed.\033[0m\n'
