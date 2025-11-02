#import <Foundation/Foundation.h>
#import "BaseAuthenticator.h"

@interface ThirdPartyAuthenticator : BaseAuthenticator

- (void)loginWithCallback:(Callback)callback;
- (void)refreshTokenWithCallback:(Callback)callback;
- (NSArray *)getJvmArgsForAuthlib;

@end