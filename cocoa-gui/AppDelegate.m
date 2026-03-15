/*
 * AppDelegate.m - PPC Stream Server Manager
 *
 * Builds the entire window and control layout programmatically in a
 * style consistent with Mac OS X 10.5 Leopard Server admin tools:
 *
 *  - Textured (brushed-metal) window
 *  - Status section with green/red dots and service names
 *  - Start / Stop buttons
 *  - Tabbed log viewer for Audio Server and iTunes Server output
 *
 * The servers are auto-started on launch.
 */

#import "AppDelegate.h"

/* Maximum lines to keep in each log view before trimming */
#define LOG_MAX_LINES 2000
#define LOG_TRIM_LINES 500

@implementation AppDelegate

/* ── Helpers ────────────────────────────────────────────────────────── */

/*
 * Create a non-editable label with the given string and font size.
 */
- (NSTextField *)labelWithString:(NSString *)str
                        fontSize:(float)size
                            bold:(BOOL)bold
{
    NSTextField *label = [[[NSTextField alloc]
                            initWithFrame:NSZeroRect] autorelease];
    [label setStringValue:str];
    [label setEditable:NO];
    [label setSelectable:NO];
    [label setBezeled:NO];
    [label setDrawsBackground:NO];
    if (bold) {
        [label setFont:[NSFont boldSystemFontOfSize:size]];
    } else {
        [label setFont:[NSFont systemFontOfSize:size]];
    }
    [label sizeToFit];
    return label;
}

/*
 * Create a small colored circle image for status indication.
 * green = running, red = stopped, gray = unknown.
 */
- (NSImage *)statusDotWithColor:(NSColor *)color
{
    NSImage *img = [[[NSImage alloc] initWithSize:NSMakeSize(12, 12)] autorelease];
    [img lockFocus];
    [color set];
    NSBezierPath *dot = [NSBezierPath bezierPathWithOvalInRect:
                            NSMakeRect(1, 1, 10, 10)];
    [dot fill];
    [[NSColor colorWithCalibratedWhite:0.3 alpha:0.5] set];
    [dot setLineWidth:0.5];
    [dot stroke];
    [img unlockFocus];
    return img;
}

/*
 * Create a scrollable text view suitable for log output.
 */
- (NSScrollView *)logScrollViewWithFrame:(NSRect)frame
                                textView:(NSTextView **)outTV
{
    NSScrollView *sv = [[[NSScrollView alloc] initWithFrame:frame] autorelease];
    [sv setHasVerticalScroller:YES];
    [sv setHasHorizontalScroller:NO];
    [sv setAutoresizingMask:NSViewWidthSizable | NSViewHeightSizable];
    [sv setBorderType:NSBezelBorder];

    NSSize contentSize = [sv contentSize];
    NSTextView *tv = [[[NSTextView alloc]
                        initWithFrame:NSMakeRect(0, 0,
                            contentSize.width, contentSize.height)] autorelease];
    [tv setMinSize:NSMakeSize(0, contentSize.height)];
    [tv setMaxSize:NSMakeSize(FLT_MAX, FLT_MAX)];
    [tv setVerticallyResizable:YES];
    [tv setHorizontallyResizable:NO];
    [tv setAutoresizingMask:NSViewWidthSizable];
    [[tv textContainer] setContainerSize:
        NSMakeSize(contentSize.width, FLT_MAX)];
    [[tv textContainer] setWidthTracksTextView:YES];

    [tv setEditable:NO];
    [tv setSelectable:YES];
    [tv setFont:[NSFont fontWithName:@"Monaco" size:10.0]];
    [tv setBackgroundColor:[NSColor colorWithCalibratedWhite:0.13 alpha:1.0]];
    [tv setTextColor:[NSColor colorWithCalibratedRed:0.0
                                               green:0.9
                                                blue:0.0
                                               alpha:1.0]];

    [sv setDocumentView:tv];
    *outTV = tv;
    return sv;
}

/* ── Build the UI ───────────────────────────────────────────────────── */

