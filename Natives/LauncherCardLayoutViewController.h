#import <UIKit/UIKit.h>

// 卡片式（便当盒）启动器根视图控制器
// 左侧：功能菜单卡片 | 中间：内容卡片 | 右侧：账户和启动卡片

@interface LauncherCardLayoutViewController : UIViewController <UINavigationControllerDelegate>

// 三个主要区域
@property(nonatomic, strong, readonly) UIViewController *sidebarViewController;      // 左侧边栏
@property(nonatomic, strong, readonly) UIViewController *contentViewController;      // 中间内容
@property(nonatomic, strong, readonly) UIViewController *rightPanelViewController;   // 右侧面板

// 切换中间内容
- (void)setContentViewController:(UIViewController *)viewController animated:(BOOL)animated;

@end
