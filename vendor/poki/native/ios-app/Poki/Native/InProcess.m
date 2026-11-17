#import "InProcess.h"
#import "RecoveredNative.h"
#import <TargetConditionals.h>
#import <dlfcn.h>
#import <notify.h>
#import <objc/message.h>
#import <objc/runtime.h>
#import <unistd.h>
#import <sys/utsname.h>
#import <UIKit/UIKit.h>
#import <Vision/Vision.h>

@interface NSObject (PKObservedPrivateAPI)
- (id)initForTouchAtPoint:(CGPoint)point offset:(double)offset;
- (void)moveToPoint:(CGPoint)point atOffset:(double)offset;
- (void)liftUpAtOffset:(double)offset;
- (id)initWithName:(NSString *)name;
- (id)initWithName:(NSString *)name interfaceOrientation:(long long)orientation;
- (id)initWithName:(NSString *)name displayID:(unsigned long long)displayID interfaceOrientation:(long long)orientation;
- (void)addPointerEventPath:(id)path;
- (id)daemonProxy;
- (void)_XCT_synthesizeEvent:(id)event implicitConfirmationInterval:(double)interval
    completion:(void (^)(NSError *))completion;
+ (id)sharedDevice;
+ (id)mainScreen;
- (id)accessibilityInterface;
- (id)activeApplications;
- (int)processIdentifier;
- (id)systemApplication;
- (NSDictionary *)defaultParameters;
- (id)screenshot;
- (NSData *)PNGRepresentation;
- (void)_XCT_requestBundleIDForPID:(int)pid reply:(void (^)(NSString *, NSError *))reply;
- (void)_XCT_requestScreenshotOfScreenWithID:(long long)screenID withRect:(CGRect)rect uti:(NSString *)uti compressionQuality:(double)quality withReply:(void (^)(NSData *, NSError *))reply;
- (long long)displayID;
- (NSArray *)children;
- (long long)elementType;
- (CGRect)frame;
- (NSString *)identifier;
- (NSString *)label;
- (id)value;
- (id)placeholderValue;
- (BOOL)hasFocus;
- (BOOL)hasKeyboardFocus;
- (BOOL)loadAccessibility:(NSError **)error;
- (void)_XCT_launchApplicationWithBundleID:(NSString *)bundle arguments:(NSArray *)arguments environment:(NSDictionary *)environment completion:(void (^)(NSError *))completion;
- (void)_XCT_terminateApplicationWithBundleID:(NSString *)bundle completion:(void (^)(NSError *))completion;
- (void)pressButton:(long long)button;
+ (id)deviceEventWithPage:(unsigned int)page usage:(unsigned int)usage duration:(double)duration;
- (BOOL)performDeviceEvent:(id)event error:(NSError **)error;
- (void)pressLockButton;
+ (id)connectionForInitiatingSharedSession;
+ (void)sessionWithConnection:(id)connection completion:(void (^)(id, NSError *))completion;
- (BOOL)enableAutomationModeWithError:(NSError **)error;
- (id)registerInvalidationHandler:(void (^)(void))handler;
- (id)connection;
- (void)invalidate;
+ (id)sharedSession;
- (id)applicationMonitor;
- (id)initWithApplicationProcessTracker:(id)tracker remoteAccessibilityInterface:(id)remote device:(id)device;
@end

/// XCUIElementType's names, by value (XCUIElementTypes.h).
static NSString *PKTypeName(long long type) {
    static NSArray<NSString *> *names;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        names = [@"Any Other Application Group Window Sheet Drawer Alert Dialog Button RadioButton RadioGroup CheckBox DisclosureTriangle PopUpButton ComboBox MenuButton ToolbarButton Popover Keyboard Key NavigationBar TabBar TabGroup Toolbar StatusBar Table TableRow TableColumn Outline OutlineRow Browser CollectionView Slider PageIndicator ProgressIndicator ActivityIndicator SegmentedControl Picker PickerWheel Switch Toggle Link Image Icon SearchField ScrollView ScrollBar StaticText TextField SecureTextField DatePicker TextView Menu MenuItem MenuBar MenuBarItem Map WebView IncrementArrow DecrementArrow Timeline RatingIndicator ValueIndicator SplitGroup Splitter RelevanceIndicator ColorWell HelpTag Matte DockItem Ruler RulerMarker Grid LevelIndicator Cell LayoutArea LayoutItem Handle Stepper Tab TouchBar StatusItem" componentsSeparatedByString:@" "];
    });
    return type >= 0 && type < (long long)names.count ? names[type] : @"Other";
}

static NSString *PKEscape(NSString *s) {
    NSMutableString *out = [NSMutableString stringWithCapacity:s.length];
    [s enumerateSubstringsInRange:NSMakeRange(0, s.length) options:NSStringEnumerationByComposedCharacterSequences usingBlock:^(NSString *c, NSRange r, NSRange e, BOOL *stop) {
        if ([c isEqualToString:@"&"]) [out appendString:@"&amp;"];
        else if ([c isEqualToString:@"<"]) [out appendString:@"&lt;"];
        else if ([c isEqualToString:@">"]) [out appendString:@"&gt;"];
        else if ([c isEqualToString:@"\""]) [out appendString:@"&quot;"];
        else if ([c isEqualToString:@"\n"]) [out appendString:@"&#10;"];
        else if (c.length == 1 && [c characterAtIndex:0] < 0x20) {}
        else [out appendString:c];
    }];
    return out;
}

static NSString *PKText(id value) {
    if ([value isKindOfClass:NSString.class]) return value;
    if ([value isKindOfClass:NSNumber.class]) return [value stringValue];
    return nil;
}

static BOOL PKMatches(NSMethodSignature *signature, const char *result, NSArray<NSString *> *arguments);

typedef id (*PKSnapshotRequest)(id, SEL, id, id, id, NSError **);
typedef id (*PKElementAtPoint)(id, SEL, CGPoint, NSError **);
typedef id (*PKMapAttributes)(id, SEL, id, BOOL);

/// XCUIApplication refuses to exist outside a UI test bundle ("Device is not configured for UI
/// testing"), so the screen is read the way WebDriverAgent's FBXCAXClientProxy does: the AX client's
/// own elements and snapshot request, which testmanagerd answers for any process with a session.
/// Synchronous accessibility requests have no deadline of their own. One to an app whose main thread
/// was busy (Settings bringing up its keyboard on the CI simulator) had not returned after 12 minutes,
/// and every read, picture and launch queued behind it hung with it, the watchdog's new sessions
/// included: the agent was blind for the rest of the run (the gym's finding 36). XCTest asks an app
/// to confirm its run loop is responsive within 2 s before it asks for a snapshot; here each request
/// runs on its own thread and is given up after `seconds`: the caller gets nil and a code at once,
/// the thread ends when the app answers, and until then nothing else is asked of that pid (it would
/// hang the same way). `pid` 0 stands for the accessibility server itself.
static NSObject *PKHungLock(void) {
    static NSObject *lock;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ lock = [NSObject new]; });
    return lock;
}
static NSMutableDictionary<NSNumber *, NSNumber *> *PKHungSince(void) {
    static NSMutableDictionary *since;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ since = [NSMutableDictionary dictionary]; });
    return since;
}
static NSString *PKUnresponsive(int pid, NSTimeInterval seconds) {
    if (pid < 0) return [NSString stringWithFormat:@"front_app_unresponsive: looking up the app in front has not finished in %.0f s (the app in front or the accessibility server is not answering); the picture still shows the screen", seconds];
    if (pid <= 0) return [NSString stringWithFormat:@"accessibility_unresponsive: the accessibility server has not answered for %.0f s", seconds];
    return [NSString stringWithFormat:@"app_unresponsive: the app in front (pid %d) has not answered an accessibility request for %.0f s (its main thread is busy); the picture still shows the screen; the phone serves one such request at a time, so nothing more is read or touched until the app answers (at most a minute), and the tree comes back then", pid, seconds];
}
static id PKBounded(int pid, NSTimeInterval seconds, NSString **code, id (^work)(void)) {
    NSObject *lock = PKHungLock();
    NSTimeInterval now = NSProcessInfo.processInfo.systemUptime;
    @synchronized (lock) {
        NSNumber *since = PKHungSince()[@(pid)];
        if (since) { if (code) *code = PKUnresponsive(pid, now - since.doubleValue); return nil; }
    }
    dispatch_semaphore_t done = dispatch_semaphore_create(0);
    __block id result = nil;
    __block BOOL finished = NO, abandoned = NO;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        id value = nil;
        @try { value = work(); } @catch (__unused NSException *e) {}
        @synchronized (lock) {
            finished = YES;
            if (abandoned) {
                [PKHungSince() removeObjectForKey:@(pid)];
                NSLog(@"PokiInProcess: pid %d answered after %.1f s; it is asked again", pid, NSProcessInfo.processInfo.systemUptime - now);
            } else {
                result = value;
            }
        }
        dispatch_semaphore_signal(done);
    });
    if (dispatch_semaphore_wait(done, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(seconds * NSEC_PER_SEC))) == 0) return result;
    @synchronized (lock) {
        if (finished) return result;
        abandoned = YES;
        PKHungSince()[@(pid)] = @(now);
    }
    NSLog(@"PokiInProcess: pid %d did not answer an accessibility request within %.1f s; given up, nothing more is asked of it until it answers", pid, seconds);
    if (code) *code = PKUnresponsive(pid, seconds);
    return nil;
}

static id PKAXClient(void) {
    id device = [NSClassFromString(@"XCUIDevice") sharedDevice];
    return [device respondsToSelector:@selector(accessibilityInterface)] ? [device accessibilityInterface] : nil;
}

static int PKAXPid(id element) {
    SEL selector = @selector(processIdentifier);
    if (!element || ![element respondsToSelector:selector]) return 0;
    const char *type = [element methodSignatureForSelector:selector].methodReturnType;
    if (type && !strcmp(type, @encode(int))) return ((int (*)(id, SEL))objc_msgSend)(element, selector);
    return (int)((long long (*)(id, SEL))objc_msgSend)(element, selector);
}

static NSArray *PKActiveApplications(id ax) {
    if (![ax respondsToSelector:@selector(activeApplications)]) return @[];
    id active = PKBounded(0, 4, NULL, ^id { return [ax activeApplications]; });
    return [active isKindOfClass:NSArray.class] ? active : @[];
}

static id PKRequestSnapshot(id ax, id element, NSInteger maxDepth, NSInteger maxNodes, NSString **code);
static id PKRequestSnapshotWithin(NSTimeInterval seconds, id ax, id element, NSInteger maxDepth, NSInteger maxNodes, NSString **code);

CGRect PKPeerPane(CGRect screen, CGRect window) {
    if (CGRectIsEmpty(screen) || CGRectIsInfinite(screen) || CGRectIsEmpty(window) || CGRectIsInfinite(window)) return CGRectNull;
    // Side-by-side windows run almost the whole height. Exclude sheets, floating windows and a
    // full-screen app. Allow for the system's inset at the edge of a pane.
    CGFloat tolerance = 32;
    if (fabs(CGRectGetMinY(window) - CGRectGetMinY(screen)) > tolerance ||
        fabs(CGRectGetMaxY(window) - CGRectGetMaxY(screen)) > tolerance) return CGRectNull;
    if (window.size.width < screen.size.width * 0.2 || window.size.width > screen.size.width * 0.8) return CGRectNull;
    BOOL left = fabs(CGRectGetMinX(window) - CGRectGetMinX(screen)) <= tolerance;
    BOOL right = fabs(CGRectGetMaxX(window) - CGRectGetMaxX(screen)) <= tolerance;
    if (left == right) return CGRectNull;
    CGFloat start = left ? CGRectGetMaxX(window) : CGRectGetMinX(screen);
    CGFloat end = left ? CGRectGetMaxX(screen) : CGRectGetMinX(window);
    return CGRectMake(start, CGRectGetMinY(screen), end - start, screen.size.height);
}

/// Prefer the app's actual visible window. The application root can report the full display.
static CGRect PKTargetFrame(id root, CGRect screen) {
    if (!root) return CGRectNull;
    CGRect frame = [root frame];
    if (!CGRectIsNull(PKPeerPane(screen, frame))) return frame;
    for (id child in [root children]) {
        if ([child elementType] != 5) continue; // XCUIElementTypeWindow
        CGRect window = [child frame];
        if (!CGRectIsNull(PKPeerPane(screen, window))) return window;
    }
    return frame;
}

static CGRect PKOppositePane(PKDisplayGeometry geometry) {
    CGRect screen = geometry.bounds;
    CGRect candidate = geometry.peer;
    CGFloat width = screen.size.width - candidate.size.width;
    BOOL candidateIsLeft = CGRectGetMidX(candidate) < CGRectGetMidX(screen);
    CGFloat x = candidateIsLeft ? CGRectGetMaxX(screen) - width : CGRectGetMinX(screen);
    return CGRectMake(x, CGRectGetMinY(screen), width, screen.size.height);
}

/// The front app's AX element. One active app is the front one. Several (an alert over an app, split
/// screen, picture in picture): SpringBoard set aside, the one owning the screen's centre.
/// The system app's frame (the screen in its current orientation), read again after 5 s: one AX
/// round trip on every read before.
static CGRect PKScreenFrame(id ax, id system) {
    static CGRect frame;
    static NSTimeInterval at = -100;
    static NSObject *lock;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ lock = [NSObject new]; frame = CGRectNull; });
    NSTimeInterval now = NSProcessInfo.processInfo.systemUptime;
    @synchronized (lock) { if (now - at < 5 && !CGRectIsEmpty(frame)) return frame; }
    id root = system ? PKRequestSnapshotWithin(3, ax, system, 1, 1, NULL) : nil;
    CGRect read = root ? [root frame] : CGRectNull;
    @synchronized (lock) { if (!CGRectIsEmpty(read)) { frame = read; at = now; } }
    return read;
}

static id PKForegroundElementTimed(id ax, PKDisplayGeometry geometry, CGRect *pane, NSString *(^bundleForPID)(int));

static BOOL PKPhoneLocked(void) {
    static int token = -1;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ if (notify_register_check("com.apple.springboard.lockstate", &token) != NOTIFY_STATUS_OK) token = -1; });
    if (token == -1) return NO;
    uint64_t state = 0;
    notify_get_state(token, &state);
    return state != 0;
}

/// Processes iOS lists as active that show only over the Lock Screen.
static NSSet<NSString *> *PKLockScreenOnlyBundles(void) {
    static NSSet *bundles;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ bundles = [NSSet setWithObjects:@"com.apple.SleepLockScreen", nil]; });
    return bundles;
}

static id PKForegroundElement(id ax, PKDisplayGeometry geometry, CGRect *pane, NSString *(^bundleForPID)(int)) {
    NSTimeInterval started = NSProcessInfo.processInfo.systemUptime;
    id chosen = PKForegroundElementTimed(ax, geometry, pane, bundleForPID);
    int ms = (int)lround((NSProcessInfo.processInfo.systemUptime - started) * 1000);
    if (ms > 60) NSLog(@"PokiInProcess timing: foreground %d ms", ms);
    return chosen;
}

