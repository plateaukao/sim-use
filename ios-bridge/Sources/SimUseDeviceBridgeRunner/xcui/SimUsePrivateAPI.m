// SPDX-License-Identifier: Apache-2.0
#import "SimUsePrivateAPI.h"
#import <objc/runtime.h>
#import <objc/message.h>

#pragma mark - Forward declarations of XCUIAutomation SPI

@interface XCPointerEventPath : NSObject
- (instancetype)initForTouchAtPoint:(CGPoint)point offset:(NSTimeInterval)offset;
- (instancetype)initForTextInput;
- (void)moveToPoint:(CGPoint)point atOffset:(NSTimeInterval)offset;
- (void)liftUpAtOffset:(NSTimeInterval)offset;
- (void)typeText:(NSString *)text
        atOffset:(NSTimeInterval)offset
     typingSpeed:(NSUInteger)typingSpeed
    shouldRedact:(BOOL)shouldRedact;
- (void)typeKey:(NSString *)key modifiers:(NSUInteger)modifiers atOffset:(NSTimeInterval)offset;
@end

@interface XCSynthesizedEventRecord : NSObject
- (instancetype)initWithName:(NSString *)name interfaceOrientation:(NSInteger)orientation;
- (void)addPointerEventPath:(XCPointerEventPath *)path;
/// `XCSynthesizedEventRecord(Dispatch)` on iOS. Submits the event and
/// blocks until the system has delivered it.
- (BOOL)synthesizeWithError:(NSError **)error;
@end

@interface XCUIDevice (SimUsePrivate)
- (BOOL)performDeviceEvent:(id)event error:(NSError **)error;
- (id)eventSynthesizer;
- (id)system;
- (void)pressLockButton;
@end

@interface XCUIApplication (SimUsePrivate)
- (NSString *)bundleID;
- (NSInteger)interfaceOrientation;
@end

#pragma mark -

static NSString *const SimUseErrorDomain = @"com.linecorp.simuse.devicebridge";

static NSError *SimUseError(NSInteger code, NSString *message) {
    return [NSError errorWithDomain:SimUseErrorDomain
                               code:code
                           userInfo:@{NSLocalizedDescriptionKey: message}];
}

/// How long to wait for the asynchronous synthesizer fallback before
/// giving up. Generous relative to any real gesture (a 3 s long-press is
/// already extreme) and short enough that a completion block that never
/// fires cannot park the serial work queue for the session.
static const NSTimeInterval SimUseSynthesizeTimeout = 60.0;

