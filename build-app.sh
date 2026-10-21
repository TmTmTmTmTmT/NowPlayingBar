#!/bin/bash
#
# Builds NowPlayingBar.app from scratch, with no dependency on Xcode or
# Homebrew — only the Command Line Tools (clang + swift) are required.
#
# Steps:
#   1. Compile the bundled mediaremote-adapter helper into a framework (clang).
#   2. Compile the Swift menu bar app (SwiftPM).
#   3. Assemble + ad-hoc sign NowPlayingBar.app.
#
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
VENDOR="$ROOT/vendor/mediaremote-adapter"
APP="$ROOT/build/NowPlayingBar.app"
CONTENTS="$APP/Contents"
RES="$CONTENTS/Resources"
FW="$RES/MediaRemoteAdapter.framework"

echo "==> Cleaning previous build"
rm -rf "$APP"
mkdir -p "$CONTENTS/MacOS" "$RES"

echo "==> [1/3] Building MediaRemoteAdapter.framework (clang)"
mkdir -p "$FW/Versions/A/Resources"
clang -dynamiclib -fobjc-arc -fvisibility=default \
    -mmacosx-version-min=26.0 \
    -I "$VENDOR/include" -I "$VENDOR/src" \
    -framework Foundation -framework AppKit -framework UniformTypeIdentifiers \
    -install_name @rpath/MediaRemoteAdapter.framework/Versions/A/MediaRemoteAdapter \
    -o "$FW/Versions/A/MediaRemoteAdapter" \
    "$VENDOR"/src/adapter/*.m \
    "$VENDOR"/src/private/MediaRemote.m \
    "$VENDOR"/src/utility/*.m

cat > "$FW/Versions/A/Resources/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>com.vandenbe.MediaRemoteAdapter</string>
<key>CFBundleName</key><string>MediaRemoteAdapter</string>
<key>CFBundlePackageType</key><string>FMWK</string>
<key>CFBundleShortVersionString</key><string>0.7</string>
<key>CFBundleVersion</key><string>0.7.6</string>
</dict></plist>
PLIST

ln -sf A "$FW/Versions/Current"
ln -sf Versions/Current/MediaRemoteAdapter "$FW/MediaRemoteAdapter"
ln -sf Versions/Current/Resources "$FW/Resources"
codesign --force --sign - "$FW" >/dev/null

echo "==> [2/3] Building Swift executable (release)"
swift build -c release --package-path "$ROOT"
EXE="$ROOT/.build/release/NowPlayingBar"

echo "==> [3/3] Assembling NowPlayingBar.app"
cp "$EXE" "$CONTENTS/MacOS/NowPlayingBar"
cp "$ROOT/Resources/Info.plist" "$CONTENTS/Info.plist"
cp "$VENDOR/bin/mediaremote-adapter.pl" "$RES/mediaremote-adapter.pl"
cp "$VENDOR/LICENSE" "$RES/mediaremote-adapter.LICENSE"

# Sign the app last so the seal covers the (already-signed) nested framework.
codesign --force --sign - "$CONTENTS/MacOS/NowPlayingBar" >/dev/null
codesign --force --sign - "$APP" >/dev/null

echo ""
echo "==> Done: $APP"
echo "    Run with:   open \"$APP\""
echo "    Or:         \"$CONTENTS/MacOS/NowPlayingBar\"   (to see logs in the terminal)"