static id PKForegroundElementTimed(id ax, PKDisplayGeometry geometry, CGRect *pane, NSString *(^bundleForPID)(int)) {
    NSTimeInterval started = NSProcessInfo.processInfo.systemUptime;
    NSArray *active = PKActiveApplications(ax);
    int activeMs = (int)lround((NSProcessInfo.processInfo.systemUptime - started) * 1000);
    if (activeMs > 60) NSLog(@"PokiInProcess timing: active apps %d ms, %lu", activeMs, (unsigned long)active.count);
    CGRect peer = geometry.peer;
    if (pane) *pane = CGRectNull;
    if (!CGRectIsNull(peer)) {
        // UIKit can report a pane-local origin even when Poki is on the right. AX hit-testing
        // uses the fixed display axes, so probe both panes there before choosing a crop.
        SEL selector = NSSelectorFromString(@"accessibilityElementForElementAtPoint:error:");
        if (!geometry.panePlacementKnown && [ax respondsToSelector:selector]) {
            CGRect alternate = PKOppositePane(geometry);
            CGRect panes[] = {peer, alternate};
            for (NSUInteger i = 0; i < 2; i++) {
                CGRect probe = panes[i];
                CGPoint point = CGPointApplyAffineTransform(CGPointMake(CGRectGetMidX(probe), CGRectGetMinY(probe) + 0.38 * probe.size.height), geometry.toFixed);
                id hit = PKBounded(0, 0.35, NULL, ^id {
                    NSError *error;
                    return ((PKElementAtPoint)objc_msgSend)(ax, selector, point, &error);
                });
                int pid = PKAXPid(hit);
                if (pid == getpid()) { if (pane) *pane = panes[1 - i]; continue; }
                if (pid <= 0 || [bundleForPID(pid) isEqualToString:@"com.apple.springboard"]) continue;
                for (id app in active) if (PKAXPid(app) == pid) {
                    if (pane) *pane = probe;
                    return app;
                }
            }
        }
        id other = nil;
        for (id app in active) {
            int pid = PKAXPid(app);
            if (pid <= 0 || pid == getpid()) continue;
            NSString *bundle = bundleForPID(pid);
            if ([bundle isEqualToString:@"com.apple.springboard"] ||
                (geometry.routesDisplay && [bundle isEqualToString:@"com.apple.SleepLockScreen"])) continue;
            if (other && PKAXPid(other) != pid) return nil;
            other = app;
        }
        return other; // If AX cannot identify it, use the picture of the pane on its own.
    }
    if (active.count == 1 && PKAXPid(active.firstObject) > 0) return active.firstObject;
    id system = [ax respondsToSelector:@selector(systemApplication)] ? [ax systemApplication] : nil;
    int springBoardPID = PKAXPid(system);
    NSMutableArray *candidates = [NSMutableArray array];
    id springBoard = nil;
    id sleepOverlay = nil;
    for (id element in active) {
        int pid = PKAXPid(element);
        if (pid <= 0) continue;
        BOOL isSpringBoard = springBoardPID > 0 ? pid == springBoardPID : [bundleForPID(pid) isEqualToString:@"com.apple.springboard"];
        if (isSpringBoard) springBoard = element;
        else if (geometry.routesDisplay && [bundleForPID(pid) isEqualToString:@"com.apple.SleepLockScreen"]) sleepOverlay = element;
        else [candidates addObject:element];
    }
    // iOS keeps its Sleep screen's process among the active apps with the phone unlocked and another
    // app in front, during a Sleep Focus and after it is turned off (iPhone, iOS 27.3: Poki in front,
    // two active apps, the Sleep screen taken for the front one, so every read was of it and an app
    // Poki had just opened was never seen in front). It is in front only on a locked phone.
    if (candidates.count > 1 && !PKPhoneLocked()) {
        NSMutableArray *shown = [NSMutableArray array];
        for (id element in candidates)
            if (![PKLockScreenOnlyBundles() containsObject:bundleForPID(PKAXPid(element)) ?: @""]) [shown addObject:element];
        if (shown.count) candidates = shown;
    }
    if (candidates.count == 1) return candidates.firstObject;
    if (!candidates.count) return sleepOverlay ?: springBoard ?: system;
    CGRect screen = PKScreenFrame(ax, system);
    // The app under the screen's centre is the front one. Poki's own process is the answer only when
    // it is there and fills the screen; beside the target app (the iPhone Duo's side-by-side apps,
    // iPad windows) the centre can fall on Poki, and the other app is the one being driven. (A
    // process in the background still reports a full-screen frame, so the frame alone says nothing.)
    id own = nil;
    for (id element in candidates) if (PKAXPid(element) == getpid()) own = element;
    NSMutableArray *others = [candidates mutableCopy];
    if (own) [others removeObject:own];
    SEL hitTest = NSSelectorFromString(@"accessibilityElementForElementAtPoint:error:");
    int hitPID = 0;
    if (!CGRectIsEmpty(screen) && [ax respondsToSelector:hitTest]) {
        id hit = PKBounded(0, 3, NULL, ^id {
            NSError *error;
            return ((PKElementAtPoint)objc_msgSend)(ax, hitTest, CGPointMake(CGRectGetMidX(screen), CGRectGetMidY(screen)), &error);
        });
        hitPID = PKAXPid(hit);
    }
    for (id element in others) if (hitPID > 0 && PKAXPid(element) == hitPID) return element;
    if (own && hitPID == getpid()) {
        id ownRoot = PKRequestSnapshotWithin(3, ax, own, 1, 1, NULL);
        CGRect frame = ownRoot ? [ownRoot frame] : CGRectNull;
        BOOL fullScreen = !CGRectIsEmpty(screen) && !CGRectIsEmpty(frame)
            && frame.size.width >= screen.size.width - 8 && frame.size.height >= screen.size.height - 8;
        if (fullScreen || !others.count) return own;
    }
    if (others.count) return others.firstObject;
    return candidates.firstObject;
}

/// The attributes the XML needs and no more: each extra one (visibility, hittability) costs the AX
/// server more round trips per element.
static NSArray *PKSnapshotAttributes(void) {
    static NSArray *attributes;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSArray<NSString *> *keyPaths = @[@"elementType", @"identifier", @"label", @"value", @"placeholderValue", @"frame",
                                          @"enabled", @"selected", @"hasFocus", @"hasKeyboardFocus", @"children"];
        NSArray *mappedAttributes = keyPaths;
        Class snapshotClass = NSClassFromString(@"XCElementSnapshot");
        SEL mapSelector = NSSelectorFromString(@"axAttributesForElementSnapshotKeyPaths:isMacOS:");
        if ([snapshotClass respondsToSelector:mapSelector]) {
            id mapped = ((PKMapAttributes)objc_msgSend)(snapshotClass, mapSelector, keyPaths, NO);
            if ([mapped isKindOfClass:NSSet.class]) mapped = [(NSSet *)mapped allObjects];
            if ([mapped isKindOfClass:NSArray.class] && [(NSArray *)mapped count] > 0) {
                NSArray<NSString *> *needed = @[@"ElementType", @"Identifier", @"Label", @"Value", @"PlaceholderValue", @"Frame",
                                                @"Enabled", @"Selected", @"Focus"];
                NSMutableArray *filtered = [NSMutableArray array];
                for (id attribute in (NSArray *)mapped) {
                    NSString *name = [attribute description];
                    for (NSString *suffix in needed) if ([name hasSuffix:suffix]) { [filtered addObject:attribute]; break; }
                }
                mappedAttributes = filtered.count > 0 ? filtered.copy : mapped;
            }
        }
        attributes = mappedAttributes;
    });
    return attributes;
}

/// A full tree is given 6 s (PokiCore gives up on the read at 4.5 s and asks for a smaller one once
/// the queue is free; a slow but answering app is through by then). A one-element frame gets 3 s.
static id PKRequestSnapshot(id ax, id element, NSInteger maxDepth, NSInteger maxNodes, NSString **code) {
    return PKRequestSnapshotWithin(6, ax, element, maxDepth, maxNodes, code);
}

static id PKRequestSnapshotWithin(NSTimeInterval seconds, id ax, id element, NSInteger maxDepth, NSInteger maxNodes, NSString **code) {
    SEL selector = @selector(requestSnapshotForElement:attributes:parameters:error:);
    if (![ax respondsToSelector:selector] || !PKMatches([ax methodSignatureForSelector:selector], "@", @[@"@", @"@", @"@", @"^@"])) {
        if (code) *code = @"snapshot_api_unavailable";
        return nil;
    }
    NSMutableDictionary *parameters = [NSMutableDictionary dictionary];
    id defaults = [ax respondsToSelector:@selector(defaultParameters)] ? [ax defaultParameters] : nil;
    if ([defaults isKindOfClass:NSDictionary.class]) [parameters addEntriesFromDictionary:defaults];
    parameters[@"maxDepth"] = @(MAX(1, maxDepth));
    parameters[@"maxChildren"] = @(MAX(1, maxNodes));
    parameters[@"maxArrayCount"] = @(MAX(1, maxNodes));
    parameters[@"traverseFromParentsToChildren"] = @YES;
    __block NSError *error = nil;
    __block NSString *thrown = nil;
    NSArray *attributes = PKSnapshotAttributes();
    NSDictionary *frozen = parameters.copy;
    NSString *given = nil;
    id result = PKBounded(PKAXPid(element), seconds, &given, ^id {
        @try {
            return ((PKSnapshotRequest)objc_msgSend)(ax, selector, element, attributes, frozen, &error);
        } @catch (NSException *e) {
            thrown = [NSString stringWithFormat:@"%@: %@", e.name, e.reason];
            return nil;
        }
    });
    if (!result) {
        if (code) *code = given ?: thrown ?: error.localizedDescription ?: @"no_snapshot";
        return nil;
    }
    id root = nil;
    @try { root = [result valueForKey:@"_rootElementSnapshot"]; } @catch (__unused NSException *e) {}
    return root ?: result;
}

/// The AX server can refuse a deep request; each shallower depth is tried once before giving up.
/// `maxDepth` and `maxChildren` bound the request as WebDriverAgent's settings do (0: no bound of
/// PokiCore's): after a read that took too long PokiCore asks for fewer children, then less depth,
/// and a dense screen (1,500 elements in the gym) stops stalling the queue.
static id PKSnapshotTreeBounded(id ax, id element, NSInteger maxDepth, NSInteger maxChildren, NSString **code) {
    NSInteger nodes = maxChildren > 0 ? MIN(maxChildren, 10000) : 10000;
    NSMutableArray<NSNumber *> *depths = [NSMutableArray array];
    if (maxDepth > 0 && maxDepth < 64) [depths addObject:@(maxDepth)];
    for (NSNumber *depth in @[@64, @56, @40, @24, @12]) {
        if (maxDepth > 0 && depth.integerValue >= maxDepth) continue;
        [depths addObject:depth];
    }
    for (NSNumber *depth in depths) {
        id root = PKRequestSnapshot(ax, element, depth.integerValue, nodes, code);
        if (root) { if (code) *code = nil; return root; }
    }
    return nil;
}

static id PKSnapshotTree(id ax, id element, NSString **code) {
    return PKSnapshotTreeBounded(ax, element, 0, 0, code);
}

static NSUInteger PKCount(id node) {
    NSUInteger n = 1;
    for (id child in [node children]) n += PKCount(child);
    return n;
}

/// Whether `selector` has exactly this return type and these argument types, as encoded at runtime.
static BOOL PKMatches(NSMethodSignature *signature, const char *result, NSArray<NSString *> *arguments) {
    if (!signature || signature.numberOfArguments != arguments.count + 2 || strcmp(signature.methodReturnType, result)) return NO;
    for (NSUInteger i = 0; i < arguments.count; i++)
        if (strcmp([signature getArgumentTypeAtIndex:i + 2], arguments[i].UTF8String)) return NO;
    return YES;
}

static BOOL PKSignature(id target, SEL selector, const char *result, NSArray<NSString *> *arguments) {
    return [target respondsToSelector:selector] && PKMatches([target methodSignatureForSelector:selector], result, arguments);
}

static BOOL PKInstanceSignature(Class cls, SEL selector, const char *result, NSArray<NSString *> *arguments) {
    return [cls instancesRespondToSelector:selector] && PKMatches([cls instanceMethodSignatureForSelector:selector], result, arguments);
}

@implementation PKTouchPoint
+ (instancetype)at:(CGPoint)point offset:(double)offset {
    PKTouchPoint *p = [self new];
    p->_point = point;
    p->_offset = offset;
    return p;
}
@end

@interface PKOutcome ()
@property (nonatomic) PKDelivery delivery;
@property (nonatomic, nullable) NSString *code;
@property (nonatomic, nullable) NSString *detail;
@property (nonatomic) double seconds;
@property (nonatomic) uint64_t generation;
@end

@implementation PKOutcome
+ (instancetype)delivery:(PKDelivery)delivery code:(NSString *)code detail:(NSString *)detail {
    PKOutcome *o = [self new];
    o.delivery = delivery;
    o.code = code;
    o.detail = detail;
    return o;
}
@end

static BOOL PKIsDuo(void) {
    static BOOL duo;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
#if TARGET_OS_SIMULATOR
        const char *model = getenv("SIMULATOR_MODEL_IDENTIFIER");
        duo = model && strcmp(model, "iPhone19,4") == 0;
#else
        struct utsname system;
        if (uname(&system) == 0) duo = strcmp(system.machine, "iPhone19,4") == 0;
#endif
    });
    return duo;
}

static BOOL PKSameDisplay(PKDisplayGeometry a, PKDisplayGeometry b) {
    return CGRectEqualToRect(a.bounds, b.bounds) && CGRectEqualToRect(a.peer, b.peer) &&
        CGSizeEqualToSize(a.nativeSize, b.nativeSize) &&
        CGAffineTransformEqualToTransform(a.toFixed, b.toFixed) && a.orientation == b.orientation &&
        a.orientationRevision == b.orientationRevision;
}

/// A workspace identified by two separate visible windows on the same physical display.
@interface PKWorkspace : NSObject
@property (nonatomic) PKDisplayGeometry display;
@property (nonatomic) CGRect left, right;
@property (nonatomic) int leftPID, rightPID;
@property (nonatomic) BOOL selectRight;
@property (nonatomic) BOOL paneLocal;
@property (nonatomic) uint64_t generation;
/// The labels from the resolved trees, used to revalidate with a fresh image alone when still visible.
@property (nonatomic, copy) NSSet<NSString *> *leftLabels, *rightLabels;
/// Downsampled grayscale of the unobscured part of each pane. Kept in memory for this selection.
@property (nonatomic, copy) NSArray<NSData *> *appearance;
@end
@implementation PKWorkspace
@end

static int PKPIDAt(id ax, CGRect pane, PKDisplayGeometry display) {
    CGPoint upright = CGPointMake(CGRectGetMidX(pane), CGRectGetMinY(pane) + pane.size.height * 0.33);
    CGPoint fixed = CGPointApplyAffineTransform(upright, display.toFixed);
    for (NSString *name in @[@"elementAtPoint:error:", @"accessibilityElementForElementAtPoint:error:"]) {
        SEL selector = NSSelectorFromString(name);
        if (![ax respondsToSelector:selector]) continue;
        for (NSValue *coordinate in @[[NSValue valueWithCGPoint:fixed], [NSValue valueWithCGPoint:upright]]) {
            id hit = PKBounded(0, 0.4, NULL, ^id {
                NSError *error;
                return ((PKElementAtPoint)objc_msgSend)(ax, selector, coordinate.CGPointValue, &error);
            });
            int pid = PKAXPid(hit);
            if (pid > 0) return pid;
        }
    }
    return 0;
}

/// Accept upright or fixed-space AX window frames that sit on the requested display edge.
static CGRect PKWorkspaceFrame(id root, PKDisplayGeometry display, BOOL right) {
    CGRect screen = display.bounds;
    NSMutableArray<NSValue *> *frames = [NSMutableArray array];
    if (root) [frames addObject:[NSValue valueWithCGRect:[root frame]]];
    for (id child in [root children]) {
        if ([PKTypeName([child elementType]) isEqualToString:@"Window"]) [frames addObject:[NSValue valueWithCGRect:[child frame]]];
    }
    CGAffineTransform upright = CGAffineTransformInvert(display.toFixed);
    for (NSValue *value in frames) {
        CGRect reported = value.CGRectValue;
        CGRect framesToCheck[] = {reported, CGRectApplyAffineTransform(reported, upright)};
        for (NSUInteger i = 0; i < 2; i++) {
            CGRect frame = framesToCheck[i];
            if (!CGRectIsNull(PKPeerPane(screen, frame)) && (CGRectGetMidX(frame) > CGRectGetMidX(screen)) == right)
                return CGRectIntersection(screen, frame);
        }
    }
    return CGRectNull;
}

