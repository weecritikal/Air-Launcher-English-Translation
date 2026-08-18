#import <UIKit/UIKit.h>

// Card-style (bento box) launcher root view controller
// Left: the feature menu card | Middle: the content card | Right: the account and play card

@interface LauncherCardLayoutViewController : UIViewController <UINavigationControllerDelegate>

// The three main areas
@property(nonatomic, strong, readonly) UIViewController *sidebarViewController;      // Left sidebar
@property(nonatomic, strong, readonly) UIViewController *contentViewController;      // Middle content
@property(nonatomic, strong, readonly) UIViewController *rightPanelViewController;   // Right panel

// Switch the middle content
- (void)setContentViewController:(UIViewController *)viewController animated:(BOOL)animated;

@end
