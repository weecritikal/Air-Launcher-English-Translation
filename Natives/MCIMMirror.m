#import "MCIMMirror.h"
#import "LauncherPreferences.h"
#import "utils.h"

/// MCIM 镜像根地址（参考 ZalithLauncher 2 MCIMMirror.kt）
static NSString *const kMCIMRootURL = @"https://mod.mcimirror.top";

/// 偏好键
static NSString *const kPrefModMirror = @"general.mod_mirror";

@implementation MCIMMirror

+ (NSString *)rootURL {
    return kMCIMRootURL;
}

+ (MCIMMirrorSource)currentSource {
    NSString *value = getPrefObject(kPrefModMirror);
    if ([value isKindOfClass:[NSString class]] && [value isEqualToString:@"mcim"]) {
        return MCIMMirrorSourceMCIM;
    }
    return MCIMMirrorSourceOfficial;
}

+ (BOOL)isMirrorEnabled {
    return [self currentSource] == MCIMMirrorSourceMCIM;
}

+ (void)setSource:(MCIMMirrorSource)source {
    NSString *value = (source == MCIMMirrorSourceMCIM) ? @"mcim" : @"official";
    setPrefObject(kPrefModMirror, value);
}

+ (nullable NSString *)rewriteURL:(NSString *)originalURL {
    if (!originalURL || originalURL.length == 0) return nil;
    if (![self isMirrorEnabled]) return nil;

    // Modrinth API: https://api.modrinth.com/v2/... → https://mod.mcimirror.top/modrinth/v2/...
    if ([originalURL hasPrefix:@"https://api.modrinth.com/"]) {
        NSString *path = [originalURL substringFromIndex:@"https://api.modrinth.com".length];
        return [NSString stringWithFormat:@"%@/modrinth%@", kMCIMRootURL, path];
    }
    // CurseForge API: https://api.curseforge.com/v1/... → https://mod.mcimirror.top/curseforge/v1/...
    if ([originalURL hasPrefix:@"https://api.curseforge.com/"]) {
        NSString *path = [originalURL substringFromIndex:@"https://api.curseforge.com".length];
        return [NSString stringWithFormat:@"%@/curseforge%@", kMCIMRootURL, path];
    }
    // Modrinth CDN: https://cdn.modrinth.com/... → https://mod.mcimirror.top/...
    // （参考 ZalithLauncher 2 MCIMMirror.kt：CDN 链接做简单主机替换，不加平台前缀）
    if ([originalURL hasPrefix:@"https://cdn.modrinth.com/"]) {
        NSString *path = [originalURL substringFromIndex:@"https://cdn.modrinth.com".length];
        return [NSString stringWithFormat:@"%@%@", kMCIMRootURL, path];
    }
    // CurseForge Edge CDN: https://edge.forgecdn.net/... → https://mod.mcimirror.top/...
    if ([originalURL hasPrefix:@"https://edge.forgecdn.net/"]) {
        NSString *path = [originalURL substringFromIndex:@"https://edge.forgecdn.net".length];
        return [NSString stringWithFormat:@"%@%@", kMCIMRootURL, path];
    }
    // CurseForge Media CDN: https://media.forgecdn.net/... → https://mod.mcimirror.top/...
    if ([originalURL hasPrefix:@"https://media.forgecdn.net/"]) {
        NSString *path = [originalURL substringFromIndex:@"https://media.forgecdn.net".length];
        return [NSString stringWithFormat:@"%@%@", kMCIMRootURL, path];
    }

    return nil;
}

+ (NSString *)applyToURL:(NSString *)originalURL {
    NSString *rewritten = [self rewriteURL:originalURL];
    return rewritten ?: originalURL;
}

+ (NSString *)modrinthAPIBaseURL {
    if ([self isMirrorEnabled]) {
        return [NSString stringWithFormat:@"%@/modrinth/v2", kMCIMRootURL];
    }
    return @"https://api.modrinth.com/v2";
}

+ (NSString *)curseForgeAPIBaseURL {
    if ([self isMirrorEnabled]) {
        return [NSString stringWithFormat:@"%@/curseforge/v1", kMCIMRootURL];
    }
    return @"https://api.curseforge.com/v1";
}

@end
