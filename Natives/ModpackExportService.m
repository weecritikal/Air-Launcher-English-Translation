#import "ModpackExportService.h"
#import "PLProfiles.h"
#import "ModService.h"
#import "external/UnzipKit/UZKArchive.h"
#import <CommonCrypto/CommonCrypto.h>
#import "utils.h"

@interface ModpackExportService ()
/// Resolve the profile gameDir into an absolute path (reusing the ModService logic)
- (nullable NSString *)resolveAbsoluteGameDirForProfile:(NSString *)profileName;
/// Compute the sha1 of a file (read in chunks, to avoid memory pressure on large files)
- (nullable NSString *)sha1ForFileAtPath:(NSString *)path;
/// Compute the sha512 of a file (read in chunks)
- (nullable NSString *)sha512ForFileAtPath:(NSString *)path;
/// Write a folder into the zip recursively
- (void)addDirectoryToArchive:(UZKArchive *)archive
                      dirPath:(NSString *)dirPath
                  prefixInZip:(NSString *)prefixInZip
                     progress:(void (^_Nullable)(NSUInteger done, NSUInteger total))progress;
/// Internal: check the cancellation signal
- (BOOL)checkCancelledWithError:(NSError **)error;
@end

@implementation ModpackExportService

+ (instancetype)sharedService {
    static ModpackExportService *sharedInstance = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        sharedInstance = [[self alloc] init];
    });
    return sharedInstance;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _cancelled = NO;
    }
    return self;
}

- (void)resetCancelState {
    @synchronized(self) {
        _cancelled = NO;
    }
}

- (BOOL)checkCancelledWithError:(NSError **)error {
    @synchronized(self) {
        if (_cancelled) {
            if (error) {
                *error = [NSError errorWithDomain:@"ModpackExportService"
                                             code:9999
                                         userInfo:@{NSLocalizedDescriptionKey: @"Export cancelled"}];
            }
            return YES;
        }
    }
    return NO;
}

+ (NSArray<NSString *> *)overrideDirectoriesForOptions:(ModpackExportFileOptions)options {
    NSMutableArray *dirs = [NSMutableArray array];
    if (options & ModpackExportFileMods) {
        [dirs addObject:@"mods"];
    }
    if (options & ModpackExportFileConfigs) {
        [dirs addObject:@"config"];
        [dirs addObject:@"defaultconfigs"];
    }
    if (options & ModpackExportFileResourcePacks) {
        [dirs addObject:@"resourcepacks"];
    }
    if (options & ModpackExportFileShaderPacks) {
        [dirs addObject:@"shaderpacks"];
    }
    if (options & ModpackExportFileSaves) {
        [dirs addObject:@"saves"];
    }
    if (options & ModpackExportFileScripts) {
        [dirs addObject:@"kubejs"];
        [dirs addObject:@"scripts"];
        [dirs addObject:@"localization"];
        [dirs addObject:@"patchouli_books"];
    }
    return [dirs copy];
}

+ (NSArray<NSString *> *)overrideFilesForOptions:(ModpackExportFileOptions)options {
    NSMutableArray *files = [NSMutableArray array];
    if (options & ModpackExportFileGameSettings) {
        [files addObject:@"options.txt"];
        [files addObject:@"optionsof.txt"];
        [files addObject:@"optionsshaders.txt"];
        [files addObject:@"hotbar.nbt"];
    }
    if (options & ModpackExportFileServers) {
        [files addObject:@"servers.dat"];
        [files addObject:@"servers.dat_old"];
        [files addObject:@"realms_persistence.json"];
    }
    if (options & ModpackExportFileGameSettings) {
        [files addObject:@"launcher_profiles.json"];
    }
    return [files copy];
}

#pragma mark - Public export API

- (BOOL)exportModpackForProfile:(NSString *)profileName
                         toPath:(NSString *)destPath
                            name:(NSString *)name
                         version:(NSString *)version
                          author:(NSString *)author
                         format:(ModpackExportFormat)format
                includeOverrides:(BOOL)includeOverrides
                       progress:(void (^_Nullable)(double progress, NSString *stageMessage))progress
                          error:(NSError **)error {
    ModpackExportFileOptions options = includeOverrides ? ModpackExportFileDefault : ModpackExportFileMods;
    return [self exportModpackForProfile:profileName
                                  toPath:destPath
                                     name:name
                                  version:version
                                   author:author
                                  format:format
                              fileOptions:options
                                 progress:progress
                                    error:error];
}

