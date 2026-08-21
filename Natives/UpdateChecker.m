#import "UpdateChecker.h"
#import <UIKit/UIKit.h>

#pragma mark - UpdateInfo

@implementation UpdateInfo
@end

#pragma mark - UpdateChecker

@implementation UpdateChecker

+ (NSString *)repoOwner { return @"weecritikal"; }
+ (NSString *)repoName { return @"Air-Launcher-English-Translation"; }

+ (NSString *)latestReleaseURL {
    /* The /releases/latest endpoint automatically returns the newest non-pre-release (stable) version */
    return [NSString stringWithFormat:@"https://api.github.com/repos/%@/%@/releases/latest",
            self.repoOwner, self.repoName];
}

+ (NSString *)currentVersion {
    NSString *v = [[[NSBundle mainBundle] infoDictionary] objectForKey:@"CFBundleShortVersionString"];
    if (v == nil) v = @"";
    /* Compared against this fork's own releases. Pointing it upstream would report every
       build as out of date, since the two projects number independently. */
    return v;
}

#pragma mark - Check For Update

+ (void)checkForUpdateWithCompletion:(void(^)(UpdateInfo *_Nullable info, NSError *_Nullable error))completion {
    NSString *urlStr = self.latestReleaseURL;
    NSURL *url = [NSURL URLWithString:urlStr];
    if (url == nil) {
        if (completion) dispatch_async(dispatch_get_main_queue(), ^{
            completion(nil, [NSError errorWithDomain:@"UpdateChecker" code:-1
                                         userInfo:@{NSLocalizedDescriptionKey: @"Invalid URL"}]);
        });
        return;
    }

    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:url
                                                            cachePolicy:NSURLRequestReloadIgnoringLocalCacheData
                                                        timeoutInterval:15.0];
    [request setHTTPMethod:@"GET"];
    /* The GitHub API requires a User-Agent header, otherwise the request may be rejected */
    [request setValue:@"Flux-iOS-UpdateChecker" forHTTPHeaderField:@"User-Agent"];
    [request setValue:@"application/vnd.github+json" forHTTPHeaderField:@"Accept"];

    NSURLSessionDataTask *task = [[NSURLSession sharedSession] dataTaskWithRequest:request
        completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        if (error) {
            if (completion) dispatch_async(dispatch_get_main_queue(), ^{
                completion(nil, error);
            });
            return;
        }
        NSHTTPURLResponse *httpResp = (NSHTTPURLResponse *)response;
        if (httpResp.statusCode != 200 || data == nil) {
            if (completion) dispatch_async(dispatch_get_main_queue(), ^{
                completion(nil, [NSError errorWithDomain:@"UpdateChecker" code:httpResp.statusCode
                                             userInfo:@{NSLocalizedDescriptionKey:
                                                [NSString stringWithFormat:@"The GitHub API returned %ld", (long)httpResp.statusCode]}]);
            });
            return;
        }

        /* Parse the JSON */
        NSDictionary *json = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
        if (![json isKindOfClass:[NSDictionary class]]) {
            if (completion) dispatch_async(dispatch_get_main_queue(), ^{
                completion(nil, [NSError errorWithDomain:@"UpdateChecker" code:-2
                                             userInfo:@{NSLocalizedDescriptionKey: @"Failed to parse JSON"}]);
            });
            return;
        }

        UpdateInfo *info = [self parseReleaseJSON:json];
        if (info == nil) {
            if (completion) dispatch_async(dispatch_get_main_queue(), ^{
                completion(nil, [NSError errorWithDomain:@"UpdateChecker" code:-3
                                             userInfo:@{NSLocalizedDescriptionKey: @"Could not parse the release information"}]);
            });
            return;
        }
        if (completion) dispatch_async(dispatch_get_main_queue(), ^{
            completion(info, nil);
        });
    }];
    [task resume];
}

