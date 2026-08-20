#import "DownloadTaskManager.h"
#import "utils.h"

NSString * const DownloadTaskManagerDidUpdateTaskNotification          = @"com.amethyst.DownloadTaskManager.DidUpdateTask";
NSString * const DownloadTaskManagerAggregateStateDidChangeNotification = @"com.amethyst.DownloadTaskManager.AggregateStateDidChange";
NSString * const DownloadTaskManagerTaskCompletedNotification           = @"com.amethyst.DownloadTaskManager.TaskCompleted";
NSString * const DownloadTaskManagerTaskKey                             = @"DownloadTaskManagerTaskKey";

@interface DownloadTaskManager ()
@property (nonatomic, strong) NSMutableDictionary<NSString *, DownloadTaskItem *> *tasks;
@property (nonatomic, strong) NSLock *lock;
@property (nonatomic, assign) DownloadTaskAggregateState lastAggregateState;
@end

@implementation DownloadTaskManager

+ (instancetype)sharedManager {
    static DownloadTaskManager *shared = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        shared = [[self alloc] init];
    });
    return shared;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _tasks = [NSMutableDictionary dictionary];
        _lock = [[NSLock alloc] init];
        _lastAggregateState = DownloadTaskAggregateStateNone;
    }
    return self;
}

#pragma mark - Registration / Query

- (DownloadTaskItem *)registerTaskWithResourceType:(NSString *)resourceType
                                      resourceName:(NSString *)resourceName
                                       displayName:(NSString *)displayName
                                    downloadSource:(NSString *)downloadSource
                                           rawTask:(id)rawTask
                                    supportsResume:(BOOL)supportsResume
                                           iconURL:(NSString *)iconURL {
    DownloadTaskItem *item = [[DownloadTaskItem alloc] initWithResourceType:resourceType
                                                               resourceName:resourceName
                                                                displayName:displayName
                                                             downloadSource:downloadSource
                                                                    rawTask:rawTask
                                                             supportsResume:supportsResume
                                                                    iconURL:iconURL];
    [self.lock lock];
    self.tasks[item.taskId] = item;
    [self.lock unlock];

    [self postUpdateForTask:item];
    [self checkAggregateStateChange];
    return item;
}

- (void)removeTaskWithId:(NSString *)taskId {
    if (!taskId) return;
    [self.lock lock];
    DownloadTaskItem *item = self.tasks[taskId];
    if (item) [self.tasks removeObjectForKey:taskId];
    [self.lock unlock];

    if (item) {
        [self postUpdateForTask:item];
        [self checkAggregateStateChange];
    }
}

- (DownloadTaskItem *)taskWithId:(NSString *)taskId {
    if (!taskId) return nil;
    [self.lock lock];
    DownloadTaskItem *item = self.tasks[taskId];
    [self.lock unlock];
    return item;
}

- (NSArray<DownloadTaskItem *> *)allTasks {
    [self.lock lock];
    NSArray *copy = [self.tasks.allValues copy];
    [self.lock unlock];
    return copy;
}

- (NSArray<DownloadTaskItem *> *)tasksWithState:(DownloadTaskState)state {
    return [self tasksWithStates:@[@(state)]];
}

- (NSArray<DownloadTaskItem *> *)tasksWithStates:(NSArray<NSNumber *> *)states {
    NSMutableArray *result = [NSMutableArray array];
    [self.lock lock];
    for (DownloadTaskItem *item in self.tasks.allValues) {
        if ([states containsObject:@(item.state)]) {
            [result addObject:item];
        }
    }
    [self.lock unlock];
    return [result copy];
}

- (NSInteger)countOfTasksWithState:(DownloadTaskState)state {
    [self.lock lock];
    NSInteger count = 0;
    for (DownloadTaskItem *item in self.tasks.allValues) {
        if (item.state == state) count++;
    }
    [self.lock unlock];
    return count;
}