- (BOOL)exportModpackForProfile:(NSString *)profileName
                         toPath:(NSString *)destPath
                            name:(NSString *)name
                         version:(NSString *)version
                          author:(NSString *)author
                         format:(ModpackExportFormat)format
                     fileOptions:(ModpackExportFileOptions)fileOptions
                       progress:(void (^_Nullable)(double progress, NSString *stageMessage))progress
                          error:(NSError **)error {
    if (error) *error = nil;
    NSString *resolvedAuthor = author.length > 0 ? author : @"Flux User";

    void (^reportProgress)(double, NSString *) = ^(double p, NSString *msg) {
        NSLog(@"[ModpackExport] Progress: %.2f - %@", p, msg);
        if (progress) progress(p, msg);
    };

    reportProgress(0.0, @"Starting the modpack export");

    // Cancellation checkpoint
    if ([self checkCancelledWithError:error]) return NO;

    // 1. Read the profile information
    NSDictionary *profile = PLProfiles.current.profiles[profileName];
    if (![profile isKindOfClass:[NSDictionary class]]) {
        if (error) {
            *error = [NSError errorWithDomain:@"ModpackExportService" code:1
                                     userInfo:@{NSLocalizedDescriptionKey: @"The specified profile was not found"}];
        }
        return NO;
    }

    NSString *lastVersionId = profile[@"lastVersionId"] ?: @"";
    NSString *gameDirAbsolute = [self resolveAbsoluteGameDirForProfile:profileName];
    if (gameDirAbsolute.length == 0) {
        const char *env = getenv("POJAV_GAME_DIR");
        gameDirAbsolute = env ? [NSString stringWithUTF8String:env] : NSHomeDirectory();
    }

    // 2. Decode the loader and MC version
    NSDictionary *versionInfo = [ModpackExportService parseVersionId:lastVersionId];
    NSString *mcVersion = versionInfo[@"minecraft"] ?: @"";
    NSString *loader = versionInfo[@"loader"] ?: @"";
    NSString *loaderVersion = versionInfo[@"loaderVersion"] ?: @"";

    NSLog(@"[ModpackExport] Profile=%@, mcVersion=%@, loader=%@ %@, gameDir=%@",
          profileName, mcVersion, loader, loaderVersion, gameDirAbsolute);

    if (mcVersion.length == 0) {
        if (error) {
            *error = [NSError errorWithDomain:@"ModpackExportService" code:2
                                     userInfo:@{NSLocalizedDescriptionKey: @"Could not determine the Minecraft version (unrecognized lastVersionId format)"}];
        }
        return NO;
    }

    // Cancellation checkpoint
    if ([self checkCancelledWithError:error]) return NO;

    // 3. Collect the list of mod files
    reportProgress(0.1, @"Scanning the mods folder");
    NSFileManager *fm = [NSFileManager defaultManager];
    NSString *modsDir = [gameDirAbsolute stringByAppendingPathComponent:@"mods"];
    NSMutableArray<NSDictionary *> *modFiles = [NSMutableArray new];
    if ([fm fileExistsAtPath:modsDir]) {
        // Scan nested folders (some modpacks put mods in subfolders)
        NSDirectoryEnumerator *enumerator = [fm enumeratorAtPath:modsDir];
        NSString *relativePath;
        while ((relativePath = [enumerator nextObject])) {
            NSString *fullPath = [modsDir stringByAppendingPathComponent:relativePath];
            BOOL isDir = NO;
            if (![fm fileExistsAtPath:fullPath isDirectory:&isDir] || isDir) continue;
            // Include only .jar files (not .disabled ones)
            if (![relativePath hasSuffix:@".jar"]) continue;
            NSDictionary *attrs = [fm attributesOfItemAtPath:fullPath error:nil];
            unsigned long long fileSize = [attrs fileSize];
            NSString *sha1 = [self sha1ForFileAtPath:fullPath];
            [modFiles addObject:@{
                @"path": [NSString stringWithFormat:@"mods/%@", relativePath],
                @"fullPath": fullPath,
                @"fileName": relativePath.lastPathComponent,
                @"sha1": sha1 ?: @"",
                @"fileSize": @(fileSize)
            }];
        }
    }
    NSLog(@"[ModpackExport] Found %lu mod files", (unsigned long)modFiles.count);

    // Cancellation checkpoint
    if ([self checkCancelledWithError:error]) return NO;

    // 4. Export in the chosen format
    switch (format) {
        case ModpackExportFormatModrinth:
            return [self exportModrinthFormat:modFiles
                                      toPath:destPath
                                         name:name
                                      version:version
                                       author:resolvedAuthor
                                    mcVersion:mcVersion
                                       loader:loader
                                loaderVersion:loaderVersion
                                gameDirAbsolute:gameDirAbsolute
                                  fileOptions:fileOptions
                                      progress:reportProgress
                                         error:error];
        case ModpackExportFormatCurseForge:
            return [self exportCurseForgeFormat:modFiles
                                         toPath:destPath
                                            name:name
                                         version:version
                                          author:resolvedAuthor
                                       mcVersion:mcVersion
                                          loader:loader
                                    loaderVersion:loaderVersion
                                gameDirAbsolute:gameDirAbsolute
                                  fileOptions:fileOptions
                                        progress:reportProgress
                                           error:error];
        case ModpackExportFormatMMC:
            return [self exportMMCFormat:modFiles
                                  toPath:destPath
                                     name:name
                                  version:version
                                   author:resolvedAuthor
                                mcVersion:mcVersion
                                   loader:loader
                            loaderVersion:loaderVersion
                            gameDirAbsolute:gameDirAbsolute
                              fileOptions:fileOptions
                                profileName:profileName
                                  progress:reportProgress
                                     error:error];
        case ModpackExportFormatPlainZip:
            return [self exportPlainZipFormat:modFiles
                                       toPath:destPath
                                          name:name
                                       version:version
                                        author:resolvedAuthor
                                     mcVersion:mcVersion
                                        loader:loader
                                  loaderVersion:loaderVersion
                                  gameDirAbsolute:gameDirAbsolute
                                    fileOptions:fileOptions
                                      progress:reportProgress
                                         error:error];
        case ModpackExportFormatLinkList:
            return [self exportLinkListFormat:modFiles
                                       toPath:destPath
                                      mcVersion:mcVersion
                                         loader:loader
                                   loaderVersion:loaderVersion
                                         name:name
                                       version:version
                                         error:error];
    }
    return NO;
}

