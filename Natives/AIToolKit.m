//
//  AIToolKit.m
//  Amethyst
//
//  AI 修复功能的工具集合实现
//

// 必须首先导入 Foundation，避免其他头文件中的宏定义与 Objective-C 关键字冲突
#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <mach/mach.h>

// 取消可能存在的 interface 宏定义，避免与 Objective-C 的 @interface 关键字冲突
#ifdef interface
#undef interface
#endif

#import "AIToolKit.h"
#import "ModService.h"
#import "ModItem.h"
#import "LauncherPreferences.h"
#import "PLProfiles.h"

#pragma mark - AIToolRequest

@implementation AIToolRequest

+ (instancetype)requestWithToolName:(NSString *)toolName 
                       displayName:(NSString *)displayName
                        parameters:(NSDictionary *)parameters 
                            reason:(NSString *)reason {
    AIToolRequest *request = [[AIToolRequest alloc] init];
    request.requestId = [[NSUUID UUID] UUIDString];
    request.toolName = toolName;
    request.toolDisplayName = displayName;
    request.parameters = parameters;
    request.reason = reason;
    request.status = AIToolRequestStatusPending;
    return request;
}

@end

#pragma mark - AIToolResult

@implementation AIToolResult

+ (instancetype)successWithData:(id)data message:(NSString *)message {
    AIToolResult *result = [[AIToolResult alloc] init];
    result.success = YES;
    result.data = data;
    result.message = message;
    return result;
}

+ (instancetype)failureWithError:(NSError *)error {
    AIToolResult *result = [[AIToolResult alloc] init];
    result.success = NO;
    result.error = error;
    return result;
}

@end

#pragma mark - AIToolKit

@implementation AIToolKit

+ (NSString *)launcherRootDirectory {
    const char *home = getenv("POJAV_HOME");
    return home ? [NSString stringWithUTF8String:home] : nil;
}

+ (NSString *)gameDirectory {
    const char *gameDir = getenv("POJAV_GAME_DIR");
    return gameDir ? [NSString stringWithUTF8String:gameDir] : nil;
}

+ (BOOL)isPathWithinLauncherDirectory:(NSString *)path {
    NSString *launcherRoot = [self launcherRootDirectory];
    NSString *gameDir = [self gameDirectory];
    
    if (!launcherRoot) return NO;
    
    NSString *standardizedPath = [path stringByStandardizingPath];
    NSString *standardizedRoot = [launcherRoot stringByStandardizingPath];
    
    // 检查路径是否以启动器目录开头
    if ([standardizedPath hasPrefix:standardizedRoot]) {
        return YES;
    }
    
    // 也检查游戏目录
    if (gameDir && [standardizedPath hasPrefix:[gameDir stringByStandardizingPath]]) {
        return YES;
    }
    
    return NO;
}

+ (NSArray<NSDictionary *> *)availableToolsInfo {
    return @[
        @{@"name": @"read_file", @"display": @"读取文件", @"description": @"读取指定文件的内容"},
        @{@"name": @"list_directory", @"display": @"读取目录", @"description": @"列出指定目录下的所有文件和文件夹"},
        @{@"name": @"write_file", @"display": @"写入文件", @"description": @"向指定文件写入内容（会覆盖原内容）"},
        @{@"name": @"append_file", @"display": @"追加文件", @"description": @"向指定文件末尾追加内容"},
        @{@"name": @"rename_file", @"display": @"重命名文件", @"description": @"重命名或移动文件"},
        @{@"name": @"delete_file", @"display": @"删除文件", @"description": @"删除指定的文件"},
        @{@"name": @"create_directory", @"display": @"创建目录", @"description": @"创建新目录"},
        @{@"name": @"get_mod_list", @"display": @"获取 Mod 列表", @"description": @"获取当前游戏配置文件下的所有 Mod 信息"},
        @{@"name": @"toggle_mod", @"display": @"启用/禁用 Mod", @"description": @"启用或禁用指定的 Mod"},
        @{@"name": @"delete_mod", @"display": @"删除 Mod", @"description": @"删除指定的 Mod 文件"},
        @{@"name": @"get_profiles", @"display": @"获取游戏配置列表", @"description": @"获取所有游戏配置文件的信息"},
        @{@"name": @"get_settings", @"display": @"获取启动器设置", @"description": @"获取启动器的所有设置信息"},
        @{@"name": @"update_setting", @"display": @"更新启动器设置", @"description": @"更新启动器的某个设置项"},
        @{@"name": @"get_system_info", @"display": @"获取系统信息", @"description": @"获取当前设备的系统信息"},
        @{@"name": @"search_log", @"display": @"搜索日志", @"description": @"在崩溃日志中搜索关键词"},
        @{@"name": @"analyze_crash_report", @"display": @"分析崩溃报告", @"description": @"分析崩溃报告并提取关键信息"},
        @{@"name": @"get_file_info", @"display": @"获取文件信息", @"description": @"获取文件的详细信息（大小、修改时间等）"},
        @{@"name": @"copy_file", @"display": @"复制文件", @"description": @"复制文件到指定位置"}
    ];
}

