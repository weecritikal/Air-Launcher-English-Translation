#import "ModCompatibility.h"
#import "utils.h"

/// One known-incompatible mod.
///
/// @c filePrefix is matched case-insensitively against the start of the jar's file name. Matching a
/// prefix rather than a substring keeps an unrelated mod whose name merely contains one of these
/// words from being set aside, and every mod here publishes its jars under a stable name.
typedef struct {
    __unsafe_unretained NSString *filePrefix;
    __unsafe_unretained NSString *reason;
} PLUnsupportedMod;

/// Two mods that do the same job and cannot both be installed.
///
/// @c supersededPrefix is the one to set aside; @c keepsPrefix is the one that stays. Both must be
/// present for the rule to fire - either alone is fine.
typedef struct {
    __unsafe_unretained NSString *supersededPrefix;
    __unsafe_unretained NSString *keepsPrefix;
    __unsafe_unretained NSString *reason;
} PLConflictingMods;

/// Whether any enabled jar in @c entries starts with @c prefix.
static BOOL PLDirectoryHasMod(NSArray<NSString *> *entries, NSString *prefix) {
    for (NSString *name in entries) {
        if ([name hasPrefix:@"."]) continue;
        if (![name.pathExtension.lowercaseString isEqualToString:@"jar"]) continue;
        NSRange match = [name rangeOfString:prefix
                                    options:NSCaseInsensitiveSearch | NSAnchoredSearch];
        if (match.location != NSNotFound) return YES;
    }
    return NO;
}

static NSArray<NSDictionary<NSString *, NSString *> *> *PLScanUnsupportedMods(NSString *directory) {
    // Kept deliberately short. A mod belongs here only when it cannot work on this platform at all
    // and takes the game down with it - not when it merely runs badly or looks wrong.
    static const PLUnsupportedMod kUnsupported[] = {
        {@"controllable-forge",
         @"loads a desktop build of SDL2 that needs Apple's ForceFeedback framework, which iOS does "
          "not have. Controllers already work without it: the launcher reads them itself and feeds "
          "the game the same input as a keyboard and mouse."},
        {@"controllable-fabric",
         @"loads a desktop build of SDL2 that needs Apple's ForceFeedback framework, which iOS does "
          "not have. Controllers already work without it: the launcher reads them itself and feeds "
          "the game the same input as a keyboard and mouse."},
        {@"controllable-neoforge",
         @"loads a desktop build of SDL2 that needs Apple's ForceFeedback framework, which iOS does "
          "not have. Controllers already work without it: the launcher reads them itself and feeds "
          "the game the same input as a keyboard and mouse."},
        {@"controllable-sdl",
         @"is the desktop SDL2 library Controllable loads, built for Mac rather than iOS."},
    };
    static const size_t kUnsupportedCount = sizeof(kUnsupported) / sizeof(kUnsupported[0]);

    NSFileManager *fm = NSFileManager.defaultManager;
    NSArray<NSString *> *entries = [fm contentsOfDirectoryAtPath:directory error:nil];
    if (entries.count == 0) return @[];

    NSMutableArray<NSDictionary<NSString *, NSString *> *> *found = [NSMutableArray new];
    for (NSString *name in entries) {
        // Only enabled jars. A ".jar.disabled" file is already switched off, and the folders the
        // launcher sets files aside into start with a dot.
        if ([name hasPrefix:@"."]) continue;
        if (![name.pathExtension.lowercaseString isEqualToString:@"jar"]) continue;

        for (size_t i = 0; i < kUnsupportedCount; i++) {
            NSRange match = [name rangeOfString:kUnsupported[i].filePrefix
                                        options:NSCaseInsensitiveSearch | NSAnchoredSearch];
            if (match.location == NSNotFound) continue;
            [found addObject:@{@"name": name, @"reason": kUnsupported[i].reason}];
            break;
        }
    }

    // Mods that work alone and destroy each other together. A renderer replacement rewrites the
    // whole terrain pipeline through mixins into the same Minecraft classes; installing two means
    // two sets of buffers and two sets of GL state for one screen. The game loads, and then the
    // graphics driver dies the moment a world is drawn - a SIGSEGV inside Apple's Metal driver
    // that names nothing and looks exactly like a hardware fault.
    static const PLConflictingMods kConflicts[] = {
        {@"rubidium", @"embeddium",
         @"is the older version of Embeddium - they are the same renderer, and this pack has both. "
          "Two renderers rewriting the same drawing code crashes the graphics driver as soon as a "
          "world loads. Embeddium is the maintained one, so it stays."},
        {@"reeses_sodium_options", @"textrues_embeddium_options",
         @"is the settings screen for Rubidium, which has been set aside. Embeddium's own settings "
          "screen is installed and does the same job."},
        {@"magnesium", @"embeddium",
         @"is an older name for the same renderer as Embeddium. Two of them crash the graphics "
          "driver as soon as a world loads."},
    };
    static const size_t kConflictCount = sizeof(kConflicts) / sizeof(kConflicts[0]);

    for (size_t i = 0; i < kConflictCount; i++) {
        if (!PLDirectoryHasMod(entries, kConflicts[i].keepsPrefix)) continue;
        for (NSString *name in entries) {
            if ([name hasPrefix:@"."]) continue;
            if (![name.pathExtension.lowercaseString isEqualToString:@"jar"]) continue;
            NSRange match = [name rangeOfString:kConflicts[i].supersededPrefix
                                        options:NSCaseInsensitiveSearch | NSAnchoredSearch];
            if (match.location == NSNotFound) continue;

            // A jar already listed above is set aside for a stronger reason; do not report it twice.
            BOOL already = NO;
            for (NSDictionary *entry in found) {
                if ([entry[@"name"] isEqualToString:name]) { already = YES; break; }
            }
            if (!already) {
                [found addObject:@{@"name": name, @"reason": kConflicts[i].reason}];
            }
        }
    }

    return found;
}

