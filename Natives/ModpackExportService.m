#import "ModpackExportService.h"
#import "PLProfiles.h"
#import "ModService.h"
#import "external/UnzipKit/UZKArchive.h"
#import <CommonCrypto/CommonCrypto.h>

@interface ModpackExportService ()
/// 解析 profile gameDir 为绝对路径（复用 ModService 的逻辑）
- (nullable NSString *)resolveAbsoluteGameDirForProfile:(NSString *)profileName;
/// 计算文件 sha1（分块读取，避免大文件内存压力）
- (nullable NSString *)sha1ForFileAtPath:(NSString *)path;
/// 计算文件 sha512（分块读取）
- (nullable NSString *)sha512ForFileAtPath:(NSString *)path;
/// 将目录递归写入 zip
- (void)addDirectoryToArchive:(UZKArchive *)archive
                      dirPath:(NSString *)dirPath
                  prefixInZip:(NSString *)prefixInZip
                     progress:(void (^_Nullable)(NSUInteger done))progress;
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

- (BOOL)exportModpackForProfile:(NSString *)profileName
                         toPath:(NSString *)destPath
                            name:(NSString *)name
                         version:(NSString *)version
                          author:(NSString *)author
                         format:(ModpackExportFormat)format
                includeOverrides:(BOOL)includeOverrides
                       progress:(void (^_Nullable)(double progress, NSString *stageMessage))progress
                          error:(NSError **)error {
    if (error) *error = nil;
    (void)author;  // 预留字段，CurseForge manifest 已硬编码作者

    void (^reportProgress)(double, NSString *) = ^(double p, NSString *msg) {
        NSLog(@"[ModpackExport] Progress: %.2f - %@", p, msg);
        if (progress) progress(p, msg);
    };

    reportProgress(0.0, @"开始导出整合包");

    // 1. 获取 profile 信息
    NSDictionary *profile = PLProfiles.current.profiles[profileName];
    if (![profile isKindOfClass:[NSDictionary class]]) {
        if (error) {
            *error = [NSError errorWithDomain:@"ModpackExportService" code:1
                                     userInfo:@{NSLocalizedDescriptionKey: @"找不到指定的 profile"}];
        }
        return NO;
    }

    NSString *lastVersionId = profile[@"lastVersionId"] ?: @"";
    NSString *gameDirAbsolute = [self resolveAbsoluteGameDirForProfile:profileName];
    if (gameDirAbsolute.length == 0) {
        // 回退到 POJAV_GAME_DIR
        const char *env = getenv("POJAV_GAME_DIR");
        gameDirAbsolute = env ? [NSString stringWithUTF8String:env] : NSHomeDirectory();
    }

    // 2. 解析 loader 和 mc 版本
    NSDictionary *versionInfo = [ModpackExportService parseVersionId:lastVersionId];
    NSString *mcVersion = versionInfo[@"minecraft"] ?: @"";
    NSString *loader = versionInfo[@"loader"] ?: @"";
    NSString *loaderVersion = versionInfo[@"loaderVersion"] ?: @"";

    NSLog(@"[ModpackExport] Profile=%@, mcVersion=%@, loader=%@ %@, gameDir=%@",
          profileName, mcVersion, loader, loaderVersion, gameDirAbsolute);

    if (mcVersion.length == 0) {
        if (error) {
            *error = [NSError errorWithDomain:@"ModpackExportService" code:2
                                     userInfo:@{NSLocalizedDescriptionKey: @"无法解析 Minecraft 版本（lastVersionId 格式无法识别）"}];
        }
        return NO;
    }

    // 3. 收集 mods 文件列表
    reportProgress(0.1, @"正在扫描 mods 文件");
    NSFileManager *fm = [NSFileManager defaultManager];
    NSString *modsDir = [gameDirAbsolute stringByAppendingPathComponent:@"mods"];
    NSMutableArray<NSDictionary *> *modFiles = [NSMutableArray new];
    if ([fm fileExistsAtPath:modsDir]) {
        NSArray *entries = [fm contentsOfDirectoryAtPath:modsDir error:nil];
        for (NSString *entry in entries) {
            // 只包含 .jar 文件（不包含 .disabled）
            if (![entry hasSuffix:@".jar"]) continue;
            NSString *fullPath = [modsDir stringByAppendingPathComponent:entry];
            NSDictionary *attrs = [fm attributesOfItemAtPath:fullPath error:nil];
            unsigned long long fileSize = [attrs fileSize];
            NSString *sha1 = [self sha1ForFileAtPath:fullPath];
            [modFiles addObject:@{
                @"path": [NSString stringWithFormat:@"mods/%@", entry],
                @"fullPath": fullPath,
                @"fileName": entry,
                @"sha1": sha1 ?: @"",
                @"fileSize": @(fileSize)
            }];
        }
    }
    NSLog(@"[ModpackExport] 找到 %lu 个 mod 文件", (unsigned long)modFiles.count);

    // 4. 根据格式导出
    switch (format) {
        case ModpackExportFormatModrinth:
            return [self exportModrinthFormat:modFiles
                                      toPath:destPath
                                         name:name
                                      version:version
                                    mcVersion:mcVersion
                                       loader:loader
                                loaderVersion:loaderVersion
                                gameDirAbsolute:gameDirAbsolute
                                includeOverrides:includeOverrides
                                      progress:reportProgress
                                         error:error];
        case ModpackExportFormatCurseForge:
            return [self exportCurseForgeFormat:modFiles
                                         toPath:destPath
                                            name:name
                                         version:version
                                       mcVersion:mcVersion
                                          loader:loader
                                    loaderVersion:loaderVersion
                                gameDirAbsolute:gameDirAbsolute
                                includeOverrides:includeOverrides
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

#pragma mark - Modrinth 格式导出

- (BOOL)exportModrinthFormat:(NSArray<NSDictionary *> *)modFiles
                      toPath:(NSString *)destPath
                        name:(NSString *)name
                     version:(NSString *)version
                   mcVersion:(NSString *)mcVersion
                      loader:(NSString *)loader
              loaderVersion:(NSString *)loaderVersion
            gameDirAbsolute:(NSString *)gameDirAbsolute
            includeOverrides:(BOOL)includeOverrides
                    progress:(void (^)(double, NSString *))progress
                       error:(NSError **)error {
    progress(0.2, @"正在生成 modrinth.index.json");
    NSFileManager *fm = [NSFileManager defaultManager];

    // 构造 dependencies
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

    // 构造 files 列表
    NSMutableArray *files = [NSMutableArray new];
    for (NSDictionary *modFile in modFiles) {
        NSString *sha512 = [self sha512ForFileAtPath:modFile[@"fullPath"]];
        [files addObject:@{
            @"path": modFile[@"path"],
            @"hashes": @{
                @"sha1": modFile[@"sha1"],
                @"sha512": sha512 ?: @""
            },
            @"downloads": @[],  // 不填下载链接，导入时走 overrides 还原
            @"fileSize": modFile[@"fileSize"]
        }];
    }

    // 构造 modrinth.index.json
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
                                     userInfo:@{NSLocalizedDescriptionKey: @"生成 modrinth.index.json 失败"}];
        }
        return NO;
    }

    progress(0.3, @"正在创建 zip 文件");
    // 删除已存在的目标文件，避免 UZKArchive 读取到旧的 zip 头
    [fm removeItemAtPath:destPath error:nil];

    NSError *archiveError = nil;
    UZKArchive *archive = [[UZKArchive alloc] initWithPath:destPath error:&archiveError];
    if (!archive || archiveError) {
        if (error) *error = archiveError;
        return NO;
    }

    // 写入 modrinth.index.json
    progress(0.4, @"正在写入 modrinth.index.json");
    if (![archive writeData:indexData filePath:@"modrinth.index.json" error:&archiveError]) {
        if (error) *error = archiveError;
        return NO;
    }

    // 写入 overrides（mods + config + options.txt 等）
    if (includeOverrides) {
        progress(0.5, @"正在打包 overrides");
        NSArray *overrideDirs = @[@"mods", @"config", @"defaultconfigs", @"resourcepacks", @"shaderpacks"];
        NSArray *overrideFiles = @[@"options.txt", @"optionsshaders.txt", @"servers.dat"];

        NSUInteger totalItems = modFiles.count + overrideDirs.count + overrideFiles.count;
        __block NSUInteger processed = 0;

        for (NSString *dir in overrideDirs) {
            NSString *dirPath = [gameDirAbsolute stringByAppendingPathComponent:dir];
            if (![fm fileExistsAtPath:dirPath]) {
                processed++;
                continue;
            }
            [self addDirectoryToArchive:archive
                                dirPath:dirPath
                            prefixInZip:[NSString stringWithFormat:@"overrides/%@", dir]
                               progress:^(NSUInteger done) {
                processed++;
                progress(0.5 + 0.4 * ((double)processed / (double)totalItems),
                         [NSString stringWithFormat:@"正在打包 overrides/%@", dir]);
            }];
        }

        for (NSString *file in overrideFiles) {
            NSString *filePath = [gameDirAbsolute stringByAppendingPathComponent:file];
            if ([fm fileExistsAtPath:filePath]) {
                NSData *data = [NSData dataWithContentsOfFile:filePath];
                if (data) {
                    [archive writeData:data
                              filePath:[NSString stringWithFormat:@"overrides/%@", file]
                                 error:nil];
                }
            }
            processed++;
        }
    }

    progress(0.95, @"正在完成导出");
    // UZKArchive 在 dealloc 时会关闭，但显式释放更安全
    archive = nil;

    progress(1.0, @"导出完成");
    NSLog(@"[ModpackExport] Modrinth 格式导出完成: %@", destPath);
    return YES;
}

