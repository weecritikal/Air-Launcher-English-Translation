//
//  DataPackService.h
//  Amethyst
//
//  Service for managing data packs (local and online)
//  数据包本地管理与下载服务，结构参照 ShaderService，复用 ShaderItem 作为数据模型
//

#import <Foundation/Foundation.h>
#import "ShaderItem.h"

NS_ASSUME_NONNULL_BEGIN

// 数据包列表回调
typedef void(^DataPackListHandler)(NSArray<ShaderItem *> *items);
// 数据包元数据回调（数据包无嵌入元数据，目前为空实现）
typedef void(^DataPackMetadataHandler)(ShaderItem *item, NSError * _Nullable error);
// 下载完成回调（success 表示是否成功）
typedef void(^DataPackDownloadCompletionHandler)(BOOL success, NSError * _Nullable error);
// 下载进度回调（在主线程执行，UI 更新安全）
typedef void(^DataPackDownloadProgressHandler)(NSProgress * _Nullable downloadProgress);

@class PLProfiles;

@interface DataPackService : NSObject

@property (nonatomic, assign) BOOL onlineSearchEnabled;

+ (instancetype)sharedService;

// --- 本地数据包管理 ---
// 扫描指定 profile 的 datapacks 目录，返回 .zip 和 .zip.disabled 文件列表
- (void)scanDataPacksForProfile:(PLProfiles *)profile completion:(DataPackListHandler)completion;
// 获取数据包元数据（数据包无嵌入元数据，直接返回原对象）
- (void)fetchMetadataForDataPack:(ShaderItem *)item completion:(DataPackMetadataHandler)completion;
// 启用/禁用数据包（加/去 .disabled 后缀）
- (BOOL)toggleEnableForDataPack:(ShaderItem *)item error:(NSError **)error;
// 删除数据包文件
- (BOOL)deleteDataPack:(ShaderItem *)item error:(NSError **)error;

// --- 在线数据包下载 ---
// 下载数据包到指定 profile 的 datapacks 目录，支持实时进度回调
- (void)downloadDataPack:(ShaderItem *)item
               toProfile:(PLProfiles *)profile
                progress:(DataPackDownloadProgressHandler _Nullable)progress
              completion:(DataPackDownloadCompletionHandler _Nullable)completion;

@end

NS_ASSUME_NONNULL_END
