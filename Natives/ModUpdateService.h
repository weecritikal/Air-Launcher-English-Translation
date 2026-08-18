#import <Foundation/Foundation.h>
#import "ModItem.h"
#import "ModVersion.h"

NS_ASSUME_NONNULL_BEGIN

/// The update check result for one mod
@interface ModUpdateResult : NSObject
/// Path of the local mod file
@property (nonatomic, copy) NSString *localFilePath;
/// The current version (the one the lookup matched)
@property (nonatomic, strong, nullable) ModVersion *currentVersion;
/// Candidate update versions (sorted by datePublished descending, newest first)
@property (nonatomic, copy) NSArray<ModVersion *> *candidateVersions;
/// Every version (used for downgrading, sorted by datePublished descending)
@property (nonatomic, copy) NSArray<ModVersion *> *allVersions;
/// Project ID (used to fetch the version list)
@property (nonatomic, copy, nullable) NSString *projectID;
/// API source (1=Modrinth, 2=CurseForge)
@property (nonatomic, strong, nullable) NSNumber *apiSource;
/// Project type (mod/shader/resourcepack/datapack)
@property (nonatomic, copy) NSString *projectType;
/// Whether an update is available
- (BOOL)hasUpdate;
@end

@interface ModUpdateService : NSObject

+ (instancetype)sharedService;

/// Check one mod for updates
/// @param mod The local mod item (which needs filePath and fileSHA1)
/// @param gameVersion The current game version (such as "1.20.1")
/// @param loader The current loader (such as "fabric"/"forge"/"neoforge"/"quilt"; may be nil)
/// @param projectType The project type (mod/shader/resourcepack/datapack)
/// @param completion Result callback (on the main thread; a nil result means the check failed or found no match)
- (void)checkUpdateForMod:(ModItem *)mod
              gameVersion:(NSString *)gameVersion
                   loader:(nullable NSString *)loader
              projectType:(NSString *)projectType
               completion:(void (^)(ModUpdateResult *_Nullable result))completion;

/// Check many mods for updates (with a concurrency limit of 3)
/// @param mods The array of local mods
/// @param gameVersion The current game version
/// @param loader The current loader
/// @param projectType The project type
/// @param progress Progress callback (completed count / total)
/// @param completion Called when everything finishes (the results array holds one entry per mod that was checked; mods with no update are not included)
- (void)checkUpdatesForMods:(NSArray<ModItem *> *)mods
               gameVersion:(NSString *)gameVersion
                    loader:(nullable NSString *)loader
               projectType:(NSString *)projectType
                  progress:(void (^)(NSInteger completed, NSInteger total))progress
                completion:(void (^)(NSArray<ModUpdateResult *> *results))completion;

@end

NS_ASSUME_NONNULL_END
