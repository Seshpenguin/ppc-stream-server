#!/bin/bash
#
# stream_receive.sh - Connect to the G5 audio stream server
#
# Connects to the G5's audio stream server and plays lossless PCM
# through the default PulseAudio/PipeWire output.
#
# Format: 16-bit signed little-endian, stereo, 44100 Hz (CD quality)
#
# Usage: ./stream_receive.sh [host] [port]
#

HOST="${1:-192.168.2.102}"
PORT="${2:-7777}"

echo "Connecting to audio stream at $HOST:$PORT..."
echo "Format: 44100 Hz, 16-bit signed LE, stereo (lossless PCM)"
echo "Bitrate: 1411 kbps (uncompressed, lossless)"
echo "Press Ctrl+C to stop."
echo ""

ncat "$HOST" "$PORT" --recv-only | \
    ffplay -nodisp \
           -flags low_delay \
           -fflags nobuffer \
           -analyzeduration 0 \
           -probesize 32 \
           -stats \
           -infbuf \
           -f s16le \
           -sample_rate 44100 \
           -ch_layout stereo \
           -i pipe:0
