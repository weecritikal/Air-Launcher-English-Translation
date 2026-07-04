//
//  WorldsManagerViewController.h
//  Amethyst
//
//  世界存档管理视图控制器，参照 ModsManagerViewController
//  扫描 saves/ 目录、删除世界、导入世界 zip（含健壮解压）
//

#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSInteger, WorldsManagerMode) {
    WorldsManagerModeLocal,
    WorldsManagerModeOnline
};

@interface WorldsManagerViewController : UIViewController

@property (nonatomic, copy, nullable) NSString *profileName;
@property (nonatomic, assign) WorldsManagerMode initialMode;
@property (nonatomic, assign) WorldsManagerMode currentMode;
@property (nonatomic, strong) NSMutableArray *onlineSearchResults;

@end

NS_ASSUME_NONNULL_END
