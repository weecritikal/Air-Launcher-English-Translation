#import <Foundation/Foundation.h>

typedef void(^Callback)(id status, BOOL success);

@interface BaseAuthenticator : NSObject

@property (nonatomic, strong) NSMutableDictionary *authData;

+ (id)current;
+ (void)setCurrent:(BaseAuthenticator *)auth;
+ (id)loadSavedName:(NSString *)name;

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
