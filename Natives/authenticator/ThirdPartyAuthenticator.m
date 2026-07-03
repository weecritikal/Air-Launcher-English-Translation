#import "AFNetworking.h"
#import "ThirdPartyAuthenticator.h"
#import "../ios_uikit_bridge.h"
#import "../utils.h"

// authlib-injector 下载源：BMCLAPI 镜像优先，失败后回退到 GitHub 官方源
#define AUTHLIB_INJECTOR_URL_BMCL  @"https://bmclapi2.bangbang93.com/mirrors/authlib-injector/artifact/54/authlib-injector-1.2.6.jar"
#define AUTHLIB_INJECTOR_URL_GITHUB @"https://github.com/yushijinhun/authlib-injector/releases/download/v1.2.6/authlib-injector-1.2.6.jar"
#define AUTHLIB_INJECTOR_FILE @"authlib-injector.jar"

// Helper function to create NSError
static NSError* createError(NSString *message, NSInteger code) {
    return [NSError errorWithDomain:@"ThirdPartyAuthenticator" 
                            code:code 
                        userInfo:@{NSLocalizedDescriptionKey: message}];
}

@implementation ThirdPartyAuthenticator

- (NSString *)getAuthlibInjectorPath {
    NSString *path = [NSString stringWithFormat:@"%s/authlib-injector/%@", getenv("POJAV_HOME"), AUTHLIB_INJECTOR_FILE];
    return path;
}

- (BOOL)isAuthlibInjectorDownloaded {
    NSString *path = [self getAuthlibInjectorPath];
    return [[NSFileManager defaultManager] fileExistsAtPath:path];
}

- (void)downloadAuthlibInjector:(void (^)(BOOL success, NSError *error))completion {
    [self downloadAuthlibInjectorFromURL:AUTHLIB_INJECTOR_URL_BMCL attempt:1 completion:completion];
}

/// 逐个尝试下载源：BMCLAPI 失败后回退到 GitHub 官方源
- (void)downloadAuthlibInjectorFromURL:(NSString *)urlString
                               attempt:(NSInteger)attempt
                            completion:(void (^)(BOOL success, NSError *error))completion {
    NSString *dirPath = [NSString stringWithFormat:@"%s/authlib-injector", getenv("POJAV_HOME")];
    NSString *filePath = [self getAuthlibInjectorPath];

    // Create directory if it doesn't exist
    NSError *dirError;
    [[NSFileManager defaultManager] createDirectoryAtPath:dirPath withIntermediateDirectories:YES attributes:nil error:&dirError];
    if (dirError) {
        completion(NO, dirError);
        return;
    }

    NSURLSessionConfiguration *configuration = [NSURLSessionConfiguration defaultSessionConfiguration];
    configuration.timeoutIntervalForRequest = 30;
    configuration.timeoutIntervalForResource = 120;
    AFURLSessionManager *manager = [[AFURLSessionManager alloc] initWithSessionConfiguration:configuration];

    NSURL *URL = [NSURL URLWithString:urlString];
    // 使用 NSMutableURLRequest 以允许重定向跟随（GitHub releases 会 302 跳转）
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:URL];
    request.HTTPShouldUsePipelining = YES;

    NSLog(@"[ThirdPartyAuthenticator] 尝试下载 authlib-injector (第%ld源): %@", (long)attempt, urlString);

    NSURLSessionDownloadTask *downloadTask = [manager downloadTaskWithRequest:request progress:nil destination:^NSURL *(NSURL *targetPath, NSURLResponse *response) {
        return [NSURL fileURLWithPath:filePath];
    } completionHandler:^(NSURLResponse *response, NSURL *filePath, NSError *error) {
        if (error) {
            NSLog(@"[ThirdPartyAuthenticator] 下载失败 (第%ld源): %@", (long)attempt, error.localizedDescription);
            // BMCLAPI 失败后尝试 GitHub 官方源
            if (attempt == 1) {
                [self downloadAuthlibInjectorFromURL:AUTHLIB_INJECTOR_URL_GITHUB attempt:2 completion:completion];
            } else {
                completion(NO, error);
            }
        } else {
            NSLog(@"[ThirdPartyAuthenticator] 下载成功 (第%ld源)", (long)attempt);
            completion(YES, nil);
        }
    }];
    [downloadTask resume];
}

