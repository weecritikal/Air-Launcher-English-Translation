#import "ModUpdateService.h"
#import "installer/modpack/ModrinthAPI.h"
#import "installer/modpack/CurseForgeAPI.h"

#pragma mark - ModUpdateResult implementation

@implementation ModUpdateResult

- (instancetype)init {
    self = [super init];
    if (self) {
        _candidateVersions = @[];
        _allVersions = @[];
        _projectType = @"mod";
    }
    return self;
}

/// Whether an update is available: a non-empty candidate version list counts as an update
- (BOOL)hasUpdate {
    return self.candidateVersions.count > 0;
}

@end

#pragma mark - ModUpdateService implementation

@interface ModUpdateService ()
/// The serial queue used for concurrent lookups (only to isolate the dispatch of the two-source tasks)
@property (nonatomic, strong) dispatch_queue_t lookupQueue;
@end

@implementation ModUpdateService

+ (instancetype)sharedService {
    static ModUpdateService *sharedInstance = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        sharedInstance = [[self alloc] init];
    });
    return sharedInstance;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        // The lookup tasks are dispatched on the global concurrent queue; this is kept only as an identifier
        _lookupQueue = dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0);
    }
    return self;
}

#pragma mark - Single mod update check (racing both sources)

- (void)checkUpdateForMod:(ModItem *)mod
              gameVersion:(NSString *)gameVersion
                   loader:(nullable NSString *)loader
              projectType:(NSString *)projectType
               completion:(void (^)(ModUpdateResult *_Nullable result))completion {
    // Parameter check: a local file path is required
    if (!mod || mod.filePath.length == 0) {
        [self callCompletionOnMain:nil completion:completion];
        return;
    }

    // Shared state used to coordinate the race between the two sources
    NSObject *lock = [[NSObject alloc] init];
    __block BOOL resolved = NO;            // Whether a decision has been made (a hit, or both sources failing)
    __block BOOL modrinthDone = NO;        // Whether the Modrinth lookup has finished
    __block BOOL curseforgeDone = NO;      // Whether the CurseForge lookup has finished
    __block NSMutableDictionary *winnerResult = nil;  // The project dictionary returned by the winning source
    __block NSNumber *winnerSource = nil;              // The winning source (1=Modrinth, 2=CurseForge)

    // The core race logic: the first non-empty result wins; if the first to return is empty, wait for the other source
    void (^tryResolve)(NSMutableDictionary *_Nullable, NSNumber *) = ^(NSMutableDictionary *_Nullable result, NSNumber *source) {
        @synchronized(lock) {
            // Once a decision is made, discard any result that arrives later (a soft cancel)
            if (resolved) return;

            if (result && result.count > 0) {
                // A hit: take this source's result
                resolved = YES;
                winnerResult = result;
                winnerSource = source;
            } else {
                // This source found nothing, so check whether both sources have finished
                if (modrinthDone && curseforgeDone) {
                    // Neither source found anything, so the whole lookup failed
                    resolved = YES;
                }
            }
        }

        // Decide whether to continue outside the lock (so callbacks do not run while holding it)
        BOOL shouldFetch = NO;
        BOOL shouldFail = NO;
        @synchronized(lock) {
            if (winnerResult && [winnerSource isEqual:source]) {
                shouldFetch = YES;
                // Read it once and clear it, to avoid firing twice
                winnerSource = nil;
            } else if (resolved && !winnerResult) {
                shouldFail = YES;
            }
        }

        if (shouldFetch) {
            // After a hit, fetch the full version list of that project
            [self fetchVersionsAndBuildResultWithProjectDict:result
                                                       source:source
                                                          mod:mod
                                                  gameVersion:gameVersion
                                                       loader:loader
                                                  projectType:projectType
                                                   completion:completion];
        } else if (shouldFail) {
            // Neither source found anything, so call back with nil on the main thread
            [self callCompletionOnMain:nil completion:completion];
        }
    };

    // Modrinth lookup: uses mod.fileSHA1 (a synchronous method, so it runs on a background queue)
    dispatch_async(self.lookupQueue, ^{
        @autoreleasepool {
            NSMutableDictionary *r = nil;
            // Modrinth needs fileSHA1
            if (mod.fileSHA1.length > 0) {
                @try {
                    r = [[ModrinthAPI sharedInstance] projectForFileHash:mod.fileSHA1 projectType:projectType];
                } @catch (NSException *exception) {
                    r = nil;
                }
            }
            @synchronized(lock) {
                modrinthDone = YES;
            }
            tryResolve(r, @(1));
        }
    });

    // CurseForge lookup: uses mod.filePath (which uses MurmurHash2 internally; a synchronous method)
    dispatch_async(self.lookupQueue, ^{
        @autoreleasepool {
            NSMutableDictionary *r = nil;
            if (mod.filePath.length > 0) {
                @try {
                    r = [[CurseForgeAPI sharedInstance] projectForFileHash:mod.filePath projectType:projectType];
                } @catch (NSException *exception) {
                    r = nil;
                }
            }
            @synchronized(lock) {
                curseforgeDone = YES;
            }
            tryResolve(r, @(2));
        }
    });
}

