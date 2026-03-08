//
//  AIFixService.m
//  Amethyst
//
//  AI 崩溃修复核心服务实现
//

#import <Foundation/Foundation.h>

// 取消可能存在的 interface 宏定义，避免与 Objective-C 的 @interface 关键字冲突
#ifdef interface
#undef interface
#endif

#import "AIFixService.h"
#import "utils.h"

static NSString *const kOpenAIChatEndpoint = @"/chat/completions";

#pragma mark - AIMessage

@implementation AIMessage

+ (instancetype)systemMessage:(NSString *)content {
    AIMessage *msg = [[AIMessage alloc] init];
    msg.role = AIMessageRoleSystem;
    msg.content = content;
    return msg;
}

+ (instancetype)userMessage:(NSString *)content {
    AIMessage *msg = [[AIMessage alloc] init];
    msg.role = AIMessageRoleUser;
    msg.content = content;
    return msg;
}

+ (instancetype)assistantMessage:(NSString *)content {
    AIMessage *msg = [[AIMessage alloc] init];
    msg.role = AIMessageRoleAssistant;
    msg.content = content;
    return msg;
}

+ (instancetype)toolResponseMessage:(NSString *)content toolCallId:(NSString *)toolCallId {
    AIMessage *msg = [[AIMessage alloc] init];
    msg.role = AIMessageRoleTool;
    msg.content = content;
    msg.toolCallId = toolCallId;
    return msg;
}

@end

#pragma mark - AIFileModification

@implementation AIFileModification
@end

#pragma mark - AIFixService

@interface AIFixService ()

@property (nonatomic, strong) NSMutableArray<AIMessage *> *mutableMessages;
@property (nonatomic, strong) NSMutableArray<AIFileModification *> *mutableModifications;
@property (nonatomic, strong) NSURLSession *session;
@property (nonatomic, strong) NSURLSessionDataTask *currentTask;
@property (nonatomic, assign) AISessionState state;
@property (nonatomic, strong) AIToolRequest *pendingToolRequest;
@property (nonatomic, assign) BOOL isRunning;
@property (nonatomic, assign) BOOL isStopped;

@end

@implementation AIFixService

+ (instancetype)sharedService {
    static AIFixService *instance;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        instance = [[AIFixService alloc] init];
    });
    return instance;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _mutableMessages = [NSMutableArray array];
        _mutableModifications = [NSMutableArray array];
        _state = AISessionStateIdle;
        _isRunning = NO;
        _isStopped = NO;
        
        NSURLSessionConfiguration *config = [NSURLSessionConfiguration defaultSessionConfiguration];
        config.timeoutIntervalForRequest = 120.0;
        config.timeoutIntervalForResource = 300.0;
        _session = [NSURLSession sessionWithConfiguration:config delegate:nil delegateQueue:nil];
    }
    return self;
}

- (NSArray<AIMessage *> *)messages {
    return [_mutableMessages copy];
}

- (NSArray<AIFileModification *> *)modifications {
    return [_mutableModifications copy];
}

#pragma mark - 状态管理

- (void)setState:(AISessionState)newState {
    if (_state != newState) {
        _state = newState;
        dispatch_async(dispatch_get_main_queue(), ^{
            if ([self.delegate respondsToSelector:@selector(aiService:didChangeState:)]) {
                [self.delegate aiService:self didChangeState:newState];
            }
        });
    }
}

- (void)handleError:(NSError *)error {
    self.state = AISessionStateError;
    dispatch_async(dispatch_get_main_queue(), ^{
        if ([self.delegate respondsToSelector:@selector(aiService:didEncounterError:)]) {
            [self.delegate aiService:self didEncounterError:error];
        }
    });
}

#pragma mark - 公开方法

