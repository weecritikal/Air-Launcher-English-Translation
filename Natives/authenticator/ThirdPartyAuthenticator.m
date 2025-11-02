#import "AFNetworking.h"
#import "ThirdPartyAuthenticator.h"
#import "../ios_uikit_bridge.h"
#import "../utils.h"

// URL for downloading authlib-injector
#define AUTHLIB_INJECTOR_URL @"https://bmclapi2.bangbang93.com/mirrors/authlib-injector/artifact/54/authlib-injector-1.2.6.jar"
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
    NSString *dirPath = [NSString stringWithFormat:@"%s/authlib-injector", getenv("POJAV_HOME")];
    NSString *filePath = [self getAuthlibInjectorPath];
    
    // Create directory if it doesn't exist
    NSError *error;
    [[NSFileManager defaultManager] createDirectoryAtPath:dirPath withIntermediateDirectories:YES attributes:nil error:&error];
    if (error) {
        completion(NO, error);
        return;
    }
    
    // Download authlib-injector file
    NSURLSessionConfiguration *configuration = [NSURLSessionConfiguration defaultSessionConfiguration];
    AFURLSessionManager *manager = [[AFURLSessionManager alloc] initWithSessionConfiguration:configuration];
    
    NSURL *URL = [NSURL URLWithString:AUTHLIB_INJECTOR_URL];
    NSURLRequest *request = [NSURLRequest requestWithURL:URL];
    
    NSURLSessionDownloadTask *downloadTask = [manager downloadTaskWithRequest:request progress:nil destination:^NSURL *(NSURL *targetPath, NSURLResponse *response) {
        return [NSURL fileURLWithPath:filePath];
    } completionHandler:^(NSURLResponse *response, NSURL *filePath, NSError *error) {
        if (error) {
            completion(NO, error);
        } else {
            completion(YES, nil);
        }
    }];
    [downloadTask resume];
}

- (void)ensureAuthlibInjectorWithCompletion:(void (^)(BOOL success, NSError *error))completion {
    if ([self isAuthlibInjectorDownloaded]) {
        completion(YES, nil);
    } else {
        NSLog(@"[ThirdPartyAuthenticator] Downloading authlib-injector from %@", AUTHLIB_INJECTOR_URL);
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
        @"username": username,
        @"password": passwordWithToken,
        @"clientToken": [[NSUUID UUID] UUIDString]
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
            
            if (!response[@"accessToken"] || !response[@"clientToken"] || !response[@"selectedProfile"]) {
                NSError *error = createError(localize(@"login.error.invalid_response", @"Invalid server response"), 1004);
                callback(error, NO);
                return;
            }
            
            self.authData[@"accessToken"] = response[@"accessToken"];
            self.authData[@"clientToken"] = response[@"clientToken"];
            self.authData[@"username"] = response[@"selectedProfile"][@"name"];
            self.authData[@"uuid"] = response[@"selectedProfile"][@"id"];
            self.authData[@"profileId"] = response[@"selectedProfile"][@"id"];
            
            // Save information for authlib-injector
        self.authData[@"authserver"] = self.authData[@"authserver"] ?: @"https://authserver.ely.by";
            
            // Format UUID with hyphens
            NSString *uuid = response[@"selectedProfile"][@"id"];
            if (uuid.length == 32) { // If UUID without hyphens
                self.authData[@"profileId"] = [NSString stringWithFormat:@"%@-%@-%@-%@-%@",
                    [uuid substringWithRange:NSMakeRange(0, 8)],
                    [uuid substringWithRange:NSMakeRange(8, 4)],
                    [uuid substringWithRange:NSMakeRange(12, 4)],
                    [uuid substringWithRange:NSMakeRange(16, 4)],
                    [uuid substringWithRange:NSMakeRange(20, 12)]
                ];
            }
            
            // Set avatar URL based on server
            NSString *serverURL = self.authData[@"authserver"] ?: @"https://authserver.ely.by";
            if ([serverURL rangeOfString:@"ely.by"].location != NSNotFound) {
                self.authData[@"profilePicURL"] = [NSString stringWithFormat:@"https://skin.ely.by/helm/%@/120", self.authData[@"profileId"]];
            } else if ([serverURL rangeOfString:@"mcskin.com.cn"].location != NSNotFound) {
                // Redstone skin station uses different format
                self.authData[@"profilePicURL"] = [NSString stringWithFormat:@"https://mcskin.com.cn/skin/%@.png", self.authData[@"profileId"]];
            } else {
                // For other servers, try to construct a generic URL or use a default
                self.authData[@"profilePicURL"] = [NSString stringWithFormat:@"https://crafatar.com/avatars/%@?overlay", self.authData[@"profileId"]];
            }
            
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
            @"username": username,
            @"password": password,
            @"clientToken": [[NSUUID UUID] UUIDString]
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
            @"clientToken": clientToken
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
                    
                    // Update avatar URL based on server
                    NSString *serverURL = self.authData[@"authserver"] ?: @"https://authserver.ely.by";
                    if ([serverURL rangeOfString:@"ely.by"].location != NSNotFound) {
                        self.authData[@"profilePicURL"] = [NSString stringWithFormat:@"https://skin.ely.by/helm/%@/120", self.authData[@"profileId"]];
                    } else if ([serverURL rangeOfString:@"mcskin.com.cn"].location != NSNotFound) {
                        // Redstone skin station uses different format
                        self.authData[@"profilePicURL"] = [NSString stringWithFormat:@"https://mcskin.com.cn/skin/%@.png", self.authData[@"profileId"]];
                    } else {
                        // For other servers, try to construct a generic URL or use a default
                        self.authData[@"profilePicURL"] = [NSString stringWithFormat:@"https://crafatar.com/avatars/%@?overlay", self.authData[@"profileId"]];
                    }
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