#import <UIKit/UIKit.h>

/// 陶瓦联机界面（参考 FCL 风格）
///
/// 启动器内由 LauncherRootViewController/LauncherCardLayoutViewController 通过
/// ShowMultiplayer 通知弹出；游戏内由 SurfaceViewController+Navigation 通过
/// 悬浮球菜单弹出。两种入口都展示同一个控制器（modal）。
@interface TerracottaViewController : UIViewController

@end
