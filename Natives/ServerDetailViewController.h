//
//  ServerDetailViewController.h
//  Flux
//
//  The server detail page:
//  - the server icon, name and description
//  - the server address (which can be copied)
//  - a "Join server" button (saving the address into the current profile)
//  - a "Download the linked modpack" button (when there is a linked modpack / server pack)
//  - InlineMessageView shows the results
//

#import <UIKit/UIKit.h>
#import "ServerItem.h"
#import "ServerService.h"

NS_ASSUME_NONNULL_BEGIN

@interface ServerDetailViewController : UIViewController

- (instancetype)initWithServerItem:(ServerItem *)item api:(ServerDownloadAPI)api;

@end

NS_ASSUME_NONNULL_END