+ (NSArray<NSDictionary *> *)toolsJSONSchema {
    return @[
        // read_file
        @{
            @"type": @"function",
            @"function": @{
                @"name": @"read_file",
                @"description": @"读取指定文件的内容",
                @"parameters": @{
                    @"type": @"object",
                    @"properties": @{
                        @"path": @{
                            @"type": @"string",
                            @"description": @"文件的绝对路径"
                        }
                    },
                    @"required": @[@"path"]
                }
            }
        },
        // list_directory
        @{
            @"type": @"function",
            @"function": @{
                @"name": @"list_directory",
                @"description": @"列出指定目录下的所有文件和文件夹",
                @"parameters": @{
                    @"type": @"object",
                    @"properties": @{
                        @"path": @{
                            @"type": @"string",
                            @"description": @"目录的绝对路径"
                        }
                    },
                    @"required": @[@"path"]
                }
            }
        },
        // write_file
        @{
            @"type": @"function",
            @"function": @{
                @"name": @"write_file",
                @"description": @"向指定文件写入内容（会覆盖原内容）",
                @"parameters": @{
                    @"type": @"object",
                    @"properties": @{
                        @"path": @{
                            @"type": @"string",
                            @"description": @"文件路径"
                        },
                        @"content": @{
                            @"type": @"string",
                            @"description": @"要写入的内容"
                        }
                    },
                    @"required": @[@"path", @"content"]
                }
            }
        },
        // append_file
        @{
            @"type": @"function",
            @"function": @{
                @"name": @"append_file",
                @"description": @"向指定文件末尾追加内容",
                @"parameters": @{
                    @"type": @"object",
                    @"properties": @{
                        @"path": @{
                            @"type": @"string",
                            @"description": @"文件路径"
                        },
                        @"content": @{
                            @"type": @"string",
                            @"description": @"要追加的内容"
                        }
                    },
                    @"required": @[@"path", @"content"]
                }
            }
        },
        // rename_file
        @{
            @"type": @"function",
            @"function": @{
                @"name": @"rename_file",
                @"description": @"重命名或移动文件",
                @"parameters": @{
                    @"type": @"object",
                    @"properties": @{
                        @"old_path": @{
                            @"type": @"string",
                            @"description": @"原文件路径"
                        },
                        @"new_path": @{
                            @"type": @"string",
                            @"description": @"新文件路径"
                        }
                    },
                    @"required": @[@"old_path", @"new_path"]
                }
            }
        },
        // delete_file
        @{
            @"type": @"function",
            @"function": @{
                @"name": @"delete_file",
                @"description": @"删除指定的文件",
                @"parameters": @{
                    @"type": @"object",
                    @"properties": @{
                        @"path": @{
                            @"type": @"string",
                            @"description": @"要删除的文件路径"
                        }
                    },
                    @"required": @[@"path"]
                }
            }
        },
        // create_directory
        @{
            @"type": @"function",
            @"function": @{
                @"name": @"create_directory",
                @"description": @"创建新目录",
                @"parameters": @{
                    @"type": @"object",
                    @"properties": @{
                        @"path": @{
                            @"type": @"string",
                            @"description": @"目录路径"
                        }
                    },
                    @"required": @[@"path"]
                }
            }
        },
        // get_mod_list
        @{
            @"type": @"function",
            @"function": @{
                @"name": @"get_mod_list",
                @"description": @"获取当前游戏配置文件下的所有 Mod 信息",
                @"parameters": @{
                    @"type": @"object",
                    @"properties": @{
                        @"profile_name": @{
                            @"type": @"string",
                            @"description": @"游戏配置文件名（可选，默认为当前选中的配置）"
                        }
                    },
                    @"required": @[]
                }
            }
        },
        // toggle_mod
        @{
            @"type": @"function",
            @"function": @{
                @"name": @"toggle_mod",
                @"description": @"启用或禁用指定的 Mod",
                @"parameters": @{
                    @"type": @"object",
                    @"properties": @{
                        @"mod_path": @{
                            @"type": @"string",
                            @"description": @"Mod 文件的完整路径"
                        },
                        @"enable": @{
                            @"type": @"boolean",
                            @"description": @"true 为启用，false 为禁用"
                        }
                    },
                    @"required": @[@"mod_path", @"enable"]
                }
            }
        },
        // delete_mod
        @{
            @"type": @"function",
            @"function": @{
                @"name": @"delete_mod",
                @"description": @"删除指定的 Mod 文件",
                @"parameters": @{
                    @"type": @"object",
                    @"properties": @{
                        @"mod_path": @{
                            @"type": @"string",
                            @"description": @"Mod 文件的完整路径"
                        }
                    },
                    @"required": @[@"mod_path"]
                }
            }
        },
        // get_profiles
        @{
            @"type": @"function",
            @"function": @{
                @"name": @"get_profiles",
                @"description": @"获取所有游戏配置文件的信息",
                @"parameters": @{
                    @"type": @"object",
                    @"properties": @{},
                    @"required": @[]
                }
            }
        },
        // get_settings
        @{
            @"type": @"function",
            @"function": @{
                @"name": @"get_settings",
                @"description": @"获取启动器的所有设置信息",
                @"parameters": @{
                    @"type": @"object",
                    @"properties": @{},
                    @"required": @[]
                }
            }
        },
        // update_setting
        @{
            @"type": @"function",
            @"function": @{
                @"name": @"update_setting",
                @"description": @"更新启动器的某个设置项",
                @"parameters": @{
                    @"type": @"object",
                    @"properties": @{
                        @"key": @{
                            @"type": @"string",
                            @"description": @"设置项的键名（如 \"video.renderer\", \"java.allocated_memory\"）"
                        },
                        @"value": @{
                            @"description": @"新的值"
                        }
                    },
                    @"required": @[@"key", @"value"]
                }
            }
        },
        // get_system_info
        @{
            @"type": @"function",
            @"function": @{
                @"name": @"get_system_info",
                @"description": @"获取当前设备的系统信息",
                @"parameters": @{
                    @"type": @"object",
                    @"properties": @{},
                    @"required": @[]
                }
            }
        },
        // search_log
        @{
            @"type": @"function",
            @"function": @{
                @"name": @"search_log",
                @"description": @"在崩溃日志中搜索关键词",
                @"parameters": @{
                    @"type": @"object",
                    @"properties": @{
                        @"keyword": @{
                            @"type": @"string",
                            @"description": @"搜索关键词"
                        }
                    },
                    @"required": @[@"keyword"]
                }
            }
        },
        // analyze_crash_report
        @{
            @"type": @"function",
            @"function": @{
                @"name": @"analyze_crash_report",
                @"description": @"分析崩溃报告并提取关键信息",
                @"parameters": @{
                    @"type": @"object",
                    @"properties": @{},
                    @"required": @[]
                }
            }
        },
        // get_file_info
        @{
            @"type": @"function",
            @"function": @{
                @"name": @"get_file_info",
                @"description": @"获取文件的详细信息（大小、修改时间等）",
                @"parameters": @{
                    @"type": @"object",
                    @"properties": @{
                        @"path": @{
                            @"type": @"string",
                            @"description": @"文件路径"
                        }
                    },
                    @"required": @[@"path"]
                }
            }
        },
        // copy_file
        @{
            @"type": @"function",
            @"function": @{
                @"name": @"copy_file",
                @"description": @"复制文件到指定位置",
                @"parameters": @{
                    @"type": @"object",
                    @"properties": @{
                        @"source_path": @{
                            @"type": @"string",
                            @"description": @"源文件路径"
                        },
                        @"destination_path": @{
                            @"type": @"string",
                            @"description": @"目标文件路径"
                        }
                    },
                    @"required": @[@"source_path", @"destination_path"]
                }
            }
        }
    ];
}

