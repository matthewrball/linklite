// SPDX-License-Identifier: GPL-2.0-or-later
//
// C module for the Swift display host: the Rust engine's C ABI plus our own declarations of the
// private CoreGraphics virtual-display classes. CoreGraphics exports these classes (macOS 11+),
// but no public header describes them; the declarations below cover only what the host uses.

#ifndef CDLLITE_H
#define CDLLITE_H

#include "../../../engine/include/dllite.h"

#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>
#import <dispatch/dispatch.h>

NS_ASSUME_NONNULL_BEGIN

@class CGVirtualDisplay;

/// One mode a virtual display offers, in pixels. With CGVirtualDisplaySettings.hiDPI set, macOS can
/// also list a HiDPI ("looks like") variant at half the width and height of a mode.
@interface CGVirtualDisplayMode : NSObject
@property (readonly, nonatomic) unsigned int width;
@property (readonly, nonatomic) unsigned int height;
@property (readonly, nonatomic) double refreshRate;
- (instancetype)initWithWidth:(unsigned int)width
                       height:(unsigned int)height
                  refreshRate:(double)refreshRate;
@end

@interface CGVirtualDisplaySettings : NSObject
@property (strong, nonatomic) NSArray<CGVirtualDisplayMode *> *modes;
@property (nonatomic) unsigned int hiDPI;
- (instancetype)init;
@end

@interface CGVirtualDisplayDescriptor : NSObject
@property (strong, nonatomic, nullable) dispatch_queue_t queue;
@property (copy, nonatomic) NSString *name;
@property (nonatomic) unsigned int maxPixelsWide;
@property (nonatomic) unsigned int maxPixelsHigh;
@property (nonatomic) CGSize sizeInMillimeters;
@property (nonatomic) unsigned int vendorID;
@property (nonatomic) unsigned int productID;
@property (nonatomic) unsigned int serialNum;
@property (nonatomic) CGPoint redPrimary;
@property (nonatomic) CGPoint greenPrimary;
@property (nonatomic) CGPoint bluePrimary;
@property (nonatomic) CGPoint whitePoint;
/// Called on `queue` if the window server tears the display down on its own.
@property (copy, nonatomic, nullable) void (^terminationHandler)(id _Nullable reason, CGVirtualDisplay *display);
- (instancetype)init;
@end

/// The display exists while this object is alive; releasing it removes the display.
@interface CGVirtualDisplay : NSObject
@property (readonly, nonatomic) CGDirectDisplayID displayID;
@property (readonly, nonatomic) unsigned int hiDPI;
@property (readonly, nonatomic) NSArray<CGVirtualDisplayMode *> *modes;
- (nullable instancetype)initWithDescriptor:(CGVirtualDisplayDescriptor *)descriptor;
- (BOOL)applySettings:(CGVirtualDisplaySettings *)settings;
@end

NS_ASSUME_NONNULL_END

#endif
