#import "VersionManagerViewController.h"
#import "BackgroundManager.h"
#import "PLProfiles.h"
#import "ProfileSettingsViewController.h"
#import "ModsManagerViewController.h"
#import "ShadersManagerViewController.h"
#import "ResourcePacksManagerViewController.h"
#import "DataPacksManagerViewController.h"
#import "WorldsManagerViewController.h"
#import "LauncherPreferences.h"
#import "ScreenUtils.h"
#import "utils.h"
#import "ModLoaderIconHelper.h"
#import "ModpackExportService.h" // for parseVersionId:
#import <QuartzCore/QuartzCore.h>
#import "FluxTheme.h"

// Section indices: 2 sections (game directory / installed versions)
// Redesign highlights (modeled 100% on FCL):
//   1. The version management screen only shows: the game directory switcher + the installed version list
//   2. Renderer, graphics API, mod/shader/resource pack management and so on have all moved to the "per-version settings page" (ProfileSettingsViewController)
//      Tapping a version card goes straight to that version's dedicated settings page, and the settings apply only to that version (FCL style)
//   3. The old UI (LauncherPrefGameDirViewController / LauncherProfileEditorViewController) is never invoked
//   4. The game directory card supports a long-press context menu (switch/delete the current directory)
//   5. accentColor() and a frosted glass background are used consistently, matching the launcher's new UI
static NSInteger const kSectionGameDir     = 0;
static NSInteger const kSectionVersions    = 1;

#pragma mark - Modern Tile Base Cell

@interface VMTileBaseCell : UICollectionViewCell
@property (nonatomic, strong) UIView *contentContainer;
- (void)setupViews;
@end

@implementation VMTileBaseCell

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        [self setupViews];
    }
    return self;
}

- (void)setupViews {
    // Shadow: the shadow tier from spec 5.2 (0.12, 6, (0,3))
    self.layer.shadowColor = [UIColor blackColor].CGColor;
    self.layer.shadowOffset = CGSizeMake(0, 3);
    self.layer.shadowOpacity = 0.12;
    self.layer.shadowRadius = 6;
    self.layer.masksToBounds = NO;

    self.contentContainer = [[UIView alloc] initWithFrame:self.contentView.bounds];
    self.contentContainer.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    // Spec 5.1: L2 standard card with a 12pt corner radius + continuous corners
    self.contentContainer.layer.cornerRadius = 12;
    self.contentContainer.layer.cornerCurve = kCACornerCurveContinuous;
    self.contentContainer.layer.masksToBounds = YES;
    // Spec 6.2: layer 1, a light translucent base
    self.contentContainer.backgroundColor = [[UIColor whiteColor] colorWithAlphaComponent:0.08];
    // Spec 5.3: default card stroke, 0.5pt white at 0.10
    self.contentContainer.layer.borderWidth = 0.5;
    self.contentContainer.layer.borderColor = [[UIColor whiteColor] colorWithAlphaComponent:0.10].CGColor;
    [self.contentView addSubview:self.contentContainer];

    // Spec 6.2: layer 2, BackgroundManager frosted glass
    [[BackgroundManager sharedManager] applyEffectToCollectionViewCell:self];
}

- (void)touchesBegan:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    [super touchesBegan:touches withEvent:event];
    [UIView animateWithDuration:0.25 delay:0 usingSpringWithDamping:0.7 initialSpringVelocity:0.8 options:UIViewAnimationOptionAllowUserInteraction animations:^{
        self.transform = CGAffineTransformMakeScale(0.96, 0.96);
    } completion:nil];
}

- (void)touchesEnded:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    [super touchesEnded:touches withEvent:event];
    [UIView animateWithDuration:0.25 delay:0 usingSpringWithDamping:0.7 initialSpringVelocity:0.8 options:UIViewAnimationOptionAllowUserInteraction animations:^{
        self.transform = CGAffineTransformIdentity;
    } completion:nil];
}

- (void)touchesCancelled:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    [super touchesCancelled:touches withEvent:event];
    [UIView animateWithDuration:0.25 delay:0 usingSpringWithDamping:0.7 initialSpringVelocity:0.8 options:UIViewAnimationOptionAllowUserInteraction animations:^{
        self.transform = CGAffineTransformIdentity;
    } completion:nil];
}

@end

#pragma mark - Quick Action Tile Cell

@interface VMQuickActionCell : VMTileBaseCell
@property (nonatomic, strong) UIImageView *iconView;
@property (nonatomic, strong) UILabel *titleLabel;
@property (nonatomic, strong) UILabel *subtitleLabel;
@end

@implementation VMQuickActionCell

- (void)setupViews {
    [super setupViews];

    CGFloat iconSize = [ScreenUtils dp:24];
    CGFloat titleFont = [ScreenUtils sp:13];

    self.iconView = [[UIImageView alloc] init];
    self.iconView.translatesAutoresizingMaskIntoConstraints = NO;
    self.iconView.contentMode = UIViewContentModeScaleAspectFit;
    [self.contentContainer addSubview:self.iconView];

    self.titleLabel = [[UILabel alloc] init];
    self.titleLabel.translatesAutoresizingMaskIntoConstraints = NO;
    self.titleLabel.font = [UIFont systemFontOfSize:titleFont weight:UIFontWeightSemibold];
    self.titleLabel.textColor = [UIColor whiteColor];
    self.titleLabel.adjustsFontForContentSizeCategory = NO;
    [self.contentContainer addSubview:self.titleLabel];

    self.subtitleLabel = [[UILabel alloc] init];
    self.subtitleLabel.translatesAutoresizingMaskIntoConstraints = NO;
    self.subtitleLabel.font = [UIFont systemFontOfSize:[ScreenUtils sp:10] weight:UIFontWeightRegular];
    self.subtitleLabel.textColor = [[UIColor whiteColor] colorWithAlphaComponent:0.6];
    self.subtitleLabel.numberOfLines = 0;
    self.subtitleLabel.lineBreakMode = NSLineBreakByWordWrapping;
    self.subtitleLabel.adjustsFontForContentSizeCategory = NO;
    [self.contentContainer addSubview:self.subtitleLabel];

    [NSLayoutConstraint activateConstraints:@[
        [self.iconView.topAnchor constraintEqualToAnchor:self.contentContainer.topAnchor constant:12],
        [self.iconView.leadingAnchor constraintEqualToAnchor:self.contentContainer.leadingAnchor constant:12],
        [self.iconView.widthAnchor constraintEqualToConstant:iconSize],
        [self.iconView.heightAnchor constraintEqualToConstant:iconSize],
        [self.titleLabel.topAnchor constraintEqualToAnchor:self.iconView.bottomAnchor constant:8],
        [self.titleLabel.leadingAnchor constraintEqualToAnchor:self.contentContainer.leadingAnchor constant:12],
        [self.titleLabel.trailingAnchor constraintEqualToAnchor:self.contentContainer.trailingAnchor constant:-12],
        [self.subtitleLabel.topAnchor constraintEqualToAnchor:self.titleLabel.bottomAnchor constant:2],
        [self.subtitleLabel.leadingAnchor constraintEqualToAnchor:self.contentContainer.leadingAnchor constant:12],
        [self.subtitleLabel.trailingAnchor constraintEqualToAnchor:self.contentContainer.trailingAnchor constant:-12],
        [self.subtitleLabel.bottomAnchor constraintLessThanOrEqualToAnchor:self.contentContainer.bottomAnchor constant:-10]
    ]];
}

- (void)configureWithIcon:(NSString *)iconName title:(NSString *)title subtitle:(NSString *)subtitle color:(UIColor *)color {
    self.iconView.image = [UIImage systemImageNamed:iconName];
    self.iconView.tintColor = color;
    self.titleLabel.text = title;
    self.subtitleLabel.text = subtitle;
}

@end

#pragma mark - Version Card Cell

@interface VMVersionCardCell : VMTileBaseCell
@property (nonatomic, strong) UIView *iconContainer;
@property (nonatomic, strong) UIImageView *iconView;
@property (nonatomic, strong) UILabel *nameLabel;
@property (nonatomic, strong) UILabel *versionLabel;
@property (nonatomic, strong) UILabel *lastPlayedLabel;
@property (nonatomic, strong) UIView *selectedBadge;
@property (nonatomic, strong) UILabel *isolatedBadge;
@property (nonatomic, strong) UIImageView *chevronView;
@end

@implementation VMVersionCardCell

