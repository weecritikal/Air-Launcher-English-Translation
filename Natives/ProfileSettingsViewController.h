#import <UIKit/UIKit.h>

// 版本设置 - 管理当前版本的模组/光影/Java/内存/渲染器/服务器/资源包/世界
// 合并了原 LauncherProfileEditorViewController 的版本选择和重命名功能
// 参照 FCL 风格，作为统一的 Edit Profile 页面
@interface ProfileSettingsViewController : UITableViewController

// 编辑现有 profile 时设置 profileName（从 PLProfiles.current.profiles 查找）
@property (nonatomic, copy, nullable) NSString *profileName;
// 新建 profile 时直接传入 profile 字典（与 profileName 二选一）
@property (nonatomic, strong, nullable) NSMutableDictionary *profile;

@end
