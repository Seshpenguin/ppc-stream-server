/*
 * main.m - PPC Stream Server Manager
 *
 * Entry point for the Cocoa GUI server management app.
 * Builds the NSApplication and main menu programmatically
 * (no NIB required).
 */

#import <Cocoa/Cocoa.h>
#import <signal.h>
#import <string.h>
#import <sys/wait.h>
#import <unistd.h>
#import "AppDelegate.h"

/*
 * Global child PIDs for the signal handler.
 * Set by ServerManager when processes are launched.
 */
pid_t g_audioServerPid  = 0;
pid_t g_itunesServerPid = 0;

static void cleanup_and_exit(int sig)
{
    /*
     * Kill children immediately with SIGKILL (async-signal-safe).
     * No SIGTERM + usleep dance — these servers hold no persistent
     * state, and avoiding the sleep prevents signal handler hangs.
     */
    if (g_audioServerPid > 0)  kill(g_audioServerPid, SIGKILL);
    if (g_itunesServerPid > 0) kill(g_itunesServerPid, SIGKILL);
    _exit(0);
}

int main(int argc, const char *argv[])
{
    NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];

    [NSApplication sharedApplication];

    /*
     * Install signal handlers AFTER creating NSApplication.
     * NSApplication's init may install its own handlers, so we
     * override them here.  Use sigaction for reliability.
     */
    struct sigaction sa;
    memset(&sa, 0, sizeof(sa));
    sa.sa_handler = cleanup_and_exit;
    sigemptyset(&sa.sa_mask);
    sa.sa_flags = 0;
    sigaction(SIGTERM, &sa, NULL);
    sigaction(SIGINT,  &sa, NULL);
    sigaction(SIGHUP,  &sa, NULL);

    /* ── Build the main menu bar ─────────────────────────────────── */

    NSMenu *mainMenu = [[[NSMenu alloc] initWithTitle:@"MainMenu"] autorelease];

    /* -- Application menu -- */
    NSMenuItem *appMenuItem = [[[NSMenuItem alloc] initWithTitle:@""
                                                         action:nil
                                                  keyEquivalent:@""] autorelease];
    [mainMenu addItem:appMenuItem];

    NSMenu *appMenu = [[[NSMenu alloc] initWithTitle:@"PPC Stream Server"] autorelease];
    [appMenu addItemWithTitle:@"About PPC Stream Server"
                       action:@selector(orderFrontStandardAboutPanel:)
                keyEquivalent:@""];
    [appMenu addItem:[NSMenuItem separatorItem]];
    [appMenu addItemWithTitle:@"Quit PPC Stream Server"
                       action:@selector(quitApp:)
                keyEquivalent:@"q"];
    [appMenuItem setSubmenu:appMenu];

    /* -- Window menu -- */
    NSMenuItem *windowMenuItem = [[[NSMenuItem alloc] initWithTitle:@""
                                                            action:nil
                                                     keyEquivalent:@""] autorelease];
    [mainMenu addItem:windowMenuItem];

    NSMenu *windowMenu = [[[NSMenu alloc] initWithTitle:@"Window"] autorelease];
    [windowMenu addItemWithTitle:@"Minimize"
                          action:@selector(performMiniaturize:)
                   keyEquivalent:@"m"];
    [windowMenu addItemWithTitle:@"Close"
                          action:@selector(performClose:)
                   keyEquivalent:@"w"];
    [windowMenuItem setSubmenu:windowMenu];

    [NSApp setMainMenu:mainMenu];
    [NSApp setWindowsMenu:windowMenu];

    /* ── Set up the delegate and run ─────────────────────────────── */

    AppDelegate *delegate = [[AppDelegate alloc] init];
    [NSApp setDelegate:delegate];
    [NSApp run];

    [pool drain];
    return 0;
}
