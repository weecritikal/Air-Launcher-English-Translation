//
//  ForgeDirectInstaller.h
//  Flux
//
//  Direct Forge installer (old + new format) based on FCL logic.
//

#import <Foundation/Foundation.h>

extern NSString *const ForgeDirectInstallerErrorDomain;

typedef NS_ENUM(NSInteger, ForgeDirectInstallerErrorCode) {
    ForgeDirectInstallerErrorInvalidArchive   = 1,
    ForgeDirectInstallerErrorMissingProfile   = 2,
    ForgeDirectInstallerErrorInvalidProfile   = 3,
    ForgeDirectInstallerErrorExtractionFailed = 4,
    ForgeDirectInstallerErrorWriteFailed      = 5,
    ForgeDirectInstallerErrorException        = 6
};

@interface ForgeDirectInstaller : NSObject

+ (BOOL)installForgeFromInstaller:(NSString *)installerPath
                        versionId:(NSString *)versionId
                            error:(NSError **)error;

+ (BOOL)installForgeFromInstaller:(NSString *)installerPath
                        versionId:(NSString *)versionId
                          progress:(void (^)(double progress, NSString *stageMessage))progress
                            error:(NSError **)error;

// Dedicated to modpack imports: supports a custom gameDir (written into the modpack's custom_gamedir subdirectory)
// The default POJAV_GAME_DIR is used when customGameDir is nil; when skipRegisterVersion=YES no profile is written (the caller registers it)
+ (BOOL)installForgeFromInstaller:(NSString *)installerPath
                        versionId:(NSString *)versionId
                    customGameDir:(nullable NSString *)customGameDir
              skipRegisterVersion:(BOOL)skipRegisterVersion
                         progress:(void (^)(double progress, NSString *stageMessage))progress
                            error:(NSError **)error;

+ (BOOL)isNewFormatInstaller:(NSString *)installerPath;

+ (BOOL)ensureParentVersionExists:(NSString *)minecraftVersion error:(NSError **)error;

/// Return the runtime artifacts a Forge version needs to start but cannot use, each as
/// @{@"path": absolute path, @"reason": why it is unusable}.
///
/// Forge 1.13+ boots through three files its installer's processors build - the SRG-mapped client,
/// the client's resources, and the patched Forge client. FML rebuilds those paths from the version
/// JSON's --fml.* game arguments rather than its library list, so this reads the same arguments to
/// predict exactly what it will look for. Being present is not enough: these are written locally
/// rather than downloaded, so an interrupted install leaves a file that exists and will not open,
/// and the JVM reports that as "zip END header not found" without naming it. An empty result means
/// all three are there and readable, including for versions that do not boot this way at all.
+ (NSArray<NSDictionary<NSString *, NSString *> *> *)unusableRuntimeArtifactsForVersionJSON:(NSDictionary *)versionJson
                                                                              librariesDir:(NSString *)librariesDir;

@end
