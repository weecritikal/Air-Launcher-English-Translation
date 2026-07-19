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
#import "MinecraftResourceUtils.h"
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
    return [self installForgeFromInstaller:installerPath
                                  versionId:versionId
                              customGameDir:nil
                        skipRegisterVersion:NO
                                   progress:progress
                                     error:error];
}

+ (BOOL)installForgeFromInstaller:(NSString *)installerPath
                        versionId:(NSString *)versionId
                    customGameDir:(nullable NSString *)customGameDir
              skipRegisterVersion:(BOOL)skipRegisterVersion
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

        // 整合包导入时使用自定义 gameDir；否则使用默认 POJAV_GAME_DIR
        // 注意：gameDir（user.dir，mods/saves/configs 隔离目录）用 customGameDir，
        // 但 versionDir 和 librariesDir 必须始终用 POJAV_GAME_DIR（主目录）。
        // 原因：Minecraft 启动器（Java 端 Tools.java）的 DIR_HOME_VERSION 和 DIR_HOME_LIBRARY
        // 固定指向 POJAV_GAME_DIR/versions 和 POJAV_GAME_DIR/libraries，不从 profile gameDir 读取。
        // 之前把 versionDir/librariesDir 放到 customGameDir 下会导致启动时"找不到版本信息"。
        NSString *gameDir = customGameDir.length > 0 ? customGameDir : [self gameDirectory];
        NSString *mainGameDir = [self gameDirectory];  // 始终用主目录存放 versions 和 libraries
        NSString *librariesDir = [mainGameDir stringByAppendingPathComponent:@"libraries"];
        NSLog(@"[ForgeDirect] Game directory (user.dir): %@", gameDir);
        NSLog(@"[ForgeDirect] Main game directory (versions/libraries): %@", mainGameDir);
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
        // 整合包导入时跳过（由 ModpackImportService.createProfileForModpack 统一注册）
        if (!skipRegisterVersion) {
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
        }

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

/// 阶段6修复（参照 FCL）：用 NSURLSession 替代已废弃的 NSURLConnection sendSynchronousRequest:
/// 进行同步 HTTP 下载。原 NSURLConnection 在 iOS 13+ 已废弃，BMCLAPI 等镜像源在某些 iOS 版本
/// 下表现不稳定（TLS 协商失败、超时不生效、不跟随 302 重定向等），导致 ensureParentVersionExists:
/// 拉取父版本 JSON 失败 → Forge/NeoForge 版本 inheritsFrom 找不到原版 → 启动崩溃。
/// 这里复用 downloadFileFromURL: 中已验证可用的 NSURLSession + 信号量模式。
+ (NSData *)downloadDataForRequest:(NSURLRequest *)request error:(NSError **)error {
    if (!request) {
        if (error) {
            *error = [NSError errorWithDomain:ForgeDirectInstallerErrorDomain
                                         code:ForgeDirectInstallerErrorWriteFailed
                                     userInfo:@{NSLocalizedDescriptionKey: @"nil request"}];
        }
        return nil;
    }
    __block NSData *resultData = nil;
    __block NSError *resultError = nil;
    dispatch_semaphore_t sem = dispatch_semaphore_create(0);
    NSURLSessionDataTask *task = [[NSURLSession sharedSession] dataTaskWithRequest:request
                                                                   completionHandler:^(NSData *data, NSURLResponse *response, NSError *taskError) {
        if (taskError) {
            resultError = taskError;
        } else if ([response isKindOfClass:[NSHTTPURLResponse class]]) {
            NSInteger statusCode = [(NSHTTPURLResponse *)response statusCode];
            if (statusCode >= 400) {
                resultError = [NSError errorWithDomain:ForgeDirectInstallerErrorDomain
                                                   code:statusCode
                                               userInfo:@{NSLocalizedDescriptionKey: [NSString stringWithFormat:@"HTTP %ld for %@", (long)statusCode, request.URL.absoluteString]}];
            } else {
                resultData = data;
            }
        } else {
            resultData = data;
        }
        dispatch_semaphore_signal(sem);
    }];
    [task resume];
    long waitResult = dispatch_semaphore_wait(sem, dispatch_time(DISPATCH_TIME_NOW, 60 * NSEC_PER_SEC));
    if (waitResult != 0) {
        [task cancel];
        if (error) {
            *error = [NSError errorWithDomain:ForgeDirectInstallerErrorDomain
                                         code:NSURLErrorTimedOut
                                     userInfo:@{NSLocalizedDescriptionKey: [NSString stringWithFormat:@"请求超时（60s）: %@", request.URL.absoluteString]}];
        }
        return nil;
    }
    if (error) *error = resultError;
    return resultData;
}

