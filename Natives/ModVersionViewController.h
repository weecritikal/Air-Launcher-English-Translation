#import <UIKit/UIKit.h>
#import <UIKit/UIKit.h>
#import "ModItem.h"
#import "ModVersion.h"

NS_ASSUME_NONNULL_BEGIN

@class ModVersionViewController;

@protocol ModVersionViewControllerDelegate <NSObject>
- (void)modVersionViewController:(ModVersionViewController *)viewController didSelectVersion:(ModVersion *)version;
@end

@interface ModVersionViewController : UIViewController

@property (nonatomic, strong) UIActivityIndicatorView *activityIndicator;
@property (nonatomic, strong) ModItem *modItem;
@property (nonatomic, weak) id<ModVersionViewControllerDelegate> delegate;

@end

NS_ASSUME_NONNULL_END
