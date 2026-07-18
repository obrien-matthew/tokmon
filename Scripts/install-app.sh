#!/bin/bash
# Build tokmon as a minimal .app bundle and install it to /Applications
# (falls back to ~/Applications if /Applications isn't writable).
# Re-run after code changes to update the installed app.
set -euo pipefail

cd "$(dirname "$0")/.."

echo "Building release binary..."
swift build -c release

VERSION="0.1.0"
BUNDLE_ID="com.matthew.tokmon"
STAGE=".build/tokmon.app"

rm -rf "$STAGE"
mkdir -p "$STAGE/Contents/MacOS"
cp .build/release/tokmon "$STAGE/Contents/MacOS/tokmon"

cat > "$STAGE/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleExecutable</key>
	<string>tokmon</string>
	<key>CFBundleIdentifier</key>
	<string>${BUNDLE_ID}</string>
	<key>CFBundleName</key>
	<string>tokmon</string>
	<key>CFBundlePackageType</key>
	<string>APPL</string>
	<key>CFBundleShortVersionString</key>
	<string>${VERSION}</string>
	<key>CFBundleVersion</key>
	<string>${VERSION}</string>
	<key>LSMinimumSystemVersion</key>
	<string>14.0</string>
	<key>LSUIElement</key>
	<true/>
	<key>NSHighResolutionCapable</key>
	<true/>
</dict>
</plist>
PLIST

# Ad-hoc signature keeps Gatekeeper happy for a locally built app.
codesign --force --sign - "$STAGE"

DEST="/Applications/tokmon.app"
if [ ! -w /Applications ]; then
    DEST="$HOME/Applications/tokmon.app"
    mkdir -p "$HOME/Applications"
    echo "/Applications not writable; installing to $DEST"
fi

# Replace any previous install and stop a running instance so the new
# binary takes over cleanly.
pkill -x tokmon 2>/dev/null || true
rm -rf "$DEST"
ditto "$STAGE" "$DEST"

echo "Installed $DEST"
echo "Launching..."
open "$DEST"
