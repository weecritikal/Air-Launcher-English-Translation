//
//  ModLoaderInstallViewController.h
//  Flux
//
//  Rebuilt after the mod loader selection screen of FCL (FoldCraftLauncher).
//  - The loader list uses a grouped UITableView with card-style row selection
//  - Mutual exclusion rules: forge/fabric/quilt/neoforge are mutually exclusive;
//              optifine excludes fabric/quilt/neoforge (but can coexist with forge);
//              fabricApi depends on fabric and excludes forge/optifine/neoforge
//  - Version selection is pushed to a separate ModLoaderVersionPickerViewController, so the main page layout is not squeezed
//  - The install button at the bottom is pinned to the bottom safe area, so it is never clipped on iPhone
//

#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

/// Loader type identifiers (matching the convention of the external install dispatcher)
typedef NS_ENUM(NSInteger, ModLoaderKind) {
    ModLoaderKindVanilla  = 0,
    ModLoaderKindFabric   = 1,
    ModLoaderKindForge    = 2,
    ModLoaderKindNeoForge = 3,
    ModLoaderKindQuilt    = 4,
    ModLoaderKindOptiFine = 5,  // Install OptiFine on its own (not alongside Forge), as a version patch
};

/// The mod loader install selection VC (modeled on FCL InstallerListPage + VersionInstallInfoPage)
@interface ModLoaderInstallViewController : UIViewController

/// The game version to install, such as "1.20.1"
@property (nonatomic, copy) NSString *gameVersion;

/// Completion callback: loaderId is @"vanilla"/@"fabric"/@"forge"/@"neoforge"/@"quilt"/@"optifine",
/// installFabricAPI can only be YES when fabric is selected,
/// installOptiFine is YES when forge is selected (coexisting as a mod) or when optifine is selected on its own,
/// and loaderVersion is the loader version number (nil for vanilla)
@property (nonatomic, copy) void (^completion)(NSString *loaderId,
                                               BOOL installFabricAPI,
                                               BOOL installOptiFine,
                                               NSString * _Nullable loaderVersion);

/// Cancellation callback
@property (nonatomic, copy) void (^cancelled)(void);

@end

NS_ASSUME_NONNULL_END
