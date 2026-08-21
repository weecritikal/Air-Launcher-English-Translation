#import "MinecraftResourceDownloadTask.h"
#import "ModrinthAPI.h"
#import "PLProfiles.h"
#import "ModpackUtils.h"
#import "UZKArchive.h"
#import "installer/ForgeDirectInstaller.h"
#import "installer/NeoForgeDirectInstaller.h"
#import "MCIMMirror.h"

@implementation ModrinthAPI

@dynamic reachedLastPage, lastError;

/// Override the baseURL getter to return the official or the mirror URL dynamically, based on the MCIMMirror preference
/// This way every request that uses self.baseURL (search/version list/details) goes through the mirror automatically
- (NSString *)baseURL {
    return [MCIMMirror modrinthAPIBaseURL];
}

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

#pragma mark - Helper

- (BOOL)boolValueFromObject:(id)obj {
    if (obj == nil || obj == [NSNull null]) return NO;
    if ([obj isKindOfClass:[NSNumber class]]) return [(NSNumber *)obj boolValue];
    if ([obj isKindOfClass:[NSString class]]) return [(NSString *)obj boolValue];
    return NO;
}

#pragma mark - Sync Search (with projectType support)

- (NSMutableArray *)searchModWithFilters:(NSDictionary<NSString *, NSString *> *)searchFilters
                     previousPageResult:(NSMutableArray *)modrinthSearchResult {
    int limit = 50;
    NSString *projectType = searchFilters[@"projectType"];
    if (projectType.length == 0) {
        // Defensive fallback: search as a modpack when projectType is unspecified but isModpack is declared, so mods are not searched by mistake
        projectType = [searchFilters[@"isModpack"] boolValue] ? @"modpack" : @"mod";
    }

    // Fix #50: the loader (the categories facet) must be passed to the Modrinth API, otherwise filtering by neoforge/fabric has no effect
    // Modrinth loader categories: fabric / quilt / forge / neoforge / liteloader / rift and so on
    NSMutableString *facetString = [NSMutableString new];
    [facetString appendString:@"["];
    [facetString appendFormat:@"[\"project_type:%@\"]", projectType];
    if (searchFilters[@"mcVersion"].length > 0) {
        [facetString appendFormat:@", [\"versions:%@\"]", searchFilters[@"mcVersion"]];
    }
    NSString *loader = searchFilters[@"loader"] ?: searchFilters[@"categories"];
    if (loader.length > 0) {
        [facetString appendFormat:@", [\"categories:%@\"]", loader];
    }
    [facetString appendString:@"]"];

    NSDictionary *params = @{
        @"facets": facetString,
        @"query": [searchFilters[@"name"] stringByReplacingOccurrencesOfString:@" " withString:@"+"] ?: @"",
        @"limit": @(limit),
        @"index": @"relevance",
        @"offset": @(modrinthSearchResult.count)
    };
    NSDictionary *response = [self getEndpoint:@"search" params:params];
    if (!response) return nil;
    
    NSMutableArray *result = modrinthSearchResult ?: [NSMutableArray new];
    for (NSDictionary *hit in response[@"hits"]) {
        BOOL isModpack = [hit[@"project_type"] isEqualToString:@"modpack"];
        [result addObject:@{
            @"apiSource": @(1),
            @"isModpack": @(isModpack),
            @"projectType": hit[@"project_type"] ?: projectType,
            @"id": hit[@"project_id"] ?: hit[@"slug"] ?: @"",
            @"title": hit[@"title"] ?: @"",
            @"description": hit[@"description"] ?: @"",
            @"imageUrl": hit[@"icon_url"] ?: @"",
            @"author": hit[@"author"] ?: @"",
            @"downloads": hit[@"downloads"] ?: @0,
            @"likes": hit[@"follows"] ?: @0,
            @"categories": hit[@"categories"] ?: @[],
            @"lastUpdated": hit[@"date_modified"] ?: @""
        }.mutableCopy];
    }
    self.reachedLastPage = result.count >= [response[@"total_hits"] unsignedLongValue];
    return result;
}

#pragma mark - Sync Load Details (array assignment fix)

