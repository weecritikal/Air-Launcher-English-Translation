#include <CommonCrypto/CommonDigest.h>
#include <sys/time.h>

#import "authenticator/BaseAuthenticator.h"
#import "installer/modpack/ModpackAPI.h"
#import "AFNetworking.h"
#import "LauncherNavigationController.h"
#import "LauncherPreferences.h"
#import "MinecraftResourceDownloadTask.h"
#import "MinecraftResourceUtils.h"
#import "DownloadTaskManager.h"
#import "DownloadTaskItem.h"
#import "ios_uikit_bridge.h"
#import "utils.h"

NSString * const kMinecraftResourceDownloadBackgroundSessionIdentifier = @"com.air-devs.air.MinecraftResourceDownloadTask";

@interface MinecraftResourceDownloadTask ()
@property AFURLSessionManager* manager;
@property (nonatomic, strong) DownloadTaskItem *currentDownloadTaskItem;
@property (nonatomic, copy) NSString *currentVersionId;
@property (nonatomic, assign) BOOL isObservingTaskProgress;
@property (nonatomic, assign) NSTimeInterval progressLastTime;
@property (nonatomic, assign) int64_t progressLastCompleted;
@end

@implementation MinecraftResourceDownloadTask

+ (AFURLSessionManager *)sharedBackgroundSessionManager {
    // 参照 main 分支：使用前台 defaultSessionConfiguration 而非后台 backgroundSessionConfiguration。
    //
    // 为什么不用后台 URLSession：
    // 1. 后台会话由系统守护进程 nsurlsessiond 调度，会限流并发数、串行化任务，
    //    导致原版下载（数百个 asset + 数十个 library）极慢，"转圈不下载"。
    // 2. 后台会话的未完成任务会被系统持久化，失败/取消不干净时残留 task 卡住新下载。
    // 3. 前台会话 resume 即立即并发执行，适合启动器这种前台活跃下载场景。
    //
    // 保留单例模式（避免每次 init 都创建新会话），但使用前台配置。
    static AFURLSessionManager *manager = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        NSURLSessionConfiguration *configuration = [NSURLSessionConfiguration defaultSessionConfiguration];
        configuration.timeoutIntervalForRequest = 86400;
        // 参考 FCL（FoldCraftLauncher）和 ZalithLauncher2：高并发下载加速。
        // FCL 在 Java 端使用 OkHttp 的线程池并发下载，本项目对应在 NSURLSession
        // 层面提升 HTTPMaximumConnectionsPerHost。从 16 提升到 24，加速原版数百个
        // asset 的并发下载。注意 iOS 系统对单 host 实际并发有调度上限，过高的设置
        // 会被系统降级，24 是经验值。完整性仍由 SHA1 校验保证。
        configuration.HTTPMaximumConnectionsPerHost = 24;
        manager = [[AFURLSessionManager alloc] initWithSessionConfiguration:configuration];
    });
    return manager;
}

- (void)dealloc {
    if (self.isObservingTaskProgress && self.progress) {
        @try {
            [self.progress removeObserver:self forKeyPath:@"fractionCompleted"];
        } @catch (NSException *exception) {
            // ignore
        }
        self.isObservingTaskProgress = NO;
    }
}

- (instancetype)init {
    self = [super init];
    self.manager = [MinecraftResourceDownloadTask sharedBackgroundSessionManager];
    self.fileList = [NSMutableArray new];
    self.progressList = [NSMutableArray new];
    // 阶段5修复：初始化失败文件列表（参照 FCL 的失败汇总机制）
    self.failedFiles = [NSMutableArray new];
    return self;
}

// 根据配置选择下载源并替换URL
- (NSString *)replaceURLWithDownloadSource:(NSString *)originalURL {
    return [self replaceURLWithDownloadSource:originalURL forceSource:nil];
}

