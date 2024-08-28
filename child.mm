#include <Cocoa/Cocoa.h>
#include <CoreFoundation/CoreFoundation.h>
#include <CoreGraphics/CoreGraphics.h>
#import <Foundation/Foundation.h>
#include <sys/_types/_mach_port_t.h>
#import <QuartzCore/QuartzCore.h>
#import <IOSurface/IOSurface.h>
#import <Metal/Metal.h>

#include <mach/mach.h>
#include <servers/bootstrap.h>

#include "./message-structures.h"


#define PORT_NAME "com.example.messageport"

static NSDictionary *optionsFor32BitSurface(CGSize size, unsigned pixelFormat)
{
    int width = size.width;
    int height = size.height;

    unsigned bytesPerElement = 4;
    unsigned bytesPerPixel = 4;

    size_t bytesPerRow = IOSurfaceAlignProperty(kIOSurfaceBytesPerRow, width * bytesPerPixel);

    size_t totalBytes = IOSurfaceAlignProperty(kIOSurfaceAllocSize, height * bytesPerRow);

    return @{
        (id)kIOSurfaceWidth: @(width),
        (id)kIOSurfaceHeight: @(height),
        (id)kIOSurfacePixelFormat: @(pixelFormat),
        (id)kIOSurfaceBytesPerElement: @(bytesPerElement),
        (id)kIOSurfaceBytesPerRow: @(bytesPerRow),
        (id)kIOSurfaceAllocSize: @(totalBytes),
        (id)kIOSurfaceElementHeight: @(1),
        (id)kIOSurfaceName: @"TestSurface"
    };
}

id<MTLTexture> textureFromSurface(IOSurfaceRef surface)
{
    // Create Metal texture descriptor
    MTLTextureDescriptor *textureDescriptor = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm
                                                                                                 width:IOSurfaceGetWidth(surface)
                                                                                                height:IOSurfaceGetHeight(surface)
                                                                                             mipmapped:NO];
    textureDescriptor.usage = MTLTextureUsageShaderRead | MTLTextureUsageRenderTarget;

    id<MTLDevice> device = MTLCreateSystemDefaultDevice();
    // Create Metal texture from IOSurface
    id<MTLTexture> texture = [device newTextureWithDescriptor:textureDescriptor
                                                   iosurface:surface
                                                       plane:0];
    
    if (!texture)
    {
        NSLog(@"Failed to create Metal texture from IOSurface");
        CFRelease(surface);
        return nil;
    }

    // Release IOSurface (Metal texture retains it)
    CFRelease(surface);
    
    return texture;
}

typedef struct
{
    CARenderer *renderer;
    IOSurfaceRef surfaces[2];
    id<MTLTexture> textures[2];
    int totalBuffers;
    int nextSurfaceIndex;
    mach_port_t remotePort;
} DoubleBuffer;

DoubleBuffer createDoubleBuffer(CGSize size, mach_port_t remotePort)
{
    DoubleBuffer buffer;
    buffer.totalBuffers = 2;
    buffer.nextSurfaceIndex = 0;
    buffer.remotePort = remotePort;

    NSDictionary *surfaceAttributes = optionsFor32BitSurface(size, 'BGRA');
    
    for (int i = 0; i < 2; i++)
    {
        IOSurfaceRef surface = IOSurfaceCreate((__bridge CFDictionaryRef)surfaceAttributes);
        buffer.surfaces[i] = surface;
        buffer.textures[i] = textureFromSurface(surface);
    }
    
    buffer.renderer = [CARenderer rendererWithMTLTexture:buffer.textures[0] options:nil];

    return buffer;
}


#import <CoreText/CoreText.h>

