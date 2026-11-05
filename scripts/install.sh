#!/bin/bash
# Installs (or updates) the latest MyToolbox release into /Applications.
#   curl -fsSL https://raw.githubusercontent.com/wenayy/MyToolbox/main/scripts/install.sh | bash
set -euo pipefail
REPO="wenayy/MyToolbox"
DEST="/Applications"

if [[ "$(sw_vers -productVersion | cut -d. -f1)" -lt 26 ]]; then
  echo "MyToolbox needs macOS 26 or later." >&2
  exit 1
fi

echo "▸ Finding the latest release…"
URL=$(curl -fsSL "https://api.github.com/repos/$REPO/releases/latest" \
  | grep -o '"browser_download_url": *"[^"]*\.zip"' | head -1 | sed 's/.*"\(https[^"]*\)"/\1/')
[[ -n "$URL" ]] || { echo "Couldn't find a release to download." >&2; exit 1; }

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
echo "▸ Downloading $(basename "$URL")…"
curl -fL --progress-bar "$URL" -o "$TMP/MyToolbox.zip"
ditto -x -k "$TMP/MyToolbox.zip" "$TMP"

if pgrep -x MyToolbox >/dev/null; then
  echo "▸ Quitting the running copy…"
  osascript -e 'quit app "MyToolbox"' 2>/dev/null || true
  sleep 1
fi

echo "▸ Installing to $DEST…"
rm -rf "$DEST/MyToolbox.app"
ditto "$TMP/MyToolbox.app" "$DEST/MyToolbox.app"
xattr -dr com.apple.quarantine "$DEST/MyToolbox.app" 2>/dev/null || true

echo "✓ Installed. Opening MyToolbox…"
open "$DEST/MyToolbox.app"
if ! command -v brew >/dev/null 2>&1 && [[ ! -x /opt/homebrew/bin/brew && ! -x /usr/local/bin/brew ]]; then
  echo "Tip: some tools use free helpers installed with Homebrew — get it at https://brew.sh"
fi
