/*
 * audio_stream_server.c - Multi-client audio streaming server for Mac OS X 10.5
 *
 * Captures audio from the default input (Line In) and streams raw PCM
 * to all connected TCP clients simultaneously.
 *
 * Uses a shared ring buffer so the audio capture callback never blocks.
 * Each client has its own writer thread that is woken by a condition
 * variable whenever new audio data arrives.
 *
 * Format: 16-bit signed little-endian, stereo, 44100 Hz
 *
 * Compile: gcc -O2 -o audio_stream_server audio_stream_server.c \
 *          -framework CoreAudio -framework AudioToolbox -framework CoreFoundation -lpthread
 *
 * Usage:   ./audio_stream_server [port]    (default: 7777)
 */

#include <AudioToolbox/AudioQueue.h>
#include <CoreAudio/CoreAudio.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <signal.h>
#include <pthread.h>
#include <sys/socket.h>
#include <netinet/in.h>
#include <netinet/tcp.h>
#include <arpa/inet.h>
#include <errno.h>

/* Audio settings */
#define NUM_BUFFERS      6
#define BUFFER_DURATION  0.02   /* 20ms per AudioQueue buffer */
#define SAMPLE_RATE      44100
#define CHANNELS         2
#define BITS             16
#define BYTES_PER_FRAME  (CHANNELS * (BITS / 8))

/* Ring buffer: must be power of 2. ~1.5 sec of audio. */
#define RING_SIZE        (1 << 18)  /* 262144 bytes */
#define RING_MASK        (RING_SIZE - 1)

static unsigned char ring_buf[RING_SIZE];
static volatile unsigned int ring_write_pos = 0;

/* Condition variable to wake client threads when new data arrives */
static pthread_mutex_t data_mutex = PTHREAD_MUTEX_INITIALIZER;
static pthread_cond_t  data_cond  = PTHREAD_COND_INITIALIZER;

/* Client management */
#define MAX_CLIENTS      32

typedef struct {
    int                 fd;
    struct sockaddr_in  addr;
    volatile int        active;
    unsigned int        read_pos;
    pthread_t           thread;
} Client;

static Client clients[MAX_CLIENTS];
static pthread_mutex_t clients_mutex = PTHREAD_MUTEX_INITIALIZER;
static volatile int running = 1;
static int client_count = 0;

static void signal_handler(int sig) {
    running = 0;
    /* Wake all waiting threads so they can exit */
    pthread_cond_broadcast(&data_cond);
}

/* Swap bytes for 16-bit samples (big-endian PPC -> little-endian) */
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

/* AudioQueue input callback - must never block */
static void input_callback(
    void *userData,
    AudioQueueRef inAQ,
    AudioQueueBufferRef inBuffer,
    const AudioTimeStamp *inStartTime,
    UInt32 inNumberPackets,
    const AudioStreamPacketDescription *inPacketDesc)
{
    if (!running) return;

    UInt32 len = inBuffer->mAudioDataByteSize;
    if (len > 0) {
        swap_16bit(inBuffer->mAudioData, len);

        /* Write into ring buffer */
        unsigned char *src = (unsigned char *)inBuffer->mAudioData;
        unsigned int wpos = ring_write_pos;
        UInt32 i;
        for (i = 0; i < len; i++) {
            ring_buf[wpos & RING_MASK] = src[i];
            wpos++;
        }

        /* PPC memory barrier then publish new write position */
        __asm__ volatile ("lwsync" ::: "memory");
        ring_write_pos = wpos;

        /* Wake all client writer threads */
        pthread_mutex_lock(&data_mutex);
        pthread_cond_broadcast(&data_cond);
        pthread_mutex_unlock(&data_mutex);
    }

    if (running) {
        AudioQueueEnqueueBuffer(inAQ, inBuffer, 0, NULL);
    }
}

