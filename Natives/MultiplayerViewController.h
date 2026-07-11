#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

/// MC 联机界面（参照 FCL 和 ZL2）
///
/// 功能：
/// 1. ZeroTier 状态卡片（检测 app 安装、一键跳转 ZeroTier One）
/// 2. 联机房间列表（已保存的房间，点击连接/断开）
/// 3. 创建房间（输入房间名、Network ID、IP、端口）
/// 4. 加入房间（通过分享文本导入）
/// 5. 快速直连（输入 IP + 端口，一键加入游戏）
@interface MultiplayerViewController : UIViewController

@end

NS_ASSUME_NONNULL_END