#pragma mark - CurseForge 格式导出

- (BOOL)exportCurseForgeFormat:(NSArray<NSDictionary *> *)modFiles
                        toPath:(NSString *)destPath
                           name:(NSString *)name
                        version:(NSString *)version
                      mcVersion:(NSString *)mcVersion
                         loader:(NSString *)loader
                 loaderVersion:(NSString *)loaderVersion
               gameDirAbsolute:(NSString *)gameDirAbsolute
               includeOverrides:(BOOL)includeOverrides
                       progress:(void (^)(double, NSString *))progress
                          error:(NSError **)error {
    progress(0.2, @"正在生成 manifest.json");
    NSFileManager *fm = [NSFileManager defaultManager];

    // 构造 modLoaders
    NSMutableArray *modLoaders = [NSMutableArray new];
    if (loader.length > 0 && loaderVersion.length > 0) {
        // CurseForge 标准的 loader id：fabric/quilt/forge/neoforge
        NSString *loaderId = [NSString stringWithFormat:@"%@-%@", loader, loaderVersion];
        [modLoaders addObject:@{@"id": loaderId, @"primary": @YES}];
    }

    // 构造 manifest.json
    // 注意：CurseForge 格式需要 projectID/fileID，本地 mod 无法获取。
    // 简化方案：files 为空，所有 mod 打进 overrides/mods/
    NSDictionary *manifest = @{
        @"minecraft": @{
            @"version": mcVersion,
            @"modLoaders": modLoaders
        },
        @"manifestType": @"minecraftModpack",
        @"manifestVersion": @(1),
        @"name": name.length > 0 ? name : @"Exported Modpack",
        @"version": version.length > 0 ? version : @"1.0",
        @"author": @"Amethyst Export",
        @"files": @[],
        @"overrides": @"overrides"
    };

    NSData *manifestData = [NSJSONSerialization dataWithJSONObject:manifest options:NSJSONWritingPrettyPrinted error:error];
    if (!manifestData) {
        if (error && !*error) {
            *error = [NSError errorWithDomain:@"ModpackExportService" code:4
                                     userInfo:@{NSLocalizedDescriptionKey: @"生成 manifest.json 失败"}];
        }
        return NO;
    }

    progress(0.3, @"正在创建 zip 文件");
    [fm removeItemAtPath:destPath error:nil];

    NSError *archiveError = nil;
    UZKArchive *archive = [[UZKArchive alloc] initWithPath:destPath error:&archiveError];
    if (!archive || archiveError) {
        if (error) *error = archiveError;
        return NO;
    }

    progress(0.4, @"正在写入 manifest.json");
    if (![archive writeData:manifestData filePath:@"manifest.json" error:&archiveError]) {
        if (error) *error = archiveError;
        return NO;
    }

    if (includeOverrides) {
        progress(0.5, @"正在打包 overrides");
        NSArray *overrideDirs = @[@"mods", @"config", @"defaultconfigs", @"resourcepacks", @"shaderpacks"];
        NSArray *overrideFiles = @[@"options.txt", @"optionsshaders.txt", @"servers.dat"];
        NSUInteger totalItems = overrideDirs.count + overrideFiles.count;
        __block NSUInteger processed = 0;

        for (NSString *dir in overrideDirs) {
            NSString *dirPath = [gameDirAbsolute stringByAppendingPathComponent:dir];
            if (![fm fileExistsAtPath:dirPath]) {
                processed++;
                continue;
            }
            [self addDirectoryToArchive:archive
                                dirPath:dirPath
                            prefixInZip:[NSString stringWithFormat:@"overrides/%@", dir]
                               progress:^(NSUInteger done) {
                processed++;
                progress(0.5 + 0.4 * ((double)processed / (double)totalItems),
                         [NSString stringWithFormat:@"正在打包 overrides/%@", dir]);
            }];
        }

        for (NSString *file in overrideFiles) {
            NSString *filePath = [gameDirAbsolute stringByAppendingPathComponent:file];
            if ([fm fileExistsAtPath:filePath]) {
                NSData *data = [NSData dataWithContentsOfFile:filePath];
                if (data) {
                    [archive writeData:data
                              filePath:[NSString stringWithFormat:@"overrides/%@", file]
                                 error:nil];
                }
            }
            processed++;
        }
    }

    progress(0.95, @"正在完成导出");
    archive = nil;

    progress(1.0, @"导出完成");
    NSLog(@"[ModpackExport] CurseForge 格式导出完成: %@", destPath);
    return YES;
}