#pragma mark - Modrinth format export

- (BOOL)exportModrinthFormat:(NSArray<NSDictionary *> *)modFiles
                      toPath:(NSString *)destPath
                        name:(NSString *)name
                     version:(NSString *)version
                      author:(NSString *)author
                   mcVersion:(NSString *)mcVersion
                      loader:(NSString *)loader
              loaderVersion:(NSString *)loaderVersion
            gameDirAbsolute:(NSString *)gameDirAbsolute
                fileOptions:(ModpackExportFileOptions)fileOptions
                    progress:(void (^)(double, NSString *))progress
                       error:(NSError **)error {
    (void)author;
    if ([self checkCancelledWithError:error]) return NO;

    progress(0.2, @"Generating modrinth.index.json");
    NSFileManager *fm = [NSFileManager defaultManager];

    // Build dependencies
    NSMutableDictionary *dependencies = @{@"minecraft": mcVersion}.mutableCopy;
    if ([loader isEqualToString:@"fabric"] && loaderVersion.length > 0) {
        dependencies[@"fabric-loader"] = loaderVersion;
    } else if ([loader isEqualToString:@"quilt"] && loaderVersion.length > 0) {
        dependencies[@"quilt-loader"] = loaderVersion;
    } else if ([loader isEqualToString:@"forge"] && loaderVersion.length > 0) {
        dependencies[@"forge"] = loaderVersion;
    } else if ([loader isEqualToString:@"neoforge"] && loaderVersion.length > 0) {
        dependencies[@"neoforge"] = loaderVersion;
    }

    // Build the files list
    NSMutableArray *files = [NSMutableArray new];
    for (NSDictionary *modFile in modFiles) {
        if ([self checkCancelledWithError:error]) return NO;
        NSString *sha512 = [self sha512ForFileAtPath:modFile[@"fullPath"]];
        [files addObject:@{
            @"path": modFile[@"path"],
            @"hashes": @{
                @"sha1": modFile[@"sha1"],
                @"sha512": sha512 ?: @""
            },
            @"downloads": @[],  // No download links; import restores them from overrides (matching the HMCL export strategy)
            @"fileSize": modFile[@"fileSize"]
        }];
    }

    // Build modrinth.index.json
    NSDictionary *indexJson = @{
        @"formatVersion": @(1),
        @"game": @"minecraft",
        @"versionId": version.length > 0 ? version : @"1.0",
        @"name": name.length > 0 ? name : @"Exported Modpack",
        @"files": files,
        @"dependencies": dependencies
    };

    NSData *indexData = [NSJSONSerialization dataWithJSONObject:indexJson options:NSJSONWritingPrettyPrinted error:error];
    if (!indexData) {
        if (error && !*error) {
            *error = [NSError errorWithDomain:@"ModpackExportService" code:3
                                     userInfo:@{NSLocalizedDescriptionKey: @"Failed to generate modrinth.index.json"}];
        }
        return NO;
    }

    if ([self checkCancelledWithError:error]) return NO;

    progress(0.3, @"Creating the zip file");
    [fm removeItemAtPath:destPath error:nil];

    NSError *archiveError = nil;
    UZKArchive *archive = [[UZKArchive alloc] initWithPath:destPath error:&archiveError];
    if (!archive || archiveError) {
        if (error) *error = archiveError;
        return NO;
    }

    // Write modrinth.index.json
    progress(0.4, @"Writing modrinth.index.json");
    if (![archive writeData:indexData filePath:@"modrinth.index.json" error:&archiveError]) {
        if (error) *error = archiveError;
        return NO;
    }

    // Write the overrides
    if (![self writeOverridesToArchive:archive
                          gameDirAbsolute:gameDirAbsolute
                            fileOptions:fileOptions
                              zipPrefix:@"overrides"
                          baseProgress:0.5
                          progressRange:0.4
                                progress:progress
                                  error:error]) {
        return NO;
    }

    progress(0.95, @"Finishing the export");
    archive = nil;

    progress(1.0, @"Export complete");
    NSLog(@"[ModpackExport] Modrinth format export completed: %@", destPath);
    return YES;
}