@implementation ModCompatibility

+ (NSArray<NSDictionary<NSString *, NSString *> *> *)unsupportedModsInDirectory:(NSString *)directory {
    if (directory.length == 0) return @[];
    return PLScanUnsupportedMods(directory);
}

+ (NSArray<NSDictionary<NSString *, NSString *> *> *)setAsideUnsupportedModsInDirectory:(NSString *)directory {
    NSArray<NSDictionary<NSString *, NSString *> *> *unsupported = [self unsupportedModsInDirectory:directory];
    if (unsupported.count == 0) return unsupported;

    NSFileManager *fm = NSFileManager.defaultManager;
    NSString *asideDir = [directory stringByAppendingPathComponent:@".air_unsupported"];
    [fm createDirectoryAtPath:asideDir withIntermediateDirectories:YES attributes:nil error:nil];

    NSMutableArray<NSDictionary<NSString *, NSString *> *> *moved = [NSMutableArray new];
    for (NSDictionary<NSString *, NSString *> *entry in unsupported) {
        NSString *name = entry[@"name"];
        NSString *source = [directory stringByAppendingPathComponent:name];
        NSString *destination = [asideDir stringByAppendingPathComponent:name];
        [fm removeItemAtPath:destination error:nil];

        NSError *moveError = nil;
        if ([fm moveItemAtPath:source toPath:destination error:&moveError]) {
            NSLog(@"[ModCompatibility] Set aside '%@': %@", name, entry[@"reason"]);
            [moved addObject:entry];
        } else {
            // Unlike a failed download, this is a file the user chose to install, so it is never
            // deleted. Leaving it in place means the game will still crash, which the caller says.
            NSLog(@"[ModCompatibility] Could not set aside '%@': %@", name, moveError.localizedDescription);
        }
    }
    return moved;
}

@end