+ (AIToolResult *)executeToolWithName:(NSString *)toolName 
                           parameters:(NSDictionary *)parameters 
                                error:(NSError **)error {
    // 检查路径安全性（对于涉及路径的工具）
    NSArray *pathTools = @[@"read_file", @"list_directory", @"write_file", @"append_file", 
                           @"rename_file", @"delete_file", @"create_directory", @"get_file_info", @"copy_file"];
    
    if ([pathTools containsObject:toolName]) {
        NSString *path = parameters[@"path"] ?: parameters[@"old_path"] ?: parameters[@"source_path"];
        if (path && ![self isPathWithinLauncherDirectory:path]) {
            NSString *errorMsg = [NSString stringWithFormat:@"路径 '%@' 不在启动器目录内，操作已被拒绝", path];
            if (error) {
                *error = [NSError errorWithDomain:@"AIToolKitError" code:403 userInfo:@{NSLocalizedDescriptionKey: errorMsg}];
            }
            return [AIToolResult failureWithError:*error];
        }
        
        // 检查 rename_file 和 copy_file 的目标路径
        NSString *destPath = parameters[@"new_path"] ?: parameters[@"destination_path"];
        if (destPath && ![self isPathWithinLauncherDirectory:destPath]) {
            NSString *errorMsg = [NSString stringWithFormat:@"目标路径 '%@' 不在启动器目录内，操作已被拒绝", destPath];
            if (error) {
                *error = [NSError errorWithDomain:@"AIToolKitError" code:403 userInfo:@{NSLocalizedDescriptionKey: errorMsg}];
            }
            return [AIToolResult failureWithError:*error];
        }
    }
    
    // 路由到具体的工具执行器
    if ([toolName isEqualToString:@"read_file"]) {
        return [AIToolReadFile executeWithParameters:parameters];
    } else if ([toolName isEqualToString:@"list_directory"]) {
        return [AIToolListDirectory executeWithParameters:parameters];
    } else if ([toolName isEqualToString:@"write_file"]) {
        return [AIToolWriteFile executeWithParameters:parameters];
    } else if ([toolName isEqualToString:@"append_file"]) {
        return [AIToolAppendFile executeWithParameters:parameters];
    } else if ([toolName isEqualToString:@"rename_file"]) {
        return [AIToolRenameFile executeWithParameters:parameters];
    } else if ([toolName isEqualToString:@"delete_file"]) {
        return [AIToolDeleteFile executeWithParameters:parameters];
    } else if ([toolName isEqualToString:@"create_directory"]) {
        return [AIToolCreateDirectory executeWithParameters:parameters];
    } else if ([toolName isEqualToString:@"get_mod_list"]) {
        return [AIToolGetModList executeWithParameters:parameters];
    } else if ([toolName isEqualToString:@"toggle_mod"]) {
        return [AIToolToggleMod executeWithParameters:parameters];
    } else if ([toolName isEqualToString:@"delete_mod"]) {
        return [AIToolDeleteMod executeWithParameters:parameters];
    } else if ([toolName isEqualToString:@"get_profiles"]) {
        return [AIToolGetProfiles executeWithParameters:parameters];
    } else if ([toolName isEqualToString:@"get_settings"]) {
        return [AIToolGetSettings executeWithParameters:parameters];
    } else if ([toolName isEqualToString:@"update_setting"]) {
        return [AIToolUpdateSetting executeWithParameters:parameters];
    } else if ([toolName isEqualToString:@"get_system_info"]) {
        return [AIToolGetSystemInfo executeWithParameters:parameters];
    } else if ([toolName isEqualToString:@"search_log"]) {
        return [AIToolSearchLog executeWithParameters:parameters];
    } else if ([toolName isEqualToString:@"analyze_crash_report"]) {
        return [AIToolAnalyzeCrashReport executeWithParameters:parameters];
    } else if ([toolName isEqualToString:@"get_file_info"]) {
        return [AIToolGetFileInfo executeWithParameters:parameters];
    } else if ([toolName isEqualToString:@"copy_file"]) {
        return [AIToolCopyFile executeWithParameters:parameters];
    }
    
    if (error) {
        *error = [NSError errorWithDomain:@"AIToolKitError" code:404 userInfo:@{NSLocalizedDescriptionKey: [NSString stringWithFormat:@"未知的工具: %@", toolName]}];
    }
    return [AIToolResult failureWithError:*error];
}

+ (BOOL)toolRequiresUserConfirmation:(NSString *)toolName {
    NSArray *confirmationRequiredTools = @[
        @"write_file", @"append_file", @"rename_file", @"delete_file", 
        @"create_directory", @"toggle_mod", @"delete_mod", @"update_setting", @"copy_file"
    ];
    return [confirmationRequiredTools containsObject:toolName];
}

+ (BOOL)toolIsReadOnlyOperation:(NSString *)toolName {
    NSArray *readOnlyTools = @[
        @"read_file", @"list_directory", @"get_mod_list", @"get_profiles", 
        @"get_settings", @"get_system_info", @"search_log", @"analyze_crash_report", @"get_file_info"
    ];
    return [readOnlyTools containsObject:toolName];
}

@end

#pragma mark - AIToolReadFile

@implementation AIToolReadFile

+ (NSString *)toolName { return @"read_file"; }
+ (NSString *)toolDisplayName { return @"读取文件"; }
+ (NSString *)toolDescription { return @"读取指定文件的内容"; }
+ (BOOL)requiresUserConfirmation { return NO; }
+ (BOOL)isReadOnlyOperation { return YES; }

+ (AIToolResult *)executeWithParameters:(NSDictionary *)parameters {
    NSString *path = parameters[@"path"];
    if (!path) {
        NSError *error = [NSError errorWithDomain:@"AIToolKitError" code:1 userInfo:@{NSLocalizedDescriptionKey: @"缺少 path 参数"}];
        return [AIToolResult failureWithError:error];
    }
    
    NSFileManager *fm = [NSFileManager defaultManager];
    if (![fm fileExistsAtPath:path]) {
        NSError *error = [NSError errorWithDomain:@"AIToolKitError" code:2 userInfo:@{NSLocalizedDescriptionKey: [NSString stringWithFormat:@"文件不存在: %@", path]}];
        return [AIToolResult failureWithError:error];
    }
    
    NSError *readError;
    NSString *content = [NSString stringWithContentsOfFile:path encoding:NSUTF8StringEncoding error:&readError];
    
    if (readError) {
        return [AIToolResult failureWithError:readError];
    }
    
    // 对于大文件，限制返回的内容大小
    if (content.length > 100000) {
        content = [NSString stringWithFormat:@"[文件内容过长，已截取前100000字符]\n\n%@", [content substringToIndex:100000]];
    }
    
    return [AIToolResult successWithData:@{@"content": content} message:@"文件读取成功"];
}

@end

#pragma mark - AIToolListDirectory

@implementation AIToolListDirectory

+ (NSString *)toolName { return @"list_directory"; }
+ (NSString *)toolDisplayName { return @"读取目录"; }
+ (NSString *)toolDescription { return @"列出指定目录下的所有文件和文件夹"; }
+ (BOOL)requiresUserConfirmation { return NO; }
+ (BOOL)isReadOnlyOperation { return YES; }

