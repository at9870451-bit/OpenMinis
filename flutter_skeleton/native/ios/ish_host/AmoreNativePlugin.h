#import <Flutter/Flutter.h>

/// Registers the `amore/native` channel. Written in Objective-C because a
/// CocoaPods framework target cannot use a Swift bridging header, and this
/// plugin needs the iSH ObjC wrappers directly.
@interface AmoreNativePlugin : NSObject <FlutterPlugin>
@end