/// 镜像源替换核心实现。
/// 参考 FCL（FoldCraftLauncher）和 ZalithLauncher2：支持多镜像源 fallback。
/// @param originalURL 原始 URL
/// @param forceSource 强制使用的源（nil=用用户偏好；@"official"=不替换；@"bmclapi"=强制 BMCLAPI）。
///                    在下载失败重试时，调用方传入对端源以触发镜像源切换，
///                    避免单一镜像源故障导致整批下载卡死。
- (NSString *)replaceURLWithDownloadSource:(NSString *)originalURL forceSource:(nullable NSString *)forceSource {
    if (!originalURL) return originalURL;

    NSString *downloadSource = forceSource ?: getPrefObject(@"general.download_source");
    if (!downloadSource || [downloadSource isEqualToString:@"official"]) {
        return originalURL;
    }

    // BMCLAPI镜像源
    if ([downloadSource isEqualToString:@"bmclapi"]) {
        // piston-meta.mojang.com：Mojang 新版版本清单和版本 JSON 域名（1.19+ 起使用）
        // 修复：原版安装时 version.json 直连此域名，国内超时导致转圈不下载
        if ([originalURL containsString:@"piston-meta.mojang.com"]) {
            originalURL = [originalURL stringByReplacingOccurrencesOfString:@"https://piston-meta.mojang.com"
                                                                withString:@"https://bmclapi2.bangbang93.com"];
        }
        // piston-data.mojang.com：Mojang 新版 client.jar 和资源下载域名
        if ([originalURL containsString:@"piston-data.mojang.com"]) {
            originalURL = [originalURL stringByReplacingOccurrencesOfString:@"https://piston-data.mojang.com"
                                                                withString:@"https://bmclapi2.bangbang93.com"];
        }

        // 版本清单和版本JSON（旧域名，向后兼容）
        if ([originalURL containsString:@"launchermeta.mojang.com"] ||
            [originalURL containsString:@"launcher.mojang.com"]) {
            return [originalURL stringByReplacingOccurrencesOfString:@"https://launchermeta.mojang.com"
                                                           withString:@"https://bmclapi2.bangbang93.com"];
        }

        // Assets资源
        if ([originalURL containsString:@"resources.download.minecraft.net"]) {
            return [originalURL stringByReplacingOccurrencesOfString:@"http://resources.download.minecraft.net"
                                                           withString:@"https://bmclapi2.bangbang93.com/assets"];
        }

        // Libraries库文件
        if ([originalURL containsString:@"libraries.minecraft.net"]) {
            return [originalURL stringByReplacingOccurrencesOfString:@"https://libraries.minecraft.net"
                                                           withString:@"https://bmclapi2.bangbang93.com/maven"];
        }

        // Forge
        if ([originalURL containsString:@"files.minecraftforge.net"]) {
            return [originalURL stringByReplacingOccurrencesOfString:@"https://files.minecraftforge.net"
                                                           withString:@"https://bmclapi2.bangbang93.com"];
        }

        // Fabric
        if ([originalURL containsString:@"meta.fabricmc.net"]) {
            return [originalURL stringByReplacingOccurrencesOfString:@"https://meta.fabricmc.net"
                                                           withString:@"https://bmclapi2.bangbang93.com/fabric-meta"];
        }

        if ([originalURL containsString:@"maven.fabricmc.net"]) {
            return [originalURL stringByReplacingOccurrencesOfString:@"https://maven.fabricmc.net"
                                                           withString:@"https://bmclapi2.bangbang93.com/maven"];
        }

        // NeoForge
        if ([originalURL containsString:@"maven.neoforged.net"]) {
            return [originalURL stringByReplacingOccurrencesOfString:@"https://maven.neoforged.net"
                                                           withString:@"https://bmclapi2.bangbang93.com/maven"];
        }

        // authlib-injector
        if ([originalURL containsString:@"authlib-injector.yushi.moe"]) {
            return [originalURL stringByReplacingOccurrencesOfString:@"https://authlib-injector.yushi.moe"
                                                           withString:@"https://bmclapi2.bangbang93.com/mirrors/authlib-injector"];
        }

        // Mojang Java运行时
        if ([originalURL containsString:@"launchermeta.mojang.com/v1/products/java-runtime"]) {
            return [originalURL stringByReplacingOccurrencesOfString:@"https://launchermeta.mojang.com"
                                                           withString:@"https://bmclapi2.bangbang93.com"];
        }
    }

    return originalURL;
}

// Add file to the queue
- (NSURLSessionDownloadTask *)createDownloadTask:(NSString *)url size:(NSUInteger)size sha:(NSString *)sha altName:(NSString *)altName toPath:(NSString *)path success:(void (^)())success {
    return [self createDownloadTask:url size:size sha:sha altName:altName toPath:path retryCount:0 success:success];
}