#pragma mark - Aggregate State

- (DownloadTaskAggregateState)currentAggregateState {
    [self.lock lock];
    NSArray *values = [self.tasks.allValues copy];
    [self.lock unlock];

    if (values.count == 0) return DownloadTaskAggregateStateNone;

    BOOL hasActive = NO;
    BOOL hasPaused = NO;
    BOOL hasPending = NO;
    BOOL allCompleted = YES;
    BOOL hasFailed = NO;

    for (DownloadTaskItem *item in values) {
        switch (item.state) {
            case DownloadTaskStateDownloading:
                hasActive = YES;
                allCompleted = NO;
                break;
            case DownloadTaskStatePending:
                hasPending = YES;
                allCompleted = NO;
                break;
            case DownloadTaskStatePaused:
                hasPaused = YES;
                allCompleted = NO;
                break;
            case DownloadTaskStateFailed:
                hasFailed = YES;
                allCompleted = NO;
                break;
            case DownloadTaskStateCancelled:
                allCompleted = NO;
                break;
            case DownloadTaskStateCompleted:
                break;
        }
    }

    if (hasActive || hasPending) return DownloadTaskAggregateStateActive;
    if (hasPaused) return DownloadTaskAggregateStatePaused;
    if (allCompleted) return DownloadTaskAggregateStateCompleted;
    if (hasFailed) return DownloadTaskAggregateStateFailed;
    return DownloadTaskAggregateStateIdle;
}

- (BOOL)hasActiveTasks {
    return [self hasTasksInStates:@[@(DownloadTaskStateDownloading), @(DownloadTaskStatePending)]];
}

- (BOOL)hasTasksInStates:(NSArray<NSNumber *> *)states {
    [self.lock lock];
    BOOL found = NO;
    for (DownloadTaskItem *item in self.tasks.allValues) {
        if ([states containsObject:@(item.state)]) {
            found = YES;
            break;
        }
    }
    [self.lock unlock];
    return found;
}

#pragma mark - Actions

- (void)pauseTaskWithId:(NSString *)taskId {
    if (!taskId) return;
    [self.lock lock];
    DownloadTaskItem *item = self.tasks[taskId];
    [self.lock unlock];
    if (!item) return;

    id rawTask = item.rawTask;
    if ([rawTask respondsToSelector:@selector(suspend)]) {
        [rawTask suspend];
    }

    if (item.state == DownloadTaskStateDownloading || item.state == DownloadTaskStatePending) {
        item.state = DownloadTaskStatePaused;
        [self postUpdateForTask:item];
        [self checkAggregateStateChange];
    }
}

- (void)resumeTaskWithId:(NSString *)taskId {
    if (!taskId) return;
    [self.lock lock];
    DownloadTaskItem *item = self.tasks[taskId];
    [self.lock unlock];
    if (!item) return;

    id rawTask = item.rawTask;
    if ([rawTask respondsToSelector:@selector(resume)]) {
        [rawTask resume];
    }

    if (item.state == DownloadTaskStatePaused || item.state == DownloadTaskStatePending) {
        item.state = DownloadTaskStateDownloading;
        [self postUpdateForTask:item];
        [self checkAggregateStateChange];
    }
}

- (void)cancelTaskWithId:(NSString *)taskId {
    if (!taskId) return;
    [self.lock lock];
    DownloadTaskItem *item = self.tasks[taskId];
    [self.lock unlock];
    if (!item) return;

    id rawTask = item.rawTask;
    if ([rawTask isKindOfClass:[NSOperation class]]) {
        [(NSOperation *)rawTask cancel];
    } else if ([rawTask respondsToSelector:@selector(cancel)]) {
        [rawTask cancel];
    }

    if (item.state != DownloadTaskStateCompleted && item.state != DownloadTaskStateCancelled && item.state != DownloadTaskStateFailed) {
        item.state = DownloadTaskStateCancelled;
        [self postUpdateForTask:item];
        [self checkAggregateStateChange];
    }
}