- (void)loadDetailsOfMod:(NSMutableDictionary *)item {
    NSArray *response = [self getEndpoint:[NSString stringWithFormat:@"project/%@/version", item[@"id"]] params:nil];
    if (!response) return;

    NSMutableArray<NSString *> *names = [NSMutableArray new];
    NSMutableArray<NSString *> *mcNames = [NSMutableArray new];
    NSMutableArray<NSString *> *urls = [NSMutableArray new];
    NSMutableArray<NSString *> *hashes = [NSMutableArray new];
    NSMutableArray<NSString *> *sizes = [NSMutableArray new];
    NSMutableArray<NSString *> *fileNames = [NSMutableArray new];
    NSMutableArray<NSString *> *fileTypes = [NSMutableArray new];

    for (NSDictionary *version in response) {
        NSArray *files = version[@"files"];
        if (![files isKindOfClass:[NSArray class]] || files.count == 0) continue;
        NSDictionary *file = files.firstObject;

        [names addObject:version[@"name"] ?: @"Unknown"];
        NSArray *gameVersions = version[@"game_versions"];
        [mcNames addObject:[gameVersions isKindOfClass:[NSArray class]] ? gameVersions.firstObject : @""];
        [urls addObject:file[@"url"] ?: @""];
        NSDictionary *hashesMap = file[@"hashes"];
        [hashes addObject:hashesMap[@"sha1"] ?: @""];
        [sizes addObject:file[@"size"] ?: @0];
        [fileNames addObject:file[@"filename"] ?: @""];
        [fileTypes addObject:version[@"version_type"] ?: @""];
    }

    item[@"versionNames"] = names;
    item[@"mcVersionNames"] = mcNames;
    item[@"versionSizes"] = sizes;
    item[@"versionUrls"] = urls;
    item[@"versionHashes"] = hashes;
    item[@"versionFileNames"] = fileNames;
    item[@"versionFileTypes"] = fileTypes;
    item[@"versionDetailsLoaded"] = @(YES);
}

/// Asynchronously load the modpack version details, so a synchronous dispatch_group_wait does not block the main thread and freeze the UI
- (void)loadDetailsOfModAsync:(NSMutableDictionary *)item
                   completion:(void (^)(BOOL success, NSError * _Nullable error))completion {
    NSString *modID = item[@"id"];
    if (!modID || modID.length == 0) {
        if (completion) completion(NO, [NSError errorWithDomain:@"ModrinthAPIError" code:1
                                                       userInfo:@{NSLocalizedDescriptionKey: @"Missing mod ID"}]);
        return;
    }

    NSString *urlString = [NSString stringWithFormat:@"%@/project/%@/version", self.baseURL, modID];
    NSURL *url = [NSURL URLWithString:urlString];
    if (!url) {
        if (completion) completion(NO, [NSError errorWithDomain:@"ModrinthAPIError" code:2
                                                       userInfo:@{NSLocalizedDescriptionKey: @"Invalid URL"}]);
        return;
    }

    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:url];
    request.timeoutInterval = 30.0;
    [request setValue:@"application/json" forHTTPHeaderField:@"Accept"];
    [request setValue:@"Flux-iOS/1.0" forHTTPHeaderField:@"User-Agent"];

    NSURLSession *session = [NSURLSession sharedSession];
    NSURLSessionDataTask *task = [session dataTaskWithRequest:request
                                           completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        if (error) {
            self.lastError = error;
            if (completion) completion(NO, error);
            return;
        }
        if (!data) {
            NSError *err = [NSError errorWithDomain:@"ModrinthAPIError" code:3
                                           userInfo:@{NSLocalizedDescriptionKey: @"No data returned"}];
            self.lastError = err;
            if (completion) completion(NO, err);
            return;
        }

        NSError *jsonError = nil;
        id jsonResult = [NSJSONSerialization JSONObjectWithData:data options:0 error:&jsonError];
        if (jsonError || ![jsonResult isKindOfClass:[NSArray class]]) {
            NSError *err = jsonError ?: [NSError errorWithDomain:@"ModrinthAPIError" code:4
                                                       userInfo:@{NSLocalizedDescriptionKey: @"Failed to parse JSON"}];
            self.lastError = err;
            if (completion) completion(NO, err);
            return;
        }

        NSMutableArray<NSString *> *names = [NSMutableArray new];
        NSMutableArray<NSString *> *mcNames = [NSMutableArray new];
        NSMutableArray<NSString *> *urls = [NSMutableArray new];
        NSMutableArray<NSString *> *hashes = [NSMutableArray new];
        NSMutableArray<NSString *> *sizes = [NSMutableArray new];
        NSMutableArray<NSString *> *fileNames = [NSMutableArray new];
        NSMutableArray<NSString *> *fileTypes = [NSMutableArray new];

        for (NSDictionary *version in jsonResult) {
            NSArray *files = version[@"files"];
            if (![files isKindOfClass:[NSArray class]] || files.count == 0) continue;
            NSDictionary *file = files.firstObject;

            [names addObject:version[@"name"] ?: @"Unknown"];
            NSArray *gameVersions = version[@"game_versions"];
            [mcNames addObject:[gameVersions isKindOfClass:[NSArray class]] ? gameVersions.firstObject : @""];
            [urls addObject:[MCIMMirror applyToURL:file[@"url"] ?: @""]];
            NSDictionary *hashesMap = file[@"hashes"];
            [hashes addObject:hashesMap[@"sha1"] ?: @""];
            [sizes addObject:file[@"size"] ?: @0];
            [fileNames addObject:file[@"filename"] ?: @""];
            [fileTypes addObject:version[@"version_type"] ?: @""];
        }

        item[@"versionNames"] = names;
        item[@"mcVersionNames"] = mcNames;
        item[@"versionSizes"] = sizes;
        item[@"versionUrls"] = urls;
        item[@"versionHashes"] = hashes;
        item[@"versionFileNames"] = fileNames;
        item[@"versionFileTypes"] = fileTypes;
        item[@"versionDetailsLoaded"] = @(YES);

        if (completion) completion(YES, nil);
    }];
    [task resume];
}

