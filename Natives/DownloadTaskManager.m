//
//  DownloadTaskManager.m
//  Amethyst
//

#import "DownloadTaskManager.h"
#import "DownloadTaskItem.h"

NSString * const DownloadTaskManagerAggregateStateDidChangeNotification = @"DownloadTaskManagerAggregateStateDidChangeNotification";

@interface DownloadTaskManager ()

@property (nonatomic, strong) NSMutableDictionary<NSString *, DownloadTaskItem *> *tasks;
@property (nonatomic, strong) dispatch_queue_t lockQueue;
@property (nonatomic, assign) BOOL lastHasActive;

@end

@implementation DownloadTaskManager

+ (instancetype)sharedManager {
    static DownloadTaskManager *sharedInstance = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        sharedInstance = [[self alloc] init];
    });
    return sharedInstance;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _tasks = [NSMutableDictionary dictionary];
        _lockQueue = dispatch_queue_create("com.angelaura.downloadtaskmanager", DISPATCH_QUEUE_SERIAL);
        _lastHasActive = NO;
    }
    return self;
}

- (DownloadTaskItem *)registerTaskWithResourceType:(DownloadTaskResourceType)resourceType
                                      resourceName:(NSString *)resourceName
                                       displayName:(NSString *)displayName
                                    downloadSource:(NSString *)downloadSource
                                           rawTask:(id)rawTask
                                    supportsResume:(BOOL)supportsResume
                                           iconURL:(NSString *)iconURL {
    DownloadTaskItem *item = [[DownloadTaskItem alloc] init];
    item.resourceType = resourceType;
    item.resourceName = resourceName;
    item.displayName = displayName;
    item.downloadSource = downloadSource;
    item.rawTask = rawTask;
    item.supportsResume = supportsResume;
    item.iconURL = iconURL;
    item.state = DownloadTaskStatePending;
    item.progress = -1.0;

    __block DownloadTaskItem *result = item;
    dispatch_sync(self.lockQueue, ^{
        self.tasks[item.taskId] = item;
    });

    [self checkAndNotifyAggregateStateChanged];
    return result;
}

- (void)setTaskWithId:(NSString *)taskId state:(DownloadTaskState)state {
    if (!taskId) return;

    __block BOOL changed = NO;
    dispatch_sync(self.lockQueue, ^{
        DownloadTaskItem *item = self.tasks[taskId];
        if (!item) return;
        // 幂等：已终结态不再变更
        if (item.state == DownloadTaskStateCompleted ||
            item.state == DownloadTaskStateFailed ||
            item.state == DownloadTaskStateCancelled) {
            return;
        }
        if (item.state != state) {
            item.state = state;
            changed = YES;
        }
    });

    if (changed) {
        [self checkAndNotifyAggregateStateChanged];
    }
}

- (void)setTaskWithId:(NSString *)taskId completedWithError:(NSError *)error {
    if (!taskId) return;

    __block BOOL changed = NO;
    dispatch_sync(self.lockQueue, ^{
        DownloadTaskItem *item = self.tasks[taskId];
        if (!item) return;
        // 幂等：已终结态不再变更
        if (item.state == DownloadTaskStateCompleted ||
            item.state == DownloadTaskStateFailed ||
            item.state == DownloadTaskStateCancelled) {
            return;
        }
        if (error) {
            item.state = DownloadTaskStateFailed;
            item.errorInfo = error;
        } else {
            item.state = DownloadTaskStateCompleted;
            item.progress = 1.0;
            item.errorInfo = nil;
        }
        changed = YES;
    });

    if (changed) {
        [self checkAndNotifyAggregateStateChanged];
    }
}

- (void)updateTaskWithId:(NSString *)taskId
                progress:(double)progress
              totalBytes:(int64_t)totalBytes
         downloadedBytes:(int64_t)downloadedBytes {
    if (!taskId) return;

    dispatch_sync(self.lockQueue, ^{
        DownloadTaskItem *item = self.tasks[taskId];
        if (!item) return;
        item.progress = progress;
        item.totalBytes = totalBytes;
        item.downloadedBytes = downloadedBytes;
    });
}

- (void)updateTaskWithId:(NSString *)taskId
                   speed:(double)speed
estimatedTimeRemaining:(NSTimeInterval)estimatedTimeRemaining {
    if (!taskId) return;

    dispatch_sync(self.lockQueue, ^{
        DownloadTaskItem *item = self.tasks[taskId];
        if (!item) return;
        item.speed = speed;
        item.estimatedTimeRemaining = estimatedTimeRemaining;
    });
}

- (BOOL)hasActiveTasks {
    __block BOOL hasActive = NO;
    dispatch_sync(self.lockQueue, ^{
        for (DownloadTaskItem *item in self.tasks.allValues) {
            if (item.isActive) {
                hasActive = YES;
                break;
            }
        }
    });
    return hasActive;
}

- (NSArray<DownloadTaskItem *> *)allTasks {
    __block NSArray<DownloadTaskItem *> *result = nil;
    dispatch_sync(self.lockQueue, ^{
        result = [self.tasks.allValues sortedArrayUsingComparator:^NSComparisonResult(DownloadTaskItem *a, DownloadTaskItem *b) {
            return [b.createdAt compare:a.createdAt];
        }];
    });
    return result ?: @[];
}

- (DownloadTaskItem *)taskWithId:(NSString *)taskId {
    if (!taskId) return nil;
    __block DownloadTaskItem *result = nil;
    dispatch_sync(self.lockQueue, ^{
        result = self.tasks[taskId];
    });
    return result;
}

#pragma mark - Private

- (void)checkAndNotifyAggregateStateChanged {
    BOOL currentHasActive = [self hasActiveTasks];
    // 仅在 0->N 或 N->0 边界变化时发送通知，避免高频通知
    if (currentHasActive != self.lastHasActive) {
        self.lastHasActive = currentHasActive;
        dispatch_async(dispatch_get_main_queue(), ^{
            [[NSNotificationCenter defaultCenter] postNotificationName:DownloadTaskManagerAggregateStateDidChangeNotification
                                                                object:self
                                                              userInfo:nil];
        });
    }
}

@end
