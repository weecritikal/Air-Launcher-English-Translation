//
//  NeoForgeDirectInstaller.m
//  Amethyst
//
//  Direct NeoForge installer (new format only, NeoForge 1.20.1+).
//
//  本直装器采用"下载预打补丁 PATCHED artifact"方案，不执行 install_profile.json 的 processors。
//  原因：iOS 沙箱禁止 fork/exec，无法 spawn 子 JVM 执行 processor 工具（binarypatcher、
//  jarsplitter、SpecialSource 等）。社区启动器在受限平台的通用做法是直接从 maven 下载
//  NeoForge 已发布的预打补丁 client jar（如 neoforge-{loader}-client.jar），
//  这等同于 processor 的输出产物，运行时直接可用。
//
//  JarJar（JarInJar）机制是运行期由 modlauncher 的 JarInJarDependencyLocator 处理，
//  安装期无需任何 processor 介入。
//

#import "NeoForgeDirectInstaller.h"
#import "PLProfiles.h"
#import "utils.h"
#import "LauncherPreferences.h"
#import "external/UnzipKit/UZKArchive.h"

NSString *const NeoForgeDirectInstallerErrorDomain = @"NeoForgeDirectInstallerErrorDomain";

@implementation NeoForgeDirectInstaller

#pragma mark - Public

+ (BOOL)installNeoForgeFromInstaller:(NSString *)installerPath
                           versionId:(NSString *)versionId
                               error:(NSError **)error {
    return [self installNeoForgeFromInstaller:installerPath versionId:versionId progress:nil error:error];
}

+ (BOOL)installNeoForgeFromInstaller:(NSString *)installerPath
                           versionId:(NSString *)versionId
                            progress:(void (^)(double progress, NSString *stageMessage))progress
                               error:(NSError **)error {
    return [self installNeoForgeFromInstaller:installerPath
                                    versionId:versionId
                                customGameDir:nil
                          skipRegisterVersion:NO
                                     progress:progress
                                       error:error];
}

+ (BOOL)installNeoForgeFromInstaller:(NSString *)installerPath
                           versionId:(NSString *)versionId
                       customGameDir:(nullable NSString *)customGameDir
                 skipRegisterVersion:(BOOL)skipRegisterVersion
                            progress:(void (^)(double progress, NSString *stageMessage))progress
                               error:(NSError **)error {
    void (^reportProgress)(double, NSString *) = ^(double p, NSString *msg) {
        NSLog(@"[NeoForgeDirect] Progress: %.2f - %@", p, msg);
        if (progress) {
            progress(p, msg);
        }
    };

    @try {
        NSLog(@"[NeoForgeDirect] Starting installation: %@", versionId);
        reportProgress(0.0, @"开始安装");
        if (error) {
            *error = nil;
        }

        // Step 1: Read install_profile.json
        NSLog(@"[NeoForgeDirect] Reading install_profile.json");
        reportProgress(0.05, @"正在读取 install_profile.json");
        NSData *profileData = [self dataFromZip:installerPath entry:@"install_profile.json" error:error];
        if (!profileData) {
            NSLog(@"[NeoForgeDirect] Failed to read install_profile.json");
            if (error && !*error) {
                *error = [NSError errorWithDomain:NeoForgeDirectInstallerErrorDomain
                                             code:NeoForgeDirectInstallerErrorMissingProfile
                                         userInfo:@{NSLocalizedDescriptionKey: @"Missing install_profile.json in installer"}];
            }
            return NO;
        }
        NSLog(@"[NeoForgeDirect] Successfully read install_profile.json (%lu bytes)", (unsigned long)profileData.length);

        // Step 2: Parse install_profile.json
        NSLog(@"[NeoForgeDirect] Parsing install_profile.json");
        reportProgress(0.1, @"正在解析 JSON");
        NSError *jsonError = nil;
        NSMutableDictionary *installProfile = [NSJSONSerialization JSONObjectWithData:profileData
                                                                              options:NSJSONReadingMutableContainers
                                                                                error:&jsonError];
        NSLog(@"[NeoForgeDirect] JSON parsing completed, error=%@", jsonError ?: @"none");
        if (![installProfile isKindOfClass:[NSDictionary class]] || jsonError) {
            if (error) {
                *error = [NSError errorWithDomain:NeoForgeDirectInstallerErrorDomain
                                             code:NeoForgeDirectInstallerErrorInvalidProfile
                                         userInfo:@{NSLocalizedDescriptionKey: @"Failed to parse install_profile.json"}];
            }
            return NO;
        }

        // NeoForge only uses new format (spec field)
        BOOL isNewFormat = (installProfile[@"spec"] != nil);
        NSLog(@"[NeoForgeDirect] Format detection: new=%d", isNewFormat);
        if (!isNewFormat) {
            if (error) {
                *error = [NSError errorWithDomain:NeoForgeDirectInstallerErrorDomain
                                             code:NeoForgeDirectInstallerErrorInvalidProfile
                                         userInfo:@{NSLocalizedDescriptionKey: @"NeoForge installer uses unknown format (expected new format with spec)"}];
            }
            return NO;
        }

        // 整合包导入时使用自定义 gameDir；否则使用默认 POJAV_GAME_DIR
        NSString *gameDir = customGameDir.length > 0 ? customGameDir : [self gameDirectory];
        NSString *librariesDir = [gameDir stringByAppendingPathComponent:@"libraries"];
        NSLog(@"[NeoForgeDirect] Game directory: %@", gameDir);
        NSLog(@"[NeoForgeDirect] Libraries directory: %@", librariesDir);
        reportProgress(0.15, @"正在准备版本目录");

        // 提前创建 libraries 目录，避免后续下载/解压失败
        [[NSFileManager defaultManager] createDirectoryAtPath:librariesDir
                                  withIntermediateDirectories:YES
                                                   attributes:nil
                                                        error:nil];

        BOOL success = [self installNewFormat:installProfile
                               installerPath:installerPath
                                   versionId:versionId
                                     gameDir:gameDir
                               librariesDir:librariesDir
                                    progress:progress
                                      error:error];
        if (!success) {
            NSLog(@"[NeoForgeDirect] Installation failed");
            return NO;
        }

        // Step: Register version in launcher_profiles.json (must run on main thread)
        // 整合包导入时跳过（由 ModpackImportService.createProfileForModpack 统一注册）
        if (!skipRegisterVersion) {
            NSLog(@"[NeoForgeDirect] Registering version on main thread");
            reportProgress(0.95, @"正在注册版本");
            if ([NSThread isMainThread]) {
                [self registerVersion:versionId];
            } else {
                dispatch_sync(dispatch_get_main_queue(), ^{
                    [self registerVersion:versionId];
                });
            }
            NSLog(@"[NeoForgeDirect] Version registered successfully");
        }

        NSLog(@"[NeoForgeDirect] Installation completed successfully");
        reportProgress(1.0, @"安装完成");
        return YES;
    }
    @catch (NSException *exception) {
        NSString *stack = [exception.callStackSymbols componentsJoinedByString:@"\n"];
        NSLog(@"[NeoForgeDirect] EXCEPTION: name=%@, reason=%@, callStack=%@", exception.name, exception.reason, stack);
        if (error) {
            *error = [NSError errorWithDomain:NeoForgeDirectInstallerErrorDomain
                                          code:NeoForgeDirectInstallerErrorException
                                      userInfo:@{
                                          NSLocalizedDescriptionKey: [NSString stringWithFormat:@"安装异常: %@", exception.reason ?: @"未知原因"],
                                          NSLocalizedFailureReasonErrorKey: exception.name ?: @"UnknownException"
                                      }];
        }
        return NO;
    }
}

