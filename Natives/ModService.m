//
//  ModService.m
//  AmethystMods
//
//  Change: added a file modification time cache, greatly speeding up scanning
//  Change: switched the download session to the default configuration, fixing the slow downloads caused by background session throttling
//

#import "ModService.h"
#import <CommonCrypto/CommonCrypto.h>
#import <UIKit/UIKit.h>
#import "PLProfiles.h"
#import "ModItem.h"
#import "UnzipKit.h"
#import "DownloadTaskManager.h"
#import "DownloadTaskItem.h"
#import "LauncherPreferences.h"

@interface ModService () <NSURLSessionDownloadDelegate>
@property (nonatomic, strong) NSURLSession *downloadSession;
@property (nonatomic, strong) NSMutableDictionary<NSURLSessionTask *, ModDownloadHandler> *downloadCompletionHandlers;
@property (nonatomic, strong) NSMutableDictionary<NSURLSessionTask *, NSString *> *downloadDestinationPaths;
@property (nonatomic, strong) NSMutableDictionary<NSURLSessionTask *, void(^)(NSProgress *)> *downloadProgressHandlers;
@property (nonatomic, strong) NSMutableDictionary<NSURLSessionTask *, DownloadTaskItem *> *downloadTaskItems;
@property (nonatomic, strong) NSMutableDictionary<NSURLSessionTask *, NSMutableDictionary *> *downloadProgressSnapshots;

// Cache
@property (nonatomic, strong) NSMutableDictionary<NSString *, ModItem *> *metadataCache;
@property (nonatomic, strong) NSMutableDictionary<NSString *, NSDate *> *checkpointTimes;
@property (nonatomic, strong) dispatch_queue_t cacheQueue;
@end

@implementation ModService

