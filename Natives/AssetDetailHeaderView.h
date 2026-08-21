//
//  AssetDetailHeaderView.h
//  Flux
//
//  Header view for the asset detail page (modelled on the project detail header in FCL/ZL2)
//
//  Purpose: used as the tableView.tableHeaderView of ModVersionViewController / ShaderVersionViewController /
//  AssetVersionViewController, showing the full project information at the top when the user opens the version picker:
//    - Project cover image (72x72, rounded, loaded via AFNetworking with an SF Symbol placeholder)
//    - Project title (18pt bold, at most 2 lines)
//    - Author (with a person.crop.circle icon)
//    - Meta row: downloads / follows / last updated (with SF Symbol icons)
//    - Tag row: colored category pills (modelled on ZL2 LittleTextLabel)
//    - Description area: 3 lines by default, with an "Expand/Collapse" button when longer
//
//  Design goals:
//    1. Fill the "show the information plus the matching image" gap (earlier version pages had no project info or cover image at all)
//    2. Match ModernAssetCell / ModVersionTableViewCell visually (rounded card + light shadow + frosted glass)
//    3. Support expanding/collapsing the description and notify the controller via onSizeChanged so it can update the tableHeaderView height
//

#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

@interface AssetDetailHeaderView : UIView

/// Size-change callback (fired when the description expands/collapses; the controller must recompute the tableHeaderView height here)
@property (nonatomic, copy, nullable) void (^onSizeChanged)(void);

/// Configure the header content
/// @param iconURL Project cover image URL (may be nil, in which case a placeholder SF Symbol is shown)
/// @param title Project title
/// @param author Author (may be nil)
/// @param downloads Download count (may be nil)
/// @param likes Follow/like count (may be nil)
/// @param descriptionText Project description (may be nil)
/// @param categories Array of categories/tags (colored pills, may be nil)
/// @param lastUpdated Last updated time (an ISO8601 string, or any displayable string; may be nil)
/// @param placeholderSymbolName Name of the placeholder SF Symbol shown when there is no cover image (e.g. "puzzlepiece.extension.fill")
/// @param placeholderColor Accent color of the placeholder icon (matching the asset type)
- (void)configureWithIconURL:(nullable NSString *)iconURL
                       title:(NSString *)title
                      author:(nullable NSString *)author
                   downloads:(nullable NSNumber *)downloads
                       likes:(nullable NSNumber *)likes
             descriptionText:(nullable NSString *)descriptionText
                 categories:(nullable NSArray<NSString *> *)categories
                lastUpdated:(nullable NSString *)lastUpdated
        placeholderSymbolName:(NSString *)placeholderSymbolName
            placeholderColor:(UIColor *)placeholderColor;

/// Compute the height this header needs at the given width (used to set the tableHeaderView frame)
/// @param width Target width (usually tableView.bounds.size.width)
- (CGFloat)fittingHeightForWidth:(CGFloat)width;

@end

NS_ASSUME_NONNULL_END
