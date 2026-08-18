#import <Foundation/Foundation.h>
#import "BaseAuthenticator.h"

@interface ThirdPartyAuthenticator : BaseAuthenticator

- (void)loginWithCallback:(Callback)callback;
- (void)refreshTokenWithCallback:(Callback)callback;
- (NSArray *)getJvmArgsForAuthlib;

/// Resolve the ALI (API Location Indication) following the authlib-injector launcher technical specification
/// Expands the shorthand address entered by the user into a full API root and prefetches the server metadata
/// completion is invoked on the main thread; resolvedURL is the final API root (the original input is returned if resolution fails)
/// metadata is the server metadata JSON string (used for the prefetched parameter, nil on failure)
+ (void)resolveAuthserverURL:(NSString *)inputURL
                  completion:(void (^)(NSString *resolvedURL, NSString *_Nullable metadata))completion;

@end