+ (BOOL)isNewFormatInstaller:(NSString *)installerPath {
    NSData *profileData = [self dataFromZip:installerPath entry:@"install_profile.json" error:nil];
    if (!profileData) {
        return NO;
    }

    NSDictionary *dict = [NSJSONSerialization JSONObjectWithData:profileData options:0 error:nil];
    if (![dict isKindOfClass:[NSDictionary class]]) {
        return NO;
    }

    return dict[@"spec"] != nil;
}

#pragma mark - New format (NeoForge 1.20.1+)

+ (BOOL)installNewFormat:(NSDictionary *)installProfile
           installerPath:(NSString *)installerPath
               versionId:(NSString *)versionId
                 gameDir:(NSString *)gameDir
            librariesDir:(NSString *)librariesDir
                progress:(void (^)(double, NSString *))progress
                  error:(NSError **)error {
    NSLog(@"[NeoForgeDirect] installNewFormat started");
    void (^reportProgress)(double, NSString *) = ^(double p, NSString *msg) {
        NSLog(@"[NeoForgeDirect] Progress: %.2f - %@", p, msg);
        if (progress) {
            progress(p, msg);
        }
    };

    // Read version.json
    NSLog(@"[NeoForgeDirect] Reading version.json");
    NSString *versionJsonEntry = installProfile[@"json"];
    if (!versionJsonEntry || ![versionJsonEntry isKindOfClass:[NSString class]]) {
        versionJsonEntry = @"version.json";
    }
    // version.json 路径可能以 "/" 开头，统一去掉
    if ([versionJsonEntry hasPrefix:@"/"]) {
        versionJsonEntry = [versionJsonEntry substringFromIndex:1];
    }
    NSLog(@"[NeoForgeDirect] version.json entry: %@", versionJsonEntry);

    NSData *versionData = [self dataFromZip:installerPath entry:versionJsonEntry error:error];
    if (!versionData) {
        if (error && !*error) {
            *error = [NSError errorWithDomain:NeoForgeDirectInstallerErrorDomain
                                         code:NeoForgeDirectInstallerErrorMissingProfile
                                     userInfo:@{NSLocalizedDescriptionKey: @"Missing version.json in installer"}];
        }
        return NO;
    }
    NSLog(@"[NeoForgeDirect] Successfully read version.json (%lu bytes)", (unsigned long)versionData.length);

    NSLog(@"[NeoForgeDirect] Parsing version.json");
    NSMutableDictionary *versionJson = [NSJSONSerialization JSONObjectWithData:versionData
                                                                       options:NSJSONReadingMutableContainers
                                                                         error:nil];
    if (![versionJson isKindOfClass:[NSDictionary class]]) {
        if (error) {
            *error = [NSError errorWithDomain:NeoForgeDirectInstallerErrorDomain
                                         code:NeoForgeDirectInstallerErrorInvalidProfile
                                     userInfo:@{NSLocalizedDescriptionKey: @"Failed to parse version.json"}];
        }
        return NO;
    }
    NSLog(@"[NeoForgeDirect] version.json parsed successfully");

    versionJson[@"id"] = versionId;

    // Merge libraries from install_profile into versionJson (dedup by name)
    NSLog(@"[NeoForgeDirect] Merging libraries");
    NSArray *profileLibraries = installProfile[@"libraries"];
    if ([profileLibraries isKindOfClass:[NSArray class]] && profileLibraries.count > 0) {
        NSMutableArray *mergedLibraries = [NSMutableArray array];
        NSMutableArray *existingNames = [NSMutableArray array];

        NSArray *versionLibraries = versionJson[@"libraries"];
        if ([versionLibraries isKindOfClass:[NSArray class]]) {
            for (NSDictionary *lib in versionLibraries) {
                [mergedLibraries addObject:lib];
                if ([lib isKindOfClass:[NSDictionary class]]) {
                    NSString *name = lib[@"name"];
                    if ([name isKindOfClass:[NSString class]]) {
                        [existingNames addObject:name];
                    }
                }
            }
        }

        NSUInteger addedCount = 0;
        NSUInteger skippedCount = 0;
        for (NSDictionary *library in installProfile[@"libraries"]) {
            if (![library isKindOfClass:[NSDictionary class]]) continue;
            NSString *name = library[@"name"];
            if (![name isKindOfClass:[NSString class]]) continue;
            if ([existingNames containsObject:name]) {
                skippedCount++;
                continue;
            }
            [mergedLibraries addObject:library];
            [existingNames addObject:name];
            addedCount++;
        }
        NSLog(@"[NeoForgeDirect] Merged libraries: added %lu, skipped %lu duplicates", (unsigned long)addedCount, (unsigned long)skippedCount);
        versionJson[@"libraries"] = mergedLibraries;
    }

    // Prepare version directory
    NSString *versionDir = [gameDir stringByAppendingPathComponent:[NSString stringWithFormat:@"versions/%@", versionId]];
    NSString *versionJsonPath = [versionDir stringByAppendingPathComponent:[NSString stringWithFormat:@"%@.json", versionId]];
    NSLog(@"[NeoForgeDirect] Version directory: %@", versionDir);
    [[NSFileManager defaultManager] createDirectoryAtPath:versionDir
                              withIntermediateDirectories:YES
                                               attributes:nil
                                                    error:nil];

    // Step A: 解压 installer.jar 内 maven/ 下的所有依赖到 libraries 目录
    NSLog(@"[NeoForgeDirect] Extracting all maven entries from installer jar");
    reportProgress(0.2, @"正在解压内嵌 maven 依赖");
    NSUInteger extractedCount = [self extractAllMavenEntries:installerPath toLibrariesDir:librariesDir];
    NSLog(@"[NeoForgeDirect] Extracted %lu maven entries", (unsigned long)extractedCount);

    // Step B: 下载 versionJson.libraries 中未在 installer.jar 内的库
    NSLog(@"[NeoForgeDirect] Downloading missing libraries from maven");
    reportProgress(0.3, @"正在下载缺失的依赖库");
    NSArray *allLibraries = versionJson[@"libraries"];
    if ([allLibraries isKindOfClass:[NSArray class]]) {
        [self downloadMissingLibraries:allLibraries librariesDir:librariesDir progress:progress baseProgress:0.3 progressSpan:0.4];
    }

    // Step C: 关键步骤——下载预打补丁的 PATCHED artifact
    // install_profile.json 的 processors 会生成 :client 这个 jar，但 iOS 不能跑 processor。
    // NeoForge 已将这个预打补丁 jar 发布到 maven，直接下载即可。
    NSLog(@"[NeoForgeDirect] Downloading pre-patched client artifact");
    reportProgress(0.75, @"正在下载预打补丁的核心 jar");
    NSString *mainPath = installProfile[@"path"];
    // 兜底：path 字段缺失时用 version 字段拼接（NeoForge 1.20.1 用 forge artifactId，1.20.2+ 用 neoforge artifactId）
    if (![mainPath isKindOfClass:[NSString class]] || mainPath.length == 0) {
        NSString *versionField = installProfile[@"version"];
        if ([versionField isKindOfClass:[NSString class]] && versionField.length > 0) {
            // NeoForge 1.20.1 path 形如 "net.neoforged:forge:1.20.1-47.1.0"
            // 其他版本 path 形如 "net.neoforged:neoforge:20.6.119-beta"
            if ([versionField containsString:@"1.20.1"]) {
                mainPath = [NSString stringWithFormat:@"net.neoforged:forge:%@", versionField];
            } else {
                mainPath = [NSString stringWithFormat:@"net.neoforged:neoforge:%@", versionField];
            }
            NSLog(@"[NeoForgeDirect] path 字段缺失，用 version 字段兜底拼接: %@", mainPath);
        }
    }
    if ([mainPath isKindOfClass:[NSString class]] && mainPath.length > 0) {
        if (![self downloadPatchedArtifact:mainPath librariesDir:librariesDir error:error]) {
            NSLog(@"[NeoForgeDirect] Failed to download patched artifact");
            return NO;
        }
    } else {
        // path 是 NeoForge 运行核心依赖，缺失会导致启动时 ClassNotFoundException
        NSLog(@"[NeoForgeDirect] install_profile.json 缺少 path/version 字段，无法下载 patched client jar");
        if (error) {
            *error = [NSError errorWithDomain:NeoForgeDirectInstallerErrorDomain
                                         code:NeoForgeDirectInstallerErrorInvalidProfile
                                     userInfo:@{NSLocalizedDescriptionKey: @"install_profile.json 缺少 path 和 version 字段，无法定位预打补丁核心 jar"}];
        }
        return NO;
    }

    // Write version JSON
    NSLog(@"[NeoForgeDirect] Writing version JSON to: %@", versionJsonPath);
    reportProgress(0.9, @"正在写入版本 JSON");
    NSError *writeError = saveJSONToFile(versionJson, versionJsonPath);
    if (writeError) {
        if (error) {
            *error = [NSError errorWithDomain:NeoForgeDirectInstallerErrorDomain
                                         code:NeoForgeDirectInstallerErrorWriteFailed
                                     userInfo:@{NSLocalizedDescriptionKey: [NSString stringWithFormat:@"Failed to write version JSON: %@", writeError.localizedDescription]}];
        }
        return NO;
    }
    NSLog(@"[NeoForgeDirect] Version JSON written successfully");

    NSLog(@"[NeoForgeDirect] installNewFormat completed");
    return YES;
}

