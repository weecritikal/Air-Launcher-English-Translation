//
//  WorldService.m
//  Flux
//
//  World save service implementation, structured after ResourcePackService/DataPackService
//  The API consistently takes NSString *profileName
//  Uses defaultSessionConfiguration + NSURLSessionDownloadTask for better download throughput
//  Implements robust extraction logic: detect whether the zip contains a top-level directory, and if not create a subdirectory before extracting
//

#import "WorldService.h"
#import <CommonCrypto/CommonCrypto.h>
#import <UIKit/UIKit.h>
#import "PLProfiles.h"
#import "WorldItem.h"
#import "UZKArchive.h"
#import "DownloadTaskManager.h"
#import "DownloadTaskItem.h"
#import "LauncherPreferences.h"
#import "utils.h"

@interface WorldService () <NSURLSessionDownloadDelegate>
@property (nonatomic, strong) NSURLSession *downloadSession;
// Internally stores the completion handler carrying success/error
@property (nonatomic, strong) NSMutableDictionary<NSURLSessionTask *, WorldDownloadCompletionHandler> *downloadCompletionHandlers;
@property (nonatomic, strong) NSMutableDictionary<NSURLSessionTask *, NSString *> *downloadDestinationPaths;
// Progress callbacks: the progress handler and the NSProgress object are stored separately
@property (nonatomic, strong) NSMutableDictionary<NSURLSessionTask *, WorldDownloadProgressHandler> *downloadProgressHandlers;
@property (nonatomic, strong) NSMutableDictionary<NSURLSessionTask *, NSProgress *> *downloadProgresses;
@property (nonatomic, strong) NSMutableDictionary<NSURLSessionTask *, DownloadTaskItem *> *downloadTaskItems;
@property (nonatomic, strong) NSMutableDictionary<NSURLSessionTask *, NSMutableDictionary *> *downloadProgressSnapshots;
// Dictionary dedicated to import tasks (they are not downloaded via NSURLSession but still need progress reporting)
@property (nonatomic, strong) NSMutableDictionary<NSString *, WorldDownloadCompletionHandler> *importCompletionHandlers;
@end

@implementation WorldService

+ (instancetype)sharedService {
    static WorldService *s;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        s = [[WorldService alloc] init];
    });
    return s;
}

- (instancetype)init {
    if (self = [super init]) {
        // Use the default session configuration to avoid background-session throttling
        NSURLSessionConfiguration *config = [NSURLSessionConfiguration defaultSessionConfiguration];
        config.timeoutIntervalForRequest = 120.0;
        config.timeoutIntervalForResource = 600.0; // World packs are usually large, so use a longer timeout
        config.allowsCellularAccess = YES;
        config.HTTPMaximumConnectionsPerHost = 6;

        _downloadSession = [NSURLSession sessionWithConfiguration:config delegate:self delegateQueue:nil];
        _downloadCompletionHandlers = [NSMutableDictionary dictionary];
        _downloadDestinationPaths = [NSMutableDictionary dictionary];
        _downloadProgressHandlers = [NSMutableDictionary dictionary];
        _downloadProgresses = [NSMutableDictionary dictionary];
        _downloadTaskItems = [NSMutableDictionary dictionary];
        _downloadProgressSnapshots = [NSMutableDictionary dictionary];
        _importCompletionHandlers = [NSMutableDictionary dictionary];
    }
    return self;
}

#pragma mark - Utility methods

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

#pragma mark - Saves folder detection & scan

