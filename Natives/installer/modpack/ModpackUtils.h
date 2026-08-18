#import <Foundation/Foundation.h>
#import "UnzipKit.h"

@interface ModpackUtils : NSObject

+ (void)archive:(UZKArchive *)archive extractDirectory:(NSString *)dir toPath:(NSString *)path error:(NSError **)error;
+ (NSDictionary *)infoForDependencies:(NSDictionary *)dependency;

/// Build the installer.jar download URL for a loader type (Forge/NeoForge)
/// Extracted from ModpackImportService, so ModrinthAPI/CurseForgeAPI modpack installation can reuse it
+ (nullable NSString *)installerURLForLoader:(NSString *)loader
                               loaderVersion:(NSString *)loaderVersion
                            minecraftVersion:(NSString *)minecraftVersion;

/// Infer the required major Java version from the MC version
+ (NSInteger)javaMajorVersionForMC:(NSString *)mcVersion;

/// Write a placeholder version JSON that fails explicitly (mainClass points at a nonexistent class, so launching reports an error explicitly)
/// This keeps a failed Forge/NeoForge direct install from being mistaken for vanilla MC and making the user believe their mods are active
+ (void)writePlaceholderVersionJSONForVersionId:(NSString *)versionId
                               minecraftVersion:(NSString *)minecraftVersion
                                         loader:(NSString *)loader
                                 loaderVersion:(NSString *)loaderVersion
                                          error:(NSError *)error;

@end
