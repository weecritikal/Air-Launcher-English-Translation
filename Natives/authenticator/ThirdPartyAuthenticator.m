#import "AFNetworking.h"
#import "ThirdPartyAuthenticator.h"
#import "../ios_uikit_bridge.h"
#import "../utils.h"

// authlib-injector download sources: the BMCLAPI mirror first, falling back to the official source on failure
// Fix: upgraded from 1.2.6 to 1.2.7 (build 55); 1.2.7 fixes the Java 25 compatibility problem.
// Note: 26.x launches with Java 21 by default (Mojang metadata javaVersion.majorVersion=21),
// but if the user explicitly sets javaVersion=25 for 26.x in PLProfiles, 26.x uses Java 25,
// and then the ASM bytecode processing of authlib-injector 1.2.6 cannot recognize Java 25 class file version 69,
// so the javaagent fails to load and the game will not start. After the upgrade to 1.2.7, Java 17/21/25 are all supported.
// Also: authlib-injector 1.2.7's Java 25 support is used by the execute_jar path as well
// (some mod installer JARs, for example, target Java 25).
// The project's own host is tried first and the mirror only as a fallback. The order used
// to be reversed, so every third-party login went to a mainland-China mirror first.
#define AUTHLIB_INJECTOR_URL_UPSTREAM @"https://authlib-injector.yushi.moe/artifact/55/authlib-injector-1.2.7.jar"
#define AUTHLIB_INJECTOR_URL_MIRROR   @"https://bmclapi2.bangbang93.com/mirrors/authlib-injector/artifact/55/authlib-injector-1.2.7.jar"
#define AUTHLIB_INJECTOR_FILE @"authlib-injector.jar"
#define AUTHLIB_INJECTOR_VERSION @"1.2.7"
#define AUTHLIB_INJECTOR_VERSION_FILE @"authlib-injector.version"

// Helper function to create NSError
static NSError* createError(NSString *message, NSInteger code) {
    return [NSError errorWithDomain:@"ThirdPartyAuthenticator" 
                            code:code 
                        userInfo:@{NSLocalizedDescriptionKey: message}];
}

@implementation ThirdPartyAuthenticator