/// Match XCTest's active screens to the current UIKit display in either orientation. One iPhone
/// Duo pane is not a separate physical display; both panes match the same inner screen.
static id PKAutomationScreen(PKDisplayGeometry geometry) {
    Class type = NSClassFromString(@"XCUIScreen");
    id main = [type mainScreen];
    if (!geometry.routesDisplay) return main;
    NSArray *screens = [type respondsToSelector:@selector(screens)] ? [(id)type screens] : nil;
    id matched = nil;
    for (id screen in screens) {
        if (![screen respondsToSelector:@selector(bounds)]) continue;
        CGSize size = [screen bounds].size;
        // XCTest reports pixels; support point-sized bounds too if the platform reports those.
        BOOL pixels = fabs(MIN(size.width, size.height) - MIN(geometry.nativeSize.width, geometry.nativeSize.height)) < 8 &&
                      fabs(MAX(size.width, size.height) - MAX(geometry.nativeSize.width, geometry.nativeSize.height)) < 8;
        CGSize points = geometry.bounds.size;
        BOOL logical = fabs(MIN(size.width, size.height) - MIN(points.width, points.height)) < 4 &&
                       fabs(MAX(size.width, size.height) - MAX(points.width, points.height)) < 4;
        if (!pixels && !logical) continue;
        if (matched) { matched = nil; break; }
        matched = screen;
    }
    if (matched) return matched;
    // The test service can report stale or differently scaled bounds after a fold. Try its active
    // main screen, but only use its image or accept input if the actual pixels match the pane's display.
    return main;
}

static UIImage *PKUprightImage(NSData *data, PKDisplayGeometry geometry) {
    UIImage *image = [UIImage imageWithData:data];
    if (!image.CGImage) return nil;
    CGSize screen = geometry.bounds.size;
    CGSize size = image.size;
    if (fabs((size.width / size.height) / (screen.width / screen.height) - 1) > 0.04) {
        // Some XCTest screenshots are in the fixed display orientation rather than the UI's.
        if (image.imageOrientation != UIImageOrientationUp ||
            fabs((size.height / size.width) / (screen.width / screen.height) - 1) > 0.04) return nil;
        CGAffineTransform t = geometry.toFixed;
        if (fabs(t.b) < 0.5) return nil;
        UIImageOrientation rotation = t.b > 0 ? UIImageOrientationLeft : UIImageOrientationRight;
        image = [UIImage imageWithCGImage:image.CGImage scale:1 orientation:rotation];
    }
    if (image.imageOrientation == UIImageOrientationUp) return image;
    UIGraphicsImageRendererFormat *format = [UIGraphicsImageRendererFormat defaultFormat];
    format.scale = 1;
    format.opaque = YES;
    UIGraphicsImageRenderer *renderer = [[UIGraphicsImageRenderer alloc] initWithSize:image.size format:format];
    return [renderer imageWithActions:^(__unused UIGraphicsImageRendererContext *context) { [image drawAtPoint:CGPointZero]; }];
}

/// The screenshot cut to the viewport: the picture is in pixels, the viewport in points.
static NSData *PKCropped(NSData *data, CGRect viewport, PKDisplayGeometry geometry) {
    CGRect screen = geometry.bounds;
    if (CGRectIsEmpty(screen)) return nil;
    UIImage *image = PKUprightImage(data, geometry);
    if (!image.CGImage) return nil;
    CGFloat w = CGImageGetWidth(image.CGImage), h = CGImageGetHeight(image.CGImage);
    CGFloat sx = w / screen.size.width, sy = h / screen.size.height;
    // A picture from the cover display or with axes exchanged cannot be used for inner-pane taps.
    if (fabs(sx / sy - 1) > 0.04) return nil;
    CGRect rect = CGRectIntegral(CGRectMake((viewport.origin.x - screen.origin.x) * sx,
                                            (viewport.origin.y - screen.origin.y) * sy,
                                            viewport.size.width * sx, viewport.size.height * sy));
    if (!CGRectContainsRect(CGRectMake(0, 0, w, h), rect) || CGRectIsEmpty(rect)) return nil;
    CGImageRef part = CGImageCreateWithImageInRect(image.CGImage, rect);
    if (!part) return nil;
    NSData *out = UIImageJPEGRepresentation([UIImage imageWithCGImage:part], 0.85);
    CGImageRelease(part);
    return out;
}

static NSString *PKMatchText(NSString *text) {
    return [[text.lowercaseString componentsSeparatedByCharactersInSet:NSCharacterSet.alphanumericCharacterSet.invertedSet] componentsJoinedByString:@""];
}

static void PKWindowLabels(id node, NSMutableSet<NSString *> *labels, NSMutableSet<NSString *> *bodyLines) {
    NSString *type = PKTypeName([node elementType]);
    if ([type isEqualToString:@"SecureTextField"] || [type isEqualToString:@"Keyboard"]) return;
    NSString *label = PKMatchText(PKText([node label]) ?: @"");
    if (labels.count < 90 && label.length >= 2 && label.length <= 55) [labels addObject:label];
    // The visible address is commonly the value of Safari's address field rather than its label.
    if ([type isEqualToString:@"TextField"] || [type isEqualToString:@"SearchField"]) {
        NSString *value = PKText([(NSObject *)node value]);
        NSURLComponents *address = [NSURLComponents componentsWithString:value ?: @""];
        if (!address.scheme.length && value.length && [value rangeOfCharacterFromSet:NSCharacterSet.whitespaceAndNewlineCharacterSet].location == NSNotFound)
            address = [NSURLComponents componentsWithString:[@"https://" stringByAppendingString:value]];
        NSString *host = address.host;
        if (labels.count < 90 && host.length >= 8 && host.length <= 64 && [host containsString:@"."]) [labels addObject:PKMatchText(host)];
    }
    // Notes exposes its visible title and body as a single TextView value. These short lines are
    // compared with visible OCR in this process only, never sent to the log or provider here.
    if (bodyLines.count < 16 && [type isEqualToString:@"TextView"]) {
        NSString *value = PKText([(NSObject *)node value]);
        for (NSString *line in [value componentsSeparatedByCharactersInSet:NSCharacterSet.newlineCharacterSet]) {
            NSString *visible = PKMatchText(line);
            if (visible.length >= 8 && visible.length <= 55) [bodyLines addObject:visible];
            if (bodyLines.count >= 16) break;
        }
    }
    if (labels.count >= 90 && bodyLines.count >= 16) return;
    for (id child in [node children]) PKWindowLabels(child, labels, bodyLines);
}

static NSSet<NSString *> *PKWorkspaceLabels(id ax, NSDictionary *candidate) {
    NSMutableSet *labels = [NSMutableSet set];
    NSMutableSet *bodyLines = [NSMutableSet set];
    PKWindowLabels(PKRequestSnapshotWithin(0.85, ax, candidate[@"element"], 24, 600, NULL), labels, bodyLines);
    [labels unionSet:bodyLines];
    return labels;
}

/// Duo can give both AX windows a pane-local origin. Match visible labels to the picture only when
/// the result is unambiguous. The screenshot never leaves this process during this check.
static NSArray<NSSet<NSString *> *> *PKWorkspaceText(UIImage *upright) {
    if (!upright.CGImage) return nil;
    VNRecognizeTextRequest *request = [VNRecognizeTextRequest new];
    request.recognitionLevel = VNRequestTextRecognitionLevelAccurate;
    request.usesLanguageCorrection = NO;
    if (@available(iOS 16.0, *)) request.automaticallyDetectsLanguage = YES;
    VNImageRequestHandler *recognizer = [[VNImageRequestHandler alloc] initWithCGImage:upright.CGImage options:@{}];
    if (![recognizer performRequests:@[request] error:NULL]) return nil;
    NSMutableSet<NSString *> *lines[2] = {[NSMutableSet new], [NSMutableSet new]};
    NSMutableArray<NSDictionary *> *observed[2] = {[NSMutableArray new], [NSMutableArray new]};
    for (VNRecognizedTextObservation *observation in request.results) {
        CGRect box = observation.boundingBox;
        if (CGRectGetMaxX(box) > 0.48 && CGRectGetMinX(box) < 0.52) continue;
        NSString *word = PKMatchText([observation topCandidates:1].firstObject.string ?: @"");
        if (word.length < 2) continue;
        int side = CGRectGetMidX(box) > 0.5;
        [lines[side] addObject:word];
        [observed[side] addObject:@{@"text": word, @"box": [NSValue valueWithCGRect:box]}];
    }
    // A title or filename can wrap in the half-width pane. Preserve the original lines and
    // also reconstruct two rows sharing a leading edge. The matcher counts each AX label once.
    for (int side = 0; side < 2; side++) {
        for (NSDictionary *upper in observed[side]) {
            CGRect a = [upper[@"box"] CGRectValue];
            for (NSDictionary *lower in observed[side]) {
                CGRect b = [lower[@"box"] CGRectValue];
                CGFloat gap = CGRectGetMidY(a) - CGRectGetMidY(b);
                if (gap < CGRectGetHeight(a) * 0.8 || gap > CGRectGetHeight(a) * 2.2 ||
                    fabs(CGRectGetMinX(a) - CGRectGetMinX(b)) > 0.024) continue;
                [lines[side] addObject:[upper[@"text"] stringByAppendingString:lower[@"text"]]];
            }
        }
    }
    return @[lines[0], lines[1]];
}

static NSInteger PKWorkspaceOrder(NSArray<NSSet<NSString *> *> *lines, NSSet *first, NSSet *second) {
    if (lines.count != 2) return 0;
    first = first ?: [NSSet set];
    second = second ?: [NSSet set];
    NSSet *sets[] = {first, second};
    NSInteger matches[2][2] = {{0, 0}, {0, 0}};
    NSInteger exact[2][2] = {{0, 0}, {0, 0}};
    for (NSInteger app = 0; app < 2; app++) {
        NSMutableSet *unique = [sets[app] mutableCopy];
        [unique minusSet:sets[1 - app]];
        NSMutableSet<NSString *> *matched[2] = {[NSMutableSet new], [NSMutableSet new]};
        NSMutableSet<NSString *> *exactLines[2] = {[NSMutableSet new], [NSMutableSet new]};
        for (NSInteger side = 0; side < 2; side++) {
            for (NSString *line in lines[side]) {
                if ([lines[1 - side] containsObject:line]) continue;
                NSString *best = nil;
                for (NSString *label in unique) {
                    if (label.length > best.length && ([label isEqualToString:line] || (label.length >= 3 && [line hasPrefix:label]))) best = label;
                }
                if (best) {
                    [matched[side] addObject:best];
                    if (best.length >= 12 && [best isEqualToString:line]) [exactLines[side] addObject:best];
                }
            }
        }
        // Dragging or typing copied content can put the same title in both apps, with different
        // wrapping. A label that matches both panes is no longer evidence for either side.
        NSMutableSet<NSString *> *shared = [matched[0] mutableCopy];
        [shared intersectSet:matched[1]];
        for (NSInteger side = 0; side < 2; side++) {
            [exactLines[side] minusSet:shared];
            matches[app][side] = matched[side].count - shared.count;
            exact[app][side] = exactLines[side].count;
        }
    }
    NSInteger direct = matches[0][0] + matches[1][1], reversed = matches[0][1] + matches[1][0];
    // The system keyboard and copied content can contribute common labels. Allow the ordinary
    // test when the evidence is unopposed or overwhelmingly supports one order.
    if (direct >= 2 && (reversed == 0 || (reversed <= 2 && direct >= 4 * reversed))) return 1;
    if (reversed >= 2 && (direct == 0 || (direct <= 2 && reversed >= 4 * direct))) return -1;
    // With mixed evidence, require both apps to have fresh, distinctive text on their proposed
    // sides. One app must have two exact lines. A competing exact line or a close score blocks it.
    if (exact[0][1] + exact[1][0] == 0 && exact[0][0] > 0 && exact[1][1] > 0 &&
        exact[0][0] + exact[1][1] >= 3 && direct >= 2 * reversed) return 1;
    if (exact[0][0] + exact[1][1] == 0 && exact[0][1] > 0 && exact[1][0] > 0 &&
        exact[0][1] + exact[1][0] >= 3 && reversed >= 2 * direct) return -1;
    NSLog(@"PokiInProcess: workspace labels %lu/%lu, visible lines %lu/%lu, matches %ld/%ld",
          (unsigned long)first.count, (unsigned long)second.count, (unsigned long)lines[0].count, (unsigned long)lines[1].count,
          (long)direct, (long)reversed);
    return 0;
}

/// The software keyboard covers both panes. Compare the upper content, clear of the keyboard
/// and the system status area, so it can still distinguish the two live windows after typing.
static NSArray<NSData *> *PKWorkspaceAppearance(UIImage *image) {
    CGImageRef raster = image.CGImage;
    if (!raster) return nil;
    CGFloat width = CGImageGetWidth(raster) / 2.0, height = CGImageGetHeight(raster);
    const size_t columns = 24, rows = 20;
    CGColorSpaceRef gray = CGColorSpaceCreateDeviceGray();
    CGContextRef context = CGBitmapContextCreate(NULL, columns, rows, 8, columns, gray, (CGBitmapInfo)kCGImageAlphaNone);
    CGColorSpaceRelease(gray);
    if (!context) return nil;
    NSMutableArray<NSData *> *panes = [NSMutableArray arrayWithCapacity:2];
    CGContextSetInterpolationQuality(context, kCGInterpolationMedium);
    for (NSUInteger side = 0; side < 2; side++) {
        CGRect region = CGRectIntegral(CGRectMake(width * (side + 0.05), height * 0.08, width * 0.90, height * 0.40));
        CGImageRef pane = CGImageCreateWithImageInRect(raster, region);
        if (!pane) break;
        CGContextDrawImage(context, CGRectMake(0, 0, columns, rows), pane);
        [panes addObject:[NSData dataWithBytes:CGBitmapContextGetData(context) length:columns * rows]];
        CGImageRelease(pane);
    }
    CGContextRelease(context);
    return panes.count == 2 ? panes : nil;
}

static double PKAppearanceDifference(NSData *a, NSData *b) {
    if (!a.length || a.length != b.length) return 255;
    const uint8_t *left = a.bytes, *right = b.bytes;
    NSUInteger total = 0;
    for (NSUInteger i = 0; i < a.length; i++) total += abs((int)left[i] - (int)right[i]);
    return (double)total / a.length;
}

static NSInteger PKWorkspaceAppearanceOrder(NSArray<NSData *> *current, NSArray<NSData *> *prior) {
    if (current.count != 2 || prior.count != 2) return 0;
    // Similar-looking panes cannot establish order. Neither can a match that is also plausible
    // on the opposite side. A stable, distinct pane is enough when both live windows still exist.
    if (PKAppearanceDifference(prior[0], prior[1]) < 24) return 0;
    NSInteger order = 0;
    for (NSInteger side = 0; side < 2; side++) {
        double same = PKAppearanceDifference(prior[side], current[side]);
        double opposite = PKAppearanceDifference(prior[side], current[1 - side]);
        NSInteger vote = same <= 9 && opposite >= 24 ? 1 : opposite <= 9 && same >= 24 ? -1 : 0;
        if (order && vote && order != vote) return 0;
        if (vote) order = vote;
    }
    return order;
}

/// One front-app search shared by the tree read and the screenshot PokiCore asks for together.
@interface PKFrontSearch : NSObject
@property (nonatomic) NSTimeInterval started;
@property (nonatomic) NSTimeInterval ended;
@property (nonatomic) uint64_t inputs;
@property (nonatomic, strong) dispatch_group_t done;
@property (nonatomic, strong, nullable) id element;
@property (nonatomic, strong, nullable) id ax;
@property (nonatomic, copy, nullable) NSDictionary *info;
@property (nonatomic, copy, nullable) NSString *code;
@end
@implementation PKFrontSearch
@end