- (NSURLSessionDownloadTask *)createDownloadTask:(NSString *)url size:(NSUInteger)size sha:(NSString *)sha altName:(NSString *)altName toPath:(NSString *)path retryCount:(NSInteger)retryCount success:(void (^)())success {
    BOOL fileExists = [NSFileManager.defaultManager fileExistsAtPath:path];
    // logSuccess?
    if (fileExists && [self checkSHA:sha forFile:path altName:altName]) {
        if (success) success();
        return nil;
    } else if (![self checkAccessWithDialog:YES]) {
        return nil;
    }

    NSString *name = altName ?: path.lastPathComponent;
    // 根据配置选择下载源并替换URL
    // 参考 FCL（FoldCraftLauncher）和 ZalithLauncher2：重试时切换到对端镜像源，
    // 避免单一镜像源故障导致整批下载卡死。SHA1 校验仍照常进行，不破坏下载完整性。
    NSString *forceSource = nil;
    if (retryCount > 0) {
        NSString *currentSource = getPrefObject(@"general.download_source") ?: @"bmclapi";
        forceSource = [currentSource isEqualToString:@"bmclapi"] ? @"official" : @"bmclapi";
        NSLog(@"[MCDL] Retry %@ with fallback source: %@", name, forceSource);
    }
    NSString *replacedURL = [self replaceURLWithDownloadSource:url forceSource:forceSource];
    NSURLRequest *request = [NSURLRequest requestWithURL:[NSURL URLWithString:replacedURL]];
    __block NSProgress *progress;
    __weak MinecraftResourceDownloadTask *weakSelf = self;
    __block NSURLSessionDownloadTask *task = [self.manager downloadTaskWithRequest:request progress:nil
    destination:^NSURL * _Nonnull(NSURL * _Nonnull targetPath, NSURLResponse * _Nonnull response) {
        NSLog(@"[MCDL] Downloading %@", name);
        if (!weakSelf) {
            [NSFileManager.defaultManager createDirectoryAtPath:path.stringByDeletingLastPathComponent withIntermediateDirectories:YES attributes:nil error:nil];
            [NSFileManager.defaultManager removeItemAtPath:path error:nil];
            return [NSURL fileURLWithPath:path];
        }
        progress = [weakSelf.manager downloadProgressForTask:task];
        if (!size && task) {
            [weakSelf addDownloadTaskToProgress:task size:response.expectedContentLength];
            [weakSelf.fileList addObject:name];
        }
        [NSFileManager.defaultManager createDirectoryAtPath:path.stringByDeletingLastPathComponent withIntermediateDirectories:YES attributes:nil error:nil];
        [NSFileManager.defaultManager removeItemAtPath:path error:nil];
        return [NSURL fileURLWithPath:path];
    } completionHandler:^(NSURLResponse * _Nonnull response, NSURL * _Nullable filePath, NSError * _Nullable error) {
        if (self.progress.cancelled) {
            // Ignore any further errors
        } else if (error != nil) {
            // 重试机制
            NSInteger maxRetry = weakSelf.maxRetryCount > 0 ? weakSelf.maxRetryCount : 3;
            if (retryCount < maxRetry) {
                NSInteger nextRetry = retryCount + 1;
                NSLog(@"[MCDL] Retrying %@ (attempt %ld/%ld)", name, (long)nextRetry, (long)maxRetry);
                
                if (weakSelf.retryCallback) {
                    dispatch_async(dispatch_get_main_queue(), ^{
                        weakSelf.retryCallback(nextRetry, maxRetry);
                    });
                }
                
                // 延迟重试（缩短到 0.5 秒，避免数百个文件重试时累加延迟过长）
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                    NSURLSessionDownloadTask *retryTask = [weakSelf createDownloadTask:url size:size sha:sha altName:altName toPath:path retryCount:nextRetry success:success];
                    if (retryTask) {
                        [retryTask resume];
                    }
                });
            } else {
                [weakSelf finishDownloadWithError:error file:name];
                // 阶段5修复（参照 FCL）：单文件失败后必须手动推进进度，否则父 progress
                // 永远不会达到 100%（failed 子 progress 的份额无人填补），
                // 用户会看到下载条卡住不动，误以为下载未完成。
                // 注意：destination block 只在下载成功时才会被调用，所以这里 progress
                // 可能为 nil。需要重新从 manager 取该 task 对应的子 progress。
                NSProgress *taskProgress = progress ?: [weakSelf.manager downloadProgressForTask:task];
                if (taskProgress) {
                    int64_t pending = taskProgress.totalUnitCount - taskProgress.completedUnitCount;
                    if (pending > 0) {
                        taskProgress.completedUnitCount = taskProgress.totalUnitCount;
                    }
                } else if (weakSelf.progress.totalUnitCount > weakSelf.progress.completedUnitCount) {
                    // 极端兜底：连子 progress 都拿不到（如 size 未知且 destination 未触发），
                    // 直接给父 progress 推 1 个单位，避免下载条卡死。
                    weakSelf.progress.completedUnitCount += 1;
                }
            }
        } else if (![self checkSHA:sha forFile:path altName:altName]) {
            // SHA1 校验失败也尝试重试
            NSInteger maxRetry = weakSelf.maxRetryCount > 0 ? weakSelf.maxRetryCount : 3;
            if (retryCount < maxRetry) {
                NSInteger nextRetry = retryCount + 1;
                NSLog(@"[MCDL] SHA1 mismatch, retrying %@ (attempt %ld/%ld)", name, (long)nextRetry, (long)maxRetry);

                // 删除损坏的文件
                [NSFileManager.defaultManager removeItemAtPath:path error:nil];

                // SHA 失败重试延迟缩短到 0.3 秒
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.3 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                    NSURLSessionDownloadTask *retryTask = [weakSelf createDownloadTask:url size:size sha:sha altName:altName toPath:path retryCount:nextRetry success:success];
                    if (retryTask) {
                        [retryTask resume];
                    }
                });
            } else {
                // 阶段5修复（参照 FCL）：SHA1 校验失败也记录到 failedFiles，不取消整批任务
                @synchronized(weakSelf.failedFiles) {
                    [weakSelf.failedFiles addObject:@{
                        @"name": path.lastPathComponent ?: @"unknown",
                        @"error": @"SHA1 mismatch"
                    }];
                }
                NSLog(@"[MCDL] SHA1 mismatch for '%@', added to failedFiles (total failed: %lu), other downloads will continue",
                      path.lastPathComponent, (unsigned long)weakSelf.failedFiles.count);
                // 阶段5修复：与上面 error 分支一致，推进父 progress 避免卡死
                NSProgress *taskProgress2 = progress ?: [weakSelf.manager downloadProgressForTask:task];
                if (taskProgress2) {
                    int64_t pending = taskProgress2.totalUnitCount - taskProgress2.completedUnitCount;
                    if (pending > 0) {
                        taskProgress2.completedUnitCount = taskProgress2.totalUnitCount;
                    }
                } else if (weakSelf.progress.totalUnitCount > weakSelf.progress.completedUnitCount) {
                    weakSelf.progress.completedUnitCount += 1;
                }
            }
        } else {
            progress.totalUnitCount = progress.completedUnitCount;
            if (success) success();
        }
    }];

    if (size && task) {
        [self addDownloadTaskToProgress:task size:size];
        [self.fileList addObject:name];
    }

    if (task && self.currentDownloadTaskItem) {
        task.taskDescription = self.currentDownloadTaskItem.taskId;
    }

    return task;
}

