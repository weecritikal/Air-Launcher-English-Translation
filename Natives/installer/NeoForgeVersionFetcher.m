#import "NeoForgeVersionFetcher.h"
#import "LauncherPreferences.h"

@implementation NeoForgeVersionFetcher

#pragma mark - Public

+ (void)fetchVersionsForGameVersion:(NSString *)gameVersion
                         completion:(void (^)(NSArray *versions, NSError *error))completion {
    if (!completion) return;
    if (!gameVersion || gameVersion.length == 0) {
        completion(@[], [NSError errorWithDomain:@"NeoForge" code:1 userInfo:@{NSLocalizedDescriptionKey:@"No game version"}]);
        return;
    }

    NSString *downloadSource = getPrefObject(@"general.download_source");
    BOOL preferBMCLAPI = [downloadSource isEqualToString:@"bmclapi"];

    void (^finish)(NSArray *, NSError *) = ^(NSArray *versions, NSError *error) {
        NSArray *filtered = [self filterVersions:versions gameVersion:gameVersion];
        if (filtered.count > 0) {
            completion(filtered, nil);
        } else if (error) {
            completion(@[], error);
        } else {
            completion(@[], [NSError errorWithDomain:@"NeoForge" code:2 userInfo:@{NSLocalizedDescriptionKey:@"No matching NeoForge versions"}]);
        }
    };

    // Try preferred source first, then fallback.
    [self fetchAllVersionsUseBMCLAPI:preferBMCLAPI completion:^(NSArray *versions, NSError *error) {
        if (versions.count > 0) {
            finish(versions, nil);
        } else {
            NSLog(@"[NeoForge] Primary source (%@) returned no versions, falling back to %@",
                  preferBMCLAPI ? @"BMCLAPI" : @"official",
                  preferBMCLAPI ? @"official" : @"BMCLAPI");
            [self fetchAllVersionsUseBMCLAPI:!preferBMCLAPI completion:^(NSArray *fallbackVersions, NSError *fallbackError) {
                if (fallbackVersions.count > 0) {
                    finish(fallbackVersions, nil);
                } else {
                    finish(@[], fallbackError ?: error);
                }
            }];
        }
    }];
}

+ (NSString *)installerURLForVersion:(NSString *)version {
    if (!version || version.length == 0) return nil;
    NSString *downloadSource = getPrefObject(@"general.download_source");
    BOOL useBMCLAPI = [downloadSource isEqualToString:@"bmclapi"];
    // Legacy 1.20.1 versions use the old forge coordinates.
    if ([version containsString:@"1.20.1"] || [version hasPrefix:@"47."]) {
        if (useBMCLAPI) {
            return [NSString stringWithFormat:@"https://bmclapi2.bangbang93.com/maven/net/neoforged/forge/%@/forge-%@-installer.jar", version, version];
        }
        // 官方 maven 路径必须包含 /releases/，否则 404
        return [NSString stringWithFormat:@"https://maven.neoforged.net/releases/net/neoforged/forge/%@/forge-%@-installer.jar", version, version];
    }
    if (useBMCLAPI) {
        return [NSString stringWithFormat:@"https://bmclapi2.bangbang93.com/maven/net/neoforged/neoforge/%@/neoforge-%@-installer.jar", version, version];
    }
    // 官方 maven 路径必须包含 /releases/，否则 404
    return [NSString stringWithFormat:@"https://maven.neoforged.net/releases/net/neoforged/neoforge/%@/neoforge-%@-installer.jar", version, version];
}

#pragma mark - Internal