/// Submits a built `XCSynthesizedEventRecord`.
///
/// Three routes, most-preferred first, because the submission API is the
/// one piece of this file that has actually moved between Xcode
/// releases:
///
///  1. `-[XCSynthesizedEventRecord synthesizeWithError:]` — present on
///     iOS since Xcode 15, synchronous, and the shape XCUITest itself
///     uses internally.
///  2. `-[[XCUIDevice.sharedDevice eventSynthesizer] synthesizeEvent:completion:]`
///     — WebDriverAgent's long-standing route; asynchronous.
///  3. `-[XCUIDevice performDeviceEvent:error:]` — the macOS-flavoured
///     entry point. Listed last because on iOS it reaches for a
///     `-duration` the record does not implement, which is an
///     unrecognized-selector *exception*, not an error return.
///
/// Every route runs inside `@try`: an ObjC exception unwinding out of
/// here would tear down the XCTest case and with it the whole bridge
/// session, turning a single bad request into "the phone stopped
/// responding".
static BOOL SimUseSubmitEvent(XCSynthesizedEventRecord *record, NSError **error) {
    @try {
        if ([record respondsToSelector:@selector(synthesizeWithError:)]) {
            NSError *inner = nil;
            if ([record synthesizeWithError:&inner]) {
                return YES;
            }
            if (error) { *error = inner ?: SimUseError(10, @"synthesizeWithError: failed"); }
            return NO;
        }

        XCUIDevice *device = XCUIDevice.sharedDevice;
        if ([device respondsToSelector:@selector(eventSynthesizer)]) {
            id synthesizer = [device eventSynthesizer];
            SEL selector = NSSelectorFromString(@"synthesizeEvent:completion:");
            if ([synthesizer respondsToSelector:selector]) {
                __block NSError *inner = nil;
                __block BOOL ok = NO;
                dispatch_semaphore_t done = dispatch_semaphore_create(0);
                void (*send)(id, SEL, id, void (^)(BOOL, NSError *)) = (void *)objc_msgSend;
                send(synthesizer, selector, record, ^(BOOL result, NSError *callbackError) {
                    ok = result;
                    inner = callbackError;
                    dispatch_semaphore_signal(done);
                });
                dispatch_time_t deadline =
                    dispatch_time(DISPATCH_TIME_NOW, (int64_t)(SimUseSynthesizeTimeout * NSEC_PER_SEC));
                if (dispatch_semaphore_wait(done, deadline) != 0) {
                    if (error) { *error = SimUseError(11, @"synthesizeEvent:completion: never completed"); }
                    return NO;
                }
                if (!ok && error) { *error = inner ?: SimUseError(12, @"synthesizeEvent:completion: failed"); }
                return ok;
            }
        }

        if ([device respondsToSelector:@selector(performDeviceEvent:error:)]) {
            NSError *inner = nil;
            if ([device performDeviceEvent:record error:&inner]) {
                return YES;
            }
            if (error) { *error = inner ?: SimUseError(13, @"performDeviceEvent:error: failed"); }
            return NO;
        }

        if (error) {
            *error = SimUseError(14, @"No usable event-submission API found in XCUIAutomation");
        }
        return NO;
    } @catch (NSException *exception) {
        if (error) {
            *error = SimUseError(15, [NSString stringWithFormat:
                @"Event submission raised %@: %@. The XCUIAutomation event API has changed shape in this Xcode; "
                @"please file an issue with your Xcode version.",
                exception.name, exception.reason]);
        }
        return NO;
    }
}

@implementation SimUsePrivateAPI

/// Resolved once at first use. A missing class here is not fatal to the
/// bridge as a whole — `/screenshot` and the public-API paths keep
/// working — so we record the reason rather than trapping.
+ (NSString *)resolveUnavailableReason {
    static NSString *reason = nil;
    static dispatch_once_t token;
    dispatch_once(&token, ^{
        Class recordClass = NSClassFromString(@"XCSynthesizedEventRecord");
        XCUIDevice *device = XCUIDevice.sharedDevice;
        // Mirrors the route list in `SimUseSubmitEvent`: any one of the
        // three is enough. Requiring a specific one here is how the
        // first cut reported "available" on a device where the only
        // route it knew about raised on use.
        BOOL canSubmit =
            [recordClass instancesRespondToSelector:@selector(synthesizeWithError:)] ||
            [device respondsToSelector:@selector(eventSynthesizer)] ||
            [device respondsToSelector:@selector(performDeviceEvent:error:)];

        if (!NSClassFromString(@"XCPointerEventPath")) {
            reason = @"XCPointerEventPath is missing from XCUIAutomation";
        } else if (!recordClass) {
            reason = @"XCSynthesizedEventRecord is missing from XCUIAutomation";
        } else if (!canSubmit) {
            reason = @"No event-submission API (synthesizeWithError:, eventSynthesizer, performDeviceEvent:error:) is available";
        }
    });
    return reason;
}

+ (BOOL)isAvailable {
    return [self resolveUnavailableReason] == nil;
}

+ (NSString *)unavailableReason {
    return [self resolveUnavailableReason];
}

#pragma mark - Foreground application

/// `-[XCUISystem activeForegroundApplications]` is the supported-ish
/// route in Xcode 15+ (`XCAXClient_iOS` is no longer a singleton and has
/// no public constructor). The array's element type has changed shape
/// across Xcode releases — sometimes `XCUIApplication`, sometimes an
/// accessibility element carrying only a pid — so we probe rather than
/// assume, and report what we saw through `+foregroundDiagnostics`.
+ (NSArray *)rawForegroundApplications {
    XCUIDevice *device = XCUIDevice.sharedDevice;
    if (![device respondsToSelector:@selector(system)]) {
        return @[];
    }
    id system = [device system];
    SEL selector = NSSelectorFromString(@"activeForegroundApplications");
    if (![system respondsToSelector:selector]) {
        return @[];
    }
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Warc-performSelector-leaks"
    id result = [system performSelector:selector];
#pragma clang diagnostic pop
    return [result isKindOfClass:NSArray.class] ? result : @[];
}