- (void)setupViews {
    [super setupViews];

    CGFloat iconBoxSize = [ScreenUtils dp:34];
    CGFloat iconSize = [ScreenUtils dp:20];
    CGFloat nameFont = [ScreenUtils sp:15];

    // Spec 8.2: the icon must sit inside a rounded container with the type color
    self.iconContainer = [[UIView alloc] init];
    self.iconContainer.translatesAutoresizingMaskIntoConstraints = NO;
    self.iconContainer.layer.cornerRadius = 9;
    self.iconContainer.layer.cornerCurve = kCACornerCurveContinuous;
    self.iconContainer.backgroundColor = FluxTheme.accent;
    [self.contentContainer addSubview:self.iconContainer];

    self.iconView = [[UIImageView alloc] init];
    self.iconView.translatesAutoresizingMaskIntoConstraints = NO;
    self.iconView.contentMode = UIViewContentModeScaleAspectFit;
    self.iconView.image = [UIImage systemImageNamed:@"cube.box.fill"];
    self.iconView.tintColor = [UIColor whiteColor];
    [self.iconContainer addSubview:self.iconView];

    self.nameLabel = [[UILabel alloc] init];
    self.nameLabel.translatesAutoresizingMaskIntoConstraints = NO;
    self.nameLabel.font = [UIFont systemFontOfSize:nameFont weight:UIFontWeightSemibold];
    // Spec 2.1: system colors are mandatory
    self.nameLabel.textColor = [UIColor labelColor];
    self.nameLabel.numberOfLines = 1;
    self.nameLabel.adjustsFontForContentSizeCategory = NO;
    [self.contentContainer addSubview:self.nameLabel];

    self.versionLabel = [[UILabel alloc] init];
    self.versionLabel.translatesAutoresizingMaskIntoConstraints = NO;
    self.versionLabel.font = [UIFont systemFontOfSize:[ScreenUtils sp:11] weight:UIFontWeightRegular];
    // Spec 2.1: secondary text uses secondaryLabelColor
    self.versionLabel.textColor = [UIColor secondaryLabelColor];
    self.versionLabel.adjustsFontForContentSizeCategory = NO;
    [self.contentContainer addSubview:self.versionLabel];

    self.lastPlayedLabel = [[UILabel alloc] init];
    self.lastPlayedLabel.translatesAutoresizingMaskIntoConstraints = NO;
    self.lastPlayedLabel.font = [UIFont systemFontOfSize:[ScreenUtils sp:10] weight:UIFontWeightRegular];
    // Spec 2.1: meta text uses tertiaryLabelColor
    self.lastPlayedLabel.textColor = [UIColor tertiaryLabelColor];
    self.lastPlayedLabel.text = @"";
    self.lastPlayedLabel.adjustsFontForContentSizeCategory = NO;
    [self.contentContainer addSubview:self.lastPlayedLabel];

    // Spec 9.1: selected state badge (second reinforcement layer)
    self.selectedBadge = [[UIView alloc] init];
    self.selectedBadge.translatesAutoresizingMaskIntoConstraints = NO;
    self.selectedBadge.backgroundColor = accentColor();
    self.selectedBadge.layer.cornerRadius = 10;
    self.selectedBadge.layer.cornerCurve = kCACornerCurveContinuous;
    self.selectedBadge.hidden = YES;
    [self.contentContainer addSubview:self.selectedBadge];

    UIImageView *checkmark = [[UIImageView alloc] init];
    checkmark.translatesAutoresizingMaskIntoConstraints = NO;
    checkmark.image = [UIImage systemImageNamed:@"checkmark" withConfiguration:[UIImageSymbolConfiguration configurationWithPointSize:9 weight:UIFontWeightBold]];
    checkmark.tintColor = [UIColor whiteColor];
    [self.selectedBadge addSubview:checkmark];

    self.isolatedBadge = [[UILabel alloc] init];
    self.isolatedBadge.translatesAutoresizingMaskIntoConstraints = NO;
    self.isolatedBadge.font = [UIFont systemFontOfSize:9 weight:UIFontWeightSemibold];
    self.isolatedBadge.textColor = [UIColor whiteColor];
    self.isolatedBadge.backgroundColor = [UIColor systemTealColor];
    self.isolatedBadge.textAlignment = NSTextAlignmentCenter;
    self.isolatedBadge.layer.cornerRadius = 8;
    self.isolatedBadge.layer.cornerCurve = kCACornerCurveContinuous;
    self.isolatedBadge.layer.masksToBounds = YES;
    self.isolatedBadge.text = @" Isolated ";
    self.isolatedBadge.hidden = YES;
    [self.contentContainer addSubview:self.isolatedBadge];

    // Spec 9.4: the chevron hints that it is tappable
    self.chevronView = [[UIImageView alloc] init];
    self.chevronView.translatesAutoresizingMaskIntoConstraints = NO;
    self.chevronView.image = [UIImage systemImageNamed:@"chevron.right" withConfiguration:[UIImageSymbolConfiguration configurationWithPointSize:12 weight:UIFontWeightSemibold]];
    self.chevronView.tintColor = [UIColor tertiaryLabelColor];
    [self.contentContainer addSubview:self.chevronView];

    [NSLayoutConstraint activateConstraints:@[
        [self.iconContainer.leadingAnchor constraintEqualToAnchor:self.contentContainer.leadingAnchor constant:14],
        [self.iconContainer.centerYAnchor constraintEqualToAnchor:self.contentContainer.centerYAnchor],
        [self.iconContainer.widthAnchor constraintEqualToConstant:iconBoxSize],
        [self.iconContainer.heightAnchor constraintEqualToConstant:iconBoxSize],
        [self.iconView.centerXAnchor constraintEqualToAnchor:self.iconContainer.centerXAnchor],
        [self.iconView.centerYAnchor constraintEqualToAnchor:self.iconContainer.centerYAnchor],
        [self.iconView.widthAnchor constraintEqualToConstant:iconSize],
        [self.iconView.heightAnchor constraintEqualToConstant:iconSize],
        [self.nameLabel.leadingAnchor constraintEqualToAnchor:self.iconContainer.trailingAnchor constant:10],
        [self.nameLabel.topAnchor constraintEqualToAnchor:self.contentContainer.topAnchor constant:14],
        [self.nameLabel.trailingAnchor constraintEqualToAnchor:self.chevronView.leadingAnchor constant:-8],
        [self.versionLabel.leadingAnchor constraintEqualToAnchor:self.nameLabel.leadingAnchor],
        [self.versionLabel.topAnchor constraintEqualToAnchor:self.nameLabel.bottomAnchor constant:3],
        [self.versionLabel.trailingAnchor constraintEqualToAnchor:self.chevronView.leadingAnchor constant:-8],
        [self.lastPlayedLabel.leadingAnchor constraintEqualToAnchor:self.nameLabel.leadingAnchor],
        [self.lastPlayedLabel.topAnchor constraintEqualToAnchor:self.versionLabel.bottomAnchor constant:2],
        [self.lastPlayedLabel.trailingAnchor constraintEqualToAnchor:self.isolatedBadge.leadingAnchor constant:-6],
        [self.isolatedBadge.centerYAnchor constraintEqualToAnchor:self.lastPlayedLabel.centerYAnchor],
        [self.isolatedBadge.trailingAnchor constraintEqualToAnchor:self.chevronView.leadingAnchor constant:-8],
        [self.isolatedBadge.heightAnchor constraintEqualToConstant:16],
        [self.chevronView.trailingAnchor constraintEqualToAnchor:self.contentContainer.trailingAnchor constant:-14],
        [self.chevronView.centerYAnchor constraintEqualToAnchor:self.contentContainer.centerYAnchor],
        [self.chevronView.widthAnchor constraintEqualToConstant:12],
        [self.chevronView.heightAnchor constraintEqualToConstant:12],
        [self.selectedBadge.trailingAnchor constraintEqualToAnchor:self.contentContainer.trailingAnchor constant:-14],
        [self.selectedBadge.topAnchor constraintEqualToAnchor:self.contentContainer.topAnchor constant:10],
        [self.selectedBadge.widthAnchor constraintEqualToConstant:20],
        [self.selectedBadge.heightAnchor constraintEqualToConstant:20],
        [checkmark.centerXAnchor constraintEqualToAnchor:self.selectedBadge.centerXAnchor],
        [checkmark.centerYAnchor constraintEqualToAnchor:self.selectedBadge.centerYAnchor]
    ]];
}

- (void)configureWithName:(NSString *)name version:(NSString *)version isSelected:(BOOL)isSelected isolated:(BOOL)isolated lastPlayed:(NSString *)lastPlayed {
    self.nameLabel.text = name;
    self.versionLabel.text = version ?: @"Unknown version";
    self.selectedBadge.hidden = !isSelected;
    self.selectedBadge.backgroundColor = accentColor();
    self.isolatedBadge.hidden = !isolated;
    self.lastPlayedLabel.text = lastPlayed.length > 0 ? lastPlayed : @"";

    NSString *detectedLoader = [ModLoaderIconHelper detectLoaderFromVersionId:version];
    if (detectedLoader) {
        [ModLoaderIconHelper configureImageView:self.iconView
                                      forLoader:detectedLoader
                                 traitCollection:self.traitCollection];
        // Spec 2.6: the loader brand color is used as the icon container background
        self.iconContainer.backgroundColor = [ModLoaderIconHelper brandColorForLoader:detectedLoader];
    } else {
        self.iconView.image = [UIImage systemImageNamed:@"cube.box.fill"];
        self.iconView.tintColor = [UIColor whiteColor];
        self.iconContainer.backgroundColor = FluxTheme.accent;
    }

    // Spec 9.1: three-layer reinforcement of the selected state (border + badge + background color)
    if (isSelected) {
        self.contentContainer.layer.borderColor = accentColor().CGColor;
        self.contentContainer.layer.borderWidth = 1.5;
        self.contentContainer.backgroundColor = [accentColor() colorWithAlphaComponent:0.10];
        self.chevronView.tintColor = accentColor();
    } else {
        self.contentContainer.layer.borderColor = [[UIColor whiteColor] colorWithAlphaComponent:0.10].CGColor;
        self.contentContainer.layer.borderWidth = 0.5;
        self.contentContainer.backgroundColor = [[UIColor whiteColor] colorWithAlphaComponent:0.08];
        self.chevronView.tintColor = [UIColor tertiaryLabelColor];
    }
}

@end

#pragma mark - Game Directory Cell (FCL style version isolation card)

@interface VMGameDirCell : VMTileBaseCell
@property (nonatomic, strong) UIView *iconContainer;
@property (nonatomic, strong) UIImageView *iconView;
@property (nonatomic, strong) UILabel *nameLabel;
@property (nonatomic, strong) UILabel *detailLabel;
@property (nonatomic, strong) UIView *selectedBadge;
@property (nonatomic, strong) UIImageView *chevronView;
@end

@implementation VMGameDirCell

- (void)setupViews {
    [super setupViews];

    CGFloat iconBoxSize = [ScreenUtils dp:28];
    CGFloat iconSize = [ScreenUtils dp:16];
    CGFloat nameFont = [ScreenUtils sp:13];

    // Spec 8.2: icon container
    self.iconContainer = [[UIView alloc] init];
    self.iconContainer.translatesAutoresizingMaskIntoConstraints = NO;
    self.iconContainer.layer.cornerRadius = 8;
    self.iconContainer.layer.cornerCurve = kCACornerCurveContinuous;
    self.iconContainer.backgroundColor = FluxTheme.accent;
    [self.contentContainer addSubview:self.iconContainer];

    self.iconView = [[UIImageView alloc] init];
    self.iconView.translatesAutoresizingMaskIntoConstraints = NO;
    self.iconView.contentMode = UIViewContentModeScaleAspectFit;
    self.iconView.image = [UIImage systemImageNamed:@"folder.fill"];
    self.iconView.tintColor = [UIColor whiteColor];
    [self.iconContainer addSubview:self.iconView];

    self.nameLabel = [[UILabel alloc] init];
    self.nameLabel.translatesAutoresizingMaskIntoConstraints = NO;
    self.nameLabel.font = [UIFont systemFontOfSize:nameFont weight:UIFontWeightSemibold];
    // Spec 2.1: system colors
    self.nameLabel.textColor = [UIColor labelColor];
    self.nameLabel.numberOfLines = 1;
    self.nameLabel.adjustsFontForContentSizeCategory = NO;
    [self.contentContainer addSubview:self.nameLabel];

    self.detailLabel = [[UILabel alloc] init];
    self.detailLabel.translatesAutoresizingMaskIntoConstraints = NO;
    self.detailLabel.font = [UIFont systemFontOfSize:[ScreenUtils sp:10] weight:UIFontWeightRegular];
    // Spec 2.1: secondary text uses secondaryLabelColor
    self.detailLabel.textColor = [UIColor secondaryLabelColor];
    self.detailLabel.numberOfLines = 0;
    self.detailLabel.lineBreakMode = NSLineBreakByWordWrapping;
    self.detailLabel.adjustsFontForContentSizeCategory = NO;
    [self.contentContainer addSubview:self.detailLabel];

    self.selectedBadge = [[UIView alloc] init];
    self.selectedBadge.translatesAutoresizingMaskIntoConstraints = NO;
    self.selectedBadge.backgroundColor = accentColor();
    self.selectedBadge.layer.cornerRadius = 9;
    self.selectedBadge.layer.cornerCurve = kCACornerCurveContinuous;
    self.selectedBadge.hidden = YES;
    [self.contentContainer addSubview:self.selectedBadge];

    UIImageView *checkmark = [[UIImageView alloc] init];
    checkmark.translatesAutoresizingMaskIntoConstraints = NO;
    checkmark.image = [UIImage systemImageNamed:@"checkmark" withConfiguration:[UIImageSymbolConfiguration configurationWithPointSize:8 weight:UIFontWeightBold]];
    checkmark.tintColor = [UIColor whiteColor];
    [self.selectedBadge addSubview:checkmark];

    // Spec 9.4: the chevron hints that it is tappable
    self.chevronView = [[UIImageView alloc] init];
    self.chevronView.translatesAutoresizingMaskIntoConstraints = NO;
    self.chevronView.image = [UIImage systemImageNamed:@"chevron.right" withConfiguration:[UIImageSymbolConfiguration configurationWithPointSize:11 weight:UIFontWeightSemibold]];
    self.chevronView.tintColor = [UIColor tertiaryLabelColor];
    [self.contentContainer addSubview:self.chevronView];

    [NSLayoutConstraint activateConstraints:@[
        [self.iconContainer.leadingAnchor constraintEqualToAnchor:self.contentContainer.leadingAnchor constant:10],
        [self.iconContainer.centerYAnchor constraintEqualToAnchor:self.contentContainer.centerYAnchor],
        [self.iconContainer.widthAnchor constraintEqualToConstant:iconBoxSize],
        [self.iconContainer.heightAnchor constraintEqualToConstant:iconBoxSize],
        [self.iconView.centerXAnchor constraintEqualToAnchor:self.iconContainer.centerXAnchor],
        [self.iconView.centerYAnchor constraintEqualToAnchor:self.iconContainer.centerYAnchor],
        [self.iconView.widthAnchor constraintEqualToConstant:iconSize],
        [self.iconView.heightAnchor constraintEqualToConstant:iconSize],
        [self.nameLabel.leadingAnchor constraintEqualToAnchor:self.iconContainer.trailingAnchor constant:8],
        [self.nameLabel.topAnchor constraintEqualToAnchor:self.contentContainer.topAnchor constant:8],
        [self.nameLabel.trailingAnchor constraintEqualToAnchor:self.chevronView.leadingAnchor constant:-6],
        [self.detailLabel.leadingAnchor constraintEqualToAnchor:self.nameLabel.leadingAnchor],
        [self.detailLabel.topAnchor constraintEqualToAnchor:self.nameLabel.bottomAnchor constant:2],
        [self.detailLabel.trailingAnchor constraintEqualToAnchor:self.chevronView.leadingAnchor constant:-6],
        [self.detailLabel.bottomAnchor constraintLessThanOrEqualToAnchor:self.contentContainer.bottomAnchor constant:-8],
        [self.selectedBadge.trailingAnchor constraintEqualToAnchor:self.contentContainer.trailingAnchor constant:-10],
        [self.selectedBadge.topAnchor constraintEqualToAnchor:self.contentContainer.topAnchor constant:8],
        [self.selectedBadge.widthAnchor constraintEqualToConstant:18],
        [self.selectedBadge.heightAnchor constraintEqualToConstant:18],
        [self.chevronView.trailingAnchor constraintEqualToAnchor:self.contentContainer.trailingAnchor constant:-10],
        [self.chevronView.centerYAnchor constraintEqualToAnchor:self.contentContainer.centerYAnchor],
        [self.chevronView.widthAnchor constraintEqualToConstant:11],
        [self.chevronView.heightAnchor constraintEqualToConstant:11],
        [checkmark.centerXAnchor constraintEqualToAnchor:self.selectedBadge.centerXAnchor],
        [checkmark.centerYAnchor constraintEqualToAnchor:self.selectedBadge.centerYAnchor]
    ]];
}

