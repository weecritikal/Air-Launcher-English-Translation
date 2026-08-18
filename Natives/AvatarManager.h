#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

/// Manager for importing custom account avatars (singleton).
/// Stores a custom avatar PNG per accountName at Documents/avatars/<accountName>.png.
/// On read, the local file wins, falling back to the online URL.
@interface AvatarManager : NSObject

+ (instancetype)sharedManager;

/// Save a custom avatar image for the given account.
/// Does nothing if accountName is nil or empty.
- (void)saveAvatarForAccount:(NSString *)accountName
                     image:(UIImage *)image
          withCompletion:(void (^)(BOOL success, NSError * _Nullable error))completion;

/// Read the custom avatar image for the given account, returning nil if there is none.
- (nullable UIImage *)avatarForAccount:(NSString *)accountName;

/// Whether a custom avatar already exists for the given account.
- (BOOL)hasCustomAvatarForAccount:(NSString *)accountName;

/// Delete the custom avatar for the given account (reverting to the online URL avatar).
- (void)removeAvatarForAccount:(NSString *)accountName;

@end

NS_ASSUME_NONNULL_END
