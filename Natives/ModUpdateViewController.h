#import <UIKit/UIKit.h>
#import "ModItem.h"

NS_ASSUME_NONNULL_BEGIN

/// Mod 更新/降级多阶段任务流页面
/// 流程：清理缓存 → 过滤 → 并发检查 → 用户确认 → 并发下载 → 替换文件 → 清理
@interface ModUpdateViewController : UIViewController

/// 初始化
/// @param mods 本地 Mod 列表（来自 ModService 扫描）
/// @param gameVersion 当前游戏版本
/// @param loader 当前加载器（fabric/forge/neoforge/quilt，可为 nil）
/// @param projectType 项目类型（mod/shader/resourcepack/datapack）
- (instancetype)initWithMods:(NSArray<ModItem *> *)mods
                gameVersion:(NSString *)gameVersion
                     loader:(nullable NSString *)loader
               projectType:(NSString *)projectType NS_DESIGNATED_INITIALIZER;

- (instancetype)initWithNibName:(nullable NSString *)nibNameOrNil bundle:(nullable NSBundle *)nibBundleOrNil NS_UNAVAILABLE;
- (instancetype)initWithCoder:(NSCoder *)coder NS_UNAVAILABLE;

@end

NS_ASSUME_NONNULL_END
