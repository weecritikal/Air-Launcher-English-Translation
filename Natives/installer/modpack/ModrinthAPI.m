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

/// 重写 baseURL getter，根据 MCIMMirror 偏好动态返回官方或镜像 URL
/// 这样所有使用 self.baseURL 的请求（搜索/版本列表/详情）都会自动走镜像
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

#pragma mark - Sync Search (支持 projectType)

- (NSMutableArray *)searchModWithFilters:(NSDictionary<NSString *, NSString *> *)searchFilters
                     previousPageResult:(NSMutableArray *)modrinthSearchResult {
    int limit = 50;
    NSString *projectType = searchFilters[@"projectType"];
    if (projectType.length == 0) {
        // 防御性回退：未指定 projectType 但声明 isModpack 时按整合包搜索，避免误搜 Mod
        projectType = [searchFilters[@"isModpack"] boolValue] ? @"modpack" : @"mod";
    }

    // 修复 #50: 必须把 loader（categories facet）传给 Modrinth API，否则筛选 neoforge/fabric 不生效
    // Modrinth 的 loader 类别：fabric / quilt / forge / neoforge / liteloader / rift 等
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

#pragma mark - Sync Load Details (修复数组赋值)

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

/// 异步加载整合包版本详情，避免 dispatch_group_wait 同步阻塞主线程/卡 UI
- (void)loadDetailsOfModAsync:(NSMutableDictionary *)item
                   completion:(void (^)(BOOL success, NSError * _Nullable error))completion {
    NSString *modID = item[@"id"];
    if (!modID || modID.length == 0) {
        if (completion) completion(NO, [NSError errorWithDomain:@"ModrinthAPIError" code:1
                                                       userInfo:@{NSLocalizedDescriptionKey: @"缺少 mod ID"}]);
        return;
    }

    NSString *urlString = [NSString stringWithFormat:@"%@/project/%@/version", self.baseURL, modID];
    NSURL *url = [NSURL URLWithString:urlString];
    if (!url) {
        if (completion) completion(NO, [NSError errorWithDomain:@"ModrinthAPIError" code:2
                                                       userInfo:@{NSLocalizedDescriptionKey: @"无效的 URL"}]);
        return;
    }

    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:url];
    request.timeoutInterval = 30.0;
    [request setValue:@"application/json" forHTTPHeaderField:@"Accept"];
    [request setValue:@"Amethyst-iOS/1.0" forHTTPHeaderField:@"User-Agent"];

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
                                           userInfo:@{NSLocalizedDescriptionKey: @"无数据返回"}];
            self.lastError = err;
            if (completion) completion(NO, err);
            return;
        }

        NSError *jsonError = nil;
        id jsonResult = [NSJSONSerialization JSONObjectWithData:data options:0 error:&jsonError];
        if (jsonError || ![jsonResult isKindOfClass:[NSArray class]]) {
            NSError *err = jsonError ?: [NSError errorWithDomain:@"ModrinthAPIError" code:4
                                                       userInfo:@{NSLocalizedDescriptionKey: @"JSON 解析失败"}];
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

#pragma mark - 补充：ModpackAPI 协议方法（支持所有下载）

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

#pragma mark - Async Mod Search (推荐使用)

- (void)searchModWithFilters:(NSDictionary *)filters
                  completion:(void (^)(NSArray * _Nullable results, NSError * _Nullable error))completion {
    NSString *projectType = filters[@"projectType"];
    if (projectType.length == 0) {
        // 防御性回退：未指定 projectType 但声明 isModpack 时按整合包搜索，避免误搜 Mod
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
    // 修复 #50: 必须把 loader（categories facet）传给 Modrinth API，否则筛选 neoforge/fabric 不生效
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
    [request setValue:@"Amethyst-iOS/1.0" forHTTPHeaderField:@"User-Agent"];
    
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
    [request setValue:@"Amethyst-iOS/1.0" forHTTPHeaderField:@"User-Agent"];
    
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

#pragma mark - Shader Search (专用方法)

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
    [request setValue:@"Amethyst-iOS/1.0" forHTTPHeaderField:@"User-Agent"];

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

#pragma mark - Server Projects 搜索

/// 内部工具：发起一次 server 或 modpack 的搜索请求
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
    [request setValue:@"Amethyst-iOS/1.0" forHTTPHeaderField:@"User-Agent"];

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
    // 优先使用 project_type=server（Modrinth Server Projects，2026 年新功能）
    __weak typeof(self) weakSelf = self;
    [self _searchServerWithProjectType:@"server" filters:filters completion:^(NSArray * _Nullable serverResults, NSError * _Nullable error) {
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (error) {
            // server 类型 API 不可用，直接回退到 modpack 搜索
            NSLog(@"[ModrinthAPI] Server Projects 搜索失败，回退到 modpack 搜索: %@", error.localizedDescription);
            [strongSelf _searchServerWithProjectType:@"modpack" filters:filters completion:completion];
            return;
        }
        if (serverResults.count > 0) {
            if (completion) completion(serverResults, nil);
            return;
        }
        // server 类型结果为空，回退到 modpack 搜索（作为"服务器整合包"展示）
        NSLog(@"[ModrinthAPI] Server Projects 结果为空，回退到 modpack 搜索");
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
    [request setValue:@"Amethyst-iOS/1.0" forHTTPHeaderField:@"User-Agent"];

    NSURLSessionDataTask *task = [[NSURLSession sharedSession] dataTaskWithRequest:request completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        if (error) { if (completion) completion(nil, error); return; }
        if (!data) { if (completion) completion(nil, [NSError errorWithDomain:@"ModrinthAPIError" code:3 userInfo:@{NSLocalizedDescriptionKey: @"No data"}]); return; }

        NSError *jsonError = nil;
        NSDictionary *json = [NSJSONSerialization JSONObjectWithData:data options:0 error:&jsonError];
        if (jsonError || ![json isKindOfClass:[NSDictionary class]]) {
            if (completion) completion(nil, jsonError ?: [NSError errorWithDomain:@"ModrinthAPIError" code:4 userInfo:@{NSLocalizedDescriptionKey: @"Invalid JSON"}]);
            return;
        }

        // 提取关键字段，统一字段命名以便 ServerItem.applyDetailData: 处理
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

        // Server Projects 详情可能直接包含 server_address 字段
        id addrObj = json[@"server_address"] ?: json[@"ip"] ?: json[@"address"];
        if ([addrObj isKindOfClass:[NSString class]]) {
            NSString *addr = (NSString *)addrObj;
            if (addr.length > 0) {
                details[@"serverAddress"] = addr;
            }
        }
        // 关联整合包 ID
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

#pragma mark - 整合包下载 (完整处理)

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
        // env 字段过滤：与 ModpackImportService 一致，跳过 env.client=="unsupported" 的服务端专用文件。
        NSDictionary *env = indexFile[@"env"];
        NSString *clientEnv = env[@"client"];
        if ([clientEnv isKindOfClass:[NSString class]] && [clientEnv isEqualToString:@"unsupported"]) {
            skippedServerOnly++;
            downloader.progress.completedUnitCount++;
            NSLog(@"[ModrinthAPI] 跳过 server-only 文件: %@", indexFile[@"path"]);
            continue;
        }
        NSString *rawUrl = [indexFile[@"downloads"] isKindOfClass:[NSArray class]] ? [indexFile[@"downloads"] firstObject] : nil;
        // 应用 MCIM 镜像（如果启用），加速国内整合包文件下载
        NSString *url = [MCIMMirror applyToURL:rawUrl];
        NSString *sha = indexFile[@"hashes"][@"sha1"];
        NSString *path = [destPath stringByAppendingPathComponent:indexFile[@"path"]];
        NSUInteger size = [indexFile[@"fileSize"] unsignedLongLongValue];
        // 关键修复：URL 为空时不能静默 completedUnitCount++ 跳过，否则用户不会感知缺失，
        // 但又没有可下载的链接。改为记录警告并推进进度（避免卡死），但不视为致命错误。
        // 阶段5修复（参照 FCL）：同时将缺失 URL 的文件记入 failedFiles，最终汇总报告
        // 给用户，避免"下载不完全"问题被静默隐藏。
        if (!url || ![url isKindOfClass:[NSString class]] || url.length == 0) {
            skippedEmptyURL++;
            downloader.progress.completedUnitCount++;
            NSLog(@"[ModrinthAPI] 警告：Modrinth 文件 %@ 缺少 download URL，跳过", indexFile[@"path"]);
            @synchronized(downloader.failedFiles) {
                [downloader.failedFiles addObject:@{
                    @"name": indexFile[@"path"] ?: @"(unknown)",
                    @"error": @"缺少 download URL（modrinth.index.json 中 downloads 为空）"
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
        NSLog(@"[ModrinthAPI] 整合包下载：跳过空 URL %lu 个，server-only %lu 个", (unsigned long)skippedEmptyURL, (unsigned long)skippedServerOnly);
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

    // 立即设置 profile，确保整合包安装后能从 profile 列表中看到（即使加载器安装失败）
    PLProfiles.current.profiles[profileName] = @{
        @"gameDir": gameDirRelative,
        @"name": profileName,
        @"lastVersionId": depInfo[@"id"] ?: @"",
        @"icon": iconBase64
    }.mutableCopy;
    PLProfiles.current.selectedProfileName = profileName;

    if (depInfo[@"json"]) {
        // Fabric/Quilt：直接下载 version JSON 并触发版本完整下载
        NSString *jsonPath = [NSString stringWithFormat:@"%1$s/versions/%2$@/%2$@.json", getenv("POJAV_GAME_DIR"), depInfo[@"id"]];
        NSURLSessionDownloadTask *task = [downloader createDownloadTask:depInfo[@"json"] size:0 sha:nil altName:nil toPath:jsonPath success:^{
            [downloader downloadVersion:@{@"id": depInfo[@"id"]}];
        }];
        [task resume];
    } else if (depInfo[@"installer"] && [(NSString *)depInfo[@"installer"] length] > 0) {
        // Forge/NeoForge：下载 installer.jar 并调用直装器写入完整的 version.json + 下载库
        // 之前不处理这个分支会导致整合包安装后只设置 profile 但不下载版本 JSON，
        // 启动时报"找不到版本信息"。
        NSString *versionId = depInfo[@"id"];
        NSString *loader = depInfo[@"loader"];
        NSString *customGameDir = destPath;  // 整合包隔离目录（mods/saves/configs）
        NSString *installerPath = [NSTemporaryDirectory() stringByAppendingPathComponent:
                                   [NSString stringWithFormat:@"%@-installer.jar", versionId]];

        NSURLSessionDownloadTask *task = [downloader createDownloadTask:depInfo[@"installer"]
                                                                   size:0 sha:nil altName:nil
                                                                 toPath:installerPath success:^{
            // 直装器是同步且耗时的，放到后台线程执行，避免阻塞主线程
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
                // 清理临时 installer.jar
                [NSFileManager.defaultManager removeItemAtPath:installerPath error:nil];
                if (!installSuccess) {
                    NSLog(@"[ModrinthAPI] %@ 直装失败: %@", loader, installError.localizedDescription);
                    // 写入占位 JSON，启动时显式报错而非误装作 vanilla
                    [ModpackUtils writePlaceholderVersionJSONForVersionId:versionId
                                                          minecraftVersion:depInfo[@"minecraftVersion"]
                                                                    loader:loader
                                                            loaderVersion:depInfo[@"loaderVersion"]
                                                                     error:installError];
                } else {
                    NSLog(@"[ModrinthAPI] %@ 直装成功，version.json 已写入: %@", loader, versionId);
                    // 阶段5修复（参照 FCL ModpackHelper.ensureCompleteVersion）：
                    // 直装器只写入了 loader 的 version.json + Forge/NeoForge 库，
                    // 但原版 MC 的 libraries 和 assets 还没下载。
                    // 触发 downloadVersion: 让 MinecraftResourceDownloadTask 下载完整版本文件。
                    // downloadVersion: 内部会处理 inheritsFrom，对已存在的文件自动跳过。
                    [downloader downloadVersion:@{@"id": versionId}];
                }
            });
        }];
        [task resume];
    }
}

@end