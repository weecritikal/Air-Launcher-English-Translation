//
//  DataPackService.m
//  Flux
//
//  Data pack service implementation, structured like ShaderService/ModService
//  The API consistently takes NSString *profileName
//  Uses defaultSessionConfiguration + NSURLSessionDownloadTask for better download throughput
//  Implements pack.mcmeta parsing (pack_format / description)
//  Supports a worldName parameter for downloading into a specific world's datapacks folder
//

#import "ArchiveIntegrity.h"
#import "DataPackService.h"
#import <CommonCrypto/CommonCrypto.h>
#import <UIKit/UIKit.h>
#import "PLProfiles.h"
#import "DataPackItem.h"
#import "UZKArchive.h"
#import "DownloadTaskManager.h"
#import "DownloadTaskItem.h"
#import "LauncherPreferences.h"
#import "utils.h"

@interface DataPackService () <NSURLSessionDownloadDelegate>
@property (nonatomic, strong) NSURLSession *downloadSession;
// Internally stores the completion handler carrying success/error
@property (nonatomic, strong) NSMutableDictionary<NSURLSessionTask *, DataPackDownloadCompletionHandler> *downloadCompletionHandlers;
@property (nonatomic, strong) NSMutableDictionary<NSURLSessionTask *, NSString *> *downloadDestinationPaths;
// Progress callbacks: the progress handler and the NSProgress object are stored separately
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

        // Use the default session configuration to avoid background-session throttling
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

#pragma mark - Utility methods

// SHA1 of the URL string, used as the icon cache file name
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

// Read the data of a given entry from a zip
- (nullable NSData *)readFileFromZip:(NSString *)zipPath entryName:(NSString *)entryName {
    if (!zipPath || !entryName) return nil;
    NSError *err = nil;
    UZKArchive *archive = [[UZKArchive alloc] initWithPath:zipPath error:&err];
    if (!archive || err) return nil;
    NSData *data = [archive extractDataFromFile:entryName error:&err];
    return data;
}

// Parse pack.mcmeta and extract pack_format and description
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

// Resolve the gameDir of a profile, returning it or nil
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

// Find the datapacks folder of the given profile (returning the path if it exists, otherwise nil)
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

    // Fallback: read the POJAV_GAME_DIR environment variable
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

/// Return the datapacks folder of the current profile, creating it if it does not exist
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
            *error = [NSError errorWithDomain:@"DataPackService" code:1 userInfo:@{NSLocalizedDescriptionKey: @"Could not determine the game directory"}];
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

// Parse pack.mcmeta inside the zip to get pack_format and description
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

// Enable/disable a data pack by adding or removing the .disabled suffix
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

// Delete a data pack file
- (BOOL)deleteDataPack:(DataPackItem *)item error:(NSError **)error {
    return [[NSFileManager defaultManager] removeItemAtPath:item.filePath error:error];
}

#pragma mark - Online DataPack Downloading (using NSURLSessionDownloadTask)

// Download a data pack into the default datapacks folder (no worldName)
- (void)downloadDataPack:(DataPackItem *)item
               toProfile:(NSString *)profileName
                progress:(DataPackDownloadProgressHandler _Nullable)progress
              completion:(DataPackDownloadCompletionHandler _Nullable)completion {
    [self downloadDataPack:item toProfile:profileName worldName:nil progress:progress completion:completion];
}

// Download a data pack; when worldName is set it goes to saves/<worldName>/datapacks/
- (void)downloadDataPack:(DataPackItem *)item
               toProfile:(NSString *)profileName
               worldName:(nullable NSString *)worldName
                progress:(DataPackDownloadProgressHandler _Nullable)progress
              completion:(DataPackDownloadCompletionHandler _Nullable)completion {
    NSFileManager *fm = [NSFileManager defaultManager];
    NSString *dataPacksFolder = nil;

    // Decide the download folder based on whether worldName was given
    if (worldName.length > 0) {
        // Download into saves/<worldName>/datapacks/
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
        // Make sure the target folder exists (including saves/<worldName>/datapacks/)
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
        // Download into <gameDir>/datapacks/ by default
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
                                                     userInfo:@{NSLocalizedDescriptionKey: @"Game directory not found."}];
                    dispatch_async(dispatch_get_main_queue(), ^{ completion(NO, error); });
                }
                return;
            }
        }
    }

    // Validate the download link
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

    // Make sure the file name is valid
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

    // Create the download task (default session configuration, no background throttling)
    NSURLSessionDownloadTask *task = [self.downloadSession downloadTaskWithURL:url];
    self.downloadCompletionHandlers[task] = completion;
    self.downloadDestinationPaths[task] = destinationPath;
    // Only create the NSProgress object when the caller wants progress callbacks
    if (progress) {
        NSProgress *progressObj = [NSProgress progressWithTotalUnitCount:-1];
        progressObj.kind = NSProgressKindFile;
        self.downloadProgresses[task] = progressObj;
        self.downloadProgressHandlers[task] = progress;
    }

    // Register with the shared download task manager (the floating button is gone, but registering keeps the task list accurate)
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

    // Set retryHandler: FCL-style re-download
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

// Download progress callback: update NSProgress and report on the main thread
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

    // Set the total byte count on the first callback (it stays -1 if the HTTP headers did not provide one)
    if (progressObj.totalUnitCount < 0 && totalBytesExpectedToWrite > 0) {
        progressObj.totalUnitCount = totalBytesExpectedToWrite;
    }
    progressObj.completedUnitCount = totalBytesWritten;

    // The progress callback runs on the main thread (so UI updates are safe)
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

    // Verify what actually landed. A download task reports no error for an HTTP 403 or 404 - the
    // error page arrives as the body - so without this an error page was installed under a .jar or
    // .zip name and only showed up later as a game that would not start.
    if (success) {
        NSString *rejection = [ArchiveIntegrity rejectionReasonForDownloadedFile:destinationPath
                                                                        response:downloadTask.response];
        if (rejection) {
            [fm removeItemAtPath:destinationPath error:nil];
            success = NO;
            moveError = [NSError errorWithDomain:@"DataPackServiceError" code:5003 userInfo:@{
                NSLocalizedDescriptionKey: [NSString stringWithFormat:@"Damaged download of %@: %@",
                                            destinationPath.lastPathComponent, rejection]
            }];
            NSLog(@"[DataPackService] Discarded damaged download of %@ (%@)", destinationPath.lastPathComponent, rejection);
        }
    }

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
