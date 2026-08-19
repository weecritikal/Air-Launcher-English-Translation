#include <CommonCrypto/CommonDigest.h>
#include <sys/time.h>

#import "ArchiveIntegrity.h"
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
- (BOOL)hasVerifiedHash:(NSString *)sha;
- (NSString *)integrityFailureForDownloadAtPath:(NSString *)path
                                   expectedSize:(NSUInteger)expectedSize
                                            sha:(NSString *)sha
                                        altName:(NSString *)altName
                                       response:(NSURLResponse *)response;
@end

@implementation MinecraftResourceDownloadTask

+ (AFURLSessionManager *)sharedBackgroundSessionManager {
    // Following the main branch: use the foreground defaultSessionConfiguration rather than backgroundSessionConfiguration.
    //
    // Why not a background URLSession:
    // 1. A background session is scheduled by the nsurlsessiond system daemon, which throttles concurrency and serializes tasks,
    //    making a vanilla download (hundreds of assets + dozens of libraries) extremely slow — "spinning without downloading".
    // 2. Unfinished background session tasks are persisted by the system, so a failure/cancellation that is not clean leaves a task behind that blocks new downloads.
    // 3. A foreground session runs concurrently as soon as resume is called, which suits a launcher downloading in the foreground.
    //
    // The singleton pattern is kept (so a new session is not created on every init), but with the foreground configuration.
    static AFURLSessionManager *manager = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        NSURLSessionConfiguration *configuration = [NSURLSessionConfiguration defaultSessionConfiguration];
        configuration.timeoutIntervalForRequest = 86400;
        // Following FCL (FoldCraftLauncher) and ZalithLauncher2: high-concurrency download acceleration.
        // FCL uses the OkHttp thread pool on the Java side to download concurrently; the equivalent here is raising
        // HTTPMaximumConnectionsPerHost on NSURLSession. Raised from 16 to 24, speeding up the concurrent download of the
        // hundreds of vanilla assets. Note that iOS caps the real per-host concurrency, so setting it too high
        // is downgraded by the system; 24 is an empirical value. Integrity is still guaranteed by the SHA1 check.
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
    // Phase 5 fix: initialize the failed file list (following the failure summary mechanism of FCL)
    self.failedFiles = [NSMutableArray new];
    return self;
}

// Pick the download source from the settings and rewrite the URL
- (NSString *)replaceURLWithDownloadSource:(NSString *)originalURL {
    return [self replaceURLWithDownloadSource:originalURL forceSource:nil];
}