- (BOOL)startFixWithLogPath:(NSString *)logPath error:(NSError **)error {
    AIConfigService *config = [AIConfigService sharedService];
    
    if (!config.isConfigured) {
        if (error) {
            *error = [NSError errorWithDomain:@"AIFixServiceError" 
                                         code:1 
                                     userInfo:@{NSLocalizedDescriptionKey: @"请先完成 API 配置"}];
        }
        return NO;
    }
    
    // 验证配置
    NSError *configError;
    if (![config validateConfigWithError:&configError]) {
        if (error) *error = configError;
        return NO;
    }
    
    // 清除旧会话
    [self clearSession];
    
    _isRunning = YES;
    _isStopped = NO;
    
    // 加载系统提示词
    NSString *systemPrompt = [self loadSystemPrompt];
    [_mutableMessages addObject:[AIMessage systemMessage:systemPrompt]];
    
    // 添加初始化信息
    NSString *initialContext = [self buildInitialContextWithLogPath:logPath];
    [_mutableMessages addObject:[AIMessage userMessage:initialContext]];
    
    // 开始对话
    [self sendChatRequest];
    
    return YES;
}

- (NSString *)buildInitialContextWithLogPath:(NSString *)logPath {
    NSMutableString *context = [NSMutableString string];
    
    // 添加崩溃日志
    [context appendString:@"## 崩溃日志\n\n"];
    [context appendFormat:@"日志文件路径: %@\n\n", logPath];
    
    NSString *logContent = [NSString stringWithContentsOfFile:logPath encoding:NSUTF8StringEncoding error:nil];
    if (logContent) {
        // 限制日志长度
        if (logContent.length > 50000) {
            logContent = [NSString stringWithFormat:@"[日志过长，已截取最后50000字符]\n\n%@", [logContent substringFromIndex:logContent.length - 50000]];
        }
        [context appendString:@"```\n"];
        [context appendString:logContent];
        [context appendString:@"\n```\n\n"];
    } else {
        [context appendString:@"无法读取日志文件。\n\n"];
    }
    
    // 添加项目文档信息
    NSString *iflowPath = [[NSBundle mainBundle] pathForResource:@"IFLOW" ofType:@"md"];
    if (!iflowPath) {
        iflowPath = [NSString stringWithFormat:@"%s/IFLOW.md", getenv("POJAV_HOME")];
    }
    
    if ([[NSFileManager defaultManager] fileExistsAtPath:iflowPath]) {
        NSString *iflowContent = [NSString stringWithContentsOfFile:iflowPath encoding:NSUTF8StringEncoding error:nil];
        if (iflowContent) {
            [context appendString:@"## 项目文档 (IFLOW.md)\n\n"];
            [context appendString:@"```\n"];
            [context appendString:iflowContent];
            [context appendString:@"\n```\n\n"];
        }
    }
    
    // 添加启动器目录信息
    [context appendString:@"## 启动器目录信息\n\n"];
    [context appendFormat:@"启动器根目录: %s\n", getenv("POJAV_HOME")];
    [context appendFormat:@"游戏目录: %s\n\n", getenv("POJAV_GAME_DIR")];
    
    // 添加提示
    [context appendString:@"---\n\n"];
    [context appendString:@"请根据以上信息分析崩溃原因并提供修复方案。在执行任何操作前，请先解释你的分析和计划。\n"];
    
    return [context copy];
}

- (void)sendUserMessage:(NSString *)message {
    if (!self.isRunning || self.isStopped) {
        // 如果不在运行状态，直接回复
        _isRunning = YES;
        _isStopped = NO;
    }
    
    [_mutableMessages addObject:[AIMessage userMessage:message]];
    [self sendChatRequest];
}

