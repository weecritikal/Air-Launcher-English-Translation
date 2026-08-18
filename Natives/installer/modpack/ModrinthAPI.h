#import <Foundation/Foundation.h>
#import "ModpackAPI.h"
#import "ModVersion.h"
#import "ShaderVersion.h"

NS_ASSUME_NONNULL_BEGIN

@interface ModrinthAPI : ModpackAPI
+ (instancetype)sharedInstance;

// Synchronous methods
- (NSMutableArray *)searchModWithFilters:(NSDictionary<NSString *, NSString *> *)searchFilters 
                      previousPageResult:(NSMutableArray *)modrinthSearchResult;

// Asynchronous methods (recommended)
- (void)searchModWithFilters:(NSDictionary *)filters
                  completion:(void (^)(NSArray * _Nullable results, NSError * _Nullable error))completion;

- (void)getVersionsForModWithID:(NSString *)modID
                     completion:(void (^)(NSArray<ModVersion *> * _Nullable versions, NSError * _Nullable error))completion;

/// Asynchronously load the modpack version details (fixing the slow list load after tapping a modpack)
/// Uses NSURLSession directly, avoiding the synchronous dispatch_group_wait
- (void)loadDetailsOfModAsync:(NSMutableDictionary *)item
                   completion:(void (^)(BOOL success, NSError * _Nullable error))completion;

- (void)searchShaderWithFilters:(NSDictionary *)filters
                     completion:(void (^)(NSArray * _Nullable results, NSError * _Nullable error))completion;

- (void)getVersionsForShaderWithID:(NSString *)shaderID
                        completion:(void (^)(NSArray<ShaderVersion *> * _Nullable versions, NSError * _Nullable error))completion;

#pragma mark - Server Projects (Modrinth Server Projects API)

/// Asynchronously search for server projects: prefer project_type=server, falling back to project_type=modpack when the result is empty
/// @param filters The search filters (query/limit/offset/mcVersion/loader and so on)
/// @param completion the completion callback, returning an array of dictionaries (with apiSource=1 and a projectType field)
- (void)searchServersWithFilters:(NSDictionary *)filters
                      completion:(void (^)(NSArray * _Nullable results, NSError * _Nullable error))completion;

/// Asynchronously fetch the details of a server project (including fields such as server_address and the associated modpack)
/// @param serverID the Modrinth project ID
- (void)getServerDetailsForID:(NSString *)serverID
                   completion:(void (^)(NSDictionary * _Nullable details, NSError * _Nullable error))completion;

// Utility methods (called by the downloader)
- (NSString *)downloadURLForFile:(NSDictionary *)file;
- (BOOL)file:(NSDictionary *)file matchesProjectType:(NSString *)projectType;
- (NSMutableDictionary *)projectForFileHash:(NSString *)sha1 projectType:(NSString *)projectType;

@property (nonatomic, assign) BOOL reachedLastPage;
@property (nonatomic, strong, nullable) NSError *lastError;

@end

NS_ASSUME_NONNULL_END