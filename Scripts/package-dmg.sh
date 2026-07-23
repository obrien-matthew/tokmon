#!/bin/bash
# Package the ad-hoc-signed app as a compressed DMG.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
OUTPUT_PATH="${1:-$PROJECT_DIR/.build/tokmon.dmg}"
if [[ "$OUTPUT_PATH" != /* ]]; then
    OUTPUT_PATH="$PROJECT_DIR/$OUTPUT_PATH"
fi

case "$OUTPUT_PATH" in
    "$PROJECT_DIR"/.build/*.dmg) ;;
    *)
        echo "DMG output must be a .dmg file inside $PROJECT_DIR/.build." >&2
        exit 2
        ;;
esac

"$SCRIPT_DIR/package-app.sh"

DMG_STAGE="$(mktemp -d "${TMPDIR:-/tmp}/tokmon-dmg.XXXXXX")"
trap 'rm -rf "$DMG_STAGE"' EXIT

ditto "$PROJECT_DIR/.build/tokmon.app" "$DMG_STAGE/tokmon.app"
ln -s /Applications "$DMG_STAGE/Applications"

rm -f "$OUTPUT_PATH"
hdiutil create \
    -volname "tokmon" \
    -srcfolder "$DMG_STAGE" \
    -format UDZO \
    -ov \
    "$OUTPUT_PATH"
hdiutil verify "$OUTPUT_PATH"

echo "Packaged $OUTPUT_PATH"
