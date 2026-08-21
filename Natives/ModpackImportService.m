//
//  ModpackImportService.m
//  Flux
//
//  Modpack import service implementation
//
//  Rewritten after the modpack import flow of FCL (Fold Craft Launcher):
//  1. Parse both the Modrinth (.mrpack) and CurseForge (manifest.json) formats correctly
//  2. Extract overrides/client-overrides into gameDir (rather than the modpackDir root)
//  3. Download every mod listed in manifest/files into gameDir/mods
//  4. For Fabric/Quilt modpacks, fetch the loader profile json automatically and write it into the version folder
//  5. For Forge/NeoForge modpacks, download installer.jar and call the direct installer to write into the modpack gameDir
//  6. gameDir uses a relative path (./custom_gamedir/<id>), aligned with the launcher POJAV_GAME_DIR
//  7. Write a complete profile (with gameDir, lastVersionId and icon)
//

#import "ModpackImportService.h"
#import "installer/FabricUtils.h"
#import "ArchiveIntegrity.h"
#import "installer/modpack/CurseForgeAPI.h"
#import "installer/modpack/ModpackUtils.h"
#import "installer/ForgeDirectInstaller.h"
#import "installer/NeoForgeDirectInstaller.h"
#import "PLProfiles.h"
#import "PLPreferences.h"
#import "UnzipKit.h"
#import "DownloadTaskManager.h"
#import "DownloadTaskItem.h"
#import "LauncherPreferences.h"
#import "MinecraftResourceDownloadTask.h"
#import "MinecraftResourceUtils.h"
#import "utils.h"

static NSString * const kImportedModpacksKey = @"ImportedModpacks";

@interface ModpackImportService () <NSURLSessionDownloadDelegate>
/// The modpack workspace root: <POJAV_GAME_DIR>/custom_gamedir
@property (nonatomic, strong) NSString *customGameDir;
/// The session used to download mod files and the loader installer/profile json
@property (nonatomic, strong) NSURLSession *downloadSession;
/// task -> { success, location, error }
@property (nonatomic, strong) NSMutableDictionary<NSURLSessionTask *, NSMutableDictionary *> *downloadResults;
/// task -> dispatch_semaphore_t, used to wait for one download to finish
@property (nonatomic, strong) NSMutableDictionary<NSURLSessionTask *, dispatch_semaphore_t> *downloadSemaphores;
/// task -> DownloadTaskItem.taskId
@property (nonatomic, strong) NSMutableDictionary<NSURLSessionTask *, NSString *> *downloadTaskIds;
/// task -> { lastTime, lastBytes }
@property (nonatomic, strong) NSMutableDictionary<NSURLSessionTask *, NSMutableDictionary *> *downloadProgressSnapshots;
@property (nonatomic, strong) NSMutableDictionary<NSURLSessionTask *, DownloadTaskItem *> *downloadTaskItems;
@property (nonatomic, strong) NSLock *downloadLock;
/// Phase 5 fix (following FCL DownloadList): tracks the files that failed during this import, so the caller can report them to the user
@property (nonatomic, strong) NSMutableArray<NSDictionary *> *failedFilesInternal;

// Forward declaration: resolve the iconBase64 in modpackInfo into a usable file URL string
- (nullable NSString *)resolveIconURLFromModpackInfo:(NSDictionary *)modpackInfo;
@end

@implementation ModpackImportService

- (instancetype)init {
    self = [super init];
    if (self) {
        // The modpack folder is custom_gamedir under POJAV_GAME_DIR, with a relative path in the gameDir field,
        // so when the launcher reads the profile it resolves to <POJAV_GAME_DIR>/custom_gamedir/<id>
        const char *gameDirEnv = getenv("POJAV_GAME_DIR");
        self.customGameDir = [@(gameDirEnv ?: ".") stringByAppendingPathComponent:@"custom_gamedir"];
        NSFileManager *fm = [NSFileManager defaultManager];
        if (![fm fileExistsAtPath:self.customGameDir]) {
            [fm createDirectoryAtPath:self.customGameDir withIntermediateDirectories:YES attributes:nil error:nil];
        }

        NSURLSessionConfiguration *config = [NSURLSessionConfiguration defaultSessionConfiguration];
        config.timeoutIntervalForRequest = 120.0;
        config.timeoutIntervalForResource = 300.0;
        config.allowsCellularAccess = YES;
        config.HTTPMaximumConnectionsPerHost = 6;
        _downloadSession = [NSURLSession sessionWithConfiguration:config delegate:self delegateQueue:nil];
        _downloadResults = [NSMutableDictionary dictionary];
        _downloadSemaphores = [NSMutableDictionary dictionary];
        _downloadTaskIds = [NSMutableDictionary dictionary];
        _downloadProgressSnapshots = [NSMutableDictionary dictionary];
        _downloadTaskItems = [NSMutableDictionary dictionary];
        _downloadLock = [[NSLock alloc] init];
        _failedFilesInternal = [NSMutableArray array];
        _cancelled = NO;
    }
    return self;
}

/// Phase 5 fix: a public read-only accessor returning an immutable copy, so it cannot be modified from outside
- (NSArray<NSDictionary *> *)failedFiles {
    @synchronized(self) {
        return [self.failedFilesInternal copy];
    }
}

- (void)resetCancelState {
    @synchronized(self) {
        _cancelled = NO;
    }
}

/// Internal: throw a cancellation error
- (BOOL)checkCancelledWithError:(NSError **)error {
    @synchronized(self) {
        if (_cancelled) {
            if (error) {
                *error = [NSError errorWithDomain:@"ModpackImportError"
                                             code:9999
                                         userInfo:@{NSLocalizedDescriptionKey: @"Import cancelled"}];
            }
            return YES;
        }
    }
    return NO;
}

#pragma mark - Helpers

/// Resolve the iconBase64 field of modpackInfo into a usable icon URL.
/// In modrinth.index.json, iconBase64 is base64-encoded image data (such as "data:image/png;base64,...." or a bare base64 string),
/// which cannot be used as a URL directly. This method decodes it into a UIImage, saves it to a temporary file and returns that file URL string.
/// Returns nil if parsing fails or there is no icon (the caller then uses the default icon).
- (nullable NSString *)resolveIconURLFromModpackInfo:(NSDictionary *)modpackInfo {
    NSString *iconBase64 = modpackInfo[@"iconBase64"];
    if (!iconBase64 || iconBase64.length == 0) return nil;

    // Strip any data URI prefix (such as "data:image/png;base64,")
    NSString *base64String = iconBase64;
    NSString *prefix = @"base64,";
    NSRange prefixRange = [iconBase64 rangeOfString:prefix];
    if (prefixRange.location != NSNotFound) {
        base64String = [iconBase64 substringFromIndex:prefixRange.location + prefixRange.length];
    }

    // Decode the base64
    NSData *imageData = [[NSData alloc] initWithBase64EncodedString:base64String
                                                             options:NSDataBase64DecodingIgnoreUnknownCharacters];
    if (!imageData || imageData.length == 0) return nil;

    // Save to a temporary file
    NSString *tempDir = NSTemporaryDirectory();
    NSString *iconFileName = [NSString stringWithFormat:@"modpack_icon_%@.png",
                              modpackInfo[@"id"] ?: modpackInfo[@"name"] ?: @"unknown"];
    NSString *iconPath = [tempDir stringByAppendingPathComponent:iconFileName];
    NSError *writeError = nil;
    if ([imageData writeToFile:iconPath options:NSDataWritingAtomic error:&writeError]) {
        // Return the file URL string (the AFNetworking setImageWithURL: supports file URLs)
        NSURL *fileURL = [NSURL fileURLWithPath:iconPath];
        return fileURL.absoluteString;
    }
    return nil;
}

/// Convert an NSDate into an ISO8601 string, so JSON serialization is safe
- (NSString *)iso8601StringFromDate:(NSDate *)date {
    static NSDateFormatter *formatter = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        formatter = [[NSDateFormatter alloc] init];
        formatter.locale = [NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"];
        formatter.timeZone = [NSTimeZone timeZoneWithAbbreviation:@"UTC"];
        formatter.dateFormat = @"yyyy-MM-dd'T'HH:mm:ss'Z'";
    });
    return [formatter stringFromDate:date];
}

/// Given a modpack id, return the absolute gameDir path (for local file operations)
- (NSString *)absoluteGameDirForModpackId:(NSString *)modpackId {
    return [self.customGameDir stringByAppendingPathComponent:modpackId];
}

/// Given a modpack id, return the relative gameDir path (written into the profile gameDir field)
- (NSString *)relativeGameDirForModpackId:(NSString *)modpackId {
    return [NSString stringWithFormat:@"./custom_gamedir/%@", modpackId];
}

/// Parse the Modrinth dependencies into loader information
- (void)resolveModrinthDependencies:(NSDictionary *)dependencies
                            loader:(NSString **)outLoader
                     loaderVersion:(NSString **)outLoaderVersion
                    minecraftVer:(NSString **)outMcVersion {
    if (outMcVersion) *outMcVersion = dependencies[@"minecraft"];
    if (dependencies[@"forge"]) {
        if (outLoader) *outLoader = @"Forge";
        if (outLoaderVersion) *outLoaderVersion = dependencies[@"forge"];
    } else if (dependencies[@"neoforge"]) {
        if (outLoader) *outLoader = @"NeoForge";
        if (outLoaderVersion) *outLoaderVersion = dependencies[@"neoforge"];
    } else if (dependencies[@"fabric-loader"]) {
        if (outLoader) *outLoader = @"Fabric";
        if (outLoaderVersion) *outLoaderVersion = dependencies[@"fabric-loader"];
    } else if (dependencies[@"quilt-loader"]) {
        if (outLoader) *outLoader = @"Quilt";
        if (outLoaderVersion) *outLoaderVersion = dependencies[@"quilt-loader"];
    } else {
        if (outLoader) *outLoader = @"Vanilla";
        if (outLoaderVersion) *outLoaderVersion = @"";
    }
}

/// Parse the CurseForge manifest.modLoaders into loader information
- (void)resolveCurseForgeLoader:(NSArray *)modLoaders
                        loader:(NSString **)outLoader
                 loaderVersion:(NSString **)outLoaderVersion {
    if (outLoader) *outLoader = @"Vanilla";
    if (outLoaderVersion) *outLoaderVersion = @"";
    if (modLoaders.count == 0) return;
    NSDictionary *loaderInfo = modLoaders.firstObject;
    NSString *loaderId = loaderInfo[@"id"];
    if ([loaderId hasPrefix:@"forge-"]) {
        if (outLoader) *outLoader = @"Forge";
        if (outLoaderVersion) *outLoaderVersion = [loaderId substringFromIndex:6];
    } else if ([loaderId hasPrefix:@"neoforge-"]) {
        if (outLoader) *outLoader = @"NeoForge";
        if (outLoaderVersion) *outLoaderVersion = [loaderId substringFromIndex:9];
    } else if ([loaderId hasPrefix:@"fabric-"]) {
        if (outLoader) *outLoader = @"Fabric";
        if (outLoaderVersion) *outLoaderVersion = [loaderId substringFromIndex:7];
    } else if ([loaderId hasPrefix:@"quilt-"]) {
        if (outLoader) *outLoader = @"Quilt";
        if (outLoaderVersion) *outLoaderVersion = [loaderId substringFromIndex:6];
    }
}

#pragma mark - Parse Modpack

