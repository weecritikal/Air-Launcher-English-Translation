//
//  ForgeDirectInstaller.m
//  Amethyst
//
//  Direct Forge installer (old + new format) based on FCL logic.
//
//  本直装器采用"下载预打补丁 PATCHED artifact"方案，不执行 install_profile.json 的 processors。
//  原因：iOS 沙箱禁止 fork/exec，无法 spawn 子 JVM 执行 processor 工具（binarypatcher、
//  jarsplitter、SpecialSource 等）。社区启动器在受限平台的通用做法是直接从 maven 下载
//  Forge/NeoForge 已发布的预打补丁 client jar（如 forge-{mc}-{loader}-client.jar），
//  这等同于 processor 的输出产物，运行时直接可用。
//
//  JarJar（JarInJar）机制是运行期由 modlauncher 的 JarInJarDependencyLocator 处理，
//  安装期无需任何 processor 介入。
//
//  1.12.2 及以下旧格式 Forge 没有 processors，直装直接放 universal jar + version.json 即可。
//

#import "ForgeDirectInstaller.h"
#import "PLProfiles.h"
#import "utils.h"
#import "LauncherPreferences.h"
#import "external/UnzipKit/UZKArchive.h"

NSString *const ForgeDirectInstallerErrorDomain = @"ForgeDirectInstallerErrorDomain";

@implementation ForgeDirectInstaller

#pragma mark - Public

+ (BOOL)installForgeFromInstaller:(NSString *)installerPath
                        versionId:(NSString *)versionId
                            error:(NSError **)error {
    return [self installForgeFromInstaller:installerPath versionId:versionId progress:nil error:error];
}