#pragma mark - Additional: ModpackAPI protocol methods (supporting all downloads)

- (NSString *)downloadURLForFile:(NSDictionary *)file {
    if ([file isKindOfClass:[NSDictionary class]]) {
        NSString *url = file[@"url"];
        if ([url isKindOfClass:[NSString class]] && url.length > 0) {
            return [MCIMMirror applyToURL:url];
        }
    }
    return @"";
}

- (BOOL)file:(NSDictionary *)file matchesProjectType:(NSString *)projectType {
    if (![file isKindOfClass:[NSDictionary class]]) return NO;
    NSString *fileName = file[@"filename"] ?: file[@"fileName"] ?: @"";
    NSString *extension = fileName.pathExtension.lowercaseString;
    NSArray *extensions = [self preferredFileExtensionsForProjectType:projectType];
    return extensions.count == 0 || [extensions containsObject:extension];
}

- (NSArray<NSString *> *)preferredFileExtensionsForProjectType:(NSString *)projectType {
    if ([projectType isEqualToString:@"shader"] ||
        [projectType isEqualToString:@"resourcepack"] ||
        [projectType isEqualToString:@"datapack"] ||
        [projectType isEqualToString:@"modpack"] ||
        [projectType isEqualToString:@"world"]) {
        return @[@"zip"];
    }
    return @[@"jar"];
}

- (NSMutableDictionary *)projectForFileHash:(NSString *)sha1 projectType:(NSString *)projectType {
    if (sha1.length == 0) return nil;
    NSDictionary *response = [self getEndpoint:@"version_file" params:@{@"hash": sha1}];
    if (![response isKindOfClass:[NSDictionary class]]) return nil;
    
    NSMutableDictionary *result = [NSMutableDictionary new];
    result[@"id"] = response[@"project_id"] ?: @"";
    result[@"title"] = response[@"name"] ?: @"";
    result[@"projectType"] = projectType ?: @"mod";
    result[@"version"] = response[@"version_number"] ?: @"";
    result[@"fileName"] = response[@"filename"] ?: @"";
    result[@"downloadUrl"] = [MCIMMirror applyToURL:[response[@"files"] firstObject][@"url"]] ?: @"";
    return result;
}

#pragma mark - Async Mod Search (recommended)

- (void)searchModWithFilters:(NSDictionary *)filters
                  completion:(void (^)(NSArray * _Nullable results, NSError * _Nullable error))completion {
    NSString *projectType = filters[@"projectType"];
    if (projectType.length == 0) {
        // Defensive fallback: search as a modpack when projectType is unspecified but isModpack is declared, so mods are not searched by mistake
        projectType = [filters[@"isModpack"] boolValue] ? @"modpack" : @"mod";
    }
    NSString *query = filters[@"query"] ?: filters[@"name"] ?: @"";
    NSNumber *limitNum = filters[@"limit"] ?: @50;
    int limit = [limitNum intValue];
    NSNumber *offsetNum = filters[@"offset"] ?: @0;
    int offset = [offsetNum intValue];
    
    NSMutableString *facetString = [NSMutableString new];
    [facetString appendString:@"["];
    [facetString appendFormat:@"[\"project_type:%@\"]", projectType];
    NSString *mcVersion = filters[@"mcVersion"] ?: filters[@"version"];
    if (mcVersion.length > 0) {
        [facetString appendFormat:@", [\"versions:%@\"]", mcVersion];
    }
    // Fix #50: the loader (the categories facet) must be passed to the Modrinth API, otherwise filtering by neoforge/fabric has no effect
    NSString *loader = filters[@"loader"] ?: filters[@"categories"];
    if (loader.length > 0) {
        [facetString appendFormat:@", [\"categories:%@\"]", loader];
    }
    [facetString appendString:@"]"];
    
    NSString *encodedQuery = [query stringByAddingPercentEncodingWithAllowedCharacters:[NSCharacterSet URLQueryAllowedCharacterSet]];
    NSString *encodedFacets = [facetString stringByAddingPercentEncodingWithAllowedCharacters:[NSCharacterSet URLQueryAllowedCharacterSet]];
    NSString *index = query.length > 0 ? @"relevance" : @"follows";
    NSString *urlString = [NSString stringWithFormat:@"%@/search?query=%@&limit=%d&offset=%d&facets=%@&index=%@",
                           self.baseURL, encodedQuery, limit, offset, encodedFacets, index];
    
    NSURL *url = [NSURL URLWithString:urlString];
    if (!url) {
        if (completion) {
            completion(nil, [NSError errorWithDomain:@"ModrinthAPIError" code:1 userInfo:@{NSLocalizedDescriptionKey: @"Invalid URL"}]);
        }
        return;
    }
    
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:url];
    request.timeoutInterval = 30.0;
    [request setValue:@"application/json" forHTTPHeaderField:@"Accept"];
    [request setValue:@"Flux-iOS/1.0" forHTTPHeaderField:@"User-Agent"];
    
    NSURLSession *session = [NSURLSession sharedSession];
    NSURLSessionDataTask *task = [session dataTaskWithRequest:request completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        if (error) { if (completion) completion(nil, error); return; }
        if (!data) { if (completion) completion(nil, [NSError errorWithDomain:@"ModrinthAPIError" code:2 userInfo:@{NSLocalizedDescriptionKey: @"No data"}]); return; }
        
        NSError *jsonError = nil;
        NSDictionary *json = [NSJSONSerialization JSONObjectWithData:data options:0 error:&jsonError];
        if (jsonError || ![json isKindOfClass:[NSDictionary class]]) {
            if (completion) completion(nil, jsonError ?: [NSError errorWithDomain:@"ModrinthAPIError" code:3 userInfo:@{NSLocalizedDescriptionKey: @"Invalid JSON"}]);
            return;
        }
        
        NSArray *hits = json[@"hits"];
        if (![hits isKindOfClass:[NSArray class]]) { if (completion) completion(@[], nil); return; }
        
        NSMutableArray *results = [NSMutableArray array];
        for (NSDictionary *item in hits) {
            if (![item isKindOfClass:[NSDictionary class]]) continue;
            NSMutableDictionary *modData = [NSMutableDictionary dictionary];
            modData[@"apiSource"] = @(1);
            modData[@"isModpack"] = @([item[@"project_type"] isEqualToString:@"modpack"]);
            modData[@"projectType"] = item[@"project_type"] ?: projectType;
            modData[@"id"] = item[@"project_id"] ?: item[@"slug"] ?: @"";
            modData[@"title"] = item[@"title"] ?: @"Unknown";
            modData[@"description"] = item[@"description"] ?: @"";
            modData[@"author"] = item[@"author"] ?: @"Unknown";
            modData[@"downloads"] = item[@"downloads"] ?: @0;
            modData[@"likes"] = item[@"follows"] ?: @0;
            modData[@"imageUrl"] = item[@"icon_url"] ?: @"";
            modData[@"categories"] = item[@"categories"] ?: @[];
            modData[@"lastUpdated"] = item[@"date_modified"] ?: @"";
            [results addObject:modData];
        }
        if (completion) completion(results, nil);
    }];
    [task resume];
}

