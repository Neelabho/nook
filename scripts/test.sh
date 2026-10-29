#!/bin/bash
# Runs the NookCore test suite. Works with full Xcode or with only the Command Line Tools
# (where Swift Testing lives outside the default search paths).
set -euo pipefail
cd "$(dirname "$0")/.."
ARGS=()
CLT=/Library/Developer/CommandLineTools/Library/Developer
if ! xcode-select -p 2>/dev/null | grep -q "Xcode.app" && [ -d "$CLT/Frameworks/Testing.framework" ]; then
  ARGS+=(-Xswiftc -F"$CLT/Frameworks" -Xlinker -F"$CLT/Frameworks"
         -Xlinker -rpath -Xlinker "$CLT/Frameworks" -Xlinker -rpath -Xlinker "$CLT/usr/lib")
fi
exec swift test "${ARGS[@]}" "$@"
