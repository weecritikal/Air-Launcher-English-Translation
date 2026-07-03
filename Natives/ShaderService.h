//
//  ShaderService.h
//  Amethyst
//
//  Service for managing shader packs (local and online)
//

#import <Foundation/Foundation.h>
#import "ShaderItem.h"

NS_ASSUME_NONNULL_BEGIN

typedef void(^ShaderListHandler)(NSArray<ShaderItem *> *shaders);
typedef void(^ShaderMetadataHandler)(ShaderItem *item, NSError * _Nullable error);
typedef void(^ShaderDownloadHandler)(NSError * _Nullable error);

@interface ShaderService : NSObject

@property (nonatomic, assign) BOOL onlineSearchEnabled;

+ (instancetype)sharedService;

// --- Local Shader Management ---
- (void)scanShadersForProfile:(NSString *)profileName completion:(ShaderListHandler)completion;
- (void)fetchMetadataForShader:(ShaderItem *)shader completion:(ShaderMetadataHandler)completion;
- (BOOL)toggleEnableForShader:(ShaderItem *)shader error:(NSError **)error;
- (BOOL)deleteShader:(ShaderItem *)shader error:(NSError **)error;

// --- Online Shader Downloading ---
- (void)downloadShader:(ShaderItem *)shader toProfile:(NSString *)profileName completion:(ShaderDownloadHandler)completion;

/// 下载光影包并上报进度
- (void)downloadShader:(ShaderItem *)shader
             toProfile:(NSString *)profileName
              progress:(void (^)(NSProgress *downloadProgress))progress
            completion:(ShaderDownloadHandler)completion;

// --- Utility ---
- (NSString *)iconCachePathForURL:(NSString *)urlString;

/// 获取当前 profile 的 shaderpacks 目录，不存在时自动创建
- (nullable NSString *)ensureShadersFolderForProfile:(NSString *)profileName error:(NSError **)error;

@end

NS_ASSUME_NONNULL_END
