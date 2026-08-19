#import "CurseForgeAPI.h"
#import "AFNetworking.h"
#import "MinecraftResourceDownloadTask.h"
#import "PLProfiles.h"
#import "PLPreferences.h"
#import "config.h"
#import "ModpackUtils.h"
#import "UZKArchive.h"
#import "installer/ForgeDirectInstaller.h"
#import "installer/NeoForgeDirectInstaller.h"
#import "MCIMMirror.h"

// CurseForge static constants
static const NSInteger kCurseForgeGameIDMinecraft = 432;
static const NSInteger kCurseForgeClassIDBukkitPlugins = 5;
static const NSInteger kCurseForgeClassIDMods = 6;
static const NSInteger kCurseForgeClassIDResourcePacks = 12;
static const NSInteger kCurseForgeClassIDWorlds = 17;
static const NSInteger kCurseForgeClassIDModpacks = 4471;
static const NSInteger kCurseForgeClassIDShaders = 6552;
static const NSInteger kCurseForgeClassIDDataPacks = 6945;
static const NSInteger kCurseForgeCategoryIDServerUtility = 435;

// NSError userInfo keys for diagnostic information
NSString *const CurseForgeResponseContentTypeKey = @"CurseForgeResponseContentTypeKey";
NSString *const CurseForgeResponseSnippetKey = @"CurseForgeResponseSnippetKey";

/// Safely obtain the compile-time CurseForge API key (avoiding the invalid expression @nil)
/// See the CFKCompiledAPIKey() implementation in CurseForgeAPIKeyViewController.m
static NSString *CFACompiledAPIKey(void) {
#define CFA_STR_INNER(x) #x
#define CFA_STR(x) CFA_STR_INNER(x)
    NSString *compiledKey = [NSString stringWithUTF8String:CFA_STR(CONFIG_CURSEFORGE_API_KEY)];
#undef CFA_STR
#undef CFA_STR_INNER
    // Handle the quotes around the string literal (when the CONFIG_CURSEFORGE_API_KEY macro is defined as "actual_key", stringifying it yields "\"actual_key\"")
    if (compiledKey.length >= 2 && [compiledKey hasPrefix:@"\""] && [compiledKey hasSuffix:@"\""]) {
        compiledKey = [compiledKey substringWithRange:NSMakeRange(1, compiledKey.length - 2)];
    }
    // When the macro is undefined, stringifying it in the preprocessor yields the macro name itself, "CONFIG_CURSEFORGE_API_KEY", or "nil" when it is nil
    if ([compiledKey isEqualToString:@"nil"] || compiledKey.length == 0 ||
        [compiledKey isEqualToString:@"CONFIG_CURSEFORGE_API_KEY"]) {
        return @"";
    }
    return compiledKey;
}

@interface CurseForgeAPI ()
@property (nonatomic, strong) NSURLSession *session;   // Used for asynchronous requests
// Error diagnostics helper: wrap the HTTP response information into the NSError userInfo
- (NSError *)errorWithResponse:(NSURLResponse *)response
                          data:(NSData *)data
                 originalError:(NSError *)originalError
                       snippet:(NSString *)snippet;
// Debug logging helper: print the full details of a request/response/JSON parse error
- (void)debugLogRequest:(NSURLRequest *)request
               response:(NSURLResponse *)response
                   data:(NSData *)data
              jsonError:(NSError *)jsonError;
// Convert NSData into a printable string (handling non-UTF-8 content, up to maxLen bytes)
- (NSString *)printableStringFromData:(NSData *)data maxLen:(NSUInteger)maxLen;
@end

@implementation CurseForgeAPI

/// Override the baseURL getter to return the official or the mirror URL dynamically, based on the MCIMMirror preference
/// This way every request that uses self.baseURL goes through the mirror automatically
- (NSString *)baseURL {
    return [MCIMMirror curseForgeAPIBaseURL];
}

+ (instancetype)sharedInstance {
    static CurseForgeAPI *sharedInstance = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        sharedInstance = [[self alloc] init];
    });
    return sharedInstance;
}

- (instancetype)init {
    self = [super initWithURL:@"https://api.curseforge.com/v1"];
    if (self) {
        _session = [NSURLSession sharedSession];
    }
    return self;
}

#pragma mark - API key and headers

- (NSString *)apiKey {
    // 1. Runtime preference (the highest priority)
    NSString *runtimeKey = [PLPreferences curseForgeAPIKey];
    if ([runtimeKey isKindOfClass:NSString.class] && runtimeKey.length > 0) {
        NSLog(@"[CurseForgeAPI] API Key source: runtime preference (length=%lu, prefix=%@...)",
              (unsigned long)runtimeKey.length,
              runtimeKey.length >= 8 ? [runtimeKey substringToIndex:8] : runtimeKey);
        return runtimeKey;
    }
    // 2. Compile-time macro (using the stringification approach, to avoid the @nil edge case)
    NSString *compiledKey = CFACompiledAPIKey();
    if (compiledKey.length > 0) {
        NSLog(@"[CurseForgeAPI] API Key source: compile-time macro (length=%lu, prefix=%@...)",
              (unsigned long)compiledKey.length,
              compiledKey.length >= 8 ? [compiledKey substringToIndex:8] : compiledKey);
        return compiledKey;
    }
    // 3. Info.plist
    NSString *infoPlistKey = [[NSBundle mainBundle] objectForInfoDictionaryKey:@"CurseForgeAPIKey"];
    if ([infoPlistKey isKindOfClass:NSString.class] && infoPlistKey.length > 0) {
        NSLog(@"[CurseForgeAPI] API Key source: Info.plist (length=%lu, prefix=%@...)",
              (unsigned long)infoPlistKey.length,
              infoPlistKey.length >= 8 ? [infoPlistKey substringToIndex:8] : infoPlistKey);
        return infoPlistKey;
    }
    NSLog(@"[CurseForgeAPI] Warning: API Key not configured!");
    return @"";
}

- (NSDictionary *)headers {
    NSString *key = [self apiKey];
    if (key.length == 0) {
        return nil;
    }
    return @{
        @"Accept": @"application/json",
        @"x-api-key": key
    };
}

+ (BOOL)isAPIKeyConfigured {
    // The same three-level fallback as the apiKey getter, so the UI gating and the actual request check cannot disagree
    NSString *runtimeKey = [PLPreferences curseForgeAPIKey];
    if ([runtimeKey isKindOfClass:NSString.class] && runtimeKey.length > 0) {
        return YES;
    }
    NSString *compiledKey = CFACompiledAPIKey();
    if (compiledKey.length > 0) {
        return YES;
    }
    NSString *infoPlistKey = [[NSBundle mainBundle] objectForInfoDictionaryKey:@"CurseForgeAPIKey"];
    if ([infoPlistKey isKindOfClass:NSString.class] && infoPlistKey.length > 0) {
        return YES;
    }
    return NO;
}

- (NSError *)missingAPIKeyError {
    return [NSError errorWithDomain:@"CurseForgeAPI"
                               code:401
                           userInfo:@{NSLocalizedDescriptionKey: @"CurseForge API key is missing. Set CURSEFORGE_API_KEY before building."}];
}

#pragma mark - Error diagnostics helpers