- (NSURLSessionDownloadTask *)createDownloadTask:(NSString *)url size:(NSUInteger)size sha:(NSString *)sha altName:(NSString *)altName toPath:(NSString *)path {
    return [self createDownloadTask:url size:size sha:sha altName:altName toPath:path success:nil];
}

- (void)addDownloadTaskToProgress:(NSURLSessionDownloadTask *)task size:(NSInteger)size {
    NSProgress *progress = [self.manager downloadProgressForTask:task];
    NSUInteger fileSize = size>0 ? size : 1;
    progress.kind = NSProgressKindFile;
    if (size > 0) {
        progress.totalUnitCount = fileSize;
    }
    [self.progressList addObject:progress];
    [self.progress addChild:progress withPendingUnitCount:fileSize];
    self.progress.totalUnitCount += fileSize;
    self.textProgress.totalUnitCount = self.progress.totalUnitCount;
}

- (void)downloadVersionMetadata:(NSDictionary *)version success:(void (^)())success {
    // Download base json
    NSString *versionStr = version[@"id"];
    if ([versionStr isEqualToString:@"latest-release"]) {
        versionStr = getPrefObject(@"internal.latest_version.release");
    } else if ([versionStr isEqualToString:@"latest-snapshot"]) {
        versionStr = getPrefObject(@"internal.latest_version.snapshot");
    }

    NSString *path = [NSString stringWithFormat:@"%1$s/versions/%2$@/%2$@.json", getenv("POJAV_GAME_DIR"), versionStr];
    // Find it again to resolve latest-*
    version = (id)[MinecraftResourceUtils findVersion:versionStr inList:remoteVersionList];

    void(^completionBlock)(void) = ^{
        self.metadata = parseJSONFromFile(path);
        if (self.metadata[@"NSErrorObject"]) {
            [self finishDownloadWithErrorString:[self.metadata[@"NSErrorObject"] localizedDescription]];
            return;
        }
        if (self.metadata[@"inheritsFrom"]) {
            NSMutableDictionary *inheritsFromDict = parseJSONFromFile([NSString stringWithFormat:@"%1$s/versions/%2$@/%2$@.json", getenv("POJAV_GAME_DIR"), self.metadata[@"inheritsFrom"]]);
            if (inheritsFromDict && !inheritsFromDict[@"NSErrorObject"]) {  // 添加错误字典检测
                // 修复：parseJSONFromFile 返回错误字典而非 nil，
                //   导致 inheritsFrom 父版本缺失时错误字典被当作 metadata
                [MinecraftResourceUtils processVersion:self.metadata inheritsFrom:inheritsFromDict];
                self.metadata = inheritsFromDict;
            } else {
                // 父版本不存在或损坏，报错
                [self finishDownloadWithErrorString:[NSString stringWithFormat:@"缺少父版本 %@ 的 version.json", self.metadata[@"inheritsFrom"]]];
                return;
            }
        }
        [MinecraftResourceUtils tweakVersionJson:self.metadata];
        success();
    };

    if (!version) {
        // This is likely local version, check if json exists and has inheritsFrom
        NSMutableDictionary *json = parseJSONFromFile(path);
        if (json[@"NSErrorObject"]) {
            [self finishDownloadWithErrorString:[json[@"NSErrorObject"] localizedDescription]];
            return;
        } else if (json[@"inheritsFrom"]) {
            version = (id)[MinecraftResourceUtils findVersion:json[@"inheritsFrom"] inList:remoteVersionList];
            if (version) {
                path = [NSString stringWithFormat:@"%1$s/versions/%2$@/%2$@.json", getenv("POJAV_GAME_DIR"), json[@"inheritsFrom"]];
            } else {
                // 阶段5修复（参照 FCL ModpackHelper.ensureCompleteVersion）：
                // findVersion 失败通常因为 remoteVersionList 尚未加载（整合包导入在后台线程，
                // 不经过 DownloadViewController 的清单加载流程）。
                // 此时检查父版本 JSON 是否已由 ensureParentVersionExists 预先下载：
                //   - 已存在 → 直接走 completionBlock，后续 libraries/assets 下载照常进行
                //   - 不存在 → 报错（启动器无法继续）
                NSString *parentJsonPath = [NSString stringWithFormat:@"%1$s/versions/%2$@/%2$@.json",
                                            getenv("POJAV_GAME_DIR"), json[@"inheritsFrom"]];
                if ([NSFileManager.defaultManager fileExistsAtPath:parentJsonPath]) {
                    NSLog(@"[MCDL] remoteVersionList 未加载，但父版本 JSON 已存在：%@", parentJsonPath);
                    completionBlock();
                    return;
                } else {
                    [self finishDownloadWithErrorString:[NSString stringWithFormat:@"缺少父版本 %@ 的 version.json，且远程版本清单未加载，无法自动下载", json[@"inheritsFrom"]]];
                    return;
                }
            }
        } else {
            completionBlock();
            return;
        }
    }

    versionStr = version[@"id"];
    NSString *url = version[@"url"];
    NSString *sha = url.stringByDeletingLastPathComponent.lastPathComponent;
    NSUInteger size = [version[@"size"] unsignedLongLongValue];

    NSURLSessionDownloadTask *task = [self createDownloadTask:url size:size sha:sha altName:nil toPath:path success:completionBlock];
    [task resume];
}

