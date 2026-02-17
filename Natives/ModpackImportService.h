//
//  ModpackImportService.h
//  Amethyst
//
//  整合包导入服务 - 支持 .zip 和 .mrpack 格式
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface ModpackImportService : NSObject

// 解析整合包文件并返回信息字典
- (nullable NSDictionary *)parseModpackAtURL:(NSURL *)fileURL error:(NSError **)error;

// 导入整合包到游戏目录
- (BOOL)importModpack:(NSDictionary *)modpackInfo error:(NSError **)error;

// 获取已导入的整合包列表
- (NSArray<NSDictionary *> *)getImportedModpacks;

// 删除已导入的整合包
- (BOOL)deleteModpack:(NSDictionary *)modpackInfo error:(NSError **)error;

@end

NS_ASSUME_NONNULL_END
LL_END
