/*
 * ServerManager.m - Process manager for the PPC stream servers
 *
 * Launches audio_stream_server and itunes_server.py as child processes,
 * captures their combined stdout+stderr via NSPipe, and reads from the
 * pipes on detached background threads using raw POSIX read().
 *
 * The POSIX read() approach avoids deadlocks caused by NSFileHandle's
 * readInBackgroundAndNotify / availableData interacting badly with
 * NSApplication teardown on Mac OS X 10.5 Leopard.
 */

#import "ServerManager.h"
#import <signal.h>
#import <sys/wait.h>
#import <unistd.h>
#import <fcntl.h>

/* Global PIDs for the signal handler in main.m */
extern pid_t g_audioServerPid;
extern pid_t g_itunesServerPid;

@implementation ServerManager

@synthesize delegate;
@synthesize running;
@synthesize audioPort;
@synthesize itunesPort;

- (id)init
{
    self = [super init];
    if (self) {
        audioPort    = 7777;
        itunesPort   = 7778;
        audioReadFD  = -1;
        itunesReadFD = -1;
        running      = NO;
        stopping     = NO;
        audioTask    = nil;
        itunesTask   = nil;
    }
    return self;
}

- (void)dealloc
{
    [self stopServers];
    [super dealloc];
}

/* ── Background pipe reader thread ──────────────────────────────────── */

/*
 * Reads from a pipe's file descriptor using POSIX read() on a
 * background thread.  Sends each line of output to the delegate
 * on the main thread.  Exits on EOF or when `stopping` is set.
 *
 * Argument: NSDictionary with:
 *   @"fd"   -> NSNumber (int, the file descriptor to read)
 *   @"name" -> NSString (process name for the delegate)
 */
- (void)readPipeThread:(NSDictionary *)info
{
    NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];

    int fd = [[info objectForKey:@"fd"] intValue];
    NSString *name = [info objectForKey:@"name"];
    char buf[4096];

    while (!stopping) {
        ssize_t n = read(fd, buf, sizeof(buf) - 1);
        if (n <= 0) break;  /* EOF or error */

        buf[n] = '\0';

        NSAutoreleasePool *inner = [[NSAutoreleasePool alloc] init];
        NSString *text = [NSString stringWithUTF8String:buf];
        if (!text) {
            text = [[[NSString alloc]
                initWithBytes:buf length:n
                     encoding:NSASCIIStringEncoding] autorelease];
        }

        if (text && delegate && !stopping) {
            NSArray *lines = [text componentsSeparatedByString:@"\n"];
            NSEnumerator *e = [lines objectEnumerator];
            NSString *line;
            while ((line = [e nextObject])) {
                if ([line length] > 0) {
                    NSDictionary *msg = [[NSDictionary alloc]
                        initWithObjectsAndKeys:
                            line, @"line",
                            name, @"name",
                            nil];
                    [self performSelectorOnMainThread:@selector(deliverLog:)
                                          withObject:msg
                                       waitUntilDone:NO];
                    [msg release];
                }
            }
        }
        [inner drain];
    }

    close(fd);

    /* Notify delegate of process exit if we didn't initiate the stop */
    if (!stopping && delegate) {
        NSDictionary *msg = [[NSDictionary alloc]
            initWithObjectsAndKeys:name, @"name", nil];
        [self performSelectorOnMainThread:@selector(handleProcessExit:)
                               withObject:msg
                            waitUntilDone:NO];
        [msg release];
    }

    [pool drain];
}

/* Main-thread callbacks from the reader threads */

- (void)deliverLog:(NSDictionary *)info
{
    if (!delegate) return;
    NSString *line = [info objectForKey:@"line"];
    NSString *name = [info objectForKey:@"name"];
    [delegate serverManager:self didReceiveLog:line forProcess:name];
}

- (void)handleProcessExit:(NSDictionary *)info
{
    NSString *name = [info objectForKey:@"name"];
    int status = 0;

    if ([name isEqualToString:@"Audio Server"] && audioTask) {
        status = [audioTask terminationStatus];
    } else if ([name isEqualToString:@"iTunes Server"] && itunesTask) {
        status = [itunesTask terminationStatus];
    }

    if (delegate) {
        [delegate serverManager:self
            processDidTerminate:name
                     withStatus:status];
    }

    BOOL audioDead  = !audioTask  || ![audioTask isRunning];
    BOOL itunesDead = !itunesTask || ![itunesTask isRunning];
    if (audioDead && itunesDead) {
        running = NO;
    }
}

/* ── Start / Stop ───────────────────────────────────────────────────── */

