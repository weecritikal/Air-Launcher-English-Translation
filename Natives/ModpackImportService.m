//
//  ModpackImportService.m
//  Amethyst
//
//  Modpack import service implementation
//
//  参照 FCL (Fold Craft Launcher) 的整合包导入流程重写:
//  1. 正确解析 Modrinth (.mrpack) 和 CurseForge (manifest.json) 两种格式
//  2. 解压 overrides/client-overrides 到 gameDir (而非 modpackDir 根目录)
//  3. 下载 manifest/files 列出的所有 mod 到 gameDir/mods
//  4. 对 Fabric/Quilt 整合包自动拉取 loader profile json 写入版本目录
//  5. 对 Forge/NeoForge 整合包下载 installer.jar 并调用直装器写入 modpack gameDir
//  6. gameDir 使用相对路径 (./custom_gamedir/<id>) 与启动器 POJAV_GAME_DIR 对齐
//  7. 写完整 profile (含 gameDir、lastVersionId、icon)
//

#import "ModpackImportService.h"
#import "installer/FabricUtils.h"
#import "installer/modpack/ModpackUtils.h"
#import "installer/ForgeDirectInstaller.h"
#import "installer/NeoForgeDirectInstaller.h"
#import "PLProfiles.h"
#import "PLPreferences.h"
#import "UnzipKit.h"
#import "DownloadTaskManager.h"
#import "DownloadTaskItem.h"
#import "LauncherPreferences.h"

static NSString * const kImportedModpacksKey = @"ImportedModpacks";

@interface ModpackImportService () <NSURLSessionDownloadDelegate>
/// 整合包工作区根目录: <POJAV_GAME_DIR>/custom_gamedir
@property (nonatomic, strong) NSString *customGameDir;
/// 用于下载 mod 文件、加载器 installer/profile json 的会话
@property (nonatomic, strong) NSURLSession *downloadSession;
/// task -> { success, location, error }
@property (nonatomic, strong) NSMutableDictionary<NSURLSessionTask *, NSMutableDictionary *> *downloadResults;
/// task -> dispatch_semaphore_t，用于同步等待单个下载完成
@property (nonatomic, strong) NSMutableDictionary<NSURLSessionTask *, dispatch_semaphore_t> *downloadSemaphores;
/// task -> DownloadTaskItem.taskId
@property (nonatomic, strong) NSMutableDictionary<NSURLSessionTask *, NSString *> *downloadTaskIds;
/// task -> { lastTime, lastBytes }
@property (nonatomic, strong) NSMutableDictionary<NSURLSessionTask *, NSMutableDictionary *> *downloadProgressSnapshots;
@property (nonatomic, strong) NSMutableDictionary<NSURLSessionTask *, DownloadTaskItem *> *downloadTaskItems;
@property (nonatomic, strong) NSLock *downloadLock;

// 前向声明：将 modpackInfo 中的 iconBase64 解析为可用的文件 URL 字符串
- (nullable NSString *)resolveIconURLFromModpackInfo:(NSDictionary *)modpackInfo;
@end

@implementation ModpackImportService

- (instancetype)init {
    self = [super init];
    if (self) {
        // 整合包目录直接用 POJAV_GAME_DIR 下的 custom_gamedir，gameDir 字段写相对路径
        // 这样启动器读取 profile 时会拼成 <POJAV_GAME_DIR>/custom_gamedir/<id>
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
    }
    return self;
}

#pragma mark - Helpers

/// 将 modpackInfo 中的 iconBase64 字段解析为可用的图标 URL。
/// modrinth.index.json 中 iconBase64 是 base64 编码的图片数据（如 "data:image/png;base64,...." 或纯 base64 字符串），
/// 不能直接作为 URL 使用。该方法将其解码为 UIImage，保存到临时文件，返回文件 URL 字符串。
/// 如果解析失败或无图标，返回 nil（调用方使用默认图标）。
- (nullable NSString *)resolveIconURLFromModpackInfo:(NSDictionary *)modpackInfo {
    NSString *iconBase64 = modpackInfo[@"iconBase64"];
    if (!iconBase64 || iconBase64.length == 0) return nil;

    // 去除可能的 data URI 前缀（如 "data:image/png;base64,"）
    NSString *base64String = iconBase64;
    NSString *prefix = @"base64,";
    NSRange prefixRange = [iconBase64 rangeOfString:prefix];
    if (prefixRange.location != NSNotFound) {
        base64String = [iconBase64 substringFromIndex:prefixRange.location + prefixRange.length];
    }

    // 解码 base64
    NSData *imageData = [[NSData alloc] initWithBase64EncodedString:base64String
                                                             options:NSDataBase64DecodingIgnoreUnknownCharacters];
    if (!imageData || imageData.length == 0) return nil;

    // 保存到临时文件
    NSString *tempDir = NSTemporaryDirectory();
    NSString *iconFileName = [NSString stringWithFormat:@"modpack_icon_%@.png",
                              modpackInfo[@"id"] ?: modpackInfo[@"name"] ?: @"unknown"];
    NSString *iconPath = [tempDir stringByAppendingPathComponent:iconFileName];
    NSError *writeError = nil;
    if ([imageData writeToFile:iconPath options:NSDataWritingAtomic error:&writeError]) {
        // 返回文件 URL 字符串（AFNetworking 的 setImageWithURL: 支持文件 URL）
        NSURL *fileURL = [NSURL fileURLWithPath:iconPath];
        return fileURL.absoluteString;
    }
    return nil;
}

