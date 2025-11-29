#import "MinecraftResourceDownloadTask.h"
#import "ModrinthAPI.h"
#import "ModpackConfiguration.h"
#import "PLProfiles.h"
#import <CommonCrypto/CommonDigest.h>

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
        [facetString appendFormat:@",[\"versions:%@\"]", searchFilters[@"mcVersion"]];
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

- (void)downloader:(MinecraftResourceDownloadTask *)downloader submitDownloadTasksFromPackage:(NSString *)packagePath toPath:(NSString *)destPath {
    NSError *error;
    
    // 检查是否为本地文件路径
    BOOL isLocalFile = [packagePath hasPrefix:@"file://"];
    if (isLocalFile) {
        packagePath = [packagePath substringFromIndex:7]; // 移除 file:// 前缀
    }
    
    // 检查是否为 .mrpack 文件（Modrinth 格式）
    BOOL isMrpack = [[packagePath lowercaseString] hasSuffix:@".mrpack"];
    
    UZKArchive *archive = [[UZKArchive alloc] initWithPath:packagePath error:&error];
    if (error) {
        [downloader finishDownloadWithErrorString:[NSString stringWithFormat:@"Failed to open modpack package: %@", error.localizedDescription]];
        return;
    }

    NSData *indexData;
    if (isMrpack) {
        // .mrpack 格式使用 modrinth.index.json
        indexData = [archive extractDataFromFile:@"modrinth.index.json" error:&error];
    } else {
        // 尝试查找其他格式的索引文件
        indexData = [archive extractDataFromFile:@"modrinth.index.json" error:&error];
        if (!indexData) {
            indexData = [archive extractDataFromFile:@"manifest.json" error:&error];
        }
    }
    
    if (!indexData) {
        [downloader finishDownloadWithErrorString:[NSString stringWithFormat:@"Failed to find modpack index file: %@", error.localizedDescription]];
        return;
    }
    
    NSDictionary* indexDict = [NSJSONSerialization JSONObjectWithData:indexData options:kNilOptions error:&error];
    if (error) {
        [downloader finishDownloadWithErrorString:[NSString stringWithFormat:@"Failed to parse modpack index file: %@", error.localizedDescription]];
        return;
    }

    // 创建并保存整合包配置
    ModpackConfiguration *config = [[ModpackConfiguration alloc] initWithName:indexDict[@"name"] 
                                                                   version:indexDict[@"versionId"] 
                                                              gameVersion:indexDict[@"gameVersion"]];
    config.author = indexDict[@"author"];
    config.description = indexDict[@"summary"];
    config.dependencies = indexDict[@"dependencies"];
    
    // 解析文件列表
    NSMutableArray<ModpackFileInformation *> *files = [NSMutableArray array];
    NSArray *filesArray = indexDict[@"files"];
    if ([filesArray isKindOfClass:[NSArray class]]) {
        for (NSDictionary *fileDict in filesArray) {
            if ([fileDict isKindOfClass:[NSDictionary class]]) {
                ModpackFileInformation *fileInfo = [[ModpackFileInformation alloc] initWithDictionary:fileDict];
                if (fileInfo) {
                    [files addObject:fileInfo];
                }
            }
        }
    }
    config.files = [files copy];
    
    // 保存配置文件
    NSString *configPath = [destPath stringByAppendingPathComponent:@"modpack.json"];
    [config saveToFile:configPath error:&error];
    if (error) {
        NSLog(@"[ModrinthAPI] Warning: Failed to save modpack configuration: %@", error.localizedDescription);
    }

    // 计算总文件大小（修复进度条问题）
    NSUInteger totalSize = 0;
    for (ModpackFileInformation *fileInfo in config.files) {
        totalSize += fileInfo.fileSize;
    }
    downloader.progress.totalUnitCount = totalSize;
    downloader.textProgress.totalUnitCount = totalSize;
    
    // 下载文件（添加重试机制）
    __block NSUInteger completedSize = 0;
    __block NSMutableArray *failedDownloads = [NSMutableArray array];
    
    for (ModpackFileInformation *fileInfo in config.files) {
        NSString *path = [destPath stringByAppendingPathComponent:fileInfo.path];
        
        // 检查文件是否已存在且校验通过
        if ([NSFileManager.defaultManager fileExistsAtPath:path]) {
            if ([self verifyFileHash:path expectedHash:fileInfo.fileHash]) {
                completedSize += fileInfo.fileSize;
                downloader.progress.completedUnitCount = completedSize;
                downloader.textProgress.completedUnitCount = completedSize;
                continue;
            }
        }
        
        // 创建下载任务
        __block NSInteger retryCount = 0;
        __block NSURLSessionDownloadTask *task = nil;
        
        void (^attemptDownload)(void) = ^{
            task = [downloader createDownloadTask:fileInfo.downloadURL 
                                           size:fileInfo.fileSize 
                                            sha:fileInfo.fileHash 
                                        altName:nil 
                                          toPath:path 
                                        success:^{
                                            completedSize += fileInfo.fileSize;
                                            downloader.progress.completedUnitCount = completedSize;
                                            downloader.textProgress.completedUnitCount = completedSize;
                                        }];
            
            if (task) {
                [downloader.fileList addObject:fileInfo.path];
                
                // 设置失败重试
                task.taskDescription = fileInfo.path;
                [task resume];
            } else if (!downloader.progress.cancelled) {
                [failedDownloads addObject:fileInfo];
            }
        };
        
        attemptDownload();
    }

    // 提取覆盖文件
    [ModpackUtils archive:archive extractDirectory:@"overrides" toPath:destPath error:&error];
    if (error) {
        NSLog(@"[ModrinthAPI] Warning: Failed to extract overrides: %@", error.localizedDescription);
    }

    [ModpackUtils archive:archive extractDirectory:@"client-overrides" toPath:destPath error:&error];
    if (error) {
        NSLog(@"[ModrinthAPI] Warning: Failed to extract client-overrides: %@", error.localizedDescription);
    }

    // 删除临时包文件
    [NSFileManager.defaultManager removeItemAtPath:packagePath error:nil];

    // 下载依赖
    NSDictionary<NSString *, NSString *> *depInfo = [ModpackUtils infoForDependencies:indexDict[@"dependencies"]];
    if (depInfo[@"json"]) {
        // 设置完成回调
        downloader.modpackDownloadCompletion = ^{
            // 创建配置文件
            [self createProfileForModpack:config destPath:destPath depInfo:depInfo];
        };
        
        NSString *jsonPath = [NSString stringWithFormat:@"%1$s/versions/%2$@/%2$@.json", getenv("POJAV_GAME_DIR"), depInfo[@"id"]];
        NSURLSessionDownloadTask *task = [downloader createDownloadTask:depInfo[@"json"] 
                                                               size:0 
                                                                sha:nil 
                                                            altName:nil 
                                                              toPath:jsonPath 
                                                            success:^{
            NSDictionary *version = @{@"id": depInfo[@"id"]};
            [downloader downloadVersion:version];
        }];
        [task resume];
    } else {
        // 直接创建配置文件
        [self createProfileForModpack:config destPath:destPath depInfo:depInfo];
    }
}

