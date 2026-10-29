#!/bin/bash
# Installs build/Nook.app into ~/Applications (default) or /Applications (--system).
# An existing installation is never overwritten: it is moved aside to a timestamped backup,
# and only after you confirm.
#
#   scripts/install.sh [--system] [--yes]
set -euo pipefail
cd "$(dirname "$0")/.."
SRC="$(pwd)/build/Nook.app"
DEST_DIR="$HOME/Applications"
ASSUME_YES=0
for arg in "$@"; do
  case "$arg" in
    --system) DEST_DIR="/Applications" ;;
    --yes) ASSUME_YES=1 ;;
    *) echo "Unknown option: $arg"; exit 2 ;;
  esac
done

confirm() {
  [ "$ASSUME_YES" = 1 ] && return 0
  read -r -p "$1 [y/N] " reply
  [[ "$reply" =~ ^[Yy]$ ]]
}

[ -d "$SRC" ] || { echo "No build found. Run scripts/build-app.sh first."; exit 1; }
codesign --verify --strict "$SRC"
BUNDLE_ID="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$SRC/Contents/Info.plist")"
if [[ "$BUNDLE_ID" == *.staging ]]; then
  echo "⚠︎  This is a staging build ($BUNDLE_ID) with its own separate data."
  echo "   For daily use, rebuild with: scripts/build-app.sh"
  confirm "Install the staging build anyway?" || exit 1
fi

DEST="$DEST_DIR/Nook.app"
mkdir -p "$DEST_DIR"

quit_running() {
  local pids
  pids="$(pgrep -f "$1/Contents/MacOS/Nook" || true)"
  [ -z "$pids" ] && return 0
  echo "▸ Asking the running Nook to quit…"
  kill -TERM $pids          # Nook treats SIGTERM like ⌘Q (orderly shutdown)
  for _ in $(seq 1 20); do
    pgrep -f "$1/Contents/MacOS/Nook" >/dev/null || return 0
    sleep 0.5
  done
  echo "Nook didn't quit. Quit it from the menu bar and run this script again."
  exit 1
}

if [ -e "$DEST" ]; then
  BACKUP="$DEST_DIR/Nook.app.backup-$(date +%Y%m%d-%H%M%S)"
  echo "An existing Nook is installed at: $DEST"
  echo "It will be moved (not deleted) to: $BACKUP"
  echo "Your Shelf items live in Nook's data container and are not affected."
  confirm "Continue?" || { echo "Nothing changed."; exit 1; }
  quit_running "$DEST"
  mv "$DEST" "$BACKUP"
fi

echo "▸ Installing to $DEST"
ditto "$SRC" "$DEST"
codesign --verify --strict "$DEST"
open "$DEST"
cat <<MSG
✓ Installed. Nook is running (look at the notch, or press ⌥⌘N).
  • First launch from this location registers "Open at login" (turn it off in Settings › General).
  • If macOS asks you to approve the login item, use System Settings › General › Login Items.
  • To roll back: quit Nook, delete $DEST and rename the .backup-… copy to Nook.app.
MSG