- (NSError *)errorWithResponse:(NSURLResponse *)response
                          data:(NSData *)data
                 originalError:(NSError *)originalError
                       snippet:(NSString *)snippet {
    NSHTTPURLResponse *httpResponse = [response isKindOfClass:[NSHTTPURLResponse class]] ? (NSHTTPURLResponse *)response : nil;
    NSInteger statusCode = httpResponse.statusCode;
    NSString *contentType = httpResponse.allHeaderFields[@"Content-Type"];

    // Take the first 1024 bytes of the response body as the snippet (if the caller did not supply one)
    if (!snippet && data.length > 0) {
        snippet = [self printableStringFromData:data maxLen:1024];
    }

    // Build the userInfo
    NSMutableDictionary *userInfo = [NSMutableDictionary dictionary];
    if (originalError) {
        [userInfo addEntriesFromDictionary:originalError.userInfo];
        if (originalError.localizedDescription.length > 0) {
            userInfo[NSLocalizedDescriptionKey] = originalError.localizedDescription;
        }
    } else {
        userInfo[NSLocalizedDescriptionKey] = @"CurseForge API request failed";
    }
    if (statusCode > 0) {
        userInfo[@"CurseForgeHTTPStatusCodeKey"] = @(statusCode);
    }
    if (contentType.length > 0) {
        userInfo[CurseForgeResponseContentTypeKey] = contentType;
    }
    if (snippet.length > 0) {
        userInfo[CurseForgeResponseSnippetKey] = snippet;
    }

    // Print the diagnostic log
    NSLog(@"[CurseForgeAPI] ❌ Request failed - statusCode=%ld, contentType=%@, error=%@, snippet=%@",
          (long)statusCode, contentType, originalError.localizedDescription, snippet);

    return [NSError errorWithDomain:@"CurseForgeAPI"
                               code:originalError.code ?: 0
                           userInfo:[userInfo copy]];
}

#pragma mark - Debug logging helpers

// Convert NSData into a printable string (handling non-UTF-8 content, up to maxLen bytes)
- (NSString *)printableStringFromData:(NSData *)data maxLen:(NSUInteger)maxLen {
    if (!data || data.length == 0) return @"";
    NSUInteger len = MIN(data.length, maxLen);
    NSData *subData = [data subdataWithRange:NSMakeRange(0, len)];
    // Try UTF-8
    NSString *str = [[NSString alloc] initWithData:subData encoding:NSUTF8StringEncoding];
    if (str) return str;
    // Try ISO-8859-1 (Latin-1, which can decode any byte sequence)
    str = [[NSString alloc] initWithData:subData encoding:NSISOLatin1StringEncoding];
    if (str) return str;
    // Last resort: hexadecimal
    NSMutableString *hex = [NSMutableString stringWithCapacity:len * 3];
    const char *bytes = subData.bytes;
    for (NSUInteger i = 0; i < len; i++) {
        [hex appendFormat:@"%02x ", (unsigned char)bytes[i]];
    }
    return [NSString stringWithFormat:@"(non-text data, hex) %@", hex];
}

// Print the full debug log for a request/response/JSON parse error
- (void)debugLogRequest:(NSURLRequest *)request
               response:(NSURLResponse *)response
                   data:(NSData *)data
              jsonError:(NSError *)jsonError {
    NSHTTPURLResponse *httpResponse = [response isKindOfClass:[NSHTTPURLResponse class]] ? (NSHTTPURLResponse *)response : nil;
    NSInteger statusCode = httpResponse.statusCode;
    NSString *contentType = httpResponse.allHeaderFields[@"Content-Type"];
    NSURL *url = request.URL;
    NSString *method = request.HTTPMethod ?: @"GET";

    NSLog(@"\n"
          "========== [CurseForgeAPI] DEBUG ==========\n"
          "📍 Request: %@ %@\n"
          "📍 Request Headers:",
          method, url.absoluteString ?: @"<nil URL>");

    // Print the request headers (with the API key redacted)
    NSDictionary *reqHeaders = request.allHTTPHeaderFields ?: @{};
    for (NSString *key in reqHeaders) {
        NSString *value = reqHeaders[key];
        if ([key.lowercaseString containsString:@"api"] || [key.lowercaseString containsString:@"key"]) {
            // Show only the first 8 characters plus the length
            if (value.length > 8) {
                NSLog(@"    %@: %@... (len=%lu)", key, [value substringToIndex:8], (unsigned long)value.length);
            } else {
                NSLog(@"    %@: (len=%lu)", key, (unsigned long)value.length);
            }
        } else {
            NSLog(@"    %@: %@", key, value);
        }
    }

    NSLog(@"📍 Response: statusCode=%ld, contentType=%@, dataLength=%lu",
          (long)statusCode, contentType ?: @"<none>", (unsigned long)(data.length));

    if (httpResponse) {
        // Print the response headers (at most 20 of them)
        NSDictionary *respHeaders = httpResponse.allHeaderFields;
        NSUInteger i = 0;
        for (NSString *key in respHeaders) {
            if (i++ >= 20) break;
            NSLog(@"    %@: %@", key, respHeaders[key]);
        }
    }

    if (jsonError) {
        NSLog(@"📍 JSON Parse Error: domain=%@, code=%ld, desc=%@",
              jsonError.domain, (long)jsonError.code,
              jsonError.localizedDescription ?: @"<no description>");
    }

    if (data.length > 0) {
        NSString *bodyStr = [self printableStringFromData:data maxLen:2048];
        NSLog(@"📍 Response Body (first 2048 bytes):\n%@", bodyStr);
    } else {
        NSLog(@"📍 Response Body: (empty)");
    }
    NSLog(@"========== [CurseForgeAPI] END DEBUG ==========");
}

#pragma mark - Synchronous network requests (the original AFNetworking implementation, kept for compatibility)

- (id)getEndpoint:(NSString *)endpoint params:(NSDictionary *)params {
    NSDictionary *headers = [self headers];
    if (!headers) {
        self.lastError = [self missingAPIKeyError];
        return nil;
    }
    
    __block id result;
    dispatch_group_t group = dispatch_group_create();
    dispatch_group_enter(group);
    NSString *url = [self.baseURL stringByAppendingPathComponent:endpoint];
    AFHTTPSessionManager *manager = [AFHTTPSessionManager manager];
    [manager GET:url parameters:params headers:headers progress:nil
          success:^(NSURLSessionTask *task, id obj) {
        result = obj;
        dispatch_group_leave(group);
    } failure:^(NSURLSessionTask *operation, NSError *error) {
        self.lastError = error;
        dispatch_group_leave(group);
    }];
    dispatch_group_wait(group, DISPATCH_TIME_FOREVER);
    return result;
}

- (id)postEndpoint:(NSString *)endpoint params:(NSDictionary *)params {
    NSDictionary *headers = [self headers];
    if (!headers) {
        self.lastError = [self missingAPIKeyError];
        return nil;
    }
    
    __block id result;
    dispatch_group_t group = dispatch_group_create();
    dispatch_group_enter(group);
    NSString *url = [self.baseURL stringByAppendingPathComponent:endpoint];
    AFHTTPSessionManager *manager = [AFHTTPSessionManager manager];
    manager.requestSerializer = [AFJSONRequestSerializer serializer];
    [manager POST:url parameters:params headers:headers progress:nil
           success:^(NSURLSessionTask *task, id obj) {
        result = obj;
        dispatch_group_leave(group);
    } failure:^(NSURLSessionTask *operation, NSError *error) {
        self.lastError = error;
        dispatch_group_leave(group);
    }];
    dispatch_group_wait(group, DISPATCH_TIME_FOREVER);
    return result;
}

#pragma mark - Project type mapping