+ (void)resolveAuthserverURL:(NSString *)inputURL
                  completion:(void (^)(NSString *resolvedURL, NSString *_Nullable metadata))completion {
    if (inputURL.length == 0) {
        if (completion) completion(inputURL, nil);
        return;
    }

    // 1. Add HTTPS when the scheme is missing (the specification forbids downgrading to HTTP)
    NSString *urlStr = inputURL;
    if (![urlStr hasPrefix:@"http://"] && ![urlStr hasPrefix:@"https://"]) {
        urlStr = [@"https://" stringByAppendingString:urlStr];
    }

    NSURL *url = [NSURL URLWithString:urlStr];
    if (!url || !url.scheme || !url.host) {
        // Invalid URL, so fall back to returning the original input
        if (completion) completion(inputURL, nil);
        return;
    }

    // 2. Send a GET request to that URL and check the X-Authlib-Injector-API-Location response header
    NSURLSessionConfiguration *config = [NSURLSessionConfiguration defaultSessionConfiguration];
    config.timeoutIntervalForRequest = 15;
    config.timeoutIntervalForResource = 30;
    // Allow redirects to be followed (302 hops such as GitHub releases)
    config.HTTPShouldUsePipelining = YES;
    NSURLSession *session = [NSURLSession sessionWithConfiguration:config];

    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:url];
    request.HTTPMethod = @"GET";
    // Do not cache, so the ALI header is not swallowed by a caching layer
    request.cachePolicy = NSURLRequestReloadIgnoringLocalCacheData;

    __block NSString *resolvedURL = urlStr;
    __block NSString *metadata = nil;

    NSURLSessionDataTask *task = [session dataTaskWithRequest:request
        completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
            if (error) {
                NSLog(@"[ThirdPartyAuthenticator] ALI resolution failed: %@", error.localizedDescription);
                // Fall back to the original URL if resolution fails; login can still be attempted
                dispatch_async(dispatch_get_main_queue(), ^{
                    if (completion) completion(inputURL, nil);
                });
                return;
            }

            NSHTTPURLResponse *httpResponse = (NSHTTPURLResponse *)response;
            if ([httpResponse isKindOfClass:[NSHTTPURLResponse class]]) {
                // 3. Check the ALI header
                NSString *ali = httpResponse.allHeaderFields[@"X-Authlib-Injector-API-Location"];
                if (ali.length > 0) {
                    // Resolve the ALI into an absolute URL
                    NSURL *aliURL = [NSURL URLWithString:ali relativeToURL:httpResponse.URL];
                    if (aliURL) {
                        // If the ALI does not point at itself, update resolvedURL
                        NSString *aliStr = aliURL.absoluteString;
                        if (![aliStr isEqualToString:httpResponse.URL.absoluteString]) {
                            NSLog(@"[ThirdPartyAuthenticator] ALI redirect: %@ -> %@", urlStr, aliStr);
                            resolvedURL = aliStr;
                            // The ALI points at a new address, so the metadata must be requested again
                            [self fetchMetadataFromURL:aliURL completion:completion originalInput:inputURL];
                            return;
                        }
                    }
                }
            }

            // 4. No ALI header, or the ALI points at itself: the current URL is the API root, so reuse the response body as the metadata
            if (data.length > 0) {
                metadata = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
                // Check that it is valid JSON (the metadata must be JSON)
                if (metadata) {
                    NSData *check = [NSJSONSerialization JSONObjectWithData:data
                                                                   options:kNilOptions
                                                                     error:nil] ? data : nil;
                    if (!check) {
                        NSLog(@"[ThirdPartyAuthenticator] Response body is not valid JSON, discarding metadata");
                        metadata = nil;
                    }
                }
            }

            // Normalize: make sure it ends with a slash (matching how buildAuthURLForServer handles it)
            if (![resolvedURL hasSuffix:@"/"]) {
                resolvedURL = [resolvedURL stringByAppendingString:@"/"];
            }

            NSLog(@"[ThirdPartyAuthenticator] ALI resolution complete: %@ (metadata=%@)", resolvedURL, metadata ? @"YES" : @"NO");
            dispatch_async(dispatch_get_main_queue(), ^{
                if (completion) completion(resolvedURL, metadata);
            });
        }];
    [task resume];
}

/// Helper method: fetch the server metadata from a given URL (the second request after an ALI redirect)
+ (void)fetchMetadataFromURL:(NSURL *)url
                  completion:(void (^)(NSString *, NSString *_Nullable))completion
               originalInput:(NSString *)originalInput {
    NSURLSessionConfiguration *config = [NSURLSessionConfiguration defaultSessionConfiguration];
    config.timeoutIntervalForRequest = 15;
    NSURLSession *session = [NSURLSession sessionWithConfiguration:config];

    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:url];
    request.HTTPMethod = @"GET";
    request.cachePolicy = NSURLRequestReloadIgnoringLocalCacheData;

    NSURLSessionDataTask *task = [session dataTaskWithRequest:request
        completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
            NSString *resolvedURL = url.absoluteString;
            NSString *metadata = nil;

            if (error) {
                NSLog(@"[ThirdPartyAuthenticator] Metadata secondary request failed: %@", error.localizedDescription);
            } else if (data.length > 0) {
                metadata = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
                // Check that the JSON is valid
                if (![NSJSONSerialization JSONObjectWithData:data options:kNilOptions error:nil]) {
                    NSLog(@"[ThirdPartyAuthenticator] Secondary response body is not valid JSON, discarding metadata");
                    metadata = nil;
                }
            }

            if (![resolvedURL hasSuffix:@"/"]) {
                resolvedURL = [resolvedURL stringByAppendingString:@"/"];
            }

            NSLog(@"[ThirdPartyAuthenticator] Metadata secondary request complete: %@ (metadata=%@)", resolvedURL, metadata ? @"YES" : @"NO");
            dispatch_async(dispatch_get_main_queue(), ^{
                if (completion) completion(resolvedURL, metadata);
            });
        }];
    [task resume];
}

