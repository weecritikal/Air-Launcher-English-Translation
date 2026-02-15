#import "MinecraftResourceDownloadTask.h"
#import "ModrinthAPI.h"
#import "PLProfiles.h"

@implementation ModrinthAPI

+ (instancetype)sharedInstance {
    static ModrinthAPI *sharedInstance = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        sharedInstance = [[self alloc] init];
    });
    return sharedInstance;
}

- (instancetype)init {
    return [super initWithURL:@"https://api.modrinth.com/v2"];
}

- (NSMutableArray *)searchModWithFilters:(NSDictionary<NSString *, NSString *> *)searchFilters previousPageResult:(NSMutableArray *)modrinthSearchResult {
    int limit = 50;

    NSMutableString *facetString = [NSMutableString new];
    [facetString appendString:@"["];
    [facetString appendFormat:@"[\"project_type:%@\"]", searchFilters[@"isModpack"].boolValue ? @"modpack" : @"mod"];
    if (searchFilters[@"mcVersion"].length > 0) {
        [facetString appendFormat:@", [\"versions:%@\"]", searchFilters[@"mcVersion"]];
    }
    [facetString appendString:@"]"];

    NSDictionary *params = @{
        @"facets": facetString,
        @"query": [searchFilters[@"name"] stringByReplacingOccurrencesOfString:@" " withString:@"+"],
        @"limit": @(limit),
        @"index": @"relevance",
        @"offset": @(modrinthSearchResult.count)
    };
    NSDictionary *response = [self getEndpoint:@"search" params:params];
    if (!response) {
        return nil;
    }

    NSMutableArray *result = modrinthSearchResult ?: [NSMutableArray new];
    for (NSDictionary *hit in response[@"hits"]) {
        BOOL isModpack = [hit[@"project_type"] isEqualToString:@"modpack"];
        [result addObject:@{
            @"apiSource": @(1), // Constant MODRINTH
            @"isModpack": @(isModpack),
            @"id": hit[@"project_id"],
            @"title": hit[@"title"],
            @"description": hit[@"description"],
            @"imageUrl": hit[@"icon_url"]
        }.mutableCopy];
    }
    self.reachedLastPage = result.count >= [response[@"total_hits"] unsignedLongValue];
    return result;
}

- (void)loadDetailsOfMod:(NSMutableDictionary *)item {
    NSArray *response = [self getEndpoint:[NSString stringWithFormat:@"project/%@/version", item[@"id"]] params:nil];
    if (!response) {
        return;
    }
    NSArray<NSString *> *names = [response valueForKey:@"name"];
    NSMutableArray<NSString *> *mcNames = [NSMutableArray new];
    NSMutableArray<NSString *> *urls = [NSMutableArray new];
    NSMutableArray<NSString *> *hashes = [NSMutableArray new];
    NSMutableArray<NSString *> *sizes = [NSMutableArray new];
    [response enumerateObjectsUsingBlock:
  ^(NSDictionary *version, NSUInteger i, BOOL *stop) {
        NSDictionary *file = [version[@"files"] firstObject];
        mcNames[i] = [version[@"game_versions"] firstObject];
        sizes[i] = file[@"size"];
        urls[i] = file[@"url"];
        NSDictionary *hashesMap = file[@"hashes"];
        hashes[i] = hashesMap[@"sha1"] ?: [NSNull null];
    }];
    item[@"versionNames"] = names;
    item[@"mcVersionNames"] = mcNames;
    item[@"versionSizes"] = sizes;
    item[@"versionUrls"] = urls;
    item[@"versionHashes"] = hashes;
    item[@"versionDetailsLoaded"] = @(YES);
}

