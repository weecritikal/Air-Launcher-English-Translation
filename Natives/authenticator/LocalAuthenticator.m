#import "BaseAuthenticator.h"

@implementation LocalAuthenticator

- (void)loginWithCallback:(Callback)callback {
    self.authData[@"oldusername"] = self.authData[@"username"] = self.authData[@"input"];
    self.authData[@"profileId"] = @"00000000-0000-0000-0000-000000000000";
    // 使用Minecraft Headshot API加载头像
    self.authData[@"profilePicURL"] = [NSString stringWithFormat:@"http://api.rms.net.cn/head/%@", self.authData[@"username"]];
    callback(nil, [super saveChanges]);
}

- (void)refreshTokenWithCallback:(Callback)callback {
    // Nothing to do
    callback(nil, YES);
}

@end