// ---------- TOML parsing (unchanged) ----------
- (nullable id)parseTomlValue:(NSString *)valPart inLines:(NSArray<NSString *> *)lines atIndex:(NSUInteger *)i {
    NSString *trimmedVal = [valPart stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
    NSString *delimiter = nil;
    if ([trimmedVal hasPrefix:@"'''"]) delimiter = @"'''";
    else if ([trimmedVal hasPrefix:@"\"\"\""]) delimiter = @"\"\"\"";

    if (delimiter) {
        NSMutableString *multiLineContent = [[trimmedVal substringFromIndex:3] mutableCopy];
        if ([multiLineContent hasSuffix:delimiter]) {
            return [multiLineContent substringToIndex:multiLineContent.length - 3];
        } else {
            NSMutableArray<NSString *> *contentLines = [NSMutableArray array];
            [contentLines addObject:multiLineContent];
            (*i)++;
            while (*i < lines.count) {
                NSString *nextLine = lines[*i];
                NSRange endDelimiterRange = [nextLine rangeOfString:delimiter];
                if (endDelimiterRange.location != NSNotFound) {
                    [contentLines addObject:[nextLine substringToIndex:endDelimiterRange.location]];
                    break;
                } else {
                    [contentLines addObject:nextLine];
                }
                (*i)++;
            }
            return [contentLines componentsJoinedByString:@"\n"];
        }
    }

    if (([trimmedVal hasPrefix:@"\""] && [trimmedVal hasSuffix:@"\""]) ||
        ([trimmedVal hasPrefix:@"'"] && [trimmedVal hasSuffix:@"'"])) {
        if (trimmedVal.length > 1) {
            return [trimmedVal substringWithRange:NSMakeRange(1, trimmedVal.length - 2)];
        }
        return @"";
    }
    return trimmedVal;
}

- (NSDictionary<NSString *, id> *)parseTomlString:(NSString *)s {
    if (!s) return nil;
    NSMutableDictionary<NSString *, id> *root = [NSMutableDictionary dictionary];
    NSMutableDictionary *currentTable = root;
    NSString *currentTableName = nil;
    NSArray<NSString *> *lines = [s componentsSeparatedByCharactersInSet:[NSCharacterSet newlineCharacterSet]];
    for (NSUInteger i = 0; i < lines.count; i++) {
        NSString *line = lines[i];
        NSString *trimmed = [line stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
        if ([trimmed hasPrefix:@"#"] || trimmed.length == 0) continue;

        if ([trimmed hasPrefix:@"[["] && [trimmed hasSuffix:@"]]"]) {
            currentTableName = [trimmed substringWithRange:NSMakeRange(2, trimmed.length - 4)];
            NSMutableArray *array = root[currentTableName] ?: [NSMutableArray array];
            root[currentTableName] = array;
            currentTable = [NSMutableDictionary dictionary];
            [array addObject:currentTable];
            continue;
        } else if ([trimmed hasPrefix:@"["] && [trimmed hasSuffix:@"]"]) {
            currentTableName = [trimmed substringWithRange:NSMakeRange(1, trimmed.length - 2)];
            currentTable = [NSMutableDictionary dictionary];
            root[currentTableName] = currentTable;
            continue;
        }

        NSRange eqRange = [trimmed rangeOfString:@"="];
        if (eqRange.location != NSNotFound) {
            NSString *key = [[trimmed substringToIndex:eqRange.location] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
            NSString *valPart = [trimmed substringFromIndex:NSMaxRange(eqRange)];
            id value = [self parseTomlValue:valPart inLines:lines atIndex:&i];
            if (value) {
                currentTable[key] = value;
            }
        }
    }
    return root;
}

// ---------- Initialization ----------
+ (instancetype)sharedService {
    static ModService *s;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        s = [[ModService alloc] init];
    });
    return s;
}

- (instancetype)init {
    if (self = [super init]) {
        _onlineSearchEnabled = NO;
        
        // Fix: use defaultSessionConfiguration instead of backgroundSessionConfiguration
        // A background session throttles downloads, making a user-initiated mod download very slow
        // The default session has no bandwidth limit and suits foreground downloads
        NSURLSessionConfiguration *config = [NSURLSessionConfiguration defaultSessionConfiguration];
        config.timeoutIntervalForRequest = 120.0;
        config.timeoutIntervalForResource = 300.0;
        config.allowsCellularAccess = YES;
        // Following FCL/ZalithLauncher2: raise the concurrent connection count from 6 to 16,
        // matching MinecraftResourceDownloadTask, which noticeably improves throughput when downloading several mods
        // or fetching mod metadata concurrently. Download integrity is guaranteed by the JAR format check itself
        // (chunked downloading was deliberately not introduced, so the existing completion callback flow is not disturbed).
        config.HTTPMaximumConnectionsPerHost = 16;
        
        _downloadSession = [NSURLSession sessionWithConfiguration:config delegate:self delegateQueue:nil];
        _downloadCompletionHandlers = [NSMutableDictionary dictionary];
        _downloadDestinationPaths = [NSMutableDictionary dictionary];
        _downloadProgressHandlers = [NSMutableDictionary dictionary];
        _downloadTaskItems = [NSMutableDictionary dictionary];
        _downloadProgressSnapshots = [NSMutableDictionary dictionary];

        // Initialize the cache
        _metadataCache = [NSMutableDictionary dictionary];
        _checkpointTimes = [NSMutableDictionary dictionary];
        _cacheQueue = dispatch_queue_create("com.amethyst.modcache", DISPATCH_QUEUE_CONCURRENT);
    }
    return self;
}

// ---------- Helpers ----------
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
    NSString *folder = [cacheDir stringByAppendingPathComponent:@"mod_icons"];
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

- (nullable NSData *)readFileFromJar:(NSString *)jarPath entryName:(NSString *)entryName {
    if (!jarPath || !entryName) return nil;
    NSError *err = nil;
    UZKArchive *archive = [[UZKArchive alloc] initWithPath:jarPath error:&err];
    if (!archive || err) return nil;
    NSData *data = [archive extractDataFromFile:entryName error:&err];
    return data;
}

/// Resolve the profile gameDir into an absolute path.
/// A profile gameDir is usually relative (such as "./custom_gamedir/{name}") and has to be resolved against POJAV_GAME_DIR.
/// Using the relative path directly used to make the mods folder unfindable (fileExistsAtPath resolves a relative path against the cwd,
/// and the cwd is not necessarily POJAV_GAME_DIR).
- (nullable NSString *)resolveAbsoluteGameDirForProfile:(NSString *)profileName {
    NSString *profile = profileName.length ? profileName : @"default";
    @try {
        NSDictionary *profiles = PLProfiles.current.profiles;
        NSDictionary *prof = profiles[profile];
        if (![prof isKindOfClass:[NSDictionary class]]) return nil;
        NSString *gameDir = prof[@"gameDir"];
        if (![gameDir isKindOfClass:[NSString class]] || gameDir.length == 0) return nil;
        if ([gameDir isEqualToString:@"."]) {
            // "." means the main directory
            const char *env = getenv("POJAV_GAME_DIR");
            return env ? [NSString stringWithUTF8String:env] : NSHomeDirectory();
        }
        if ([gameDir isAbsolutePath]) {
            return gameDir;
        }
        // A relative path, resolved against POJAV_GAME_DIR
        const char *env = getenv("POJAV_GAME_DIR");
        NSString *baseDir = env ? [NSString stringWithUTF8String:env] : NSHomeDirectory();
        // Strip the leading "./" (if any); stringByAppendingPathComponent handles the rest correctly
        NSString *cleanGameDir = [gameDir hasPrefix:@"./"] ? [gameDir substringFromIndex:2] : gameDir;
        return [baseDir stringByAppendingPathComponent:cleanGameDir];
    } @catch (NSException *ex) {
        return nil;
    }
}

- (nullable NSString *)existingModsFolderForProfile:(NSString *)profileName {
    NSString *profile = profileName.length ? profileName : @"default";
    NSFileManager *fm = [NSFileManager defaultManager];

    // Prefer the profile gameDir (already resolved to an absolute path)
    NSString *resolvedGameDir = [self resolveAbsoluteGameDirForProfile:profile];
    if (resolvedGameDir.length > 0) {
        NSString *modsPath = [resolvedGameDir stringByAppendingPathComponent:@"mods"];
        BOOL isDir = NO;
        if ([fm fileExistsAtPath:modsPath isDirectory:&isDir] && isDir) {
            return modsPath;
        }
    }

    // Fall back to POJAV_GAME_DIR/mods
    const char *gameDirC = getenv("POJAV_GAME_DIR");
    if (gameDirC) {
        NSString *gameDir = [NSString stringWithUTF8String:gameDirC];
        NSString *modsPath = [gameDir stringByAppendingPathComponent:@"mods"];
        BOOL isDir = NO;
        if ([fm fileExistsAtPath:modsPath isDirectory:&isDir] && isDir) {
            return modsPath;
        }
    }
    return nil;
}

/// Return the mods folder of the current profile, creating it if it does not exist
- (nullable NSString *)ensureModsFolderForProfile:(NSString *)profileName error:(NSError **)error {
    NSString *profile = profileName.length ? profileName : @"default";
    NSFileManager *fm = [NSFileManager defaultManager];
    NSString *modsPath = nil;

    // Prefer the profile gameDir (already resolved to an absolute path)
    NSString *resolvedGameDir = [self resolveAbsoluteGameDirForProfile:profile];
    if (resolvedGameDir.length > 0) {
        modsPath = [resolvedGameDir stringByAppendingPathComponent:@"mods"];
    }

    if (!modsPath) {
        const char *gameDirC = getenv("POJAV_GAME_DIR");
        if (gameDirC) {
            NSString *gameDir = [NSString stringWithUTF8String:gameDirC];
            modsPath = [gameDir stringByAppendingPathComponent:@"mods"];
        }
    }

    if (!modsPath) {
        if (error) {
            *error = [NSError errorWithDomain:@"ModService" code:1 userInfo:@{NSLocalizedDescriptionKey: @"Could not determine the game directory"}];
        }
        return nil;
    }

    BOOL isDir = NO;
    if (![fm fileExistsAtPath:modsPath isDirectory:&isDir]) {
        // The directory does not exist, so create it
        NSError *createError = nil;
        [fm createDirectoryAtPath:modsPath withIntermediateDirectories:YES attributes:nil error:&createError];
        if (createError) {
            if (error) *error = createError;
            return nil;
        }
        NSLog(@"[ModService] Created mods directory: %@", modsPath);
    } else if (!isDir) {
        if (error) {
            *error = [NSError errorWithDomain:@"ModService" code:2 userInfo:@{NSLocalizedDescriptionKey: [NSString stringWithFormat:@"%@ is not a directory", modsPath]}];
        }
        return nil;
    }
    return modsPath;
}

// ---------- Cache methods ----------
- (BOOL)needsRescanForPath:(NSString *)path {
    __block BOOL needs = YES;
    dispatch_sync(self.cacheQueue, ^{
        NSDate *lastScan = self.checkpointTimes[path];
        if (lastScan) {
            NSDictionary *attrs = [[NSFileManager defaultManager] attributesOfItemAtPath:path error:nil];
            NSDate *modifyDate = attrs[NSFileModificationDate];
            if (modifyDate && [modifyDate isEqualToDate:lastScan]) {
                needs = NO;
            }
        }
    });
    return needs;
}

- (void)updateCheckpointForPath:(NSString *)path {
    dispatch_barrier_async(self.cacheQueue, ^{
        NSDictionary *attrs = [[NSFileManager defaultManager] attributesOfItemAtPath:path error:nil];
        NSDate *modifyDate = attrs[NSFileModificationDate];
        if (modifyDate) {
            self.checkpointTimes[path] = modifyDate;
        }
    });
}

- (nullable ModItem *)cachedModForPath:(NSString *)path {
    __block ModItem *item = nil;
    dispatch_sync(self.cacheQueue, ^{
        item = self.metadataCache[path];
    });
    return item;
}

- (void)cacheModItem:(ModItem *)item forPath:(NSString *)path {
    dispatch_barrier_async(self.cacheQueue, ^{
        self.metadataCache[path] = item;
    });
}

// ---------- Mod scanning (the core optimization) ----------
- (void)scanModsForProfile:(NSString *)profileName completion:(ModListHandler)completion {
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSString *modsFolder = [self existingModsFolderForProfile:profileName];
        NSMutableArray<ModItem *> *items = [NSMutableArray array];

        if (!modsFolder) {
            if (completion) {
                dispatch_async(dispatch_get_main_queue(), ^{ completion(items); });
            }
            return;
        }

        NSArray<NSString *> *contents = [[NSFileManager defaultManager] contentsOfDirectoryAtPath:modsFolder error:nil];
        dispatch_group_t group = dispatch_group_create();

        for (NSString *fileName in contents) {
            if ([fileName.lowercaseString hasSuffix:@".jar"] || [fileName.lowercaseString hasSuffix:@".jar.disabled"]) {
                NSString *fullPath = [modsFolder stringByAppendingPathComponent:fileName];

                // Check the cache
                if (![self needsRescanForPath:fullPath]) {
                    ModItem *cached = [self cachedModForPath:fullPath];
                    if (cached) {
                        [items addObject:cached];
                        continue;
                    }
                }

                ModItem *mod = [[ModItem alloc] initWithFilePath:fullPath];
                [items addObject:mod];

                dispatch_group_enter(group);
                [self fetchMetadataForMod:mod completion:^(ModItem *populatedMod, NSError *error) {
                    if (!error) {
                        [self cacheModItem:populatedMod forPath:fullPath];
                        [self updateCheckpointForPath:fullPath];
                    }
                    dispatch_group_leave(group);
                }];
            }
        }

        dispatch_group_notify(group, dispatch_get_main_queue(), ^{
            [items sortUsingComparator:^NSComparisonResult(ModItem *obj1, ModItem *obj2) {
                NSString *name1 = obj1.displayName ?: obj1.fileName;
                NSString *name2 = obj2.displayName ?: obj2.fileName;
                return [name1 localizedCaseInsensitiveCompare:name2];
            }];
            if (completion) completion(items);
        });
    });
}

