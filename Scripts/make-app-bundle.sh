#!/usr/bin/env bash
# Assembles build/LocalTranslator.app from the SwiftPM product. Not for distribution.
#
# Signing decides whether the Accessibility grant survives a rebuild. Ad-hoc signing
# re-keys the bundle every time, so macOS treats each build as a new application and
# asks again. A stable self-signed identity keeps the grant. To create one:
#   Keychain Access -> Certificate Assistant -> Create a Certificate,
#   name «LocalTranslator Dev», type «Code Signing», self-signed.
# Or point at any identity you already have: CODESIGN_IDENTITY=… ./Scripts/make-app-bundle.sh
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
IDENTITY="${CODESIGN_IDENTITY:-}"
if [ -z "$IDENTITY" ] && security find-identity -v -p codesigning 2>/dev/null | grep -q "LocalTranslator Dev"; then
  IDENTITY="LocalTranslator Dev"
fi
if [ -n "$IDENTITY" ]; then
  codesign --force --sign "$IDENTITY" "$APP"
  echo "signed with $IDENTITY — the Accessibility grant survives rebuilds"
else
  codesign --force --sign - "$APP"
  echo "ad-hoc signed — macOS will ask for Accessibility again after each rebuild"
fi
echo "built $APP"