+ (NSArray<NSString *> *)activeForegroundBundleIDs {
    NSMutableArray<NSString *> *out = [NSMutableArray array];
    for (id app in [self rawForegroundApplications]) {
        NSString *bundleID = nil;
        if ([app respondsToSelector:@selector(bundleID)]) {
            bundleID = [app bundleID];
        } else if ([app respondsToSelector:NSSelectorFromString(@"bundleIdentifier")]) {
            bundleID = [app valueForKey:@"bundleIdentifier"];
        }
        if (bundleID.length > 0 && ![out containsObject:bundleID]) {
            [out addObject:bundleID];
        }
    }
    return out;
}

+ (NSString *)foregroundDiagnostics {
    NSString *reason = [self resolveUnavailableReason];
    NSMutableString *text = [NSMutableString string];
    [text appendFormat:@"spi_available=%@", reason ? [NSString stringWithFormat:@"NO (%@)", reason] : @"YES"];

    NSArray *raw = [self rawForegroundApplications];
    [text appendFormat:@"; activeForegroundApplications.count=%lu", (unsigned long)raw.count];
    NSUInteger index = 0;
    for (id app in raw) {
        [text appendFormat:@"; [%lu] class=%@", (unsigned long)index++, NSStringFromClass([app class])];
        if ([app respondsToSelector:@selector(bundleID)]) {
            [text appendFormat:@" bundleID=%@", [app bundleID]];
        }
        if ([app respondsToSelector:NSSelectorFromString(@"processIdentifier")]) {
            [text appendFormat:@" pid=%@", [app valueForKey:@"processIdentifier"]];
        }
    }
    return text;
}

+ (NSInteger)interfaceOrientationForBundleID:(NSString *)bundleID {
    if (bundleID.length == 0) {
        return 1; // UIInterfaceOrientationPortrait
    }
    XCUIApplication *app = [[XCUIApplication alloc] initWithBundleIdentifier:bundleID];
    if ([app respondsToSelector:@selector(interfaceOrientation)]) {
        NSInteger orientation = [app interfaceOrientation];
        if (orientation > 0) {
            return orientation;
        }
    }
    return 1;
}

#pragma mark - Event synthesis

+ (BOOL)performTouchStrokes:(NSArray<NSArray<NSDictionary<NSString *, NSNumber *> *> *> *)strokes
       interfaceOrientation:(NSInteger)orientation
                      error:(NSError *__autoreleasing *)error {
    NSString *reason = [self resolveUnavailableReason];
    if (reason) {
        if (error) { *error = SimUseError(1, reason); }
        return NO;
    }
    if (strokes.count == 0) {
        if (error) { *error = SimUseError(2, @"no strokes supplied"); }
        return NO;
    }

    Class pathClass = NSClassFromString(@"XCPointerEventPath");
    Class recordClass = NSClassFromString(@"XCSynthesizedEventRecord");
    XCSynthesizedEventRecord *record =
        [[recordClass alloc] initWithName:@"sim-use gesture" interfaceOrientation:orientation];

    for (NSArray<NSDictionary<NSString *, NSNumber *> *> *stroke in strokes) {
        if (stroke.count < 2) {
            if (error) { *error = SimUseError(3, @"each stroke needs at least a down and an up waypoint"); }
            return NO;
        }
        NSDictionary<NSString *, NSNumber *> *first = stroke.firstObject;
        CGPoint start = CGPointMake(first[@"x"].doubleValue, first[@"y"].doubleValue);
        NSTimeInterval startTime = first[@"t"].doubleValue;

        // `initForTouchAtPoint:offset:` *is* the touch-down; there is no
        // separate press call in this API shape.
        XCPointerEventPath *path = [[pathClass alloc] initForTouchAtPoint:start offset:startTime];

        for (NSUInteger i = 1; i < stroke.count - 1; i++) {
            NSDictionary<NSString *, NSNumber *> *waypoint = stroke[i];
            [path moveToPoint:CGPointMake(waypoint[@"x"].doubleValue, waypoint[@"y"].doubleValue)
                     atOffset:waypoint[@"t"].doubleValue];
        }

        NSDictionary<NSString *, NSNumber *> *last = stroke.lastObject;
        CGPoint end = CGPointMake(last[@"x"].doubleValue, last[@"y"].doubleValue);
        NSTimeInterval endTime = last[@"t"].doubleValue;
        // A stroke whose last waypoint moved must arrive there before it
        // lifts, otherwise the lift lands at the previous position and a
        // swipe reads as a tap at the wrong place.
        if (stroke.count > 1 && !CGPointEqualToPoint(end, start)) {
            [path moveToPoint:end atOffset:endTime];
        }
        [path liftUpAtOffset:endTime];
        [record addPointerEventPath:path];
    }

    return SimUseSubmitEvent(record, error);
}