// ---------- Metadata retrieval (the original logic, only called from above) ----------
- (void)fetchMetadataForMod:(ModItem *)mod completion:(ModMetadataHandler)completion {
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        @try {
            // Fabric
            NSData *fabricData = [self readFileFromJar:mod.filePath entryName:@"fabric.mod.json"];
            if (fabricData) {
                NSDictionary *json = [NSJSONSerialization JSONObjectWithData:fabricData options:0 error:nil];
                if ([json isKindOfClass:[NSDictionary class]]) {
                    mod.isFabric = YES;
                    mod.onlineID = json[@"id"];
                    mod.version = json[@"version"];
                    mod.displayName = json[@"name"];
                    mod.modDescription = json[@"description"];
                    mod.author = [json[@"authors"] componentsJoinedByString:@", "];

                    NSDictionary *deps = json[@"depends"];
                    if ([deps isKindOfClass:[NSDictionary class]] && [deps[@"minecraft"] isKindOfClass:[NSString class]]) {
                        mod.gameVersion = deps[@"minecraft"];
                    }

                    NSString *iconPath = json[@"icon"];
                    if ([iconPath isKindOfClass:[NSString class]]) {
                        NSData *iconData = [self readFileFromJar:mod.filePath entryName:iconPath];
                        if (iconData) mod.icon = [[UIImage alloc] initWithData:iconData];
                    }
                    if (completion) completion(mod, nil);
                    return;
                }
            }

            // Forge / NeoForge
            NSData *tomlData = [self readFileFromJar:mod.filePath entryName:@"META-INF/mods.toml"];
            if (tomlData) {
                mod.isForge = YES;
            } else {
                tomlData = [self readFileFromJar:mod.filePath entryName:@"META-INF/neoforge.mods.toml"];
                if (tomlData) mod.isNeoForge = YES;
            }

            if (tomlData) {
                NSString *tomlString = [[NSString alloc] initWithData:tomlData encoding:NSUTF8StringEncoding];
                NSDictionary<NSString *, id> *toml = [self parseTomlString:tomlString];
                NSArray *mods = toml[@"mods"];
                if ([mods isKindOfClass:[NSArray class]] && mods.count > 0) {
                    NSDictionary *modInfo = mods.firstObject;
                    if ([modInfo isKindOfClass:[NSDictionary class]]) {
                        mod.onlineID = modInfo[@"modId"];
                        mod.version = modInfo[@"version"];
                        mod.displayName = modInfo[@"displayName"];
                        mod.modDescription = modInfo[@"description"];
                        mod.author = modInfo[@"authors"];

                        NSArray *deps = nil;
                        for (NSString *key in toml) {
                            if ([key hasPrefix:@"dependencies"]) {
                                deps = toml[key];
                                break;
                            }
                        }
                        if ([deps isKindOfClass:[NSArray class]]) {
                            for (NSDictionary *depInfo in deps) {
                                if ([depInfo isKindOfClass:[NSDictionary class]] && [depInfo[@"modId"] isEqualToString:@"minecraft"]) {
                                    mod.gameVersion = depInfo[@"versionRange"];
                                    break;
                                }
                            }
                        }

                        NSString *logoFile = modInfo[@"logoFile"];
                        if (logoFile.length > 0) {
                            NSData *logoData = [self readFileFromJar:mod.filePath entryName:logoFile];
                            if (logoData) mod.icon = [[UIImage alloc] initWithData:logoData];
                        }
                        if (completion) completion(mod, nil);
                        return;
                    }
                }
            }
        } @catch (NSException *exception) {
            NSLog(@"[ModService] CRITICAL: Exception while parsing %@: %@", mod.fileName, exception);
        }
        if (completion) completion(mod, nil);
    });
}

