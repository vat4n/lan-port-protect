#!/usr/bin/env bash
set -euo pipefail

PORTS=(3306 10050 10051 29090 29093 29094 29100 29115)
HOST="${1:-}"
TIMEOUT="${2:-3}"

[[ -n "$HOST" ]] || { echo "Usage: $0 <host> [timeout_seconds]"; exit 1; }
command -v rustscan >/dev/null 2>&1 || { echo "Error: rustscan is not installed."; exit 1; }

PORTS_CSV="$(IFS=,; echo "${PORTS[*]}")"
OUT="$(rustscan -a "$HOST" -p "$PORTS_CSV" --timeout "$((TIMEOUT * 1000))" 2>/dev/null || true)"

OPEN_COUNT=0
BLOCKED_COUNT=0

for PORT in "${PORTS[@]}"; do
    if grep -Eq "\b${PORT}\b" <<<"$OUT"; then
        echo "[OPEN]     $HOST:$PORT"
        OPEN_COUNT=$((OPEN_COUNT + 1))
    else
        echo "[BLOCKED]  $HOST:$PORT"
        BLOCKED_COUNT=$((BLOCKED_COUNT + 1))
    fi
done

echo
echo "Summary:"
echo "  Open ports:    $OPEN_COUNT"
echo "  Blocked ports: $BLOCKED_COUNT"

(( OPEN_COUNT > 0 )) && exit 2
exit 0