/*
 * ServerManager.h - Process manager for audio_stream_server and itunes_server.py
 *
 * Wraps NSTask to launch, monitor, and collect log output from each
 * server process.  The server executables are expected to be embedded
 * in the app bundle's Contents/MacOS directory.  Reads stdout+stderr
 * on background threads and forwards log lines to the delegate on
 * the main thread.
 */

#import <Cocoa/Cocoa.h>

@class ServerManager;

@protocol ServerManagerDelegate <NSObject>
- (void)serverManager:(ServerManager *)mgr
       didReceiveLog:(NSString *)line
          forProcess:(NSString *)processName;
- (void)serverManager:(ServerManager *)mgr
   processDidTerminate:(NSString *)processName
            withStatus:(int)status;
@end

@interface ServerManager : NSObject
{
    NSTask   *audioTask;
    NSTask   *itunesTask;
    NSPipe   *audioPipe;
    NSPipe   *itunesPipe;
    int       audioPort;
    int       itunesPort;
    int       audioReadFD;       /* dup'd FD for audio pipe reader thread */
    int       itunesReadFD;      /* dup'd FD for itunes pipe reader thread */
    BOOL      running;
    BOOL      stopping;          /* flag to tell reader threads to exit */
    id <ServerManagerDelegate> delegate;
}

@property (assign) id <ServerManagerDelegate> delegate;
@property (readonly) BOOL running;
@property (assign) int audioPort;
@property (assign) int itunesPort;

- (id)init;
- (BOOL)startServers;
- (void)stopServers;

@end
