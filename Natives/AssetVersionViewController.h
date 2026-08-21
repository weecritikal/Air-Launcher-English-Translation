//
//  AssetVersionViewController.h
//  Flux
//
//  Generic asset version picker view controller
//  Used for resource packs / data packs / worlds — the three asset types with no concept of a "loader"
//  Modelled on ModVersionViewController, but without the loader filter button (game version filter only)
//  Reuses ModVersion as the version model (its structure matches ShaderVersion)
//

#import <UIKit/UIKit.h>
#import "ModVersion.h"

NS_ASSUME_NONNULL_BEGIN

// Asset type enum: decides the title and default behavior
typedef NS_ENUM(NSInteger, AssetVersionType) {
    AssetVersionTypeResourcePack = 0, // Resource pack
    AssetVersionTypeDataPack = 1,     // Data pack
    AssetVersionTypeWorld = 2,        // World
};

@class AssetVersionViewController;

@protocol AssetVersionViewControllerDelegate <NSObject>
// Called back once the user picks a version
- (void)assetVersionViewController:(AssetVersionViewController *)viewController
               didSelectVersion:(ModVersion *)version;
@end

@interface AssetVersionViewController : UIViewController

// Asset type (decides the title text, e.g. "Select resource pack version")
@property (nonatomic, assign) AssetVersionType assetType;
// Modrinth/CurseForge ID of the online project
@property (nonatomic, copy, nullable) NSString *projectID;
// Project display name (used as the navigation bar title)
@property (nonatomic, copy, nullable) NSString *projectDisplayName;
// Delegate
@property (nonatomic, weak, nullable) id<AssetVersionViewControllerDelegate> delegate;

// FCL style: the preferred version of the current profile is passed in
// AssetVersionViewController preselects the matching chip and moves the matching version to the top
// Note: asset types (resource pack/data pack/world) have no loader, so there is no preferredLoader
// Phase 3 alignment: add the preferred properties that were missing compared with ModVersionViewController
@property (nonatomic, copy, nullable) NSString *preferredGameVersion;

// --- Project display information (for the detail header, passed in by DownloadViewController) ---
// Fills the gap where earlier version pages showed no project cover image, title, author, downloads, tags or description
@property (nonatomic, copy, nullable) NSString *projectIconURL;
@property (nonatomic, copy, nullable) NSString *projectAuthor;
@property (nonatomic, strong, nullable) NSNumber *projectDownloads;
@property (nonatomic, strong, nullable) NSNumber *projectLikes;
@property (nonatomic, copy, nullable) NSString *projectDescription;
@property (nonatomic, strong, nullable) NSArray<NSString *> *projectCategories;
@property (nonatomic, copy, nullable) NSString *projectLastUpdated;

@end

NS_ASSUME_NONNULL_END
