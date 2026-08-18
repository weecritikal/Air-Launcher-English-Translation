#import <UIKit/UIKit.h>

// FCL风格启动器根视图控制器 - 管理三栏布局
// 左侧：功能菜单 | 中间：内容区 | 右侧：账户和启动

@interface LauncherRootViewController : UIViewController <UINavigationControllerDelegate>

// The three main areas
@property(nonatomic, strong, readonly) UIViewController *sidebarViewController;      // Left sidebar
@property(nonatomic, strong, readonly) UIViewController *contentViewController;      // Middle content
@property(nonatomic, strong, readonly) UIViewController *rightPanelViewController;   // Right panel

// Switch the middle content
- (void)setContentViewController:(UIViewController *)viewController animated:(BOOL)animated;

@end
