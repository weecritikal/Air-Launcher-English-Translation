//
//  ModService.m
//  AmethystMods
//
//  Created by Copilot on 2025-08-22.
//  Revised: detect multiple loaders, choose metadata by priority (Fabric > Forge > NeoForge),
//  add defensive parsing for neoforge & toml, avoid crashes.
//

#import "ModService.h"
#import <CommonCrypto/CommonCrypto.h>
#import <UIKit/UIKit.h>
#import "PLProfiles.h"
#import "ModItem.h"
#import "UnzipKit.h"

@interface ModService ()
- (NSDictionary<NSString *, NSString *> *)parseFirstModsTableFromTomlString:(NSString *)s;
@end

@implementation ModService

+ (instancetype)sharedService {
    static ModService *s;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        s = [ModService new];
        s.onlineSearchEnabled = NO;
    });
    return s;
}

#pragma mark - Helpers (sha1/icon cache/readdata etc.) unchanged (omitted here for brevity)
// ... re-use earlier implementations of sha1ForFileAtPath:, iconCachePathForURL:, readFileFromJar:, extractFirstMatchingImageFromJar:, parseFirstModsTableFromTomlString: ...
// For brevity in this message I include full implementations below so you can paste/replace the file directly.

- (nullable NSString *)sha1ForFileAtPath:(NSString *)path {
    NSData *d = [NSData dataWithContentsOfFile:path];
    if (!d) return nil;
    unsigned char digest[CC_SHA1_DIGEST_LENGTH];
    CC_SHA1(d.bytes, (CC_LONG)d.length, digest);
    NSMutableString *hex = [NSMutableString stringWithCapacity:CC_SHA1_DIGEST_LENGTH * 2];
    for (int i = 0; i < CC_SHA1_DIGEST_LENGTH; i++) {
        [hex appendFormat:@"%02x", digest[i]];
    }
    return [hex copy];
}

- (NSString *)iconCachePathForURL:(NSString *)urlString {
    if (!urlString) return nil;
    NSString *cacheDir = [NSSearchPathForDirectoriesInDomains(NSCachesDirectory, NSUserDomainMask, YES) firstObject];
    NSString *folder = [cacheDir stringByAppendingPathComponent:@"mod_icons"];
    if (![[NSFileManager defaultManager] fileExistsAtPath:folder]) {
        [[NSFileManager defaultManager] createDirectoryAtPath:folder withIntermediateDirectories:YES attributes:nil error:nil];
    }
    const char *cstr = [urlString UTF8String];
    unsigned char digest[CC_SHA1_DIGEST_LENGTH];
    CC_SHA1(cstr, (CC_LONG)strlen(cstr), digest);
    NSMutableString *hex = [NSMutableString stringWithCapacity:CC_SHA1_DIGEST_LENGTH * 2];
    for (int i = 0; i < CC_SHA1_DIGEST_LENGTH; i++) {
        [hex appendFormat:@"%02x", digest[i]];
    }
    return [folder stringByAppendingPathComponent:hex];
}

- (nullable NSData *)readFileFromJar:(NSString *)jarPath entryName:(NSString *)entryName {
    if (!jarPath || !entryName) return nil;
    NSError *err = nil;
    UZKArchive *archive = [[UZKArchive alloc] initWithPath:jarPath error:&err];
    if (!archive || err) return nil;

    NSArray<NSString *> *tryList = @[
        entryName,
        [entryName stringByReplacingOccurrencesOfString:@"\\" withString:@"/"],
        [entryName stringByReplacingOccurrencesOfString:@"./" withString:@""],
        [NSString stringWithFormat:@"/%@", entryName],
        [entryName lastPathComponent]
    ];

    for (NSString *tryEntry in tryList) {
        if (!tryEntry || tryEntry.length == 0) continue;
        NSError *e = nil;
        NSData *data = [archive extractDataFromFile:tryEntry error:&e];
        if (data && data.length > 0) return data;
    }

    NSError *enumErr = nil;
    NSArray<UZKFileInfo *> *infos = [archive listFileInfo:&enumErr];
    if (!infos) return nil;

    for (UZKFileInfo *info in infos) {
        NSString *entryPath = info.filename ?: @"";
        NSString *normalized = [entryPath stringByReplacingOccurrencesOfString:@"\\" withString:@"/"];
        if ([normalized caseInsensitiveCompare:entryName] == NSOrderedSame ||
            [[normalized lastPathComponent] caseInsensitiveCompare:entryName] == NSOrderedSame ||
            [[normalized lastPathComponent] isEqualToString:entryName]) {
            NSError *e = nil;
            NSData *data = [archive extractDataFromFile:entryPath error:&e];
            if (data && data.length > 0) return data;
        }
    }
    return nil;
}