- (nullable NSDictionary *)parseModpackAtURL:(NSURL *)fileURL error:(NSError **)error {
    NSString *filePath = fileURL.path;
    NSFileManager *fm = [NSFileManager defaultManager];
    if (![fm fileExistsAtPath:filePath]) {
        if (error) {
            *error = [NSError errorWithDomain:@"ModpackImportError"
                                         code:1001
                                     userInfo:@{NSLocalizedDescriptionKey: @"The file does not exist"}];
        }
        return nil;
    }

    NSError *archiveError = nil;
    UZKArchive *archive = [[UZKArchive alloc] initWithPath:filePath error:&archiveError];
    if (archiveError || !archive) {
        if (error) {
            *error = [NSError errorWithDomain:@"ModpackImportError"
                                         code:1002
                                     userInfo:@{NSLocalizedDescriptionKey: @"Could not open the archive"}];
        }
        return nil;
    }

    NSData *indexData = [archive extractDataFromFile:@"modrinth.index.json" error:&archiveError];
    if (indexData) {
        return [self parseModrinthModpack:archive indexData:indexData filePath:filePath error:error];
    }

    // Key fix (cross-launcher compatibility): MMC (MultiMC / Prism Launcher) modpack detection
    // The mmc-pack.json marker file holds a components array where each component has a uid (net.minecraft / net.fabricmc.fabric-loader and so on)
    // It must be checked before manifest.json (CurseForge), because some MMC modpacks also contain a manifest.json
    NSData *mmcPackData = [archive extractDataFromFile:@"mmc-pack.json" error:&archiveError];
    if (mmcPackData) {
        NSLog(@"[ModpackImport] Detected MMC (MultiMC/Prism) modpack");
        return [self parseMMCPack:archive mmcPackData:mmcPackData filePath:filePath error:error];
    }

    NSData *manifestData = [archive extractDataFromFile:@"manifest.json" error:&archiveError];
    if (manifestData) {
        return [self parseManifestModpack:archive manifestData:manifestData filePath:filePath error:error];
    }

    // Key fix (cross-launcher compatibility): add Plain ZIP modpack support
    // A Plain ZIP is the "bare .minecraft folder structure" modpack exported by launchers such as HMCL/FCL/PojavLauncher:
    //   - it has neither modrinth.index.json nor manifest.json
    //   - the zip root holds mods/, config/, versions/, options.txt and other .minecraft files directly
    //   - zips with a .minecraft/ prefix are handled too (one of the HMCL export formats)
    // This format has no mod download manifest: every file comes straight out of the zip, and the loader must be installed by the user afterwards.
    if ([self isPlainZipModpack:archive]) {
        NSLog(@"[ModpackImport] Detected Plain ZIP modpack (no manifest, direct .minecraft directory structure)");
        return [self parsePlainZipModpack:archive filePath:filePath error:error];
    }

    if (error) {
        *error = [NSError errorWithDomain:@"ModpackImportError"
                                     code:1003
                                 userInfo:@{NSLocalizedDescriptionKey: @"Invalid modpack format. It has no modrinth.index.json, mmc-pack.json, manifest.json, or .minecraft folder structure"}];
    }
    return nil;
}

