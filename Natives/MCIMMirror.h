#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Mod mirror source type
/// - MCIMMirrorSourceOfficial: the official source (connecting directly to api.modrinth.com / api.curseforge.com)
/// - MCIMMirrorSourceMCIM: the MCIM mirror (mod.mcimirror.top, faster from mainland China)
typedef NS_ENUM(NSInteger, MCIMMirrorSource) {
    MCIMMirrorSourceOfficial = 0,
    MCIMMirrorSourceMCIM = 1,
};

/// MCIM mod mirror helper class
///
/// Modelled on MCIMMirror.kt from ZalithLauncher 2, rewriting the Modrinth / CurseForge
/// API and CDN URLs to the MCIM mirror (mod.mcimirror.top).
///
/// MCIM mirror URL rules (fully compatible with the official API; only the host prefix is replaced):
///   - api.modrinth.com      → mod.mcimirror.top/modrinth
///   - api.curseforge.com    → mod.mcimirror.top/curseforge
///   - cdn.modrinth.com      → mod.mcimirror.top/modrinth/deliver
///   - edge.forgecdn.net     → mod.mcimirror.top/curseforge/deliver
///   - media.forgecdn.net    → mod.mcimirror.top/curseforge/medias
///
/// How to use:
///   NSString *url = [MCIMMirror rewriteURL:originalURL];
///   if (url) { /* the mirror is on and the URL was rewritten */ } else { /* use the original URL */ }
@interface MCIMMirror : NSObject

/// MCIM mirror root address
@property (class, readonly, copy) NSString *rootURL;

/// The mirror source currently enabled (read live from the general.mod_mirror preference)
+ (MCIMMirrorSource)currentSource;

/// Whether the MCIM mirror is enabled (currentSource == MCIMMirrorSourceMCIM)
+ (BOOL)isMirrorEnabled;

/// Set the mirror source (persisted to the general.mod_mirror preference)
+ (void)setSource:(MCIMMirrorSource)source;

/// Rewrite an official URL to its mirror URL
/// Returns nil when the mirror is off, or when the URL is not a Modrinth/CurseForge one (the caller should then use the original URL)
/// @param originalURL The original URL (api.modrinth.com / api.curseforge.com / cdn.modrinth.com / edge.forgecdn.net / media.forgecdn.net)
/// @return The rewritten mirror URL, or nil when it does not apply
+ (nullable NSString *)rewriteURL:(NSString *)originalURL;

/// Rewrite an official URL to its mirror URL (when the mirror is on and applicable), otherwise return the original URL
+ (NSString *)applyToURL:(NSString *)originalURL;

/// Modrinth API base URL (the official or the mirror, depending on the current source)
+ (NSString *)modrinthAPIBaseURL;

/// CurseForge API base URL (the official or the mirror, depending on the current source)
+ (NSString *)curseForgeAPIBaseURL;

@end

NS_ASSUME_NONNULL_END