#pragma mark - Helpers

// 游戏目录：与 JavaLauncher.m 中 [launchTarget isKindOfClass:NSDictionary.class] 分支保持一致
// 即 $POJAV_HOME/instances/<general.game_directory>/<profile.gameDir>
// 但直装时还没有 profile，无法读 gameDir，使用默认 "."
+ (NSString *)gameDirectory {
    const char *env = getenv("POJAV_GAME_DIR");
    if (env) {
        return [@(env) stringByStandardizingPath];
    }
    return NSHomeDirectory();
}

+ (void)registerVersion:(NSString *)versionId {
    NSLog(@"[NeoForgeDirect] registerVersion called: %@", versionId);
    PLProfiles *profiles = [PLProfiles current];
    NSLog(@"[NeoForgeDirect] PLProfiles current: %@", profiles ? @"ok" : @"nil");
    NSMutableDictionary *profileDict = [NSMutableDictionary dictionary];
    profileDict[@"name"] = versionId;
    profileDict[@"lastVersionId"] = versionId;
    // 改回原来的"游戏目录切换"机制：所有版本共享根目录（gameDir="."）
    // 用户通过设置中的"游戏目录切换"功能手动切换不同的 gameDir
    profileDict[@"gameDir"] = @".";
    profileDict[@"type"] = @"custom";
    profileDict[@"created"] = [NSDate date].description;
    // 推断 Java 版本：NeoForge 1.20.5+ 需 Java 21，1.18+ 需 Java 17，1.17 需 Java 16
    NSInteger javaMajor = [self inferJavaMajorVersionFromVersionId:versionId];
    // 写入 NSString 而非 NSDictionary，与 ProfileSettingsViewController 等所有读取方一致
    // JavaLauncher 通过 .intValue 读取，"17".intValue = 17
    profileDict[@"javaVersion"] = [NSString stringWithFormat:@"%ld", (long)javaMajor];
    [profiles saveProfile:profileDict withName:versionId];
    // 与 Fabric / Vanilla 安装路径保持一致：自动选中新建的 profile，避免用户回到主界面仍启动旧版本
    profiles.selectedProfileName = versionId;
    NSLog(@"[NeoForgeDirect] Profile saved and selected (javaVersion=%ld, gameDir=%@)", (long)javaMajor, profileDict[@"gameDir"]);
}

