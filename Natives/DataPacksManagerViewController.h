//
//  DataPacksManagerViewController.h
//  Flux
//
//  Data pack manager view controller, modelled on ModsManagerViewController
//  Local/online mode switching, search, enable/disable, delete, import
//  Note: Minecraft requires data packs in saves/<world name>/datapacks/,
//  while this manager scans <gameDir>/datapacks/ (the shared folder), so the user must move them into the right world folder
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
