//
//  ShaderService.m
//  Amethyst
//
//  Shader service implementation - Fixed version
//  修复：统一使用 defaultSessionConfiguration，改用 NSURLSessionDownloadTask 提升下载效率和速度
//

#import "ShaderService.h"
#import <CommonCrypto/CommonCrypto.h>
#import <UIKit/UIKit.h>
#import "PLProfiles.h"
#import "ShaderItem.h"
#import "DownloadTaskManager.h"
#import "DownloadTaskItem.h"
#import "LauncherPreferences.h"

@interface ShaderService () <NSURLSessionDownloadDelegate>
@property (nonatomic, strong) NSURLSession *downloadSession;
@property (nonatomic, strong) NSMutableDictionary<NSURLSessionTask *, ShaderDownloadHandler> *downloadCompletionHandlers;
@property (nonatomic, strong) NSMutableDictionary<NSURLSessionTask *, NSString *> *downloadDestinationPaths;
@property (nonatomic, strong) NSMutableDictionary<NSURLSessionTask *, void(^)(NSProgress *)> *downloadProgressHandlers;
@property (nonatomic, strong) NSMutableDictionary<NSURLSessionTask *, DownloadTaskItem *> *downloadTaskItems;
@property (nonatomic, strong) NSMutableDictionary<NSURLSessionTask *, NSMutableDictionary *> *downloadProgressSnapshots;
@end

@implementation ShaderService

+ (instancetype)sharedService {
    static ShaderService *s;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        s = [[ShaderService alloc] init];
    });
    return s;
}

- (instancetype)init {
    if (self = [super init]) {
        _onlineSearchEnabled = NO;

        // 使用默认会话配置，避免后台会话限速。
        // 参考 FCL/ZalithLauncher2：提升并发连接数 6 → 16，与 ModService 对齐，
        // 在并发下载多个光影资源文件时显著提升吞吐量。完整性仍由下载完成后的
        // 文件大小/格式校验保证（与原实现一致，未引入分片下载以避免破坏校验流程）。
        NSURLSessionConfiguration *config = [NSURLSessionConfiguration defaultSessionConfiguration];
        config.timeoutIntervalForRequest = 120.0;
        config.timeoutIntervalForResource = 300.0;
        config.allowsCellularAccess = YES;
        config.HTTPMaximumConnectionsPerHost = 16;

        _downloadSession = [NSURLSession sessionWithConfiguration:config delegate:self delegateQueue:nil];
        _downloadCompletionHandlers = [NSMutableDictionary dictionary];
        _downloadDestinationPaths = [NSMutableDictionary dictionary];
        _downloadProgressHandlers = [NSMutableDictionary dictionary];
        _downloadTaskItems = [NSMutableDictionary dictionary];
        _downloadProgressSnapshots = [NSMutableDictionary dictionary];
    }
    return self;
}

#pragma mark - Helpers

- (nullable NSString *)sha1ForFileAtPath:(NSString *)path {
    NSData *d = [NSData dataWithContentsOfFile:path];
    if (!d) return nil;
    unsigned char digest[CC_SHA1_DIGEST_LENGTH];
    CC_SHA1(d.bytes, (CC_LONG)d.length, digest);
    NSMutableString *hex = [NSMutableString stringWithCapacity:CC_SHA1_DIGEST_LENGTH * 2];
    for (int i = 0; i < CC_SHA1_DIGEST_LENGTH; i++) {
        [hex appendFormat:@"%02x", digest[i]];
    }
    return [hex copy];
}

- (NSString *)iconCachePathForURL:(NSString *)urlString {
    if (!urlString) return nil;
    NSString *cacheDir = [NSSearchPathForDirectoriesInDomains(NSCachesDirectory, NSUserDomainMask, YES) firstObject];
    NSString *folder = [cacheDir stringByAppendingPathComponent:@"shader_icons"];
    if (![[NSFileManager defaultManager] fileExistsAtPath:folder]) {
        [[NSFileManager defaultManager] createDirectoryAtPath:folder withIntermediateDirectories:YES attributes:nil error:nil];
    }
    const char *cstr = [urlString UTF8String];
    unsigned char digest[CC_SHA1_DIGEST_LENGTH];
    CC_SHA1(cstr, (CC_LONG)strlen(cstr), digest);
    NSMutableString *hex = [NSMutableString stringWithCapacity:CC_SHA1_DIGEST_LENGTH * 2];
    for (int i = 0; i < CC_SHA1_DIGEST_LENGTH; i++) {
        [hex appendFormat:@"%02x", digest[i]];
    }
    return [folder stringByAppendingPathComponent:hex];
}

