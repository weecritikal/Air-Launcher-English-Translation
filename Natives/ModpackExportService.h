#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// 整合包导出格式（参照 FCL/HMCL）
typedef NS_ENUM(NSInteger, ModpackExportFormat) {
    ModpackExportFormatModrinth = 0,   // Modrinth .mrpack 格式
    ModpackExportFormatCurseForge = 1, // CurseForge .zip 格式（manifest.json）
    ModpackExportFormatLinkList = 2,   // 链接列表 .txt 格式（FCL 支持的简单格式）
};

/// 整合包导出服务（参照 FCL ExportModpackViewModel.kt / HMCL ModpackHelper）
@interface ModpackExportService : NSObject

+ (instancetype)sharedService;

/// 导出整合包
/// @param profileName profile 名称（从 PLProfiles.current.profiles 获取 gameDir/lastVersionId）
/// @param destPath 目标文件路径（.mrpack / .zip / .txt）
/// @param name 整合包名称
/// @param version 整合包版本
/// @param author 作者
/// @param format 导出格式
/// @param includeOverrides 是否包含 overrides（config/options.txt 等）
/// @param progress 进度回调（0.0-1.0）
/// @param error 错误信息
/// @return 是否成功
- (BOOL)exportModpackForProfile:(NSString *)profileName
                         toPath:(NSString *)destPath
                            name:(NSString *)name
                         version:(NSString *)version
                          author:(NSString *)author
                         format:(ModpackExportFormat)format
                includeOverrides:(BOOL)includeOverrides
                       progress:(void (^_Nullable)(double progress, NSString *stageMessage))progress
                          error:(NSError **)error;

/// 从 lastVersionId 反解 loader 和 minecraft 版本
/// 例如 "fabric-loader-0.15.7-1.20.1" → loader="fabric", loaderVersion="0.15.7", mcVersion="1.20.1"
/// "1.20.1-forge-47.3.0" → loader="forge", loaderVersion="47.3.0", mcVersion="1.20.1"
/// "1.20.1-neoforge-47.1.0" → loader="neoforge", loaderVersion="47.1.0", mcVersion="1.20.1"
+ (NSDictionary *)parseVersionId:(NSString *)versionId;

@end

NS_ASSUME_NONNULL_END
