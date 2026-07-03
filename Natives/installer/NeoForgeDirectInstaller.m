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

        NSString *gameDir = [self gameDirectory];
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
    if ([mainPath isKindOfClass:[NSString class]] && mainPath.length > 0) {
        if (![self downloadPatchedArtifact:mainPath librariesDir:librariesDir error:error]) {
            NSLog(@"[NeoForgeDirect] Failed to download patched artifact");
            return NO;
        }
    } else {
        NSLog(@"[NeoForgeDirect] No main path in install_profile, skipping patched artifact download");
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
    NSLog(@"[NeoForgeDirect] Profile saved and selected");
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
    for (NSString *name in filenames) {
        if (![name hasPrefix:@"maven/"]) continue;

        NSString *relativePath = [name substringFromIndex:@"maven/".length];
        if (relativePath.length == 0) continue;

        NSString *destPath = [librariesDir stringByAppendingPathComponent:relativePath];
        NSError *extractError = nil;
        if (![self extractFile:installerPath entry:name to:destPath error:&extractError]) {
            NSLog(@"[NeoForgeDirect] extractAllMavenEntries: failed to extract %@: %@", name, extractError.localizedDescription ?: @"unknown");
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
            url = [self buildMavenURLForLibrary:name relativePath:relativePath];
        }

        if (!url) {
            NSLog(@"[NeoForgeDirect] Cannot build URL for library %@, skipping", name);
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
            NSLog(@"[NeoForgeDirect] Downloaded library: %@", name);
        } else {
            failed++;
            NSLog(@"[NeoForgeDirect] Failed to download library %@: %@", name, downloadError.localizedDescription ?: @"unknown");
        }
    }

    NSLog(@"[NeoForgeDirect] Library download summary: downloaded=%lu, skipped=%lu, failed=%lu, total=%lu",
          (unsigned long)downloaded, (unsigned long)skipped, (unsigned long)failed, (unsigned long)total);
}

// 为 library 构建 maven URL
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

    // 其他库（Mojang、lwjgl 等）走 libraries.minecraft.net（BMCLAPI 镜像）
    if (useBMCLAPI) {
        return [NSString stringWithFormat:@"https://bmclapi2.bangbang93.com/maven/%@", relativePath];
    }
    return [NSString stringWithFormat:@"https://libraries.minecraft.net/%@", relativePath];
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
        if (error) {
            *error = [NSError errorWithDomain:NeoForgeDirectInstallerErrorDomain
                                         code:NeoForgeDirectInstallerErrorExtractionFailed
                                     userInfo:@{
                                         NSLocalizedDescriptionKey: [NSString stringWithFormat:@"下载预打补丁核心 jar 失败: %@\nURL: %@\n错误: %@",
                                             jarName, url, downloadError.localizedDescription ?: @"未知错误"]
                                     }];
        }
        return NO;
    }
    NSLog(@"[NeoForgeDirect] Patched artifact downloaded: %@", destPath);
    return YES;
}

// 同步下载文件到指定路径
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

    NSData *data = [NSData dataWithContentsOfURL:url options:NSDataReadingMapped error:error];
    if (!data) {
        return NO;
    }

    BOOL written = [data writeToFile:destPath options:NSDataWritingAtomic error:error];
    if (!written) {
        return NO;
    }

    NSLog(@"[NeoForgeDirect] Downloaded %@ (%lu bytes) -> %@", urlString.lastPathComponent ?: urlString, (unsigned long)data.length, destPath);
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