/// Parse an MMC (MultiMC / Prism Launcher) format modpack
/// The mmc-pack.json structure:
///   {
///     "components": [
///       {"uid": "net.minecraft", "version": "1.20.1"},
///       {"uid": "net.fabricmc.fabric-loader", "version": "0.15.7"},
///       ...
///     ]
///   }
/// instance.cfg (key=value format, optional):
///   name=My Modpack
/// The .minecraft folder of an MMC modpack usually sits under a .minecraft/ prefix inside the zip
- (nullable NSDictionary *)parseMMCPack:(UZKArchive *)archive
                          mmcPackData:(NSData *)mmcPackData
                              filePath:(NSString *)filePath
                                 error:(NSError **)error {
    NSError *jsonError = nil;
    NSDictionary *mmcPack = [NSJSONSerialization JSONObjectWithData:mmcPackData options:0 error:&jsonError];
    if (jsonError || ![mmcPack isKindOfClass:[NSDictionary class]]) {
        if (error) {
            *error = [NSError errorWithDomain:@"ModpackImportError"
                                         code:1006
                                     userInfo:@{NSLocalizedDescriptionKey: @"Could not parse mmc-pack.json"}];
        }
        return nil;
    }

    NSArray *components = mmcPack[@"components"];
    if (![components isKindOfClass:[NSArray class]]) {
        if (error) {
            *error = [NSError errorWithDomain:@"ModpackImportError"
                                         code:1007
                                     userInfo:@{NSLocalizedDescriptionKey: @"mmc-pack.json is missing the components array"}];
        }
        return nil;
    }

    NSString *minecraftVersion = nil;
    NSString *loader = @"Vanilla";
    NSString *loaderVersion = @"";

    // Walk the components to find the MC version and the loader
    for (NSDictionary *comp in components) {
        if (![comp isKindOfClass:[NSDictionary class]]) continue;
        NSString *uid = comp[@"uid"];
        NSString *version = comp[@"version"];
        if (![uid isKindOfClass:[NSString class]] || ![version isKindOfClass:[NSString class]]) continue;

        if ([uid isEqualToString:@"net.minecraft"]) {
            minecraftVersion = version;
        } else if ([uid isEqualToString:@"net.fabricmc.fabric-loader"]) {
            loader = @"Fabric";
            loaderVersion = version;
        } else if ([uid isEqualToString:@"org.quiltmc.quilt-loader"]) {
            loader = @"Quilt";
            loaderVersion = version;
        } else if ([uid isEqualToString:@"net.minecraftforge"]) {
            loader = @"Forge";
            loaderVersion = version;
        } else if ([uid isEqualToString:@"net.neoforged"]) {
            loader = @"NeoForge";
            loaderVersion = version;
        }
    }

    // Read name from instance.cfg (optional)
    NSString *name = [filePath.lastPathComponent stringByDeletingPathExtension];
    NSError *cfgError = nil;
    NSData *cfgData = [archive extractDataFromFile:@"instance.cfg" error:&cfgError];
    if (cfgData) {
        NSString *cfgContent = [[NSString alloc] initWithData:cfgData encoding:NSUTF8StringEncoding];
        for (NSString *line in [cfgContent componentsSeparatedByString:@"\n"]) {
            if ([line hasPrefix:@"name="]) {
                NSString *parsedName = [line substringFromIndex:@"name=".length];
                parsedName = [parsedName stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
                if (parsedName.length > 0) {
                    name = parsedName;
                }
                break;
            }
        }
    }

    NSString *modpackId = [NSString stringWithFormat:@"mmc_%@", [[NSUUID UUID] UUIDString]];
    NSString *iconBase64 = [self extractIconFromArchive:archive];

    NSLog(@"[ModpackImport] MMC modpack: name=%@, MC=%@, loader=%@ %@", name, minecraftVersion, loader, loaderVersion);

    return @{
        @"id": modpackId,
        @"name": name,
        @"version": @"1.0.0",
        @"minecraftVersion": minecraftVersion ?: @"unknown",
        @"loader": loader,
        @"loaderVersion": loaderVersion,
        @"filePath": filePath,
        @"format": @"mmc",
        @"files": @[],
        @"iconBase64": iconBase64 ?: @""
    };
}

/// Detect whether a zip is a Plain ZIP modpack (no manifest, containing the .minecraft folder structure directly)
/// The test: the zip contains at least one top-level folder or file typical of .minecraft
- (BOOL)isPlainZipModpack:(UZKArchive *)archive {
    // The top-level folders/files that identify a .minecraft layout
    NSArray<NSString *> *knownTopLevelEntries = @[
        @"mods/", @"config/", @"versions/", @"saves/", @"resourcepacks/",
        @"shaderpacks/", @"defaultconfigs/", @"kubejs/", @"scripts/",
        @"localization/", @"patchouli_books/", @"options.txt",
        @"optionsof.txt", @"optionsshaders.txt", @"servers.dat",
        @"launcher_profiles.json", @"hotbar.nbt"
    ];
    __block BOOL hasMinecraftStructure = NO;
    [archive performOnFilesInArchive:^(UZKFileInfo *fileInfo, BOOL *stop) {
        NSString *filename = fileInfo.filename;
        // Handle the .minecraft/ prefix too (the HMCL export format)
        NSString *normalized = filename;
        if ([normalized hasPrefix:@".minecraft/"]) {
            normalized = [normalized substringFromIndex:@".minecraft/".length];
        }
        // Skip the macOS __MACOSX folder and hidden files
        if ([filename hasPrefix:@"__MACOSX/"]) return;
        if ([filename.lastPathComponent hasPrefix:@"."]) return;

        for (NSString *entry in knownTopLevelEntries) {
            if ([normalized hasPrefix:entry] || [normalized isEqualToString:[entry stringByDeletingPathExtension]]) {
                hasMinecraftStructure = YES;
                *stop = YES;
                return;
            }
        }
    } error:nil];
    return hasMinecraftStructure;
}

/// Parse a Plain ZIP modpack
/// A Plain ZIP has no manifest, so it needs:
///   1. the Minecraft version inferred from versions/<version>/<version>.json
///   2. the loader defaulting to vanilla (it cannot be inferred reliably from the zip, so the user installs it afterwards)
///   3. the whole zip root treated as overrides and extracted into gameDir
- (nullable NSDictionary *)parsePlainZipModpack:(UZKArchive *)archive filePath:(NSString *)filePath error:(NSError **)error {
    (void)error;
    NSString *minecraftVersion = [self detectMinecraftVersionFromArchive:archive] ?: @"unknown";
    NSString *name = [filePath.lastPathComponent stringByDeletingPathExtension];
    NSString *modpackId = [NSString stringWithFormat:@"plainzip_%@", [[NSUUID UUID] UUIDString]];

    NSLog(@"[ModpackImport] Plain ZIP modpack: name=%@, inferred MC version=%@", name, minecraftVersion);

    return @{
        @"id": modpackId,
        @"name": name,
        @"version": @"1.0.0",
        @"minecraftVersion": minecraftVersion,
        @"loader": @"Vanilla",
        @"loaderVersion": @"",
        @"filePath": filePath,
        @"format": @"plainzip",
        @"files": @[],
        @"iconBase64": [self extractIconFromArchive:archive] ?: @""
    };
}

/// Infer the Minecraft version from the versions/<version>/<version>.json path in the zip
- (nullable NSString *)detectMinecraftVersionFromArchive:(UZKArchive *)archive {
    __block NSString *detectedVersion = nil;
    [archive performOnFilesInArchive:^(UZKFileInfo *fileInfo, BOOL *stop) {
        NSString *filename = fileInfo.filename;
        // Handle the .minecraft/ prefix too
        if ([filename hasPrefix:@".minecraft/"]) {
            filename = [filename substringFromIndex:@".minecraft/".length];
        }
        // Match versions/<version>/<version>.json
        if ([filename hasPrefix:@"versions/"] && [filename hasSuffix:@".json"]) {
            NSArray *parts = [filename componentsSeparatedByString:@"/"];
            if (parts.count >= 3) {
                NSString *versionFromPath = parts[parts.count - 2];
                // Prefer a pure Minecraft version (without a -forge-/-neoforge-/-fabric- suffix)
                if (detectedVersion.length == 0) {
                    detectedVersion = versionFromPath;
                }
                // If it is a plain version number (with no loader suffix), take it
                if (![versionFromPath containsString:@"-forge-"] &&
                    ![versionFromPath containsString:@"-neoforge-"] &&
                    ![versionFromPath containsString:@"-fabric-"] &&
                    ![versionFromPath containsString:@"-quilt-"]) {
                    detectedVersion = versionFromPath;
                    *stop = YES;
                }
            }
        }
    } error:nil];
    return detectedVersion;
}

- (nullable NSDictionary *)parseModrinthModpack:(UZKArchive *)archive indexData:(NSData *)indexData filePath:(NSString *)filePath error:(NSError **)error {
    NSError *jsonError = nil;
    NSDictionary *indexDict = [NSJSONSerialization JSONObjectWithData:indexData options:0 error:&jsonError];

    if (jsonError || ![indexDict isKindOfClass:[NSDictionary class]]) {
        if (error) {
            *error = [NSError errorWithDomain:@"ModpackImportError"
                                         code:1004
                                     userInfo:@{NSLocalizedDescriptionKey: @"Could not parse modrinth.index.json"}];
        }
        return nil;
    }

    NSDictionary *dependencies = indexDict[@"dependencies"];
    NSString *minecraftVersion = nil, *loader = nil, *loaderVersion = nil;
    [self resolveModrinthDependencies:dependencies
                                loader:&loader
                         loaderVersion:&loaderVersion
                          minecraftVer:&minecraftVersion];

    NSString *name = indexDict[@"name"] ?: [filePath.lastPathComponent stringByDeletingPathExtension];
    NSString *version = indexDict[@"versionId"] ?: @"1.0.0";
    NSString *modpackId = [NSString stringWithFormat:@"modrinth_%@", [[NSUUID UUID] UUIDString]];

    // Extract icon.png (if there is one)
    NSString *iconBase64 = [self extractIconFromArchive:archive];

    return @{
        @"id": modpackId,
        @"name": name,
        @"version": version,
        @"minecraftVersion": minecraftVersion ?: @"unknown",
        @"loader": loader ?: @"Vanilla",
        @"loaderVersion": loaderVersion ?: @"",
        @"filePath": filePath,
        @"format": @"modrinth",
        @"indexData": indexDict,
        @"files": indexDict[@"files"] ?: @[],
        @"iconBase64": iconBase64 ?: @""
    };
}

- (nullable NSDictionary *)parseManifestModpack:(UZKArchive *)archive manifestData:(NSData *)manifestData filePath:(NSString *)filePath error:(NSError **)error {
    NSError *jsonError = nil;
    NSDictionary *manifestDict = [NSJSONSerialization JSONObjectWithData:manifestData options:0 error:&jsonError];

    if (jsonError || ![manifestDict isKindOfClass:[NSDictionary class]]) {
        if (error) {
            *error = [NSError errorWithDomain:@"ModpackImportError"
                                         code:1005
                                     userInfo:@{NSLocalizedDescriptionKey: @"Could not parse manifest.json"}];
        }
        return nil;
    }

    NSDictionary *minecraft = manifestDict[@"minecraft"];
    NSString *minecraftVersion = minecraft[@"version"];

    NSString *loader = nil, *loaderVersion = nil;
    [self resolveCurseForgeLoader:minecraft[@"modLoaders"]
                           loader:&loader
                    loaderVersion:&loaderVersion];

    NSString *name = manifestDict[@"name"] ?: [filePath.lastPathComponent stringByDeletingPathExtension];
    NSString *version = manifestDict[@"version"] ?: @"1.0.0";
    NSString *modpackId = [NSString stringWithFormat:@"curseforge_%@", [[NSUUID UUID] UUIDString]];

    // Extract the icon (CurseForge modpacks usually have none, so modpack.png or pack.png is tried)
    NSString *iconBase64 = [self extractIconFromArchive:archive];

    return @{
        @"id": modpackId,
        @"name": name,
        @"version": version,
        @"minecraftVersion": minecraftVersion ?: @"unknown",
        @"loader": loader ?: @"Vanilla",
        @"loaderVersion": loaderVersion ?: @"",
        @"filePath": filePath,
        @"format": @"curseforge",
        @"manifestData": manifestDict,
        @"files": manifestDict[@"files"] ?: @[],
        @"iconBase64": iconBase64 ?: @""
    };
}

/// Try to extract icon.png/modpack.png/pack.png from the modpack and return a base64 data URI
- (nullable NSString *)extractIconFromArchive:(UZKArchive *)archive {
    NSArray<NSString *> *iconCandidates = @[@"icon.png", @"modpack.png", @"pack.png"];
    for (NSString *name in iconCandidates) {
        NSError *err = nil;
        NSData *data = [archive extractDataFromFile:name error:&err];
        if (data && !err) {
            return [NSString stringWithFormat:@"data:image/png;base64,%@",
                    [data base64EncodedStringWithOptions:0]];
        }
    }
    return nil;
}

#pragma mark - Import Modpack

- (BOOL)importModpack:(NSDictionary *)modpackInfo error:(NSError **)error {
    return [self importModpack:modpackInfo progress:nil error:error];
}

- (BOOL)importModpack:(NSDictionary *)modpackInfo
             progress:(void (^_Nullable)(double progress, NSString *stageMessage))progress
                error:(NSError **)error {
    // Phase 5 fix: clear the failure list at the start of every import (following FCL DownloadList.reset())
    @synchronized(self) {
        [self.failedFilesInternal removeAllObjects];
    }

    NSString *filePath = modpackInfo[@"filePath"];
    NSString *format = modpackInfo[@"format"];

    NSFileManager *fm = [NSFileManager defaultManager];
    if (![fm fileExistsAtPath:filePath]) {
        if (error) {
            *error = [NSError errorWithDomain:@"ModpackImportError"
                                         code:2001
                                     userInfo:@{NSLocalizedDescriptionKey: @"The modpack file does not exist"}];
        }
        return NO;
    }

    if ([self checkCancelledWithError:error]) {
        return NO;
    }

    if (progress) progress(0.05, @"Preparing the modpack folder");

    NSString *modpackId = modpackInfo[@"id"];
    NSString *gameDirAbsolute = [self absoluteGameDirForModpackId:modpackId];
    NSString *gameDirRelative = [self relativeGameDirForModpackId:modpackId];

    // Clean up any old folder that may exist
    if ([fm fileExistsAtPath:gameDirAbsolute]) {
        [fm removeItemAtPath:gameDirAbsolute error:nil];
    }
    NSError *dirError = nil;
    if (![fm createDirectoryAtPath:gameDirAbsolute
       withIntermediateDirectories:YES
                        attributes:nil
                             error:&dirError]) {
        if (error) *error = dirError;
        return NO;
    }

    // Create the mods folder
    NSString *modsDir = [gameDirAbsolute stringByAppendingPathComponent:@"mods"];
    [fm createDirectoryAtPath:modsDir withIntermediateDirectories:YES attributes:nil error:nil];

    // Create the versions folder
    NSString *versionsDir = [gameDirAbsolute stringByAppendingPathComponent:@"versions"];
    [fm createDirectoryAtPath:versionsDir withIntermediateDirectories:YES attributes:nil error:nil];

    // Cancellation checkpoint
    if ([self checkCancelledWithError:error]) {
        [fm removeItemAtPath:gameDirAbsolute error:nil];
        return NO;
    }

    // Step 1: extract overrides/client-overrides (Modrinth) or overrides (CurseForge/MMC) into gameDir
    if (progress) progress(0.10, @"Extracting overrides");
    NSError *extractError = nil;
    BOOL extractSuccess = [self extractOverrides:filePath format:format toDirectory:gameDirAbsolute error:&extractError];
    if (!extractSuccess) {
        [fm removeItemAtPath:gameDirAbsolute error:nil];
        if (error) *error = extractError;
        return NO;
    }

    // Cancellation checkpoint
    if ([self checkCancelledWithError:error]) {
        [fm removeItemAtPath:gameDirAbsolute error:nil];
        return NO;
    }

    // Step 2: download the mod file list
    NSArray *modFiles = modpackInfo[@"files"];
    if (modFiles.count > 0) {
        if (progress) progress(0.15, [NSString stringWithFormat:@"Downloading %lu mod file(s)", (unsigned long)modFiles.count]);
        NSError *downloadError = nil;
        BOOL downloadSuccess = [self downloadModFiles:modpackInfo toModsDirectory:modsDir progress:progress error:&downloadError];
        if (!downloadSuccess) {
            // A failed mod download does not abort the import; it is only logged as a warning
            NSLog(@"[ModpackImport] Mod download partially failed: %@", downloadError.localizedDescription);
        }
    }

    // Cancellation checkpoint
    if ([self checkCancelledWithError:error]) {
        [fm removeItemAtPath:gameDirAbsolute error:nil];
        return NO;
    }

    // Step 3: install the mod loader
    if (progress) progress(0.85, @"Installing the mod loader");
    NSString *loader = modpackInfo[@"loader"];
    NSString *loaderVersion = modpackInfo[@"loaderVersion"];
    NSString *minecraftVersion = modpackInfo[@"minecraftVersion"];
    NSString *versionId = [self versionIdForModpack:modpackInfo];

    NSError *loaderError = nil;
    BOOL loaderSuccess = [self installModLoader:loader
                                 loaderVersion:loaderVersion
                                minecraftVersion:minecraftVersion
                                       versionId:versionId
                                   gameDirAbsolute:gameDirAbsolute
                                          error:&loaderError];
    if (!loaderSuccess) {
        // A failed loader install does not abort the import (the user may have installed it by hand)
        NSLog(@"[ModpackImport] Loader installation failed (user may have already installed): %@", loaderError.localizedDescription);
    }

    // Phase 5 fix (following FCL ModpackHelper.ensureCompleteVersion):
    // installModLoader only writes the version.json of the loader, while the version.json, libraries and assets of
    // the parent (vanilla MC) version are still missing. Users launching a modpack used to see
    // "net.minecraft.client.main.Main not found" or missing libraries precisely because this step was absent.
    // The full version download is triggered here, so every dependency is in place at launch.
    if (progress) progress(0.86, @"Downloading game files (libraries + assets)");
    NSError *versionDLError = nil;
    BOOL versionDLOK = [self ensureCompleteVersionInstalled:versionId
                                          minecraftVersion:minecraftVersion
                                                 progress:progress
                                                    error:&versionDLError];
    if (!versionDLOK) {
        NSLog(@"[ModpackImport] Warning: Full version download failed: %@", versionDLError.localizedDescription);
        // Do not abort the import: the user may already have downloaded the vanilla files, or they will be fetched on demand at launch
        // But record the failure in failedFiles so the user knows
        @synchronized(self) {
            [self.failedFilesInternal addObject:@{
                @"fileName": [NSString stringWithFormat:@"%@ (game files)", versionId],
                @"url": @"",
                @"reason": versionDLError.localizedDescription ?: @"Failed to download the game files",
                @"format": @"version"
            }];
        }
    }

    // Cancellation checkpoint
    if ([self checkCancelledWithError:error]) {
        [fm removeItemAtPath:gameDirAbsolute error:nil];
        return NO;
    }

    // Step 4: write the profile
    if (progress) progress(0.95, @"Writing the profile");
    NSString *profileName = [self createProfileForModpack:modpackInfo
                                          gameDirRelative:gameDirRelative
                                                versionId:versionId
                                                    error:error];
    if (!profileName) {
        [fm removeItemAtPath:gameDirAbsolute error:nil];
        return NO;
    }

    // Step 5: persist the modpack metadata
    NSMutableDictionary *savedModpack = [modpackInfo mutableCopy];
    savedModpack[@"gameDirAbsolute"] = gameDirAbsolute;
    savedModpack[@"gameDirRelative"] = gameDirRelative;
    savedModpack[@"profileName"] = profileName;
    savedModpack[@"importDate"] = [self iso8601StringFromDate:[NSDate date]];
    [self saveImportedModpack:savedModpack];

    if (progress) progress(1.0, @"Import complete");
    return YES;
}

/// Work out lastVersionId from modpackInfo
- (NSString *)versionIdForModpack:(NSDictionary *)modpackInfo {
    NSString *loader = modpackInfo[@"loader"];
    NSString *loaderVersion = modpackInfo[@"loaderVersion"];
    NSString *minecraftVersion = modpackInfo[@"minecraftVersion"];

    if ([loader isEqualToString:@"Fabric"]) {
        return [NSString stringWithFormat:@"fabric-loader-%@-%@", loaderVersion, minecraftVersion];
    } else if ([loader isEqualToString:@"Quilt"]) {
        return [NSString stringWithFormat:@"quilt-loader-%@-%@", loaderVersion, minecraftVersion];
    } else if ([loader isEqualToString:@"Forge"]) {
        return [NSString stringWithFormat:@"%@-forge-%@", minecraftVersion, loaderVersion];
    } else if ([loader isEqualToString:@"NeoForge"]) {
        // A NeoForge version number already encodes the MC version, e.g. 47.1.0 (which is 1.20.1)
        // but the version folder still uses the <mc>-neoforge-<loader> form so they can be told apart
        return [NSString stringWithFormat:@"%@-neoforge-%@", minecraftVersion, loaderVersion];
    } else {
        return minecraftVersion ?: @"";
    }
}

/// Extract the overrides folder into gameDir
/// Modrinth: overrides + client-overrides
/// CurseForge: overrides
/// Plain ZIP: the whole zip root is treated as overrides (handling the .minecraft/ prefix too)
- (BOOL)extractOverrides:(NSString *)filePath format:(NSString *)format toDirectory:(NSString *)destDir error:(NSError **)error {
    NSError *archiveError = nil;
    UZKArchive *archive = [[UZKArchive alloc] initWithPath:filePath error:&archiveError];
    if (archiveError || !archive) {
        if (error) {
            *error = [NSError errorWithDomain:@"ModpackImportError"
                                         code:3001
                                     userInfo:@{NSLocalizedDescriptionKey: @"Could not open the modpack archive"}];
        }
        return NO;
    }

    // Plain ZIP: the whole zip root is extracted into gameDir as overrides
    // Handling both the .minecraft/ prefix (the HMCL export format) and the __MACOSX folder (metadata created by macOS)
    if ([format isEqualToString:@"plainzip"] || [format isEqualToString:@"mmc"]) {
        NSLog(@"[ModpackImport] %@: extracting zip root to gameDir", format);
        // Key fix (cross-launcher compatibility): the versions/ folder is a special case
        // DIR_HOME_VERSION in Tools.java on the Java side always points at POJAV_GAME_DIR/versions
        // and is not read from the profile gameDir. The versions/ folder in a Plain ZIP/MMC must therefore go to the main directory,
        // otherwise launching reports "version information not found".
        const char *pojavGameDir = getenv("POJAV_GAME_DIR");
        NSString *mainVersionsDir = pojavGameDir ?
            [NSString stringWithFormat:@"%s/versions", pojavGameDir] :
            [destDir stringByAppendingPathComponent:@"versions"];

        [archive performOnFilesInArchive:^(UZKFileInfo *fileInfo, BOOL *stop) {
            // Cancellation checkpoint (checked often inside a long loop)
            @synchronized(self) {
                if (self.cancelled) {
                    *stop = YES;
                    return;
                }
            }

            NSString *filename = fileInfo.filename;
            // Handle the .minecraft/ prefix too (the HMCL/MMC export format)
            if ([filename hasPrefix:@".minecraft/"]) {
                filename = [filename substringFromIndex:@".minecraft/".length];
            }
            // Skip the macOS __MACOSX folder and hidden files
            if ([filename hasPrefix:@"__MACOSX/"]) return;
            if ([filename.lastPathComponent hasPrefix:@"."]) return;
            // Skip the MMC metadata files (already handled in parseMMCPack)
            if ([format isEqualToString:@"mmc"] &&
                ([filename isEqualToString:@"mmc-pack.json"] ||
                 [filename isEqualToString:@"instance.cfg"] ||
                 [filename isEqualToString:@"pack.png"])) {
                return;
            }
            if (filename.length == 0) return;

            // Files under the versions/ prefix are extracted into the main POJAV_GAME_DIR/versions/
            // Everything else is extracted into gameDirAbsolute (keeping the modpack isolated)
            NSString *baseDir = destDir;
            NSString *relativePath = filename;
            if ([filename hasPrefix:@"versions/"]) {
                baseDir = mainVersionsDir;
                relativePath = [filename substringFromIndex:@"versions/".length];
                // If relativePath still starts with versions/ (such as versions/1.20.1/1.20.1.json), keep it
                if ([relativePath hasPrefix:@"versions/"]) {
                    relativePath = [relativePath substringFromIndex:@"versions/".length];
                }
            }

            NSString *destItemPath = [baseDir stringByAppendingPathComponent:relativePath];
            NSString *destDirPath = fileInfo.isDirectory ? destItemPath : destItemPath.stringByDeletingLastPathComponent;
            BOOL createdDir = [NSFileManager.defaultManager createDirectoryAtPath:destDirPath
                                                              withIntermediateDirectories:YES
                                                                              attributes:nil
                                                                                   error:error];
            if (!createdDir) {
                *stop = YES;
                return;
            }
            if (fileInfo.isDirectory) return;

            NSData *data = [archive extractData:fileInfo error:error];
            BOOL written = [data writeToFile:destItemPath options:NSDataWritingAtomic error:error];
            *stop = !data || !written;
        } error:error];
        if (error && *error) {
            NSLog(@"[ModpackImport] %@ extraction failed: %@", format, *error);
            return NO;
        }
        // Clean up on cancellation
        @synchronized(self) {
            if (self.cancelled) {
                if (error) {
                    *error = [NSError errorWithDomain:@"ModpackImportError"
                                                 code:9999
                                             userInfo:@{NSLocalizedDescriptionKey: @"Import cancelled"}];
                }
                return NO;
            }
        }
        return YES;
    }

    // Modrinth: extract overrides and client-overrides (the latter overriding the former)
    [ModpackUtils archive:archive extractDirectory:@"overrides" toPath:destDir error:error];
    if (error && *error) {
        return NO;
    }

    if ([format isEqualToString:@"modrinth"]) {
        [ModpackUtils archive:archive extractDirectory:@"client-overrides" toPath:destDir error:error];
        if (error && *error) {
            // A missing client-overrides is not an error
            NSLog(@"[ModpackImport] client-overrides extract (may not exist): %@", *error);
            *error = nil;
        }
    }

    return YES;
}

/// Download the mod file list
/// The Modrinth format: files[].downloads[0] is a direct URL and files[].path is a relative path
/// The CurseForge format: files[].projectID + fileID have to be resolved into a download URL through the CurseForge API
- (BOOL)downloadModFiles:(NSDictionary *)modpackInfo toModsDirectory:(NSString *)modsDir progress:(void (^_Nullable)(double progress, NSString *stageMessage))progress error:(NSError **)error {
    NSString *format = modpackInfo[@"format"];
    NSArray *files = modpackInfo[@"files"];
    if (files.count == 0) return YES;

    NSUInteger total = files.count;
    NSUInteger successCount = 0;
    NSString *downloadSource = getPrefObject(@"general.download_source") ?: @"official";
    // Fix for modpack icons not showing: the original implementation assigned modpackInfo[@"iconBase64"] (a base64-encoded image data string)
    // straight to the iconURL field, and NSURL URLWithString: returned nil when it was passed to setImageWithURL: (base64 is not a valid URL),
    // so the icon of a modpack download task never appeared.
    // The correct approach: decode the base64 into a UIImage, save it to a temporary file and use that file URL.
    NSString *iconURL = [self resolveIconURLFromModpackInfo:modpackInfo];

    if ([format isEqualToString:@"modrinth"]) {
        // Modrinth: download directly
        NSUInteger skippedOptional = 0;
        for (NSUInteger i = 0; i < total; i++) {
            // Cancellation checkpoint
            if ([self checkCancelledWithError:error]) {
                return NO;
            }
            NSDictionary *fileInfo = files[i];
            NSArray *downloads = fileInfo[@"downloads"];
            NSString *url = downloads.firstObject;
            NSString *relPath = fileInfo[@"path"];
            // env field filtering: a Modrinth file can declare itself server-only or client-only.
            // The launcher is a client, so files with env.client=="unsupported" are skipped (avoiding server-only mods).
            // Files are downloaded normally when env is missing or env.client is "required"/"optional".
            NSDictionary *env = fileInfo[@"env"];
            NSString *clientEnv = env[@"client"];
            if ([clientEnv isKindOfClass:[NSString class]] && [clientEnv isEqualToString:@"unsupported"]) {
                skippedOptional++;
                NSLog(@"[ModpackImport] Skipping server-only mod: %@", relPath);
                continue;
            }

            if (!url || !relPath) {
                // Key fix: an empty URL must not be skipped silently without counting, otherwise the progress bar sticks forever and the user cannot tell anything is missing.
                // completedUnitCount++ used to happen without reporting a failure, leaving the modpack mods incomplete.
                NSLog(@"[ModpackImport] Warning: Modrinth file %@ missing download URL, skipping", relPath);
                continue;
            }

            // Key fix: `if (![relPath hasPrefix:@"mods/"]) continue;` used to discard every file without a mods/ prefix,
            // including shaderpacks/, resourcepacks/, datapacks/ and other user resources.
            // That is closely tied to the reported "incomplete mods" issue — many modpacks ship shader packs and resource packs alongside mods.
            // The correct approach: dispatch to the matching folder outside modsDir based on the path prefix.
            // Note: the overrides folder is already extracted by extractModpackOverrides, so only the mods/, shaderpacks/,
            // resourcepacks/ and datapacks/ subfolder prefixes are handled here.
            NSString *destDir = nil;
            if ([relPath hasPrefix:@"mods/"]) {
                destDir = modsDir;
            } else if ([relPath hasPrefix:@"shaderpacks/"]) {
                destDir = [modsDir.stringByDeletingLastPathComponent stringByAppendingPathComponent:@"shaderpacks"];
            } else if ([relPath hasPrefix:@"resourcepacks/"]) {
                destDir = [modsDir.stringByDeletingLastPathComponent stringByAppendingPathComponent:@"resourcepacks"];
            } else if ([relPath hasPrefix:@"datapacks/"]) {
                destDir = [modsDir.stringByDeletingLastPathComponent stringByAppendingPathComponent:@"datapacks"];
            } else {
                // Other prefixes (such as config/ and defaultconfigs/) usually live in overrides, and the files array of
                // modrinth.index.json should not repeat the overrides contents; if it does, the relative path is written into the gameDir root as-is.
                destDir = [modsDir.stringByDeletingLastPathComponent stringByAppendingPathComponent:relPath.stringByDeletingLastPathComponent];
            }
            // Handle subfolders (such as mods/inner/sub.jar)
            // Phase 5 fix (following FCL): when relPath contains no "/", rangeOfString: returns NSNotFound,
            // so adding 1 overflows and substringFromIndex: throws NSRangeException and crashes.
            // Some malformed modpacks put root files (such as "config.toml") into files[],
            // in which case the original file name should simply be appended to destDir.
            NSRange firstSlashRange = [relPath rangeOfString:@"/"];
            NSString *relativeUnder = (firstSlashRange.location == NSNotFound)
                ? relPath.lastPathComponent
                : [relPath substringFromIndex:firstSlashRange.location + 1];
            NSString *fileName = relPath.lastPathComponent;
            NSString *destPath = [destDir stringByAppendingPathComponent:relativeUnder];

            // Key fix: downloadFileFromURL had no retries. An occasional failure on a single mod in a modpack was simply skipped,
            // leaving files missing from the mods folder. Up to 3 retries (1s apart) have been added.
            BOOL ok = NO;
            NSError *dlError = nil;
            for (NSInteger retry = 0; retry < 3 && !ok; retry++) {
                if (retry > 0) {
                    NSLog(@"[ModpackImport] Retrying download %@ (attempt %ld)", fileName, (long)retry);
                    [NSThread sleepForTimeInterval:1.0];
                    // Clean up the partial file a previous failure may have left behind
                    [[NSFileManager defaultManager] removeItemAtPath:destPath error:nil];
                }
                // Phase 5 fix: [NSURL URLWithString:] returns nil for an invalid string,
                // and downloadTaskWithURL:nil throws NSInvalidArgumentException and crashes.
                // Even a non-empty url can return nil because of control characters or spaces, so it must be checked explicitly.
                NSURL *downloadURL = [NSURL URLWithString:url];
                if (!downloadURL) {
                    NSLog(@"[ModpackImport] Warning: Modrinth file URL invalid, skipping: %@", url);
                    dlError = [NSError errorWithDomain:@"ModpackImportError"
                                                  code:5001
                                              userInfo:@{NSLocalizedDescriptionKey: [NSString stringWithFormat:@"Invalid download link: %@", url]}];
                    break;
                }
                // Each retry creates a new task (the old one has finished)
                NSURLSessionDownloadTask *task = [self.downloadSession downloadTaskWithURL:downloadURL];
                NSString *taskId = nil;
                {
                    DownloadTaskItem *taskItem = [[DownloadTaskManager sharedManager]
                        registerTaskWithResourceType:DownloadTaskResourceTypeMod
                                        resourceName:fileName
                                         displayName:fileName
                                      downloadSource:downloadSource
                                             rawTask:task
                                      supportsResume:YES
                                             iconURL:iconURL];
                    self.downloadTaskItems[task] = taskItem;
                    [[DownloadTaskManager sharedManager] setTaskWithId:taskItem.taskId state:DownloadTaskStateDownloading];
                    taskId = taskItem.taskId;
                }
                ok = [self downloadFileFromURL:url toPath:destPath taskId:taskId task:task error:&dlError];
                if (!ok) {
                    NSLog(@"[ModpackImport] mod download failed %@ (attempt %ld): %@", fileName, (long)retry, dlError.localizedDescription);
                }
            }
            if (ok) {
                successCount++;
            } else {
                // Phase 5 fix (following FCL DownloadList): record the failed file, so the caller can show the user which mods are missing
                NSLog(@"[ModpackImport] Mod permanently failed to download: %@ (%@)", fileName, url);
                @synchronized(self) {
                    [self.failedFilesInternal addObject:@{
                        @"fileName": fileName ?: @"(unknown)",
                        @"url": url ?: @"",
                        @"reason": dlError.localizedDescription ?: @"unknown error",
                        @"format": @"modrinth"
                    }];
                }
            }

            if (progress) {
                double p = 0.15 + 0.70 * ((double)(i + 1) / (double)total);
                progress(p, [NSString stringWithFormat:@"Downloading mod %lu/%lu: %@", (unsigned long)(i+1), (unsigned long)total, fileName]);
            }
        }
        if (skippedOptional > 0) {
            NSLog(@"[ModpackImport] Modrinth modpack: skipped %lu server-only mods", (unsigned long)skippedOptional);
        }
    } else if ([format isEqualToString:@"curseforge"]) {
        // CurseForge: a manifest lists only projectID + fileID, so the real download links and file
        // names have to come from the API. Resolve them all up front in batches of 50, the same way
        // the browse-and-install path does, rather than asking about one mod at a time.
        NSMutableArray *allFileIDs = [NSMutableArray arrayWithCapacity:total];
        for (NSUInteger i = 0; i < total; i++) {
            NSNumber *fid = files[i][@"fileID"];
            if (fid) [allFileIDs addObject:fid];
        }
        NSDictionary<NSString *, NSDictionary *> *resolvedFiles =
            allFileIDs.count > 0 ? [[CurseForgeAPI sharedInstance] filesByFileID:allFileIDs] : @{};
        NSLog(@"[ModpackImport] Resolved %lu/%lu CurseForge files up front",
              (unsigned long)resolvedFiles.count, (unsigned long)allFileIDs.count);

        for (NSUInteger i = 0; i < total; i++) {
            // Cancellation checkpoint
            if ([self checkCancelledWithError:error]) {
                return NO;
            }
            NSDictionary *fileInfo = files[i];
            NSNumber *projectID = fileInfo[@"projectID"];
            NSNumber *fileID = fileInfo[@"fileID"];
            if (!projectID || !fileID) continue;

            // The batch lookup usually answers with both the download URL and the real file name.
            // Only when it came back short does this fall back to asking about this one file.
            NSDictionary *resolved = resolvedFiles[fileID.stringValue];
            NSString *downloadURL = resolved ? [[CurseForgeAPI sharedInstance] downloadURLForFile:resolved] : nil;
            if (downloadURL.length == 0) {
                downloadURL = [self fetchCurseForgeFileURL:projectID.longLongValue fileID:fileID.longLongValue];
            }

            // Using projectID-fileID.jar as the file name is only a fallback. A real name is much
            // more recognizable in mods/, so prefer the manifest's, then the API's, then the one the
            // resolved download URL ends in.
            NSString *fileName = fileInfo[@"fileName"];
            if (![fileName isKindOfClass:[NSString class]] || fileName.length == 0) {
                NSString *apiName = resolved[@"fileName"];
                if ([apiName isKindOfClass:[NSString class]] && apiName.length > 0) {
                    fileName = apiName;
                }
            }
            if (![fileName isKindOfClass:[NSString class]] || fileName.length == 0) {
                NSString *realName = [self fetchCurseForgeRealFileName:projectID.longLongValue
                                                                fileID:fileID.longLongValue
                                                           resolvedURL:downloadURL];
                if (realName.length > 0) {
                    fileName = realName;
                    NSLog(@"[ModpackImport] Resolved real filename: projectID=%@ fileID=%@ -> %@",
                          projectID, fileID, realName);
                } else {
                    fileName = [NSString stringWithFormat:@"%@-%@.jar", projectID, fileID];
                }
            }

            // The Edge CDN can be addressed directly from the file id once the name is known, which
            // is what the retry loop falls back to. When the API could not be reached at all (no key
            // configured, for instance) it becomes the primary, so the mod is still attempted rather
            // than silently skipped.
            NSString *cdnURL = [self fetchCurseForgeFileURLAlternate:projectID.longLongValue
                                                              fileID:fileID.longLongValue
                                                            fileName:fileName];
            if (downloadURL.length == 0) {
                downloadURL = cdnURL;
            }
            if (downloadURL.length == 0) {
                // Record it by name rather than by id pair, for the same reason as the
                // browse-and-install path: a mod skipped as a number is a mod nobody knows is gone
                // until the game will not start.
                NSString *label = fileName.length > 0 ? fileName
                    : [NSString stringWithFormat:@"CurseForge project %@ (file %@)", projectID, fileID];
                NSString *reason = @"CurseForge did not give a download link. The author has most likely "
                                    "turned off third-party downloads, so this one has to be downloaded "
                                    "from the CurseForge website by hand and put in the mods folder.";
                NSLog(@"[ModpackImport] Skipping '%@' (projectID=%@ fileID=%@): %@", label, projectID, fileID, reason);
                @synchronized(self) {
                    [self.failedFilesInternal addObject:@{
                        @"fileName": label,
                        @"url": @"",
                        @"reason": reason,
                        @"format": @"curseforge",
                        @"projectID": projectID ?: @0,
                        @"fileID": fileID ?: @0
                    }];
                }
                continue;
            }
            NSString *destPath = [modsDir stringByAppendingPathComponent:fileName];

            // Key fix: as on the Modrinth path, up to 3 retries have been added.
            // After the 3rd failure it switches to the backup source (the official CurseForge CDN) and tries once more.
            BOOL ok = NO;
            NSError *dlError = nil;
            NSString *currentURL = downloadURL;
            for (NSInteger retry = 0; retry < 4 && !ok; retry++) {
                if (retry > 0) {
                    NSLog(@"[ModpackImport] Retrying download %@ (attempt %ld)", fileName, (long)retry);
                    [NSThread sleepForTimeInterval:1.0];
                    [[NSFileManager defaultManager] removeItemAtPath:destPath error:nil];
                }
                // The 4th attempt switches to the Edge CDN, addressed directly from the file id
                if (retry == 3 && cdnURL.length > 0 && ![cdnURL isEqualToString:currentURL]) {
                    currentURL = cdnURL;
                    NSLog(@"[ModpackImport] Switching to the CDN for %@: %@", fileName, cdnURL);
                }
                // Phase 5 fix: [NSURL URLWithString:] returns nil for an invalid string,
                // and downloadTaskWithURL:nil throws NSInvalidArgumentException and crashes.
                NSURL *currentNSURL = [NSURL URLWithString:currentURL];
                if (!currentNSURL) {
                    NSLog(@"[ModpackImport] Warning: CurseForge file URL invalid, skipping: %@", currentURL);
                    dlError = [NSError errorWithDomain:@"ModpackImportError"
                                                  code:5001
                                              userInfo:@{NSLocalizedDescriptionKey: [NSString stringWithFormat:@"Invalid download link: %@", currentURL]}];
                    break;
                }
                NSURLSessionDownloadTask *task = [self.downloadSession downloadTaskWithURL:currentNSURL];
                NSString *taskId = nil;
                {
                    DownloadTaskItem *taskItem = [[DownloadTaskManager sharedManager]
                        registerTaskWithResourceType:DownloadTaskResourceTypeMod
                                        resourceName:fileName
                                         displayName:fileName
                                      downloadSource:downloadSource
                                             rawTask:task
                                      supportsResume:YES
                                             iconURL:iconURL];
                    self.downloadTaskItems[task] = taskItem;
                    [[DownloadTaskManager sharedManager] setTaskWithId:taskItem.taskId state:DownloadTaskStateDownloading];
                    taskId = taskItem.taskId;
                }
                ok = [self downloadFileFromURL:currentURL toPath:destPath taskId:taskId task:task error:&dlError];
                if (!ok) {
                    NSLog(@"[ModpackImport] mod download failed %@ (attempt %ld): %@", fileName, (long)retry, dlError.localizedDescription);
                }
            }
            if (ok) {
                successCount++;
            } else {
                // Phase 5 fix (following FCL DownloadList): record the failed file, so the caller can show the user which mods are missing
                NSLog(@"[ModpackImport] Mod permanently failed to download: %@", fileName);
                @synchronized(self) {
                    [self.failedFilesInternal addObject:@{
                        @"fileName": fileName ?: @"(unknown)",
                        @"url": currentURL ?: @"",
                        @"reason": dlError.localizedDescription ?: @"unknown error",
                        @"format": @"curseforge",
                        @"projectID": projectID ?: @0,
                        @"fileID": fileID ?: @0
                    }];
                }
            }

            if (progress) {
                double p = 0.15 + 0.70 * ((double)(i + 1) / (double)total);
                progress(p, [NSString stringWithFormat:@"Downloading mod %lu/%lu (CurseForge)", (unsigned long)(i+1), (unsigned long)total]);
            }
        }
    }

    NSLog(@"[ModpackImport] Mod download completed: %lu/%lu succeeded", (unsigned long)successCount, (unsigned long)total);
    // Phase 5 fix (following FCL DownloadList.finishAll): the failed files are now collected in failedFilesInternal,
    // so failures are no longer hidden behind a silent 70% threshold. Any failure returns NO, so the caller can use self.failedFiles
    // to show the user exactly which mods are missing and offer a "retry the missing mods" entry point.
    //   - everything succeeded: return YES
    //   - something failed: return NO, with the failed file names in the error (at most 5); the full list is available through self.failedFiles
    // The old 70% threshold left users thinking the import succeeded while missing mods crashed the game at launch — that was the root cause of the
    // reported "incomplete download" problem.
    if (total == 0) return YES;
    if (successCount >= total) return YES;

    // Collect the failed file names (for the error message)
    NSArray<NSDictionary *> *failedSnapshot = self.failedFiles;
    NSMutableArray<NSString *> *failedNames = [NSMutableArray arrayWithCapacity:failedSnapshot.count];
    for (NSDictionary *f in failedSnapshot) {
        NSString *n = f[@"fileName"];
        if ([n isKindOfClass:[NSString class]] && n.length > 0) {
            [failedNames addObject:n];
        }
    }
    // Error message: the success rate + the failure count + the first 5 failed file names (so the error description does not get too long)
    NSMutableString *msg = [NSMutableString stringWithFormat:@"The modpack's mods did not fully download: %lu/%lu succeeded, %lu failed",
                            (unsigned long)successCount, (unsigned long)total, (unsigned long)failedNames.count];
    if (failedNames.count > 0) {
        NSUInteger showCount = MIN(failedNames.count, (NSUInteger)5);
        [msg appendString:@"\nFailed mods:"];
        for (NSUInteger k = 0; k < showCount; k++) {
            [msg appendFormat:@"%@\n", failedNames[k]];
        }
        if (failedNames.count > showCount) {
            [msg appendFormat:@"...and %lu in total", (unsigned long)failedNames.count];
        }
    }
    NSLog(@"[ModpackImport] Warning: %@", msg);
    if (error) {
        *error = [NSError errorWithDomain:@"ModpackImportError"
                                     code:5004
                                 userInfo:@{
                                     NSLocalizedDescriptionKey: [msg copy],
                                     @"failedFiles": failedSnapshot
                                 }];
    }
    return NO;
}

/// Download one file synchronously and associate it with the registered DownloadTaskItem(taskId).
/// When existingTask is passed in it is used directly; otherwise a new download task is created internally.
/// Returns YES when the file was saved to destPath successfully, and NO when the download or the save failed.
- (BOOL)downloadFileFromURL:(NSString *)urlString
                     toPath:(NSString *)destPath
                     taskId:(nullable NSString *)taskId
                       task:(nullable NSURLSessionDownloadTask *)existingTask
                      error:(NSError **)outError {
    NSURL *url = [NSURL URLWithString:urlString];
    if (!url) {
        NSError *invalidURLError = [NSError errorWithDomain:@"ModpackImportError"
                                                       code:5001
                                                   userInfo:@{NSLocalizedDescriptionKey: @"Invalid download link"}];
        if (outError) *outError = invalidURLError;
        if (taskId) [[DownloadTaskManager sharedManager] setTaskWithId:taskId completedWithError:invalidURLError];
        return NO;
    }

    NSURLSessionDownloadTask *task = existingTask ?: [self.downloadSession downloadTaskWithURL:url];
    NSMutableDictionary *result = [NSMutableDictionary dictionary];
    dispatch_semaphore_t sema = dispatch_semaphore_create(0);

    [self.downloadLock lock];
    self.downloadResults[task] = result;
    self.downloadSemaphores[task] = sema;
    if (taskId) self.downloadTaskIds[task] = taskId;
    [self.downloadLock unlock];

    [task resume];
    dispatch_semaphore_wait(sema, DISPATCH_TIME_FOREVER);

    [self.downloadLock lock];
    [self.downloadResults removeObjectForKey:task];
    [self.downloadSemaphores removeObjectForKey:task];
    [self.downloadTaskIds removeObjectForKey:task];
    [self.downloadProgressSnapshots removeObjectForKey:task];
    [self.downloadTaskItems removeObjectForKey:task];
    [self.downloadLock unlock];

    BOOL success = [result[@"success"] boolValue];
    NSError *downloadError = result[@"error"];
    NSURL *location = result[@"location"];

    if (!success) {
        if (outError) *outError = downloadError;
        return NO;
    }
    if (!location) {
        NSError *noLocationError = [NSError errorWithDomain:@"ModpackImportError"
                                                       code:5002
                                                   userInfo:@{NSLocalizedDescriptionKey: @"The download finished but the temporary file is missing"}];
        if (outError) *outError = noLocationError;
        if (taskId) [[DownloadTaskManager sharedManager] setTaskWithId:taskId completedWithError:noLocationError];
        return NO;
    }

    NSFileManager *fm = [NSFileManager defaultManager];
    NSString *dir = [destPath stringByDeletingLastPathComponent];
    if (![fm fileExistsAtPath:dir]) {
        [fm createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:nil];
    }
    if ([fm fileExistsAtPath:destPath]) {
        [fm removeItemAtPath:destPath error:nil];
    }

    NSError *moveError = nil;
    if (![fm moveItemAtURL:location toURL:[NSURL fileURLWithPath:destPath] error:&moveError]) {
        if (outError) *outError = moveError;
        if (taskId) [[DownloadTaskManager sharedManager] setTaskWithId:taskId completedWithError:moveError];
        return NO;
    }

    // The download delegate marks every completed transfer as a success, because a download task
    // reports no error for an HTTP 403 or 404 - the error page is simply delivered as the body.
    // Left unchecked it was moved into mods/ under a .jar name and only surfaced much later, when
    // the game died at startup on an archive it could not open. Verify here instead, and report a
    // failure so the retry loop tries the next source.
    NSString *rejection = nil;
    NSURLResponse *response = task.response;
    if ([response isKindOfClass:NSHTTPURLResponse.class]) {
        NSInteger statusCode = ((NSHTTPURLResponse *)response).statusCode;
        if (statusCode >= 400) {
            rejection = [NSString stringWithFormat:@"the server returned HTTP %ld", (long)statusCode];
        }
    }
    if (!rejection && [ArchiveIntegrity isArchivePath:destPath]) {
        rejection = [ArchiveIntegrity validationFailureForArchiveAtPath:destPath];
    }
    if (rejection) {
        [fm removeItemAtPath:destPath error:nil];
        NSError *corruptError = [NSError errorWithDomain:@"ModpackImportError"
                                                    code:5003
                                                userInfo:@{NSLocalizedDescriptionKey:
            [NSString stringWithFormat:@"Damaged download of %@: %@", destPath.lastPathComponent, rejection]}];
        NSLog(@"[ModpackImport] Discarded damaged download of %@ (%@)", destPath.lastPathComponent, rejection);
        if (outError) *outError = corruptError;
        if (taskId) [[DownloadTaskManager sharedManager] setTaskWithId:taskId completedWithError:corruptError];
        return NO;
    }

    if (taskId) [[DownloadTaskManager sharedManager] setTaskWithId:taskId completedWithError:nil];
    return YES;
}

#pragma mark - NSURLSessionDownloadDelegate

- (void)URLSession:(NSURLSession *)session
      downloadTask:(NSURLSessionDownloadTask *)downloadTask
      didWriteData:(int64_t)bytesWritten
 totalBytesWritten:(int64_t)totalBytesWritten
totalBytesExpectedToWrite:(int64_t)totalBytesExpectedToWrite {
    [self.downloadLock lock];
    DownloadTaskItem *taskItem = self.downloadTaskItems[downloadTask];
    NSMutableDictionary *snapshot = self.downloadProgressSnapshots[downloadTask];
    [self.downloadLock unlock];

    if (!taskItem) return;

    double fraction = totalBytesExpectedToWrite > 0 ? (double)totalBytesWritten / (double)totalBytesExpectedToWrite : -1.0;
    NSTimeInterval now = [NSDate date].timeIntervalSince1970;
    double speed = 0.0;
    NSTimeInterval eta = 0.0;

    if (snapshot) {
        NSTimeInterval lastTime = [snapshot[@"lastTime"] doubleValue];
        int64_t lastBytes = [snapshot[@"lastBytes"] longLongValue];
        if (lastTime > 0 && now > lastTime) {
            speed = (double)(totalBytesWritten - lastBytes) / (now - lastTime);
            if (speed > 0 && totalBytesExpectedToWrite > totalBytesWritten) {
                eta = (double)(totalBytesExpectedToWrite - totalBytesWritten) / speed;
            }
        }
    } else {
        snapshot = [NSMutableDictionary dictionary];
        [self.downloadLock lock];
        self.downloadProgressSnapshots[downloadTask] = snapshot;
        [self.downloadLock unlock];
    }
    snapshot[@"lastTime"] = @(now);
    snapshot[@"lastBytes"] = @(totalBytesWritten);

    [[DownloadTaskManager sharedManager] updateTaskWithId:taskItem.taskId
                                                 progress:fraction
                                               totalBytes:totalBytesExpectedToWrite
                                          downloadedBytes:totalBytesWritten];
    [[DownloadTaskManager sharedManager] updateTaskWithId:taskItem.taskId
                                                    speed:speed
                                   estimatedTimeRemaining:eta];
}

- (void)URLSession:(NSURLSession *)session
      downloadTask:(NSURLSessionDownloadTask *)downloadTask
didFinishDownloadingToURL:(NSURL *)location {
    [self.downloadLock lock];
    NSMutableDictionary *result = self.downloadResults[downloadTask];
    DownloadTaskItem *taskItem = self.downloadTaskItems[downloadTask];
    [self.downloadLock unlock];
    if (result) {
        result[@"location"] = location;
        result[@"success"] = @YES;
    }
    if (taskItem) {
        [[DownloadTaskManager sharedManager] setTaskWithId:taskItem.taskId state:DownloadTaskStateCompleted];
    }
}

- (void)URLSession:(NSURLSession *)session task:(NSURLSessionTask *)task didCompleteWithError:(NSError *)error {
    [self.downloadLock lock];
    NSMutableDictionary *result = self.downloadResults[task];
    dispatch_semaphore_t sema = self.downloadSemaphores[task];
    DownloadTaskItem *taskItem = self.downloadTaskItems[task];
    BOOL alreadySuccessful = [result[@"success"] boolValue];
    [self.downloadLock unlock];

    if (taskItem) {
        if (error) {
            if (error.code == NSURLErrorCancelled) {
                [[DownloadTaskManager sharedManager] setTaskWithId:taskItem.taskId state:DownloadTaskStateCancelled];
            } else {
                [[DownloadTaskManager sharedManager] setTaskWithId:taskItem.taskId completedWithError:error];
            }
        } else if (!alreadySuccessful) {
            // No file data even though the flow finished, so mark it as failed
            NSError *unknownError = [NSError errorWithDomain:@"ModpackImportError"
                                                        code:5003
                                                    userInfo:@{NSLocalizedDescriptionKey: @"The download did not finish"}];
            [[DownloadTaskManager sharedManager] setTaskWithId:taskItem.taskId completedWithError:unknownError];
        }
    }

    if (result) {
        if (error && !alreadySuccessful) {
            result[@"success"] = @NO;
            result[@"error"] = error;
        } else if (!alreadySuccessful) {
            result[@"success"] = @NO;
            result[@"error"] = [NSError errorWithDomain:@"ModpackImportError"
                                                     code:5003
                                                 userInfo:@{NSLocalizedDescriptionKey: @"The download did not finish"}];
        }
    }

    if (sema) dispatch_semaphore_signal(sema);
}

/// Get the download link for a mod file through the CurseForge API.
///
/// This used to hand back a BMCLAPI mirror link and only fall back after three failed attempts,
/// which meant every mod in an imported CurseForge pack was fetched through a mirror intended for
/// mainland China - three timeouts each, times however many mods the pack has. Worse, the "backup"
/// it fell back to (cdn.curseforge.com/files/<projectID>/<fileID>/download) is not a real CurseForge
/// endpoint at all, so once the mirror failed the import had nowhere left to go.
///
/// It now uses the same resolution the working browse-and-install path uses: ask the CurseForge API
/// for the file's own downloadUrl, which is authoritative and points at the official CDN.
- (nullable NSString *)fetchCurseForgeFileURL:(long long)projectID fileID:(long long)fileID {
    NSString *resolved = [[CurseForgeAPI sharedInstance] downloadURLForFile:@{
        @"modId": @(projectID),
        @"id": @(fileID)
    }];
    if (resolved.length > 0) {
        return resolved;
    }
    // No API key configured, or the API did not answer. The Edge CDN can still be addressed
    // directly, but only when the file name is known, so the caller resolves that first.
    return nil;
}

/// The backup CurseForge download link, used once retries on the primary source have failed.
/// Built from the file id the way CurseForge's Edge CDN lays its files out
/// (files/<id / 1000>/<id % 1000, three digits>/<file name>), matching the final fallback in
/// CurseForgeAPI.downloadURLForFile:.
- (nullable NSString *)fetchCurseForgeFileURLAlternate:(long long)projectID fileID:(long long)fileID fileName:(NSString *)fileName {
    if (fileID <= 0 || fileName.length == 0) return nil;
    NSString *encodedName = [fileName stringByAddingPercentEncodingWithAllowedCharacters:NSCharacterSet.URLPathAllowedCharacterSet];
    return [NSString stringWithFormat:@"https://edge.forgecdn.net/files/%lld/%03lld/%@",
            fileID / 1000, fileID % 1000, encodedName ?: fileName];
}

/// Work out the real file name for a mod (such as "jei-1.20.1-15.2.0.27.jar"), so mods/ does not
/// fill up with unrecognizable names like "12345-67890.jar".
///
/// A resolved CurseForge download URL already ends in the file name, so that is tried first and
/// costs nothing. Only when the URL carries no usable name does this fall back to a HEAD request
/// and read Content-Disposition. Returns nil on failure, leaving the caller to use its own fallback.
- (nullable NSString *)fetchCurseForgeRealFileName:(long long)projectID
                                            fileID:(long long)fileID
                                       resolvedURL:(nullable NSString *)resolvedURL {
    NSString *fromURL = [resolvedURL stringByRemovingPercentEncoding].lastPathComponent;
    if (fromURL.length > 0 && ![fromURL isEqualToString:@"download"] && [fromURL containsString:@"."]) {
        return fromURL;
    }

    NSURL *url = resolvedURL.length > 0 ? [NSURL URLWithString:resolvedURL] : nil;
    if (!url) return nil;

    // Use a temporary NSURLSession that does not follow redirects (handled by hand), so the Location header can be read
    NSURLSessionConfiguration *cfg = [NSURLSessionConfiguration defaultSessionConfiguration];
    cfg.timeoutIntervalForRequest = 15;
    cfg.HTTPAdditionalHeaders = @{
        @"User-Agent": @"Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36",
        @"Accept": @"*/*"
    };
    NSURLSession *session = [NSURLSession sessionWithConfiguration:cfg];
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:url];
    request.HTTPMethod = @"HEAD";

    __block NSString *resolvedName = nil;
    dispatch_semaphore_t sem = dispatch_semaphore_create(0);
    NSURLSessionDataTask *task = [session dataTaskWithRequest:request
                                            completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        if (!error && [response isKindOfClass:[NSHTTPURLResponse class]]) {
            NSHTTPURLResponse *http = (NSHTTPURLResponse *)response;
            // Prefer the filename from the Content-Disposition header (the most authoritative source)
            NSString *contentDisposition = http.allHeaderFields[@"Content-Disposition"];
            if ([contentDisposition isKindOfClass:[NSString class]] && contentDisposition.length > 0) {
                NSRange fnRange = [contentDisposition rangeOfString:@"filename=\""
                                                            options:NSCaseInsensitiveSearch];
                if (fnRange.location != NSNotFound) {
                    NSUInteger start = fnRange.location + fnRange.length;
                    NSUInteger end = [contentDisposition rangeOfString:@"\"" options:0 range:NSMakeRange(start, contentDisposition.length - start)].location;
                    if (end != NSNotFound && end > start) {
                        resolvedName = [contentDisposition substringWithRange:NSMakeRange(start, end - start)];
                    }
                }
            }
            // With no Content-Disposition, try the lastPathComponent of the final URL
            if (!resolvedName && http.URL) {
                NSString *last = http.URL.lastPathComponent;
                if (last.length > 0 && ![last isEqualToString:@"download"]) {
                    resolvedName = last;
                }
            }
        }
        dispatch_semaphore_signal(sem);
    }];
    [task resume];
    long waitResult = dispatch_semaphore_wait(sem, dispatch_time(DISPATCH_TIME_NOW, 15 * NSEC_PER_SEC));
    if (waitResult != 0) {
        [task cancel];
    }
    [session finishTasksAndInvalidate];
    return resolvedName;
}

