#!/usr/bin/env bash
# The quick tour: everything that runs against a plain PostgreSQL + ClickHouse pair (containers or local, see scripts/setup.sh).
#   scripts/run_all.sh            paths 1, 2, 3, the path 4 transform test, engines, basics, the PeerDB pattern
#   RUN_BENCH=yes scripts/run_all.sh   adds the benchmark (BENCH_ROWS rows)
#   scripts/run_all.sh --demo     demo mode: every statement is shown BEFORE it runs and waits for a key
#                                 ([Enter] run, [c] stop pausing, [q] quit); also waits before each script.
#                                 The same works for a single script: DEMO=yes scripts/10_path1_csv.sh
#                                 (DEMO=full also shows the one-value queries behind the checks)
# Not included because they need more than two servers: 25 (pg_clickhouse extension), 40 (Kafka + Debezium), 50 (Aiven).
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
[[ "${1:-}" == "--demo" ]] && export DEMO="${DEMO:-yes}"
[[ "${DEMO:-no}" != no ]] && { DEMO_NOPAUSE_FILE="$(mktemp -u)"; export DEMO_NOPAUSE_FILE; trap 'rm -f "$DEMO_NOPAUSE_FILE"' EXIT; }
tty_ok() { if { : </dev/tty; } 2>/dev/null; then echo yes; else echo no; fi; }
steps=(01_seed 10_path1_csv 20_path2_federation 30_path3_refreshable_mv 41_test_cdc_transform 60_engines 65_peerdb_pattern 80_basics 85_architecture_tour)
[[ "${RUN_BENCH:-no}" == "yes" ]] && steps+=(70_benchmark)
for s in "${steps[@]}"; do
  if [[ "${DEMO:-no}" != no && ! -e "$DEMO_NOPAUSE_FILE" && "$(tty_ok)" == yes ]]; then
    printf '\n\033[1;35m>>> next: %s\033[0m   [Enter] go  [c] stop pausing  [q] quit ' "$s" > /dev/tty
    read -r -n1 -s k < /dev/tty || true; printf '\n' > /dev/tty
    case "${k:-}" in c|C) : > "$DEMO_NOPAUSE_FILE" ;; q|Q) exit 130 ;; esac
  fi
  "$HERE/$s.sh"
done
printf '\n\033[1;32mAll steps passed.\033[0m\n'