@implementation PKInProcess {
    SRNativeSession *_sessions;
    uint64_t _accessibilityGeneration;
    /// Only where XCTest's local device could not be rebuilt for a reopened session: an AX client
    /// made for that session. nil while the first session lasts, and whenever the device was rebuilt.
    id _freshAX;
    CGRect _viewport;
    PKDisplayGeometry _capturedGeometry;
    CGRect _capturedViewport;
    NSNumber *_capturedDisplay;
    PKWorkspace *_workspace;
    /// Bundle ids by pid, asked of testmanagerd once per process (a round trip each, on every read before).
    NSMutableDictionary<NSNumber *, NSString *> *_bundleByPID;
    uint64_t _bundleGeneration;
    /// What the last tree read found in front, for /wda/activeAppInfo asked right after it (PokiCore
    /// asks for both at once; the second lookup repeated the first's accessibility and daemon round trips).
    NSDictionary<NSString *, id> *_lastFront;
    NSTimeInterval _lastFrontAt;
    uint64_t _lastFrontGeneration;
    /// Counts touches, keys, buttons and app changes; a shared search from before one is not reused.
    uint64_t _inputs;
    PKFrontSearch *_search;
    // Written and read on the main thread. Geometry still comes from the active screen, not the sensor.
    UIDeviceOrientation _lastPhysicalOrientation;
    uint64_t _orientationRevision;
    /// The generation that has answered with an element tree, and the one being checked now.
    uint64_t _readableGeneration, _provingGeneration;
    NSLock *_proofLock;
}

+ (BOOL)canUseDuoSplitView { return PKIsDuo(); }

+ (instancetype)shared {
    static PKInProcess *shared;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ shared = [PKInProcess new]; });
    return shared;
}

- (instancetype)init {
    if ((self = [super init])) { _sessions = [SRNativeSession new]; _viewport = CGRectNull; _proofLock = [NSLock new]; }
    return self;
}

- (void)trackDuoOrientation {
    if (!PKIsDuo()) return;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        UIDevice *device = UIDevice.currentDevice;
        [device beginGeneratingDeviceOrientationNotifications];
        self->_lastPhysicalOrientation = device.orientation;
        [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(duoOrientationChanged:)
                                                    name:UIDeviceOrientationDidChangeNotification object:nil];
    });
}

- (void)duoOrientationChanged:(NSNotification *)notification {
    UIDeviceOrientation orientation = UIDevice.currentDevice.orientation;
    if ((!UIDeviceOrientationIsPortrait(orientation) && !UIDeviceOrientationIsLandscape(orientation)) ||
        orientation == _lastPhysicalOrientation) return;
    _lastPhysicalOrientation = orientation;
    _orientationRevision++;
}

- (uint64_t)generation { return _sessions.generation; }

- (BOOL)developerFrameworksAvailable {
    return [_sessions loadDeveloperFrameworks:nil];
}

- (PKWorkspace *)selectedWorkspace {
    @synchronized (self) { return _workspace; }
}

- (BOOL)hasSelectedPane { return self.selectedWorkspace != nil; }

- (CGRect)otherWorkspacePane {
    PKWorkspace *workspace = self.selectedWorkspace;
    if (!workspace) return CGRectNull;
    return workspace.selectRight ? workspace.left : workspace.right;
}

- (void)setWorkspace:(PKWorkspace *)workspace {
    @synchronized (self) {
        _workspace = workspace;
        _viewport = CGRectNull;
        _capturedDisplay = nil;
        _lastFront = nil;
        _inputs++;
    }
}

- (BOOL)isPokiSceneVisible {
    __block BOOL visible = NO;
    void (^read)(void) = ^{
        for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
            if ([scene isKindOfClass:UIWindowScene.class] &&
                (scene.activationState == UISceneActivationStateForegroundActive || scene.activationState == UISceneActivationStateForegroundInactive)) {
                visible = YES;
                break;
            }
        }
    };
    if (NSThread.isMainThread) read(); else dispatch_sync(dispatch_get_main_queue(), read);
    return visible;
}

/// The observed layout, with AX identity and physical positions independent of keyboard focus.
- (PKWorkspace *)workspaceOn:(PKDisplayGeometry)display ax:(id)ax session:(id)session
                   generation:(uint64_t)generation known:(PKWorkspace *)known elements:(NSArray **)elements {
    if (!PKIsDuo() || !display.routesDisplay || !CGRectIsNull(display.peer) ||
        CGRectGetWidth(display.bounds) <= CGRectGetHeight(display.bounds) || [self isPokiSceneVisible]) return nil;
    NSArray *active = PKActiveApplications(ax);
    if (active.count < 2) return nil;
    CGRect leftProbe, rightProbe;
    CGRectDivide(display.bounds, &leftProbe, &rightProbe, CGRectGetWidth(display.bounds) / 2, CGRectMinXEdge);
    int leftHit = PKPIDAt(ax, leftProbe, display), rightHit = PKPIDAt(ax, rightProbe, display);
    if (leftHit == getpid() || rightHit == getpid()) return nil;
    NSMutableArray<NSDictionary *> *candidates = [NSMutableArray array];
    NSMutableSet<NSNumber *> *seen = [NSMutableSet new];
    for (id element in active) {
        int pid = PKAXPid(element);
        if (pid <= 0 || pid == getpid() || [seen containsObject:@(pid)]) continue;
        [seen addObject:@(pid)];
        NSString *bundle = [self bundleForPID:pid session:session];
        if (!bundle.length || [@[@"com.apple.springboard", @"com.apple.SleepLockScreen"] containsObject:bundle]) continue;
        id root = PKRequestSnapshotWithin(0.6, ax, element, 2, 12, NULL);
        CGRect a = PKWorkspaceFrame(root, display, NO), b = PKWorkspaceFrame(root, display, YES);
        if (CGRectIsNull(a) == CGRectIsNull(b)) continue;
        [candidates addObject:@{@"element": element, @"pid": @(pid), @"left": [NSValue valueWithCGRect:a], @"right": [NSValue valueWithCGRect:b]}];
    }
    if (candidates.count != 2) return nil;
    // iOS may report SpringBoard or the lock-screen compositor at a point on the unlocked
    // inner screen. It is not evidence about either app's position.
    if (leftHit > 0 && [@[@"com.apple.springboard", @"com.apple.SleepLockScreen"] containsObject:[self bundleForPID:leftHit session:session] ?: @""]) leftHit = 0;
    if (rightHit > 0 && [@[@"com.apple.springboard", @"com.apple.SleepLockScreen"] containsObject:[self bundleForPID:rightHit session:session] ?: @""]) rightHit = 0;
    if (leftHit > 0 && leftHit == rightHit) return nil;
    NSDictionary *left = candidates[0], *right = candidates[1];
    NSSet<NSString *> *leftLabels = nil, *rightLabels = nil;
    NSArray<NSData *> *appearance = nil;
    BOOL paneLocal = CGRectIsNull([left[@"right"] CGRectValue]) && CGRectIsNull([right[@"right"] CGRectValue]);
    if (paneLocal) {
        id screen = PKAutomationScreen(display);
        NSData *picture = screen ? ([self daemonJPEGForScreen:screen] ?: [[screen screenshot] PNGRepresentation]) : nil;
        UIImage *upright = PKUprightImage(picture, display);
        NSArray<NSData *> *freshAppearance = PKWorkspaceAppearance(upright);
        if (leftHit > 0 && rightHit > 0) {
            if (![left[@"pid"] isEqual:@(leftHit)]) { NSDictionary *swap = left; left = right; right = swap; }
            appearance = freshAppearance;
        } else {
            int first = [left[@"pid"] intValue], second = [right[@"pid"] intValue];
            BOOL samePair = known.paneLocal && known.generation == generation && PKSameDisplay(known.display, display) &&
                ((first == known.leftPID && second == known.rightPID) || (first == known.rightPID && second == known.leftPID));
            if (samePair) {
                leftLabels = first == known.leftPID ? known.leftLabels : known.rightLabels;
                rightLabels = first == known.leftPID ? known.rightLabels : known.leftLabels;
            }
            NSArray *visible = PKWorkspaceText(upright);
            if (!visible) return nil;
            NSInteger order = PKWorkspaceOrder(visible, leftLabels, rightLabels);
            if (!order) {
                leftLabels = PKWorkspaceLabels(ax, left);
                rightLabels = PKWorkspaceLabels(ax, right);
                order = PKWorkspaceOrder(visible, leftLabels, rightLabels);
            }
            NSInteger visualOrder = samePair ? PKWorkspaceAppearanceOrder(freshAppearance, known.appearance) : 0;
            if (first == known.rightPID) visualOrder = -visualOrder;
            if (order && visualOrder && order != visualOrder) return nil;
            if (order) {
                appearance = freshAppearance;
            } else if (visualOrder) {
                // Keep the independently verified reference. Replacing it on every fallback can
                // let a succession of small changes drift into an unrelated screen.
                order = visualOrder;
                appearance = visualOrder == (first == known.leftPID ? 1 : -1)
                    ? known.appearance : @[known.appearance[1], known.appearance[0]];
            }
            if (!order) return nil;
            if (order < 0) {
                NSDictionary *swap = left; left = right; right = swap;
                NSSet *labels = leftLabels; leftLabels = rightLabels; rightLabels = labels;
            }
        }
    } else if (CGRectIsNull([left[@"left"] CGRectValue])) {
        NSDictionary *swap = left; left = right; right = swap;
    }
    if ((leftHit > 0 && ![left[@"pid"] isEqual:@(leftHit)]) || (rightHit > 0 && ![right[@"pid"] isEqual:@(rightHit)])) return nil;
    CGRect leftFrame = [left[@"left"] CGRectValue], rightFrame = [right[paneLocal ? @"left" : @"right"] CGRectValue];
    if (paneLocal) rightFrame = CGRectOffset(rightFrame, CGRectGetMaxX(display.bounds) - CGRectGetMaxX(rightFrame), 0);
    if (CGRectIsNull(leftFrame) || CGRectIsNull(rightFrame) || CGRectIntersectsRect(leftFrame, rightFrame) ||
        CGRectGetMinX(rightFrame) - CGRectGetMaxX(leftFrame) > 32) return nil;
    PKWorkspace *workspace = [PKWorkspace new];
    workspace.display = display;
    workspace.generation = generation;
    workspace.left = leftFrame;
    workspace.right = rightFrame;
    workspace.leftPID = [left[@"pid"] intValue];
    workspace.rightPID = [right[@"pid"] intValue];
    workspace.paneLocal = paneLocal;
    workspace.leftLabels = leftLabels;
    workspace.rightLabels = rightLabels;
    workspace.appearance = appearance;
    if (elements) *elements = @[left[@"element"], right[@"element"]];
    return workspace;
}

static BOOL PKSameWorkspace(PKWorkspace *a, PKWorkspace *b) {
    return a && b && a.generation == b.generation && PKSameDisplay(a.display, b.display) &&
        a.leftPID == b.leftPID && a.rightPID == b.rightPID && a.paneLocal == b.paneLocal &&
        CGRectEqualToRect(a.left, b.left) && CGRectEqualToRect(a.right, b.right);
}

- (NSDictionary<NSString *, id> *)selectPane:(NSString *)side code:(NSString **)code {
    if ([side isEqualToString:@"auto"]) {
        if (self.selectedWorkspace) [self setWorkspace:nil];
        return @{};
    }
    PKOutcome *refused;
    uint64_t generation = 0;
    id session = [self current:&generation outcome:&refused];
    PKDisplayGeometry display = self.displayGeometry;
    PKWorkspace *workspace = session ? [self workspaceOn:display ax:[self accessibilityFor:generation] session:session generation:generation known:self.selectedWorkspace elements:NULL] : nil;
    if (!workspace || !PKSameDisplay(display, self.displayGeometry)) {
        if (code) *code = @"two visible apps could not be confirmed; open two apps in Split View with Poki in the background";
        return nil;
    }
    workspace.selectRight = [side isEqualToString:@"right"];
    [self setWorkspace:workspace];
    int pid = workspace.selectRight ? workspace.rightPID : workspace.leftPID;
    int otherPID = workspace.selectRight ? workspace.leftPID : workspace.rightPID;
    NSString *identity = [NSString stringWithFormat:@"%@/%llu/%d/%d/%@/%@/%@/%ld/%@/%llu", side, generation, workspace.leftPID,
                          workspace.rightPID, NSStringFromCGRect(workspace.left), NSStringFromCGRect(workspace.right),
                          NSStringFromCGAffineTransform(workspace.display.toFixed), (long)workspace.display.orientation,
                          NSStringFromCGSize(workspace.display.nativeSize),
                          workspace.display.orientationRevision];
    return @{@"bundleId": [self bundleForPID:pid session:session] ?: @"", @"otherBundleId": [self bundleForPID:otherPID session:session] ?: @"",
             @"identity": identity, @"x": @(CGRectGetMinX(workspace.selectRight ? workspace.right : workspace.left)),
             @"y": @(CGRectGetMinY(workspace.selectRight ? workspace.right : workspace.left))};
}

- (NSString *)validateSelectedPane {
    PKWorkspace *selected = self.selectedWorkspace;
    if (!selected) return nil;
    PKOutcome *refused;
    uint64_t generation = 0;
    id session = [self current:&generation outcome:&refused];
    PKDisplayGeometry display = self.displayGeometry;
    PKWorkspace *current = session ? [self workspaceOn:display ax:[self accessibilityFor:generation] session:session generation:generation known:selected elements:NULL] : nil;
    if (selected != self.selectedWorkspace || !PKSameWorkspace(selected, current) || !PKSameDisplay(display, self.displayGeometry))
        return @"the Split View apps or layout changed; look at the target pane again";
    return nil;
}

- (NSDictionary<NSString *, id> *)prepare {
    NSError *error;
    NSTimeInterval started = NSProcessInfo.processInfo.systemUptime;
    id session = nil;
    @try {
        session = [_sessions prepare:&error];
    } @catch (NSException *exception) {
        return @{@"ok": @NO, @"code": @"exception", @"detail": [NSString stringWithFormat:@"%@: %@", exception.name, exception.reason ?: @""]};
    }
    double seconds = NSProcessInfo.processInfo.systemUptime - started;
    if (!session) {
        const char *loader = dlerror();
        NSString *detail = error.localizedDescription ?: @"no session";
        if (loader) detail = [detail stringByAppendingFormat:@" (%s)", loader];
        NSString *code = [error.domain isEqualToString:@"RecoveredNative"] ? error.localizedDescription : [NSString stringWithFormat:@"%@ %ld", error.domain ?: @"unknown", (long)error.code];
        return @{@"ok": @NO, @"code": code ?: @"unknown", @"detail": detail, @"seconds": @(seconds)};
    }
    // Ready means readable: a session that is enabled but answers no element tree is not handed out
    // (issue 347: such a session was reported ready, and every read after it failed).
    uint64_t generation = _sessions.generation;
    double warm = 0;
    NSString *unreadable = [self unreadableReason:generation warm:&warm];
    if (unreadable) {
        return @{@"ok": @NO, @"code": @"session_unreadable", @"detail": unreadable, @"generation": @(generation),
                 @"seconds": @(seconds), @"warm_seconds": @(warm), @"device": [_sessions rebindDetail] ?: @"first"};
    }
    return @{@"ok": @YES, @"generation": @(generation), @"reused": @(_sessions.enableWasReused), @"seconds": @(seconds), @"warm_seconds": @(warm),
             @"device": [_sessions rebindDetail] ?: @"first"};
}

- (double)authorizationWaitSeconds { return [_sessions enablingSeconds]; }

/// nil once this generation has answered with an element tree (checked once per generation), else
/// why it has not. A generation that cannot read is closed, so nothing reuses it and the next
/// prepare opens a new session.
- (nullable NSString *)unreadableReason:(uint64_t)generation warm:(double *)warm {
    // The check's own lookups come back through -current:outcome: and pass.
    @synchronized (self) { if (_readableGeneration == generation || _provingGeneration == generation) return nil; }
    [_proofLock lock];
    @try {
        @synchronized (self) {
            if (_readableGeneration == generation) return nil;
            _provingGeneration = generation;
        }
        NSTimeInterval started = NSProcessInfo.processInfo.systemUptime;
        NSString *why = [self proveReadable:generation];
        if (warm) *warm = NSProcessInfo.processInfo.systemUptime - started;
        @synchronized (self) {
            _provingGeneration = 0;
            if (!why) _readableGeneration = generation;
        }
        if (why) {
            NSLog(@"PokiInProcess: session generation %llu cannot read (%@): closing it", generation, why);
            if (_sessions.generation == generation) [_sessions close];
        }
        return why;
    } @finally {
        [_proofLock unlock];
    }
}