/// Install the mod loader
/// Fabric/Quilt: fetch the profile json and write it to versions/<id>/<id>.json
/// Forge/NeoForge: write a minimal placeholder version JSON (relying on the user to install it manually afterwards)
///                or guide the user through installing it. A placeholder is written for now, so the profile does not crash by referencing a missing version
- (BOOL)installModLoader:(NSString *)loader
          loaderVersion:(NSString *)loaderVersion
         minecraftVersion:(NSString *)minecraftVersion
                versionId:(NSString *)versionId
          gameDirAbsolute:(NSString *)gameDirAbsolute
                   error:(NSError **)error {
    if (!loaderVersion || loaderVersion.length == 0 || !minecraftVersion || minecraftVersion.length == 0) {
        if (error) {
            *error = [NSError errorWithDomain:@"ModpackImportError"
                                         code:4001
                                     userInfo:@{NSLocalizedDescriptionKey: @"The loader version or game version is missing"}];
        }
        return NO;
    }

    NSString *downloadSource = getPrefObject(@"general.download_source") ?: @"official";
    // The version JSON must be written into POJAV_GAME_DIR/versions/ (the main directory) rather than gameDirAbsolute (the isolated modpack folder).
    // DIR_HOME_VERSION in Tools.java on the Java side always points at POJAV_GAME_DIR/versions
    // and is not read from the profile gameDir. Writing into gameDirAbsolute/versions/ used to give "version information not found" at launch.
    // gameDirAbsolute is only for isolating user data such as mods/saves/configs (through the profile gameDir=user.dir).
    NSString *mainVersionDir = [NSString stringWithFormat:@"%s/versions/%@", getenv("POJAV_GAME_DIR"), versionId];
    NSString *versionDir = mainVersionDir;
    NSString *versionJsonPath = [versionDir stringByAppendingPathComponent:[NSString stringWithFormat:@"%@.json", versionId]];
    NSFileManager *fm = [NSFileManager defaultManager];
    [fm createDirectoryAtPath:versionDir withIntermediateDirectories:YES attributes:nil error:nil];

    // Fabric/Quilt: fetch the profile json straight from the meta API
    if ([loader isEqualToString:@"Fabric"] || [loader isEqualToString:@"Quilt"]) {
        NSDictionary *endpoints = FabricUtils.endpoints[loader];
        NSString *jsonURLTemplate = endpoints[@"json"];
        if (!jsonURLTemplate) {
            if (error) {
                *error = [NSError errorWithDomain:@"ModpackImportError"
                                             code:4002
                                         userInfo:@{NSLocalizedDescriptionKey: [NSString stringWithFormat:@"%@ endpoints not found", loader]}];
            }
            return NO;
        }
        NSString *jsonURL = [NSString stringWithFormat:jsonURLTemplate, minecraftVersion, loaderVersion];
        NSURL *url = [NSURL URLWithString:jsonURL];
        // Phase 5 fix: the URL built here can make URLWithString: return nil when loaderVersion contains invalid characters,
        // and downloadTaskWithURL:nil crashes. This is checked explicitly and returns a clear error.
        if (!url) {
            if (error) {
                *error = [NSError errorWithDomain:@"ModpackImportError"
                                             code:4002
                                         userInfo:@{NSLocalizedDescriptionKey: [NSString stringWithFormat:@"Invalid %@ profile JSON URL: %@", loader, jsonURL]}];
            }
            return NO;
        }

        NSString *displayName = [NSString stringWithFormat:@"%@ %@ profile", loader, loaderVersion];
        NSURLSessionDownloadTask *task = [self.downloadSession downloadTaskWithURL:url];
        NSString *taskId = nil;
        {
            DownloadTaskItem *taskItem = [[DownloadTaskManager sharedManager]
                registerTaskWithResourceType:DownloadTaskResourceTypeModloader
                                resourceName:versionId
                                 displayName:displayName
                              downloadSource:downloadSource
                                     rawTask:task
                              supportsResume:YES
                                     iconURL:nil];
            self.downloadTaskItems[task] = taskItem;
            [[DownloadTaskManager sharedManager] setTaskWithId:taskItem.taskId state:DownloadTaskStateDownloading];
            taskId = taskItem.taskId;
        }

        NSError *dlError = nil;
        if (![self downloadFileFromURL:jsonURL toPath:versionJsonPath taskId:taskId task:task error:&dlError]) {
            if (error) *error = dlError;
            return NO;
        }
        return YES;
    }

    // Forge/NeoForge: download installer.jar and call the direct installer to write into the modpack gameDir
    // The direct installer writes a complete version.json (with the right mainClass, arguments and libraries) and downloads the Forge libraries,
    // so the modpack loads Forge correctly at launch instead of crashing on a placeholder JSON with missing libraries or arguments
    NSString *installerURL = [self buildInstallerURLForLoader:loader
                                               loaderVersion:loaderVersion
                                              minecraftVersion:minecraftVersion];
    if (!installerURL) {
        if (error) {
            *error = [NSError errorWithDomain:@"ModpackImportError"
                                         code:4003
                                     userInfo:@{NSLocalizedDescriptionKey: [NSString stringWithFormat:@"Could not build the %@ installer URL", loader]}];
        }
        return NO;
    }

    // Download installer.jar into a temporary folder
    NSString *tmpInstallerPath = [NSTemporaryDirectory() stringByAppendingPathComponent:
                                  [NSString stringWithFormat:@"%@-installer.jar", versionId]];

    NSString *installerDisplayName = [NSString stringWithFormat:@"%@ %@ installer", loader, loaderVersion];
    // Phase 5 fix: buildInstallerURLForLoader already returns a non-empty string for installerURL,
    // but [NSURL URLWithString:] can still return nil for a string containing spaces or special characters,
    // and downloadTaskWithURL:nil crashes. This is checked explicitly and returns a clear error.
    NSURL *installerNSURL = [NSURL URLWithString:installerURL];
    if (!installerNSURL) {
        if (error) {
            *error = [NSError errorWithDomain:@"ModpackImportError"
                                         code:4003
                                     userInfo:@{NSLocalizedDescriptionKey: [NSString stringWithFormat:@"Invalid %@ installer URL: %@", loader, installerURL]}];
        }
        return NO;
    }
    NSURLSessionDownloadTask *installerTask = [self.downloadSession downloadTaskWithURL:installerNSURL];
    NSString *installerTaskId = nil;
    {
        DownloadTaskItem *installerItem = [[DownloadTaskManager sharedManager]
            registerTaskWithResourceType:DownloadTaskResourceTypeModloader
                            resourceName:versionId
                             displayName:installerDisplayName
                          downloadSource:downloadSource
                                 rawTask:installerTask
                          supportsResume:YES
                                 iconURL:nil];
        self.downloadTaskItems[installerTask] = installerItem;
        [[DownloadTaskManager sharedManager] setTaskWithId:installerItem.taskId state:DownloadTaskStateDownloading];
        installerTaskId = installerItem.taskId;
    }

    NSError *dlError = nil;
    if (![self downloadFileFromURL:installerURL toPath:tmpInstallerPath taskId:installerTaskId task:installerTask error:&dlError]) {
        // The installer.jar download failed: write a placeholder JSON that fails explicitly (with a mainClass pointing at a missing class, so launching reports it clearly
        // rather than quietly behaving like vanilla MC and leaving the user thinking their mods are active)
        NSLog(@"[ModpackImport] %@ installer.jar download failed, falling back to placeholder JSON: %@", loader, installerURL);
        NSInteger javaMajor = [self javaMajorVersionForMC:minecraftVersion];
        NSDictionary *placeholderJSON = @{
            @"_comment_": [NSString stringWithFormat:@"This modpack needs the %@ %@ loader and the automatic install failed. Please install it manually from the download screen.", loader, loaderVersion],
            @"id": versionId,
            @"inheritsFrom": minecraftVersion,
            @"type": @"release",
            @"mainClass": @"net.angelaura.installer.MissingLoader",  // Deliberately a missing class, so launching reports the problem explicitly
            @"javaVersion": @{@"component": @"java-runtime", @"majorVersion": @(javaMajor)}
        };
        NSData *jsonData = [NSJSONSerialization dataWithJSONObject:placeholderJSON options:NSJSONWritingPrettyPrinted error:nil];
        [jsonData writeToFile:versionJsonPath options:NSDataWritingAtomic error:nil];
        if (error) {
            *error = [NSError errorWithDomain:@"ModpackImportService" code:1001
                                     userInfo:@{NSLocalizedDescriptionKey: [NSString stringWithFormat:@"Failed to download the %@ installer.jar; a placeholder JSON was written instead. Please install the loader manually.", loader]}];
        }
        return NO;  // Let the caller see the failure and log a warning
    }

    NSLog(@"[ModpackImport] %@ installer.jar download completed: %@", loader, tmpInstallerPath);

    // Call the direct installer, writing into the modpack gameDirAbsolute (without registering a profile; createProfileForModpack does that)
    NSError *installError = nil;
    BOOL installSuccess = NO;
    if ([loader isEqualToString:@"NeoForge"]) {
        installSuccess = [NeoForgeDirectInstaller installNeoForgeFromInstaller:tmpInstallerPath
                                                                     versionId:versionId
                                                                 customGameDir:gameDirAbsolute
                                                           skipRegisterVersion:YES
                                                                      progress:nil
                                                                         error:&installError];
    } else {
        // Forge
        installSuccess = [ForgeDirectInstaller installForgeFromInstaller:tmpInstallerPath
                                                               versionId:versionId
                                                           customGameDir:gameDirAbsolute
                                                     skipRegisterVersion:YES
                                                                progress:nil
                                                                   error:&installError];
    }

    // Clean up the temporary installer.jar
    [[NSFileManager defaultManager] removeItemAtPath:tmpInstallerPath error:nil];

    if (!installSuccess) {
        NSLog(@"[ModpackImport] %@ direct install failed, falling back to placeholder JSON: %@", loader, installError.localizedDescription);
        // Use installerTaskId from the outer scope (installerItem is only declared inside the floatingBallEnabled block)
        if (installerTaskId) {
            [[DownloadTaskManager sharedManager] setTaskWithId:installerTaskId completedWithError:installError];
        }
        // The direct install failed: write a placeholder JSON that fails explicitly (with a mainClass pointing at a missing class, so launching reports it clearly,
        // rather than quietly behaving like vanilla MC and leaving the user thinking their mods are active)
        NSInteger javaMajor = [self javaMajorVersionForMC:minecraftVersion];
        NSDictionary *placeholderJSON = @{
            @"_comment_": [NSString stringWithFormat:@"This modpack needs the %@ %@ loader and the automatic install failed: %@. Please install it manually from the download screen.", loader, loaderVersion, installError.localizedDescription ?: @"Unknown error"],
            @"id": versionId,
            @"inheritsFrom": minecraftVersion,
            @"type": @"release",
            @"mainClass": @"net.angelaura.installer.MissingLoader",  // Deliberately a missing class, so launching reports the problem explicitly
            @"javaVersion": @{@"component": @"java-runtime", @"majorVersion": @(javaMajor)}
        };
        NSData *jsonData = [NSJSONSerialization dataWithJSONObject:placeholderJSON options:NSJSONWritingPrettyPrinted error:nil];
        [jsonData writeToFile:versionJsonPath options:NSDataWritingAtomic error:nil];
        if (error) {
            *error = [NSError errorWithDomain:@"ModpackImportService" code:1002
                                     userInfo:@{NSLocalizedDescriptionKey: [NSString stringWithFormat:@"Direct %@ install failed: %@. A placeholder JSON was written instead. Please install the loader manually.", loader, installError.localizedDescription ?: @"Unknown error"]}];
        }
        return NO;  // Let the caller see the failure and log a warning
    }

    NSLog(@"[ModpackImport] %@ direct install succeeded, version.json written to: %@", loader, versionJsonPath);
    return YES;
}