- (void)getVersionsForModWithID:(NSString *)modID
                     completion:(void (^)(NSArray<ModVersion *> * _Nullable, NSError * _Nullable))completion {
    NSString *urlString = [NSString stringWithFormat:@"%@/project/%@/version", self.baseURL, modID];
    NSURL *url = [NSURL URLWithString:urlString];
    if (!url) {
        if (completion) completion(nil, [NSError errorWithDomain:@"ModrinthAPIError" code:1 userInfo:@{NSLocalizedDescriptionKey: @"Invalid URL"}]);
        return;
    }
    
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:url];
    request.timeoutInterval = 30.0;
    [request setValue:@"application/json" forHTTPHeaderField:@"Accept"];
    [request setValue:@"Flux-iOS/1.0" forHTTPHeaderField:@"User-Agent"];
    
    NSURLSession *session = [NSURLSession sharedSession];
    NSURLSessionDataTask *task = [session dataTaskWithRequest:request completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        if (error) { if (completion) completion(nil, error); return; }
        if (!data) { if (completion) completion(nil, [NSError errorWithDomain:@"ModrinthAPIError" code:2 userInfo:@{NSLocalizedDescriptionKey: @"No data"}]); return; }
        
        NSError *jsonError = nil;
        id jsonResult = [NSJSONSerialization JSONObjectWithData:data options:0 error:&jsonError];
        if (jsonError || ![jsonResult isKindOfClass:[NSArray class]]) {
            if (completion) completion(nil, jsonError ?: [NSError errorWithDomain:@"ModrinthAPIError" code:3 userInfo:@{NSLocalizedDescriptionKey: @"Invalid JSON"}]);
            return;
        }
        
        NSMutableArray<ModVersion *> *versions = [NSMutableArray array];
        for (NSDictionary *dict in jsonResult) {
            ModVersion *version = [[ModVersion alloc] initWithDictionary:dict];
            if (version) [versions addObject:version];
        }
        if (completion) completion(versions, nil);
    }];
    [task resume];
}

#pragma mark - Shader Search (dedicated methods)

- (void)searchShaderWithFilters:(NSDictionary *)filters
                     completion:(void (^)(NSArray * _Nullable, NSError * _Nullable))completion {
    NSMutableDictionary *shaderFilters = [filters mutableCopy];
    shaderFilters[@"projectType"] = @"shader";
    [self searchModWithFilters:shaderFilters completion:completion];
}

