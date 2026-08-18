#import <UIKit/UIKit.h>
#import "DownloadTaskItem.h"

NS_ASSUME_NONNULL_BEGIN

/**
 * Full-screen download task manager page.
 * Shows every download registered with DownloadTaskManager in one place,
 * with two levels of filtering (download state and resource type) plus pause/resume/cancel/switch-source actions.
 */
@interface DownloadTasksViewController : UIViewController

/// Download state filter selected when the page opens (DownloadTaskStatePending by default, meaning all)
@property (nonatomic, assign) DownloadTaskState filterState;

/// Resource type filter selected when the page opens (nil means all)
@property (nonatomic, copy, nullable) NSString *filterType;

@end

NS_ASSUME_NONNULL_END
