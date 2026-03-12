# PPC Stream Server

> The code in this repository was "agentically engineered", mostly for fun to see if Claude and OpenCode could solve an interesting task with a legacy computer.
> After some guidance here and there, I would say it's a success, I tasked Claude to use ssh to access the G5 and it was able to remotely compile and test code, 
> even going as far as running small AppleScripts over ssh with osascript to do things like adjust the audio levels. It also didn't really have problems understanding 
> the constraints of developing on OS X Leopard and using the old gcc and Xcode toolchain (even considering subtle details like the big-endian nature of the ppc64 G5).
> Thinking about it, this could make for an interesting LLM benchmark. Either way, now I can listen to my vinyls over the network from a Power Mac G5 using code written 
> by a frontier LLM. This has got to be a pretty unique setup :)

![G5 Setup and OpenCode](docs/g5_setup_and_opencode.png)

> The rest of this README was written by Claude.

A lossless, low-latency audio streaming system that captures line-level audio input from a Power Mac G5 (or any PPC Mac running Mac OS X Leopard) and streams it over the network to one or more clients simultaneously.

Built for a specific use case: a Power Mac G5 receiving mixed audio from a vinyl turntable/CD player setup, streamed live to Linux desktops on the local network.

## Architecture

```
[Audio Source] --> [Mac Line In] --> audio_stream_server (TCP :7777)
                                          |
                                          +--> client 1 (stream_receive.sh)
                                          +--> client 2
                                          +--> ... up to 32 simultaneous clients
```

The server runs persistently on the Mac, always capturing from the line input. Clients connect and disconnect freely without affecting the server or each other.

Internally, the audio capture callback writes into a lock-free ring buffer and wakes per-client writer threads via a condition variable. This ensures the CoreAudio callback never blocks on network I/O, eliminating audio dropouts regardless of client behavior.

## Audio Specs

| Property           | Value                              |
|--------------------|------------------------------------|
| Format             | PCM 16-bit signed, little-endian   |
| Sample rate        | 44,100 Hz                          |
| Channels           | 2 (stereo)                         |
| Bitrate            | 1,411 kbps                         |
| Compression        | None (lossless)                    |
| Capture buffers    | 6 x 20ms (AudioQueue)              |
| Ring buffer        | ~1.5 seconds (262,144 bytes)       |
| Transport          | Raw TCP                            |

## Files

| File                       | Description                                              |
|----------------------------|----------------------------------------------------------|
| `audio_stream_server.c`    | Main server - captures audio and streams to TCP clients  |
| `audio_capture.c`          | Standalone capture tool (writes PCM to stdout)           |
| `audio_info.c`             | Diagnostic tool - shows input device, source, and volume |
| `set_input.c`              | Utility to switch between Line In and S/PDIF Digital In  |
| `stream_receive.sh`        | Linux client script - connects and plays audio           |
| `stream_send.sh`           | Legacy sender script (replaced by audio_stream_server)   |

## Deploying on a PPC Mac

### Requirements

- Mac OS X 10.5 Leopard (tested on 10.5.8)
- PowerPC G4 or G5 processor
- Xcode / GCC (the system `gcc` from Xcode 3.x works)
- Built-in audio or any CoreAudio-compatible input device

### Building

Copy the source files to the Mac and compile:

```bash
gcc -O2 -o audio_stream_server audio_stream_server.c \
    -framework CoreAudio -framework AudioToolbox -framework CoreFoundation -lpthread

gcc -O2 -o audio_info audio_info.c \
    -framework CoreAudio -framework AudioToolbox

gcc -O2 -o set_input set_input.c \
    -framework CoreAudio

gcc -O2 -o audio_capture audio_capture.c \
    -framework CoreAudio -framework AudioToolbox -framework CoreFoundation
```

A good place to put the binaries is `~/bin/`:

```bash
mkdir -p ~/bin
mv audio_stream_server audio_info set_input audio_capture ~/bin/
```

### Configuring the audio input

Check current input device settings:

```bash
~/bin/audio_info
```

The Power Mac G5 has two inputs on the built-in audio: analog **Line In** and **S/PDIF Digital In**. Switch between them with:

```bash
~/bin/set_input line    # Analog Line In (3.5mm jack)
~/bin/set_input spdf    # S/PDIF Digital In (optical)
```

Set the input volume (0-100) with:

```bash
osascript -e 'set volume input volume 75'
```

A value of 75 works well for typical line-level sources. If the audio sounds distorted, lower it. If it's too quiet, raise it.

### Running the server

Start the server:

```bash
~/bin/audio_stream_server
```

It will print status to stderr and begin listening on port 7777. You can optionally pass a different port as the first argument.

To run it in the background persistently:

```bash
nohup ~/bin/audio_stream_server 2>> ~/audio_server.log &
```

To start it automatically at login, add it to System Preferences > Accounts > Login Items, or create a launchd plist at `~/Library/LaunchAgents/com.g5.audiostream.plist`:

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
  "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>com.g5.audiostream</string>
    <key>ProgramArguments</key>
    <array>
        <string>/Users/swadmin/bin/audio_stream_server</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <true/>
    <key>StandardErrorPath</key>
    <string>/Users/swadmin/audio_server.log</string>
</dict>
</plist>
```

Load it with:

```bash
launchctl load ~/Library/LaunchAgents/com.g5.audiostream.plist
```

## Connecting from a Linux client

### Requirements

- `ncat` (from nmap) or `nc`
- `ffplay` (from ffmpeg) for playback with stats display
- PulseAudio or PipeWire

### Usage

```bash
./stream_receive.sh [host] [port]
```

Defaults to `192.168.2.102` on port `7777`. Override as needed:

```bash
./stream_receive.sh 192.168.1.50 7777
```

ffplay will show real-time stats including playback position, audio queue buffer level, and master-audio clock sync offset.

### Manual connection

You can also connect manually with any tool that speaks TCP:

```bash
# Using ffplay directly
ncat 192.168.2.102 7777 --recv-only | \
    ffplay -nodisp -stats -infbuf \
           -flags low_delay -fflags nobuffer \
           -analyzeduration 0 -probesize 32 \
           -f s16le -sample_rate 44100 -ch_layout stereo \
           -i pipe:0

# Using pacat (PulseAudio) for lower latency, no stats
ncat 192.168.2.102 7777 --recv-only | \
    pacat --playback --format=s16le --rate=44100 --channels=2 \
          --latency-msec=50 --process-time-msec=10

# Record to a WAV file using ffmpeg
ncat 192.168.2.102 7777 --recv-only | \
    ffmpeg -f s16le -ar 44100 -ch_layout stereo -i pipe:0 output.wav
```

## Design Notes

- The audio capture callback writes into a shared ring buffer and never touches the network. Per-client writer threads are woken via `pthread_cond_broadcast` when new data arrives, so there is no polling delay and no risk of the capture stalling on a slow client.
- If a client falls too far behind (more than the ring buffer size), it is skipped ahead to the live position rather than receiving stale audio.
- The server handles big-endian to little-endian byte conversion on the PPC side using a `lwsync` memory barrier for safe ring buffer publishing. Clients receive standard little-endian PCM with no processing needed.
- `SIGPIPE` is ignored on the server so a disconnecting client never crashes it.
- Each client gets a 2-second kernel TCP send buffer (`SO_SNDBUF`) and `TCP_NODELAY` is enabled to minimize latency.