/// One read of a new session, which also pays for the accessibility client's first snapshot and
/// XCUIScreen's first screenshot (the gym: the agent's first look after prepare took 8.1 s and came
/// with no tree and no picture; the next read took 1.6 s). The system application's tree is what
/// proves the session: it answers whatever is in front, so an app that is slow or hung is not taken
/// for a broken session. nil when it read.
- (nullable NSString *)proveReadable:(uint64_t)generation {
    if (self.failNextReadinessCheck) {
        self.failNextReadinessCheck = NO;
        return @"no element tree (failure asked for by the readiness test)";
    }
    @try {
        id ax = [self accessibilityFor:generation];
        if (!ax) return @"no accessibility client";
        // Whether testmanagerd turned accessibility on for this session. On the simulator the load
        // answers no and reads work, so it is not asked for there.
        BOOL loaded = YES;
#if !TARGET_OS_SIMULATOR
        @synchronized (self) { loaded = _accessibilityGeneration == generation || ![ax respondsToSelector:@selector(loadAccessibility:)]; }
#endif
        id system = [ax respondsToSelector:@selector(systemApplication)] ? [ax systemApplication] : nil;
        NSString *code = nil;
        id root = system ? PKRequestSnapshotWithin(3, ax, system, 1, 1, &code) : nil;
        id client = nil;
        NSString *frontCode = nil;
        id app = [self front:NULL ax:&client code:&frontCode];
        // The front app's first snapshot is paid for here. With accessibility loaded, its own
        // timeout is the app's and not the session's.
        NSString *appCode = nil;
        id appRoot = (app && client) ? PKRequestSnapshotWithin(3, client, app, 3, 30, &appCode) : nil;
        if (!root && !appRoot) {
            return [NSString stringWithFormat:@"no element tree from the system or from the app in front (%@)", code ?: appCode ?: frontCode ?: @"no answer"];
        }
        // Accessibility did not load (issue 347's reopened sessions): only a tree from the app in
        // front itself shows that this session reads all the same.
        if (!loaded && !appRoot) {
            return [NSString stringWithFormat:@"accessibility did not load for this session, and the app in front gave no element tree (%@)", appCode ?: frontCode ?: @"no answer"];
        }
        NSString *shot = nil;
        [self screenshot:&shot];
        if (shot) NSLog(@"PokiInProcess: session generation %llu reads its tree; its first picture failed (%@)", generation, shot);
        return nil;
    } @catch (NSException *exception) {
        return [NSString stringWithFormat:@"%@: %@", exception.name, exception.reason ?: @""];
    }
}

- (NSDictionary<NSString *, id> *)close {
    NSTimeInterval started = NSProcessInfo.processInfo.systemUptime;
    uint64_t generation = _sessions.generation;
    BOOL closed = [_sessions close];
    return @{@"closed": @(closed), @"generation": @(generation), @"seconds": @(NSProcessInfo.processInfo.systemUptime - started),
             @"detail": [_sessions closeDetail] ?: @""};
}

/// Standing by with the session kept: nobody watches it, and the owner can end Automation Mode from iOS's
/// banner meanwhile (the reads then fail as "no_front_app"). The next prepare proves it reads again.
- (NSDictionary<NSString *, id> *)pauseAutomation {
    NSDictionary *result = [_sessions pauseAutomation];
    @synchronized (self) { _readableGeneration = 0; }
    return result;
}

/// The prepared session and its generation, or why there is none.
- (id)current:(uint64_t *)generation outcome:(PKOutcome **)outcome {
    NSError *error;
    id session = nil;
    @try {
        session = [_sessions prepare:&error];
    } @catch (NSException *exception) {
        *outcome = [PKOutcome delivery:PKDeliveryNotSent code:@"exception" detail:exception.reason];
        return nil;
    }
    *generation = _sessions.generation;
    if (!session) { *outcome = [PKOutcome delivery:PKDeliveryNotSent code:error.localizedDescription ?: @"no_session" detail:nil]; return nil; }
    // A session opened here (testmanagerd ended the last one) reads before anything is sent to it.
    NSString *unreadable = [self unreadableReason:*generation warm:NULL];
    if (unreadable) {
        *outcome = [PKOutcome delivery:PKDeliveryNotSent code:@"session_unreadable" detail:unreadable];
        return nil;
    }
    return session;
}

- (SRActionContext *)contextFor:(id)session generation:(uint64_t)generation {
    SRNativeSession *sessions = _sessions;
    return [[SRActionContext alloc] initWithOperationID:NSUUID.UUID.UUIDString currentOwner:^BOOL {
        return [sessions isCurrent:session generation:generation];
    }];
}

/// Waits for the one reply of a dispatched action.
- (PKOutcome *)await:(SRActionContext *)context timeout:(double)timeout started:(NSTimeInterval)started generation:(uint64_t)generation {
    dispatch_semaphore_t done = dispatch_semaphore_create(0);
    [context whenRepliesDrain:^{ dispatch_semaphore_signal(done); }];
    BOOL answered = dispatch_semaphore_wait(done, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(timeout * NSEC_PER_SEC))) == 0;
    PKOutcome *outcome;
    if (!answered) {
        outcome = [PKOutcome delivery:PKDeliveryUnknown code:@"reply_timeout" detail:[NSString stringWithFormat:@"no reply from testmanagerd within %.1f s", timeout]];
    } else {
        id accepted = context.evidence[@"inputAccepted"];
        BOOL ok = [accepted isKindOfClass:NSNumber.class] && [accepted boolValue];
        outcome = ok ? [PKOutcome delivery:PKDeliverySent code:nil detail:nil]
                     : [PKOutcome delivery:PKDeliveryUnknown code:@"reply_error" detail:@"testmanagerd answered with an error"];
    }
    outcome.seconds = NSProcessInfo.processInfo.systemUptime - started;
    outcome.generation = generation;
    return outcome;
}

- (PKOutcome *)touch:(NSArray<NSArray<PKTouchPoint *> *> *)fingers timeout:(double)timeout {
    return [self touch:fingers timeout:timeout geometry:(PKDisplayGeometry){CGRectNull, CGRectNull, CGSizeZero, CGAffineTransformIdentity, UIInterfaceOrientationPortrait, NO, NO, 0}];
}

- (PKOutcome *)touch:(NSArray<NSArray<PKTouchPoint *> *> *)fingers timeout:(double)timeout geometry:(PKDisplayGeometry)geometry {
    NSString *workspaceFailure = [self validateSelectedPane];
    if (workspaceFailure) return [PKOutcome delivery:PKDeliveryNotSent code:@"split_view_changed" detail:workspaceFailure];
    PKWorkspace *workspace = self.selectedWorkspace;
    [self forgetFront];
    PKOutcome *refused;
    uint64_t generation = 0;
    id session = [self current:&generation outcome:&refused];
    if (!session) return refused;
    Class pathClass = NSClassFromString(@"XCPointerEventPath");
    Class recordClass = NSClassFromString(@"XCSynthesizedEventRecord");
    if (!fingers.count || !PKInstanceSignature(pathClass, @selector(initForTouchAtPoint:offset:), "@", @[@"{CGPoint=dd}", @"d"]) ||
        !PKInstanceSignature(pathClass, @selector(moveToPoint:atOffset:), "v", @[@"{CGPoint=dd}", @"d"]) ||
        !PKInstanceSignature(pathClass, @selector(liftUpAtOffset:), "v", @[@"d"])) {
        return [PKOutcome delivery:PKDeliveryNotSent code:@"touch_event_abi_mismatch" detail:@"XCPointerEventPath has no touch path with the expected signature"];
    }
    BOOL oriented = PKInstanceSignature(recordClass, @selector(initWithName:interfaceOrientation:), "@", @[@"@", @"q"]);
    if (!oriented && ![recordClass instancesRespondToSelector:@selector(initWithName:)]) {
        return [PKOutcome delivery:PKDeliveryNotSent code:@"event_api_unavailable" detail:@"no XCSynthesizedEventRecord"];
    }
    id record;
    if (geometry.routesDisplay) {
        id screen = PKAutomationScreen(geometry);
        BOOL confirmed;
        @synchronized (self) {
            confirmed = [screen respondsToSelector:@selector(displayID)] && [_capturedDisplay isEqual:@([screen displayID])] &&
                PKSameDisplay(geometry, _capturedGeometry) && CGRectEqualToRect(_viewport, _capturedViewport);
        }
        if (!confirmed) return [PKOutcome delivery:PKDeliveryNotSent code:@"target_display_unavailable" detail:@"look again to confirm the current display"];
        // The orientation-only initializer encodes display 0, even when XCTest now considers
        // the inner panel its main screen. Dispatch to the same display the crop came from.
        SEL selector = @selector(initWithName:displayID:interfaceOrientation:);
        if (!PKInstanceSignature(recordClass, selector, "@", @[@"@", @"Q", @"q"]) &&
            !PKInstanceSignature(recordClass, selector, "@", @[@"@", @"q", @"q"])) {
            return [PKOutcome delivery:PKDeliveryNotSent code:@"target_display_input_unavailable" detail:nil];
        }
        record = [[recordClass alloc] initWithName:@"Poki touch" displayID:(unsigned long long)[screen displayID] interfaceOrientation:geometry.orientation];
    } else {
        record = oriented ? [[recordClass alloc] initWithName:@"Poki touch" interfaceOrientation:geometry.orientation] : [[recordClass alloc] initWithName:@"Poki touch"];
    }
    if (![record respondsToSelector:@selector(addPointerEventPath:)]) {
        return [PKOutcome delivery:PKDeliveryNotSent code:@"event_dispatch_api_unavailable" detail:@"XCSynthesizedEventRecord cannot take a path"];
    }
    for (NSArray<PKTouchPoint *> *finger in fingers) {
        if (!finger.count) return [PKOutcome delivery:PKDeliveryNotSent code:@"invalid_touch" detail:@"a finger without points"];
        id path = [[pathClass alloc] initForTouchAtPoint:CGPointApplyAffineTransform(finger.firstObject.point, geometry.toFixed) offset:finger.firstObject.offset];
        for (NSUInteger i = 1; i < finger.count; i++) [path moveToPoint:CGPointApplyAffineTransform(finger[i].point, geometry.toFixed) atOffset:finger[i].offset];
        [path liftUpAtOffset:finger.lastObject.offset];
        [record addPointerEventPath:path];
    }
    id proxy = [session respondsToSelector:@selector(daemonProxy)] ? [session daemonProxy] : nil;
    SEL dispatch = @selector(_XCT_synthesizeEvent:implicitConfirmationInterval:completion:);
    if (!proxy || !PKSignature(proxy, dispatch, "v", @[@"@", @"d", @"@?"])) {
        return [PKOutcome delivery:PKDeliveryNotSent code:@"event_dispatch_abi_mismatch" detail:@"the daemon proxy has no event synthesis with the expected signature"];
    }
    if (geometry.routesDisplay && !PKSameDisplay(geometry, self.displayGeometry))
        return [PKOutcome delivery:PKDeliveryNotSent code:@"split_view_changed" detail:@"the display changed before dispatch"];
    SRActionContext *context = [self contextFor:session generation:generation];
    NSError *error;
    if (![context commit:&error]) return [PKOutcome delivery:PKDeliveryNotSent code:error.localizedDescription detail:nil];
    NSTimeInterval started = NSProcessInfo.processInfo.systemUptime;
    [context beginReply];
    [proxy _XCT_synthesizeEvent:record implicitConfirmationInterval:0 completion:^(NSError *replyError) {
        (void)[record class];
        [context receiveReply:replyError];
    }];
    [context markDispatched];
    PKOutcome *outcome = [self await:context timeout:timeout started:started generation:generation];
    if (workspace && (workspace != self.selectedWorkspace || !PKSameDisplay(geometry, self.displayGeometry)))
        return [PKOutcome delivery:PKDeliveryUnknown code:@"split_view_changed_after_dispatch" detail:@"verify where the gesture landed"];
    return outcome;
}

- (PKOutcome *)type:(NSString *)text timeout:(double)timeout {
    return [self type:text typingSpeed:120 timeout:timeout];
}

- (PKOutcome *)type:(NSString *)text typingSpeed:(NSUInteger)speed timeout:(double)timeout {
    PKWorkspace *workspace = self.selectedWorkspace;
    if (workspace) {
        if (!PKSameDisplay(workspace.display, self.displayGeometry))
            return [PKOutcome delivery:PKDeliveryNotSent code:@"split_view_changed" detail:@"the display changed before typing"];
        if (![self selectedPaneHasKeyboardFocus]) {
            return [PKOutcome delivery:PKDeliveryNotSent code:@"split_view_focus_unconfirmed"
                                   detail:@"focus a text field in the selected pane before typing"];
        }
    }
    [self forgetFront];
    PKOutcome *refused;
    uint64_t generation = 0;
    id session = [self current:&generation outcome:&refused];
    if (!session) return refused;
    SRActionContext *context = [self contextFor:session generation:generation];
    NSTimeInterval started = NSProcessInfo.processInfo.systemUptime;
    NSError *error;
    if (workspace && !PKSameDisplay(workspace.display, self.displayGeometry))
        return [PKOutcome delivery:PKDeliveryNotSent code:@"split_view_changed" detail:@"the display changed before typing"];
    if (!SRInsertTextAtSpeed(session, text, speed, context, &error)) {
        return [PKOutcome delivery:PKDeliveryNotSent code:error.localizedDescription ?: @"text_not_sent" detail:nil];
    }
    PKOutcome *outcome = [self await:context timeout:timeout started:started generation:generation];
    if (workspace && !PKSameDisplay(workspace.display, self.displayGeometry))
        return [PKOutcome delivery:PKDeliveryUnknown code:@"split_view_changed_after_dispatch" detail:@"verify the field before trying again"];
    return outcome;
}

- (BOOL)selectedPaneHasKeyboardFocus {
    PKWorkspace *workspace = self.selectedWorkspace;
    if (!workspace) return NO;
    NSDictionary *info = nil;
    id ax = nil;
    id element = [self sharedFront:&info ax:&ax code:NULL];
    if (!element || workspace != self.selectedWorkspace) return NO;
    id root = PKRequestSnapshotWithin(1.4, ax, element, 24, 600, NULL);
    if (!root) return NO;
    CGRect pane = workspace.selectRight ? workspace.right : workspace.left;
    if (workspace.paneLocal) pane.origin = CGPointZero;
    NSMutableArray *nodes = [NSMutableArray arrayWithObject:root];
    while (nodes.count) {
        id node = nodes.lastObject;
        [nodes removeLastObject];
        NSString *type = PKTypeName([node elementType]);
        if ([type hasSuffix:@"Field"] || [type isEqualToString:@"TextView"]) {
            BOOL focused = [node respondsToSelector:@selector(hasKeyboardFocus)] ? [node hasKeyboardFocus] :
                [node respondsToSelector:@selector(hasFocus)] && [node hasFocus];
            if (focused && CGRectIntersectsRect([node frame], pane)) return workspace == self.selectedWorkspace;
        }
        NSArray *children = [node children];
        if (children.count) [nodes addObjectsFromArray:children];
    }
    return NO;
}

/// The screen as a JPEG from testmanagerd, as WebDriverAgent asks for it, or nil within 1.5 s.
- (nullable NSData *)daemonJPEGForScreen:(id)screen {
    PKOutcome *refused;
    uint64_t generation = 0;
    id session = [self current:&generation outcome:&refused];
    id proxy = [session daemonProxy];
    if (!proxy || ![screen respondsToSelector:@selector(displayID)]) return nil;
    long long display = [screen displayID];
    dispatch_semaphore_t got = dispatch_semaphore_create(0);
    __block NSData *data;
    @try {
        [proxy _XCT_requestScreenshotOfScreenWithID:display withRect:CGRectNull uti:@"public.jpeg" compressionQuality:0.6 withReply:^(NSData *value, NSError *error) {
            data = value; dispatch_semaphore_signal(got);
        }];
    } @catch (__unused NSException *e) { return nil; }
    if (dispatch_semaphore_wait(got, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.5 * NSEC_PER_SEC)))) return nil;
    return data.length ? data : nil;
}

- (nullable NSData *)screenshot:(NSString **)code {
    return [self screenshot:code refreshViewport:YES];
}