- (void)getVersionsForShaderWithID:(NSString *)shaderID
                        completion:(void (^)(NSArray<ShaderVersion *> * _Nullable, NSError * _Nullable))completion {
    if (shaderID.length == 0) {
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
    request.timeoutInterval = 30.0;
    [request setValue:@"application/json" forHTTPHeaderField:@"Accept"];
    [request setValue:@"Flux-iOS/1.0" forHTTPHeaderField:@"User-Agent"];

    NSURLSession *session = [NSURLSession sharedSession];
    NSURLSessionDataTask *task = [session dataTaskWithRequest:request completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        if (error) { if (completion) completion(nil, error); return; }
        if (!data) { if (completion) completion(nil, [NSError errorWithDomain:@"ModrinthAPIError" code:3 userInfo:@{NSLocalizedDescriptionKey: @"No data"}]); return; }

        NSError *jsonError = nil;
        id jsonResult = [NSJSONSerialization JSONObjectWithData:data options:0 error:&jsonError];
        if (jsonError || ![jsonResult isKindOfClass:[NSArray class]]) {
            if (completion) completion(nil, jsonError ?: [NSError errorWithDomain:@"ModrinthAPIError" code:4 userInfo:@{NSLocalizedDescriptionKey: @"Invalid JSON"}]);
            return;
        }

        NSMutableArray<ShaderVersion *> *versions = [NSMutableArray array];
        for (NSDictionary *dict in jsonResult) {
            ShaderVersion *version = [[ShaderVersion alloc] initWithDictionary:dict];
            if (version) [versions addObject:version];
        }
        if (completion) completion(versions, nil);
    }];
    [task resume];
}

#pragma mark - Server Projects search

/// Internal helper: issue one server or modpack search request
- (void)_searchServerWithProjectType:(NSString *)projectType
                              filters:(NSDictionary *)filters
                           completion:(void (^)(NSArray * _Nullable, NSError * _Nullable))completion {
    NSString *query = filters[@"query"] ?: filters[@"name"] ?: @"";
    NSNumber *limitNum = filters[@"limit"] ?: @30;
    int limit = [limitNum intValue];
    NSNumber *offsetNum = filters[@"offset"] ?: @0;
    int offset = [offsetNum intValue];

    NSMutableString *facetString = [NSMutableString new];
    [facetString appendString:@"["];
    [facetString appendFormat:@"[\"project_type:%@\"]", projectType];
    NSString *mcVersion = filters[@"mcVersion"] ?: filters[@"version"];
    if (mcVersion.length > 0) {
        [facetString appendFormat:@", [\"versions:%@\"]", mcVersion];
    }
    NSString *loader = filters[@"loader"] ?: filters[@"categories"];
    if (loader.length > 0) {
        [facetString appendFormat:@", [\"categories:%@\"]", loader];
    }
    [facetString appendString:@"]"];

    NSString *encodedQuery = [query stringByAddingPercentEncodingWithAllowedCharacters:[NSCharacterSet URLQueryAllowedCharacterSet]];
    NSString *encodedFacets = [facetString stringByAddingPercentEncodingWithAllowedCharacters:[NSCharacterSet URLQueryAllowedCharacterSet]];
    NSString *index = query.length > 0 ? @"relevance" : @"follows";
    NSString *urlString = [NSString stringWithFormat:@"%@/search?query=%@&limit=%d&offset=%d&facets=%@&index=%@",
                           self.baseURL, encodedQuery, limit, offset, encodedFacets, index];

    NSURL *url = [NSURL URLWithString:urlString];
    if (!url) {
        if (completion) completion(nil, [NSError errorWithDomain:@"ModrinthAPIError" code:1 userInfo:@{NSLocalizedDescriptionKey: @"Invalid URL"}]);
        return;
    }

    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:url];
    request.timeoutInterval = 30.0;
    [request setValue:@"application/json" forHTTPHeaderField:@"Accept"];
    [request setValue:@"Flux-iOS/1.0" forHTTPHeaderField:@"User-Agent"];

    NSURLSessionDataTask *task = [[NSURLSession sharedSession] dataTaskWithRequest:request completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        if (error) { if (completion) completion(nil, error); return; }
        if (!data) { if (completion) completion(nil, [NSError errorWithDomain:@"ModrinthAPIError" code:2 userInfo:@{NSLocalizedDescriptionKey: @"No data"}]); return; }

        NSError *jsonError = nil;
        NSDictionary *json = [NSJSONSerialization JSONObjectWithData:data options:0 error:&jsonError];
        if (jsonError || ![json isKindOfClass:[NSDictionary class]]) {
            if (completion) completion(nil, jsonError ?: [NSError errorWithDomain:@"ModrinthAPIError" code:3 userInfo:@{NSLocalizedDescriptionKey: @"Invalid JSON"}]);
            return;
        }

        NSArray *hits = json[@"hits"];
        if (![hits isKindOfClass:[NSArray class]]) { if (completion) completion(@[], nil); return; }

        NSMutableArray *results = [NSMutableArray array];
        for (NSDictionary *item in hits) {
            if (![item isKindOfClass:[NSDictionary class]]) continue;
            NSMutableDictionary *serverData = [NSMutableDictionary dictionary];
            serverData[@"apiSource"] = @(1);
            serverData[@"projectType"] = item[@"project_type"] ?: projectType;
            serverData[@"serverID"] = item[@"project_id"] ?: item[@"slug"] ?: @"";
            serverData[@"title"] = item[@"title"] ?: @"Unknown";
            serverData[@"description"] = item[@"description"] ?: @"";
            serverData[@"author"] = item[@"author"] ?: @"Unknown";
            serverData[@"downloads"] = item[@"downloads"] ?: @0;
            serverData[@"likes"] = item[@"follows"] ?: @0;
            serverData[@"icon_url"] = item[@"icon_url"] ?: @"";
            serverData[@"page_url"] = item[@"page_url"] ?: @"";
            serverData[@"categories"] = item[@"categories"] ?: @[];
            serverData[@"date_modified"] = item[@"date_modified"] ?: @"";
            [results addObject:serverData];
        }
        if (completion) completion(results, nil);
    }];
    [task resume];
}