#pragma mark - Shaders folder detection & scan

/// 解析 profile 的 gameDir 为绝对路径。
/// 与 ModService.resolveAbsoluteGameDirForProfile: 对齐：
/// profile gameDir 通常是相对路径（如 "./custom_gamedir/{name}"），需相对于 POJAV_GAME_DIR 解析。
/// 之前 ShaderService 直接使用相对路径，导致 shaderpacks 目录找不到（fileExistsAtPath 基于 cwd 解析），
/// 用户点击下载光影按钮后没反应（实际是 ensureShadersFolderForProfile 创建目录到错误位置，
/// 下载完成后 moveItem 失败但 handler 已切主线程报错，用户感知"无反应"）。
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

- (nullable NSString *)existingShadersFolderForProfile:(NSString *)profileName {
    NSString *profile = profileName.length ? profileName : @"default";
    NSFileManager *fm = [NSFileManager defaultManager];

    // 优先用 profile gameDir（已解析为绝对路径）
    NSString *resolvedGameDir = [self resolveAbsoluteGameDirForProfile:profile];
    if (resolvedGameDir.length > 0) {
        NSString *shadersPath = [resolvedGameDir stringByAppendingPathComponent:@"shaderpacks"];
        BOOL isDir = NO;
        if ([fm fileExistsAtPath:shadersPath isDirectory:&isDir] && isDir) {
            return shadersPath;
        }
    }

    // 回退到 POJAV_GAME_DIR/shaderpacks
    const char *gameDirC = getenv("POJAV_GAME_DIR");
    if (gameDirC) {
        NSString *gameDir = [NSString stringWithUTF8String:gameDirC];
        NSString *shadersPath = [gameDir stringByAppendingPathComponent:@"shaderpacks"];
        BOOL isDir = NO;
        if ([fm fileExistsAtPath:shadersPath isDirectory:&isDir] && isDir) {
            return shadersPath;
        }
    }
    return nil;
}

/// 获取当前 profile 的 shaderpacks 目录，不存在时自动创建
- (nullable NSString *)ensureShadersFolderForProfile:(NSString *)profileName error:(NSError **)error {
    NSString *profile = profileName.length ? profileName : @"default";
    NSFileManager *fm = [NSFileManager defaultManager];
    NSString *shadersPath = nil;

    // 优先用 profile gameDir（已解析为绝对路径）
    NSString *resolvedGameDir = [self resolveAbsoluteGameDirForProfile:profile];
    if (resolvedGameDir.length > 0) {
        shadersPath = [resolvedGameDir stringByAppendingPathComponent:@"shaderpacks"];
    }

    if (!shadersPath) {
        const char *gameDirC = getenv("POJAV_GAME_DIR");
        if (gameDirC) {
            NSString *gameDir = [NSString stringWithUTF8String:gameDirC];
            shadersPath = [gameDir stringByAppendingPathComponent:@"shaderpacks"];
        }
    }

    if (!shadersPath) {
        if (error) {
            *error = [NSError errorWithDomain:@"ShaderService" code:1 userInfo:@{NSLocalizedDescriptionKey: @"无法确定游戏目录"}];
        }
        return nil;
    }

    BOOL isDir = NO;
    if (![fm fileExistsAtPath:shadersPath isDirectory:&isDir]) {
        NSError *createError = nil;
        [fm createDirectoryAtPath:shadersPath withIntermediateDirectories:YES attributes:nil error:&createError];
        if (createError) {
            if (error) *error = createError;
            return nil;
        }
        NSLog(@"[ShaderService] Created shaderpacks directory: %@", shadersPath);
    } else if (!isDir) {
        if (error) {
            *error = [NSError errorWithDomain:@"ShaderService" code:2 userInfo:@{NSLocalizedDescriptionKey: [NSString stringWithFormat:@"%@ 不是目录", shadersPath]}];
        }
        return nil;
    }
    return shadersPath;
}