- (NSNumber *)classIDForProjectType:(NSString *)projectType {
    if ([projectType isEqualToString:@"modpack"]) {
        return @(kCurseForgeClassIDModpacks);
    }
    if ([projectType isEqualToString:@"plugin"]) {
        return @(kCurseForgeClassIDBukkitPlugins);
    }
    if ([projectType isEqualToString:@"datapack"]) {
        return @(kCurseForgeClassIDDataPacks);
    }
    if ([projectType isEqualToString:@"shader"]) {
        return @(kCurseForgeClassIDShaders);
    }
    if ([projectType isEqualToString:@"resourcepack"]) {
        return @(kCurseForgeClassIDResourcePacks);
    }
    if ([projectType isEqualToString:@"world"]) {
        return @(kCurseForgeClassIDWorlds);
    }
    return @(kCurseForgeClassIDMods);
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

#pragma mark - File validation and URL construction

- (BOOL)file:(NSDictionary *)file matchesProjectType:(NSString *)projectType {
    if (![file isKindOfClass:NSDictionary.class]) return NO;
    if ([file[@"isAvailable"] respondsToSelector:@selector(boolValue)] &&
        ![file[@"isAvailable"] boolValue]) {
        return NO;
    }
    if ([projectType isEqualToString:@"modpack"] && [file[@"isServerPack"] boolValue]) {
        return NO;
    }
    
    NSString *fileName = [file[@"fileName"] isKindOfClass:NSString.class] ? file[@"fileName"] : @"";
    NSString *extension = fileName.pathExtension.lowercaseString;
    NSArray *extensions = [self preferredFileExtensionsForProjectType:projectType];
    return extensions.count == 0 || [extensions containsObject:extension];
}

- (NSString *)imageURLForProject:(NSDictionary *)project {
    NSDictionary *logo = [project[@"logo"] isKindOfClass:NSDictionary.class] ? project[@"logo"] : nil;
    NSString *image = logo[@"thumbnailUrl"];
    if (![image isKindOfClass:NSString.class] || image.length == 0) {
        image = logo[@"url"];
    }
    return [image isKindOfClass:NSString.class] ? image : @"";
}

/// Map the CurseForge sort vocabulary used by the UI (which is Modrinth's) onto
/// CurseForge sortField ids: 1=Featured, 2=Popularity, 3=LastUpdated, 4=Name,
/// 5=Author, 6=TotalDownloads. Anything unrecognised falls back to Popularity,
/// which is what the CurseForge website shows by default. Without an explicit
/// sortField the API returns results in name order, which looked like noise.
+ (NSString *)curseForgeSortFieldForSort:(NSString *)sort {
    if ([sort isEqualToString:@"downloads"]) return @"6";
    if ([sort isEqualToString:@"updated"] || [sort isEqualToString:@"newest"]) return @"3";
    if ([sort isEqualToString:@"relevance"]) return @"1";
    return @"2"; // follows / unset -> Popularity
}

- (NSString *)authorNameForProject:(NSDictionary *)project {
    NSArray *authors = [project[@"authors"] isKindOfClass:NSArray.class] ? project[@"authors"] : @[];
    for (NSDictionary *author in authors) {
        if ([author isKindOfClass:NSDictionary.class] && [author[@"name"] isKindOfClass:NSString.class]) {
            return author[@"name"];
        }
    }
    return @"";
}

- (NSArray *)categoryNamesForProject:(NSDictionary *)project {
    NSArray *categories = [project[@"categories"] isKindOfClass:NSArray.class] ? project[@"categories"] : @[];
    NSMutableArray *names = [NSMutableArray new];
    for (NSDictionary *category in categories) {
        if ([category isKindOfClass:NSDictionary.class] && [category[@"name"] isKindOfClass:NSString.class]) {
            [names addObject:category[@"name"]];
        }
    }
    return names;
}

- (NSMutableDictionary *)projectFromCurseForgeProject:(NSDictionary *)project projectType:(NSString *)projectType {
    NSString *title = project[@"name"];
    NSString *description = project[@"summary"];
    NSString *dateModified = project[@"dateModified"];
    // The same keys Modrinth returns, so the shared cell renders both sources identically.
    // Without downloads/author/categories the list showed "0 downloads" for every row.
    return @{
        @"apiSource": @(2),
        @"isModpack": @([projectType isEqualToString:@"modpack"]),
        @"projectType": projectType ?: @"mod",
        @"id": [project[@"id"] description] ?: @"",
        @"title": [title isKindOfClass:NSString.class] ? title : @"",
        @"description": [description isKindOfClass:NSString.class] ? description : @"",
        @"imageUrl": [self imageURLForProject:project],
        @"author": [self authorNameForProject:project],
        @"downloads": [project[@"downloadCount"] isKindOfClass:NSNumber.class] ? project[@"downloadCount"] : @0,
        @"likes": [project[@"thumbsUpCount"] isKindOfClass:NSNumber.class] ? project[@"thumbsUpCount"] : @0,
        @"categories": [self categoryNamesForProject:project],
        @"lastUpdated": [dateModified isKindOfClass:NSString.class] ? dateModified : @""
    }.mutableCopy;
}

- (NSString *)sha1ForFile:(NSDictionary *)file {
    NSArray *hashes = [file[@"hashes"] isKindOfClass:NSArray.class] ? file[@"hashes"] : @[];
    for (NSDictionary *hash in hashes) {
        if ([hash[@"algo"] integerValue] == 1 && [hash[@"value"] isKindOfClass:NSString.class]) {
            return hash[@"value"];
        }
    }
    return @"";
}

- (NSString *)downloadURLForFile:(NSDictionary *)file {
    NSString *url = file[@"downloadUrl"];
    if ([url isKindOfClass:NSString.class] && url.length > 0) {
        return [MCIMMirror applyToURL:url];
    }
    
    NSString *modId = [file[@"modId"] description];
    NSString *fileId = [file[@"id"] description];
    if (modId.length == 0 || fileId.length == 0) {
        return @"";
    }
    NSDictionary *response = [self getEndpoint:[NSString stringWithFormat:@"mods/%@/files/%@/download-url", modId, fileId] params:nil];
    NSString *fallback = [response isKindOfClass:NSDictionary.class] ? response[@"data"] : nil;
    if ([fallback isKindOfClass:NSString.class] && fallback.length > 0) {
        return [MCIMMirror applyToURL:fallback];
    }
    
    // Final fallback: the Edge CDN
    NSString *fileName = [file[@"fileName"] isKindOfClass:NSString.class] ? file[@"fileName"] : @"";
    NSInteger numericFileId = fileId.integerValue;
    if (numericFileId <= 0 || fileName.length == 0) {
        return @"";
    }
    NSString *encodedName = [fileName stringByAddingPercentEncodingWithAllowedCharacters:NSCharacterSet.URLPathAllowedCharacterSet];
    NSString *cdnURL = [NSString stringWithFormat:@"https://edge.forgecdn.net/files/%ld/%03ld/%@",
            (long)(numericFileId / 1000),
            (long)(numericFileId % 1000),
            encodedName ?: fileName];
    return [MCIMMirror applyToURL:cdnURL];
}

- (NSString *)gameVersionSummaryForFile:(NSDictionary *)file {
    NSArray<NSString *> *gameVersions = [file[@"gameVersions"] isKindOfClass:NSArray.class] ? file[@"gameVersions"] : @[];
    NSMutableArray<NSString *> *minecraftVersions = [NSMutableArray new];
    NSMutableArray<NSString *> *loaders = [NSMutableArray new];
    NSCharacterSet *digits = NSCharacterSet.decimalDigitCharacterSet;
    for (NSString *value in gameVersions) {
        if (![value isKindOfClass:NSString.class] || value.length == 0) continue;
        unichar first = [value characterAtIndex:0];
        if ([digits characterIsMember:first]) {
            [minecraftVersions addObject:value];
        } else if ([value rangeOfString:@"client" options:NSCaseInsensitiveSearch].location == NSNotFound &&
                   [value rangeOfString:@"server" options:NSCaseInsensitiveSearch].location == NSNotFound) {
            [loaders addObject:value];
        }
    }
    NSString *mcVersion = minecraftVersions.firstObject ?: @"";
    NSString *loader = loaders.firstObject ?: @"";
    if (mcVersion.length > 0 && loader.length > 0) {
        return [NSString stringWithFormat:@"%@/%@", mcVersion, loader];
    }
    return mcVersion.length > 0 ? mcVersion : loader;
}

#pragma mark - Synchronous search (the original implementation)

- (NSMutableArray *)searchModWithFilters:(NSDictionary<NSString *, NSString *> *)searchFilters
                     previousPageResult:(NSMutableArray *)previousPageResult {
    int pageSize = 50;
    NSString *projectType = searchFilters[@"projectType"];
    if (projectType.length == 0) {
        projectType = searchFilters[@"isModpack"] ? ([searchFilters[@"isModpack"] boolValue] ? @"modpack" : @"mod") : @"modpack";
    }
    
    NSMutableDictionary *params = @{
        @"gameId": @(kCurseForgeGameIDMinecraft),
        @"classId": [self classIDForProjectType:projectType],
        @"pageSize": @(pageSize),
        @"index": @(previousPageResult.count)
    }.mutableCopy;
    // Sort explicitly, otherwise the API falls back to name order.
    params[@"sortField"] = [CurseForgeAPI curseForgeSortFieldForSort:searchFilters[@"sort"]];
    params[@"sortOrder"] = @"desc";
    NSString *query = [searchFilters[@"name"] stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet] ?: @"";
    if (query.length > 0) {
        params[@"searchFilter"] = query;
    }
    if (searchFilters[@"mcVersion"].length > 0) {
        params[@"gameVersion"] = searchFilters[@"mcVersion"];
    }
    if ([projectType isEqualToString:@"minecraft_java_server"]) {
        params[@"categoryId"] = @(kCurseForgeCategoryIDServerUtility);
    }
    
    NSDictionary *response = [self getEndpoint:@"mods/search" params:params];
    if (!response) return nil;
    
    NSMutableArray *result = previousPageResult ?: [NSMutableArray new];
    NSArray *projects = [response[@"data"] isKindOfClass:NSArray.class] ? response[@"data"] : @[];
    for (NSDictionary *project in projects) {
        if (![project isKindOfClass:NSDictionary.class]) continue;
        [result addObject:[self projectFromCurseForgeProject:project projectType:projectType]];
    }
    
    NSDictionary *pagination = [response[@"pagination"] isKindOfClass:NSDictionary.class] ? response[@"pagination"] : @{};
    NSUInteger total = [pagination[@"totalCount"] unsignedIntegerValue];
    NSUInteger index = [pagination[@"index"] unsignedIntegerValue];
    NSUInteger count = [pagination[@"resultCount"] unsignedIntegerValue];
    self.reachedLastPage = total == 0 || index + count >= total;
    return result;
}

#pragma mark - Synchronous detail loading

- (void)loadDetailsOfMod:(NSMutableDictionary *)item {
    NSString *projectId = [item[@"id"] description];
    if (projectId.length == 0) return;
    
    NSMutableArray<NSString *> *names = [NSMutableArray new];
    NSMutableArray<NSString *> *mcNames = [NSMutableArray new];
    NSMutableArray<NSString *> *urls = [NSMutableArray new];
    NSMutableArray<NSString *> *hashes = [NSMutableArray new];
    NSMutableArray<NSString *> *sizes = [NSMutableArray new];
    NSMutableArray<NSString *> *fileNames = [NSMutableArray new];
    NSMutableArray<NSString *> *fileTypes = [NSMutableArray new];
    NSString *projectType = item[@"projectType"] ?: @"mod";
    
    NSUInteger index = 0;
    NSUInteger total = NSUIntegerMax;
    while (index < total) {
        NSDictionary *response = [self getEndpoint:[NSString stringWithFormat:@"mods/%@/files", projectId]
                                            params:@{@"pageSize": @10000, @"index": @(index)}];
        if (!response) return;
        
        NSArray *files = [response[@"data"] isKindOfClass:NSArray.class] ? response[@"data"] : @[];
        for (NSDictionary *file in files) {
            [self addFile:file toNames:names mcNames:mcNames urls:urls hashes:hashes sizes:sizes fileNames:fileNames fileTypes:fileTypes projectType:projectType];
        }
        
        NSDictionary *pagination = [response[@"pagination"] isKindOfClass:NSDictionary.class] ? response[@"pagination"] : @{};
        total = [pagination[@"totalCount"] unsignedIntegerValue];
        NSUInteger resultCount = [pagination[@"resultCount"] unsignedIntegerValue];
        if (resultCount == 0) break;
        index += resultCount;
    }
    
    if (names.count == 0) {
        self.lastError = [NSError errorWithDomain:@"CurseForgeAPI"
                                             code:404
                                         userInfo:@{NSLocalizedDescriptionKey: @"No downloadable files were found for this CurseForge project."}];
        return;
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

// Helper: append a single file's information to the array (called internally by loadDetailsOfMod)
- (void)addFile:(NSDictionary *)file toNames:(NSMutableArray *)names mcNames:(NSMutableArray *)mcNames urls:(NSMutableArray *)urls hashes:(NSMutableArray *)hashes sizes:(NSMutableArray *)sizes fileNames:(NSMutableArray *)fileNames fileTypes:(NSMutableArray *)fileTypes projectType:(NSString *)projectType {
    if (![self file:file matchesProjectType:projectType]) return;
    NSString *url = [self downloadURLForFile:file];
    if (url.length == 0) return;
    
    NSString *name = file[@"displayName"];
    if (![name isKindOfClass:NSString.class] || name.length == 0) {
        name = file[@"fileName"];
    }
    NSString *fileName = file[@"fileName"];
    if (![fileName isKindOfClass:NSString.class] || fileName.length == 0) {
        fileName = url.lastPathComponent;
    }
    
    [names addObject:name ?: @"Download"];
    [mcNames addObject:[self gameVersionSummaryForFile:file] ?: @""];
    [sizes addObject:file[@"fileLength"] ?: @0];
    [urls addObject:url];
    [hashes addObject:[self sha1ForFile:file] ?: @""];
    [fileNames addObject:fileName ?: @"download"];
    [fileTypes addObject:@""];
}

#pragma mark - Asynchronous search (new, recommended)

- (void)searchModWithFilters:(NSDictionary *)filters
                  completion:(void (^)(NSArray * _Nullable, NSError * _Nullable))completion {
    NSString *projectType = filters[@"projectType"];
    if (projectType.length == 0) {
        // Defensive fallback: consistent with the synchronous version, search as a modpack when projectType is unspecified but isModpack is declared
        projectType = [filters[@"isModpack"] boolValue] ? @"modpack" : @"mod";
    }
    NSString *query = filters[@"query"] ?: filters[@"name"] ?: @"";
    NSNumber *limitNum = filters[@"limit"] ?: @50;
    int limit = [limitNum intValue];
    NSNumber *offsetNum = filters[@"offset"] ?: @0;
    int offset = [offsetNum intValue];
    NSString *mcVersion = filters[@"mcVersion"] ?: filters[@"version"];
    
    // Build the URL
    NSMutableString *urlString = [NSMutableString stringWithFormat:@"%@/mods/search?gameId=%ld&classId=%@&pageSize=%d&index=%d",
                                  self.baseURL,
                                  (long)kCurseForgeGameIDMinecraft,
                                  [self classIDForProjectType:projectType],
                                  limit, offset];
    // Sort explicitly, otherwise the API falls back to name order.
    [urlString appendFormat:@"&sortField=%@&sortOrder=desc",
     [CurseForgeAPI curseForgeSortFieldForSort:filters[@"sort"]]];
    if (query.length > 0) {
        NSString *encodedQuery = [query stringByAddingPercentEncodingWithAllowedCharacters:[NSCharacterSet URLQueryAllowedCharacterSet]];
        [urlString appendFormat:@"&searchFilter=%@", encodedQuery];
    }
    if (mcVersion.length > 0) {
        [urlString appendFormat:@"&gameVersion=%@", mcVersion];
    }
    
    NSURL *url = [NSURL URLWithString:urlString];
    if (!url) {
        if (completion) completion(nil, [NSError errorWithDomain:@"CurseForgeAPI" code:1 userInfo:@{NSLocalizedDescriptionKey: @"Invalid URL"}]);
        return;
    }
    
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:url];
    NSDictionary *headers = [self headers];
    if (!headers) {
        NSLog(@"[CurseForgeAPI] Warning: searchModWithFilters failed: API Key not configured");
        if (completion) completion(nil, [self missingAPIKeyError]);
        return;
    }
    for (NSString *key in headers) {
        [request setValue:headers[key] forHTTPHeaderField:key];
    }
    request.timeoutInterval = 30.0;
    NSLog(@"[CurseForgeAPI] searchModWithFilters starting request: %@", urlString);

    NSURLSessionDataTask *task = [self.session dataTaskWithRequest:request completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        if (error) {
            // Network error: pass the original NSError through, with the HTTP diagnostics attached when available
            NSLog(@"[CurseForgeAPI] searchModWithFilters network error: %@", error.localizedDescription);
            [self debugLogRequest:request response:response data:data jsonError:nil];
            NSError *diagnosticError = [self errorWithResponse:response data:data originalError:error snippet:nil];
            if (completion) completion(nil, diagnosticError);
            return;
        }
        if (!data || data.length == 0) {
            // Empty response data: return an NSError containing the HTTP status code
            NSLog(@"[CurseForgeAPI] searchModWithFilters empty response");
            [self debugLogRequest:request response:response data:data jsonError:nil];
            NSError *emptyError = [NSError errorWithDomain:@"CurseForgeAPI"
                                                      code:2
                                                  userInfo:@{NSLocalizedDescriptionKey: @"CurseForge API returned empty response"}];
            NSError *diagnosticError = [self errorWithResponse:response data:data originalError:emptyError snippet:nil];
            if (completion) completion(nil, diagnosticError);
            return;
        }

        NSError *jsonError = nil;
        NSDictionary *json = [NSJSONSerialization JSONObjectWithData:data options:0 error:&jsonError];
        if (jsonError || ![json isKindOfClass:NSDictionary.class]) {
            // JSON parse failure: print the full debug log, to make cases such as a 401 HTML error page easy to diagnose
            NSLog(@"[CurseForgeAPI] searchModWithFilters JSON parse failed");
            [self debugLogRequest:request response:response data:data jsonError:jsonError];
            NSError *baseError = jsonError ?: [NSError errorWithDomain:@"CurseForgeAPI"
                                                                   code:3
                                                               userInfo:@{NSLocalizedDescriptionKey: @"CurseForge API returned non-JSON response"}];
            NSError *diagnosticError = [self errorWithResponse:response data:data originalError:baseError snippet:nil];
            if (completion) completion(nil, diagnosticError);
            return;
        }
        
        NSArray *projects = json[@"data"];
        if (![projects isKindOfClass:NSArray.class]) { if (completion) completion(@[], nil); return; }

        NSMutableArray *results = [NSMutableArray array];
        for (NSDictionary *project in projects) {
            if (![project isKindOfClass:NSDictionary.class]) continue;
            [results addObject:[self projectFromCurseForgeProject:project projectType:projectType]];
        }

        // Update the pagination state
        NSDictionary *pagination = json[@"pagination"] ?: @{};
        NSUInteger total = [pagination[@"totalCount"] unsignedIntegerValue];
        NSUInteger idx = [pagination[@"index"] unsignedIntegerValue];
        NSUInteger count = [pagination[@"resultCount"] unsignedIntegerValue];
        self.reachedLastPage = total == 0 || idx + count >= total;

        NSLog(@"[CurseForgeAPI] searchModWithFilters success: returned %lu items (total=%lu)",
              (unsigned long)results.count, (unsigned long)total);
        if (completion) completion(results, nil);
    }];
    [task resume];
}

#pragma mark - Fetching versions asynchronously

- (void)getVersionsForModWithID:(NSString *)modID
                     completion:(void (^)(NSArray<ModVersion *> * _Nullable, NSError * _Nullable))completion {
    if (modID.length == 0) {
        if (completion) completion(nil, [NSError errorWithDomain:@"CurseForgeAPI" code:1 userInfo:@{NSLocalizedDescriptionKey: @"Invalid mod ID"}]);
        return;
    }

    // Call loadDetailsOfMod:completion: asynchronously and directly, so the calling thread is not blocked
    NSMutableDictionary *item = [@{@"id": modID, @"projectType": @"mod"} mutableCopy];
    [self loadDetailsOfMod:item completion:^(NSError * _Nullable error) {
        if (error) {
            if (completion) completion(nil, error);
            return;
        }
        if (completion) completion(item[@"versions"], nil);
    }];
}

#pragma mark - Modpack download support

- (NSDictionary *)modpackDependencyInfoFromManifest:(NSDictionary *)manifest {
    NSDictionary *minecraft = [manifest[@"minecraft"] isKindOfClass:NSDictionary.class] ? manifest[@"minecraft"] : @{};
    NSString *minecraftVersion = minecraft[@"version"];
    if (![minecraftVersion isKindOfClass:NSString.class] || minecraftVersion.length == 0) {
        return @{};
    }
    
    NSMutableDictionary *dependencies = @{@"minecraft": minecraftVersion}.mutableCopy;
    NSArray *modLoaders = [minecraft[@"modLoaders"] isKindOfClass:NSArray.class] ? minecraft[@"modLoaders"] : @[];
    NSDictionary *selectedLoader = nil;
    for (NSDictionary *loader in modLoaders) {
        if ([loader[@"primary"] boolValue]) {
            selectedLoader = loader;
            break;
        }
    }
    if (!selectedLoader) {
        selectedLoader = modLoaders.firstObject;
    }
    
    NSString *loaderId = [selectedLoader[@"id"] isKindOfClass:NSString.class] ? selectedLoader[@"id"] : @"";
    NSArray<NSString *> *loaderParts = [loaderId componentsSeparatedByString:@"-"];
    NSString *loaderName = loaderParts.count > 0 ? loaderParts.firstObject.lowercaseString : @"";
    NSString *loaderVersion = loaderParts.count > 1 ? [[loaderParts subarrayWithRange:NSMakeRange(1, loaderParts.count - 1)] componentsJoinedByString:@"-"] : @"";
    if ([loaderName isEqualToString:@"forge"]) {
        dependencies[@"forge"] = loaderVersion;
    } else if ([loaderName isEqualToString:@"fabric"]) {
        dependencies[@"fabric-loader"] = loaderVersion;
    } else if ([loaderName isEqualToString:@"quilt"]) {
        dependencies[@"quilt-loader"] = loaderVersion;
    } else if ([loaderName isEqualToString:@"neoforge"]) {
        // Fix: this used to map to @"forge" by mistake, which produced the wrong version ID format (forge rather than neoforge)
        // and meant ModpackUtils.infoForDependencies: did not download the NeoForge version JSON.
        // It now maps correctly to @"neoforge", consistent with the Modrinth format.
        dependencies[@"neoforge"] = loaderVersion;
    }
    
    NSMutableDictionary *info = [[ModpackUtils infoForDependencies:dependencies] mutableCopy];
    if (!info[@"id"]) {
        info[@"id"] = minecraftVersion;
    }
    return info;
}

- (NSDictionary *)fileForProjectID:(NSString *)projectID fileID:(NSString *)fileID {
    NSDictionary *response = [self getEndpoint:[NSString stringWithFormat:@"mods/%@/files/%@", projectID, fileID] params:nil];
    NSDictionary *file = [response isKindOfClass:NSDictionary.class] ? response[@"data"] : nil;
    return [file isKindOfClass:NSDictionary.class] ? file : nil;
}

- (NSDictionary<NSString *, NSDictionary *> *)filesByFileID:(NSArray *)fileIDs {
    NSMutableArray<NSNumber *> *uniqueFileIDs = [NSMutableArray new];
    NSMutableSet<NSString *> *seenFileIDs = [NSMutableSet new];
    for (id fileIDObject in fileIDs) {
        NSString *fileID = [fileIDObject description];
        if (fileID.length == 0 || [seenFileIDs containsObject:fileID]) continue;
        [seenFileIDs addObject:fileID];
        [uniqueFileIDs addObject:@(fileID.longLongValue)];
    }
    
    NSMutableDictionary<NSString *, NSDictionary *> *files = [NSMutableDictionary new];
    NSUInteger index = 0;
    while (index < uniqueFileIDs.count) {
        NSUInteger count = MIN((NSUInteger)50, uniqueFileIDs.count - index);
        NSArray *batch = [uniqueFileIDs subarrayWithRange:NSMakeRange(index, count)];
        // Key fix: the bulk fingerprint endpoint occasionally fails or times out, leaving a whole batch of fileIDs missing from filesByID,
        // so each missing file in the following loop triggered the single-file fileForProjectID:fileID: fallback (adding API calls),
        // and in the worst case the fallback failed too and the file was skipped → the modpack ended up with missing mods.
        // A retry was added: up to 3 attempts per batch (1s apart).
        NSDictionary *response = nil;
        for (NSInteger retry = 0; retry < 3 && !response; retry++) {
            if (retry > 0) {
                NSLog(@"[CurseForgeAPI] filesByFileID batch %ld retry %ld", (long)index/50 + 1, (long)retry);
                [NSThread sleepForTimeInterval:1.0];
            }
            NSDictionary *resp = [self postEndpoint:@"mods/files" params:@{@"fileIds": batch}];
            if ([resp isKindOfClass:NSDictionary.class] && [resp[@"data"] isKindOfClass:NSArray.class]) {
                response = resp;
            }
        }
        NSArray *batchFiles = [response isKindOfClass:NSDictionary.class] && [response[@"data"] isKindOfClass:NSArray.class] ? response[@"data"] : @[];
        for (NSDictionary *file in batchFiles) {
            if (![file isKindOfClass:NSDictionary.class]) continue;
            NSString *fileID = [file[@"id"] description];
            if (fileID.length > 0) {
                files[fileID] = file;
            }
        }
        index += count;
    }
    return files;
}

- (void)downloader:(MinecraftResourceDownloadTask *)downloader
submitDownloadTasksFromPackage:(NSString *)packagePath
            toPath:(NSString *)destPath {
    NSError *error;
    UZKArchive *archive = [[UZKArchive alloc] initWithPath:packagePath error:&error];
    if (error) {
        [downloader finishDownloadWithErrorString:[NSString stringWithFormat:@"Failed to open CurseForge package: %@", error.localizedDescription]];
        return;
    }
    
    NSData *manifestData = [archive extractDataFromFile:@"manifest.json" error:&error];
    NSDictionary *manifest = manifestData ? [NSJSONSerialization JSONObjectWithData:manifestData options:kNilOptions error:&error] : nil;
    if (![manifest isKindOfClass:NSDictionary.class] || error) {
        [downloader finishDownloadWithErrorString:[NSString stringWithFormat:@"Failed to parse CurseForge manifest.json: %@", error.localizedDescription ?: @"invalid manifest"]];
        return;
    }
    
    NSString *modsPath = [destPath stringByAppendingPathComponent:@"mods"];
    NSArray *manifestFiles = [manifest[@"files"] isKindOfClass:NSArray.class] ? manifest[@"files"] : @[];
    NSMutableArray<NSDictionary *> *requiredManifestFiles = [NSMutableArray new];
    NSMutableArray *requiredFileIDs = [NSMutableArray new];
    for (NSDictionary *manifestFile in manifestFiles) {
        if (![manifestFile isKindOfClass:NSDictionary.class]) continue;
        // Key fix: some modpack manifests omit the required field (or write a non-boolean value),
        // and `![manifestFile[@"required"] boolValue]` used to treat a missing/non-boolean field as NO and skip it,
        // losing a whole batch of mods. It now treats a missing required field as required (matching CurseForge's official convention).
        // Only an explicit NO is skipped.
        id requiredValue = manifestFile[@"required"];
        if (requiredValue != nil && [requiredValue isKindOfClass:[NSNumber class]] && ![requiredValue boolValue]) {
            continue;
        }
        id fileID = manifestFile[@"fileID"];
        if (!fileID) continue;
        [requiredManifestFiles addObject:manifestFile];
        [requiredFileIDs addObject:fileID];
    }

    NSDictionary<NSString *, NSDictionary *> *filesByID = [self filesByFileID:requiredFileIDs];
    NSUInteger skippedCount = 0;
    for (NSDictionary *manifestFile in requiredManifestFiles) {
        NSString *projectID = [manifestFile[@"projectID"] description] ?: @"";
        NSString *fileID = [manifestFile[@"fileID"] description] ?: @"";
        NSDictionary *file = fileID.length > 0 ? filesByID[fileID] : nil;
        // Fall back to the per-file lookup endpoint when parsing a single file fails
        if (!file && projectID.length > 0 && fileID.length > 0) {
            file = [self fileForProjectID:projectID fileID:fileID];
        }
        NSString *url = file ? [self downloadURLForFile:file] : @"";
        NSString *fileName = [file[@"fileName"] isKindOfClass:NSString.class] ? file[@"fileName"] : @"";
        // Key fix: a single file failing to parse no longer aborts the whole modpack download; it is logged and skipped instead.
        // `finishDownloadWithErrorString:` + `return` used to lose the entire batch of mods
        // even when only 1 file could not be parsed. That matches the "incomplete mods" problem described in the issue exactly.
        // Phase 5 fix (modeled on FCL): the skipped files are also recorded in failedFiles and reported to the user in the final summary.
        if (url.length == 0 || fileName.length == 0) {
            NSLog(@"[CurseForgeAPI] Skipping unresolvable modpack file projectID=%@ fileID=%@ (url or fileName is empty), continuing with remaining files", projectID, fileID);
            skippedCount++;
            // Progress must advance even when a single file fails, so the download card does not get stuck
            downloader.progress.completedUnitCount++;
            @synchronized(downloader.failedFiles) {
                [downloader.failedFiles addObject:@{
                    @"name": [NSString stringWithFormat:@"projectID=%@ fileID=%@", projectID, fileID],
                    @"error": @"Could not parse file information from the CurseForge API (url or fileName is empty)"
                }];
            }
            continue;
        }
        NSString *path = [modsPath stringByAppendingPathComponent:fileName];
        NSURLSessionDownloadTask *task = [downloader createDownloadTask:url
                                                                   size:[file[@"fileLength"] unsignedLongLongValue]
                                                                    sha:[self sha1ForFile:file]
                                                                altName:fileName
                                                                 toPath:path];
        if (task) {
            [task resume];
        } else if (downloader.progress.cancelled) {
            return;
        }
    }
    if (skippedCount > 0) {
        NSLog(@"[CurseForgeAPI] Modpack download: skipped %lu unresolvable files, continuing with remaining", (unsigned long)skippedCount);
    }
    
    NSString *overrides = manifest[@"overrides"];
    if (![overrides isKindOfClass:NSString.class] || overrides.length == 0) {
        overrides = @"overrides";
    }
    [ModpackUtils archive:archive extractDirectory:overrides toPath:destPath error:&error];
    if (error) {
        [downloader finishDownloadWithErrorString:[NSString stringWithFormat:@"Failed to extract overrides from CurseForge package: %@", error.localizedDescription]];
        return;
    }
    
    [NSFileManager.defaultManager removeItemAtPath:packagePath error:nil];

    NSDictionary *depInfo = [self modpackDependencyInfoFromManifest:manifest];
    NSString *profileName = manifest[@"name"] ?: destPath.lastPathComponent;
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
        // Fabric/Quilt: download the version JSON directly
        NSString *jsonPath = [NSString stringWithFormat:@"%1$s/versions/%2$@/%2$@.json", getenv("POJAV_GAME_DIR"), depInfo[@"id"]];
        NSURLSessionDownloadTask *task = [downloader createDownloadTask:depInfo[@"json"] size:0 sha:nil altName:nil toPath:jsonPath];
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
                [NSFileManager.defaultManager removeItemAtPath:installerPath error:nil];
                if (!installSuccess) {
                    NSLog(@"[CurseForgeAPI] %@ direct install failed: %@", loader, installError.localizedDescription);
                    [ModpackUtils writePlaceholderVersionJSONForVersionId:versionId
                                                          minecraftVersion:depInfo[@"minecraftVersion"]
                                                                    loader:loader
                                                            loaderVersion:depInfo[@"loaderVersion"]
                                                                     error:installError];
                } else {
                    NSLog(@"[CurseForgeAPI] %@ direct install succeeded, version.json written: %@", loader, versionId);
                    // Phase 5 fix (modeled on FCL ModpackHelper.ensureCompleteVersion):
                    // the direct installer only wrote the loader's version.json and the Forge/NeoForge libraries,
                    // while vanilla MC's libraries and assets have not been downloaded yet.
                    // downloadVersion: is triggered so MinecraftResourceDownloadTask downloads the complete version files.
                    [downloader downloadVersion:@{@"id": versionId}];
                }
            });
        }];
        [task resume];
    }
}

