#!/bin/bash
#
# build.sh - Compile all C sources for Mac OS X (PPC / Leopard)
#
# Run this on the Power Mac G5.  Compiled binaries are placed in ./bin/
# so the whole g5-stream-server folder can be scp'd as a self-contained unit.
#
# Usage: ./build.sh
#

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
BIN_DIR="$SCRIPT_DIR/bin"

mkdir -p "$BIN_DIR"

echo "=== G5 Stream Server — Build ==="
echo "Output: $BIN_DIR"
echo ""

# audio_stream_server — the main multi-client PCM streaming server
echo "  Compiling audio_stream_server..."
gcc -O2 -o "$BIN_DIR/audio_stream_server" "$SCRIPT_DIR/audio_stream_server.c" \
    -framework CoreAudio -framework CoreFoundation -lpthread

# audio_capture — line-in capture to stdout (used by stream_send.sh)
echo "  Compiling audio_capture..."
gcc -O2 -o "$BIN_DIR/audio_capture" "$SCRIPT_DIR/audio_capture.c" \
    -framework CoreAudio -framework AudioToolbox -framework CoreFoundation

# set_input — switch the default CoreAudio input device
echo "  Compiling set_input..."
gcc -O2 -o "$BIN_DIR/set_input" "$SCRIPT_DIR/tools/set_input.c" \
    -framework CoreAudio

# audio_info — list audio devices and their properties
echo "  Compiling audio_info..."
gcc -O2 -o "$BIN_DIR/audio_info" "$SCRIPT_DIR/tools/audio_info.c" \
    -framework CoreAudio -framework AudioToolbox -framework CoreFoundation

# PPCStreamServer.app — Cocoa GUI server manager
echo "  Building PPCStreamServer.app..."
"$SCRIPT_DIR/cocoa-gui/build_gui.sh"

echo ""
echo "Done. Built $(ls "$BIN_DIR" | wc -l | tr -d ' ') binaries in $BIN_DIR/"
ls -lh "$BIN_DIR/"