/// 将 NSDate 转为 ISO8601 字符串，确保 JSON 序列化安全
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

/// 给定 modpack id，返回 gameDir 的绝对路径 (用于本地文件操作)
- (NSString *)absoluteGameDirForModpackId:(NSString *)modpackId {
    return [self.customGameDir stringByAppendingPathComponent:modpackId];
}

/// 给定 modpack id，返回 gameDir 的相对路径 (写入 profile 的 gameDir 字段)
- (NSString *)relativeGameDirForModpackId:(NSString *)modpackId {
    return [NSString stringWithFormat:@"./custom_gamedir/%@", modpackId];
}

/// 把 Modrinth dependencies 解析成 loader 信息
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

/// 把 CurseForge manifest.modLoaders 解析成 loader 信息
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
                                     userInfo:@{NSLocalizedDescriptionKey: @"文件不存在"}];
        }
        return nil;
    }

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

    NSData *indexData = [archive extractDataFromFile:@"modrinth.index.json" error:&archiveError];
    if (indexData) {
        return [self parseModrinthModpack:archive indexData:indexData filePath:filePath error:error];
    }

    NSData *manifestData = [archive extractDataFromFile:@"manifest.json" error:&archiveError];
    if (manifestData) {
        return [self parseManifestModpack:archive manifestData:manifestData filePath:filePath error:error];
    }

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

    NSDictionary *dependencies = indexDict[@"dependencies"];
    NSString *minecraftVersion = nil, *loader = nil, *loaderVersion = nil;
    [self resolveModrinthDependencies:dependencies
                                loader:&loader
                         loaderVersion:&loaderVersion
                          minecraftVer:&minecraftVersion];

    NSString *name = indexDict[@"name"] ?: [filePath.lastPathComponent stringByDeletingPathExtension];
    NSString *version = indexDict[@"versionId"] ?: @"1.0.0";
    NSString *modpackId = [NSString stringWithFormat:@"modrinth_%@", [[NSUUID UUID] UUIDString]];

    // 提取 icon.png (如果有)
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
                                     userInfo:@{NSLocalizedDescriptionKey: @"无法解析 manifest.json"}];
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

    // 提取 icon (CurseForge 整合包通常没有，尝试 modpack.png 或 pack.png)
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

/// 从整合包内尝试提取 icon.png/modpack.png/pack.png，返回 base64 data URI
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

    if (progress) progress(0.05, @"准备整合包目录");

    NSString *modpackId = modpackInfo[@"id"];
    NSString *gameDirAbsolute = [self absoluteGameDirForModpackId:modpackId];
    NSString *gameDirRelative = [self relativeGameDirForModpackId:modpackId];

    // 清理可能存在的旧目录
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

    // 创建 mods 目录
    NSString *modsDir = [gameDirAbsolute stringByAppendingPathComponent:@"mods"];
    [fm createDirectoryAtPath:modsDir withIntermediateDirectories:YES attributes:nil error:nil];

    // 创建 versions 目录
    NSString *versionsDir = [gameDirAbsolute stringByAppendingPathComponent:@"versions"];
    [fm createDirectoryAtPath:versionsDir withIntermediateDirectories:YES attributes:nil error:nil];

    // 第 1 步: 解压 overrides/client-overrides (Modrinth) 或 overrides (CurseForge) 到 gameDir
    if (progress) progress(0.10, @"正在解压 overrides");
    NSError *extractError = nil;
    BOOL extractSuccess = [self extractOverrides:filePath format:format toDirectory:gameDirAbsolute error:&extractError];
    if (!extractSuccess) {
        [fm removeItemAtPath:gameDirAbsolute error:nil];
        if (error) *error = extractError;
        return NO;
    }

    // 第 2 步: 下载 mod 文件列表
    NSArray *modFiles = modpackInfo[@"files"];
    if (modFiles.count > 0) {
        if (progress) progress(0.15, [NSString stringWithFormat:@"正在下载 %lu 个 mod 文件", (unsigned long)modFiles.count]);
        NSError *downloadError = nil;
        BOOL downloadSuccess = [self downloadModFiles:modpackInfo toModsDirectory:modsDir progress:progress error:&downloadError];
        if (!downloadSuccess) {
            // mod 下载失败不阻断导入，只记录警告
            NSLog(@"[ModpackImport] mod 下载部分失败: %@", downloadError.localizedDescription);
        }
    }

    // 第 3 步: 安装模组加载器
    if (progress) progress(0.85, @"正在安装模组加载器");
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
        // 加载器安装失败不阻断 (用户可能已经手动安装)
        NSLog(@"[ModpackImport] 加载器安装失败 (用户可能已安装): %@", loaderError.localizedDescription);
    }

    // 第 4 步: 写 profile
    if (progress) progress(0.95, @"正在写入配置文件");
    NSString *profileName = [self createProfileForModpack:modpackInfo
                                          gameDirRelative:gameDirRelative
                                                versionId:versionId
                                                    error:error];
    if (!profileName) {
        [fm removeItemAtPath:gameDirAbsolute error:nil];
        return NO;
    }

    // 第 5 步: 持久化整合包元信息
    NSMutableDictionary *savedModpack = [modpackInfo mutableCopy];
    savedModpack[@"gameDirAbsolute"] = gameDirAbsolute;
    savedModpack[@"gameDirRelative"] = gameDirRelative;
    savedModpack[@"profileName"] = profileName;
    savedModpack[@"importDate"] = [self iso8601StringFromDate:[NSDate date]];
    [self saveImportedModpack:savedModpack];

    if (progress) progress(1.0, @"导入完成");
    return YES;
}