#pragma mark - CurseForge format export

- (BOOL)exportCurseForgeFormat:(NSArray<NSDictionary *> *)modFiles
                        toPath:(NSString *)destPath
                           name:(NSString *)name
                        version:(NSString *)version
                         author:(NSString *)author
                      mcVersion:(NSString *)mcVersion
                         loader:(NSString *)loader
                 loaderVersion:(NSString *)loaderVersion
               gameDirAbsolute:(NSString *)gameDirAbsolute
                   fileOptions:(ModpackExportFileOptions)fileOptions
                       progress:(void (^)(double, NSString *))progress
                          error:(NSError **)error {
    if ([self checkCancelledWithError:error]) return NO;

    progress(0.2, @"Generating manifest.json");
    NSFileManager *fm = [NSFileManager defaultManager];

    // Build modLoaders
    NSMutableArray *modLoaders = [NSMutableArray new];
    if (loader.length > 0 && loaderVersion.length > 0) {
        NSString *loaderId = [NSString stringWithFormat:@"%@-%@", loader, loaderVersion];
        [modLoaders addObject:@{@"id": loaderId, @"primary": @YES}];
    }

    // Build manifest.json
    // Note: the CurseForge format needs a projectID/fileID, which a local mod cannot provide.
    // Simplification: files is left empty and every mod is packed into overrides/mods/ (matching the HMCL export strategy)
    NSDictionary *manifest = @{
        @"minecraft": @{
            @"version": mcVersion,
            @"modLoaders": modLoaders
        },
        @"manifestType": @"minecraftModpack",
        @"manifestVersion": @(1),
        @"name": name.length > 0 ? name : @"Exported Modpack",
        @"version": version.length > 0 ? version : @"1.0",
        @"author": author.length > 0 ? author : @"Flux User",
        @"files": @[],
        @"overrides": @"overrides"
    };

    NSData *manifestData = [NSJSONSerialization dataWithJSONObject:manifest options:NSJSONWritingPrettyPrinted error:error];
    if (!manifestData) {
        if (error && !*error) {
            *error = [NSError errorWithDomain:@"ModpackExportService" code:4
                                     userInfo:@{NSLocalizedDescriptionKey: @"Failed to generate manifest.json"}];
        }
        return NO;
    }

    if ([self checkCancelledWithError:error]) return NO;

    progress(0.3, @"Creating the zip file");
    [fm removeItemAtPath:destPath error:nil];

    NSError *archiveError = nil;
    UZKArchive *archive = [[UZKArchive alloc] initWithPath:destPath error:&archiveError];
    if (!archive || archiveError) {
        if (error) *error = archiveError;
        return NO;
    }

    progress(0.4, @"Writing manifest.json");
    if (![archive writeData:manifestData filePath:@"manifest.json" error:&archiveError]) {
        if (error) *error = archiveError;
        return NO;
    }

    if (![self writeOverridesToArchive:archive
                          gameDirAbsolute:gameDirAbsolute
                            fileOptions:fileOptions
                              zipPrefix:@"overrides"
                          baseProgress:0.5
                          progressRange:0.4
                                progress:progress
                                  error:error]) {
        return NO;
    }

    progress(0.95, @"Finishing the export");
    archive = nil;

    progress(1.0, @"Export complete");
    NSLog(@"[ModpackExport] CurseForge format export completed: %@", destPath);
    return YES;
}

#pragma mark - MMC (MultiMC/Prism) format export