- (void)searchServersWithFilters:(NSDictionary *)filters
                      completion:(void (^)(NSArray * _Nullable, NSError * _Nullable))completion {
    // Prefer project_type=server (Modrinth Server Projects, a 2026 feature)
    __weak typeof(self) weakSelf = self;
    [self _searchServerWithProjectType:@"server" filters:filters completion:^(NSArray * _Nullable serverResults, NSError * _Nullable error) {
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (error) {
            // The server type API is unavailable, so fall back to the modpack search directly
            NSLog(@"[ModrinthAPI] Server Projects search failed, falling back to modpack search: %@", error.localizedDescription);
            [strongSelf _searchServerWithProjectType:@"modpack" filters:filters completion:completion];
            return;
        }
        if (serverResults.count > 0) {
            if (completion) completion(serverResults, nil);
            return;
        }
        // The server type result is empty, so fall back to the modpack search (presenting them as "server modpacks")
        NSLog(@"[ModrinthAPI] Server Projects result is empty, falling back to modpack search");
        [strongSelf _searchServerWithProjectType:@"modpack" filters:filters completion:completion];
    }];
}

- (void)getServerDetailsForID:(NSString *)serverID
                   completion:(void (^)(NSDictionary * _Nullable, NSError * _Nullable))completion {
    if (serverID.length == 0) {
        if (completion) completion(nil, [NSError errorWithDomain:@"ModrinthAPIError" code:1 userInfo:@{NSLocalizedDescriptionKey: @"Invalid server ID"}]);
        return;
    }

    NSString *urlString = [NSString stringWithFormat:@"%@/project/%@", self.baseURL, serverID];
    NSURL *url = [NSURL URLWithString:urlString];
    if (!url) {
        if (completion) completion(nil, [NSError errorWithDomain:@"ModrinthAPIError" code:2 userInfo:@{NSLocalizedDescriptionKey: @"Invalid URL"}]);
        return;
    }

    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:url];
    request.timeoutInterval = 30.0;
    [request setValue:@"application/json" forHTTPHeaderField:@"Accept"];
    [request setValue:@"Flux-iOS/1.0" forHTTPHeaderField:@"User-Agent"];

    NSURLSessionDataTask *task = [[NSURLSession sharedSession] dataTaskWithRequest:request completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        if (error) { if (completion) completion(nil, error); return; }
        if (!data) { if (completion) completion(nil, [NSError errorWithDomain:@"ModrinthAPIError" code:3 userInfo:@{NSLocalizedDescriptionKey: @"No data"}]); return; }

        NSError *jsonError = nil;
        NSDictionary *json = [NSJSONSerialization JSONObjectWithData:data options:0 error:&jsonError];
        if (jsonError || ![json isKindOfClass:[NSDictionary class]]) {
            if (completion) completion(nil, jsonError ?: [NSError errorWithDomain:@"ModrinthAPIError" code:4 userInfo:@{NSLocalizedDescriptionKey: @"Invalid JSON"}]);
            return;
        }

        // Extract the key fields and normalize the field names so ServerItem.applyDetailData: can handle them
        NSMutableDictionary *details = [NSMutableDictionary dictionary];
        details[@"serverID"] = json[@"id"] ?: json[@"slug"] ?: @"";
        details[@"title"] = json[@"title"] ?: @"";
        details[@"description"] = json[@"description"] ?: @"";
        details[@"projectType"] = json[@"project_type"] ?: @"server";
        details[@"icon_url"] = json[@"icon_url"] ?: @"";
        details[@"page_url"] = json[@"page_url"] ?: @"";
        details[@"downloads"] = json[@"downloads"] ?: @0;
        details[@"likes"] = json[@"followers"] ?: @0;
        details[@"date_modified"] = json[@"updated"] ?: @"";

        // The details of a Server Project may include a server_address field directly
        id addrObj = json[@"server_address"] ?: json[@"ip"] ?: json[@"address"];
        if ([addrObj isKindOfClass:[NSString class]]) {
            NSString *addr = (NSString *)addrObj;
            if (addr.length > 0) {
                details[@"serverAddress"] = addr;
            }
        }
        // The associated modpack ID
        id mpIDObj = json[@"modpack_project_id"] ?: json[@"modpack_id"];
        if ([mpIDObj isKindOfClass:[NSString class]]) {
            NSString *mpID = (NSString *)mpIDObj;
            if (mpID.length > 0) {
                details[@"modpack_project_id"] = mpID;
            }
        }

        if (completion) completion(details, nil);
    }];
    [task resume];
}

