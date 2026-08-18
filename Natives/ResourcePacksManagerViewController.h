//
//  ResourcePacksManagerViewController.h
//  Amethyst
//
//  资源包管理视图控制器，参照 ModsManagerViewController
//  Local/online mode switching, search, enable/disable, delete, import
//

#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSInteger, ResourcePacksManagerMode) {
    ResourcePacksManagerModeLocal,
    ResourcePacksManagerModeOnline
};

@interface ResourcePacksManagerViewController : UIViewController

@property (nonatomic, copy, nullable) NSString *profileName;
@property (nonatomic, assign) ResourcePacksManagerMode initialMode;
@property (nonatomic, assign) ResourcePacksManagerMode currentMode;
@property (nonatomic, strong) NSMutableArray *onlineSearchResults;

@end

NS_ASSUME_NONNULL_END
