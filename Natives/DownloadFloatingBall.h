// ============================================================================
// DownloadFloatingBall.h
// 下载进度悬浮球（参照 FCL / ZL2 / HMCL 的统一下载进度入口）
// ============================================================================
//
// 设计理念
// ============================================================================
// 本组件综合参考了 FCL（FoldCraftLauncher）、ZL2（ZalithLauncher）和 HMCL 三个
// 启动器的下载进度显示方式，提供一个始终悬浮在启动器界面顶层的下载进度入口：
//
// 1. FCL 风格：
//    - 浮动圆形按钮，点击展开下载列表
//    - 按钮上直接显示总进度百分比，无需打开即可感知进度
//
// 2. ZL2 风格：
//    - 圆形进度环包裹数字百分比，视觉精致
//    - 可拖动到屏幕任意边缘位置
//
// 3. HMCL 风格：
//    - 下载任务有聚合状态（下载中/暂停/完成/失败）
//    - 任务列表清晰，支持暂停/取消操作
//
// 工作机制
// ============================================================================
// - 监听 DownloadTaskManager 的通知，自动显示/隐藏
// - 存在 downloading/pending 状态的任务时显示悬浮球
// - 所有任务完成后延迟 3 秒自动隐藏（让用户看到 100% 完成态）
// - 点击悬浮球以 FormSheet 方式弹出 DownloadProgressViewController（全任务模式）
// - 悬浮球显示聚合进度：所有活动任务的平均进度
// - 支持拖动重定位，位置记忆到 NSUserDefaults
//
// 使用方式
// ============================================================================
//   // 在 SceneDelegate 中激活一次即可（单例）
//   [[DownloadFloatingBall sharedBall] activateInWindowScene:windowScene];
//
// 视觉规范
// ============================================================================
// - 直径：56pt
// - 圆形进度环线宽：4pt
// - 圆角：28pt（完全圆形）
// - 阴影：半径 8，不透明度 0.25
// - 主题色：accentColor()，与启动器主题统一
// ============================================================================

#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

/**
 * 下载进度悬浮球（单例）。
 *
 * 负责在启动器界面顶层显示一个可拖动的圆形悬浮按钮，
 * 实时反映 DownloadTaskManager 中所有下载任务的聚合进度。
 * 点击后打开 DownloadProgressViewController 的全任务模式，
 * 展示每个下载任务的详细信息（参照 FCL/ZL2/HMCL 风格）。
 */
@interface DownloadFloatingBall : NSObject

/// 获取共享单例
+ (instancetype)sharedBall;

/**
 * 在指定的 UIWindowScene 中激活悬浮球。
 * 会在窗口层级上方创建一个独立 UIWindow 用于承载悬浮球，
 * 确保悬浮球始终显示在所有启动器内容之上（但不遮挡游戏运行界面）。
 *
 * @param windowScene 当前活跃的 UIWindowScene
 */
- (void)activateInWindowScene:(UIWindowScene *)windowScene;

/**
 * 手动显示悬浮球（通常由 DownloadTaskManager 通知自动触发）。
 * 若悬浮球已显示或没有活跃任务，此方法无效果。
 */
- (void)show;

/**
 * 手动隐藏悬浮球。
 * @param animated 是否带动画
 */
- (void)hideAnimated:(BOOL)animated;

/// 当前悬浮球是否可见
@property (nonatomic, assign, readonly) BOOL isVisible;

/// 当前聚合进度（0.0~1.0），所有活动任务的平均进度
@property (nonatomic, assign, readonly) CGFloat aggregateProgress;

/// 当前活动任务数量（downloading + pending 状态）
@property (nonatomic, assign, readonly) NSInteger activeTaskCount;

NS_ASSUME_NONNULL_END
@end
