//
//  DataPackService.m
//  Amethyst
//
//  数据包服务实现，结构参照 ShaderService/ModService
//  API 签名统一使用 NSString *profileName
//  使用 defaultSessionConfiguration + NSURLSessionDownloadTask 提升下载效率和速度
//  实现 pack.mcmeta 解析（pack_format / description）
//  支持 worldName 参数下载到指定世界的 datapacks 目录
//

#import "DataPackService.h"
#import <CommonCrypto/CommonCrypto.h>
#import <UIKit/UIKit.h>
#import "PLProfiles.h"
#import "DataPackItem.h"
#import "UZKArchive.h"
#import "DownloadTaskManager.h"
#import "DownloadTaskItem.h"
#import "LauncherPreferences.h"

@interface DataPackService () <NSURLSessionDownloadDelegate>
@property (nonatomic, strong) NSURLSession *downloadSession;
// 内部统一存储带 success/error 的 completion handler
@property (nonatomic, strong) NSMutableDictionary<NSURLSessionTask *, DataPackDownloadCompletionHandler> *downloadCompletionHandlers;
@property (nonatomic, strong) NSMutableDictionary<NSURLSessionTask *, NSString *> *downloadDestinationPaths;
// 进度回调相关：分别保存进度 handler 和 NSProgress 对象
@property (nonatomic, strong) NSMutableDictionary<NSURLSessionTask *, DataPackDownloadProgressHandler> *downloadProgressHandlers;
@property (nonatomic, strong) NSMutableDictionary<NSURLSessionTask *, NSProgress *> *downloadProgresses;
@property (nonatomic, strong) NSMutableDictionary<NSURLSessionTask *, DownloadTaskItem *> *downloadTaskItems;
@property (nonatomic, strong) NSMutableDictionary<NSURLSessionTask *, NSMutableDictionary *> *downloadProgressSnapshots;
@end

@implementation DataPackService

+ (instancetype)sharedService {
    static DataPackService *s;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        s = [[DataPackService alloc] init];
    });
    return s;
}

- (instancetype)init {
    if (self = [super init]) {
        _onlineSearchEnabled = NO;

        // 使用默认会话配置，避免后台会话限速
        NSURLSessionConfiguration *config = [NSURLSessionConfiguration defaultSessionConfiguration];
        config.timeoutIntervalForRequest = 120.0;
        config.timeoutIntervalForResource = 300.0;
        config.allowsCellularAccess = YES;
        config.HTTPMaximumConnectionsPerHost = 6;

        _downloadSession = [NSURLSession sessionWithConfiguration:config delegate:self delegateQueue:nil];
        _downloadCompletionHandlers = [NSMutableDictionary dictionary];
        _downloadDestinationPaths = [NSMutableDictionary dictionary];
        _downloadProgressHandlers = [NSMutableDictionary dictionary];
        _downloadProgresses = [NSMutableDictionary dictionary];
        _downloadTaskItems = [NSMutableDictionary dictionary];
        _downloadProgressSnapshots = [NSMutableDictionary dictionary];
    }
    return self;
}

#pragma mark - 工具方法

