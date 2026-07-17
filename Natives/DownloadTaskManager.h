#import <Foundation/Foundation.h>
#import "DownloadTaskItem.h"

NS_ASSUME_NONNULL_BEGIN

extern NSString * const DownloadTaskManagerDidUpdateTaskNotification;
extern NSString * const DownloadTaskManagerAggregateStateDidChangeNotification;
extern NSString * const DownloadTaskManagerTaskCompletedNotification;
extern NSString * const DownloadTaskManagerTaskKey;

/**
 * 统一下载任务管理器（单例）。
 * 负责集中管理所有下载任务的生命周期、状态聚合与操作。
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
- (BOOL)hasActiveTasks;                       // 存在 downloading / pending
- (BOOL)hasTasksInStates:(NSArray<NSNumber *> *)states;

#pragma mark - Actions

- (void)pauseTaskWithId:(NSString *)taskId;
- (void)resumeTaskWithId:(NSString *)taskId;
- (void)cancelTaskWithId:(NSString *)taskId;

/// 重新下载（FCL 风格）。
/// 取消旧 rawTask、重置 item 状态（progress/speed/error）、retryCount++，
/// 然后调用 item.retryHandler 重建底层 rawTask。若未设置 retryHandler 或超过 maxRetryCount 则无效。
- (void)retryTaskWithId:(NSString *)taskId;

/// 切换下载源。completion 返回 shouldRecreate：YES 表示调用方需要取消旧任务并重新创建下载。
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

/// 标记任务完成或失败；error 为 nil 表示成功
- (void)setTaskWithId:(NSString *)taskId completedWithError:(nullable NSError *)error;

/// 更新任务错误信息（不修改状态）
- (void)updateTaskWithId:(NSString *)taskId error:(nullable NSError *)error;

@end

NS_ASSUME_NONNULL_END
