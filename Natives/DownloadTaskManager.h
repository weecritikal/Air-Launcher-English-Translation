#import <Foundation/Foundation.h>
#import "DownloadTaskItem.h"

NS_ASSUME_NONNULL_BEGIN

extern NSString * const DownloadTaskManagerDidUpdateTaskNotification;
extern NSString * const DownloadTaskManagerAggregateStateDidChangeNotification;
extern NSString * const DownloadTaskManagerTaskCompletedNotification;
extern NSString * const DownloadTaskManagerTaskKey;

/**
 * Unified download task manager (singleton).
 * Owns the lifecycle, aggregate state and operations of every download task.
 */
@interface DownloadTaskManager : NSObject

+ (instancetype)sharedManager;

#pragma mark - Registration / Query

- (DownloadTaskItem *)registerTaskWithResourceType:(NSString *)resourceType
                                      resourceName:(NSString *)resourceName
                                       displayName:(NSString *)displayName
                                    downloadSource:(NSString *)downloadSource
                                           rawTask:(nullable id)rawTask
                                    supportsResume:(BOOL)supportsResume
                                           iconURL:(nullable NSString *)iconURL;

- (void)removeTaskWithId:(NSString *)taskId;
- (nullable DownloadTaskItem *)taskWithId:(NSString *)taskId;
- (NSArray<DownloadTaskItem *> *)allTasks;
- (NSArray<DownloadTaskItem *> *)tasksWithState:(DownloadTaskState)state;
- (NSArray<DownloadTaskItem *> *)tasksWithStates:(NSArray<NSNumber *> *)states;
- (NSInteger)countOfTasksWithState:(DownloadTaskState)state;

#pragma mark - Aggregate State

- (DownloadTaskAggregateState)currentAggregateState;
- (BOOL)hasActiveTasks;                       // Whether any task is downloading / pending
- (BOOL)hasTasksInStates:(NSArray<NSNumber *> *)states;

#pragma mark - Actions

- (void)pauseTaskWithId:(NSString *)taskId;
- (void)resumeTaskWithId:(NSString *)taskId;
- (void)cancelTaskWithId:(NSString *)taskId;

/// Re-download (FCL style).
/// Cancels the old rawTask, resets the item state (progress/speed/error), increments retryCount,
/// then calls item.retryHandler to rebuild the underlying rawTask. Does nothing if retryHandler is unset or maxRetryCount has been exceeded.
- (void)retryTaskWithId:(NSString *)taskId;

/// Switch the download source. completion returns shouldRecreate: YES means the caller must cancel the old task and start the download again.
- (void)switchDownloadSourceForTaskId:(NSString *)taskId
                             toSource:(NSString *)source
                           completion:(void (^)(BOOL shouldRecreate,
                                                BOOL supportsResume,
                                                NSError * _Nullable error))completion;

#pragma mark - Progress / State Reporting

- (void)updateTaskWithId:(NSString *)taskId
                progress:(double)progress
              totalBytes:(int64_t)totalBytes
         downloadedBytes:(int64_t)downloadedBytes;

- (void)updateTaskWithId:(NSString *)taskId
                   speed:(double)speed
  estimatedTimeRemaining:(NSTimeInterval)estimatedTimeRemaining;

- (void)setTaskWithId:(NSString *)taskId state:(DownloadTaskState)state;

/// Mark a task complete or failed; a nil error means success
- (void)setTaskWithId:(NSString *)taskId completedWithError:(nullable NSError *)error;

/// Update a task's error information (without changing its state)
- (void)updateTaskWithId:(NSString *)taskId error:(nullable NSError *)error;

@end

NS_ASSUME_NONNULL_END
