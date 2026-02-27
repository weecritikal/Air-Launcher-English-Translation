#import <UIKit/UIKit.h>

@interface ForgeInstallViewController : UITableViewController

@property (nonatomic, copy) NSString *gameVersion;
@property (nonatomic, assign) BOOL isNeoForge;
@property (nonatomic, copy) void (^completionHandler)(BOOL success, NSString *profileName, NSError *error);

@end