- (NSMutableDictionary *)projectForFileHash:(NSString *)murmurHash projectType:(NSString *)projectType {
    if (!murmurHash || murmurHash.length == 0) return nil;
    NSString *urlStr = [NSString stringWithFormat:@"%@/fingerprints/%ld", self.baseURL, (long)kCurseForgeGameIDMinecraft];
    NSURL *url = [NSURL URLWithString:urlStr];
    if (!url) return nil;
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:url];
    request.HTTPMethod = @"POST";
    [request setValue:[self apiKey] forHTTPHeaderField:@"x-api-key"];
    [request setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];
    NSDictionary *body = @{@"fingerprints": @[@([murmurHash longLongValue])]};
    NSError *jsonError = nil;
    NSData *bodyData = [NSJSONSerialization dataWithJSONObject:body options:0 error:&jsonError];
    if (jsonError) return nil;
    request.HTTPBody = bodyData;

    __block NSMutableDictionary *result = nil;
    dispatch_semaphore_t sem = dispatch_semaphore_create(0);
    NSURLSessionDataTask *task = [self.session dataTaskWithRequest:request completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        if (!error && data) {
            NSDictionary *json = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
            NSArray *exactMatches = [json isKindOfClass:NSDictionary.class] ? json[@"data"][@"exactMatches"] : nil;
            if ([exactMatches isKindOfClass:NSArray.class] && exactMatches.count > 0) {
                NSDictionary *match = exactMatches[0];
                result = [NSMutableDictionary dictionary];
                result[@"id"] = [match[@"id"] stringValue];
                result[@"fileId"] = [match[@"file"][@"id"] stringValue];
                result[@"name"] = match[@"name"];
            }
        }
        dispatch_semaphore_signal(sem);
    }];
    [task resume];
    dispatch_semaphore_wait(sem, dispatch_time(DISPATCH_TIME_NOW, 15 * NSEC_PER_SEC));
    return result;
}

