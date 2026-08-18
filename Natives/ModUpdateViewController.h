#import <UIKit/UIKit.h>
#import "ModItem.h"

NS_ASSUME_NONNULL_BEGIN

/// Multi-stage task flow page for mod updates/downgrades
/// Flow: clear the cache -> filter -> check concurrently -> user confirmation -> download concurrently -> replace files -> clean up
@interface ModUpdateViewController : UIViewController

/// Initializer
/// @param mods The local mod list (from the ModService scan)
/// @param gameVersion The current game version
/// @param loader The current loader (fabric/forge/neoforge/quilt; may be nil)
/// @param projectType The project type (mod/shader/resourcepack/datapack)
- (instancetype)initWithMods:(NSArray<ModItem *> *)mods
                gameVersion:(NSString *)gameVersion
                     loader:(nullable NSString *)loader
               projectType:(NSString *)projectType NS_DESIGNATED_INITIALIZER;

- (instancetype)initWithNibName:(nullable NSString *)nibNameOrNil bundle:(nullable NSBundle *)nibBundleOrNil NS_UNAVAILABLE;
- (instancetype)initWithCoder:(NSCoder *)coder NS_UNAVAILABLE;

@end

NS_ASSUME_NONNULL_END
