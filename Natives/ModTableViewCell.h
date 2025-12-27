#import <UIKit/UIKit.h>
@class ModItem;

NS_ASSUME_NONNULL_BEGIN

// Display mode for the cell
typedef NS_ENUM(NSInteger, ModTableViewCellDisplayMode) {
    ModTableViewCellDisplayModeLocal,
    ModTableViewCellDisplayModeOnline
};

@protocol ModTableViewCellDelegate <NSObject>
- (void)modCellDidTapToggle:(UITableViewCell *)cell;
- (void)modCellDidTapOpenLink:(UITableViewCell *)cell;
@optional // Optional because it's only for online mode
- (void)modCellDidTapDownload:(UITableViewCell *)cell;
@end

@interface ModTableViewCell : UITableViewCell

// --- UI Elements ---
@property (nonatomic, strong) UIImageView *modIconView;
@property (nonatomic, strong) UILabel *nameLabel;
@property (nonatomic, strong) UILabel *modVersionLabel;
@property (nonatomic, strong) UILabel *gameVersionLabel;
@property (nonatomic, strong) UILabel *authorLabel; // For online author
@property (nonatomic, strong) UILabel *descLabel;
@property (nonatomic, strong) UILabel *statsLabel; // For downloads, likes, etc.
@property (nonatomic, strong) UILabel *categoryLabel; // For categories
@property (nonatomic, strong) UIStackView *loaderBadgesStackView; // Container for loader icons

// --- Action Buttons ---
@property (nonatomic, strong) UISwitch *enableSwitch;
@property (nonatomic, strong) UIButton *downloadButton; // For online mode
@property (nonatomic, strong) UIButton *openLinkButton;

@property (nonatomic, weak) id<ModTableViewCellDelegate> delegate;

// --- Configuration ---
- (void)configureWithMod:(ModItem *)mod displayMode:(ModTableViewCellDisplayMode)mode;

// --- State Updates ---
- (void)updateToggleState:(BOOL)disabled;

@end

NS_ASSUME_NONNULL_END