- (void)getVersionsForModWithID:(NSString *)modID completion:(void (^)(NSArray<ModVersion *> * _Nullable versions, NSError * _Nullable error))completion {
    NSString *urlString = [NSString stringWithFormat:@"%@/project/%@/version", self.baseURL, modID];
    NSURL *url = [NSURL URLWithString:urlString];

    if (!url) {
        if (completion) {
            NSError *error = [NSError errorWithDomain:@"ModrinthAPIError" code:-1 userInfo:@{NSLocalizedDescriptionKey: @"Invalid URL"}];
            completion(nil, error);
        }
        return;
    }

    NSURLSessionDataTask *task = [[NSURLSession sharedSession] dataTaskWithURL:url completionHandler:^(NSData * _Nullable data, NSURLResponse * _Nullable response, NSError * _Nullable error) {
        if (error) {
            if (completion) {
                completion(nil, error);
            }
            return;
        }

        if (!data) {
            if (completion) {
                NSError *dataError = [NSError errorWithDomain:@"ModrinthAPIError" code:-2 userInfo:@{NSLocalizedDescriptionKey: @"No data received"}];
                completion(nil, dataError);
            }
            return;
        }

        NSError *jsonError = nil;
        id jsonResult = [NSJSONSerialization JSONObjectWithData:data options:0 error:&jsonError];

        if (jsonError) {
            if (completion) {
                completion(nil, jsonError);
            }
            return;
        }

        if (![jsonResult isKindOfClass:[NSArray class]]) {
            if (completion) {
                NSError *formatError = [NSError errorWithDomain:@"ModrinthAPIError" code:-3 userInfo:@{NSLocalizedDescriptionKey: @"Unexpected JSON format"}];
                completion(nil, formatError);
            }
            return;
        }

        NSMutableArray<ModVersion *> *versions = [NSMutableArray array];
        for (NSDictionary *versionDict in jsonResult) {
            if ([versionDict isKindOfClass:[NSDictionary class]]) {
                ModVersion *version = [[ModVersion alloc] initWithDictionary:versionDict];
                if (version) {
                    [versions addObject:version];
                }
            }
        }

        if (completion) {
            completion([versions copy], nil);
        }
    }];

    [task resume];
}

#pragma mark - Shader Search

- (void)searchShaderWithFilters:(NSDictionary *)filters completion:(void (^)(NSArray * _Nullable results, NSError * _Nullable error))completion {
    NSString *query = filters[@"name"] ?: @"";
    if (query.length == 0) {
        if (completion) completion(@[], nil);
        return;
    }

    // Modrinth project type: shader
    NSString *encodedQuery = [query stringByAddingPercentEncodingWithAllowedCharacters:[NSCharacterSet URLQueryAllowedCharacterSet]];
    NSString *urlString = [NSString stringWithFormat:@"%@/search?query=%@&limit=50&offset=0&facets=[[%%22project_type:shader%%22]]", self.baseURL, encodedQuery];

    NSURL *url = [NSURL URLWithString:urlString];
    if (!url) {
        if (completion) completion(nil, [NSError errorWithDomain:@"ModrinthAPIError" code:2 userInfo:@{NSLocalizedDescriptionKey: @"Invalid URL"}]);
        return;
    }

    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:url];
    [request setValue:@"application/json" forHTTPHeaderField:@"Accept"];
    [request setValue:@"Amethyst-iOS/1.0" forHTTPHeaderField:@"User-Agent"];

    NSURLSessionDataTask *task = [[NSURLSession sharedSession] dataTaskWithRequest:request completionHandler:^(NSData * _Nullable data, NSURLResponse * _Nullable response, NSError * _Nullable error) {
        if (error) {
            if (completion) completion(nil, error);
            return;
        }

        if (!data) {
            if (completion) completion(nil, [NSError errorWithDomain:@"ModrinthAPIError" code:3 userInfo:@{NSLocalizedDescriptionKey: @"No data received"}]);
            return;
        }

        NSError *jsonError = nil;
        NSDictionary *json = [NSJSONSerialization JSONObjectWithData:data options:0 error:&jsonError];

        if (jsonError || ![json isKindOfClass:[NSDictionary class]]) {
            if (completion) completion(nil, jsonError ?: [NSError errorWithDomain:@"ModrinthAPIError" code:4 userInfo:@{NSLocalizedDescriptionKey: @"Invalid JSON response"}]);
            return;
        }

        NSArray *hits = json[@"hits"];
        if (![hits isKindOfClass:[NSArray class]]) {
            if (completion) completion(@[], nil);
            return;
        }

        NSMutableArray *results = [NSMutableArray array];
        for (NSDictionary *item in hits) {
            if (![item isKindOfClass:[NSDictionary class]]) continue;

            NSMutableDictionary *shaderData = [NSMutableDictionary dictionary];
            shaderData[@"id"] = item[@"project_id"] ?: item[@"slug"] ?: @"";
            shaderData[@"title"] = item[@"title"] ?: @"Unknown";
            shaderData[@"description"] = item[@"description"] ?: @"";
            shaderData[@"author"] = item[@"author"] ?: @"Unknown";
            shaderData[@"downloads"] = item[@"downloads"] ?: @0;
            shaderData[@"likes"] = item[@"follows"] ?: @0;
            shaderData[@"imageUrl"] = item[@"icon_url"] ?: @"";
            shaderData[@"categories"] = item[@"categories"] ?: @[];
            shaderData[@"lastUpdated"] = item[@"date_modified"] ?: @"";

            [results addObject:shaderData];
        }

        if (completion) completion(results, nil);
    }];

    [task resume];
}

