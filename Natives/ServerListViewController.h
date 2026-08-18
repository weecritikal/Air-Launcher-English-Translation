//
//  ServerListViewController.h
//  Amethyst
//
//  The server list page, following the UI pattern of ModpackInstallViewController:
//  - a source switch at the top (Modrinth / CurseForge)
//  - a search box
//  - a list of servers
//  - tapping one opens the details (ServerDetailViewController)
//  - InlineMessageView replaces the modal alerts
//

#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

@interface ServerListViewController : UITableViewController <UISearchResultsUpdating>

@end

NS_ASSUME_NONNULL_END
