#import <UIKit/UIKit.h>
#import "DownloadTaskItem.h"

@interface DownloadTasksViewController : UIViewController
@property (nonatomic, assign) DownloadTaskState filterState;
@property (nonatomic, copy, nullable) NSString *filterType;
@end