// Look up the saves directory of the given profile (returns the path if it exists, otherwise nil)
- (nullable NSString *)existingWorldsFolderForProfile:(NSString *)profileName {
    NSString *profile = profileName.length ? profileName : @"default";
    NSFileManager *fm = [NSFileManager defaultManager];

    @try {
        NSDictionary *profiles = PLProfiles.current.profiles;
        NSDictionary *prof = profiles[profile];
        if ([prof isKindOfClass:[NSDictionary class]]) {
            NSString *gameDir = prof[@"gameDir"];
            if ([gameDir isKindOfClass:[NSString class]] && gameDir.length > 0) {
                NSString *savesPath = [gameDir stringByAppendingPathComponent:@"saves"];
                BOOL isDir = NO;
                if ([fm fileExistsAtPath:savesPath isDirectory:&isDir] && isDir) {
                    return savesPath;
                }
            }
        }
    } @catch (NSException *ex) { }

    // Fallback: read the POJAV_GAME_DIR environment variable
    const char *gameDirC = getenv("POJAV_GAME_DIR");
    if (gameDirC) {
        NSString *gameDir = [NSString stringWithUTF8String:gameDirC];
        NSString *savesPath = [gameDir stringByAppendingPathComponent:@"saves"];
        BOOL isDir = NO;
        if ([fm fileExistsAtPath:savesPath isDirectory:&isDir] && isDir) {
            return savesPath;
        }
    }
    return nil;
}

/// Get the saves directory of the current profile, creating it automatically if it does not exist
- (nullable NSString *)ensureWorldsFolderForProfile:(NSString *)profileName error:(NSError **)error {
    NSString *profile = profileName.length ? profileName : @"default";
    NSFileManager *fm = [NSFileManager defaultManager];
    NSString *savesPath = nil;

    @try {
        NSDictionary *profiles = PLProfiles.current.profiles;
        NSDictionary *prof = profiles[profile];
        if ([prof isKindOfClass:[NSDictionary class]]) {
            NSString *gameDir = prof[@"gameDir"];
            if ([gameDir isKindOfClass:[NSString class]] && gameDir.length > 0) {
                savesPath = [gameDir stringByAppendingPathComponent:@"saves"];
            }
        }
    } @catch (NSException *ex) { }

    if (!savesPath) {
        const char *gameDirC = getenv("POJAV_GAME_DIR");
        if (gameDirC) {
            NSString *gameDir = [NSString stringWithUTF8String:gameDirC];
            savesPath = [gameDir stringByAppendingPathComponent:@"saves"];
        }
    }

    if (!savesPath) {
        if (error) {
            *error = [NSError errorWithDomain:@"WorldService" code:1 userInfo:@{NSLocalizedDescriptionKey: @"Could not determine the game directory"}];
        }
        return nil;
    }

    BOOL isDir = NO;
    if (![fm fileExistsAtPath:savesPath isDirectory:&isDir]) {
        NSError *createError = nil;
        [fm createDirectoryAtPath:savesPath withIntermediateDirectories:YES attributes:nil error:&createError];
        if (createError) {
            if (error) *error = createError;
            return nil;
        }
        NSLog(@"[WorldService] created saves directory: %@", savesPath);
    } else if (!isDir) {
        if (error) {
            *error = [NSError errorWithDomain:@"WorldService" code:2 userInfo:@{NSLocalizedDescriptionKey: [NSString stringWithFormat:@"%@ is not a directory", savesPath]}];
        }
        return nil;
    }
    return savesPath;
}

- (void)scanWorldsForProfile:(NSString *)profileName completion:(WorldListHandler)completion {
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSString *savesFolder = [self existingWorldsFolderForProfile:profileName];
        NSMutableArray<WorldItem *> *items = [NSMutableArray array];

        if (!savesFolder) {
            if (completion) {
                dispatch_async(dispatch_get_main_queue(), ^{ completion(items); });
            }
            return;
        }

        NSFileManager *fm = [NSFileManager defaultManager];
        NSError *listError = nil;
        NSArray<NSString *> *contents = [fm contentsOfDirectoryAtPath:savesFolder error:&listError];
        if (!contents) {
            if (completion) {
                dispatch_async(dispatch_get_main_queue(), ^{ completion(items); });
            }
            return;
        }

        for (NSString *subDir in contents) {
            NSString *fullPath = [savesFolder stringByAppendingPathComponent:subDir];
            BOOL isDir = NO;
            if (![fm fileExistsAtPath:fullPath isDirectory:&isDir] || !isDir) {
                continue;
            }
            // Check whether level.dat exists, to confirm this is a valid world save
            NSString *levelDat = [fullPath stringByAppendingPathComponent:@"level.dat"];
            if ([fm fileExistsAtPath:levelDat]) {
                WorldItem *world = [[WorldItem alloc] initWithFilePath:fullPath];
                [items addObject:world];
            }
        }

        // Sort by last played time in descending order (entries without a time go last)
        [items sortUsingComparator:^NSComparisonResult(WorldItem *obj1, WorldItem *obj2) {
            NSString *t1 = obj1.lastPlayed ?: @"";
            NSString *t2 = obj2.lastPlayed ?: @"";
            return [t2 compare:t1]; // Descending order
        }];

        if (completion) {
            dispatch_async(dispatch_get_main_queue(), ^{ completion(items); });
        }
    });
}

