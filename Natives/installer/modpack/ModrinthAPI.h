#import <Foundation/Foundation.h>
#import "ModpackAPI.h"
#import "ModVersion.h"

NS_ASSUME_NONNULL_BEGIN

@interface ModrinthAPI : ModpackAPI
+ (instancetype)sharedInstance;
- (void)getVersionsForModWithID:(NSString *)modID completion:(void (^)(NSArray<ModVersion *> * _Nullable versions, NSError * _Nullable error))completion;
@end

NS_ASSUME_NONNULL_END
