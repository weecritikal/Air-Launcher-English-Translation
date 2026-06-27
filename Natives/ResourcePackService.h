//
//  ResourcePackService.h
//  Amethyst
//
//  Service for managing resource packs (local and online)
//  资源包本地管理与下载服务，结构参照 ShaderService，复用 ShaderItem 作为数据模型
//

#import <Foundation/Foundation.h>
#import "ShaderItem.h"

NS_ASSUME_NONNULL_BEGIN

// 资源包列表回调
typedef void(^ResourcePackListHandler)(NSArray<ShaderItem *> *items);
// 资源包元数据回调（资源包无嵌入元数据，目前为空实现）
typedef void(^ResourcePackMetadataHandler)(ShaderItem *item, NSError * _Nullable error);
// 下载完成回调（success 表示是否成功）
typedef void(^ResourcePackDownloadCompletionHandler)(BOOL success, NSError * _Nullable error);
// 下载进度回调（在主线程执行，UI 更新安全）
typedef void(^ResourcePackDownloadProgressHandler)(NSProgress * _Nullable downloadProgress);

@class PLProfiles;

@interface ResourcePackService : NSObject

@property (nonatomic, assign) BOOL onlineSearchEnabled;

+ (instancetype)sharedService;

// --- 本地资源包管理 ---
// 扫描指定 profile 的 resourcepacks 目录，返回 .zip 和 .zip.disabled 文件列表
- (void)scanResourcePacksForProfile:(PLProfiles *)profile completion:(ResourcePackListHandler)completion;
// 获取资源包元数据（资源包无嵌入元数据，直接返回原对象）
- (void)fetchMetadataForResourcePack:(ShaderItem *)item completion:(ResourcePackMetadataHandler)completion;
// 启用/禁用资源包（加/去 .disabled 后缀）
- (BOOL)toggleEnableForResourcePack:(ShaderItem *)item error:(NSError **)error;
// 删除资源包文件
- (BOOL)deleteResourcePack:(ShaderItem *)item error:(NSError **)error;

// --- 在线资源包下载 ---
// 下载资源包到指定 profile 的 resourcepacks 目录，支持实时进度回调
- (void)downloadResourcePack:(ShaderItem *)item
                   toProfile:(PLProfiles *)profile
                    progress:(ResourcePackDownloadProgressHandler _Nullable)progress
                  completion:(ResourcePackDownloadCompletionHandler _Nullable)completion;

@end

NS_ASSUME_NONNULL_END