/// 从 versionId 中推断所需 Java 主版本号
/// versionId 可能为两种格式：
///   - 整合包路径: "{mc}-neoforge-{loader}"，如 "1.20.1-neoforge-47.1.0"、"1.21.5-neoforge-21.5.75"
///   - UI 路径: "NeoForge-{loader}"，如 "NeoForge-47.1.0"、"NeoForge-21.5.75"
/// 需兼顾两种格式，先尝试直接匹配 MC 版本，失败则从 NeoForge loader 版本号反推 MC 版本
+ (NSInteger)inferJavaMajorVersionFromVersionId:(NSString *)versionId {
    // 1. 先尝试匹配 "1.x.x" 格式的 MC 版本（覆盖整合包路径，以及 UI 路径中可能含 1.x.x 的边界情况）
    //    使用锚定开头（^|[-_]) 避免误匹配 loader 版本号中的 "1.x" 子串
    NSRegularExpression *regex = [NSRegularExpression regularExpressionWithPattern:@"(?:^|[-_])1\\.(\\d+)(?:\\.(\\d+))?"
                                                                           options:0
                                                                             error:nil];
    NSTextCheckingResult *match = [regex firstMatchInString:versionId options:0 range:NSMakeRange(0, versionId.length)];
    if (match && match.numberOfRanges >= 2) {
        NSString *minorStr = [versionId substringWithRange:[match rangeAtIndex:1]];
        NSInteger minor = [minorStr integerValue];
        NSString *patchStr = (match.numberOfRanges >= 3 && [match rangeAtIndex:2].location != NSNotFound)
                            ? [versionId substringWithRange:[match rangeAtIndex:2]]
                            : @"0";
        NSInteger patch = [patchStr integerValue];
        if (minor >= 21) return 21;                  // 1.21+
        if (minor >= 20 && patch >= 5) return 21;    // 1.20.5+
        if (minor >= 18) return 17;                  // 1.18 - 1.20.4
        if (minor >= 17) return 17;                  // 1.17（NeoForge 最低 17，Java 17 可向后兼容运行 1.17）
        return 17;                                    // 1.16 及以下（NeoForge 不支持，但保守返回 17）
    }

    // 2. 匹配失败时（UI 路径 versionId = "NeoForge-{loader}"），从 NeoForge loader 版本号反推 MC 版本
    //    NeoForge 版本号约定：
    //      - 47.x.y         → MC 1.20.1（legacy forge artifactId）→ Java 17
    //      - 20.2.x - 20.4.x → MC 1.20.2-1.20.4                     → Java 17
    //      - 20.5.x - 20.6.x → MC 1.20.5-1.20.6                     → Java 21
    //      - 21.x.x          → MC 1.21.x                            → Java 21
    //      - 26.x.x+         → MC 1.26.x+（未来版本）               → Java 21
    NSString *loaderVersion = [self extractNeoForgeLoaderVersionFromVersionId:versionId];
    if (loaderVersion.length > 0) {
        NSArray *parts = [loaderVersion componentsSeparatedByString:@"."];
        if (parts.count >= 2) {
            NSInteger major = [parts[0] integerValue];
            NSInteger minor = (parts.count >= 2) ? [parts[1] integerValue] : 0;
            // 47.x（1.20.1 legacy）→ Java 17
            if (major == 47) return 17;
            // 20.x 系列：20.5+ → Java 21，20.2-20.4 → Java 17
            if (major == 20) {
                return (minor >= 5) ? 21 : 17;
            }
            // 21.x 及以上（1.21+）→ Java 21
            if (major >= 21) return 21;
        }
    }

    return 17; // NeoForge 最低 Java 17
}

/// 从 versionId 中提取 NeoForge loader 版本号
/// "NeoForge-21.5.75" → "21.5.75"
/// "1.20.1-neoforge-47.1.0" → "47.1.0"
/// "1.21.5-neoforge-21.5.75-beta" → "21.5.75-beta"
+ (NSString *)extractNeoForgeLoaderVersionFromVersionId:(NSString *)versionId {
    if (!versionId.length) return @"";
    // 整合包路径格式: "{mc}-neoforge-{loader}"
    NSString *marker = @"-neoforge-";
    NSRange markerRange = [versionId rangeOfString:marker options:NSCaseInsensitiveSearch];
    if (markerRange.location != NSNotFound) {
        return [versionId substringFromIndex:markerRange.location + markerRange.length];
    }
    // UI 路径格式: "NeoForge-{loader}"
    NSRange dashRange = [versionId rangeOfString:@"-"];
    if (dashRange.location != NSNotFound) {
        return [versionId substringFromIndex:dashRange.location + dashRange.length];
    }
    return versionId;
}

#pragma mark - Maven entry Extraction

// 解压 installer.jar 内 maven/ 目录下所有文件到 libraries 目录
// 返回成功解压的文件数
+ (NSUInteger)extractAllMavenEntries:(NSString *)installerPath toLibrariesDir:(NSString *)librariesDir {
    NSError *openError = nil;
    UZKArchive *archive = [[UZKArchive alloc] initWithPath:installerPath error:&openError];
    if (!archive || openError) {
        NSLog(@"[NeoForgeDirect] extractAllMavenEntries: failed to open archive: %@", openError.localizedDescription ?: @"unknown");
        return 0;
    }

    NSError *listError = nil;
    NSArray<NSString *> *filenames = [archive listFilenames:&listError];
    if (!filenames || listError) {
        NSLog(@"[NeoForgeDirect] extractAllMavenEntries: failed to list filenames: %@", listError.localizedDescription ?: @"unknown");
        return 0;
    }

    NSUInteger count = 0;
    NSFileManager *fm = [NSFileManager defaultManager];
    for (NSString *name in filenames) {
        if (![name hasPrefix:@"maven/"]) continue;
        // 跳过目录条目（以 / 结尾），避免 extractDataFromFile 返回空数据产生误报日志
        if ([name hasSuffix:@"/"]) continue;

        NSString *relativePath = [name substringFromIndex:@"maven/".length];
        if (relativePath.length == 0) continue;

        NSString *destPath = [librariesDir stringByAppendingPathComponent:relativePath];
        // 已存在的文件跳过，避免重复解压（重复安装场景）
        if ([fm fileExistsAtPath:destPath]) {
            count++;
            continue;
        }

        // 直接用已打开的 archive 实例提取，避免每个文件都重新打开 zip（性能优化）
        NSError *extractError = nil;
        NSData *data = [archive extractDataFromFile:name error:&extractError];
        if (!data || extractError) {
            NSLog(@"[NeoForgeDirect] extractAllMavenEntries: failed to extract %@: %@", name, extractError.localizedDescription ?: @"unknown");
            continue;
        }

        // 创建目标目录
        NSString *destDir = [destPath stringByDeletingLastPathComponent];
        [fm createDirectoryAtPath:destDir withIntermediateDirectories:YES attributes:nil error:nil];

        // 写入文件
        NSError *writeError = nil;
        if (![data writeToFile:destPath options:NSDataWritingAtomic error:&writeError]) {
            NSLog(@"[NeoForgeDirect] extractAllMavenEntries: failed to write %@: %@", destPath, writeError.localizedDescription ?: @"unknown");
            continue;
        }
        count++;
    }
    return count;
}

