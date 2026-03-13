#!/bin/bash
#
# start_server.sh - Start the audio stream server and iTunes control server
#
# Launches both services and tears them down cleanly on Ctrl+C or exit.
# Run this on the Power Mac G5.
#
# Usage: ./start_server.sh [audio_port] [itunes_port]
#

AUDIO_PORT="${1:-7777}"
ITUNES_PORT="${2:-7778}"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
AUDIO_BIN="$SCRIPT_DIR/bin/audio_stream_server"
ITUNES_SCRIPT="$SCRIPT_DIR/itunes_server.py"

# ── Preflight checks ──────────────────────────────────────────────────────────

if [ ! -x "$AUDIO_BIN" ]; then
    echo "Error: $AUDIO_BIN not found."
    echo "Run ./build.sh first."
    exit 1
fi

if [ ! -f "$ITUNES_SCRIPT" ]; then
    echo "Error: $ITUNES_SCRIPT not found."
    exit 1
fi

# ── Cleanup on exit ───────────────────────────────────────────────────────────

AUDIO_PID=""
ITUNES_PID=""

cleanup() {
    echo ""
    echo "Shutting down..."
    [ -n "$AUDIO_PID" ]  && kill "$AUDIO_PID"  2>/dev/null && echo "  Stopped audio_stream_server (PID $AUDIO_PID)"
    [ -n "$ITUNES_PID" ] && kill "$ITUNES_PID" 2>/dev/null && echo "  Stopped itunes_server.py (PID $ITUNES_PID)"
    wait 2>/dev/null
    echo "Done."
}

trap cleanup EXIT INT TERM

# ── Launch services ───────────────────────────────────────────────────────────

echo "=== G5 Stream Server ==="
echo ""

echo "Starting audio_stream_server on port $AUDIO_PORT..."
"$AUDIO_BIN" "$AUDIO_PORT" &
AUDIO_PID=$!

echo "Starting itunes_server.py on port $ITUNES_PORT..."
python "$ITUNES_SCRIPT" "$ITUNES_PORT" &
ITUNES_PID=$!

echo ""
echo "Both services running. Press Ctrl+C to stop."
echo ""

# Wait for both processes. The trap handles cleanup on Ctrl+C.
wait
