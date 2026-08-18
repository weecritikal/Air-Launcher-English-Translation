#import <Foundation/Foundation.h>
#import "ModpackAPI.h"
#import "ModVersion.h"

NS_ASSUME_NONNULL_BEGIN

// NSError userInfo keys for diagnostic information (CurseForge API)
extern NSString *const CurseForgeResponseContentTypeKey;
extern NSString *const CurseForgeResponseSnippetKey;

/// CurseForge API implementation, supporting mods, resource packs, shaders, data packs, modpacks and more
@interface CurseForgeAPI : ModpackAPI

+ (instancetype)sharedInstance;

/// Determine whether the CurseForge API key has been configured (a three-level fallback: runtime preference + compile-time macro + Info.plist)
/// Used to gate the UI, and kept consistent with the apiKey getter used for the actual requests
+ (BOOL)isAPIKeyConfigured;

// ========== Synchronous methods (kept for older code; note that they block the thread) ==========
/// Search for projects (synchronous, uses dispatch_group_wait internally, so it should be called on a background queue)
- (NSMutableArray *)searchModWithFilters:(NSDictionary<NSString *, NSString *> *)searchFilters
                     previousPageResult:(nullable NSMutableArray *)previousPageResult;

/// Load project details (synchronous, fills in the item's version information)
- (void)loadDetailsOfMod:(NSMutableDictionary *)item;

// ========== Asynchronous methods (recommended, they do not block the UI) ==========
/// Asynchronous search (recommended), supporting projectType = @"resourcepack" / @"mod" / @"shader" and so on
- (void)searchModWithFilters:(NSDictionary *)filters
                  completion:(void (^)(NSArray * _Nullable results, NSError * _Nullable error))completion;

/// Asynchronously fetch every version of a project
- (void)getVersionsForModWithID:(NSString *)modID
                     completion:(void (^)(NSArray<ModVersion *> * _Nullable versions, NSError * _Nullable error))completion;

// ========== Asynchronous detail loading ==========
/// Load project details asynchronously (without blocking the calling thread)
- (void)loadDetailsOfMod:(NSMutableDictionary *)item
              completion:(void (^)(NSError * _Nullable error))completion;

#pragma mark - Server Packs (CurseForge server modpacks)

/// Asynchronously search for server modpacks: search classId=4471 (modpack) projects and present them as server modpacks
/// @param filters the search filter conditions (query/limit/offset/mcVersion and so on)
/// @param completion the completion callback, returning an array of dictionaries (with apiSource=2, projectType=modpack and a serverID field)
- (void)searchServersWithFilters:(NSDictionary *)filters
                      completion:(void (^)(NSArray * _Nullable results, NSError * _Nullable error))completion;

/// Asynchronously fetch the server pack file list of a given modpack project (the files with isServerPack=true)
/// @param modpackID CurseForge project id
/// @param completion the completion callback, returning an array of server pack file dictionaries
- (void)getServerPackFilesForModpack:(NSString *)modpackID
                          completion:(void (^)(NSArray * _Nullable files, NSError * _Nullable error))completion;

// ========== Download helper methods ==========
/// Get the direct download link for a file (CurseForge requires a second request)
- (NSString *)downloadURLForFile:(NSDictionary *)file;

/// Check whether a file matches the project type (for example resource packs only allow zip)
- (BOOL)file:(NSDictionary *)file matchesProjectType:(NSString *)projectType;

/// Get the recommended file extension for a project type (jar/zip)
- (NSArray<NSString *> *)preferredFileExtensionsForProjectType:(NSString *)projectType;

// ========== Fingerprint lookup ==========
/// Look up a CurseForge project from a MurmurHash2 file fingerprint (single file)
- (nullable NSMutableDictionary *)projectForFileHash:(NSString *)murmurHash projectType:(NSString *)projectType;

/// Bulk fingerprint lookup (used for bulk update checks)
- (NSArray<NSMutableDictionary *> *)fileFingerprints:(NSArray<NSNumber *> *)fingerprints;

// ========== Modpack handling ==========
/// Parse a CurseForge modpack (manifest.json) and submit the download tasks in bulk
- (void)downloader:(MinecraftResourceDownloadTask *)downloader
submitDownloadTasksFromPackage:(NSString *)packagePath
            toPath:(NSString *)destPath;

@end

NS_ASSUME_NONNULL_END