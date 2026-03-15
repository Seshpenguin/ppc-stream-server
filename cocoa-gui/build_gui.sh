#!/bin/bash
#
# build_gui.sh - Compile the PPC Stream Server Manager Cocoa app
#
# Run this on a PowerPC Mac.  Produces PPCStreamServer.app bundle in-place.
#
# Usage: ./build_gui.sh
#

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
APP_DIR="$SCRIPT_DIR/PPCStreamServer.app"
MACOS_DIR="$APP_DIR/Contents/MacOS"
RESOURCES_DIR="$APP_DIR/Contents/Resources"

echo "=== PPC Stream Server Manager — Build ==="
echo ""

# Create the .app bundle structure
mkdir -p "$MACOS_DIR"
mkdir -p "$RESOURCES_DIR"

# Copy Info.plist
cp "$SCRIPT_DIR/Info.plist" "$APP_DIR/Contents/Info.plist"

# Create PkgInfo
echo -n "APPLPPCS" > "$APP_DIR/Contents/PkgInfo"

# Compile the Objective-C sources
echo "  Compiling PPCStreamServer..."
gcc -O2 \
    -o "$MACOS_DIR/PPCStreamServer" \
    "$SCRIPT_DIR/main.m" \
    "$SCRIPT_DIR/AppDelegate.m" \
    "$SCRIPT_DIR/ServerManager.m" \
    -framework Cocoa \
    -framework Foundation \
    -lobjc

# Embed the server executables into the app bundle
REPO_DIR="$SCRIPT_DIR/.."
AUDIO_BIN="$REPO_DIR/bin/audio_stream_server"
ITUNES_SCRIPT="$REPO_DIR/itunes_server.py"

if [ -x "$AUDIO_BIN" ]; then
    echo "  Embedding audio_stream_server..."
    cp "$AUDIO_BIN" "$MACOS_DIR/audio_stream_server"
else
    echo "  WARNING: $AUDIO_BIN not found — run build.sh from the repo root first."
fi

if [ -f "$ITUNES_SCRIPT" ]; then
    echo "  Embedding itunes_server.py..."
    cp "$ITUNES_SCRIPT" "$MACOS_DIR/itunes_server.py"
else
    echo "  WARNING: $ITUNES_SCRIPT not found."
fi

echo ""
echo "Done. Built PPCStreamServer.app at:"
echo "  $APP_DIR"
echo ""
echo "To run:  open $APP_DIR"