#pragma mark - Minecraft installation

- (void)downloadAssetMetadataWithSuccess:(void (^)())success {
    NSDictionary *assetIndex = self.metadata[@"assetIndex"];
    if (!assetIndex) {
        success();
        return;
    }
    NSString *name = [NSString stringWithFormat:@"assets/indexes/%@.json", assetIndex[@"id"]];
    NSString *path = [@(getenv("POJAV_GAME_DIR")) stringByAppendingPathComponent:name];
    NSString *url = assetIndex[@"url"];
    NSString *sha = url.stringByDeletingLastPathComponent.lastPathComponent;
    NSUInteger size = [assetIndex[@"size"] unsignedLongLongValue];
    NSURLSessionDownloadTask *task = [self createDownloadTask:url size:size sha:sha altName:name toPath:path success:^{
        self.metadata[@"assetIndexObj"] = parseJSONFromFile(path);
        success();
    }];
    [task resume];
}

- (NSArray *)downloadClientLibraries {
    NSMutableArray *tasks = [NSMutableArray new];
    for (NSDictionary *library in self.metadata[@"libraries"]) {
        NSString *name = library[@"name"];

        NSMutableDictionary *artifact = library[@"downloads"][@"artifact"];
        if (artifact == nil && [name containsString:@":"]) {
            NSLog(@"[MCDL] Unknown artifact object for %@, attempting to generate one", name);
            artifact = [[NSMutableDictionary alloc] init];
            NSString *prefix = library[@"url"] == nil ? @"https://libraries.minecraft.net/" : [library[@"url"] stringByReplacingOccurrencesOfString:@"http://" withString:@"https://"];
            NSArray *libParts = [name componentsSeparatedByString:@":"];
            artifact[@"path"] = [NSString stringWithFormat:@"%1$@/%2$@/%3$@/%2$@-%3$@.jar", [libParts[0] stringByReplacingOccurrencesOfString:@"." withString:@"/"], libParts[1], libParts[2]];
            artifact[@"url"] = [NSString stringWithFormat:@"%@%@", prefix, artifact[@"path"]];
            artifact[@"sha1"] = library[@"checksums"][0];
        }

        NSString *path = [NSString stringWithFormat:@"%s/libraries/%@", getenv("POJAV_GAME_DIR"), artifact[@"path"]];
        NSString *sha = artifact[@"sha1"];
        NSUInteger size = [artifact[@"size"] unsignedLongLongValue];
        NSString *url = artifact[@"url"];
        if ([library[@"skip"] boolValue]) {
            NSLog(@"[MDCL] Skipped library %@", name);
            continue;
        }

        NSURLSessionDownloadTask *task = [self createDownloadTask:url size:size sha:sha altName:name toPath:path success:nil];
        if (task) {
            [tasks addObject:task];
        } else if (self.progress.cancelled) {
            return nil;
        }
    }
    return tasks;
}

- (NSArray *)downloadClientAssets {
    NSMutableArray *tasks = [NSMutableArray new];
    NSDictionary *assets = self.metadata[@"assetIndexObj"];
    if (!assets) {
        return @[];
    }
    for (NSString *name in assets[@"objects"]) {
        NSDictionary *object = assets[@"objects"][name];
        NSString *hash = object[@"hash"];
        NSString *pathname = [NSString stringWithFormat:@"%@/%@", [hash substringToIndex:2], hash];
        NSUInteger size = [object[@"size"] unsignedLongLongValue];

        NSString *path;
        if ([assets[@"map_to_resources"] boolValue]) {
            path = [NSString stringWithFormat:@"%s/resources/%@", getenv("POJAV_GAME_DIR"), name];
        } else {
            path = [NSString stringWithFormat:@"%s/assets/objects/%@", getenv("POJAV_GAME_DIR"), pathname];
        }

        /* Special case for 1.19+
         * Since 1.19-pre1, setting the window icon on macOS invokes ObjC.
         * However, if an IOException occurs, it won't try to set.
         * We skip downloading the icon file to workaround this. */
        if ([name hasSuffix:@"/minecraft.icns"]) {
            [NSFileManager.defaultManager removeItemAtPath:path error:nil];
            continue;
        }

        NSString *url = [NSString stringWithFormat:@"https://resources.download.minecraft.net/%@", pathname];
        NSURLSessionDownloadTask *task = [self createDownloadTask:url size:size sha:hash altName:name toPath:path success:nil];
        if (task) {
            [tasks addObject:task];
        } else if (self.progress.cancelled) {
            return nil;
        }
    }
    return tasks;
}