+ (BOOL)installForgeFromInstaller:(NSString *)installerPath
                        versionId:(NSString *)versionId
                          progress:(void (^)(double progress, NSString *stageMessage))progress
                            error:(NSError **)error {
    void (^reportProgress)(double, NSString *) = ^(double p, NSString *msg) {
        NSLog(@"[ForgeDirect] Progress: %.2f - %@", p, msg);
        if (progress) {
            progress(p, msg);
        }
    };

    @try {
        NSLog(@"[ForgeDirect] Starting installation: %@", versionId);
        reportProgress(0.0, @"开始安装");
        if (error) {
            *error = nil;
        }

        // Step 1 & 2: Open jar as ZIP and read install_profile.json
        NSLog(@"[ForgeDirect] Reading install_profile.json");
        reportProgress(0.05, @"正在读取 install_profile.json");
        NSData *profileData = [self dataFromZip:installerPath entry:@"install_profile.json" error:error];
        if (!profileData) {
            NSLog(@"[ForgeDirect] Failed to read install_profile.json");
            if (error && !*error) {
                *error = [NSError errorWithDomain:ForgeDirectInstallerErrorDomain
                                             code:ForgeDirectInstallerErrorMissingProfile
                                         userInfo:@{NSLocalizedDescriptionKey: @"Missing install_profile.json in installer"}];
            }
            return NO;
        }
        NSLog(@"[ForgeDirect] Successfully read install_profile.json (%lu bytes)", (unsigned long)profileData.length);

        // Step 3: Parse install_profile.json
        NSLog(@"[ForgeDirect] Parsing install_profile.json");
        reportProgress(0.1, @"正在解析 JSON 并检测格式");
        NSError *jsonError = nil;
        NSMutableDictionary *installProfile = [NSJSONSerialization JSONObjectWithData:profileData
                                                                              options:NSJSONReadingMutableContainers
                                                                                error:&jsonError];
        NSLog(@"[ForgeDirect] JSON parsing completed, error=%@", jsonError ?: @"none");
        if (![installProfile isKindOfClass:[NSDictionary class]] || jsonError) {
            if (error) {
                *error = [NSError errorWithDomain:ForgeDirectInstallerErrorDomain
                                             code:ForgeDirectInstallerErrorInvalidProfile
                                         userInfo:@{NSLocalizedDescriptionKey: @"Failed to parse install_profile.json"}];
            }
            return NO;
        }

        // Step 4: Determine format
        NSLog(@"[ForgeDirect] Detecting installer format");
        BOOL isNewFormat = (installProfile[@"spec"] != nil);
        BOOL isOldFormat = (installProfile[@"install"] != nil && installProfile[@"versionInfo"] != nil);
        NSLog(@"[ForgeDirect] Format detection: new=%d, old=%d", isNewFormat, isOldFormat);

        if (!isNewFormat && !isOldFormat) {
            if (error) {
                *error = [NSError errorWithDomain:ForgeDirectInstallerErrorDomain
                                             code:ForgeDirectInstallerErrorInvalidProfile
                                         userInfo:@{NSLocalizedDescriptionKey: @"Unknown install_profile format"}];
            }
            return NO;
        }

        NSString *gameDir = [self gameDirectory];
        NSString *librariesDir = [gameDir stringByAppendingPathComponent:@"libraries"];
        NSLog(@"[ForgeDirect] Game directory: %@", gameDir);
        NSLog(@"[ForgeDirect] Libraries directory: %@", librariesDir);
        reportProgress(0.15, @"正在准备版本目录");

        // 提前创建 libraries 目录，避免后续下载/解压失败
        [[NSFileManager defaultManager] createDirectoryAtPath:librariesDir
                                  withIntermediateDirectories:YES
                                                   attributes:nil
                                                        error:nil];

        BOOL success = NO;
        if (isOldFormat) {
            NSLog(@"[ForgeDirect] Using old format installer");
            success = [self installOldFormat:installProfile
                               installerPath:installerPath
                                   versionId:versionId
                                    gameDir:gameDir
                               librariesDir:librariesDir
                                    progress:progress
                                      error:error];
        } else {
            NSLog(@"[ForgeDirect] Using new format installer");
            success = [self installNewFormat:installProfile
                               installerPath:installerPath
                                   versionId:versionId
                                    gameDir:gameDir
                               librariesDir:librariesDir
                                    progress:progress
                                      error:error];
        }

        if (!success) {
            NSLog(@"[ForgeDirect] Installation failed");
            return NO;
        }

        // Step 7: Register version in launcher_profiles.json (must run on main thread)
        NSLog(@"[ForgeDirect] Registering version on main thread");
        reportProgress(0.95, @"正在注册版本");
        if ([NSThread isMainThread]) {
            [self registerVersion:versionId];
        } else {
            dispatch_sync(dispatch_get_main_queue(), ^{
                [self registerVersion:versionId];
            });
        }
        NSLog(@"[ForgeDirect] Version registered successfully");

        NSLog(@"[ForgeDirect] Installation completed successfully");
        reportProgress(1.0, @"安装完成");
        return YES;
    }
    @catch (NSException *exception) {
        NSString *stack = [exception.callStackSymbols componentsJoinedByString:@"\n"];
        NSLog(@"[ForgeDirect] EXCEPTION: name=%@, reason=%@, callStack=%@", exception.name, exception.reason, stack);
        if (error) {
            *error = [NSError errorWithDomain:ForgeDirectInstallerErrorDomain
                                          code:ForgeDirectInstallerErrorException
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
    NSLog(@"[ForgeDirect] registerVersion called: %@", versionId);
    PLProfiles *profiles = [PLProfiles current];
    NSLog(@"[ForgeDirect] PLProfiles current: %@", profiles ? @"ok" : @"nil");
    NSMutableDictionary *profileDict = [NSMutableDictionary dictionary];
    profileDict[@"name"] = versionId;
    profileDict[@"lastVersionId"] = versionId;
    // gameDir 使用 "."，与 JavaLauncher 拼装逻辑一致：
    // JavaLauncher: gameDir = $POJAV_HOME/instances/<general.game_directory>/<profile.gameDir>
    // 当 profile.gameDir="." 时，最终 gameDir = $POJAV_HOME/instances/<general.game_directory>
    // 这与 POJAV_GAME_DIR 默认值一致，确保启动时读到的 versions/libraries 与直装写入的目录相同
    profileDict[@"gameDir"] = @".";
    profileDict[@"type"] = @"custom";
    profileDict[@"created"] = [NSDate date].description;
    [profiles saveProfile:profileDict withName:versionId];
    // 与 Fabric / Vanilla 安装路径保持一致：自动选中新建的 profile，避免用户回到主界面仍启动旧版本
    profiles.selectedProfileName = versionId;
    NSLog(@"[ForgeDirect] Profile saved and selected");
}

#pragma mark - Old format (Forge 1.12.2-)

+ (BOOL)installOldFormat:(NSDictionary *)installProfile
           installerPath:(NSString *)installerPath
               versionId:(NSString *)versionId
                gameDir:(NSString *)gameDir
            librariesDir:(NSString *)librariesDir
                progress:(void (^)(double, NSString *))progress
                  error:(NSError **)error {
    NSLog(@"[ForgeDirect] installOldFormat started");
    void (^reportProgress)(double, NSString *) = ^(double p, NSString *msg) {
        NSLog(@"[ForgeDirect] Progress: %.2f - %@", p, msg);
        if (progress) {
            progress(p, msg);
        }
    };

    NSDictionary *versionInfo = installProfile[@"versionInfo"];
    if (![versionInfo isKindOfClass:[NSDictionary class]]) {
        if (error) {
            *error = [NSError errorWithDomain:ForgeDirectInstallerErrorDomain
                                         code:ForgeDirectInstallerErrorInvalidProfile
                                     userInfo:@{NSLocalizedDescriptionKey: @"Missing versionInfo in install_profile.json"}];
        }
        return NO;
    }

    NSMutableDictionary *mutableVersionInfo = [versionInfo mutableCopy];
    mutableVersionInfo[@"id"] = versionId;

    // Prepare version directory
    NSString *versionDir = [gameDir stringByAppendingPathComponent:[NSString stringWithFormat:@"versions/%@", versionId]];
    NSString *versionJsonPath = [versionDir stringByAppendingPathComponent:[NSString stringWithFormat:@"%@.json", versionId]];
    NSLog(@"[ForgeDirect] Version directory: %@", versionDir);
    [[NSFileManager defaultManager] createDirectoryAtPath:versionDir
                              withIntermediateDirectories:YES
                                               attributes:nil
                                                    error:nil];

    // Extract universal jar
    NSLog(@"[ForgeDirect] Extracting universal jar");
    reportProgress(0.4, @"正在提取 libraries (1/1)");
    NSDictionary *installDict = installProfile[@"install"];
    id filePathObj = installDict[@"filePath"];
    id mavenPathObj = installDict[@"path"];
    NSString *filePath = [filePathObj isKindOfClass:[NSString class]] ? filePathObj : nil;
    NSString *mavenPath = [mavenPathObj isKindOfClass:[NSString class]] ? mavenPathObj : nil;

    if (filePath.length > 0) {
        NSString *destPath;
        if (mavenPath.length > 0) {
            destPath = [librariesDir stringByAppendingPathComponent:[self mavenPathToRelativePath:mavenPath]];
        } else {
            destPath = [versionDir stringByAppendingPathComponent:[filePath lastPathComponent]];
        }
        NSLog(@"[ForgeDirect] Extracting universal jar to: %@", destPath);

        if (![self extractFile:installerPath entry:filePath to:destPath error:error]) {
            return NO;
        }
        NSLog(@"[ForgeDirect] Universal jar extracted successfully");
    }
    reportProgress(0.7, @"正在提取 libraries (1/1)");

    // 老格式也需要解压 installer.jar 内 maven/ 下的所有依赖
    // 老版本 Forge 通常 libraries 是运行时从 Maven 下载的，但 installer.jar 内可能也带了一部分
    reportProgress(0.75, @"正在解压内嵌 maven 依赖");
    [self extractAllMavenEntries:installerPath toLibrariesDir:librariesDir];

    // 下载 versionInfo.libraries 中缺失的库（老格式也可能有 libraries 数组）
    NSArray *libs = mutableVersionInfo[@"libraries"];
    if ([libs isKindOfClass:[NSArray class]] && libs.count > 0) {
        reportProgress(0.8, @"正在下载缺失的依赖库");
        [self downloadMissingLibraries:libs librariesDir:librariesDir progress:progress baseProgress:0.8 progressSpan:0.1];
    }

    // Write version JSON
    NSLog(@"[ForgeDirect] Writing version JSON to: %@", versionJsonPath);
    reportProgress(0.9, @"正在写入版本 JSON");
    NSError *writeError = saveJSONToFile(mutableVersionInfo, versionJsonPath);
    if (writeError) {
        if (error) {
            *error = [NSError errorWithDomain:ForgeDirectInstallerErrorDomain
                                         code:ForgeDirectInstallerErrorWriteFailed
                                     userInfo:@{NSLocalizedDescriptionKey: [NSString stringWithFormat:@"Failed to write version JSON: %@", writeError.localizedDescription]}];
        }
        return NO;
    }
    NSLog(@"[ForgeDirect] Version JSON written successfully");

    NSLog(@"[ForgeDirect] installOldFormat completed");
    return YES;
}

#pragma mark - New format (Forge 1.13+)

+ (BOOL)installNewFormat:(NSDictionary *)installProfile
           installerPath:(NSString *)installerPath
               versionId:(NSString *)versionId
                gameDir:(NSString *)gameDir
            librariesDir:(NSString *)librariesDir
                progress:(void (^)(double, NSString *))progress
                  error:(NSError **)error {
    NSLog(@"[ForgeDirect] installNewFormat started");
    void (^reportProgress)(double, NSString *) = ^(double p, NSString *msg) {
        NSLog(@"[ForgeDirect] Progress: %.2f - %@", p, msg);
        if (progress) {
            progress(p, msg);
        }
    };

    // Read version.json
    NSLog(@"[ForgeDirect] Reading version.json");
    NSString *versionJsonEntry = installProfile[@"json"];
    if (!versionJsonEntry || ![versionJsonEntry isKindOfClass:[NSString class]]) {
        versionJsonEntry = @"version.json";
    }
    // version.json 路径可能以 "/" 开头，统一去掉
    if ([versionJsonEntry hasPrefix:@"/"]) {
        versionJsonEntry = [versionJsonEntry substringFromIndex:1];
    }
    NSLog(@"[ForgeDirect] version.json entry: %@", versionJsonEntry);

    NSData *versionData = [self dataFromZip:installerPath entry:versionJsonEntry error:error];
    if (!versionData) {
        if (error && !*error) {
            *error = [NSError errorWithDomain:ForgeDirectInstallerErrorDomain
                                         code:ForgeDirectInstallerErrorMissingProfile
                                     userInfo:@{NSLocalizedDescriptionKey: @"Missing version.json in installer"}];
        }
        return NO;
    }
    NSLog(@"[ForgeDirect] Successfully read version.json (%lu bytes)", (unsigned long)versionData.length);

    NSLog(@"[ForgeDirect] Parsing version.json");
    NSMutableDictionary *versionJson = [NSJSONSerialization JSONObjectWithData:versionData
                                                                       options:NSJSONReadingMutableContainers
                                                                         error:nil];
    if (![versionJson isKindOfClass:[NSDictionary class]]) {
        if (error) {
            *error = [NSError errorWithDomain:ForgeDirectInstallerErrorDomain
                                         code:ForgeDirectInstallerErrorInvalidProfile
                                     userInfo:@{NSLocalizedDescriptionKey: @"Failed to parse version.json"}];
        }
        return NO;
    }
    NSLog(@"[ForgeDirect] version.json parsed successfully");

    versionJson[@"id"] = versionId;

    // Merge libraries from install_profile into versionJson (dedup by name)
    NSLog(@"[ForgeDirect] Merging libraries");
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
        NSLog(@"[ForgeDirect] Merged libraries: added %lu, skipped %lu duplicates", (unsigned long)addedCount, (unsigned long)skippedCount);
        versionJson[@"libraries"] = mergedLibraries;
    }

    // Prepare version directory
    NSString *versionDir = [gameDir stringByAppendingPathComponent:[NSString stringWithFormat:@"versions/%@", versionId]];
    NSString *versionJsonPath = [versionDir stringByAppendingPathComponent:[NSString stringWithFormat:@"%@.json", versionId]];
    NSLog(@"[ForgeDirect] Version directory: %@", versionDir);
    [[NSFileManager defaultManager] createDirectoryAtPath:versionDir
                              withIntermediateDirectories:YES
                                               attributes:nil
                                                    error:nil];

    // Step A: 解压 installer.jar 内 maven/ 下的所有依赖到 libraries 目录
    // 这是 installer 自带的依赖，必装
    NSLog(@"[ForgeDirect] Extracting all maven entries from installer jar");
    reportProgress(0.2, @"正在解压内嵌 maven 依赖");
    NSUInteger extractedCount = [self extractAllMavenEntries:installerPath toLibrariesDir:librariesDir];
    NSLog(@"[ForgeDirect] Extracted %lu maven entries", (unsigned long)extractedCount);

    // Step B: 下载 versionJson.libraries 中未在 installer.jar 内的库
    // version.json 的 libraries 包含 vanilla mc、modlauncher、bootstraplauncher 等
    // 这些不在 installer.jar 内，必须从 maven 下载
    NSLog(@"[ForgeDirect] Downloading missing libraries from maven");
    reportProgress(0.3, @"正在下载缺失的依赖库");
    NSArray *allLibraries = versionJson[@"libraries"];
    if ([allLibraries isKindOfClass:[NSArray class]]) {
        [self downloadMissingLibraries:allLibraries librariesDir:librariesDir progress:progress baseProgress:0.3 progressSpan:0.4];
    }

    // Step C: 关键步骤——下载预打补丁的 PATCHED artifact
    // install_profile.json 的 processors 会生成 :client 这个 jar，但 iOS 不能跑 processor。
    // Forge/NeoForge 已将这个预打补丁 jar 发布到 maven，直接下载即可。
    NSLog(@"[ForgeDirect] Downloading pre-patched client artifact");
    reportProgress(0.75, @"正在下载预打补丁的核心 jar");
    NSString *mainPath = installProfile[@"path"];
    if ([mainPath isKindOfClass:[NSString class]] && mainPath.length > 0) {
        if (![self downloadPatchedArtifact:mainPath librariesDir:librariesDir error:error]) {
            NSLog(@"[ForgeDirect] Failed to download patched artifact");
            return NO;
        }
    } else {
        NSLog(@"[ForgeDirect] No main path in install_profile, skipping patched artifact download");
    }

    // Write version JSON
    NSLog(@"[ForgeDirect] Writing version JSON to: %@", versionJsonPath);
    reportProgress(0.9, @"正在写入版本 JSON");
    NSError *writeError = saveJSONToFile(versionJson, versionJsonPath);
    if (writeError) {
        if (error) {
            *error = [NSError errorWithDomain:ForgeDirectInstallerErrorDomain
                                         code:ForgeDirectInstallerErrorWriteFailed
                                     userInfo:@{NSLocalizedDescriptionKey: [NSString stringWithFormat:@"Failed to write version JSON: %@", writeError.localizedDescription]}];
        }
        return NO;
    }
    NSLog(@"[ForgeDirect] Version JSON written successfully");

    NSLog(@"[ForgeDirect] installNewFormat completed");
    return YES;
}

#pragma mark - Maven entry Extraction

// 解压 installer.jar 内 maven/ 目录下所有文件到 libraries 目录
// 返回成功解压的文件数
+ (NSUInteger)extractAllMavenEntries:(NSString *)installerPath toLibrariesDir:(NSString *)librariesDir {
    NSError *openError = nil;
    UZKArchive *archive = [[UZKArchive alloc] initWithPath:installerPath error:&openError];
    if (!archive || openError) {
        NSLog(@"[ForgeDirect] extractAllMavenEntries: failed to open archive: %@", openError.localizedDescription ?: @"unknown");
        return 0;
    }

    NSError *listError = nil;
    NSArray<NSString *> *filenames = [archive listFilenames:&listError];
    if (!filenames || listError) {
        NSLog(@"[ForgeDirect] extractAllMavenEntries: failed to list filenames: %@", listError.localizedDescription ?: @"unknown");
        return 0;
    }

    NSUInteger count = 0;
    for (NSString *name in filenames) {
        // 只处理 maven/ 前缀的文件
        if (![name hasPrefix:@"maven/"]) continue;

        // 转换为相对路径：去掉 "maven/" 前缀
        NSString *relativePath = [name substringFromIndex:@"maven/".length];
        if (relativePath.length == 0) continue;

        NSString *destPath = [librariesDir stringByAppendingPathComponent:relativePath];
        NSError *extractError = nil;
        if (![self extractFile:installerPath entry:name to:destPath error:&extractError]) {
            NSLog(@"[ForgeDirect] extractAllMavenEntries: failed to extract %@: %@", name, extractError.localizedDescription ?: @"unknown");
            continue;
        }
        count++;
    }
    return count;
}

#pragma mark - Library Download

// 下载 version.json.libraries 中尚未存在的库
// 优先用 library.downloads.artifact.url；若没有则用 maven 仓库拼接
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
            // 用 maven 仓库拼接（Forge 库走 maven.minecraftforge.net，其他走 libraries.minecraft.net）
            url = [self buildMavenURLForLibrary:name relativePath:relativePath];
        }

        if (!url) {
            NSLog(@"[ForgeDirect] Cannot build URL for library %@, skipping", name);
            failed++;
            continue;
        }

        if (progress) {
            double p = base + span * ((double)downloaded / (double)total);
            progress(p, [NSString stringWithFormat:@"正在下载依赖库 (%lu/%lu): %@", (unsigned long)(downloaded + 1), (unsigned long)total, name]);
        }

        NSError *downloadError = nil;
        if ([self downloadFileFromURL:url toPath:destPath error:&downloadError]) {
            downloaded++;
            NSLog(@"[ForgeDirect] Downloaded library: %@", name);
        } else {
            failed++;
            NSLog(@"[ForgeDirect] Failed to download library %@: %@", name, downloadError.localizedDescription ?: @"unknown");
            // 不中断流程，部分库可能不重要或可由游戏启动时再次下载
        }
    }

    NSLog(@"[ForgeDirect] Library download summary: downloaded=%lu, skipped=%lu, failed=%lu, total=%lu",
          (unsigned long)downloaded, (unsigned long)skipped, (unsigned long)failed, (unsigned long)total);
}