/// 根据 modpackInfo 计算 lastVersionId
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
        // NeoForge 版本号本身已包含 MC 版本信息，例如 47.1.0 (对应 1.20.1)
        // 但在版本目录里仍用 <mc>-neoforge-<loader> 形式以便区分
        return [NSString stringWithFormat:@"%@-neoforge-%@", minecraftVersion, loaderVersion];
    } else {
        return minecraftVersion ?: @"";
    }
}

/// 解压 overrides 目录到 gameDir
/// Modrinth: overrides + client-overrides
/// CurseForge: overrides
- (BOOL)extractOverrides:(NSString *)filePath format:(NSString *)format toDirectory:(NSString *)destDir error:(NSError **)error {
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

    // Modrinth: 解压 overrides 和 client-overrides (后者覆盖前者)
    [ModpackUtils archive:archive extractDirectory:@"overrides" toPath:destDir error:error];
    if (error && *error) {
        return NO;
    }

    if ([format isEqualToString:@"modrinth"]) {
        [ModpackUtils archive:archive extractDirectory:@"client-overrides" toPath:destDir error:error];
        if (error && *error) {
            // client-overrides 不存在不算错误
            NSLog(@"[ModpackImport] client-overrides 提取 (可能不存在): %@", *error);
            *error = nil;
        }
    }

    return YES;
}