- (void)downloadVersion:(NSDictionary *)version {
    self.currentVersionId = version[@"id"];
    [self prepareForDownload];
    [self downloadVersionMetadata:version success:^{
        [self downloadAssetMetadataWithSuccess:^{
            NSArray *libTasks = [self downloadClientLibraries];
            NSArray *assetTasks = [self downloadClientAssets];
            // Drop the 1 byte we set initially
            self.progress.totalUnitCount--;
            self.textProgress.totalUnitCount--;
            if (self.progress.totalUnitCount == 0) {
                // We have nothing to download, invoke completion observer
                self.progress.totalUnitCount = 1;
                self.progress.completedUnitCount = 1;
                self.textProgress.totalUnitCount = 1;
                self.textProgress.completedUnitCount = 1;
                return;
            }
            [libTasks makeObjectsPerformSelector:@selector(resume)];
            [assetTasks makeObjectsPerformSelector:@selector(resume)];
            [self.metadata removeObjectForKey:@"assetIndexObj"];

            if (self.currentDownloadTaskItem) {
                [[DownloadTaskManager sharedManager] setTaskWithId:self.currentDownloadTaskItem.taskId
                                                              state:DownloadTaskStateDownloading];
            }
        }];
    }];
}

#pragma mark - Modpack installation

