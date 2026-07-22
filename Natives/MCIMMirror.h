#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// 模组镜像源类型
/// - MCIMMirrorSourceOfficial: 官方源（直连 api.modrinth.com / api.curseforge.com）
/// - MCIMMirrorSourceMCIM: MCIM 镜像源（mod.mcimirror.top，国内加速）
typedef NS_ENUM(NSInteger, MCIMMirrorSource) {
    MCIMMirrorSourceOfficial = 0,
    MCIMMirrorSourceMCIM = 1,
};

/// MCIM 模组镜像源工具类
///
/// 参考 ZalithLauncher 2 的 MCIMMirror.kt 实现，提供 Modrinth / CurseForge 的
/// API 与 CDN URL 到 MCIM 镜像（mod.mcimirror.top）的替换。
///
/// MCIM 镜像 URL 规则（与官方接口完全兼容，仅替换主机前缀）：
///   - api.modrinth.com      → mod.mcimirror.top/modrinth
///   - api.curseforge.com    → mod.mcimirror.top/curseforge
///   - cdn.modrinth.com      → mod.mcimirror.top/modrinth/deliver
///   - edge.forgecdn.net     → mod.mcimirror.top/curseforge/deliver
///   - media.forgecdn.net    → mod.mcimirror.top/curseforge/medias
///
/// 使用方式：
///   NSString *url = [MCIMMirror rewriteURL:originalURL];
///   if (url) { /* 镜像已启用且 URL 被替换 */ } else { /* 用原始 URL */ }
@interface MCIMMirror : NSObject

/// MCIM 镜像根地址
@property (class, readonly, copy) NSString *rootURL;

/// 当前启用的镜像源（实时读取偏好 general.mod_mirror）
+ (MCIMMirrorSource)currentSource;

/// 是否启用 MCIM 镜像（currentSource == MCIMMirrorSourceMCIM）
+ (BOOL)isMirrorEnabled;

/// 设置镜像源（持久化到偏好 general.mod_mirror）
+ (void)setSource:(MCIMMirrorSource)source;

/// 把官方 URL 重写为镜像 URL
/// 如果镜像未启用，或 URL 不属于 Modrinth/CurseForge，返回 nil（调用方应使用原始 URL）
/// @param originalURL 原始 URL（api.modrinth.com / api.curseforge.com / cdn.modrinth.com / edge.forgecdn.net / media.forgecdn.net）
/// @return 重写后的镜像 URL，或 nil（不适用）
+ (nullable NSString *)rewriteURL:(NSString *)originalURL;

/// 把官方 URL 重写为镜像 URL（如果镜像启用且适用），否则返回原始 URL
+ (NSString *)applyToURL:(NSString *)originalURL;

/// Modrinth API base URL（根据当前镜像源返回官方或镜像）
+ (NSString *)modrinthAPIBaseURL;

/// CurseForge API base URL（根据当前镜像源返回官方或镜像）
+ (NSString *)curseForgeAPIBaseURL;

@end

NS_ASSUME_NONNULL_END
