#!/bin/bash
# Rebuilds the staging variant (separate bundle id + data, never registers a login item) and
# relaunches it from ~/Applications/Nook Staging.app.
set -euo pipefail
cd "$(dirname "$0")/.."
NOOK_ALLOW_LOOPBACK_SIGNIN=1 NOOK_PRODUCT_NAME="Nook Staging" NOOK_BUNDLE_ID=dev.local.nook.staging NOOK_OUT_DIR="$(pwd)/build/staging" ./scripts/build-app.sh | grep -E "Done|error" || true
pids="$(pgrep -f 'Nook Staging.app/Contents/MacOS/Nook' || true)"
if [ -n "$pids" ]; then kill -TERM $pids; for _ in $(seq 1 20); do pgrep -f 'Nook Staging.app/Contents/MacOS/Nook' >/dev/null || break; sleep 0.25; done; fi
rm -rf "$HOME/Applications/Nook Staging.app"
ditto "build/staging/Nook Staging.app" "$HOME/Applications/Nook Staging.app"
open "$HOME/Applications/Nook Staging.app"
sleep 1.5
echo "staging pid: $(pgrep -f 'Nook Staging.app/Contents/MacOS/Nook')"
