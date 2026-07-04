//
//  DataPacksManagerViewController.h
//  Amethyst
//
//  数据包管理视图控制器，参照 ModsManagerViewController
//  本地/在线模式切换、搜索、启用/禁用、删除、导入
//  注意：Minecraft 要求数据包放在 saves/<世界名>/datapacks/，
//  本管理器扫描 <gameDir>/datapacks/（通用目录），用户需手动移动到对应世界目录
//

#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSInteger, DataPacksManagerMode) {
    DataPacksManagerModeLocal,
    DataPacksManagerModeOnline
};

@interface DataPacksManagerViewController : UIViewController

@property (nonatomic, copy, nullable) NSString *profileName;
@property (nonatomic, assign) DataPacksManagerMode initialMode;
@property (nonatomic, assign) DataPacksManagerMode currentMode;
@property (nonatomic, strong) NSMutableArray *onlineSearchResults;

@end

NS_ASSUME_NONNULL_END
