/*
 * audio_capture.c - CoreAudio line input capture for Mac OS X 10.5 (Leopard)
 * Captures audio from the default input device and writes raw PCM to stdout.
 * 
 * Format: 16-bit signed little-endian, stereo, 44100 Hz
 * (G5 is big-endian PPC, so we do the byte swap)
 *
 * Compile: gcc -o audio_capture audio_capture.c -framework CoreAudio -framework AudioToolbox -framework CoreFoundation
 * Usage:   ./audio_capture | nc <host> <port>
 *     or:  ./audio_capture > /dev/tcp/...
 */

#include <AudioToolbox/AudioQueue.h>
#include <CoreAudio/CoreAudio.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <signal.h>

/* Number of audio queue buffers */
#define NUM_BUFFERS 3

/* Buffer duration in seconds - small for low latency */
#define BUFFER_DURATION 0.02

static volatile int running = 1;

static void signal_handler(int sig) {
    running = 0;
}

/* Swap bytes for 16-bit samples (big-endian PPC -> little-endian for network/PC) */
static void swap_16bit(void *buf, size_t bytes) {
    unsigned char *p = (unsigned char *)buf;
    unsigned char tmp;
    size_t i;
    for (i = 0; i + 1 < bytes; i += 2) {
        tmp = p[i];
        p[i] = p[i + 1];
        p[i + 1] = tmp;
    }
}

/* AudioQueue input callback - called when a buffer is full */
static void input_callback(
    void *userData,
    AudioQueueRef inAQ,
    AudioQueueBufferRef inBuffer,
    const AudioTimeStamp *inStartTime,
    UInt32 inNumberPackets,
    const AudioStreamPacketDescription *inPacketDesc)
{
    if (!running) return;

    if (inBuffer->mAudioDataByteSize > 0) {
        /* Swap bytes from big-endian (PPC) to little-endian */
        swap_16bit(inBuffer->mAudioData, inBuffer->mAudioDataByteSize);

        /* Write raw PCM to stdout */
        ssize_t written = write(STDOUT_FILENO, inBuffer->mAudioData, inBuffer->mAudioDataByteSize);
        if (written < 0) {
            running = 0;
            return;
        }
    }

    /* Re-enqueue the buffer */
    if (running) {
        AudioQueueEnqueueBuffer(inAQ, inBuffer, 0, NULL);
    }
}

int main(int argc, char *argv[]) {
    OSStatus err;
    AudioQueueRef queue;
    AudioQueueBufferRef buffers[NUM_BUFFERS];
    AudioStreamBasicDescription format;
    UInt32 bufferByteSize;
    int i;

    /* Set up signal handlers for clean shutdown */
    signal(SIGINT, signal_handler);
    signal(SIGTERM, signal_handler);
    signal(SIGPIPE, signal_handler);

    /* Define the audio format: 16-bit signed integer, stereo, 44.1kHz */
    memset(&format, 0, sizeof(format));
    format.mSampleRate = 44100.0;
    format.mFormatID = kAudioFormatLinearPCM;
    format.mFormatFlags = kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked;
    /* Note: NOT setting kAudioFormatFlagIsBigEndian - we want native (big-endian on PPC) */
    /* We'll manually swap to little-endian for the receiving end */
    format.mFormatFlags |= kAudioFormatFlagIsBigEndian;
    format.mBytesPerPacket = 4;   /* 2 channels * 2 bytes */
    format.mFramesPerPacket = 1;
    format.mBytesPerFrame = 4;
    format.mChannelsPerFrame = 2;
    format.mBitsPerChannel = 16;

    /* Print info to stderr so it doesn't mix with audio data on stdout */
    fprintf(stderr, "Audio Capture: 44100 Hz, 16-bit signed LE, stereo\n");
    fprintf(stderr, "Buffer duration: %.0f ms, %d buffers\n", BUFFER_DURATION * 1000, NUM_BUFFERS);

    /* Create input audio queue */
    err = AudioQueueNewInput(
        &format,
        input_callback,
        NULL,       /* user data */
        NULL,       /* run loop (NULL = internal) */
        NULL,       /* run loop mode */
        0,          /* flags */
        &queue
    );
    if (err != noErr) {
        fprintf(stderr, "Error creating audio queue: %d\n", (int)err);
        return 1;
    }

    /* Calculate buffer size for desired duration */
    bufferByteSize = (UInt32)(format.mSampleRate * BUFFER_DURATION * format.mBytesPerFrame);
    fprintf(stderr, "Buffer size: %u bytes\n", (unsigned int)bufferByteSize);

    /* Allocate and enqueue buffers */
    for (i = 0; i < NUM_BUFFERS; i++) {
        err = AudioQueueAllocateBuffer(queue, bufferByteSize, &buffers[i]);
        if (err != noErr) {
            fprintf(stderr, "Error allocating buffer %d: %d\n", i, (int)err);
            return 1;
        }
        err = AudioQueueEnqueueBuffer(queue, buffers[i], 0, NULL);
        if (err != noErr) {
            fprintf(stderr, "Error enqueuing buffer %d: %d\n", i, (int)err);
            return 1;
        }
    }

    /* Start recording */
    err = AudioQueueStart(queue, NULL);
    if (err != noErr) {
        fprintf(stderr, "Error starting audio queue: %d\n", (int)err);
        return 1;
    }

    fprintf(stderr, "Recording from line input... (Ctrl+C to stop)\n");

    /* Run until signaled to stop */
    while (running) {
        /* Use CFRunLoopRunInMode to process audio callbacks */
        CFRunLoopRunInMode(kCFRunLoopDefaultMode, 0.1, false);
    }

    /* Stop and clean up */
    fprintf(stderr, "\nStopping...\n");
    AudioQueueStop(queue, true);
    AudioQueueDispose(queue, true);

    return 0;
}