/// 参照 FCL/HMCL：确保父版本（vanilla MC）的 version JSON 已存在。
/// Forge/NeoForge 的 version.json 含 "inheritsFrom": "1.20.1" 等字段，启动时 Java 端
/// Tools.getVersionInfo() 会读取 versions/{inheritsFrom}/{inheritsFrom}.json 与当前版本合并。
/// 若用户尚未安装原版，启动会因 FileNotFoundException 崩溃。
/// 本方法仅下载父版本的 version JSON（不下载原版 client.jar，因为 iOS 启动器使用
/// 自有渲染管线，不需要原版 client.jar；但需要 JSON 以提供 mainClass、arguments、
/// assetIndex、vanilla libraries 等元数据）。
+ (BOOL)ensureParentVersionExists:(NSString *)parentVersionId error:(NSError **)error {
    if (parentVersionId.length == 0) return YES;

    NSString *mainGameDir = [self gameDirectory];
    NSString *parentVersionDir = [mainGameDir stringByAppendingPathComponent:
                                  [NSString stringWithFormat:@"versions/%@", parentVersionId]];
    NSString *parentJsonPath = [parentVersionDir stringByAppendingPathComponent:
                                [NSString stringWithFormat:@"%@.json", parentVersionId]];

    // 1. 父版本 JSON 已存在，无需下载
    if ([NSFileManager.defaultManager fileExistsAtPath:parentJsonPath]) {
        NSLog(@"[ForgeDirect] Parent version JSON already exists: %@", parentJsonPath);
        return YES;
    }

    NSLog(@"[ForgeDirect] Parent version JSON missing, downloading: %@", parentVersionId);

    // 2. 拉取 Mojang 版本清单
    NSString *downloadSource = getPrefObject(@"general.download_source");
    BOOL useBMCLAPI = [downloadSource isEqualToString:@"bmclapi"];
    NSString *manifestURL = useBMCLAPI
        ? @"https://bmclapi2.bangbang93.com/mc/game/version_manifest_v2.json"
        : @"https://piston-meta.mojang.com/mc/game/version_manifest_v2.json";

    NSURL *url = [NSURL URLWithString:manifestURL];
    if (!url) {
        if (error) {
            *error = [NSError errorWithDomain:ForgeDirectInstallerErrorDomain
                                         code:ForgeDirectInstallerErrorWriteFailed
                                     userInfo:@{NSLocalizedDescriptionKey: @"Invalid manifest URL"}];
        }
        return NO;
    }

    NSMutableURLRequest *manifestRequest = [NSMutableURLRequest requestWithURL:url];
    manifestRequest.timeoutInterval = 30.0;
    manifestRequest.cachePolicy = NSURLRequestReloadIgnoringLocalCacheData;
    [manifestRequest setValue:@"Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15" forHTTPHeaderField:@"User-Agent"];

    NSData *manifestData = [self downloadDataForRequest:manifestRequest error:error];
    if (!manifestData) {
        NSLog(@"[ForgeDirect] Failed to download version manifest: %@", error ? [*error localizedDescription] : @"unknown");
        return NO;
    }

    NSDictionary *manifest = [NSJSONSerialization JSONObjectWithData:manifestData options:0 error:nil];
    NSArray *versions = [manifest isKindOfClass:[NSDictionary class]] ? manifest[@"versions"] : nil;
    if (![versions isKindOfClass:[NSArray class]]) {
        if (error) {
            *error = [NSError errorWithDomain:ForgeDirectInstallerErrorDomain
                                         code:ForgeDirectInstallerErrorInvalidProfile
                                     userInfo:@{NSLocalizedDescriptionKey: @"Invalid version manifest format"}];
        }
        return NO;
    }

    // 3. 查找匹配的版本条目，获取 version JSON URL
    NSString *versionJSONURL = nil;
    for (NSDictionary *v in versions) {
        if ([v isKindOfClass:[NSDictionary class]] && [v[@"id"] isEqualToString:parentVersionId]) {
            versionJSONURL = [v[@"url"] isKindOfClass:[NSString class]] ? v[@"url"] : nil;
            break;
        }
    }
    if (!versionJSONURL) {
        if (error) {
            *error = [NSError errorWithDomain:ForgeDirectInstallerErrorDomain
                                         code:ForgeDirectInstallerErrorInvalidProfile
                                     userInfo:@{NSLocalizedDescriptionKey: [NSString stringWithFormat:@"Version %@ not found in manifest", parentVersionId]}];
        }
        return NO;
    }

    // BMCLAPI 镜像：替换 Mojang 官方域名为 BMCLAPI 域名
    if (useBMCLAPI) {
        versionJSONURL = [versionJSONURL stringByReplacingOccurrencesOfString:@"piston-meta.mojang.com"
                                                                    withString:@"bmclapi2.bangbang93.com"];
        versionJSONURL = [versionJSONURL stringByReplacingOccurrencesOfString:@"launchermeta.mojang.com"
                                                                    withString:@"bmclapi2.bangbang93.com"];
    }

    NSLog(@"[ForgeDirect] Downloading parent version JSON from: %@", versionJSONURL);

    // 4. 下载 version JSON
    NSURL *jsonURL = [NSURL URLWithString:versionJSONURL];
    if (!jsonURL) {
        if (error) {
            *error = [NSError errorWithDomain:ForgeDirectInstallerErrorDomain
                                         code:ForgeDirectInstallerErrorWriteFailed
                                     userInfo:@{NSLocalizedDescriptionKey: @"Invalid version JSON URL"}];
        }
        return NO;
    }

    NSMutableURLRequest *jsonRequest = [NSMutableURLRequest requestWithURL:jsonURL];
    jsonRequest.timeoutInterval = 30.0;
    jsonRequest.cachePolicy = NSURLRequestReloadIgnoringLocalCacheData;
    [jsonRequest setValue:@"Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15" forHTTPHeaderField:@"User-Agent"];

    NSData *jsonData = [self downloadDataForRequest:jsonRequest error:error];
    if (!jsonData) {
        NSLog(@"[ForgeDirect] Failed to download parent version JSON: %@", error ? [*error localizedDescription] : @"unknown");
        return NO;
    }

    // 5. 创建父版本目录并写入 JSON
    NSError *dirError = nil;
    [NSFileManager.defaultManager createDirectoryAtPath:parentVersionDir
                            withIntermediateDirectories:YES
                                             attributes:nil
                                                  error:&dirError];
    if (dirError) {
        NSLog(@"[ForgeDirect] Failed to create parent version dir: %@", dirError.localizedDescription);
        if (error) *error = dirError;
        return NO;
    }

    NSError *writeErr = nil;
    if (![jsonData writeToFile:parentJsonPath options:NSDataWritingAtomic error:&writeErr]) {
        NSLog(@"[ForgeDirect] Failed to write parent version JSON: %@", writeErr.localizedDescription);
        if (error) *error = writeErr;
        return NO;
    }

    NSLog(@"[ForgeDirect] Parent version JSON saved: %@ (%lu bytes)", parentJsonPath, (unsigned long)jsonData.length);
    return YES;
}

