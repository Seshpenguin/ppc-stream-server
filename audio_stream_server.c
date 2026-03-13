/*
 * audio_stream_server.c - Multi-client audio streaming server for Mac OS X 10.5
 *
 * Captures line-level audio input from the default input device and streams
 * raw PCM to all connected TCP clients simultaneously.
 *
 * Uses a single AudioDeviceIOProc registered via AudioDeviceCreateIOProcID
 * (the non-deprecated Leopard API).  The IOProc fires at the true hardware
 * interrupt rate (~512 frames / 11.6 ms on the G5) so output is smooth with
 * no batching artefacts.  All property queries use AudioObjectGetPropertyData,
 * also the non-deprecated API on 10.5.
 *
 * Each client has its own writer thread woken by a condition variable.  The
 * IOProc never touches the network.
 *
 * Output format: 16-bit signed little-endian PCM, stereo, 44100 Hz.
 * The HAL delivers 32-bit big-endian float (native on PPC); we convert inline.
 *
 * Compile:
 *   gcc -O2 -o audio_stream_server audio_stream_server.c \
 *       -framework CoreAudio -framework CoreFoundation -lpthread
 *
 * Usage: ./audio_stream_server [port]    (default port: 7777)
 */

#include <CoreAudio/CoreAudio.h>
#include <CoreFoundation/CoreFoundation.h>
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

/* -------------------------------------------------------------------------
 * Audio / stream constants
 * ---------------------------------------------------------------------- */
#define SAMPLE_RATE      44100
#define CHANNELS         2
#define BITS             16
#define BYTES_PER_FRAME  (CHANNELS * (BITS / 8))   /* 4 bytes */

/* Ring buffer — power of 2, ~1.5 seconds of audio */
#define RING_SIZE  (1 << 18)    /* 262144 bytes */
#define RING_MASK  (RING_SIZE - 1)

/* -------------------------------------------------------------------------
 * Shared ring buffer + wake condition for client writer threads
 * ---------------------------------------------------------------------- */
static unsigned char        ring_buf[RING_SIZE];
static volatile unsigned int ring_write_pos = 0;

static pthread_mutex_t data_mutex = PTHREAD_MUTEX_INITIALIZER;
static pthread_cond_t  data_cond  = PTHREAD_COND_INITIALIZER;

/* -------------------------------------------------------------------------
 * Client management
 * ---------------------------------------------------------------------- */
#define MAX_CLIENTS 32

typedef struct {
    int                fd;
    struct sockaddr_in addr;
    volatile int       active;
    unsigned int       read_pos;
    pthread_t          thread;
} Client;

static Client          clients[MAX_CLIENTS];
static pthread_mutex_t clients_mutex = PTHREAD_MUTEX_INITIALIZER;
static int             client_count  = 0;

/* -------------------------------------------------------------------------
 * Global state
 * ---------------------------------------------------------------------- */
static volatile int      running   = 1;
static AudioDeviceID     device_id = kAudioDeviceUnknown;
static AudioDeviceIOProcID ioproc_id = NULL;

/* -------------------------------------------------------------------------
 * Signal handler
 * ---------------------------------------------------------------------- */
static void signal_handler(int sig) {
    (void)sig;
    running = 0;
    pthread_cond_broadcast(&data_cond);
}

/* -------------------------------------------------------------------------
 * Helpers
 * ---------------------------------------------------------------------- */

/*
 * Saturating add of two 16-bit signed samples — prevents wrap-around clipping.
 */
static inline short mix_samples(short a, short b) {
    int sum = (int)a + (int)b;
    if (sum >  32767) return  32767;
    if (sum < -32768) return -32768;
    return (short)sum;
}

/*
 * Convert one 32-bit big-endian IEEE 754 float to 16-bit signed LE integer.
 *
 * On PPC, the CPU is big-endian so the HAL's float bytes are already in
 * native order — memcpy into a float works directly with no byte swap.
 */
static inline short float32be_to_int16(const unsigned char *src) {
    float f;
    memcpy(&f, src, sizeof(float));
    if (f >  1.0f) f =  1.0f;
    if (f < -1.0f) f = -1.0f;
    return (short)(f * 32767.0f);
}

