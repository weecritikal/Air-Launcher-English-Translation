//
//  DownloadTaskManager.h
//  Amethyst
//
//  统一下载任务管理器：跟踪所有下载任务的状态，并通过通知对外发布聚合状态变化
//

#import <Foundation/Foundation.h>

@class DownloadTaskItem;

NS_ASSUME_NONNULL_BEGIN

/// 聚合状态变更通知（活跃任务数从 0->N 或 N->0 时发送）
extern NSString * const DownloadTaskManagerAggregateStateDidChangeNotification;

@interface DownloadTaskManager : NSObject

+ (instancetype)sharedManager;

/// 注册新任务并返回任务项
- (DownloadTaskItem *)registerTaskWithResourceType:(DownloadTaskResourceType)resourceType
                                      resourceName:(NSString *)resourceName
                                       displayName:(NSString *)displayName
                                    downloadSource:(NSString *)downloadSource
                                           rawTask:(nullable id)rawTask
                                    supportsResume:(BOOL)supportsResume
                                           iconURL:(nullable NSString *)iconURL;

/// 设置任务状态
- (void)setTaskWithId:(NSString *)taskId state:(DownloadTaskState)state;

/// 标记任务完成（error==nil 成功 -> Completed；error!=nil 失败 -> Failed）
- (void)setTaskWithId:(NSString *)taskId completedWithError:(nullable NSError *)error;

/// 更新任务进度
- (void)updateTaskWithId:(NSString *)taskId
                progress:(double)progress
              totalBytes:(int64_t)totalBytes
         downloadedBytes:(int64_t)downloadedBytes;

/// 更新任务速度与剩余时间
- (void)updateTaskWithId:(NSString *)taskId
                   speed:(double)speed
estimatedTimeRemaining:(NSTimeInterval)estimatedTimeRemaining;

/// 是否有活跃任务（Pending / Downloading）
- (BOOL)hasActiveTasks;

/// 获取所有任务（按注册时间倒序）
- (NSArray<DownloadTaskItem *> *)allTasks;

/// 根据 taskId 获取任务项
- (nullable DownloadTaskItem *)taskWithId:(NSString *)taskId;

@end

NS_ASSUME_NONNULL_END
