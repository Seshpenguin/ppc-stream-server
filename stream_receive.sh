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
RATE=44100
CHANNELS=2
BITS=16
BITRATE=$(( RATE * CHANNELS * BITS / 1000 ))

echo "Connecting to audio stream at $HOST:$PORT..."
echo "Format: ${RATE} Hz, ${BITS}-bit signed LE, ${CHANNELS}ch (lossless PCM)"
echo "Bitrate: ${BITRATE} kbps"
echo "Press Ctrl+C to stop."
echo ""

if command -v pw-cat &>/dev/null; then
    ncat "$HOST" "$PORT" --recv-only | pv | \
        pw-cat --playback \
               --raw \
               --format=s16 \
               --rate=$RATE \
               --channels=$CHANNELS \
               --latency=2048 \
               -
    exit $?
fi

if command -v gst-launch-1.0 &>/dev/null; then
    ncat "$HOST" "$PORT" --recv-only | pv | \
        gst-launch-1.0 -q \
            fdsrc fd=0 \
            ! audio/x-raw,format=S16LE,rate=$RATE,channels=$CHANNELS,layout=interleaved \
            ! audioconvert \
            ! autoaudiosink sync=false
    exit $?
fi

echo "Warning: pw-cat and gst-launch-1.0 not found, falling back to ffplay." >&2
ncat "$HOST" "$PORT" --recv-only | pv | \
    ffplay -nodisp \
           -stats \
           -f s16le \
           -sample_rate $RATE \
           -ch_layout stereo \
           -af "aresample=async=1" \
           -i pipe:0