#pragma mark - Fetching the version list and building the result

- (void)fetchVersionsAndBuildResultWithProjectDict:(NSMutableDictionary *)projectDict
                                            source:(NSNumber *)source
                                               mod:(ModItem *)mod
                                       gameVersion:(NSString *)gameVersion
                                            loader:(nullable NSString *)loader
                                       projectType:(NSString *)projectType
                                        completion:(void (^)(ModUpdateResult *_Nullable))completion {
    // Extract the project ID from the dictionary the lookup returned
    NSString *projectID = [self extractProjectIDFromDict:projectDict source:source];
    if (projectID.length == 0) {
        [self callCompletionOnMain:nil completion:completion];
        return;
    }

    // Pick the API instance for that source and fetch the version list
    id api = ([source intValue] == 1) ? [ModrinthAPI sharedInstance] : [CurseForgeAPI sharedInstance];
    if (![api respondsToSelector:@selector(getVersionsForModWithID:completion:)]) {
        [self callCompletionOnMain:nil completion:completion];
        return;
    }

    [api getVersionsForModWithID:projectID completion:^(NSArray<ModVersion *> *_Nullable versions, NSError *_Nullable error) {
        // Note: the existing API implementation calls this block on the main thread
        if (error || !versions || versions.count == 0) {
            [self callCompletionOnMain:nil completion:completion];
            return;
        }

        ModUpdateResult *result = [self buildResultWithMod:mod
                                                 projectID:projectID
                                                 apiSource:source
                                               projectType:projectType
                                                  versions:versions
                                              gameVersion:gameVersion
                                                   loader:loader
                                              projectDict:projectDict];
        [self callCompletionOnMain:result completion:completion];
    }];
}

#pragma mark - Version filtering and result construction