// Delete a world directory (recursively)
- (BOOL)deleteWorld:(WorldItem *)item error:(NSError **)error {
    if (!item.filePath) {
        if (error) {
            *error = [NSError errorWithDomain:@"WorldServiceError" code:101 userInfo:@{NSLocalizedDescriptionKey: @"The world directory path is empty"}];
        }
        return NO;
    }
    return [[NSFileManager defaultManager] removeItemAtPath:item.filePath error:error];
}

#pragma mark - Robust extraction logic

// Detect whether the zip contains a top-level directory (i.e. every entry starts with the same directory name)
// If it does, return that top-level directory name; otherwise return nil (meaning the zip holds level.dat and friends loose at the root)
- (nullable NSString *)detectTopLevelDirectoryInZip:(NSString *)zipPath {
    NSError *err = nil;
    UZKArchive *archive = [[UZKArchive alloc] initWithPath:zipPath error:&err];
    if (!archive || err) return nil;

    NSArray<NSString *> *fileNames = [archive listFilenames:&err];
    if (!fileNames || fileNames.count == 0) return nil;

    NSMutableSet<NSString *> *topLevels = [NSMutableSet set];
    for (NSString *name in fileNames) {
        if (name.length == 0) continue;
        // Skip macOS metadata files (such as __MACOSX/...)
        if ([name hasPrefix:@"__MACOSX/"]) continue;
        // Take the first path segment as the top-level directory candidate
        NSString *firstComponent = [name componentsSeparatedByString:@"/"].firstObject;
        if (firstComponent.length == 0) continue;
        [topLevels addObject:firstComponent];
    }

    // Only treat the zip as having a top-level directory when every entry shares the same one
    if (topLevels.count == 1) {
        return [topLevels anyObject];
    }
    return nil;
}

// Robust extraction:
// - If the zip has a top-level directory, extract straight into saves/
// - If the zip has no top-level directory (loose files), first create a subdirectory named after the world, then extract into it
// - worldName is used to name the new world directory when there is no top-level directory
- (BOOL)extractWorldZipAt:(NSString *)zipPath
                toSavesDir:(NSString *)savesDir
                worldName:(NSString *)worldName
                    error:(NSError **)error {
    NSFileManager *fm = [NSFileManager defaultManager];

    NSString *topLevelDir = [self detectTopLevelDirectoryInZip:zipPath];
    NSString *extractTargetDir = nil;
    NSString *finalWorldDir = nil;

    if (topLevelDir) {
        // The zip has a top-level directory, so extract straight into saves/
        extractTargetDir = savesDir;
        finalWorldDir = [savesDir stringByAppendingPathComponent:topLevelDir];
    } else {
        // The zip has no top-level directory, so a subdirectory must be created before extracting
        NSString *baseName = worldName.length > 0 ? worldName : [zipPath lastPathComponent];
        // Strip any .zip suffix
        if ([baseName.lowercaseString hasSuffix:@".zip"]) {
            baseName = [baseName substringToIndex:baseName.length - @".zip".length];
        }
        // If saves/<baseName> already exists, append a numeric suffix to avoid overwriting it
        NSString *candidate = [savesDir stringByAppendingPathComponent:baseName];
        NSInteger suffix = 1;
        while ([fm fileExistsAtPath:candidate]) {
            candidate = [savesDir stringByAppendingPathComponent:[NSString stringWithFormat:@"%@_%ld", baseName, (long)suffix]];
            suffix++;
        }
        extractTargetDir = candidate;
        finalWorldDir = candidate;

        // Create the target subdirectory
        NSError *createError = nil;
        if (![fm createDirectoryAtPath:extractTargetDir withIntermediateDirectories:YES attributes:nil error:&createError]) {
            if (error) *error = createError;
            return NO;
        }
    }

    // Extract into the target directory with UnzipKit
    NSError *archiveError = nil;
    UZKArchive *archive = [[UZKArchive alloc] initWithPath:zipPath error:&archiveError];
    if (!archive || archiveError) {
        if (error) *error = archiveError;
        return NO;
    }

    NSError *extractError = nil;
    BOOL success = [archive extractFilesTo:extractTargetDir overwrite:YES error:&extractError];
    if (!success || extractError) {
        if (error) *error = extractError;
        // If extraction failed and we created the subdirectory, clean up the empty directory
        if (!topLevelDir && [fm fileExistsAtPath:extractTargetDir]) {
            NSArray<NSString *> *leftover = [fm contentsOfDirectoryAtPath:extractTargetDir error:nil];
            if (leftover.count == 0) {
                [fm removeItemAtPath:extractTargetDir error:nil];
            }
        }
        return NO;
    }

    // Validate the extraction result: level.dat must exist (either directly under finalWorldDir or one level deeper)
    NSString *levelDatCheck = [finalWorldDir stringByAppendingPathComponent:@"level.dat"];
    if (![fm fileExistsAtPath:levelDatCheck]) {
        // Some zips have a top-level directory but still keep level.dat deeper down. This is only logged, not treated as a failure
        NSLog(@"[WorldService] warning: level.dat not found at %@ after extraction", finalWorldDir);
    }

    NSLog(@"[WorldService] world extracted to: %@", finalWorldDir);
    return YES;
}

