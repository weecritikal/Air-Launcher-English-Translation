//
//  ModService.m
//  AmethystMods
//
//  Created by Copilot on 2025-08-22.
//

#import "ModService.h"
#import <CommonCrypto/CommonCrypto.h>
#import <UIKit/UIKit.h>

@implementation ModService

+ (instancetype)sharedService {
    static ModService *s;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        s = [ModService new];
    });
    return s;
}

#pragma mark - Paths

// NOTE: adjust this to your actual launcher profile/mods layout if different.
- (NSString *)modsPathForProfile:(NSString *)profileName {
    NSArray *paths = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES);
    NSString *documents = paths.firstObject;
    NSString *modsPath = [documents stringByAppendingPathComponent:[NSString stringWithFormat:@"game_data/%@/mods", profileName ?: @"default"]];
    if (![[NSFileManager defaultManager] fileExistsAtPath:modsPath]) {
        [[NSFileManager defaultManager] createDirectoryAtPath:modsPath withIntermediateDirectories:YES attributes:nil error:nil];
    }
    return modsPath;
}

#pragma mark - Scan

- (void)scanModsForProfile:(NSString *)profileName completion:(ModListHandler)completion {
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSString *modsFolder = [self modsPathForProfile:profileName];
        NSError *err = nil;
        NSArray *contents = [[NSFileManager defaultManager] contentsOfDirectoryAtPath:modsFolder error:&err];
        NSMutableArray<ModItem *> *items = [NSMutableArray array];
        if (contents) {
            for (NSString *f in contents) {
                if ([f hasSuffix:@".jar"] || [f hasSuffix:@".jar.disabled"] || [f hasSuffix:@".disabled"]) {
                    NSString *full = [modsFolder stringByAppendingPathComponent:f];
                    ModItem *m = [[ModItem alloc] initWithFilePath:full];
                    [items addObject:m];
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

#pragma mark - Metadata (Modrinth search fallback)

- (void)fetchMetadataForMod:(ModItem *)mod completion:(ModMetadataHandler)completion {
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        // compute SHA1 (optional, stored on mod)
        NSString *sha1 = [self sha1ForFileAtPath:mod.filePath];
        if (sha1) mod.fileSHA1 = sha1;

        // Simple fallback: search Modrinth by displayName keyword
        NSString *query = [mod.displayName stringByAddingPercentEncodingWithAllowedCharacters:[NSCharacterSet URLQueryAllowedCharacterSet]];
        NSString *searchURL = [NSString stringWithFormat:@"https://api.modrinth.com/v2/search?query=%@&index=0&limit=5", query ?: @""];
        NSURL *urlObj = [NSURL URLWithString:searchURL];
        if (!urlObj) {
            dispatch_async(dispatch_get_main_queue(), ^{
                completion(mod, nil);
            });
            return;
        }
        NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:urlObj];
        req.HTTPMethod = @"GET";
        NSURLSessionDataTask *task = [NSURLSession.sharedSession dataTaskWithRequest:req completionHandler:^(NSData * _Nullable data, NSURLResponse * _Nullable response, NSError * _Nullable error) {
            if (error || !data) {
                dispatch_async(dispatch_get_main_queue(), ^{
                    completion(mod, error);
                });
                return;
            }
            NSError *jsonErr;
            NSDictionary *json = [NSJSONSerialization JSONObjectWithData:data options:0 error:&jsonErr];
            if (jsonErr || ![json isKindOfClass:[NSDictionary class]]) {
                dispatch_async(dispatch_get_main_queue(), ^{
                    completion(mod, jsonErr);
                });
                return;
            }
            NSArray *hits = json[@"hits"];
            if (hits.count > 0) {
                NSDictionary *first = hits.firstObject;
                NSString *desc = first[@"description"] ?: first[@"summary"] ?: @"";
                NSString *icon = nil;
                NSString *projectId = first[@"project_id"];
                if (projectId) {
                    NSString *projURL = [NSString stringWithFormat:@"https://api.modrinth.com/v2/project/%@", projectId];
                    NSData *projData = [NSData dataWithContentsOfURL:[NSURL URLWithString:projURL]];
                    if (projData) {
                        NSDictionary *projJson = [NSJSONSerialization JSONObjectWithData:projData options:0 error:nil];
                        if ([projJson isKindOfClass:[NSDictionary class]]) {
                            icon = projJson[@"icon_url"];
                            if (!icon) {
                                NSDictionary *icons = projJson[@"icons"];
                                if ([icons isKindOfClass:[NSDictionary class]]) {
                                    icon = icons[@"512"] ?: icons[@"256"] ?: icons[@"128"];
                                }
                            }
                        }
                    }
                }
                dispatch_async(dispatch_get_main_queue(), ^{
                    mod.modDescription = desc;
                    mod.iconURL = icon;
                    completion(mod, nil);
                });
                return;
            } else {
                dispatch_async(dispatch_get_main_queue(), ^{
                    completion(mod, nil);
                });
                return;
            }
        }];
        [task resume];
    });
}

#pragma mark - File ops

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

@end