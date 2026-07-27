#!/usr/bin/env bash
# Assembles build/LocalTranslator.app from the SwiftPM product. Ad-hoc signed:
# enough for a stable Accessibility grant on this machine (Plan 3), not for
# distribution.
set -euo pipefail
CONFIG="${1:-debug}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="$ROOT/build/LocalTranslator.app"

swift build -c "$CONFIG" --product TranslatorApp
BIN="$(swift build -c "$CONFIG" --product TranslatorApp --show-bin-path)/TranslatorApp"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp "$ROOT/Sources/TranslatorApp/Info.plist" "$APP/Contents/Info.plist"
cp "$BIN" "$APP/Contents/MacOS/TranslatorApp"
codesign --force --sign - "$APP"
echo "built $APP"
