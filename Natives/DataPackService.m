//
//  DataPackService.m
//  Amethyst
//
//  Data pack service implementation
//  数据包服务实现，结构参照 ShaderService，复用 ShaderItem 作为数据模型
//  使用 defaultSessionConfiguration + NSURLSessionDownloadTask 提升下载效率和速度
//

#import "DataPackService.h"
#import <UIKit/UIKit.h>
#import "PLProfiles.h"
#import "ShaderItem.h"

@interface DataPackService () <NSURLSessionDownloadDelegate>
@property (nonatomic, strong) NSURLSession *downloadSession;
// 内部统一存储带 success/error 的 completion handler
@property (nonatomic, strong) NSMutableDictionary<NSURLSessionTask *, DataPackDownloadCompletionHandler> *downloadCompletionHandlers;
@property (nonatomic, strong) NSMutableDictionary<NSURLSessionTask *, NSString *> *downloadDestinationPaths;
// 进度回调相关：分别保存进度 handler 和 NSProgress 对象
@property (nonatomic, strong) NSMutableDictionary<NSURLSessionTask *, DataPackDownloadProgressHandler> *downloadProgressHandlers;
@property (nonatomic, strong) NSMutableDictionary<NSURLSessionTask *, NSProgress *> *downloadProgresses;
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
    }
    return self;
}

#pragma mark - DataPacks folder detection & scan