#pragma mark - Bulk fingerprint lookup

- (NSArray<NSMutableDictionary *> *)fileFingerprints:(NSArray<NSNumber *> *)fingerprints {
    if (!fingerprints || fingerprints.count == 0) return @[];
    NSString *urlStr = [NSString stringWithFormat:@"%@/fingerprints/%ld", self.baseURL, (long)kCurseForgeGameIDMinecraft];
    NSURL *url = [NSURL URLWithString:urlStr];
    if (!url) return @[];
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:url];
    request.HTTPMethod = @"POST";
    [request setValue:[self apiKey] forHTTPHeaderField:@"x-api-key"];
    [request setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];
    NSDictionary *body = @{@"fingerprints": fingerprints};
    NSError *bodyError = nil;
    NSData *bodyData = [NSJSONSerialization dataWithJSONObject:body options:0 error:&bodyError];
    if (bodyError) return @[];
    request.HTTPBody = bodyData;

    __block NSMutableArray *results = [NSMutableArray array];
    dispatch_semaphore_t sem = dispatch_semaphore_create(0);
    NSURLSessionDataTask *task = [self.session dataTaskWithRequest:request completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        if (!error && data) {
            NSDictionary *json = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
            NSArray *exactMatches = [json isKindOfClass:NSDictionary.class] ? json[@"data"][@"exactMatches"] : nil;
            if ([exactMatches isKindOfClass:NSArray.class]) {
                for (NSDictionary *match in exactMatches) {
                    if (![match isKindOfClass:NSDictionary.class]) continue;
                    NSMutableDictionary *item = [NSMutableDictionary dictionary];
                    item[@"id"] = [match[@"id"] stringValue];
                    item[@"fileId"] = [match[@"file"][@"id"] stringValue];
                    item[@"name"] = match[@"name"];
                    [results addObject:item];
                }
            }
        }
        dispatch_semaphore_signal(sem);
    }];
    [task resume];
    dispatch_semaphore_wait(sem, dispatch_time(DISPATCH_TIME_NOW, 15 * NSEC_PER_SEC));
    return results;
}