+ (AIToolResult *)executeWithParameters:(NSDictionary *)parameters {
    NSString *path = parameters[@"path"];
    if (!path) {
        NSError *error = [NSError errorWithDomain:@"AIToolKitError" code:1 userInfo:@{NSLocalizedDescriptionKey: @"缺少 path 参数"}];
        return [AIToolResult failureWithError:error];
    }
    
    NSFileManager *fm = [NSFileManager defaultManager];
    BOOL isDirectory = NO;
    
    if (![fm fileExistsAtPath:path isDirectory:&isDirectory]) {
        NSError *error = [NSError errorWithDomain:@"AIToolKitError" code:2 userInfo:@{NSLocalizedDescriptionKey: [NSString stringWithFormat:@"目录不存在: %@", path]}];
        return [AIToolResult failureWithError:error];
    }
    
    if (!isDirectory) {
        NSError *error = [NSError errorWithDomain:@"AIToolKitError" code:3 userInfo:@{NSLocalizedDescriptionKey: [NSString stringWithFormat:@"路径不是目录: %@", path]}];
        return [AIToolResult failureWithError:error];
    }
    
    NSError *listError;
    NSArray<NSString *> *contents = [fm contentsOfDirectoryAtPath:path error:&listError];
    
    if (listError) {
        return [AIToolResult failureWithError:listError];
    }
    
    NSMutableArray *items = [NSMutableArray array];
    for (NSString *item in contents) {
        NSString *itemPath = [path stringByAppendingPathComponent:item];
        NSDictionary *attributes = [fm attributesOfItemAtPath:itemPath error:nil];
        BOOL isDir = [attributes[NSFileType] isEqualToString:NSFileTypeDirectory];

        // 将 NSDate 转换为 ISO 8601 字符串以便 JSON 序列化
        NSDate *modDate = attributes[NSFileModificationDate];
        NSString *modDateString = @"未知";
        if (modDate) {
            NSDateFormatter *formatter = [[NSDateFormatter alloc] init];
            formatter.dateFormat = @"yyyy-MM-dd HH:mm:ss";
            modDateString = [formatter stringFromDate:modDate];
        }

        [items addObject:@{
            @"name": item,
            @"path": itemPath,
            @"isDirectory": @(isDir),
            @"size": attributes[NSFileSize] ?: @0,
            @"modificationDate": modDateString
        }];
    }
    
    return [AIToolResult successWithData:@{@"items": items} message:[NSString stringWithFormat:@"目录包含 %lu 个项目", (unsigned long)items.count]];
}

@end

#pragma mark - AIToolWriteFile

@implementation AIToolWriteFile

+ (NSString *)toolName { return @"write_file"; }
+ (NSString *)toolDisplayName { return @"写入文件"; }
+ (NSString *)toolDescription { return @"向指定文件写入内容（会覆盖原内容）"; }
+ (BOOL)requiresUserConfirmation { return YES; }
+ (BOOL)isReadOnlyOperation { return NO; }

+ (AIToolResult *)executeWithParameters:(NSDictionary *)parameters {
    NSString *path = parameters[@"path"];
    NSString *content = parameters[@"content"];
    
    if (!path || !content) {
        NSError *error = [NSError errorWithDomain:@"AIToolKitError" code:1 userInfo:@{NSLocalizedDescriptionKey: @"缺少 path 或 content 参数"}];
        return [AIToolResult failureWithError:error];
    }
    
    // 确保目录存在
    NSString *directory = [path stringByDeletingLastPathComponent];
    NSFileManager *fm = [NSFileManager defaultManager];
    if (![fm fileExistsAtPath:directory]) {
        [fm createDirectoryAtPath:directory withIntermediateDirectories:YES attributes:nil error:nil];
    }
    
    NSError *writeError;
    BOOL success = [content writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:&writeError];
    
    if (!success) {
        return [AIToolResult failureWithError:writeError];
    }
    
    return [AIToolResult successWithData:nil message:@"文件写入成功"];
}

@end

#pragma mark - AIToolAppendFile

@implementation AIToolAppendFile

+ (NSString *)toolName { return @"append_file"; }
+ (NSString *)toolDisplayName { return @"追加文件"; }
+ (NSString *)toolDescription { return @"向指定文件末尾追加内容"; }
+ (BOOL)requiresUserConfirmation { return YES; }
+ (BOOL)isReadOnlyOperation { return NO; }

+ (AIToolResult *)executeWithParameters:(NSDictionary *)parameters {
    NSString *path = parameters[@"path"];
    NSString *content = parameters[@"content"];
    
    if (!path || !content) {
        NSError *error = [NSError errorWithDomain:@"AIToolKitError" code:1 userInfo:@{NSLocalizedDescriptionKey: @"缺少 path 或 content 参数"}];
        return [AIToolResult failureWithError:error];
    }
    
    NSFileHandle *fileHandle = [NSFileHandle fileHandleForWritingAtPath:path];
    if (!fileHandle) {
        // 文件不存在，创建新文件
        NSError *writeError;
        BOOL success = [content writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:&writeError];
        if (!success) {
            return [AIToolResult failureWithError:writeError];
        }
    } else {
        [fileHandle seekToEndOfFile];
        [fileHandle writeData:[content dataUsingEncoding:NSUTF8StringEncoding]];
        [fileHandle closeFile];
    }
    
    return [AIToolResult successWithData:nil message:@"内容追加成功"];
}

@end

#pragma mark - AIToolRenameFile

@implementation AIToolRenameFile

+ (NSString *)toolName { return @"rename_file"; }
+ (NSString *)toolDisplayName { return @"重命名文件"; }
+ (NSString *)toolDescription { return @"重命名或移动文件"; }
+ (BOOL)requiresUserConfirmation { return YES; }
+ (BOOL)isReadOnlyOperation { return NO; }

+ (AIToolResult *)executeWithParameters:(NSDictionary *)parameters {
    NSString *oldPath = parameters[@"old_path"];
    NSString *newPath = parameters[@"new_path"];
    
    if (!oldPath || !newPath) {
        NSError *error = [NSError errorWithDomain:@"AIToolKitError" code:1 userInfo:@{NSLocalizedDescriptionKey: @"缺少 old_path 或 new_path 参数"}];
        return [AIToolResult failureWithError:error];
    }
    
    NSFileManager *fm = [NSFileManager defaultManager];
    
    if (![fm fileExistsAtPath:oldPath]) {
        NSError *error = [NSError errorWithDomain:@"AIToolKitError" code:2 userInfo:@{NSLocalizedDescriptionKey: [NSString stringWithFormat:@"原文件不存在: %@", oldPath]}];
        return [AIToolResult failureWithError:error];
    }
    
    NSError *moveError;
    BOOL success = [fm moveItemAtPath:oldPath toPath:newPath error:&moveError];
    
    if (!success) {
        return [AIToolResult failureWithError:moveError];
    }
    
    return [AIToolResult successWithData:@{@"old_path": oldPath, @"new_path": newPath} message:@"文件重命名成功"];
}

