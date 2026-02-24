//
//  ModpackImportService.m
//  Amethyst
//
//  Modpack import service implementation
//

#import "ModpackImportService.h"
#import "installer/modpack/ModpackUtils.h"
#import "PLProfiles.h"
#import "UnzipKit.h"

static NSString * const kImportedModpacksKey = @"ImportedModpacks";
static NSString * const kModpacksDirectory = @"modpacks";

@interface ModpackImportService ()
@property (nonatomic, strong) NSString *modpacksDirectory;
@end

@implementation ModpackImportService

- (instancetype)init {
    self = [super init];
    if (self) {
        [self setupModpacksDirectory];
    }
    return self;
}

- (void)setupModpacksDirectory {
    NSString *documentsPath = [NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES) firstObject];
    self.modpacksDirectory = [documentsPath stringByAppendingPathComponent:kModpacksDirectory];
    
    // Create directory if it doesn't exist
    NSFileManager *fm = [NSFileManager defaultManager];
    if (![fm fileExistsAtPath:self.modpacksDirectory]) {
        NSError *error = nil;
        BOOL created = [fm createDirectoryAtPath:self.modpacksDirectory
                     withIntermediateDirectories:YES
                                      attributes:nil
                                           error:&error];
        if (!created) {
            NSLog(@"[ModpackImportService] Failed to create directory: %@", error);
        }
    }
}

#pragma mark - Parse Modpack

- (nullable NSDictionary *)parseModpackAtURL:(NSURL *)fileURL error:(NSError **)error {
    NSString *filePath = fileURL.path;
    NSString *fileExtension = fileURL.pathExtension.lowercaseString;
    
    NSFileManager *fm = [NSFileManager defaultManager];
    if (![fm fileExistsAtPath:filePath]) {
        if (error) {
            *error = [NSError errorWithDomain:@"ModpackImportError"
                                         code:1001
                                     userInfo:@{NSLocalizedDescriptionKey: @"文件不存在"}];
        }
        return nil;
    }
    
    // Open archive
    NSError *archiveError = nil;
    UZKArchive *archive = [[UZKArchive alloc] initWithPath:filePath error:&archiveError];
    if (archiveError || !archive) {
        if (error) {
            *error = [NSError errorWithDomain:@"ModpackImportError"
                                         code:1002
                                     userInfo:@{NSLocalizedDescriptionKey: @"无法打开压缩文件"}];
        }
        return nil;
    }
    
    // Try parsing modrinth.index.json (Modrinth format)
    NSData *indexData = [archive extractDataFromFile:@"modrinth.index.json" error:&archiveError];
    if (indexData) {
        return [self parseModrinthModpack:archive indexData:indexData filePath:filePath error:error];
    }
    
    // Try parsing manifest.json (CurseForge/Generic format)
    NSData *manifestData = [archive extractDataFromFile:@"manifest.json" error:&archiveError];
    if (manifestData) {
        return [self parseManifestModpack:archive manifestData:manifestData filePath:filePath error:error];
    }
    
    // Neither format found
    if (error) {
        *error = [NSError errorWithDomain:@"ModpackImportError"
                                     code:1003
                                 userInfo:@{NSLocalizedDescriptionKey: @"无效的整合包格式。缺少 modrinth.index.json 或 manifest.json"}];
    }
    return nil;
}

- (nullable NSDictionary *)parseModrinthModpack:(UZKArchive *)archive indexData:(NSData *)indexData filePath:(NSString *)filePath error:(NSError **)error {
    NSError *jsonError = nil;
    NSDictionary *indexDict = [NSJSONSerialization JSONObjectWithData:indexData options:0 error:&jsonError];
    
    if (jsonError || ![indexDict isKindOfClass:[NSDictionary class]]) {
        if (error) {
            *error = [NSError errorWithDomain:@"ModpackImportError"
                                         code:1004
                                     userInfo:@{NSLocalizedDescriptionKey: @"无法解析 modrinth.index.json"}];
        }
        return nil;
    }
    
    // Extract dependency info
    NSDictionary *dependencies = indexDict[@"dependencies"];
    NSString *minecraftVersion = dependencies[@"minecraft"];
    NSString *loader = nil;
    NSString *loaderVersion = nil;
    
    if (dependencies[@"forge"]) {
        loader = @"Forge";
        loaderVersion = dependencies[@"forge"];
    } else if (dependencies[@"fabric-loader"]) {
        loader = @"Fabric";
        loaderVersion = dependencies[@"fabric-loader"];
    } else if (dependencies[@"quilt-loader"]) {
        loader = @"Quilt";
        loaderVersion = dependencies[@"quilt-loader"];
    } else if (dependencies[@"neoforge"]) {
        loader = @"NeoForge";
        loaderVersion = dependencies[@"neoforge"];
    }
    
    // Get version info
    NSString *name = indexDict[@"name"] ?: @"未知整合包";
    NSString *version = indexDict[@"versionId"] ?: @"1.0.0";
    NSString *modpackId = [NSString stringWithFormat:@"modpack_%@", [[NSUUID UUID] UUIDString]];
    
    return @{
        @"id": modpackId,
        @"name": name,
        @"version": version,
        @"minecraftVersion": minecraftVersion ?: @"unknown",
        @"loader": loader ?: @"Unknown",
        @"loaderVersion": loaderVersion ?: @"",
        @"filePath": filePath,
        @"format": @"modrinth",
        @"indexData": indexDict,
        @"files": indexDict[@"files"] ?: @[]
    };
}