#pragma mark - Library Download

// 下载 version.json.libraries 中尚未存在的库
+ (void)downloadMissingLibraries:(NSArray *)libraries
                   librariesDir:(NSString *)librariesDir
                       progress:(void (^)(double, NSString *))progress
                   baseProgress:(double)base
                  progressSpan:(double)span {
    NSUInteger total = libraries.count;
    if (total == 0) return;

    NSFileManager *fm = [NSFileManager defaultManager];
    NSUInteger downloaded = 0;
    NSUInteger skipped = 0;
    NSUInteger failed = 0;
    NSUInteger processed = 0;  // 已处理数（用于进度计算，包含成功/跳过/失败）
    NSMutableArray<NSString *> *criticalFailures = [NSMutableArray array];  // 关键库失败清单

    for (NSDictionary *library in libraries) {
        if (![library isKindOfClass:[NSDictionary class]]) continue;

        NSString *name = [library[@"name"] isKindOfClass:[NSString class]] ? library[@"name"] : nil;
        if (!name) continue;

        // 解析目标路径
        NSString *relativePath = nil;
        NSDictionary *downloads = library[@"downloads"];
        if ([downloads isKindOfClass:[NSDictionary class]]) {
            NSDictionary *artifact = downloads[@"artifact"];
            if ([artifact isKindOfClass:[NSDictionary class]]) {
                id artifactPathObj = artifact[@"path"];
                if ([artifactPathObj isKindOfClass:[NSString class]] && [(NSString *)artifactPathObj length] > 0) {
                    relativePath = (NSString *)artifactPathObj;
                }
            }
        }
        if (!relativePath) {
            relativePath = [self mavenPathToRelativePath:name];
        }
        if (relativePath.length == 0) continue;

        NSString *destPath = [librariesDir stringByAppendingPathComponent:relativePath];

        // 已存在则跳过
        if ([fm fileExistsAtPath:destPath]) {
            skipped++;
            processed++;
            continue;
        }

        // 拼 URL
        NSString *url = nil;
        if ([downloads isKindOfClass:[NSDictionary class]]) {
            NSDictionary *artifact = downloads[@"artifact"];
            if ([artifact isKindOfClass:[NSDictionary class]]) {
                id urlObj = artifact[@"url"];
                if ([urlObj isKindOfClass:[NSString class]] && [(NSString *)urlObj length] > 0) {
                    url = (NSString *)urlObj;
                }
            }
        }
        if (!url) {
            url = [self buildMavenURLForLibrary:name relativePath:relativePath];
        }

        if (!url) {
            NSLog(@"[NeoForgeDirect] Cannot build URL for library %@, skipping", name);
            failed++;
            processed++;
            continue;
        }

        // 用 processed 计算进度（避免失败时进度停滞）
        if (progress) {
            double p = base + span * ((double)processed / (double)total);
            progress(p, [NSString stringWithFormat:@"正在下载依赖库 (%lu/%lu): %@", (unsigned long)(processed + 1), (unsigned long)total, name]);
        }

        NSError *downloadError = nil;
        if ([self downloadFileFromURL:url toPath:destPath error:&downloadError]) {
            downloaded++;
            NSLog(@"[NeoForgeDirect] Downloaded library: %@", name);
        } else {
            // 主源失败：尝试 fallback 源
            NSLog(@"[NeoForgeDirect] Primary source failed for %@, trying fallback: %@", name, downloadError.localizedDescription ?: @"unknown");
            NSString *fallbackURL = [self buildFallbackURLForLibrary:name relativePath:relativePath];
            if (fallbackURL && ![fallbackURL isEqualToString:url]) {
                NSError *fallbackError = nil;
                if ([self downloadFileFromURL:fallbackURL toPath:destPath error:&fallbackError]) {
                    downloaded++;
                    NSLog(@"[NeoForgeDirect] Downloaded library via fallback: %@", name);
                    processed++;
                    continue;
                }
                NSLog(@"[NeoForgeDirect] Fallback also failed for %@: %@", name, fallbackError.localizedDescription ?: @"unknown");
            }
            failed++;
            // 关键库失败会启动崩溃，记录警告
            if ([self isCriticalLibrary:name]) {
                [criticalFailures addObject:name];
                NSLog(@"[NeoForgeDirect] ⚠️ 关键库下载失败（启动将崩溃）: %@", name);
            } else {
                NSLog(@"[NeoForgeDirect] Failed to download library %@ (both sources failed)", name);
            }
        }
        processed++;
    }

    NSLog(@"[NeoForgeDirect] Library download summary: downloaded=%lu, skipped=%lu, failed=%lu, total=%lu, criticalFailures=%lu",
          (unsigned long)downloaded, (unsigned long)skipped, (unsigned long)failed, (unsigned long)total, (unsigned long)criticalFailures.count);
    if (criticalFailures.count > 0) {
        NSLog(@"[NeoForgeDirect] ⚠️ 关键库下载失败清单: %@", criticalFailures);
    }
}

/// 判断是否为关键库（缺失会导致启动崩溃）
+ (BOOL)isCriticalLibrary:(NSString *)name {
    if (!name.length) return NO;
    NSArray<NSString *> *criticalPrefixes = @[
        @"cpw.mods:modlauncher",
        @"net.minecraftforge.bootstraplauncher",
        @"net.minecraftforge:forge",
        @"net.neoforged:forge",
        @"net.neoforged:neoforge",
        @"net.neoforged.fancymodloader",
        @"org.spongepowered:mixin",
        @"org.ow2.asm:asm",
        @"com.google.guava:guava",
        @"com.google.code.gson:gson",
        @"org.lwjgl:lwjgl",
        @"com.mojang:authlib",
        @"com.mojang:brigadier",
        @"com.mojang:datafixerupper",
        @"com.mojang:minecraft"
    ];
    for (NSString *prefix in criticalPrefixes) {
        if ([name hasPrefix:prefix]) return YES;
    }
    return NO;
}