- (void)scanShadersForProfile:(NSString *)profileName completion:(ShaderListHandler)completion {
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSString *shadersFolder = [self existingShadersFolderForProfile:profileName];
        NSMutableArray<ShaderItem *> *items = [NSMutableArray array];

        if (!shadersFolder) {
            if (completion) {
                completion(items);
            }
            return;
        }

        NSArray<NSString *> *contents = [[NSFileManager defaultManager] contentsOfDirectoryAtPath:shadersFolder error:nil];
        dispatch_group_t group = dispatch_group_create();

        for (NSString *fileName in contents) {
            if ([fileName.lowercaseString hasSuffix:@".zip"] || [fileName.lowercaseString hasSuffix:@".zip.disabled"]) {
                NSString *fullPath = [shadersFolder stringByAppendingPathComponent:fileName];
                ShaderItem *shader = [[ShaderItem alloc] initWithFilePath:fullPath];
                [items addObject:shader];

                dispatch_group_enter(group);
                [self fetchMetadataForShader:shader completion:^(ShaderItem *populatedShader, NSError * _Nullable error) {
                    dispatch_group_leave(group);
                }];
            }
        }

        dispatch_group_notify(group, dispatch_get_main_queue(), ^{
            [items sortUsingComparator:^NSComparisonResult(ShaderItem *obj1, ShaderItem *obj2) {
                NSString *name1 = obj1.displayName ?: obj1.fileName;
                NSString *name2 = obj2.displayName ?: obj2.fileName;
                return [name1 localizedCaseInsensitiveCompare:name2];
            }];

            if (completion) {
                completion(items);
            }
        });
    });
}

#pragma mark - Metadata fetch

- (void)fetchMetadataForShader:(ShaderItem *)shader completion:(ShaderMetadataHandler)completion {
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        // For shaders, we don't have embedded metadata like mods do
        // Just return the shader as-is
        if (completion) completion(shader, nil);
    });
}

#pragma mark - File operations

- (BOOL)toggleEnableForShader:(ShaderItem *)shader error:(NSError **)error {
    NSFileManager *fileManager = [NSFileManager defaultManager];
    NSString *currentPath = shader.filePath;
    NSString *newPath;

    if (shader.disabled) {
        if ([currentPath.lowercaseString hasSuffix:@".zip.disabled"]) {
            newPath = [currentPath substringToIndex:currentPath.length - [@".disabled" length]];
        } else {
            if (error) *error = [NSError errorWithDomain:@"ShaderServiceError" code:101 userInfo:@{NSLocalizedDescriptionKey:@"File state inconsistent, cannot enable."}];
            return NO;
        }
    } else {
        newPath = [currentPath stringByAppendingString:@".disabled"];
    }

    BOOL success = [fileManager moveItemAtPath:currentPath toPath:newPath error:error];
    if (success) {
        shader.filePath = newPath;
        shader.fileName = [newPath lastPathComponent];
        [shader refreshDisabledFlag];
    }

    return success;
}

- (BOOL)deleteShader:(ShaderItem *)shader error:(NSError **)error {
    return [[NSFileManager defaultManager] removeItemAtPath:shader.filePath error:error];
}

#pragma mark - Online Shader Downloading (Fixed: using NSURLSessionDownloadTask)

- (void)downloadShader:(ShaderItem *)shader toProfile:(NSString *)profileName completion:(ShaderDownloadHandler)completion {
    [self downloadShader:shader toProfile:profileName progress:nil completion:completion];
}

#pragma mark - Online Shader Downloading with progress