// ---------- File operations (enable/disable, delete) ----------
- (BOOL)toggleEnableForMod:(ModItem *)mod error:(NSError **)error {
    NSFileManager *fileManager = [NSFileManager defaultManager];
    NSString *currentPath = mod.filePath;
    NSString *newPath;

    if (mod.disabled) {
        if ([currentPath.lowercaseString hasSuffix:@".jar.disabled"]) {
            newPath = [currentPath substringToIndex:currentPath.length - 9];
        } else {
            if (error) *error = [NSError errorWithDomain:@"ModServiceError" code:101 userInfo:@{NSLocalizedDescriptionKey:@"The file state is inconsistent, so it cannot be enabled."}];
            return NO;
        }
    } else {
        newPath = [currentPath stringByAppendingString:@".disabled"];
    }

    BOOL success = [fileManager moveItemAtPath:currentPath toPath:newPath error:error];
    if (success) {
        mod.filePath = newPath;
        mod.fileName = [newPath lastPathComponent];
        [mod refreshDisabledFlag];
    }
    return success;
}

- (BOOL)deleteMod:(ModItem *)mod error:(NSError **)error {
    return [[NSFileManager defaultManager] removeItemAtPath:mod.filePath error:error];
}

// ---------- Downloading (with the key fix applied: defaultSessionConfiguration) ----------
- (void)downloadMod:(ModItem *)mod toProfile:(NSString *)profileName completion:(ModDownloadHandler)completion {
    [self downloadMod:mod toProfile:profileName progress:nil completion:completion];
}