// 为 library 构建 maven URL
+ (NSString *)buildMavenURLForLibrary:(NSString *)name relativePath:(NSString *)relativePath {
    NSString *downloadSource = getPrefObject(@"general.download_source");
    BOOL useBMCLAPI = [downloadSource isEqualToString:@"bmclapi"];

    // Forge 自家库走 maven.minecraftforge.net
    if ([name hasPrefix:@"net.minecraftforge:"]) {
        if (useBMCLAPI) {
            return [NSString stringWithFormat:@"https://bmclapi2.bangbang93.com/maven/%@", relativePath];
        }
        return [NSString stringWithFormat:@"https://maven.minecraftforge.net/%@", relativePath];
    }

    // NeoForge 自家库走 maven.neoforged.net
    if ([name hasPrefix:@"net.neoforged:"] || [name hasPrefix:@"net.neoforged."] || [name hasPrefix:@"cpw.mods:"]) {
        if (useBMCLAPI) {
            return [NSString stringWithFormat:@"https://bmclapi2.bangbang93.com/maven/%@", relativePath];
        }
        return [NSString stringWithFormat:@"https://maven.neoforged.net/releases/%@", relativePath];
    }

    // 其他库（Mojang、lwjgl 等）走 libraries.minecraft.net（BMCLAPI 镜像）
    if (useBMCLAPI) {
        return [NSString stringWithFormat:@"https://bmclapi2.bangbang93.com/maven/%@", relativePath];
    }
    return [NSString stringWithFormat:@"https://libraries.minecraft.net/%@", relativePath];
}