- (nullable NSData *)screenshot:(NSString **)code refreshViewport:(BOOL)refreshViewport {
    @try {
        NSTimeInterval started = NSProcessInfo.processInfo.systemUptime;
        PKDisplayGeometry geometry = self.displayGeometry;
        PKWorkspace *selected = self.selectedWorkspace;
        NSDictionary *workspaceFront = nil;
        if (selected && !refreshViewport) { if (code) *code = @"target_pane_unconfirmed"; return nil; }
        if (selected && ![self sharedFront:&workspaceFront ax:NULL code:code]) return nil;
        id screen = PKAutomationScreen(geometry);
        if (!screen) { if (code) *code = @"target_display_unavailable"; return nil; }
        // A JPEG from testmanagerd (what WebDriverAgent uses): a fraction of the PNG's bytes to
        // encode, send and decode; PokiCore makes its own 402-pixel JPEG from any image. XCTest's
        // quality API next, then the PNG. (The quality API was not there on the CI simulator: every
        // picture was a 190 KB PNG at ~220 ms.)
        NSData *picture = nil;
        NSString *kind = @"png";
        // Three misses in a row and the daemon is not asked again in this process.
        static int daemonMisses = 0;
        if (daemonMisses < 3) {
            picture = [self daemonJPEGForScreen:screen];
            if (picture.length) { kind = @"daemon jpeg"; daemonMisses = 0; } else daemonMisses++;
        }
        SEL quality = NSSelectorFromString(@"screenshotDataForQuality:rect:error:");
        NSString *rect = @"{CGRect={CGPoint=dd}{CGSize=dd}}";
        if (!picture.length && [screen respondsToSelector:quality] && (PKMatches([screen methodSignatureForSelector:quality], "@", @[@"Q", rect, @"^@"]) || PKMatches([screen methodSignatureForSelector:quality], "@", @[@"q", rect, @"^@"]))) {
            NSError *error = nil;
            picture = ((NSData *(*)(id, SEL, NSUInteger, CGRect, NSError **))objc_msgSend)(screen, quality, 1, CGRectNull, &error);
            if (picture.length) kind = @"jpeg";
        }
        if (!picture.length) picture = [[screen screenshot] PNGRepresentation];
        if (picture.length) {
            NSLog(@"PokiInProcess timing: screenshot %d ms, %lu bytes (%@)", (int)lround((NSProcessInfo.processInfo.systemUptime - started) * 1000), (unsigned long)picture.length, kind);
            // Read the crop before exposing any pixels to PokiCore. Share the target lookup with
            // the tree read; during a held request use only a previously confirmed split crop.
            PKDisplayGeometry current = self.displayGeometry;
            if ((selected || !CGRectIsNull(geometry.peer) || !CGRectIsNull(current.peer)) &&
                (selected != self.selectedWorkspace || !PKSameDisplay(geometry, current))) {
                if (code) *code = @"display_changed_during_screenshot";
                return nil;
            }
            CGRect viewport = geometry.peer;
            if (selected) {
                if (!workspaceFront[@"pane"]) { if (code) *code = @"target_pane_unconfirmed"; return nil; }
                viewport = [self noteViewport:CGRectNull confirmedPane:workspaceFront[@"pane"] geometry:geometry];
            } else if (geometry.panePlacementKnown) {
                viewport = [self noteViewport:CGRectNull confirmedPane:nil geometry:geometry];
            } else if (refreshViewport) {
                NSDictionary *info = nil; id ax;
                id element = [self sharedFront:&info ax:&ax code:NULL];
                id root = element ? PKRequestSnapshotWithin(1, ax, element, 1, 3, NULL) : nil;
                CGRect target = PKTargetFrame(root, geometry.bounds);
                viewport = [self noteViewport:target confirmedPane:info[@"pane"] geometry:geometry];
                if (!CGRectIsNull(geometry.peer) && CGRectIsNull(viewport)) {
                    if (code) *code = @"target_pane_unconfirmed";
                    return nil;
                }

            } else {
                if (!CGRectIsNull(geometry.peer)) { if (code) *code = @"target_pane_unconfirmed"; return nil; }
                viewport = self.viewport;
            }
            if (CGRectIsNull(viewport) && !geometry.routesDisplay) return picture;
            NSData *cropped = PKCropped(picture, CGRectIsNull(viewport) ? geometry.bounds : viewport, geometry);
            if (!cropped) {
                if (code) *code = @"screenshot_does_not_match_active_display";
#if __IPHONE_OS_VERSION_MAX_ALLOWED < 270100
                // Linked against an SDK before iOS 27.1, Poki is letterboxed on both displays of
                // a Duo: its UIScreen is the letterbox, and the picture is the whole panel (#419).
                if (code && PKIsDuo() && CGRectIsNull(viewport)) *code = @"duo_needs_ios_27_1_sdk_build";
#endif
                UIImage *seen = [UIImage imageWithData:picture];
                NSLog(@"PokiInProcess: picture %.0fx%.0f px does not fit display %.0fx%.0f pt (native %.0fx%.0f px), viewport %@",
                      seen.size.width * seen.scale, seen.size.height * seen.scale, geometry.bounds.size.width, geometry.bounds.size.height,
                      geometry.nativeSize.width, geometry.nativeSize.height, NSStringFromCGRect(viewport));
            } else if (geometry.routesDisplay && [screen respondsToSelector:@selector(displayID)]) {
                @synchronized (self) {
                    _capturedGeometry = geometry;
                    _capturedViewport = viewport;
                    _capturedDisplay = @([screen displayID]);
                }
            }
            return cropped;
        }
        if (code) *code = @"no_picture";
    } @catch (NSException *e) {
        if (code) *code = [NSString stringWithFormat:@"%@: %@", e.name, e.reason];
    }
    return nil;
}

/// The bundle id testmanagerd gives for a pid, or nil within a second.
- (nullable NSString *)bundleForPID:(int)pid session:(id)session {
    uint64_t generation = _sessions.generation;
    @synchronized (self) {
        if (_bundleGeneration != generation || !_bundleByPID) { _bundleByPID = [NSMutableDictionary dictionary]; _bundleGeneration = generation; }
        NSString *known = _bundleByPID[@(pid)];
        if (known) return known;
    }
    dispatch_semaphore_t got = dispatch_semaphore_create(0);
    __block NSString *bundle;
    [[session daemonProxy] _XCT_requestBundleIDForPID:pid reply:^(NSString *value, NSError *error) {
        bundle = value; dispatch_semaphore_signal(got);
    }];
    dispatch_semaphore_wait(got, dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC));
    // A pid keeps its bundle for the process's life; the cache goes with the session's generation.
    if (bundle.length) { @synchronized (self) { if (_bundleGeneration == generation) _bundleByPID[@(pid)] = bundle; } }
    return bundle;
}

/// The front app the last tree read found, served once and only when under a second old with no
/// input since (nil otherwise): PokiCore asks /wda/activeAppInfo together with /source, and that one
/// answer comes from the tree read. A poll (a launch waiting for its app) always looks again.
- (nullable NSDictionary<NSString *, id> *)takeRecentFront {
    @synchronized (self) {
        NSDictionary *front = _lastFront;
        _lastFront = nil;
        if (!front || _lastFrontGeneration != _sessions.generation) return nil;
        if (NSProcessInfo.processInfo.systemUptime - _lastFrontAt > 1.0) return nil;
        return front;
    }
}

/// Any touch, key, button or app change can change the front app: the tree read's no longer stands.
- (void)forgetFront {
    @synchronized (self) { _lastFront = nil; _inputs++; }
}

static const NSTimeInterval PKWorkspaceFrontSeconds = 4.0;

/// The front app's element for a tree read or a screenshot: a search still running, or ended under
/// 150 ms ago with no input since, is waited for and shared (the two requests come together on two
/// queues, and each searched on its own: ~220 ms of AX round trips twice per read). A poll a while
/// later searches again.
- (id)sharedFront:(NSDictionary **)info ax:(id *)client code:(NSString **)code {
    PKFrontSearch *search;
    BOOL mine = NO;
    NSTimeInterval now = NSProcessInfo.processInfo.systemUptime;
    NSTimeInterval shareSeconds = self.selectedWorkspace ? PKWorkspaceFrontSeconds : 1.5;
    @synchronized (self) {
        PKFrontSearch *last = _search;
        if (last && last.inputs == _inputs && (last.ended == 0 || now - last.ended < 0.15) && now - last.started < shareSeconds) {
            search = last;
        } else {
            search = [PKFrontSearch new];
            search.started = now;
            search.inputs = _inputs;
            search.done = dispatch_group_create();
            dispatch_group_enter(search.done);
            _search = search;
            mine = YES;
        }
    }
    if (mine) {
        NSDictionary *found = nil;
        id ax = nil;
        id element = nil;
        NSString *why = nil;
        @try { element = [self front:&found ax:&ax code:&why]; } @catch (__unused NSException *e) {}
        search.element = element; search.ax = ax; search.info = found; search.code = why;
        search.ended = NSProcessInfo.processInfo.systemUptime;
        dispatch_group_leave(search.done);
    } else if (dispatch_group_wait(search.done, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(shareSeconds * NSEC_PER_SEC)))) {
        return [self front:info ax:client code:code];
    }
    if (info) *info = search.info;
    if (client) *client = search.ax;
    if (code && !search.element) *code = search.code;
    return search.element;
}

- (void)rememberFront:(NSDictionary<NSString *, id> *)front {
    @synchronized (self) {
        _lastFront = front;
        _lastFrontAt = NSProcessInfo.processInfo.systemUptime;
        _lastFrontGeneration = _sessions.generation;
    }
}

/// The AX client, after asking testmanagerd once per session to turn accessibility on in every app, as
/// XCUIApplication does when a UI test launches one. Without it a third-party app's tree is
/// kAXErrorServerNotFound; system apps such as Settings answer either way.
- (id)accessibilityFor:(uint64_t)generation {
    // Once accessibility is on, every AX notification (an app activating, for one) reaches
    // -[XCAXClient_iOS handleAccessibilityNotification:fromElement:payload:], which asks
    // XCUIApplicationMonitor for an XCUIApplication on the main queue; that throws outside a UI test
    // and ends Poki (seen on the phone). Poki reads on request and needs none of them.
    static dispatch_once_t quiet;
    dispatch_once(&quiet, ^{
        Class client = NSClassFromString(@"XCAXClient_iOS");
        SEL selector = NSSelectorFromString(@"handleAccessibilityNotification:fromElement:payload:");
        Method method = client ? class_getInstanceMethod(client, selector) : NULL;
        // The notification is a number, not an object (1021 came in on the simulator): the arguments
        // are taken as plain pointers so that nothing is retained, or a Debug build crashes on it.
        if (method) method_setImplementation(method, imp_implementationWithBlock(^(__unused void *me, __unused void *notification, __unused void *element, __unused void *payload) {}));
    });
    id ax = PKAXClient();
    @synchronized (self) {
        if (_accessibilityGeneration != 0 && _accessibilityGeneration != generation) {
            // A new session after a close: requests the old one left hanging never return, so the
            // pids they marked unresponsive (the accessibility server's among them) are asked again.
            @synchronized (PKHungLock()) { [PKHungSince() removeAllObjects]; }
            // The AX client is the one of the local device SRNativeSession rebuilt on the new session
            // (`ax` above already is). A client made here with plain -init is not one: XCAXClient_iOS
            // has no -init of its own on iOS 27, so its remoteAccessibilityInterface and queue were
            // nil, loadAccessibility went to nil and no reply ever came (issue 347: "pid 0 gets no
            // answer for 4 s" on every reopened session). Where the device cannot be rebuilt, the
            // client is made with its real initializer on the new session; plain -init is the last
            // resort for an XCTest that has neither (the CI simulator's read after a reopen with it).
            _freshAX = nil;
            if (![_sessions deviceRebuilt]) @try {
                Class client = NSClassFromString(@"XCAXClient_iOS");
                SEL designated = NSSelectorFromString(@"initWithApplicationProcessTracker:remoteAccessibilityInterface:device:");
                id device = [NSClassFromString(@"XCUIDevice") sharedDevice];
                id session = [NSClassFromString(@"XCTRunnerDaemonSession") sharedSession];
                id fresh = nil;
                if (session && [client instancesRespondToSelector:designated] &&
                    PKMatches([client instanceMethodSignatureForSelector:designated], "@", @[@"@", @"@", @"@"])) {
                    id tracker = [device respondsToSelector:@selector(applicationMonitor)] ? [device applicationMonitor] : nil;
                    fresh = [[client alloc] initWithApplicationProcessTracker:tracker remoteAccessibilityInterface:session device:device];
                } else if ([client instancesRespondToSelector:@selector(init)]) {
                    fresh = [[client alloc] init];
                }
                if (fresh) { _freshAX = fresh; ax = fresh; }
            } @catch (NSException *e) {
                NSLog(@"PokiInProcess: no AX client of its own for session generation %llu: %@", generation, e.reason);
            }
            NSLog(@"PokiInProcess: session generation %llu: hung marks cleared, AX client of %@", generation,
                  [_sessions deviceRebuilt] ? @"the rebuilt device" : _freshAX ? @"its own (no device rebuild)" : @"the old device");
        }
        if (_freshAX) ax = _freshAX;
        if (_accessibilityGeneration != generation && [ax respondsToSelector:@selector(loadAccessibility:)]) {
            __block NSString *why = nil;
            NSNumber *loaded = PKBounded(0, 4, NULL, ^id { NSError *error; BOOL done = [ax loadAccessibility:&error]; why = error.localizedDescription; return @(done); });
            if (loaded.boolValue) _accessibilityGeneration = generation;
            // Whether third-party apps can be read at all (kAXErrorServerNotFound without it).
            NSLog(@"PokiInProcess: accessibility for session generation %llu: %@", generation, loaded.boolValue ? @"loaded" : [NSString stringWithFormat:@"not loaded (%@)", why ?: (loaded ? @"refused" : @"no answer in 4 s")]);
        }
    }
    return ax;
}

/// A lookup of the app in front gets 2 s in all: PokiCore waits 2 s for /wda/activeAppInfo, so a longer
/// lookup is never used, and the 4 s of a tree read keep 2 s for the snapshot. Ordinary lookups take
/// 0.2 to 0.3 s (the slowest outside a hang in the ESP-464 system log: 1.1 s). Without it the lookup
/// had no deadline as a whole: on the phone the active applications went unanswered for 4 s, and the
/// system application, asked after them with no deadline of its own, held the lookup 28 s more (and
/// with it the read, and Poki's queue). Given up, the lookup goes on on its own thread, and later
/// lookups answer at once (no app) until it is through. `PKFrontKey` stands for it among the pids.
static const NSTimeInterval PKFrontSeconds = 2.0;
static const int PKFrontKey = -1;

/// The front app's AX element, with its bundle id and pid in `info`.
- (id)front:(NSDictionary **)info ax:(id *)client {
    return [self front:info ax:client code:NULL];
}