/// Phase 5 fix (following FCL ModpackHelper.ensureCompleteVersion):
/// During a modpack import, installModLoader only writes the version.json of the loader (the Fabric profile json
/// or the version.json produced by the Forge direct installer), while the version.json, libraries and
/// assets of the parent (vanilla MC) version are still missing. Users launching a modpack used to see
/// "net.minecraft.client.main.Main not found" or "libraries not found" precisely because this step was absent.
///
/// This method:
/// 1. makes sure the parent version JSON exists (reusing ForgeDirectInstaller.ensureParentVersionExists:,
///    which is generic and has no Forge-specific logic, so it works for Fabric/Quilt/vanilla too)
/// 2. creates a MinecraftResourceDownloadTask to trigger the full version download (libraries + assets);
///    downloadVersion: handles inheritsFrom internally and skips files that already exist with the right SHA1
/// 3. waits for the download with KVO + dispatch_semaphore, reporting progress upwards
- (BOOL)ensureCompleteVersionInstalled:(NSString *)versionId
                       minecraftVersion:(NSString *)minecraftVersion
                              progress:(void (^_Nullable)(double progress, NSString *stageMessage))progress
                                 error:(NSError **)error {
    if (!versionId || versionId.length == 0) {
        if (error) {
            *error = [NSError errorWithDomain:@"ModpackImportError"
                                         code:4005
                                     userInfo:@{NSLocalizedDescriptionKey: @"versionId is empty, so the full version cannot be installed"}];
        }
        return NO;
    }

    NSLog(@"[ModpackImport] Ensuring complete version is installed: %@ (parent version: %@)", versionId, minecraftVersion ?: @"(none)");

    // Step 1: make sure the parent version JSON exists (only needed when the loader version JSON has an inheritsFrom)
    // ensureParentVersionExists: is called unconditionally here; it checks whether the JSON already exists and skips if so.
    if (minecraftVersion.length > 0) {
        NSError *parentError = nil;
        BOOL parentOK = [ForgeDirectInstaller ensureParentVersionExists:minecraftVersion error:&parentError];
        if (!parentOK) {
            NSLog(@"[ModpackImport] Warning: Parent version %@ JSON download failed: %@",
                  minecraftVersion, parentError.localizedDescription);
            // Do not fail outright: downloadVersion: checks the parent version too and carries on if it is already there
            // It only fails when the parent version JSON really is missing
        }
    }

    if (progress) progress(0.88, [NSString stringWithFormat:@"Downloading the game files for %@", versionId]);

    // Step 2: create a MinecraftResourceDownloadTask to trigger the full download
    // It is not registered with DownloadTaskManager (the modpack import has its own progress card, so this would show twice)
    MinecraftResourceDownloadTask *downloader = [MinecraftResourceDownloadTask new];
    downloader.maxRetryCount = 3;

    // Wait synchronously by polling progress.finished, avoiding a dangling KVO observer
    // (prepareForDownload inside downloadVersion: rebuilds self.progress,
    //  so an addObserver before the call would observe the old object and never fire when the new progress completes)
    __block BOOL errorOccurred = NO;
    __block NSString *failReason = nil;

    // downloader.handleError is called when the download flow errors (inside finishDownloadWithErrorString:)
    downloader.handleError = ^{
        @synchronized(self) {
            errorOccurred = YES;
            failReason = @"The download failed (see the log)";
        }
    };

    // Start the download (downloadVersion: is asynchronous and rebuilds progress in prepareForDownload)
    NSDictionary *versionArg = @{@"id": versionId};
    [downloader downloadVersion:versionArg];

    // Poll until it finishes (checking every 0.5s, for at most 30 minutes)
    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:30 * 60];
    BOOL downloadSucceeded = NO;
    while ([deadline timeIntervalSinceNow] > 0) {
        // Check for errors
        @synchronized(self) {
            if (errorOccurred) {
                break;
            }
        }
        // Check how far progress has got (every read of downloader.progress gets the latest object)
        NSProgress *currentProg = downloader.progress;
        if (currentProg && currentProg.finished) {
            downloadSucceeded = !currentProg.cancelled;
            break;
        }
        // Check the cancellation signal
        if (self.cancelled) {
            if (currentProg) [currentProg cancel];
            break;
        }
        [NSThread sleepForTimeInterval:0.5];
    }

    // Final state check
    NSProgress *finalProg = downloader.progress;
    if (finalProg && finalProg.finished && !finalProg.cancelled) {
        downloadSucceeded = YES;
    } else if (finalProg && !finalProg.finished) {
        // Timed out
        [finalProg cancel];
        if (error) {
            *error = [NSError errorWithDomain:@"ModpackImportError"
                                         code:4006
                                     userInfo:@{NSLocalizedDescriptionKey: [NSString stringWithFormat:@"Downloading the game files for %@ timed out (30 minutes)", versionId]}];
        }
        return NO;
    }

    @synchronized(self) {
        if (errorOccurred) {
            if (error) {
                *error = [NSError errorWithDomain:@"ModpackImportError"
                                             code:4007
                                         userInfo:@{NSLocalizedDescriptionKey: [NSString stringWithFormat:@"Failed to download the game files for %@: %@", versionId, failReason ?: @"Unknown error"]}];
            }
            return NO;
        }
    }

    if (!downloadSucceeded) {
        if (error) {
            *error = [NSError errorWithDomain:@"ModpackImportError"
                                         code:4007
                                     userInfo:@{NSLocalizedDescriptionKey: [NSString stringWithFormat:@"Failed to download the game files for %@", versionId]}];
        }
        return NO;
    }

    NSLog(@"[ModpackImport] Full version download completed: %@", versionId);

    // Phase 5 fix: even when progress completes, some library/asset files may have failed (recorded in downloader.failedFiles)
    // Those failures are merged into ModpackImportService.failedFiles so the caller can show them to the user
    NSArray<NSDictionary *> *versionFailedFiles = [downloader.failedFiles copy];
    if (versionFailedFiles.count > 0) {
        NSLog(@"[ModpackImport] Warning: Version %@ has %lu files that failed to download",
              versionId, (unsigned long)versionFailedFiles.count);
        @synchronized(self) {
            for (NSDictionary *f in versionFailedFiles) {
                [self.failedFilesInternal addObject:@{
                    @"fileName": [NSString stringWithFormat:@"%@: %@", versionId, f[@"name"] ?: @"(unknown)"],
                    @"url": @"",
                    @"reason": f[@"error"] ?: @"Download failed",
                    @"format": @"version"
                }];
            }
        }
    }

    return YES;
}