+ (void)fetchAllVersionsUseBMCLAPI:(BOOL)useBMCLAPI
                        completion:(void (^)(NSArray *versions, NSError *error))completion {
    NSString *officialNeoURL = @"https://maven.neoforged.net/api/maven/versions/releases/net/neoforged/neoforge";
    NSString *officialLegacyURL = @"https://maven.neoforged.net/api/maven/versions/releases/net/neoforged/forge";
    NSString *bmclNeoURL = @"https://bmclapi2.bangbang93.com/neoforge/meta/api/maven/details/releases/net/neoforged/neoforge";
    NSString *bmclLegacyURL = @"https://bmclapi2.bangbang93.com/neoforge/meta/api/maven/details/releases/net/neoforged/forge";

    NSMutableArray *allVersions = [NSMutableArray array];
    dispatch_group_t group = dispatch_group_create();
    __block NSError *lastError = nil;

    dispatch_group_enter(group);
    if (useBMCLAPI) {
        [self fetchBMCLAPIVersions:bmclNeoURL completion:^(NSArray *versions, NSError *error) {
            if (versions.count > 0) { @synchronized (allVersions) { [allVersions addObjectsFromArray:versions]; } }
            if (error) lastError = error;
            dispatch_group_leave(group);
        }];
    } else {
        [self fetchOfficialVersions:officialNeoURL completion:^(NSArray *versions, NSError *error) {
            if (versions.count > 0) { @synchronized (allVersions) { [allVersions addObjectsFromArray:versions]; } }
            if (error) lastError = error;
            dispatch_group_leave(group);
        }];
    }

    dispatch_group_enter(group);
    if (useBMCLAPI) {
        [self fetchBMCLAPIVersions:bmclLegacyURL completion:^(NSArray *versions, NSError *error) {
            if (versions.count > 0) { @synchronized (allVersions) { [allVersions addObjectsFromArray:versions]; } }
            if (error) lastError = error;
            dispatch_group_leave(group);
        }];
    } else {
        [self fetchOfficialVersions:officialLegacyURL completion:^(NSArray *versions, NSError *error) {
            if (versions.count > 0) { @synchronized (allVersions) { [allVersions addObjectsFromArray:versions]; } }
            if (error) lastError = error;
            dispatch_group_leave(group);
        }];
    }

    dispatch_group_notify(group, dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        if (completion) completion(allVersions, lastError);
    });
}

+ (void)fetchOfficialVersions:(NSString *)urlString
                   completion:(void (^)(NSArray *versions, NSError *error))completion {
    NSURL *url = [NSURL URLWithString:urlString];
    NSURLSessionDataTask *task = [[NSURLSession sharedSession] dataTaskWithURL:url completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        if (error || !data) {
            NSLog(@"[NeoForge] Official fetch failed: %@", error.localizedDescription ?: @"no data");
            if (completion) completion(@[], error ?: [NSError errorWithDomain:@"NeoForge" code:3 userInfo:@{NSLocalizedDescriptionKey:@"No data"}]);
            return;
        }
        NSDictionary *json = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
        if ([json isKindOfClass:[NSDictionary class]]) {
            NSArray *versions = json[@"versions"];
            if ([versions isKindOfClass:[NSArray class]]) {
                if (completion) completion(versions, nil);
                return;
            }
        }
        if (completion) completion(@[], [NSError errorWithDomain:@"NeoForge" code:4 userInfo:@{NSLocalizedDescriptionKey:@"Invalid JSON"}]);
    }];
    [task resume];
}

+ (void)fetchBMCLAPIVersions:(NSString *)urlString
                  completion:(void (^)(NSArray *versions, NSError *error))completion {
    NSURL *url = [NSURL URLWithString:urlString];
    NSURLSessionDataTask *task = [[NSURLSession sharedSession] dataTaskWithURL:url completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        if (error || !data) {
            NSLog(@"[NeoForge] BMCLAPI fetch failed: %@", error.localizedDescription ?: @"no data");
            if (completion) completion(@[], error ?: [NSError errorWithDomain:@"NeoForge" code:3 userInfo:@{NSLocalizedDescriptionKey:@"No data"}]);
            return;
        }
        NSDictionary *json = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
        if ([json isKindOfClass:[NSDictionary class]]) {
            NSArray *files = json[@"files"];
            if ([files isKindOfClass:[NSArray class]]) {
                NSMutableArray *versions = [NSMutableArray array];
                for (id obj in files) {
                    if (![obj isKindOfClass:[NSDictionary class]]) continue;
                    NSDictionary *file = obj;
                    NSString *type = file[@"type"];
                    NSString *name = file[@"name"];
                    if ([type isEqualToString:@"DIRECTORY"] && name && ![name.lowercaseString containsString:@"maven"]) {
                        [versions addObject:name];
                    }
                }
                if (completion) completion(versions, nil);
                return;
            }
        }
        if (completion) completion(@[], [NSError errorWithDomain:@"NeoForge" code:4 userInfo:@{NSLocalizedDescriptionKey:@"Invalid BMCLAPI JSON"}]);
    }];
    [task resume];
}

