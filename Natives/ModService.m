//
//  ModService.m
//  AmethystMods
//
//  Created by Copilot on 2025-08-22.
//
//  Uses libarchive to reliably read files inside jar (zip) archives.
//

#import "ModService.h"
#import <CommonCrypto/CommonCrypto.h>
#import <UIKit/UIKit.h>
#import "PLProfiles.h"
#import "ModItem.h"

#include <archive.h>
#include <archive_entry.h>

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

#pragma mark - Helpers

- (NSString *)sha1ForFileAtPath:(NSString *)path {
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

#pragma mark - Read specific entry from jar (libarchive)

- (NSData *)readFileFromJar:(NSString *)jarPath entryName:(NSString *)entryName {
    if (!jarPath || !entryName) return nil;
    struct archive *a = archive_read_new();
    archive_read_support_format_zip(a);
    archive_read_support_format_all(a);
    archive_read_support_compression_all(a);

    int r = archive_read_open_filename(a, [jarPath fileSystemRepresentation], 10240);
    if (r != ARCHIVE_OK) {
        archive_read_free(a);
        return nil;
    }

    struct archive_entry *entry;
    NSData *result = nil;
    while (archive_read_next_header(a, &entry) == ARCHIVE_OK) {
        const char *path = archive_entry_pathname(entry);
        if (!path) {
            // skip
        } else {
            NSString *p = [NSString stringWithUTF8String:path];
            if (!p) p = @"";
            // Normalize paths for comparison
            NSString *norm = [p stringByReplacingOccurrencesOfString:@"\\" withString:@"/"];
            // Compare exact or basename matches
            if ([norm isEqualToString:entryName] ||
                [[norm lastPathComponent] isEqualToString:entryName] ||
                [norm caseInsensitiveCompare:entryName] == NSOrderedSame) {
                // Read entry data
                off_t size = archive_entry_size(entry);
                NSMutableData *buf = [NSMutableData data];
                const void *buff = NULL;
                ssize_t len;
                char tmp[8192];
                while ((len = archive_read_data(a, tmp, sizeof(tmp))) > 0) {
                    [buf appendBytes:tmp length:(NSUInteger)len];
                }
                if (buf.length > 0) {
                    result = [buf copy];
                    break;
                }
            }
        }
        archive_read_data_skip(a);
    }

    archive_read_close(a);
    archive_read_free(a);
    return result;
}

#pragma mark - helpers for extracting first-matching resource (icon)

- (NSString *)extractFirstMatchingImageFromJar:(NSString *)jarPath candidates:(NSArray<NSString *> *)candidates baseName:(NSString *)baseName {
    if (!jarPath) return nil;
    for (NSString *cand in candidates) {
        if (!cand || cand.length == 0) continue;
        NSData *d = [self readFileFromJar:jarPath entryName:cand];
        if (d && d.length > 8) {
            // check PNG header
            const unsigned char *bytes = d.bytes;
            if (d.length >= 8 && bytes[0] == 0x89 && bytes[1] == 0x50 && bytes[2] == 0x4E && bytes[3] == 0x47) {
                // write to cache
                NSString *cacheDir = [NSSearchPathForDirectoriesInDomains(NSCachesDirectory, NSUserDomainMask, YES) firstObject];
                NSString *iconsDir = [cacheDir stringByAppendingPathComponent:@"mod_icons"];
                if (![[NSFileManager defaultManager] fileExistsAtPath:iconsDir]) {
                    [[NSFileManager defaultManager] createDirectoryAtPath:iconsDir withIntermediateDirectories:YES attributes:nil error:nil];
                }
                NSString *fname = [NSString stringWithFormat:@"%@_%@", [baseName stringByReplacingOccurrencesOfString:@" " withString:@"_"], [cand lastPathComponent]];
                NSString *dest = [iconsDir stringByAppendingPathComponent:fname];
                NSError *err = nil;
                if ([d writeToFile:dest options:NSDataWritingAtomic error:&err]) {
                    return [NSURL fileURLWithPath:dest].absoluteString;
                }
            } else {
                // not PNG — still try to save (some mods use JPG)
                NSString *cacheDir = [NSSearchPathForDirectoriesInDomains(NSCachesDirectory, NSUserDomainMask, YES) firstObject];
                NSString *iconsDir = [cacheDir stringByAppendingPathComponent:@"mod_icons"];
                if (![[NSFileManager defaultManager] fileExistsAtPath:iconsDir]) {
                    [[NSFileManager defaultManager] createDirectoryAtPath:iconsDir withIntermediateDirectories:YES attributes:nil error:nil];
                }
                NSString *fname = [NSString stringWithFormat:@"%@_%@", [baseName stringByReplacingOccurrencesOfString:@" " withString:@"_"], [cand lastPathComponent]];
                NSString *dest = [iconsDir stringByAppendingPathComponent:fname];
                NSError *err = nil;
                if ([d writeToFile:dest options:NSDataWritingAtomic error:&err]) {
                    return [NSURL fileURLWithPath:dest].absoluteString;
                }
            }
        }
    }
    return nil;
}

#pragma mark - TOML lightweight parser (unchanged heuristic)

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

#pragma mark - Mods folder detection & scan (unchanged)

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
                    if ([f hasSuffix:@".jar"] || [f hasSuffix:@".jar.disabled"] || [f hasSuffix:@".disabled"]) {
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

#pragma mark - Metadata fetch (zip-based + online optional)

- (void)fetchMetadataForMod:(ModItem *)mod completion:(ModMetadataHandler)completion {
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        NSString *sha1 = [self sha1ForFileAtPath:mod.filePath];
        if (sha1) mod.fileSHA1 = sha1;

        __block BOOL gotLocal = NO;

        // 1) Try to read fabric.mod.json directly from jar
        NSData *fabricJsonData = [self readFileFromJar:mod.filePath entryName:@"fabric.mod.json"];
        if (!fabricJsonData) {
            // sometimes it's stored under META-INF or root with different casing; try basenames
            fabricJsonData = [self readFileFromJar:mod.filePath entryName:@"META-INF/fabric.mod.json"];
        }
        if (fabricJsonData) {
            NSError *jerr = nil;
            id obj = [NSJSONSerialization JSONObjectWithData:fabricJsonData options:0 error:&jerr];
            if (!jerr && [obj isKindOfClass:[NSDictionary class]]) {
                NSDictionary *d = obj;
                if (d[@"name"]) mod.displayName = d[@"name"];
                if (d[@"description"]) mod.modDescription = d[@"description"];
                if (d[@"version"]) mod.version = d[@"version"];
                if (d[@"homepage"] && [d[@"homepage"] isKindOfClass:[NSString class]]) mod.homepage = d[@"homepage"];
                else if (d[@"sources"] && [d[@"sources"] isKindOfClass:[NSString class]]) mod.sources = d[@"sources"];
                if (d[@"icon"] && [d[@"icon"] isKindOfClass:[NSString class]]) {
                    NSString *iconPath = d[@"icon"];
                    // candidates for where this path could be inside jar
                    NSArray *cands = @[
                        iconPath,
                        [NSString stringWithFormat:@"/%@", iconPath],
                        [iconPath stringByReplacingOccurrencesOfString:@"./" withString:@""],
                        [@"assets/" stringByAppendingPathComponent:iconPath],
                        [NSString stringWithFormat:@"assets/%@/%@", [mod.basename lowercaseString], [iconPath lastPathComponent]]
                    ];
                    NSString *cached = [self extractFirstMatchingImageFromJar:mod.filePath candidates:cands baseName:mod.basename];
                    if (cached) mod.iconURL = cached;
                }
                mod.isFabric = YES;
                gotLocal = YES;
            }
        }

        // 2) Try mods.toml (META-INF/mods.toml) and neoforge.mods.toml
        if (!gotLocal) {
            NSData *modsTomlData = [self readFileFromJar:mod.filePath entryName:@"META-INF/mods.toml"];
            if (!modsTomlData) modsTomlData = [self readFileFromJar:mod.filePath entryName:@"mods.toml"];
            if (!modsTomlData) modsTomlData = [self readFileFromJar:mod.filePath entryName:@"neoforge.mods.toml"];
            if (modsTomlData) {
                NSString *s = [[NSString alloc] initWithData:modsTomlData encoding:NSUTF8StringEncoding];
                if (!s) {
                    // try latin1 fallback
                    s = [[NSString alloc] initWithData:modsTomlData encoding:NSISOLatin1StringEncoding];
                }
                if (s) {
                    NSDictionary *fields = [self parseFirstModsTableFromTomlString:s];
                    if (fields.count > 0) {
                        NSString *dname = fields[@"displayName"] ?: fields[@"name"];
                        if (dname.length) mod.displayName = dname;
                        if (fields[@"description"]) mod.modDescription = fields[@"description"];
                        if (fields[@"version"]) mod.version = fields[@"version"];
                        if (fields[@"displayURL"]) mod.homepage = fields[@"displayURL"];
                        if (fields[@"homepage"]) mod.homepage = fields[@"homepage"];
                        if (fields[@"logoFile"]) {
                            NSString *logo = fields[@"logoFile"];
                            NSArray *cands = @[
                                logo ?: @"",
                                [NSString stringWithFormat:@"assets/%@/%@", [[mod.basename lowercaseString] stringByReplacingOccurrencesOfString:@" " withString:@"_"], logo ?: @""],
                                [logo lastPathComponent] ?: @""
                            ];
                            NSString *cached = [self extractFirstMatchingImageFromJar:mod.filePath candidates:cands baseName:mod.basename];
                            if (cached) mod.iconURL = cached;
                        }
                        // detect neoforge by filename fallback
                        if ([self readFileFromJar:mod.filePath entryName:@"neoforge.mods.toml"]) mod.isNeoForge = YES;
                        else mod.isForge = YES;
                        gotLocal = YES;
                    }
                }
            }
        }

        // 3) mcmod.info (old) — read directly if present
        if (!gotLocal) {
            NSData *mcData = [self readFileFromJar:mod.filePath entryName:@"mcmod.info"];
            if (mcData) {
                // mcmod.info might be JSON array
                NSError *jerr = nil;
                id obj = [NSJSONSerialization JSONObjectWithData:mcData options:0 error:&jerr];
                if (!jerr && [obj isKindOfClass:[NSArray class]]) {
                    NSArray *arr = obj;
                    if (arr.count > 0 && [arr[0] isKindOfClass:[NSDictionary class]]) {
                        NSDictionary *d = arr[0];
                        if (d[@"name"]) mod.displayName = d[@"name"];
                        if (d[@"description"]) mod.modDescription = d[@"description"];
                        if (d[@"version"]) mod.version = d[@"version"];
                        gotLocal = YES;
                    }
                } else {
                    // try to interpret as text and do simple search
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
                            if (buf.length) { mod.displayName = buf; gotLocal = YES; }
                        }
                    }
                }
            }
        }

        // If local not found and onlineSearchEnabled == YES -> remote Modrinth search
        __block BOOL didRemote = NO;
        if (!gotLocal && self.onlineSearchEnabled) {
            NSString *query = mod.displayName ?: [mod basename];
            query = [query stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
            NSString *q = [query stringByAddingPercentEncodingWithAllowedCharacters:[NSCharacterSet URLQueryAllowedCharacterSet]];
            if (q) {
                NSString *searchURL = [NSString stringWithFormat:@"https://api.modrinth.com/v2/search?query=%@&limit=5", q];
                NSData *d = [NSData dataWithContentsOfURL:[NSURL URLWithString:searchURL]];
                if (d) {
                    NSError *jsonErr;
                    NSDictionary *json = [NSJSONSerialization JSONObjectWithData:d options:0 error:&jsonErr];
                    if (!jsonErr && [json isKindOfClass:[NSDictionary class]]) {
                        NSArray *hits = json[@"hits"];
                        if (hits.count > 0) {
                            NSDictionary *first = hits.firstObject;
                            NSString *projectId = first[@"project_id"];
                            NSString *desc = first[@"description"] ?: first[@"title"];
                            __block NSString *iconUrl = nil;
                            if (projectId) {
                                NSString *projURL = [NSString stringWithFormat:@"https://api.modrinth.com/v2/project/%@", projectId];
                                NSData *projData = [NSData dataWithContentsOfURL:[NSURL URLWithString:projURL]];
                                if (projData) {
                                    NSDictionary *projJson = [NSJSONSerialization JSONObjectWithData:projData options:0 error:nil];
                                    if ([projJson isKindOfClass:[NSDictionary class]]) {
                                        iconUrl = projJson[@"icon_url"] ?: projJson[@"icon"];
                                        if (!iconUrl) {
                                            NSDictionary *icons = projJson[@"icons"];
                                            if ([icons isKindOfClass:[NSDictionary class]]) {
                                                iconUrl = icons[@"512"] ?: icons[@"256"] ?: icons[@"128"];
                                            }
                                        }
                                        if (!desc) desc = projJson[@"description"];
                                    }
                                }
                            }
                            if (first[@"title"] && [first[@"title"] isKindOfClass:[NSString class]]) mod.displayName = first[@"title"];
                            if (desc && [desc isKindOfClass:[NSString class]]) mod.modDescription = desc;
                            if (iconUrl && [iconUrl isKindOfClass:[NSString class]]) mod.iconURL = iconUrl;
                            didRemote = YES;
                        }
                    }
                }
            }
        }

        dispatch_async(dispatch_get_main_queue(), ^{
            completion(mod, nil);
        });
    });
}

#pragma mark - File operations

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