- (NSString *)getAuthlibInjectorPath {
    NSString *path = [NSString stringWithFormat:@"%s/authlib-injector/%@", getenv("POJAV_HOME"), AUTHLIB_INJECTOR_FILE];
    return path;
}

- (NSString *)getAuthlibInjectorVersionPath {
    NSString *path = [NSString stringWithFormat:@"%s/authlib-injector/%@", getenv("POJAV_HOME"), AUTHLIB_INJECTOR_VERSION_FILE];
    return path;
}

- (BOOL)isAuthlibInjectorDownloaded {
    NSString *path = [self getAuthlibInjectorPath];
    if (![[NSFileManager defaultManager] fileExistsAtPath:path]) {
        return NO;
    }
    // Version check: the already downloaded jar version must match the currently expected version
    // Fix: the old 1.2.6 jar is incompatible with Java 25, so it must be upgraded to 1.2.7
    NSString *versionPath = [self getAuthlibInjectorVersionPath];
    NSString *downloadedVersion = [NSString stringWithContentsOfFile:versionPath encoding:NSUTF8StringEncoding error:nil];
    if (downloadedVersion.length == 0 || ![downloadedVersion isEqualToString:AUTHLIB_INJECTOR_VERSION]) {
        NSLog(@"[ThirdPartyAuthenticator] authlib-injector version outdated (current: %@, required: %@), needs re-download",
              downloadedVersion.length > 0 ? downloadedVersion : @"unknown", AUTHLIB_INJECTOR_VERSION);
        return NO;
    }
    return YES;
}

/// Save the version marker after a successful download
- (void)saveAuthlibInjectorVersion {
    NSString *versionPath = [self getAuthlibInjectorVersionPath];
    [AUTHLIB_INJECTOR_VERSION writeToFile:versionPath atomically:YES encoding:NSUTF8StringEncoding error:nil];
}

- (void)downloadAuthlibInjector:(void (^)(BOOL success, NSError *error))completion {
    [self downloadAuthlibInjectorFromURL:AUTHLIB_INJECTOR_URL_UPSTREAM attempt:1 completion:completion];
}

/// Try the download sources one by one: fall back to the official GitHub source after BMCLAPI fails
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
    // NSMutableURLRequest is used so redirects can be followed (GitHub releases responds with a 302)
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:URL];
    request.HTTPShouldUsePipelining = YES;

    NSLog(@"[ThirdPartyAuthenticator] Attempting to download authlib-injector (source %ld): %@", (long)attempt, urlString);

    NSURLSessionDownloadTask *downloadTask = [manager downloadTaskWithRequest:request progress:nil destination:^NSURL *(NSURL *targetPath, NSURLResponse *response) {
        return [NSURL fileURLWithPath:filePath];
    } completionHandler:^(NSURLResponse *response, NSURL *filePath, NSError *error) {
        if (error) {
            NSLog(@"[ThirdPartyAuthenticator] Download failed (source %ld): %@", (long)attempt, error.localizedDescription);
            // Try the official GitHub source after BMCLAPI fails
            if (attempt == 1) {
                [self downloadAuthlibInjectorFromURL:AUTHLIB_INJECTOR_URL_MIRROR attempt:2 completion:completion];
            } else {
                completion(NO, error);
            }
        } else {
            NSLog(@"[ThirdPartyAuthenticator] Download succeeded (source %ld)", (long)attempt);
            // Save the version marker for later version checks
            [self saveAuthlibInjectorVersion];
            completion(YES, nil);
        }
    }];
    [downloadTask resume];
}