/// The MMC format:
///   mmc-pack.json: holds a components array (net.minecraft + the loader component)
///   instance.cfg: key=value pairs, including name/JvmArgs/InstanceType and so on
///   .minecraft/: holds mods/config/options.txt and so on (not under overrides/, but directly under .minecraft/)
- (BOOL)exportMMCFormat:(NSArray<NSDictionary *> *)modFiles
                 toPath:(NSString *)destPath
                    name:(NSString *)name
                 version:(NSString *)version
                  author:(NSString *)author
               mcVersion:(NSString *)mcVersion
                  loader:(NSString *)loader
          loaderVersion:(NSString *)loaderVersion
          gameDirAbsolute:(NSString *)gameDirAbsolute
            fileOptions:(ModpackExportFileOptions)fileOptions
            profileName:(NSString *)profileName
                progress:(void (^)(double, NSString *))progress
                   error:(NSError **)error {
    if ([self checkCancelledWithError:error]) return NO;

    progress(0.2, @"Generating mmc-pack.json");
    NSFileManager *fm = [NSFileManager defaultManager];

    // Build the components array
    NSMutableArray *components = [NSMutableArray array];
    [components addObject:@{
        @"cachedName": @"Minecraft",
        @"cachedVersion": mcVersion,
        @"important": @YES,
        @"uid": @"net.minecraft",
        @"version": mcVersion
    }];
    if ([loader isEqualToString:@"fabric"] && loaderVersion.length > 0) {
        [components addObject:@{
            @"cachedName": @"Fabric Loader",
            @"uid": @"net.fabricmc.fabric-loader",
            @"version": loaderVersion
        }];
    } else if ([loader isEqualToString:@"quilt"] && loaderVersion.length > 0) {
        [components addObject:@{
            @"cachedName": @"Quilt Loader",
            @"uid": @"org.quiltmc.quilt-loader",
            @"version": loaderVersion
        }];
    } else if ([loader isEqualToString:@"forge"] && loaderVersion.length > 0) {
        [components addObject:@{
            @"cachedName": @"Forge",
            @"uid": @"net.minecraftforge",
            @"version": loaderVersion
        }];
    } else if ([loader isEqualToString:@"neoforge"] && loaderVersion.length > 0) {
        [components addObject:@{
            @"cachedName": @"NeoForge",
            @"uid": @"net.neoforged",
            @"version": loaderVersion
        }];
    }

    NSDictionary *mmcPack = @{
        @"components": components,
        @"formatVersion": @(1)
    };

    NSData *mmcPackData = [NSJSONSerialization dataWithJSONObject:mmcPack options:NSJSONWritingPrettyPrinted error:error];
    if (!mmcPackData) {
        if (error && !*error) {
            *error = [NSError errorWithDomain:@"ModpackExportService" code:5
                                     userInfo:@{NSLocalizedDescriptionKey: @"Failed to generate mmc-pack.json"}];
        }
        return NO;
    }

    // Build instance.cfg (key=value format)
    NSString *instanceName = name.length > 0 ? name : (profileName ?: @"Exported Modpack");
    NSMutableString *cfgContent = [NSMutableString string];
    [cfgContent appendFormat:@"InstanceType=OneSix\n"];
    [cfgContent appendFormat:@"name=%@\n", instanceName];
    [cfgContent appendFormat:@"%s=%@\n", "notes", [NSString stringWithFormat:@"Exported by Flux v%@", version.length > 0 ? version : @"1.0"]];
    [cfgContent appendFormat:@"%s=%@\n", "iconKey", "default"];
    [cfgContent appendFormat:@"%s=%@\n", "OverrideCommands", "false"];
    [cfgContent appendFormat:@"%s=%@\n", "OverrideConsole", "false"];
    [cfgContent appendFormat:@"%s=%@\n", "OverrideJava", "false"];
    [cfgContent appendFormat:@"%s=%@\n", "OverrideJavaArgs", "false"];
    [cfgContent appendFormat:@"%s=%@\n", "OverrideMCLauncher", "false"];
    [cfgContent appendFormat:@"%s=%@\n", "OverrideWindow", "false"];
    NSData *cfgData = [cfgContent dataUsingEncoding:NSUTF8StringEncoding];

    if ([self checkCancelledWithError:error]) return NO;

    progress(0.3, @"Creating the zip file");
    [fm removeItemAtPath:destPath error:nil];

    NSError *archiveError = nil;
    UZKArchive *archive = [[UZKArchive alloc] initWithPath:destPath error:&archiveError];
    if (!archive || archiveError) {
        if (error) *error = archiveError;
        return NO;
    }

    progress(0.4, @"Writing mmc-pack.json");
    if (![archive writeData:mmcPackData filePath:@"mmc-pack.json" error:&archiveError]) {
        if (error) *error = archiveError;
        return NO;
    }
    progress(0.45, @"Writing instance.cfg");
    if (cfgData && ![archive writeData:cfgData filePath:@"instance.cfg" error:&archiveError]) {
        if (error) *error = archiveError;
        return NO;
    }

    // The MMC overrides are written under the .minecraft/ prefix (the standard MMC structure)
    if (![self writeOverridesToArchive:archive
                          gameDirAbsolute:gameDirAbsolute
                            fileOptions:fileOptions
                              zipPrefix:@".minecraft"
                          baseProgress:0.5
                          progressRange:0.4
                                progress:progress
                                  error:error]) {
        return NO;
    }

    progress(0.95, @"Finishing the export");
    archive = nil;

    progress(1.0, @"Export complete");
    NSLog(@"[ModpackExport] MMC format export completed: %@", destPath);
    return YES;
}

#pragma mark - Plain zip format export (HMCL compatible)

