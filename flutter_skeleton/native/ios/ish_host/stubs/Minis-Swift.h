#ifndef AMORE_STUB_MINIS_SWIFT_H
#define AMORE_STUB_MINIS_SWIFT_H
#import <Foundation/Foundation.h>
// The kernel asks the host for a custom resolv.conf. The Flutter runner has no
// container DNS settings, so answer "none" and the kernel uses the default.
@interface MinisContainerDns : NSObject
+ (nullable NSString *)customResolvConfForKernel;
@end
#endif
