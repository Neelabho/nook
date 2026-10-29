#!/bin/bash
# Asks a running Nook to write its live state (and a render of its panel) into its container's tmp folder.
#   scripts/probe.sh [bundle-id]   (default dev.local.nook.staging)
set -euo pipefail
ID="${1:-dev.local.nook.staging}"
# Pick the process of the requested variant (staging and production can both be running).
if [[ "$ID" == *.staging ]]; then PATTERN='Nook Staging\.app/Contents/MacOS/Nook$'; else PATTERN='/Nook\.app/Contents/MacOS/Nook$'; fi
PID="$(pgrep -f "$PATTERN" | head -1)"
[ -n "$PID" ] || { echo "Nook isn't running"; exit 1; }
TMPD="$HOME/Library/Containers/$ID/Data/tmp"
rm -f "$TMPD/nook-state.json" "$TMPD/nook-panel.png"
kill -USR1 "$PID"
for _ in $(seq 1 30); do [ -f "$TMPD/nook-state.json" ] && [ -f "$TMPD/nook-panel.png" ] && break; sleep 0.1; done
cat "$TMPD/nook-state.json"