/*
 * Convenience wrapper: AudioObjectGetPropertyData with a simple scalar address.
 */
static OSStatus get_property(AudioObjectID obj,
                             AudioObjectPropertySelector sel,
                             AudioObjectPropertyScope    scope,
                             UInt32 *io_size, void *data) {
    AudioObjectPropertyAddress addr = { sel, scope,
                                        kAudioObjectPropertyElementMaster };
    return AudioObjectGetPropertyData(obj, &addr, 0, NULL, io_size, data);
}

/* -------------------------------------------------------------------------
 * AudioDeviceIOProc — the capture / output callback
 *
 * Fires at the true hardware interrupt rate (512 frames ≈ 11.6 ms on this G5).
 *
 * inInputData contains the line-in audio: 32-bit big-endian float, 2 ch,
 * 44100 Hz.  We convert each sample to 16-bit signed LE and write into the
 * shared ring buffer, then wake all waiting client writer threads.
 *
 * We do not touch outOutputData so speaker output is unaffected.
 * ---------------------------------------------------------------------- */
static OSStatus io_proc(
    AudioDeviceID            inDevice,
    const AudioTimeStamp    *inNow,
    const AudioBufferList   *inInputData,
    const AudioTimeStamp    *inInputTime,
    AudioBufferList         *outOutputData,
    const AudioTimeStamp    *outOutputTime,
    void                    *inClientData)
{
    (void)inDevice; (void)inNow; (void)inInputTime;
    (void)outOutputData; (void)outOutputTime; (void)inClientData;

    if (!running) return kAudioHardwareNoError;
    if (!inInputData || inInputData->mNumberBuffers == 0)
        return kAudioHardwareNoError;

    const AudioBuffer *buf = &inInputData->mBuffers[0];
    if (!buf->mData || buf->mDataByteSize == 0)
        return kAudioHardwareNoError;

    /* HAL guarantees 32-bit float, 2 channels, native (big-endian) order */
    const unsigned char *src = (const unsigned char *)buf->mData;
    UInt32 num_frames = buf->mDataByteSize / (sizeof(float) * CHANNELS);

    unsigned int wpos = ring_write_pos;
    UInt32 f;
    for (f = 0; f < num_frames; f++) {
        int ch;
        for (ch = 0; ch < CHANNELS; ch++) {
            unsigned int off = (f * CHANNELS + ch) * sizeof(float);
            short s = float32be_to_int16(src + off);
            ring_buf[ wpos      & RING_MASK] = (unsigned char)( s       & 0xFF);
            ring_buf[(wpos + 1) & RING_MASK] = (unsigned char)((s >> 8) & 0xFF);
            wpos += 2;
        }
    }

    /* PPC memory barrier then publish the new write position atomically */
    __asm__ volatile ("lwsync" ::: "memory");
    ring_write_pos = wpos;

    /* Wake all client writer threads */
    pthread_mutex_lock(&data_mutex);
    pthread_cond_broadcast(&data_cond);
    pthread_mutex_unlock(&data_mutex);

    return kAudioHardwareNoError;
}

/* -------------------------------------------------------------------------
 * Per-client writer thread
 * ---------------------------------------------------------------------- */
