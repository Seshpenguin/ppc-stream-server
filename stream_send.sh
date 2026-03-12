#!/bin/bash
#
# stream_send.sh - Stream audio from Line Input to a remote host
#
# Captures from the default CoreAudio input (Line In) and sends
# raw PCM over TCP using netcat.
#
# Format: 16-bit signed little-endian, stereo, 44100 Hz (CD quality)
# Bitrate: 1411 kbps (uncompressed, lossless)
#
# Usage: ./stream_send.sh <host> [port]
#

HOST="${1}"
PORT="${2:-7777}"

if [ -z "$HOST" ]; then
    echo "Usage: $0 <host> [port]"
    echo "  host: IP or hostname of the receiving machine"
    echo "  port: TCP port (default: 7777)"
    exit 1
fi

CAPTURE="$HOME/bin/audio_capture"

if [ ! -x "$CAPTURE" ]; then
    echo "Error: audio_capture not found at $CAPTURE"
    exit 1
fi

echo "Streaming line input to $HOST:$PORT..."
echo "Format: 44100 Hz, 16-bit signed LE, stereo (lossless PCM)"
echo "Press Ctrl+C to stop."
echo ""

"$CAPTURE" 2>/dev/stderr | nc "$HOST" "$PORT"