- (void)configureWithName:(NSString *)name detail:(NSString *)detail isSelected:(BOOL)isSelected isAddButton:(BOOL)isAddButton {
    if (isAddButton) {
        self.iconView.image = [UIImage systemImageNamed:@"plus"];
        self.iconView.tintColor = [UIColor whiteColor];
        self.iconContainer.backgroundColor = [UIColor systemGreenColor];
        self.nameLabel.text = @"New directory";
        self.detailLabel.text = @"Create a new isolated version directory";
        self.selectedBadge.hidden = YES;
        self.chevronView.hidden = YES;
        // Spec 5.3: recommended state stroke, 1.0pt accentColor at 0.4
        self.contentContainer.layer.borderColor = [[UIColor systemGreenColor] colorWithAlphaComponent:0.6].CGColor;
        self.contentContainer.layer.borderWidth = 1.0;
        self.contentContainer.backgroundColor = [[UIColor systemGreenColor] colorWithAlphaComponent:0.08];
        return;
    }

    self.chevronView.hidden = NO;
    self.iconView.image = [UIImage systemImageNamed:@"folder.fill"];
    self.iconView.tintColor = [UIColor whiteColor];
    self.iconContainer.backgroundColor = FluxTheme.accent;
    self.nameLabel.text = name;
    self.detailLabel.text = detail ?: @"";
    self.selectedBadge.hidden = !isSelected;
    self.selectedBadge.backgroundColor = accentColor();

    // Spec 9.1: three-layer reinforcement of the selected state
    if (isSelected) {
        self.contentContainer.layer.borderColor = accentColor().CGColor;
        self.contentContainer.layer.borderWidth = 1.5;
        self.contentContainer.backgroundColor = [accentColor() colorWithAlphaComponent:0.10];
        self.chevronView.tintColor = accentColor();
    } else {
        self.contentContainer.layer.borderColor = [[UIColor whiteColor] colorWithAlphaComponent:0.10].CGColor;
        self.contentContainer.layer.borderWidth = 0.5;
        self.contentContainer.backgroundColor = [[UIColor whiteColor] colorWithAlphaComponent:0.08];
        self.chevronView.tintColor = [UIColor tertiaryLabelColor];
    }
}

@end

#pragma mark - Renderer Card Cell (graphics API selection card, FCL style)

@interface VMRendererCell : VMTileBaseCell
@property (nonatomic, strong) UIImageView *iconView;
@property (nonatomic, strong) UILabel *nameLabel;
@property (nonatomic, strong) UILabel *descLabel;
@property (nonatomic, strong) UIView *selectedBadge;
@end

@implementation VMRendererCell

- (void)setupViews {
    [super setupViews];

    CGFloat iconSize = [ScreenUtils dp:22];

    self.iconView = [[UIImageView alloc] init];
    self.iconView.translatesAutoresizingMaskIntoConstraints = NO;
    self.iconView.contentMode = UIViewContentModeScaleAspectFit;
    [self.contentContainer addSubview:self.iconView];

    self.nameLabel = [[UILabel alloc] init];
    self.nameLabel.translatesAutoresizingMaskIntoConstraints = NO;
    self.nameLabel.font = [UIFont systemFontOfSize:[ScreenUtils sp:13] weight:UIFontWeightSemibold];
    self.nameLabel.textColor = [UIColor whiteColor];
    self.nameLabel.numberOfLines = 1;
    self.nameLabel.adjustsFontForContentSizeCategory = NO;
    [self.contentContainer addSubview:self.nameLabel];

    self.descLabel = [[UILabel alloc] init];
    self.descLabel.translatesAutoresizingMaskIntoConstraints = NO;
    self.descLabel.font = [UIFont systemFontOfSize:[ScreenUtils sp:10] weight:UIFontWeightRegular];
    self.descLabel.textColor = [[UIColor whiteColor] colorWithAlphaComponent:0.55];
    self.descLabel.numberOfLines = 2;
    self.descLabel.lineBreakMode = NSLineBreakByWordWrapping;
    self.descLabel.adjustsFontForContentSizeCategory = NO;
    [self.contentContainer addSubview:self.descLabel];

    self.selectedBadge = [[UIView alloc] init];
    self.selectedBadge.translatesAutoresizingMaskIntoConstraints = NO;
    self.selectedBadge.backgroundColor = accentColor();
    self.selectedBadge.layer.cornerRadius = 8;
    self.selectedBadge.hidden = YES;
    [self.contentContainer addSubview:self.selectedBadge];

    UIImageView *checkmark = [[UIImageView alloc] init];
    checkmark.translatesAutoresizingMaskIntoConstraints = NO;
    checkmark.image = [UIImage systemImageNamed:@"checkmark" withConfiguration:[UIImageSymbolConfiguration configurationWithPointSize:8 weight:UIFontWeightBold]];
    checkmark.tintColor = [UIColor whiteColor];
    [self.selectedBadge addSubview:checkmark];

    [NSLayoutConstraint activateConstraints:@[
        [self.iconView.topAnchor constraintEqualToAnchor:self.contentContainer.topAnchor constant:10],
        [self.iconView.leadingAnchor constraintEqualToAnchor:self.contentContainer.leadingAnchor constant:10],
        [self.iconView.widthAnchor constraintEqualToConstant:iconSize],
        [self.iconView.heightAnchor constraintEqualToConstant:iconSize],
        [self.nameLabel.topAnchor constraintEqualToAnchor:self.iconView.bottomAnchor constant:6],
        [self.nameLabel.leadingAnchor constraintEqualToAnchor:self.contentContainer.leadingAnchor constant:10],
        [self.nameLabel.trailingAnchor constraintEqualToAnchor:self.contentContainer.trailingAnchor constant:-10],
        [self.descLabel.topAnchor constraintEqualToAnchor:self.nameLabel.bottomAnchor constant:2],
        [self.descLabel.leadingAnchor constraintEqualToAnchor:self.contentContainer.leadingAnchor constant:10],
        [self.descLabel.trailingAnchor constraintEqualToAnchor:self.contentContainer.trailingAnchor constant:-10],
        [self.descLabel.bottomAnchor constraintLessThanOrEqualToAnchor:self.contentContainer.bottomAnchor constant:-8],
        [self.selectedBadge.topAnchor constraintEqualToAnchor:self.contentContainer.topAnchor constant:8],
        [self.selectedBadge.trailingAnchor constraintEqualToAnchor:self.contentContainer.trailingAnchor constant:-8],
        [self.selectedBadge.widthAnchor constraintEqualToConstant:16],
        [self.selectedBadge.heightAnchor constraintEqualToConstant:16],
        [checkmark.centerXAnchor constraintEqualToAnchor:self.selectedBadge.centerXAnchor],
        [checkmark.centerYAnchor constraintEqualToAnchor:self.selectedBadge.centerYAnchor]
    ]];
}

- (void)configureWithIcon:(NSString *)iconName
                     name:(NSString *)name
                  details:(NSString *)details
              isSelected:(BOOL)isSelected
                  isBest:(BOOL)isBest {
    self.iconView.image = [UIImage systemImageNamed:iconName];
    self.iconView.tintColor = isBest ? accentColor() : [UIColor systemGrayColor];
    self.nameLabel.text = name;
    self.descLabel.text = details;
    self.selectedBadge.hidden = !isSelected;
    self.selectedBadge.backgroundColor = accentColor();

    if (isSelected) {
        self.contentView.layer.borderColor = accentColor().CGColor;
        self.contentView.layer.borderWidth = 1.5;
    } else if (isBest) {
        self.contentView.layer.borderColor = [[accentColor() colorWithAlphaComponent:0.4] CGColor];
        self.contentView.layer.borderWidth = 1.0;
    } else {
        self.contentView.layer.borderColor = [[UIColor whiteColor] colorWithAlphaComponent:0.12].CGColor;
        self.contentView.layer.borderWidth = 0.5;
    }
    self.contentView.layer.cornerRadius = 12;
    self.contentView.layer.masksToBounds = YES;
}

@end

#pragma mark - Header View

@interface VMSectionHeaderView : UICollectionReusableView
@property (nonatomic, strong) UIView *accentBar;
@property (nonatomic, strong) UIImageView *iconView;
@property (nonatomic, strong) UILabel *titleLabel;
@property (nonatomic, strong) UILabel *subtitleLabel;
@property (nonatomic, strong) UILabel *countBadge;
@property (nonatomic, strong) UIVisualEffectView *blurView;
- (void)configureWithIcon:(NSString *)iconName title:(NSString *)title subtitle:(NSString *)subtitle count:(NSInteger)count;
@end