- (void)ensureAuthlibInjectorWithCompletion:(void (^)(BOOL success, NSError *error))completion {
    if ([self isAuthlibInjectorDownloaded]) {
        completion(YES, nil);
    } else {
        NSLog(@"[ThirdPartyAuthenticator] Downloading authlib-injector (BMCLAPI 优先，失败回退 GitHub)");
        [self downloadAuthlibInjector:^(BOOL success, NSError *error) {
            if (!success) {
                NSLog(@"[ThirdPartyAuthenticator] Failed to download authlib-injector: %@", error.localizedDescription);
                
                // Create a more informative error message
                NSString *errorMessage = [NSString stringWithFormat:@"Failed to download authlib-injector for third party authentication: %@", error.localizedDescription];
                NSError *customError = [NSError errorWithDomain:@"ThirdPartyAuthenticator" 
                                                          code:1001 
                                                      userInfo:@{NSLocalizedDescriptionKey: errorMessage}];
                
                completion(NO, customError);
            } else {
                NSLog(@"[ThirdPartyAuthenticator] Successfully downloaded authlib-injector");
                completion(YES, nil);
            }
        }];
    }
}

// Method to get JVM arguments for authlib-injector
- (NSArray *)getJvmArgsForAuthlib {
    NSString *injectorPath = [self getAuthlibInjectorPath];
    
    // Check file existence
    if (![[NSFileManager defaultManager] fileExistsAtPath:injectorPath]) {
        NSLog(@"[ThirdPartyAuthenticator] Warning: authlib-injector file not found at %@", injectorPath);
        return @[];
    }
    
    // Get server URL from authData or use default Ely.by server
    NSString *serverURL = self.authData[@"authserver"] ?: @"https://authserver.ely.by";
    
    NSString *jvmArg = [NSString stringWithFormat:@"-javaagent:%@=%@", injectorPath, serverURL];
    return @[jvmArg, @"-Dauthlibinjector.side=client"];
}

// Method to handle re-authentication with two-factor authentication
- (void)loginWithTwoFactorToken:(NSString *)token callback:(Callback)callback {
    NSString *username = self.authData[@"input"];
    NSString *password = self.authData[@"password"];
    
    if (username.length == 0 || password.length == 0) {
        NSError *error = createError(localize(@"login.error.fields.empty", nil), 1002);
        callback(error, NO);
        return;
    }
    
    // Add two-factor token to password
    NSString *passwordWithToken = [NSString stringWithFormat:@"%@:%@", password, token];
    
    NSDictionary *data = @{
        @"agent": @{@"name": @"Minecraft", @"version": @1},
        @"username": username,
        @"password": passwordWithToken,
        @"clientToken": [[NSUUID UUID] UUIDString],
        @"requestUser": @YES
    };
    
    AFHTTPSessionManager *manager = AFHTTPSessionManager.manager;
    manager.requestSerializer = AFJSONRequestSerializer.serializer;
    
    [self sendAuthenticateRequest:data manager:manager callback:callback];
}

// Helper method to build authentication URL based on server
- (NSString *)buildAuthURLForServer:(NSString *)serverURL {
    // Ensure serverURL ends with a slash
    if (![serverURL hasSuffix:@"/"]) {
        serverURL = [serverURL stringByAppendingString:@"/"];
    }
    
    // For Ely.by, use the old method
    if ([serverURL isEqualToString:@"https://authserver.ely.by/"]) {
        return [NSString stringWithFormat:@"%@auth/authenticate", serverURL];
    }
    // For other servers, use the standard Yggdrasil API method
    else {
        return [NSString stringWithFormat:@"%@authserver/authenticate", serverURL];
    }
}

// Helper method to build refresh URL based on server
- (NSString *)buildRefreshURLForServer:(NSString *)serverURL {
    // Ensure serverURL ends with a slash
    if (![serverURL hasSuffix:@"/"]) {
        serverURL = [serverURL stringByAppendingString:@"/"];
    }
    
    // For Ely.by, use the old method
    if ([serverURL isEqualToString:@"https://authserver.ely.by/"]) {
        return [NSString stringWithFormat:@"%@auth/refresh", serverURL];
    }
    // For other servers, use the standard Yggdrasil API method
    else {
        return [NSString stringWithFormat:@"%@authserver/refresh", serverURL];
    }
}

