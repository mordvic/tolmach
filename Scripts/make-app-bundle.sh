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
# The signature covers Contents/Resources, so the icon has to be in place before codesign runs:
# a resource added afterwards leaves the seal broken, and a broken seal costs the Accessibility
# grant this script's signing identity exists to preserve.
ICNS="$ROOT/build/AppIcon.icns"
# Regenerating costs a few seconds of compile, so it happens only when the generator moved.
if [ ! -f "$ICNS" ] || [ "$ROOT/Scripts/make-icon.swift" -nt "$ICNS" ]; then
  swift "$ROOT/Scripts/make-icon.swift" "$ICNS"
fi
mkdir -p "$APP/Contents/Resources"
cp "$ICNS" "$APP/Contents/Resources/AppIcon.icns"
IDENTITY="${CODESIGN_IDENTITY:-}"
if [ -z "$IDENTITY" ]; then
  # The matched name is extracted rather than hardcoded. A substring test that then signs
  # with a fixed literal can match one identity and hand codesign another — or an ambiguous
  # one, if an old certificate with a similar name is still in the keychain.
  IDENTITY="$(security find-identity -v -p codesigning 2>/dev/null \
    | sed -n 's/.*"\(.*LocalTranslator Dev.*\)".*/\1/p' | head -1)"
fi
if [ -n "$IDENTITY" ]; then
  codesign --force --sign "$IDENTITY" "$APP"
  echo "signed with $IDENTITY — the Accessibility grant survives rebuilds"
else
  codesign --force --sign - "$APP"
  echo "ad-hoc signed — macOS will ask for Accessibility again after each rebuild"
fi
echo "built $APP"
