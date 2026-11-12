#import "AmoreNativePlugin.h"
#import "ISHKernel.h"
#import "ISHShellExecutor.h"

@implementation AmoreNativePlugin

+ (void)registerWithRegistrar:(NSObject<FlutterPluginRegistrar> *)registrar {
    FlutterMethodChannel *channel =
        [FlutterMethodChannel methodChannelWithName:@"amore/native"
                                    binaryMessenger:[registrar messenger]];
    AmoreNativePlugin *instance = [[AmoreNativePlugin alloc] init];
    [registrar addMethodCallDelegate:instance channel:channel];
}

- (void)handleMethodCall:(FlutterMethodCall *)call result:(FlutterResult)result {
    if ([call.method isEqualToString:@"isAvailable"]) {
        result(@YES);
    } else if ([call.method isEqualToString:@"sandbox.status"]) {
        result([self statusPayload]);
    } else if ([call.method isEqualToString:@"sandbox.exec"]) {
        NSDictionary *args = (NSDictionary *)call.arguments;
        NSString *command = args[@"command"];
        if (![command isKindOfClass:[NSString class]] || command.length == 0) {
            result([FlutterError errorWithCode:@"bad_args"
                                      message:@"command required"
                                      details:nil]);
            return;
        }
        [self exec:command result:result];
    } else if ([call.method isEqualToString:@"fileProvider.register"] ||
               [call.method isEqualToString:@"liveActivity.set"]) {
        result(nil);
    } else {
        result(FlutterMethodNotImplemented);
    }
}

#pragma mark - Rootfs

- (NSString *)rootfsPath {
    NSString *docs = NSSearchPathForDirectoriesInDomains(
        NSDocumentDirectory, NSUserDomainMask, YES).firstObject;
    return [docs stringByAppendingPathComponent:@"alpine-rootfs"];
}

- (BOOL)rootfsInstalled {
    NSFileManager *fm = [NSFileManager defaultManager];
    NSString *data = [[self rootfsPath] stringByAppendingPathComponent:@"data"];
    NSString *meta = [[self rootfsPath] stringByAppendingPathComponent:@"meta.db"];
    return [fm fileExistsAtPath:data] && [fm fileExistsAtPath:meta];
}

- (NSDictionary *)statusPayload {
    NSMutableDictionary *payload = [@{
        @"available": @YES,
        @"booted": @([ISHKernel shared].isBooted),
        @"rootfsPath": [self rootfsPath],
    } mutableCopy];

    if (![self rootfsInstalled]) {
        payload[@"error"] = @"rootfs not installed";
        return payload;
    }
    if (![ISHKernel shared].isBooted) {
        int code = [[ISHKernel shared] bootWithRootPath:[self rootfsPath]];
        payload[@"booted"] = @([ISHKernel shared].isBooted);
        if (code != 0) {
            payload[@"error"] = [NSString stringWithFormat:@"boot failed (%d)", code];
        }
    }
    return payload;
}

- (void)exec:(NSString *)command result:(FlutterResult)result {
    if (![self rootfsInstalled]) {
        result([FlutterError errorWithCode:@"sandbox_unavailable"
                                  message:@"rootfs not installed"
                                  details:nil]);
        return;
    }
    if (![ISHKernel shared].isBooted) {
        [[ISHKernel shared] bootWithRootPath:[self rootfsPath]];
    }
    if (![ISHKernel shared].isBooted) {
        result([FlutterError errorWithCode:@"sandbox_unavailable"
                                  message:@"kernel not booted"
                                  details:nil]);
        return;
    }

    // The executor reports on the main queue; run it off-main so a long guest
    // command cannot stall the UI.
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        ISHShellExecutionResult *r =
            [ISHShellExecutor executeCommandSync:command timeout:30 lineCallback:nil];
        dispatch_async(dispatch_get_main_queue(), ^{
            result(@{
                @"exitCode": @(r.exitCode),
                @"stdout": r.output ?: @"",
                @"stderr": r.errorOutput ?: @"",
            });
        });
    });
}

@end