// 下载预打补丁的 PATCHED artifact
// mainPath 格式："net.minecraftforge:forge:1.20.1-47.3.0"
// 对应 maven 上的 :client classifier jar：
//   官方源: https://maven.minecraftforge.net/net/minecraftforge/forge/1.20.1-47.3.0/forge-1.20.1-47.3.0-client.jar
//   BMCLAPI: https://bmclapi2.bangbang93.com/maven/net/minecraftforge/forge/1.20.1-47.3.0/forge-1.20.1-47.3.0-client.jar
+ (BOOL)downloadPatchedArtifact:(NSString *)mainPath librariesDir:(NSString *)librariesDir error:(NSError **)error {
    // 拆分 maven 坐标
    NSArray *parts = [mainPath componentsSeparatedByString:@":"];
    if (parts.count < 3) {
        if (error) {
            *error = [NSError errorWithDomain:ForgeDirectInstallerErrorDomain
                                         code:ForgeDirectInstallerErrorInvalidProfile
                                     userInfo:@{NSLocalizedDescriptionKey: [NSString stringWithFormat:@"Invalid main path: %@", mainPath]}];
        }
        return NO;
    }

    NSString *groupId = parts[0];
    NSString *artifactId = parts[1];
    NSString *version = parts[2];

    NSString *groupPath = [groupId stringByReplacingOccurrencesOfString:@"." withString:@"/"];
    // 关键：client classifier，这是 Forge/NeoForge 预打补丁的 jar
    NSString *jarName = [NSString stringWithFormat:@"%@-%@-client.jar", artifactId, version];
    NSString *relativePath = [NSString stringWithFormat:@"%@/%@/%@/%@", groupPath, artifactId, version, jarName];
    NSString *destPath = [librariesDir stringByAppendingPathComponent:relativePath];

    // 已存在则跳过
    if ([NSFileManager.defaultManager fileExistsAtPath:destPath]) {
        NSLog(@"[ForgeDirect] Patched artifact already exists: %@", destPath);
        return YES;
    }

    // 拼 URL
    NSString *downloadSource = getPrefObject(@"general.download_source");
    BOOL useBMCLAPI = [downloadSource isEqualToString:@"bmclapi"];
    NSString *url;
    if ([groupId hasPrefix:@"net.neoforged"]) {
        // NeoForge 走 maven.neoforged.net/releases
        if (useBMCLAPI) {
            url = [NSString stringWithFormat:@"https://bmclapi2.bangbang93.com/maven/%@", relativePath];
        } else {
            url = [NSString stringWithFormat:@"https://maven.neoforged.net/releases/%@", relativePath];
        }
    } else {
        // Forge 走 maven.minecraftforge.net
        if (useBMCLAPI) {
            url = [NSString stringWithFormat:@"https://bmclapi2.bangbang93.com/maven/%@", relativePath];
        } else {
            url = [NSString stringWithFormat:@"https://maven.minecraftforge.net/%@", relativePath];
        }
    }

    NSLog(@"[ForgeDirect] Downloading patched artifact from: %@", url);
    NSError *downloadError = nil;
    if (![self downloadFileFromURL:url toPath:destPath error:&downloadError]) {
        if (error) {
            *error = [NSError errorWithDomain:ForgeDirectInstallerErrorDomain
                                         code:ForgeDirectInstallerErrorExtractionFailed
                                     userInfo:@{
                                         NSLocalizedDescriptionKey: [NSString stringWithFormat:@"下载预打补丁核心 jar 失败: %@\nURL: %@\n错误: %@",
                                             jarName, url, downloadError.localizedDescription ?: @"未知错误"]
                                     }];
        }
        return NO;
    }
    NSLog(@"[ForgeDirect] Patched artifact downloaded: %@", destPath);
    return YES;
}