- (void)respondToToolRequest:(BOOL)approved {
    if (!self.pendingToolRequest) return;
    
    AIToolRequest *request = self.pendingToolRequest;
    self.pendingToolRequest = nil;
    
    if (approved) {
        // 执行工具
        self.state = AISessionStateExecutingTool;
        
        NSError *error;
        AIToolResult *result = [AIToolKit executeToolWithName:request.toolName 
                                                   parameters:request.parameters 
                                                        error:&error];
        
        request.status = result.success ? AIToolRequestStatusExecuted : AIToolRequestStatusFailed;
        request.result = result.data;
        request.error = error;
        
        // 记录修改
        if (result.success && ![AIToolKit toolIsReadOnlyOperation:request.toolName]) {
            [self recordModificationForTool:request.toolName parameters:request.parameters];
        }
        
        // 通知代理
        dispatch_async(dispatch_get_main_queue(), ^{
            if ([self.delegate respondsToSelector:@selector(aiService:didCompleteToolRequest:withResult:)]) {
                [self.delegate aiService:self didCompleteToolRequest:request withResult:result];
            }
        });
        
        // 将结果发送给 AI
        NSString *resultContent;
        if (result.success) {
            NSData *jsonData = [NSJSONSerialization dataWithJSONObject:result.data ?: @{} options:0 error:nil];
            resultContent = [[NSString alloc] initWithData:jsonData encoding:NSUTF8StringEncoding];
        } else {
            resultContent = [NSString stringWithFormat:@"工具执行失败: %@", error.localizedDescription];
        }
        
        [_mutableMessages addObject:[AIMessage toolResponseMessage:resultContent toolCallId:request.requestId]];
        [self sendChatRequest];
    } else {
        // 用户拒绝
        request.status = AIToolRequestStatusRejected;
        
        [_mutableMessages addObject:[AIMessage toolResponseMessage:@"用户拒绝了此操作，请尝试其他方案。" toolCallId:request.requestId]];
        [self sendChatRequest];
    }
}

- (void)stopFix {
    _isStopped = YES;
    _isRunning = NO;
    
    // 取消当前网络请求
    [_currentTask cancel];
    _currentTask = nil;
    
    // 如果有待确认的工具请求，自动拒绝
    if (self.pendingToolRequest) {
        self.pendingToolRequest.status = AIToolRequestStatusRejected;
        self.pendingToolRequest = nil;
    }
    
    self.state = AISessionStateStopped;
}

- (void)clearSession {
    [_mutableMessages removeAllObjects];
    [_mutableModifications removeAllObjects];
    _pendingToolRequest = nil;
    _isRunning = NO;
    _isStopped = NO;
    self.state = AISessionStateIdle;
}

- (void)rollbackAllModifications {
    // 按时间倒序恢复
    NSArray *mods = [[self.mutableModifications reverseObjectEnumerator] allObjects];
    
    for (AIFileModification *mod in mods) {
        NSFileManager *fm = [NSFileManager defaultManager];
        
        if ([mod.operationType isEqualToString:@"delete"]) {
            // 恢复被删除的文件
            if (mod.originalContent) {
                NSString *dir = [mod.filePath stringByDeletingLastPathComponent];
                [fm createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:nil];
                [fm createFileAtPath:mod.filePath contents:mod.originalContent attributes:nil];
            }
        } else if ([mod.operationType isEqualToString:@"modify"]) {
            // 恢复原内容
            if (mod.originalContent) {
                [mod.originalContent writeToFile:mod.filePath atomically:YES];
            }
        } else if ([mod.operationType isEqualToString:@"rename"]) {
            // 恢复原文件名
            if (mod.originalPath) {
                [fm moveItemAtPath:mod.filePath toPath:mod.originalPath error:nil];
            }
        } else if ([mod.operationType isEqualToString:@"create"]) {
            // 删除新创建的文件
            [fm removeItemAtPath:mod.filePath error:nil];
        }
    }
    
    [_mutableModifications removeAllObjects];
}

- (NSString *)generateFixReport {
    NSMutableString *report = [NSMutableString string];
    
    [report appendString:@"# AI 修复报告\n\n"];
    [report appendFormat:@"生成时间: %@\n\n", [NSDate date]];
    
    if (self.modifications.count > 0) {
        [report appendString:@"## 修改记录\n\n"];
        
        for (AIFileModification *mod in self.modifications) {
            [report appendFormat:@"- **%@**: %@\n", mod.operationType, mod.filePath];
            if (mod.modificationDescription) {
                [report appendFormat:@"  - 说明: %@\n", mod.modificationDescription];
            }
        }
        
        [report appendString:@"\n## 恢复方法\n\n"];
        [report appendString:@"如果修复后问题未解决或出现新问题，您可以：\n"];
        [report appendString:@"1. 在 AI 修复界面点击\"撤销所有修改\"按钮\n"];
        [report appendString:@"2. 或手动恢复以下文件：\n\n"];
        
        for (AIFileModification *mod in self.modifications) {
            if (mod.originalContent) {
                [report appendFormat:@"- %@: 原内容已备份\n", mod.filePath];
            }
        }
    }
    
    return [report copy];
}

