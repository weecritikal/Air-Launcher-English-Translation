#import <Foundation/Foundation.h>

typedef void(^Callback)(id status, BOOL success);

@interface BaseAuthenticator : NSObject

@property (nonatomic, strong) NSMutableDictionary *authData;

+ (id)current;
+ (void)setCurrent:(BaseAuthenticator *)auth;
// Load the account file from disk by accountId. Compatible with legacy accounts (named by username):
// if the loaded authData has no accountId field, one is generated and the file, avatar and selected_account are migrated automatically.
+ (id)loadSavedName:(NSString *)accountId;
// Generate a unique accountId from the account data. Microsoft accounts use the xuid, third-party accounts the profileId, and local accounts a generated UUID.
+ (NSString *)generateAccountIdForData:(NSMutableDictionary *)authData;

- (id)initWithData:(NSMutableDictionary *)data;
- (id)initWithInput:(NSString *)string;
- (void)loginWithCallback:(Callback)callback;
- (void)refreshTokenWithCallback:(Callback)callback;
- (BOOL)saveChanges;

@end

@interface LocalAuthenticator : BaseAuthenticator
@end

@interface MicrosoftAuthenticator : BaseAuthenticator

+ (void)clearTokenDataOfProfile:(NSString *)profile;
+ (NSDictionary *)tokenDataOfProfile:(NSString *)profile;

@end
