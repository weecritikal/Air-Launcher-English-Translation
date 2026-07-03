#import "MinecraftResourceDownloadTask.h"
#import "ModrinthAPI.h"
#import "PLProfiles.h"
#import "ModpackUtils.h"
#import "UZKArchive.h"

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

        if (completion) completion(YES, nil);
    }];
    [task resume];
}

#pragma mark - 补充：ModpackAPI 协议方法（支持所有下载）

- (NSString *)downloadURLForFile:(NSDictionary *)file {
    if ([file isKindOfClass:[NSDictionary class]]) {
        NSString *url = file[@"url"];
        if ([url isKindOfClass:[NSString class]] && url.length > 0) {
            return url;
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
    result[@"downloadUrl"] = [response[@"files"] firstObject][@"url"] ?: @"";
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
            return;
        }
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
    if (depInfo[@"json"]) {
        downloader.modpackDownloadCompletion = ^{
            NSString *tmpIconPath = [NSTemporaryDirectory() stringByAppendingPathComponent:@"icon.png"];
            PLProfiles.current.profiles[indexDict[@"name"]] = @{
                @"gameDir": [NSString stringWithFormat:@"./custom_gamedir/%@", destPath.lastPathComponent],
                @"name": indexDict[@"name"],
                @"lastVersionId": depInfo[@"id"] ?: @"",
                @"icon": [NSString stringWithFormat:@"data:image/png;base64,%@",
                    [[NSData dataWithContentsOfFile:tmpIconPath] base64EncodedStringWithOptions:0]]
            }.mutableCopy;
            PLProfiles.current.selectedProfileName = indexDict[@"name"];
        };
        NSString *jsonPath = [NSString stringWithFormat:@"%1$s/versions/%2$@/%2$@.json", getenv("POJAV_GAME_DIR"), depInfo[@"id"]];
        NSURLSessionDownloadTask *task = [downloader createDownloadTask:depInfo[@"json"] size:0 sha:nil altName:nil toPath:jsonPath success:^{
            [downloader downloadVersion:@{@"id": depInfo[@"id"]}];
        }];
        [task resume];
    } else {
        NSString *tmpIconPath = [NSTemporaryDirectory() stringByAppendingPathComponent:@"icon.png"];
        PLProfiles.current.profiles[indexDict[@"name"]] = @{
            @"gameDir": [NSString stringWithFormat:@"./custom_gamedir/%@", destPath.lastPathComponent],
            @"name": indexDict[@"name"],
            @"lastVersionId": depInfo[@"id"] ?: @"",
            @"icon": [NSString stringWithFormat:@"data:image/png;base64,%@",
                [[NSData dataWithContentsOfFile:tmpIconPath] base64EncodedStringWithOptions:0]]
        }.mutableCopy;
        PLProfiles.current.selectedProfileName = indexDict[@"name"];
    }
}

@end