- (nullable NSString *)extractFirstMatchingImageFromJar:(NSString *)jarPath candidates:(NSArray<NSString *> *)candidates baseName:(NSString *)baseName {
    if (!jarPath) return nil;
    for (NSString *cand in candidates) {
        if (!cand || cand.length == 0) continue;
        NSData *d = [self readFileFromJar:jarPath entryName:cand];
        if (d && d.length > 8) {
            const unsigned char *bytes = d.bytes;
            BOOL isPNG = (d.length >= 8 && bytes[0] == 0x89 && bytes[1] == 0x50 && bytes[2] == 0x4E && bytes[3] == 0x47);
            NSString *cacheDir = [NSSearchPathForDirectoriesInDomains(NSCachesDirectory, NSUserDomainMask, YES) firstObject];
            NSString *iconsDir = [cacheDir stringByAppendingPathComponent:@"mod_icons"];
            if (![[NSFileManager defaultManager] fileExistsAtPath:iconsDir]) {
                [[NSFileManager defaultManager] createDirectoryAtPath:iconsDir withIntermediateDirectories:YES attributes:nil error:nil];
            }
            NSString *safeBase = [[baseName stringByReplacingOccurrencesOfString:@" " withString:@"_"] stringByReplacingOccurrencesOfString:@"/" withString:@"_"];
            NSString *fname = [NSString stringWithFormat:@"%@_%@", safeBase, [cand lastPathComponent]];
            if (![fname.pathExtension length]) {
                fname = [fname stringByAppendingPathExtension:(isPNG ? @"png":@"dat")];
            }
            NSString *dest = [iconsDir stringByAppendingPathComponent:fname];
            NSError *err = nil;
            if ([d writeToFile:dest options:NSDataWritingAtomic error:&err]) {
                return [NSURL fileURLWithPath:dest].absoluteString;
            }
        }
    }
    return nil;
}