@implementation VMSectionHeaderView

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        // Spec 6.2: SystemMaterial adapts to light/dark mode automatically (replacing the original SystemMaterialDark)
        UIBlurEffect *blurEffect = [UIBlurEffect effectWithStyle:UIBlurEffectStyleSystemMaterial];
        self.blurView = [[UIVisualEffectView alloc] initWithEffect:blurEffect];
        self.blurView.translatesAutoresizingMaskIntoConstraints = NO;
        [self addSubview:self.blurView];

        // Spec 9.5: leading accent bar (4pt wide, rounded, accentColor)
        self.accentBar = [[UIView alloc] init];
        self.accentBar.translatesAutoresizingMaskIntoConstraints = NO;
        self.accentBar.backgroundColor = accentColor();
        self.accentBar.layer.cornerRadius = 2;
        self.accentBar.layer.cornerCurve = kCACornerCurveContinuous;
        [self addSubview:self.accentBar];

        // Spec 8.2: icon container (uses an SF Symbol, tint = accentColor)
        self.iconView = [[UIImageView alloc] init];
        self.iconView.translatesAutoresizingMaskIntoConstraints = NO;
        self.iconView.contentMode = UIViewContentModeScaleAspectFit;
        self.iconView.tintColor = accentColor();
        [self addSubview:self.iconView];

        self.titleLabel = [[UILabel alloc] init];
        self.titleLabel.translatesAutoresizingMaskIntoConstraints = NO;
        self.titleLabel.font = [UIFont systemFontOfSize:[ScreenUtils sp:16] weight:UIFontWeightBold];
        // Spec 2.1: system colors are mandatory
        self.titleLabel.textColor = [UIColor labelColor];
        [self addSubview:self.titleLabel];

        self.subtitleLabel = [[UILabel alloc] init];
        self.subtitleLabel.translatesAutoresizingMaskIntoConstraints = NO;
        self.subtitleLabel.font = [UIFont systemFontOfSize:[ScreenUtils sp:11] weight:UIFontWeightRegular];
        // Spec 2.1: secondary text uses secondaryLabelColor
        self.subtitleLabel.textColor = [UIColor secondaryLabelColor];
        self.subtitleLabel.numberOfLines = 0;
        self.subtitleLabel.lineBreakMode = NSLineBreakByWordWrapping;
        [self addSubview:self.subtitleLabel];

        // Spec 7.1: count pill badge (top right, light accentColor background)
        self.countBadge = [[UILabel alloc] init];
        self.countBadge.translatesAutoresizingMaskIntoConstraints = NO;
        self.countBadge.font = [UIFont systemFontOfSize:[ScreenUtils sp:11] weight:UIFontWeightBold];
        self.countBadge.textColor = [UIColor whiteColor];
        self.countBadge.textAlignment = NSTextAlignmentCenter;
        self.countBadge.backgroundColor = accentColor();
        self.countBadge.layer.cornerRadius = 9;
        self.countBadge.layer.cornerCurve = kCACornerCurveContinuous;
        self.countBadge.layer.masksToBounds = YES;
        self.countBadge.hidden = YES;
        [self addSubview:self.countBadge];

        [NSLayoutConstraint activateConstraints:@[
            [self.blurView.topAnchor constraintEqualToAnchor:self.topAnchor],
            [self.blurView.leadingAnchor constraintEqualToAnchor:self.leadingAnchor],
            [self.blurView.trailingAnchor constraintEqualToAnchor:self.trailingAnchor],
            [self.blurView.bottomAnchor constraintEqualToAnchor:self.bottomAnchor],
            // Leading accent bar: 18pt from the left, vertically centered, 4pt wide, 18pt tall
            [self.accentBar.leadingAnchor constraintEqualToAnchor:self.leadingAnchor constant:18],
            [self.accentBar.centerYAnchor constraintEqualToAnchor:self.centerYAnchor],
            [self.accentBar.widthAnchor constraintEqualToConstant:4],
            [self.accentBar.heightAnchor constraintEqualToConstant:18],
            // Icon: 8pt to the right of the accent bar, vertically centered, 16x16
            [self.iconView.leadingAnchor constraintEqualToAnchor:self.accentBar.trailingAnchor constant:8],
            [self.iconView.centerYAnchor constraintEqualToAnchor:self.titleLabel.centerYAnchor],
            [self.iconView.widthAnchor constraintEqualToConstant:16],
            [self.iconView.heightAnchor constraintEqualToConstant:16],
            // Title: 6pt to the right of the icon
            [self.titleLabel.leadingAnchor constraintEqualToAnchor:self.iconView.trailingAnchor constant:6],
            [self.titleLabel.topAnchor constraintEqualToAnchor:self.topAnchor constant:8],
            [self.titleLabel.trailingAnchor constraintEqualToAnchor:self.countBadge.leadingAnchor constant:-8],
            // Subtitle: 2pt below the title
            [self.subtitleLabel.leadingAnchor constraintEqualToAnchor:self.titleLabel.leadingAnchor],
            [self.subtitleLabel.topAnchor constraintEqualToAnchor:self.titleLabel.bottomAnchor constant:2],
            [self.subtitleLabel.trailingAnchor constraintEqualToAnchor:self.trailingAnchor constant:-18],
            [self.subtitleLabel.bottomAnchor constraintLessThanOrEqualToAnchor:self.bottomAnchor constant:-4],
            // Count badge: 18pt from the right, 8pt from the top, minimum width 18, height 18
            [self.countBadge.trailingAnchor constraintEqualToAnchor:self.trailingAnchor constant:-18],
            [self.countBadge.centerYAnchor constraintEqualToAnchor:self.titleLabel.centerYAnchor],
            [self.countBadge.heightAnchor constraintEqualToConstant:18]
        ]];
    }
    return self;
}

/// Configure the header (icon + title + subtitle + count)
- (void)configureWithIcon:(NSString *)iconName
                    title:(NSString *)title
                 subtitle:(NSString *)subtitle
                    count:(NSInteger)count {
    UIImageSymbolConfiguration *config = [UIImageSymbolConfiguration configurationWithPointSize:14 weight:UIFontWeightSemibold];
    self.iconView.image = [UIImage systemImageNamed:iconName withConfiguration:config] ?: [UIImage systemImageNamed:iconName];
    self.iconView.tintColor = accentColor();
    self.accentBar.backgroundColor = accentColor();
    self.countBadge.backgroundColor = accentColor();

    self.titleLabel.text = title;
    self.subtitleLabel.text = subtitle;

    if (count >= 0) {
        self.countBadge.text = [NSString stringWithFormat:@" %ld ", (long)count];
        self.countBadge.hidden = NO;
    } else {
        self.countBadge.hidden = YES;
    }
}

@end

#pragma mark - View Controller

@interface VersionManagerViewController () <UICollectionViewDataSource, UICollectionViewDelegate, UITextFieldDelegate>
@property (nonatomic, strong) UICollectionView *collectionView;
@property (nonatomic, strong) NSArray<NSString *> *profileList;
@property (nonatomic, strong) NSString *selectedProfile;
@property (nonatomic, strong) NSMutableArray<NSString *> *gameDirList;
@property (nonatomic, strong) NSString *currentGameDir;
// Empty state view (guidance shown when there are no versions)
@property (nonatomic, strong) UIView *emptyStateView;
// Renderer section data (the launcher's native renderer library selection, the LWJGL layer)
@property (nonatomic, strong) NSArray<NSString *> *rendererKeys;
@property (nonatomic, strong) NSArray<NSString *> *rendererNames;
@property (nonatomic, strong) NSArray<NSString *> *rendererIcons;
@property (nonatomic, strong) NSArray<NSString *> *rendererDescs;
// Graphics API section data (the in-game OpenGL/Vulkan switch of MC 26.2+, the game layer)
@property (nonatomic, strong) NSArray<NSString *> *graphicsApiKeys;
@property (nonatomic, strong) NSArray<NSString *> *graphicsApiNames;
@property (nonatomic, strong) NSArray<NSString *> *graphicsApiIcons;
@property (nonatomic, strong) NSArray<NSString *> *graphicsApiDescs;
@end

@implementation VersionManagerViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    // self.title is deliberately not set, to avoid a black "Version management" title bar at the top (modeled on FCL's title-less style)
    self.view.backgroundColor = [UIColor clearColor];
    // Hide the navigation bar band completely (only when this is a non-modal root page and the only VC on the stack)
    // Shortcut entry points (such as showModsManager) pre-push a child page, so count > 1 there and the navigation bar is not hidden
    if (self.navigationController &&
        self.navigationController.viewControllers.firstObject == self &&
        self.navigationController.presentingViewController == nil &&
        self.navigationController.viewControllers.count == 1) {
        self.navigationController.navigationBarHidden = YES;
    }
    if (self.navigationController) {
        [[BackgroundManager sharedManager] applyEffectToNavigationBar:self.navigationController.navigationBar];
    }
    [[BackgroundManager sharedManager] makeViewControllerTransparent:self];
    [self setupRendererData];
    [self setupGraphicsApiData];
    [self setupCollectionView];
    [self setupEmptyStateView];
    [self setupNavigationBar];
    [self setupLongPressGesture];
    [self loadProfiles];
    [self loadGameDirList];
    [self updateEmptyState];

    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(profileChanged)
                                                 name:@"SelectedProfileChanged"
                                               object:nil];

    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(profileChanged)
                                                 name:@"ReloadProfileList"
                                               object:nil];

    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(handleBackgroundUIEffectChanged:)
                                                 name:@"BackgroundUIEffectChanged"
                                               object:nil];

    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(handleAccentColorChanged)
                                                 name:@"LauncherAppearanceChanged"
                                               object:nil];
}

/// FCL style: a floating "+" button at the top right of the view; tapping it opens the download/create version page
/// A floating button is used whether or not the navigation bar is visible, so the button is reachable in every mode
- (void)setupNavigationBar {
    UIButton *fab = [UIButton buttonWithType:UIButtonTypeSystem];
    UIImageSymbolConfiguration *plusConfig = [UIImageSymbolConfiguration configurationWithPointSize:18 weight:UIFontWeightBold];
    UIImage *plusImg = [UIImage systemImageNamed:@"plus" withConfiguration:plusConfig];
    [fab setImage:plusImg forState:UIControlStateNormal];
    fab.tintColor = [UIColor whiteColor];
    // Spec 2.6: use accentColor() rather than systemBlueColor
    fab.backgroundColor = accentColor();
    // Spec 5.1: the FAB is a perfect circle (22pt corner radius = 44/2)
    fab.layer.cornerRadius = 22;
    fab.layer.cornerCurve = kCACornerCurveContinuous;
    // Spec 5.2: FAB shadow tier (0.20, 8, (0,4)) - stronger than the L2 card shadow
    fab.layer.shadowColor = [UIColor blackColor].CGColor;
    fab.layer.shadowOffset = CGSizeMake(0, 4);
    fab.layer.shadowOpacity = 0.20;
    fab.layer.shadowRadius = 8;
    // Note: masksToBounds=YES must not be used, or the shadow would be clipped away
    fab.layer.masksToBounds = NO;
    fab.translatesAutoresizingMaskIntoConstraints = NO;
    fab.accessibilityLabel = @"New version";
    [fab addTarget:self action:@selector(fabTouchDown) forControlEvents:UIControlEventTouchDown];
    [fab addTarget:self action:@selector(fabTouchUp) forControlEvents:UIControlEventTouchUpInside | UIControlEventTouchUpOutside | UIControlEventTouchCancel];
    [fab addTarget:self action:@selector(createNewVersion) forControlEvents:UIControlEventTouchUpInside];
    [self.view addSubview:fab];
    [self.view bringSubviewToFront:fab];

    [NSLayoutConstraint activateConstraints:@[
        // Spec 4.1: FAB is 44x44 (a better touch target, matching the iOS HIG)
        [fab.widthAnchor constraintEqualToConstant:44],
        [fab.heightAnchor constraintEqualToConstant:44],
        [fab.topAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.topAnchor constant:8],
        [fab.trailingAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.trailingAnchor constant:-16],
    ]];

    // Spec 15.4: FAB entrance animation (JellyBounce)
    fab.transform = CGAffineTransformMakeScale(0.3, 0.3);
    [UIView animateWithDuration:0.6
                          delay:0.15
         usingSpringWithDamping:0.55
          initialSpringVelocity:0.8
                         options:UIViewAnimationOptionAllowUserInteraction
                     animations:^{
        fab.transform = CGAffineTransformIdentity;
    } completion:nil];
}

/// FAB press: scale feedback (spec 9.3)
- (void)fabTouchDown {
    [UIView animateWithDuration:0.15 delay:0 usingSpringWithDamping:0.7 initialSpringVelocity:0.8 options:UIViewAnimationOptionAllowUserInteraction animations:^{
        UIButton *fab = [self findFabButton];
        fab.transform = CGAffineTransformMakeScale(0.90, 0.90);
        fab.layer.shadowOpacity = 0.12;
        fab.layer.shadowRadius = 4;
    } completion:nil];
}