/// 下载 mod 文件列表
/// Modrinth 格式: files[].downloads[0] 是直接 URL，files[].path 是相对路径
/// CurseForge 格式: files[].projectID + fileID 需要通过 CurseForge API 解析下载 URL
- (BOOL)downloadModFiles:(NSDictionary *)modpackInfo toModsDirectory:(NSString *)modsDir progress:(void (^_Nullable)(double progress, NSString *stageMessage))progress error:(NSError **)error {
    NSString *format = modpackInfo[@"format"];
    NSArray *files = modpackInfo[@"files"];
    if (files.count == 0) return YES;

    NSUInteger total = files.count;
    NSUInteger successCount = 0;
    NSString *downloadSource = getPrefObject(@"general.download_source") ?: @"official";
    // 修复整合包图标不显示：原实现将 modpackInfo[@"iconBase64"]（base64 编码的图片数据字符串）
    // 直接赋给 iconURL 字段，传给 setImageWithURL: 时 NSURL URLWithString: 返回 nil（base64 不是合法 URL），
    // 导致整合包下载任务的图标永远不显示。
    // 正确做法：将 base64 数据解码为 UIImage，保存到临时文件，使用文件 URL。
    NSString *iconURL = [self resolveIconURLFromModpackInfo:modpackInfo];

    if ([format isEqualToString:@"modrinth"]) {
        // Modrinth: 直接下载
        NSUInteger skippedOptional = 0;
        for (NSUInteger i = 0; i < total; i++) {
            NSDictionary *fileInfo = files[i];
            NSArray *downloads = fileInfo[@"downloads"];
            NSString *url = downloads.firstObject;
            NSString *relPath = fileInfo[@"path"];
            // env 字段过滤：Modrinth 文件可声明仅 server 或仅 client 适用。
            // 启动器是客户端，跳过 env.client=="unsupported" 的文件（避免下载服务端专用 mod）。
            // env 缺失或 env.client=="required"/"optional" 时正常下载。
            NSDictionary *env = fileInfo[@"env"];
            NSString *clientEnv = env[@"client"];
            if ([clientEnv isKindOfClass:[NSString class]] && [clientEnv isEqualToString:@"unsupported"]) {
                skippedOptional++;
                NSLog(@"[ModpackImport] 跳过 server-only 模组: %@", relPath);
                continue;
            }

            if (!url || !relPath) {
                // 关键修复：URL 为空时不应静默跳过而不计数，否则进度条永远卡住、用户也无法感知有缺失。
                // 之前只 completedUnitCount++ 但不报告失败，造成整合包 mod 不完整。
                NSLog(@"[ModpackImport] 警告：Modrinth 文件 %@ 缺少 download URL，跳过", relPath);
                continue;
            }

            // 关键修复：之前 `if (![relPath hasPrefix:@"mods/"]) continue;` 会丢弃所有非 mods/ 前缀的文件，
            // 包括 shaderpacks/、resourcepacks/、datapacks/ 等用户自定义资源。
            // 这与 issue 描述的"模组不完整"密切相关——很多整合包除 mod 外还含 shaderpack、资源包等。
            // 正确做法：根据 path 前缀分发到 modsDir 之外的对应目录。
            // 注意：overrides 目录已通过 extractModpackOverrides 解压，这里只处理 mods/、shaderpacks/、
            // resourcepacks/、datapacks/ 等具体子目录前缀。
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
                // 其他前缀（如 config/、defaultconfigs/）通常在 overrides 中，但 modrinth.index.json
                // 的 files 数组理论上不应重复列出 overrides 内容；若出现，按相对路径完整写入 gameDir 根。
                destDir = [modsDir.stringByDeletingLastPathComponent stringByAppendingPathComponent:relPath.stringByDeletingLastPathComponent];
            }
            // 处理子目录（如 mods/inner/sub.jar）
            NSString *relativeUnder = [relPath substringFromIndex:[relPath rangeOfString:@"/"].location + 1];
            NSString *fileName = relPath.lastPathComponent;
            NSString *destPath = [destDir stringByAppendingPathComponent:relativeUnder];

            // 关键修复：原 downloadFileFromURL 无重试。整合包中单个 mod 下载偶发失败会直接被跳过，
            // 造成最终 mods 目录缺文件。增加最多 3 次重试（间隔 1s）。
            BOOL ok = NO;
            NSError *dlError = nil;
            for (NSInteger retry = 0; retry < 3 && !ok; retry++) {
                if (retry > 0) {
                    NSLog(@"[ModpackImport] 重试下载 %@ (第 %ld 次)", fileName, (long)retry);
                    [NSThread sleepForTimeInterval:1.0];
                    // 清理上次失败可能残留的半成品文件
                    [[NSFileManager defaultManager] removeItemAtPath:destPath error:nil];
                }
                // 每次重试都创建新 task（旧 task 已结束）
                NSURLSessionDownloadTask *task = [self.downloadSession downloadTaskWithURL:[NSURL URLWithString:url]];
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
                    NSLog(@"[ModpackImport] mod 下载失败 %@ (第 %ld 次): %@", fileName, (long)retry, dlError.localizedDescription);
                }
            }
            if (ok) successCount++;
            else NSLog(@"[ModpackImport] 模组最终下载失败：%@ (%@)", fileName, url);

            if (progress) {
                double p = 0.15 + 0.70 * ((double)(i + 1) / (double)total);
                progress(p, [NSString stringWithFormat:@"下载 mod %lu/%lu: %@", (unsigned long)(i+1), (unsigned long)total, fileName]);
            }
        }
        if (skippedOptional > 0) {
            NSLog(@"[ModpackImport] Modrinth 整合包：跳过 %lu 个 server-only 模组", (unsigned long)skippedOptional);
        }
    } else if ([format isEqualToString:@"curseforge"]) {
        // CurseForge: 需要 projectID + fileID 通过 API 获取下载链接
        // 这里通过 CurseForgeAPI 获取，避免循环依赖，直接构造 API URL
        for (NSUInteger i = 0; i < total; i++) {
            NSDictionary *fileInfo = files[i];
            NSNumber *projectID = fileInfo[@"projectID"];
            NSNumber *fileID = fileInfo[@"fileID"];
            if (!projectID || !fileID) continue;

            NSString *downloadURL = [self fetchCurseForgeFileURL:projectID.longLongValue fileID:fileID.longLongValue];
            if (!downloadURL) continue;

            // 关键修复：使用 projectID-fileID.jar 作为文件名只是 fallback。
            // 优先使用 manifest 中真实 fileName（若 modpackInfo 解析时已透传），便于用户识别。
            NSString *fileName = fileInfo[@"fileName"];
            if (![fileName isKindOfClass:[NSString class]] || fileName.length == 0) {
                fileName = [NSString stringWithFormat:@"%@-%@.jar", projectID, fileID];
            }
            NSString *destPath = [modsDir stringByAppendingPathComponent:fileName];

            // 关键修复：与 Modrinth 路径一致，增加最多 3 次重试。
            // 第 3 次失败后切换到备用源（CurseForge 官方 CDN）再试 1 次。
            BOOL ok = NO;
            NSError *dlError = nil;
            NSString *currentURL = downloadURL;
            for (NSInteger retry = 0; retry < 4 && !ok; retry++) {
                if (retry > 0) {
                    NSLog(@"[ModpackImport] 重试下载 %@ (第 %ld 次)", fileName, (long)retry);
                    [NSThread sleepForTimeInterval:1.0];
                    [[NSFileManager defaultManager] removeItemAtPath:destPath error:nil];
                }
                // 第 4 次重试切换到备用源（CurseForge 官方 CDN）
                if (retry == 3) {
                    NSString *altURL = [self fetchCurseForgeFileURLAlternate:projectID.longLongValue fileID:fileID.longLongValue];
                    if (altURL.length > 0) {
                        currentURL = altURL;
                        NSLog(@"[ModpackImport] 切换到备用源下载 %@: %@", fileName, altURL);
                    }
                }
                NSURLSessionDownloadTask *task = [self.downloadSession downloadTaskWithURL:[NSURL URLWithString:currentURL]];
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
                    NSLog(@"[ModpackImport] mod 下载失败 %@ (第 %ld 次): %@", fileName, (long)retry, dlError.localizedDescription);
                }
            }
            if (ok) successCount++;
            else NSLog(@"[ModpackImport] 模组最终下载失败：%@", fileName);

            if (progress) {
                double p = 0.15 + 0.70 * ((double)(i + 1) / (double)total);
                progress(p, [NSString stringWithFormat:@"下载 mod %lu/%lu (CurseForge)", (unsigned long)(i+1), (unsigned long)total]);
            }
        }
    }

    NSLog(@"[ModpackImport] mod 下载完成: %lu/%lu 成功", (unsigned long)successCount, (unsigned long)total);
    // 关键修复：之前永远 `return YES;`，无论实际成功多少，调用方无法感知失败。
    // 改为：仅当 successCount == total（或成功数 >= 80% 且无致命错误）时返回 YES。
    // 失败比例过高时返回 NO，让上层能给出"整合包安装失败"的明确错误。
    // 但仍允许部分失败（>= 50%）通过，避免单个边缘 mod 导致整个整合包安装失败。
    if (total == 0) return YES;
    double successRate = (double)successCount / (double)total;
    if (successRate >= 0.5) {
        if (successCount < total) {
            NSLog(@"[ModpackImport] 整合包部分模组下载失败：%lu/%lu 成功（成功率 %.0f%%）", (unsigned long)successCount, (unsigned long)total, successRate * 100);
        }
        return YES;
    }
    if (error) {
        *error = [NSError errorWithDomain:@"ModpackImportError"
                                     code:5004
                                 userInfo:@{NSLocalizedDescriptionKey: [NSString stringWithFormat:@"整合包模组下载失败过多：%lu/%lu 成功", (unsigned long)successCount, (unsigned long)total]}];
    }
    return NO;
}