- (NSDictionary<NSString *, NSString *> *)parseFirstModsTableFromTomlString:(NSString *)s {
    if (!s) return @{};
    NSRange modsRange = [s rangeOfString:@"[[mods]]"];
    if (modsRange.location == NSNotFound) {
        modsRange = [s rangeOfString:@"[mods]"];
        if (modsRange.location == NSNotFound) return @{};
    }
    NSUInteger start = modsRange.location;
    NSUInteger end = s.length;
    NSRange nextSection = [s rangeOfString:@"[[" options:0 range:NSMakeRange(start+1, s.length - (start+1))];
    if (nextSection.location != NSNotFound) end = nextSection.location;
    NSString *block = [s substringWithRange:NSMakeRange(start, end - start)];
    NSMutableDictionary *out = [NSMutableDictionary dictionary];

    NSArray<NSString *> *keys = @[@"displayName", @"version", @"description", @"logoFile", @"displayURL", @"authors", @"homepage", @"url"];
    for (NSString *key in keys) {
        NSString *patternTriple = [NSString stringWithFormat:@"%@\\s*=\\s*([\"']{3})([\\s\\S]*?)\\1", key];
        NSRegularExpression *reTriple = [NSRegularExpression regularExpressionWithPattern:patternTriple options:NSRegularExpressionCaseInsensitive error:nil];
        NSTextCheckingResult *rTriple = [reTriple firstMatchInString:block options:0 range:NSMakeRange(0, block.length)];
        if (rTriple) {
            NSRange valRange = [rTriple rangeAtIndex:2];
            if (valRange.location != NSNotFound) {
                NSString *val = [block substringWithRange:valRange];
                if (val.length) out[key] = [val stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
                continue;
            }
        }
        NSString *pattern = [NSString stringWithFormat:@"%@\\s*=\\s*([\"'])(.*?)\\1", key];
        NSRegularExpression *re = [NSRegularExpression regularExpressionWithPattern:pattern options:NSRegularExpressionCaseInsensitive error:nil];
        NSTextCheckingResult *r = [re firstMatchInString:block options:0 range:NSMakeRange(0, block.length)];
        if (r) {
            NSRange valRange = [r rangeAtIndex:2];
            if (valRange.location != NSNotFound) {
                NSString *val = [block substringWithRange:valRange];
                if (val.length) out[key] = [val stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
                continue;
            }
        }
        if ([key isEqualToString:@"authors"]) {
            NSString *patternArr = @"authors\\s*=\\s*\\[([^\\]]+)\\]";
            NSRegularExpression *reArr = [NSRegularExpression regularExpressionWithPattern:patternArr options:NSRegularExpressionCaseInsensitive error:nil];
            NSTextCheckingResult *ra = [reArr firstMatchInString:block options:0 range:NSMakeRange(0, block.length)];
            if (ra) {
                NSRange inner = [ra rangeAtIndex:1];
                if (inner.location != NSNotFound) {
                    NSString *arr = [block substringWithRange:inner];
                    NSRegularExpression *reQ = [NSRegularExpression regularExpressionWithPattern:@"[\"'](.*?)[\"']" options:0 error:nil];
                    NSTextCheckingResult *rq = [reQ firstMatchInString:arr options:0 range:NSMakeRange(0, arr.length)];
                    if (rq) {
                        NSString *val = [arr substringWithRange:[rq rangeAtIndex:1]];
                        if (val.length) out[key] = val;
                    }
                }
            }
        }
    }
    return out;
}

#pragma mark - Mods folder detection & scan (conservative)
- (nullable NSString *)existingModsFolderForProfile:(NSString *)profileName {
    NSString *profile = profileName.length ? profileName : @"default";
    NSFileManager *fm = NSFileManager.defaultManager;

    @try {
        NSDictionary *profiles = PLProfiles.current.profiles;
        NSDictionary *prof = profiles[profile];
        if ([prof isKindOfClass:[NSDictionary class]]) {
            NSString *gameDir = prof[@"gameDir"];
            if ([gameDir isKindOfClass:[NSString class]] && gameDir.length > 0) {
                if ([gameDir hasPrefix:@"./"]) {
                    const char *gameDirC = getenv("POJAV_GAME_DIR");
                    if (gameDirC) {
                        NSString *pojGameDir = [NSString stringWithUTF8String:gameDirC];
                        NSString *rel = [gameDir substringFromIndex:2];
                        NSString *cand = [pojGameDir stringByAppendingPathComponent:rel];
                        NSString *candMods = [cand stringByAppendingPathComponent:@"mods"];
                        BOOL isDir = NO;
                        if ([fm fileExistsAtPath:candMods isDirectory:&isDir] && isDir) return candMods;
                        if ([fm fileExistsAtPath:cand isDirectory:&isDir] && isDir) {
                            NSString *cand2 = [cand stringByAppendingPathComponent:@"mods"];
                            if ([fm fileExistsAtPath:cand2 isDirectory:&isDir] && isDir) return cand2;
                        }
                    }
                } else if ([gameDir hasPrefix:@"/"]) {
                    NSString *candMods = [gameDir stringByAppendingPathComponent:@"mods"];
                    BOOL isDir = NO;
                    if ([fm fileExistsAtPath:candMods isDirectory:&isDir] && isDir) return candMods;
                    if ([fm fileExistsAtPath:gameDir isDirectory:&isDir] && isDir) {
                        NSString *cand2 = [gameDir stringByAppendingPathComponent:@"mods"];
                        if ([fm fileExistsAtPath:cand2 isDirectory:&isDir] && isDir) return cand2;
                    }
                } else {
                    const char *pojHomeC = getenv("POJAV_HOME");
                    if (pojHomeC) {
                        NSString *pojHome = [NSString stringWithUTF8String:pojHomeC];
                        NSString *cand1 = [pojHome stringByAppendingPathComponent:[NSString stringWithFormat:@"instances/%@/mods", gameDir]];
                        BOOL isDir = NO;
                        if ([fm fileExistsAtPath:cand1 isDirectory:&isDir] && isDir) return cand1;
                    }
                    NSArray *paths = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES);
                    NSString *documents = paths.firstObject;
                    NSString *cand2 = [documents stringByAppendingPathComponent:[NSString stringWithFormat:@"instances/%@/mods", gameDir]];
                    BOOL isDir2 = NO;
                    if ([fm fileExistsAtPath:cand2 isDirectory:&isDir2] && isDir2) return cand2;
                }
            }
        }
    } @catch (NSException *ex) { }

    // Standard environment locations
    const char *pojHomeC = getenv("POJAV_HOME");
    if (pojHomeC) {
        NSString *pojHome = [NSString stringWithUTF8String:pojHomeC];
        NSString *cand1 = [pojHome stringByAppendingPathComponent:[NSString stringWithFormat:@"instances/%@/mods", profile]];
        BOOL isDir = NO;
        if ([fm fileExistsAtPath:cand1 isDirectory:&isDir] && isDir) return cand1;
    }
    NSArray *paths = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES);
    NSString *documents = paths.firstObject;
    NSString *cand2 = [documents stringByAppendingPathComponent:[NSString stringWithFormat:@"instances/%@/mods", profile]];
    BOOL isDir2 = NO;
    if ([fm fileExistsAtPath:cand2 isDirectory:&isDir2] && isDir2) return cand2;
    const char *gameDirC = getenv("POJAV_GAME_DIR");
    if (gameDirC) {
        NSString *gameDir = [NSString stringWithUTF8String:gameDirC];
        NSString *cand3 = [gameDir stringByAppendingPathComponent:@"mods"];
        BOOL isDir3 = NO;
        if ([fm fileExistsAtPath:cand3 isDirectory:&isDir3] && isDir3) return cand3;
    }
    NSString *cand4 = [documents stringByAppendingPathComponent:[NSString stringWithFormat:@"game_data/%@/mods", profile]];
    BOOL isDir4 = NO;
    if ([fm fileExistsAtPath:cand4 isDirectory:&isDir4] && isDir4) return cand4;

    // conservative fallback only for default profile
    if (profile && ![profile isEqualToString:@"default"]) {
        return nil;
    }

    NSDirectoryEnumerator *enumerator = [fm enumeratorAtPath:documents];
    NSString *entry;
    int depth = 0;
    while ((entry = [enumerator nextObject]) && depth < 1000) {
        depth++;
        if ([entry.lastPathComponent.lowercaseString isEqualToString:@"mods"]) {
            NSString *full = [documents stringByAppendingPathComponent:entry];
            BOOL isDir = NO;
            if ([fm fileExistsAtPath:full isDirectory:&isDir] && isDir) {
                NSArray *sub = [fm contentsOfDirectoryAtPath:full error:nil];
                for (NSString *fn in sub) {
                    NSString *lower = fn.lowercaseString;
                    if ([lower hasSuffix:@".jar"] || [lower hasSuffix:@".jar.disabled"]) {
                        return full;
                    }
                }
            }
        }
    }

    return nil;
}