/* Per-client writer thread */
static void *client_writer_thread(void *arg) {
    Client *c = (Client *)arg;
    unsigned char sendbuf[8192];

    while (running && c->active) {
        unsigned int wpos = ring_write_pos;
        unsigned int available = wpos - c->read_pos;

        if (available == 0) {
            /* Wait for new data instead of polling */
            pthread_mutex_lock(&data_mutex);
            /* Re-check after acquiring lock to avoid missed wakeup */
            if (ring_write_pos == c->read_pos && running && c->active) {
                pthread_cond_wait(&data_cond, &data_mutex);
            }
            pthread_mutex_unlock(&data_mutex);
            continue;
        }

        /* If client fell behind the ring buffer, skip to live position */
        if (available > RING_SIZE) {
            unsigned int skip = available - (RING_SIZE / 4);
            skip = (skip / BYTES_PER_FRAME) * BYTES_PER_FRAME;
            c->read_pos += skip;
            available = wpos - c->read_pos;
            fprintf(stderr, "Client %s:%d: overrun, skipped %u bytes\n",
                    inet_ntoa(c->addr.sin_addr), ntohs(c->addr.sin_port), skip);
        }

        /* Copy from ring buffer into linear send buffer */
        unsigned int to_send = available;
        if (to_send > sizeof(sendbuf)) to_send = sizeof(sendbuf);

        unsigned int i;
        unsigned int rpos = c->read_pos;
        for (i = 0; i < to_send; i++) {
            sendbuf[i] = ring_buf[rpos & RING_MASK];
            rpos++;
        }

        /* Blocking write - fine, each client has its own thread */
        ssize_t written = write(c->fd, sendbuf, to_send);
        if (written <= 0) {
            break;
        }
        c->read_pos += (unsigned int)written;
    }

    close(c->fd);

    pthread_mutex_lock(&clients_mutex);
    c->active = 0;
    client_count--;
    fprintf(stderr, "Client %s:%d disconnected (active: %d)\n",
            inet_ntoa(c->addr.sin_addr), ntohs(c->addr.sin_port), client_count);
    pthread_mutex_unlock(&clients_mutex);

    return NULL;
}

/* Thread to accept incoming client connections */
static void *accept_thread(void *arg) {
    int server_fd = *(int *)arg;

    while (running) {
        struct sockaddr_in client_addr;
        socklen_t addr_len = sizeof(client_addr);

        int client_fd = accept(server_fd, (struct sockaddr *)&client_addr, &addr_len);
        if (client_fd < 0) {
            if (running) usleep(100000);
            continue;
        }

        /* TCP_NODELAY: send data immediately, don't wait to coalesce */
        int flag = 1;
        setsockopt(client_fd, IPPROTO_TCP, TCP_NODELAY, &flag, sizeof(flag));

        /* Larger send buffer to absorb short stalls */
        int sndbuf = SAMPLE_RATE * BYTES_PER_FRAME * 2;  /* ~2 seconds */
        setsockopt(client_fd, SOL_SOCKET, SO_SNDBUF, &sndbuf, sizeof(sndbuf));

        pthread_mutex_lock(&clients_mutex);
        int added = 0;
        int i;
        for (i = 0; i < MAX_CLIENTS; i++) {
            if (!clients[i].active) {
                clients[i].fd = client_fd;
                clients[i].addr = client_addr;
                clients[i].read_pos = ring_write_pos;
                clients[i].active = 1;
                client_count++;
                added = 1;

                pthread_attr_t attr;
                pthread_attr_init(&attr);
                pthread_attr_setdetachstate(&attr, PTHREAD_CREATE_DETACHED);
                pthread_create(&clients[i].thread, &attr, client_writer_thread, &clients[i]);
                pthread_attr_destroy(&attr);

                fprintf(stderr, "Client connected: %s:%d (active: %d)\n",
                        inet_ntoa(client_addr.sin_addr),
                        ntohs(client_addr.sin_port),
                        client_count);
                break;
            }
        }
        pthread_mutex_unlock(&clients_mutex);

        if (!added) {
            fprintf(stderr, "Max clients reached, rejecting %s:%d\n",
                    inet_ntoa(client_addr.sin_addr),
                    ntohs(client_addr.sin_port));
            close(client_fd);
        }
    }
    return NULL;
}

