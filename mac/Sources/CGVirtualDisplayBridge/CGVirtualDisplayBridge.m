#import "CGVirtualDisplayBridge.h"
#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>
#import <dispatch/dispatch.h>

// Private CoreGraphics classes, declared locally. They are the same API used by
// BetterDisplay/DeskPad; there is no public replacement for creating displays.
@interface CGVirtualDisplayDescriptor : NSObject
@property (nonatomic, strong) dispatch_queue_t queue;
@property (nonatomic, copy) NSString *name;
@property (nonatomic) uint32_t maxPixelsWide;
@property (nonatomic) uint32_t maxPixelsHigh;
@property (nonatomic) CGSize sizeInMillimeters;
@property (nonatomic) uint32_t serialNum;
@property (nonatomic) uint32_t productID;
@property (nonatomic) uint32_t vendorID;
@end

@interface CGVirtualDisplayMode : NSObject
- (instancetype)initWithWidth:(uint32_t)width height:(uint32_t)height refreshRate:(double)refreshRate;
@end

@interface CGVirtualDisplaySettings : NSObject
@property (nonatomic) uint32_t hiDPI;
@property (nonatomic, strong) NSArray *modes;
@end

@interface CGVirtualDisplay : NSObject
- (instancetype)initWithDescriptor:(CGVirtualDisplayDescriptor *)descriptor;
- (BOOL)applySettings:(CGVirtualDisplaySettings *)settings;
@property (nonatomic, readonly) uint32_t displayID;
@end

MiraVirtualDisplayRef mira_virtual_display_create(
    uint32_t pointWidth,
    uint32_t pointHeight,
    double refreshRate,
    int hiDPI,
    const char *name
) {
    static dispatch_queue_t displayQueue;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        displayQueue = dispatch_queue_create("app.mirage.virtualdisplay", DISPATCH_QUEUE_SERIAL);
    });

    @autoreleasepool {
        Class descriptorClass = NSClassFromString(@"CGVirtualDisplayDescriptor");
        Class displayClass = NSClassFromString(@"CGVirtualDisplay");
        Class modeClass = NSClassFromString(@"CGVirtualDisplayMode");
        Class settingsClass = NSClassFromString(@"CGVirtualDisplaySettings");
        if (!descriptorClass || !displayClass || !modeClass || !settingsClass) {
            return NULL;
        }

        CGVirtualDisplayDescriptor *descriptor = [descriptorClass new];
        descriptor.queue = displayQueue;
        descriptor.name = name ? [NSString stringWithUTF8String:name] : @"Mirage";
        descriptor.maxPixelsWide = pointWidth * 2;
        descriptor.maxPixelsHigh = pointHeight * 2;
        descriptor.sizeInMillimeters = CGSizeMake(pointWidth * 0.264, pointHeight * 0.264);
        descriptor.serialNum = 424242;
        descriptor.productID = 0x4d49;
        descriptor.vendorID = 0x4d52;

        CGVirtualDisplay *display = [[displayClass alloc] initWithDescriptor:descriptor];
        if (!display) {
            return NULL;
        }

        CGVirtualDisplaySettings *settings = [settingsClass new];
        settings.hiDPI = hiDPI ? 1 : 0;
        id mode = [[modeClass alloc] initWithWidth:pointWidth height:pointHeight refreshRate:refreshRate];
        settings.modes = @[mode];

        if (![display applySettings:settings]) {
            return NULL;
        }
        return (MiraVirtualDisplayRef)CFBridgingRetain(display);
    }
}

uint32_t mira_virtual_display_display_id(MiraVirtualDisplayRef displayRef) {
    if (!displayRef) {
        return 0;
    }
    CGVirtualDisplay *display = (__bridge CGVirtualDisplay *)displayRef;
    return display.displayID;
}

void mira_virtual_display_destroy(MiraVirtualDisplayRef displayRef) {
    if (!displayRef) {
        return;
    }
    // The private API only removes the display when the process exits; releasing
    // here is best-effort cleanup of our own reference.
    CFBridgingRelease(displayRef);
}