- (void)downloadShader:(ShaderItem *)shader
             toProfile:(NSString *)profileName
              progress:(void (^)(NSProgress *downloadProgress))progress
            completion:(ShaderDownloadHandler)completion {
    // Ensure shaderpacks folder exists
    NSString *shadersFolder = [self existingShadersFolderForProfile:profileName];
    NSFileManager *fm = [NSFileManager defaultManager];

    if (!shadersFolder) {
        // 回退到 ensureShadersFolderForProfile:error:，复用绝对路径解析逻辑
        // （之前直接读 prof[@"gameDir"] 不做相对路径解析，会导致目录创建到错误位置）
        NSString *profile = profileName.length ? profileName : @"default";
        NSError *dirError = nil;
        NSString *created = [self ensureShadersFolderForProfile:profile error:&dirError];
        if (!created) {
            if (completion) {
                NSError *error = [NSError errorWithDomain:@"ShaderServiceError"
                                                     code:1
                                                 userInfo:@{NSLocalizedDescriptionKey: dirError.localizedDescription ?: @"Failed to create shaderpacks folder, please check storage permissions."}];
                dispatch_async(dispatch_get_main_queue(), ^{ completion(error); });
            }
            return;
        }
        shadersFolder = created;
    }

    // Validate URL
    NSURL *url = [NSURL URLWithString:shader.selectedVersionDownloadURL];
    if (!url) {
        if (completion) {
            NSError *error = [NSError errorWithDomain:@"ShaderServiceError"
                                                 code:2
                                             userInfo:@{NSLocalizedDescriptionKey: @"Invalid download link."}];
            dispatch_async(dispatch_get_main_queue(), ^{ completion(error); });
        }
        return;
    }

    // Ensure filename is valid
    NSString *fileName = shader.fileName;
    if (!fileName || fileName.length == 0) {
        fileName = [url lastPathComponent];
    }
    if (!fileName || fileName.length == 0) {
        fileName = @"shaderpack.zip";
    }
    if (![fileName.lowercaseString hasSuffix:@".zip"]) {
        fileName = [fileName stringByAppendingString:@".zip"];
    }

    NSString *destinationPath = [shadersFolder stringByAppendingPathComponent:fileName];

    // Create download task with the session (default configuration, no background throttling)
    NSURLSessionDownloadTask *task = [self.downloadSession downloadTaskWithURL:url];
    self.downloadCompletionHandlers[task] = completion;
    self.downloadDestinationPaths[task] = destinationPath;
    if (progress) {
        self.downloadProgressHandlers[task] = progress;
    }

    // 注册到统一下载任务管理器（悬浮球已移除，始终注册以便下载任务列表跟踪）
    NSString *resourceName = shader.fileName.length > 0 ? shader.fileName : (shader.displayName.length > 0 ? shader.displayName : @"shader");
    NSString *displayName = shader.displayName.length > 0 ? shader.displayName : resourceName;
    NSString *downloadSource = getPrefObject(@"general.download_source") ?: @"official";
    DownloadTaskItem *taskItem = [[DownloadTaskManager sharedManager]
        registerTaskWithResourceType:DownloadTaskResourceTypeShader
                        resourceName:resourceName
                         displayName:displayName
                      downloadSource:downloadSource
                             rawTask:task
                      supportsResume:YES
                             iconURL:shader.iconURL];
    taskItem.downloadURL = shader.selectedVersionDownloadURL;
    self.downloadTaskItems[task] = taskItem;
    [[DownloadTaskManager sharedManager] setTaskWithId:taskItem.taskId state:DownloadTaskStateDownloading];

    // 设置 retryHandler：FCL 风格重新下载，复用同一 taskItem，重建底层 NSURLSessionTask
    __weak typeof(self) weakSelf = self;
    NSString *capturedDestPath = destinationPath;
    ShaderDownloadHandler capturedCompletion = completion;
    void (^capturedProgress)(NSProgress *) = progress;
    ShaderItem *capturedShader = shader;
    taskItem.retryHandler = ^id(DownloadTaskItem *taskItemRef) {
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf) return nil;
        NSURL *retryURL = [NSURL URLWithString:taskItemRef.downloadURL] ?: [NSURL URLWithString:capturedShader.selectedVersionDownloadURL];
        if (!retryURL) return nil;
        NSURLSessionDownloadTask *newTask = [strongSelf.downloadSession downloadTaskWithURL:retryURL];
        strongSelf.downloadCompletionHandlers[newTask] = capturedCompletion;
        strongSelf.downloadDestinationPaths[newTask] = capturedDestPath;
        if (capturedProgress) {
            strongSelf.downloadProgressHandlers[newTask] = capturedProgress;
        }
        strongSelf.downloadTaskItems[newTask] = taskItemRef;
        [[DownloadTaskManager sharedManager] setTaskWithId:taskItemRef.taskId state:DownloadTaskStateDownloading];
        [newTask resume];
        return newTask;
    };

    [task resume];

    NSLog(@"[ShaderService] Starting download task (with progress) for shader: %@ -> %@", url, destinationPath);
}

#pragma mark - NSURLSessionDownloadDelegate

