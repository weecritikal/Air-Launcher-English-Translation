#import <UIKit/UIKit.h>

@class ForgeInstallSchemeViewController;

@protocol ForgeInstallSchemeViewControllerDelegate <NSObject>
- (void)schemeViewController:(ForgeInstallSchemeViewController *)controller didSelectScheme:(NSInteger)scheme;
@end

@interface ForgeInstallSchemeViewController : UIViewController

@property (nonatomic, weak) id<ForgeInstallSchemeViewControllerDelegate> delegate;

/// The Minecraft version being installed for. Which scheme is recommended depends on it: Forge
/// 1.13 and later build part of the runtime during installation, and only the installer can do
/// that here. Leave it unset to keep the generic wording.
@property (nonatomic, copy) NSString *gameVersion;

@end
