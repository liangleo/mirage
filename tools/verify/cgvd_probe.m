// 验证 §15-1：CGVirtualDisplay 在当前 macOS 上是否可创建并上线。
// 编译：clang -fobjc-arc -framework Foundation -framework CoreGraphics cgvd_probe.m -o /tmp/cgvd_probe
#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>
#import <string.h>
#import <stdlib.h>

@interface CGVirtualDisplayDescriptor : NSObject
@property (nonatomic, strong) dispatch_queue_t queue;
@property (nonatomic, copy) NSString *name;
@property (nonatomic) uint32_t maxPixelsWide;
@property (nonatomic) uint32_t maxPixelsHigh;
@property (nonatomic) CGSize sizeInMillimeters;
@property (nonatomic) uint32_t serialNum;
@property (nonatomic) uint32_t productID;
@property (nonatomic) uint32_t vendorID;
@property (nonatomic, copy) void (^terminationHandler)(id, id);
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

int main(int argc, char **argv) {
    @autoreleasepool {
        Class descCls = NSClassFromString(@"CGVirtualDisplayDescriptor");
        Class dispCls = NSClassFromString(@"CGVirtualDisplay");
        Class modeCls = NSClassFromString(@"CGVirtualDisplayMode");
        Class setCls  = NSClassFromString(@"CGVirtualDisplaySettings");
        printf("classes: descriptor=%d display=%d mode=%d settings=%d\n",
               descCls != nil, dispCls != nil, modeCls != nil, setCls != nil);
        if (!descCls || !dispCls || !modeCls || !setCls) { return 2; }

        CGVirtualDisplayDescriptor *d = [descCls new];
        d.queue = dispatch_get_main_queue();
        d.name = @"Mirage Probe";
        d.maxPixelsWide = 2560;
        d.maxPixelsHigh = 1600;
        d.sizeInMillimeters = CGSizeMake(262, 164);
        d.serialNum = 424242;
        d.productID = 0x4d49;
        d.vendorID = 0x4d52;

        CGVirtualDisplay *v = [[dispCls alloc] initWithDescriptor:d];
        printf("created=%d\n", v != nil);
        if (!v) { return 3; }

        CGVirtualDisplaySettings *s = [setCls new];
        s.hiDPI = 1;
        id mode = [[modeCls alloc] initWithWidth:1280 height:800 refreshRate:60.0];
        s.modes = @[mode];

        BOOL applied = [v applySettings:s];
        uint32_t displayID = v.displayID;
        printf("apply=%d displayID=%u\n", applied, displayID);
        sleep(1);

        uint32_t count = 0;
        CGGetActiveDisplayList(0, NULL, &count);
        CGDirectDisplayID ids[32] = {0};
        CGGetActiveDisplayList(count > 32 ? 32 : count, ids, &count);
        int found = 0;
        for (uint32_t i = 0; i < count; i++) { if (ids[i] == displayID) found = 1; }
        printf("active_displays=%u contains_virtual=%d\n", count, found);

        if (displayID != 0) {
            CGDisplayModeRef m = CGDisplayCopyDisplayMode(displayID);
            if (m) {
                printf("mode: %zux%zu px, %.1f Hz, mirrored=%d online=%d\n",
                       CGDisplayModeGetPixelWidth(m), CGDisplayModeGetPixelHeight(m),
                       CGDisplayModeGetRefreshRate(m),
                       CGDisplayIsInMirrorSet(displayID), CGDisplayIsOnline(displayID));
                CGDisplayModeRelease(m);
            }
        }
        printf("RESULT=%s\n", (applied && found) ? "PASS" : "FAIL");
        fflush(stdout);

        int hold = 0;
        if (argc >= 3 && strcmp(argv[1], "--hold") == 0) hold = atoi(argv[2]);
        if (hold > 0) {
            printf("HOLDING=%d\n", hold);
            fflush(stdout);
            for (int i = 0; i < hold; i++) sleep(1);
        }
    }
    return 0;
}