- (NSString *)loadSystemPrompt {
    // 尝试从用户自定义路径加载
    NSString *customPath = [NSString stringWithFormat:@"%s/ai_config/AIFixPrompt.md", getenv("POJAV_HOME")];
    NSString *promptContent = [NSString stringWithContentsOfFile:customPath encoding:NSUTF8StringEncoding error:nil];
    
    if (!promptContent) {
        // 从 Bundle 加载默认提示词
        NSString *bundlePath = [[NSBundle mainBundle] pathForResource:@"AIFixPrompt" ofType:@"md"];
        promptContent = [NSString stringWithContentsOfFile:bundlePath encoding:NSUTF8StringEncoding error:nil];
    }
    
    if (!promptContent) {
        // 使用内置基础提示词
        promptContent = [self defaultSystemPrompt];
    }
    
    return promptContent;
}

- (NSString *)defaultSystemPrompt {
    return @"你是一个专业的 Minecraft Java 版启动器崩溃诊断与修复助手。"
           "当前是一个运行在 iOS/iPadOS 设备上的 Minecraft Java 版启动器。"
           "请在分析崩溃日志后提供修复方案。每次只执行一个修复步骤。"
           "如果无法确定崩溃原因，建议用户前往 GitHub 提交 Issue。";
}

#pragma mark - 私有方法

- (void)recordModificationForTool:(NSString *)toolName parameters:(NSDictionary *)parameters {
    AIFileModification *mod = [[AIFileModification alloc] init];
    mod.timestamp = [NSDate date];
    
    if ([toolName isEqualToString:@"write_file"] || [toolName isEqualToString:@"append_file"]) {
        mod.filePath = parameters[@"path"];
        mod.operationType = @"modify";
        
        // 备份原内容
        NSString *original = [NSString stringWithContentsOfFile:mod.filePath encoding:NSUTF8StringEncoding error:nil];
        if (original) {
            mod.originalContent = [original dataUsingEncoding:NSUTF8StringEncoding];
        }
    } else if ([toolName isEqualToString:@"rename_file"]) {
        mod.filePath = parameters[@"new_path"];
        mod.originalPath = parameters[@"old_path"];
        mod.operationType = @"rename";
    } else if ([toolName isEqualToString:@"delete_file"]) {
        mod.filePath = parameters[@"path"];
        mod.operationType = @"delete";
        
        // 备份原内容
        NSData *original = [NSData dataWithContentsOfFile:mod.filePath];
        mod.originalContent = original;
    } else if ([toolName isEqualToString:@"create_directory"]) {
        mod.filePath = parameters[@"path"];
        mod.operationType = @"create";
    } else if ([toolName isEqualToString:@"toggle_mod"]) {
        mod.filePath = parameters[@"mod_path"];
        mod.operationType = @"modify";
        mod.modificationDescription = parameters[@"enable"] ? @"启用 Mod" : @"禁用 Mod";
    } else if ([toolName isEqualToString:@"delete_mod"]) {
        mod.filePath = parameters[@"mod_path"];
        mod.operationType = @"delete";
        
        // 备份原文件
        NSData *original = [NSData dataWithContentsOfFile:mod.filePath];
        mod.originalContent = original;
    } else if ([toolName isEqualToString:@"copy_file"]) {
        mod.filePath = parameters[@"destination_path"];
        mod.operationType = @"create";
    }
    
    if (mod.filePath) {
        [_mutableModifications addObject:mod];
        
        dispatch_async(dispatch_get_main_queue(), ^{
            if ([self.delegate respondsToSelector:@selector(aiService:didRecordModification:)]) {
                [self.delegate aiService:self didRecordModification:mod];
            }
        });
    }
}

