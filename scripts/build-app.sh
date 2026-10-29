#!/bin/bash
# Builds Nook.app from source with SwiftPM (Xcode not required) and signs it.
#
#   scripts/build-app.sh                 release build, ad-hoc signature → build/Nook.app
#   NOOK_SIGN_IDENTITY="Developer ID Application: …" scripts/build-app.sh
#   NOOK_PRODUCT_NAME="Nook" NOOK_BUNDLE_ID="dev.local.nook" scripts/build-app.sh
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT="$(pwd)"
CONFIG="${NOOK_CONFIG:-release}"
PRODUCT="${NOOK_PRODUCT_NAME:-Nook}"
BUNDLE_ID="${NOOK_BUNDLE_ID:-dev.local.nook}"
IDENTITY="${NOOK_SIGN_IDENTITY:--}"
VERSION="$(cat VERSION)"
BUILD_NUMBER="$(git rev-list --count HEAD 2>/dev/null || echo 1)"
OUT="${NOOK_OUT_DIR:-$ROOT/build}"
APP="$OUT/$PRODUCT.app"

echo "▸ Compiling ($CONFIG)…"
swift build -c "$CONFIG" --arch arm64
BIN="$(swift build -c "$CONFIG" --arch arm64 --show-bin-path)/Nook"

echo "▸ Assembling $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Nook"
sed -e "s/__BUNDLE_ID__/$BUNDLE_ID/" -e "s/__PRODUCT_NAME__/$PRODUCT/" -e "s/__VERSION__/$VERSION/" -e "s/__BUILD__/$BUILD_NUMBER/" \
    Resources/Info.plist > "$APP/Contents/Info.plist"
plutil -lint "$APP/Contents/Info.plist" >/dev/null

if [ ! -f "$OUT/AppIcon.icns" ]; then
  echo "▸ Rendering icon"
  rm -rf "$OUT/AppIcon.iconset"
  swift scripts/make-icon.swift "$OUT/AppIcon.iconset" >/dev/null
  iconutil -c icns "$OUT/AppIcon.iconset" -o "$OUT/AppIcon.icns"
fi
cp "$OUT/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"

ENTITLEMENTS="Resources/Nook.entitlements"
if [ "${NOOK_ALLOW_LOOPBACK_SIGNIN:-0}" = "1" ]; then
  # Opt-in: lets Spotify sign-in receive its redirect on 127.0.0.1 (listener open only during sign-in).
  ENTITLEMENTS="$OUT/Nook.loopback.entitlements"
  cp Resources/Nook.entitlements "$ENTITLEMENTS"
  /usr/libexec/PlistBuddy -c "Add :com.apple.security.network.server bool true" "$ENTITLEMENTS"
  echo "▸ Including network.server entitlement (loopback sign-in listener)"
fi

echo "▸ Signing (identity: ${IDENTITY/-/ad-hoc})"
SIGN_ARGS=(--force --options runtime --entitlements "$ENTITLEMENTS" --sign "$IDENTITY")
[ "$IDENTITY" = "-" ] && SIGN_ARGS+=(--timestamp=none)
codesign "${SIGN_ARGS[@]}" "$APP"
codesign --verify --strict --verbose=1 "$APP"

echo "▸ Done: $APP"
codesign -dv "$APP" 2>&1 | grep -E "Identifier|Signature|Runtime|TeamIdentifier" || true

mkdir -p "$ROOT/dist"
ZIP="$ROOT/dist/$PRODUCT-$VERSION-$BUNDLE_ID.zip"
rm -f "$ZIP"
ditto -c -k --keepParent "$APP" "$ZIP"
echo "▸ Archive: $ZIP"
