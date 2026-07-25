#import <UIKit/UIKit.h>

// 版本设置 - 管理当前版本的模组/光影/Java/内存/渲染器/服务器/资源包/世界
// 合并了原 LauncherProfileEditorViewController 的版本选择和重命名功能
// 参照 FCL 风格，作为统一的 Edit Profile 页面
//
// 重构（Air-Design v1.2）：
//   - 顶部 Hero 卡片：Profile 名 + 当前版本 pill + 游戏目录
//   - 4 个 Bento 分组：版本信息与资源管理 / 高级设置 / 服务器 / 组件安装
//   - 资源管理项（模组/光影/资源包/数据包/世界）归拢到"版本信息与资源管理"分组
@interface ProfileSettingsViewController : UITableViewController

// 编辑现有 profile 时设置 profileName（从 PLProfiles.current.profiles 查找）
@property (nonatomic, copy, nullable) NSString *profileName;
// 新建 profile 时直接传入 profile 字典（与 profileName 二选一）
@property (nonatomic, strong, nullable) NSMutableDictionary *profile;

@end
