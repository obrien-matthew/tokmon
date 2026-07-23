#!/bin/bash
# Package tokmon as a minimal .app bundle and install it to /Applications
# (falls back to ~/Applications if /Applications isn't writable).
# Re-run after code changes to update the installed app.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$PROJECT_DIR"

"$SCRIPT_DIR/package-app.sh"
STAGE="$PROJECT_DIR/.build/tokmon.app"

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