CALayer *makeLayers(CGSize bounds)
{
    // Create root layer
    CALayer *rootLayer = [CALayer layer];
    rootLayer.opacity = YES;
    rootLayer.backgroundColor = [NSColor whiteColor].CGColor;
    rootLayer.frame = (CGRect){.origin = CGPointMake(0, 0), .size = bounds};

    // Create and add a circle layer
    CAShapeLayer *circleLayer = [CAShapeLayer layer];
    circleLayer.frame = CGRectMake(50, 50, 100, 100);
    circleLayer.path = CGPathCreateWithEllipseInRect(circleLayer.bounds, NULL);
    circleLayer.fillColor = NSColor.blueColor.CGColor;
    [rootLayer addSublayer:circleLayer];
    
    // Create and add a rectangle layer
    CALayer *rectangleLayer = [CALayer layer];
    rectangleLayer.frame = CGRectMake(200, 100, 150, 100);
    rectangleLayer.backgroundColor = NSColor.redColor.CGColor;
    rectangleLayer.cornerRadius = 10;
    [rootLayer addSublayer:rectangleLayer];
    
    // Add rotation animation to rectangle layer
    CABasicAnimation *rotationAnimation = [CABasicAnimation animationWithKeyPath:@"transform.rotation.z"];
    rotationAnimation.toValue = @(2 * M_PI);
    rotationAnimation.duration = 2.0;
    rotationAnimation.repeatCount = HUGE_VALF;
    [rectangleLayer addAnimation:rotationAnimation forKey:@"rotationAnimation"];
    
    // Create and add a text layer
    CATextLayer *textLayer = [CATextLayer layer];
    textLayer.frame = CGRectMake(50, 100, 300, 50);
    textLayer.string = @"Hello, Core Animation!";
    textLayer.fontSize = 20;
    textLayer.contentsScale = [NSScreen mainScreen].backingScaleFactor;
    textLayer.alignmentMode = kCAAlignmentCenter;
    textLayer.foregroundColor = NSColor.blackColor.CGColor;
    [rootLayer addSublayer:textLayer];
    
    // Create and add a gradient layer
    CAGradientLayer *gradientLayer = [CAGradientLayer layer];
    gradientLayer.frame = CGRectMake(50, 150, 300, 50);
    gradientLayer.colors = @[
        (__bridge id)NSColor.greenColor.CGColor,
        (__bridge id)NSColor.yellowColor.CGColor
    ];
    gradientLayer.startPoint = CGPointMake(0, 0.5);
    gradientLayer.endPoint = CGPointMake(1, 0.5);
    [rootLayer addSublayer:gradientLayer];
    
    return rootLayer;
}

CALayer * debugView()
{
    // Make a layer tree and put it in a window so we can see what it looks like.
    CALayer *layer = makeLayers(CGSizeMake(300, 300));
    
    // NSRect frame = NSMakeRect(100, 500, 300, 300);
    // NSWindow *window = [[NSWindow alloc] initWithContentRect:frame
    //     styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable | NSWindowStyleMaskMiniaturizable | NSWindowStyleMaskResizable
    //     backing:NSBackingStoreBuffered
    //     defer:NO];
    // window.title = @"Child";
    // [window makeKeyAndOrderFront:nil];
    // window.contentView.wantsLayer = YES;
    // window.contentView.layer = layer;
    
    return layer;
}

void sendUpdatedSurfaceMessage(mach_port_t remotePort, int surfaceIndex)
{
    MachIOSurfaceSwapMessage message;

    // Fill in the header fields
    message.header.msgh_bits = MACH_MSGH_BITS(MACH_MSG_TYPE_COPY_SEND, 0);
    // ^ Set send right to be copied, no receive right, and mark as a complex message

    message.header.msgh_size = sizeof(message);  // Set the total size of the message
    message.header.msgh_remote_port = remotePort;  // Set the destination port
    message.header.msgh_local_port = MACH_PORT_NULL;  // No reply port
    message.header.msgh_id = 2000;  // Message ID (unused in this case)

    message.surfaceIndex = surfaceIndex;

    // Send the message
    int kr = mach_msg(&message.header, MACH_SEND_MSG, sizeof(message), 0, MACH_PORT_NULL, MACH_MSG_TIMEOUT_NONE, MACH_PORT_NULL);
    if (kr != KERN_SUCCESS)
        NSLog(@"Failed to send message: %s", mach_error_string(kr));
}

MTLRenderPassDescriptor * makeDescriptorForTexture(id<MTLTexture> texture)
{
    MTLRenderPassDescriptor *descriptor = [MTLRenderPassDescriptor new];

    descriptor.colorAttachments[0].texture = texture;
    descriptor.colorAttachments[0].loadAction = MTLLoadActionClear;    
    
    descriptor.colorAttachments[0].clearColor = MTLClearColorMake(0.0, 0.0, 0.0, 1.0);
    
    descriptor.colorAttachments[0].storeAction = MTLStoreActionStore;
    
    return descriptor;
}

