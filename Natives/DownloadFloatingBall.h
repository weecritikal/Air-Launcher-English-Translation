#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

extern NSNotificationName const DownloadFloatingBallSettingsDidChangeNotification;

/**
 * 全局下载任务悬浮球。
 * - 跟随 DownloadTaskManager 聚合状态变色：空闲/暂停灰色、下载中黄色、全部完成绿色（10 秒后恢复灰色）
 * - 可拖拽，松手自动吸附到最近屏幕边缘
 * - 点击全屏打开 DownloadTasksViewController（运行时动态查找，不存在时不执行）
 * - 进入游戏（SurfaceViewController 可见）或关闭设置开关后自动隐藏
 */
@interface DownloadFloatingBall : NSObject

+ (instancetype)sharedBall;

/// 将悬浮球添加到主窗口并触发一次可见性/外观更新
- (void)attachToMainWindow;

- (void)show;
- (void)hide;
- (void)updateAppearance;

@end

NS_ASSUME_NONNULL_END
