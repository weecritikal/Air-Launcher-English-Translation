//
//  DownloadProgressCardView.h
//  Amethyst
//
//  下载进度卡片视图（参照 FCL/ZL2/HMCL 的下载进度显示）
//

#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

/// 下载进度卡片视图（参照 FCL/ZL2/HMCL 的下载进度显示）
///
/// FCL 风格：底部悬浮卡片，含进度条 + 百分比 + 速度 + ETA + 文件名
/// ZL2 风格：圆角毛玻璃背景 + 彩色进度条 + 动画
/// HMCL 风格：简洁的信息布局 + 状态图标
///
/// 使用方式：
/// 1. 创建实例，addSubview 到当前视图
/// 2. 调用 startDownloadWithTitle:subtitle: 开始
/// 3. 调用 updateProgress:downloaded:total:speed:eta:currentFile: 更新进度
/// 4. 调用 completeWithTitle: 或 failWithError: 结束
/// 5. 调用 dismiss 移除
@interface DownloadProgressCardView : UIView

/// 进度 0.0 ~ 1.0，-1 表示不确定模式（转圈）
@property (nonatomic, assign) double progress;

/// 开始下载
/// @param title 标题（如 "正在下载 1.20.1"）
/// @param subtitle 副标题（如 "Minecraft 原版"）
- (void)startDownloadWithTitle:(NSString *)title subtitle:(nullable NSString *)subtitle;

/// 更新进度
/// @param progress 进度 0.0~1.0
/// @param downloadedBytes 已下载字节数
/// @param totalBytes 总字节数（-1 表示未知）
/// @param speedBytesPerSec 下载速度（字节/秒）
/// @param etaSeconds 剩余时间（秒，-1 表示未知）
/// @param currentFile 当前下载的文件名
- (void)updateProgress:(double)progress
            downloaded:(long long)downloadedBytes
                  total:(long long)totalBytes
                 speed:(long long)speedBytesPerSec
                   eta:(NSInteger)etaSeconds
           currentFile:(nullable NSString *)currentFile;

/// 下载完成
/// @param title 完成标题（如 "下载完成"）
- (void)completeWithTitle:(NSString *)title;

/// 下载失败
/// @param error 错误信息
- (void)failWithError:(NSError *)error;

/// 取消下载
- (void)cancel;

/// 从父视图中移除（带动画）
- (void)dismiss;

/// 在指定视图中显示下载进度卡片（类方法，方便调用）
/// @param parentView 父视图
/// @param title 标题
+ (instancetype)showInParentView:(UIView *)parentView title:(NSString *)title;

@end

NS_ASSUME_NONNULL_END