+ (NSArray *)filterVersions:(NSArray *)versions gameVersion:(NSString *)gameVersion {
    NSMutableArray *filtered = [NSMutableArray array];
    for (id obj in versions) {
        if (![obj isKindOfClass:[NSString class]]) continue;
        NSString *version = obj;
        NSString *mcVersion = [self extractMinecraftVersionFromNeoForgeVersion:version];
        if ([mcVersion isEqualToString:gameVersion]) {
            [filtered addObject:version];
        }
    }
    [filtered sortUsingComparator:^NSComparisonResult(NSString *v1, NSString *v2) {
        return [v2 compare:v1 options:NSNumericSearch];
    }];
    return filtered;
}

+ (NSString *)extractMinecraftVersionFromNeoForgeVersion:(NSString *)version {
    // 1.20.1 special versions: 1.20.1-47.1.3 -> 1.20.1
    // 同时覆盖 47.x.y 系列（1.20.1 NeoForge release 版本号，不含 "1.20.1" 子串）
    if ([version containsString:@"1.20.1"] || [version hasPrefix:@"47."]) {
        return @"1.20.1";
    }

    // 0.x special snapshots: 0.25w14craftmine.3 -> 25w14craftmine
    if ([version hasPrefix:@"0."]) {
        NSString *part = [version substringFromIndex:2];
        NSRange hyphenRange = [part rangeOfString:@"-"];
        if (hyphenRange.location != NSNotFound) {
            part = [part substringToIndex:hyphenRange.location];
        }
        NSRange lastDot = [part rangeOfString:@"." options:NSBackwardsSearch];
        if (lastDot.location != NSNotFound) {
            part = [part substringToIndex:lastDot.location];
        }
        return part;
    }

    NSString *cleanVersion = version;
    NSRange hyphenRange = [version rangeOfString:@"-"];
    if (hyphenRange.location != NSNotFound) {
        cleanVersion = [version substringToIndex:hyphenRange.location];
    }

    NSArray *components = [cleanVersion componentsSeparatedByString:@"."];
    if (components.count >= 2) {
        NSString *major = components[0];
        NSString *minor = components[1];

        NSCharacterSet *nonNumbers = [[NSCharacterSet decimalDigitCharacterSet] invertedSet];
        BOOL majorIsNum = [major rangeOfCharacterFromSet:nonNumbers].location == NSNotFound;
        BOOL minorIsNum = [minor rangeOfCharacterFromSet:nonNumbers].location == NSNotFound;

        if (majorIsNum && minorIsNum) {
            NSInteger majorVal = [major integerValue];
            if (majorVal >= 26) {
                // New format: 26.1.0.0 -> 1.26.0（NeoForge 26+ 对应 MC 1.26+，未来版本）
                // 实际约定：NeoForge loader 主版本号 == MC 主版本号（从 21.x 开始）
                // 但 47.x 是 1.20.1 的特例（已在上面处理）
                if (components.count >= 3) {
                    return [NSString stringWithFormat:@"1.%@.%@", major, components[2]];
                } else {
                    return [NSString stringWithFormat:@"1.%@.0", major];
                }
            } else if (majorVal >= 21) {
                // 21.x - 25.x: NeoForge loader 版本号 == MC 版本号（21.x → MC 1.21.x）
                if (components.count >= 3) {
                    return [NSString stringWithFormat:@"1.%@.%@", major, components[2]];
                } else {
                    return [NSString stringWithFormat:@"1.%@.0", major];
                }
            } else {
                // Old format: 20.2.88 -> 1.20.2
                return [NSString stringWithFormat:@"1.%@.%@", major, minor];
            }
        }
    }

    NSRegularExpression *regex = [NSRegularExpression regularExpressionWithPattern:@"(\\d+\\.\\d+)" options:0 error:nil];
    NSTextCheckingResult *match = [regex firstMatchInString:version options:0 range:NSMakeRange(0, version.length)];
    if (match) {
        return [NSString stringWithFormat:@"1.%@", [version substringWithRange:match.range]];
    }

    return @"Unknown";
}

@end
