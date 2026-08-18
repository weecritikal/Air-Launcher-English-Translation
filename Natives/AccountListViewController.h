#import <UIKit/UIKit.h>

@interface AccountListViewController: UITableViewController<UIPopoverPresentationControllerDelegate>


@property (nonatomic, copy) void (^whenDelete)(NSString* name);
@property(nonatomic, copy) void (^whenItemSelected)();

/// FCL-style floating "Add account" button at the bottom (exposed for layout/animation control)
@property (nonatomic, strong) UIButton *addAccountButton;

@end