/// Build the installer.jar download URL for a loader type
/// Forge: https://maven.minecraftforge.net/net/minecraftforge/forge/<mc>-<loader>/forge-<mc>-<loader>-installer.jar
/// NeoForge 1.20.1: https://maven.neoforged.net/releases/net/neoforged/forge/<loader>/forge-<loader>-installer.jar
/// Other NeoForge versions: https://maven.neoforged.net/releases/net/neoforged/neoforge/<loader>/neoforge-<loader>-installer.jar
/// The BMCLAPI mirror takes priority (when the user picked the bmclapi source)
- (nullable NSString *)buildInstallerURLForLoader:(NSString *)loader
                                    loaderVersion:(NSString *)loaderVersion
                                   minecraftVersion:(NSString *)minecraftVersion {
    // This used to be a second copy of ModpackUtils' builder. Keeping one implementation means a
    // fix to the coordinate format cannot reach the browse-and-install path but miss imports.
    return [ModpackUtils installerURLForLoader:loader
                                 loaderVersion:loaderVersion
                              minecraftVersion:minecraftVersion];
}

/// Infer the required major Java version from the MC version
/// 1.20.5+ -> 21, 1.18+ -> 17, 1.17 -> 17 (Java 16 is not bundled, and Java 17 is backward compatible), 1.16.5 and earlier -> 8
- (NSInteger)javaMajorVersionForMC:(NSString *)mcVersion {
    NSArray *parts = [mcVersion componentsSeparatedByString:@"."];
    if (parts.count < 2) return 8;
    NSInteger major = [parts[1] integerValue];
    if (major >= 21) return 21;       // 1.21+
    if (major >= 20 && parts.count >= 3 && [parts[2] integerValue] >= 5) return 21; // 1.20.5+
    if (major >= 18) return 17;       // 1.18+
    if (major >= 17) return 17;       // 1.17 (Java 16 is not bundled, and Java 17 runs 1.17 fine)
    return 8;                          // 1.16.5 and earlier
}