/// The core mirror substitution implementation.
/// Following FCL (FoldCraftLauncher) and ZalithLauncher2: multiple mirror sources with fallback.
/// @param originalURL The original URL
/// @param forceSource The source to force (nil = use the user preference; @"official" = no substitution; @"bmclapi" = force BMCLAPI).
///                    On a retry after a failed download, the caller passes the opposite source to switch mirrors,
///                    so one failing mirror cannot stall the whole batch.
- (NSString *)replaceURLWithDownloadSource:(NSString *)originalURL forceSource:(nullable NSString *)forceSource {
    if (!originalURL) return originalURL;

    NSString *downloadSource = forceSource ?: getPrefObject(@"general.download_source");
    if (!downloadSource || [downloadSource isEqualToString:@"official"]) {
        return originalURL;
    }

    // The BMCLAPI mirror
    if ([downloadSource isEqualToString:@"bmclapi"]) {
        // piston-meta.mojang.com: the Mojang domain for the newer version manifest and version JSON (used from 1.19 onwards)
        // Fix: version.json connected directly to this domain during a vanilla install, which timed out in mainland China and left it spinning without downloading
        if ([originalURL containsString:@"piston-meta.mojang.com"]) {
            originalURL = [originalURL stringByReplacingOccurrencesOfString:@"https://piston-meta.mojang.com"
                                                                withString:@"https://bmclapi2.bangbang93.com"];
        }
        // piston-data.mojang.com: the Mojang domain for the newer client.jar and asset downloads
        if ([originalURL containsString:@"piston-data.mojang.com"]) {
            originalURL = [originalURL stringByReplacingOccurrencesOfString:@"https://piston-data.mojang.com"
                                                                withString:@"https://bmclapi2.bangbang93.com"];
        }

        // Version manifest and version JSON (the old domain, kept for backward compatibility)
        if ([originalURL containsString:@"launchermeta.mojang.com"] ||
            [originalURL containsString:@"launcher.mojang.com"]) {
            return [originalURL stringByReplacingOccurrencesOfString:@"https://launchermeta.mojang.com"
                                                           withString:@"https://bmclapi2.bangbang93.com"];
        }

        // Assets
        if ([originalURL containsString:@"resources.download.minecraft.net"]) {
            return [originalURL stringByReplacingOccurrencesOfString:@"http://resources.download.minecraft.net"
                                                           withString:@"https://bmclapi2.bangbang93.com/assets"];
        }

        // Library files
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

        // The Mojang Java runtime
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
        // A file already on disk is only reusable if it is actually intact. Without this,
        // a jar that arrived truncated (or as an error page) is skipped on every subsequent
        // install as "already downloaded", so reinstalling the modpack never repaired it and
        // the only way out was deleting the whole instance. Re-downloading it here makes a
        // reinstall a repair.
        NSString *archiveFailure = (![self hasVerifiedHash:sha] && [ArchiveIntegrity isArchivePath:path])
            ? [ArchiveIntegrity validationFailureForArchiveAtPath:path] : nil;
        if (!archiveFailure) {
            if (success) success();
            return nil;
        }
        NSLog(@"[MCDL] Existing file '%@' is corrupt (%@), downloading it again", path.lastPathComponent, archiveFailure);
        [NSFileManager.defaultManager removeItemAtPath:path error:nil];
    } else if (![self checkAccessWithDialog:YES]) {
        return nil;
    }

    NSString *name = altName ?: path.lastPathComponent;
    // Pick the download source from the settings and rewrite the URL
    // Following FCL (FoldCraftLauncher) and ZalithLauncher2: switch to the opposite mirror on a retry,
    // so one failing mirror cannot stall the whole batch. The SHA1 check still runs, so download integrity is unaffected.
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
        NSString *integrityFailure = nil;
        if (self.progress.cancelled) {
            // Ignore any further errors
        } else if (error != nil) {
            // Retry mechanism
            NSInteger maxRetry = weakSelf.maxRetryCount > 0 ? weakSelf.maxRetryCount : 3;
            if (retryCount < maxRetry) {
                NSInteger nextRetry = retryCount + 1;
                NSLog(@"[MCDL] Retrying %@ (attempt %ld/%ld)", name, (long)nextRetry, (long)maxRetry);
                
                if (weakSelf.retryCallback) {
                    dispatch_async(dispatch_get_main_queue(), ^{
                        weakSelf.retryCallback(nextRetry, maxRetry);
                    });
                }
                
                // Retry after a delay (shortened to 0.5 seconds, so retrying hundreds of files does not add up to a long wait)
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                    NSURLSessionDownloadTask *retryTask = [weakSelf createDownloadTask:url size:size sha:sha altName:altName toPath:path retryCount:nextRetry success:success];
                    if (retryTask) {
                        [retryTask resume];
                    }
                });
            } else {
                [weakSelf finishDownloadWithError:error file:name];
                // Phase 5 fix (following FCL): the progress must be advanced by hand after a single file fails, otherwise the parent progress
                // never reaches 100% (nothing fills in the share of the failed child progress),
                // and the user sees the download bar stuck and assumes the download did not finish.
                // Note: the destination block is only invoked on a successful download, so progress
                // may be nil here. The child progress for this task has to be fetched from the manager again.
                NSProgress *taskProgress = progress ?: [weakSelf.manager downloadProgressForTask:task];
                if (taskProgress) {
                    int64_t pending = taskProgress.totalUnitCount - taskProgress.completedUnitCount;
                    if (pending > 0) {
                        taskProgress.completedUnitCount = taskProgress.totalUnitCount;
                    }
                } else if (weakSelf.progress.totalUnitCount > weakSelf.progress.completedUnitCount) {
                    // Last resort: if even the child progress cannot be obtained (e.g. the size is unknown and destination never fired),
                    // push one unit into the parent progress directly, so the download bar does not freeze.
                    weakSelf.progress.completedUnitCount += 1;
                }
            }
        } else if ((integrityFailure = [weakSelf integrityFailureForDownloadAtPath:path expectedSize:size sha:sha altName:altName response:response]) != nil) {
            // A file that failed verification is retried too
            NSInteger maxRetry = weakSelf.maxRetryCount > 0 ? weakSelf.maxRetryCount : 3;
            if (retryCount < maxRetry) {
                NSInteger nextRetry = retryCount + 1;
                NSLog(@"[MCDL] %@ failed verification (%@), retrying (attempt %ld/%ld)", name, integrityFailure, (long)nextRetry, (long)maxRetry);

                // Delete the corrupted file
                [NSFileManager.defaultManager removeItemAtPath:path error:nil];

                // The retry delay after a verification failure is shortened to 0.3 seconds
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.3 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                    NSURLSessionDownloadTask *retryTask = [weakSelf createDownloadTask:url size:size sha:sha altName:altName toPath:path retryCount:nextRetry success:success];
                    if (retryTask) {
                        [retryTask resume];
                    }
                });
            } else {
                // Phase 5 fix (following FCL): a verification failure is recorded in failedFiles rather than cancelling the batch.
                // The corrupt file must not be left behind: something downstream (Forge scanning
                // mods/, the JVM opening a library) would try to open it and fail with an error
                // that names nothing. Removing it keeps the failure reportable and recoverable.
                [NSFileManager.defaultManager removeItemAtPath:path error:nil];
                @synchronized(weakSelf.failedFiles) {
                    [weakSelf.failedFiles addObject:@{
                        @"name": name ?: (path.lastPathComponent ?: @"unknown"),
                        @"error": integrityFailure ?: @"failed verification"
                    }];
                }
                NSLog(@"[MCDL] '%@' failed verification (%@), added to failedFiles (total failed: %lu), other downloads will continue",
                      name, integrityFailure, (unsigned long)weakSelf.failedFiles.count);
                // Phase 5 fix: as in the error branch above, advance the parent progress so it cannot freeze
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
            if (inheritsFromDict && !inheritsFromDict[@"NSErrorObject"]) {  // Add the error dictionary check
                // Fix: parseJSONFromFile returns an error dictionary rather than nil,
                //   so a missing inheritsFrom parent version had its error dictionary treated as metadata
                [MinecraftResourceUtils processVersion:self.metadata inheritsFrom:inheritsFromDict];
                self.metadata = inheritsFromDict;
            } else {
                // The parent version is missing or corrupt, so report an error
                [self finishDownloadWithErrorString:[NSString stringWithFormat:@"Missing version.json for the parent version %@", self.metadata[@"inheritsFrom"]]];
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
                // Phase 5 fix (following FCL ModpackHelper.ensureCompleteVersion):
                // findVersion usually fails because remoteVersionList has not loaded yet (modpack import runs on a background thread,
                // rather than through the manifest loading flow of DownloadViewController).
                // At this point, check whether the parent version JSON was already downloaded by ensureParentVersionExists:
                //   - present     -> go straight to completionBlock, and the libraries/assets download continues as usual
                //   - not present -> report an error (the launcher cannot continue)
                NSString *parentJsonPath = [NSString stringWithFormat:@"%1$s/versions/%2$@/%2$@.json",
                                            getenv("POJAV_GAME_DIR"), json[@"inheritsFrom"]];
                if ([NSFileManager.defaultManager fileExistsAtPath:parentJsonPath]) {
                    NSLog(@"[MCDL] remoteVersionList not loaded, but parent version JSON exists: %@", parentJsonPath);
                    completionBlock();
                    return;
                } else {
                    [self finishDownloadWithErrorString:[NSString stringWithFormat:@"Missing version.json for the parent version %@, and the remote version manifest is not loaded, so it cannot be downloaded automatically", json[@"inheritsFrom"]]];
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
    // Clean up leftover tasks from the previous download on the shared session (required with a foreground shared session,
    // otherwise a failed/cancelled task left in the session can interfere with a new download).
    // Note: the shared session must not be invalidated (that would break every later download); only the tasks are cancelled.
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
    // Phase 5 fix: reset the failed file list (following FCL)
    [self.failedFiles removeAllObjects];

    // Register/update with the shared download task manager
    [self registerOrUpdateTaskItem];

    // Observe the overall progress
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
    // The floating button is gone, but tasks are always registered with the shared download task manager so the task list stays accurate
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
                                       userInfo:@{NSLocalizedDescriptionKey: error ?: @"Download failed"}];
        [[DownloadTaskManager sharedManager] setTaskWithId:self.currentDownloadTaskItem.taskId
                                          completedWithError:err];
    }

    [self.progress cancel];

    // Cancel every background download belonging to this task, so a failure does not keep wasting bandwidth
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

    // Phase 5 fix (following FCL): one failed file no longer cancels the whole batch.
    //
    // Calling finishDownloadWithErrorString: used to:
    //   1. cancel every download with the same taskId (so all the other files in flight were cancelled too)
    //   2. show an error dialog that aborted the whole download
    //   3. leave the modpack incomplete — users reported "the downloaded mod names are wrong and the download is incomplete"
    //
    // What FCL does: record the failed file in the failedFiles array, let the other files carry on downloading,
    // and report a summary at the end. This matches the FCL design of "one failed file does not affect the others" exactly.
    //
    // Note: this tolerance only applies to multi-file modpack downloads. A single-file version download (downloadVersion:)
    // should never reach this method (its completionHandler has its own error path), but if it somehow does,
    // finishDownloadWithErrorString: is not triggered while failedFiles.count == 0,
    // so the behavior stays compatible with the original logic.
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

    // Speed / estimated time remaining (computed once per second)
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
            // Phase 5 fix (following FCL DownloadList.finishAll): once the download flow ends,
            // failed files must not simply be reported as "finished successfully" — that would leave the user thinking the modpack was complete.
            // The failed files are summarized into an NSError so DownloadTaskManager shows a failed state,
            // and the user can see exactly which files are missing in the download task list.
            NSArray<NSDictionary *> *failedSnapshot = [self.failedFiles copy];
            if (failedSnapshot.count > 0) {
                NSMutableString *msg = [NSMutableString stringWithFormat:@"Download finished, but %lu file(s) failed:", (unsigned long)failedSnapshot.count];
                NSUInteger showCount = MIN(failedSnapshot.count, (NSUInteger)5);
                for (NSUInteger k = 0; k < showCount; k++) {
                    NSString *n = failedSnapshot[k][@"name"];
                    [msg appendFormat:@"\n  • %@", n ?: @"(unknown)"];
                }
                if (failedSnapshot.count > showCount) {
                    [msg appendFormat:@"\n  ...and %lu in total", (unsigned long)failedSnapshot.count];
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

// Key change: remove the download restriction and prompt for local accounts
- (BOOL)checkAccessWithDialog:(BOOL)show {
    // Allow every download request unconditionally
    return YES;
}

// YES when checkSHA: compares against a real hash for this file, rather than falling back to
// "the file exists and is not empty". Only in that case is a passing check proof of correctness.
- (BOOL)hasVerifiedHash:(NSString *)sha {
    return sha.length > 0 && getPrefBool(@"general.check_sha");
}

// Verify a file the moment it finishes downloading.
//
// The SHA1 check alone was not enough. CurseForge often reports no SHA1 for a file, in which
// case checkSHA: only confirms the file exists, and a CDN that answers with an HTML error page
// under a 200 status produces a perfectly "existing" file. Either way a broken jar was written
// into mods/, and the first sign of trouble was the JVM dying at launch with
// "zip END header not found" — naming no file, so the only fix anyone could find was deleting
// the instance and reinstalling everything.
//
// Returns nil when the file is good, otherwise a short reason suitable for the failure summary.
- (NSString *)integrityFailureForDownloadAtPath:(NSString *)path
                                   expectedSize:(NSUInteger)expectedSize
                                            sha:(NSString *)sha
                                        altName:(NSString *)altName
                                       response:(NSURLResponse *)response {
    // 1. An HTTP error status. AFNetworking does not run its response serializer for download
    //    tasks, so a 403/404 body arrives with error == nil and gets saved as if it were the file.
    if ([response isKindOfClass:NSHTTPURLResponse.class]) {
        NSInteger statusCode = ((NSHTTPURLResponse *)response).statusCode;
        if (statusCode >= 400) {
            return [NSString stringWithFormat:@"server returned HTTP %ld", (long)statusCode];
        }
    }

    if (![NSFileManager.defaultManager fileExistsAtPath:path]) {
        return @"the file was not written to disk";
    }

    // 2. The size the server promised, against what actually landed. This catches a transfer
    //    that was cut short even when no hash is available to compare.
    //    Only a short file is treated as a failure: a file that came back longer than the
    //    catalogue claims points at stale metadata rather than a bad download, and rejecting
    //    those would block mods that are perfectly fine. Step 4 still inspects the archive.
    unsigned long long actualSize = [NSFileManager.defaultManager attributesOfItemAtPath:path error:nil].fileSize;
    if (expectedSize > 0 && actualSize < (unsigned long long)expectedSize) {
        return [NSString stringWithFormat:@"incomplete download (expected %lu bytes, got %llu)",
                (unsigned long)expectedSize, actualSize];
    }

    // 3. The hash, when one is known and the preference is on.
    if (![self checkSHA:sha forFile:path altName:altName]) {
        return @"SHA1 mismatch";
    }

    // 4. Structure, for anything the JVM will later open as a ZIP. This is the backstop for every
    //    file that has no hash and no declared size. A file whose SHA1 actually matched is already
    //    proven byte-for-byte correct, so it is left alone — the structural check must never be
    //    able to reject a file the hash vouched for.
    if (![self hasVerifiedHash:sha] && [ArchiveIntegrity isArchivePath:path]) {
        NSString *archiveFailure = [ArchiveIntegrity validationFailureForArchiveAtPath:path];
        if (archiveFailure) {
            return archiveFailure;
        }
    }

    return nil;
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
        // Check not only that the file exists but also that its size is > 0 (so an empty file is not mistaken for a completed download)
        // Fix: during a vanilla install a file wrongly created as 0 bytes was treated as already downloaded,
        //   so totalUnitCount went from 1 to 0 and forced completion (a 0-byte download)
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