// Helper method to send authentication request
/// 多角色场景：调用 refresh 把选定角色绑定到 token
/// 参照 HMCL YggdrasilService.refresh：请求体含 accessToken/clientToken/selectedProfile/requestUser
- (void)refreshToBindProfile:(NSDictionary *)profileToSelect
                  accessToken:(NSString *)accessToken
                  clientToken:(NSString *)clientToken
                     callback:(Callback)callback {
    NSString *serverURL = self.authData[@"authserver"] ?: @"https://authserver.ely.by";
    if (![serverURL hasSuffix:@"/"]) {
        serverURL = [serverURL stringByAppendingString:@"/"];
    }
    NSString *refreshURL = [self buildRefreshURLForServer:serverURL];

    NSDictionary *data = @{
        @"accessToken": accessToken,
        @"clientToken": clientToken,
        @"selectedProfile": @{
            @"id": profileToSelect[@"id"],
            @"name": profileToSelect[@"name"]
        },
        @"requestUser": @YES
    };

    AFHTTPSessionManager *manager = AFHTTPSessionManager.manager;
    manager.requestSerializer = AFJSONRequestSerializer.serializer;

    NSLog(@"[ThirdPartyAuthenticator] refresh 绑定角色请求: %@", refreshURL);

    __weak typeof(self) weakSelf = self;
    [manager POST:refreshURL parameters:data headers:nil progress:nil success:^(NSURLSessionDataTask *task, NSDictionary *response) {
        @try {
            if (![response isKindOfClass:[NSDictionary class]] ||
                !response[@"accessToken"] || !response[@"clientToken"] ||
                !response[@"selectedProfile"]) {
                NSError *error = createError(@"绑定角色失败：服务器返回缺少 selectedProfile", 1020);
                callback(error, NO);
                return;
            }

            NSDictionary *boundProfile = response[@"selectedProfile"];
            // 校验绑定的角色与请求选择的角色一致
            if (![boundProfile[@"id"] isEqualToString:profileToSelect[@"id"]]) {
                NSError *error = createError(@"绑定角色失败：服务器返回的角色与请求不一致", 1021);
                callback(error, NO);
                return;
            }

            weakSelf.authData[@"accessToken"] = response[@"accessToken"];
            weakSelf.authData[@"clientToken"] = response[@"clientToken"];
            weakSelf.authData[@"username"] = boundProfile[@"name"];
            weakSelf.authData[@"uuid"] = boundProfile[@"id"];
            weakSelf.authData[@"profileId"] = boundProfile[@"id"];

            // 格式化 UUID（补连字符）
            NSString *uuid = boundProfile[@"id"];
            if (uuid.length == 32) {
                weakSelf.authData[@"profileId"] = [NSString stringWithFormat:@"%@-%@-%@-%@-%@",
                    [uuid substringWithRange:NSMakeRange(0, 8)],
                    [uuid substringWithRange:NSMakeRange(8, 4)],
                    [uuid substringWithRange:NSMakeRange(12, 4)],
                    [uuid substringWithRange:NSMakeRange(16, 4)],
                    [uuid substringWithRange:NSMakeRange(20, 12)]
                ];
            }

            // 异步获取头像（与单角色路径一致）
            [weakSelf fetchProfileTextureWithCallback:callback];
        } @catch (NSException *exception) {
            NSError *error = createError([NSString stringWithFormat:@"解析 refresh 响应异常: %@", exception.reason], 1022);
            callback(error, NO);
        }
    } failure:^(NSURLSessionDataTask *task, NSError *error) {
        NSString *errMsg = [self parseErrorMessageFromError:error];
        NSError *callbackError = createError(errMsg ?: @"绑定角色失败", 1023);
        callback(callbackError, NO);
    }];
}

/// 异步获取角色纹理并设置头像 URL，完成后触发 callback
- (void)fetchProfileTextureWithCallback:(Callback)callback {
    NSString *serverURL = self.authData[@"authserver"] ?: @"https://authserver.ely.by";
    if (![serverURL hasSuffix:@"/"]) {
        serverURL = [serverURL stringByAppendingString:@"/"];
    }

    AFHTTPSessionManager *manager = AFHTTPSessionManager.manager;
    manager.requestSerializer = AFJSONRequestSerializer.serializer;
    NSString *profileURL = [NSString stringWithFormat:@"%@sessionserver/session/minecraft/profile/%@", serverURL, self.authData[@"profileId"]];

    __weak typeof(self) weakSelf = self;
    [manager GET:profileURL parameters:nil headers:nil progress:nil success:^(NSURLSessionDataTask *task, NSDictionary *response) {
        if (response[@"properties"] && [response[@"properties"] isKindOfClass:[NSArray class]]) {
            NSArray *properties = response[@"properties"];
            for (NSDictionary *property in properties) {
                if ([property[@"name"] isEqualToString:@"textures"]) {
                    NSString *textures = property[@"value"];
                    NSData *decodedData = [[NSData alloc] initWithBase64EncodedString:textures options:0];
                    if (decodedData) {
                        NSError *error = nil;
                        NSDictionary *texturesDict = [NSJSONSerialization JSONObjectWithData:decodedData options:kNilOptions error:&error];
                        if (texturesDict && !error) {
                            NSString *skinURL = texturesDict[@"textures"][@"SKIN"][@"url"];
                            if (skinURL) {
                                NSString *headURL = [skinURL stringByReplacingOccurrencesOfString:@".png" withString:@"/helm.png"];
                                weakSelf.authData[@"profilePicURL"] = headURL;
                                [weakSelf saveChanges];
                                callback(nil, YES);
                                return;
                            }
                        }
                    }
                }
            }
        }
        weakSelf.authData[@"profilePicURL"] = [NSString stringWithFormat:@"https://mc-heads.net/avatar/%@/100", weakSelf.authData[@"username"]];
        [weakSelf saveChanges];
        callback(nil, YES);
    } failure:^(NSURLSessionDataTask *task, NSError *error) {
        weakSelf.authData[@"profilePicURL"] = [NSString stringWithFormat:@"https://mc-heads.net/avatar/%@/100", weakSelf.authData[@"username"]];
        [weakSelf saveChanges];
        callback(nil, YES);
    }];
}

