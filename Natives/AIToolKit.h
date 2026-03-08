//
//  AIToolKit.h
//  Amethyst
//
//  AI 修复功能的工具集合
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@class ModItem;

#pragma mark - 工具请求与结果模型

/// 工具请求状态
typedef NS_ENUM(NSInteger, AIToolRequestStatus) {
    AIToolRequestStatusPending,     // 等待用户确认
    AIToolRequestStatusApproved,    // 用户已同意
    AIToolRequestStatusRejected,    // 用户已拒绝
    AIToolRequestStatusExecuted,    // 已执行
    AIToolRequestStatusFailed       // 执行失败
};

/// 工具请求
@interface AIToolRequest : NSObject

@property (nonatomic, copy) NSString *requestId;
@property (nonatomic, copy) NSString *toolName;
@property (nonatomic, copy) NSString *toolDisplayName;
@property (nonatomic, strong) NSDictionary *parameters;
@property (nonatomic, copy) NSString *reason;
@property (nonatomic, assign) AIToolRequestStatus status;
@property (nonatomic, strong, nullable) NSDictionary *result;
@property (nonatomic, strong, nullable) NSError *error;

+ (instancetype)requestWithToolName:(NSString *)toolName 
                       displayName:(NSString *)displayName
                        parameters:(NSDictionary *)parameters 
                            reason:(NSString *)reason;

@end

/// 工具执行结果
@interface AIToolResult : NSObject

@property (nonatomic, assign) BOOL success;
@property (nonatomic, strong, nullable) id data;
@property (nonatomic, strong, nullable) NSError *error;
@property (nonatomic, copy, nullable) NSString *message;

+ (instancetype)successWithData:(nullable id)data message:(nullable NSString *)message;
+ (instancetype)failureWithError:(NSError *)error;

@end

#pragma mark - 工具执行器协议

@protocol AIToolExecutor <NSObject>

@required

/// 工具名称
+ (NSString *)toolName;

/// 工具显示名称
+ (NSString *)toolDisplayName;

/// 工具描述
+ (NSString *)toolDescription;

/// 执行工具
+ (AIToolResult *)executeWithParameters:(NSDictionary *)parameters;

@optional

/// 验证参数
+ (BOOL)validateParameters:(NSDictionary *)parameters error:(NSError **)error;

/// 是否需要用户确认
+ (BOOL)requiresUserConfirmation;

/// 是否为只读操作
+ (BOOL)isReadOnlyOperation;

@end

#pragma mark - 工具集管理器

@interface AIToolKit : NSObject

/// 获取所有可用工具的信息
+ (NSArray<NSDictionary *> *)availableToolsInfo;

/// 获取工具的 JSON Schema 定义（用于 API 调用）
+ (NSArray<NSDictionary *> *)toolsJSONSchema;

/// 执行指定工具
+ (AIToolResult *)executeToolWithName:(NSString *)toolName 
                           parameters:(NSDictionary *)parameters 
                                error:(NSError **)error;

/// 检查工具是否需要用户确认
+ (BOOL)toolRequiresUserConfirmation:(NSString *)toolName;

/// 检查工具是否为只读操作
+ (BOOL)toolIsReadOnlyOperation:(NSString *)toolName;

/// 检查路径是否在启动器目录内
+ (BOOL)isPathWithinLauncherDirectory:(NSString *)path;

/// 获取启动器根目录
+ (NSString *)launcherRootDirectory;

/// 获取游戏目录
+ (NSString *)gameDirectory;

@end

#pragma mark - 具体工具执行器

/// 读取文件工具
@interface AIToolReadFile : NSObject <AIToolExecutor>
@end

/// 读取目录工具
@interface AIToolListDirectory : NSObject <AIToolExecutor>
@end

/// 写入文件工具
@interface AIToolWriteFile : NSObject <AIToolExecutor>
@end

/// 追加文件工具
@interface AIToolAppendFile : NSObject <AIToolExecutor>
@end

/// 重命名文件工具
@interface AIToolRenameFile : NSObject <AIToolExecutor>
@end

/// 删除文件工具
@interface AIToolDeleteFile : NSObject <AIToolExecutor>
@end

/// 创建目录工具
@interface AIToolCreateDirectory : NSObject <AIToolExecutor>
@end

/// 获取 Mod 列表工具
@interface AIToolGetModList : NSObject <AIToolExecutor>
@end

/// 启用/禁用 Mod 工具
@interface AIToolToggleMod : NSObject <AIToolExecutor>
@end

/// 删除 Mod 工具
@interface AIToolDeleteMod : NSObject <AIToolExecutor>
@end

/// 获取游戏配置列表工具
@interface AIToolGetProfiles : NSObject <AIToolExecutor>
@end

/// 获取启动器设置工具
@interface AIToolGetSettings : NSObject <AIToolExecutor>
@end

/// 更新启动器设置工具
@interface AIToolUpdateSetting : NSObject <AIToolExecutor>
@end

/// 获取系统信息工具
@interface AIToolGetSystemInfo : NSObject <AIToolExecutor>
@end

/// 搜索日志工具
@interface AIToolSearchLog : NSObject <AIToolExecutor>
@end

/// 分析崩溃报告工具
@interface AIToolAnalyzeCrashReport : NSObject <AIToolExecutor>
@end

/// 获取文件信息工具
@interface AIToolGetFileInfo : NSObject <AIToolExecutor>
@end

/// 复制文件工具
@interface AIToolCopyFile : NSObject <AIToolExecutor>
@end

NS_ASSUME_NONNULL_END