- (BOOL)verifyFileHash:(NSString *)filePath expectedHash:(NSString *)expectedHash {
    if (!expectedHash || expectedHash.length == 0) {
        return [NSFileManager.defaultManager fileExistsAtPath:filePath];
    }
    
    NSData *data = [NSData dataWithContentsOfFile:filePath];
    if (!data) {
        return NO;
    }
    
    unsigned char digest[CC_SHA1_DIGEST_LENGTH];
    CC_SHA1(data.bytes, (CC_LONG)data.length, digest);
    NSMutableString *localSHA = [NSMutableString stringWithCapacity:CC_SHA1_DIGEST_LENGTH * 2];
    for(int i = 0; i < CC_SHA1_DIGEST_LENGTH; i++) {
        [localSHA appendFormat:@"%02x", digest[i]];
    }
    
    return [expectedHash isEqualToString:localSHA];
}

- (void)createProfileForModpack:(ModpackConfiguration *)config destPath:(NSString *)destPath depInfo:(NSDictionary *)depInfo {
    NSString *tmpIconPath = [NSTemporaryDirectory() stringByAppendingPathComponent:@"icon.png"];
    NSString *gameDir = [NSString stringWithFormat:@"./custom_gamedir/%@", destPath.lastPathComponent];
    
    NSMutableDictionary *profile = [NSMutableDictionary dictionary];
    profile[@"gameDir"] = gameDir;
    profile[@"name"] = config.name;
    profile[@"lastVersionId"] = depInfo[@"id"] ?: @"";
    
    NSData *iconData = [NSData dataWithContentsOfFile:tmpIconPath];
    if (iconData) {
        profile[@"icon"] = [NSString stringWithFormat:@"data:image/png;base64,%@",
                           [iconData base64EncodedStringWithOptions:0]];
    }
    
    PLProfiles.current.profiles[config.name] = profile.mutableCopy;
    PLProfiles.current.selectedProfileName = config.name;
    
    // 保存配置文件信息
    NSString *profileInfoPath = [NSString stringWithFormat:@"%s/custom_gamedir/%@/profile.json", 
                                getenv("POJAV_GAME_DIR"), destPath.lastPathComponent];
    NSDictionary *profileInfo = @{
        @"modpackName": config.name,
        @"modpackVersion": config.version,
        @"modpackAuthor": config.author ?: @"",
        @"gameVersion": config.gameVersion
    };
    NSData *jsonData = [NSJSONSerialization dataWithJSONObject:profileInfo 
                                                          options:NSJSONWritingPrettyPrinted 
                                                            error:nil];
    if (jsonData) {
        [jsonData writeToFile:profileInfoPath atomically:YES];
    }
}

@end