@end

#pragma mark - AIToolDeleteFile

@implementation AIToolDeleteFile

+ (NSString *)toolName { return @"delete_file"; }
+ (NSString *)toolDisplayName { return @"删除文件"; }
+ (NSString *)toolDescription { return @"删除指定的文件"; }
+ (BOOL)requiresUserConfirmation { return YES; }
+ (BOOL)isReadOnlyOperation { return NO; }

+ (AIToolResult *)executeWithParameters:(NSDictionary *)parameters {
    NSString *path = parameters[@"path"];
    
    if (!path) {
        NSError *error = [NSError errorWithDomain:@"AIToolKitError" code:1 userInfo:@{NSLocalizedDescriptionKey: @"缺少 path 参数"}];
        return [AIToolResult failureWithError:error];
    }
    
    NSFileManager *fm = [NSFileManager defaultManager];
    
    if (![fm fileExistsAtPath:path]) {
        NSError *error = [NSError errorWithDomain:@"AIToolKitError" code:2 userInfo:@{NSLocalizedDescriptionKey: [NSString stringWithFormat:@"文件不存在: %@", path]}];
        return [AIToolResult failureWithError:error];
    }
    
    NSError *deleteError;
    BOOL success = [fm removeItemAtPath:path error:&deleteError];
    
    if (!success) {
        return [AIToolResult failureWithError:deleteError];
    }
    
    return [AIToolResult successWithData:nil message:@"文件删除成功"];
}

@end

#pragma mark - AIToolCreateDirectory

@implementation AIToolCreateDirectory

+ (NSString *)toolName { return @"create_directory"; }
+ (NSString *)toolDisplayName { return @"创建目录"; }
+ (NSString *)toolDescription { return @"创建新目录"; }
+ (BOOL)requiresUserConfirmation { return YES; }
+ (BOOL)isReadOnlyOperation { return NO; }

+ (AIToolResult *)executeWithParameters:(NSDictionary *)parameters {
    NSString *path = parameters[@"path"];
    
    if (!path) {
        NSError *error = [NSError errorWithDomain:@"AIToolKitError" code:1 userInfo:@{NSLocalizedDescriptionKey: @"缺少 path 参数"}];
        return [AIToolResult failureWithError:error];
    }
    
    NSFileManager *fm = [NSFileManager defaultManager];
    NSError *createError;
    BOOL success = [fm createDirectoryAtPath:path withIntermediateDirectories:YES attributes:nil error:&createError];
    
    if (!success) {
        return [AIToolResult failureWithError:createError];
    }
    
    return [AIToolResult successWithData:nil message:@"目录创建成功"];
}

@end

#pragma mark - AIToolGetModList

@implementation AIToolGetModList

+ (NSString *)toolName { return @"get_mod_list"; }
+ (NSString *)toolDisplayName { return @"获取 Mod 列表"; }
+ (NSString *)toolDescription { return @"获取当前游戏配置文件下的所有 Mod 信息"; }
+ (BOOL)requiresUserConfirmation { return NO; }
+ (BOOL)isReadOnlyOperation { return YES; }

+ (AIToolResult *)executeWithParameters:(NSDictionary *)parameters {
    NSString *profileName = parameters[@"profile_name"];
    
    __block AIToolResult *result = nil;
    dispatch_semaphore_t semaphore = dispatch_semaphore_create(0);
    
    [[ModService sharedService] scanModsForProfile:profileName completion:^(NSArray<ModItem *> *mods) {
        NSMutableArray *modList = [NSMutableArray array];
        for (ModItem *mod in mods) {
            [modList addObject:@{
                @"name": mod.displayName ?: mod.fileName,
                @"fileName": mod.fileName,
                @"path": mod.filePath,
                @"version": mod.version ?: @"未知",
                @"author": mod.author ?: @"未知",
                @"description": mod.modDescription ?: @"",
                @"enabled": @(!mod.disabled),
                @"isFabric": @(mod.isFabric),
                @"isForge": @(mod.isForge),
                @"isNeoForge": @(mod.isNeoForge),
                @"gameVersion": mod.gameVersion ?: @"未知"
            }];
        }
        result = [AIToolResult successWithData:@{@"mods": modList} message:[NSString stringWithFormat:@"找到 %lu 个 Mod", (unsigned long)modList.count]];
        dispatch_semaphore_signal(semaphore);
    }];
    
    dispatch_semaphore_wait(semaphore, dispatch_time(DISPATCH_TIME_NOW, 10 * NSEC_PER_SEC));
    
    return result ?: [AIToolResult successWithData:@{@"mods": @[]} message:@"获取 Mod 列表超时"];
}

@end

#pragma mark - AIToolToggleMod

@implementation AIToolToggleMod

+ (NSString *)toolName { return @"toggle_mod"; }
+ (NSString *)toolDisplayName { return @"启用/禁用 Mod"; }
+ (NSString *)toolDescription { return @"启用或禁用指定的 Mod"; }
+ (BOOL)requiresUserConfirmation { return YES; }
+ (BOOL)isReadOnlyOperation { return NO; }

+ (AIToolResult *)executeWithParameters:(NSDictionary *)parameters {
    NSString *modPath = parameters[@"mod_path"];
    BOOL enable = [parameters[@"enable"] boolValue];
    
    if (!modPath) {
        NSError *error = [NSError errorWithDomain:@"AIToolKitError" code:1 userInfo:@{NSLocalizedDescriptionKey: @"缺少 mod_path 参数"}];
        return [AIToolResult failureWithError:error];
    }
    
    NSFileManager *fm = [NSFileManager defaultManager];
    if (![fm fileExistsAtPath:modPath]) {
        NSError *error = [NSError errorWithDomain:@"AIToolKitError" code:2 userInfo:@{NSLocalizedDescriptionKey: [NSString stringWithFormat:@"Mod 文件不存在: %@", modPath]}];
        return [AIToolResult failureWithError:error];
    }
    
    // 检查当前状态
    NSString *disabledPath = [modPath stringByAppendingString:@".disabled"];
    BOOL currentlyDisabled = [fm fileExistsAtPath:disabledPath] || [modPath hasSuffix:@".disabled"];
    
    if (enable && currentlyDisabled) {
        // 启用: 移除 .disabled 后缀
        NSString *newPath = [modPath stringByDeletingPathExtension];
        if ([modPath hasSuffix:@".jar.disabled"]) {
            newPath = [modPath substringToIndex:modPath.length - 9]; // 移除 ".disabled"
        }
        NSError *moveError;
        [fm moveItemAtPath:modPath toPath:newPath error:&moveError];
        if (moveError) {
            return [AIToolResult failureWithError:moveError];
        }
        return [AIToolResult successWithData:@{@"mod_path": modPath, @"enabled": @YES} message:@"Mod 已启用"];
    } else if (!enable && !currentlyDisabled) {
        // 禁用: 添加 .disabled 后缀
        NSString *newPath = [modPath stringByAppendingString:@".disabled"];
        NSError *moveError;
        [fm moveItemAtPath:modPath toPath:newPath error:&moveError];
        if (moveError) {
            return [AIToolResult failureWithError:moveError];
        }
        return [AIToolResult successWithData:@{@"mod_path": modPath, @"enabled": @NO} message:@"Mod 已禁用"];
    }
    
    return [AIToolResult successWithData:nil message:@"Mod 状态未改变"];
}