/// The Plain Zip format: package the .minecraft folder directly, with no manifest/mmc-pack.json
/// Good for interoperating with PojavLauncher/HMCL: the gameDir contents are packed straight under the .minecraft/ prefix
- (BOOL)exportPlainZipFormat:(NSArray<NSDictionary *> *)modFiles
                      toPath:(NSString *)destPath
                         name:(NSString *)name
                      version:(NSString *)version
                       author:(NSString *)author
                     mcVersion:(NSString *)mcVersion
                        loader:(NSString *)loader
                  loaderVersion:(NSString *)loaderVersion
                  gameDirAbsolute:(NSString *)gameDirAbsolute
                    fileOptions:(ModpackExportFileOptions)fileOptions
                      progress:(void (^)(double, NSString *))progress
                         error:(NSError **)error {
    (void)name; (void)version; (void)author; (void)loader; (void)loaderVersion;
    if ([self checkCancelledWithError:error]) return NO;

    progress(0.2, @"Creating the zip file");
    NSFileManager *fm = [NSFileManager defaultManager];
    [fm removeItemAtPath:destPath error:nil];

    NSError *archiveError = nil;
    UZKArchive *archive = [[UZKArchive alloc] initWithPath:destPath error:&archiveError];
    if (!archive || archiveError) {
        if (error) *error = archiveError;
        return NO;
    }

    // Write .minecraft/AMETHYST_INFO.txt with metadata (optional, helping other launchers identify where it came from)
    NSString *infoContent = [NSString stringWithFormat:
        @"Flux Exported Modpack\n"
        @"Minecraft: %@\n"
        @"Loader: %@ %@\n"
        @"Export Time: %@\n",
        mcVersion,
        loader ?: @"vanilla",
        loaderVersion ?: @"",
        [[NSDate date] description]];
    NSData *infoData = [infoContent dataUsingEncoding:NSUTF8StringEncoding];
    if (infoData) {
        [archive writeData:infoData filePath:@".minecraft/AMETHYST_INFO.txt" error:nil];
    }

    // Write under the .minecraft/<...> prefix
    if (![self writeOverridesToArchive:archive
                          gameDirAbsolute:gameDirAbsolute
                            fileOptions:fileOptions
                              zipPrefix:@".minecraft"
                          baseProgress:0.3
                          progressRange:0.6
                                progress:progress
                                  error:error]) {
        return NO;
    }

    progress(0.95, @"Finishing the export");
    archive = nil;

    progress(1.0, @"Export complete");
    NSLog(@"[ModpackExport] Plain Zip format export completed: %@", destPath);
    return YES;
}

#pragma mark - Link list format export (the simple format FCL supports)

- (BOOL)exportLinkListFormat:(NSArray<NSDictionary *> *)modFiles
                      toPath:(NSString *)destPath
                   mcVersion:(NSString *)mcVersion
                      loader:(NSString *)loader
              loaderVersion:(NSString *)loaderVersion
                        name:(NSString *)name
                     version:(NSString *)version
                       error:(NSError **)error {
    // The FCL link list format:
    // # Minecraft: <mcVersion>
    // # Loader: <loader>-<loaderVersion>
    // # Name: <name>
    // # Version: <version>
    // <path inside zip>|<download link or local path>
    NSMutableString *content = [NSMutableString string];
    [content appendFormat:@"# Minecraft: %@\n", mcVersion];
    if (loader.length > 0 && loaderVersion.length > 0) {
        [content appendFormat:@"# Loader: %@-%@\n", loader, loaderVersion];
    }
    [content appendFormat:@"# Name: %@\n", name.length > 0 ? name : @"Exported Modpack"];
    [content appendFormat:@"# Version: %@\n", version.length > 0 ? version : @"1.0"];
    [content appendString:@"# Format: <path inside zip>|<download link or local path>\n\n"];

    for (NSDictionary *modFile in modFiles) {
        // Link list format: the mod path plus an empty download link (which the user can fill in)
        [content appendFormat:@"%@|\n", modFile[@"path"]];
    }

    NSError *writeError = nil;
    BOOL success = [content writeToFile:destPath atomically:YES encoding:NSUTF8StringEncoding error:&writeError];
    if (!success) {
        if (error) *error = writeError;
        return NO;
    }
    NSLog(@"[ModpackExport] Link list format export completed: %@", destPath);
    return YES;
}

#pragma mark - Writing the shared overrides