#pragma mark - Modpack download (full handling)

- (void)downloader:(MinecraftResourceDownloadTask *)downloader
submitDownloadTasksFromPackage:(NSString *)packagePath
            toPath:(NSString *)destPath {
    NSError *error;
    UZKArchive *archive = [[UZKArchive alloc] initWithPath:packagePath error:&error];
    if (error) {
        [downloader finishDownloadWithErrorString:[NSString stringWithFormat:@"Failed to open modpack package: %@", error.localizedDescription]];
        return;
    }
    
    NSData *indexData = [archive extractDataFromFile:@"modrinth.index.json" error:&error];
    NSDictionary *indexDict = [NSJSONSerialization JSONObjectWithData:indexData options:kNilOptions error:&error];
    if (error) {
        [downloader finishDownloadWithErrorString:[NSString stringWithFormat:@"Failed to parse modrinth.index.json: %@", error.localizedDescription]];
        return;
    }
    
    NSArray *indexFiles = [indexDict[@"files"] isKindOfClass:[NSArray class]] ? indexDict[@"files"] : @[];
    downloader.progress.totalUnitCount = indexFiles.count;
    NSUInteger skippedEmptyURL = 0;
    NSUInteger skippedServerOnly = 0;
    for (NSDictionary *indexFile in indexFiles) {
        if (![indexFile isKindOfClass:[NSDictionary class]]) {
            downloader.progress.completedUnitCount++;
            continue;
        }
        // env field filtering: consistent with ModpackImportService, skip server-only files with env.client=="unsupported".
        NSDictionary *env = indexFile[@"env"];
        NSString *clientEnv = env[@"client"];
        if ([clientEnv isKindOfClass:[NSString class]] && [clientEnv isEqualToString:@"unsupported"]) {
            skippedServerOnly++;
            downloader.progress.completedUnitCount++;
            NSLog(@"[ModrinthAPI] Skipping server-only file: %@", indexFile[@"path"]);
            continue;
        }
        NSString *rawUrl = [indexFile[@"downloads"] isKindOfClass:[NSArray class]] ? [indexFile[@"downloads"] firstObject] : nil;
        // Apply the MCIM mirror (when enabled) to speed up modpack file downloads in mainland China
        NSString *url = [MCIMMirror applyToURL:rawUrl];
        NSString *sha = indexFile[@"hashes"][@"sha1"];
        NSString *path = [destPath stringByAppendingPathComponent:indexFile[@"path"]];
        NSUInteger size = [indexFile[@"fileSize"] unsignedLongLongValue];
        // Key fix: an empty URL must not silently completedUnitCount++ and skip, because the user would not notice the file was missing
        // even though there was no link to download. It is logged as a warning and progress advances (so nothing hangs), but it is not treated as fatal.
        // Phase 5 fix (modeled on FCL): files with a missing URL are also recorded in failedFiles and reported in the final summary
        // to the user, so an "incomplete download" is not silently hidden.
        if (!url || ![url isKindOfClass:[NSString class]] || url.length == 0) {
            skippedEmptyURL++;
            downloader.progress.completedUnitCount++;
            NSLog(@"[ModrinthAPI] Warning: Modrinth file %@ missing download URL, skipping", indexFile[@"path"]);
            @synchronized(downloader.failedFiles) {
                [downloader.failedFiles addObject:@{
                    @"name": indexFile[@"path"] ?: @"(unknown)",
                    @"error": @"Missing download URL (downloads is empty in modrinth.index.json)"
                }];
            }
            continue;
        }
        NSURLSessionDownloadTask *task = [downloader createDownloadTask:url size:size sha:sha altName:nil toPath:path];
        if (task) {
            [downloader.fileList addObject:indexFile[@"path"]];
            [task resume];
        } else if (!downloader.progress.cancelled) {
            downloader.progress.completedUnitCount++;
        } else {
            return;
        }
    }
    if (skippedEmptyURL > 0 || skippedServerOnly > 0) {
        NSLog(@"[ModrinthAPI] Modpack download: skipped %lu empty URLs, %lu server-only files", (unsigned long)skippedEmptyURL, (unsigned long)skippedServerOnly);
    }
    
    [ModpackUtils archive:archive extractDirectory:@"overrides" toPath:destPath error:&error];
    if (error) {
        [downloader finishDownloadWithErrorString:[NSString stringWithFormat:@"Failed to extract overrides: %@", error.localizedDescription]];
        return;
    }
    
    [ModpackUtils archive:archive extractDirectory:@"client-overrides" toPath:destPath error:&error];
    if (error) {
        [downloader finishDownloadWithErrorString:[NSString stringWithFormat:@"Failed to extract client-overrides: %@", error.localizedDescription]];
        return;
    }
    
    [NSFileManager.defaultManager removeItemAtPath:packagePath error:nil];

    NSDictionary<NSString *, NSString *> *depInfo = [ModpackUtils infoForDependencies:indexDict[@"dependencies"]];
    NSString *profileName = indexDict[@"name"] ?: destPath.lastPathComponent;
    NSString *gameDirRelative = [NSString stringWithFormat:@"./custom_gamedir/%@", destPath.lastPathComponent];
    NSString *tmpIconPath = [NSTemporaryDirectory() stringByAppendingPathComponent:@"icon.png"];
    NSString *iconBase64 = [NSString stringWithFormat:@"data:image/png;base64,%@",
                            [[NSData dataWithContentsOfFile:tmpIconPath] base64EncodedStringWithOptions:0]];

    // Set the profile immediately, so the modpack shows up in the profile list after installation (even if the loader installation fails)
    PLProfiles.current.profiles[profileName] = @{
        @"gameDir": gameDirRelative,
        @"name": profileName,
        @"lastVersionId": depInfo[@"id"] ?: @"",
        @"icon": iconBase64
    }.mutableCopy;
    PLProfiles.current.selectedProfileName = profileName;

    if (depInfo[@"json"]) {
        // Fabric/Quilt: download the version JSON directly and trigger the full version download
        NSString *jsonPath = [NSString stringWithFormat:@"%1$s/versions/%2$@/%2$@.json", getenv("POJAV_GAME_DIR"), depInfo[@"id"]];
        NSURLSessionDownloadTask *task = [downloader createDownloadTask:depInfo[@"json"] size:0 sha:nil altName:nil toPath:jsonPath success:^{
            [downloader downloadVersion:@{@"id": depInfo[@"id"]}];
        }];
        [task resume];
    } else if (depInfo[@"installer"] && [(NSString *)depInfo[@"installer"] length] > 0) {
        // Forge/NeoForge: download installer.jar and call the direct installer to write the full version.json and download the libraries
        // Not handling this branch used to mean that after a modpack install only the profile was set and no version JSON was downloaded,
        // so launching reported "version information not found".
        NSString *versionId = depInfo[@"id"];
        NSString *loader = depInfo[@"loader"];
        NSString *customGameDir = destPath;  // The modpack's isolated directory (mods/saves/configs)
        NSString *installerPath = [NSTemporaryDirectory() stringByAppendingPathComponent:
                                   [NSString stringWithFormat:@"%@-installer.jar", versionId]];

        NSURLSessionDownloadTask *task = [downloader createDownloadTask:depInfo[@"installer"]
                                                                   size:0 sha:nil altName:nil
                                                                 toPath:installerPath success:^{
            // The direct installer is synchronous and slow, so it runs on a background thread to avoid blocking the main thread
            dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
                NSError *installError = nil;
                BOOL installSuccess = NO;
                if ([loader isEqualToString:@"NeoForge"]) {
                    installSuccess = [NeoForgeDirectInstaller installNeoForgeFromInstaller:installerPath
                                                                                  versionId:versionId
                                                                              customGameDir:customGameDir
                                                                        skipRegisterVersion:YES
                                                                                   progress:nil
                                                                                     error:&installError];
                } else {
                    installSuccess = [ForgeDirectInstaller installForgeFromInstaller:installerPath
                                                                           versionId:versionId
                                                                       customGameDir:customGameDir
                                                                 skipRegisterVersion:YES
                                                                            progress:nil
                                                                               error:&installError];
                }
                // Clean up the temporary installer.jar
                [NSFileManager.defaultManager removeItemAtPath:installerPath error:nil];
                if (!installSuccess) {
                    NSLog(@"[ModrinthAPI] %@ direct install failed: %@", loader, installError.localizedDescription);
                    // Write the placeholder JSON, so launching reports an error explicitly instead of being mistaken for vanilla
                    [ModpackUtils writePlaceholderVersionJSONForVersionId:versionId
                                                          minecraftVersion:depInfo[@"minecraftVersion"]
                                                                    loader:loader
                                                            loaderVersion:depInfo[@"loaderVersion"]
                                                                     error:installError];
                } else {
                    NSLog(@"[ModrinthAPI] %@ direct install succeeded, version.json written: %@", loader, versionId);
                    // Phase 5 fix (modeled on FCL ModpackHelper.ensureCompleteVersion):
                    // the direct installer only wrote the loader's version.json and the Forge/NeoForge libraries,
                    // while vanilla MC's libraries and assets have not been downloaded yet.
                    // downloadVersion: is triggered so MinecraftResourceDownloadTask downloads the complete version files.
                    // downloadVersion: handles inheritsFrom internally and skips files that already exist automatically.
                    [downloader downloadVersion:@{@"id": versionId}];
                }
            });
        }];
        [task resume];
    }
}

@end