@end

#pragma mark - AIToolDeleteMod

@implementation AIToolDeleteMod

+ (NSString *)toolName { return @"delete_mod"; }
+ (NSString *)toolDisplayName { return @"删除 Mod"; }
+ (NSString *)toolDescription { return @"删除指定的 Mod 文件"; }
+ (BOOL)requiresUserConfirmation { return YES; }
+ (BOOL)isReadOnlyOperation { return NO; }

+ (AIToolResult *)executeWithParameters:(NSDictionary *)parameters {
    NSString *modPath = parameters[@"mod_path"];
    
    if (!modPath) {
        NSError *error = [NSError errorWithDomain:@"AIToolKitError" code:1 userInfo:@{NSLocalizedDescriptionKey: @"缺少 mod_path 参数"}];
        return [AIToolResult failureWithError:error];
    }
    
    NSError *deleteError;
    BOOL success = [[NSFileManager defaultManager] removeItemAtPath:modPath error:&deleteError];
    
    if (!success) {
        return [AIToolResult failureWithError:deleteError];
    }
    
    return [AIToolResult successWithData:nil message:@"Mod 已删除"];
}

@end

#pragma mark - AIToolGetProfiles

@implementation AIToolGetProfiles

+ (NSString *)toolName { return @"get_profiles"; }
+ (NSString *)toolDisplayName { return @"获取游戏配置列表"; }
+ (NSString *)toolDescription { return @"获取所有游戏配置文件的信息"; }
+ (BOOL)requiresUserConfirmation { return NO; }
+ (BOOL)isReadOnlyOperation { return YES; }

+ (AIToolResult *)executeWithParameters:(NSDictionary *)parameters {
    NSDictionary *profiles = PLProfiles.current.profiles;
    NSMutableArray *profileList = [NSMutableArray array];
    
    NSString *currentSelectedName = nil;
    id selectedProfile = PLProfiles.current.selectedProfile;
    if ([selectedProfile isKindOfClass:[NSString class]]) {
        currentSelectedName = selectedProfile;
    } else if ([selectedProfile isKindOfClass:[NSDictionary class]]) {
        currentSelectedName = ((NSDictionary *)selectedProfile)[@"name"];
    }
    
    for (NSString *name in profiles) {
        NSDictionary *profile = profiles[name];
        if ([profile isKindOfClass:[NSDictionary class]]) {
            [profileList addObject:@{
                @"name": name,
                @"gameDir": profile[@"gameDir"] ?: @"",
                @"lastVersionId": profile[@"lastVersionId"] ?: @"未知",
                @"javaArgs": profile[@"javaArgs"] ?: @"",
                @"selected": @([name isEqualToString:currentSelectedName])
            }];
        }
    }
    
    return [AIToolResult successWithData:@{@"profiles": profileList} message:[NSString stringWithFormat:@"找到 %lu 个游戏配置", (unsigned long)profileList.count]];
}

@end

#pragma mark - AIToolGetSettings

@implementation AIToolGetSettings

+ (NSString *)toolName { return @"get_settings"; }
+ (NSString *)toolDisplayName { return @"获取启动器设置"; }
+ (NSString *)toolDescription { return @"获取启动器的所有设置信息"; }
+ (BOOL)requiresUserConfirmation { return NO; }
+ (BOOL)isReadOnlyOperation { return YES; }

+ (AIToolResult *)executeWithParameters:(NSDictionary *)parameters {
    NSMutableDictionary *settings = [NSMutableDictionary dictionary];
    
    // 获取各个设置区域
    NSArray *keys = @[@"general", @"video", @"control", @"java", @"internal"];
    for (NSString *key in keys) {
        id value = getPrefObject(key);
        if (value) {
            settings[key] = value;
        }
    }
    
    return [AIToolResult successWithData:@{@"settings": settings} message:@"设置获取成功"];
}

@end

#pragma mark - AIToolUpdateSetting

@implementation AIToolUpdateSetting

+ (NSString *)toolName { return @"update_setting"; }
+ (NSString *)toolDisplayName { return @"更新启动器设置"; }
+ (NSString *)toolDescription { return @"更新启动器的某个设置项"; }
+ (BOOL)requiresUserConfirmation { return YES; }
+ (BOOL)isReadOnlyOperation { return NO; }

+ (AIToolResult *)executeWithParameters:(NSDictionary *)parameters {
    NSString *key = parameters[@"key"];
    id value = parameters[@"value"];
    
    if (!key) {
        NSError *error = [NSError errorWithDomain:@"AIToolKitError" code:1 userInfo:@{NSLocalizedDescriptionKey: @"缺少 key 参数"}];
        return [AIToolResult failureWithError:error];
    }
    
    // 获取旧值用于恢复
    id oldValue = getPrefObject(key);
    
    // 设置新值
    if ([value isKindOfClass:[NSString class]]) {
        setPrefString(key, value);
    } else if ([value isKindOfClass:[NSNumber class]]) {
        if (strcmp([value objCType], @encode(BOOL)) == 0) {
            setPrefBool(key, [value boolValue]);
        } else if (strcmp([value objCType], @encode(float)) == 0 || 
                   strcmp([value objCType], @encode(double)) == 0) {
            setPrefFloat(key, [value floatValue]);
        } else {
            setPrefInt(key, [value integerValue]);
        }
    } else {
        setPrefObject(key, value);
    }
    
    return [AIToolResult successWithData:@{
        @"key": key,
        @"oldValue": oldValue ?: [NSNull null],
        @"newValue": value
    } message:@"设置更新成功"];
}

@end

#pragma mark - AIToolGetSystemInfo

@implementation AIToolGetSystemInfo

+ (NSString *)toolName { return @"get_system_info"; }
+ (NSString *)toolDisplayName { return @"获取系统信息"; }
+ (NSString *)toolDescription { return @"获取当前设备的系统信息"; }
+ (BOOL)requiresUserConfirmation { return NO; }
+ (BOOL)isReadOnlyOperation { return YES; }