// 为 library 构建 maven URL
// 优化路由：根据 groupId 精确匹配到正确的 maven 仓库，避免 404
+ (NSString *)buildMavenURLForLibrary:(NSString *)name relativePath:(NSString *)relativePath {
    NSString *downloadSource = getPrefObject(@"general.download_source");
    BOOL useBMCLAPI = [downloadSource isEqualToString:@"bmclapi"];

    // NeoForge 自家库走 maven.neoforged.net/releases
    if ([name hasPrefix:@"net.neoforged:"] || [name hasPrefix:@"net.neoforged."] || [name hasPrefix:@"cpw.mods:"]) {
        if (useBMCLAPI) {
            return [NSString stringWithFormat:@"https://bmclapi2.bangbang93.com/maven/%@", relativePath];
        }
        return [NSString stringWithFormat:@"https://maven.neoforged.net/releases/%@", relativePath];
    }

    // Forge 自家库走 maven.minecraftforge.net
    if ([name hasPrefix:@"net.minecraftforge:"]) {
        if (useBMCLAPI) {
            return [NSString stringWithFormat:@"https://bmclapi2.bangbang93.com/maven/%@", relativePath];
        }
        return [NSString stringWithFormat:@"https://maven.minecraftforge.net/%@", relativePath];
    }

    // SpongePowered (mixin 等) 走 repo.spongepowered.org
    if ([name hasPrefix:@"org.spongepowered:"]) {
        if (useBMCLAPI) {
            return [NSString stringWithFormat:@"https://bmclapi2.bangbang93.com/maven/%@", relativePath];
        }
        return [NSString stringWithFormat:@"https://repo.spongepowered.org/repository/maven-public/%@", relativePath];
    }

    // oceanlabs、asm 走 maven.minecraftforge.net
    if ([name hasPrefix:@"de.oceanlabs.mcp:"] || [name hasPrefix:@"org.ow2.asm:"]) {
        if (useBMCLAPI) {
            return [NSString stringWithFormat:@"https://bmclapi2.bangbang93.com/maven/%@", relativePath];
        }
        return [NSString stringWithFormat:@"https://maven.minecraftforge.net/%@", relativePath];
    }

    // 其他库（Mojang、lwjgl 等）走 libraries.minecraft.net（BMCLAPI 镜像）
    if (useBMCLAPI) {
        return [NSString stringWithFormat:@"https://bmclapi2.bangbang93.com/maven/%@", relativePath];
    }
    return [NSString stringWithFormat:@"https://libraries.minecraft.net/%@", relativePath];
}

/// 构建 fallback URL（当主源失败时切换到 BMCLAPI 镜像，或反之）
+ (NSString *)buildFallbackURLForLibrary:(NSString *)name relativePath:(NSString *)relativePath {
    NSString *downloadSource = getPrefObject(@"general.download_source");
    BOOL useBMCLAPI = [downloadSource isEqualToString:@"bmclapi"];

    if (useBMCLAPI) {
        // 从 BMCLAPI 失败，尝试官方源
        if ([name hasPrefix:@"net.neoforged:"] || [name hasPrefix:@"net.neoforged."] || [name hasPrefix:@"cpw.mods:"]) {
            return [NSString stringWithFormat:@"https://maven.neoforged.net/releases/%@", relativePath];
        }
        if ([name hasPrefix:@"net.minecraftforge:"] || [name hasPrefix:@"de.oceanlabs.mcp:"] || [name hasPrefix:@"org.ow2.asm:"]) {
            return [NSString stringWithFormat:@"https://maven.minecraftforge.net/%@", relativePath];
        }
        if ([name hasPrefix:@"org.spongepowered:"]) {
            return [NSString stringWithFormat:@"https://repo.spongepowered.org/repository/maven-public/%@", relativePath];
        }
        return [NSString stringWithFormat:@"https://libraries.minecraft.net/%@", relativePath];
    }
    // 从官方源失败，尝试 BMCLAPI 镜像
    return [NSString stringWithFormat:@"https://bmclapi2.bangbang93.com/maven/%@", relativePath];
}

