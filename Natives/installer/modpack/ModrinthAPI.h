#import <Foundation/Foundation.h>
#import "ModpackAPI.h"
#import "ModVersion.h"
#import "ShaderVersion.h"

NS_ASSUME_NONNULL_BEGIN

@interface ModrinthAPI : ModpackAPI <NSURLSessionDelegate>
+ (instancetype)sharedInstance;

// 现有的同步方法（保留用于兼容）
- (NSMutableArray *)searchModWithFilters:(NSDictionary<NSString *, NSString *> *)searchFilters 
                      previousPageResult:(NSMutableArray *)modrinthSearchResult;

// 新增：异步搜索方法（修复 DownloadViewController 的调用）
- (void)searchModWithFilters:(NSDictionary *)filters 
                  completion:(void (^)(NSArray * _Nullable results, NSError * _Nullable error))completion;

- (void)getVersionsForModWithID:(NSString *)modID 
                     completion:(void (^)(NSArray<ModVersion *> * _Nullable versions, NSError * _Nullable error))completion;

- (void)searchShaderWithFilters:(NSDictionary *)filters 
                     completion:(void (^)(NSArray * _Nullable results, NSError * _Nullable error))completion;

- (void)getVersionsForShaderWithID:(NSString *)shaderID 
                        completion:(void (^)(NSArray<ShaderVersion *> * _Nullable versions, NSError * _Nullable error))completion;

@end

NS_ASSUME_NONNULL_END