/// Shared overrides writing: fileOptions decides which folders/files are packaged
- (BOOL)writeOverridesToArchive:(UZKArchive *)archive
               gameDirAbsolute:(NSString *)gameDirAbsolute
                     fileOptions:(ModpackExportFileOptions)fileOptions
                       zipPrefix:(NSString *)zipPrefix
                     baseProgress:(double)baseProgress
                   progressRange:(double)progressRange
                         progress:(void (^)(double, NSString *))progress
                            error:(NSError **)error {
    NSFileManager *fm = [NSFileManager defaultManager];
    NSArray<NSString *> *overrideDirs = [ModpackExportService overrideDirectoriesForOptions:fileOptions];
    NSArray<NSString *> *overrideFiles = [ModpackExportService overrideFilesForOptions:fileOptions];

    NSUInteger totalItems = overrideDirs.count + overrideFiles.count;
    if (totalItems == 0) {
        progress(baseProgress + progressRange, @"No overrides to package");
        return YES;
    }

    __block NSUInteger processed = 0;
    __block NSError *blockError = nil;

    // Count the files in each folder, for accurate progress
    NSUInteger totalFiles = 0;
    for (NSString *dir in overrideDirs) {
        NSString *dirPath = [gameDirAbsolute stringByAppendingPathComponent:dir];
        if (![fm fileExistsAtPath:dirPath]) continue;
        NSDirectoryEnumerator *e = [fm enumeratorAtPath:dirPath];
        NSString *rel;
        while ((rel = [e nextObject])) {
            NSString *full = [dirPath stringByAppendingPathComponent:rel];
            BOOL isDir = NO;
            if ([fm fileExistsAtPath:full isDirectory:&isDir] && !isDir) {
                totalFiles++;
            }
        }
    }
    totalFiles += overrideFiles.count;
    if (totalFiles == 0) {
        progress(baseProgress + progressRange, @"No overrides to package");
        return YES;
    }

    __block NSUInteger processedFiles = 0;

    // Package the folders
    for (NSString *dir in overrideDirs) {
        if ([self checkCancelledWithError:error]) return NO;
        NSString *dirPath = [gameDirAbsolute stringByAppendingPathComponent:dir];
        if (![fm fileExistsAtPath:dirPath]) {
            processed++;
            continue;
        }
        NSString *prefixInZip = [NSString stringWithFormat:@"%@/%@", zipPrefix, dir];
        [self addDirectoryToArchive:archive
                            dirPath:dirPath
                        prefixInZip:prefixInZip
                           progress:^(NSUInteger done, NSUInteger total) {
            processedFiles = done;
            double p = baseProgress + progressRange * ((double)processedFiles / (double)totalFiles);
            progress(p, [NSString stringWithFormat:@"Packaging %@/%@", zipPrefix, dir]);
        }];
        processed++;
    }

    // Package the individual files
    for (NSString *file in overrideFiles) {
        if ([self checkCancelledWithError:error]) return NO;
        NSString *filePath = [gameDirAbsolute stringByAppendingPathComponent:file];
        if ([fm fileExistsAtPath:filePath]) {
            NSData *data = [NSData dataWithContentsOfFile:filePath];
            if (data) {
                NSError *writeErr = nil;
                [archive writeData:data
                          filePath:[NSString stringWithFormat:@"%@/%@", zipPrefix, file]
                             error:&writeErr];
                if (writeErr) {
                    NSLog(@"[ModpackExport] Warning: failed to write %@/%@: %@", zipPrefix, file, writeErr.localizedDescription);
                }
            }
        }
        processedFiles++;
        double p = baseProgress + progressRange * ((double)processedFiles / (double)totalFiles);
        progress(p, [NSString stringWithFormat:@"Packaging %@/%@", zipPrefix, file]);
        processed++;
    }

    if (blockError) {
        if (error) *error = blockError;
        return NO;
    }
    return YES;
}

#pragma mark - Helper methods

- (void)addDirectoryToArchive:(UZKArchive *)archive
                      dirPath:(NSString *)dirPath
                  prefixInZip:(NSString *)prefixInZip
                     progress:(void (^_Nullable)(NSUInteger done, NSUInteger total))progress {
    NSFileManager *fileManager = [NSFileManager defaultManager];

    // Count the total files first
    NSUInteger total = 0;
    NSDirectoryEnumerator *counter = [fileManager enumeratorAtPath:dirPath];
    NSString *relPath;
    while ((relPath = [counter nextObject])) {
        NSString *fullPath = [dirPath stringByAppendingPathComponent:relPath];
        BOOL isDir = NO;
        if ([fileManager fileExistsAtPath:fullPath isDirectory:&isDir] && !isDir) {
            total++;
        }
    }
    if (total == 0) {
        if (progress) progress(0, 0);
        return;
    }

    NSDirectoryEnumerator *enumerator = [fileManager enumeratorAtPath:dirPath];
    NSUInteger done = 0;
    while ((relPath = [enumerator nextObject])) {
        // Cancellation checkpoint
        @synchronized(self) {
            if (self.cancelled) {
                if (progress) progress(done, total);
                return;
            }
        }

        NSString *fullPath = [dirPath stringByAppendingPathComponent:relPath];
        BOOL isDir = NO;
        if (![fileManager fileExistsAtPath:fullPath isDirectory:&isDir] || isDir) continue;

        NSData *data = [NSData dataWithContentsOfFile:fullPath];
        if (!data) continue;

        NSString *zipPath = [NSString stringWithFormat:@"%@/%@", prefixInZip, relPath];
        [archive writeData:data filePath:zipPath error:nil];
        done++;
        if (progress) progress(done, total);
    }
}

- (nullable NSString *)resolveAbsoluteGameDirForProfile:(NSString *)profileName {
    NSString *profile = profileName.length ? profileName : @"default";
    @try {
        NSDictionary *profiles = PLProfiles.current.profiles;
        NSDictionary *prof = profiles[profile];
        if (![prof isKindOfClass:[NSDictionary class]]) return nil;
        NSString *gameDir = prof[@"gameDir"];
        if (![gameDir isKindOfClass:[NSString class]] || gameDir.length == 0) return nil;
        if ([gameDir isEqualToString:@"."]) {
            const char *env = getenv("POJAV_GAME_DIR");
            return env ? [NSString stringWithUTF8String:env] : NSHomeDirectory();
        }
        if ([gameDir isAbsolutePath]) {
            return gameDir;
        }
        const char *env = getenv("POJAV_GAME_DIR");
        NSString *baseDir = env ? [NSString stringWithUTF8String:env] : NSHomeDirectory();
        NSString *cleanGameDir = [gameDir hasPrefix:@"./"] ? [gameDir substringFromIndex:2] : gameDir;
        return [baseDir stringByAppendingPathComponent:cleanGameDir];
    } @catch (NSException *ex) {
        return nil;
    }
}

