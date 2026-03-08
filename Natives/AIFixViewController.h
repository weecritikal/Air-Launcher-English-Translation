//
//  AIFixViewController.h
//  Amethyst
//
//  AI 崩溃修复界面控制器
//

#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

@interface AIFixViewController : UIViewController

/// 初始化并设置崩溃日志路径
/// @param logPath 崩溃日志文件路径（可选，默认使用 latestlog.txt）
- (instancetype)initWithLogPath:(nullable NSString *)logPath;

/// 从设置界面进入的初始化方法
- (instancetype)initForSettings;

@end

NS_ASSUME_NONNULL_END