/// FAB release: bounce-back feedback
- (void)fabTouchUp {
    [UIView animateWithDuration:0.25 delay:0 usingSpringWithDamping:0.55 initialSpringVelocity:0.9 options:UIViewAnimationOptionAllowUserInteraction animations:^{
        UIButton *fab = [self findFabButton];
        fab.transform = CGAffineTransformIdentity;
        fab.layer.shadowOpacity = 0.20;
        fab.layer.shadowRadius = 8;
    } completion:nil];
}

/// Find the FAB button in the view
- (UIButton *)findFabButton {
    for (UIView *v in self.view.subviews) {
        if ([v isKindOfClass:[UIButton class]] && [v.accessibilityLabel isEqualToString:@"New version"]) {
            return (UIButton *)v;
        }
    }
    return nil;
}

/// Long press gesture: the game directory card shows an action menu (switch/delete) and the version card shows select/edit/delete
- (void)setupLongPressGesture {
    UILongPressGestureRecognizer *longPress = [[UILongPressGestureRecognizer alloc]
        initWithTarget:self action:@selector(handleLongPress:)];
    longPress.minimumPressDuration = 0.5;
    [self.collectionView addGestureRecognizer:longPress];
}

- (void)createNewVersion {
    [[NSNotificationCenter defaultCenter] postNotificationName:@"ShowDownloadPage" object:nil];
}

#pragma mark - Empty State

