//
//  LanPortDetector.h
//  Amethyst
//
//  Minecraft "对局域网开放"端口检测器
//
//  ============================================================================
//  功能说明
//  ============================================================================
//
//  当玩家在 MC 中进入世界并执行"对局域网开放"（Open to LAN）后，MC 会在日志中
//  输出端口号。本检测器通过拦截日志输出，自动识别 LAN 端口。
//
//  MC 日志格式（不同版本略有差异）：
//  - "Local game hosted on port 54321"（1.10+）
//  - "Local game hosted on 0.0.0.0:54321"（部分版本）
//  - "Started serving on 54321"（极旧版本）
//  - "Integrated server started on port 54321"（部分 Forge 版本）
//
//  使用方式：
//  1. 在游戏启动后调用 startDetecting 注册日志监听
//  2. 检测到端口后通过通知 LanPortDetectorDidDetectPort 通知 UI
//  3. 用户也可通过 setManualPort: 手动指定端口
//  4. 游戏退出时调用 stopDetecting 移除监听
//
//  通知：
//  - LanPortDetectorDidDetectPort：检测到 LAN 端口时发送
//    userInfo: @{@"port": @"54321", @"source": @"auto"/@"manual"}
//
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// LAN 端口检测通知名
extern NSString *const LanPortDetectorDidDetectPortNotification;

/// 端口检测来源
typedef NS_ENUM(NSInteger, LanPortSource) {
    LanPortSourceUnknown = 0, // 未知
    LanPortSourceAuto   = 1, // 自动检测（日志拦截）
    LanPortSourceManual = 2  // 手动输入
};

/// Minecraft "对局域网开放"端口检测器
///
/// 重要变更：自动检测已禁用，改为手动输入端口。
/// 之前通过拦截 MC 日志输出自动检测 LAN 端口，但存在以下问题：
///   - latestlog.txt 可能包含上次会话的日志，导致误检测旧端口
///   - 不同 MC 版本日志格式差异大，自动检测不可靠
///   - 用户在游戏未真正"对局域网开放"时就生成了分享代码
/// 现在改为手动输入：用户在 MC 中"对局域网开放"后，手动输入聊天框显示的端口号。
/// LanPortDetector 仅保留 setManualPort: 方法供用户手动设置端口。
/// startDetecting/stopDetecting 保留为 no-op，仅用于 API 兼容性。
@interface LanPortDetector : NSObject

/// 单例访问
+ (instancetype)sharedDetector;

/// 当前检测到的端口（nil 表示未检测到）
@property (nonatomic, copy, readonly, nullable) NSString *detectedPort;

/// 端口检测来源
@property (nonatomic, assign, readonly) LanPortSource source;

/// 上次检测到端口的时间
@property (nonatomic, strong, readonly, nullable) NSDate *detectedAt;

/// 是否正在检测中
@property (nonatomic, assign, readonly, getter=isDetecting) BOOL detecting;

/// 开始检测（注册日志监听）
/// 在游戏启动后调用
- (void)startDetecting;

/// 停止检测（移除日志监听）
/// 在游戏退出时调用
- (void)stopDetecting;

/// 手动设置端口
/// @param port 端口号字符串（如 "54321"）
- (void)setManualPort:(NSString *)port;

/// 清除当前端口（重置状态）
- (void)clearPort;

/// 尝试从 latestlog.txt 重新解析端口
/// 当自动检测失败时，可调用此方法从日志文件中重新搜索
/// @return 检测到的端口号，nil 表示未找到
- (nullable NSString *)detectFromLogFile;

/// 检查一行日志是否包含 LAN 端口信息
/// @param logLine 日志行
/// @return 解析出的端口号，nil 表示不包含
- (nullable NSString *)parsePortFromLogLine:(NSString *)logLine;

@end

NS_ASSUME_NONNULL_END
