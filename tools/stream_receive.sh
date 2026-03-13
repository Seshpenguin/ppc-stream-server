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

# pacat (PulseAudio / PipeWire-pulse) is preferred for live streams.
# It decouples network I/O from the audio callback via an internal ring
# buffer, so the playback thread never blocks on a pipe read.
# pw-cat is intentionally avoided: it does a blocking read() from stdin
# inside the PipeWire process callback, causing regular short stutters
# whenever the pipe doesn't have a full quantum of data ready.
if command -v pacat &>/dev/null; then
    ncat "$HOST" "$PORT" --recv-only | pv | \
        pacat --playback \
              --format=s16le \
              --rate=$RATE \
              --channels=2 \
              --latency-msec=25 \
              --process-time-msec=20
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

if command -v ffplay &>/dev/null; then
    ncat "$HOST" "$PORT" --recv-only | pv | \
        ffplay -nodisp \
               -stats \
               -f s16le \
               -sample_rate $RATE \
               -ch_layout stereo \
               -i pipe:0
    exit $?
fi

# Last resort: pw-cat. Works but may produce periodic short stutters on
# systems where PipeWire's quantum doesn't align with the stream packet size.
echo "Warning: pacat, gst-launch-1.0 and ffplay not found, falling back to pw-cat." >&2
ncat "$HOST" "$PORT" --recv-only | pv | \
    pw-cat --playback \
           --raw \
           --format=s16 \
           --rate=$RATE \
           --channels=$CHANNELS \
           --latency=16384 \
           -