int main(int argc, char *argv[]) {
    int port = 7777;
    if (argc > 1) port = atoi(argv[1]);

    OSStatus err;
    AudioQueueRef queue;
    AudioQueueBufferRef buffers[NUM_BUFFERS];
    AudioStreamBasicDescription format;
    UInt32 bufferByteSize;
    int i;

    signal(SIGINT, signal_handler);
    signal(SIGTERM, signal_handler);
    signal(SIGPIPE, SIG_IGN);

    memset(clients, 0, sizeof(clients));
    memset(ring_buf, 0, sizeof(ring_buf));

    /* Create TCP server socket */
    int server_fd = socket(AF_INET, SOCK_STREAM, 0);
    if (server_fd < 0) {
        perror("socket");
        return 1;
    }

    int opt = 1;
    setsockopt(server_fd, SOL_SOCKET, SO_REUSEADDR, &opt, sizeof(opt));

    struct sockaddr_in server_addr;
    memset(&server_addr, 0, sizeof(server_addr));
    server_addr.sin_family = AF_INET;
    server_addr.sin_addr.s_addr = INADDR_ANY;
    server_addr.sin_port = htons(port);

    if (bind(server_fd, (struct sockaddr *)&server_addr, sizeof(server_addr)) < 0) {
        perror("bind");
        close(server_fd);
        return 1;
    }

    if (listen(server_fd, 8) < 0) {
        perror("listen");
        close(server_fd);
        return 1;
    }

    fprintf(stderr, "=== G5 Audio Stream Server ===\n");
    fprintf(stderr, "Listening on port %d\n", port);
    fprintf(stderr, "Format: %d Hz, %d-bit, %d ch, PCM signed LE\n",
            SAMPLE_RATE, BITS, CHANNELS);
    fprintf(stderr, "Bitrate: %d kbps (lossless)\n",
            SAMPLE_RATE * CHANNELS * BITS / 1000);
    fprintf(stderr, "Ring buffer: %d bytes (~%.1f sec)\n",
            RING_SIZE, (float)RING_SIZE / (SAMPLE_RATE * BYTES_PER_FRAME));
    fprintf(stderr, "AudioQueue buffers: %d x %.0f ms\n",
            NUM_BUFFERS, BUFFER_DURATION * 1000);
    fprintf(stderr, "Max clients: %d\n", MAX_CLIENTS);
    fprintf(stderr, "Waiting for connections...\n\n");

    /* Start accept thread */
    pthread_t accept_tid;
    pthread_create(&accept_tid, NULL, accept_thread, &server_fd);

    /* Set up audio format */
    memset(&format, 0, sizeof(format));
    format.mSampleRate = SAMPLE_RATE;
    format.mFormatID = kAudioFormatLinearPCM;
    format.mFormatFlags = kAudioFormatFlagIsSignedInteger
                        | kAudioFormatFlagIsPacked
                        | kAudioFormatFlagIsBigEndian;
    format.mBytesPerPacket = BYTES_PER_FRAME;
    format.mFramesPerPacket = 1;
    format.mBytesPerFrame = BYTES_PER_FRAME;
    format.mChannelsPerFrame = CHANNELS;
    format.mBitsPerChannel = BITS;

    /* Create input audio queue */
    err = AudioQueueNewInput(&format, input_callback, NULL, NULL, NULL, 0, &queue);
    if (err != noErr) {
        fprintf(stderr, "Error creating audio queue: %d\n", (int)err);
        return 1;
    }

    /* Allocate and enqueue buffers */
    bufferByteSize = (UInt32)(SAMPLE_RATE * BUFFER_DURATION * BYTES_PER_FRAME);
    for (i = 0; i < NUM_BUFFERS; i++) {
        err = AudioQueueAllocateBuffer(queue, bufferByteSize, &buffers[i]);
        if (err != noErr) {
            fprintf(stderr, "Error allocating buffer %d: %d\n", i, (int)err);
            return 1;
        }
        AudioQueueEnqueueBuffer(queue, buffers[i], 0, NULL);
    }

    /* Start recording */
    err = AudioQueueStart(queue, NULL);
    if (err != noErr) {
        fprintf(stderr, "Error starting audio queue: %d\n", (int)err);
        return 1;
    }

    fprintf(stderr, "Capturing from Line In...\n\n");

    /* Main run loop */
    while (running) {
        CFRunLoopRunInMode(kCFRunLoopDefaultMode, 0.25, false);
    }

    /* Cleanup */
    fprintf(stderr, "\nShutting down...\n");
    AudioQueueStop(queue, true);
    AudioQueueDispose(queue, true);

    pthread_mutex_lock(&clients_mutex);
    for (i = 0; i < MAX_CLIENTS; i++) {
        if (clients[i].active) {
            clients[i].active = 0;
            close(clients[i].fd);
        }
    }
    pthread_mutex_unlock(&clients_mutex);

    /* Wake any threads still waiting */
    pthread_cond_broadcast(&data_cond);

    close(server_fd);
    usleep(200000);
    fprintf(stderr, "Done.\n");
    return 0;
}
