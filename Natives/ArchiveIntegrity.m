#import "ArchiveIntegrity.h"
#import "PLProfiles.h"

// The size of an End Of Central Directory record that carries no trailing comment.
static const NSUInteger kEOCDMinimumSize = 22;
// The EOCD comment may be up to 65535 bytes, so the record can start at most 65557 bytes
// from the end of the file. Read a little more than that in one go.
static const NSUInteger kEOCDSearchWindow = 65557 + 1024;

@implementation ArchiveIntegrity

+ (BOOL)isArchivePath:(NSString *)path {
    NSString *ext = path.pathExtension.lowercaseString;
    return [ext isEqualToString:@"jar"] || [ext isEqualToString:@"zip"];
}

+ (nullable NSString *)validationFailureForArchiveAtPath:(NSString *)path {
    NSFileManager *fm = NSFileManager.defaultManager;
    if (![fm fileExistsAtPath:path]) {
        return @"file is missing";
    }

    NSError *error = nil;
    NSDictionary *attrs = [fm attributesOfItemAtPath:path error:&error];
    if (!attrs) {
        return [NSString stringWithFormat:@"cannot be read (%@)", error.localizedDescription ?: @"unknown error"];
    }
    unsigned long long fileSize = attrs.fileSize;
    if (fileSize == 0) {
        return @"file is empty (0 bytes)";
    }
    if (fileSize < kEOCDMinimumSize) {
        return [NSString stringWithFormat:@"file is too small to be an archive (%llu bytes)", fileSize];
    }

    NSFileHandle *handle = [NSFileHandle fileHandleForReadingAtPath:path];
    if (!handle) {
        return @"file could not be opened";
    }

    NSString *failure = nil;
    @try {
        // The End Of Central Directory record is the authority on whether an archive is
        // readable, and it lives at the very end of the file — so a transfer that stopped
        // early loses it entirely. This is exactly the "zip END header not found" the JVM
        // reports while scanning mods, caught here instead of at launch.
        NSUInteger tailLength = (NSUInteger)MIN((unsigned long long)kEOCDSearchWindow, fileSize);
        [handle seekToFileOffset:fileSize - tailLength];
        NSData *tail = [handle readDataOfLength:tailLength];
        NSInteger eocdOffset = -1;
        if (tail.length >= kEOCDMinimumSize) {
            const uint8_t *tailBytes = tail.bytes;
            for (NSInteger i = (NSInteger)tail.length - (NSInteger)kEOCDMinimumSize; i >= 0; i--) {
                if (tailBytes[i] == 0x50 && tailBytes[i+1] == 0x4b && tailBytes[i+2] == 0x05 && tailBytes[i+3] == 0x06) {
                    eocdOffset = i;
                    break;
                }
            }
        }

        if (eocdOffset < 0) {
            // Read the first bytes only to tell the two failure modes apart in the message.
            // A file that never was an archive (a CDN error page served with a 200 status is
            // the common case) reads very differently to a jar whose download was cut short.
            [handle seekToFileOffset:0];
            NSData *head = [handle readDataOfLength:4];
            const uint8_t *bytes = head.bytes;
            BOOL looksLikeZip = head.length >= 4 && bytes[0] == 'P' && bytes[1] == 'K';
            if (looksLikeZip) {
                failure = @"incomplete download (no ZIP end header)";
            } else if (head.length >= 4) {
                failure = [NSString stringWithFormat:@"not a ZIP archive (starts with %02x %02x %02x %02x) — the server most likely returned an error page",
                           bytes[0], bytes[1], bytes[2], bytes[3]];
            } else {
                failure = @"file is truncated";
            }
        } else {
            // The central directory the EOCD points at has to fit inside the file. This catches
            // an archive whose body was lost but whose tail happens to have survived.
            // Note the offsets are relative to the start of the ZIP data, which may sit after
            // prepended content, so only an overrun is conclusive.
            const uint8_t *eocd = (const uint8_t *)tail.bytes + eocdOffset;
            uint32_t cdSize   = (uint32_t)eocd[12] | ((uint32_t)eocd[13] << 8) | ((uint32_t)eocd[14] << 16) | ((uint32_t)eocd[15] << 24);
            uint32_t cdOffset = (uint32_t)eocd[16] | ((uint32_t)eocd[17] << 8) | ((uint32_t)eocd[18] << 16) | ((uint32_t)eocd[19] << 24);
            // 0xffffffff is the ZIP64 sentinel; the real values live in the ZIP64 record instead,
            // so accept them rather than reporting a false positive.
            if (cdSize != 0xffffffff && cdOffset != 0xffffffff) {
                unsigned long long cdEnd = (unsigned long long)cdOffset + (unsigned long long)cdSize;
                unsigned long long eocdAbsolute = (fileSize - tailLength) + (unsigned long long)eocdOffset;
                if (cdEnd > eocdAbsolute) {
                    failure = @"archive is damaged (central directory is out of bounds)";
                }
            }
        }
    } @catch (NSException *exception) {
        failure = [NSString stringWithFormat:@"could not be read (%@)", exception.reason ?: exception.name];
    } @finally {
        @try { [handle closeFile]; } @catch (NSException *ignored) {}
    }

    return failure;
}