+ (AIToolResult *)executeWithParameters:(NSDictionary *)parameters {
    NSProcessInfo *processInfo = [NSProcessInfo processInfo];
    UIDevice *device = [UIDevice currentDevice];
    
    // 使用 Mach API 获取可用内存（iOS 兼容方式）
    NSUInteger availableMemMB = 0;
    mach_port_t host = mach_host_self();
    vm_size_t pageSize;
    host_page_size(host, &pageSize);
    
    vm_statistics64_data_t vmStats;
    mach_msg_type_number_t count = HOST_VM_INFO64_COUNT;
    kern_return_t result = host_statistics64(host, HOST_VM_INFO64, (host_info64_t)&vmStats, &count);
    
    if (result == KERN_SUCCESS) {
        // 计算可用内存：空闲页 + 非活跃页
        uint64_t freePages = vmStats.free_count + vmStats.inactive_count;
        uint64_t availableBytes = freePages * pageSize;
        availableMemMB = (NSUInteger)(availableBytes / 1024 / 1024);
    } else {
        // 如果获取失败，使用物理内存的一半作为估计值
        availableMemMB = (NSUInteger)(processInfo.physicalMemory / 1024 / 1024 / 2);
    }
    
    NSDictionary *systemInfo = @{
        @"deviceModel": device.model ?: @"未知",
        @"deviceName": device.name ?: @"未知",
        @"systemName": device.systemName ?: @"未知",
        @"systemVersion": device.systemVersion ?: @"未知",
        @"processorCount": @(processInfo.processorCount),
        @"physicalMemoryMB": @((NSUInteger)(processInfo.physicalMemory / 1024 / 1024)),
        @"availableMemoryMB": @(availableMemMB),
        @"appVersion": [[NSBundle mainBundle] objectForInfoDictionaryKey:@"CFBundleShortVersionString"] ?: @"未知",
        @"appBuild": [[NSBundle mainBundle] objectForInfoDictionaryKey:@"CFBundleVersion"] ?: @"未知",
        @"launcherHome": [AIToolKit launcherRootDirectory] ?: @"未知",
        @"gameDirectory": [AIToolKit gameDirectory] ?: @"未知"
    };
    
    return [AIToolResult successWithData:systemInfo message:@"系统信息获取成功"];
}

@end

#pragma mark - AIToolSearchLog

@implementation AIToolSearchLog

+ (NSString *)toolName { return @"search_log"; }
+ (NSString *)toolDisplayName { return @"搜索日志"; }
+ (NSString *)toolDescription { return @"在崩溃日志中搜索关键词"; }
+ (BOOL)requiresUserConfirmation { return NO; }
+ (BOOL)isReadOnlyOperation { return YES; }

+ (AIToolResult *)executeWithParameters:(NSDictionary *)parameters {
    NSString *keyword = parameters[@"keyword"];
    
    if (!keyword || keyword.length == 0) {
        NSError *error = [NSError errorWithDomain:@"AIToolKitError" code:1 userInfo:@{NSLocalizedDescriptionKey: @"缺少 keyword 参数"}];
        return [AIToolResult failureWithError:error];
    }
    
    NSString *logPath = [NSString stringWithFormat:@"%s/latestlog.txt", getenv("POJAV_HOME")];
    NSString *logContent = [NSString stringWithContentsOfFile:logPath encoding:NSUTF8StringEncoding error:nil];
    
    if (!logContent) {
        NSError *error = [NSError errorWithDomain:@"AIToolKitError" code:2 userInfo:@{NSLocalizedDescriptionKey: @"无法读取日志文件"}];
        return [AIToolResult failureWithError:error];
    }
    
    NSMutableArray *matches = [NSMutableArray array];
    NSArray *lines = [logContent componentsSeparatedByCharactersInSet:[NSCharacterSet newlineCharacterSet]];
    
    for (NSInteger i = 0; i < (NSInteger)lines.count; i++) {
        NSString *line = lines[i];
        if ([line rangeOfString:keyword options:NSCaseInsensitiveSearch].location != NSNotFound) {
            [matches addObject:@{
                @"lineNumber": @(i + 1),
                @"content": line
            }];
        }
    }
    
    return [AIToolResult successWithData:@{
        @"keyword": keyword,
        @"matches": matches,
        @"totalMatches": @(matches.count)
    } message:[NSString stringWithFormat:@"找到 %lu 个匹配项", (unsigned long)matches.count]];
}

@end

#pragma mark - AIToolAnalyzeCrashReport

@implementation AIToolAnalyzeCrashReport

+ (NSString *)toolName { return @"analyze_crash_report"; }
+ (NSString *)toolDisplayName { return @"分析崩溃报告"; }
+ (NSString *)toolDescription { return @"分析崩溃报告并提取关键信息"; }
+ (BOOL)requiresUserConfirmation { return NO; }
+ (BOOL)isReadOnlyOperation { return YES; }

