#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

/* 陶瓦联机主界面（modal 弹出）
 *
 * - 顶部：状态卡片（连接状态 + 阶段描述 + 邀请码 + 直连地址）
 * - 中部：Tab 切换「创建房间」/「加入房间」
 * - 底部：玩家列表（已连接时显示）
 * - 与 HMCL/FCL/ZL2 100% 协议互通 */
@interface TerracottaViewController : UIViewController

@end

NS_ASSUME_NONNULL_END