- (void)downloadModpackFromAPI:(ModpackAPI *)api detail:(NSDictionary *)modDetail atIndex:(NSUInteger)selectedVersion {
    [self prepareForDownload];

    NSString *url = modDetail[@"versionUrls"][selectedVersion];
    NSUInteger size = [modDetail[@"versionSizes"][selectedVersion] unsignedLongLongValue];
    NSString *sha = modDetail[@"versionHashes"][selectedVersion];
    NSString *name = [[modDetail[@"title"] lowercaseString] stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
    name = [name stringByReplacingOccurrencesOfString:@" " withString:@"_"];
    NSString *packagePath = [NSTemporaryDirectory() stringByAppendingFormat:@"/%@.zip", name];

    NSURLSessionDownloadTask *task = [self createDownloadTask:url size:size sha:sha altName:nil toPath:packagePath success:^{
        NSString *path = [NSString stringWithFormat:@"%s/custom_gamedir/%@", getenv("POJAV_GAME_DIR"), name];
        [api downloader:self submitDownloadTasksFromPackage:packagePath toPath:path];
    }];
    [task resume];
}

#pragma mark - Utilities

- (void)prepareForDownload {
    // 清理单例会话上残留的上一次下载任务（前台会话单例模式下必须清理，
    // 否则上一次失败/取消的 task 残留在会话中可能影响新下载）。
    // 注意：不能 invalidate 单例会话（会破坏后续所有下载），只取消任务。
    NSString *oldTaskId = self.currentDownloadTaskItem.taskId;
    if (oldTaskId.length > 0) {
        [self.manager.session getTasksWithCompletionHandler:^(NSArray<NSURLSessionDataTask *> *dataTasks,
                                                              NSArray<NSURLSessionUploadTask *> *uploadTasks,
                                                              NSArray<NSURLSessionDownloadTask *> *downloadTasks) {
            for (NSURLSessionDownloadTask *dt in downloadTasks) {
                if ([dt.taskDescription isEqualToString:oldTaskId]) {
                    [dt cancel];
                }
            }
        }];
    }

    // Create a fake progress which is used to update completedUnitCount properly
    // (completedUnitCount does not update unless subprogress completes)
    self.textProgress = [NSProgress new];
    self.textProgress.kind = NSProgressKindFile;
    self.textProgress.fileOperationKind = NSProgressFileOperationKindDownloading;
    self.textProgress.totalUnitCount = -1;

    self.progress = [NSProgress new];
    // Push 1 byte so it won't accidentally finish after downloading assets index
    self.progress.totalUnitCount = 1;
    [self.fileList removeAllObjects];
    [self.progressList removeAllObjects];
    // 阶段5修复：重置失败文件列表（参照 FCL）
    [self.failedFiles removeAllObjects];

    // 注册/更新到统一下载任务管理器
    [self registerOrUpdateTaskItem];

    // 监听总体进度
    if (!self.isObservingTaskProgress) {
        [self.progress addObserver:self
                        forKeyPath:@"fractionCompleted"
                           options:NSKeyValueObservingOptionInitial
                           context:(void *)@"MCDownloadProgressContext"];
        self.isObservingTaskProgress = YES;
        self.progressLastTime = 0;
        self.progressLastCompleted = 0;
    }
}

- (void)registerOrUpdateTaskItem {
    // 悬浮球已移除，始终注册到统一下载任务管理器，以便下载任务列表跟踪
    NSString *displayName = self.currentVersionId ?: (self.metadata[@"id"] ?: @"Minecraft");
    NSString *downloadSource = getPrefObject(@"general.download_source") ?: @"official";

    if (!self.currentDownloadTaskItem) {
        self.currentDownloadTaskItem = [[DownloadTaskManager sharedManager]
            registerTaskWithResourceType:DownloadTaskResourceTypeMinecraft
                            resourceName:displayName
                             displayName:displayName
                          downloadSource:downloadSource
                                 rawTask:self
                          supportsResume:NO
                                 iconURL:nil];
    } else {
        self.currentDownloadTaskItem.resourceName = displayName;
        self.currentDownloadTaskItem.displayName = displayName;
        self.currentDownloadTaskItem.downloadSource = downloadSource;
        self.currentDownloadTaskItem.rawTask = self;
        self.currentDownloadTaskItem.supportsResume = NO;
        self.currentDownloadTaskItem.state = DownloadTaskStatePending;
        self.currentDownloadTaskItem.progress = -1.0;
        self.currentDownloadTaskItem.errorInfo = nil;
    }
}

- (void)finishDownloadWithErrorString:(NSString *)error {
    if (self.currentDownloadTaskItem && self.currentDownloadTaskItem.state != DownloadTaskStateCancelled) {
        NSError *err = [NSError errorWithDomain:@"MinecraftResourceDownloadTask"
                                           code:1
                                       userInfo:@{NSLocalizedDescriptionKey: error ?: @"下载失败"}];
        [[DownloadTaskManager sharedManager] setTaskWithId:self.currentDownloadTaskItem.taskId
                                          completedWithError:err];
    }

    [self.progress cancel];

    // 取消属于当前任务的所有后台下载任务，避免失败后继续浪费流量
    NSString *taskId = self.currentDownloadTaskItem.taskId;
    [self.manager.session getTasksWithCompletionHandler:^(NSArray<NSURLSessionDataTask *> *dataTasks,
                                                          NSArray<NSURLSessionUploadTask *> *uploadTasks,
                                                          NSArray<NSURLSessionDownloadTask *> *downloadTasks) {
        for (NSURLSessionDownloadTask *downloadTask in downloadTasks) {
            if (taskId.length > 0 && [downloadTask.taskDescription isEqualToString:taskId]) {
                [downloadTask cancel];
            }
        }
    }];

    showDialog(localize(@"Error", nil), error);
    self.handleError();
}

- (void)finishDownloadWithError:(NSError *)error file:(NSString *)file {
    NSString *errorStr = [NSString stringWithFormat:localize(@"launcher.mcl.error_download", NULL), file, error.localizedDescription];
    NSLog(@"[MCDL] Error: %@ %@", errorStr, NSThread.callStackSymbols);

    // 阶段5修复（参照 FCL）：单文件下载失败不再取消整批任务。
    //
    // 之前调用 finishDownloadWithErrorString: 会：
    //   1. 取消所有同 taskId 的下载任务（正在下载的其他文件全部被取消）
    //   2. 弹出错误对话框中断整个下载流程
    //   3. 导致整合包"下载不完全"——用户报告"下载的模组名称不对、下载不完全"
    //
    // FCL 做法：单文件失败记录到 failedFiles 数组，其他文件继续下载，
    // 最终汇总报告给用户。这与 FCL "单文件失败不影响其他文件"的设计完全一致。
    //
    // 注意：仅整合包多文件下载场景适用此容错策略。单文件版本下载（downloadVersion:）
    // 不应进入此方法（其 completionHandler 已有自己的错误处理路径），但若意外进入，
    // 由于 failedFiles.count == 0 时 finishDownloadWithErrorString: 不会被触发，
    // 行为与原逻辑保持兼容。
    @synchronized(self.failedFiles) {
        [self.failedFiles addObject:@{
            @"name": file ?: @"unknown",
            @"error": error.localizedDescription ?: @"unknown error"
        }];
    }
    NSLog(@"[MCDL] File '%@' added to failedFiles (total failed: %lu), other downloads will continue",
          file, (unsigned long)self.failedFiles.count);
}

#pragma mark - Download Task Manager Reporting

- (void)observeValueForKeyPath:(NSString *)keyPath ofObject:(id)object change:(NSDictionary<NSKeyValueChangeKey,id> *)change context:(void *)context {
    if (context != (void *)@"MCDownloadProgressContext") {
        [super observeValueForKeyPath:keyPath ofObject:object change:change context:context];
        return;
    }

    if (![keyPath isEqualToString:@"fractionCompleted"] || !self.currentDownloadTaskItem) return;

    NSProgress *progress = self.progress;
    double fraction = progress.fractionCompleted;
    int64_t total = progress.totalUnitCount;
    int64_t completed = (int64_t)(total * fraction);

    // 速度 / 预计剩余时间（每秒计算一次）
    struct timeval tv;
    gettimeofday(&tv, NULL);
    NSTimeInterval now = tv.tv_sec + tv.tv_usec / 1000000.0;
    double speed = 0.0;
    NSTimeInterval eta = 0.0;

    if (self.progressLastTime > 0 && now > self.progressLastTime) {
        int64_t delta = completed - self.progressLastCompleted;
        NSTimeInterval timeDelta = now - self.progressLastTime;
        if (timeDelta > 0) {
            speed = (double)delta / timeDelta;
            if (speed > 0 && total > completed) {
                eta = (total - completed) / speed;
            }
        }
    }

    if (self.progressLastTime == 0 || now >= self.progressLastTime + 1.0) {
        self.progressLastTime = now;
        self.progressLastCompleted = completed;
    }

    DownloadTaskManager *manager = [DownloadTaskManager sharedManager];
    [manager updateTaskWithId:self.currentDownloadTaskItem.taskId
                     progress:fraction
                   totalBytes:total
              downloadedBytes:completed];
    [manager updateTaskWithId:self.currentDownloadTaskItem.taskId
                        speed:speed
       estimatedTimeRemaining:eta];

    if (progress.cancelled) {
        if (self.currentDownloadTaskItem.state != DownloadTaskStateCancelled &&
            self.currentDownloadTaskItem.state != DownloadTaskStateCompleted &&
            self.currentDownloadTaskItem.state != DownloadTaskStateFailed) {
            [manager setTaskWithId:self.currentDownloadTaskItem.taskId state:DownloadTaskStateCancelled];
        }
        [self removeProgressObserver];
        return;
    }

    if (progress.finished) {
        if (self.currentDownloadTaskItem.state != DownloadTaskStateCompleted &&
            self.currentDownloadTaskItem.state != DownloadTaskStateFailed &&
            self.currentDownloadTaskItem.state != DownloadTaskStateCancelled) {
            // 阶段5修复（参照 FCL DownloadList.finishAll）：下载流程结束后，
            // 若有失败文件，不能简单标记为"成功完成"——这会让用户以为整合包完整。
            // 应将失败文件信息汇总为 NSError，让 DownloadTaskManager 显示为失败状态，
            // 用户可在下载任务列表中看到具体缺失的文件。
            NSArray<NSDictionary *> *failedSnapshot = [self.failedFiles copy];
            if (failedSnapshot.count > 0) {
                NSMutableString *msg = [NSMutableString stringWithFormat:@"下载完成但有 %lu 个文件失败：", (unsigned long)failedSnapshot.count];
                NSUInteger showCount = MIN(failedSnapshot.count, (NSUInteger)5);
                for (NSUInteger k = 0; k < showCount; k++) {
                    NSString *n = failedSnapshot[k][@"name"];
                    [msg appendFormat:@"\n  • %@", n ?: @"(unknown)"];
                }
                if (failedSnapshot.count > showCount) {
                    [msg appendFormat:@"\n  ...等共 %lu 个", (unsigned long)failedSnapshot.count];
                }
                NSLog(@"[MCDL] %@", msg);
                NSError *partialError = [NSError errorWithDomain:@"MinecraftResourceDownloadTask"
                                                            code:2
                                                        userInfo:@{
                                                            NSLocalizedDescriptionKey: [msg copy],
                                                            @"failedFiles": failedSnapshot
                                                        }];
                [manager setTaskWithId:self.currentDownloadTaskItem.taskId completedWithError:partialError];
            } else {
                [manager setTaskWithId:self.currentDownloadTaskItem.taskId completedWithError:nil];
            }
        }
        [self removeProgressObserver];
    }
}

- (void)removeProgressObserver {
    if (self.isObservingTaskProgress) {
        @try {
            [self.progress removeObserver:self forKeyPath:@"fractionCompleted"];
        } @catch (NSException *exception) {
            // ignore
        }
        self.isObservingTaskProgress = NO;
    }
}

// 关键修改：移除本地账户下载限制和提示
- (BOOL)checkAccessWithDialog:(BOOL)show {
    // 无条件允许所有下载请求
    return YES;
}

// Check SHA of the file
- (BOOL)checkSHAIgnorePref:(NSString *)sha forFile:(NSString *)path altName:(NSString *)altName logSuccess:(BOOL)logSuccess {
    if (sha.length == 0) {
        // When sha = skip, only check for file existence
        BOOL existence = [NSFileManager.defaultManager fileExistsAtPath:path];
        if (existence) {
            NSLog(@"[MCDL] Warning: couldn't find SHA for %@, have to assume it's good.", path);
        }
        return existence;
    }

    NSData *data = [NSData dataWithContentsOfFile:path];
    if (data == nil) {
        NSLog(@"[MCDL] SHA1 checker: file doesn't exist: %@", altName ? altName : path.lastPathComponent);
        return NO;
    }

    unsigned char digest[CC_SHA1_DIGEST_LENGTH];
    CC_SHA1(data.bytes, (CC_LONG)data.length, digest);
    NSMutableString *localSHA = [NSMutableString stringWithCapacity:CC_SHA1_DIGEST_LENGTH * 2];
    for(int i = 0; i < CC_SHA1_DIGEST_LENGTH; i++) {
        [localSHA appendFormat:@"%02x", digest[i]];
    }

    BOOL check = [sha isEqualToString:localSHA];
    if (!check || (getPrefBool(@"general.debug_logging") && logSuccess)) {
        NSLog(@"[MCDL] SHA1 %@ for %@%@",
          (check ? @"passed" : @"failed"), 
          (altName ? altName : path.lastPathComponent),
          (check ? @"" : [NSString stringWithFormat:@" (expected: %@, got: %@)", sha, localSHA]));
    }
    return check;
}

- (BOOL)checkSHA:(NSString *)sha forFile:(NSString *)path altName:(NSString *)altName logSuccess:(BOOL)logSuccess {
    if (getPrefBool(@"general.check_sha")) {
        return [self checkSHAIgnorePref:sha forFile:path altName:altName logSuccess:logSuccess];
    } else {
        // 不仅检查文件存在性，还要检查文件大小 > 0（防止空文件被误判为已下载）
        // 修复：原版安装时若文件被错误创建为 0 字节，会被视为已下载，
        //   导致 totalUnitCount 从 1 变 0，触发强制完成（0 字节下载）
        if (![NSFileManager.defaultManager fileExistsAtPath:path]) return NO;
        NSDictionary *attrs = [NSFileManager.defaultManager attributesOfItemAtPath:path error:nil];
        unsigned long long fileSize = [attrs fileSize];
        return fileSize > 0;
    }
}

- (BOOL)checkSHA:(NSString *)sha forFile:(NSString *)path altName:(NSString *)altName {
    return [self checkSHA:sha forFile:path altName:altName logSuccess:altName==nil];
}

@end