- (ModUpdateResult *)buildResultWithMod:(ModItem *)mod
                              projectID:(NSString *)projectID
                              apiSource:(NSNumber *)apiSource
                            projectType:(NSString *)projectType
                               versions:(NSArray<ModVersion *> *)versions
                           gameVersion:(NSString *)gameVersion
                                loader:(nullable NSString *)loader
                           projectDict:(NSDictionary *)projectDict {
    // 1. Identify the current version (the one the lookup matched)
    ModVersion *currentVersion = [self findCurrentVersionIn:versions
                                                        mod:mod
                                              projectDict:projectDict
                                                   apiSource:apiSource];

    // 2. Sort every version by datePublished descending (newest first)
    NSArray<ModVersion *> *sortedAll = [versions sortedArrayUsingComparator:^NSComparisonResult(ModVersion *_Nonnull v1, ModVersion *_Nonnull v2) {
        NSDate *d1 = [self parseISO8601:v1.datePublished];
        NSDate *d2 = [self parseISO8601:v2.datePublished];
        if (!d1 && !d2) return NSOrderedSame;
        if (!d1) return NSOrderedAscending;
        if (!d2) return NSOrderedDescending;
        return [d2 compare:d1]; // Descending
    }];

    // 3. Work out the publication date of the current version (for the strictly-greater comparison)
    NSDate *currentDate = [self parseISO8601:currentVersion.datePublished];
    if (!currentDate && currentVersion.datePublished.length > 0) {
        currentDate = [self parseISO8601:currentVersion.datePublished];
    }

    // 4. Decide the loader filtering strategy (with smart fallback)
    NSArray<NSString *> *effectiveLoaders = [self effectiveLoadersForMod:mod inputLoader:loader];

    // 5. Select the update candidates: datePublished strictly greater than the current version + a game version filter + a loader filter
    NSMutableArray<ModVersion *> *candidates = [NSMutableArray array];
    for (ModVersion *v in sortedAll) {
        // 5.1 The publication date must be parseable
        NSDate *vDate = [self parseISO8601:v.datePublished];
        if (!vDate) continue;

        // 5.2 It must be strictly later than the current version date (this filter is skipped when the current date is unknown)
        if (currentDate && [vDate compare:currentDate] != NSOrderedDescending) {
            continue;
        }

        // 5.3 Game version filter (must be included when a gameVersion was passed in)
        if (gameVersion.length > 0 && ![v.gameVersions containsObject:gameVersion]) {
            continue;
        }

        // 5.4 Loader filter (a smart fallback strategy; no filtering when effectiveLoaders is empty)
        if (effectiveLoaders.count > 0) {
            BOOL loaderMatch = NO;
            for (NSString *l in effectiveLoaders) {
                if ([v.loaders containsObject:l]) {
                    loaderMatch = YES;
                    break;
                }
            }
            if (!loaderMatch) continue;
        }

        [candidates addObject:v];
    }

    // 6. Build the result object
    ModUpdateResult *result = [[ModUpdateResult alloc] init];
    result.localFilePath = mod.filePath;
    result.currentVersion = currentVersion;
    result.candidateVersions = [candidates copy]; // Already in descending order
    result.allVersions = sortedAll;
    result.projectID = projectID;
    result.apiSource = apiSource;
    result.projectType = projectType;
    return result;
}

#pragma mark - Current version detection

/// Identify the current version in the full version list (the one the lookup matched)
/// Priority: fileId (CurseForge) > fileSHA1 (the Modrinth primaryFile) > versionNumber > the newest version as a fallback
- (ModVersion *)findCurrentVersionIn:(NSArray<ModVersion *> *)versions
                                 mod:(ModItem *)mod
                        projectDict:(NSDictionary *)projectDict
                            apiSource:(NSNumber *)apiSource {
    if (versions.count == 0) return nil;

    // Strategy 1: CurseForge matches by fileId (the lookup dictionary contains fileId)
    if ([apiSource intValue] == 2) {
        NSString *curFileId = [projectDict[@"fileId"] isKindOfClass:[NSString class]] ? projectDict[@"fileId"] : nil;
        if (curFileId.length > 0) {
            for (ModVersion *v in versions) {
                if ([v.fileId isEqualToString:curFileId]) {
                    return v;
                }
            }
        }
    }

    // Strategy 2: Modrinth matches fileSHA1 against the hashes.sha1 of primaryFile
    if (mod.fileSHA1.length > 0) {
        for (ModVersion *v in versions) {
            NSDictionary *primaryFile = v.primaryFile;
            if (![primaryFile isKindOfClass:[NSDictionary class]]) continue;
            // The Modrinth shape: hashes[@"sha1"]
            id hashesVal = primaryFile[@"hashes"];
            if ([hashesVal isKindOfClass:[NSDictionary class]]) {
                NSString *sha1 = [hashesVal[@"sha1"] isKindOfClass:[NSString class]] ? hashesVal[@"sha1"] : nil;
                if (sha1 && [sha1 isEqualToString:mod.fileSHA1]) {
                    return v;
                }
            }
            // Fallback: the URL contains the sha1 (Modrinth file URLs usually use the sha1 as the file name)
            NSString *url = [primaryFile[@"url"] isKindOfClass:[NSString class]] ? primaryFile[@"url"] : nil;
            if (url && [url containsString:mod.fileSHA1]) {
                return v;
            }
        }
    }

    // Strategy 3: match by version number (comparing mod.version with versionNumber)
    if (mod.version.length > 0) {
        for (ModVersion *v in versions) {
            if ([v.versionNumber isEqualToString:mod.version]) {
                return v;
            }
        }
    }

    // Strategy 4: CurseForge matches fileId against ModVersion.fileId (mods have no fileId field, so this is skipped)

    // Strategy 5: fallback, returning the only version when there is just one
    if (versions.count == 1) {
        return versions.firstObject;
    }

    // Strategy 6: fallback, returning the first entry after the descending sort (the newest version)
    NSArray<ModVersion *> *sorted = [versions sortedArrayUsingComparator:^NSComparisonResult(ModVersion *_Nonnull v1, ModVersion *_Nonnull v2) {
        NSDate *d1 = [self parseISO8601:v1.datePublished];
        NSDate *d2 = [self parseISO8601:v2.datePublished];
        if (!d1 && !d2) return NSOrderedSame;
        if (!d1) return NSOrderedAscending;
        if (!d2) return NSOrderedDescending;
        return [d2 compare:d1];
    }];
    return sorted.firstObject;
}