- (nullable NSString *)sha1ForFileAtPath:(NSString *)path {
    NSFileHandle *handle = [NSFileHandle fileHandleForReadingAtPath:path];
    if (!handle) return nil;

    CC_SHA1_CTX ctx;
    CC_SHA1_Init(&ctx);

    static const NSUInteger bufferSize = 64 * 1024;  // 64KB
    NSData *chunk;
    while ((chunk = [handle readDataOfLength:bufferSize]) && chunk.length > 0) {
        CC_SHA1_Update(&ctx, chunk.bytes, (CC_LONG)chunk.length);
    }
    [handle closeFile];

    unsigned char digest[CC_SHA1_DIGEST_LENGTH];
    CC_SHA1_Final(digest, &ctx);

    NSMutableString *hex = [NSMutableString stringWithCapacity:CC_SHA1_DIGEST_LENGTH * 2];
    for (size_t i = 0; i < CC_SHA1_DIGEST_LENGTH; i++) {
        [hex appendFormat:@"%02x", digest[i]];
    }
    return [hex copy];
}

- (nullable NSString *)sha512ForFileAtPath:(NSString *)path {
    NSFileHandle *handle = [NSFileHandle fileHandleForReadingAtPath:path];
    if (!handle) return nil;

    CC_SHA512_CTX ctx;
    CC_SHA512_Init(&ctx);

    static const NSUInteger bufferSize = 64 * 1024;  // 64KB
    NSData *chunk;
    while ((chunk = [handle readDataOfLength:bufferSize]) && chunk.length > 0) {
        CC_SHA512_Update(&ctx, chunk.bytes, (CC_LONG)chunk.length);
    }
    [handle closeFile];

    unsigned char digest[CC_SHA512_DIGEST_LENGTH];
    CC_SHA512_Final(digest, &ctx);

    NSMutableString *hex = [NSMutableString stringWithCapacity:CC_SHA512_DIGEST_LENGTH * 2];
    for (size_t i = 0; i < CC_SHA512_DIGEST_LENGTH; i++) {
        [hex appendFormat:@"%02x", digest[i]];
    }
    return [hex copy];
}

+ (NSDictionary *)parseVersionId:(NSString *)versionId {
    if (versionId.length == 0) return @{};

    // fabric-loader-<loaderVer>-<mcVer>
    if ([versionId hasPrefix:@"fabric-loader-"]) {
        NSString *rest = [versionId substringFromIndex:@"fabric-loader-".length];
        NSArray *parts = [rest componentsSeparatedByString:@"-"];
        if (parts.count >= 2) {
            NSString *loaderVersion = parts[0];
            NSString *mcVersion = [[parts subarrayWithRange:NSMakeRange(1, parts.count - 1)] componentsJoinedByString:@"-"];
            return @{@"loader": @"fabric", @"loaderVersion": loaderVersion, @"minecraft": mcVersion};
        }
    }

    // quilt-loader-<loaderVer>-<mcVer>
    if ([versionId hasPrefix:@"quilt-loader-"]) {
        NSString *rest = [versionId substringFromIndex:@"quilt-loader-".length];
        NSArray *parts = [rest componentsSeparatedByString:@"-"];
        if (parts.count >= 2) {
            NSString *loaderVersion = parts[0];
            NSString *mcVersion = [[parts subarrayWithRange:NSMakeRange(1, parts.count - 1)] componentsJoinedByString:@"-"];
            return @{@"loader": @"quilt", @"loaderVersion": loaderVersion, @"minecraft": mcVersion};
        }
    }

    // <mcVer>-forge-<loaderVer>
    NSRange forgeRange = [versionId rangeOfString:@"-forge-"];
    if (forgeRange.location != NSNotFound) {
        NSString *mcVersion = [versionId substringToIndex:forgeRange.location];
        NSString *loaderVersion = [versionId substringFromIndex:forgeRange.location + forgeRange.length];
        return @{@"loader": @"forge", @"loaderVersion": loaderVersion, @"minecraft": mcVersion};
    }

    // <mcVer>-neoforge-<loaderVer>
    NSRange neoforgeRange = [versionId rangeOfString:@"-neoforge-"];
    if (neoforgeRange.location != NSNotFound) {
        NSString *mcVersion = [versionId substringToIndex:neoforgeRange.location];
        NSString *loaderVersion = [versionId substringFromIndex:neoforgeRange.location + neoforgeRange.length];
        return @{@"loader": @"neoforge", @"loaderVersion": loaderVersion, @"minecraft": mcVersion};
    }

    // A pure MC version (with no loader)
    return @{@"minecraft": versionId};
}

@end