- (nullable NSDictionary *)parseManifestModpack:(UZKArchive *)archive manifestData:(NSData *)manifestData filePath:(NSString *)filePath error:(NSError **)error {
    NSError *jsonError = nil;
    NSDictionary *manifestDict = [NSJSONSerialization JSONObjectWithData:manifestData options:0 error:&jsonError];
    
    if (jsonError || ![manifestDict isKindOfClass:[NSDictionary class]]) {
        if (error) {
            *error = [NSError errorWithDomain:@"ModpackImportError"
                                         code:1005
                                     userInfo:@{NSLocalizedDescriptionKey: @"无法解析 manifest.json"}];
        }
        return nil;
    }
    
    // Extract Minecraft version
    NSDictionary *minecraft = manifestDict[@"minecraft"];
    NSString *minecraftVersion = minecraft[@"version"];
    
    // Extract mod loader info
    NSArray *modLoaders = minecraft[@"modLoaders"];
    NSString *loader = nil;
    NSString *loaderVersion = nil;
    
    if (modLoaders.count > 0) {
        NSDictionary *loaderInfo = modLoaders.firstObject;
        NSString *loaderId = loaderInfo[@"id"];
        
        if ([loaderId hasPrefix:@"forge-"]) {
            loader = @"Forge";
            loaderVersion = [loaderId substringFromIndex:6];
        } else if ([loaderId hasPrefix:@"fabric-"]) {
            loader = @"Fabric";
            loaderVersion = [loaderId substringFromIndex:7];
        } else if ([loaderId hasPrefix:@"quilt-"]) {
            loader = @"Quilt";
            loaderVersion = [loaderId substringFromIndex:6];
        }
    }
    
    NSString *name = manifestDict[@"name"] ?: @"未知整合包";
    NSString *version = manifestDict[@"version"] ?: @"1.0.0";
    NSString *modpackId = [NSString stringWithFormat:@"modpack_%@", [[NSUUID UUID] UUIDString]];
    
    return @{
        @"id": modpackId,
        @"name": name,
        @"version": version,
        @"minecraftVersion": minecraftVersion ?: @"unknown",
        @"loader": loader ?: @"Unknown",
        @"loaderVersion": loaderVersion ?: @"",
        @"filePath": filePath,
        @"format": @"curseforge",
        @"manifestData": manifestDict
    };
}

#pragma mark - Import Modpack

- (BOOL)importModpack:(NSDictionary *)modpackInfo error:(NSError **)error {
    NSString *filePath = modpackInfo[@"filePath"];
    NSString *format = modpackInfo[@"format"];
    
    NSFileManager *fm = [NSFileManager defaultManager];
    if (![fm fileExistsAtPath:filePath]) {
        if (error) {
            *error = [NSError errorWithDomain:@"ModpackImportError"
                                         code:2001
                                     userInfo:@{NSLocalizedDescriptionKey: @"整合包文件不存在"}];
        }
        return NO;
    }
    
    // Create unique directory for this modpack
    NSString *modpackId = modpackInfo[@"id"];
    NSString *modpackDir = [self.modpacksDirectory stringByAppendingPathComponent:modpackId];
    
    NSError *dirError = nil;
    if (![fm createDirectoryAtPath:modpackDir
       withIntermediateDirectories:YES
                        attributes:nil
                             error:&dirError]) {
        if (error) *error = dirError;
        return NO;
    }
    
    // Copy original file
    NSString *destFilePath = [modpackDir stringByAppendingPathComponent:[filePath lastPathComponent]];
    if ([fm fileExistsAtPath:destFilePath]) {
        [fm removeItemAtPath:destFilePath error:nil];
    }
    
    if (![fm copyItemAtPath:filePath toPath:destFilePath error:&dirError]) {
        // Cleanup on failure
        [fm removeItemAtPath:modpackDir error:nil];
        if (error) *error = dirError;
        return NO;
    }
    
    // Extract modpack
    NSError *extractError = nil;
    BOOL extractSuccess = [self extractModpack:destFilePath toDirectory:modpackDir format:format error:&extractError];
    
    if (!extractSuccess) {
        // Cleanup on failure
        [fm removeItemAtPath:modpackDir error:nil];
        if (error) *error = extractError;
        return NO;
    }
    
    // Create game profile
    NSString *profileName = [self createProfileForModpack:modpackInfo modpackDir:modpackDir error:error];
    if (!profileName) {
        [fm removeItemAtPath:modpackDir error:nil];
        return NO;
    }
    
    // Save to imported modpacks list
    NSMutableDictionary *savedModpack = [modpackInfo mutableCopy];
    savedModpack[@"modpackDir"] = modpackDir;
    savedModpack[@"profileName"] = profileName;
    savedModpack[@"importDate"] = [NSDate date];
    savedModpack[@"filePath"] = destFilePath;
    
    [self saveImportedModpack:savedModpack];
    
    return YES;
}

