#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

/// EasyTier MC 联机界面（参照 FCL 和 ZL2 的陶瓦联机界面）
///
/// 基于 Terracotta（陶瓦联机）的 Scaffolding-MC 协议实现，
/// 使用 `U/XXXX-XXXX-XXXX-XXXX` 格式的邀请码，与 HMCL/FCL/ZL2/PCL2 完全互通。
///
/// 功能：
/// 1. EasyTier 状态卡片（检测 app 安装、一键跳转 EasyTier / TestFlight）
/// 2. 联机房间列表（已保存的房间，点击连接/断开/分享邀请码）
/// 3. 房主模式：输入房间名+端口 → 自动生成邀请码 → 弹窗显示邀请码（复制/分享）
/// 4. 房客模式：输入房主分享的邀请码（U/XXXX-XXXX-XXXX-XXXX）→ 实时验证 → 加入房间
/// 5. 快速直连（输入 IP + 端口，一键加入游戏，适用于 iOS < 16 无法使用 EasyTier 的用户）
///
/// 系统要求：
/// - EasyTier iOS app 需要 iOS 16.0 及以上系统
/// - ZeroTier iOS app 支持 iOS 13.0 及以上系统
/// - 本启动器最低支持 iOS 14.0
/// - iOS 14-15 用户会看到系统版本不足的提示，可改用 ZeroTier 或快速直连
@interface EasyTierMultiplayerViewController : UIViewController

@end

NS_ASSUME_NONNULL_END
