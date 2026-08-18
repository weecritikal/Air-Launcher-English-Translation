#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

// Download task state
typedef NS_ENUM(NSInteger, DownloadTaskState) {
    DownloadTaskStatePending = 0,    // Waiting
    DownloadTaskStateDownloading,    // Downloading
    DownloadTaskStatePaused,         // Paused
    DownloadTaskStateCompleted,      // Completed
    DownloadTaskStateCancelled,      // Cancelled
    DownloadTaskStateFailed          // Failed
};

// Aggregate state (used by the floating button, launch guarding, etc.)
typedef NS_ENUM(NSInteger, DownloadTaskAggregateState) {
    DownloadTaskAggregateStateNone = 0,   // No tasks
    DownloadTaskAggregateStateIdle,       // All paused/waiting with nothing active
    DownloadTaskAggregateStateActive,     // At least one task is downloading
    DownloadTaskAggregateStatePaused,     // At least one is paused and nothing is active
    DownloadTaskAggregateStateCompleted,  // All complete
    DownloadTaskAggregateStateFailed      // Failures remain after everything failed/was cancelled (optional)
};

// Resource type constants
extern NSString * const DownloadTaskResourceTypeMinecraft;
extern NSString * const DownloadTaskResourceTypeModloader;
extern NSString * const DownloadTaskResourceTypeMod;
extern NSString * const DownloadTaskResourceTypeShader;
extern NSString * const DownloadTaskResourceTypeResourcePack;
extern NSString * const DownloadTaskResourceTypeDataPack;
extern NSString * const DownloadTaskResourceTypeModpack;
extern NSString * const DownloadTaskResourceTypeWorld;

@class DownloadTaskItem;

/// Retry callback type: set by the caller when registering a task; DownloadTaskManager.retryTaskWithId: invokes it to rebuild the underlying rawTask.
/// Inside the handler the caller creates a new NSURLSessionTask and assigns it to item.rawTask; the old item does not need removing (the manager handles that).
/// The parameter is the current item (already reset), and the return value is the new rawTask (used by the manager to update item.rawTask).
typedef id _Nullable (^DownloadRetryHandler)(DownloadTaskItem *item);

/**
 * Unified download task model.
 * Every download (the Minecraft client, a loader, a mod, a resource pack, and so on) maps to one instance in DownloadTaskManager.
 */
@interface DownloadTaskItem : NSObject

@property (nonatomic, copy) NSString *taskId;
@property (nonatomic, copy) NSString *resourceType;
@property (nonatomic, copy) NSString *resourceName;
@property (nonatomic, copy) NSString *displayName;
@property (nonatomic, copy) NSString *downloadSource;
@property (nonatomic, assign) DownloadTaskState state;

/// 0.0 ~ 1.0; < 0 means unknown/indeterminate
@property (nonatomic, assign) double progress;
@property (nonatomic, assign) int64_t totalSize;
@property (nonatomic, assign) int64_t downloadedSize;
@property (nonatomic, assign) double speed;                    // bytes/s
@property (nonatomic, assign) NSTimeInterval estimatedTimeRemaining;

@property (nonatomic, copy, nullable) NSString *iconURL;
@property (nonatomic, assign) BOOL supportsResume;
@property (nonatomic, strong) NSDate *createdDate;

/// The underlying task object, held weakly to avoid a retain cycle (MinecraftResourceDownloadTask / NSURLSessionTask, etc.)
@property (nonatomic, weak, nullable) id rawTask;
@property (nonatomic, strong, nullable) NSError *errorInfo;

/// For callers to stash extra fields
@property (nonatomic, strong) NSMutableDictionary *userInfo;

#pragma mark - Retry support (FCL style re-download)

/// The original download URL, so a retry/source switch can rebuild it straight from the model (optional; callers may leave it empty)
@property (nonatomic, copy, nullable) NSString *downloadURL;

/// Retry callback: set by the caller when registering a task; DownloadTaskManager.retryTaskWithId: invokes it to rebuild the underlying rawTask.
/// Inside the handler the caller creates a new NSURLSessionTask and assigns it to item.rawTask; the old item does not need removing (the manager handles that).
/// The parameter is the current item (already reset), and the return value is the new rawTask (used by the manager to update item.rawTask).
@property (nonatomic, copy, nullable) DownloadRetryHandler retryHandler;

/// Number of retries so far (incremented by the manager on each retryTaskWithId:)
@property (nonatomic, assign) NSInteger retryCount;

/// Maximum retry count, 3 by default. Past this the UI stops offering "Retry" (but "Remove" is still available)
@property (nonatomic, assign) NSInteger maxRetryCount;

- (instancetype)initWithResourceType:(NSString *)resourceType
                        resourceName:(NSString *)resourceName
                         displayName:(NSString *)displayName
                      downloadSource:(NSString *)downloadSource
                             rawTask:(nullable id)rawTask
                      supportsResume:(BOOL)supportsResume
                             iconURL:(nullable NSString *)iconURL;

@end

NS_ASSUME_NONNULL_END
