//
//  AnnouncementListViewController.h
//  Amethyst
//
//  Announcement list view controller
//  Follows the waterfall card style of MinecraftNewsViewController, simplified:
//  - Two-column UICollectionViewCompositionalLayout
//  - Each cell shows a title, date and summary
//  - Cards with priority=high get a blue bar on the left
//  - Tapping opens the detail page, AnnouncementDetailViewController
//  - Supports pull-to-refresh and a force-refresh button in the top right
//

#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

@interface AnnouncementListViewController : UIViewController

@end

NS_ASSUME_NONNULL_END