- (void)buildUI
{
    /* ── Main window: textured (brushed metal) to match Leopard Server ── */
    NSRect frame = NSMakeRect(200, 200, 680, 560);
    unsigned int styleMask = NSTitledWindowMask
                           | NSClosableWindowMask
                           | NSMiniaturizableWindowMask
                           | NSResizableWindowMask
                           | NSTexturedBackgroundWindowMask;

    window = [[NSWindow alloc] initWithContentRect:frame
                                         styleMask:styleMask
                                           backing:NSBackingStoreBuffered
                                             defer:NO];
    [window setTitle:@"PPC Stream Server"];
    [window setMinSize:NSMakeSize(520, 440)];

    NSView *content = [window contentView];

    float yPos = [content bounds].size.height;
    float xPad = 20.0;
    float contentWidth = [content bounds].size.width - 2 * xPad;

    /* ── Title ──────────────────────────────────────────────────────── */
    yPos -= 35;
    NSTextField *title = [self labelWithString:@"PPC Stream Server"
                                     fontSize:18.0
                                         bold:YES];
    [title setFrame:NSMakeRect(xPad, yPos, contentWidth, 24)];
    [title setAutoresizingMask:NSViewWidthSizable | NSViewMinYMargin];
    [content addSubview:title];

    yPos -= 20;
    NSTextField *subtitle = [self labelWithString:
        @"Audio streaming and iTunes control server management"
                                         fontSize:11.0
                                             bold:NO];
    [subtitle setTextColor:[NSColor grayColor]];
    [subtitle setFrame:NSMakeRect(xPad, yPos, contentWidth, 16)];
    [subtitle setAutoresizingMask:NSViewWidthSizable | NSViewMinYMargin];
    [content addSubview:subtitle];

    /* ── Separator ──────────────────────────────────────────────────── */
    yPos -= 12;
    NSBox *sep1 = [[[NSBox alloc] initWithFrame:
                        NSMakeRect(xPad, yPos, contentWidth, 1)] autorelease];
    [sep1 setBoxType:NSBoxSeparator];
    [sep1 setAutoresizingMask:NSViewWidthSizable | NSViewMinYMargin];
    [content addSubview:sep1];

    /* ── Service Status section ─────────────────────────────────────── */
    yPos -= 28;
    NSTextField *statusHeader = [self labelWithString:@"Services"
                                             fontSize:13.0
                                                 bold:YES];
    [statusHeader setFrame:NSMakeRect(xPad, yPos, 200, 18)];
    [statusHeader setAutoresizingMask:NSViewMinYMargin];
    [content addSubview:statusHeader];

    /* Audio Server status row */
    yPos -= 24;
    audioStatusIcon = [[NSImageView alloc]
                        initWithFrame:NSMakeRect(xPad + 10, yPos, 12, 12)];
    [audioStatusIcon setImage:[self statusDotWithColor:[NSColor grayColor]]];
    [audioStatusIcon setAutoresizingMask:NSViewMinYMargin];
    [content addSubview:audioStatusIcon];

    audioStatusLabel = [[self labelWithString:@"Audio Stream Server (port 7777) — Stopped"
                                    fontSize:11.0
                                        bold:NO] retain];
    [audioStatusLabel setFrame:NSMakeRect(xPad + 30, yPos - 1, 400, 16)];
    [audioStatusLabel setAutoresizingMask:NSViewMinYMargin];
    [content addSubview:audioStatusLabel];

    /* iTunes Server status row */
    yPos -= 20;
    itunesStatusIcon = [[NSImageView alloc]
                         initWithFrame:NSMakeRect(xPad + 10, yPos, 12, 12)];
    [itunesStatusIcon setImage:[self statusDotWithColor:[NSColor grayColor]]];
    [itunesStatusIcon setAutoresizingMask:NSViewMinYMargin];
    [content addSubview:itunesStatusIcon];

    itunesStatusLabel = [[self labelWithString:@"iTunes Control Server (port 7778) — Stopped"
                                     fontSize:11.0
                                         bold:NO] retain];
    [itunesStatusLabel setFrame:NSMakeRect(xPad + 30, yPos - 1, 400, 16)];
    [itunesStatusLabel setAutoresizingMask:NSViewMinYMargin];
    [content addSubview:itunesStatusLabel];

    /* Overall status */
    yPos -= 24;
    overallStatusLabel = [[self labelWithString:@"Status: Stopped"
                                      fontSize:12.0
                                          bold:YES] retain];
    [overallStatusLabel setTextColor:[NSColor colorWithCalibratedRed:0.7
                                                              green:0.0
                                                               blue:0.0
                                                              alpha:1.0]];
    [overallStatusLabel setFrame:NSMakeRect(xPad + 10, yPos, 300, 16)];
    [overallStatusLabel setAutoresizingMask:NSViewMinYMargin];
    [content addSubview:overallStatusLabel];

    /* ── Start / Stop buttons ───────────────────────────────────────── */
    yPos -= 6;
    float btnWidth = 100.0;
    float btnHeight = 32.0;
    float btnY = yPos - btnHeight;

    startButton = [[NSButton alloc]
                    initWithFrame:NSMakeRect(xPad + 10, btnY,
                                             btnWidth, btnHeight)];
    [startButton setTitle:@"Start"];
    [startButton setBezelStyle:NSRoundedBezelStyle];
    [startButton setTarget:self];
    [startButton setAction:@selector(startServers:)];
    [startButton setAutoresizingMask:NSViewMinYMargin];
    [content addSubview:startButton];

    stopButton = [[NSButton alloc]
                   initWithFrame:NSMakeRect(xPad + 10 + btnWidth + 10, btnY,
                                            btnWidth, btnHeight)];
    [stopButton setTitle:@"Stop"];
    [stopButton setBezelStyle:NSRoundedBezelStyle];
    [stopButton setTarget:self];
    [stopButton setAction:@selector(stopServers:)];
    [stopButton setEnabled:NO];
    [stopButton setAutoresizingMask:NSViewMinYMargin];
    [content addSubview:stopButton];

    yPos = btnY;

    /* ── Separator ──────────────────────────────────────────────────── */
    yPos -= 12;
    NSBox *sep2 = [[[NSBox alloc] initWithFrame:
                        NSMakeRect(xPad, yPos, contentWidth, 1)] autorelease];
    [sep2 setBoxType:NSBoxSeparator];
    [sep2 setAutoresizingMask:NSViewWidthSizable | NSViewMinYMargin];
    [content addSubview:sep2];

    /* ── Log section with tab view ──────────────────────────────────── */
    yPos -= 10;
    NSTextField *logHeader = [self labelWithString:@"Server Logs"
                                          fontSize:13.0
                                              bold:YES];
    [logHeader setFrame:NSMakeRect(xPad, yPos - 18, 200, 18)];
    [logHeader setAutoresizingMask:NSViewWidthSizable | NSViewMinYMargin];
    [content addSubview:logHeader];

    yPos -= 28;

    /* Tab view for the two logs */
    float logHeight = yPos - 10;
    NSTabView *tabView = [[[NSTabView alloc]
                            initWithFrame:NSMakeRect(xPad, 10,
                                contentWidth, logHeight)] autorelease];
    [tabView setAutoresizingMask:NSViewWidthSizable | NSViewHeightSizable];

    /* -- Audio Server log tab -- */
    NSTabViewItem *audioTab = [[[NSTabViewItem alloc]
                                 initWithIdentifier:@"audio"] autorelease];
    [audioTab setLabel:@"Audio Server"];

    NSView *audioTabContent = [audioTab view];
    NSScrollView *audioSV = [self logScrollViewWithFrame:
                                [audioTabContent bounds]
                                            textView:&audioLogView];
    [audioLogView retain];
    [audioSV setAutoresizingMask:NSViewWidthSizable | NSViewHeightSizable];
    [audioTabContent addSubview:audioSV];
    [tabView addTabViewItem:audioTab];

    /* -- iTunes Server log tab -- */
    NSTabViewItem *itunesTab = [[[NSTabViewItem alloc]
                                  initWithIdentifier:@"itunes"] autorelease];
    [itunesTab setLabel:@"iTunes Server"];

    NSView *itunesTabContent = [itunesTab view];
    NSScrollView *itunesSV = [self logScrollViewWithFrame:
                                [itunesTabContent bounds]
                                             textView:&itunesLogView];
    [itunesLogView retain];
    [itunesSV setAutoresizingMask:NSViewWidthSizable | NSViewHeightSizable];
    [itunesTabContent addSubview:itunesSV];
    [tabView addTabViewItem:itunesTab];

    [content addSubview:tabView];
}

