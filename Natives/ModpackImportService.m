//
//  ModpackImportService.m
//  Amethyst
//
//  整合包导入服务实现
//

#import "ModpackImportService.h"
#import "ModpackUtils.h"
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
    
    // 如果目录不存在则创建
    if (![[NSFileManager defaultManager] fileExistsAtPath:self.modpacksDirectory]) {
        [[NSFileManager defaultManager] createDirectoryAtPath:self.modpacksDirectory
                                  withIntermediateDirectories:YES
                                                   attributes:nil
                                                        error:nil];
    }
}

#pragma mark - 解析整合包

- (nullable NSDictionary *)parseModpackAtURL:(NSURL *)fileURL error:(NSError **)error {
    NSString *filePath = fileURL.path;
    NSString *fileExtension = fileURL.pathExtension.lowercaseString;
    
    if (![[NSFileManager defaultManager] fileExistsAtPath:filePath]) {
        if (error) {
            *error = [NSError errorWithDomain:@"ModpackImportError"
                                         code:1001
                                     userInfo:@{NSLocalizedDescriptionKey: @"文件不存在"}];
        }
        return nil;
    }
    
    // 打开压缩包
    NSError *archiveError = nil;
    UZKArchive *archive = [[UZKArchive alloc] initWithPath:filePath error:&archiveError];
    if (archiveError || !archive) {
        if (error) {
            *error = [NSError errorWithDomain:@"ModpackImportError"
                                         code:1002
                                     userInfo:@{NSLocalizedDescriptionKey: @"无法打开压缩包"}];
        }
        return nil;
    }
    
    // 尝试解析 modrinth.index.json (Modrinth 格式)
    NSData *indexData = [archive extractDataFromFile:@"modrinth.index.json" error:&archiveError];
    if (indexData) {
        return [self parseModrinthModpack:archive indexData:indexData filePath:filePath error:error];
    }
    
    // 尝试解析 manifest.json (CurseForge/通用格式)
    NSData *manifestData = [archive extractDataFromFile:@"manifest.json" error:&archiveError];
    if (manifestData) {
        return [self parseManifestModpack:archive manifestData:manifestData filePath:filePath error:error];
    }
    
    // 如果两种格式都没找到
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
    
    // 提取依赖信息
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
    
    // 获取版本信息
    NSString *name = indexDict[@"name"] ?: @"未知整合包";
    NSString *version = indexDict[@"versionId"] ?: @"1.0.0";
    NSString *modpackId = [NSString stringWithFormat:@"modpack_%@", [[NSUUID UUID] UUIDString]];
    
    return @{
        @"id": modpackId,
        @"name": name,
        @"version": version,
        @"minecraftVersion": minecraftVersion ?: @"unknown",
        @"loader": loader ?: @"未知",
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
    
    // 提取 Minecraft 版本
    NSDictionary *minecraft = manifestDict[@"minecraft"];
    NSString *minecraftVersion = minecraft[@"version"];
    
    // 提取模组加载器信息
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
        @"loader": loader ?: @"未知",
        @"loaderVersion": loaderVersion ?: @"",
        @"filePath": filePath,
        @"format": @"curseforge",
        @"manifestData": manifestDict
    };
}

#pragma mark - 导入整合包