- (void)scanModsForProfile:(NSString *)profileName completion:(ModListHandler)completion {
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSString *modsFolder = [self existingModsFolderForProfile:profileName];
        NSMutableArray<ModItem *> *items = [NSMutableArray array];
        if (modsFolder) {
            NSError *err = nil;
            NSArray *contents = [[NSFileManager defaultManager] contentsOfDirectoryAtPath:modsFolder error:&err];
            if (contents) {
                for (NSString *f in contents) {
                    NSString *lower = f.lowercaseString;
                    if ([lower hasSuffix:@".jar"] || [lower hasSuffix:@".jar.disabled"] || [lower hasSuffix:@".disabled"]) {
                        NSString *full = [modsFolder stringByAppendingPathComponent:f];
                        ModItem *m = [[ModItem alloc] initWithFilePath:full];
                        [items addObject:m];
                    }
                }
            }
        }
        [items sortUsingComparator:^NSComparisonResult(ModItem *a, ModItem *b) {
            return [a.displayName caseInsensitiveCompare:b.displayName];
        }];
        dispatch_async(dispatch_get_main_queue(), ^{
            completion(items);
        });
    });
}

#pragma mark - Metadata fetch (collect flags; pick metadata by priority)

- (void)fetchMetadataForMod:(ModItem *)mod completion:(ModMetadataHandler)completion {
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        @try {
            NSString *sha1 = [self sha1ForFileAtPath:mod.filePath];
            if (sha1) mod.fileSHA1 = sha1;

            // We'll collect candidate metadata from different loader configs
            __block NSDictionary *fabricDict = nil;
            __block NSDictionary *modsTomlFields = nil;
            __block NSDictionary *mcmodDict = nil;

            // reset flags
            mod.isFabric = NO;
            mod.isForge = NO;
            mod.isNeoForge = NO;

            // 1) detect fabric.mod.json (and record)
            @try {
                NSData *fabricJsonData = [self readFileFromJar:mod.filePath entryName:@"fabric.mod.json"];
                if (!fabricJsonData) fabricJsonData = [self readFileFromJar:mod.filePath entryName:@"META-INF/fabric.mod.json"];
                if (fabricJsonData) {
                    NSError *jerr = nil;
                    id obj = [NSJSONSerialization JSONObjectWithData:fabricJsonData options:0 error:&jerr];
                    if (!jerr && [obj isKindOfClass:[NSDictionary class]]) {
                        fabricDict = obj;
                        mod.isFabric = YES;
                    }
                }
            } @catch (NSException *ex) { /* ignore parse exceptions */ }

            // 2) detect mods.toml / neoforge.mods.toml (and record)
            @try {
                NSData *modsTomlData = [self readFileFromJar:mod.filePath entryName:@"META-INF/mods.toml"];
                if (!modsTomlData) modsTomlData = [self readFileFromJar:mod.filePath entryName:@"mods.toml"];
                if (!modsTomlData) modsTomlData = [self readFileFromJar:mod.filePath entryName:@"neoforge.mods.toml"];
                if (modsTomlData) {
                    NSString *s = [[NSString alloc] initWithData:modsTomlData encoding:NSUTF8StringEncoding];
                    if (!s) s = [[NSString alloc] initWithData:modsTomlData encoding:NSISOLatin1StringEncoding];
                    if (s) {
                        NSDictionary *fields = [self parseFirstModsTableFromTomlString:s];
                        if (fields.count > 0) {
                            modsTomlFields = fields;
                            // mark as forge or neoforge based on presence of neoforge.mods.toml entry
                            if ([self readFileFromJar:mod.filePath entryName:@"neoforge.mods.toml"]) mod.isNeoForge = YES;
                            else mod.isForge = YES;
                        }
                    }
                }
            } @catch (NSException *ex) { /* ignore */ }

            // 3) detect mcmod.info (old)
            @try {
                NSData *mcData = [self readFileFromJar:mod.filePath entryName:@"mcmod.info"];
                if (mcData) {
                    NSError *jerr = nil;
                    id obj = [NSJSONSerialization JSONObjectWithData:mcData options:0 error:&jerr];
                    if (!jerr && [obj isKindOfClass:[NSArray class]]) {
                        NSArray *arr = obj;
                        if (arr.count > 0 && [arr[0] isKindOfClass:[NSDictionary class]]) {
                            mcmodDict = arr[0];
                        }
                    } else {
                        NSString *s = [[NSString alloc] initWithData:mcData encoding:NSUTF8StringEncoding];
                        if (s && s.length) {
                            NSRange nameRange = [s rangeOfString:@"name\"\\s*:\\s*\"" options:NSRegularExpressionSearch];
                            if (nameRange.location != NSNotFound) {
                                NSUInteger start = NSMaxRange(nameRange);
                                NSUInteger pos = start;
                                NSMutableString *buf = [NSMutableString string];
                                while (pos < s.length) {
                                    unichar c = [s characterAtIndex:pos++];
                                    if (c == '\"') break;
                                    [buf appendFormat:@"%C", c];
                                }
                                if (buf.length) {
                                    mcmodDict = @{@"name": buf};
                                }
                            }
                        }
                    }
                }
            } @catch (NSException *ex) { /* ignore */ }

            // Now choose metadata by priority: Fabric > mods.toml (Forge/NeoForge) > mcmod.info
            if (fabricDict) {
                if (fabricDict[@"name"] && [fabricDict[@"name"] isKindOfClass:[NSString class]]) mod.displayName = fabricDict[@"name"];
                if (fabricDict[@"description"] && [fabricDict[@"description"] isKindOfClass:[NSString class]]) mod.modDescription = fabricDict[@"description"];
                if (fabricDict[@"version"] && [fabricDict[@"version"] isKindOfClass:[NSString class]]) mod.version = fabricDict[@"version"];
                // homepage may be top-level or under contact.homepage
                if (fabricDict[@"homepage"] && [fabricDict[@"homepage"] isKindOfClass:[NSString class]]) mod.homepage = fabricDict[@"homepage"];
                else if (fabricDict[@"contact"] && [fabricDict[@"contact"] isKindOfClass:[NSDictionary class]]) {
                    NSString *hp = fabricDict[@"contact"][@"homepage"];
                    if (hp && [hp isKindOfClass:[NSString class]] && hp.length) mod.homepage = hp;
                }
                if (fabricDict[@"sources"] && [fabricDict[@"sources"] isKindOfClass:[NSString class]]) mod.sources = fabricDict[@"sources"];

                if (fabricDict[@"icon"] && [fabricDict[@"icon"] isKindOfClass:[NSString class]]) {
                    NSString *iconPath = fabricDict[@"icon"];
                    NSArray *cands = @[
                        iconPath ?: @"",
                        [iconPath stringByReplacingOccurrencesOfString:@"./" withString:@""],
                        [NSString stringWithFormat:@"assets/%@", iconPath ?: @""],
                        [NSString stringWithFormat:@"assets/%@/%@", [mod.basename lowercaseString], [iconPath lastPathComponent] ?: @""]
                    ];
                    NSString *cached = [self extractFirstMatchingImageFromJar:mod.filePath candidates:cands baseName:mod.basename];
                    if (cached) mod.iconURL = cached;
                }
            } else if (modsTomlFields) {
                NSString *dname = modsTomlFields[@"displayName"] ?: modsTomlFields[@"name"];
                if (dname.length) mod.displayName = dname;
                if (modsTomlFields[@"description"]) mod.modDescription = modsTomlFields[@"description"];
                if (modsTomlFields[@"version"]) mod.version = modsTomlFields[@"version"];
                if (modsTomlFields[@"displayURL"]) mod.homepage = modsTomlFields[@"displayURL"];
                else if (modsTomlFields[@"homepage"]) mod.homepage = modsTomlFields[@"homepage"];
                if (modsTomlFields[@"logoFile"]) {
                    NSString *logo = modsTomlFields[@"logoFile"];
                    NSArray *cands = @[
                        logo ?: @"",
                        [NSString stringWithFormat:@"assets/%@/%@", [[mod.basename lowercaseString] stringByReplacingOccurrencesOfString:@" " withString:@"_"], logo ?: @""],
                        [logo lastPathComponent] ?: @""
                    ];
                    NSString *cached = [self extractFirstMatchingImageFromJar:mod.filePath candidates:cands baseName:mod.basename];
                    if (cached) mod.iconURL = cached;
                }
            } else if (mcmodDict) {
                if (mcmodDict[@"name"]) mod.displayName = mcmodDict[@"name"];
                if (mcmodDict[@"description"]) mod.modDescription = mcmodDict[@"description"];
                if (mcmodDict[@"version"]) mod.version = mcmodDict[@"version"];
            }

            // If no loader flags were set but we found content that implies a loader, set minimal flags
            // (some jars might have only mods.toml but our earlier check failed to detect)
            if (!mod.isFabric && !mod.isForge && !mod.isNeoForge) {
                // Heuristic: if modsTomlFields exists -> forge-ish
                if (modsTomlFields) mod.isForge = YES;
            }
        } @catch (NSException *ex) {
            // Defensive: do not crash; return mod as-is
            NSLog(@"[ModService] Exception while fetching metadata for %@: %@", mod.filePath, ex);
        }

        dispatch_async(dispatch_get_main_queue(), ^{
            completion(mod, nil);
        });
    });
}