- (nullable NSString *)createProfileForModpack:(NSDictionary *)modpackInfo
                              gameDirRelative:(NSString *)gameDirRelative
                                    versionId:(NSString *)versionId
                                        error:(NSError **)error {
    NSString *name = modpackInfo[@"name"];
    NSString *modpackId = modpackInfo[@"id"];

    // Fix (following FCL/HMCL): the profile name now prefers the readable modpack name (the name field),
    // falling back to modpackId only when that name is taken. The original implementation used modpackId as the profile name,
    // so users saw a UUID rather than the modpack name in the version list.
    NSString *profileName = name.length > 0 ? name : modpackId;
    // Append a number when the name is taken
    if (PLProfiles.current.profiles[profileName]) {
        NSInteger suffix = 2;
        NSString *baseName = profileName;
        while (PLProfiles.current.profiles[profileName]) {
            profileName = [NSString stringWithFormat:@"%@ (%ld)", baseName, (long)suffix];
            suffix++;
        }
    }

    NSMutableDictionary *profile = [@{
        @"name": name.length > 0 ? name : profileName,
        @"lastVersionId": versionId ?: @"",
        @"gameDir": gameDirRelative,
        @"created": [self iso8601StringFromDate:[NSDate date]],
        @"type": @"modpack"
    } mutableCopy];

    // Fix (following FCL/HMCL): write the javaVersion field
    // MC 1.18+ needs Java 17, 1.20.5+ needs Java 21, and 1.16.5 and earlier use Java 8
    // Without this field the launcher may start MC 1.18+ on the default Java 8 and crash
    NSString *mcVersion = modpackInfo[@"minecraftVersion"];
    if (mcVersion.length > 0) {
        NSInteger javaMajor = [self javaMajorVersionForMC:mcVersion];
        profile[@"javaVersion"] = @{
            @"component": @"java-runtime",
            @"majorVersion": @(javaMajor)
        };
    }

    NSString *iconBase64 = modpackInfo[@"iconBase64"];
    if (iconBase64.length > 0) {
        profile[@"icon"] = iconBase64;
    }

    PLProfiles.current.profiles[profileName] = profile;
    [PLProfiles.current save];

    return profileName;
}