/// 从 AFNetworking 错误中解析 Yggdrasil 服务器返回的 errorMessage
- (NSString *)parseErrorMessageFromError:(NSError *)error {
    NSData *data = error.userInfo[AFNetworkingOperationFailingURLResponseDataErrorKey];
    if (data) {
        NSDictionary *json = [NSJSONSerialization JSONObjectWithData:data options:kNilOptions error:nil];
        if (json) {
            NSString *msg = json[@"errorMessage"] ?: json[@"error"];
            if (msg.length > 0) return msg;
        }
    }
    return error.localizedDescription;
}

- (void)sendAuthenticateRequest:(NSDictionary *)data manager:(AFHTTPSessionManager *)manager callback:(Callback)callback {
    // Get server URL from authData or use default Ely.by server
    NSString *serverURL = self.authData[@"authserver"] ?: @"https://authserver.ely.by";
    // Ensure serverURL ends with a slash for consistency
    if (![serverURL hasSuffix:@"/"]) {
        serverURL = [serverURL stringByAppendingString:@"/"];
    }
    NSString *authURL = [self buildAuthURLForServer:serverURL];
    
    NSLog(@"[ThirdPartyAuthenticator] Sending authentication request to %@", authURL);
    
    [manager POST:authURL parameters:data headers:nil progress:nil success:^(NSURLSessionDataTask *task, NSDictionary *response) {
        @try {
            NSLog(@"[ThirdPartyAuthenticator] Authentication success response received");
            
            // Handle successful response
            if (![response isKindOfClass:[NSDictionary class]]) {
                NSError *error = createError(localize(@"login.error.invalid_response", @"Invalid server response"), 1003);
                callback(error, NO);
                return;
            }
            
            if (!response[@"accessToken"] || !response[@"clientToken"]) {
                NSError *error = createError(localize(@"login.error.invalid_response", @"Invalid server response"), 1004);
                callback(error, NO);
                return;
            }

            // Yggdrasil 规范：当用户有且仅有一个角色时返回 selectedProfile；
            // 有多个角色时只返回 availableProfiles；无角色时两者都缺失。
            // 参照 HMCL：多角色场景下需要调用 refresh 把选定角色绑定到 token，
            // 否则 token 处于"无 profile"状态，游戏 join server 会失败。
            NSDictionary *selectedProfile = response[@"selectedProfile"];
            NSArray *availableProfiles = response[@"availableProfiles"];
            if (![availableProfiles isKindOfClass:[NSArray class]]) {
                availableProfiles = @[];
            }

            if (!selectedProfile && availableProfiles.count > 0) {
                // 多角色场景：先保存 token，再 refresh 绑定第一个角色
                // （HMCL 这里会弹出角色选择器；移动端简化为选第一个）
                NSString *accessToken = response[@"accessToken"];
                NSString *clientToken = response[@"clientToken"];
                NSDictionary *profileToSelect = availableProfiles[0];
                NSLog(@"[ThirdPartyAuthenticator] 多角色场景，refresh 绑定角色: %@", profileToSelect[@"name"]);
                [self refreshToBindProfile:profileToSelect
                                accessToken:accessToken
                                clientToken:clientToken
                                   callback:callback];
                return;
            }

            if (!selectedProfile) {
                // 有 token 但无任何角色：账户未创建游戏角色
                NSString *errMsg = @"该账户尚未创建游戏角色，请先在皮肤站创建角色后再登录";
                NSError *error = createError(errMsg, 1019);
                callback(error, NO);
                return;
            }

            self.authData[@"accessToken"] = response[@"accessToken"];
            self.authData[@"clientToken"] = response[@"clientToken"];
            self.authData[@"username"] = selectedProfile[@"name"];
            self.authData[@"uuid"] = selectedProfile[@"id"];
            self.authData[@"profileId"] = selectedProfile[@"id"];

            // Save information for authlib-injector
        self.authData[@"authserver"] = self.authData[@"authserver"] ?: @"https://authserver.ely.by";

            // Format UUID with hyphens
            NSString *uuid = selectedProfile[@"id"];
            if (uuid.length == 32) { // If UUID without hyphens
                self.authData[@"profileId"] = [NSString stringWithFormat:@"%@-%@-%@-%@-%@",
                    [uuid substringWithRange:NSMakeRange(0, 8)],
                    [uuid substringWithRange:NSMakeRange(8, 4)],
                    [uuid substringWithRange:NSMakeRange(12, 4)],
                    [uuid substringWithRange:NSMakeRange(16, 4)],
                    [uuid substringWithRange:NSMakeRange(20, 12)]
                ];
            }
            
            // 尝试使用Yggdrasil API获取头像
            NSString *serverURL = self.authData[@"authserver"] ?: @"https://authserver.ely.by";
            // 确保serverURL以斜杠结尾
            if (![serverURL hasSuffix:@"/"]) {
                serverURL = [serverURL stringByAppendingString:@"/"];
            }
            
            AFHTTPSessionManager *manager = AFHTTPSessionManager.manager;
            manager.requestSerializer = AFJSONRequestSerializer.serializer;
            NSString *profileURL = [NSString stringWithFormat:@"%@sessionserver/session/minecraft/profile/%@", serverURL, self.authData[@"profileId"]];
            
            // 保存当前的authData，以便在异步回调中使用
            __block NSMutableDictionary *localAuthData = [self.authData mutableCopy];
            __weak typeof(self) weakSelf = self;
            
            [manager GET:profileURL parameters:nil headers:nil progress:nil success:^(NSURLSessionDataTask *task, NSDictionary *response) {
                if (response[@"properties"] && [response[@"properties"] isKindOfClass:[NSArray class]]) {
                    NSArray *properties = response[@"properties"];
                    for (NSDictionary *property in properties) {
                        if ([property[@"name"] isEqualToString:@"textures"]) {
                            // 解析皮肤数据
                            NSString *textures = property[@"value"];
                            NSData *decodedData = [[NSData alloc] initWithBase64EncodedString:textures options:0];
                            if (decodedData) {
                                NSError *error = nil;
                                NSDictionary *texturesDict = [NSJSONSerialization JSONObjectWithData:decodedData options:kNilOptions error:&error];
                                if (texturesDict && !error) {
                                    // 获取皮肤URL
                                    NSString *skinURL = texturesDict[@"textures"][@"SKIN"][@"url"];
                                    if (skinURL) {
                                        // 设置头像URL为皮肤URL的头盔版本
                                        NSString *headURL = [skinURL stringByReplacingOccurrencesOfString:@".png" withString:@"/helm.png"];
                                        weakSelf.authData[@"profilePicURL"] = headURL;
                                        // 异步更新头像后再次保存，避免账户列表读到失效的占位 URL
                                        [weakSelf saveChanges];
                                        return;
                                    }
                                }
                            }
                        }
                    }
                }

                // 如果Yggdrasil API失败，使用 mc-heads.net 头像服务作为回退
                weakSelf.authData[@"profilePicURL"] = [NSString stringWithFormat:@"https://mc-heads.net/avatar/%@/100", weakSelf.authData[@"username"]];
                [weakSelf saveChanges];
            } failure:^(NSURLSessionDataTask *task, NSError *error) {
                // 如果请求失败，使用 mc-heads.net 头像服务作为回退
                weakSelf.authData[@"profilePicURL"] = [NSString stringWithFormat:@"https://mc-heads.net/avatar/%@/100", weakSelf.authData[@"username"]];
                [weakSelf saveChanges];
            }];

            // 设置默认头像，避免UI显示问题（异步获取真实皮肤URL后会覆盖并再次保存）
            self.authData[@"profilePicURL"] = [NSString stringWithFormat:@"https://mc-heads.net/avatar/%@/100", self.authData[@"username"]];

            // Token expiration time (24 hours)
            self.authData[@"expiresAt"] = @((long)[NSDate.date timeIntervalSince1970] + 86400);

            // Save changes
            callback(nil, [self saveChanges]);
        } @catch (NSException *exception) {
            NSLog(@"[ThirdPartyAuthenticator] Exception in login success: %@", exception);
            NSError *error = createError([NSString stringWithFormat:@"Error: %@", exception.reason], 1005);
            callback(error, NO);
        }
    } failure:^(NSURLSessionDataTask *task, NSError *error) {
        NSLog(@"[ThirdPartyAuthenticator] Authentication failed: %@", error);
        
        NSData *errorData = error.userInfo[AFNetworkingOperationFailingURLResponseDataErrorKey];
        NSHTTPURLResponse *response = error.userInfo[AFNetworkingOperationFailingURLResponseErrorKey];
        
        if (errorData) {
            @try {
                // Log error data for diagnostics
                NSString *rawErrorStr = [[NSString alloc] initWithData:errorData encoding:NSUTF8StringEncoding];
                NSLog(@"[ThirdPartyAuthenticator] Raw error data: %@", rawErrorStr);
                
                NSDictionary *errorDict = [NSJSONSerialization JSONObjectWithData:errorData options:kNilOptions error:nil];
                NSLog(@"[ThirdPartyAuthenticator] Error dictionary: %@", errorDict);
                
                // Check for two-factor authentication (status code 401 + specific error message)
                if (response.statusCode == 401 && 
                    [errorDict[@"error"] isEqualToString:@"ForbiddenOperationException"] &&
                    [errorDict[@"errorMessage"] isEqualToString:@"Account protected with two factor auth."]) {
                    
                    NSLog(@"[ThirdPartyAuthenticator] Two-factor authentication required");
                    
                    // Request TOTP code via UI
                    UIAlertController *alert = [UIAlertController 
                        alertControllerWithTitle:localize(@"login.3rdparty.2fa.title", @"Two-Factor Authentication")
                        message:localize(@"login.3rdparty.2fa.message", @"Please enter your two-factor authentication code")
                        preferredStyle:UIAlertControllerStyleAlert];
                    
                    [alert addTextFieldWithConfigurationHandler:^(UITextField *textField) {
                        textField.placeholder = localize(@"login.3rdparty.2fa.code", @"Authentication code");
                        textField.keyboardType = UIKeyboardTypeNumberPad;
                    }];
                    
                    UIAlertAction *okAction = [UIAlertAction 
                        actionWithTitle:localize(@"OK", @"OK") 
                        style:UIAlertActionStyleDefault 
                        handler:^(UIAlertAction *action) {
                            NSString *code = alert.textFields.firstObject.text;
                            if (code.length > 0) {
                                [self loginWithTwoFactorToken:code callback:callback];
                            } else {
                                NSError *codeError = createError(localize(@"login.3rdparty.2fa.empty", @"Authentication code cannot be empty"), 1006);
                                callback(codeError, NO);
                            }
                        }];
                    
                    UIAlertAction *cancelAction = [UIAlertAction 
                        actionWithTitle:localize(@"Cancel", @"Cancel") 
                        style:UIAlertActionStyleCancel 
                        handler:^(UIAlertAction *action) {
                            NSError *cancelError = createError(localize(@"login.cancelled", @"Login cancelled"), 1007);
                            callback(cancelError, NO);
                        }];
                    
                    [alert addAction:okAction];
                    [alert addAction:cancelAction];
                    
                    // Get ViewController to present alert
                    UIViewController *rootVC = nil;
                    UIWindow *keyWindow = [UIApplication sharedApplication].delegate.window;
                    if (!keyWindow) {
                        // Fallback for iOS 13+ scene-based apps
                        for (UIWindowScene *windowScene in [UIApplication sharedApplication].connectedScenes) {
                            if (windowScene.activationState == UISceneActivationStateForegroundActive) {
                                keyWindow = windowScene.windows.firstObject;
                                break;
                            }
                        }
                        // If no active scene, use the first available window
                        if (!keyWindow && [UIApplication sharedApplication].connectedScenes.count > 0) {
                            NSSet<UIScene *> *scenes = [UIApplication sharedApplication].connectedScenes;
                            if (scenes.count > 0) {
                                UIWindowScene *firstScene = (UIWindowScene *)[scenes anyObject];
                                if (firstScene.windows.count > 0) {
                                    keyWindow = firstScene.windows.firstObject;
                                }
                            }
                        }
                    }
                    if (keyWindow) {
                        rootVC = keyWindow.rootViewController;
                    }
                    
                    if (rootVC) {
                        [rootVC presentViewController:alert animated:YES completion:nil];
                    } else {
                        NSLog(@"[ThirdPartyAuthenticator] Error: Could not find root view controller to present 2FA alert");
                        NSError *viewError = createError(@"Internal error: Could not present 2FA dialog", 1008);
                        callback(viewError, NO);
                    }
                    return;
                } else if (response.statusCode == 401 && [errorDict[@"error"] isEqualToString:@"ForbiddenOperationException"]) {
                    // Check for specific error for invalid credentials
                    if ([errorDict[@"errorMessage"] isEqualToString:@"Invalid credentials. Invalid username or password."]) {
                        NSError *invalidCredentialsError = createError(localize(@"login.error.invalid_credentials", @"Invalid username or password"), 1020);
                        callback(invalidCredentialsError, NO);
                        return;
                    }
                }
                
                NSString *errorMessage = errorDict[@"errorMessage"] ?: error.localizedDescription;
                NSError *customError = createError(errorMessage, 1009);
                callback(customError, NO);
            } @catch (NSException *exception) {
                NSLog(@"[ThirdPartyAuthenticator] Exception while processing error: %@", exception);
                NSError *exceptionError = createError(error.localizedDescription, 1010);
                callback(exceptionError, NO);
            }
        } else {
            NSError *networkError = createError(error.localizedDescription, 1011);
            callback(networkError, NO);
        }
    }];
}