+ (AIToolResult *)executeWithParameters:(NSDictionary *)parameters {
    NSString *logPath = [NSString stringWithFormat:@"%s/latestlog.txt", getenv("POJAV_HOME")];
    NSString *logContent = [NSString stringWithContentsOfFile:logPath encoding:NSUTF8StringEncoding error:nil];
    
    if (!logContent) {
        NSError *error = [NSError errorWithDomain:@"AIToolKitError" code:1 userInfo:@{NSLocalizedDescriptionKey: @"无法读取日志文件"}];
        return [AIToolResult failureWithError:error];
    }
    
    NSMutableDictionary *analysis = [NSMutableDictionary dictionary];
    
    // 查找常见的错误模式
    NSArray *errorPatterns = @[
        @"Exception", @"Error", @"FATAL", @"crash", @"OutOfMemory", 
        @"NoSuchMethod", @"ClassNotFoundException", @"NullPointerException",
        @"StackOverflow", @"IllegalArgumentException", @"UnsupportedClassVersionError"
    ];
    
    NSMutableArray *foundErrors = [NSMutableArray array];
    NSArray *lines = [logContent componentsSeparatedByCharactersInSet:[NSCharacterSet newlineCharacterSet]];
    
    for (NSInteger i = 0; i < (NSInteger)lines.count; i++) {
        NSString *line = lines[i];
        for (NSString *pattern in errorPatterns) {
            if ([line rangeOfString:pattern options:NSCaseInsensitiveSearch].location != NSNotFound) {
                // 获取上下文（前后各3行）
                NSInteger startLine = MAX(0, i - 3);
                NSInteger endLine = MIN((NSInteger)lines.count - 1, i + 3);
                NSMutableString *context = [NSMutableString string];
                for (NSInteger j = startLine; j <= endLine; j++) {
                    [context appendFormat:@"%@\n", lines[j]];
                }
                
                [foundErrors addObject:@{
                    @"lineNumber": @(i + 1),
                    @"type": pattern,
                    @"content": line,
                    @"context": context
                }];
                break;
            }
        }
    }
    
    analysis[@"errors"] = foundErrors;
    analysis[@"errorCount"] = @(foundErrors.count);
    
    // 提取堆栈跟踪
    NSRegularExpression *stackTraceRegex = [NSRegularExpression regularExpressionWithPattern:@"at\\s+([\\w.$]+)\\(([\\w.]+):(\\d+)\\)" options:0 error:nil];
    NSArray *stackMatches = [stackTraceRegex matchesInString:logContent options:0 range:NSMakeRange(0, logContent.length)];
    
    NSMutableArray *stackTrace = [NSMutableArray array];
    for (NSTextCheckingResult *match in stackMatches) {
        NSString *method = [logContent substringWithRange:[match rangeAtIndex:1]];
        NSString *file = [logContent substringWithRange:[match rangeAtIndex:2]];
        NSString *lineNum = [logContent substringWithRange:[match rangeAtIndex:3]];
        [stackTrace addObject:@{@"method": method, @"file": file, @"line": lineNum}];
    }
    
    analysis[@"stackTrace"] = stackTrace;
    
    // 提取 Java 版本信息
    NSRegularExpression *javaVersionRegex = [NSRegularExpression regularExpressionWithPattern:@"java\\.version=([\\d._]+)" options:0 error:nil];
    NSTextCheckingResult *javaMatch = [javaVersionRegex firstMatchInString:logContent options:0 range:NSMakeRange(0, logContent.length)];
    if (javaMatch) {
        analysis[@"javaVersion"] = [logContent substringWithRange:[javaMatch rangeAtIndex:1]];
    }
    
    // 提取 Minecraft 版本
    NSRegularExpression *mcVersionRegex = [NSRegularExpression regularExpressionWithPattern:@"Minecraft\\s+(\\d+\\.\\d+(?:\\.\\d+)?)" options:0 error:nil];
    NSTextCheckingResult *mcMatch = [mcVersionRegex firstMatchInString:logContent options:0 range:NSMakeRange(0, logContent.length)];
    if (mcMatch) {
        analysis[@"minecraftVersion"] = [logContent substringWithRange:[mcMatch rangeAtIndex:1]];
    }
    
    return [AIToolResult successWithData:analysis message:@"崩溃报告分析完成"];
}

@end

#pragma mark - AIToolGetFileInfo

@implementation AIToolGetFileInfo

+ (NSString *)toolName { return @"get_file_info"; }
+ (NSString *)toolDisplayName { return @"获取文件信息"; }
+ (NSString *)toolDescription { return @"获取文件的详细信息（大小、修改时间等）"; }
+ (BOOL)requiresUserConfirmation { return NO; }
+ (BOOL)isReadOnlyOperation { return YES; }

+ (AIToolResult *)executeWithParameters:(NSDictionary *)parameters {
    NSString *path = parameters[@"path"];
    
    if (!path) {
        NSError *error = [NSError errorWithDomain:@"AIToolKitError" code:1 userInfo:@{NSLocalizedDescriptionKey: @"缺少 path 参数"}];
        return [AIToolResult failureWithError:error];
    }
    
    NSFileManager *fm = [NSFileManager defaultManager];
    NSDictionary *attributes = [fm attributesOfItemAtPath:path error:nil];
    
    if (!attributes) {
        NSError *error = [NSError errorWithDomain:@"AIToolKitError" code:2 userInfo:@{NSLocalizedDescriptionKey: [NSString stringWithFormat:@"无法获取文件信息: %@", path]}];
        return [AIToolResult failureWithError:error];
    }
    
    BOOL isDirectory = [attributes[NSFileType] isEqualToString:NSFileTypeDirectory];

    // 将 NSDate 转换为字符串以便 JSON 序列化
    NSDateFormatter *formatter = [[NSDateFormatter alloc] init];
    formatter.dateFormat = @"yyyy-MM-dd HH:mm:ss";

    NSDate *creationDate = attributes[NSFileCreationDate];
    NSDate *modDate = attributes[NSFileModificationDate];
    NSString *creationDateString = creationDate ? [formatter stringFromDate:creationDate] : @"未知";
    NSString *modDateString = modDate ? [formatter stringFromDate:modDate] : @"未知";

    NSDictionary *info = @{
        @"path": path,
        @"name": [path lastPathComponent],
        @"isDirectory": @(isDirectory),
        @"size": attributes[NSFileSize] ?: @0,
        @"creationDate": creationDateString,
        @"modificationDate": modDateString,
        @"extension": [path pathExtension] ?: @"",
        @"permissions": attributes[NSFilePosixPermissions] ?: @0
    };
    
    return [AIToolResult successWithData:info message:@"文件信息获取成功"];
}

@end

#pragma mark - AIToolCopyFile

@implementation AIToolCopyFile

+ (NSString *)toolName { return @"copy_file"; }
+ (NSString *)toolDisplayName { return @"复制文件"; }
+ (NSString *)toolDescription { return @"复制文件到指定位置"; }
+ (BOOL)requiresUserConfirmation { return YES; }
+ (BOOL)isReadOnlyOperation { return NO; }

+ (AIToolResult *)executeWithParameters:(NSDictionary *)parameters {
    NSString *sourcePath = parameters[@"source_path"];
    NSString *destinationPath = parameters[@"destination_path"];
    
    if (!sourcePath || !destinationPath) {
        NSError *error = [NSError errorWithDomain:@"AIToolKitError" code:1 userInfo:@{NSLocalizedDescriptionKey: @"缺少 source_path 或 destination_path 参数"}];
        return [AIToolResult failureWithError:error];
    }
    
    NSFileManager *fm = [NSFileManager defaultManager];
    
    if (![fm fileExistsAtPath:sourcePath]) {
        NSError *error = [NSError errorWithDomain:@"AIToolKitError" code:2 userInfo:@{NSLocalizedDescriptionKey: [NSString stringWithFormat:@"源文件不存在: %@", sourcePath]}];
        return [AIToolResult failureWithError:error];
    }
    
    // 确保目标目录存在
    NSString *destDir = [destinationPath stringByDeletingLastPathComponent];
    if (![fm fileExistsAtPath:destDir]) {
        [fm createDirectoryAtPath:destDir withIntermediateDirectories:YES attributes:nil error:nil];
    }
    
    NSError *copyError;
    BOOL success = [fm copyItemAtPath:sourcePath toPath:destinationPath error:&copyError];
    
    if (!success) {
        return [AIToolResult failureWithError:copyError];
    }
    
    return [AIToolResult successWithData:@{
        @"sourcePath": sourcePath,
        @"destinationPath": destinationPath
    } message:@"文件复制成功"];
}

@end

