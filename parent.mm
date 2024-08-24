#import <Cocoa/Cocoa.h>
#include <CoreGraphics/CoreGraphics.h>
#include <sys/cdefs.h>
#include <Foundation/Foundation.h>
#import <QuartzCore/QuartzCore.h>
#import <IOSurface/IOSurface.h>
#import <mach/mach.h>

#include <stdlib.h>
#include <stdio.h>
#include <unistd.h>
#include <spawn.h>
#include <sys/socket.h>
#include <fcntl.h>
#include <signal.h>
#include <string.h>
#include <CoreFoundation/CoreFoundation.h>

#include <mach/mach.h>
#include <servers/bootstrap.h>
#include <dispatch/dispatch.h>
#include "./message-structures.h"


#define PORT_NAME "com.example.messageport"
@class AppDelegate;

void parentCallback(CFMachPortRef port, void *msg, CFIndex size, void *info);

@interface AppDelegate : NSObject <NSApplicationDelegate, CALayerDelegate>
@property (strong, nonatomic) NSWindow *window;
@property (strong, nonatomic) CALayer *rootLayer;
@property (strong, nonatomic) CALayer *hostingLayer;
@property (strong, nonatomic) NSMutableArray<id>* surfaces;
@property (nonatomic) int currentSurfaceIndex;

@end

@implementation AppDelegate

- (void)applicationDidFinishLaunching:(NSNotification *)aNotification
{
    self.surfaces = [NSMutableArray arrayWithCapacity:2];
    self.currentSurfaceIndex = 0;

    NSRect frame = NSMakeRect(100, 100, 300, 300);
    self.window = [[NSWindow alloc] initWithContentRect:frame
                                              styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable | NSWindowStyleMaskMiniaturizable | NSWindowStyleMaskResizable
                                                backing:NSBackingStoreBuffered
                                                  defer:YES];
    self.window.title = @"Parent";
    NSView *contentView = [[NSView alloc] initWithFrame:self.window.contentView.frame];
    contentView.layerContentsRedrawPolicy = NSViewLayerContentsRedrawOnSetNeedsDisplay;
    self.window.contentView = contentView;
    [self.window.contentView setWantsLayer:YES];
    [self.window makeKeyAndOrderFront:nil];

    self.rootLayer = self.window.contentView.layer;//[CALayer layer];
    self.rootLayer.contentsScale = 2;
    self.rootLayer.frame = self.window.contentView.bounds;
    [self.window.contentView setLayer:self.rootLayer];

    self.hostingLayer = [CALayer layer];
    self.hostingLayer.delegate = self;
    self.hostingLayer.bounds = self.window.contentView.bounds;
    self.hostingLayer.backgroundColor = [NSColor purpleColor].CGColor;
    self.hostingLayer.position = CGPointMake(
        CGRectGetWidth(self.window.contentView.bounds) / 2.,
        CGRectGetHeight(self.window.contentView.bounds) / 2.);
    [self.rootLayer addSublayer:self.hostingLayer];

    [self setupMachPort];
    [self spawnChildProcess];
}

- (id<CAAction>)actionForLayer:(CALayer *)theLayer
                        forKey:(NSString *)theKey
{
    return [NSNull null];
}

- (void)gotSurface:(IOSurfaceRef)surface forIndex:(int)index
{
    self.surfaces[index] = (__bridge id _Nullable)surface;
}

- (void)updateToSurfaceIndex:(int)index
{
    [CATransaction begin];
    self.hostingLayer.contents = self.surfaces[index];
    [CATransaction commit];
}

