#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

// 下载任务状态
typedef NS_ENUM(NSInteger, DownloadTaskState) {
    DownloadTaskStatePending = 0,    // 等待中
    DownloadTaskStateDownloading,    // 下载中
    DownloadTaskStatePaused,         // 已暂停
    DownloadTaskStateCompleted,      // 已完成
    DownloadTaskStateCancelled,      // 已取消
    DownloadTaskStateFailed          // 失败
};

// 聚合状态（用于悬浮球、启动保护等）
typedef NS_ENUM(NSInteger, DownloadTaskAggregateState) {
    DownloadTaskAggregateStateNone = 0,   // 无任务
    DownloadTaskAggregateStateIdle,       // 全部暂停/等待中但无活动
    DownloadTaskAggregateStateActive,     // 存在下载中任务
    DownloadTaskAggregateStatePaused,     // 至少有一个暂停且无活动任务
    DownloadTaskAggregateStateCompleted,  // 全部完成
    DownloadTaskAggregateStateFailed      // 全部失败/取消后仍有失败记录（可选）
};

// 资源类型常量
extern NSString * const DownloadTaskResourceTypeMinecraft;
extern NSString * const DownloadTaskResourceTypeModloader;
extern NSString * const DownloadTaskResourceTypeMod;
extern NSString * const DownloadTaskResourceTypeShader;
extern NSString * const DownloadTaskResourceTypeResourcePack;
extern NSString * const DownloadTaskResourceTypeDataPack;
extern NSString * const DownloadTaskResourceTypeModpack;

/**
 * 统一下载任务数据模型。
 * 每个下载任务（MC 本体、加载器、Mod、资源包等）在 DownloadTaskManager 中对应一个实例。
 */
@interface DownloadTaskItem : NSObject

@property (nonatomic, copy) NSString *taskId;
@property (nonatomic, copy) NSString *resourceType;
@property (nonatomic, copy) NSString *resourceName;
@property (nonatomic, copy) NSString *displayName;
@property (nonatomic, copy) NSString *downloadSource;
@property (nonatomic, assign) DownloadTaskState state;

/// 0.0 ~ 1.0；< 0 表示未知/不确定
@property (nonatomic, assign) double progress;
@property (nonatomic, assign) int64_t totalSize;
@property (nonatomic, assign) int64_t downloadedSize;
@property (nonatomic, assign) double speed;                    // bytes/s
@property (nonatomic, assign) NSTimeInterval estimatedTimeRemaining;

@property (nonatomic, copy, nullable) NSString *iconURL;
@property (nonatomic, assign) BOOL supportsResume;
@property (nonatomic, strong) NSDate *createdDate;

/// 底层任务对象，弱引用以避免循环持有（MinecraftResourceDownloadTask / NSURLSessionTask 等）
@property (nonatomic, weak, nullable) id rawTask;
@property (nonatomic, strong, nullable) NSError *errorInfo;

/// 供业务方存放扩展字段
@property (nonatomic, strong) NSMutableDictionary *userInfo;

- (instancetype)initWithResourceType:(NSString *)resourceType
                        resourceName:(NSString *)resourceName
                         displayName:(NSString *)displayName
                      downloadSource:(NSString *)downloadSource
                             rawTask:(nullable id)rawTask
                      supportsResume:(BOOL)supportsResume
                             iconURL:(nullable NSString *)iconURL;

@end

NS_ASSUME_NONNULL_END