#pragma mark - Asynchronous detail loading

- (void)loadDetailsOfMod:(NSMutableDictionary *)item completion:(void (^)(NSError * _Nullable error))completion {
    NSString *modID = [item[@"id"] description];
    if (modID.length == 0) {
        if (completion) dispatch_async(dispatch_get_main_queue(), ^{
            completion([NSError errorWithDomain:@"CurseForgeAPI" code:1 userInfo:@{NSLocalizedDescriptionKey: @"Invalid mod ID"}]);
        });
        return;
    }
    NSString *urlStr = [NSString stringWithFormat:@"%@/mods/%@/files", self.baseURL, modID];
    NSURL *url = [NSURL URLWithString:urlStr];
    if (!url) {
        if (completion) dispatch_async(dispatch_get_main_queue(), ^{
            completion([NSError errorWithDomain:@"CurseForgeAPI" code:2 userInfo:@{NSLocalizedDescriptionKey: @"Invalid URL"}]);
        });
        return;
    }
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:url];
    [request setValue:[self apiKey] forHTTPHeaderField:@"x-api-key"];
    [request setValue:@"application/json" forHTTPHeaderField:@"Accept"];
    request.timeoutInterval = 30.0;
    NSLog(@"[CurseForgeAPI] loadDetailsOfMod starting request modID=%@: %@", modID, urlStr);

    NSURLSessionDataTask *task = [self.session dataTaskWithRequest:request completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        if (error) {
            // Network error: pass it through with the diagnostics attached
            NSLog(@"[CurseForgeAPI] loadDetailsOfMod network error: %@", error.localizedDescription);
            [self debugLogRequest:request response:response data:data jsonError:nil];
            NSError *diagnosticError = [self errorWithResponse:response data:data originalError:error snippet:nil];
            if (completion) dispatch_async(dispatch_get_main_queue(), ^{ completion(diagnosticError); });
            return;
        }
        if (!data || data.length == 0) {
            // Empty response data
            NSLog(@"[CurseForgeAPI] loadDetailsOfMod empty response");
            [self debugLogRequest:request response:response data:data jsonError:nil];
            NSError *emptyError = [NSError errorWithDomain:@"CurseForgeAPI"
                                                      code:2
                                                  userInfo:@{NSLocalizedDescriptionKey: @"CurseForge API returned empty response"}];
            NSError *diagnosticError = [self errorWithResponse:response data:data originalError:emptyError snippet:nil];
            if (completion) dispatch_async(dispatch_get_main_queue(), ^{ completion(diagnosticError); });
            return;
        }

        NSError *jsonError = nil;
        NSDictionary *json = [NSJSONSerialization JSONObjectWithData:data options:0 error:&jsonError];
        if (jsonError || ![json isKindOfClass:NSDictionary.class]) {
            // JSON parse failure: print the full debug log
            NSLog(@"[CurseForgeAPI] loadDetailsOfMod JSON parse failed");
            [self debugLogRequest:request response:response data:data jsonError:jsonError];
            NSError *baseError = jsonError ?: [NSError errorWithDomain:@"CurseForgeAPI"
                                                                   code:3
                                                               userInfo:@{NSLocalizedDescriptionKey: @"CurseForge API returned non-JSON response"}];
            NSError *diagnosticError = [self errorWithResponse:response data:data originalError:baseError snippet:nil];
            if (completion) dispatch_async(dispatch_get_main_queue(), ^{ completion(diagnosticError); });
            return;
        }

        NSArray *files = [json isKindOfClass:NSDictionary.class] ? json[@"data"] : nil;
        if (![files isKindOfClass:NSArray.class]) files = @[];
        NSMutableArray *versions = [NSMutableArray array];
        for (NSDictionary *file in files) {
            if (![file isKindOfClass:NSDictionary.class]) continue;
            ModVersion *mv = [[ModVersion alloc] initWithDictionary:file];
            if (mv) [versions addObject:mv];
        }
        item[@"versions"] = versions;
        NSLog(@"[CurseForgeAPI] loadDetailsOfMod success: modID=%@, %lu versions",
              modID, (unsigned long)versions.count);
        if (completion) dispatch_async(dispatch_get_main_queue(), ^{ completion(nil); });
    }];
    [task resume];
}