- (void)ensureAuthlibInjectorWithCompletion:(void (^)(BOOL success, NSError *error))completion {
    if ([self isAuthlibInjectorDownloaded]) {
        completion(YES, nil);
    } else {
        NSLog(@"[ThirdPartyAuthenticator] Downloading authlib-injector (BMCLAPI preferred, falls back to GitHub)");
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

    NSMutableArray *args = [NSMutableArray arrayWithArray:@[jvmArg, @"-Dauthlibinjector.side=client"]];

    // Modeled on HMCL AuthlibInjectorAuthInfo: pass the prefetched metadata
    // The server metadata is base64 encoded and passed in via -Dauthlibinjector.yggdrasil.prefetched,
    // so the game does not have to request the server metadata again at runtime, making skin loading more reliable
    NSString *metadata = self.authData[@"prefetchedMetadata"];
    if (metadata.length > 0) {
        // Strip superfluous whitespace from the JSON (the specification calls for the compact form, which also shortens the argument)
        NSData *jsonData = [metadata dataUsingEncoding:NSUTF8StringEncoding];
        NSError *jsonError = nil;
        id jsonObj = [NSJSONSerialization JSONObjectWithData:jsonData options:kNilOptions error:&jsonError];
        if (jsonObj && !jsonError) {
            NSData *compactData = [NSJSONSerialization dataWithJSONObject:jsonObj
                                                                  options:NSJSONWritingSortedKeys | NSJSONWritingWithoutEscapingSlashes
                                                                    error:nil];
            if (compactData) {
                NSString *compactStr = [[NSString alloc] initWithData:compactData encoding:NSUTF8StringEncoding];
                NSString *base64 = [[compactStr dataUsingEncoding:NSUTF8StringEncoding] base64EncodedStringWithOptions:0];
                if (base64.length > 0) {
                    NSString *prefetchedArg = [NSString stringWithFormat:@"-Dauthlibinjector.yggdrasil.prefetched=%@", base64];
                    [args addObject:prefetchedArg];
                    NSLog(@"[ThirdPartyAuthenticator] Added prefetched metadata parameter (length=%lu)", (unsigned long)base64.length);
                }
            }
        } else {
            NSLog(@"[ThirdPartyAuthenticator] Prefetched metadata JSON parse failed, skipping parameter");
        }
    } else {
        // The metadata was not cached at login time, so try to fetch it on the spot (synchronously, potentially blocking; only a fallback)
        NSLog(@"[ThirdPartyAuthenticator] No cached metadata, attempting on-the-fly fetch");
        [self fetchMetadataSynchronouslyForServerURL:serverURL];
        NSString *cachedMeta = self.authData[@"prefetchedMetadata"];
        if (cachedMeta.length > 0) {
            NSData *jsonData = [cachedMeta dataUsingEncoding:NSUTF8StringEncoding];
            id jsonObj = [NSJSONSerialization JSONObjectWithData:jsonData options:kNilOptions error:nil];
            if (jsonObj) {
                NSData *compactData = [NSJSONSerialization dataWithJSONObject:jsonObj
                                                                      options:NSJSONWritingSortedKeys | NSJSONWritingWithoutEscapingSlashes
                                                                        error:nil];
                if (compactData) {
                    NSString *compactStr = [[NSString alloc] initWithData:compactData encoding:NSUTF8StringEncoding];
                    NSString *base64 = [[compactStr dataUsingEncoding:NSUTF8StringEncoding] base64EncodedStringWithOptions:0];
                    if (base64.length > 0) {
                        NSString *prefetchedArg = [NSString stringWithFormat:@"-Dauthlibinjector.yggdrasil.prefetched=%@", base64];
                        [args addObject:prefetchedArg];
                        NSLog(@"[ThirdPartyAuthenticator] Added on-the-fly fetched prefetched metadata parameter");
                    }
                }
            }
        }
    }

    return args;
}

/// Fetch the server metadata synchronously and cache it in authData (a fallback for getJvmArgsForAuthlib)
- (void)fetchMetadataSynchronouslyForServerURL:(NSString *)serverURL {
    if (serverURL.length == 0) return;
    NSString *urlStr = serverURL;
    if (![urlStr hasSuffix:@"/"]) {
        urlStr = [urlStr stringByAppendingString:@"/"];
    }
    // The metadata is fetched with a plain GET on the API root
    NSURL *url = [NSURL URLWithString:urlStr];
    if (!url) return;

    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:url];
    request.HTTPMethod = @"GET";
    request.timeoutInterval = 10;

    NSError *requestError = nil;
    NSHTTPURLResponse *response = nil;
    NSData *data = [NSURLConnection sendSynchronousRequest:request
                                         returningResponse:&response
                                                     error:&requestError];
    if (requestError || !data || data.length == 0) {
        NSLog(@"[ThirdPartyAuthenticator] On-the-fly metadata fetch failed: %@", requestError.localizedDescription);
        return;
    }

    // Check that the JSON is valid
    id jsonObj = [NSJSONSerialization JSONObjectWithData:data options:kNilOptions error:nil];
    if (!jsonObj) {
        NSLog(@"[ThirdPartyAuthenticator] On-the-fly fetched metadata is not valid JSON");
        return;
    }

    // Check the ALI header, and make a second request if it points elsewhere
    if ([response isKindOfClass:[NSHTTPURLResponse class]]) {
        NSString *ali = response.allHeaderFields[@"X-Authlib-Injector-API-Location"];
        if (ali.length > 0) {
            NSURL *aliURL = [NSURL URLWithString:ali relativeToURL:response.URL];
            if (aliURL && ![aliURL.absoluteString isEqualToString:response.URL.absoluteString]) {
                // The ALI points elsewhere, so make a second request
                NSMutableURLRequest *aliRequest = [NSMutableURLRequest requestWithURL:aliURL];
                aliRequest.HTTPMethod = @"GET";
                aliRequest.timeoutInterval = 10;
                NSError *aliError = nil;
                NSData *aliData = [NSURLConnection sendSynchronousRequest:aliRequest
                                                       returningResponse:nil
                                                                   error:&aliError];
                if (!aliError && aliData.length > 0) {
                    if ([NSJSONSerialization JSONObjectWithData:aliData options:kNilOptions error:nil]) {
                        self.authData[@"prefetchedMetadata"] = [[NSString alloc] initWithData:aliData encoding:NSUTF8StringEncoding];
                        return;
                    }
                }
                return;
            }
        }
    }

    self.authData[@"prefetchedMetadata"] = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
    NSLog(@"[ThirdPartyAuthenticator] On-the-fly metadata fetch succeeded");
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
/// Multi-character case: call refresh to bind the selected character to the token
/// Modeled on HMCL YggdrasilService.refresh: the request body contains accessToken/clientToken/selectedProfile/requestUser
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

    NSLog(@"[ThirdPartyAuthenticator] Refresh bind profile request: %@", refreshURL);

    __weak typeof(self) weakSelf = self;
    [manager POST:refreshURL parameters:data headers:nil progress:nil success:^(NSURLSessionDataTask *task, NSDictionary *response) {
        @try {
            if (![response isKindOfClass:[NSDictionary class]] ||
                !response[@"accessToken"] || !response[@"clientToken"] ||
                !response[@"selectedProfile"]) {
                NSError *error = createError(@"Failed to bind the character: the server response is missing selectedProfile", 1020);
                callback(error, NO);
                return;
            }

            NSDictionary *boundProfile = response[@"selectedProfile"];
            // Check that the bound character matches the one the request selected
            if (![boundProfile[@"id"] isEqualToString:profileToSelect[@"id"]]) {
                NSError *error = createError(@"Failed to bind the character: the server returned a different character than requested", 1021);
                callback(error, NO);
                return;
            }

            weakSelf.authData[@"accessToken"] = response[@"accessToken"];
            weakSelf.authData[@"clientToken"] = response[@"clientToken"];
            weakSelf.authData[@"username"] = boundProfile[@"name"];
            weakSelf.authData[@"uuid"] = boundProfile[@"id"];
            weakSelf.authData[@"profileId"] = boundProfile[@"id"];

            // Format the UUID (adding the hyphens)
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
            // Third-party accounts use the profileId (the character UUID) as the accountId, letting accounts with the same name coexist
            weakSelf.authData[@"accountId"] = weakSelf.authData[@"profileId"];

            // Fetch the avatar asynchronously (as in the single-character path)
            [weakSelf fetchProfileTextureWithCallback:callback];
        } @catch (NSException *exception) {
            NSError *error = createError([NSString stringWithFormat:@"Exception while parsing the refresh response: %@", exception.reason], 1022);
            callback(error, NO);
        }
    } failure:^(NSURLSessionDataTask *task, NSError *error) {
        NSString *errMsg = [self parseErrorMessageFromError:error];
        NSError *callbackError = createError(errMsg ?: @"Failed to bind the character", 1023);
        callback(callbackError, NO);
    }];
}