+ (void)registerVersion:(NSString *)versionId {
    NSLog(@"[ForgeDirect] registerVersion called: %@", versionId);
    PLProfiles *profiles = [PLProfiles current];
    NSLog(@"[ForgeDirect] PLProfiles current: %@", profiles ? @"ok" : @"nil");
    NSMutableDictionary *profileDict = [NSMutableDictionary dictionary];
    profileDict[@"name"] = versionId;
    profileDict[@"lastVersionId"] = versionId;
    // 改回原来的"游戏目录切换"机制：所有版本共享根目录（gameDir="."）
    // 用户通过设置中的"游戏目录切换"功能手动切换不同的 gameDir
    profileDict[@"gameDir"] = @".";
    profileDict[@"type"] = @"custom";
    profileDict[@"created"] = [NSDate date].description;
    // 推断 Java 版本：Forge 1.20.5+ 需 Java 21，1.18+ 需 Java 17，1.17 需 Java 16，其他 Java 8
    // versionId 形如 "1.20.1-forge-47.3.0" 或 "Forge-1.20.1-47.3.0"，提取 MC 版本
    NSInteger javaMajor = [self inferJavaMajorVersionFromVersionId:versionId];
    // 写入 NSString 而非 NSDictionary，与 ProfileSettingsViewController 等所有读取方一致
    // JavaLauncher 通过 .intValue 读取，"17".intValue = 17
    profileDict[@"javaVersion"] = [NSString stringWithFormat:@"%ld", (long)javaMajor];
    [profiles saveProfile:profileDict withName:versionId];
    // 与 Fabric / Vanilla 安装路径保持一致：自动选中新建的 profile，避免用户回到主界面仍启动旧版本
    profiles.selectedProfileName = versionId;
    NSLog(@"[ForgeDirect] Profile saved and selected (javaVersion=%ld, gameDir=%@)", (long)javaMajor, profileDict[@"gameDir"]);
}

