//
//  AccountLoginViewController.h
//  Amethyst
//
//  Modelled on the account login screen of FCL (Fold Craft Launcher) for Android:
//  a card list offering Microsoft / LittleSkin / custom third-party / local sign-in,
//  replacing the crude ActionSheet + UIAlertController interaction.
//

#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

@interface AccountLoginViewController : UIViewController

/// Login method enum
typedef NS_ENUM(NSInteger, AccountLoginType) {
    AccountLoginTypeMicrosoft = 0,
    AccountLoginTypeLittleSkin,
    AccountLoginTypeThirdParty,
    AccountLoginTypeLocal,
};

/// Callback fired once the user picks a login method (AccountListViewController runs the actual login flow)
@property (nonatomic, copy) void (^onSelectLoginType)(AccountLoginType type);

@end

NS_ASSUME_NONNULL_END
