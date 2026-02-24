//
//  ShadersManagerViewController.h
//  Amethyst
//
//  Main view controller for managing shader packs
//

#import <UIKit/UIKit.h>
#import "ShaderVersionViewController.h"

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSInteger, ShadersManagerMode) {
    ShadersManagerModeLocal,
    ShadersManagerModeOnline
};

@interface ShadersManagerViewController : UIViewController

@property (nonatomic, copy, nullable) NSString *profileName;

// Properties for online search
@property (nonatomic, assign) ShadersManagerMode currentMode;
@property (nonatomic, strong) NSMutableArray *onlineSearchResults;

@end

NS_ASSUME_NONNULL_END