- (BOOL)extractModpack:(NSString *)filePath toDirectory:(NSString *)destDir format:(NSString *)format error:(NSError **)error {
    NSError *archiveError = nil;
    UZKArchive *archive = [[UZKArchive alloc] initWithPath:filePath error:&archiveError];
    
    if (archiveError || !archive) {
        if (error) {
            *error = [NSError errorWithDomain:@"ModpackImportError"
                                         code:3001
                                     userInfo:@{NSLocalizedDescriptionKey: @"无法打开整合包压缩文件"}];
        }
        return NO;
    }
    
    // Extract all files
    BOOL success = [archive extractFilesTo:destDir overwrite:YES error:&archiveError];
    
    if (!success || archiveError) {
        if (error) {
            *error = [NSError errorWithDomain:@"ModpackImportError"
                                         code:3002
                                     userInfo:@{NSLocalizedDescriptionKey: [NSString stringWithFormat:@"无法解压整合包: %@", archiveError.localizedDescription]}];
        }
        return NO;
    }
    
    return YES;
}

- (nullable NSString *)createProfileForModpack:(NSDictionary *)modpackInfo modpackDir:(NSString *)modpackDir error:(NSError **)error {
    NSString *name = modpackInfo[@"name"];
    NSString *minecraftVersion = modpackInfo[@"minecraftVersion"];
    NSString *loader = modpackInfo[@"loader"];
    NSString *loaderVersion = modpackInfo[@"loaderVersion"];
    
    // Generate unique profile name
    NSString *profileName = [NSString stringWithFormat:@"modpack_%@", [[NSUUID UUID] UUIDString]];
    
    // Determine version ID based on loader
    NSString *versionId = nil;
    
    if ([loader isEqualToString:@"Forge"]) {
        versionId = [NSString stringWithFormat:@"%@-forge-%@", minecraftVersion, loaderVersion];
    } else if ([loader isEqualToString:@"Fabric"]) {
        versionId = [NSString stringWithFormat:@"fabric-loader-%@-%@", loaderVersion, minecraftVersion];
    } else if ([loader isEqualToString:@"Quilt"]) {
        versionId = [NSString stringWithFormat:@"quilt-loader-%@-%@", loaderVersion, minecraftVersion];
    } else {
        versionId = minecraftVersion;
    }
    
    // Create game directory inside modpack folder
    NSString *gameDir = [modpackDir stringByAppendingPathComponent:@"minecraft"];
    NSFileManager *fm = [NSFileManager defaultManager];
    NSError *dirError = nil;
    
    if (![fm createDirectoryAtPath:gameDir
       withIntermediateDirectories:YES
                        attributes:nil
                             error:&dirError]) {
        if (error) *error = dirError;
        return nil;
    }
    
    // Create profile
    NSMutableDictionary *profile = [@{
        @"name": name,
        @"lastVersionId": versionId ?: @"",
        @"gameDir": gameDir,
        @"created": [NSDate date],
        @"type": @"modpack"
    } mutableCopy];
    
    // Add icon if available
    NSString *iconPath = [modpackDir stringByAppendingPathComponent:@"icon.png"];
    if ([fm fileExistsAtPath:iconPath]) {
        NSData *iconData = [NSData dataWithContentsOfFile:iconPath];
        if (iconData) {
            NSString *base64Icon = [iconData base64EncodedStringWithOptions:0];
            profile[@"icon"] = [NSString stringWithFormat:@"data:image/png;base64,%@", base64Icon];
        }
    }
    
    // Save profile
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
    NSString *modpackDir = modpackInfo[@"modpackDir"];
    NSString *profileName = modpackInfo[@"profileName"];
    NSFileManager *fm = [NSFileManager defaultManager];
    
    // Delete modpack directory
    if (modpackDir && [fm fileExistsAtPath:modpackDir]) {
        if (![fm removeItemAtPath:modpackDir error:error]) {
            return NO;
        }
    }
    
    // Delete profile
    if (profileName) {
        [PLProfiles.current.profiles removeObjectForKey:profileName];
        [PLProfiles.current save];
    }
    
    // Remove from saved list
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