+ (BOOL)isValidArchiveAtPath:(NSString *)path {
    return [self validationFailureForArchiveAtPath:path] == nil;
}

+ (NSArray<NSDictionary<NSString *, NSString *> *> *)findCorruptArchivesInDirectory:(NSString *)directory {
    NSMutableArray *corrupt = [NSMutableArray new];
    if (directory.length == 0) return corrupt;

    NSFileManager *fm = NSFileManager.defaultManager;
    BOOL isDir = NO;
    if (![fm fileExistsAtPath:directory isDirectory:&isDir] || !isDir) return corrupt;

    NSArray<NSString *> *entries = [fm contentsOfDirectoryAtPath:directory error:nil];
    for (NSString *entry in entries) {
        // Only enabled mods matter. A ".disabled" mod is never opened by the loader,
        // and the quarantine folder itself must not be rescanned.
        if ([entry hasPrefix:@"."]) continue;
        if (![entry.pathExtension.lowercaseString isEqualToString:@"jar"]) continue;

        NSString *fullPath = [directory stringByAppendingPathComponent:entry];
        BOOL entryIsDir = NO;
        if (![fm fileExistsAtPath:fullPath isDirectory:&entryIsDir] || entryIsDir) continue;

        NSString *reason = [self validationFailureForArchiveAtPath:fullPath];
        if (reason) {
            [corrupt addObject:@{@"name": entry, @"reason": reason}];
        }
    }
    return corrupt;
}

+ (NSArray<NSDictionary<NSString *, NSString *> *> *)quarantineCorruptArchivesInDirectory:(NSString *)directory {
    NSArray<NSDictionary<NSString *, NSString *> *> *corrupt = [self findCorruptArchivesInDirectory:directory];
    if (corrupt.count == 0) return corrupt;

    NSFileManager *fm = NSFileManager.defaultManager;
    NSString *quarantineDir = [directory stringByAppendingPathComponent:@".air_corrupt"];
    [fm createDirectoryAtPath:quarantineDir withIntermediateDirectories:YES attributes:nil error:nil];

    NSMutableArray *moved = [NSMutableArray new];
    for (NSDictionary *entry in corrupt) {
        NSString *name = entry[@"name"];
        NSString *source = [directory stringByAppendingPathComponent:name];
        NSString *destination = [quarantineDir stringByAppendingPathComponent:name];
        [fm removeItemAtPath:destination error:nil];

        NSError *moveError = nil;
        if ([fm moveItemAtPath:source toPath:destination error:&moveError]) {
            NSLog(@"[ArchiveIntegrity] Quarantined corrupt mod '%@' (%@)", name, entry[@"reason"]);
            [moved addObject:entry];
        } else {
            // Falling back to a delete is still better than letting the JVM crash on it —
            // the file is a failed download, not something the user put there.
            if ([fm removeItemAtPath:source error:nil]) {
                NSLog(@"[ArchiveIntegrity] Removed corrupt mod '%@' (%@); it could not be quarantined: %@",
                      name, entry[@"reason"], moveError.localizedDescription);
                [moved addObject:entry];
            } else {
                NSLog(@"[ArchiveIntegrity] Could not quarantine or remove corrupt mod '%@': %@",
                      name, moveError.localizedDescription);
            }
        }
    }
    return moved;
}

+ (nullable NSString *)modsFolderForProfile:(nullable NSString *)profileName {
    NSFileManager *fm = NSFileManager.defaultManager;
    const char *gameDirC = getenv("POJAV_GAME_DIR");
    NSString *baseDir = gameDirC ? @(gameDirC) : NSHomeDirectory();

    NSString *profile = profileName.length ? profileName : PLProfiles.current.selectedProfileName;
    if (profile.length == 0) profile = @"default";

    // Prefer the profile's own gameDir, which is where a modpack keeps its mods.
    @try {
        NSDictionary *entry = PLProfiles.current.profiles[profile];
        NSString *gameDir = [entry isKindOfClass:NSDictionary.class] ? entry[@"gameDir"] : nil;
        if ([gameDir isKindOfClass:NSString.class] && gameDir.length > 0 && ![gameDir isEqualToString:@"."]) {
            NSString *cleanGameDir = [gameDir hasPrefix:@"./"] ? [gameDir substringFromIndex:2] : gameDir;
            NSString *resolved = cleanGameDir.isAbsolutePath ? cleanGameDir : [baseDir stringByAppendingPathComponent:cleanGameDir];
            NSString *modsPath = [resolved stringByAppendingPathComponent:@"mods"];
            BOOL isDir = NO;
            if ([fm fileExistsAtPath:modsPath isDirectory:&isDir] && isDir) {
                return modsPath;
            }
        }
    } @catch (NSException *exception) {
        // Fall through to the shared mods folder below
    }

    NSString *sharedMods = [baseDir stringByAppendingPathComponent:@"mods"];
    BOOL isDir = NO;
    if ([fm fileExistsAtPath:sharedMods isDirectory:&isDir] && isDir) {
        return sharedMods;
    }
    return nil;
}

@end