void drawOnIOSurface(CALayer* layer, DoubleBuffer buffer) {
    // NSLog(@"drawing...");
    // Choose the next surface:
    const int surfaceIndex = buffer.nextSurfaceIndex;
    // IOSurfaceRef surface = buffer.surfaces[surfaceIndex];
    buffer.nextSurfaceIndex = 0;//(surfaceIndex + 1) % buffer.totalBuffers;
    
    id<MTLDevice> device = MTLCreateSystemDefaultDevice();
    id queue = [device newCommandQueue];
    id<MTLCommandBuffer> renderCommandBuffer = [queue commandBuffer];
    id<MTLRenderCommandEncoder> renderCommandEncoder = [renderCommandBuffer renderCommandEncoderWithDescriptor:makeDescriptorForTexture(buffer.textures[surfaceIndex])];
    [renderCommandEncoder endEncoding];
    [renderCommandBuffer commit];
    [renderCommandBuffer waitUntilCompleted];
    
    [buffer.renderer beginFrameAtTime:CACurrentMediaTime() timeStamp: nil];
    [buffer.renderer addUpdateRect:layer.bounds];
    [buffer.renderer setDestination:buffer.textures[surfaceIndex]];
    [buffer.renderer render];
    [buffer.renderer endFrame];
    
    // Lock the IOSurface for writing
    // IOSurfaceLock(surface, kIOSurfaceLockAvoidSync, NULL);
    // size_t bytesPerRow = IOSurfaceGetBytesPerRow(surface);
    // void *baseAddress = IOSurfaceGetBaseAddress(surface);

    // CGColorSpaceRef colorSpace = CGColorSpaceCreateDeviceRGB();
    // CGContextRef context = CGBitmapContextCreate(baseAddress,
    //                                              IOSurfaceGetWidth(surface),
    //                                              IOSurfaceGetHeight(surface),
    //                                              8,
    //                                              bytesPerRow,
    //                                              colorSpace,
    //                                              kCGImageAlphaPremultipliedFirst | kCGBitmapByteOrder32Little);
    // CGColorSpaceRelease(colorSpace);

    // if (!context)
    // {
    //     NSLog(@"Failed to create CGBitmapContext");
    //     IOSurfaceUnlock(surface, kIOSurfaceLockAvoidSync, NULL);
    //     CFRelease(surface);
    //     return;
    // }

    // CGContextSaveGState(context);
    // // CGContextTranslateCTM(context, 0, layer.bounds.size.height);
    // // CGContextScaleCTM(context, 1.0, -1.0);
    // CGContextScaleCTM(context, 2.0, 2.0);
    // // FIXME: -renderInContext: is not fully supported, but the documentation
    // // is (predictibly) not super helpful in what's not supported. Using a
    // // CARenderer is probably the "correct" way to do this, but this is sufficient
    // // for the purposes of this POC.
    // [layer renderInContext:context];
    // CGContextRestoreGState(context);

    // // Clean up
    // CGContextRelease(context);
    // IOSurfaceUnlock(surface, kIOSurfaceLockAvoidSync, NULL);

    sendUpdatedSurfaceMessage(buffer.remotePort, surfaceIndex);
    
    // FIXME: This should be a display link.
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1/60.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        drawOnIOSurface(layer, buffer);
    });
}

int main(int, const char *[])
{
    @autoreleasepool
    {   
        mach_port_t remotePort = MACH_PORT_NULL;
        kern_return_t kr = bootstrap_look_up(bootstrap_port, 
                                             PORT_NAME,
                                             &remotePort);

        if (kr != KERN_SUCCESS)
        {
            NSLog(@"Failed to look up Mach port. Error: %d", kr);
            return 1;
        }
        
        NSLog(@"Successfully obtained remote Mach port: %d", remotePort);

        DoubleBuffer buffer = createDoubleBuffer(CGSizeMake(300. * 2, 300. * 2), remotePort);
        
        mach_port_t ioSurfacePort1 = IOSurfaceCreateMachPort(buffer.surfaces[0]);
        mach_port_t ioSurfacePort2 = IOSurfaceCreateMachPort(buffer.surfaces[1]);

        NSLog(@"Created ports from surface: %d and %d", ioSurfacePort1, ioSurfacePort2);

        MachIOSurfaceSetupMessage message;

        // Fill in the header fields
        message.header.msgh_bits = MACH_MSGH_BITS(MACH_MSG_TYPE_COPY_SEND, 0) | MACH_MSGH_BITS_COMPLEX;
        // ^ Set send right to be copied, no receive right, and mark as a complex message

        message.header.msgh_size = sizeof(message);  // Set the total size of the message
        message.header.msgh_remote_port = remotePort;  // Set the destination port
        message.header.msgh_local_port = MACH_PORT_NULL;  // No reply port
        message.header.msgh_id = 1000;  // Message ID (unused in this case)

        // Fill in the body
        message.body.msgh_descriptor_count = 2;  // We're including one descriptor

        // Fill in the port descriptors
        message.port_descriptors[0].name = ioSurfacePort1;  // The actual port being sent
        message.port_descriptors[0].disposition = MACH_MSG_TYPE_COPY_SEND;  // Copy the send right
        message.port_descriptors[0].type = MACH_MSG_PORT_DESCRIPTOR;  // This is a port descriptor

        message.port_descriptors[1].name = ioSurfacePort2;  // The actual port being sent
        message.port_descriptors[1].disposition = MACH_MSG_TYPE_COPY_SEND;  // Copy the send right
        message.port_descriptors[1].type = MACH_MSG_PORT_DESCRIPTOR;  // This is a port descriptor

        // Send the message
        kr = mach_msg(&message.header, MACH_SEND_MSG, sizeof(message), 0, MACH_PORT_NULL, MACH_MSG_TIMEOUT_NONE, MACH_PORT_NULL);
        if (kr != KERN_SUCCESS)
        {
            NSLog(@"Failed to send message: %s", mach_error_string(kr));
            return 1;
        }

        NSLog(@"Sent port right successfully");

        CALayer *layer = debugView();
        buffer.renderer.layer = layer;
        drawOnIOSurface(layer, buffer);

        CFRunLoopRun();
    }
    return 0;
}