#pragma mark - 链接列表格式导出（FCL 支持的简单格式）

- (BOOL)exportLinkListFormat:(NSArray<NSDictionary *> *)modFiles
                      toPath:(NSString *)destPath
                   mcVersion:(NSString *)mcVersion
                      loader:(NSString *)loader
              loaderVersion:(NSString *)loaderVersion
                        name:(NSString *)name
                     version:(NSString *)version
                       error:(NSError **)error {
    // FCL 链接列表格式：
    // # Minecraft: <mcVersion>
    // # Loader: <loader>-<loaderVersion>
    // # Name: <name>
    // # Version: <version>
    // <zip内路径>|<下载链接或本地路径>
    NSMutableString *content = [NSMutableString string];
    [content appendFormat:@"# Minecraft: %@\n", mcVersion];
    if (loader.length > 0 && loaderVersion.length > 0) {
        [content appendFormat:@"# Loader: %@-%@\n", loader, loaderVersion];
    }
    [content appendFormat:@"# Name: %@\n", name.length > 0 ? name : @"Exported Modpack"];
    [content appendFormat:@"# Version: %@\n", version.length > 0 ? version : @"1.0"];
    [content appendString:@"# 格式: <zip内路径>|<下载链接或本地路径>\n\n"];

    for (NSDictionary *modFile in modFiles) {
        // 链接列表格式：mod 路径 + 空下载链接（用户可手动填写）
        [content appendFormat:@"%@|\n", modFile[@"path"]];
    }

    NSError *writeError = nil;
    BOOL success = [content writeToFile:destPath atomically:YES encoding:NSUTF8StringEncoding error:&writeError];
    if (!success) {
        if (error) *error = writeError;
        return NO;
    }
    NSLog(@"[ModpackExport] 链接列表格式导出完成: %@", destPath);
    return YES;
}

#pragma mark - 辅助方法

- (void)addDirectoryToArchive:(UZKArchive *)archive
                      dirPath:(NSString *)dirPath
                  prefixInZip:(NSString *)prefixInZip
                     progress:(void (^_Nullable)(NSUInteger done))progress {
    NSFileManager *fileManager = [NSFileManager defaultManager];
    NSDirectoryEnumerator *enumerator = [fileManager enumeratorAtPath:dirPath];
    NSString *relativePath;
    while ((relativePath = [enumerator nextObject])) {
        NSString *fullPath = [dirPath stringByAppendingPathComponent:relativePath];
        BOOL isDir = NO;
        if (![fileManager fileExistsAtPath:fullPath isDirectory:&isDir] || isDir) continue;

        NSData *data = [NSData dataWithContentsOfFile:fullPath];
        if (!data) continue;

        NSString *zipPath = [NSString stringWithFormat:@"%@/%@", prefixInZip, relativePath];
        [archive writeData:data filePath:zipPath error:nil];
        if (progress) progress(1);
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

    // 纯 mc 版本（无 loader）
    return @{@"minecraft": versionId};
}

@end
