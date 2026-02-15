#import <Foundation/Foundation.h>
#import "ModpackAPI.h"
#import "ModVersion.h"
#import "ShaderVersion.h"

NS_ASSUME_NONNULL_BEGIN

@interface ModrinthAPI : ModpackAPI
+ (instancetype)sharedInstance;
- (void)getVersionsForModWithID:(NSString *)modID completion:(void (^)(NSArray<ModVersion *> * _Nullable versions, NSError * _Nullable error))completion;
- (void)searchShaderWithFilters:(NSDictionary *)filters completion:(void (^)(NSArray * _Nullable results, NSError * _Nullable error))completion;
- (void)getVersionsForShaderWithID:(NSString *)shaderID completion:(void (^)(NSArray<ShaderVersion *> * _Nullable versions, NSError * _Nullable error))completion;
@end

NS_ASSUME_NONNULL_END