// 下载预打补丁的 PATCHED artifact
// mainPath 格式："net.neoforged:forge:1.20.1-47.3.0"（旧 NeoForge）或 "net.neoforged:neoforge:21.5.75"（新 NeoForge）
// 对应 maven 上的 :client classifier jar：
//   官方源: https://maven.neoforged.net/releases/net/neoforged/{forge|neoforge}/{ver}/{forge|neoforge}-{ver}-client.jar
//   BMCLAPI: https://bmclapi2.bangbang93.com/maven/net/neoforged/{forge|neoforge}/{ver}/{forge|neoforge}-{ver}-client.jar
+ (BOOL)downloadPatchedArtifact:(NSString *)mainPath librariesDir:(NSString *)librariesDir error:(NSError **)error {
    NSArray *parts = [mainPath componentsSeparatedByString:@":"];
    if (parts.count < 3) {
        if (error) {
            *error = [NSError errorWithDomain:NeoForgeDirectInstallerErrorDomain
                                         code:NeoForgeDirectInstallerErrorInvalidProfile
                                     userInfo:@{NSLocalizedDescriptionKey: [NSString stringWithFormat:@"Invalid main path: %@", mainPath]}];
        }
        return NO;
    }

    NSString *groupId = parts[0];
    NSString *artifactId = parts[1];
    NSString *version = parts[2];

    NSString *groupPath = [groupId stringByReplacingOccurrencesOfString:@"." withString:@"/"];
    NSString *jarName = [NSString stringWithFormat:@"%@-%@-client.jar", artifactId, version];
    NSString *relativePath = [NSString stringWithFormat:@"%@/%@/%@/%@", groupPath, artifactId, version, jarName];
    NSString *destPath = [librariesDir stringByAppendingPathComponent:relativePath];

    // 已存在则跳过
    if ([NSFileManager.defaultManager fileExistsAtPath:destPath]) {
        NSLog(@"[NeoForgeDirect] Patched artifact already exists: %@", destPath);
        return YES;
    }

    // 拼 URL
    NSString *downloadSource = getPrefObject(@"general.download_source");
    BOOL useBMCLAPI = [downloadSource isEqualToString:@"bmclapi"];
    NSString *url;
    if ([groupId hasPrefix:@"net.neoforged"]) {
        if (useBMCLAPI) {
            url = [NSString stringWithFormat:@"https://bmclapi2.bangbang93.com/maven/%@", relativePath];
        } else {
            url = [NSString stringWithFormat:@"https://maven.neoforged.net/releases/%@", relativePath];
        }
    } else {
        // 兜底：当作 Forge 处理
        if (useBMCLAPI) {
            url = [NSString stringWithFormat:@"https://bmclapi2.bangbang93.com/maven/%@", relativePath];
        } else {
            url = [NSString stringWithFormat:@"https://maven.minecraftforge.net/%@", relativePath];
        }
    }

    NSLog(@"[NeoForgeDirect] Downloading patched artifact from: %@", url);
    NSError *downloadError = nil;
    if (![self downloadFileFromURL:url toPath:destPath error:&downloadError]) {
        // 主源失败：按顺序尝试多个 fallback 源，提升国内可用性
        NSMutableArray *fallbackURLs = [NSMutableArray array];
        if (useBMCLAPI) {
            // 从 BMCLAPI 失败：依次尝试官方源、腾讯云镜像
            if ([groupId hasPrefix:@"net.neoforged"]) {
                [fallbackURLs addObject:[NSString stringWithFormat:@"https://maven.neoforged.net/releases/%@", relativePath]];
            } else {
                [fallbackURLs addObject:[NSString stringWithFormat:@"https://maven.minecraftforge.net/%@", relativePath]];
            }
            [fallbackURLs addObject:[NSString stringWithFormat:@"https://mirrors.cloud.tencent.com/maven/%@", relativePath]];
        } else {
            // 从官方源失败：依次尝试 BMCLAPI、腾讯云镜像
            [fallbackURLs addObject:[NSString stringWithFormat:@"https://bmclapi2.bangbang93.com/maven/%@", relativePath]];
            [fallbackURLs addObject:[NSString stringWithFormat:@"https://mirrors.cloud.tencent.com/maven/%@", relativePath]];
        }
        NSLog(@"[NeoForgeDirect] Primary source failed, trying %lu fallback(s)", (unsigned long)fallbackURLs.count);
        NSError *lastError = downloadError;
        BOOL success = NO;
        for (NSString *fallbackURL in fallbackURLs) {
            NSLog(@"[NeoForgeDirect] Trying fallback: %@", fallbackURL);
            NSError *fallbackError = nil;
            if ([self downloadFileFromURL:fallbackURL toPath:destPath error:&fallbackError]) {
                NSLog(@"[NeoForgeDirect] Patched artifact downloaded via fallback: %@", destPath);
                success = YES;
                break;
            }
            lastError = fallbackError;
        }
        if (!success) {
            if (error) {
                *error = [NSError errorWithDomain:NeoForgeDirectInstallerErrorDomain
                                             code:NeoForgeDirectInstallerErrorExtractionFailed
                                         userInfo:@{
                                             NSLocalizedDescriptionKey: [NSString stringWithFormat:@"下载预打补丁核心 jar 失败: %@\n主源 URL: %@\n错误: %@\n备用源错误: %@",
                                                 jarName, url, downloadError.localizedDescription ?: @"未知错误",
                                                 lastError.localizedDescription ?: @"未知错误"]
                                         }];
            }
            return NO;
        }
        return YES;
    }
    NSLog(@"[NeoForgeDirect] Patched artifact downloaded: %@", destPath);
    return YES;
}

// 同步下载文件到指定路径（带 60 秒超时）
+ (BOOL)downloadFileFromURL:(NSString *)urlString toPath:(NSString *)destPath error:(NSError **)error {
    if (error) *error = nil;

    NSURL *url = [NSURL URLWithString:urlString];
    if (!url) {
        if (error) {
            *error = [NSError errorWithDomain:NeoForgeDirectInstallerErrorDomain
                                         code:NeoForgeDirectInstallerErrorWriteFailed
                                     userInfo:@{NSLocalizedDescriptionKey: [NSString stringWithFormat:@"Invalid URL: %@", urlString]}];
        }
        return NO;
    }

    NSString *destDir = [destPath stringByDeletingLastPathComponent];
    NSError *dirError = nil;
    [NSFileManager.defaultManager createDirectoryAtPath:destDir
                            withIntermediateDirectories:YES
                                             attributes:nil
                                                  error:&dirError];
    if (dirError) {
        if (error) {
            *error = [NSError errorWithDomain:NeoForgeDirectInstallerErrorDomain
                                         code:NeoForgeDirectInstallerErrorWriteFailed
                                     userInfo:@{NSLocalizedDescriptionKey: [NSString stringWithFormat:@"Failed to create directory %@: %@", destDir, dirError.localizedDescription]}];
        }
        return NO;
    }

    // 用 NSURLSession 同步下载，带 60 秒超时（避免弱网下 dataWithContentsOfURL 挂死）
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:url];
    request.timeoutInterval = 60.0;
    request.cachePolicy = NSURLRequestReloadIgnoringLocalCacheData;
    // 添加 User-Agent：部分 maven 仓库会拒绝无 UA 的请求（返回 403）
    [request setValue:@"AngelAuraAmethyst/1.0 (iOS; Minecraft Launcher)" forHTTPHeaderField:@"User-Agent"];
    [request setValue:@"application/java-archive,*/*;q=0.9" forHTTPHeaderField:@"Accept"];

    __block NSData *resultData = nil;
    __block NSError *resultError = nil;
    dispatch_semaphore_t semaphore = dispatch_semaphore_create(0);

    NSURLSessionDataTask *task = [[NSURLSession sharedSession] dataTaskWithRequest:request
                                                                     completionHandler:^(NSData *data, NSURLResponse *response, NSError *taskError) {
        if (taskError) {
            resultError = taskError;
        } else if ([response isKindOfClass:[NSHTTPURLResponse class]]) {
            NSInteger statusCode = [(NSHTTPURLResponse *)response statusCode];
            if (statusCode >= 400) {
                resultError = [NSError errorWithDomain:NeoForgeDirectInstallerErrorDomain
                                                   code:statusCode
                                               userInfo:@{NSLocalizedDescriptionKey: [NSString stringWithFormat:@"HTTP %ld: %@", (long)statusCode, urlString]}];
            } else {
                resultData = data;
            }
        } else {
            resultData = data;
        }
        dispatch_semaphore_signal(semaphore);
    }];
    [task resume];
    long waitResult = dispatch_semaphore_wait(semaphore, dispatch_time(DISPATCH_TIME_NOW, 70 * NSEC_PER_SEC));
    if (waitResult != 0) {
        // 信号量超时：取消 task 释放网络资源，避免后台 task 持续运行导致临时内存泄漏
        [task cancel];
        if (error) {
            *error = [NSError errorWithDomain:NeoForgeDirectInstallerErrorDomain
                                         code:NSURLErrorTimedOut
                                     userInfo:@{NSLocalizedDescriptionKey: [NSString stringWithFormat:@"下载超时（70s）: %@", urlString]}];
        }
        return NO;
    }

    if (resultError) {
        if (error) *error = resultError;
        return NO;
    }
    if (!resultData || resultData.length == 0) {
        if (error) {
            *error = [NSError errorWithDomain:NeoForgeDirectInstallerErrorDomain
                                         code:NeoForgeDirectInstallerErrorWriteFailed
                                     userInfo:@{NSLocalizedDescriptionKey: [NSString stringWithFormat:@"Empty response: %@", urlString]}];
        }
        return NO;
    }

    BOOL written = [resultData writeToFile:destPath options:NSDataWritingAtomic error:error];
    if (!written) {
        return NO;
    }

    NSLog(@"[NeoForgeDirect] Downloaded %@ (%lu bytes) -> %@", urlString.lastPathComponent ?: urlString, (unsigned long)resultData.length, destPath);
    return YES;
}

