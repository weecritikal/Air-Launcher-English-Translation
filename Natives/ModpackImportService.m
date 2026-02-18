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
    if (![[NSFileManager defaultManager] fileExistsAtPath:self.modpacksDirectory]) {
        [[NSFileManager defaultManager] createDirectoryAtPath:self.modpacksDirectory
                                  withIntermediateDirectories:YES
                                                   attributes:nil
                                                        error:nil];
    }
}

#pragma mark - Parse Modpack

- (nullable NSDictionary *)parseModpackAtURL:(NSURL *)fileURL error:(NSError **)error {
    NSString *filePath = fileURL.path;
    NSString *fileExtension = fileURL.pathExtension.lowercaseString;
    
    if (![[NSFileManager defaultManager] fileExistsAtPath:filePath]) {
        if (error) {
            *error = [NSError errorWithDomain:@"ModpackImportError"
                                         code:1001
                                     userInfo:@{NSLocalizedDescriptionKey: @"File does not exist"}];
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
                                     userInfo:@{NSLocalizedDescriptionKey: @"Cannot open archive"}];
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
                                 userInfo:@{NSLocalizedDescriptionKey: @"Invalid modpack format. Missing modrinth.index.json or manifest.json"}];
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
                                     userInfo:@{NSLocalizedDescriptionKey: @"Cannot parse modrinth.index.json"}];
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
    NSString *name = indexDict[@"name"] ?: @"Unknown Modpack";
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
                                     userInfo:@{NSLocalizedDescriptionKey: @"Cannot parse manifest.json"}];
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
    
    NSString *name = manifestDict[@"name"] ?: @"Unknown Modpack";
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
    
    if (![[NSFileManager defaultManager] fileExistsAtPath:filePath]) {
        if (error) {
            *error = [NSError errorWithDomain:@"ModpackImportError"
                                         code:2001
                                     userInfo:@{NSLocalizedDescriptionKey: @"Modpack file does not exist"}];
        }
        return NO;
    }
    
    // Create unique directory for this modpack
    NSString *modpackId = modpackInfo[@"id"];
    NSString *modpackDir = [self.modpacksDirectory stringByAppendingPathComponent:modpackId];
    
    if (![[NSFileManager defaultManager] createDirectoryAtPath:modpackDir
                                   withIntermediateDirectories:YES
                                                    attributes:nil
                                                         error:error]) {
        return NO;
    }
    
    // Copy original file
    NSString *destFilePath = [modpackDir stringByAppendingPathComponent:[filePath lastPathComponent]];
    if (![[NSFileManager defaultManager] copyItemAtPath:filePath toPath:destFilePath error:error]) {
        return NO;
    }
    
    // Extract modpack
    NSError *extractError = nil;
    BOOL extractSuccess = [self extractModpack:destFilePath toDirectory:modpackDir format:format error:&extractError];
    
    if (!extractSuccess) {
        // Cleanup on failure
        [[NSFileManager defaultManager] removeItemAtPath:modpackDir error:nil];
        if (error) *error = extractError;
        return NO;
    }
    
    // Create game profile
    NSString *profileName = [self createProfileForModpack:modpackInfo modpackDir:modpackDir error:error];
    if (!profileName) {
        [[NSFileManager defaultManager] removeItemAtPath:modpackDir error:nil];
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
                                     userInfo:@{NSLocalizedDescriptionKey: @"Cannot open modpack archive"}];
        }
        return NO;
    }
    
    // Extract all files
    BOOL success = [archive extractFilesTo:destDir overwrite:YES error:&archiveError];
    
    if (!success || archiveError) {
        if (error) {
            *error = [NSError errorWithDomain:@"ModpackImportError"
                                         code:3002
                                     userInfo:@{NSLocalizedDescriptionKey: [NSString stringWithFormat:@"Cannot extract modpack: %@", archiveError.localizedDescription]}];
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
    [[NSFileManager defaultManager] createDirectoryAtPath:gameDir
                              withIntermediateDirectories:YES
                                               attributes:nil
                                                    error:nil];
    
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
    if ([[NSFileManager defaultManager] fileExistsAtPath:iconPath]) {
        NSData *iconData = [NSData dataWithContentsOfFile:iconPath];
        if (iconData) {
            NSString *base64Icon = [iconData base64EncodedStringWithOptions:0];
            profile[@"icon"] = [NSString stringWithFormat:@"data:image/png;base64,%@", base64Icon];
        }
    }
    
    // Save profile
    PLProfiles.current.profiles[profileName] = profile;
    [PLProfiles.current save];  // FIXED: was saveProfiles
    
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
    
    // Delete modpack directory
    if (modpackDir && [[NSFileManager defaultManager] fileExistsAtPath:modpackDir]) {
        if (![[NSFileManager defaultManager] removeItemAtPath:modpackDir error:error]) {
            return NO;
        }
    }
    
    // Delete profile
    if (profileName) {
        [PLProfiles.current.profiles removeObjectForKey:profileName];
        [PLProfiles.current save];  // FIXED: was saveProfiles
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