- (void)getVersionsForShaderWithID:(NSString *)shaderID completion:(void (^)(NSArray<ShaderVersion *> * _Nullable versions, NSError * _Nullable error))completion {
    if (!shaderID || shaderID.length == 0) {
        if (completion) completion(nil, [NSError errorWithDomain:@"ModrinthAPIError" code:1 userInfo:@{NSLocalizedDescriptionKey: @"Invalid shader ID"}]);
        return;
    }

    NSString *urlString = [NSString stringWithFormat:@"%@/project/%@/version", self.baseURL, shaderID];
    NSURL *url = [NSURL URLWithString:urlString];

    if (!url) {
        if (completion) completion(nil, [NSError errorWithDomain:@"ModrinthAPIError" code:2 userInfo:@{NSLocalizedDescriptionKey: @"Invalid URL"}]);
        return;
    }

    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:url];
    [request setValue:@"application/json" forHTTPHeaderField:@"Accept"];
    [request setValue:@"Amethyst-iOS/1.0" forHTTPHeaderField:@"User-Agent"];

    NSURLSessionDataTask *task = [[NSURLSession sharedSession] dataTaskWithRequest:request completionHandler:^(NSData * _Nullable data, NSURLResponse * _Nullable response, NSError * _Nullable error) {
        if (error) {
            if (completion) completion(nil, error);
            return;
        }

        if (!data) {
            if (completion) completion(nil, [NSError errorWithDomain:@"ModrinthAPIError" code:3 userInfo:@{NSLocalizedDescriptionKey: @"No data received"}]);
            return;
        }

        NSError *jsonError = nil;
        NSArray *json = [NSJSONSerialization JSONObjectWithData:data options:0 error:&jsonError];

        if (jsonError || ![json isKindOfClass:[NSArray class]]) {
            if (completion) completion(nil, jsonError ?: [NSError errorWithDomain:@"ModrinthAPIError" code:4 userInfo:@{NSLocalizedDescriptionKey: @"Invalid JSON response"}]);
            return;
        }

        NSMutableArray<ShaderVersion *> *versions = [NSMutableArray array];
        for (NSDictionary *dict in json) {
            ShaderVersion *version = [[ShaderVersion alloc] initWithDictionary:dict];
            if (version) {
                [versions addObject:version];
            }
        }

        if (completion) completion(versions, nil);
    }];

    [task resume];
}