/* ── Update status indicators ───────────────────────────────────────── */

- (void)updateUIForRunning:(BOOL)isRunning
{
    NSImage *greenDot = [self statusDotWithColor:
                            [NSColor colorWithCalibratedRed:0.0
                                                     green:0.75
                                                      blue:0.0
                                                     alpha:1.0]];
    NSImage *redDot = [self statusDotWithColor:[NSColor redColor]];
    NSImage *grayDot = [self statusDotWithColor:[NSColor grayColor]];

    if (isRunning) {
        [audioStatusIcon setImage:greenDot];
        [itunesStatusIcon setImage:greenDot];
        [audioStatusLabel setStringValue:
            [NSString stringWithFormat:
                @"Audio Stream Server (port %d) — Running",
                [serverManager audioPort]]];
        [itunesStatusLabel setStringValue:
            [NSString stringWithFormat:
                @"iTunes Control Server (port %d) — Running",
                [serverManager itunesPort]]];
        [overallStatusLabel setStringValue:@"Status: Running"];
        [overallStatusLabel setTextColor:
            [NSColor colorWithCalibratedRed:0.0
                                      green:0.6
                                       blue:0.0
                                      alpha:1.0]];
        [startButton setEnabled:NO];
        [stopButton setEnabled:YES];
    } else {
        [audioStatusIcon setImage:grayDot];
        [itunesStatusIcon setImage:grayDot];
        [audioStatusLabel setStringValue:
            [NSString stringWithFormat:
                @"Audio Stream Server (port %d) — Stopped",
                [serverManager audioPort]]];
        [itunesStatusLabel setStringValue:
            [NSString stringWithFormat:
                @"iTunes Control Server (port %d) — Stopped",
                [serverManager itunesPort]]];
        [overallStatusLabel setStringValue:@"Status: Stopped"];
        [overallStatusLabel setTextColor:
            [NSColor colorWithCalibratedRed:0.7
                                      green:0.0
                                       blue:0.0
                                      alpha:1.0]];
        [startButton setEnabled:YES];
        [stopButton setEnabled:NO];
    }
}

