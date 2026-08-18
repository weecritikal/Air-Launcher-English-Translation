#import <UIKit/UIKit.h>

// FCL-style launcher root view controller - manages the three-column layout
// Left: the feature menu | Middle: the content area | Right: account and play

@interface LauncherRootViewController : UIViewController <UINavigationControllerDelegate>

// The three main areas
@property(nonatomic, strong, readonly) UIViewController *sidebarViewController;      // Left sidebar
@property(nonatomic, strong, readonly) UIViewController *contentViewController;      // Middle content
@property(nonatomic, strong, readonly) UIViewController *rightPanelViewController;   // Right panel

// Switch the middle content
- (void)setContentViewController:(UIViewController *)viewController animated:(BOOL)animated;

@end