- (void)retryTaskWithId:(NSString *)taskId {
    if (!taskId) return;
    [self.lock lock];
    DownloadTaskItem *item = self.tasks[taskId];
    [self.lock unlock];
    if (!item) return;

    // Without a retryHandler there is nothing to rebuild
    if (!item.retryHandler) {
        NSLog(@"[DownloadTaskManager] retryTaskWithId: task %@ has no retryHandler, cannot retry", taskId);
        return;
    }

    // Stop retrying once the maximum retry count is exceeded
    if (item.maxRetryCount > 0 && item.retryCount >= item.maxRetryCount) {
        NSLog(@"[DownloadTaskManager] retryTaskWithId: task %@ has reached max retry count %ld", taskId, (long)item.maxRetryCount);
        return;
    }

    // 1. Cancel the old rawTask (so a dangling task does not keep downloading/reporting progress)
    id oldRawTask = item.rawTask;
    if ([oldRawTask isKindOfClass:[NSOperation class]]) {
        [(NSOperation *)oldRawTask cancel];
    } else if ([oldRawTask respondsToSelector:@selector(cancel)]) {
        [oldRawTask cancel];
    }

    // 2. Reset the item state (keeping metadata such as taskId/displayName/iconURL/resourceType)
    item.rawTask = nil;
    item.state = DownloadTaskStatePending;
    item.progress = -1.0;
    item.totalSize = -1;
    item.downloadedSize = 0;
    item.speed = 0.0;
    item.estimatedTimeRemaining = 0.0;
    item.errorInfo = nil;
    item.retryCount += 1;

    [self postUpdateForTask:item];
    [self checkAggregateStateChange];

    // 3. Call the caller's retryHandler to rebuild the underlying rawTask
    //    The handler must create a new NSURLSessionTask, register it in its own dictionary, assign it to item.rawTask,
    //    and finally call setTaskWithId:state:Downloading to start it.
    @try {
        id newRawTask = item.retryHandler(item);
        if (newRawTask) {
            item.rawTask = newRawTask;
            [self postUpdateForTask:item];
        }
    } @catch (NSException *exception) {
        NSLog(@"[DownloadTaskManager] retryTaskWithId: retryHandler threw exception: %@", exception);
        item.state = DownloadTaskStateFailed;
        item.errorInfo = [NSError errorWithDomain:@"DownloadTaskManager" code:3
                                         userInfo:@{NSLocalizedDescriptionKey: [NSString stringWithFormat:@"Retry failed: %@", exception.reason ?: @"Unknown error"]}];
        [self postUpdateForTask:item];
        [self checkAggregateStateChange];
    }
}

- (void)switchDownloadSourceForTaskId:(NSString *)taskId
                             toSource:(NSString *)source
                           completion:(void (^)(BOOL shouldRecreate, BOOL supportsResume, NSError * _Nullable error))completion {
    if (!completion) return;
    if (!taskId || !source) {
        completion(YES, NO, [NSError errorWithDomain:@"DownloadTaskManager" code:1 userInfo:@{NSLocalizedDescriptionKey: @"Invalid parameter"}]);
        return;
    }

    [self.lock lock];
    DownloadTaskItem *item = self.tasks[taskId];
    if (item) {
        item.downloadSource = [source copy];
    }
    BOOL supportsResume = item.supportsResume;
    [self.lock unlock];

    if (!item) {
        completion(YES, NO, [NSError errorWithDomain:@"DownloadTaskManager" code:2 userInfo:@{NSLocalizedDescriptionKey: @"Task does not exist"}]);
        return;
    }

    [self postUpdateForTask:item];
    // In the current implementation a running task cannot change URL directly, so the caller has to recreate the download.
    // When supportsResume is YES the caller may try to resume; when it is NO the download must start over.
    completion(YES, supportsResume, nil);
}