/// Fetch the character textures asynchronously, set the avatar URL, and invoke the callback when done
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

/// Parse the errorMessage returned by the Yggdrasil server out of an AFNetworking error
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

            // Yggdrasil specification: selectedProfile is returned when the user has exactly one character;
            // when there are several, only availableProfiles is returned; when there are none, both are missing.
            // Modeled on HMCL: with several characters, refresh must be called to bind the selected character to the token,
            // otherwise the token stays in a "no profile" state and joining a server in game fails.
            NSDictionary *selectedProfile = response[@"selectedProfile"];
            NSArray *availableProfiles = response[@"availableProfiles"];
            if (![availableProfiles isKindOfClass:[NSArray class]]) {
                availableProfiles = @[];
            }

            if (!selectedProfile && availableProfiles.count > 0) {
                // Multi-character case: save the token first, then refresh to bind the first character
                // (HMCL shows a character picker here; on mobile this is simplified to picking the first)
                NSString *accessToken = response[@"accessToken"];
                NSString *clientToken = response[@"clientToken"];
                NSDictionary *profileToSelect = availableProfiles[0];
                NSLog(@"[ThirdPartyAuthenticator] Multi-profile scenario, refresh binding profile: %@", profileToSelect[@"name"]);
                [self refreshToBindProfile:profileToSelect
                                accessToken:accessToken
                                clientToken:clientToken
                                   callback:callback];
                return;
            }

            if (!selectedProfile) {
                // A token but no characters at all: the account has not created a game character
                NSString *errMsg = @"This account has no game character yet. Create one on the skin site before signing in";
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
            // Third-party accounts use the profileId (the character UUID) as the accountId, letting accounts with the same name coexist
            self.authData[@"accountId"] = self.authData[@"profileId"];

            // Try to fetch the avatar using the Yggdrasil API
            NSString *serverURL = self.authData[@"authserver"] ?: @"https://authserver.ely.by";
            // Make sure serverURL ends with a slash
            if (![serverURL hasSuffix:@"/"]) {
                serverURL = [serverURL stringByAppendingString:@"/"];
            }

            AFHTTPSessionManager *manager = AFHTTPSessionManager.manager;
            manager.requestSerializer = AFJSONRequestSerializer.serializer;
            NSString *profileURL = [NSString stringWithFormat:@"%@sessionserver/session/minecraft/profile/%@", serverURL, self.authData[@"profileId"]];
            
            // Save the current authData so it can be used in the asynchronous callback
            __block NSMutableDictionary *localAuthData = [self.authData mutableCopy];
            __weak typeof(self) weakSelf = self;
            
            [manager GET:profileURL parameters:nil headers:nil progress:nil success:^(NSURLSessionDataTask *task, NSDictionary *response) {
                if (response[@"properties"] && [response[@"properties"] isKindOfClass:[NSArray class]]) {
                    NSArray *properties = response[@"properties"];
                    for (NSDictionary *property in properties) {
                        if ([property[@"name"] isEqualToString:@"textures"]) {
                            // Parse the skin data
                            NSString *textures = property[@"value"];
                            NSData *decodedData = [[NSData alloc] initWithBase64EncodedString:textures options:0];
                            if (decodedData) {
                                NSError *error = nil;
                                NSDictionary *texturesDict = [NSJSONSerialization JSONObjectWithData:decodedData options:kNilOptions error:&error];
                                if (texturesDict && !error) {
                                    // Get the skin URL
                                    NSString *skinURL = texturesDict[@"textures"][@"SKIN"][@"url"];
                                    if (skinURL) {
                                        // Set the avatar URL to the helm version of the skin URL
                                        NSString *headURL = [skinURL stringByReplacingOccurrencesOfString:@".png" withString:@"/helm.png"];
                                        weakSelf.authData[@"profilePicURL"] = headURL;
                                        // Save again after updating the avatar asynchronously, so the account list does not read a stale placeholder URL
                                        [weakSelf saveChanges];
                                        return;
                                    }
                                }
                            }
                        }
                    }
                }

                // If the Yggdrasil API fails, fall back to the mc-heads.net avatar service
                weakSelf.authData[@"profilePicURL"] = [NSString stringWithFormat:@"https://mc-heads.net/avatar/%@/100", weakSelf.authData[@"username"]];
                [weakSelf saveChanges];
            } failure:^(NSURLSessionDataTask *task, NSError *error) {
                // If the request fails, fall back to the mc-heads.net avatar service
                weakSelf.authData[@"profilePicURL"] = [NSString stringWithFormat:@"https://mc-heads.net/avatar/%@/100", weakSelf.authData[@"username"]];
                [weakSelf saveChanges];
            }];

            // Set a default avatar to avoid UI problems (it is overwritten and saved again once the real skin URL is fetched asynchronously)
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
                    // Third-party accounts use the profileId (the character UUID) as the accountId, letting accounts with the same name coexist
                    self.authData[@"accountId"] = self.authData[@"profileId"];

                    // Try to fetch the avatar using the Yggdrasil API
                    NSString *serverURL = self.authData[@"authserver"] ?: @"https://authserver.ely.by";
                    // Make sure serverURL ends with a slash
                    if (![serverURL hasSuffix:@"/"]) {
                        serverURL = [serverURL stringByAppendingString:@"/"];
                    }
                    
                    AFHTTPSessionManager *manager = AFHTTPSessionManager.manager;
                    manager.requestSerializer = AFJSONRequestSerializer.serializer;
                    NSString *profileURL = [NSString stringWithFormat:@"%@sessionserver/session/minecraft/profile/%@", serverURL, self.authData[@"profileId"]];
                    
                    // Save the current authData so it can be used in the asynchronous callback
                    __block NSMutableDictionary *localAuthData = [self.authData mutableCopy];
                    __weak typeof(self) weakSelf = self;
                    
                    [manager GET:profileURL parameters:nil headers:nil progress:nil success:^(NSURLSessionDataTask *task, NSDictionary *response) {
                        if (response[@"properties"] && [response[@"properties"] isKindOfClass:[NSArray class]]) {
                            NSArray *properties = response[@"properties"];
                            for (NSDictionary *property in properties) {
                                if ([property[@"name"] isEqualToString:@"textures"]) {
                                    // Parse the skin data
                                    NSString *textures = property[@"value"];
                                    NSData *decodedData = [[NSData alloc] initWithBase64EncodedString:textures options:0];
                                    if (decodedData) {
                                        NSError *error = nil;
                                        NSDictionary *texturesDict = [NSJSONSerialization JSONObjectWithData:decodedData options:kNilOptions error:&error];
                                        if (texturesDict && !error) {
                                            // Get the skin URL
                                            NSString *skinURL = texturesDict[@"textures"][@"SKIN"][@"url"];
                                            if (skinURL) {
                                                // Set the avatar URL to the helm version of the skin URL
                                                NSString *headURL = [skinURL stringByReplacingOccurrencesOfString:@".png" withString:@"/helm.png"];
                                                weakSelf.authData[@"profilePicURL"] = headURL;
                                                // Save again after updating the avatar asynchronously, so the account list does not read a stale placeholder URL
                                                [weakSelf saveChanges];
                                                return;
                                            }
                                        }
                                    }
                                }
                            }
                        }

                        // If the Yggdrasil API fails, fall back to the mc-heads.net avatar service
                        weakSelf.authData[@"profilePicURL"] = [NSString stringWithFormat:@"https://mc-heads.net/avatar/%@/100", weakSelf.authData[@"username"]];
                        [weakSelf saveChanges];
                    } failure:^(NSURLSessionDataTask *task, NSError *error) {
                        // If the request fails, fall back to the mc-heads.net avatar service
                        weakSelf.authData[@"profilePicURL"] = [NSString stringWithFormat:@"https://mc-heads.net/avatar/%@/100", weakSelf.authData[@"username"]];
                        [weakSelf saveChanges];
                    }];

                    // Set a default avatar to avoid UI problems (it is overwritten and saved again once the real skin URL is fetched asynchronously)
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