// 计算 URL 字符串的 SHA1，用作图标缓存文件名
- (NSString *)iconCachePathForURL:(NSString *)urlString {
    if (!urlString) return nil;
    NSString *cacheDir = [NSSearchPathForDirectoriesInDomains(NSCachesDirectory, NSUserDomainMask, YES) firstObject];
    NSString *folder = [cacheDir stringByAppendingPathComponent:@"datapack_icons"];
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

// 从 zip 中读取指定条目的数据
- (nullable NSData *)readFileFromZip:(NSString *)zipPath entryName:(NSString *)entryName {
    if (!zipPath || !entryName) return nil;
    NSError *err = nil;
    UZKArchive *archive = [[UZKArchive alloc] initWithPath:zipPath error:&err];
    if (!archive || err) return nil;
    NSData *data = [archive extractDataFromFile:entryName error:&err];
    return data;
}

// 解析 pack.mcmeta，提取 pack_format 和 description
- (void)parsePackMcmetaForItem:(DataPackItem *)item {
    if (!item.filePath) return;
    NSData *mcmetaData = [self readFileFromZip:item.filePath entryName:@"pack.mcmeta"];
    if (!mcmetaData) return;
    NSDictionary *json = [NSJSONSerialization JSONObjectWithData:mcmetaData options:0 error:nil];
    if (![json isKindOfClass:[NSDictionary class]]) return;
    NSDictionary *pack = json[@"pack"];
    if (![pack isKindOfClass:[NSDictionary class]]) return;

    id packFormatValue = pack[@"pack_format"];
    if ([packFormatValue isKindOfClass:[NSNumber class]]) {
        item.packFormat = packFormatValue;
    } else if ([packFormatValue respondsToSelector:@selector(integerValue)]) {
        item.packFormat = @([packFormatValue integerValue]);
    }

    id descValue = pack[@"description"];
    if ([descValue isKindOfClass:[NSString class]]) {
        item.dataPackDescription = descValue;
    } else if ([descValue respondsToSelector:@selector(description)]) {
        item.dataPackDescription = [descValue description];
    }
}

// 解析 profile 的 gameDir，返回 gameDir 或 nil
- (nullable NSString *)gameDirForProfile:(NSString *)profileName {
    NSString *profile = profileName.length ? profileName : @"default";
    @try {
        NSDictionary *profiles = PLProfiles.current.profiles;
        NSDictionary *prof = profiles[profile];
        if ([prof isKindOfClass:[NSDictionary class]]) {
            NSString *gameDir = prof[@"gameDir"];
            if ([gameDir isKindOfClass:[NSString class]] && gameDir.length > 0) {
                return gameDir;
            }
        }
    } @catch (NSException *ex) { }

    const char *gameDirC = getenv("POJAV_GAME_DIR");
    if (gameDirC) {
        return [NSString stringWithUTF8String:gameDirC];
    }
    return nil;
}

#pragma mark - DataPacks folder detection & scan

// 查找指定 profile 的 datapacks 目录（已存在时返回路径，否则返回 nil）
- (nullable NSString *)existingDataPacksFolderForProfile:(NSString *)profileName {
    NSString *profile = profileName.length ? profileName : @"default";
    NSFileManager *fm = [NSFileManager defaultManager];

    @try {
        NSDictionary *profiles = PLProfiles.current.profiles;
        NSDictionary *prof = profiles[profile];
        if ([prof isKindOfClass:[NSDictionary class]]) {
            NSString *gameDir = prof[@"gameDir"];
            if ([gameDir isKindOfClass:[NSString class]] && gameDir.length > 0) {
                NSString *dataPacksPath = [gameDir stringByAppendingPathComponent:@"datapacks"];
                BOOL isDir = NO;
                if ([fm fileExistsAtPath:dataPacksPath isDirectory:&isDir] && isDir) {
                    return dataPacksPath;
                }
            }
        }
    } @catch (NSException *ex) { }

    // 回退：读取 POJAV_GAME_DIR 环境变量
    const char *gameDirC = getenv("POJAV_GAME_DIR");
    if (gameDirC) {
        NSString *gameDir = [NSString stringWithUTF8String:gameDirC];
        NSString *dataPacksPath = [gameDir stringByAppendingPathComponent:@"datapacks"];
        BOOL isDir = NO;
        if ([fm fileExistsAtPath:dataPacksPath isDirectory:&isDir] && isDir) {
            return dataPacksPath;
        }
    }
    return nil;
}

/// 获取当前 profile 的 datapacks 目录，不存在时自动创建
- (nullable NSString *)ensureDataPacksFolderForProfile:(NSString *)profileName error:(NSError **)error {
    NSString *profile = profileName.length ? profileName : @"default";
    NSFileManager *fm = [NSFileManager defaultManager];
    NSString *dataPacksPath = nil;

    @try {
        NSDictionary *profiles = PLProfiles.current.profiles;
        NSDictionary *prof = profiles[profile];
        if ([prof isKindOfClass:[NSDictionary class]]) {
            NSString *gameDir = prof[@"gameDir"];
            if ([gameDir isKindOfClass:[NSString class]] && gameDir.length > 0) {
                dataPacksPath = [gameDir stringByAppendingPathComponent:@"datapacks"];
            }
        }
    } @catch (NSException *ex) { }

    if (!dataPacksPath) {
        const char *gameDirC = getenv("POJAV_GAME_DIR");
        if (gameDirC) {
            NSString *gameDir = [NSString stringWithUTF8String:gameDirC];
            dataPacksPath = [gameDir stringByAppendingPathComponent:@"datapacks"];
        }
    }

    if (!dataPacksPath) {
        if (error) {
            *error = [NSError errorWithDomain:@"DataPackService" code:1 userInfo:@{NSLocalizedDescriptionKey: @"无法确定游戏目录"}];
        }
        return nil;
    }

    BOOL isDir = NO;
    if (![fm fileExistsAtPath:dataPacksPath isDirectory:&isDir]) {
        NSError *createError = nil;
        [fm createDirectoryAtPath:dataPacksPath withIntermediateDirectories:YES attributes:nil error:&createError];
        if (createError) {
            if (error) *error = createError;
            return nil;
        }
        NSLog(@"[DataPackService] Created datapacks directory: %@", dataPacksPath);
    } else if (!isDir) {
        if (error) {
            *error = [NSError errorWithDomain:@"DataPackService" code:2 userInfo:@{NSLocalizedDescriptionKey: [NSString stringWithFormat:@"%@ is not a directory", dataPacksPath]}];
        }
        return nil;
    }
    return dataPacksPath;
}

- (void)scanDataPacksForProfile:(NSString *)profileName completion:(DataPackListHandler)completion {
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSString *dataPacksFolder = [self existingDataPacksFolderForProfile:profileName];
        NSMutableArray<DataPackItem *> *items = [NSMutableArray array];

        if (!dataPacksFolder) {
            if (completion) {
                dispatch_async(dispatch_get_main_queue(), ^{ completion(items); });
            }
            return;
        }

        NSArray<NSString *> *contents = [[NSFileManager defaultManager] contentsOfDirectoryAtPath:dataPacksFolder error:nil];
        dispatch_group_t group = dispatch_group_create();

        for (NSString *fileName in contents) {
            if ([fileName.lowercaseString hasSuffix:@".zip"] || [fileName.lowercaseString hasSuffix:@".zip.disabled"]) {
                NSString *fullPath = [dataPacksFolder stringByAppendingPathComponent:fileName];
                DataPackItem *dataPack = [[DataPackItem alloc] initWithFilePath:fullPath];
                [items addObject:dataPack];

                dispatch_group_enter(group);
                [self fetchMetadataForDataPack:dataPack completion:^(DataPackItem *populatedItem, NSError * _Nullable error) {
                    dispatch_group_leave(group);
                }];
            }
        }

        dispatch_group_notify(group, dispatch_get_main_queue(), ^{
            [items sortUsingComparator:^NSComparisonResult(DataPackItem *obj1, DataPackItem *obj2) {
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

// 解析 zip 内的 pack.mcmeta，获取 pack_format 和 description
- (void)fetchMetadataForDataPack:(DataPackItem *)item completion:(DataPackMetadataHandler)completion {
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        @try {
            [self parsePackMcmetaForItem:item];
        } @catch (NSException *exception) {
            NSLog(@"[DataPackService] Exception parsing pack.mcmeta for %@: %@", item.fileName, exception);
        }
        if (completion) completion(item, nil);
    });
}

#pragma mark - File operations

// 启用/禁用数据包：通过加/去 .disabled 后缀实现
- (BOOL)toggleEnableForDataPack:(DataPackItem *)item error:(NSError **)error {
    NSFileManager *fileManager = [NSFileManager defaultManager];
    NSString *currentPath = item.filePath;
    NSString *newPath;

    if (item.disabled) {
        if ([currentPath.lowercaseString hasSuffix:@".zip.disabled"]) {
            newPath = [currentPath substringToIndex:currentPath.length - [@".disabled" length]];
        } else {
            if (error) *error = [NSError errorWithDomain:@"DataPackServiceError" code:101 userInfo:@{NSLocalizedDescriptionKey:@"File status mismatch, cannot enable."}];
            return NO;
        }
    } else {
        newPath = [currentPath stringByAppendingString:@".disabled"];
    }

    BOOL success = [fileManager moveItemAtPath:currentPath toPath:newPath error:error];
    if (success) {
        item.filePath = newPath;
        item.fileName = [newPath lastPathComponent];
        [item refreshDisabledFlag];
    }

    return success;
}

// 删除数据包文件
- (BOOL)deleteDataPack:(DataPackItem *)item error:(NSError **)error {
    return [[NSFileManager defaultManager] removeItemAtPath:item.filePath error:error];
}

#pragma mark - Online DataPack Downloading (使用 NSURLSessionDownloadTask)

// 下载数据包到默认 datapacks 目录（无 worldName）
- (void)downloadDataPack:(DataPackItem *)item
               toProfile:(NSString *)profileName
                progress:(DataPackDownloadProgressHandler _Nullable)progress
              completion:(DataPackDownloadCompletionHandler _Nullable)completion {
    [self downloadDataPack:item toProfile:profileName worldName:nil progress:progress completion:completion];
}

// 下载数据包，worldName 不为空时下载到 saves/<worldName>/datapacks/
- (void)downloadDataPack:(DataPackItem *)item
               toProfile:(NSString *)profileName
               worldName:(nullable NSString *)worldName
                progress:(DataPackDownloadProgressHandler _Nullable)progress
              completion:(DataPackDownloadCompletionHandler _Nullable)completion {
    NSFileManager *fm = [NSFileManager defaultManager];
    NSString *dataPacksFolder = nil;

    // 根据是否指定 worldName 决定下载目录
    if (worldName.length > 0) {
        // 下载到 saves/<worldName>/datapacks/
        NSString *gameDir = [self gameDirForProfile:profileName];
        if (!gameDir) {
            if (completion) {
                NSError *error = [NSError errorWithDomain:@"DataPackServiceError"
                                                     code:1
                                                 userInfo:@{NSLocalizedDescriptionKey: @"Cannot find game directory."}];
                dispatch_async(dispatch_get_main_queue(), ^{ completion(NO, error); });
            }
            return;
        }
        NSString *savesDir = [gameDir stringByAppendingPathComponent:@"saves"];
        NSString *worldDir = [savesDir stringByAppendingPathComponent:worldName];
        dataPacksFolder = [worldDir stringByAppendingPathComponent:@"datapacks"];
        // 确保目标目录存在（含 saves/<worldName>/datapacks/）
        NSError *dirError = nil;
        BOOL created = [fm createDirectoryAtPath:dataPacksFolder
                     withIntermediateDirectories:YES
                                      attributes:nil
                                           error:&dirError];
        if (!created || dirError) {
            if (completion) {
                NSError *error = [NSError errorWithDomain:@"DataPackServiceError"
                                                     code:1
                                                 userInfo:@{NSLocalizedDescriptionKey: [NSString stringWithFormat:@"Failed to create world datapacks directory: %@", dirError.localizedDescription ?: @"Unknown error"]}];
                dispatch_async(dispatch_get_main_queue(), ^{ completion(NO, error); });
            }
            return;
        }
    } else {
        // 默认下载到 <gameDir>/datapacks/
        dataPacksFolder = [self existingDataPacksFolderForProfile:profileName];
        if (!dataPacksFolder) {
            NSString *gameDir = [self gameDirForProfile:profileName];
            if (gameDir) {
                dataPacksFolder = [gameDir stringByAppendingPathComponent:@"datapacks"];
                NSError *dirError = nil;
                BOOL created = [fm createDirectoryAtPath:dataPacksFolder
                             withIntermediateDirectories:YES
                                              attributes:nil
                                                   error:&dirError];
                if (!created || dirError) {
                    if (completion) {
                        NSError *error = [NSError errorWithDomain:@"DataPackServiceError"
                                                             code:1
                                                         userInfo:@{NSLocalizedDescriptionKey: @"Failed to create datapacks directory, please check storage permissions."}];
                        dispatch_async(dispatch_get_main_queue(), ^{ completion(NO, error); });
                    }
                    return;
                }
            } else {
                if (completion) {
                    NSError *error = [NSError errorWithDomain:@"DataPackServiceError"
                                                         code:1
                                                     userInfo:@{NSLocalizedDescriptionKey: @"找不到游戏目录。"}];
                    dispatch_async(dispatch_get_main_queue(), ^{ completion(NO, error); });
                }
                return;
            }
        }
    }

    // 校验下载链接
    NSURL *url = [NSURL URLWithString:item.selectedVersionDownloadURL];
    if (!url) {
        if (completion) {
            NSError *error = [NSError errorWithDomain:@"DataPackServiceError"
                                                 code:2
                                             userInfo:@{NSLocalizedDescriptionKey: @"Invalid download URL."}];
            dispatch_async(dispatch_get_main_queue(), ^{ completion(NO, error); });
        }
        return;
    }

    // 确保文件名有效
    NSString *fileName = item.fileName;
    if (!fileName || fileName.length == 0) {
        fileName = [url lastPathComponent];
    }
    if (!fileName || fileName.length == 0) {
        fileName = @"datapack.zip";
    }
    if (![fileName.lowercaseString hasSuffix:@".zip"]) {
        fileName = [fileName stringByAppendingString:@".zip"];
    }

    NSString *destinationPath = [dataPacksFolder stringByAppendingPathComponent:fileName];

    // 创建下载任务（默认会话配置，无后台限速）
    NSURLSessionDownloadTask *task = [self.downloadSession downloadTaskWithURL:url];
    self.downloadCompletionHandlers[task] = completion;
    self.downloadDestinationPaths[task] = destinationPath;
    // 仅当调用方需要进度回调时才创建 NSProgress 对象
    if (progress) {
        NSProgress *progressObj = [NSProgress progressWithTotalUnitCount:-1];
        progressObj.kind = NSProgressKindFile;
        self.downloadProgresses[task] = progressObj;
        self.downloadProgressHandlers[task] = progress;
    }

    // 注册到统一下载任务管理器（悬浮球已移除，始终注册以便下载任务列表跟踪）
    NSString *resourceName = item.fileName.length > 0 ? item.fileName : (item.displayName.length > 0 ? item.displayName : @"datapack");
    NSString *displayName = item.displayName.length > 0 ? item.displayName : resourceName;
    NSString *downloadSource = getPrefObject(@"general.download_source") ?: @"official";
    DownloadTaskItem *taskItem = [[DownloadTaskManager sharedManager]
        registerTaskWithResourceType:DownloadTaskResourceTypeDataPack
                        resourceName:resourceName
                         displayName:displayName
                      downloadSource:downloadSource
                             rawTask:task
                      supportsResume:YES
                             iconURL:item.iconURL];
    taskItem.downloadURL = item.selectedVersionDownloadURL;
    self.downloadTaskItems[task] = taskItem;
    [[DownloadTaskManager sharedManager] setTaskWithId:taskItem.taskId state:DownloadTaskStateDownloading];

    // 设置 retryHandler：FCL 风格重新下载
    __weak typeof(self) weakSelf = self;
    NSString *capturedDestPath = destinationPath;
    DataPackDownloadCompletionHandler capturedCompletion = completion;
    void (^capturedProgress)(NSProgress *) = progress;
    taskItem.retryHandler = ^id(DownloadTaskItem *taskItemRef) {
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf) return nil;
        NSURL *retryURL = [NSURL URLWithString:taskItemRef.downloadURL] ?: url;
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

    NSLog(@"[DataPackService] Starting datapack download: %@ -> %@", url, destinationPath);
}

#pragma mark - NSURLSessionDownloadDelegate

// 下载进度回调：更新 NSProgress 并在主线程上报
- (void)URLSession:(NSURLSession *)session downloadTask:(NSURLSessionDownloadTask *)downloadTask
      didWriteData:(int64_t)bytesWritten
 totalBytesWritten:(int64_t)totalBytesWritten
totalBytesExpectedToWrite:(int64_t)totalBytesExpectedToWrite {
    NSProgress *progressObj = self.downloadProgresses[downloadTask];
    DataPackDownloadProgressHandler progressHandler = self.downloadProgressHandlers[downloadTask];
    DownloadTaskItem *taskItem = self.downloadTaskItems[downloadTask];

    if (taskItem) {
        double fraction = totalBytesExpectedToWrite > 0 ? (double)totalBytesWritten / (double)totalBytesExpectedToWrite : -1.0;
        NSTimeInterval now = [NSDate date].timeIntervalSince1970;
        NSMutableDictionary *snapshot = self.downloadProgressSnapshots[downloadTask];
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

    if (!progressObj || !progressHandler) return;

    // 首次回调时设置总字节数（HTTP 响应头中可能未提供，则保持 -1）
    if (progressObj.totalUnitCount < 0 && totalBytesExpectedToWrite > 0) {
        progressObj.totalUnitCount = totalBytesExpectedToWrite;
    }
    progressObj.completedUnitCount = totalBytesWritten;

    // progress 回调在主线程执行（UI 更新安全）
    dispatch_async(dispatch_get_main_queue(), ^{
        progressHandler(progressObj);
    });
}

- (void)URLSession:(NSURLSession *)session downloadTask:(NSURLSessionDownloadTask *)downloadTask didFinishDownloadingToURL:(NSURL *)location {
    DataPackDownloadCompletionHandler handler = self.downloadCompletionHandlers[downloadTask];
    NSString *destinationPath = self.downloadDestinationPaths[downloadTask];
    DownloadTaskItem *taskItem = self.downloadTaskItems[downloadTask];

    [self.downloadCompletionHandlers removeObjectForKey:downloadTask];
    [self.downloadDestinationPaths removeObjectForKey:downloadTask];
    [self.downloadProgresses removeObjectForKey:downloadTask];
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
        handler(success ? YES : NO, success ? nil : moveError);
    }
}

- (void)URLSession:(NSURLSession *)session task:(NSURLSessionTask *)task didCompleteWithError:(NSError *)error {
    if (error) {
        DataPackDownloadCompletionHandler handler = self.downloadCompletionHandlers[task];
        DownloadTaskItem *taskItem = self.downloadTaskItems[task];
        if (taskItem) {
            [[DownloadTaskManager sharedManager] updateTaskWithId:taskItem.taskId error:error];
            [[DownloadTaskManager sharedManager] setTaskWithId:taskItem.taskId state:DownloadTaskStateFailed];
            [self.downloadTaskItems removeObjectForKey:task];
            [self.downloadProgressSnapshots removeObjectForKey:task];
        }
        if (handler) {
            handler(NO, error);
            [self.downloadCompletionHandlers removeObjectForKey:task];
            [self.downloadDestinationPaths removeObjectForKey:task];
            [self.downloadProgresses removeObjectForKey:task];
            [self.downloadProgressHandlers removeObjectForKey:task];
        }
    }
}

@end
