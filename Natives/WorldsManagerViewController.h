//
//  WorldsManagerViewController.h
//  Amethyst
//
//  World save management view controller, modeled on ModsManagerViewController
//  Scans the saves/ directory, deletes worlds and imports world zips (with robust extraction)
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