// ---------- Downloading with progress callbacks ----------
- (void)downloadMod:(ModItem *)mod
          toProfile:(NSString *)profileName
            progress:(void (^)(NSProgress *downloadProgress))progress
          completion:(ModDownloadHandler)completion {
    NSString *modsFolder = [self existingModsFolderForProfile:profileName];
    if (!modsFolder) {
        if (completion) {
            NSError *error = [NSError errorWithDomain:@"ModServiceError" code:1 userInfo:@{NSLocalizedDescriptionKey:@"Could not find the mods folder."}];
            dispatch_async(dispatch_get_main_queue(), ^{ completion(error); });
        }
        return;
    }

    NSURL *url = [NSURL URLWithString:mod.selectedVersionDownloadURL];
    if (!url) {
        if (completion) {
            NSError *error = [NSError errorWithDomain:@"ModServiceError" code:2 userInfo:@{NSLocalizedDescriptionKey:@"Invalid download link."}];
            dispatch_async(dispatch_get_main_queue(), ^{ completion(error); });
        }
        return;
    }

    NSString *destinationPath = [modsFolder stringByAppendingPathComponent:mod.fileName];
    NSURLSessionDownloadTask *task = [self.downloadSession downloadTaskWithURL:url];
    self.downloadCompletionHandlers[task] = completion;
    self.downloadDestinationPaths[task] = destinationPath;
    if (progress) {
        self.downloadProgressHandlers[task] = progress;
    }

    // Register with the shared download task manager (the floating button is gone, but registering keeps the task list accurate)
    NSString *resourceName = mod.fileName.length > 0 ? mod.fileName : (mod.displayName.length > 0 ? mod.displayName : @"mod");
    NSString *displayName = mod.displayName.length > 0 ? mod.displayName : resourceName;
    NSString *downloadSource = getPrefObject(@"general.download_source") ?: @"official";
    DownloadTaskItem *taskItem = [[DownloadTaskManager sharedManager]
        registerTaskWithResourceType:DownloadTaskResourceTypeMod
                        resourceName:resourceName
                         displayName:displayName
                      downloadSource:downloadSource
                             rawTask:task
                      supportsResume:YES
                             iconURL:mod.iconURL];
    taskItem.downloadURL = mod.selectedVersionDownloadURL;
    self.downloadTaskItems[task] = taskItem;
    [[DownloadTaskManager sharedManager] setTaskWithId:taskItem.taskId state:DownloadTaskStateDownloading];

    // Set retryHandler: an FCL-style re-download that reuses the same taskItem and rebuilds the underlying NSURLSessionTask
    __weak typeof(self) weakSelf = self;
    NSString *capturedDestPath = destinationPath;
    ModDownloadHandler capturedCompletion = completion;
    void (^capturedProgress)(NSProgress *) = progress;
    ModItem *capturedMod = mod;
    taskItem.retryHandler = ^id(DownloadTaskItem *taskItemRef) {
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf) return nil;
        NSURL *retryURL = [NSURL URLWithString:taskItemRef.downloadURL] ?: [NSURL URLWithString:capturedMod.selectedVersionDownloadURL];
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
}