static void *client_writer_thread(void *arg) {
    Client *c = (Client *)arg;
    unsigned char sendbuf[8192];

    while (running && c->active) {
        unsigned int wpos      = ring_write_pos;
        unsigned int available = wpos - c->read_pos;

        if (available == 0) {
            pthread_mutex_lock(&data_mutex);
            if (ring_write_pos == c->read_pos && running && c->active)
                pthread_cond_wait(&data_cond, &data_mutex);
            pthread_mutex_unlock(&data_mutex);
            continue;
        }

        /* Skip ahead if the client has fallen more than one ring behind */
        if (available > RING_SIZE) {
            unsigned int skip = available - (RING_SIZE / 4);
            skip = (skip / BYTES_PER_FRAME) * BYTES_PER_FRAME;
            c->read_pos += skip;
            available    = wpos - c->read_pos;
            fprintf(stderr, "Client %s:%d: overrun, skipped %u bytes\n",
                    inet_ntoa(c->addr.sin_addr), ntohs(c->addr.sin_port), skip);
        }

        unsigned int to_send = available < sizeof(sendbuf)
                               ? available : (unsigned int)sizeof(sendbuf);
        unsigned int rpos = c->read_pos;
        unsigned int i;
        for (i = 0; i < to_send; i++)
            sendbuf[i] = ring_buf[rpos++ & RING_MASK];

        ssize_t written = write(c->fd, sendbuf, to_send);
        if (written <= 0) break;
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

/* -------------------------------------------------------------------------
 * Accept thread — waits for incoming TCP connections
 * ---------------------------------------------------------------------- */
static void *accept_thread(void *arg) {
    int server_fd = *(int *)arg;

    while (running) {
        struct sockaddr_in client_addr;
        socklen_t addr_len = sizeof(client_addr);
        int cfd = accept(server_fd, (struct sockaddr *)&client_addr, &addr_len);
        if (cfd < 0) {
            if (running) usleep(100000);
            continue;
        }

        /* Disable Nagle — send data immediately */
        int flag = 1;
        setsockopt(cfd, IPPROTO_TCP, TCP_NODELAY, &flag, sizeof(flag));
        /* 2-second kernel send buffer to absorb short stalls */
        int sndbuf = SAMPLE_RATE * BYTES_PER_FRAME * 2;
        setsockopt(cfd, SOL_SOCKET, SO_SNDBUF, &sndbuf, sizeof(sndbuf));

        pthread_mutex_lock(&clients_mutex);
        int added = 0, i;
        for (i = 0; i < MAX_CLIENTS; i++) {
            if (!clients[i].active) {
                clients[i].fd       = cfd;
                clients[i].addr     = client_addr;
                clients[i].read_pos = ring_write_pos;
                clients[i].active   = 1;
                client_count++;
                added = 1;

                pthread_attr_t attr;
                pthread_attr_init(&attr);
                pthread_attr_setdetachstate(&attr, PTHREAD_CREATE_DETACHED);
                pthread_create(&clients[i].thread, &attr,
                               client_writer_thread, &clients[i]);
                pthread_attr_destroy(&attr);

                fprintf(stderr, "Client connected: %s:%d (active: %d)\n",
                        inet_ntoa(client_addr.sin_addr),
                        ntohs(client_addr.sin_port), client_count);
                break;
            }
        }
        pthread_mutex_unlock(&clients_mutex);

        if (!added) {
            fprintf(stderr, "Max clients reached, rejecting %s:%d\n",
                    inet_ntoa(client_addr.sin_addr), ntohs(client_addr.sin_port));
            close(cfd);
        }
    }
    return NULL;
}

/* -------------------------------------------------------------------------
 * main
 * ---------------------------------------------------------------------- */
int main(int argc, char *argv[]) {
    int port = 7777;
    if (argc > 1) port = atoi(argv[1]);

    signal(SIGINT,  signal_handler);
    signal(SIGTERM, signal_handler);
    signal(SIGPIPE, SIG_IGN);

    memset(clients,  0, sizeof(clients));
    memset(ring_buf, 0, sizeof(ring_buf));

    /* ------------------------------------------------------------------
     * TCP server socket
     * --------------------------------------------------------------- */
    int server_fd = socket(AF_INET, SOCK_STREAM, 0);
    if (server_fd < 0) { perror("socket"); return 1; }

    int opt = 1;
    setsockopt(server_fd, SOL_SOCKET, SO_REUSEADDR, &opt, sizeof(opt));

    struct sockaddr_in sa;
    memset(&sa, 0, sizeof(sa));
    sa.sin_family      = AF_INET;
    sa.sin_addr.s_addr = INADDR_ANY;
    sa.sin_port        = htons((uint16_t)port);

    if (bind(server_fd, (struct sockaddr *)&sa, sizeof(sa)) < 0) {
        perror("bind"); close(server_fd); return 1;
    }
    if (listen(server_fd, 8) < 0) {
        perror("listen"); close(server_fd); return 1;
    }

    /* ------------------------------------------------------------------
     * Discover the default input device using AudioObjectGetPropertyData
     * --------------------------------------------------------------- */
    {
        AudioObjectPropertyAddress addr = {
            kAudioHardwarePropertyDefaultInputDevice,
            kAudioObjectPropertyScopeGlobal,
            kAudioObjectPropertyElementMaster
        };
        UInt32 size = sizeof(device_id);
        OSStatus err = AudioObjectGetPropertyData(kAudioObjectSystemObject,
                                                  &addr, 0, NULL,
                                                  &size, &device_id);
        if (err != kAudioHardwareNoError || device_id == kAudioDeviceUnknown) {
            fprintf(stderr, "Error: cannot find default input device (%d)\n",
                    (int)err);
            close(server_fd);
            return 1;
        }
    }

    /* Device name */
    char devname[256] = "(unknown)";
    {
        UInt32 size = sizeof(devname);
        get_property(device_id, kAudioDevicePropertyDeviceName,
                     kAudioObjectPropertyScopeGlobal, &size, devname);
    }

    /* Actual HAL buffer size */
    UInt32 buf_frames = 0;
    {
        UInt32 size = sizeof(buf_frames);
        get_property(device_id, kAudioDevicePropertyBufferFrameSize,
                     kAudioDevicePropertyScopeInput, &size, &buf_frames);
    }

    fprintf(stderr, "=== G5 Audio Stream Server ===\n");
    fprintf(stderr, "Listening on port %d\n", port);
    fprintf(stderr, "Device: ID=%u \"%s\"\n", (unsigned)device_id, devname);
    fprintf(stderr, "Format: %d Hz, %d-bit, %d ch, PCM signed LE\n",
            SAMPLE_RATE, BITS, CHANNELS);
    fprintf(stderr, "Bitrate: %d kbps (lossless)\n",
            SAMPLE_RATE * CHANNELS * BITS / 1000);
    fprintf(stderr, "HAL buffer: %u frames (%.2f ms)\n",
            (unsigned)buf_frames,
            (double)buf_frames / SAMPLE_RATE * 1000.0);
    fprintf(stderr, "Ring buffer: %d bytes (~%.1f sec)\n",
            RING_SIZE, (float)RING_SIZE / (SAMPLE_RATE * BYTES_PER_FRAME));
    fprintf(stderr, "Max clients: %d\n", MAX_CLIENTS);
    fprintf(stderr, "Waiting for connections...\n\n");

    /* Start accept thread */
    pthread_t accept_tid;
    pthread_create(&accept_tid, NULL, accept_thread, &server_fd);

    /* ------------------------------------------------------------------
     * Register IOProc via AudioDeviceCreateIOProcID (non-deprecated API)
     * --------------------------------------------------------------- */
    OSStatus err = AudioDeviceCreateIOProcID(device_id, io_proc,
                                             NULL, &ioproc_id);
    if (err != kAudioHardwareNoError) {
        fprintf(stderr, "Error: AudioDeviceCreateIOProcID failed (%d)\n",
                (int)err);
        close(server_fd);
        return 1;
    }

    err = AudioDeviceStart(device_id, ioproc_id);
    if (err != kAudioHardwareNoError) {
        fprintf(stderr, "Error: AudioDeviceStart failed (%d)\n", (int)err);
        AudioDeviceDestroyIOProcID(device_id, ioproc_id);
        close(server_fd);
        return 1;
    }

    fprintf(stderr, "Capturing from Line In...\n\n");

    /* Main run loop — drives CoreAudio callbacks */
    while (running)
        CFRunLoopRunInMode(kCFRunLoopDefaultMode, 0.25, false);

    /* ------------------------------------------------------------------
     * Cleanup
     * --------------------------------------------------------------- */
    fprintf(stderr, "\nShutting down...\n");

    AudioDeviceStop(device_id, ioproc_id);
    AudioDeviceDestroyIOProcID(device_id, ioproc_id);

    pthread_mutex_lock(&clients_mutex);
    int i;
    for (i = 0; i < MAX_CLIENTS; i++) {
        if (clients[i].active) {
            clients[i].active = 0;
            close(clients[i].fd);
        }
    }
    pthread_mutex_unlock(&clients_mutex);

    pthread_cond_broadcast(&data_cond);
    close(server_fd);
    usleep(200000);
    fprintf(stderr, "Done.\n");
    return 0;
}