/// Create the empty state view (guidance shown when there are no versions, modeled on the empty state in spec 10.1)
- (void)setupEmptyStateView {
    self.emptyStateView = [[UIView alloc] init];
    self.emptyStateView.translatesAutoresizingMaskIntoConstraints = NO;
    self.emptyStateView.hidden = YES;
    [self.view addSubview:self.emptyStateView];
    [self.view bringSubviewToFront:self.emptyStateView];

    // Spec 10.1: icon container (80x80 circle, accentColor at 0.12 as a light background)
    UIView *iconContainer = [[UIView alloc] init];
    iconContainer.translatesAutoresizingMaskIntoConstraints = NO;
    iconContainer.backgroundColor = [accentColor() colorWithAlphaComponent:0.12];
    iconContainer.layer.cornerRadius = 40;
    iconContainer.layer.cornerCurve = kCACornerCurveContinuous;
    [self.emptyStateView addSubview:iconContainer];

    UIImageSymbolConfiguration *iconConfig = [UIImageSymbolConfiguration configurationWithPointSize:36 weight:UIFontWeightRegular];
    UIImageView *iconView = [[UIImageView alloc] init];
    iconView.translatesAutoresizingMaskIntoConstraints = NO;
    iconView.contentMode = UIViewContentModeScaleAspectFit;
    iconView.image = [UIImage systemImageNamed:@"cube.box" withConfiguration:iconConfig];
    iconView.tintColor = accentColor();
    [iconContainer addSubview:iconView];

    // Spec 2.1: the title uses labelColor
    UILabel *titleLabel = [[UILabel alloc] init];
    titleLabel.translatesAutoresizingMaskIntoConstraints = NO;
    titleLabel.font = [UIFont systemFontOfSize:[ScreenUtils sp:18] weight:UIFontWeightBold];
    titleLabel.textColor = [UIColor labelColor];
    titleLabel.text = @"No versions installed yet";
    titleLabel.textAlignment = NSTextAlignmentCenter;
    [self.emptyStateView addSubview:titleLabel];

    // Spec 2.1: the subtitle uses secondaryLabelColor
    UILabel *subtitleLabel = [[UILabel alloc] init];
    subtitleLabel.translatesAutoresizingMaskIntoConstraints = NO;
    subtitleLabel.font = [UIFont systemFontOfSize:[ScreenUtils sp:13] weight:UIFontWeightRegular];
    subtitleLabel.textColor = [UIColor secondaryLabelColor];
    subtitleLabel.text = @"Tap + in the top right to download your first Minecraft version";
    subtitleLabel.textAlignment = NSTextAlignmentCenter;
    subtitleLabel.numberOfLines = 0;
    [self.emptyStateView addSubview:subtitleLabel];

    // Spec 9.2: CTA button (accentColor background + white text + rounded corners)
    UIButton *ctaButton = [UIButton buttonWithType:UIButtonTypeSystem];
    ctaButton.translatesAutoresizingMaskIntoConstraints = NO;
    UIImageSymbolConfiguration *btnIconConfig = [UIImageSymbolConfiguration configurationWithPointSize:14 weight:UIFontWeightBold];
    UIImage *btnIcon = [UIImage systemImageNamed:@"arrow.down.circle.fill" withConfiguration:btnIconConfig];
    [ctaButton setImage:btnIcon forState:UIControlStateNormal];
    [ctaButton setTitle:@"  Download a version" forState:UIControlStateNormal];
    ctaButton.titleLabel.font = [UIFont systemFontOfSize:[ScreenUtils sp:15] weight:UIFontWeightSemibold];
    [ctaButton setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    ctaButton.tintColor = [UIColor whiteColor];
    ctaButton.backgroundColor = accentColor();
    ctaButton.layer.cornerRadius = 22;
    ctaButton.layer.cornerCurve = kCACornerCurveContinuous;
    ctaButton.layer.shadowColor = [UIColor blackColor].CGColor;
    ctaButton.layer.shadowOffset = CGSizeMake(0, 3);
    ctaButton.layer.shadowOpacity = 0.15;
    ctaButton.layer.shadowRadius = 6;
    ctaButton.layer.masksToBounds = NO;
    ctaButton.contentEdgeInsets = UIEdgeInsetsMake(0, 20, 0, 20);
    [ctaButton addTarget:self action:@selector(createNewVersion) forControlEvents:UIControlEventTouchUpInside];
    [self.emptyStateView addSubview:ctaButton];

    [NSLayoutConstraint activateConstraints:@[
        // The empty state view is centered
        [self.emptyStateView.centerXAnchor constraintEqualToAnchor:self.view.centerXAnchor],
        [self.emptyStateView.centerYAnchor constraintEqualToAnchor:self.view.centerYAnchor],
        [self.emptyStateView.widthAnchor constraintEqualToAnchor:self.view.widthAnchor constant:-64],
        // Icon container: top aligned, centered, 80x80
        [iconContainer.topAnchor constraintEqualToAnchor:self.emptyStateView.topAnchor],
        [iconContainer.centerXAnchor constraintEqualToAnchor:self.emptyStateView.centerXAnchor],
        [iconContainer.widthAnchor constraintEqualToConstant:80],
        [iconContainer.heightAnchor constraintEqualToConstant:80],
        // The icon is centered
        [iconView.centerXAnchor constraintEqualToAnchor:iconContainer.centerXAnchor],
        [iconView.centerYAnchor constraintEqualToAnchor:iconContainer.centerYAnchor],
        [iconView.widthAnchor constraintEqualToConstant:36],
        [iconView.heightAnchor constraintEqualToConstant:36],
        // Title: 16pt below the icon
        [titleLabel.topAnchor constraintEqualToAnchor:iconContainer.bottomAnchor constant:16],
        [titleLabel.leadingAnchor constraintEqualToAnchor:self.emptyStateView.leadingAnchor],
        [titleLabel.trailingAnchor constraintEqualToAnchor:self.emptyStateView.trailingAnchor],
        // Subtitle: 6pt below the title
        [subtitleLabel.topAnchor constraintEqualToAnchor:titleLabel.bottomAnchor constant:6],
        [subtitleLabel.leadingAnchor constraintEqualToAnchor:self.emptyStateView.leadingAnchor],
        [subtitleLabel.trailingAnchor constraintEqualToAnchor:self.emptyStateView.trailingAnchor],
        // CTA button: 24pt below the subtitle
        [ctaButton.topAnchor constraintEqualToAnchor:subtitleLabel.bottomAnchor constant:24],
        [ctaButton.centerXAnchor constraintEqualToAnchor:self.emptyStateView.centerXAnchor],
        [ctaButton.heightAnchor constraintEqualToConstant:44],
        [ctaButton.bottomAnchor constraintEqualToAnchor:self.emptyStateView.bottomAnchor]
    ]];
}

/// Show/hide the empty state view depending on the number of versions in the list
- (void)updateEmptyState {
    BOOL isEmpty = (self.profileList.count == 0);
    self.emptyStateView.hidden = !isEmpty;
    self.collectionView.hidden = isEmpty;

    if (isEmpty) {
        // Spec 15.4: empty state entrance animation (jelly bounce + fade in)
        self.emptyStateView.alpha = 0;
        self.emptyStateView.transform = CGAffineTransformMakeScale(0.85, 0.85);
        [UIView animateWithDuration:0.5
                              delay:0.1
             usingSpringWithDamping:0.7
              initialSpringVelocity:0.6
                             options:UIViewAnimationOptionAllowUserInteraction
                         animations:^{
            self.emptyStateView.alpha = 1;
            self.emptyStateView.transform = CGAffineTransformIdentity;
        } completion:nil];
    }
}

- (void)handleLongPress:(UILongPressGestureRecognizer *)gesture {
    if (gesture.state != UIGestureRecognizerStateBegan) return;
    CGPoint point = [gesture locationInView:self.collectionView];
    NSIndexPath *indexPath = [self.collectionView indexPathForItemAtPoint:point];
    if (!indexPath) return;

    if (indexPath.section == kSectionGameDir) {
        // Game directory section: long press shows the switch/delete menu (excluding the "New directory" button item)
        if (indexPath.item >= (NSInteger)self.gameDirList.count) return;
        NSString *dirName = self.gameDirList[indexPath.item];
        [self showGameDirActions:dirName];
    } else if (indexPath.section == kSectionVersions) {
        // Version card section: long press shows the action menu (select/delete)
        if (indexPath.item >= (NSInteger)self.profileList.count) return;
        [self showProfileActions:self.profileList[indexPath.item]];
    }
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    // Hide the navigation bar band again (topViewController == self after popping back to the root page)
    if (self.navigationController &&
        self.navigationController.viewControllers.firstObject == self &&
        self.navigationController.presentingViewController == nil &&
        self.navigationController.topViewController == self) {
        self.navigationController.navigationBarHidden = YES;
        // Spec 4.1: when the navigation bar is hidden, the top inset must leave room for the FAB
        CGFloat topInset = self.view.safeAreaInsets.top + 8 + 44 + 8;
        self.collectionView.contentInset = UIEdgeInsetsMake(topInset, 0, 24, 0);
        self.collectionView.scrollIndicatorInsets = UIEdgeInsetsMake(topInset, 0, 24, 0);
    }
    [PLProfiles updateCurrent];
    [self loadProfiles];
    [self loadGameDirList];
    [self.collectionView reloadData];
    [self updateEmptyState];
}

- (void)viewWillDisappear:(BOOL)animated {
    [super viewWillDisappear:animated];
    // Show the navigation bar when a child page is pushed (it needs a back button)
    if (self.navigationController &&
        self.navigationController.viewControllers.firstObject == self &&
        self.navigationController.presentingViewController == nil) {
        self.navigationController.navigationBarHidden = NO;
    }
}

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

- (void)profileChanged {
    [PLProfiles updateCurrent];
    [self loadProfiles];
    [self loadGameDirList];
    [self.collectionView reloadData];
    [self updateEmptyState];
}

- (void)handleBackgroundUIEffectChanged:(NSNotification *)notification {
    dispatch_async(dispatch_get_main_queue(), ^{
        [self.collectionView reloadData];
    });
}

- (void)handleAccentColorChanged {
    dispatch_async(dispatch_get_main_queue(), ^{
        [self.collectionView reloadData];
        [self updateEmptyState];
    });
}

#pragma mark - Renderer Data Setup

/// Initialize the renderer option data (the launcher's native renderer library selection, the LWJGL layer)
/// Modeled on the renderer selection panel of FCL/HMCL, offering 7 options with matching descriptions
/// Note: the names are short identifiers rather than the long localized strings returned by getRendererNames
- (void)setupRendererData {
    self.rendererKeys = getRendererKeys(NO);
    // Short renderer names (not the long localized strings from getRendererNames)
    // The order must match getRendererKeys() exactly (paired by index)
    self.rendererNames = @[
        @"Auto",
        @"GL4ES",
        @"ANGLE",
        @"MobileGlues",
        @"Zink",
        @"LTW",
        @"MoltenVK"
    ];
    self.rendererIcons = @[
        @"wand.and.stars",
        @"cpu",
        @"rectangle.stack.fill",
        @"bolt.fill",
        @"circle.hexagongrid.fill",
        @"square.stack.3d.up.fill",
        @"flame.fill"
    ];
    self.rendererDescs = @[
        @"Automatically pick the best renderer",
        @"OpenGL ES 1.14 translation (best compatibility)",
        @"MetalANGLE, Metal to GLES",
        @"Vulkan to OpenGL translation",
        @"OpenGL to Vulkan",
        @"OpenGL Core→ES translation (works perfectly with Sodium and shaders)",
        @"Native Vulkan"
    ];
}

#pragma mark - Graphics API Data Setup (MC 26.2+)

/// Initialize the graphics API option data (the in-game OpenGL/Vulkan switch of MC 26.2+, the game layer)
///
/// Mojang introduced the "Graphics API" video setting in MC 26.2 Snapshot 1, with 3 values:
///   - default        decided by Mojang (Vulkan for snapshots 1-7, OpenGL for snapshot 8+)
///   - prefer_vulkan  prefer Vulkan, falling back to OpenGL on failure
///   - prefer_opengl  prefer OpenGL, falling back to Vulkan on failure
///
/// Note: this is a different dimension from the renderer
- (void)setupGraphicsApiData {
    self.graphicsApiKeys = @[@"default", @"prefer_vulkan", @"prefer_opengl"];
    self.graphicsApiNames = @[@"Default", @"Prefer Vulkan", @"Prefer OpenGL"];
    self.graphicsApiIcons = @[
        @"wand.and.stars",
        @"flame.fill",
        @"rectangle.stack.fill"
    ];
    self.graphicsApiDescs = @[
        @"Let Mojang decide (recommended)",
        @"Prefer Vulkan, fall back to OpenGL",
        @"Prefer OpenGL, fall back to Vulkan"
    ];
}

/// Determine whether the currently selected profile's version is MC 26.2+ (i.e. the new version numbering scheme after 1.21.8)
/// The 26.x series = the new version number format adopted by snapshots/releases from 1.21.8 onwards
- (BOOL)isCurrentProfileModernVersion {
    if (!self.selectedProfile) return NO;
    NSDictionary *profile = PLProfiles.current.profiles[self.selectedProfile];
    NSString *versionId = profile[@"lastVersionId"];
    if (!versionId) return NO;
    // Fix for recognizing the version number of Fabric/Quilt/Forge loader profiles:
    //   The original implementation extracted the prefix using a digit character set, but the character at index 0
    //   of fabric-loader-0.16.0-26.2 is 'f', which is not a digit, so the prefix was cut down to an empty string and MC 26.2+ Fabric profiles
    //   could not see the "Graphics API" option.
    //   The fix: extract the Minecraft version with ModpackExportService.parseVersionId first,
    //   then test the extracted version. That also handles the forge/neoforge form "26.2-forge-...".
    NSDictionary *parsed = [ModpackExportService parseVersionId:versionId];
    NSString *mcVersion = parsed[@"minecraft"] ?: versionId;
    // The 26.x series
    if ([mcVersion hasPrefix:@"26."]) return YES;
    if ([mcVersion hasPrefix:@"26w"]) return YES;
    // 1.21.8 and above
    if ([mcVersion hasPrefix:@"1.21."]) {
        NSString *minorStr = [mcVersion substringFromIndex:5];
        NSInteger minor = [minorStr integerValue];
        if (minor >= 8) return YES;
    }
    return NO;
}

/// Get the renderer of the currently selected profile (falling back to the global preference if unset)
- (NSString *)currentRendererForSelectedProfile {
    if (!self.selectedProfile) return @"auto";
    NSDictionary *profile = PLProfiles.current.profiles[self.selectedProfile];
    NSString *r = profile[@"renderer"];
    if (r.length == 0) {
        r = getPrefObject(@"video.renderer");
    }
    return r.length > 0 ? r : @"auto";
}

/// Get the graphics API of the currently selected profile (MC 26.2+; falls back to the global preference if unset, then to default)
- (NSString *)currentGraphicsApiForSelectedProfile {
    if (!self.selectedProfile) return @"default";
    NSDictionary *profile = PLProfiles.current.profiles[self.selectedProfile];
    NSString *g = profile[@"graphicsApi"];
    if (g.length == 0) {
        g = getPrefObject(@"video.graphics_api");
    }
    return g.length > 0 ? g : @"default";
}

#pragma mark - Setup

- (void)setupCollectionView {
    UICollectionViewLayout *layout = [self createLayout];
    self.collectionView = [[UICollectionView alloc] initWithFrame:self.view.bounds collectionViewLayout:layout];
    self.collectionView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    self.collectionView.backgroundColor = [UIColor clearColor];
    self.collectionView.dataSource = self;
    self.collectionView.delegate = self;
    self.collectionView.alwaysBounceVertical = YES;
    self.collectionView.contentInsetAdjustmentBehavior = UIScrollViewContentInsetAdjustmentNever;
    // Spec 4.1: the top inset must leave room for the FAB (FAB 44pt + 8pt from the top + 8pt spacing = 60pt)
    // This keeps the count badge of the first section header from being covered by the FAB
    CGFloat topInset;
    if (self.navigationController && self.navigationController.navigationBarHidden) {
        // Navigation bar hidden: the FAB sits at safeAreaTop + 8, height 44
        topInset = self.view.safeAreaInsets.top + 8 + 44 + 8;
    } else {
        // Navigation bar visible: the FAB sits at the bottom of the navBar + 8, height 44
        CGFloat navBarHeight = 44.0;
        if (self.navigationController && self.navigationController.navigationBar.bounds.size.height > 0) {
            navBarHeight = self.navigationController.navigationBar.bounds.size.height;
        }
        topInset = navBarHeight + 8 + 44 + 8;
    }
    self.collectionView.contentInset = UIEdgeInsetsMake(topInset, 0, 24, 0);
    self.collectionView.scrollIndicatorInsets = UIEdgeInsetsMake(topInset, 0, 24, 0);

    [self.collectionView registerClass:[VMGameDirCell class] forCellWithReuseIdentifier:@"GameDirCell"];
    [self.collectionView registerClass:[VMVersionCardCell class] forCellWithReuseIdentifier:@"VersionCell"];
    [self.collectionView registerClass:[VMSectionHeaderView class] forSupplementaryViewOfKind:UICollectionElementKindSectionHeader withReuseIdentifier:@"HeaderView"];

    [self.view addSubview:self.collectionView];
}

- (UICollectionViewLayout *)createLayout {
    return [[UICollectionViewCompositionalLayout alloc] initWithSectionProvider:^NSCollectionLayoutSection * _Nullable(NSInteger sectionIndex, id<NSCollectionLayoutEnvironment> _Nonnull layoutEnvironment) {
        CGFloat width = layoutEnvironment.container.contentSize.width;
        BOOL isiPad = width > 700;

        // Spec 4.1: estimated header height 48pt
        NSCollectionLayoutSize *headerSize = [NSCollectionLayoutSize sizeWithWidthDimension:[NSCollectionLayoutDimension fractionalWidthDimension:1.0]
                                                                              heightDimension:[NSCollectionLayoutDimension estimatedDimension:48]];
        NSCollectionLayoutBoundarySupplementaryItem *header = [NSCollectionLayoutBoundarySupplementaryItem boundarySupplementaryItemWithLayoutSize:headerSize elementKind:UICollectionElementKindSectionHeader alignment:NSRectAlignmentTop];
        header.contentInsets = NSDirectionalEdgeInsetsMake(0, 0, 0, 0);

        if (sectionIndex == kSectionGameDir) {
            // Game directory section: a horizontally scrolling card list
            // Spec 4.1: card width 160pt (180pt on iPad), height 70pt (leaving breathing room for the icon container)
            CGFloat itemWidth = isiPad ? 180 : 160;
            CGFloat itemHeight = 70;
            NSCollectionLayoutSize *itemSize = [NSCollectionLayoutSize sizeWithWidthDimension:[NSCollectionLayoutDimension absoluteDimension:itemWidth]
                                                                                       heightDimension:[NSCollectionLayoutDimension absoluteDimension:itemHeight]];
            NSCollectionLayoutItem *item = [NSCollectionLayoutItem itemWithLayoutSize:itemSize];
            // Spec 4.1: card spacing 8pt (4pt above and below)
            item.contentInsets = NSDirectionalEdgeInsetsMake(4, 5, 4, 5);

            NSCollectionLayoutSize *groupSize = [NSCollectionLayoutSize sizeWithWidthDimension:[NSCollectionLayoutDimension absoluteDimension:itemWidth]
                                                                                          heightDimension:[NSCollectionLayoutDimension absoluteDimension:itemHeight]];
            NSCollectionLayoutGroup *group = [NSCollectionLayoutGroup horizontalGroupWithLayoutSize:groupSize subitems:@[item]];

            NSCollectionLayoutSection *section = [NSCollectionLayoutSection sectionWithGroup:group];
            section.orthogonalScrollingBehavior = UICollectionLayoutSectionOrthogonalScrollingBehaviorContinuous;
            // Spec 4.1: 16pt margins, 8pt between sections
            section.contentInsets = NSDirectionalEdgeInsetsMake(0, 16, 8, 16);
            section.boundarySupplementaryItems = @[header];
            return section;
        } else {
            // Version card section: a compact list (two columns on iPad, one on iPhone)
            // Spec 4.1: increase the column spacing for the two-column iPad layout
            CGFloat itemWidth = isiPad ? 0.5 : 1.0;
            // Spec 4.1: card height 84pt (leaving breathing room for the 34pt icon container + three lines of text)
            CGFloat itemHeight = 84;
            NSCollectionLayoutSize *itemSize = [NSCollectionLayoutSize sizeWithWidthDimension:[NSCollectionLayoutDimension fractionalWidthDimension:itemWidth]
                                                                                       heightDimension:[NSCollectionLayoutDimension absoluteDimension:itemHeight]];
            NSCollectionLayoutItem *item = [NSCollectionLayoutItem itemWithLayoutSize:itemSize];
            // Spec 4.1: card spacing 8pt (4pt above and below), 8pt left and right
            item.contentInsets = NSDirectionalEdgeInsetsMake(4, 8, 4, 8);

            NSCollectionLayoutSize *groupSize = [NSCollectionLayoutSize sizeWithWidthDimension:[NSCollectionLayoutDimension fractionalWidthDimension:1.0]
                                                                                          heightDimension:[NSCollectionLayoutDimension absoluteDimension:itemHeight]];
            NSCollectionLayoutGroup *group = [NSCollectionLayoutGroup horizontalGroupWithLayoutSize:groupSize subitems:@[item]];

            NSCollectionLayoutSection *section = [NSCollectionLayoutSection sectionWithGroup:group];
            // Spec 4.1: column spacing 8pt (for the two-column iPad layout)
            section.interGroupSpacing = isiPad ? 8 : 0;
            // Spec 4.1: 16pt margins, 24pt at the bottom (leaving breathing room below)
            section.contentInsets = NSDirectionalEdgeInsetsMake(0, 16, 24, 16);
            section.boundarySupplementaryItems = @[header];
            return section;
        }
    }];
}

#pragma mark - Data

- (void)loadProfiles {
    NSMutableDictionary *profiles = PLProfiles.current.profiles;
    NSMutableArray *list = [NSMutableArray array];
    for (NSString *key in profiles.allKeys) {
        [list addObject:key];
    }
    self.profileList = [list sortedArrayUsingComparator:^NSComparisonResult(NSString *obj1, NSString *obj2) {
        return [obj2 compare:obj1];
    }];
    self.selectedProfile = PLProfiles.current.selectedProfileName;
}

/// Load the list of game directories (instances)
- (void)loadGameDirList {
    NSMutableArray *list = [NSMutableArray array];
    [list addObject:@"default"];

    NSString *instancesPath = [NSString stringWithFormat:@"%s/instances", getenv("POJAV_HOME")];
    NSFileManager *fm = [NSFileManager defaultManager];
    NSArray *files = [fm contentsOfDirectoryAtPath:instancesPath error:nil];
    BOOL isDir = NO;
    for (NSString *file in files) {
        NSString *fullPath = [instancesPath stringByAppendingPathComponent:file];
        if ([fm fileExistsAtPath:fullPath isDirectory:&isDir] && isDir && ![file isEqualToString:@"default"]) {
            [list addObject:file];
        }
    }
    self.gameDirList = list;
    id raw = getPrefObject(@"general.game_directory");
    self.currentGameDir = [raw isKindOfClass:[NSString class]] ? raw : @"default";
}

#pragma mark - UICollectionViewDataSource

- (NSInteger)numberOfSectionsInCollectionView:(UICollectionView *)collectionView {
    return 2;
}

- (NSInteger)collectionView:(UICollectionView *)collectionView numberOfItemsInSection:(NSInteger)section {
    if (section == kSectionGameDir) {
        return self.gameDirList.count + 1;  // A "New directory" button is appended at the end
    } else {
        return self.profileList.count;
    }
}

- (UICollectionViewCell *)collectionView:(UICollectionView *)collectionView cellForItemAtIndexPath:(NSIndexPath *)indexPath {
    if (indexPath.section == kSectionGameDir) {
        VMGameDirCell *cell = [collectionView dequeueReusableCellWithReuseIdentifier:@"GameDirCell" forIndexPath:indexPath];

        if (indexPath.item == (NSInteger)self.gameDirList.count) {
            [cell configureWithName:nil detail:nil isSelected:NO isAddButton:YES];
            return cell;
        }

        NSString *dirName = self.gameDirList[indexPath.item];
        BOOL isSelected = [dirName isEqualToString:self.currentGameDir];

        // Compute the directory size asynchronously
        __weak typeof(self) weakSelf = self;
        dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
            unsigned long long folderSize = 0;
            NSString *directory = [NSString stringWithFormat:@"%s/instances/%@", getenv("POJAV_HOME"), dirName];
            [weakSelf calculateFolderSizeAtPath:directory size:&folderSize];
            NSString *sizeStr = [NSByteCountFormatter stringFromByteCount:folderSize countStyle:NSByteCountFormatterCountStyleMemory];
            dispatch_async(dispatch_get_main_queue(), ^{
                VMGameDirCell *targetCell = (VMGameDirCell *)[collectionView cellForItemAtIndexPath:indexPath];
                if (targetCell && [targetCell isKindOfClass:[VMGameDirCell class]]) {
                    targetCell.detailLabel.text = sizeStr;
                }
            });
        });

        [cell configureWithName:dirName detail:@"Calculating..." isSelected:isSelected isAddButton:NO];
        return cell;
    } else {
        VMVersionCardCell *cell = [collectionView dequeueReusableCellWithReuseIdentifier:@"VersionCell" forIndexPath:indexPath];

        NSString *profileName = self.profileList[indexPath.item];
        NSDictionary *profile = PLProfiles.current.profiles[profileName];
        NSString *versionId = profile[@"lastVersionId"] ?: @"Unknown version";
        BOOL isSelected = [profileName isEqualToString:self.selectedProfile];
        NSString *gameDir = profile[@"gameDir"] ?: @".";
        BOOL isolated = ![gameDir isEqualToString:@"."];
        NSString *lastPlayed = [self formatLastPlayed:profile[@"lastPlayed"]];

        [cell configureWithName:profileName version:versionId isSelected:isSelected isolated:isolated lastPlayed:lastPlayed];
        return cell;
    }
}