#pragma mark - Smart loader fallback

/// Work out the loader set used to filter versions
/// Strategy:
///   - if the loaders the mod declares (isFabric/isForge/isNeoForge) include the loader passed in, filter by the one passed in
///   - if they disagree (as with cross-loader builds), filter by the loader set the file itself declares
///   - if the mod declares no loader and loader is nil, return an empty array (no filtering)
- (NSArray<NSString *> *)effectiveLoadersForMod:(ModItem *)mod inputLoader:(nullable NSString *)loader {
    // Collect the loaders the mod declares
    NSMutableArray<NSString *> *declared = [NSMutableArray array];
    if (mod.isFabric) [declared addObject:@"fabric"];
    if (mod.isForge) [declared addObject:@"forge"];
    if (mod.isNeoForge) [declared addObject:@"neoforge"];

    // Check whether the loader passed in agrees with what the mod declares
    if (loader.length > 0) {
        NSString *lowerLoader = [loader lowercaseString];
        for (NSString *l in declared) {
            if ([l isEqualToString:lowerLoader]) {
                // They agree: filter by the loader passed in
                return @[lowerLoader];
            }
        }
        // They disagree: if the mod declares no loader at all, trust the one passed in
        if (declared.count == 0) {
            return @[lowerLoader];
        }
        // Otherwise fall through to the fallback branch (using the loader set the mod declares)
    }

    // They disagree, or loader is empty: use the loader set the file itself declares
    if (declared.count > 0) {
        return [declared copy];
    }

    // Neither is available: return an empty array, meaning no loader filtering
    return @[];
}

#pragma mark - Utility methods

/// Extract the project ID from the project dictionary the lookup returned
- (nullable NSString *)extractProjectIDFromDict:(NSDictionary *)dict source:(NSNumber *)source {
    if (!dict || dict.count == 0) return nil;

    if ([source intValue] == 1) {
        // Modrinth: the id field of the dictionary returned by projectForFileHash is the project_id
        id v = dict[@"id"];
        if ([v isKindOfClass:[NSString class]]) return v;
        if ([v isKindOfClass:[NSNumber class]]) return [v stringValue];
        // Fall back to trying the project_id key
        id pid = dict[@"project_id"];
        if ([pid isKindOfClass:[NSString class]]) return pid;
        if ([pid isKindOfClass:[NSNumber class]]) return [pid stringValue];
        return nil;
    } else {
        // CurseForge: the id field of the dictionary returned by projectForFileHash is the modId
        id v = dict[@"id"];
        if ([v isKindOfClass:[NSString class]]) return v;
        if ([v isKindOfClass:[NSNumber class]]) return [v stringValue];
        // Fall back to trying the modId key
        id mid = dict[@"modId"];
        if ([mid isKindOfClass:[NSString class]]) return mid;
        if ([mid isKindOfClass:[NSNumber class]]) return [mid stringValue];
        return nil;
    }
}

