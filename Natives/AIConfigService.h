//
//  AIConfigService.h
//  Amethyst
//
//  AI 修复功能配置管理服务
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

extern NSString *const AIConfigDidChangeNotification;

@interface AIConfigService : NSObject

/// API Base URL (例如: https://api.openai.com/v1)
@property (nonatomic, copy, nullable) NSString *apiBaseURL;

/// 模型名称 (例如: gpt-4, gpt-3.5-turbo)
@property (nonatomic, copy, nullable) NSString *modelName;

/// API Key
@property (nonatomic, copy, nullable) NSString *apiKey;

/// 是否已完成配置
@property (nonatomic, readonly) BOOL isConfigured;

/// 是否已显示过实验性功能警告
@property (nonatomic, assign) BOOL hasShownExperimentalWarning;

/// 单例实例
+ (instancetype)sharedService;

/// 保存配置到持久化存储
- (void)saveConfig;

/// 加载配置
- (void)loadConfig;

/// 清除配置
- (void)clearConfig;

/// 验证配置是否有效
- (BOOL)validateConfigWithError:(NSError **)error;

/// 获取可用的模型列表（可选功能）
- (void)fetchAvailableModelsWithCompletion:(void(^)(NSArray<NSString *> *models, NSError *error))completion;

@end

NS_ASSUME_NONNULL_END
