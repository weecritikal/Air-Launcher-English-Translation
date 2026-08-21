//
//  ThirdPartyLoginViewController.h
//  Flux
//
//  Modeled on the Android FCL (Fold Craft Launcher):
//  LittleSkin and custom Yggdrasil third-party logins share a single card-style login form page,
//  replacing the original two-field UIAlertController input.
//  - LittleSkin mode: authserver is preset, only username/password are shown
//  - Custom mode: an additional server address input field is provided
//

#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSInteger, ThirdPartyLoginMode) {
    ThirdPartyLoginModeLittleSkin = 0, // Preset LittleSkin skin site
    ThirdPartyLoginModeCustom,         // Any Yggdrasil-compatible server
};

@interface ThirdPartyLoginViewController : UIViewController

/// Login mode (determines whether the server address field is shown and whether authserver is preset)
@property (nonatomic, assign) ThirdPartyLoginMode mode;

/// Login completion callback: when success=YES the caller should pop the current VC and trigger an account list refresh
@property (nonatomic, copy) void (^onLoginComplete)(BOOL success, NSString *_Nullable errorMessage);

@end

NS_ASSUME_NONNULL_END
