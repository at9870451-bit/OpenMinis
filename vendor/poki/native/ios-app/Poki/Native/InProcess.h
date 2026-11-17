#import <CoreGraphics/CoreGraphics.h>
#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// How a dispatched action ended, as far as the phone is concerned.
typedef NS_ENUM(NSInteger, PKDelivery) {
    PKDeliveryNotSent = 0,
    PKDeliverySent = 1,
    /// Dispatched, and no answer came in time: it may or may not have happened.
    PKDeliveryUnknown = 2,
};

/// One point of a finger's path: where it is `offset` seconds after the gesture starts.
@interface PKTouchPoint : NSObject
@property (nonatomic, readonly) CGPoint point;
@property (nonatomic, readonly) double offset;
+ (instancetype)at:(CGPoint)point offset:(double)offset;
@end

@interface PKOutcome : NSObject
@property (nonatomic, readonly) PKDelivery delivery;
/// A short code when the action was refused or failed ("native_session_invalidated", "reply_timeout").
@property (nonatomic, readonly, nullable) NSString *code;
@property (nonatomic, readonly, nullable) NSString *detail;
/// From commit to the daemon's reply, in seconds.
@property (nonatomic, readonly) double seconds;
@property (nonatomic, readonly) uint64_t generation;
@end

/// The current display in upright points, with the pane beside Poki when one can be identified.
typedef struct {
    CGRect bounds;
    CGRect peer;
    CGSize nativeSize;
    CGAffineTransform toFixed;
    NSInteger orientation;
    BOOL panePlacementKnown;
    BOOL routesDisplay;
    /// Changes even when the device returns to its original orientation before the next read.
    uint64_t orientationRevision;
} PKDisplayGeometry;

/// Finds the pane on the opposite edge of a side-by-side window; CGRectNull for other layouts.
FOUNDATION_EXPORT CGRect PKPeerPane(CGRect screen, CGRect window);

/// Returns a launcher touch point only when the visible labels and accessibility frames agree on one target.
FOUNDATION_EXPORT CGPoint PKWorkspaceLauncherPoint(NSDictionary<NSString *, NSArray<NSValue *> *> *candidates,
                                                    NSDictionary<NSString *, NSArray<NSValue *> *> *visibleLabels, BOOL menu);