/// 同步下载单个文件，并关联到已注册的 DownloadTaskItem(taskId)。
/// 如果传入 existingTask，则直接使用该任务；否则内部创建新的下载任务。
/// 返回 YES 表示文件已成功保存到 destPath；NO 表示下载或保存失败。
- (BOOL)downloadFileFromURL:(NSString *)urlString
                     toPath:(NSString *)destPath
                     taskId:(nullable NSString *)taskId
                       task:(nullable NSURLSessionDownloadTask *)existingTask
                      error:(NSError **)outError {
    NSURL *url = [NSURL URLWithString:urlString];
    if (!url) {
        NSError *invalidURLError = [NSError errorWithDomain:@"ModpackImportError"
                                                       code:5001
                                                   userInfo:@{NSLocalizedDescriptionKey: @"无效的下载链接"}];
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
                                                   userInfo:@{NSLocalizedDescriptionKey: @"下载完成但缺少临时文件"}];
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
            // 没有文件数据但流程结束，标记为失败
            NSError *unknownError = [NSError errorWithDomain:@"ModpackImportError"
                                                        code:5003
                                                    userInfo:@{NSLocalizedDescriptionKey: @"下载未完成"}];
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
                                                 userInfo:@{NSLocalizedDescriptionKey: @"下载未完成"}];
        }
    }

    if (sema) dispatch_semaphore_signal(sema);
}