#pragma mark - Online world downloads (with robust extraction)

- (void)downloadWorld:(WorldItem *)item
            toProfile:(NSString *)profileName
             progress:(WorldDownloadProgressHandler _Nullable)progress
           completion:(WorldDownloadCompletionHandler _Nullable)completion {
    // Make sure the saves directory exists
    NSError *ensureError = nil;
    NSString *savesFolder = [self ensureWorldsFolderForProfile:profileName error:&ensureError];
    if (!savesFolder) {
        if (completion) {
            NSError *error = ensureError ?: [NSError errorWithDomain:@"WorldServiceError"
                                                                 code:1
                                                             userInfo:@{NSLocalizedDescriptionKey: @"Game directory not found."}];
            dispatch_async(dispatch_get_main_queue(), ^{ completion(NO, error); });
        }
        return;
    }

    // Validate the download link
    NSURL *url = [NSURL URLWithString:item.selectedVersionDownloadURL];
    if (!url) {
        if (completion) {
            NSError *error = [NSError errorWithDomain:@"WorldServiceError"
                                                 code:2
                                             userInfo:@{NSLocalizedDescriptionKey: @"Invalid download link."}];
            dispatch_async(dispatch_get_main_queue(), ^{ completion(NO, error); });
        }
        return;
    }

    // Download to a temporary zip path and delete it after extraction
    NSString *tempZipName = [NSString stringWithFormat:@"world_%@.zip", [[NSUUID UUID] UUIDString]];
    NSString *destinationPath = [NSTemporaryDirectory() stringByAppendingPathComponent:tempZipName];
    // Also record the expected world name (used to name the subdirectory when there is no top-level directory)
    NSString *worldNameForExtract = item.displayName ?: item.worldName ?: [url lastPathComponent];

    // Create the download task (default session configuration, no background throttling)
    NSURLSessionDownloadTask *task = [self.downloadSession downloadTaskWithURL:url];
    self.downloadCompletionHandlers[task] = completion;
    self.downloadDestinationPaths[task] = destinationPath;
    // Use taskDescription to stash the world name and the saves directory (for the extraction phase)
    // Format: "worldName\nsavesFolder"
    task.taskDescription = [NSString stringWithFormat:@"%@\n%@", worldNameForExtract, savesFolder];
    if (progress) {
        NSProgress *progressObj = [NSProgress progressWithTotalUnitCount:-1];
        progressObj.kind = NSProgressKindFile;
        self.downloadProgresses[task] = progressObj;
        self.downloadProgressHandlers[task] = progress;
    }

    // Register with the shared download task manager (the floating button is gone, but registering keeps the task list accurate)
    NSString *resourceName = item.worldName.length > 0 ? item.worldName : (item.displayName.length > 0 ? item.displayName : @"world");
    NSString *displayName = item.displayName.length > 0 ? item.displayName : resourceName;
    NSString *downloadSource = getPrefObject(@"general.download_source") ?: @"official";
    DownloadTaskItem *taskItem = [[DownloadTaskManager sharedManager]
        registerTaskWithResourceType:DownloadTaskResourceTypeWorld
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
    WorldDownloadCompletionHandler capturedCompletion = completion;
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

    NSLog(@"[WorldService] started downloading world: %@ -> %@", url, destinationPath);
}

#pragma mark - Importing a world from a local file

- (void)importWorldFromURL:(NSURL *)sourceURL
                toProfile:(NSString *)profileName
                 progress:(WorldDownloadProgressHandler _Nullable)progress
               completion:(WorldDownloadCompletionHandler _Nullable)completion {
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        // Make sure the saves directory exists
        NSError *ensureError = nil;
        NSString *savesFolder = [self ensureWorldsFolderForProfile:profileName error:&ensureError];
        if (!savesFolder) {
            if (completion) {
                NSError *error = ensureError ?: [NSError errorWithDomain:@"WorldServiceError"
                                                                     code:1
                                                                 userInfo:@{NSLocalizedDescriptionKey: @"Game directory not found."}];
                dispatch_async(dispatch_get_main_queue(), ^{ completion(NO, error); });
            }
            return;
        }

        // Access the file securely (URLs returned by UIDocumentPicker require startAccessingSecurityScopedResource)
        BOOL needsStopAccessing = NO;
        if ([sourceURL isKindOfClass:[NSURL class]] && sourceURL.isFileURL) {
            needsStopAccessing = [sourceURL startAccessingSecurityScopedResource];
        }

        @try {
            NSString *sourcePath = sourceURL.path;
            if (!sourcePath || ![[NSFileManager defaultManager] fileExistsAtPath:sourcePath]) {
                if (completion) {
                    NSError *error = [NSError errorWithDomain:@"WorldServiceError"
                                                         code:3
                                                     userInfo:@{NSLocalizedDescriptionKey: @"The imported file does not exist."}];
                    dispatch_async(dispatch_get_main_queue(), ^{ completion(NO, error); });
                }
                return;
            }

            // Copy to a temporary file so UnzipKit can read it safely (avoiding security scope restrictions)
            NSString *tempZipPath = [NSTemporaryDirectory() stringByAppendingPathComponent:
                                     [NSString stringWithFormat:@"world_import_%@.zip", [[NSUUID UUID] UUIDString]]];
            NSError *copyError = nil;
            if (![[NSFileManager defaultManager] copyItemAtPath:sourcePath toPath:tempZipPath error:&copyError]) {
                if (completion) {
                    NSError *error = copyError ?: [NSError errorWithDomain:@"WorldServiceError"
                                                                       code:4
                                                                   userInfo:@{NSLocalizedDescriptionKey: @"Failed to copy the imported file."}];
                    dispatch_async(dispatch_get_main_queue(), ^{ completion(NO, error); });
                }
                return;
            }

            // A local import can report 100% progress immediately (there is no network download phase)
            if (progress) {
                NSProgress *prog = [NSProgress progressWithTotalUnitCount:1];
                prog.completedUnitCount = 1;
                dispatch_async(dispatch_get_main_queue(), ^{ progress(prog); });
            }

            // Derive the world name (stripping the .zip suffix)
            NSString *worldName = [sourceURL lastPathComponent];
            if ([worldName.lowercaseString hasSuffix:@".zip"]) {
                worldName = [worldName substringToIndex:worldName.length - @".zip".length];
            }

            // Extract
            NSError *extractError = nil;
            BOOL success = [self extractWorldZipAt:tempZipPath
                                        toSavesDir:savesFolder
                                        worldName:worldName
                                            error:&extractError];

            // Delete the temporary file
            [[NSFileManager defaultManager] removeItemAtPath:tempZipPath error:nil];

            if (completion) {
                dispatch_async(dispatch_get_main_queue(), ^{
                    if (success) {
                        completion(YES, nil);
                    } else {
                        completion(NO, extractError ?: [NSError errorWithDomain:@"WorldServiceError"
                                                                            code:5
                                                                        userInfo:@{NSLocalizedDescriptionKey: @"Failed to extract the world."}]);
                    }
                });
            }
        } @finally {
            if (needsStopAccessing) {
                [sourceURL stopAccessingSecurityScopedResource];
            }
        }
    });
}

