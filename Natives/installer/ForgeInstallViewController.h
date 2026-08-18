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
// Preset version: passed in after LoaderSelectionViewController selects one, so the user does not have to pick the version again in ForgeInstallVC
// When it is non-empty, viewDidLoad skips fetching the metadata and goes straight to option selection
@property (nonatomic, copy) NSString *presetVersionString;

@end