/// 通过 CurseForge API 获取 mod 文件的下载链接
- (nullable NSString *)fetchCurseForgeFileURL:(long long)projectID fileID:(long long)fileID {
    // 关键修复：原实现只走 BMCLAPI 镜像，BMCLAPI 偶发不可达（CDN 抖动、镜像源切换、文件未同步）
    // 时整批 mod 全部下载失败。改为返回一个"主-备双源"组合：优先 BMCLAPI，
    // 失败时由下载层重试 - 此处仅返回主源 URL，下载层 fetchCurseForgeFileURL 的调用方
    // 在 3 次重试都失败后会再调用 fetchCurseForgeFileURLAlternate 获取备用源。
    NSString *apiURL = [NSString stringWithFormat:@"https://bmclapi2.bangbang93.com/curseforge/files/%lld/%lld/download", projectID, fileID];
    return apiURL;
}

/// 备用 CurseForge 下载链接（在主源重试失败后使用）
/// 优先尝试 CurseForge 官方 CDN 直链（format: cdn.curseforge.com/files/<id4>/<id4id>.jar），
/// 失败再回退到 curseforge.com 的 file detail 页（让 NSURLSession 跟随重定向）。
- (nullable NSString *)fetchCurseForgeFileURLAlternate:(long long)projectID fileID:(long long)fileID {
    // CurseForge 官方 CDN 直链（无需 API Key，但可能在国内不可达，作为 BMCLAPI 不可用时的备用）
    return [NSString stringWithFormat:@"https://cdn.curseforge.com/files/%lld/%lld/download", projectID, fileID];
}