- (void)loginWithCallback:(Callback)callback {
    // First check/download authlib-injector
    [self ensureAuthlibInjectorWithCompletion:^(BOOL success, NSError *error) {
        if (!success) {
            callback(error, NO);
            return;
        }
        
        // Continue authentication process
        callback(createError(localize(@"login.3rdparty.progress.auth", nil), 0), YES);
        
        NSString *username = self.authData[@"input"];
        NSString *password = self.authData[@"password"];
        
        if (username.length == 0 || password.length == 0) {
            NSError *fieldsError = createError(localize(@"login.error.fields.empty", nil), 1002);
            callback(fieldsError, NO);
            return;
        }
        
        NSDictionary *data = @{
            @"agent": @{@"name": @"Minecraft", @"version": @1},
            @"username": username,
            @"password": password,
            @"clientToken": [[NSUUID UUID] UUIDString],
            @"requestUser": @YES
        };
        
        AFHTTPSessionManager *manager = AFHTTPSessionManager.manager;
        manager.requestSerializer = AFJSONRequestSerializer.serializer;
        
        [self sendAuthenticateRequest:data manager:manager callback:callback];
    }];
}

- (void)refreshTokenWithCallback:(Callback)callback {
    // First check/download authlib-injector
    [self ensureAuthlibInjectorWithCompletion:^(BOOL success, NSError *error) {
        if (!success) {
            callback(error, NO);
            return;
        }
        
        callback(createError(localize(@"login.3rdparty.progress.refresh", nil), 0), YES);
        
        NSString *accessToken = self.authData[@"accessToken"];
        NSString *clientToken = self.authData[@"clientToken"];
        
        if (accessToken.length == 0 || clientToken.length == 0) {
            NSError *tokenError = createError(localize(@"login.error.token_missing", @"Access token or client token is missing"), 1012);
            callback(tokenError, NO);
            return;
        }
        
        NSDictionary *data = @{
            @"accessToken": accessToken,
            @"clientToken": clientToken,
            @"requestUser": @YES
        };
        
        AFHTTPSessionManager *manager = AFHTTPSessionManager.manager;
        manager.requestSerializer = AFJSONRequestSerializer.serializer;
        
        NSString *serverURL = self.authData[@"authserver"] ?: @"https://authserver.ely.by";
        // Ensure serverURL ends with a slash for consistency
        if (![serverURL hasSuffix:@"/"]) {
            serverURL = [serverURL stringByAppendingString:@"/"];
        }
        NSString *refreshURL = [self buildRefreshURLForServer:serverURL];
        
        [manager POST:refreshURL parameters:data headers:nil progress:nil success:^(NSURLSessionDataTask *task, NSDictionary *response) {
            @try {
                // Update tokens
                if (![response isKindOfClass:[NSDictionary class]] || !response[@"accessToken"] || !response[@"clientToken"]) {
                    NSError *invalidError = createError(localize(@"login.error.invalid_response", @"Invalid server response"), 1013);
                    callback(invalidError, NO);
                    return;
                }
                
                self.authData[@"accessToken"] = response[@"accessToken"];
                self.authData[@"clientToken"] = response[@"clientToken"];
                
                // Update selectedProfile if present
                if (response[@"selectedProfile"]) {
                    self.authData[@"username"] = response[@"selectedProfile"][@"name"];
                    self.authData[@"uuid"] = response[@"selectedProfile"][@"id"];
                    
                    // Format UUID with hyphens if needed
                    NSString *uuid = response[@"selectedProfile"][@"id"];
                    if (uuid.length == 32) { // If UUID without hyphens
                        self.authData[@"profileId"] = [NSString stringWithFormat:@"%@-%@-%@-%@-%@",
                            [uuid substringWithRange:NSMakeRange(0, 8)],
                            [uuid substringWithRange:NSMakeRange(8, 4)],
                            [uuid substringWithRange:NSMakeRange(12, 4)],
                            [uuid substringWithRange:NSMakeRange(16, 4)],
                            [uuid substringWithRange:NSMakeRange(20, 12)]
                        ];
                    } else {
                        self.authData[@"profileId"] = uuid;
                    }
                    
                    // 尝试使用Yggdrasil API获取头像
                    NSString *serverURL = self.authData[@"authserver"] ?: @"https://authserver.ely.by";
                    // 确保serverURL以斜杠结尾
                    if (![serverURL hasSuffix:@"/"]) {
                        serverURL = [serverURL stringByAppendingString:@"/"];
                    }
                    
                    AFHTTPSessionManager *manager = AFHTTPSessionManager.manager;
                    manager.requestSerializer = AFJSONRequestSerializer.serializer;
                    NSString *profileURL = [NSString stringWithFormat:@"%@sessionserver/session/minecraft/profile/%@", serverURL, self.authData[@"profileId"]];
                    
                    // 保存当前的authData，以便在异步回调中使用
                    __block NSMutableDictionary *localAuthData = [self.authData mutableCopy];
                    __weak typeof(self) weakSelf = self;
                    
                    [manager GET:profileURL parameters:nil headers:nil progress:nil success:^(NSURLSessionDataTask *task, NSDictionary *response) {
                        if (response[@"properties"] && [response[@"properties"] isKindOfClass:[NSArray class]]) {
                            NSArray *properties = response[@"properties"];
                            for (NSDictionary *property in properties) {
                                if ([property[@"name"] isEqualToString:@"textures"]) {
                                    // 解析皮肤数据
                                    NSString *textures = property[@"value"];
                                    NSData *decodedData = [[NSData alloc] initWithBase64EncodedString:textures options:0];
                                    if (decodedData) {
                                        NSError *error = nil;
                                        NSDictionary *texturesDict = [NSJSONSerialization JSONObjectWithData:decodedData options:kNilOptions error:&error];
                                        if (texturesDict && !error) {
                                            // 获取皮肤URL
                                            NSString *skinURL = texturesDict[@"textures"][@"SKIN"][@"url"];
                                            if (skinURL) {
                                                // 设置头像URL为皮肤URL的头盔版本
                                                NSString *headURL = [skinURL stringByReplacingOccurrencesOfString:@".png" withString:@"/helm.png"];
                                                weakSelf.authData[@"profilePicURL"] = headURL;
                                                // 异步更新头像后再次保存，避免账户列表读到失效的占位 URL
                                                [weakSelf saveChanges];
                                                return;
                                            }
                                        }
                                    }
                                }
                            }
                        }

                        // 如果Yggdrasil API失败，使用 mc-heads.net 头像服务作为回退
                        weakSelf.authData[@"profilePicURL"] = [NSString stringWithFormat:@"https://mc-heads.net/avatar/%@/100", weakSelf.authData[@"username"]];
                        [weakSelf saveChanges];
                    } failure:^(NSURLSessionDataTask *task, NSError *error) {
                        // 如果请求失败，使用 mc-heads.net 头像服务作为回退
                        weakSelf.authData[@"profilePicURL"] = [NSString stringWithFormat:@"https://mc-heads.net/avatar/%@/100", weakSelf.authData[@"username"]];
                        [weakSelf saveChanges];
                    }];

                    // 设置默认头像，避免UI显示问题（异步获取真实皮肤URL后会覆盖并再次保存）
                    self.authData[@"profilePicURL"] = [NSString stringWithFormat:@"https://mc-heads.net/avatar/%@/100", self.authData[@"username"]];
                }
                
                // Token expiration time (24 hours)
                self.authData[@"expiresAt"] = @((long)[NSDate.date timeIntervalSince1970] + 86400);
                
                // Save changes
                callback(nil, [self saveChanges]);
            } @catch (NSException *exception) {
                NSLog(@"[ThirdPartyAuthenticator] Exception in refresh success: %@", exception);
                NSError *exceptionError = createError([NSString stringWithFormat:@"Error: %@", exception.reason], 1014);
                callback(exceptionError, NO);
            }
        } failure:^(NSURLSessionDataTask *task, NSError *error) {
            NSData *errorData = error.userInfo[AFNetworkingOperationFailingURLResponseDataErrorKey];
            if (errorData) {
                @try {
                    NSDictionary *errorDict = [NSJSONSerialization JSONObjectWithData:errorData options:kNilOptions error:nil];
                    
                    // Check for expired token error
                    if ([errorDict[@"error"] isEqualToString:@"ForbiddenOperationException"] && 
                        [errorDict[@"errorMessage"] isEqualToString:@"Token expired."]) {
                        NSError *expiredError = createError(localize(@"login.error.token_expired", @"Authentication token has expired, please log in again"), 1015);
                        callback(expiredError, NO);
                        return;
                    }
                    
                    NSString *errorMessage = errorDict[@"errorMessage"] ?: error.localizedDescription;
                    NSError *customError = createError(errorMessage, 1016);
                    callback(customError, NO);
                } @catch (NSException *exception) {
                    NSError *exceptionError = createError(error.localizedDescription, 1017);
                    callback(exceptionError, NO);
                }
            } else {
                NSError *networkError = createError(error.localizedDescription, 1018);
                callback(networkError, NO);
            }
        }];
    }];
}

@end