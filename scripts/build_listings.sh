#!/usr/bin/env bash
# Regenerates the SQL files in listings/ from the templates in sql/: ${VAR} becomes <VAR>, so a listing is the
# exact statement the scripts run, with placeholders instead of variables. Hand-written shell listings are left alone.
set -euo pipefail
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
n=0
for f in "$REPO"/sql/*.sql; do
  sed -E 's/\$\{([A-Z0-9_]+)\}/<\1>/g' "$f" > "$REPO/listings/$(basename "$f")"; n=$((n + 1))
done
echo "listings/: $n SQL files regenerated from sql/"