- (void)sendChatRequest {
    if (self.isStopped) {
        return;
    }
    
    self.state = AISessionStateThinking;
    
    AIConfigService *config = [AIConfigService sharedService];
    
    // 构建请求
    NSString *urlString = [config.apiBaseURL stringByAppendingString:kOpenAIChatEndpoint];
    NSURL *url = [NSURL URLWithString:urlString];
    
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:url];
    request.HTTPMethod = @"POST";
    [request setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];
    [request setValue:[NSString stringWithFormat:@"Bearer %@", config.apiKey] forHTTPHeaderField:@"Authorization"];
    
    // 构建消息数组
    NSMutableArray *messagesArray = [NSMutableArray array];
    for (AIMessage *msg in self.messages) {
        NSDictionary *msgDict;
        switch (msg.role) {
            case AIMessageRoleSystem:
                msgDict = @{@"role": @"system", @"content": msg.content ?: @""};
                break;
            case AIMessageRoleUser:
                msgDict = @{@"role": @"user", @"content": msg.content ?: @""};
                break;
            case AIMessageRoleAssistant:
                if (msg.toolCall) {
                    msgDict = @{
                        @"role": @"assistant",
                        @"content": msg.content ?: @"",
                        @"tool_calls": @[msg.toolCall]
                    };
                } else {
                    msgDict = @{@"role": @"assistant", @"content": msg.content ?: @""};
                }
                break;
            case AIMessageRoleTool:
                msgDict = @{
                    @"role": @"tool",
                    @"tool_call_id": msg.toolCallId ?: @"",
                    @"content": msg.content ?: @""
                };
                break;
        }
        [messagesArray addObject:msgDict];
    }
    
    // 构建请求体
    NSMutableDictionary *requestBody = @{
        @"model": config.modelName,
        @"messages": messagesArray,
        @"tools": [AIToolKit toolsJSONSchema],
        @"tool_choice": @"auto",
        @"max_tokens": @4096,
        @"temperature": @0.7
    }.mutableCopy;
    
    NSError *jsonError;
    NSData *jsonData = [NSJSONSerialization dataWithJSONObject:requestBody options:0 error:&jsonError];
    
    if (jsonError) {
        [self handleError:jsonError];
        return;
    }
    
    request.HTTPBody = jsonData;
    
    // 发送请求
    _currentTask = [self.session dataTaskWithRequest:request completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        if (error) {
            if (error.code == NSURLErrorCancelled) {
                // 请求被取消，不报错
                return;
            }
            [self handleError:error];
            return;
        }
        
        NSHTTPURLResponse *httpResponse = (NSHTTPURLResponse *)response;
        if (httpResponse.statusCode >= 400) {
            NSString *errorBody = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
            NSError *httpError = [NSError errorWithDomain:@"AIFixServiceError" 
                                                     code:httpResponse.statusCode 
                                                 userInfo:@{NSLocalizedDescriptionKey: errorBody ?: @"HTTP Error"}];
            [self handleError:httpError];
            return;
        }
        
        NSError *parseError;
        NSDictionary *json = [NSJSONSerialization JSONObjectWithData:data options:0 error:&parseError];
        
        if (parseError) {
            [self handleError:parseError];
            return;
        }
        
        [self processAIResponse:json];
    }];
    
    [_currentTask resume];
}

