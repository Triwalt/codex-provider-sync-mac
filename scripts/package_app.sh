#!/bin/zsh
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
APP_NAME="Codex Provider Sync"
EXECUTABLE_NAME="CodexProviderSyncMacApp"
DIST_DIR="$ROOT_DIR/dist"
APP_DIR="$DIST_DIR/$APP_NAME.app"
ZIP_PATH="$DIST_DIR/$APP_NAME.zip"
INFO_PLIST_SOURCE="$ROOT_DIR/Resources/Info.plist"

mkdir -p "$DIST_DIR"

echo "Building release binary..."
swift build -c release --package-path "$ROOT_DIR"

BIN_DIR="$(swift build -c release --show-bin-path --package-path "$ROOT_DIR")"
EXECUTABLE_PATH="$BIN_DIR/$EXECUTABLE_NAME"

if [[ ! -x "$EXECUTABLE_PATH" ]]; then
  echo "Expected executable not found at: $EXECUTABLE_PATH" >&2
  exit 1
fi

rm -rf "$APP_DIR" "$ZIP_PATH"
mkdir -p "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Resources"

cp "$EXECUTABLE_PATH" "$APP_DIR/Contents/MacOS/$EXECUTABLE_NAME"
cp "$INFO_PLIST_SOURCE" "$APP_DIR/Contents/Info.plist"
chmod +x "$APP_DIR/Contents/MacOS/$EXECUTABLE_NAME"

if command -v codesign >/dev/null 2>&1; then
  echo "Applying ad-hoc code signature..."
  codesign --force --deep --sign - "$APP_DIR" >/dev/null 2>&1 || true
fi

echo "Creating zip archive..."
ditto -c -k --sequesterRsrc --keepParent "$APP_DIR" "$ZIP_PATH"

echo
echo "App bundle: $APP_DIR"
echo "Zip archive: $ZIP_PATH"