/// Parse the JSON returned by the GitHub Releases API
+ (UpdateInfo *)parseReleaseJSON:(NSDictionary *)json {
    UpdateInfo *info = [[UpdateInfo alloc] init];
    info.currentVersion = self.currentVersion;

    /* tag_name is usually "v5.0.1" or "5.0.1" */
    NSString *tag = json[@"tag_name"];
    if (tag.length == 0) return nil;
    info.latestVersion = [self normalizeVersion:tag];

    info.releaseName = json[@"name"];
    info.releaseNotes = json[@"body"];
    info.htmlURL = json[@"html_url"];
    info.publishedAt = json[@"published_at"];

    /* assets array */
    NSArray *assets = json[@"assets"];
    if ([assets isKindOfClass:[NSArray class]]) {
        NSMutableArray *assetList = [NSMutableArray array];
        for (NSDictionary *a in assets) {
            if (![a isKindOfClass:[NSDictionary class]]) continue;
            [assetList addObject:@{
                @"name": a[@"name"] ?: @"",
                @"url": a[@"browser_download_url"] ?: @"",
                @"size": a[@"size"] ?: @(0),
                @"contentType": a[@"content_type"] ?: @""
            }];
        }
        info.assets = assetList;
    }

    /* Version comparison: a version string may carry a suffix such as "1.0.0 Beta", so the
       numeric part is extracted first */
    NSString *currentNum = [self extractVersionNumbers:info.currentVersion];
    NSString *latestNum = [self extractVersionNumbers:info.latestVersion];
    if (currentNum.length > 0 && latestNum.length > 0) {
        NSComparisonResult cmp = [self compareVersion:currentNum withVersion:latestNum];
        info.hasUpdate = (cmp == NSOrderedAscending);
    } else {
        /* When no version number can be extracted, compare the tag and the current version strings directly */
        info.hasUpdate = ![info.currentVersion isEqualToString:info.latestVersion];
    }
    return info;
}

/// Strip a leading "v" or "V" prefix from the version number
+ (NSString *)normalizeVersion:(NSString *)tag {
    if (tag == nil) return @"";
    NSString *v = [tag stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
    if ([v hasPrefix:@"v"] || [v hasPrefix:@"V"]) {
        v = [v substringFromIndex:1];
    }
    return v;
}

/// Extract the numeric part from a version string (e.g. "1.0.0 Beta" → "1.0.0")
+ (NSString *)extractVersionNumbers:(NSString *)version {
    if (version.length == 0) return @"";
    NSError *err = nil;
    NSRegularExpression *regex = [NSRegularExpression
        regularExpressionWithPattern:@"^([0-9]+(\\.[0-9]+)*)"
                            options:0 error:&err];
    if (regex == nil) return @"";
    NSTextCheckingResult *match = [regex firstMatchInString:version
                                                    options:0
                                                      range:NSMakeRange(0, version.length)];
    if (match == nil) return @"";
    return [version substringWithRange:[match rangeAtIndex:1]];
}

#pragma mark - Version Comparison

+ (NSComparisonResult)compareVersion:(NSString *)v1 withVersion:(NSString *)v2 {
    /* Fault tolerance: nil or an empty string is treated as "0" */
    if (v1.length == 0) v1 = @"0";
    if (v2.length == 0) v2 = @"0";

    NSArray *c1 = [v1 componentsSeparatedByString:@"."];
    NSArray *c2 = [v2 componentsSeparatedByString:@"."];
    NSInteger max = MAX(c1.count, c2.count);

    for (NSInteger i = 0; i < max; i++) {
        /* Non-numeric segments (such as "Beta") are treated as 0 */
        NSInteger n1 = (i < c1.count) ? [c1[i] integerValue] : 0;
        NSInteger n2 = (i < c2.count) ? [c2[i] integerValue] : 0;
        if (n1 < n2) return NSOrderedAscending;
        if (n1 > n2) return NSOrderedDescending;
    }
    return NSOrderedSame;
}

#pragma mark - Open Release Page

+ (void)openReleasePage {
    NSURL *url = [NSURL URLWithString:[NSString stringWithFormat:@"https://github.com/%@/%@/releases/latest",
                                       self.repoOwner, self.repoName]];
    if (url && [[UIApplication sharedApplication] canOpenURL:url]) {
        [[UIApplication sharedApplication] openURL:url options:@{} completionHandler:nil];
    }
}

@end