#pragma mark - NSURLSessionDownloadDelegate

// Download progress callback: update NSProgress and report on the main thread
- (void)URLSession:(NSURLSession *)session downloadTask:(NSURLSessionDownloadTask *)downloadTask
      didWriteData:(int64_t)bytesWritten
 totalBytesWritten:(int64_t)totalBytesWritten
totalBytesExpectedToWrite:(int64_t)totalBytesExpectedToWrite {
    NSProgress *progressObj = self.downloadProgresses[downloadTask];
    WorldDownloadProgressHandler progressHandler = self.downloadProgressHandlers[downloadTask];
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
    WorldDownloadCompletionHandler handler = self.downloadCompletionHandlers[downloadTask];
    NSString *destinationPath = self.downloadDestinationPaths[downloadTask];
    NSString *taskDescription = downloadTask.taskDescription;
    DownloadTaskItem *taskItem = self.downloadTaskItems[downloadTask];

    [self.downloadCompletionHandlers removeObjectForKey:downloadTask];
    [self.downloadDestinationPaths removeObjectForKey:downloadTask];
    [self.downloadProgresses removeObjectForKey:downloadTask];
    [self.downloadProgressHandlers removeObjectForKey:downloadTask];
    [self.downloadTaskItems removeObjectForKey:downloadTask];
    [self.downloadProgressSnapshots removeObjectForKey:downloadTask];

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
        if (taskItem) {
            [[DownloadTaskManager sharedManager] updateTaskWithId:taskItem.taskId error:moveError];
            [[DownloadTaskManager sharedManager] setTaskWithId:taskItem.taskId state:DownloadTaskStateFailed];
        }
        dispatch_async(dispatch_get_main_queue(), ^{ handler(NO, moveError); });
        return;
    }

    if (taskItem) {
        [[DownloadTaskManager sharedManager] setTaskWithId:taskItem.taskId state:DownloadTaskStateCompleted];
    }

    // Parse taskDescription: worldName and savesFolder
    NSString *worldName = nil;
    NSString *savesFolder = nil;
    if (taskDescription.length > 0) {
        NSArray<NSString *> *parts = [taskDescription componentsSeparatedByString:@"\n"];
        if (parts.count >= 1) worldName = parts[0];
        if (parts.count >= 2) savesFolder = parts[1];
    }
    if (!savesFolder) {
        // No saves directory information, so fall back to deleting the temporary zip and reporting an error
        [fm removeItemAtPath:destinationPath error:nil];
        dispatch_async(dispatch_get_main_queue(), ^{
            handler(NO, [NSError errorWithDomain:@"WorldServiceError"
                                            code:6
                                        userInfo:@{NSLocalizedDescriptionKey: @"The saves directory is unknown, so it cannot be extracted."}]);
        });
        return;
    }

    // Extract on a background thread
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSError *extractError = nil;
        BOOL success = [self extractWorldZipAt:destinationPath
                                    toSavesDir:savesFolder
                                    worldName:worldName ?: @"imported_world"
                                        error:&extractError];

        // Delete the temporary zip once extraction completes
        [fm removeItemAtPath:destinationPath error:nil];

        dispatch_async(dispatch_get_main_queue(), ^{
            if (success) {
                handler(YES, nil);
            } else {
                handler(NO, extractError ?: [NSError errorWithDomain:@"WorldServiceError"
                                                                code:5
                                                            userInfo:@{NSLocalizedDescriptionKey: @"Failed to extract the world."}]);
            }
        });
    });
}

- (void)URLSession:(NSURLSession *)session task:(NSURLSessionTask *)task didCompleteWithError:(NSError *)error {
    if (error) {
        WorldDownloadCompletionHandler handler = self.downloadCompletionHandlers[task];
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