#pragma mark - File operations (unchanged)
- (BOOL)toggleEnableForMod:(ModItem *)mod error:(NSError **)error {
    NSString *path = mod.filePath;
    NSFileManager *fm = [NSFileManager defaultManager];
    if (mod.disabled) {
        NSString *newName = [mod.fileName stringByReplacingOccurrencesOfString:@".disabled" withString:@""];
        NSString *newPath = [[mod.filePath stringByDeletingLastPathComponent] stringByAppendingPathComponent:newName];
        BOOL ok = [fm moveItemAtPath:path toPath:newPath error:error];
        if (ok) {
            mod.filePath = newPath;
            mod.fileName = newName;
            mod.disabled = NO;
        }
        return ok;
    } else {
        NSString *newName = [mod.fileName stringByAppendingString:@".disabled"];
        NSString *newPath = [[mod.filePath stringByDeletingLastPathComponent] stringByAppendingPathComponent:newName];
        BOOL ok = [fm moveItemAtPath:path toPath:newPath error:error];
        if (ok) {
            mod.filePath = newPath;
            mod.fileName = newName;
            mod.disabled = YES;
        }
        return ok;
    }
}

- (BOOL)deleteMod:(ModItem *)mod error:(NSError **)error {
    return [[NSFileManager defaultManager] removeItemAtPath:mod.filePath error:error];
}

@end