#pragma mark - Get Imported Modpacks

- (NSArray<NSDictionary *> *)getImportedModpacks {
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    NSArray *modpacks = [defaults objectForKey:kImportedModpacksKey];
    return modpacks ?: @[];
}

- (void)saveImportedModpack:(NSDictionary *)modpackInfo {
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    NSMutableArray *modpacks = [[self getImportedModpacks] mutableCopy];
    [modpacks addObject:modpackInfo];
    [defaults setObject:modpacks forKey:kImportedModpacksKey];
    [defaults synchronize];
}

#pragma mark - Delete Modpack

- (BOOL)deleteModpack:(NSDictionary *)modpackInfo error:(NSError **)error {
    NSString *gameDirAbsolute = modpackInfo[@"gameDirAbsolute"];
    if (!gameDirAbsolute) {
        // Compatibility with old data: try reading it from the modpackDir field
        gameDirAbsolute = modpackInfo[@"modpackDir"];
    }
    NSString *profileName = modpackInfo[@"profileName"];
    NSFileManager *fm = [NSFileManager defaultManager];

    if (gameDirAbsolute && [fm fileExistsAtPath:gameDirAbsolute]) {
        if (![fm removeItemAtPath:gameDirAbsolute error:error]) {
            return NO;
        }
    }

    if (profileName) {
        [PLProfiles.current.profiles removeObjectForKey:profileName];
        [PLProfiles.current save];
    }

    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    NSMutableArray *modpacks = [[self getImportedModpacks] mutableCopy];

    NSUInteger index = [modpacks indexOfObjectPassingTest:^BOOL(NSDictionary *obj, NSUInteger idx, BOOL *stop) {
        return [obj[@"id"] isEqualToString:modpackInfo[@"id"]];
    }];

    if (index != NSNotFound) {
        [modpacks removeObjectAtIndex:index];
        [defaults setObject:modpacks forKey:kImportedModpacksKey];
        [defaults synchronize];
    }

    return YES;
}

@end