- (BOOL)startServers
{
    if (running) return YES;

    stopping = NO;

    /*
     * Resolve server executables from the app bundle.
     * They live alongside the main binary in Contents/MacOS/.
     */
    NSString *macosDir = [[[NSBundle mainBundle] executablePath]
                            stringByDeletingLastPathComponent];
    NSString *audioBin = [macosDir stringByAppendingPathComponent:
                            @"audio_stream_server"];
    NSString *itunesScript = [macosDir stringByAppendingPathComponent:
                                @"itunes_server.py"];

    /* Preflight checks */
    NSFileManager *fm = [NSFileManager defaultManager];
    if (![fm fileExistsAtPath:audioBin]) {
        if (delegate) {
            [delegate serverManager:self
                     didReceiveLog:[NSString stringWithFormat:
                         @"ERROR: %@ not found. Run build.sh first.", audioBin]
                        forProcess:@"Audio Server"];
        }
        return NO;
    }
    if (![fm fileExistsAtPath:itunesScript]) {
        if (delegate) {
            [delegate serverManager:self
                     didReceiveLog:[NSString stringWithFormat:
                         @"ERROR: %@ not found.", itunesScript]
                        forProcess:@"iTunes Server"];
        }
        return NO;
    }

    /* ── Launch audio_stream_server ──────────────────────────────── */
    audioPipe = [[NSPipe pipe] retain];
    audioTask = [[NSTask alloc] init];
    [audioTask setLaunchPath:audioBin];
    [audioTask setArguments:[NSArray arrayWithObject:
        [NSString stringWithFormat:@"%d", audioPort]]];
    [audioTask setCurrentDirectoryPath:macosDir];
    [audioTask setStandardOutput:audioPipe];
    [audioTask setStandardError:audioPipe];

    /* ── Launch itunes_server.py ─────────────────────────────────── */
    itunesPipe = [[NSPipe pipe] retain];
    itunesTask = [[NSTask alloc] init];
    [itunesTask setLaunchPath:@"/usr/bin/python"];
    [itunesTask setArguments:[NSArray arrayWithObjects:
        itunesScript,
        [NSString stringWithFormat:@"%d", itunesPort],
        nil]];
    [itunesTask setCurrentDirectoryPath:macosDir];
    [itunesTask setStandardOutput:itunesPipe];
    [itunesTask setStandardError:itunesPipe];

    /* ── Launch both processes ───────────────────────────────────── */
    @try {
        [audioTask launch];
    }
    @catch (NSException *ex) {
        if (delegate) {
            [delegate serverManager:self
                     didReceiveLog:[NSString stringWithFormat:
                         @"ERROR: Failed to launch audio server: %@", [ex reason]]
                        forProcess:@"Audio Server"];
        }
        return NO;
    }

    @try {
        [itunesTask launch];
    }
    @catch (NSException *ex) {
        if (delegate) {
            [delegate serverManager:self
                     didReceiveLog:[NSString stringWithFormat:
                         @"ERROR: Failed to launch iTunes server: %@", [ex reason]]
                        forProcess:@"iTunes Server"];
        }
        kill([audioTask processIdentifier], SIGTERM);
        return NO;
    }

    /*
     * Grab the raw file descriptors from the pipe read-ends and
     * dup() them so we own them independently of the NSPipe objects.
     * This way the background reader threads can operate purely on
     * POSIX FDs, avoiding NSFileHandle deadlocks during teardown.
     */
    audioReadFD  = dup([[audioPipe fileHandleForReading] fileDescriptor]);
    itunesReadFD = dup([[itunesPipe fileHandleForReading] fileDescriptor]);

    /* Update global PIDs for the signal handler in main.m */
    g_audioServerPid  = [audioTask processIdentifier];
    g_itunesServerPid = [itunesTask processIdentifier];

    /* Start background reader threads */
    NSDictionary *audioInfo = [NSDictionary dictionaryWithObjectsAndKeys:
        [NSNumber numberWithInt:audioReadFD], @"fd",
        @"Audio Server", @"name",
        nil];
    [NSThread detachNewThreadSelector:@selector(readPipeThread:)
                             toTarget:self
                           withObject:audioInfo];

    NSDictionary *itunesInfo = [NSDictionary dictionaryWithObjectsAndKeys:
        [NSNumber numberWithInt:itunesReadFD], @"fd",
        @"iTunes Server", @"name",
        nil];
    [NSThread detachNewThreadSelector:@selector(readPipeThread:)
                             toTarget:self
                           withObject:itunesInfo];

    running = YES;
    return YES;
}

- (void)stopServers
{
    if (!running) return;

    /* Signal reader threads to stop */
    stopping = YES;

    /*
     * Kill the child processes FIRST.  This closes the pipe write-ends
     * (held by the children), which causes the background reader
     * threads' read() calls to return 0 (EOF) and exit cleanly.
     *
     * IMPORTANT: Do NOT close the dup'd read FDs before this point!
     * On Leopard's kernel, close() on a pipe FD blocks in
     * fileproc_drain() if another thread is blocked in read() on
     * the same FD.  We must unblock the readers by killing the
     * writers (child processes) first.
     */
    pid_t audioPid  = 0;
    pid_t itunesPid = 0;

    if (audioTask && [audioTask isRunning]) {
        audioPid = [audioTask processIdentifier];
    }
    if (itunesTask && [itunesTask isRunning]) {
        itunesPid = [itunesTask processIdentifier];
    }

    if (audioPid > 0)  kill(audioPid, SIGKILL);
    if (itunesPid > 0) kill(itunesPid, SIGKILL);

    /* Reap zombies (WNOHANG — NSTask's SIGCHLD handler may have already reaped) */
    if (audioPid > 0)  waitpid(audioPid, NULL, WNOHANG);
    if (itunesPid > 0) waitpid(itunesPid, NULL, WNOHANG);

    /*
     * Do NOT close the dup'd read FDs here.  The reader threads will
     * see EOF (from the dead children's pipe write-ends closing) and
     * call close(fd) themselves.  Closing from the main thread while
     * a reader is blocked in read() causes close() to block in
     * Leopard's kernel (fileproc_drain deadlock).
     */
    audioReadFD  = -1;
    itunesReadFD = -1;

    /* Clear global PIDs so the signal handler doesn't try to kill stale PIDs */
    g_audioServerPid  = 0;
    g_itunesServerPid = 0;

    [audioTask release];
    audioTask = nil;
    [audioPipe release];
    audioPipe = nil;

    [itunesTask release];
    itunesTask = nil;
    [itunesPipe release];
    itunesPipe = nil;

    running = NO;
}

@end
