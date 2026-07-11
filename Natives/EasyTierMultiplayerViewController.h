#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

/// EasyTier MC 联机界面（参照 FCL 和 ZL2 的陶瓦联机界面）
///
/// 功能：
/// 1. EasyTier 状态卡片（检测 app 安装、一键跳转 EasyTier / TestFlight）
/// 2. 联机房间列表（已保存的房间，点击连接/断开）
/// 3. 创建房间（输入房间名、网络名、密码、中继服务器、IP、端口）
/// 4. 导入房间（通过分享文本导入）
/// 5. 快速直连（输入 IP + 端口，一键加入游戏）
///
/// 系统要求：
/// - EasyTier iOS app 需要 iOS 16.0 及以上系统
/// - 本启动器最低支持 iOS 14.0
/// - iOS 14-15 用户会看到系统版本不足的提示
@interface EasyTierMultiplayerViewController : UIViewController

@end

NS_ASSUME_NONNULL_END