/// 从 versionId 中推断所需 Java 主版本号
/// versionId 形如 "1.20.1-forge-47.3.0"、"Forge-1.20.1-47.3.0"、"1.18.2-forge-40.2.0"
+ (NSInteger)inferJavaMajorVersionFromVersionId:(NSString *)versionId {
    // 提取 1.x.x 格式的 MC 版本（锚定开头或分隔符，避免误匹配 loader 版本号中的 "1.x"）
    NSRegularExpression *regex = [NSRegularExpression regularExpressionWithPattern:@"(?:^|[-_])1\\.(\\d+)(?:\\.(\\d+))?"
                                                                           options:0
                                                                             error:nil];
    NSTextCheckingResult *match = [regex firstMatchInString:versionId options:0 range:NSMakeRange(0, versionId.length)];
    if (!match || match.numberOfRanges < 2) return 8;
    NSString *minorStr = [versionId substringWithRange:[match rangeAtIndex:1]];
    NSInteger minor = [minorStr integerValue];
    NSString *patchStr = match.numberOfRanges >= 3 && [match rangeAtIndex:2].location != NSNotFound
                        ? [versionId substringWithRange:[match rangeAtIndex:2]]
                        : @"0";
    NSInteger patch = [patchStr integerValue];
    if (minor >= 21) return 21;                  // 1.21+
    if (minor >= 20 && patch >= 5) return 21;    // 1.20.5+
    if (minor >= 18) return 17;                  // 1.18+
    if (minor >= 17) return 17;                  // 1.17（项目未捆绑 Java 16，Java 17 可向后兼容运行 1.17）
    return 8;                                     // 1.16.5 及以下
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
    // 版本 JSON 必须写入 POJAV_GAME_DIR/versions/（主目录），而非 profile gameDir。
    // Minecraft 启动器 Java 端固定从 POJAV_GAME_DIR/versions 加载版本 JSON。
    NSString *versionDir = [[self gameDirectory] stringByAppendingPathComponent:[NSString stringWithFormat:@"versions/%@", versionId]];
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
    } else {
        // filePath 缺失：universal jar 是老版本 Forge 的核心运行时依赖
        // 若 mavenPath 存在，后续 extractAllMavenEntries 可能会提取到（zip 内 maven/ 路径下）
        // 若 mavenPath 也缺失，启动时可能 NoClassDefFoundError
        NSLog(@"[ForgeDirect] ⚠️ install.filePath 缺失，universal jar 将依赖 extractAllMavenEntries 或后续 downloadMissingLibraries 补全");
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

    // 参照 FCL/HMCL：老格式 Forge 1.12- 的 versionInfo 也可能含 inheritsFrom，
    // 确保父版本（vanilla MC）的 version JSON 已存在。
    NSString *oldInheritsFrom = [mutableVersionInfo[@"inheritsFrom"] isKindOfClass:[NSString class]] ? mutableVersionInfo[@"inheritsFrom"] : nil;
    if (oldInheritsFrom.length > 0 && ![oldInheritsFrom isEqualToString:versionId]) {
        NSLog(@"[ForgeDirect] Checking parent vanilla version (old format): %@", oldInheritsFrom);
        NSError *parentError = nil;
        if (![self ensureParentVersionExists:oldInheritsFrom error:&parentError]) {
            NSLog(@"[ForgeDirect] ⚠️ 父版本 %@ 未能自动补全: %@", oldInheritsFrom, parentError.localizedDescription ?: @"未知错误");
        } else {
            NSLog(@"[ForgeDirect] Parent vanilla version ensured: %@", oldInheritsFrom);
        }
    }

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
    // 版本 JSON 必须写入 POJAV_GAME_DIR/versions/（主目录），而非 profile gameDir。
    // Minecraft 启动器 Java 端固定从 POJAV_GAME_DIR/versions 加载版本 JSON。
    NSString *versionDir = [[self gameDirectory] stringByAppendingPathComponent:[NSString stringWithFormat:@"versions/%@", versionId]];
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
    // 兜底：path 字段缺失时用 version 字段拼接标准 Forge 坐标
    if (![mainPath isKindOfClass:[NSString class]] || mainPath.length == 0) {
        NSString *versionField = installProfile[@"version"];
        if ([versionField isKindOfClass:[NSString class]] && versionField.length > 0) {
            mainPath = [NSString stringWithFormat:@"net.minecraftforge:forge:%@", versionField];
            NSLog(@"[ForgeDirect] path 字段缺失，用 version 字段兜底拼接: %@", mainPath);
        }
    }
    if ([mainPath isKindOfClass:[NSString class]] && mainPath.length > 0) {
        if (![self downloadPatchedArtifact:mainPath librariesDir:librariesDir error:error]) {
            NSLog(@"[ForgeDirect] Failed to download patched artifact");
            return NO;
        }
    } else {
        // path 是 Forge 1.13+ 运行核心依赖，缺失会导致启动时 ClassNotFoundException
        NSLog(@"[ForgeDirect] install_profile.json 缺少 path/version 字段，无法下载 patched client jar");
        if (error) {
            *error = [NSError errorWithDomain:ForgeDirectInstallerErrorDomain
                                         code:ForgeDirectInstallerErrorInvalidProfile
                                     userInfo:@{NSLocalizedDescriptionKey: @"install_profile.json 缺少 path 和 version 字段，无法定位预打补丁核心 jar"}];
        }
        return NO;
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

    // 参照 FCL/HMCL：确保父版本（vanilla MC）的 version JSON 已存在。
    // Forge 1.13+ 的 version.json 含 "inheritsFrom": "1.20.1" 等字段，启动时 Java 端会
    // 读取 versions/{inheritsFrom}/{inheritsFrom}.json 与 Forge 版本合并。
    // 若用户尚未安装原版，启动会因 FileNotFoundException 崩溃。
    // 这里在直装完成后自动补全缺失的父版本 JSON（仅下载 JSON，不下载原版客户端 jar，
    // 因为 iOS 启动器使用自有渲染管线，不需要原版 client.jar）。
    NSString *inheritsFrom = [versionJson[@"inheritsFrom"] isKindOfClass:[NSString class]] ? versionJson[@"inheritsFrom"] : nil;
    if (inheritsFrom.length > 0 && ![inheritsFrom isEqualToString:versionId]) {
        NSLog(@"[ForgeDirect] Checking parent vanilla version: %@", inheritsFrom);
        NSError *parentError = nil;
        if (![self ensureParentVersionExists:inheritsFrom error:&parentError]) {
            // 父版本缺失只发出警告，不阻断安装（用户可能后续手动安装原版）
            NSLog(@"[ForgeDirect] ⚠️ 父版本 %@ 未能自动补全: %@", inheritsFrom, parentError.localizedDescription ?: @"未知错误");
        } else {
            NSLog(@"[ForgeDirect] Parent vanilla version ensured: %@", inheritsFrom);
        }
    }

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
    NSFileManager *fm = [NSFileManager defaultManager];
    for (NSString *name in filenames) {
        // 只处理 maven/ 前缀的文件
        if (![name hasPrefix:@"maven/"]) continue;
        // 跳过目录条目（以 / 结尾），避免 extractDataFromFile 返回空数据产生误报日志
        if ([name hasSuffix:@"/"]) continue;

        // 转换为相对路径：去掉 "maven/" 前缀
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
            NSLog(@"[ForgeDirect] extractAllMavenEntries: failed to extract %@: %@", name, extractError.localizedDescription ?: @"unknown");
            continue;
        }

        // 创建目标目录（处理同名文件冲突）
        NSString *destDir = [destPath stringByDeletingLastPathComponent];
        [self ensureDirectoryExists:destDir error:nil];

        // 写入文件
        NSError *writeError = nil;
        if (![data writeToFile:destPath options:NSDataWritingAtomic error:&writeError]) {
            NSLog(@"[ForgeDirect] extractAllMavenEntries: failed to write %@: %@", destPath, writeError.localizedDescription ?: @"unknown");
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
    NSUInteger processed = 0;  // 已处理数（用于进度计算，包含成功/跳过/失败）
    NSMutableArray<NSString *> *criticalFailures = [NSMutableArray array];  // 关键库失败清单

    for (NSDictionary *library in libraries) {
        if (![library isKindOfClass:[NSDictionary class]]) continue;

        NSString *name = [library[@"name"] isKindOfClass:[NSString class]] ? library[@"name"] : nil;
        if (!name) continue;

        // 参照 FCL/HMCL：评估库的 OS rules，iOS 视为 osx。
        // 跳过仅在 Windows/Linux 上启用的库（如 natives-windows、twitch 平台库等），
        // 避免下载无用的二进制 natives 和潜在的 404 失败。
        id rulesObj = library[@"rules"];
        if ([rulesObj isKindOfClass:[NSArray class]] && [(NSArray *)rulesObj count] > 0) {
            if (![MinecraftResourceUtils evaluateRules:(NSArray *)rulesObj]) {
                NSLog(@"[ForgeDirect] Skipping library %@ (OS rules disallow osx/iOS)", name);
                skipped++;
                processed++;
                continue;
            }
        }

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
            // 用 maven 仓库拼接（Forge 库走 maven.minecraftforge.net，其他走 libraries.minecraft.net）
            url = [self buildMavenURLForLibrary:name relativePath:relativePath];
        }

        if (!url) {
            NSLog(@"[ForgeDirect] Cannot build URL for library %@, skipping", name);
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
            NSLog(@"[ForgeDirect] Downloaded library: %@", name);
        } else {
            // 主源失败：尝试 fallback 源（BMCLAPI ↔ 官方源）
            NSLog(@"[ForgeDirect] Primary source failed for %@, trying fallback: %@", name, downloadError.localizedDescription ?: @"unknown");
            NSString *fallbackURL = [self buildFallbackURLForLibrary:name relativePath:relativePath];
            if (fallbackURL && ![fallbackURL isEqualToString:url]) {
                NSError *fallbackError = nil;
                if ([self downloadFileFromURL:fallbackURL toPath:destPath error:&fallbackError]) {
                    downloaded++;
                    NSLog(@"[ForgeDirect] Downloaded library via fallback: %@", name);
                    processed++;
                    continue;
                }
                NSLog(@"[ForgeDirect] Fallback also failed for %@: %@", name, fallbackError.localizedDescription ?: @"unknown");
            }
            failed++;
            // 关键库（modlauncher、bootstraplauncher、mixin、asm、forge/neoforged 自家库）失败会启动崩溃，记录警告
            if ([self isCriticalLibrary:name]) {
                [criticalFailures addObject:name];
                NSLog(@"[ForgeDirect] ⚠️ 关键库下载失败（启动将崩溃）: %@", name);
            } else {
                NSLog(@"[ForgeDirect] Failed to download library %@ (both sources failed)", name);
            }
            // 不中断流程，部分库可能不重要或可由游戏启动时再次下载
        }
        processed++;
    }

    NSLog(@"[ForgeDirect] Library download summary: downloaded=%lu, skipped=%lu, failed=%lu, total=%lu, criticalFailures=%lu",
          (unsigned long)downloaded, (unsigned long)skipped, (unsigned long)failed, (unsigned long)total, (unsigned long)criticalFailures.count);
    if (criticalFailures.count > 0) {
        NSLog(@"[ForgeDirect] ⚠️ 关键库下载失败清单: %@", criticalFailures);
    }
}

/// 判断是否为关键库（缺失会导致启动崩溃）
+ (BOOL)isCriticalLibrary:(NSString *)name {
    if (!name.length) return NO;
    // modlauncher、bootstraplauncher、mixin、asm、forge/neoforged 自家库、jimfs 等核心运行时依赖
    NSArray<NSString *> *criticalPrefixes = @[
        @"cpw.mods:modlauncher",
        @"net.minecraftforge.bootstraplauncher",
        @"net.minecraftforge:forge",
        @"net.minecraftforge:fmlloader",
        @"net.minecraftforge:javafmllanguage",
        @"net.minecraftforge:lowcodelanguage",
        @"net.minecraftforge:mclanguage",
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

    // Forge 自家库走 maven.minecraftforge.net
    if ([name hasPrefix:@"net.minecraftforge:"]) {
        if (useBMCLAPI) {
            return [NSString stringWithFormat:@"https://bmclapi2.bangbang93.com/maven/%@", relativePath];
        }
        return [NSString stringWithFormat:@"https://maven.minecraftforge.net/%@", relativePath];
    }

    // NeoForge 自家库走 maven.neoforged.net
    if ([name hasPrefix:@"net.neoforged:"] || [name hasPrefix:@"net.neoforged."]) {
        if (useBMCLAPI) {
            return [NSString stringWithFormat:@"https://bmclapi2.bangbang93.com/maven/%@", relativePath];
        }
        return [NSString stringWithFormat:@"https://maven.neoforged.net/releases/%@", relativePath];
    }

    // cpw.mods:modlauncher 是 Forge 1.13+ 核心依赖，主源是 Forge maven
    if ([name hasPrefix:@"cpw.mods:"]) {
        if (useBMCLAPI) {
            return [NSString stringWithFormat:@"https://bmclapi2.bangbang93.com/maven/%@", relativePath];
        }
        return [NSString stringWithFormat:@"https://maven.minecraftforge.net/%@", relativePath];
    }

    // SpongePowered (mixin、asm 等) 走 repo.spongepowered.org
    if ([name hasPrefix:@"org.spongepowered:"]) {
        if (useBMCLAPI) {
            return [NSString stringWithFormat:@"https://bmclapi2.bangbang93.com/maven/%@", relativePath];
        }
        return [NSString stringWithFormat:@"https://repo.spongepowered.org/repository/maven-public/%@", relativePath];
    }

    // oceanlabs (mcp_config、mcp_mappings 等) 走 maven.minecraftforge.net（Forge 镜像了这些）
    if ([name hasPrefix:@"de.oceanlabs.mcp:"]) {
        if (useBMCLAPI) {
            return [NSString stringWithFormat:@"https://bmclapi2.bangbang93.com/maven/%@", relativePath];
        }
        return [NSString stringWithFormat:@"https://maven.minecraftforge.net/%@", relativePath];
    }

    // asm (ow2 asm) 走 maven.minecraftforge.net（Forge 镜像了 asm）
    if ([name hasPrefix:@"org.ow2.asm:"]) {
        if (useBMCLAPI) {
            return [NSString stringWithFormat:@"https://bmclapi2.bangbang93.com/maven/%@", relativePath];
        }
        return [NSString stringWithFormat:@"https://maven.minecraftforge.net/%@", relativePath];
    }

    // MojoHaus (bootstraplauncher、installertools 等) 优先走 maven.minecraftforge.net
    if ([name hasPrefix:@"net.minecraftforge.installertools:"] ||
        [name hasPrefix:@"net.minecraftforge.bootstraplauncher:"]) {
        if (useBMCLAPI) {
            return [NSString stringWithFormat:@"https://bmclapi2.bangbang93.com/maven/%@", relativePath];
        }
        return [NSString stringWithFormat:@"https://maven.minecraftforge.net/%@", relativePath];
    }

    // JitPack (部分 modlauncher 依赖)
    if ([name hasPrefix:@"com.machinezoo.noexception:"] ||
        [name hasPrefix:@"org.codehaus.mojo:"]) {
        if (useBMCLAPI) {
            return [NSString stringWithFormat:@"https://bmclapi2.bangbang93.com/maven/%@", relativePath];
        }
        return [NSString stringWithFormat:@"https://maven.minecraftforge.net/%@", relativePath];
    }

    // 其他库（Mojang、lwjgl、gson 等）走 libraries.minecraft.net（BMCLAPI 镜像）
    if (useBMCLAPI) {
        return [NSString stringWithFormat:@"https://bmclapi2.bangbang93.com/maven/%@", relativePath];
    }
    return [NSString stringWithFormat:@"https://libraries.minecraft.net/%@", relativePath];
}

/// 构建 fallback URL（当主源失败时切换到 BMCLAPI 镜像，或反之）
+ (NSString *)buildFallbackURLForLibrary:(NSString *)name relativePath:(NSString *)relativePath {
    NSString *downloadSource = getPrefObject(@"general.download_source");
    BOOL useBMCLAPI = [downloadSource isEqualToString:@"bmclapi"];

    // 主源是 BMCLAPI 时，fallback 到官方源；主源是官方源时，fallback 到 BMCLAPI
    if (useBMCLAPI) {
        // 从 BMCLAPI 失败，尝试官方源
        if ([name hasPrefix:@"net.minecraftforge:"] || [name hasPrefix:@"de.oceanlabs.mcp:"] || [name hasPrefix:@"org.ow2.asm:"] || [name hasPrefix:@"cpw.mods:"]) {
            return [NSString stringWithFormat:@"https://maven.minecraftforge.net/%@", relativePath];
        }
        if ([name hasPrefix:@"net.neoforged:"] || [name hasPrefix:@"net.neoforged."]) {
            return [NSString stringWithFormat:@"https://maven.neoforged.net/releases/%@", relativePath];
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

    // 参照 FCL/HMCL：尝试多个 classifier。
    // 实测 Forge maven（如 1.21.11-61.0.x）通常只发布 -universal（HTTP 200），
    // -client 和无 classifier 均 404。早期 Forge（1.7-1.12）也主要用 -universal。
    // 调整顺序为 universal -> client -> 无 classifier，优先尝试成功率最高的 universal，
    // 避免先尝试必定 404 的 client 浪费时间（每次 404 仍需等待响应）。
    NSArray *classifiers = @[@"universal", @"client", @""];
    NSString *downloadSource = getPrefObject(@"general.download_source");
    BOOL useBMCLAPI = [downloadSource isEqualToString:@"bmclapi"];

    // 源 URL 构造：官方源 + BMCLAPI + HMCL 镜像
    // 注意：腾讯云镜像（mirrors.cloud.tencent.com/maven）不镜像 Forge/NeoForge maven，
    // 之前作为 fallback 是错误配置，已替换为 HMCL 镜像（mirror.hua-u.me）。
    NSMutableArray *baseURLs = [NSMutableArray array];
    if ([groupId hasPrefix:@"net.neoforged"]) {
        if (useBMCLAPI) {
            [baseURLs addObject:@"https://bmclapi2.bangbang93.com/maven"];
            [baseURLs addObject:@"https://maven.neoforged.net/releases"];
        } else {
            [baseURLs addObject:@"https://maven.neoforged.net/releases"];
            [baseURLs addObject:@"https://bmclapi2.bangbang93.com/maven"];
        }
    } else {
        if (useBMCLAPI) {
            [baseURLs addObject:@"https://bmclapi2.bangbang93.com/maven"];
            [baseURLs addObject:@"https://maven.minecraftforge.net"];
        } else {
            [baseURLs addObject:@"https://maven.minecraftforge.net"];
            [baseURLs addObject:@"https://bmclapi2.bangbang93.com/maven"];
        }
    }
    // HMCL 镜像作为最后兜底（国内可用性较好，且镜像了 Forge maven）
    if ([groupId hasPrefix:@"net.neoforged"]) {
        [baseURLs addObject:@"https://mirror.hua-u.me/neoforge"];
    } else {
        [baseURLs addObject:@"https://mirror.hua-u.me/forge"];
    }

    NSError *lastError = nil;
    NSString *firstTriedURL = nil;
    for (NSString *classifier in classifiers) {
        NSString *jarName;
        if (classifier.length > 0) {
            jarName = [NSString stringWithFormat:@"%@-%@-%@.jar", artifactId, version, classifier];
        } else {
            jarName = [NSString stringWithFormat:@"%@-%@.jar", artifactId, version];
        }
        NSString *relativePath = [NSString stringWithFormat:@"%@/%@/%@/%@", groupPath, artifactId, version, jarName];
        NSString *destPath = [librariesDir stringByAppendingPathComponent:relativePath];

        // 已存在则跳过
        if ([NSFileManager.defaultManager fileExistsAtPath:destPath]) {
            NSLog(@"[ForgeDirect] Patched artifact already exists: %@", destPath);
            return YES;
        }

        for (NSString *baseURL in baseURLs) {
            NSString *url = [NSString stringWithFormat:@"%@/%@", baseURL, relativePath];
            if (firstTriedURL == nil) firstTriedURL = url;
            NSLog(@"[ForgeDirect] Trying classifier=%@ source=%@", classifier, url);
            NSError *downloadError = nil;
            if ([self downloadFileFromURL:url toPath:destPath error:&downloadError]) {
                NSLog(@"[ForgeDirect] Patched artifact downloaded: %@ (classifier=%@)", destPath, classifier);
                return YES;
            }
            // 下载失败：清理可能的部分文件，避免下次误判已存在
            [NSFileManager.defaultManager removeItemAtPath:destPath error:nil];
            lastError = downloadError;
            NSLog(@"[ForgeDirect] Failed: %@ (%@)", url, downloadError.localizedDescription ?: @"未知错误");
        }
    }

    if (error) {
        *error = [NSError errorWithDomain:ForgeDirectInstallerErrorDomain
                                     code:ForgeDirectInstallerErrorExtractionFailed
                                 userInfo:@{
                                     NSLocalizedDescriptionKey: [NSString stringWithFormat:@"下载预打补丁核心 jar 失败\n主源 URL: %@\n已尝试 classifier: client/universal/无\n已尝试源: 官方/BMCLAPI/HMCL镜像\n最后错误: %@",
                                         firstTriedURL ?: @"未知",
                                         lastError.localizedDescription ?: @"未知错误"]
                                 }];
    }
    return NO;
}

// 安全创建目录：若路径上存在同名普通文件（之前安装失败残留），先删除再创建。
// APFS 不允许同名文件和目录共存，直接 createDirectoryAtPath 会失败。
+ (BOOL)ensureDirectoryExists:(NSString *)path error:(NSError **)error {
    NSFileManager *fm = NSFileManager.defaultManager;
    BOOL isDir = NO;
    if ([fm fileExistsAtPath:path isDirectory:&isDir]) {
        if (isDir) return YES; // 目录已存在
        // 存在同名普通文件，删除它
        NSError *removeError = nil;
        if (![fm removeItemAtPath:path error:&removeError]) {
            if (error) {
                *error = [NSError errorWithDomain:ForgeDirectInstallerErrorDomain
                                             code:ForgeDirectInstallerErrorWriteFailed
                                         userInfo:@{NSLocalizedDescriptionKey: [NSString stringWithFormat:@"无法删除冲突文件 %@: %@", path, removeError.localizedDescription]}];
            }
            return NO;
        }
    }
    NSError *createError = nil;
    [fm createDirectoryAtPath:path withIntermediateDirectories:YES attributes:nil error:&createError];
    if (createError) {
        if (error) *error = createError;
        return NO;
    }
    return YES;
}

// 同步下载文件到指定路径（带 60 秒超时）
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

    // 创建目标目录（处理同名文件冲突）
    NSString *destDir = [destPath stringByDeletingLastPathComponent];
    NSError *dirError = nil;
    if (![self ensureDirectoryExists:destDir error:&dirError]) {
        if (error) {
            *error = dirError ?: [NSError errorWithDomain:ForgeDirectInstallerErrorDomain
                                                   code:ForgeDirectInstallerErrorWriteFailed
                                               userInfo:@{NSLocalizedDescriptionKey: [NSString stringWithFormat:@"Failed to create directory %@: %@", destDir, dirError.localizedDescription]}];
        }
        return NO;
    }

    // 用 NSURLSession 同步下载，带 60 秒超时（避免弱网下 dataWithContentsOfURL 挂死）
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:url];
    request.timeoutInterval = 60.0;
    request.cachePolicy = NSURLRequestReloadIgnoringLocalCacheData;
    // 添加 User-Agent：部分 maven 仓库（BMCLAPI/Cloudflare 保护的源）会拒绝非浏览器 UA（403/WAF）。
    // 参照 FCL 使用浏览器风格 UA 提升兼容性。
    [request setValue:@"Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15" forHTTPHeaderField:@"User-Agent"];
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
                resultError = [NSError errorWithDomain:ForgeDirectInstallerErrorDomain
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
            *error = [NSError errorWithDomain:ForgeDirectInstallerErrorDomain
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
            *error = [NSError errorWithDomain:ForgeDirectInstallerErrorDomain
                                         code:ForgeDirectInstallerErrorWriteFailed
                                     userInfo:@{NSLocalizedDescriptionKey: [NSString stringWithFormat:@"Empty response: %@", urlString]}];
        }
        return NO;
    }

    BOOL written = [resultData writeToFile:destPath options:NSDataWritingAtomic error:error];
    if (!written) {
        return NO;
    }

    NSLog(@"[ForgeDirect] Downloaded %@ (%lu bytes) -> %@", urlString.lastPathComponent ?: urlString, (unsigned long)resultData.length, destPath);
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
