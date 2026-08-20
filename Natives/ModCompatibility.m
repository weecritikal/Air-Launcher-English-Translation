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