// 查找指定 profile 的 datapacks 目录（已存在时返回路径，否则返回 nil）
- (nullable NSString *)existingDataPacksFolderForProfile:(PLProfiles *)profile {
    PLProfiles *profiles = profile ?: PLProfiles.current;
    NSFileManager *fm = [NSFileManager defaultManager];

    @try {
        NSDictionary *prof = [profiles selectedProfile];
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

- (void)scanDataPacksForProfile:(PLProfiles *)profile completion:(DataPackListHandler)completion {
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSString *dataPacksFolder = [self existingDataPacksFolderForProfile:profile];
        NSMutableArray<ShaderItem *> *items = [NSMutableArray array];

        if (!dataPacksFolder) {
            if (completion) {
                completion(items);
            }
            return;
        }

        NSArray<NSString *> *contents = [[NSFileManager defaultManager] contentsOfDirectoryAtPath:dataPacksFolder error:nil];
        dispatch_group_t group = dispatch_group_create();

        for (NSString *fileName in contents) {
            if ([fileName.lowercaseString hasSuffix:@".zip"] || [fileName.lowercaseString hasSuffix:@".zip.disabled"]) {
                NSString *fullPath = [dataPacksFolder stringByAppendingPathComponent:fileName];
                ShaderItem *dataPack = [[ShaderItem alloc] initWithFilePath:fullPath];
                [items addObject:dataPack];

                dispatch_group_enter(group);
                [self fetchMetadataForDataPack:dataPack completion:^(ShaderItem *populatedItem, NSError * _Nullable error) {
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

// 数据包无嵌入元数据，直接返回原对象（与 ShaderService 行为一致）
- (void)fetchMetadataForDataPack:(ShaderItem *)item completion:(DataPackMetadataHandler)completion {
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        if (completion) completion(item, nil);
    });
}

#pragma mark - File operations

// 启用/禁用数据包：通过加/去 .disabled 后缀实现
- (BOOL)toggleEnableForDataPack:(ShaderItem *)item error:(NSError **)error {
    NSFileManager *fileManager = [NSFileManager defaultManager];
    NSString *currentPath = item.filePath;
    NSString *newPath;

    if (item.disabled) {
        if ([currentPath.lowercaseString hasSuffix:@".zip.disabled"]) {
            newPath = [currentPath substringToIndex:currentPath.length - [@".disabled" length]];
        } else {
            if (error) *error = [NSError errorWithDomain:@"DataPackServiceError" code:101 userInfo:@{NSLocalizedDescriptionKey:@"文件状态不一致，无法启用。"}];
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
- (BOOL)deleteDataPack:(ShaderItem *)item error:(NSError **)error {
    return [[NSFileManager defaultManager] removeItemAtPath:item.filePath error:error];
}

#pragma mark - Online DataPack Downloading (使用 NSURLSessionDownloadTask)

// 带实时进度回调的下载方法
- (void)downloadDataPack:(ShaderItem *)item
               toProfile:(PLProfiles *)profile
                progress:(DataPackDownloadProgressHandler _Nullable)progress
              completion:(DataPackDownloadCompletionHandler _Nullable)completion {
    // 确保 datapacks 目录存在
    NSString *dataPacksFolder = [self existingDataPacksFolderForProfile:profile];
    NSFileManager *fm = [NSFileManager defaultManager];

    if (!dataPacksFolder) {
        // 目录不存在时尝试创建
        PLProfiles *profiles = profile ?: PLProfiles.current;
        NSString *gameDir = nil;

        @try {
            NSDictionary *prof = [profiles selectedProfile];
            if ([prof isKindOfClass:[NSDictionary class]]) {
                gameDir = prof[@"gameDir"];
            }
        } @catch (NSException *ex) { }

        if (!gameDir) {
            const char *gameDirC = getenv("POJAV_GAME_DIR");
            if (gameDirC) {
                gameDir = [NSString stringWithUTF8String:gameDirC];
            }
        }

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
                                                     userInfo:@{NSLocalizedDescriptionKey: @"创建 datapacks 目录失败，请检查存储权限。"}];
                    completion(NO, error);
                }
                return;
            }
        } else {
            if (completion) {
                NSError *error = [NSError errorWithDomain:@"DataPackServiceError"
                                                     code:1
                                                 userInfo:@{NSLocalizedDescriptionKey: @"找不到游戏目录。"}];
                completion(NO, error);
            }
            return;
        }
    }

    // 校验下载链接
    NSURL *url = [NSURL URLWithString:item.selectedVersionDownloadURL];
    if (!url) {
        if (completion) {
            NSError *error = [NSError errorWithDomain:@"DataPackServiceError"
                                                 code:2
                                             userInfo:@{NSLocalizedDescriptionKey: @"无效的下载链接。"}];
            completion(NO, error);
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
    [task resume];

    NSLog(@"[DataPackService] 开始下载数据包: %@ -> %@", url, destinationPath);
}

#pragma mark - NSURLSessionDownloadDelegate

// 下载进度回调：更新 NSProgress 并在主线程上报
- (void)URLSession:(NSURLSession *)session downloadTask:(NSURLSessionDownloadTask *)downloadTask
      didWriteData:(int64_t)bytesWritten
 totalBytesWritten:(int64_t)totalBytesWritten
totalBytesExpectedToWrite:(int64_t)totalBytesExpectedToWrite {
    NSProgress *progressObj = self.downloadProgresses[downloadTask];
    DataPackDownloadProgressHandler progressHandler = self.downloadProgressHandlers[downloadTask];
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

    [self.downloadCompletionHandlers removeObjectForKey:downloadTask];
    [self.downloadDestinationPaths removeObjectForKey:downloadTask];
    [self.downloadProgresses removeObjectForKey:downloadTask];
    [self.downloadProgressHandlers removeObjectForKey:downloadTask];

    if (!handler || !destinationPath) {
        return;
    }

    NSFileManager *fm = [NSFileManager defaultManager];
    NSError *moveError = nil;
    NSString *dir = [destinationPath stringByDeletingLastPathComponent];
    if (![fm fileExistsAtPath:dir]) {
        [fm createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:nil];
    }
    if ([fm fileExistsAtPath:destinationPath]) {
        [fm removeItemAtPath:destinationPath error:nil];
    }
    if (![fm moveItemAtURL:location toURL:[NSURL fileURLWithPath:destinationPath] error:&moveError]) {
        handler(NO, moveError);
    } else {
        handler(YES, nil);
    }
}

- (void)URLSession:(NSURLSession *)session task:(NSURLSessionTask *)task didCompleteWithError:(NSError *)error {
    if (error) {
        DataPackDownloadCompletionHandler handler = self.downloadCompletionHandlers[task];
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