/// Parse an ISO8601 date string into an NSDate (handling both the with-milliseconds and without-milliseconds forms)
- (nullable NSDate *)parseISO8601:(NSString *)dateString {
    if (![dateString isKindOfClass:[NSString class]] || dateString.length == 0) return nil;
    NSISO8601DateFormatter *formatter = [[NSISO8601DateFormatter alloc] init];
    // Try the form with milliseconds first (the usual CurseForge fileDate format)
    formatter.formatOptions = NSISO8601DateFormatWithInternetDateTime | NSISO8601DateFormatWithFractionalSeconds;
    NSDate *date = [formatter dateFromString:dateString];
    if (!date) {
        // Fall back to the form without milliseconds
        formatter.formatOptions = NSISO8601DateFormatWithInternetDateTime;
        date = [formatter dateFromString:dateString];
    }
    return date;
}

/// Call completion on the main thread
- (void)callCompletionOnMain:(ModUpdateResult *_Nullable)result
                  completion:(void (^)(ModUpdateResult *_Nullable))completion {
    if (!completion) return;
    if ([NSThread isMainThread]) {
        completion(result);
    } else {
        dispatch_async(dispatch_get_main_queue(), ^{
            completion(result);
        });
    }
}

#pragma mark - Bulk update check (concurrency limited to 3)

- (void)checkUpdatesForMods:(NSArray<ModItem *> *)mods
               gameVersion:(NSString *)gameVersion
                    loader:(nullable NSString *)loader
               projectType:(NSString *)projectType
                  progress:(void (^)(NSInteger completed, NSInteger total))progress
                completion:(void (^)(NSArray<ModUpdateResult *> *results))completion {
    NSInteger total = mods.count;

    // Call back immediately for an empty array
    if (total == 0) {
        [self callProgressOnMain:0 total:0 progress:progress];
        [self callBatchCompletionOnMain:@[] completion:completion];
        return;
    }

    // Concurrency-limiting semaphore (at most 3 at a time)
    dispatch_semaphore_t semaphore = dispatch_semaphore_create(3);
    dispatch_queue_t workQueue = dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0);

    // Lock used to collect the results
    NSObject *lock = [[NSObject alloc] init];
    __block NSMutableArray<ModUpdateResult *> *results = [NSMutableArray array];
    __block NSInteger completed = 0;

    for (ModItem *mod in mods) {
        dispatch_async(workQueue, ^{
            // Wait on the semaphore (throttling)
            dispatch_semaphore_wait(semaphore, DISPATCH_TIME_FOREVER);

            // Run the update check for one mod
            [self checkUpdateForMod:mod
                        gameVersion:gameVersion
                             loader:loader
                        projectType:projectType
                         completion:^(ModUpdateResult *_Nullable result) {
                // This callback runs on the main thread
                @synchronized(lock) {
                    if (result && [result hasUpdate]) {
                        [results addObject:result];
                    }
                    completed++;
                    NSInteger c = completed;
                    NSArray<ModUpdateResult *> *snapshot = [results copy];

                    // Progress callback
                    [self callProgressOnMain:c total:total progress:progress];

                    // Deliver the final result once everything finishes
                    if (c >= total) {
                        [self callBatchCompletionOnMain:snapshot completion:completion];
                    }
                }
                // Release the semaphore so the next task can start
                dispatch_semaphore_signal(semaphore);
            }];
        });
    }
}

/// Report progress on the main thread
- (void)callProgressOnMain:(NSInteger)completed
                     total:(NSInteger)total
                  progress:(void (^)(NSInteger completed, NSInteger total))progress {
    if (!progress) return;
    if ([NSThread isMainThread]) {
        progress(completed, total);
    } else {
        dispatch_async(dispatch_get_main_queue(), ^{
            progress(completed, total);
        });
    }
}

/// Report batch completion on the main thread
- (void)callBatchCompletionOnMain:(NSArray<ModUpdateResult *> *)results
                       completion:(void (^)(NSArray<ModUpdateResult *> *results))completion {
    if (!completion) return;
    if ([NSThread isMainThread]) {
        completion(results);
    } else {
        dispatch_async(dispatch_get_main_queue(), ^{
            completion(results);
        });
    }
}

@end