#pragma mark - Server Packs (server modpacks)

- (void)searchServersWithFilters:(NSDictionary *)filters
                      completion:(void (^)(NSArray * _Nullable, NSError * _Nullable))completion {
    // CurseForge has no separate server type, so modpacks (classId=4471) are presented as "server modpacks"
    NSMutableDictionary *serverFilters = [filters mutableCopy] ?: [NSMutableDictionary dictionary];
    serverFilters[@"projectType"] = @"modpack";
    // Reuse the existing asynchronous modpack search logic
    [self searchModWithFilters:serverFilters completion:^(NSArray * _Nullable results, NSError * _Nullable error) {
        if (error) {
            if (completion) completion(nil, error);
            return;
        }
        // Append a serverID field to each result, so ServerItem can recognize them uniformly
        NSMutableArray *serverResults = [NSMutableArray array];
        for (NSDictionary *item in results) {
            if (![item isKindOfClass:[NSDictionary class]]) continue;
            NSMutableDictionary *serverItem = [item mutableCopy];
            serverItem[@"serverID"] = item[@"id"] ?: @"";
            serverItem[@"projectType"] = @"modpack";
            [serverResults addObject:serverItem];
        }
        if (completion) completion(serverResults, nil);
    }];
}

- (void)getServerPackFilesForModpack:(NSString *)modpackID
                          completion:(void (^)(NSArray * _Nullable, NSError * _Nullable error))completion {
    if (modpackID.length == 0) {
        if (completion) completion(nil, [NSError errorWithDomain:@"CurseForgeAPI" code:1 userInfo:@{NSLocalizedDescriptionKey: @"Invalid modpack ID"}]);
        return;
    }

    // Fetch every file of that modpack and keep the ones with isServerPack=true
    NSString *urlStr = [NSString stringWithFormat:@"%@/mods/%@/files?pageSize=10000", self.baseURL, modpackID];
    NSURL *url = [NSURL URLWithString:urlStr];
    if (!url) {
        if (completion) completion(nil, [NSError errorWithDomain:@"CurseForgeAPI" code:2 userInfo:@{NSLocalizedDescriptionKey: @"Invalid URL"}]);
        return;
    }
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:url];
    [request setValue:[self apiKey] forHTTPHeaderField:@"x-api-key"];
    [request setValue:@"application/json" forHTTPHeaderField:@"Accept"];
    request.timeoutInterval = 30.0;
    NSLog(@"[CurseForgeAPI] 🔍 getServerPackFilesForModpack: %@", urlStr);

    NSURLSessionDataTask *task = [self.session dataTaskWithRequest:request completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        if (error) {
            NSError *diagnosticError = [self errorWithResponse:response data:data originalError:error snippet:nil];
            if (completion) dispatch_async(dispatch_get_main_queue(), ^{ completion(nil, diagnosticError); });
            return;
        }
        if (!data || data.length == 0) {
            NSError *emptyError = [NSError errorWithDomain:@"CurseForgeAPI" code:3 userInfo:@{NSLocalizedDescriptionKey: @"CurseForge API returned empty response"}];
            if (completion) dispatch_async(dispatch_get_main_queue(), ^{ completion(nil, emptyError); });
            return;
        }
        NSError *jsonError = nil;
        NSDictionary *json = [NSJSONSerialization JSONObjectWithData:data options:0 error:&jsonError];
        if (jsonError || ![json isKindOfClass:NSDictionary.class]) {
            NSError *baseError = jsonError ?: [NSError errorWithDomain:@"CurseForgeAPI" code:4 userInfo:@{NSLocalizedDescriptionKey: @"Invalid JSON"}];
            if (completion) dispatch_async(dispatch_get_main_queue(), ^{ completion(nil, baseError); });
            return;
        }

        NSArray *files = [json[@"data"] isKindOfClass:[NSArray class]] ? json[@"data"] : @[];
        NSMutableArray *serverPacks = [NSMutableArray array];
        for (NSDictionary *file in files) {
            if (![file isKindOfClass:[NSDictionary class]]) continue;
            // Keep the files with isServerPack=true (the inverse of the logic in loadDetailsOfMod, which excludes server packs)
            if (![file[@"isServerPack"] boolValue]) continue;
            // Parse the download URL and the file name
            NSString *dlURL = [self downloadURLForFile:file];
            NSString *fileName = [file[@"fileName"] isKindOfClass:[NSString class]] ? file[@"fileName"] : @"";
            NSString *displayName = [file[@"displayName"] isKindOfClass:[NSString class]] ? file[@"displayName"] : fileName;
            [serverPacks addObject:@{
                @"serverPackDownloadURL": dlURL ?: @"",
                @"serverPackFileName": fileName ?: @"",
                @"serverPackDisplayName": displayName ?: fileName ?: @"",
                @"serverPackFileSize": file[@"fileLength"] ?: @0,
                @"fileId": [file[@"id"] description] ?: @"",
                @"modpackId": modpackID
            }];
        }
        NSLog(@"[CurseForgeAPI] getServerPackFilesForModpack success: modpackID=%@, %lu server packs",
              modpackID, (unsigned long)serverPacks.count);
        if (completion) dispatch_async(dispatch_get_main_queue(), ^{ completion(serverPacks, nil); });
    }];
    [task resume];
}

@end