#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN
// Readable reconstruction; address-level provenance is in ../PROVENANCE.json.
// One context belongs to one logical action. Retain it across retries.
@interface SRActionContext : NSObject
- (instancetype)initWithOperationID:(NSString *)operationID
                      currentOwner:(BOOL (^)(void))currentOwner;
- (BOOL)commit:(NSError **)error;
- (void)beginReply;
- (void)markDispatched;
- (void)receiveReply:(nullable NSError *)error;
- (void)whenRepliesDrain:(dispatch_block_t)continuation;
- (NSDictionary *)evidence;
@end

@interface SRNativeSession : NSObject
/// Loads developer frameworks without opening a daemon session or enabling Automation Mode.
- (BOOL)loadDeveloperFrameworks:(NSError **)error;
// Call from a worker queue: the upstream promise wait can take 3 seconds.
- (nullable id)prepare:(NSError **)error;
- (BOOL)isCurrent:(id)session generation:(uint64_t)generation;
// Ends the current session (and Automation Mode with it). YES when one was open. The next prepare
// opens a new one, with a new generation.
- (BOOL)close;
/// What the last close found: the connection class, whether it could be invalidated, and whether
/// the session's invalidation handler fired (testmanagerd saw it go).
- (nullable NSString *)closeDetail;
/// How the last session of this process's own got XCTest's local device: "rebuilt" (a new XCUIDevice
/// on the new session, so reads, pictures and buttons go to it), "unavailable" or "abi_mismatch"
/// (this XCTest offers no way), or the exception. nil while the first session lasts.
- (nullable NSString *)rebindDetail;
- (BOOL)deviceRebuilt;
- (uint64_t)generation;
- (BOOL)enableWasReused;
/// How long the enable of Automation Mode under way has been waiting, in seconds; 0 while none is.
/// iOS shows its passcode screen from inside that call, so a long wait here is the owner being asked.
- (double)enablingSeconds;
/// Turns Automation Mode (and iOS's banner) off while the session stays open, when this iOS offers a
/// way; the next prepare turns it on again. Keys: paused, how, selectors (what the session offers).
- (NSDictionary<NSString *, id> *)pauseAutomation;
@end

// Inserts into the CURRENTLY FOCUSED field. Does not focus, clear, paste or verify.
// The context must also validate the current session generation before dispatch.
FOUNDATION_EXPORT NSDictionary * _Nullable SRInsertText(
    id session, NSString *text, SRActionContext *context, NSError **error);
// The same at `speed` characters a second (XCTest's typingSpeed; 120 is SRInsertText's), so typed
// text can come in bursts at a person's uneven pace (PokiCore's Humanize) rather than one fixed rate.
FOUNDATION_EXPORT NSDictionary * _Nullable SRInsertTextAtSpeed(
    id session, NSString *text, NSUInteger speed, SRActionContext *context, NSError **error);
NS_ASSUME_NONNULL_END