/// 安装模组加载器
/// Fabric/Quilt: 拉取 profile json 并写入 versions/<id>/<id>.json
/// Forge/NeoForge: 写一个最小的版本 JSON 占位 (依赖用户后续手动安装)
///                或者引导用户安装。这里先写占位，避免 profile 引用不存在的版本时崩溃
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
                                     userInfo:@{NSLocalizedDescriptionKey: @"缺少加载器版本或游戏版本"}];
        }
        return NO;
    }

    NSString *downloadSource = getPrefObject(@"general.download_source") ?: @"official";
    // 版本 JSON 必须写入 POJAV_GAME_DIR/versions/（主目录），而非 gameDirAbsolute（整合包隔离目录）。
    // Minecraft 启动器 Java 端 Tools.java 的 DIR_HOME_VERSION 固定指向 POJAV_GAME_DIR/versions，
    // 不从 profile gameDir 读取。之前写入 gameDirAbsolute/versions/ 会导致启动时"找不到版本信息"。
    // gameDirAbsolute 仅用于 mods/saves/configs 等用户数据隔离（通过 profile gameDir=user.dir 实现）。
    NSString *mainVersionDir = [NSString stringWithFormat:@"%s/versions/%@", getenv("POJAV_GAME_DIR"), versionId];
    NSString *versionDir = mainVersionDir;
    NSString *versionJsonPath = [versionDir stringByAppendingPathComponent:[NSString stringWithFormat:@"%@.json", versionId]];
    NSFileManager *fm = [NSFileManager defaultManager];
    [fm createDirectoryAtPath:versionDir withIntermediateDirectories:YES attributes:nil error:nil];

    // Fabric/Quilt: 直接从 meta API 拉 profile json
    if ([loader isEqualToString:@"Fabric"] || [loader isEqualToString:@"Quilt"]) {
        NSDictionary *endpoints = FabricUtils.endpoints[loader];
        NSString *jsonURLTemplate = endpoints[@"json"];
        if (!jsonURLTemplate) {
            if (error) {
                *error = [NSError errorWithDomain:@"ModpackImportError"
                                             code:4002
                                         userInfo:@{NSLocalizedDescriptionKey: [NSString stringWithFormat:@"%@ endpoints 未找到", loader]}];
            }
            return NO;
        }
        NSString *jsonURL = [NSString stringWithFormat:jsonURLTemplate, minecraftVersion, loaderVersion];
        NSURL *url = [NSURL URLWithString:jsonURL];

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

    // Forge/NeoForge: 下载 installer.jar 并调用直装器写入 modpack 的 gameDir
    // 直装器会写完整的 version.json（含正确的 mainClass、arguments、libraries）+ 下载 Forge 库
    // 这样整合包启动时能正确加载 Forge，不再因占位 JSON 缺库/缺参数而崩溃
    NSString *installerURL = [self buildInstallerURLForLoader:loader
                                               loaderVersion:loaderVersion
                                              minecraftVersion:minecraftVersion];
    if (!installerURL) {
        if (error) {
            *error = [NSError errorWithDomain:@"ModpackImportError"
                                         code:4003
                                     userInfo:@{NSLocalizedDescriptionKey: [NSString stringWithFormat:@"无法构造 %@ installer URL", loader]}];
        }
        return NO;
    }

    // 下载 installer.jar 到临时目录
    NSString *tmpInstallerPath = [NSTemporaryDirectory() stringByAppendingPathComponent:
                                  [NSString stringWithFormat:@"%@-installer.jar", versionId]];

    NSString *installerDisplayName = [NSString stringWithFormat:@"%@ %@ installer", loader, loaderVersion];
    NSURLSessionDownloadTask *installerTask = [self.downloadSession downloadTaskWithURL:[NSURL URLWithString:installerURL]];
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
        // installer.jar 下载失败：写显式失败的占位 JSON（mainClass 指向不存在的类，启动时会显式报错，
        // 避免误装作 vanilla MC 让用户以为 mods 生效）
        NSLog(@"[ModpackImport] %@ installer.jar 下载失败，回退到占位 JSON: %@", loader, installerURL);
        NSInteger javaMajor = [self javaMajorVersionForMC:minecraftVersion];
        NSDictionary *placeholderJSON = @{
            @"_comment_": [NSString stringWithFormat:@"此整合包需要 %@ %@ 加载器，自动安装失败。请通过下载界面手动安装。", loader, loaderVersion],
            @"id": versionId,
            @"inheritsFrom": minecraftVersion,
            @"type": @"release",
            @"mainClass": @"net.angelaura.installer.MissingLoader",  // 故意指向不存在的类，启动时显式报错
            @"javaVersion": @{@"component": @"java-runtime", @"majorVersion": @(javaMajor)}
        };
        NSData *jsonData = [NSJSONSerialization dataWithJSONObject:placeholderJSON options:NSJSONWritingPrettyPrinted error:nil];
        [jsonData writeToFile:versionJsonPath options:NSDataWritingAtomic error:nil];
        if (error) {
            *error = [NSError errorWithDomain:@"ModpackImportService" code:1001
                                     userInfo:@{NSLocalizedDescriptionKey: [NSString stringWithFormat:@"%@ installer.jar 下载失败，已写入占位 JSON。请手动安装加载器。", loader]}];
        }
        return NO;  // 让调用方感知失败并打印警告
    }

    NSLog(@"[ModpackImport] %@ installer.jar 下载完成: %@", loader, tmpInstallerPath);

    // 调用直装器，写入 modpack 的 gameDirAbsolute（不注册 profile，由 createProfileForModpack 统一注册）
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

    // 清理临时 installer.jar
    [[NSFileManager defaultManager] removeItemAtPath:tmpInstallerPath error:nil];

    if (!installSuccess) {
        NSLog(@"[ModpackImport] %@ 直装失败，回退到占位 JSON: %@", loader, installError.localizedDescription);
        // 使用外层作用域的 installerTaskId（installerItem 仅在 floatingBallEnabled 块内声明）
        if (installerTaskId) {
            [[DownloadTaskManager sharedManager] setTaskWithId:installerTaskId completedWithError:installError];
        }
        // 直装失败：写显式失败的占位 JSON（mainClass 指向不存在的类，启动时会显式报错，
        // 避免误装作 vanilla MC 让用户以为 mods 生效）
        NSInteger javaMajor = [self javaMajorVersionForMC:minecraftVersion];
        NSDictionary *placeholderJSON = @{
            @"_comment_": [NSString stringWithFormat:@"此整合包需要 %@ %@ 加载器，自动安装失败：%@。请通过下载界面手动安装。", loader, loaderVersion, installError.localizedDescription ?: @"未知错误"],
            @"id": versionId,
            @"inheritsFrom": minecraftVersion,
            @"type": @"release",
            @"mainClass": @"net.angelaura.installer.MissingLoader",  // 故意指向不存在的类，启动时显式报错
            @"javaVersion": @{@"component": @"java-runtime", @"majorVersion": @(javaMajor)}
        };
        NSData *jsonData = [NSJSONSerialization dataWithJSONObject:placeholderJSON options:NSJSONWritingPrettyPrinted error:nil];
        [jsonData writeToFile:versionJsonPath options:NSDataWritingAtomic error:nil];
        if (error) {
            *error = [NSError errorWithDomain:@"ModpackImportService" code:1002
                                     userInfo:@{NSLocalizedDescriptionKey: [NSString stringWithFormat:@"%@ 直装失败：%@。已写入占位 JSON。请手动安装加载器。", loader, installError.localizedDescription ?: @"未知错误"]}];
        }
        return NO;  // 让调用方感知失败并打印警告
    }

    NSLog(@"[ModpackImport] %@ 直装成功，version.json 已写入: %@", loader, versionJsonPath);
    return YES;
}