- (void)processAIResponse:(NSDictionary *)json {
    NSArray *choices = json[@"choices"];
    if (choices.count == 0) {
        NSError *error = [NSError errorWithDomain:@"AIFixServiceError" code:100 userInfo:@{NSLocalizedDescriptionKey: @"AI 未返回任何响应"}];
        [self handleError:error];
        return;
    }
    
    NSDictionary *choice = choices.firstObject;
    NSDictionary *message = choice[@"message"];
    
    NSString *content = message[@"content"] ?: @"";
    NSArray *toolCalls = message[@"tool_calls"];
    
    // 添加 AI 消息到历史
    AIMessage *assistantMsg = [[AIMessage alloc] init];
    assistantMsg.role = AIMessageRoleAssistant;
    assistantMsg.content = content;
    
    // 通知代理收到消息
    dispatch_async(dispatch_get_main_queue(), ^{
        if ([self.delegate respondsToSelector:@selector(aiService:didReceiveMessage:)]) {
            [self.delegate aiService:self didReceiveMessage:assistantMsg];
        }
    });
    
    // 检查是否有工具调用
    if (toolCalls.count > 0) {
        NSDictionary *toolCall = toolCalls.firstObject;
        NSString *toolCallId = toolCall[@"id"];
        NSDictionary *function = toolCall[@"function"];
        NSString *toolName = function[@"name"];
        NSString *argumentsString = function[@"arguments"];
        
        // 解析参数
        NSError *parseError;
        NSDictionary *parameters = [NSJSONSerialization JSONObjectWithData:[argumentsString dataUsingEncoding:NSUTF8StringEncoding] options:0 error:&parseError];
        
        if (parseError) {
            parameters = @{};
        }
        
        // 记录工具调用
        assistantMsg.toolCall = toolCall;
        assistantMsg.toolCallId = toolCallId;
        
        [_mutableMessages addObject:assistantMsg];
        
        // 检查是否需要用户确认
        if ([AIToolKit toolRequiresUserConfirmation:toolName]) {
            // 创建工具请求并等待用户确认
            AIToolRequest *request = [AIToolRequest requestWithToolName:toolName
                                                            displayName:[AIToolKit availableToolsInfo].firstObject[@"display"]
                                                             parameters:parameters
                                                                 reason:content];
            
            // 从工具列表中获取显示名称
            for (NSDictionary *toolInfo in [AIToolKit availableToolsInfo]) {
                if ([toolInfo[@"name"] isEqualToString:toolName]) {
                    request.toolDisplayName = toolInfo[@"display"];
                    break;
                }
            }
            
            self.pendingToolRequest = request;
            self.state = AISessionStateWaitingTool;
            
            dispatch_async(dispatch_get_main_queue(), ^{
                if ([self.delegate respondsToSelector:@selector(aiService:didReceiveToolRequest:)]) {
                    [self.delegate aiService:self didReceiveToolRequest:request];
                }
            });
        } else {
            // 自动执行只读工具
            self.state = AISessionStateExecutingTool;
            
            NSError *error;
            AIToolResult *result = [AIToolKit executeToolWithName:toolName parameters:parameters error:&error];
            
            NSString *resultContent;
            if (result.success) {
                NSData *jsonData = [NSJSONSerialization dataWithJSONObject:result.data ?: @{} options:NSJSONWritingPrettyPrinted error:nil];
                resultContent = [[NSString alloc] initWithData:jsonData encoding:NSUTF8StringEncoding];
            } else {
                resultContent = [NSString stringWithFormat:@"工具执行失败: %@", error.localizedDescription];
            }
            
            [_mutableMessages addObject:[AIMessage toolResponseMessage:resultContent toolCallId:toolCallId]];
            [self sendChatRequest];
        }
    } else {
        // 没有工具调用，添加消息并继续
        [_mutableMessages addObject:assistantMsg];
        
        // 检查是否完成
        NSString *finishReason = choice[@"finish_reason"];
        if ([finishReason isEqualToString:@"stop"] || content.length == 0) {
            self.state = AISessionStateCompleted;
            _isRunning = NO;
            
            dispatch_async(dispatch_get_main_queue(), ^{
                if ([self.delegate respondsToSelector:@selector(aiServiceDidCompleteFix:)]) {
                    [self.delegate aiServiceDidCompleteFix:self];
                }
            });
        } else {
            // 继续对话
            [self sendChatRequest];
        }
    }
}

@end