/// The same, with why there is none in `code`.
- (id)front:(NSDictionary **)info ax:(id *)client code:(NSString **)code {
    PKOutcome *refused;
    uint64_t generation = 0;
    id session = [self current:&generation outcome:&refused];
    if (!session) return nil;
    id ax = [self accessibilityFor:generation];
    if (client) *client = ax;
    __weak PKInProcess *weakSelf = self;
    NSString *given = nil;
    PKDisplayGeometry geometry = self.displayGeometry;
    PKWorkspace *selected = self.selectedWorkspace;
    // Pane-local accessibility needs the workspace's physical placement as well as the app.
    // On rotation recovery, hit tests, two snapshots and visual matching can exceed 2 s.
    NSDictionary *found = PKBounded(PKFrontKey, selected ? PKWorkspaceFrontSeconds : PKFrontSeconds, &given, ^id {
        CGRect pane;
        id chosen;
        if (selected) {
            NSArray *elements = nil;
            PKWorkspace *current = [weakSelf workspaceOn:geometry ax:ax session:session generation:generation known:selected elements:&elements];
            if (selected != weakSelf.selectedWorkspace || !PKSameWorkspace(selected, current)) return @{};
            pane = selected.selectRight ? current.right : current.left;
            chosen = elements[selected.selectRight ? 1 : 0];
        } else {
            chosen = PKForegroundElement(ax, geometry, &pane, ^NSString *(int pid) { return [weakSelf bundleForPID:pid session:session]; });
        }
        int pid = PKAXPid(chosen);
        NSMutableDictionary *answer = [NSMutableDictionary dictionary];
        if (!CGRectIsNull(pane)) answer[@"pane"] = [NSValue valueWithCGRect:pane];
        if (selected.paneLocal) answer[@"paneLocal"] = @YES;
        if (chosen && pid > 0) {
            answer[@"element"] = chosen;
            answer[@"bundleId"] = [weakSelf bundleForPID:pid session:session] ?: @"";
            answer[@"pid"] = @(pid);
        }
        return answer;
    });
    if (![found isKindOfClass:NSDictionary.class]) { if (code) *code = given ?: @"no_front_app"; return nil; }
    if (info) {
        NSMutableDictionary *copy = [found mutableCopy];
        [copy removeObjectForKey:@"element"];
        *info = copy;
    }
    if (!found[@"element"] && code) *code = selected ? @"split_view_changed" : @"no_front_app";
    return found[@"element"];
}

- (NSDictionary<NSString *, id> *)unanswered {
    NSTimeInterval now = NSProcessInfo.processInfo.systemUptime;
    // The latest: one that never answers must not hide a newer one past testmanagerd's limit.
    NSNumber *pid = nil;
    NSTimeInterval latest = 0;
    @synchronized (PKHungLock()) {
        for (NSNumber *key in PKHungSince()) {
            NSTimeInterval since = PKHungSince()[key].doubleValue;
            if (!pid || since > latest) { latest = since; pid = key; }
        }
    }
    return pid ? @{@"pid": pid, @"seconds": @(now - latest)} : nil;
}

- (CGRect)viewport {
    @synchronized (self) { return _viewport; }
}

- (PKDisplayGeometry)displayGeometry {
    __block PKDisplayGeometry result;
    void (^read)(void) = ^{
        [self trackDuoOrientation];
        for (UIScene *candidate in UIApplication.sharedApplication.connectedScenes) {
            if (![candidate isKindOfClass:UIWindowScene.class]) continue;
            BOOL visible = candidate.activationState == UISceneActivationStateForegroundActive ||
                           candidate.activationState == UISceneActivationStateForegroundInactive;
            if (!visible && !PKIsDuo()) continue;
            UIWindowScene *scene = (UIWindowScene *)candidate;
            UIWindow *window = scene.keyWindow;
            if (!window || window.hidden) {
                for (UIWindow *visible in scene.windows) {
                    if (!visible.hidden && visible.windowLevel == UIWindowLevelNormal) { window = visible; break; }
                }
            }
            if (!window || window.hidden) continue;
            UIScreen *screen = scene.screen;
            id<UICoordinateSpace> upright = screen.coordinateSpace;
            CGRect windowOnDisplay = [window convertRect:window.bounds toCoordinateSpace:upright];
            if (@available(iOS 26.0, *)) {
                id<UICoordinateSpace> sceneSpace = scene.effectiveGeometry.coordinateSpace;
                CGRect sceneOnDisplay = [sceneSpace convertRect:sceneSpace.bounds toCoordinateSpace:upright];
                if (!CGRectIsNull(PKPeerPane(upright.bounds, sceneOnDisplay))) windowOnDisplay = sceneOnDisplay;
            }
            CGRect peer = visible ? PKPeerPane(upright.bounds, windowOnDisplay) : CGRectNull;
            BOOL panePlacementKnown = NO;
            if (@available(iOS 27.1, *)) {
                if (!CGRectIsNull(peer) && PKIsDuo() && upright.bounds.size.width > upright.bounds.size.height) {
                    UIEdgeInsets insets = window.safeAreaInsets;
                    UIView *root = window.rootViewController.viewIfLoaded;
                    UIEdgeInsets rootInsets = root ? root.safeAreaInsets : UIEdgeInsetsZero;
                    // The two equal Duo panes are separated by a narrow divider. UIKit's converted
                    // origin can be local to a pane; use the system bars' side to anchor its peer.
                    if (fabs(windowOnDisplay.size.width * 2 - upright.bounds.size.width) <= 32) {
                        CGFloat windowBias = insets.right - insets.left;
                        CGFloat rootBias = rootInsets.right - rootInsets.left;
                        CGFloat bias = fabs(windowBias) >= fabs(rootBias) ? windowBias : rootBias;
                        // A true display-space origin on the right can be used directly. On the
                        // observed Duo, a trailing system bar identifies the right-hand pane;
                        // the opposite pane can have its leading inset or have no such bar.
                        BOOL ownOnRight = CGRectGetMidX(windowOnDisplay) > CGRectGetMidX(upright.bounds) || bias > 12;
                        CGFloat width = windowOnDisplay.size.width;
                        CGFloat x = ownOnRight ? CGRectGetMinX(upright.bounds) : CGRectGetMaxX(upright.bounds) - width;
                        peer = CGRectMake(x, CGRectGetMinY(upright.bounds), width, upright.bounds.size.height);
                        panePlacementKnown = YES;
                    }
                }
            }
            CGAffineTransform transform = CGAffineTransformIdentity;
            NSInteger orientation = UIInterfaceOrientationPortrait;
            BOOL routesDisplay = PKIsDuo() || !CGRectIsNull(peer);
            if (routesDisplay) {
                id<UICoordinateSpace> fixed = screen.fixedCoordinateSpace;
                CGPoint o = [upright convertPoint:CGPointZero toCoordinateSpace:fixed];
                CGPoint x = [upright convertPoint:CGPointMake(1, 0) toCoordinateSpace:fixed];
                CGPoint y = [upright convertPoint:CGPointMake(0, 1) toCoordinateSpace:fixed];
                transform = CGAffineTransformMake(x.x - o.x, x.y - o.y, y.x - o.x, y.y - o.y, o.x, o.y);
                if (@available(iOS 26.0, *)) orientation = scene.effectiveGeometry.interfaceOrientation;
                else orientation = scene.interfaceOrientation;
                if (orientation == UIInterfaceOrientationUnknown) orientation = UIInterfaceOrientationPortrait;
            }
            result = (PKDisplayGeometry){upright.bounds, peer, screen.nativeBounds.size, transform, orientation, panePlacementKnown, routesDisplay, self->_orientationRevision};
            return;
        }
        result = (PKDisplayGeometry){UIScreen.mainScreen.bounds, CGRectNull, CGSizeZero, CGAffineTransformIdentity, UIInterfaceOrientationPortrait, NO, NO, self->_orientationRevision};
    };
    if (NSThread.isMainThread) read(); else dispatch_sync(dispatch_get_main_queue(), read);
    return result;
}

/// Use the same pane for image and tree, even when a third-party app's AX root reports full screen
/// or fails. Otherwise use its frame for windowed layouts that do not match a side-by-side pair.
- (CGRect)noteViewport:(CGRect)frame confirmedPane:(NSValue *)confirmed geometry:(PKDisplayGeometry)geometry {
    CGRect screen = geometry.bounds;
    CGRect next = CGRectNull;
    if (self.selectedWorkspace && confirmed) {
        next = confirmed.CGRectValue;
    } else if (!CGRectIsNull(geometry.peer)) {
        if (geometry.panePlacementKnown) next = geometry.peer;
        else if (confirmed) next = confirmed.CGRectValue;
        else if (!CGRectIsNull(PKPeerPane(screen, frame))) next = CGRectIntersection(frame, screen);
    } else if (!PKIsDuo() && !CGRectIsEmpty(frame) && !CGRectIsInfinite(frame) &&
        (fabs(frame.size.width - screen.size.width) > 8 || fabs(frame.size.height - screen.size.height) > 8)) {
        CGRect visible = CGRectIntersection(frame, screen);
        if (!CGRectIsEmpty(visible)) next = visible;
    }
    @synchronized (self) {
        _viewport = next;
        if (!geometry.routesDisplay) _capturedDisplay = nil;
    }
    return next;
}

- (NSDictionary<NSString *, id> *)frontApp {
    NSDictionary *recent = [self takeRecentFront];
    if (recent) return recent;
    @try {
        NSTimeInterval started = NSProcessInfo.processInfo.systemUptime;
        NSDictionary *info;
        id ax;
        id element = [self front:&info ax:&ax];
        if (!element) return @{};
        // The bundle id and pid come from the active applications; the snapshot adds the name.
        // An app that does not answer it (starting up, or its main thread busy) is still
        // reported as the front app, so a launch waiting for it sees it arrive.
        id root = PKRequestSnapshotWithin(3, ax, element, 1, 1, NULL);
        // Foreground polling must not replace the coordinate space of the latest read.
        NSMutableDictionary *out = [info mutableCopy];
        out[@"name"] = root ? (PKText([root label]) ?: @"") : @"";
        NSLog(@"PokiInProcess timing: front app %d ms (%@)", (int)lround((NSProcessInfo.processInfo.systemUptime - started) * 1000), out[@"bundleId"]);
        return out;
    } @catch (NSException *e) { return @{}; }
}

CGPoint PKWorkspaceLauncherPoint(NSDictionary<NSString *, NSArray<NSValue *> *> *candidates,
                                 NSDictionary<NSString *, NSArray<NSValue *> *> *visibleLabels, BOOL menu) {
    CGPoint unavailable = CGPointMake(NAN, NAN);
    CGPoint point = unavailable;
    for (NSString *label in visibleLabels) {
        NSArray<NSValue *> *frames = candidates[label];
        if (!frames.count) continue;
        for (NSValue *value in visibleLabels[label]) {
            CGPoint position = value.CGPointValue;
            // The grid can report page-local x coordinates and icons on adjacent pages. Match a
            // screenshot label to the icon's row to reject the same text in widgets or banners.
            if (!menu) {
                CGFloat firstRow = INFINITY, lastRow = -INFINITY;
                for (NSValue *frame in frames) {
                    CGRect icon = frame.CGRectValue;
                    CGFloat middle = CGRectGetMidY(icon);
                    if (CGRectIsEmpty(icon) || CGRectGetHeight(icon) <= 50 ||
                        position.y < middle || position.y > CGRectGetMaxY(icon) + 8) continue;
                    firstRow = fmin(firstRow, middle);
                    lastRow = fmax(lastRow, middle);
                }
                if (!isfinite(firstRow)) continue;
                if (lastRow - firstRow > 6) return unavailable;
                position.y = (firstRow + lastRow) / 2 - 6;
            }
            if (isfinite(point.x)) return unavailable;
            point = position;
        }
    }
    return point;
}

- (nullable PKOutcome *)openWorkspaceLauncherItem:(NSArray<NSString *> *)labels menu:(BOOL)menu {
    @try {
        PKDisplayGeometry display = self.displayGeometry;
        if (!PKIsDuo() || self.screenLocked || self.selectedWorkspace || [self isPokiSceneVisible] ||
            !display.routesDisplay || CGRectGetWidth(display.bounds) <= CGRectGetHeight(display.bounds)) return nil;
        PKOutcome *refused;
        uint64_t generation = 0;
        if (![self current:&generation outcome:&refused]) return nil;
        id ax = [self accessibilityFor:generation];
        if (![ax respondsToSelector:@selector(systemApplication)]) return nil;
        id system = PKBounded(0, 1, NULL, ^id { return [ax systemApplication]; });
        id root = system ? PKRequestSnapshotWithin(2, ax, system, 22, 480, NULL) : nil;
        if (!root) return nil;
        NSString *targetType = menu ? @"Button" : @"Icon";
        NSMutableDictionary<NSString *, NSMutableArray<NSValue *> *> *candidates = [NSMutableDictionary dictionary];
        NSMutableArray *nodes = [NSMutableArray arrayWithObject:root];
        while (nodes.count) {
            id node = nodes.lastObject;
            [nodes removeLastObject];
            NSString *label = PKText([node label]);
            if (label && [labels containsObject:label] && [PKTypeName([node elementType]) isEqualToString:targetType]) {
                if (!candidates[label]) candidates[label] = [NSMutableArray array];
                [candidates[label] addObject:[NSValue valueWithCGRect:[node frame]]];
            }
            NSArray *children = [node children];
            if (children.count) [nodes addObjectsFromArray:children];
        }
        if (!candidates.count) return nil;
        UIImage *picture = PKUprightImage([self screenshot:NULL refreshViewport:NO], display);
        if (!picture.CGImage || !CGRectIsNull(self.viewport)) return nil;
        VNRecognizeTextRequest *request = [VNRecognizeTextRequest new];
        request.recognitionLevel = VNRequestTextRecognitionLevelAccurate;
        request.recognitionLanguages = @[@"zh-Hans", @"zh-Hant", @"en-US"];
        request.usesLanguageCorrection = NO;
        VNImageRequestHandler *recognizer = [[VNImageRequestHandler alloc] initWithCGImage:picture.CGImage options:@{}];
        if (![recognizer performRequests:@[request] error:NULL]) return nil;
        CGRect bounds = display.bounds;
        NSMutableDictionary<NSString *, NSMutableArray<NSValue *> *> *visibleLabels = [NSMutableDictionary dictionary];
        for (VNRecognizedTextObservation *observation in request.results) {
            NSString *label = [observation topCandidates:1].firstObject.string;
            if (!label || !candidates[label]) continue;
            CGRect word = observation.boundingBox;
            CGFloat x = CGRectGetMinX(bounds) + CGRectGetMidX(word) * CGRectGetWidth(bounds);
            CGFloat y = CGRectGetMinY(bounds) + (1 - CGRectGetMidY(word)) * CGRectGetHeight(bounds);
            if (!visibleLabels[label]) visibleLabels[label] = [NSMutableArray array];
            [visibleLabels[label] addObject:[NSValue valueWithCGPoint:CGPointMake(x, y)]];
        }
        CGPoint point = PKWorkspaceLauncherPoint(candidates, visibleLabels, menu);
        if (!isfinite(point.x) || !CGRectContainsPoint(bounds, point) || self.screenLocked || self.generation != generation ||
            !PKSameDisplay(display, self.displayGeometry)) return nil;
        NSArray *finger = @[[PKTouchPoint at:point offset:0], [PKTouchPoint at:point offset:menu ? 0.08 : 0.9]];
        return [self touch:@[finger] timeout:5 geometry:display];
    } @catch (__unused NSException *e) { return nil; }
}

- (nullable NSString *)sourceXML:(NSDictionary **)focused code:(NSString **)code {
    return [self sourceXML:focused maxDepth:0 maxChildren:0 code:code];
}