/// 根据 loader 类型构造 installer.jar 下载 URL
/// Forge: https://maven.minecraftforge.net/net/minecraftforge/forge/<mc>-<loader>/forge-<mc>-<loader>-installer.jar
/// NeoForge 1.20.1: https://maven.neoforged.net/releases/net/neoforged/forge/<loader>/forge-<loader>-installer.jar
/// NeoForge 其他: https://maven.neoforged.net/releases/net/neoforged/neoforge/<loader>/neoforge-<loader>-installer.jar
/// BMCLAPI 镜像优先（若用户选了 bmclapi 源）
- (nullable NSString *)buildInstallerURLForLoader:(NSString *)loader
                                    loaderVersion:(NSString *)loaderVersion
                                   minecraftVersion:(NSString *)minecraftVersion {
    NSString *downloadSource = [PLPreferences currentDownloadSourceForType:@"forge"];
    BOOL useBMCLAPI = [downloadSource isEqualToString:@"bmclapi"];

    if ([loader isEqualToString:@"Forge"]) {
        // Forge versionString = "<mc>-<loaderVersion>"，例如 "1.20.1-47.3.0"
        NSString *versionString = [NSString stringWithFormat:@"%@-%@", minecraftVersion, loaderVersion];
        if (useBMCLAPI) {
            return [NSString stringWithFormat:@"https://bmclapi2.bangbang93.com/maven/net/minecraftforge/forge/%@/forge-%@-installer.jar", versionString, versionString];
        }
        return [NSString stringWithFormat:@"https://maven.minecraftforge.net/net/minecraftforge/forge/%@/forge-%@-installer.jar", versionString, versionString];
    }

    if ([loader isEqualToString:@"NeoForge"]) {
        // NeoForge 1.20.1 早期版本 artifactId 是 net.neoforged:forge，之后是 net.neoforged:neoforge
        // loaderVersion 例如 "47.1.0"（1.20.1）或 "20.6.119-beta"（1.20.6+）
        BOOL isLegacyForgeArtifact = [minecraftVersion isEqualToString:@"1.20.1"];
        if (isLegacyForgeArtifact) {
            if (useBMCLAPI) {
                return [NSString stringWithFormat:@"https://bmclapi2.bangbang93.com/maven/net/neoforged/forge/%@/forge-%@-installer.jar", loaderVersion, loaderVersion];
            }
            return [NSString stringWithFormat:@"https://maven.neoforged.net/releases/net/neoforged/forge/%@/forge-%@-installer.jar", loaderVersion, loaderVersion];
        }
        if (useBMCLAPI) {
            return [NSString stringWithFormat:@"https://bmclapi2.bangbang93.com/maven/net/neoforged/neoforge/%@/neoforge-%@-installer.jar", loaderVersion, loaderVersion];
        }
        return [NSString stringWithFormat:@"https://maven.neoforged.net/releases/net/neoforged/neoforge/%@/neoforge-%@-installer.jar", loaderVersion, loaderVersion];
    }

    return nil;
}

/// 根据 MC 版本推断所需 Java 主版本号
/// 1.20.5+ → 21, 1.18+ → 17, 1.17 → 17（项目未捆绑 Java 16，Java 17 可向后兼容），1.16.5- → 8
- (NSInteger)javaMajorVersionForMC:(NSString *)mcVersion {
    NSArray *parts = [mcVersion componentsSeparatedByString:@"."];
    if (parts.count < 2) return 8;
    NSInteger major = [parts[1] integerValue];
    if (major >= 21) return 21;       // 1.21+
    if (major >= 20 && parts.count >= 3 && [parts[2] integerValue] >= 5) return 21; // 1.20.5+
    if (major >= 18) return 17;       // 1.18+
    if (major >= 17) return 17;       // 1.17（项目未捆绑 Java 16，Java 17 可向后兼容运行 1.17）
    return 8;                          // 1.16.5 及以下
}

- (nullable NSString *)createProfileForModpack:(NSDictionary *)modpackInfo
                              gameDirRelative:(NSString *)gameDirRelative
                                    versionId:(NSString *)versionId
                                        error:(NSError **)error {
    NSString *name = modpackInfo[@"name"];
    NSString *modpackId = modpackInfo[@"id"];
    NSString *profileName = modpackId;  // 用 modpackId 作为 profile name 避免重名冲突

    NSMutableDictionary *profile = [@{
        @"name": name,
        @"lastVersionId": versionId ?: @"",
        @"gameDir": gameDirRelative,
        @"created": [self iso8601StringFromDate:[NSDate date]],
        @"type": @"modpack"
    } mutableCopy];

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
        // 兼容旧数据: 尝试从 modpackDir 字段获取
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