- (void)setupMachPort
{
    CFMachPortContext context = {0, (__bridge void*)self, NULL, NULL, NULL};
    Boolean shouldFreeInfo;

    mach_port_t parentPort = MACH_PORT_NULL;    
    mach_port_t bootstrapPort = MACH_PORT_NULL;
    task_get_bootstrap_port(mach_task_self(), &bootstrapPort);
    kern_return_t kr = bootstrap_check_in(bootstrapPort, 
                                        (char *)PORT_NAME,
                                        &parentPort);
    if (kr != KERN_SUCCESS)
    {
        NSLog(@"Failed to register Mach port with bootstrap. Error: %d", kr);
        return;
    }
    CFMachPortRef parentPortCF = CFMachPortCreateWithPort(NULL, parentPort, parentCallback, &context, &shouldFreeInfo);
    CFRunLoopSourceRef runLoopSource = CFMachPortCreateRunLoopSource(NULL, parentPortCF, 0);

    if (!runLoopSource)
    {
        NSLog(@"Failed to create run loop source");
        return;
    }

    CFRunLoopAddSource(CFRunLoopGetCurrent(), runLoopSource, kCFRunLoopCommonModes);
    CFRelease(runLoopSource);
}

- (void)spawnChildProcess
{
    pid_t pid;
    int status;
    char *envp[0];
    envp[0] = NULL;

    status = posix_spawn(&pid, "./ChildProcess", NULL, NULL, (char*[]){NULL}, envp);
    if (status != 0)
    {
        printf("posix_spawn: %s\n", strerror(status));
        return;
    }
}

@end

int main(int, const char *[])
{
    @autoreleasepool
    {
        NSApplication *application = [NSApplication sharedApplication];
        AppDelegate *delegate = [[AppDelegate alloc] init];
        [application setDelegate:delegate];
        [application run];
    }
    return 0;
}

void parentCallback(__unused CFMachPortRef port, void *msgData, __unused CFIndex size, void *info)
{
    AppDelegate *appDelegate = (__bridge AppDelegate *)info;
    mach_msg_header_t *messageHeader = (mach_msg_header_t *)msgData;

    NSLog(@"Received message:");
    NSLog(@"  msgh_bits: 0x%x", messageHeader->msgh_bits);
    NSLog(@"  msgh_size: %u", messageHeader->msgh_size);
    NSLog(@"  msgh_remote_port: %d", messageHeader->msgh_remote_port);
    NSLog(@"  msgh_local_port: %d", messageHeader->msgh_local_port);
    NSLog(@"  msgh_id: %d", messageHeader->msgh_id);

    if (messageHeader->msgh_id == 1000)
    {
        // handle setup message:

        if (!(messageHeader->msgh_bits & MACH_MSGH_BITS_COMPLEX))
        {
            NSLog(@"Received message is not complex");
            return;
        }
        MachIOSurfaceSetupMessage *message = (MachIOSurfaceSetupMessage *)msgData;

        mach_msg_body_t *body = &message->body;
        if (body->msgh_descriptor_count != 2)
        {
            NSLog(@"Received message does not have `2` descriptor count as expected.");
            return;
        }

        for (uint i = 0; i < body->msgh_descriptor_count; i++)
        {
            mach_msg_port_descriptor_t *portDescriptor = &message->port_descriptors[i];
            mach_port_t receivedPort = portDescriptor->name;
            NSLog(@"Received Mach port: %d", receivedPort);

            IOSurfaceRef receivedSurface = IOSurfaceLookupFromMachPort(receivedPort);
            if (receivedSurface)
                [appDelegate gotSurface:receivedSurface forIndex:i];
            else
            {
                NSLog(@"Failed to create IOSurface from received port");
                mach_port_type_t type;
                kern_return_t kr = mach_port_type(mach_task_self(), receivedPort, &type);
                if (kr == KERN_SUCCESS)
                    NSLog(@"Port type: %u", type);
                    // MACH_PORT_TYPE_SEND should be set
                else
                    NSLog(@"Failed to get port type. Error: %d (%s)", kr, mach_error_string(kr));
            }
        }
    }
    else if (messageHeader->msgh_id == 2000)
    {
        // update message
        MachIOSurfaceSwapMessage *message = (MachIOSurfaceSwapMessage *)msgData;
        [appDelegate updateToSurfaceIndex:message->surfaceIndex];
    }

    

    // Clean up the received Mach port if you're done with it
    // mach_port_deallocate(mach_task_self(), receivedPort);
}