- (void)downloader:(MinecraftResourceDownloadTask *)downloader submitDownloadTasksFromPackage:(NSString *)packagePath toPath:(NSString *)destPath {
    NSError *error;
    UZKArchive *archive = [[UZKArchive alloc] initWithPath:packagePath error:&error];
    if (error) {
        [downloader finishDownloadWithErrorString:[NSString stringWithFormat:@"Failed to open modpack package: %@", error.localizedDescription]];
        return;
    }

    NSData *indexData = [archive extractDataFromFile:@"modrinth.index.json" error:&error];
    NSDictionary* indexDict = [NSJSONSerialization JSONObjectWithData:indexData options:kNilOptions error:&error];
    if (error) {
        [downloader finishDownloadWithErrorString:[NSString stringWithFormat:@"Failed to parse modrinth.index.json: %@", error.localizedDescription]];
        return;
    }

    downloader.progress.totalUnitCount = [indexDict[@"files"] count];
    for (NSDictionary *indexFile in indexDict[@"files"]) {
        NSString *url = [indexFile[@"downloads"] firstObject];
        NSString *sha = indexFile[@"hashes"][@"sha1"];
        NSString *path = [destPath stringByAppendingPathComponent:indexFile[@"path"]];
        NSUInteger size = [indexFile[@"fileSize"] unsignedLongLongValue];
        NSURLSessionDownloadTask *task = [downloader createDownloadTask:url size:size sha:sha altName:nil toPath:path];
        if (task) {
            [downloader.fileList addObject:indexFile[@"path"]];
            [task resume];
        } else if (!downloader.progress.cancelled) {
            downloader.progress.completedUnitCount++;
        } else {
            return; // cancelled
        }
    }

    [ModpackUtils archive:archive extractDirectory:@"overrides" toPath:destPath error:&error];
    if (error) {
        [downloader finishDownloadWithErrorString:[NSString stringWithFormat:@"Failed to extract overrides from modpack package: %@", error.localizedDescription]];
        return;
    }

    [ModpackUtils archive:archive extractDirectory:@"client-overrides" toPath:destPath error:&error];
    if (error) {
        [downloader finishDownloadWithErrorString:[NSString stringWithFormat:@"Failed to extract client-overrides from modpack package: %@", error.localizedDescription]];
        return;
    }

    // Delete package cache
    [NSFileManager.defaultManager removeItemAtPath:packagePath error:nil];

    // Download dependency client json (if available)
    NSDictionary<NSString *, NSString *> *depInfo = [ModpackUtils infoForDependencies:indexDict[@"dependencies"]];
    if (depInfo[@"json"]) {
        // Set up completion callback to create profile after all dependencies are downloaded
        downloader.modpackDownloadCompletion = ^{
            // Create profile after all dependencies are downloaded
            NSString *tmpIconPath = [NSTemporaryDirectory() stringByAppendingPathComponent:@"icon.png"];
            PLProfiles.current.profiles[indexDict[@"name"]] = @{
                @"gameDir": [NSString stringWithFormat:@"./custom_gamedir/%@", destPath.lastPathComponent],
                @"name": indexDict[@"name"],
                @"lastVersionId": depInfo[@"id"] ?: @"",
                @"icon": [NSString stringWithFormat:@"data:image/png;base64,%@",
                    [[NSData dataWithContentsOfFile:tmpIconPath]
                    base64EncodedStringWithOptions:0]]
            }.mutableCopy;
            PLProfiles.current.selectedProfileName = indexDict[@"name"];
        };
        NSString *jsonPath = [NSString stringWithFormat:@"%1$s/versions/%2$@/%2$@.json", getenv("POJAV_GAME_DIR"), depInfo[@"id"]];
        NSURLSessionDownloadTask *task = [downloader createDownloadTask:depInfo[@"json"] size:0 sha:nil altName:nil toPath:jsonPath success:^{
            // Now download the rest of the game files
            NSDictionary *version = @{@"id": depInfo[@"id"]};
            [downloader downloadVersion:version];
        }];
        [task resume];
    } else {
        // If no dependencies to download, create the profile immediately
        // Create profile
        NSString *tmpIconPath = [NSTemporaryDirectory() stringByAppendingPathComponent:@"icon.png"];
        PLProfiles.current.profiles[indexDict[@"name"]] = @{
            @"gameDir": [NSString stringWithFormat:@"./custom_gamedir/%@", destPath.lastPathComponent],
            @"name": indexDict[@"name"],
            @"lastVersionId": depInfo[@"id"] ?: @"",
            @"icon": [NSString stringWithFormat:@"data:image/png;base64,%@",
                [[NSData dataWithContentsOfFile:tmpIconPath]
                base64EncodedStringWithOptions:0]]
        }.mutableCopy;
        PLProfiles.current.selectedProfileName = indexDict[@"name"];
    }
    // TODO: automation for Forge
}

@end