/// Simple recursive directory size calculation
- (void)calculateFolderSizeAtPath:(NSString *)path size:(unsigned long long *)size {
    NSFileManager *fm = [NSFileManager defaultManager];
    NSDirectoryEnumerator *enumerator = [fm enumeratorAtPath:path];
    NSString *relativePath;
    while ((relativePath = [enumerator nextObject])) {
        NSString *fullPath = [path stringByAppendingPathComponent:relativePath];
        NSDictionary *attrs = [fm attributesOfItemAtPath:fullPath error:nil];
        if (attrs) {
            *size += [attrs fileSize];
        }
    }
}

/// Format the lastPlayed timestamp as "Last played: xxx"
- (NSString *)formatLastPlayed:(id)lastPlayedRaw {
    if (!lastPlayedRaw) return @"";
    NSTimeInterval ts;
    if ([lastPlayedRaw isKindOfClass:[NSNumber class]]) {
        ts = [lastPlayedRaw doubleValue];
    } else if ([lastPlayedRaw isKindOfClass:[NSString class]]) {
        ts = [(NSString *)lastPlayedRaw doubleValue];
    } else {
        return @"";
    }
    if (ts <= 0) return @"";
    NSDate *date = [NSDate dateWithTimeIntervalSince1970:ts];
    NSDateFormatter *fmt = [[NSDateFormatter alloc] init];
    fmt.locale = [NSLocale currentLocale];
    fmt.doesRelativeDateFormatting = YES;
    fmt.dateStyle = NSDateFormatterShortStyle;
    fmt.timeStyle = NSDateFormatterShortStyle;
    return [NSString stringWithFormat:@"Last played: %@", [fmt stringFromDate:date]];
}

- (UICollectionReusableView *)collectionView:(UICollectionView *)collectionView viewForSupplementaryElementOfKind:(NSString *)kind atIndexPath:(NSIndexPath *)indexPath {
    if (kind == UICollectionElementKindSectionHeader) {
        VMSectionHeaderView *header = [collectionView dequeueReusableSupplementaryViewOfKind:kind withReuseIdentifier:@"HeaderView" forIndexPath:indexPath];
        switch (indexPath.section) {
            case kSectionGameDir:
                [header configureWithIcon:@"folder.badge.gearshape"
                                     title:@"Game directory (version isolation)"
                                  subtitle:@"Tap to switch · long-press to delete the current directory"
                                     count:(NSInteger)self.gameDirList.count];
                break;
            case kSectionVersions:
                [header configureWithIcon:@"cube.box.fill"
                                     title:@"Installed versions"
                                  subtitle:@"Tap to open version settings · long-press for the action menu"
                                     count:(NSInteger)self.profileList.count];
                break;
            default:
                [header configureWithIcon:@""
                                     title:@""
                                  subtitle:@""
                                     count:-1];
                break;
        }
        return header;
    }
    return [UICollectionReusableView new];
}

#pragma mark - UICollectionViewDelegate

- (void)collectionView:(UICollectionView *)collectionView didSelectItemAtIndexPath:(NSIndexPath *)indexPath {
    [collectionView deselectItemAtIndexPath:indexPath animated:YES];

    if (indexPath.section == kSectionGameDir) {
        if (indexPath.item == (NSInteger)self.gameDirList.count) {
            [self showCreateGameDirAlert];
        } else {
            NSString *dirName = self.gameDirList[indexPath.item];
            if (![dirName isEqualToString:self.currentGameDir]) {
                [self switchGameDirTo:dirName];
            }
        }
    } else if (indexPath.section == kSectionVersions) {
        // Tapping a version card goes straight to that version's dedicated settings page (FCL style)
        NSString *profileName = self.profileList[indexPath.item];
        [self editProfile:profileName];
    }
}

#pragma mark - Game Directory Actions

/// Switch the game directory (instance) and rebuild the symbolic links
- (void)switchGameDirTo:(NSString *)name {
    if (getenv("DEMO_LOCK")) return;

    setPrefObject(@"general.game_directory", name);
    NSString *multidirPath = [NSString stringWithFormat:@"%s/instances/%@", getenv("POJAV_HOME"), name];
    NSString *lasmPath = @(getenv("POJAV_GAME_DIR"));
    NSError *removeError = nil;
    [NSFileManager.defaultManager removeItemAtPath:lasmPath error:&removeError];

    NSError *linkError = nil;
    BOOL linkOK = [NSFileManager.defaultManager createSymbolicLinkAtPath:lasmPath
                                                       withDestinationPath:multidirPath
                                                                     error:&linkError];
    if (!linkOK) {
        NSLog(@"[VersionMgr] createSymbolicLink failed: %@", linkError.localizedDescription);
        [self showAlert:[NSString stringWithFormat:@"Could not switch the game directory:\n\n%@", linkError.localizedDescription]];
        return;
    }
    [NSFileManager.defaultManager changeCurrentDirectoryPath:lasmPath];
    toggleIsolatedPref(NO);
    [PLProfiles updateCurrent];

    [[NSNotificationCenter defaultCenter] postNotificationName:@"ReloadProfileList" object:nil];
    [[NSNotificationCenter defaultCenter] postNotificationName:@"SelectedProfileChanged" object:nil];

    [self loadGameDirList];
    [self loadProfiles];
    [self.collectionView reloadData];
    [self updateEmptyState];
}

/// Show the new game directory dialog
- (void)showCreateGameDirAlert {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"New game directory"
                                                                   message:@"Enter a new directory name (used for version isolation)"
                                                            preferredStyle:UIAlertControllerStyleAlert];
    [alert addTextFieldWithConfigurationHandler:^(UITextField *textField) {
        textField.placeholder = @"Directory name";
        textField.autocapitalizationType = UITextAutocapitalizationTypeNone;
        textField.autocorrectionType = UITextAutocorrectionTypeNo;
        textField.clearButtonMode = UITextFieldViewModeWhileEditing;
        textField.delegate = self;
    }];
    [alert addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    [alert addAction:[UIAlertAction actionWithTitle:@"Create" style:UIAlertActionStyleDefault handler:^(UIAlertAction * _Nonnull action) {
        NSString *name = alert.textFields.firstObject.text;
        if (name.length == 0) return;
        [self createGameDirWithName:name];
    }]];

    if (UIDevice.currentDevice.userInterfaceIdiom == UIUserInterfaceIdiomPad) {
        alert.popoverPresentationController.sourceView = self.view;
        alert.popoverPresentationController.sourceRect = CGRectMake(self.view.bounds.size.width / 2, self.view.bounds.size.height / 2, 1, 1);
    }
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)createGameDirWithName:(NSString *)name {
    NSString *dest = [NSString stringWithFormat:@"%s/instances/%@", getenv("POJAV_HOME"), name];
    NSError *error = nil;
    if (![NSFileManager.defaultManager createDirectoryAtPath:dest withIntermediateDirectories:YES attributes:nil error:&error]) {
        [self showAlert:[NSString stringWithFormat:@"Could not create the directory:\n\n%@", error.localizedDescription]];
        return;
    }
    [self switchGameDirTo:name];
}

