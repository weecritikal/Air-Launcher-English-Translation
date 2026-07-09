#import <UIKit/UIKit.h>

@interface PLCrashView : UIView

/// 显示崩溃界面并处理退出代码
/// @param exitCode 游戏退出代码
/// @param customTitle 自定义错误标题（可选）
/// @param customReason 自定义错误原因（可选）
+ (void)showWithExitCode:(int)exitCode customTitle:(NSString *)customTitle customReason:(NSString *)customReason;

/// 显示崩溃界面（仅退出代码）
/// @param exitCode 游戏退出代码
+ (void)showWithExitCode:(int)exitCode;

/// 隐藏崩溃界面并返回启动器
- (void)dismissAndReturnToLauncher;

/// 重启启动器（类方法，可从其他 VC 安全调用）
/// 会清理当前崩溃界面并重启应用进程
+ (void)restartLauncher;

/// 隐藏崩溃界面并返回启动器（类方法，可从其他 VC 安全调用）
+ (void)dismissAndReturnToLauncher;

@end