/// UI automation from Poki's own process: the XCTest daemon session (testmanagerd), Automation Mode,
/// and synthesized touch and text events. No runner app and no port. Every method blocks, so call it
/// from a serial worker queue, never the main thread: the first enable waits for the owner to
/// authenticate in iOS's prompt.
@interface PKInProcess : NSObject
+ (instancetype)shared;
/// Loads the developer frameworks only. Does not open a session or ask for the passcode.
- (BOOL)developerFrameworksAvailable;
+ (BOOL)canUseDuoSplitView;
/// Loads the Developer libraries, opens the daemon session and enables Automation Mode, or reuses an
/// enable of the same session and generation. Keys: ok, code, detail, generation, reused, seconds.
- (NSDictionary<NSString *, id> *)prepare;
/// How long iOS has been asked to allow automation in the open under way (seconds); 0 while no
/// open is at that point. Opening the session and its first read do not count.
- (double)authorizationWaitSeconds;
/// Testing only: the next readiness check of a new session fails as if no element tree came back,
/// so the handling of a session that cannot read can be seen on a phone.
@property (atomic) BOOL failNextReadinessCheck;
/// Ends the session, and with it Automation Mode and iOS's "Automation Running" banner, while Poki
/// stays up. Keys: closed (whether one was open), generation (the one that ended), seconds. The next
/// prepare opens a new session; iOS asks for no passcode again within the same boot.
- (NSDictionary<NSString *, id> *)close;
/// Automation Mode (and its banner) off with the session kept open, where iOS offers a way; the next
/// prepare turns it on again. Keys: paused, how, selectors.
- (NSDictionary<NSString *, id> *)pauseAutomation;
/// One or more fingers, each a path pressed at its first point and lifted at its last, sent as one
/// event. Waits up to `timeout` for the daemon's reply; a dispatched event is never sent again.
- (PKOutcome *)touch:(NSArray<NSArray<PKTouchPoint *> *> *)fingers timeout:(double)timeout;
/// Types into whatever field has the keyboard focus. Does not focus or clear.
- (PKOutcome *)type:(NSString *)text timeout:(double)timeout;
/// The same at `speed` characters a second (PokiCore sends a `frequency` per burst; 120 without one).
- (PKOutcome *)type:(NSString *)text typingSpeed:(NSUInteger)speed timeout:(double)timeout;
/// Whether the screen can be read from here: the front app (accessibility), its element tree, and a
/// screenshot, each timed. Keys per part: *_ok, *_seconds, *_error, and counts.
- (NSDictionary<NSString *, id> *)readProbe;
/// A picture of the main screen (a JPEG through XCTest's quality API where it exists, else a PNG), or nil and why.
- (nullable NSData *)screenshot:(NSString *_Nullable *_Nullable)code;
/// The same; with `refreshViewport` NO the picture and nothing more: no lookup of the app in front for
/// the viewport (the one noted last stands), as that lookup would wait behind a request testmanagerd is
/// still serving.
- (nullable NSData *)screenshot:(NSString *_Nullable *_Nullable)code refreshViewport:(BOOL)refreshViewport;
/// The latest accessibility request this process gave up on that testmanagerd is still serving: keys
/// pid (0: the accessibility server, -1: a lookup of the app in front) and seconds. nil when none is.
- (nullable NSDictionary<NSString *, id> *)unanswered;
/// The app in front: bundleId, name, pid. Empty when accessibility gives none.
- (NSDictionary<NSString *, id> *)frontApp;
/// Confirms a named app icon or its Split View menu item from the system tree and a fresh local screenshot.
- (nullable PKOutcome *)openWorkspaceLauncherItem:(NSArray<NSString *> *)labels menu:(BOOL)menu;
/// Select a side of a two-app inner display, or clear the selection with "auto".
/// Refuses when both visible apps and their window bounds cannot be confirmed.
- (nullable NSDictionary<NSString *, id> *)selectPane:(NSString *)side code:(NSString *_Nullable *_Nullable)code;
@property (nonatomic, readonly) BOOL hasSelectedPane;
/// The opposite pane of the selected workspace, in display coordinates (CGRectNull without one).
@property (nonatomic, readonly) CGRect otherWorkspacePane;
/// The pane used for the latest read, or CGRectNull for a full-screen app. Both the screenshot
/// and the tree use points relative to the pane. Gestures add its origin back before dispatch.
@property (nonatomic, readonly) CGRect viewport;
/// Reads the geometry of Poki's visible scene. Falls back to the main screen when it is hidden.
- (PKDisplayGeometry)displayGeometry;
/// Sends upright display coordinates using the same display geometry that bounded the gesture.
- (PKOutcome *)touch:(NSArray<NSArray<PKTouchPoint *> *> *)fingers timeout:(double)timeout geometry:(PKDisplayGeometry)geometry;
/// The front app's elements in WebDriverAgent's XML source format, and the element with the
/// keyboard focus (keys value, x, y, width, height) when there is one.
- (nullable NSString *)sourceXML:(NSDictionary *_Nullable *_Nullable)focused code:(NSString *_Nullable *_Nullable)code;
/// The same, bounded as WebDriverAgent's snapshotMaxDepth and snapshotMaxChildren settings bound
/// it (0 for either: no bound beyond the AX server's own), so a dense screen reads in time.
- (nullable NSString *)sourceXML:(NSDictionary *_Nullable *_Nullable)focused maxDepth:(NSInteger)maxDepth maxChildren:(NSInteger)maxChildren code:(NSString *_Nullable *_Nullable)code;
/// home, lock, volumeUp or volumeDown. Nil when pressed, else why not.
- (nullable NSString *)press:(NSString *)name;
/// launch, activate or terminate an app by its bundle id. Nil when done, else why not.
- (nullable NSString *)app:(NSString *)bundle action:(NSString *)action;
- (BOOL)screenLocked;
/// The current session's generation: it goes up when the daemon session is replaced.
- (uint64_t)generation;
/// A trial for ending the session: opens a session of its own (not the shared one that XCUIAutomation
/// uses), turns on Automation Mode with it, taps once at the point, waits `hold` seconds, then closes its
/// connection to testmanagerd and waits for the invalidation handler. Run it in a fresh Poki process
/// before anything opens the shared session. The dictionary says what each step returned and when.
- (NSDictionary<NSString *, id> *)separateSessionTrialAt:(CGPoint)point hold:(double)hold;
@end

NS_ASSUME_NONNULL_END
