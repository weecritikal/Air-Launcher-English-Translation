//
//  DownloadTaskItem.h
//  Amethyst
//
//  统一下载任务项：用于 DownloadTaskManager 跟踪各类下载（Minecraft/Mod/Modloader/Modpack）
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// 下载资源类型
typedef NS_ENUM(NSInteger, DownloadTaskResourceType) {
    DownloadTaskResourceTypeMinecraft,    // Minecraft 版本本体
    DownloadTaskResourceTypeMod,          // 单个 Mod 文件
    DownloadTaskResourceTypeModloader,    // Mod 加载器（Fabric/Forge/NeoForge）
    DownloadTaskResourceTypeModpack,      // 整合包
    DownloadTaskResourceTypeResourcePack, // 资源包
    DownloadTaskResourceTypeDataPack,     // 数据包
    DownloadTaskResourceTypeWorld,        // 世界存档
    DownloadTaskResourceTypeShader,       // 光影
};

/// 下载任务状态
typedef NS_ENUM(NSInteger, DownloadTaskState) {
    DownloadTaskStatePending,      // 已注册，未开始
    DownloadTaskStateDownloading,  // 下载中
    DownloadTaskStateCompleted,    // 已完成（成功）
    DownloadTaskStateFailed,       // 已失败
    DownloadTaskStateCancelled,    // 已取消
};

@interface DownloadTaskItem : NSObject

/// 任务唯一标识（由 Manager 在注册时生成）
@property (nonatomic, copy, readonly) NSString *taskId;
/// 资源名（通常是文件名或版本 ID）
@property (nonatomic, copy) NSString *resourceName;
/// 显示名（用于 UI 展示）
@property (nonatomic, copy) NSString *displayName;
/// 下载来源（如 "official"/"modrinth"/"curseforge"/"bmclapi"）
@property (nonatomic, copy) NSString *downloadSource;
/// 资源类型
@property (nonatomic, assign) DownloadTaskResourceType resourceType;
/// 原始任务对象（NSURLSessionTask / MinecraftResourceDownloadTask / nil）
@property (nonatomic, strong, nullable) id rawTask;
/// 是否支持断点续传
@property (nonatomic, assign) BOOL supportsResume;
/// 图标 URL（可选）
@property (nonatomic, copy, nullable) NSString *iconURL;
/// 当前状态
@property (nonatomic, assign) DownloadTaskState state;
/// 进度（0.0-1.0，-1.0 表示未知）
@property (nonatomic, assign) double progress;
/// 总字节数（-1 表示未知）
@property (nonatomic, assign) int64_t totalBytes;
/// 已下载字节数
@property (nonatomic, assign) int64_t downloadedBytes;
/// 下载速度（字节/秒）
@property (nonatomic, assign) double speed;
/// 预计剩余时间（秒）
@property (nonatomic, assign) NSTimeInterval estimatedTimeRemaining;
/// 错误信息（失败时设置）
@property (nonatomic, strong, nullable) NSError *errorInfo;
/// 注册时间
@property (nonatomic, strong, readonly) NSDate *createdAt;

/// 是否处于活跃状态（Pending / Downloading）
- (BOOL)isActive;

@end

NS_ASSUME_NONNULL_END