/* Mark a single service as terminated in the status display */
- (void)markServiceStopped:(NSString *)processName withStatus:(int)status
{
    NSImage *redDot = [self statusDotWithColor:[NSColor redColor]];
    NSString *suffix;
    if (status == 0) {
        suffix = @"Exited normally";
    } else if (status == 15) {
        suffix = @"Stopped";
    } else {
        suffix = [NSString stringWithFormat:@"Exited (code %d)", status];
    }

    if ([processName isEqualToString:@"Audio Server"]) {
        [audioStatusIcon setImage:redDot];
        [audioStatusLabel setStringValue:
            [NSString stringWithFormat:@"Audio Stream Server (port %d) — %@",
                [serverManager audioPort], suffix]];
    } else if ([processName isEqualToString:@"iTunes Server"]) {
        [itunesStatusIcon setImage:redDot];
        [itunesStatusLabel setStringValue:
            [NSString stringWithFormat:@"iTunes Control Server (port %d) — %@",
                [serverManager itunesPort], suffix]];
    }
}

/* ── Append a line to a log view (on main thread) ───────────────────── */

- (void)appendLog:(NSString *)text toView:(NSTextView *)tv
{
    if (!tv) return;

    /* Timestamp each line */
    NSDateFormatter *df = [[[NSDateFormatter alloc] init] autorelease];
    [df setDateFormat:@"HH:mm:ss"];
    NSString *ts = [df stringFromDate:[NSDate date]];
    NSString *line = [NSString stringWithFormat:@"[%@] %@\n", ts, text];

    NSAttributedString *attrLine = [[[NSAttributedString alloc]
        initWithString:line
            attributes:[NSDictionary dictionaryWithObjectsAndKeys:
                [NSFont fontWithName:@"Monaco" size:10.0], NSFontAttributeName,
                [tv textColor], NSForegroundColorAttributeName,
                nil]] autorelease];

    [[tv textStorage] appendAttributedString:attrLine];

    /* Trim if too many lines */
    NSString *allText = [[tv textStorage] string];
    unsigned int lineCount = 0;
    unsigned int i;
    for (i = 0; i < [allText length]; i++) {
        if ([allText characterAtIndex:i] == '\n') lineCount++;
    }
    if (lineCount > LOG_MAX_LINES) {
        /* Find the position of the LOG_TRIM_LINES-th newline */
        unsigned int trimCount = 0;
        unsigned int trimPos = 0;
        for (trimPos = 0; trimPos < [allText length]; trimPos++) {
            if ([allText characterAtIndex:trimPos] == '\n') {
                trimCount++;
                if (trimCount >= LOG_TRIM_LINES) {
                    trimPos++;
                    break;
                }
            }
        }
        [[tv textStorage] deleteCharactersInRange:
            NSMakeRange(0, trimPos)];
    }

    /* Scroll to bottom */
    [tv scrollRangeToVisible:
        NSMakeRange([[tv string] length], 0)];
}