#pragma mark - Progress / State Reporting

- (void)updateTaskWithId:(NSString *)taskId
                progress:(double)progress
              totalBytes:(int64_t)totalBytes
         downloadedBytes:(int64_t)downloadedBytes {
    if (!taskId) return;
    [self.lock lock];
    DownloadTaskItem *item = self.tasks[taskId];
    if (item) {
        item.progress = progress;
        if (totalBytes >= 0) item.totalSize = totalBytes;
        item.downloadedSize = downloadedBytes;
        if (item.state == DownloadTaskStatePending) {
            item.state = DownloadTaskStateDownloading;
        }
    }
    [self.lock unlock];

    if (item) {
        [self postUpdateForTask:item];
        [self checkAggregateStateChange];
    }
}

- (void)updateTaskWithId:(NSString *)taskId
                   speed:(double)speed
  estimatedTimeRemaining:(NSTimeInterval)estimatedTimeRemaining {
    if (!taskId) return;
    [self.lock lock];
    DownloadTaskItem *item = self.tasks[taskId];
    if (item) {
        item.speed = speed;
        item.estimatedTimeRemaining = estimatedTimeRemaining;
    }
    [self.lock unlock];

    if (item) [self postUpdateForTask:item];
}

- (void)setTaskWithId:(NSString *)taskId state:(DownloadTaskState)state {
    if (!taskId) return;
    [self.lock lock];
    DownloadTaskItem *item = self.tasks[taskId];
    if (item) item.state = state;
    [self.lock unlock];

    if (item) {
        [self postUpdateForTask:item];
        [self checkAggregateStateChange];
    }
}

- (void)setTaskWithId:(NSString *)taskId completedWithError:(NSError *)error {
    if (!taskId) return;
    [self.lock lock];
    DownloadTaskItem *item = self.tasks[taskId];
    if (item) {
        if (error) {
            item.state = DownloadTaskStateFailed;
            item.errorInfo = error;
        } else {
            item.state = DownloadTaskStateCompleted;
            item.progress = 1.0;
            item.errorInfo = nil;
        }
    }
    [self.lock unlock];

    if (item) {
        [self postUpdateForTask:item];
        [self postCompletionForTask:item];
        [self checkAggregateStateChange];
    }
}

- (void)updateTaskWithId:(NSString *)taskId error:(NSError *)error {
    if (!taskId) return;
    [self.lock lock];
    DownloadTaskItem *item = self.tasks[taskId];
    if (item) item.errorInfo = error ?: item.errorInfo;
    [self.lock unlock];

    if (item) [self postUpdateForTask:item];
}

#pragma mark - Notifications

- (void)postUpdateForTask:(DownloadTaskItem *)item {
    if (!item) return;
    dispatch_async(dispatch_get_main_queue(), ^{
        [[NSNotificationCenter defaultCenter] postNotificationName:DownloadTaskManagerDidUpdateTaskNotification
                                                            object:self
                                                          userInfo:@{DownloadTaskManagerTaskKey: item}];
    });
}

- (void)postCompletionForTask:(DownloadTaskItem *)item {
    if (!item) return;
    dispatch_async(dispatch_get_main_queue(), ^{
        [[NSNotificationCenter defaultCenter] postNotificationName:DownloadTaskManagerTaskCompletedNotification
                                                            object:self
                                                          userInfo:@{DownloadTaskManagerTaskKey: item}];
    });
}

- (void)checkAggregateStateChange {
    DownloadTaskAggregateState newState = [self currentAggregateState];
    if (newState != self.lastAggregateState) {
        self.lastAggregateState = newState;
        dispatch_async(dispatch_get_main_queue(), ^{
            [[NSNotificationCenter defaultCenter] postNotificationName:DownloadTaskManagerAggregateStateDidChangeNotification
                                                                object:self
                                                              userInfo:@{@"aggregateState": @(newState)}];
        });
    }
}

@end