- (nullable NSString *)sourceXML:(NSDictionary **)focused maxDepth:(NSInteger)maxDepth maxChildren:(NSInteger)maxChildren code:(NSString **)code {
    @try {
        NSTimeInterval started = NSProcessInfo.processInfo.systemUptime;
        id ax;
        NSDictionary *info;
        NSString *why = nil;
        id app = [self sharedFront:&info ax:&ax code:&why];
        if (!app) { if (code) *code = why ?: @"no_front_app"; return nil; }
        NSTimeInterval frontAt = NSProcessInfo.processInfo.systemUptime;
        id root = PKSnapshotTreeBounded(ax, app, maxDepth, maxChildren, code);
        if (!root) {
            // The app is in front all the same (WeChat on the phone: "Error getting main window"): the
            // /wda/activeAppInfo PokiCore asks beside this read answers it at once, instead of searching
            // again with its own snapshot behind this one.
            if ([info[@"bundleId"] length]) {
                NSMutableDictionary *front = [info mutableCopy];
                front[@"name"] = @"";
                [self rememberFront:front];
            }
            if (code && !*code) *code = @"no_snapshot";
            return nil;
        }
        PKDisplayGeometry geometry = self.displayGeometry;
        // An application root can be in fixed display coordinates even when its children are
        // upright. On Duo the screen or confirmed pane supplies the bounds; keep child points as read.
        CGRect viewport = [self noteViewport:PKTargetFrame(root, geometry.bounds) confirmedPane:info[@"pane"] geometry:geometry];
        BOOL paneRead = !CGRectIsNull(geometry.peer) || self.selectedWorkspace != nil;
        BOOL paneLocal = [info[@"paneLocal"] boolValue];
        if (paneRead && CGRectIsNull(viewport)) {
            if (code) *code = @"target_pane_unconfirmed";
            return nil;
        }
        CGPoint shift = CGRectIsNull(viewport) || paneLocal ? CGPointZero : viewport.origin;
        CGRect clip = paneLocal ? (CGRect){CGPointZero, viewport.size} : viewport;
        NSTimeInterval snapshotAt = NSProcessInfo.processInfo.systemUptime;
        {
            NSMutableDictionary *front = [info mutableCopy];
            front[@"name"] = PKText([root label]) ?: @"";
            [self rememberFront:front];
        }
        __block NSUInteger count = 0;
        NSMutableString *xml = [NSMutableString stringWithString:@"<?xml version=\"1.0\" encoding=\"UTF-8\"?><AppiumAUT>"];
        __block NSDictionary *focus = nil;
        __block void (^walk)(id);
        __weak __block void (^weakWalk)(id);
        weakWalk = walk = ^(id node) {
            NSString *type = [@"XCUIElementType" stringByAppendingString:PKTypeName([node elementType])];
            count++;
            CGRect f = [node frame];
            NSString *identifier = PKText([node identifier]), *label = PKText([node label]), *value = PKText([(NSObject *)node value]);
            // An empty field shows its placeholder as its value, as WebDriverAgent's source does
            // (UIKit's accessibilityValue of an empty UITextField is its placeholder; the snapshot
            // keeps them apart), so a listing names the field by what the person sees in it.
            if (!value.length && [node respondsToSelector:@selector(placeholderValue)] && ([type hasSuffix:@"Field"] || [type hasSuffix:@"TextView"])) {
                value = PKText([node placeholderValue]);
            }
            NSString *name = identifier.length ? identifier : label;
            [xml appendFormat:@"<%@ type=\"%@\"", type, type];
            if (name.length) [xml appendFormat:@" name=\"%@\"", PKEscape(name)];
            if (label.length) [xml appendFormat:@" label=\"%@\"", PKEscape(label)];
            if (value.length) [xml appendFormat:@" value=\"%@\"", PKEscape(value)];
            if (CGRectIsNull(f) || CGRectIsInfinite(f)) f = CGRectZero;
            else {
                if (paneRead) f = CGRectIntersection(f, clip);
                f = CGRectIsNull(f) ? CGRectZero : CGRectOffset(f, -shift.x, -shift.y);
            }
            [xml appendFormat:@" x=\"%d\" y=\"%d\" width=\"%d\" height=\"%d\"", (int)lround(f.origin.x), (int)lround(f.origin.y), (int)lround(f.size.width), (int)lround(f.size.height)];
            BOOL keyboard = [node respondsToSelector:@selector(hasKeyboardFocus)] ? [node hasKeyboardFocus]
                : [node respondsToSelector:@selector(hasFocus)] && [node hasFocus];
            if (!focus && keyboard && (!paneRead || !CGRectIsEmpty(f)) && ([type hasSuffix:@"Field"] || [type hasSuffix:@"TextView"])) {
                NSMutableDictionary *field = [@{@"value": value ?: @"", @"x": @(f.origin.x), @"y": @(f.origin.y), @"width": @(f.size.width), @"height": @(f.size.height)} mutableCopy];
                // The placeholder, so a failed type can tell an empty field that shows it from typed text
                // (ESP-160). NSNull: the field has none; no key: the snapshot did not say.
                if ([node respondsToSelector:@selector(placeholderValue)]) field[@"placeholderValue"] = PKText([node placeholderValue]) ?: (id)NSNull.null;
                focus = field;
            }
            NSArray *children = [node children];
            if (!children.count) { [xml appendString:@"/>"]; return; }
            [xml appendString:@">"];
            for (id child in children) weakWalk(child);
            [xml appendFormat:@"</%@>", type];
        };
        walk(root);
        [xml appendString:@"</AppiumAUT>"];
        if (focused) *focused = focus;
        NSTimeInterval end = NSProcessInfo.processInfo.systemUptime;
        NSLog(@"PokiInProcess timing: source %d ms (front %d, snapshot %d, xml %d), %lu elements, %lu chars",
              (int)lround((end - started) * 1000), (int)lround((frontAt - started) * 1000), (int)lround((snapshotAt - frontAt) * 1000),
              (int)lround((end - snapshotAt) * 1000), (unsigned long)count, (unsigned long)xml.length);
        return xml;
    } @catch (NSException *e) {
        if (code) *code = [NSString stringWithFormat:@"%@: %@", e.name, e.reason];
        return nil;
    }
}

- (nullable NSString *)press:(NSString *)name {
    [self forgetFront];
    @try {
        PKOutcome *refused;
        uint64_t generation = 0;
        if (![self current:&generation outcome:&refused]) return refused.code ?: @"no_session";
        id device = [NSClassFromString(@"XCUIDevice") sharedDevice];
        NSDictionary *buttons = @{@"home": @1, @"volumeUp": @2, @"volumeDown": @3};
        if ([name isEqualToString:@"lock"]) {
            if (![device respondsToSelector:@selector(pressLockButton)]) return @"lock_unavailable";
            [device pressLockButton];
            return nil;
        }
        NSNumber *button = buttons[name];
        if (!button) return @"unknown_button";
        // pressButton: drops the answer; the same HID event (consumer page 0x0C: Menu 0x40, volume
        // 0xE9/0xEA) is sent here so that a refusal comes back instead of a silent nothing.
        static const uint32_t usages[] = {0, 0x40, 0xE9, 0xEA};
        id event = [NSClassFromString(@"XCDeviceEvent") deviceEventWithPage:0x0C usage:usages[button.intValue] duration:0.1];
        NSError *error = nil;
        if (!event || ![device performDeviceEvent:event error:&error]) return error.localizedDescription ?: @"button_failed";
        return nil;
    } @catch (NSException *e) {
        return [NSString stringWithFormat:@"%@: %@", e.name, e.reason];
    }
}

/// testmanagerd's answer to one launch or terminate request, or nil within `seconds`.
static NSString *PKDaemonReply(NSTimeInterval seconds, void (^send)(void (^)(NSError *))) {
    dispatch_semaphore_t done = dispatch_semaphore_create(0);
    __block NSString *code = @"no_reply";
    send(^(NSError *error) { code = error ? (error.localizedDescription ?: @"failed") : nil; dispatch_semaphore_signal(done); });
    if (dispatch_semaphore_wait(done, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(seconds * NSEC_PER_SEC)))) return @"no_reply";
    return code;
}

/// Opens, brings forward or ends an app through testmanagerd, as XCUIApplication does inside a UI
/// test: launch ends a running copy first and starts it again, activate brings a running copy forward
/// (or starts it), terminate ends it. XCUIApplication itself refuses to exist outside a UI test bundle.
/// Launch and activate return once the app is in front.
- (nullable NSString *)app:(NSString *)bundle action:(NSString *)action {
    [self forgetFront];
    @try {
        PKOutcome *refused;
        uint64_t generation = 0;
        id session = [self current:&generation outcome:&refused];
        if (!session) return refused.code ?: @"no_session";
        id proxy = [session daemonProxy];
        BOOL launch = [action isEqualToString:@"launch"], activate = [action isEqualToString:@"activate"];
        if (!launch && !activate && ![action isEqualToString:@"terminate"]) return @"unknown_action";
        if (!launch && !activate) {
            return PKDaemonReply(15, ^(void (^reply)(NSError *)) { [proxy _XCT_terminateApplicationWithBundleID:bundle completion:reply]; });
        }
        BOOL (^inFront)(NSTimeInterval) = ^BOOL(NSTimeInterval seconds) {
            NSDate *by = [NSDate dateWithTimeIntervalSinceNow:seconds];
            do {
                if ([[self frontApp][@"bundleId"] isEqualToString:bundle]) return YES;
                [NSThread sleepForTimeInterval:0.25];
            } while ([by timeIntervalSinceNow] > 0);
            return NO;
        };
        if (launch && !PKDaemonReply(15, ^(void (^reply)(NSError *)) { [proxy _XCT_terminateApplicationWithBundleID:bundle completion:reply]; })) {
            // A launch sent while the old process is still exiting is answered but starts nothing.
            NSDate *by = [NSDate dateWithTimeIntervalSinceNow:5];
            while ([by timeIntervalSinceNow] > 0 && [[self frontApp][@"bundleId"] isEqualToString:bundle]) [NSThread sleepForTimeInterval:0.25];
            [NSThread sleepForTimeInterval:0.5];
        }
        for (int attempt = 0; attempt < 2; attempt++) {
            NSString *code = PKDaemonReply(30, ^(void (^reply)(NSError *)) {
                [proxy _XCT_launchApplicationWithBundleID:bundle arguments:@[] environment:@{} completion:reply];
            });
            if (code) return code;
            if (inFront(attempt ? 10 : 5)) return nil;
        }
        return @"not_in_front";
    } @catch (NSException *e) {
        return [NSString stringWithFormat:@"%@: %@", e.name, e.reason];
    }
}

- (BOOL)screenLocked {
    static int token = -1;
    if (token == -1 && notify_register_check("com.apple.springboard.lockstate", &token) != NOTIFY_STATUS_OK) return NO;
    uint64_t state = 0;
    notify_get_state(token, &state);
    return state != 0;
}

- (NSDictionary<NSString *, id> *)readProbe {
    NSMutableDictionary *out = [NSMutableDictionary new];
    PKOutcome *refused;
    uint64_t generation = 0;
    id session = [self current:&generation outcome:&refused];
    if (!session) { out[@"error"] = refused.code ?: @"no_session"; return out; }
    NSTimeInterval t = NSProcessInfo.processInfo.systemUptime;
    id app = nil, ax = nil;
    @try {
        ax = [self accessibilityFor:generation];
        NSArray *apps = PKActiveApplications(ax);
        out[@"front_count"] = @(apps.count);
        __weak PKInProcess *weakSelf = self;
        app = PKForegroundElement(ax, self.displayGeometry, NULL, ^NSString *(int pid) { return [weakSelf bundleForPID:pid session:session]; });
        int pid = PKAXPid(app);
        out[@"front_pid"] = @(pid);
        if (pid) out[@"front_bundle"] = [self bundleForPID:pid session:session] ?: @"?";
        out[@"front_ok"] = @(app != nil);
    } @catch (NSException *e) {
        out[@"front_error"] = [NSString stringWithFormat:@"%@: %@", e.name, e.reason];
    }
    out[@"front_seconds"] = @(NSProcessInfo.processInfo.systemUptime - t);
    t = NSProcessInfo.processInfo.systemUptime;
    @try {
        NSString *code;
        id root = app ? PKSnapshotTree(ax, app, &code) : nil;
        out[@"tree_ok"] = @(root != nil);
        out[@"tree_elements"] = @(root ? PKCount(root) : 0);
        if (root) out[@"tree_root_label"] = PKText([root label]) ?: @"";
        if (code && !root) out[@"tree_error"] = code;
    } @catch (NSException *e) {
        out[@"tree_error"] = [NSString stringWithFormat:@"%@: %@", e.name, e.reason];
    }
    out[@"tree_seconds"] = @(NSProcessInfo.processInfo.systemUptime - t);
    t = NSProcessInfo.processInfo.systemUptime;
    @try {
        NSData *png = [[[NSClassFromString(@"XCUIScreen") mainScreen] screenshot] PNGRepresentation];
        out[@"picture_ok"] = @(png.length > 0);
        out[@"picture_bytes"] = @(png.length);
    } @catch (NSException *e) {
        out[@"picture_error"] = [NSString stringWithFormat:@"%@: %@", e.name, e.reason];
    }
    out[@"picture_seconds"] = @(NSProcessInfo.processInfo.systemUptime - t);
    return out;
}

- (NSDictionary<NSString *, id> *)separateSessionTrialAt:(CGPoint)point hold:(double)hold {
    NSMutableDictionary *out = [NSMutableDictionary new];
    NSTimeInterval t0 = NSProcessInfo.processInfo.systemUptime;
    double (^now)(void) = ^{ return NSProcessInfo.processInfo.systemUptime - t0; };
    for (NSString *path in @[@"/System/Developer/Library/PrivateFrameworks/XCTestSupport.framework/XCTestSupport",
                             @"/System/Developer/usr/lib/lib_TestingInterop.dylib",
                             @"/System/Developer/Library/PrivateFrameworks/XCTestCore.framework/XCTestCore",
                             @"/System/Developer/Library/Frameworks/XCUIAutomation.framework/XCUIAutomation"]) {
        if (!dlopen(path.UTF8String, RTLD_NOW | RTLD_GLOBAL)) { out[@"code"] = @"developer_framework_unavailable"; return out; }
    }
    Class cls = NSClassFromString(@"XCTRunnerDaemonSession");
    if (![cls respondsToSelector:@selector(connectionForInitiatingSharedSession)] || ![cls respondsToSelector:@selector(sessionWithConnection:completion:)]) {
        out[@"code"] = @"session_api_unavailable"; return out;
    }
    id connection = [cls connectionForInitiatingSharedSession];
    __block id session; __block NSError *opened;
    dispatch_semaphore_t ready = dispatch_semaphore_create(0);
    [cls sessionWithConnection:connection completion:^(id s, NSError *e) { session = s; opened = e; dispatch_semaphore_signal(ready); }];
    if (dispatch_semaphore_wait(ready, dispatch_time(DISPATCH_TIME_NOW, 3 * NSEC_PER_SEC))) { out[@"code"] = @"session_timeout"; return out; }
    out[@"opened_s"] = @(now());
    if (!session) { out[@"code"] = @"session_failed"; out[@"detail"] = opened.localizedDescription ?: @""; return out; }
    __block double invalidatedAt = -1;
    dispatch_semaphore_t gone = dispatch_semaphore_create(0);
    if ([session respondsToSelector:@selector(registerInvalidationHandler:)])
        [session registerInvalidationHandler:^{ invalidatedAt = now(); dispatch_semaphore_signal(gone); }];
    NSError *error;
    BOOL enabled = [session respondsToSelector:@selector(enableAutomationModeWithError:)] && [session enableAutomationModeWithError:&error];
    out[@"enabled"] = @(enabled); out[@"enabled_s"] = @(now());
    if (!enabled) { out[@"code"] = @"enable_failed"; out[@"detail"] = error.localizedDescription ?: @""; return out; }
    Class pathClass = NSClassFromString(@"XCPointerEventPath"), recordClass = NSClassFromString(@"XCSynthesizedEventRecord");
    id record = [recordClass instancesRespondToSelector:@selector(initWithName:interfaceOrientation:)]
        ? [[recordClass alloc] initWithName:@"Poki trial" interfaceOrientation:1] : [[recordClass alloc] initWithName:@"Poki trial"];
    id path = [[pathClass alloc] initForTouchAtPoint:point offset:0];
    [path liftUpAtOffset:0.05];
    [record addPointerEventPath:path];
    __block NSString *tap = @"no_reply";
    dispatch_semaphore_t tapped = dispatch_semaphore_create(0);
    [[session daemonProxy] _XCT_synthesizeEvent:record implicitConfirmationInterval:0 completion:^(NSError *e) {
        tap = e ? (e.localizedDescription ?: @"error") : @"accepted"; dispatch_semaphore_signal(tapped);
    }];
    dispatch_semaphore_wait(tapped, dispatch_time(DISPATCH_TIME_NOW, 5 * NSEC_PER_SEC));
    out[@"tap"] = tap; out[@"tap_s"] = @(now());
    [NSThread sleepForTimeInterval:hold];
    id link = [session respondsToSelector:@selector(connection)] ? [session connection] : connection;
    [link invalidate];
    out[@"closed_s"] = @(now());
    BOOL handler = dispatch_semaphore_wait(gone, dispatch_time(DISPATCH_TIME_NOW, 5 * NSEC_PER_SEC)) == 0;
    out[@"invalidation_handler"] = @(handler);
    if (handler) out[@"invalidated_s"] = @(invalidatedAt);
    out[@"code"] = @"done";
    return out;
}

@end
