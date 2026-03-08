//
//  AIConfigService.m
//  Amethyst
//
//  AI 修复功能配置管理服务
//

#import "AIConfigService.h"
#import "LauncherPreferences.h"

NSString *const AIConfigDidChangeNotification = @"AIConfigDidChangeNotification";

@interface AIConfigService ()
@property (nonatomic, strong) NSString *configFilePath;
@end

@implementation AIConfigService

+ (instancetype)sharedService {
    static AIConfigService *instance;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        instance = [[AIConfigService alloc] init];
    });
    return instance;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        NSString *configDir = [NSString stringWithFormat:@"%s/ai_config", getenv("POJAV_HOME")];
        _configFilePath = [configDir stringByAppendingPathComponent:@"ai_config.plist"];
        [self loadConfig];
    }
    return self;
}

- (BOOL)isConfigured {
    return self.apiBaseURL.length > 0 && 
           self.modelName.length > 0 && 
           self.apiKey.length > 0;
}

- (void)loadConfig {
    NSDictionary *config = [NSDictionary dictionaryWithContentsOfFile:self.configFilePath];
    if (config) {
        _apiBaseURL = config[@"apiBaseURL"];
        _modelName = config[@"modelName"];
        _apiKey = config[@"apiKey"];
        _hasShownExperimentalWarning = [config[@"hasShownExperimentalWarning"] boolValue];
    }
}

- (void)saveConfig {
    NSDictionary *config = @{
        @"apiBaseURL": self.apiBaseURL ?: @"",
        @"modelName": self.modelName ?: @"",
        @"apiKey": self.apiKey ?: @"",
        @"hasShownExperimentalWarning": @(self.hasShownExperimentalWarning)
    };
    
    // 确保目录存在
    NSString *configDir = [self.configFilePath stringByDeletingLastPathComponent];
    NSFileManager *fm = [NSFileManager defaultManager];
    if (![fm fileExistsAtPath:configDir]) {
        [fm createDirectoryAtPath:configDir withIntermediateDirectories:YES attributes:nil error:nil];
    }
    
    [config writeToFile:self.configFilePath atomically:YES];
    
    // 发送配置变更通知
    [[NSNotificationCenter defaultCenter] postNotificationName:AIConfigDidChangeNotification object:nil];
}

- (void)clearConfig {
    _apiBaseURL = nil;
    _modelName = nil;
    _apiKey = nil;
    _hasShownExperimentalWarning = NO;
    
    [[NSFileManager defaultManager] removeItemAtPath:self.configFilePath error:nil];
    
    [[NSNotificationCenter defaultCenter] postNotificationName:AIConfigDidChangeNotification object:nil];
}

- (BOOL)validateConfigWithError:(NSError **)error {
    if (self.apiBaseURL.length == 0) {
        if (error) {
            *error = [NSError errorWithDomain:@"AIConfigError" 
                                         code:1 
                                     userInfo:@{NSLocalizedDescriptionKey: @"API Base URL 不能为空"}];
        }
        return NO;
    }
    
    if (self.modelName.length == 0) {
        if (error) {
            *error = [NSError errorWithDomain:@"AIConfigError" 
                                         code:2 
                                     userInfo:@{NSLocalizedDescriptionKey: @"模型名称不能为空"}];
        }
        return NO;
    }
    
    if (self.apiKey.length == 0) {
        if (error) {
            *error = [NSError errorWithDomain:@"AIConfigError" 
                                         code:3 
                                     userInfo:@{NSLocalizedDescriptionKey: @"API Key 不能为空"}];
        }
        return NO;
    }
    
    // 验证 URL 格式
    NSURL *url = [NSURL URLWithString:self.apiBaseURL];
    if (!url || !url.scheme || !url.host) {
        if (error) {
            *error = [NSError errorWithDomain:@"AIConfigError" 
                                         code:4 
                                     userInfo:@{NSLocalizedDescriptionKey: @"API Base URL 格式无效"}];
        }
        return NO;
    }
    
    return YES;
}

- (void)fetchAvailableModelsWithCompletion:(void(^)(NSArray<NSString *> *models, NSError *error))completion {
    if (!self.isConfigured) {
        if (completion) {
            NSError *error = [NSError errorWithDomain:@"AIConfigError" 
                                                 code:5 
                                             userInfo:@{NSLocalizedDescriptionKey: @"请先完成配置"}];
            completion(nil, error);
        }
        return;
    }
    
    NSString *modelsURL = [self.apiBaseURL stringByAppendingPathComponent:@"models"];
    
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:modelsURL]];
    [request setValue:[NSString stringWithFormat:@"Bearer %@", self.apiKey] forHTTPHeaderField:@"Authorization"];
    [request setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];
    
    NSURLSessionDataTask *task = [[NSURLSession sharedSession] dataTaskWithRequest:request completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        if (error) {
            dispatch_async(dispatch_get_main_queue(), ^{
                if (completion) completion(nil, error);
            });
            return;
        }
        
        NSError *jsonError;
        NSDictionary *json = [NSJSONSerialization JSONObjectWithData:data options:0 error:&jsonError];
        
        if (jsonError || ![json[@"data"] isKindOfClass:[NSArray class]]) {
            dispatch_async(dispatch_get_main_queue(), ^{
                if (completion) {
                    NSError *parseError = [NSError errorWithDomain:@"AIConfigError" 
                                                             code:6 
                                                         userInfo:@{NSLocalizedDescriptionKey: @"无法解析模型列表"}];
                    completion(nil, parseError);
                }
            });
            return;
        }
        
        NSMutableArray<NSString *> *models = [NSMutableArray array];
        for (NSDictionary *model in json[@"data"]) {
            NSString *modelId = model[@"id"];
            if ([modelId isKindOfClass:[NSString class]]) {
                [models addObject:modelId];
            }
        }
        
        // 按名称排序
        [models sortUsingSelector:@selector(localizedCaseInsensitiveCompare:)];
        
        dispatch_async(dispatch_get_main_queue(), ^{
            if (completion) completion(models, nil);
        });
    }];
    
    [task resume];
}

@end
