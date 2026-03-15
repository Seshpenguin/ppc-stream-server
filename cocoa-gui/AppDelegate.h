/*
 * AppDelegate.h - PPC Stream Server Manager
 *
 * Main application delegate.  Builds the UI programmatically (no NIB)
 * and coordinates the ServerManager to start/stop the server processes.
 */

#import <Cocoa/Cocoa.h>
#import "ServerManager.h"

@interface AppDelegate : NSObject <ServerManagerDelegate>
{
    NSWindow       *window;
    ServerManager  *serverManager;

    /* Status area */
    NSImageView    *audioStatusIcon;
    NSImageView    *itunesStatusIcon;
    NSTextField    *audioStatusLabel;
    NSTextField    *itunesStatusLabel;
    NSTextField    *overallStatusLabel;

    /* Controls */
    NSButton       *startButton;
    NSButton       *stopButton;

    /* Log views */
    NSTextView     *audioLogView;
    NSTextView     *itunesLogView;
}

- (IBAction)startServers:(id)sender;
- (IBAction)stopServers:(id)sender;
- (IBAction)quitApp:(id)sender;

@end
