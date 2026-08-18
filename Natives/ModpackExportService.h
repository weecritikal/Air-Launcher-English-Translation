#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Modpack export formats (following FCL/HMCL/ZL2)
typedef NS_ENUM(NSInteger, ModpackExportFormat) {
    ModpackExportFormatModrinth = 0,   // The Modrinth .mrpack format
    ModpackExportFormatCurseForge = 1, // The CurseForge .zip format (manifest.json)
    ModpackExportFormatMMC = 2,        // The MMC (MultiMC/Prism) .zip format (mmc-pack.json + instance.cfg)
    ModpackExportFormatPlainZip = 3,   // A plain .zip (packaging the .minecraft directory directly, HMCL compatible)
    ModpackExportFormatLinkList = 4,   // A link list .txt (the simple format FCL supports)
};

/// The file types that can optionally be included in an export (a bitmask)
/// Note: the enum value names must not clash with the typedef name `ModpackExportFileOptions`,
/// so the flag for options.txt is called `ModpackExportFileGameSettings`.
typedef NS_OPTIONS(NSInteger, ModpackExportFileOptions) {
    ModpackExportFileNone           = 0,
    ModpackExportFileMods           = 1 << 0,  // The mods/ folder
    ModpackExportFileConfigs        = 1 << 1,  // config/ + defaultconfigs/
    ModpackExportFileResourcePacks  = 1 << 2,  // resourcepacks/
    ModpackExportFileShaderPacks    = 1 << 3,  // shaderpacks/
    ModpackExportFileSaves          = 1 << 4,  // saves/ (excluded by default)
    ModpackExportFileGameSettings   = 1 << 5,  // options.txt/optionsof.txt/optionsshaders.txt
    ModpackExportFileServers        = 1 << 6,  // servers.dat (excluded by default, as it holds sensitive information)
    ModpackExportFileScripts        = 1 << 7,  // kubejs/scripts/localization/patchouli_books
    ModpackExportFileDefault        = ModpackExportFileMods | ModpackExportFileConfigs |
                                      ModpackExportFileResourcePacks | ModpackExportFileShaderPacks |
                                      ModpackExportFileGameSettings | ModpackExportFileScripts,
    ModpackExportFileAll            = ModpackExportFileMods | ModpackExportFileConfigs |
                                      ModpackExportFileResourcePacks | ModpackExportFileShaderPacks |
                                      ModpackExportFileSaves | ModpackExportFileGameSettings |
                                      ModpackExportFileServers | ModpackExportFileScripts,
};

/// Modpack export service (following FCL ExportModpackViewModel.kt / HMCL ModpackHelper / ZL2 ExportModpackHelper)
@interface ModpackExportService : NSObject

+ (instancetype)sharedService;

/// Cancellation signal: once set to YES from outside, an export in progress stops at the next checkpoint
@property (nonatomic, assign, getter=isCancelled) BOOL cancelled;

/// Reset the cancellation state (called before starting a new export)
- (void)resetCancelState;

/// Export a modpack (the basic version, using the default file options)
/// @param profileName The profile name (gameDir/lastVersionId come from PLProfiles.current.profiles)
/// @param destPath The destination file path (.mrpack / .zip / .txt)
/// @param name The modpack name
/// @param version The modpack version
/// @param author The author
/// @param format The export format
/// @param includeOverrides Whether to include overrides (config/options.txt and so on), equivalent to ModpackExportFileDefault
/// @param progress Progress callback (0.0-1.0)
/// @param error Error information
/// @return Whether it succeeded
- (BOOL)exportModpackForProfile:(NSString *)profileName
                         toPath:(NSString *)destPath
                            name:(NSString *)name
                         version:(NSString *)version
                          author:(NSString *)author
                         format:(ModpackExportFormat)format
                includeOverrides:(BOOL)includeOverrides
                       progress:(void (^_Nullable)(double progress, NSString *stageMessage))progress
                          error:(NSError **)error;

/// Export a modpack (the advanced version, with file type filtering)
/// @param fileOptions A file type bitmask deciding which folders/files are included in overrides
- (BOOL)exportModpackForProfile:(NSString *)profileName
                         toPath:(NSString *)destPath
                            name:(NSString *)name
                         version:(NSString *)version
                          author:(NSString *)author
                         format:(ModpackExportFormat)format
                     fileOptions:(ModpackExportFileOptions)fileOptions
                       progress:(void (^_Nullable)(double progress, NSString *stageMessage))progress
                          error:(NSError **)error;

/// Decode the loader and Minecraft version out of lastVersionId
/// For example "fabric-loader-0.15.7-1.20.1" -> loader="fabric", loaderVersion="0.15.7", mcVersion="1.20.1"
/// "1.20.1-forge-47.3.0" → loader="forge", loaderVersion="47.3.0", mcVersion="1.20.1"
/// "1.20.1-neoforge-47.1.0" → loader="neoforge", loaderVersion="47.1.0", mcVersion="1.20.1"
+ (NSDictionary *)parseVersionId:(NSString *)versionId;

/// Return the folders to package from fileOptions (without the "overrides/" prefix)
+ (NSArray<NSString *> *)overrideDirectoriesForOptions:(ModpackExportFileOptions)options;

/// Return the files to package from fileOptions (top-level file names)
+ (NSArray<NSString *> *)overrideFilesForOptions:(ModpackExportFileOptions)options;

@end

NS_ASSUME_NONNULL_END