#pragma mark - NSURLSessionDownloadDelegate

- (void)URLSession:(NSURLSession *)session downloadTask:(NSURLSessionDownloadTask *)downloadTask didFinishDownloadingToURL:(NSURL *)location {
    ModDownloadHandler handler = self.downloadCompletionHandlers[downloadTask];
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
        ModDownloadHandler handler = self.downloadCompletionHandlers[task];
        DownloadTaskItem *taskItem = self.downloadTaskItems[task];
        if (taskItem) {
            [[DownloadTaskManager sharedManager] updateTaskWithId:taskItem.taskId error:error];
            [[DownloadTaskManager sharedManager] setTaskWithId:taskItem.taskId state:DownloadTaskStateFailed];
            [self.downloadTaskItems removeObjectForKey:task];
            [self.downloadProgressSnapshots removeObjectForKey:task];
        }
        if (handler) {
            handler(error);
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
    // speed/eta are declared before the if (taskItem) block so the NSProgress built below can reference them
    // (fixing a compile error: they were previously declared inside the block and used outside it, giving "use of undeclared identifier")
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

    // Set throughput and estimatedTimeRemaining on the NSProgress passed to the progress callback,
    // so the caller (DownloadViewController) can show the speed and ETA on the FCL-style download progress card.
    // The NSProgress in the progress callback used to have only fractionCompleted, so the card always showed a speed and ETA of 0.
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