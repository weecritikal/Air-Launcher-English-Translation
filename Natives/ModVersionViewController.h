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

// FCL style: pass in the preferred version and loader of the current profile
// ModVersionViewController preselects the matching chip and pins the matching version to the top
// Without them it keeps the original "All" default
@property (nonatomic, copy, nullable) NSString *preferredGameVersion;
@property (nonatomic, copy, nullable) NSString *preferredLoader;

@end

NS_ASSUME_NONNULL_END