// 同步下载文件到指定路径
+ (BOOL)downloadFileFromURL:(NSString *)urlString toPath:(NSString *)destPath error:(NSError **)error {
    if (error) *error = nil;

    NSURL *url = [NSURL URLWithString:urlString];
    if (!url) {
        if (error) {
            *error = [NSError errorWithDomain:ForgeDirectInstallerErrorDomain
                                         code:ForgeDirectInstallerErrorWriteFailed
                                     userInfo:@{NSLocalizedDescriptionKey: [NSString stringWithFormat:@"Invalid URL: %@", urlString]}];
        }
        return NO;
    }

    // 创建目标目录
    NSString *destDir = [destPath stringByDeletingLastPathComponent];
    NSError *dirError = nil;
    [NSFileManager.defaultManager createDirectoryAtPath:destDir
                            withIntermediateDirectories:YES
                                             attributes:nil
                                                  error:&dirError];
    if (dirError) {
        if (error) {
            *error = [NSError errorWithDomain:ForgeDirectInstallerErrorDomain
                                         code:ForgeDirectInstallerErrorWriteFailed
                                     userInfo:@{NSLocalizedDescriptionKey: [NSString stringWithFormat:@"Failed to create directory %@: %@", destDir, dirError.localizedDescription]}];
        }
        return NO;
    }

    // 同步下载
    NSData *data = [NSData dataWithContentsOfURL:url options:NSDataReadingMapped error:error];
    if (!data) {
        return NO;
    }

    BOOL written = [data writeToFile:destPath options:NSDataWritingAtomic error:error];
    if (!written) {
        return NO;
    }

    NSLog(@"[ForgeDirect] Downloaded %@ (%lu bytes) -> %@", urlString.lastPathComponent ?: urlString, (unsigned long)data.length, destPath);
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
        NSLog(@"[ForgeDirect] Failed to open archive: %@", openError.localizedDescription ?: @"unknown");
        if (error) {
            *error = [NSError errorWithDomain:ForgeDirectInstallerErrorDomain
                                         code:ForgeDirectInstallerErrorInvalidArchive
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
        NSLog(@"[ForgeDirect] Failed to extract entry '%@': %@", entryPath, extractError.localizedDescription ?: @"unknown");
        if (error) {
            *error = [NSError errorWithDomain:ForgeDirectInstallerErrorDomain
                                         code:ForgeDirectInstallerErrorExtractionFailed
                                     userInfo:@{NSLocalizedDescriptionKey: [NSString stringWithFormat:@"Failed to extract %@: %@", entryPath, extractError.localizedDescription ?: @"not found"]}];
        }
        return nil;
    }

    NSLog(@"[ForgeDirect] Extracted entry '%@' (%lu bytes)", entryPath, (unsigned long)result.length);
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
            *error = [NSError errorWithDomain:ForgeDirectInstallerErrorDomain
                                         code:ForgeDirectInstallerErrorExtractionFailed
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
        NSLog(@"[ForgeDirect] Failed to create directory '%@': %@", destDir, dirError.localizedDescription);
        if (error) {
            *error = [NSError errorWithDomain:ForgeDirectInstallerErrorDomain
                                         code:ForgeDirectInstallerErrorWriteFailed
                                     userInfo:@{NSLocalizedDescriptionKey: [NSString stringWithFormat:@"Failed to create directory %@: %@", destDir, dirError.localizedDescription]}];
        }
        return NO;
    }

    BOOL written = [data writeToFile:destPath options:NSDataWritingAtomic error:error];
    if (!written) {
        NSLog(@"[ForgeDirect] Failed to write file '%@'", destPath);
        if (error && !*error) {
            *error = [NSError errorWithDomain:ForgeDirectInstallerErrorDomain
                                         code:ForgeDirectInstallerErrorWriteFailed
                                     userInfo:@{NSLocalizedDescriptionKey: [NSString stringWithFormat:@"Failed to write %@", destPath]}];
        }
        return NO;
    }

    NSLog(@"[ForgeDirect] Written file '%@' (%lu bytes)", destPath, (unsigned long)data.length);
    return YES;
}

#pragma mark - Maven path utilities

+ (NSString *)mavenPathToRelativePath:(NSString *)mavenPath {
    // Format: groupId:artifactId:version[:classifier]
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
    // Same format as mavenPathToRelativePath
    return [self mavenPathToRelativePath:name];
}

@end