+ (BOOL)typeText:(NSString *)text
     typingSpeed:(NSUInteger)typingSpeed
interfaceOrientation:(NSInteger)orientation
           error:(NSError *__autoreleasing *)error {
    NSString *reason = [self resolveUnavailableReason];
    if (reason) {
        if (error) { *error = SimUseError(1, reason); }
        return NO;
    }
    Class pathClass = NSClassFromString(@"XCPointerEventPath");
    Class recordClass = NSClassFromString(@"XCSynthesizedEventRecord");

    XCPointerEventPath *path = [[pathClass alloc] initForTextInput];
    if (!path) {
        if (error) { *error = SimUseError(5, @"XCPointerEventPath has no text-input path in this Xcode"); }
        return NO;
    }
    [path typeText:text atOffset:0 typingSpeed:(typingSpeed ?: 60) shouldRedact:NO];

    XCSynthesizedEventRecord *record =
        [[recordClass alloc] initWithName:@"sim-use type" interfaceOrientation:orientation];
    [record addPointerEventPath:path];

    return SimUseSubmitEvent(record, error);
}

+ (BOOL)pressKey:(NSString *)key
   modifierFlags:(NSUInteger)modifierFlags
interfaceOrientation:(NSInteger)orientation
           error:(NSError *__autoreleasing *)error {
    NSString *reason = [self resolveUnavailableReason];
    if (reason) {
        if (error) { *error = SimUseError(1, reason); }
        return NO;
    }
    Class pathClass = NSClassFromString(@"XCPointerEventPath");
    Class recordClass = NSClassFromString(@"XCSynthesizedEventRecord");

    XCPointerEventPath *path = [[pathClass alloc] initForTextInput];
    if (![path respondsToSelector:@selector(typeKey:modifiers:atOffset:)]) {
        if (error) { *error = SimUseError(8, @"XCPointerEventPath does not support -typeKey:modifiers:atOffset:"); }
        return NO;
    }
    [path typeKey:key modifiers:modifierFlags atOffset:0];

    XCSynthesizedEventRecord *record =
        [[recordClass alloc] initWithName:@"sim-use key" interfaceOrientation:orientation];
    [record addPointerEventPath:path];

    return SimUseSubmitEvent(record, error);
}

+ (BOOL)pressLockButton:(NSError *__autoreleasing *)error {
    XCUIDevice *device = XCUIDevice.sharedDevice;
    if (![device respondsToSelector:@selector(pressLockButton)]) {
        if (error) { *error = SimUseError(7, @"XCUIDevice does not respond to -pressLockButton"); }
        return NO;
    }
    [device pressLockButton];
    return YES;
}

@end

@implementation SimUseExceptionTrap

+ (BOOL)run:(NS_NOESCAPE dispatch_block_t)block error:(NSError *__autoreleasing *)error {
    @try {
        block();
        return YES;
    } @catch (NSException *exception) {
        if (error) {
            *error = SimUseError(100, [NSString stringWithFormat:@"%@: %@",
                                       exception.name,
                                       exception.reason ?: @"(no reason)"]);
        }
        return NO;
    }
}

@end
