#!/bin/bash
# Samples a running Nook's CPU, idle wakeups, power impact and memory.
#   scripts/measure.sh [seconds] [interval]
set -euo pipefail
SECONDS_TOTAL="${1:-60}"
INTERVAL="${2:-5}"
# NOOK_PID picks a specific process; otherwise production Nook.app, then Nook Staging.app.
PID="${NOOK_PID:-$(pgrep -f '/Nook\.app/Contents/MacOS/Nook$' | head -1 || pgrep -f 'Nook Staging\.app/Contents/MacOS/Nook$' | head -1 || true)}"
[ -n "$PID" ] || { echo "Nook isn't running."; exit 1; }
SAMPLES=$(( SECONDS_TOTAL / INTERVAL + 1 ))
# In logging mode top's IDLEW column is a running total, so the wake-up rate is its growth over the window.
CPU_BEFORE="$(ps -o time= -p "$PID" | tr -d ' ')"
echo "Nook pid $PID — sampling ${SAMPLES}× every ${INTERVAL}s (first sample is discarded by top)"
top -l "$SAMPLES" -s "$INTERVAL" -pid "$PID" -stats pid,cpu,idlew,power,mem 2>/dev/null | awk -v pid="$PID" '$1==pid' | tail -n +2 |
  awk -v iv="$INTERVAL" '{w=$3; gsub(/[^0-9]/,"",w); if (n==0) w0=w; w1=w; cpu+=$2; p+=$4; n++; print}
    END { if (n>1) printf("avg: cpu %.2f%%, idle wakeups %.2f/s, power %.2f over %d samples\n", cpu/n, (w1-w0)/((n-1)*iv), p/n, n) }'
footprint "$PID" 2>/dev/null | grep -E "phys_footprint:|phys_footprint_peak:" || true
echo "CPU time: $CPU_BEFORE → $(ps -o time= -p "$PID" | tr -d ' ')"