- (void)URLSession:(NSURLSession *)session downloadTask:(NSURLSessionDownloadTask *)downloadTask didFinishDownloadingToURL:(NSURL *)location {
    ShaderDownloadHandler handler = self.downloadCompletionHandlers[downloadTask];
    NSString *destinationPath = self.downloadDestinationPaths[downloadTask];
    DownloadTaskItem *taskItem = self.downloadTaskItems[downloadTask];

    [self.downloadCompletionHandlers removeObjectForKey:downloadTask];
    [self.downloadDestinationPaths removeObjectForKey:downloadTask];
    [self.downloadProgressHandlers removeObjectForKey:downloadTask];
    [self.downloadTaskItems removeObjectForKey:downloadTask];
    [self.downloadProgressSnapshots removeObjectForKey:downloadTask];

    NSFileManager *fm = [NSFileManager defaultManager];
    NSError *moveError = nil;
    NSString *dir = [destinationPath stringByDeletingLastPathComponent];
    if (![fm fileExistsAtPath:dir]) {
        [fm createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:nil];
    }
    if ([fm fileExistsAtPath:destinationPath]) {
        [fm removeItemAtPath:destinationPath error:nil];
    }
    BOOL success = destinationPath && [fm moveItemAtURL:location toURL:[NSURL fileURLWithPath:destinationPath] error:&moveError];

    if (taskItem) {
        if (success) {
            [[DownloadTaskManager sharedManager] setTaskWithId:taskItem.taskId state:DownloadTaskStateCompleted];
        } else {
            [[DownloadTaskManager sharedManager] updateTaskWithId:taskItem.taskId error:moveError];
            [[DownloadTaskManager sharedManager] setTaskWithId:taskItem.taskId state:DownloadTaskStateFailed];
        }
    }
    if (handler) {
        handler(success ? nil : moveError);
    }
}

- (void)URLSession:(NSURLSession *)session task:(NSURLSessionTask *)task didCompleteWithError:(NSError *)error {
    if (error) {
        ShaderDownloadHandler handler = self.downloadCompletionHandlers[task];
        DownloadTaskItem *taskItem = self.downloadTaskItems[task];
        if (taskItem) {
            [[DownloadTaskManager sharedManager] updateTaskWithId:taskItem.taskId error:error];
            [[DownloadTaskManager sharedManager] setTaskWithId:taskItem.taskId state:DownloadTaskStateFailed];
            [self.downloadTaskItems removeObjectForKey:task];
            [self.downloadProgressSnapshots removeObjectForKey:task];
        }
        if (handler) {
            // 防御性切主线程：delegate 默认在 NSURLSession 的 delegateQueue 上执行（非主线程）。
            // 调用方（DownloadViewController）虽然已切主线程，但接口约定应当安全。
            NSError *capturedError = error;
            dispatch_async(dispatch_get_main_queue(), ^{
                handler(capturedError);
            });
            [self.downloadCompletionHandlers removeObjectForKey:task];
            [self.downloadDestinationPaths removeObjectForKey:task];
            [self.downloadProgressHandlers removeObjectForKey:task];
        }
    }
}

- (void)URLSession:(NSURLSession *)session
      downloadTask:(NSURLSessionDownloadTask *)downloadTask
      didWriteData:(int64_t)bytesWritten
 totalBytesWritten:(int64_t)totalBytesWritten
totalBytesExpectedToWrite:(int64_t)totalBytesExpectedToWrite {
    void(^progress)(NSProgress *) = self.downloadProgressHandlers[downloadTask];
    DownloadTaskItem *taskItem = self.downloadTaskItems[downloadTask];
    // speed/eta 声明提到 if (taskItem) 块之前，供下方构造 NSProgress 时引用
    // （修复编译错误：之前在块内声明，块外使用导致 use of undeclared identifier）
    double speed = 0.0;
    NSTimeInterval eta = 0.0;

    if (taskItem) {
        double fraction = totalBytesExpectedToWrite > 0 ? (double)totalBytesWritten / (double)totalBytesExpectedToWrite : -1.0;
        NSTimeInterval now = [NSDate date].timeIntervalSince1970;
        NSMutableDictionary *snapshot = self.downloadProgressSnapshots[downloadTask];
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
            self.downloadProgressSnapshots[downloadTask] = snapshot;
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

    if (!progress) return;

    // 在 progress 回调的 NSProgress 上设置 throughput 和 estimatedTimeRemaining，
    // 供调用方（DownloadViewController）在 FCL 风格的下载进度卡片上显示速度和 ETA。
    // 与 ModService 对齐，之前 ShaderService 同样存在速度/ETA 永远为 0 的问题。
    NSProgress *downloadProgress = [NSProgress progressWithTotalUnitCount:totalBytesExpectedToWrite];
    downloadProgress.completedUnitCount = totalBytesWritten;
    if (speed > 0) {
        downloadProgress.throughput = @(speed);
    }
    if (eta > 0) {
        downloadProgress.estimatedTimeRemaining = @(eta);
    }

    dispatch_async(dispatch_get_main_queue(), ^{
        progress(downloadProgress);
    });
}

@end