- (BOOL)importModpack:(NSDictionary *)modpackInfo error:(NSError **)error {
    NSString *filePath = modpackInfo[@"filePath"];
    NSString *format = modpackInfo[@"format"];
    
    if (![[NSFileManager defaultManager] fileExistsAtPath:filePath]) {
        if (error) {
            *error = [NSError errorWithDomain:@"ModpackImportError"
                                         code:2001
                                     userInfo:@{NSLocalizedDescriptionKey: @"整合包文件不存在"}];
        }
        return NO;
    }
    
    // 为此整合包创建唯一目录
    NSString *modpackId = modpackInfo[@"id"];
    NSString *modpackDir = [self.modpacksDirectory stringByAppendingPathComponent:modpackId];
    
    if (![[NSFileManager defaultManager] createDirectoryAtPath:modpackDir
                                   withIntermediateDirectories:YES
                                                    attributes:nil
                                                         error:error]) {
        return NO;
    }
    
    // 复制原始文件
    NSString *destFilePath = [modpackDir stringByAppendingPathComponent:[filePath lastPathComponent]];
    if (![[NSFileManager defaultManager] copyItemAtPath:filePath toPath:destFilePath error:error]) {
        return NO;
    }
    
    // 解压整合包
    NSError *extractError = nil;
    BOOL extractSuccess = [self extractModpack:destFilePath toDirectory:modpackDir format:format error:&extractError];
    
    if (!extractSuccess) {
        // 失败时清理
        [[NSFileManager defaultManager] removeItemAtPath:modpackDir error:nil];
        if (error) *error = extractError;
        return NO;
    }
    
    // 创建游戏配置文件
    NSString *profileName = [self createProfileForModpack:modpackInfo modpackDir:modpackDir error:error];
    if (!profileName) {
        [[NSFileManager defaultManager] removeItemAtPath:modpackDir error:nil];
        return NO;
    }
    
    // 保存到已导入整合包列表
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
                                     userInfo:@{NSLocalizedDescriptionKey: @"无法打开整合包压缩包"}];
        }
        return NO;
    }
    
    // 解压所有文件
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
    
    // 生成唯一的配置文件名称
    NSString *profileName = [NSString stringWithFormat:@"modpack_%@", [[NSUUID UUID] UUIDString]];
    
    // 根据加载器确定版本 ID
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
    
    // 在整合包文件夹内创建游戏目录
    NSString *gameDir = [modpackDir stringByAppendingPathComponent:@"minecraft"];
    [[NSFileManager defaultManager] createDirectoryAtPath:gameDir
                              withIntermediateDirectories:YES
                                               attributes:nil
                                                    error:nil];
    
    // 创建配置文件
    NSMutableDictionary *profile = [@{
        @"name": name,
        @"lastVersionId": versionId ?: @"",
        @"gameDir": gameDir,
        @"created": [NSDate date],
        @"type": @"modpack"
    } mutableCopy];
    
    // 如果有图标则添加
    NSString *iconPath = [modpackDir stringByAppendingPathComponent:@"icon.png"];
    if ([[NSFileManager defaultManager] fileExistsAtPath:iconPath]) {
        NSData *iconData = [NSData dataWithContentsOfFile:iconPath];
        if (iconData) {
            NSString *base64Icon = [iconData base64EncodedStringWithOptions:0];
            profile[@"icon"] = [NSString stringWithFormat:@"data:image/png;base64,%@", base64Icon];
        }
    }
    
    // 保存配置文件
    PLProfiles.current.profiles[profileName] = profile;
    [PLProfiles.current saveProfiles];
    
    return profileName;
}

#pragma mark - 获取已导入的整合包

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

#pragma mark - 删除整合包

- (BOOL)deleteModpack:(NSDictionary *)modpackInfo error:(NSError **)error {
    NSString *modpackDir = modpackInfo[@"modpackDir"];
    NSString *profileName = modpackInfo[@"profileName"];
    
    // 删除整合包目录
    if (modpackDir && [[NSFileManager defaultManager] fileExistsAtPath:modpackDir]) {
        if (![[NSFileManager defaultManager] removeItemAtPath:modpackDir error:error]) {
            return NO;
        }
    }
    
    // 删除配置文件
    if (profileName) {
        [PLProfiles.current.profiles removeObjectForKey:profileName];
        [PLProfiles.current saveProfiles];
    }
    
    // 从保存的列表中移除
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
dpacks = [[self getImportedModpacks] mutableCopy];
    [modpacks addObject:modpackInfo];
    [defaults setObject:modpacks forKey:kImportedModpacksKey];
    [defaults synchronize];
}

#pragma mark - Delete Modpack

- (BOOL)deleteModpack:(NSDictionary *)modpackInfo error:(NSError **)error {
    NSString *modpackDir = modpackInfo[@"modpackDir"];
    NSString *profileName = modpackInfo[@"profileName"];
    
    // Remove modpack directory
    if (modpackDir && [[NSFileManager defaultManager] fileExistsAtPath:modpackDir]) {
        if (![[NSFileManager defaultManager] removeItemAtPath:modpackDir error:error]) {
            return NO;
        }
    }
    
    // Remove profile
    if (profileName) {
        [PLProfiles.current.profiles removeObjectForKey:profileName];
        [PLProfiles.current saveProfiles];
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
