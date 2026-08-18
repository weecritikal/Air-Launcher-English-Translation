#import <UIKit/UIKit.h>

// FCL-style left sidebar - the feature menu

@interface LauncherMenuViewController : UIViewController

// Menu item tap callback
@property(nonatomic, copy) void (^onMenuItemSelected)(NSInteger index, NSString *title);

// Refresh the account information
- (void)updateAccountInfo;

@end
