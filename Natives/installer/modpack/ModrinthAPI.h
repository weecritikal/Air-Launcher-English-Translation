#import <Foundation/Foundation.h>
#import "ModpackAPI.h"
#import "ModVersion.h"
#import "ShaderVersion.h"

NS_ASSUME_NONNULL_BEGIN

@interface ModrinthAPI : ModpackAPI
+ (instancetype)sharedInstance;

// 同步方法
- (NSMutableArray *)searchModWithFilters:(NSDictionary<NSString *, NSString *> *)searchFilters 
                      previousPageResult:(NSMutableArray *)modrinthSearchResult;

// 异步方法（推荐）
- (void)searchModWithFilters:(NSDictionary *)filters
                  completion:(void (^)(NSArray * _Nullable results, NSError * _Nullable error))completion;

- (void)getVersionsForModWithID:(NSString *)modID
                     completion:(void (^)(NSArray<ModVersion *> * _Nullable versions, NSError * _Nullable error))completion;

/// 异步加载整合包版本详情（修复点击整合包后加载列表过慢的问题）
/// 直接使用 NSURLSession，避免 dispatch_group_wait 同步阻塞
- (void)loadDetailsOfModAsync:(NSMutableDictionary *)item
                   completion:(void (^)(BOOL success, NSError * _Nullable error))completion;

- (void)searchShaderWithFilters:(NSDictionary *)filters 
                     completion:(void (^)(NSArray * _Nullable results, NSError * _Nullable error))completion;

- (void)getVersionsForShaderWithID:(NSString *)shaderID 
                        completion:(void (^)(NSArray<ShaderVersion *> * _Nullable versions, NSError * _Nullable error))completion;

// 工具方法（供下载器调用）
- (NSString *)downloadURLForFile:(NSDictionary *)file;
- (BOOL)file:(NSDictionary *)file matchesProjectType:(NSString *)projectType;
- (NSMutableDictionary *)projectForFileHash:(NSString *)sha1 projectType:(NSString *)projectType;

@property (nonatomic, assign) BOOL reachedLastPage;
@property (nonatomic, strong, nullable) NSError *lastError;

@end

NS_ASSUME_NONNULL_END