#import <UIKit/UIKit.h>
#import "installer/ForgeInstallSchemeViewController.h"

extern NSString * const ForgeInstallerFlowErrorDomain;
typedef NS_ENUM(NSInteger, ForgeInstallerFlowErrorCode) {
    ForgeInstallerFlowErrorCodeCancelled = 1,
    ForgeInstallerFlowErrorCodeFailedToOpenInstaller = 2,
};

@interface ForgeInstallViewController : UITableViewController <ForgeInstallSchemeViewControllerDelegate>

@property (nonatomic, copy) NSString *gameVersion;
@property (nonatomic, assign) BOOL isNeoForge;
@property (nonatomic, assign) NSInteger selectedScheme;
@property (nonatomic, copy) void (^completionHandler)(BOOL success, NSString *profileName, id resultOrError);

@end
