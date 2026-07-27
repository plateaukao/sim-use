// SPDX-License-Identifier: Apache-2.0
#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>
#import <XCTest/XCTest.h>

NS_ASSUME_NONNULL_BEGIN

/// Thin Objective-C façade over the `XCUIAutomation` SPI that XCUITest
/// exposes to a test process but does not publish in its headers.
///
/// Why Objective-C and not Swift: these calls pass C structs (`CGPoint`)
/// and `double`s, which `NSObject.perform(_:with:)` cannot marshal.
/// Doing it from Swift means hand-rolled `objc_msgSend` casts that break
/// silently on an ABI change. Forward-declaring the interfaces here lets
/// the compiler type-check every call site while still linking nothing —
/// the classes are resolved at runtime through `NSClassFromString`, so a
/// future Xcode that renames one degrades to a structured error rather
/// than a launch-time missing-symbol crash.
///
/// This is the same technique WebDriverAgent has used since 2015; the
/// specific selectors were verified against Xcode 26's
/// `XCUIAutomation.framework` before being declared.
@interface SimUsePrivateAPI : NSObject

/// `YES` when every SPI the bridge needs resolved at load time. When
/// `NO`, `unavailableReason` explains which piece is missing and the
/// handlers fall back to public API where one exists.
@property (class, nonatomic, readonly) BOOL isAvailable;
@property (class, nonatomic, readonly, nullable) NSString *unavailableReason;

/// Bundle identifiers of the foreground applications, front-most first.
/// Empty when the SPI is unavailable — callers then require the host to
/// supply `bundle_id` explicitly.
+ (NSArray<NSString *> *)activeForegroundBundleIDs;

/// Human-readable description of what `activeForegroundApplications`
/// actually returned (class names, responds-to checks). Surfaced by the
/// `/diag` endpoint; the shape of that array is the single most
/// Xcode-version-sensitive thing in this file, so it is worth being able
/// to inspect it on a device without a rebuild.
+ (NSString *)foregroundDiagnostics;

/// The interface orientation the event system should interpret
/// coordinates in. Falls back to portrait (0) when unavailable.
+ (NSInteger)interfaceOrientationForBundleID:(nullable NSString *)bundleID;

/// Synthesizes a multi-touch event.
///
/// `strokes` is an array of strokes; each stroke is an ordered array of
/// waypoints `@{@"x": …, @"y": …, @"t": …}` where `t` is seconds from
/// the start of the whole event. A stroke's first waypoint is its
/// touch-down and its last is its lift-up, so a tap is a two-waypoint
/// stroke at one location and a swipe is a polyline.
+ (BOOL)performTouchStrokes:(NSArray<NSArray<NSDictionary<NSString *, NSNumber *> *> *> *)strokes
       interfaceOrientation:(NSInteger)orientation
                      error:(NSError *__autoreleasing _Nullable *_Nullable)error;

/// Types `text` through the text-input event path — the same route the
/// on-screen keyboard uses — so it works without an `XCUIElement`
/// reference and without the field having been tapped first (it still
/// requires something on screen to have keyboard focus).
+ (BOOL)typeText:(NSString *)text
   typingSpeed:(NSUInteger)typingSpeed
interfaceOrientation:(NSInteger)orientation
           error:(NSError *__autoreleasing _Nullable *_Nullable)error;

/// Sends a single key with modifier flags — the hardware-keyboard
/// route, which is how `paste` delivers Cmd+V without a physical
/// keyboard attached. `modifierFlags` uses `XCUIKeyModifierFlags`.
+ (BOOL)pressKey:(NSString *)key
   modifierFlags:(NSUInteger)modifierFlags
interfaceOrientation:(NSInteger)orientation
           error:(NSError *__autoreleasing _Nullable *_Nullable)error;

/// Hardware lock (side) button. `XCUIDevice.press(_:)` covers home and
/// volume publicly but has no lock case on iOS.
+ (BOOL)pressLockButton:(NSError *__autoreleasing _Nullable *_Nullable)error;

@end

/// Runs a Swift closure with an Objective-C exception handler around it.
///
/// Swift cannot catch `NSException`, and XCTest raises them freely —
/// `snapshot()` on an app that died mid-call, a private selector a new
/// Xcode dropped, an internal assertion. Unhandled, one such exception
/// unwinds through the test method and ends the whole bridge session:
/// the phone stops answering and the user sees a connection error with
/// no cause. Wrapping every handler turns that into a single failed
/// request with the exception name and reason in the response.
@interface SimUseExceptionTrap : NSObject
+ (BOOL)run:(NS_NOESCAPE dispatch_block_t)block error:(NSError *__autoreleasing _Nullable *_Nullable)error;
@end

NS_ASSUME_NONNULL_END