/* ── ServerManagerDelegate ──────────────────────────────────────────── */

- (void)serverManager:(ServerManager *)mgr
       didReceiveLog:(NSString *)line
          forProcess:(NSString *)processName
{
    /* This may be called from a background thread; bounce to main */
    NSTextView *targetView;
    if ([processName isEqualToString:@"Audio Server"]) {
        targetView = audioLogView;
    } else {
        targetView = itunesLogView;
    }

    NSDictionary *info = [NSDictionary dictionaryWithObjectsAndKeys:
        line, @"line",
        targetView, @"view",
        nil];

    [self performSelectorOnMainThread:@selector(appendLogFromDict:)
                           withObject:info
                        waitUntilDone:NO];
}

- (void)appendLogFromDict:(NSDictionary *)info
{
    NSString *line = [info objectForKey:@"line"];
    NSTextView *tv = [info objectForKey:@"view"];
    [self appendLog:line toView:tv];
}

- (void)serverManager:(ServerManager *)mgr
   processDidTerminate:(NSString *)processName
            withStatus:(int)status
{
    NSDictionary *info = [NSDictionary dictionaryWithObjectsAndKeys:
        processName, @"name",
        [NSNumber numberWithInt:status], @"status",
        nil];

    [self performSelectorOnMainThread:@selector(handleTerminationOnMain:)
                           withObject:info
                        waitUntilDone:NO];
}

- (void)handleTerminationOnMain:(NSDictionary *)info
{
    NSString *processName = [info objectForKey:@"name"];
    int status = [[info objectForKey:@"status"] intValue];

    NSString *msg = [NSString stringWithFormat:
        @"Process terminated with exit code %d", status];

    NSTextView *targetView;
    if ([processName isEqualToString:@"Audio Server"]) {
        targetView = audioLogView;
    } else {
        targetView = itunesLogView;
    }
    [self appendLog:msg toView:targetView];

    [self markServiceStopped:processName withStatus:status];

    /* If both are now dead, update overall status */
    if (![serverManager running]) {
        [self updateUIForRunning:NO];
    }
}

/* ── Actions ────────────────────────────────────────────────────────── */

- (IBAction)startServers:(id)sender
{
    [self appendLog:@"Starting servers..." toView:audioLogView];
    [self appendLog:@"Starting servers..." toView:itunesLogView];

    if ([serverManager startServers]) {
        [self updateUIForRunning:YES];
        [self appendLog:@"audio_stream_server launched." toView:audioLogView];
        [self appendLog:@"itunes_server.py launched." toView:itunesLogView];
    } else {
        [self appendLog:@"Failed to start servers." toView:audioLogView];
    }
}

- (IBAction)stopServers:(id)sender
{
    [self appendLog:@"Stopping servers..." toView:audioLogView];
    [self appendLog:@"Stopping servers..." toView:itunesLogView];

    [serverManager stopServers];

    [self updateUIForRunning:NO];
    [self appendLog:@"All servers stopped." toView:audioLogView];
    [self appendLog:@"All servers stopped." toView:itunesLogView];
}

/* ── App Delegate lifecycle ─────────────────────────────────────────── */

- (void)applicationDidFinishLaunching:(NSNotification *)note
{
    [self buildUI];

    serverManager = [[ServerManager alloc] init];
    [serverManager setDelegate:self];

    [window makeKeyAndOrderFront:nil];

    /* Auto-start servers on launch */
    [self startServers:nil];
}

/*
 * Custom quit handler that kills child processes and exits
 * immediately.  This avoids the Apple Event / run loop deadlock
 * that occurs on Leopard when detached threads are posting to
 * the main thread via performSelectorOnMainThread.
 */
- (IBAction)quitApp:(id)sender
{
    [serverManager stopServers];
    _exit(0);
}

- (void)applicationWillTerminate:(NSNotification *)note
{
    [serverManager stopServers];
}

- (BOOL)applicationShouldTerminateAfterLastWindowClosed:(NSApplication *)app
{
    /* Don't use NSApp terminate: — it deadlocks.  Instead, quit directly. */
    [self quitApp:nil];
    return NO;  /* not reached */
}

- (void)dealloc
{
    [audioStatusIcon release];
    [itunesStatusIcon release];
    [audioStatusLabel release];
    [itunesStatusLabel release];
    [overallStatusLabel release];
    [startButton release];
    [stopButton release];
    [audioLogView release];
    [itunesLogView release];
    [window release];
    [super dealloc];
}

@end