#pragma mark - ZIP / UnzipKit helpers

+ (NSData *)dataFromZip:(NSString *)zipPath entry:(NSString *)entryPath error:(NSError **)error {
    if (error) {
        *error = nil;
    }

    NSError *openError = nil;
    UZKArchive *archive = [[UZKArchive alloc] initWithPath:zipPath error:&openError];
    if (!archive || openError) {
        NSLog(@"[NeoForgeDirect] Failed to open archive: %@", openError.localizedDescription ?: @"unknown");
        if (error) {
            *error = [NSError errorWithDomain:NeoForgeDirectInstallerErrorDomain
                                         code:NeoForgeDirectInstallerErrorInvalidArchive
                                     userInfo:@{NSLocalizedDescriptionKey: [NSString stringWithFormat:@"Failed to open installer archive: %@", openError.localizedDescription ?: @"unknown"]}];
        }
        return nil;
    }

    NSError *extractError = nil;
    NSData *result = [archive extractDataFromFile:entryPath error:&extractError];
    if (!result) {
        // 部分版本 entry 路径带前导 "/"，尝试兼容
        if ([entryPath hasPrefix:@"/"]) {
            NSString *altPath = [entryPath substringFromIndex:1];
            result = [archive extractDataFromFile:altPath error:&extractError];
        }
    }
    if (!result) {
        NSLog(@"[NeoForgeDirect] Failed to extract entry '%@': %@", entryPath, extractError.localizedDescription ?: @"unknown");
        if (error) {
            *error = [NSError errorWithDomain:NeoForgeDirectInstallerErrorDomain
                                         code:NeoForgeDirectInstallerErrorExtractionFailed
                                     userInfo:@{NSLocalizedDescriptionKey: [NSString stringWithFormat:@"Failed to extract %@: %@", entryPath, extractError.localizedDescription ?: @"not found"]}];
        }
        return nil;
    }

    NSLog(@"[NeoForgeDirect] Extracted entry '%@' (%lu bytes)", entryPath, (unsigned long)result.length);
    return result;
}

+ (BOOL)entryExists:(NSString *)zipPath entry:(NSString *)entryPath {
    NSError *openError = nil;
    UZKArchive *archive = [[UZKArchive alloc] initWithPath:zipPath error:&openError];
    if (!archive || openError) {
        return NO;
    }

    NSError *listError = nil;
    NSArray<NSString *> *filenames = [archive listFilenames:&listError];
    if (!filenames || listError) {
        return NO;
    }

    for (NSString *name in filenames) {
        if ([name isEqualToString:entryPath]) {
            return YES;
        }
    }
    return NO;
}

+ (BOOL)extractFile:(NSString *)zipPath entry:(NSString *)entryPath to:(NSString *)destPath error:(NSError **)error {
    if (error) {
        *error = nil;
    }

    NSData *data = [self dataFromZip:zipPath entry:entryPath error:error];
    if (!data) {
        if (error && !*error) {
            *error = [NSError errorWithDomain:NeoForgeDirectInstallerErrorDomain
                                         code:NeoForgeDirectInstallerErrorExtractionFailed
                                     userInfo:@{NSLocalizedDescriptionKey: [NSString stringWithFormat:@"Failed to extract %@ from installer", entryPath]}];
        }
        return NO;
    }

    NSString *destDir = [destPath stringByDeletingLastPathComponent];
    NSError *dirError = nil;
    [[NSFileManager defaultManager] createDirectoryAtPath:destDir
                              withIntermediateDirectories:YES
                                               attributes:nil
                                                    error:&dirError];
    if (dirError) {
        NSLog(@"[NeoForgeDirect] Failed to create directory '%@': %@", destDir, dirError.localizedDescription);
        if (error) {
            *error = [NSError errorWithDomain:NeoForgeDirectInstallerErrorDomain
                                         code:NeoForgeDirectInstallerErrorWriteFailed
                                     userInfo:@{NSLocalizedDescriptionKey: [NSString stringWithFormat:@"Failed to create directory %@: %@", destDir, dirError.localizedDescription]}];
        }
        return NO;
    }

    BOOL written = [data writeToFile:destPath options:NSDataWritingAtomic error:error];
    if (!written) {
        NSLog(@"[NeoForgeDirect] Failed to write file '%@'", destPath);
        if (error && !*error) {
            *error = [NSError errorWithDomain:NeoForgeDirectInstallerErrorDomain
                                         code:NeoForgeDirectInstallerErrorWriteFailed
                                     userInfo:@{NSLocalizedDescriptionKey: [NSString stringWithFormat:@"Failed to write %@", destPath]}];
        }
        return NO;
    }

    NSLog(@"[NeoForgeDirect] Written file '%@' (%lu bytes)", destPath, (unsigned long)data.length);
    return YES;
}

#pragma mark - Maven path utilities

+ (NSString *)mavenPathToRelativePath:(NSString *)mavenPath {
    NSArray *parts = [mavenPath componentsSeparatedByString:@":"];
    if (parts.count < 3) {
        return mavenPath;
    }

    NSString *groupId = parts[0];
    NSString *artifactId = parts[1];
    NSString *version = parts[2];
    NSString *classifier = (parts.count > 3) ? parts[3] : nil;

    NSString *groupPath = [groupId stringByReplacingOccurrencesOfString:@"." withString:@"/"];
    NSString *jarName;
    if (classifier.length > 0) {
        jarName = [NSString stringWithFormat:@"%@-%@-%@.jar", artifactId, version, classifier];
    } else {
        jarName = [NSString stringWithFormat:@"%@-%@.jar", artifactId, version];
    }

    return [NSString stringWithFormat:@"%@/%@/%@/%@", groupPath, artifactId, version, jarName];
}

+ (NSString *)mavenNameToPath:(NSString *)name {
    return [self mavenPathToRelativePath:name];
}

@end
