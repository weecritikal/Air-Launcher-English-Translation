//
//  AIFixService.h
//  Amethyst
//
//  AI 崩溃修复核心服务
//

#import <Foundation/Foundation.h>
#import "AIToolKit.h"
#import "AIConfigService.h"

NS_ASSUME_NONNULL_BEGIN

@class AIFixService;

#pragma mark - 消息模型

/// 消息角色
typedef NS_ENUM(NSInteger, AI_messageRole) {
    AIMessageRoleSystem,    // 系统消息
    AIMessageRoleUser,      // 用户消息
    AIMessageRoleAssistant, // AI 助手消息
    AIMessageRoleTool       // 工具响应消息
};

/// AI 消息
@interface AIMessage : NSObject

@property (nonatomic, assign) AI_messageRole role;
@property (nonatomic, copy) NSString *content;
@property (nonatomic, strong, nullable) NSDictionary *toolCall;
@property (nonatomic, copy, nullable) NSString *toolCallId;
@property (nonatomic, assign) BOOL isSuccess;
@property (nonatomic, assign) BOOL isPending;

+ (instancetype)systemMessage:(NSString *)content;
+ (instancetype)userMessage:(NSString *)content;
+ (instancetype)assistantMessage:(NSString *)content;
+ (instancetype)toolResponseMessage:(NSString *)content toolCallId:(NSString *)toolCallId;

@end

#pragma mark - 会话状态

/// AI 会话状态
typedef NS_ENUM(NSInteger, AISessionState) {
    AISessionStateIdle,           // 空闲
    AISessionStateThinking,       // AI 思考中
    AISessionStateWaitingTool,    // 等待工具确认
    AISessionStateExecutingTool,  // 执行工具中
    AISessionStateCompleted,      // 已完成
    AISessionStateError,          // 出错
    AISessionStateStopped         // 用户停止
};

#pragma mark - 修改记录

/// 文件修改记录
@interface AIFileModification : NSObject

@property (nonatomic, copy) NSString *filePath;
@property (nonatomic, copy) NSString *operationType; // "create", "modify", "delete", "rename"
@property (nonatomic, strong, nullable) NSData *originalContent; // 原始内容（用于恢复）
@property (nonatomic, copy, nullable) NSString *originalPath; // 原路径（用于重命名）
@property (nonatomic, strong) NSDate *timestamp;
@property (nonatomic, copy, nullable) NSString *modificationDescription; // 修改说明

@end

#pragma mark - 服务代理协议

@protocol AIFixServiceDelegate <NSObject>

@optional

/// 状态变更回调
- (void)aiService:(AIFixService *)service didChangeState:(AISessionState)state;

/// 收到新消息
- (void)aiService:(AIFixService *)service didReceiveMessage:(AIMessage *)message;

/// 收到工具调用请求（需要用户确认）
- (void)aiService:(AIFixService *)service didReceiveToolRequest:(AIToolRequest *)request;

/// 工具执行完成
- (void)aiService:(AIFixService *)service didCompleteToolRequest:(AIToolRequest *)request withResult:(AIToolResult *)result;

/// 修改记录更新
- (void)aiService:(AIFixService *)service didRecordModification:(AIFileModification *)modification;

/// 流式响应更新
- (void)aiService:(AIFixService *)service didReceiveStreamChunk:(NSString *)chunk;

/// 发生错误
- (void)aiService:(AIFixService *)service didEncounterError:(NSError *)error;

/// 修复完成
- (void)aiServiceDidCompleteFix:(AIFixService *)service;

@end

#pragma mark - 主服务类

@interface AIFixService : NSObject

/// 当前状态
@property (nonatomic, readonly) AISessionState state;

/// 消息历史
@property (nonatomic, readonly) NSArray<AIMessage *> *messages;

/// 修改记录
@property (nonatomic, readonly) NSArray<AIFileModification *> *modifications;

/// 当前待确认的工具请求
@property (nonatomic, readonly, nullable) AIToolRequest *pendingToolRequest;

/// 是否正在运行
@property (nonatomic, readonly) BOOL isRunning;

/// 代理
@property (nonatomic, weak, nullable) id<AIFixServiceDelegate> delegate;

/// 单例
+ (instancetype)sharedService;

/// 开始修复流程
/// @param logPath 崩溃日志路径
/// @param error 错误信息
- (BOOL)startFixWithLogPath:(NSString *)logPath error:(NSError **)error;

/// 发送用户消息
/// @param message 用户消息内容
- (void)sendUserMessage:(NSString *)message;

/// 确认工具请求
/// @param approved 是否同意
- (void)respondToToolRequest:(BOOL)approved;

/// 停止修复流程
- (void)stopFix;

/// 清除会话历史
- (void)clearSession;

/// 撤销所有修改
- (void)rollbackAllModifications;

/// 生成修复报告
- (NSString *)generateFixReport;

/// 获取系统提示词
- (NSString *)loadSystemPrompt;

@end

NS_ASSUME_NONNULL_END
