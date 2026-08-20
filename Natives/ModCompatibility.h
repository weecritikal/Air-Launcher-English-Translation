#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Mods that cannot run on iOS, identified before the game starts rather than after it dies.
///
/// A handful of mods ship a desktop native library and load it as soon as the game reaches them.
/// On iOS that load can never succeed, and because these loads happen inside Forge's parallel mod
/// setup, one failure aborts the whole queue and takes the game down with a message that names
/// neither the mod nor the reason. The user sees a long load, a black screen, and a crash.
@interface ModCompatibility : NSObject

/// Mods in @c directory that are known not to work on iOS, without moving anything.
/// Each entry is @c @{@"name": file name, @"reason": one sentence on why it cannot work}.
+ (NSArray<NSDictionary<NSString *, NSString *> *> *)unsupportedModsInDirectory:(NSString *)directory;

/// Moves the mods reported by @c unsupportedModsInDirectory: into @c mods/.air_unsupported and
/// returns the ones actually moved. The files are kept, so the choice can be undone by hand.
+ (NSArray<NSDictionary<NSString *, NSString *> *> *)setAsideUnsupportedModsInDirectory:(NSString *)directory;

@end

NS_ASSUME_NONNULL_END