/// Long press on a game directory card shows the action menu: switch/delete the current directory
- (void)showGameDirActions:(NSString *)dirName {
    BOOL isSelected = [dirName isEqualToString:self.currentGameDir];
    BOOL isDefault = [dirName isEqualToString:@"default"];

    UIAlertController *alert = [UIAlertController alertControllerWithTitle:dirName
                                                                   message:isSelected ? @"This directory is currently in use" : @"Switch to this directory"
                                                            preferredStyle:UIAlertControllerStyleActionSheet];

    if (!isSelected) {
        [alert addAction:[UIAlertAction actionWithTitle:@"Switch to this directory" style:UIAlertActionStyleDefault handler:^(UIAlertAction * _Nonnull action) {
            [self switchGameDirTo:dirName];
        }]];
    }

    // Delete the directory (the default directory cannot be deleted, and the directory in use must be switched away from before it can be deleted)
    if (!isDefault) {
        NSString *deleteTitle = isSelected ? @"Delete (switch to another directory first)" : @"Delete this directory";
        [alert addAction:[UIAlertAction actionWithTitle:deleteTitle style:UIAlertActionStyleDestructive handler:^(UIAlertAction * _Nonnull action) {
            if (isSelected) {
                [self showAlert:@"Switch to another directory before deleting this one"];
                return;
            }
            [self confirmDeleteGameDir:dirName];
        }]];
    }

    [alert addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];

    if (UIDevice.currentDevice.userInterfaceIdiom == UIUserInterfaceIdiomPad) {
        alert.popoverPresentationController.sourceView = self.view;
        alert.popoverPresentationController.sourceRect = CGRectMake(self.view.bounds.size.width / 2, self.view.bounds.size.height / 2, 1, 1);
        alert.popoverPresentationController.permittedArrowDirections = UIPopoverArrowDirectionAny;
    }
    [self presentViewController:alert animated:YES completion:nil];
}

/// Confirm deletion of a game directory
- (void)confirmDeleteGameDir:(NSString *)dirName {
    UIAlertController *confirm = [UIAlertController alertControllerWithTitle:@"Confirm directory deletion"
                                                                     message:[NSString stringWithFormat:@"This will delete the directory \"%@\" and everything in it (saves, mods, configs, and so on). This cannot be undone.", dirName]
                                                              preferredStyle:UIAlertControllerStyleAlert];
    [confirm addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    [confirm addAction:[UIAlertAction actionWithTitle:@"Confirm delete" style:UIAlertActionStyleDestructive handler:^(UIAlertAction * _Nonnull action) {
        [self deleteGameDir:dirName];
    }]];
    [self presentViewController:confirm animated:YES completion:nil];
}

/// Delete the specified game directory
- (void)deleteGameDir:(NSString *)dirName {
    if ([dirName isEqualToString:@"default"]) {
        [self showAlert:@"The default directory cannot be deleted"];
        return;
    }
    if ([dirName isEqualToString:self.currentGameDir]) {
        [self showAlert:@"Switch to another directory before deleting this one"];
        return;
    }

    NSString *dest = [NSString stringWithFormat:@"%s/instances/%@", getenv("POJAV_HOME"), dirName];
    NSError *error = nil;
    if (![NSFileManager.defaultManager removeItemAtPath:dest error:&error]) {
        [self showAlert:[NSString stringWithFormat:@"Could not delete the directory:\n\n%@", error.localizedDescription]];
        return;
    }

    [self loadGameDirList];
    [self.collectionView reloadData];
    [self updateEmptyState];
    [self showAlert:[NSString stringWithFormat:@"Deleted the directory \"%@\"", dirName]];
}

#pragma mark - Renderer Selection (the launcher's native library choice)

/// Select a renderer and save it to the current profile
- (void)selectRendererAtIndex:(NSInteger)index {
    if (!self.selectedProfile) {
        [self showAlert:@"Select a version first"];
        return;
    }
    if (index >= (NSInteger)self.rendererKeys.count) return;

    NSString *key = self.rendererKeys[index];
    NSString *displayName = index < (NSInteger)self.rendererNames.count ? self.rendererNames[index] : key;

    // Write to the renderer field of the current profile
    NSMutableDictionary *profiles = PLProfiles.current.profiles;
    NSMutableDictionary *profile = [profiles[self.selectedProfile] mutableCopy];
    if (!profile) {
        profile = [NSMutableDictionary dictionary];
    }
    profile[@"renderer"] = key;
    profiles[self.selectedProfile] = profile;
    [PLProfiles.current save];

    // Sync to the global preference (so LauncherRightPanelViewController can read it when the game launches)
    setPrefString(@"video.renderer", key);

    [self.collectionView reloadData];

    NSLog(@"[VersionMgr] Renderer for profile '%@' set to '%@' (%@)", self.selectedProfile, key, displayName);
}

#pragma mark - Graphics API Selection (in-game OpenGL/Vulkan for MC 26.2+)

/// Select a graphics API and save it to the current profile
/// Note: graphicsApi and renderer are two different dimensions:
///   - renderer: which native library LWJGL loads (libgl4es/libMoltenVK etc.)
///   - graphicsApi: whether MC 26.2+ internally takes the OpenGL path or the Vulkan path
/// When the user selects prefer_vulkan it is advisable to also set renderer to libMoltenVK.dylib,
/// but they are deliberately not linked here, so advanced users can configure them separately.
- (void)selectGraphicsApiAtIndex:(NSInteger)index {
    if (!self.selectedProfile) {
        [self showAlert:@"Select a version first"];
        return;
    }
    if (index >= (NSInteger)self.graphicsApiKeys.count) return;

    NSString *key = self.graphicsApiKeys[index];
    NSString *displayName = index < (NSInteger)self.graphicsApiNames.count ? self.graphicsApiNames[index] : key;

    // Write to the graphicsApi field of the current profile
    NSMutableDictionary *profiles = PLProfiles.current.profiles;
    NSMutableDictionary *profile = [profiles[self.selectedProfile] mutableCopy];
    if (!profile) {
        profile = [NSMutableDictionary dictionary];
    }
    profile[@"graphicsApi"] = key;
    profiles[self.selectedProfile] = profile;
    [PLProfiles.current save];

    // Sync to the global preference
    setPrefString(@"video.graphics_api", key);

    [self.collectionView reloadData];

    NSLog(@"[VersionMgr] Graphics API for profile '%@' set to '%@' (%@)", self.selectedProfile, key, displayName);
}

#pragma mark - Quick Actions

- (void)openModsManager {
    if (!self.selectedProfile) {
        [self showAlert:@"Select a version first"];
        return;
    }
    ModsManagerViewController *vc = [[ModsManagerViewController alloc] init];
    vc.profileName = self.selectedProfile;
    vc.initialMode = ModsManagerModeLocal;
    [self.navigationController pushViewController:vc animated:YES];
}

- (void)openShadersManager {
    if (!self.selectedProfile) {
        [self showAlert:@"Select a version first"];
        return;
    }
    ShadersManagerViewController *vc = [[ShadersManagerViewController alloc] init];
    vc.profileName = self.selectedProfile;
    vc.initialMode = ShadersManagerModeLocal;
    [self.navigationController pushViewController:vc animated:YES];
}

- (void)openResourcePacksManager {
    if (!self.selectedProfile) {
        [self showAlert:@"Select a version first"];
        return;
    }
    ResourcePacksManagerViewController *vc = [[ResourcePacksManagerViewController alloc] init];
    vc.profileName = self.selectedProfile;
    vc.initialMode = ResourcePacksManagerModeLocal;
    [self.navigationController pushViewController:vc animated:YES];
}

- (void)openDataPacksManager {
    if (!self.selectedProfile) {
        [self showAlert:@"Select a version first"];
        return;
    }
    DataPacksManagerViewController *vc = [[DataPacksManagerViewController alloc] init];
    vc.profileName = self.selectedProfile;
    vc.initialMode = DataPacksManagerModeLocal;
    [self.navigationController pushViewController:vc animated:YES];
}

- (void)openWorldsManager {
    if (!self.selectedProfile) {
        [self showAlert:@"Select a version first"];
        return;
    }
    WorldsManagerViewController *vc = [[WorldsManagerViewController alloc] init];
    vc.profileName = self.selectedProfile;
    vc.initialMode = WorldsManagerModeLocal;
    [self.navigationController pushViewController:vc animated:YES];
}

#pragma mark - Profile Actions

- (void)showProfileActions:(NSString *)profileName {
    NSDictionary *profile = PLProfiles.current.profiles[profileName];
    BOOL isSelected = [profileName isEqualToString:self.selectedProfile];

    UIAlertController *alert = [UIAlertController alertControllerWithTitle:profileName
                                                                   message:profile[@"lastVersionId"]
                                                            preferredStyle:UIAlertControllerStyleActionSheet];

    if (!isSelected) {
        [alert addAction:[UIAlertAction actionWithTitle:@"Select this version" style:UIAlertActionStyleDefault handler:^(UIAlertAction * _Nonnull action) {
            PLProfiles.current.selectedProfileName = profileName;
            [PLProfiles.current save];
            [[NSNotificationCenter defaultCenter] postNotificationName:@"SelectedProfileChanged" object:nil];
            [self loadProfiles];
            [self.collectionView reloadData];
        }]];
    }

    [alert addAction:[UIAlertAction actionWithTitle:@"Edit profile" style:UIAlertActionStyleDefault handler:^(UIAlertAction * _Nonnull action) {
        [self editProfile:profileName];
    }]];

    [alert addAction:[UIAlertAction actionWithTitle:@"Delete" style:UIAlertActionStyleDestructive handler:^(UIAlertAction * _Nonnull action) {
        [self deleteProfile:profileName];
    }]];

    [alert addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];

    if (UIDevice.currentDevice.userInterfaceIdiom == UIUserInterfaceIdiomPad) {
        alert.popoverPresentationController.sourceView = self.view;
        alert.popoverPresentationController.sourceRect = CGRectMake(self.view.bounds.size.width / 2, self.view.bounds.size.height / 2, 1, 1);
        alert.popoverPresentationController.permittedArrowDirections = UIPopoverArrowDirectionAny;
    }
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)editProfile:(NSString *)profileName {
    // Use ProfileSettingsViewController (the merged, unified Edit Profile page, new UI)
    ProfileSettingsViewController *vc = [[ProfileSettingsViewController alloc] init];
    vc.profileName = profileName;
    [self.navigationController pushViewController:vc animated:YES];
}

- (void)deleteProfile:(NSString *)profileName {
    if (self.profileList.count <= 1) {
        [self showAlert:@"At least one profile must remain"];
        return;
    }

    UIAlertController *confirm = [UIAlertController alertControllerWithTitle:@"Confirm delete"
                                                                     message:[NSString stringWithFormat:@"Delete \"%@\"?", profileName]
                                                              preferredStyle:UIAlertControllerStyleAlert];

    [confirm addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    [confirm addAction:[UIAlertAction actionWithTitle:@"Delete" style:UIAlertActionStyleDestructive handler:^(UIAlertAction * _Nonnull action) {
        [PLProfiles.current.profiles removeObjectForKey:profileName];
        if ([PLProfiles.current.selectedProfileName isEqualToString:profileName]) {
            PLProfiles.current.selectedProfileName = PLProfiles.current.profiles.allKeys.firstObject;
        }
        [PLProfiles.current save];
        [self loadProfiles];
        [self.collectionView reloadData];
        [self updateEmptyState];
    }]];

    [self presentViewController:confirm animated:YES completion:nil];
}

- (void)showAlert:(NSString *)message {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Notice" message:message preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
}

#pragma mark - Orientation

- (BOOL)shouldAutorotate {
    return YES;
}

- (UIInterfaceOrientationMask)supportedInterfaceOrientations {
    if ([ScreenUtils isPad]) {
        return UIInterfaceOrientationMaskAll;
    }
    return UIInterfaceOrientationMaskAllButUpsideDown;
}

@end
