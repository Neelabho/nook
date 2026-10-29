#!/bin/bash
# Removes the Nook app. Shelf contents and settings are NOT deleted.
#
#   scripts/uninstall.sh [--system]
set -euo pipefail
DEST_DIR="$HOME/Applications"
[ "${1:-}" = "--system" ] && DEST_DIR="/Applications"
APP="$DEST_DIR/Nook.app"
[ -d "$APP" ] || { echo "No Nook.app in $DEST_DIR."; exit 1; }
BUNDLE_ID="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$APP/Contents/Info.plist")"
CONTAINER="$HOME/Library/Containers/$BUNDLE_ID"

pids="$(pgrep -f "$APP/Contents/MacOS/Nook" || true)"
if [ -n "$pids" ]; then
  echo "▸ Asking Nook to quit…"
  kill -TERM $pids
  for _ in $(seq 1 20); do pgrep -f "$APP/Contents/MacOS/Nook" >/dev/null || break; sleep 0.5; done
fi

TRASHED="$HOME/.Trash/Nook.app-$(date +%Y%m%d-%H%M%S)"
mv "$APP" "$TRASHED"
echo "✓ Moved Nook.app to the Trash ($TRASHED)."
echo "  macOS removes its login item automatically once the app is gone; you can confirm in"
echo "  System Settings › General › Login Items."
echo
echo "Your data was left untouched:"
echo "  Shelf files:   $CONTAINER/Data/Library/Application Support/Nook/Shelf/items/"
echo "  Conversation:  $CONTAINER/Data/Library/Application Support/Nook/Assistant/"
echo "  Settings:      $CONTAINER/Data/Library/Preferences/"
echo
echo "To keep Shelf files, copy them out of the items/ folder first (each item is in its own folder)."
echo "To erase everything Nook stored, delete $CONTAINER in Finder once you're sure."
