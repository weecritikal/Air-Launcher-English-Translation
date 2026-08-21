//
//  ModLoaderIconHelper.h
//  Flux
//
//  Unified mod loader icon helper
// Following the loader icon systems of FCL/ZL2, this unifies the three parallel ways loaders were represented in this project:
//   1. PNG images (the ModLoaderIcons/ folder, which already has dark/light versions for fabric/forge/neoforge)
//   2. SF Symbols (used by VersionManagerViewController/ModLoaderInstallViewController, with inconsistent colors)
//   3. Text-only pill badges (ModVersionTableViewCell/ShaderVersionTableViewCell/AssetDetailHeaderView/DownloadViewController)
// This helper unifies all three behind one entry point, preferring the official PNG icons in the bundle
// and falling back to an SF Symbol shaped like the official logo plus the official brand color, so the whole project looks consistent.
//
// The loader brand colors follow each loader's official brand guidelines:
//   fabric   = #5B8DF9 (official blue)
//   quilt    = #D668AC (official purple-pink)
//   forge    = #8B5A2B (official brown)
//   neoforge = #E0732B (official orange)
//   optifine = #E6991A (official yellow)
//   iris     = #4DA6F2 (official light blue)
//   rift     = #33B280 (official green)
//   vanilla  = #66CC66 (vanilla green)
//

#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

@interface ModLoaderIconHelper : NSObject

/// Get the official brand color for a loader name (one palette shared across the project)
/// Recognizes the fabric/quilt/forge/neoforge/optifine/optifabric/iris/rift/vanilla keywords
/// @param loader The loader name (case-insensitive, matched as a substring, so "fabric-loader" is recognized too)
/// @return The official brand color, or the system secondary label color when unrecognized
+ (UIColor *)brandColorForLoader:(NSString *)loader;

/// Get the SF Symbol name for a loader (a symbol shaped like the official logo)
/// Used as a fallback when the bundle has no matching PNG
+ (NSString *)symbolNameForLoader:(NSString *)loader;

/// Get the localized display name of a loader (for the badge text)
+ (NSString *)displayNameForLoader:(NSString *)loader;

/// Load a loader icon (preferring a bundled PNG, falling back to an SF Symbol)
/// Picks the dark/light PNG automatically from the userInterfaceStyle of the traitCollection
/// @param loader The loader name
/// @param traitCollection The current traitCollection (used to decide light/dark); nil means light
/// @return The loader icon as a UIImage (a PNG or an SF Symbol), or nil when unrecognized
+ (nullable UIImage *)iconImageForLoader:(NSString *)loader
                         traitCollection:(nullable UITraitCollection *)traitCollection;

/// Configure a UIImageView to show a loader icon
/// Sets image, tintColor (tinting SF Symbols, leaving PNGs in their own colors) and contentMode automatically
/// @param imageView The UIImageView to configure
/// @param loader The loader name
/// @param traitCollection The current traitCollection
+ (void)configureImageView:(UIImageView *)imageView
                forLoader:(NSString *)loader
           traitCollection:(nullable UITraitCollection *)traitCollection;

/// Build a loader badge view (an icon + text pill, following the loader tags of FCL/ZL2)
/// The icon prefers a PNG and the text comes from displayNameForLoader:
/// @param loader The loader name
/// @param traitCollection The current traitCollection
/// @return The configured UIView (icon and text laid out horizontally)
+ (UIView *)createBadgeViewForLoader:(NSString *)loader
                      traitCollection:(nullable UITraitCollection *)traitCollection;

/// Build an icon-only badge (no text, just the icon on a rounded brand-colored background, in the ZL2 LittleTextLabel style)
/// For tight spaces, such as the small loader icon on the right of a version row
/// @param loader The loader name
/// @param traitCollection The current traitCollection
/// @param size Icon size (18pt by default)
+ (UIView *)createIconBadgeForLoader:(NSString *)loader
                      traitCollection:(nullable UITraitCollection *)traitCollection
                                size:(CGFloat)size;

/// Whether a loader name is a known loader (used to filter what is shown)
+ (BOOL)isKnownLoader:(NSString *)loader;

/// Detect the loader type from a version ID string
/// For example "1.20.1-Fabric-0.15.7" -> "fabric" and "1.20.1-forge-47.2.0" -> "forge"
+ (nullable NSString *)detectLoaderFromVersionId:(NSString *)versionId;

@end

NS_ASSUME_NONNULL_END
