//
//  ShaderTableViewCell.h
//  Amethyst
//
//  Custom table view cell for displaying shader information
//

#import <UIKit/UIKit.h>
@class ShaderItem;

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSInteger, ShaderTableViewCellDisplayMode) {
    ShaderTableViewCellDisplayModeLocal,
    ShaderTableViewCellDisplayModeOnline
};

@protocol ShaderTableViewCellDelegate <NSObject>
- (void)shaderCellDidTapToggle:(UITableViewCell *)cell;
- (void)shaderCellDidTapOpenLink:(UITableViewCell *)cell;
@optional
- (void)shaderCellDidTapDownload:(UITableViewCell *)cell;
@end

@interface ShaderTableViewCell : UITableViewCell

// --- UI Elements ---
@property (nonatomic, strong) UIImageView *shaderIconView;
@property (nonatomic, strong) UILabel *nameLabel;
@property (nonatomic, strong) UILabel *shaderVersionLabel;
@property (nonatomic, strong) UILabel *gameVersionLabel;
@property (nonatomic, strong) UILabel *authorLabel;
@property (nonatomic, strong) UILabel *descLabel;
@property (nonatomic, strong) UILabel *statsLabel;
@property (nonatomic, strong) UILabel *categoryLabel;

// --- Action Buttons ---
@property (nonatomic, strong) UISwitch *enableSwitch;
@property (nonatomic, strong) UIButton *downloadButton;
@property (nonatomic, strong) UIButton *openLinkButton;

@property (nonatomic, weak) id<ShaderTableViewCellDelegate> delegate;

// --- Configuration ---
- (void)configureWithShader:(ShaderItem *)shader displayMode:(ShaderTableViewCellDisplayMode)mode;

// --- State Updates ---
- (void)updateToggleState:(BOOL)disabled;

@end

NS_ASSUME_NONNULL_END