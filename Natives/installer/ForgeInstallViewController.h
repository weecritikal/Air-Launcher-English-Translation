#import <UIKit/UIKit.h>

extern NSString * const ForgeInstallerFlowErrorDomain;
typedef NS_ENUM(NSInteger, ForgeInstallerFlowErrorCode) {
    ForgeInstallerFlowErrorCodeCancelled = 1,
    ForgeInstallerFlowErrorCodeFailedToOpenInstaller = 2,
};

@interface ForgeInstallViewController : UITableViewController

@property (nonatomic, copy) NSString *gameVersion;
@property (nonatomic, assign) BOOL isNeoForge;
@property (nonatomic, copy) void (^completionHandler)(BOOL success, NSString *profileName, id resultOrError);

@end
