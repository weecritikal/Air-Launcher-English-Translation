#import "ArchiveIntegrity.h"
#import "DownloadViewController.h"
#import "BackgroundManager.h"
// IconLoader: the unified project icon loader (two-level cache + downsampling + concurrency control + CDN mirrors),
// replacing UIImageView+AFNetworking (memory cache only, no downsampling, no mirrors)
// Modelled on the best practices of FCL Glide and ZL2 Coil
#import "IconLoader.h"
#import "DownloadTaskManager.h"
#import "DownloadTaskItem.h"
#import "InlineMessageView.h"
#import "installer/modpack/ModrinthAPI.h"
#import "installer/modpack/CurseForgeAPI.h"
#import "PLPreferences.h"
#import "ModService.h"
#import "ShaderService.h"
#import "ResourcePackService.h"
#import "DataPackService.h"
#import "PLProfiles.h"
#import "LauncherPreferences.h"
#import "VersionCardCell.h"
#import "MinecraftResourceDownloadTask.h"
#import "DownloadProgressViewController.h"
#import "ModItem.h"
#import "ModVersionViewController.h"
#import "ModVersion.h"
#import "ShaderItem.h"
#import "ShaderVersionViewController.h"
#import "ShaderVersion.h"
#import "ResourcePackItem.h"
#import "DataPackItem.h"
#import "WorldItem.h"
#import "AssetVersionViewController.h"
#import "WorldService.h"
#import "installer/FabricInstallViewController.h"
#import "installer/ForgeInstallViewController.h"
#import "installer/ForgeDirectInstaller.h"
#import "installer/NeoForgeDirectInstaller.h"
#import "installer/NeoForgeVersionFetcher.h"
#import "installer/ModLoaderInstallViewController.h"
#import "LauncherNavigationController.h"
#import "installer/ModpackInstallViewController.h"
#import "ModpackImportViewController.h"
#import "ModpackImportService.h"
#import "ModpackExportService.h"
#import "installer/CurseForgeAPIKeyViewController.h"
#import "UZKArchive.h"
#import <QuartzCore/QuartzCore.h>
#import "JavaGUIViewController.h"
#import "utils.h"
#import "ios_uikit_bridge.h"
#import "ALTServerConnection.h"
#import "ModLoaderIconHelper.h"
#import "DownloadProgressCardView.h"

#include <sys/time.h>
#include <SystemConfiguration/SystemConfiguration.h>
#include <netinet/in.h>
#import "FluxTheme.h"

#pragma mark - Modern Asset Cell

// Asset type enum: decides the placeholder icon and colors for the 6 asset kinds (mod/shader/resourcepack/datapack/world/modpack)
// Modelled on the icon systems of FCL CategoryBox and ZL2 AddonListLayout, using SF Symbols instead of bundled PNGs
typedef NS_ENUM(NSInteger, ModernAssetType) {
    ModernAssetTypeMod = 0,           // Mod: puzzlepiece.fill + orange
    ModernAssetTypeShader,            // Shader: paintbrush.fill + purple
    ModernAssetTypeResourcepack,      // Resource pack: photo.stack.fill + blue
    ModernAssetTypeDatapack,          // Data pack: doc.text.fill + cyan
    ModernAssetTypeWorld,             // World: globe.asia.australia.fill + green
    ModernAssetTypeModpack            // Modpack: shippingbox.fill + pink
};

@interface ModernAssetCell : UITableViewCell
@property (nonatomic, strong) UIView *contentContainer;
@property (nonatomic, strong) UIImageView *iconView;
@property (nonatomic, strong) UILabel *titleLabel;
@property (nonatomic, strong) UILabel *descLabel;
@property (nonatomic, strong) UILabel *metaLabel;
@property (nonatomic, strong) UIStackView *tagsStack;
@property (nonatomic, strong) UIButton *downloadButton;
// Current asset type (used to reset the placeholder icon and colors in prepareForReuse)
@property (nonatomic, assign) ModernAssetType assetType;
// Caches the URL of the image currently loading, so an old request cannot overwrite a newer one on reuse (a cell-reuse race)
@property (nonatomic, copy, nullable) NSString *currentIconURL;
@end

@implementation ModernAssetCell

- (instancetype)initWithStyle:(UITableViewCellStyle)style reuseIdentifier:(NSString *)reuseIdentifier {
    self = [super initWithStyle:style reuseIdentifier:reuseIdentifier];
    if (self) {
        self.selectionStyle = UITableViewCellSelectionStyleDefault;
        self.backgroundColor = [UIColor clearColor];
        self.contentView.backgroundColor = [UIColor clearColor];
        self.assetType = ModernAssetTypeMod;

        // FCL view_installer_item.xml style: a flat row with no card container, shadow or border
        // It relies solely on BackgroundManager.applyEffectToView: for the frosted-glass/translucent background
        // Row separation comes from the vertical padding inside rowHeight (mirroring FCL marginBottom 10dp)
        self.contentContainer = [[UIView alloc] init];
        self.contentContainer.translatesAutoresizingMaskIntoConstraints = NO;
        // Equivalent of FCL bg_container_white_clickable: a light translucent background + rounded corners
        self.contentContainer.backgroundColor = [[UIColor whiteColor] colorWithAlphaComponent:0.06];
        self.contentContainer.layer.cornerRadius = 8;
        self.contentContainer.layer.cornerCurve = kCACornerCurveContinuous;
        // No shadow or border (the flat FCL style does not need them)
        [self.contentView addSubview:self.contentContainer];

        // ----- Icon on the left: 26x26 (FCL uses 30dp; slightly smaller in compact mode) -----
        self.iconView = [[UIImageView alloc] init];
        self.iconView.translatesAutoresizingMaskIntoConstraints = NO;
        self.iconView.layer.cornerRadius = 5;
        self.iconView.layer.cornerCurve = kCACornerCurveContinuous;
        self.iconView.clipsToBounds = YES;
        self.iconView.backgroundColor = [[UIColor whiteColor] colorWithAlphaComponent:0.06];
        self.iconView.contentMode = UIViewContentModeScaleAspectFit;
        self.iconView.tintColor = [UIColor systemOrangeColor];
        [self.contentContainer addSubview:self.iconView];

        // ----- Title: 13pt Medium (FCL title is 14sp; slightly smaller in compact mode) -----
        self.titleLabel = [[UILabel alloc] init];
        self.titleLabel.translatesAutoresizingMaskIntoConstraints = NO;
        self.titleLabel.font = [UIFont systemFontOfSize:13 weight:UIFontWeightMedium];
        self.titleLabel.textColor = [UIColor labelColor];
        self.titleLabel.numberOfLines = 1;
        self.titleLabel.lineBreakMode = NSLineBreakByTruncatingTail;
        [self.titleLabel setContentCompressionResistancePriority:UILayoutPriorityDefaultLow forAxis:UILayoutConstraintAxisHorizontal];
        [self.contentContainer addSubview:self.titleLabel];

        // ----- Second line: download count + description (FCL download_count 12sp + description 12sp) -----
        self.descLabel = [[UILabel alloc] init];
        self.descLabel.translatesAutoresizingMaskIntoConstraints = NO;
        self.descLabel.font = [UIFont systemFontOfSize:11];
        self.descLabel.textColor = [UIColor secondaryLabelColor];
        self.descLabel.numberOfLines = 1;
        self.descLabel.lineBreakMode = NSLineBreakByTruncatingTail;
        [self.contentContainer addSubview:self.descLabel];

        // ----- Meta info hidden (merged into the second line of descLabel) -----
        self.metaLabel = [[UILabel alloc] init];
        self.metaLabel.translatesAutoresizingMaskIntoConstraints = NO;
        self.metaLabel.hidden = YES;
        [self.contentContainer addSubview:self.metaLabel];

        // ----- Tag stack: sits at the right of the second line (FCL tag 11sp, padding 4dp/2dp) -----
        self.tagsStack = [[UIStackView alloc] init];
        self.tagsStack.translatesAutoresizingMaskIntoConstraints = NO;
        self.tagsStack.axis = UILayoutConstraintAxisHorizontal;
        self.tagsStack.spacing = 4;
        self.tagsStack.distribution = UIStackViewDistributionFill;
        self.tagsStack.alignment = UIStackViewAlignmentCenter;
        [self.contentContainer addSubview:self.tagsStack];

        // ----- Download button: 24x24 on the right (compact FCL-style button) -----
        self.downloadButton = [UIButton buttonWithType:UIButtonTypeSystem];
        self.downloadButton.translatesAutoresizingMaskIntoConstraints = NO;
        UIImage *downloadSymbol = [UIImage systemImageNamed:@"arrow.down.circle.fill"
                                          withConfiguration:[UIImageSymbolConfiguration configurationWithPointSize:18 weight:UIFontWeightRegular]];
        if (!downloadSymbol) {
            downloadSymbol = [UIImage systemImageNamed:@"arrow.down.circle.fill"];
        }
        [self.downloadButton setImage:downloadSymbol forState:UIControlStateNormal];
        self.downloadButton.tintColor = [UIColor systemGreenColor];
        self.downloadButton.showsTouchWhenHighlighted = NO;
        [self.downloadButton setContentHuggingPriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisHorizontal];
        [self.downloadButton setContentCompressionResistancePriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisHorizontal];
        [self.contentContainer addSubview:self.downloadButton];

        [NSLayoutConstraint activateConstraints:@[
            // Equivalent of FCL marginBottom 10dp / padding 8dp,10dp: 3pt top and bottom + 8pt left and right (compact)
            [self.contentContainer.topAnchor constraintEqualToAnchor:self.contentView.topAnchor constant:3],
            [self.contentContainer.leadingAnchor constraintEqualToAnchor:self.contentView.leadingAnchor constant:8],
            [self.contentContainer.trailingAnchor constraintEqualToAnchor:self.contentView.trailingAnchor constant:-8],
            [self.contentContainer.bottomAnchor constraintEqualToAnchor:self.contentView.bottomAnchor constant:-3],

            // Icon: 8 from the left, vertically centered, 26x26
            [self.iconView.leadingAnchor constraintEqualToAnchor:self.contentContainer.leadingAnchor constant:8],
            [self.iconView.centerYAnchor constraintEqualToAnchor:self.contentContainer.centerYAnchor],
            [self.iconView.widthAnchor constraintEqualToConstant:26],
            [self.iconView.heightAnchor constraintEqualToConstant:26],

            // Title: 8 to the right of the icon, 6 below the top of the container
            [self.titleLabel.leadingAnchor constraintEqualToAnchor:self.iconView.trailingAnchor constant:8],
            [self.titleLabel.topAnchor constraintEqualToAnchor:self.contentContainer.topAnchor constant:6],
            [self.titleLabel.trailingAnchor constraintLessThanOrEqualToAnchor:self.downloadButton.leadingAnchor constant:-4],

            // Second line descLabel: 2 below the title, left-aligned with it
            [self.descLabel.leadingAnchor constraintEqualToAnchor:self.titleLabel.leadingAnchor],
            [self.descLabel.topAnchor constraintEqualToAnchor:self.titleLabel.bottomAnchor constant:2],
            [self.descLabel.trailingAnchor constraintLessThanOrEqualToAnchor:self.tagsStack.leadingAnchor constant:-4],
            [self.descLabel.bottomAnchor constraintLessThanOrEqualToAnchor:self.contentContainer.bottomAnchor constant:-6],

            // Tag stack: on the same line as descLabel, flush against the download button
            [self.tagsStack.centerYAnchor constraintEqualToAnchor:self.descLabel.centerYAnchor],
            [self.tagsStack.trailingAnchor constraintLessThanOrEqualToAnchor:self.downloadButton.leadingAnchor constant:-4],

            // Download button: -6 from the right, vertically centered, 24x24
            [self.downloadButton.trailingAnchor constraintEqualToAnchor:self.contentContainer.trailingAnchor constant:-6],
            [self.downloadButton.centerYAnchor constraintEqualToAnchor:self.contentContainer.centerYAnchor],
            [self.downloadButton.widthAnchor constraintEqualToConstant:24],
            [self.downloadButton.heightAnchor constraintEqualToConstant:24]
        ]];

        // Apply the frosted-glass background effect (BackgroundManager handles light/dark and blur amount centrally)
        [[BackgroundManager sharedManager] applyEffectToView:self.contentContainer];
    }
    return self;
}

- (void)prepareForReuse {
    [super prepareForReuse];
    // Cancel the icon load in flight for this cell (an old request should not keep using the network and firing callbacks after reuse)
    // Equivalent to Glide's clear() and the automatic cancellation of ZL2 Compose composition
    [IconLoader cancelLoadingForImageView:self.iconView];
    // Reset the icon state, so a stale image from a previous use does not show up in the wrong row
    self.iconView.image = nil;
    self.iconView.tintColor = [UIColor systemOrangeColor];
    self.iconView.contentMode = UIViewContentModeScaleAspectFit;
    self.iconView.backgroundColor = [[UIColor whiteColor] colorWithAlphaComponent:0.06];
    self.currentIconURL = nil;
    // Remove every tag
    [self.tagsStack.arrangedSubviews makeObjectsPerformSelector:@selector(removeFromSuperview)];
    // Reset the download button target (so a stale target after reuse cannot trigger the wrong download)
    [self.downloadButton removeTarget:nil action:NULL forControlEvents:UIControlEventAllEvents];
}

#pragma mark - Placeholder icons and colors (by resource type)

/// Return the default placeholder SF Symbol name for an asset type
- (NSString *)placeholderIconNameForType:(ModernAssetType)type {
    switch (type) {
        case ModernAssetTypeMod:          return @"puzzlepiece.fill";
        case ModernAssetTypeShader:       return @"paintbrush.fill";
        case ModernAssetTypeResourcepack: return @"photo.stack.fill";
        case ModernAssetTypeDatapack:     return @"doc.text.fill";
        case ModernAssetTypeWorld:        return @"globe.asia.australia.fill";
        case ModernAssetTypeModpack:      return @"shippingbox.fill";
    }
    return @"puzzlepiece.fill";
}

/// Return the primary placeholder icon color for an asset type (used as iconView.tintColor, matching the FCL/ZL2 colors per asset type)
- (UIColor *)placeholderColorForType:(ModernAssetType)type {
    switch (type) {
        case ModernAssetTypeMod:          return [UIColor systemOrangeColor];
        case ModernAssetTypeShader:       return [UIColor systemPurpleColor];
        case ModernAssetTypeResourcepack: return FluxTheme.accent;
        case ModernAssetTypeDatapack:     return [UIColor systemTealColor];
        case ModernAssetTypeWorld:        return [UIColor systemGreenColor];
        case ModernAssetTypeModpack:      return [UIColor systemPinkColor];
    }
    return [UIColor systemOrangeColor];
}

/// Apply the placeholder icon: show the SF Symbol for the type first, then swap in the project icon once it loads
- (void)applyPlaceholderIconForType:(ModernAssetType)type {
    NSString *iconName = [self placeholderIconNameForType:type];
    UIColor *iconColor = [self placeholderColorForType:type];
    UIImage *symbol = [UIImage systemImageNamed:iconName];
    if (symbol) {
        self.iconView.image = symbol;
    } else {
        self.iconView.image = [UIImage systemImageNamed:@"puzzlepiece.fill"];
    }
    self.iconView.tintColor = iconColor;
    self.iconView.contentMode = UIViewContentModeScaleAspectFit;
}

#pragma mark - Shared configuration helpers

/// Format a download count: 1234 -> "1.2K", 1234567 -> "1.2M"
- (NSString *)formatDownloadCount:(NSNumber *)downloads {
    if (!downloads) return @"0";
    NSInteger dl = [downloads integerValue];
    if (dl >= 1000000) {
        return [NSString stringWithFormat:@"%.1fM", dl / 1000000.0];
    } else if (dl >= 1000) {
        return [NSString stringWithFormat:@"%.1fK", dl / 1000.0];
    } else {
        return [NSString stringWithFormat:@"%ld", (long)dl];
    }
}

/// Format a date string: "2024-01-15T12:34:56Z" -> "2024-01-15"; returns an empty string on failure
- (NSString *)formatDateString:(NSString *)dateString {
    if (![dateString isKindOfClass:[NSString class]] || dateString.length < 10) return @"";
    return [dateString substringToIndex:10];
}

/// Load the project icon asynchronously (using the unified IconLoader)
/// Mirrors the loadIcon logic of ZL2 AssetsIcon: two-level cache + downsampling + CDN mirror + placeholder/fallback
- (void)loadIconFromURL:(NSString *)iconUrl placeholderType:(ModernAssetType)type {
    // Show the placeholder icon first (the SF Symbol for the type, shown while loading)
    [self applyPlaceholderIconForType:type];

    if (![iconUrl isKindOfClass:[NSString class]] || iconUrl.length == 0) {
        return;
    }

    // Record the URL currently loading, so an old request cannot overwrite a newer one after cell reuse
    self.currentIconURL = [iconUrl copy];

    // Build the fallback image: the same as the placeholder, so the type SF Symbol also shows if loading fails
    UIImage *placeholder = self.iconView.image;
    UIImage *fallback = [UIImage systemImageNamed:[self placeholderIconNameForType:type]] ?: placeholder;

    // Load via IconLoader (which handles cancelling the old request, placeholder, memory cache, disk cache, downsampled decode, CDN mirror and fallback)
    // The icon is displayed at 26x26 (FCL uses 30dp; slightly smaller in compact mode), so downsample to that size instead of decoding the full image
    __weak typeof(self) weakSelf = self;
    [IconLoader loadIconForImageView:self.iconView
                                 URL:iconUrl
                         placeholder:placeholder
                            fallback:fallback
                           targetSize:CGSizeMake(26, 26)
                              options:IconLoaderOptionsDefault
                           completion:^(UIImage *image) {
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf || !image) return;
        // Check: currentIconURL may have changed after cell reuse, so a stale image does not land on the new cell
        // (IconLoader already checks this internally via associated objects; checking again here is safer)
        if (![strongSelf.currentIconURL isEqualToString:iconUrl]) return;
        // The real project icon uses AspectFill, overriding the AspectFit style of the placeholder SF Symbol
        strongSelf.iconView.contentMode = UIViewContentModeScaleAspectFill;
        strongSelf.iconView.tintColor = [UIColor clearColor];
    }];
}

/// Configure the tag stack: take at most 3 entries from categories, colored by loader/category
/// Modelled on ZL2 LittleTextLabel: mod loaders use their brand color, ordinary categories use neutral colors
- (void)configureTagsWithCategories:(NSArray *)categories {
    [self.tagsStack.arrangedSubviews makeObjectsPerformSelector:@selector(removeFromSuperview)];
    if (![categories isKindOfClass:[NSArray class]]) return;

    for (NSInteger i = 0; i < MIN(3, categories.count); i++) {
        id catObj = categories[i];
        NSString *cat = nil;
        if ([catObj isKindOfClass:[NSString class]]) {
            cat = catObj;
        } else if ([catObj isKindOfClass:[NSDictionary class]]) {
            // CurseForge categories are dictionaries, so read the name field
            cat = catObj[@"name"];
        }
        if (![cat isKindOfClass:[NSString class]] || cat.length == 0) continue;

        UILabel *tag = [self createTagLabel:cat];
        [self.tagsStack addArrangedSubview:tag];
    }
}

/// Return the color for a category name: loader brand colors are delegated to ModLoaderIconHelper, category colors stay local
- (UIColor *)colorForCategory:(NSString *)category {
    NSString *lower = category.lowercaseString;
    // Loader brand colors: delegated to ModLoaderIconHelper (which prefers the official colors of the PNG icons)
    if ([ModLoaderIconHelper isKnownLoader:category]) {
        return [ModLoaderIconHelper brandColorForLoader:category];
    }
    // Colors for the common mod categories
    if ([lower containsString:@"magic"])     return [UIColor systemPurpleColor];
    if ([lower containsString:@"tech"])      return [UIColor systemOrangeColor];
    if ([lower containsString:@"adventure"]) return [UIColor systemTealColor];
    if ([lower containsString:@"decoration"]) return [UIColor systemPinkColor];
    if ([lower containsString:@"utility"])   return FluxTheme.accent;
    if ([lower containsString:@"world"])     return [UIColor systemGreenColor];
    // Fallback
    return [UIColor tertiaryLabelColor];
}

- (UILabel *)createTagLabel:(NSString *)text {
    UILabel *label = [[UILabel alloc] init];
    label.text = text;
    // FCL tag 11sp Medium (10pt in compact mode)
    label.font = [UIFont systemFontOfSize:10 weight:UIFontWeightMedium];
    label.textColor = [UIColor whiteColor];
    label.backgroundColor = [self colorForCategory:text];
    label.layer.cornerRadius = 4;
    label.layer.cornerCurve = kCACornerCurveContinuous;
    label.layer.masksToBounds = YES;
    label.textAlignment = NSTextAlignmentCenter;
    [label setContentHuggingPriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisHorizontal];
    [label setContentCompressionResistancePriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisHorizontal];
    // Padding: 5 left and right, 1 top and bottom (equivalent to FCL padding 4dp/2dp, slightly smaller in compact mode)
    label.translatesAutoresizingMaskIntoConstraints = NO;
    [NSLayoutConstraint activateConstraints:@[
        [label.heightAnchor constraintEqualToConstant:14]
    ]];
    [label sizeToFit];
    CGFloat textWidth = label.frame.size.width;
    [label.widthAnchor constraintEqualToConstant:textWidth + 8].active = YES;
    return label;
}

#pragma mark - Configuration entry points per resource type

- (void)configureWithMod:(NSDictionary *)mod {
    self.assetType = ModernAssetTypeMod;
    [self configureCommonWithData:mod type:ModernAssetTypeMod];
}

- (void)configureWithShader:(NSDictionary *)shader {
    self.assetType = ModernAssetTypeShader;
    [self configureCommonWithData:shader type:ModernAssetTypeShader];
}

- (void)configureWithResourcepack:(NSDictionary *)resourcepack {
    self.assetType = ModernAssetTypeResourcepack;
    [self configureCommonWithData:resourcepack type:ModernAssetTypeResourcepack];
}

- (void)configureWithDatapack:(NSDictionary *)datapack {
    self.assetType = ModernAssetTypeDatapack;
    [self configureCommonWithData:datapack type:ModernAssetTypeDatapack];
}

- (void)configureWithWorld:(NSDictionary *)world {
    self.assetType = ModernAssetTypeWorld;
    [self configureCommonWithData:world type:ModernAssetTypeWorld];
}

- (void)configureWithModpack:(NSDictionary *)modpack {
    self.assetType = ModernAssetTypeModpack;
    [self configureCommonWithData:modpack type:ModernAssetTypeModpack];
}

/// Shared configuration for all 6 asset types: title/description/meta/icon/tags
/// FCL style: 14sp title + a second line (download count + description), with meta info (author/date) merged into descLabel
- (void)configureCommonWithData:(NSDictionary *)data type:(ModernAssetType)type {
    self.titleLabel.text = data[@"title"] ?: data[@"slug"] ?: @"Unknown";

    // Second line: download count + description (FCL puts download_count and description on one line)
    NSString *downloadsStr = [self formatDownloadCount:data[@"downloads"]];
    NSString *description = data[@"description"] ?: @"";
    // Truncate the description so it does not squeeze out the download count
    NSString *truncatedDesc = description;
    if (truncatedDesc.length > 40) {
        truncatedDesc = [[description substringToIndex:40] stringByAppendingString:@"…"];
    }
    self.descLabel.text = [NSString stringWithFormat:@"%@ downloads  •  %@", downloadsStr, truncatedDesc];

    // metaLabel is now hidden (the property is kept for compatibility with older code) and no longer set
    self.metaLabel.text = @"";

    // Icon: placeholder first, then load the project icon asynchronously
    NSString *iconUrl = data[@"imageUrl"] ?: data[@"icon_url"];
    [self loadIconFromURL:iconUrl placeholderType:type];

    // Tags
    [self configureTagsWithCategories:data[@"categories"]];
}

@end

// LoaderCell and LoaderSelectionViewController have moved to installer/ModLoaderInstallViewController.m
// Reworked after the InstallerListPage + VersionInstallInfoPage of FCL (FoldCraftLauncher)


#pragma mark - Installer Progress View Controller (FCL style progress display)

@interface InstallerProgressViewController : UIViewController
// Progress 0.0~1.0; <0 means indeterminate mode (only a spinner, for network stages where progress cannot be measured)
@property (nonatomic, assign) double progress;
@property (nonatomic, copy, nullable) NSString *stageMessage;
@property (nonatomic, copy, nullable) NSString *titleText;
@property (nonatomic, copy, nullable) void (^cancelHandler)(void);

// ===== Added in phase 12: FCL/ZL2-style enhanced fields =====
// Category icon (SF Symbol name), e.g. "cube.box.fill"=vanilla / "wand.and.stars"=Fabric / "archivebox.fill"=modpack
@property (nonatomic, copy, nullable) NSString *categoryIconName;
// Category icon color (falls back to accentColor when unset)
@property (nonatomic, strong, nullable) UIColor *categoryIconColor;
// Detail info line (e.g. "42.3 MB / 102.5 MB • 3.2 MB/s"); hidden when unset
@property (nonatomic, copy, nullable) NSString *detailInfoText;
// Time-remaining text (e.g. "18s left"); hidden when unset
@property (nonatomic, copy, nullable) NSString *etaText;
// Stage list: each element is an NSDictionary with @"title" (NSString) and @"status" (NSNumber: 0=not started, 1=in progress, 2=done)
@property (nonatomic, copy, nullable) NSArray<NSDictionary *> *stageSteps;
@end

@interface InstallerProgressViewController ()
@property (nonatomic, strong) UIView *cardView;
@property (nonatomic, strong) UIImageView *iconView; // Category icon (48x48)
@property (nonatomic, strong) UILabel *titleLabel;
@property (nonatomic, strong) UILabel *percentLabel;
@property (nonatomic, strong) UIProgressView *progressBar;
@property (nonatomic, strong) UILabel *detailInfoLabel; // File size + speed
@property (nonatomic, strong) UILabel *etaLabel; // Time remaining
@property (nonatomic, strong) UIView *stagesContainer; // Container for the stage list
@property (nonatomic, strong) UIStackView *stagesStack; // Stages arranged vertically
@property (nonatomic, strong) UILabel *stageLabel;
@property (nonatomic, strong) UIActivityIndicatorView *indeterminateIndicator;
@end

@implementation InstallerProgressViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    // Adapt to the custom launcher background (as in ForgeInstallViewController)
    [[BackgroundManager sharedManager] makeViewControllerTransparent:self];
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(refreshBackgroundEffect)
                                                 name:@"BackgroundUIEffectChanged"
                                               object:nil];

    // Cancel button (instead of a back button, so it does not look like the install already finished)
    self.navigationItem.leftBarButtonItem = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemCancel
                                                                                          target:self
                                                                                          action:@selector(cancelTapped)];
    self.navigationItem.hidesBackButton = YES;

    [self setupUI];
    [self updateUI];
}

- (void)refreshBackgroundEffect {
    // Nothing extra is needed against a transparent background
}

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

- (void)setupUI {
    self.cardView = [[UIView alloc] init];
    self.cardView.translatesAutoresizingMaskIntoConstraints = NO;
    self.cardView.backgroundColor = [UIColor clearColor];
    [[BackgroundManager sharedManager] applyEffectToView:self.cardView];
    self.cardView.layer.cornerRadius = 16;
    self.cardView.layer.masksToBounds = YES;
    [self.view addSubview:self.cardView];

    // ===== Category icon (48x48, modelled on the category icon at the top of the FCL install page) =====
    self.iconView = [[UIImageView alloc] init];
    self.iconView.translatesAutoresizingMaskIntoConstraints = NO;
    self.iconView.contentMode = UIViewContentModeScaleAspectFit;
    self.iconView.tintColor = accentColor();
    self.iconView.image = [UIImage systemImageNamed:@"cube.box.fill"];
    self.iconView.hidden = YES; // Hidden by default, shown once categoryIconName is set
    [self.cardView addSubview:self.iconView];

    self.titleLabel = [[UILabel alloc] init];
    self.titleLabel.translatesAutoresizingMaskIntoConstraints = NO;
    self.titleLabel.font = [UIFont systemFontOfSize:20 weight:UIFontWeightBold];
    self.titleLabel.textAlignment = NSTextAlignmentCenter;
    self.titleLabel.numberOfLines = 0;
    self.titleLabel.text = @"Installing";
    [self.cardView addSubview:self.titleLabel];

    self.percentLabel = [[UILabel alloc] init];
    self.percentLabel.translatesAutoresizingMaskIntoConstraints = NO;
    self.percentLabel.font = [UIFont systemFontOfSize:36 weight:UIFontWeightHeavy];
    self.percentLabel.textAlignment = NSTextAlignmentCenter;
    // Use the launcher theme accent color (accentColor), matching the play button and selected menu items.
    // When the user changes the theme color in settings, the progress percentage changes with it (FCL auto_tint style).
    self.percentLabel.textColor = accentColor();
    self.percentLabel.text = @"0%";
    [self.cardView addSubview:self.percentLabel];

    self.indeterminateIndicator = [[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleLarge];
    self.indeterminateIndicator.translatesAutoresizingMaskIntoConstraints = NO;
    self.indeterminateIndicator.hidesWhenStopped = YES;
    self.indeterminateIndicator.hidden = YES;
    [self.cardView addSubview:self.indeterminateIndicator];

    self.progressBar = [[UIProgressView alloc] initWithProgressViewStyle:UIProgressViewStyleDefault];
    self.progressBar.translatesAutoresizingMaskIntoConstraints = NO;
    self.progressBar.progress = 0.0;
    // The progress bar fill follows the theme accent color too, matching the percentage text and the play button
    self.progressBar.progressTintColor = accentColor();
    [self.cardView addSubview:self.progressBar];

    // ===== Detail info line (file size + speed, modelled on the file info line of the FCL install page) =====
    self.detailInfoLabel = [[UILabel alloc] init];
    self.detailInfoLabel.translatesAutoresizingMaskIntoConstraints = NO;
    self.detailInfoLabel.font = [UIFont systemFontOfSize:13 weight:UIFontWeightMedium];
    self.detailInfoLabel.textAlignment = NSTextAlignmentCenter;
    self.detailInfoLabel.textColor = [UIColor secondaryLabelColor];
    self.detailInfoLabel.hidden = YES; // Hidden by default, shown once detailInfoText is set
    [self.cardView addSubview:self.detailInfoLabel];

    // ===== Time remaining (ETA, modelled on the time remaining shown on the FCL install page) =====
    self.etaLabel = [[UILabel alloc] init];
    self.etaLabel.translatesAutoresizingMaskIntoConstraints = NO;
    self.etaLabel.font = [UIFont systemFontOfSize:12];
    self.etaLabel.textAlignment = NSTextAlignmentCenter;
    self.etaLabel.textColor = [UIColor tertiaryLabelColor];
    self.etaLabel.hidden = YES; // Hidden by default, shown once etaText is set
    [self.cardView addSubview:self.etaLabel];

    // ===== Stage container (modelled on the FCL install step list, showing ✓/◐/○ states) =====
    self.stagesContainer = [[UIView alloc] init];
    self.stagesContainer.translatesAutoresizingMaskIntoConstraints = NO;
    self.stagesContainer.hidden = YES; // Hidden by default, shown once stageSteps is set
    [self.cardView addSubview:self.stagesContainer];

    self.stagesStack = [[UIStackView alloc] init];
    self.stagesStack.translatesAutoresizingMaskIntoConstraints = NO;
    self.stagesStack.axis = UILayoutConstraintAxisVertical;
    self.stagesStack.spacing = 8;
    self.stagesStack.alignment = UIStackViewAlignmentLeading;
    self.stagesStack.distribution = UIStackViewDistributionFill;
    [self.stagesContainer addSubview:self.stagesStack];

    self.stageLabel = [[UILabel alloc] init];
    self.stageLabel.translatesAutoresizingMaskIntoConstraints = NO;
    self.stageLabel.font = [UIFont systemFontOfSize:14];
    self.stageLabel.textAlignment = NSTextAlignmentCenter;
    self.stageLabel.textColor = [UIColor secondaryLabelColor];
    self.stageLabel.numberOfLines = 0;
    self.stageLabel.text = @"Preparing...";
    [self.cardView addSubview:self.stageLabel];

    // A container view plus a vertical stack organizes everything, so stagesContainer can be shown/hidden dynamically
    // Layout strategy: everything is stacked top to bottom, with the bottom of stagesContainer constrained to the top of stageLabel
    // The bottom of cardView is constrained to the bottom of stageLabel, so the height collapses to 0 when stagesContainer is hidden
    [NSLayoutConstraint activateConstraints:@[
        [self.cardView.centerYAnchor constraintEqualToAnchor:self.view.centerYAnchor],
        [self.cardView.leadingAnchor constraintEqualToAnchor:self.view.layoutMarginsGuide.leadingAnchor],
        [self.cardView.trailingAnchor constraintEqualToAnchor:self.view.layoutMarginsGuide.trailingAnchor],

        // Category icon: 24pt from the top, centered, 48x48
        [self.iconView.topAnchor constraintEqualToAnchor:self.cardView.topAnchor constant:24],
        [self.iconView.centerXAnchor constraintEqualToAnchor:self.cardView.centerXAnchor],
        [self.iconView.widthAnchor constraintEqualToConstant:48],
        [self.iconView.heightAnchor constraintEqualToConstant:48],

        // titleLabel: 12pt below the icon (the constraints still lay out correctly when the icon is hidden)
        [self.titleLabel.topAnchor constraintEqualToAnchor:self.iconView.bottomAnchor constant:12],
        [self.titleLabel.leadingAnchor constraintEqualToAnchor:self.cardView.leadingAnchor constant:16],
        [self.titleLabel.trailingAnchor constraintEqualToAnchor:self.cardView.trailingAnchor constant:-16],

        [self.percentLabel.topAnchor constraintEqualToAnchor:self.titleLabel.bottomAnchor constant:20],
        [self.percentLabel.leadingAnchor constraintEqualToAnchor:self.cardView.leadingAnchor constant:16],
        [self.percentLabel.trailingAnchor constraintEqualToAnchor:self.cardView.trailingAnchor constant:-16],

        [self.indeterminateIndicator.topAnchor constraintEqualToAnchor:self.titleLabel.bottomAnchor constant:20],
        [self.indeterminateIndicator.centerXAnchor constraintEqualToAnchor:self.cardView.centerXAnchor],

        [self.progressBar.topAnchor constraintEqualToAnchor:self.percentLabel.bottomAnchor constant:16],
        [self.progressBar.leadingAnchor constraintEqualToAnchor:self.cardView.leadingAnchor constant:16],
        [self.progressBar.trailingAnchor constraintEqualToAnchor:self.cardView.trailingAnchor constant:-16],
        [self.progressBar.heightAnchor constraintEqualToConstant:8],

        // Detail info line: 10pt below the progress bar
        [self.detailInfoLabel.topAnchor constraintEqualToAnchor:self.progressBar.bottomAnchor constant:10],
        [self.detailInfoLabel.leadingAnchor constraintEqualToAnchor:self.cardView.leadingAnchor constant:16],
        [self.detailInfoLabel.trailingAnchor constraintEqualToAnchor:self.cardView.trailingAnchor constant:-16],

        // ETA: 4pt below the detail info line
        [self.etaLabel.topAnchor constraintEqualToAnchor:self.detailInfoLabel.bottomAnchor constant:4],
        [self.etaLabel.leadingAnchor constraintEqualToAnchor:self.cardView.leadingAnchor constant:16],
        [self.etaLabel.trailingAnchor constraintEqualToAnchor:self.cardView.trailingAnchor constant:-16],

        // Stage container: 12pt below the ETA
        [self.stagesContainer.topAnchor constraintEqualToAnchor:self.etaLabel.bottomAnchor constant:12],
        [self.stagesContainer.leadingAnchor constraintEqualToAnchor:self.cardView.leadingAnchor constant:20],
        [self.stagesContainer.trailingAnchor constraintEqualToAnchor:self.cardView.trailingAnchor constant:-20],

        // stagesStack fills stagesContainer
        [self.stagesStack.topAnchor constraintEqualToAnchor:self.stagesContainer.topAnchor],
        [self.stagesStack.leadingAnchor constraintEqualToAnchor:self.stagesContainer.leadingAnchor],
        [self.stagesStack.trailingAnchor constraintEqualToAnchor:self.stagesContainer.trailingAnchor],
        [self.stagesStack.bottomAnchor constraintEqualToAnchor:self.stagesContainer.bottomAnchor],

        // stageLabel: 12pt below the stage container
        [self.stageLabel.topAnchor constraintEqualToAnchor:self.stagesContainer.bottomAnchor constant:12],
        [self.stageLabel.leadingAnchor constraintEqualToAnchor:self.cardView.leadingAnchor constant:16],
        [self.stageLabel.trailingAnchor constraintEqualToAnchor:self.cardView.trailingAnchor constant:-16],
        [self.stageLabel.bottomAnchor constraintEqualToAnchor:self.cardView.bottomAnchor constant:-24]
    ]];
}

- (void)setTitleText:(NSString *)titleText {
    _titleText = [titleText copy];
    self.titleLabel.text = titleText ?: @"Installing";
    self.title = titleText ?: @"Installing";
}

- (void)setStageMessage:(NSString *)stageMessage {
    _stageMessage = [stageMessage copy];
    [self updateUI];
}

- (void)setProgress:(double)progress {
    _progress = progress;
    [self updateUI];
}

- (void)setCategoryIconName:(NSString *)categoryIconName {
    _categoryIconName = [categoryIconName copy];
    if (categoryIconName.length > 0) {
        self.iconView.image = [UIImage systemImageNamed:categoryIconName];
        self.iconView.hidden = NO;
    } else {
        self.iconView.hidden = YES;
    }
}

- (void)setCategoryIconColor:(UIColor *)categoryIconColor {
    _categoryIconColor = categoryIconColor;
    self.iconView.tintColor = categoryIconColor ?: accentColor();
}

- (void)setDetailInfoText:(NSString *)detailInfoText {
    _detailInfoText = [detailInfoText copy];
    if (detailInfoText.length > 0) {
        self.detailInfoLabel.text = detailInfoText;
        self.detailInfoLabel.hidden = NO;
    } else {
        self.detailInfoLabel.hidden = YES;
    }
}

- (void)setEtaText:(NSString *)etaText {
    _etaText = [etaText copy];
    if (etaText.length > 0) {
        self.etaLabel.text = etaText;
        self.etaLabel.hidden = NO;
    } else {
        self.etaLabel.hidden = YES;
    }
}

- (void)setStageSteps:(NSArray<NSDictionary *> *)stageSteps {
    _stageSteps = [stageSteps copy];
    [self rebuildStagesStack];
}

/// Rebuild the stage list (modelled on the FCL install step list)
/// Each row has a status icon (✓/◐/○) plus the step title, with a different color per status
- (void)rebuildStagesStack {
    // Remove the old step rows
    [self.stagesStack.arrangedSubviews makeObjectsPerformSelector:@selector(removeFromSuperview)];

    if (!self.stageSteps || self.stageSteps.count == 0) {
        self.stagesContainer.hidden = YES;
        return;
    }

    self.stagesContainer.hidden = NO;
    for (NSDictionary *step in self.stageSteps) {
        NSString *title = [step[@"title"] isKindOfClass:[NSString class]] ? step[@"title"] : @"";
        NSInteger status = [step[@"status"] integerValue]; // 0=not started, 1=in progress, 2=done

        UILabel *stepLabel = [[UILabel alloc] init];
        stepLabel.translatesAutoresizingMaskIntoConstraints = NO;
        stepLabel.font = [UIFont systemFontOfSize:13];
        stepLabel.numberOfLines = 0;

        NSString *symbolName;
        UIColor *statusColor;
        switch (status) {
            case 2: // Done
                symbolName = @"checkmark.circle.fill";
                statusColor = [UIColor systemGreenColor];
                break;
            case 1: // In progress
                symbolName = @"circle.dotted";
                statusColor = accentColor();
                break;
            default: // Not started
                symbolName = @"circle";
                statusColor = [UIColor tertiaryLabelColor];
                break;
        }

        // Build the step row with its icon using NSAttributedString
        NSTextAttachment *attachment = [[NSTextAttachment alloc] init];
        attachment.image = [[UIImage systemImageNamed:symbolName] imageWithTintColor:statusColor renderingMode:UIImageRenderingModeAlwaysOriginal];
        attachment.bounds = CGRectMake(0, -2, 16, 16);
        NSAttributedString *iconAttr = [NSAttributedString attributedStringWithAttachment:attachment];
        NSMutableAttributedString *attrString = [[NSMutableAttributedString alloc] initWithAttributedString:iconAttr];
        [attrString appendAttributedString:[[NSAttributedString alloc] initWithString:[NSString stringWithFormat:@"  %@", title]
                                                                         attributes:@{
            NSFontAttributeName: [UIFont systemFontOfSize:13],
            NSForegroundColorAttributeName: (status == 0) ? [UIColor tertiaryLabelColor] : [UIColor labelColor]
        }]];
        stepLabel.attributedText = attrString;
        [self.stagesStack addArrangedSubview:stepLabel];
    }
}

- (void)updateUI {
    if (self.progress < 0) {
        // Indeterminate mode: hide the progress bar and percentage, showing only the spinner
        self.progressBar.hidden = YES;
        self.percentLabel.hidden = YES;
        self.indeterminateIndicator.hidden = NO;
        [self.indeterminateIndicator startAnimating];
    } else {
        self.progressBar.hidden = NO;
        self.percentLabel.hidden = NO;
        self.indeterminateIndicator.hidden = YES;
        [self.indeterminateIndicator stopAnimating];
        double clamped = MAX(0.0, MIN(1.0, self.progress));
        NSInteger percent = (NSInteger)(clamped * 100);
        self.percentLabel.text = [NSString stringWithFormat:@"%ld%%", (long)percent];
        [self.progressBar setProgress:(float)clamped animated:YES];
    }
    self.stageLabel.text = self.stageMessage ?: @"";
}

- (void)cancelTapped {
    if (self.cancelHandler) {
        self.cancelHandler();
    } else {
        [self.navigationController popViewControllerAnimated:YES];
    }
}

@end

#pragma mark - DownloadViewController

@interface DownloadViewController () <UICollectionViewDataSource, UICollectionViewDelegate, UITableViewDataSource, UITableViewDelegate, UISearchBarDelegate, ModVersionViewControllerDelegate, ShaderVersionViewControllerDelegate, AssetVersionViewControllerDelegate>

@property (nonatomic, strong) UISegmentedControl *tabSegment;
@property (nonatomic, strong) UISegmentedControl *versionFilterSegment;
// Height constraint of versionFilterSegment: about 32pt on the version tab and 0 on the others,
// so that hidden=YES does not still take up space and leave "a big white band" between tabSegment and searchBar.
@property (nonatomic, strong) NSLayoutConstraint *versionFilterHeightConstraint;
@property (nonatomic, strong) UISearchBar *searchBar;
@property (nonatomic, strong) UIButton *filterButton;
@property (nonatomic, strong) UIButton *importModpackButton;  // Import button used only on the modpack tab (as in FCL)
@property (nonatomic, strong) NSLayoutConstraint *importModpackButtonWidthConstraint;
@property (nonatomic, strong) UICollectionView *versionCollectionView;
@property (nonatomic, strong) UITableView *modTableView;
@property (nonatomic, strong) UITableView *shaderTableView;
@property (nonatomic, strong) UIActivityIndicatorView *loadingIndicator;
@property (nonatomic, strong) UILabel *emptyLabel;

@property (nonatomic, strong) NSArray *versionList;
@property (nonatomic, strong) NSArray *filteredVersions;
@property (nonatomic, strong) NSMutableArray *modList;
@property (nonatomic, strong) NSMutableArray *shaderList;

// Search term on the version tab (filters by version number prefix, e.g. "1.2" matches 1.20.x / 1.2.x)
@property (nonatomic, strong) NSString *versionSearchQuery;

@property (nonatomic, assign) NSInteger currentModOffset;
@property (nonatomic, assign) NSInteger currentShaderOffset;
@property (nonatomic, assign) BOOL isLoadingMore;
@property (nonatomic, assign) BOOL hasMoreMods;
@property (nonatomic, assign) BOOL hasMoreShaders;
@property (nonatomic, strong) NSString *currentSearchQuery;
@property (nonatomic, strong) NSString *currentGameVersion;
@property (nonatomic, strong) NSString *currentModLoader;
@property (nonatomic, strong) NSString *currentSortField;
// FCL style: tracks whether the user has changed the filters by hand (after which they are no longer overwritten by the profile version)
@property (nonatomic, assign) BOOL hasUserTouchedFilters;

@property (nonatomic, strong) MinecraftResourceDownloadTask *downloadTask;
@property (nonatomic, strong) DownloadProgressViewController *progressVC;
@property (nonatomic, strong) InlineMessageView *downloadingAlert;
// Modelled on the download progress cards of FCL/ZL2/HMCL, replacing the spinning loadingIndicator
@property (nonatomic, strong) DownloadProgressCardView *progressCardView;

@property (nonatomic, assign) BOOL isObservingProgress;

// Modpack-related properties
@property (nonatomic, strong) UITableView *modpackTableView;
@property (nonatomic, strong) NSMutableArray *modpackList;
@property (nonatomic, assign) NSInteger currentModpackOffset;
@property (nonatomic, assign) BOOL hasMoreModpacks;
@property (nonatomic, assign) BOOL isLoadingModpacks;
@property (nonatomic, strong) NSString *modpackSearchQuery;

// Resource pack-related properties
@property (nonatomic, strong) UITableView *resourcepackTableView;
@property (nonatomic, strong) NSMutableArray *resourcepackList;
@property (nonatomic, assign) NSInteger currentResourcepackOffset;
@property (nonatomic, assign) BOOL hasMoreResourcepacks;
@property (nonatomic, assign) BOOL isLoadingResourcepacks;
@property (nonatomic, strong) NSString *resourcepackSearchQuery;

// Data pack-related properties
@property (nonatomic, strong) UITableView *datapackTableView;
@property (nonatomic, strong) NSMutableArray *datapackList;
@property (nonatomic, assign) NSInteger currentDatapackOffset;
@property (nonatomic, assign) BOOL hasMoreDatapacks;
@property (nonatomic, assign) BOOL isLoadingDatapacks;
@property (nonatomic, strong) NSString *datapackSearchQuery;

// World-related properties (mirroring the world download category added in FCL for Android)
@property (nonatomic, strong) UITableView *worldTableView;
@property (nonatomic, strong) NSMutableArray *worldList;
@property (nonatomic, assign) NSInteger currentWorldOffset;
@property (nonatomic, assign) BOOL hasMoreWorlds;
@property (nonatomic, assign) BOOL isLoadingWorlds;
@property (nonatomic, strong) NSString *worldSearchQuery;

// Source switch UI (an FCL-for-Android-style rounded capsule switch: Modrinth green / CurseForge orange)
@property (nonatomic, strong) UIView *sourceSwitchContainer;
@property (nonatomic, strong) UIView *sourceSwitchTrack;        // Rounded capsule background track
@property (nonatomic, strong) UIView *sourceSwitchSlider;       // Colored slider for the selected item
@property (nonatomic, strong) UIButton *modrinthSourceButton;
@property (nonatomic, strong) UIButton *curseforgeSourceButton;
@property (nonatomic, strong) NSLayoutConstraint *sourceSwitchHeightConstraint;
@property (nonatomic, strong) NSLayoutConstraint *sliderLeftPosConstraint;   // Slider on the left (Modrinth)
@property (nonatomic, strong) NSLayoutConstraint *sliderRightPosConstraint;  // Slider on the right (CurseForge)

// ===== FCL/ZL2-style side filter bar =====
// Modelled on the mod/shader download screens of FCL (FoldCraftLauncher) and ZL2 (ZalithLauncher):
// a filter panel on the left (download source, game version, mod loader, sort) with the search box and list on the right.
// The sidebar is shown on the mod/shader/resource pack/data pack/modpack tabs and hidden on the version and world tabs.
// On narrow screens (iPhone portrait) it shrinks to 140pt; on wide screens (iPad) it is 180pt.
@property (nonatomic, strong) UIView *filterSidebarContainer;      // Sidebar container
@property (nonatomic, strong) NSLayoutConstraint *sidebarWidthConstraint;  // Sidebar width constraint (0 when hidden)
@property (nonatomic, strong) NSLayoutConstraint *sidebarLeadingConstraint; // Sidebar leading (flush left when hidden, so the list does not shift)

// Download source picker inside the sidebar (moved down from the top)
@property (nonatomic, strong) UIView *sidebarSourceContainer;
@property (nonatomic, strong) UIButton *sidebarModrinthButton;
@property (nonatomic, strong) UIButton *sidebarCurseforgeButton;
@property (nonatomic, strong) NSLayoutConstraint *sidebarSliderLeftConstraint;
@property (nonatomic, strong) NSLayoutConstraint *sidebarSliderRightConstraint;
@property (nonatomic, strong) UIView *sidebarSourceTrack;
@property (nonatomic, strong) UIView *sidebarSourceSlider;

// Game version button inside the sidebar (opens an ActionSheet to pick a version)
@property (nonatomic, strong) UIButton *sidebarVersionButton;
@property (nonatomic, strong) UILabel *sidebarVersionTitleLabel;
@property (nonatomic, strong) UILabel *sidebarVersionValueLabel;

// Mod loader button inside the sidebar (opens an ActionSheet to pick a loader)
@property (nonatomic, strong) UIButton *sidebarLoaderButton;
@property (nonatomic, strong) UILabel *sidebarLoaderTitleLabel;
@property (nonatomic, strong) UILabel *sidebarLoaderValueLabel;

// Sort button inside the sidebar
@property (nonatomic, strong) UIButton *sidebarSortButton;
@property (nonatomic, strong) UILabel *sidebarSortTitleLabel;
@property (nonatomic, strong) UILabel *sidebarSortValueLabel;

// Reset filters button in the sidebar
@property (nonatomic, strong) UIButton *sidebarResetButton;

// The asset type currently queued for download (mod/resourcepack/datapack/world/modpack), used by the version-picker callback to choose the download folder
@property (nonatomic, copy) NSString *pendingDownloadType;
// Temporarily holds the resource pack/data pack/world object while an online version is being picked (used by the AssetVersionViewController callback)
@property (nonatomic, strong, nullable) ResourcePackItem *pendingResourcePackItem;
@property (nonatomic, strong, nullable) DataPackItem *pendingDataPackItem;
@property (nonatomic, strong, nullable) WorldItem *pendingWorldItem;
// Temporarily holds the modpack dictionary during the modpack version callback (it shares the VC with mods but has a different download flow)
@property (nonatomic, strong, nullable) NSDictionary *pendingModpackDict;

// Mod loader install progress VC (FCL-style progress display, replacing the spinner alert)
@property (nonatomic, strong) InstallerProgressViewController *installerProgressVC;

// Vanilla prerequisite install (FCL style: install the matching vanilla version before the mod loader)
@property (nonatomic, strong) MinecraftResourceDownloadTask *vanillaPreinstallTask;
@property (nonatomic, strong) InstallerProgressViewController *vanillaPreinstallProgressVC;
@property (nonatomic, assign) BOOL isObservingVanillaPreinstall;
@property (nonatomic, copy, nullable) void (^vanillaPreinstallCompletion)(BOOL success);
// Improvement 2 (following the unified progress flow of ZL2): YES means the vanilla preinstall is a prerequisite step of the loader install,
// so the preinstall VC is not popped when it finishes but handed over to self.installerProgressVC for the later install* methods to reuse,
// letting "vanilla + loader" run continuously on one progress page instead of two separate ones.
@property (nonatomic, assign) BOOL vanillaPreinstallForLoader;

@end

@implementation DownloadViewController

- (void)dealloc {
    if (self.isObservingProgress) {
        @try {
            [self.downloadTask.progress removeObserver:self forKeyPath:@"fractionCompleted"];
        } @catch (NSException *exception) {
            // The KVO observer may be registered on the old downloadTask.progress while downloadTask has already been
            // reassigned to a new object (startVersionDownload: creates a new task each time), so removing it from the new
            // progress throws a "not registered as an observer" exception. It is safe to ignore.
            NSLog(@"[DownloadVC] dealloc: removeObserver fractionCompleted failed: %@", exception.reason);
        }
        self.isObservingProgress = NO;
    }
    if (self.downloadTask) {
        [self.downloadTask.progress cancel];
        self.downloadTask = nil;
    }
    // Clean up the KVO observer of the vanilla preinstall, so a KVO callback after the VC is freed cannot message a dead object and crash
    if (self.isObservingVanillaPreinstall) {
        @try {
            [self.vanillaPreinstallTask.progress removeObserver:self forKeyPath:@"fractionCompleted"];
        } @catch (NSException *exception) {
            NSLog(@"[DownloadVC] dealloc: removeObserver vanillaPreinstall fractionCompleted failed: %@", exception.reason);
        }
        self.isObservingVanillaPreinstall = NO;
    }
    if (self.vanillaPreinstallTask) {
        [self.vanillaPreinstallTask.progress cancel];
        self.vanillaPreinstallTask = nil;
    }
    [[NSNotificationCenter defaultCenter] removeObserver:self name:@"BackgroundUIEffectChanged" object:nil];
}

- (void)viewDidLoad {
    [super viewDidLoad];

    // self.title is deliberately not set, to avoid a black "Download" title band in the navigation bar (matching the title-less FCL style)
    self.view.backgroundColor = [UIColor clearColor];

    // Hide the navigation bar band completely (only when this is a non-modal root page and the only VC on the stack)
    // Shortcuts (showModpackImport and friends) pre-push a child page, so count > 1 and the navigation bar stays visible
    if (self.navigationController &&
        self.navigationController.viewControllers.firstObject == self &&
        self.navigationController.presentingViewController == nil &&
        self.navigationController.viewControllers.count == 1) {
        self.navigationController.navigationBarHidden = YES;
    }

    // Adapt to the custom launcher background (as in LauncherPreferencesViewController / LauncherRightPanelViewController)
    // makeViewControllerTransparent: handles the view background correctly for the current BackgroundUIEffect (frosted glass/translucent)
    // and makes child VCs transparent recursively. Its absence previously stopped the mod download screen adapting to the custom background.
    [[BackgroundManager sharedManager] makeViewControllerTransparent:self];

    // The CurseForge API key entry point now lives in the settings page (LauncherPreferencesViewController),
    // so it is no longer kept here, freeing up space on the right of the navigation bar.
    // The World tab always uses CurseForge; when the key is missing, emptyLabel/InlineMessageView point the user to the settings page.

    self.modList = [NSMutableArray array];
    self.shaderList = [NSMutableArray array];
    self.modpackList = [NSMutableArray array]; // Newly added
    self.resourcepackList = [NSMutableArray array];
    self.datapackList = [NSMutableArray array];
    self.worldList = [NSMutableArray array];
    self.currentModOffset = 0;
    self.currentShaderOffset = 0;
    self.currentModpackOffset = 0;
    self.currentResourcepackOffset = 0;
    self.currentDatapackOffset = 0;
    self.currentWorldOffset = 0;
    self.hasMoreMods = YES;
    self.hasMoreShaders = YES;
    self.hasMoreModpacks = YES;
    self.hasMoreResourcepacks = YES;
    self.hasMoreDatapacks = YES;
    self.hasMoreWorlds = YES;
    self.currentSortField = @"follows";
    self.isObservingProgress = NO;

    [self setupUI];
    [self switchToTab:0];
    [self loadVersionList];

    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(handleBackgroundUIEffectChanged:)
                                                 name:@"BackgroundUIEffectChanged"
                                               object:nil];
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    // Hide the navigation bar band again (topViewController == self after popping back to the root page)
    if (self.navigationController &&
        self.navigationController.viewControllers.firstObject == self &&
        self.navigationController.presentingViewController == nil &&
        self.navigationController.topViewController == self) {
        self.navigationController.navigationBarHidden = YES;
    }
    // Re-apply the transparent background effect (as in LauncherPreferencesViewController)
    // The user may have changed the background settings elsewhere, so it has to be reapplied on return
    if ([[BackgroundManager sharedManager] hasBackground]) {
        self.view.backgroundColor = [UIColor clearColor];
        // Apply the effect to the navigation bar (DownloadViewController is wrapped in a UINavigationController)
        UINavigationController *nav = self.navigationController;
        if (nav) {
            nav.view.backgroundColor = [UIColor clearColor];
            [[BackgroundManager sharedManager] applyEffectToNavigationBar:nav.navigationBar];
        }
        // Re-apply the sidebar effect
        if (self.filterSidebarContainer) {
            [[BackgroundManager sharedManager] applyEffectToView:self.filterSidebarContainer];
        }
    }
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

- (void)setupUI {
    [self setupTabSegment];
    [self setupVersionFilterSegment];
    // Note: setupSearchBar refers to filterSidebarContainer.trailingAnchor internally,
    // so it must be called after setupFilterSidebar (otherwise filterSidebarContainer is nil and
    // UIKit throws NSInvalidArgumentException when the constraints activate, crashing as soon as the download tile is tapped).
    [self setupFilterSidebar];  // FCL/ZL2-style side filter bar (create the container first)
    [self setupSearchBar];      // Then the search box (which depends on filterSidebarContainer)
    [self setupSourceSwitch];
    [self setupVersionCollectionView];
    [self setupModTableView];
    [self setupShaderTableView];
    [self setupModpackTableView]; // Newly added
    [self setupResourcepackTableView];
    [self setupDatapackTableView];
    [self setupWorldTableView];
    [self setupLoadingIndicator];
    [self setupEmptyLabel];
}

- (void)setupTabSegment {
    // Shorten the tab labels to one word plus an icon, so they are not cramped or truncated on narrow screens (matching the compact FCL tabs)
    self.tabSegment = [[UISegmentedControl alloc] initWithItems:@[@"Version", @"Mods", @"Shaders", @"Resources", @"Data", @"Modpacks", @"Worlds"]];
    self.tabSegment.translatesAutoresizingMaskIntoConstraints = NO;
    self.tabSegment.selectedSegmentIndex = 0;
    // Reduce the font size so all 7 tabs fit in iPhone portrait
    NSDictionary *textAttrs = @{NSFontAttributeName: [UIFont systemFontOfSize:12 weight:UIFontWeightMedium]};
    [self.tabSegment setTitleTextAttributes:textAttrs forState:UIControlStateNormal];
    [self.tabSegment addTarget:self action:@selector(tabChanged:) forControlEvents:UIControlEventValueChanged];
    [self.view addSubview:self.tabSegment];

    [NSLayoutConstraint activateConstraints:@[
        [self.tabSegment.topAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.topAnchor constant:8],
        [self.tabSegment.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor constant:12],
        [self.tabSegment.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor constant:-12],
        [self.tabSegment.heightAnchor constraintEqualToConstant:32]
    ]];
}

- (void)setupVersionFilterSegment {
    self.versionFilterSegment = [[UISegmentedControl alloc] initWithItems:@[@"All", @"Release", @"Snapshot", @"Ancient"]];
    self.versionFilterSegment.translatesAutoresizingMaskIntoConstraints = NO;
    self.versionFilterSegment.selectedSegmentIndex = 0;
    [self.versionFilterSegment addTarget:self action:@selector(versionFilterChanged:) forControlEvents:UIControlEventValueChanged];
    [self.view addSubview:self.versionFilterSegment];

    // Height constraint: 32 on the version tab (the default UISegmentedControl height) and 0 on the others
    // This avoids hidden=YES still taking up space and leaving "a big white band" between tabSegment and searchBar
    self.versionFilterHeightConstraint = [self.versionFilterSegment.heightAnchor constraintEqualToConstant:32];

    [NSLayoutConstraint activateConstraints:@[
        [self.versionFilterSegment.topAnchor constraintEqualToAnchor:self.tabSegment.bottomAnchor constant:8],
        [self.versionFilterSegment.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor constant:16],
        [self.versionFilterSegment.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor constant:-16],
        self.versionFilterHeightConstraint
    ]];
}

- (void)setupSearchBar {
    self.searchBar = [[UISearchBar alloc] init];
    self.searchBar.translatesAutoresizingMaskIntoConstraints = NO;
    self.searchBar.placeholder = @"Search versions...";
    self.searchBar.delegate = self;
    self.searchBar.searchBarStyle = UISearchBarStyleMinimal;
    // The search box is shown on every tab (on the version tab it filters by version number prefix)
    self.searchBar.hidden = NO;
    [self.view addSubview:self.searchBar];

    self.filterButton = [UIButton buttonWithType:UIButtonTypeSystem];
    self.filterButton.translatesAutoresizingMaskIntoConstraints = NO;
    [self.filterButton setImage:[UIImage systemImageNamed:@"slider.horizontal.3"] forState:UIControlStateNormal];
    [self.filterButton addTarget:self action:@selector(showFilterOptions) forControlEvents:UIControlEventTouchUpInside];
    self.filterButton.hidden = YES;
    [self.view addSubview:self.filterButton];

    // "Import local modpack" button used only on the modpack tab (FCL for Android puts a prominent import entry above the modpack list)
    self.importModpackButton = [UIButton buttonWithType:UIButtonTypeSystem];
    self.importModpackButton.translatesAutoresizingMaskIntoConstraints = NO;
    // square.and.arrow.down.on.square is an iOS 14+ symbol, so there is a fallback to avoid rendering an empty box
    UIImage *importIcon = [UIImage systemImageNamed:@"square.and.arrow.down.on.square"]
                          ?: [UIImage systemImageNamed:@"square.and.arrow.down"]
                          ?: [UIImage systemImageNamed:@"tray.and.arrow.down"];
    [self.importModpackButton setImage:importIcon forState:UIControlStateNormal];
    [self.importModpackButton setTitle:@"Import" forState:UIControlStateNormal];
    self.importModpackButton.tintColor = [UIColor whiteColor];
    self.importModpackButton.backgroundColor = FluxTheme.accent;
    self.importModpackButton.layer.cornerRadius = 10;
    self.importModpackButton.titleLabel.font = [UIFont boldSystemFontOfSize:14];
    self.importModpackButton.contentEdgeInsets = UIEdgeInsetsMake(0, 10, 0, 10);
    self.importModpackButton.imageEdgeInsets = UIEdgeInsetsMake(0, -4, 0, 4);
    self.importModpackButton.hidden = YES;
    [self.importModpackButton addTarget:self action:@selector(openImportModpackView) forControlEvents:UIControlEventTouchUpInside];
    [self.view addSubview:self.importModpackButton];

    [NSLayoutConstraint activateConstraints:@[
        // The search box sits below the version filter so it does not overlap versionFilterSegment.
        // Key fix: searchBar.leading follows filterSidebarContainer.trailing (matching every tab table),
        // so the search box moves right out of the way when the side filter bar expands instead of being covered by it.
        // Previously searchBar.leading = view.leading+8, so an expanded sidebar (140/180pt) overlapped the left half of the search box.
        [self.searchBar.topAnchor constraintEqualToAnchor:self.versionFilterSegment.bottomAnchor constant:8],
        [self.searchBar.leadingAnchor constraintEqualToAnchor:self.filterSidebarContainer.trailingAnchor constant:8],
        [self.searchBar.trailingAnchor constraintEqualToAnchor:self.importModpackButton.leadingAnchor constant:-8],

        [self.importModpackButton.centerYAnchor constraintEqualToAnchor:self.searchBar.centerYAnchor],
        [self.importModpackButton.trailingAnchor constraintEqualToAnchor:self.filterButton.leadingAnchor constant:-4],
        [self.importModpackButton.heightAnchor constraintEqualToConstant:36],

        [self.filterButton.centerYAnchor constraintEqualToAnchor:self.searchBar.centerYAnchor],
        [self.filterButton.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor constant:-16],
        [self.filterButton.widthAnchor constraintEqualToConstant:44],
        [self.filterButton.heightAnchor constraintEqualToConstant:44]
    ]];

    // Width defaults to 0 (taking no space when hidden) and becomes 80 when switching to the modpack tab
    self.importModpackButtonWidthConstraint = [self.importModpackButton.widthAnchor constraintEqualToConstant:0];
    self.importModpackButtonWidthConstraint.active = YES;
}

- (void)setupVersionCollectionView {
    // Modelled on FCL (the single-column list of item_remote_version.xml) and ZL2 (LazyColumn VersionItemLayout):
    // changed to a single-column list of horizontal rows, one full-width card per row, 64pt row height (the cell adds 4pt of vertical padding, so the card is 56pt).
    // itemSize.width is updated dynamically in viewDidLayoutSubviews from the real collectionView width, so rotation does not misalign it.
    UICollectionViewFlowLayout *layout = [[UICollectionViewFlowLayout alloc] init];
    layout.scrollDirection = UICollectionViewScrollDirectionVertical;
    layout.minimumInteritemSpacing = 0;  // Single column, so no horizontal spacing
    layout.minimumLineSpacing = 4;       // Small gap between rows; the card shadows provide the visual separation
    layout.itemSize = CGSizeMake(360, 64); // Default width; viewDidLayoutSubviews overrides it
    layout.sectionInset = UIEdgeInsetsMake(8, 16, 8, 16);

    self.versionCollectionView = [[UICollectionView alloc] initWithFrame:CGRectZero collectionViewLayout:layout];
    self.versionCollectionView.translatesAutoresizingMaskIntoConstraints = NO;
    self.versionCollectionView.backgroundColor = [UIColor clearColor];
    self.versionCollectionView.dataSource = self;
    self.versionCollectionView.delegate = self;
    // Selection feedback: briefly highlight the cell on tap (both FCL and ZL2 give press feedback)
    self.versionCollectionView.allowsSelection = YES;
    self.versionCollectionView.alwaysBounceVertical = YES;
    [self.versionCollectionView registerClass:[VersionCardCell class] forCellWithReuseIdentifier:@"VersionCard"];
    [self.view addSubview:self.versionCollectionView];

    [NSLayoutConstraint activateConstraints:@[
        // The version list sits below the search box so they do not overlap
        [self.versionCollectionView.topAnchor constraintEqualToAnchor:self.searchBar.bottomAnchor constant:4],
        [self.versionCollectionView.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [self.versionCollectionView.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [self.versionCollectionView.bottomAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.bottomAnchor]
    ]];
}

// Update the version list itemSize width dynamically so it fills the collectionView width (minus 16pt of sectionInset on each side).
// The system calls this automatically on rotation or a split-view size change, so no notification needs registering.
- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    if (!self.versionCollectionView) return;
    UICollectionViewFlowLayout *layout = (UICollectionViewFlowLayout *)self.versionCollectionView.collectionViewLayout;
    if (![layout isKindOfClass:[UICollectionViewFlowLayout class]]) return;
    CGFloat horizInset = layout.sectionInset.left + layout.sectionInset.right;
    CGFloat availableWidth = MAX(0, self.versionCollectionView.bounds.size.width - horizInset);
    CGSize target = CGSizeMake(availableWidth, 64);
    if (!CGSizeEqualToSize(layout.itemSize, target)) {
        layout.itemSize = target;
        // invalidateLayout forces a re-layout, so the width does not lag behind during cell reuse
        [layout invalidateLayout];
    }

    // Adjust the sidebar width dynamically (on rotation)
    if (self.filterSidebarContainer && !self.filterSidebarContainer.hidden) {
        // FCL page_download.xml: search_layout uses layout_constraintWidth_percent="0.3"
        // Here it is 30% of the view width, clamped to avoid extremes (minimum 120pt on iPhone SE, maximum 280pt on iPad)
        CGFloat screenWidth = self.view.bounds.size.width;
        CGFloat newWidth = screenWidth * 0.3;
        newWidth = MAX(120.0, MIN(280.0, newWidth));
        if (ABS(self.sidebarWidthConstraint.constant - newWidth) > 0.5) {
            self.sidebarWidthConstraint.constant = newWidth;
        }
    }
}

- (void)setupModTableView {
    self.modTableView = [[UITableView alloc] initWithFrame:CGRectZero style:UITableViewStylePlain];
    self.modTableView.translatesAutoresizingMaskIntoConstraints = NO;
    self.modTableView.backgroundColor = [UIColor clearColor];
    self.modTableView.dataSource = self;
    self.modTableView.delegate = self;
    // FCL view_installer_item.xml: item height ~46dp + marginBottom 10dp
    // Here it is 54pt (26pt icon + two lines of text + 4pt of vertical padding), fitting more rows per screen
    self.modTableView.rowHeight = 54;
    self.modTableView.separatorStyle = UITableViewCellSeparatorStyleNone;
    [self.modTableView registerClass:[ModernAssetCell class] forCellReuseIdentifier:@"ModCell"];
    self.modTableView.hidden = YES;
    [self.view addSubview:self.modTableView];

    UIRefreshControl *refreshControl = [[UIRefreshControl alloc] init];
    [refreshControl addTarget:self action:@selector(refreshModList) forControlEvents:UIControlEventValueChanged];
    self.modTableView.refreshControl = refreshControl;

    // FCL/ZL2 style: the list leading follows the sidebar trailing and its top follows searchBar
    // When the sidebar is hidden its width is 0, so trailingAnchor equals view.leadingAnchor and the list fills the screen
    // 8pt of leading spacing so the list is not flush against the filter bar (visual breathing room, phase 3 UI tweak)
    [NSLayoutConstraint activateConstraints:@[
        [self.modTableView.topAnchor constraintEqualToAnchor:self.searchBar.bottomAnchor constant:4],
        [self.modTableView.leadingAnchor constraintEqualToAnchor:self.filterSidebarContainer.trailingAnchor constant:8],
        [self.modTableView.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [self.modTableView.bottomAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.bottomAnchor]
    ]];
}

- (void)setupShaderTableView {
    self.shaderTableView = [[UITableView alloc] initWithFrame:CGRectZero style:UITableViewStylePlain];
    self.shaderTableView.translatesAutoresizingMaskIntoConstraints = NO;
    self.shaderTableView.backgroundColor = [UIColor clearColor];
    self.shaderTableView.dataSource = self;
    self.shaderTableView.delegate = self;
    // FCL-style flat rows: 54pt row height
    self.shaderTableView.rowHeight = 54;
    self.shaderTableView.separatorStyle = UITableViewCellSeparatorStyleNone;
    [self.shaderTableView registerClass:[ModernAssetCell class] forCellReuseIdentifier:@"ShaderCell"];
    self.shaderTableView.hidden = YES;
    [self.view addSubview:self.shaderTableView];

    UIRefreshControl *refreshControl = [[UIRefreshControl alloc] init];
    [refreshControl addTarget:self action:@selector(refreshShaderList) forControlEvents:UIControlEventValueChanged];
    self.shaderTableView.refreshControl = refreshControl;

    // 8pt of leading spacing so the list is not flush against the filter bar (visual breathing room, phase 3 UI tweak)
    [NSLayoutConstraint activateConstraints:@[
        [self.shaderTableView.topAnchor constraintEqualToAnchor:self.searchBar.bottomAnchor constant:4],
        [self.shaderTableView.leadingAnchor constraintEqualToAnchor:self.filterSidebarContainer.trailingAnchor constant:8],
        [self.shaderTableView.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [self.shaderTableView.bottomAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.bottomAnchor]
    ]];
}

- (void)setupModpackTableView {
    self.modpackTableView = [[UITableView alloc] initWithFrame:CGRectZero style:UITableViewStylePlain];
    self.modpackTableView.translatesAutoresizingMaskIntoConstraints = NO;
    self.modpackTableView.backgroundColor = [UIColor clearColor];
    self.modpackTableView.dataSource = self;
    self.modpackTableView.delegate = self;
    // FCL-style flat rows: 54pt row height
    self.modpackTableView.rowHeight = 54;
    self.modpackTableView.separatorStyle = UITableViewCellSeparatorStyleNone;
    [self.modpackTableView registerClass:[ModernAssetCell class] forCellReuseIdentifier:@"ModpackCell"];
    self.modpackTableView.hidden = YES;
    [self.view addSubview:self.modpackTableView];

    UIRefreshControl *refreshControl = [[UIRefreshControl alloc] init];
    [refreshControl addTarget:self action:@selector(refreshModpackList) forControlEvents:UIControlEventValueChanged];
    self.modpackTableView.refreshControl = refreshControl;

    // 8pt of leading spacing so the list is not flush against the filter bar (visual breathing room, phase 3 UI tweak)
    [NSLayoutConstraint activateConstraints:@[
        [self.modpackTableView.topAnchor constraintEqualToAnchor:self.searchBar.bottomAnchor constant:4],
        [self.modpackTableView.leadingAnchor constraintEqualToAnchor:self.filterSidebarContainer.trailingAnchor constant:8],
        [self.modpackTableView.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [self.modpackTableView.bottomAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.bottomAnchor]
    ]];
}

- (void)setupResourcepackTableView {
    self.resourcepackTableView = [[UITableView alloc] initWithFrame:CGRectZero style:UITableViewStylePlain];
    self.resourcepackTableView.translatesAutoresizingMaskIntoConstraints = NO;
    self.resourcepackTableView.backgroundColor = [UIColor clearColor];
    self.resourcepackTableView.dataSource = self;
    self.resourcepackTableView.delegate = self;
    // FCL-style flat rows: 54pt row height
    self.resourcepackTableView.rowHeight = 54;
    self.resourcepackTableView.separatorStyle = UITableViewCellSeparatorStyleNone;
    [self.resourcepackTableView registerClass:[ModernAssetCell class] forCellReuseIdentifier:@"ResourcepackCell"];
    self.resourcepackTableView.hidden = YES;
    [self.view addSubview:self.resourcepackTableView];

    UIRefreshControl *refreshControl = [[UIRefreshControl alloc] init];
    [refreshControl addTarget:self action:@selector(refreshResourcepackList) forControlEvents:UIControlEventValueChanged];
    self.resourcepackTableView.refreshControl = refreshControl;

    // 8pt of leading spacing so the list is not flush against the filter bar (visual breathing room, phase 3 UI tweak)
    [NSLayoutConstraint activateConstraints:@[
        [self.resourcepackTableView.topAnchor constraintEqualToAnchor:self.searchBar.bottomAnchor constant:4],
        [self.resourcepackTableView.leadingAnchor constraintEqualToAnchor:self.filterSidebarContainer.trailingAnchor constant:8],
        [self.resourcepackTableView.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [self.resourcepackTableView.bottomAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.bottomAnchor]
    ]];
}

- (void)setupDatapackTableView {
    self.datapackTableView = [[UITableView alloc] initWithFrame:CGRectZero style:UITableViewStylePlain];
    self.datapackTableView.translatesAutoresizingMaskIntoConstraints = NO;
    self.datapackTableView.backgroundColor = [UIColor clearColor];
    self.datapackTableView.dataSource = self;
    self.datapackTableView.delegate = self;
    // FCL-style flat rows: 54pt row height
    self.datapackTableView.rowHeight = 54;
    self.datapackTableView.separatorStyle = UITableViewCellSeparatorStyleNone;
    [self.datapackTableView registerClass:[ModernAssetCell class] forCellReuseIdentifier:@"DatapackCell"];
    self.datapackTableView.hidden = YES;
    [self.view addSubview:self.datapackTableView];

    UIRefreshControl *refreshControl = [[UIRefreshControl alloc] init];
    [refreshControl addTarget:self action:@selector(refreshDatapackList) forControlEvents:UIControlEventValueChanged];
    self.datapackTableView.refreshControl = refreshControl;

    // 8pt of leading spacing so the list is not flush against the filter bar (visual breathing room, phase 3 UI tweak)
    [NSLayoutConstraint activateConstraints:@[
        [self.datapackTableView.topAnchor constraintEqualToAnchor:self.searchBar.bottomAnchor constant:4],
        [self.datapackTableView.leadingAnchor constraintEqualToAnchor:self.filterSidebarContainer.trailingAnchor constant:8],
        [self.datapackTableView.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [self.datapackTableView.bottomAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.bottomAnchor]
    ]];
}

- (void)setupWorldTableView {
    self.worldTableView = [[UITableView alloc] initWithFrame:CGRectZero style:UITableViewStylePlain];
    self.worldTableView.translatesAutoresizingMaskIntoConstraints = NO;
    self.worldTableView.backgroundColor = [UIColor clearColor];
    self.worldTableView.dataSource = self;
    self.worldTableView.delegate = self;
    // FCL-style flat rows: 54pt row height
    self.worldTableView.rowHeight = 54;
    self.worldTableView.separatorStyle = UITableViewCellSeparatorStyleNone;
    [self.worldTableView registerClass:[ModernAssetCell class] forCellReuseIdentifier:@"WorldCell"];
    self.worldTableView.hidden = YES;
    [self.view addSubview:self.worldTableView];

    UIRefreshControl *refreshControl = [[UIRefreshControl alloc] init];
    [refreshControl addTarget:self action:@selector(refreshWorldList) forControlEvents:UIControlEventValueChanged];
    self.worldTableView.refreshControl = refreshControl;

    // The world tab has no sidebar (it always uses CurseForge), so the list leading follows the view directly
    // 8pt of leading spacing to match the breathing room of the other tabs (phase 3 UI tweak)
    [NSLayoutConstraint activateConstraints:@[
        [self.worldTableView.topAnchor constraintEqualToAnchor:self.searchBar.bottomAnchor constant:4],
        [self.worldTableView.leadingAnchor constraintEqualToAnchor:self.filterSidebarContainer.trailingAnchor constant:8],
        [self.worldTableView.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [self.worldTableView.bottomAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.bottomAnchor]
    ]];
}

- (void)setupSourceSwitch {
    // FCL-for-Android style: a centered rounded capsule switch with a colored slider and brand colors
    self.sourceSwitchContainer = [[UIView alloc] init];
    self.sourceSwitchContainer.translatesAutoresizingMaskIntoConstraints = NO;
    self.sourceSwitchContainer.hidden = YES;
    [self.view addSubview:self.sourceSwitchContainer];

    // Rounded capsule background track
    self.sourceSwitchTrack = [[UIView alloc] init];
    self.sourceSwitchTrack.translatesAutoresizingMaskIntoConstraints = NO;
    self.sourceSwitchTrack.backgroundColor = [UIColor tertiarySystemFillColor];
    self.sourceSwitchTrack.layer.cornerRadius = 16;
    self.sourceSwitchTrack.layer.masksToBounds = YES;
    [self.sourceSwitchContainer addSubview:self.sourceSwitchTrack];

    // Slider for the selected item (Modrinth green initially)
    self.sourceSwitchSlider = [[UIView alloc] init];
    self.sourceSwitchSlider.translatesAutoresizingMaskIntoConstraints = NO;
    self.sourceSwitchSlider.backgroundColor = [UIColor systemGreenColor];
    self.sourceSwitchSlider.layer.cornerRadius = 14;
    // A shadow to add depth
    self.sourceSwitchSlider.layer.shadowColor = [UIColor blackColor].CGColor;
    self.sourceSwitchSlider.layer.shadowOpacity = 0.15;
    self.sourceSwitchSlider.layer.shadowOffset = CGSizeMake(0, 1);
    self.sourceSwitchSlider.layer.shadowRadius = 3;
    [self.sourceSwitchTrack addSubview:self.sourceSwitchSlider];

    // Modrinth button
    self.modrinthSourceButton = [UIButton buttonWithType:UIButtonTypeSystem];
    self.modrinthSourceButton.translatesAutoresizingMaskIntoConstraints = NO;
    [self.modrinthSourceButton setTitle:@"Modrinth" forState:UIControlStateNormal];
    self.modrinthSourceButton.titleLabel.font = [UIFont systemFontOfSize:13 weight:UIFontWeightSemibold];
    [self.modrinthSourceButton addTarget:self action:@selector(modrinthSourceButtonClicked:) forControlEvents:UIControlEventTouchUpInside];
    [self.sourceSwitchTrack addSubview:self.modrinthSourceButton];

    // CurseForge button
    self.curseforgeSourceButton = [UIButton buttonWithType:UIButtonTypeSystem];
    self.curseforgeSourceButton.translatesAutoresizingMaskIntoConstraints = NO;
    [self.curseforgeSourceButton setTitle:@"CurseForge" forState:UIControlStateNormal];
    self.curseforgeSourceButton.titleLabel.font = [UIFont systemFontOfSize:13 weight:UIFontWeightSemibold];
    [self.curseforgeSourceButton addTarget:self action:@selector(curseforgeSourceButtonClicked:) forControlEvents:UIControlEventTouchUpInside];
    [self.sourceSwitchTrack addSubview:self.curseforgeSourceButton];

    // Container constraints: centered, fixed width, fixed height
    self.sliderLeftPosConstraint = [self.sourceSwitchSlider.leadingAnchor constraintEqualToAnchor:self.sourceSwitchTrack.leadingAnchor constant:2];
    self.sliderRightPosConstraint = [self.sourceSwitchSlider.trailingAnchor constraintEqualToAnchor:self.sourceSwitchTrack.trailingAnchor constant:-2];
    self.sliderRightPosConstraint.active = NO; // Modrinth is on the left initially

    [NSLayoutConstraint activateConstraints:@[
        [self.sourceSwitchContainer.topAnchor constraintEqualToAnchor:self.searchBar.bottomAnchor constant:6],
        [self.sourceSwitchContainer.centerXAnchor constraintEqualToAnchor:self.view.centerXAnchor],
        [self.sourceSwitchContainer.widthAnchor constraintEqualToConstant:220],
        [self.sourceSwitchContainer.heightAnchor constraintEqualToConstant:36],

        // The track fills the container
        [self.sourceSwitchTrack.topAnchor constraintEqualToAnchor:self.sourceSwitchContainer.topAnchor],
        [self.sourceSwitchTrack.leadingAnchor constraintEqualToAnchor:self.sourceSwitchContainer.leadingAnchor],
        [self.sourceSwitchTrack.trailingAnchor constraintEqualToAnchor:self.sourceSwitchContainer.trailingAnchor],
        [self.sourceSwitchTrack.bottomAnchor constraintEqualToAnchor:self.sourceSwitchContainer.bottomAnchor],

        // Slider height/width (width = half the track - 2pt of margin); its position comes from one of the left/right constraints
        [self.sourceSwitchSlider.topAnchor constraintEqualToAnchor:self.sourceSwitchTrack.topAnchor constant:2],
        [self.sourceSwitchSlider.bottomAnchor constraintEqualToAnchor:self.sourceSwitchTrack.bottomAnchor constant:-2],
        [self.sourceSwitchSlider.widthAnchor constraintEqualToAnchor:self.sourceSwitchTrack.widthAnchor multiplier:0.5 constant:-2],
        self.sliderLeftPosConstraint,

        // The two buttons take half each
        [self.modrinthSourceButton.topAnchor constraintEqualToAnchor:self.sourceSwitchTrack.topAnchor],
        [self.modrinthSourceButton.bottomAnchor constraintEqualToAnchor:self.sourceSwitchTrack.bottomAnchor],
        [self.modrinthSourceButton.leadingAnchor constraintEqualToAnchor:self.sourceSwitchTrack.leadingAnchor],
        [self.modrinthSourceButton.widthAnchor constraintEqualToAnchor:self.sourceSwitchTrack.widthAnchor multiplier:0.5],

        [self.curseforgeSourceButton.topAnchor constraintEqualToAnchor:self.sourceSwitchTrack.topAnchor],
        [self.curseforgeSourceButton.bottomAnchor constraintEqualToAnchor:self.sourceSwitchTrack.bottomAnchor],
        [self.curseforgeSourceButton.trailingAnchor constraintEqualToAnchor:self.sourceSwitchTrack.trailingAnchor],
        [self.curseforgeSourceButton.widthAnchor constraintEqualToAnchor:self.sourceSwitchTrack.widthAnchor multiplier:0.5]
    ]];

    // Dynamic height constraint (0 when hidden, 36 when shown)
    self.sourceSwitchHeightConstraint = [self.sourceSwitchContainer.heightAnchor constraintEqualToConstant:0];
    self.sourceSwitchHeightConstraint.active = YES;
}

#pragma mark - FCL/ZL2 style side filter bar

/// Build the side filter bar (modelled on the mod/shader download screens of FCL/ZL2)
///
/// Layout (top to bottom inside the sidebar):
/// 1. Download source picker (a Modrinth / CurseForge rounded capsule switch)
/// 2. Game version button (opens an ActionSheet to pick a version)
/// 3. Mod loader button (opens an ActionSheet to pick a loader; shown only on the mod tab)
/// 4. Sort button (opens an ActionSheet to pick a sort order)
/// 5. Reset filters button
///
/// The sidebar is shown on the mod/shader/resource pack/data pack/modpack tabs and hidden on the version and world tabs.
/// When hidden its width is 0 and it takes no space; when shown it is 180pt (wide screens) or 140pt (narrow screens).
- (void)setupFilterSidebar {
    self.filterSidebarContainer = [[UIView alloc] init];
    self.filterSidebarContainer.translatesAutoresizingMaskIntoConstraints = NO;
    // Adapt to the custom launcher background: use BackgroundManager's applyEffectToView: rather than the opaque
    // secondarySystemBackgroundColor. The previous secondarySystemBackgroundColor (fully opaque)
    // hid the custom background, so the mod/shader download screens did not adapt to it.
    // applyEffectToView: handles the current BackgroundUIEffect setting (frosted glass/translucent) correctly,
    // mirroring how sidebarContainer is handled in LauncherRootViewController.m.
    self.filterSidebarContainer.backgroundColor = [UIColor clearColor];
    self.filterSidebarContainer.layer.cornerRadius = 12;
    self.filterSidebarContainer.layer.masksToBounds = YES;
    [[BackgroundManager sharedManager] applyEffectToView:self.filterSidebarContainer];
    self.filterSidebarContainer.hidden = YES;
    [self.view addSubview:self.filterSidebarContainer];

    // Sidebar width constraint: 0 when hidden, 180 (wide screen) or 140 (narrow screen) when shown
    // Adjusted dynamically from the screen width in viewDidLayoutSubviews
    self.sidebarWidthConstraint = [self.filterSidebarContainer.widthAnchor constraintEqualToConstant:0];

    [NSLayoutConstraint activateConstraints:@[
        [self.filterSidebarContainer.topAnchor constraintEqualToAnchor:self.tabSegment.bottomAnchor constant:8],
        // Key fix: leave 8pt of leading spacing so it does not visually touch the menu bar on the left (LauncherMenuViewController).
        // Previously leading = view.leading+0, so filterSidebarContainer sat flush against the left edge of contentContainer,
        // and that edge is the right edge of the menu bar, making the filter bar look "glued" to it.
        // With 8pt of spacing there is a clear gap, symmetric with the 8pt gap to the tableView on the right.
        [self.filterSidebarContainer.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor constant:8],
        [self.filterSidebarContainer.bottomAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.bottomAnchor],
        self.sidebarWidthConstraint
    ]];

    // ===== 1. Download source picker (moved down from the top) =====
    self.sidebarSourceContainer = [[UIView alloc] init];
    self.sidebarSourceContainer.translatesAutoresizingMaskIntoConstraints = NO;
    [self.filterSidebarContainer addSubview:self.sidebarSourceContainer];

    // Download source title
    UILabel *sourceTitleLabel = [[UILabel alloc] init];
    sourceTitleLabel.translatesAutoresizingMaskIntoConstraints = NO;
    sourceTitleLabel.text = @"Download source";
    sourceTitleLabel.font = [UIFont systemFontOfSize:13 weight:UIFontWeightSemibold];
    sourceTitleLabel.textColor = [UIColor secondaryLabelColor];
    [self.filterSidebarContainer addSubview:sourceTitleLabel];

    // Download source track
    self.sidebarSourceTrack = [[UIView alloc] init];
    self.sidebarSourceTrack.translatesAutoresizingMaskIntoConstraints = NO;
    self.sidebarSourceTrack.backgroundColor = [UIColor tertiarySystemFillColor];
    self.sidebarSourceTrack.layer.cornerRadius = 14;
    self.sidebarSourceTrack.layer.masksToBounds = YES;
    [self.sidebarSourceContainer addSubview:self.sidebarSourceTrack];

    // Download source slider
    self.sidebarSourceSlider = [[UIView alloc] init];
    self.sidebarSourceSlider.translatesAutoresizingMaskIntoConstraints = NO;
    self.sidebarSourceSlider.backgroundColor = [UIColor systemGreenColor];
    self.sidebarSourceSlider.layer.cornerRadius = 12;
    self.sidebarSourceSlider.layer.shadowColor = [UIColor blackColor].CGColor;
    self.sidebarSourceSlider.layer.shadowOpacity = 0.15;
    self.sidebarSourceSlider.layer.shadowOffset = CGSizeMake(0, 1);
    self.sidebarSourceSlider.layer.shadowRadius = 3;
    [self.sidebarSourceTrack addSubview:self.sidebarSourceSlider];

    // Modrinth button
    self.sidebarModrinthButton = [UIButton buttonWithType:UIButtonTypeSystem];
    self.sidebarModrinthButton.translatesAutoresizingMaskIntoConstraints = NO;
    [self.sidebarModrinthButton setTitle:@"Mod" forState:UIControlStateNormal];
    self.sidebarModrinthButton.titleLabel.font = [UIFont systemFontOfSize:12 weight:UIFontWeightSemibold];
    [self.sidebarModrinthButton addTarget:self action:@selector(sidebarModrinthClicked:) forControlEvents:UIControlEventTouchUpInside];
    [self.sidebarSourceTrack addSubview:self.sidebarModrinthButton];

    // CurseForge button
    self.sidebarCurseforgeButton = [UIButton buttonWithType:UIButtonTypeSystem];
    self.sidebarCurseforgeButton.translatesAutoresizingMaskIntoConstraints = NO;
    [self.sidebarCurseforgeButton setTitle:@"CF" forState:UIControlStateNormal];
    self.sidebarCurseforgeButton.titleLabel.font = [UIFont systemFontOfSize:12 weight:UIFontWeightSemibold];
    [self.sidebarCurseforgeButton addTarget:self action:@selector(sidebarCurseforgeClicked:) forControlEvents:UIControlEventTouchUpInside];
    [self.sidebarSourceTrack addSubview:self.sidebarCurseforgeButton];

    // Download source slider position constraints
    self.sidebarSliderLeftConstraint = [self.sidebarSourceSlider.leadingAnchor constraintEqualToAnchor:self.sidebarSourceTrack.leadingAnchor constant:2];
    self.sidebarSliderRightConstraint = [self.sidebarSourceSlider.trailingAnchor constraintEqualToAnchor:self.sidebarSourceTrack.trailingAnchor constant:-2];
    self.sidebarSliderRightConstraint.active = NO;

    [NSLayoutConstraint activateConstraints:@[
        // Download source title
        [sourceTitleLabel.topAnchor constraintEqualToAnchor:self.filterSidebarContainer.topAnchor constant:12],
        [sourceTitleLabel.leadingAnchor constraintEqualToAnchor:self.filterSidebarContainer.leadingAnchor constant:12],
        [sourceTitleLabel.trailingAnchor constraintEqualToAnchor:self.filterSidebarContainer.trailingAnchor constant:-12],

        // Download source container
        [self.sidebarSourceContainer.topAnchor constraintEqualToAnchor:sourceTitleLabel.bottomAnchor constant:4],
        [self.sidebarSourceContainer.leadingAnchor constraintEqualToAnchor:self.filterSidebarContainer.leadingAnchor constant:8],
        [self.sidebarSourceContainer.trailingAnchor constraintEqualToAnchor:self.filterSidebarContainer.trailingAnchor constant:-8],
        [self.sidebarSourceContainer.heightAnchor constraintEqualToConstant:32],

        // The track fills the container
        [self.sidebarSourceTrack.topAnchor constraintEqualToAnchor:self.sidebarSourceContainer.topAnchor],
        [self.sidebarSourceTrack.leadingAnchor constraintEqualToAnchor:self.sidebarSourceContainer.leadingAnchor],
        [self.sidebarSourceTrack.trailingAnchor constraintEqualToAnchor:self.sidebarSourceContainer.trailingAnchor],
        [self.sidebarSourceTrack.bottomAnchor constraintEqualToAnchor:self.sidebarSourceContainer.bottomAnchor],

        // Slider
        [self.sidebarSourceSlider.topAnchor constraintEqualToAnchor:self.sidebarSourceTrack.topAnchor constant:2],
        [self.sidebarSourceSlider.bottomAnchor constraintEqualToAnchor:self.sidebarSourceTrack.bottomAnchor constant:-2],
        [self.sidebarSourceSlider.widthAnchor constraintEqualToAnchor:self.sidebarSourceTrack.widthAnchor multiplier:0.5 constant:-2],
        self.sidebarSliderLeftConstraint,

        // The two buttons take half each
        [self.sidebarModrinthButton.topAnchor constraintEqualToAnchor:self.sidebarSourceTrack.topAnchor],
        [self.sidebarModrinthButton.bottomAnchor constraintEqualToAnchor:self.sidebarSourceTrack.bottomAnchor],
        [self.sidebarModrinthButton.leadingAnchor constraintEqualToAnchor:self.sidebarSourceTrack.leadingAnchor],
        [self.sidebarModrinthButton.widthAnchor constraintEqualToAnchor:self.sidebarSourceTrack.widthAnchor multiplier:0.5],

        [self.sidebarCurseforgeButton.topAnchor constraintEqualToAnchor:self.sidebarSourceTrack.topAnchor],
        [self.sidebarCurseforgeButton.bottomAnchor constraintEqualToAnchor:self.sidebarSourceTrack.bottomAnchor],
        [self.sidebarCurseforgeButton.trailingAnchor constraintEqualToAnchor:self.sidebarSourceTrack.trailingAnchor],
        [self.sidebarCurseforgeButton.widthAnchor constraintEqualToAnchor:self.sidebarSourceTrack.widthAnchor multiplier:0.5]
    ]];

    // ===== 2. Game version button =====
    self.sidebarVersionButton = [self createSidebarSelectButtonWithTitle:@"Game version"
                                                                    value:@"All versions"
                                                                  selector:@selector(sidebarVersionButtonClicked:)];
    [self.filterSidebarContainer addSubview:self.sidebarVersionButton];
    self.sidebarVersionTitleLabel = [self findSubviewInButton:self.sidebarVersionButton withTag:100];
    self.sidebarVersionValueLabel = [self findSubviewInButton:self.sidebarVersionButton withTag:101];
    [NSLayoutConstraint activateConstraints:@[
        [self.sidebarVersionButton.topAnchor constraintEqualToAnchor:self.sidebarSourceContainer.bottomAnchor constant:8],
        [self.sidebarVersionButton.leadingAnchor constraintEqualToAnchor:self.filterSidebarContainer.leadingAnchor constant:8],
        [self.sidebarVersionButton.trailingAnchor constraintEqualToAnchor:self.filterSidebarContainer.trailingAnchor constant:-8],
        [self.sidebarVersionButton.heightAnchor constraintEqualToConstant:44]
    ]];

    // ===== 3. Mod loader button =====
    self.sidebarLoaderButton = [self createSidebarSelectButtonWithTitle:@"Mod loader"
                                                                   value:@"All"
                                                                 selector:@selector(sidebarLoaderButtonClicked:)];
    [self.filterSidebarContainer addSubview:self.sidebarLoaderButton];
    self.sidebarLoaderTitleLabel = [self findSubviewInButton:self.sidebarLoaderButton withTag:100];
    self.sidebarLoaderValueLabel = [self findSubviewInButton:self.sidebarLoaderButton withTag:101];
    [NSLayoutConstraint activateConstraints:@[
        [self.sidebarLoaderButton.topAnchor constraintEqualToAnchor:self.sidebarVersionButton.bottomAnchor constant:8],
        [self.sidebarLoaderButton.leadingAnchor constraintEqualToAnchor:self.filterSidebarContainer.leadingAnchor constant:8],
        [self.sidebarLoaderButton.trailingAnchor constraintEqualToAnchor:self.filterSidebarContainer.trailingAnchor constant:-8],
        [self.sidebarLoaderButton.heightAnchor constraintEqualToConstant:44]
    ]];

    // ===== 4. Sort button =====
    self.sidebarSortButton = [self createSidebarSelectButtonWithTitle:@"Sort by"
                                                                 value:@"Relevance"
                                                               selector:@selector(sidebarSortButtonClicked:)];
    [self.filterSidebarContainer addSubview:self.sidebarSortButton];
    self.sidebarSortTitleLabel = [self findSubviewInButton:self.sidebarSortButton withTag:100];
    self.sidebarSortValueLabel = [self findSubviewInButton:self.sidebarSortButton withTag:101];
    [NSLayoutConstraint activateConstraints:@[
        [self.sidebarSortButton.topAnchor constraintEqualToAnchor:self.sidebarLoaderButton.bottomAnchor constant:8],
        [self.sidebarSortButton.leadingAnchor constraintEqualToAnchor:self.filterSidebarContainer.leadingAnchor constant:8],
        [self.sidebarSortButton.trailingAnchor constraintEqualToAnchor:self.filterSidebarContainer.trailingAnchor constant:-8],
        [self.sidebarSortButton.heightAnchor constraintEqualToConstant:44]
    ]];

    // ===== 5. Reset filters button =====
    self.sidebarResetButton = [UIButton buttonWithType:UIButtonTypeSystem];
    self.sidebarResetButton.translatesAutoresizingMaskIntoConstraints = NO;
    [self.sidebarResetButton setTitle:@"Reset filters" forState:UIControlStateNormal];
    self.sidebarResetButton.titleLabel.font = [UIFont systemFontOfSize:13 weight:UIFontWeightMedium];
    [self.sidebarResetButton setImage:[UIImage systemImageNamed:@"arrow.counterclockwise"] forState:UIControlStateNormal];
    self.sidebarResetButton.tintColor = [UIColor systemRedColor];
    self.sidebarResetButton.backgroundColor = [UIColor tertiarySystemFillColor];
    self.sidebarResetButton.layer.cornerRadius = 8;
    self.sidebarResetButton.imageEdgeInsets = UIEdgeInsetsMake(0, -2, 0, 2);
    self.sidebarResetButton.titleEdgeInsets = UIEdgeInsetsMake(0, 2, 0, -2);
    [self.sidebarResetButton addTarget:self action:@selector(sidebarResetButtonClicked:) forControlEvents:UIControlEventTouchUpInside];
    [self.filterSidebarContainer addSubview:self.sidebarResetButton];

    [NSLayoutConstraint activateConstraints:@[
        [self.sidebarResetButton.topAnchor constraintEqualToAnchor:self.sidebarSortButton.bottomAnchor constant:12],
        [self.sidebarResetButton.leadingAnchor constraintEqualToAnchor:self.filterSidebarContainer.leadingAnchor constant:12],
        [self.sidebarResetButton.trailingAnchor constraintEqualToAnchor:self.filterSidebarContainer.trailingAnchor constant:-12],
        [self.sidebarResetButton.heightAnchor constraintEqualToConstant:32]
    ]];

    // Separator at the bottom
    UIView *sidebarSeparator = [[UIView alloc] init];
    sidebarSeparator.translatesAutoresizingMaskIntoConstraints = NO;
    sidebarSeparator.backgroundColor = [UIColor separatorColor];
    [self.filterSidebarContainer addSubview:sidebarSeparator];
    [NSLayoutConstraint activateConstraints:@[
        [sidebarSeparator.trailingAnchor constraintEqualToAnchor:self.filterSidebarContainer.trailingAnchor],
        [sidebarSeparator.topAnchor constraintEqualToAnchor:self.filterSidebarContainer.topAnchor],
        [sidebarSeparator.bottomAnchor constraintEqualToAnchor:self.filterSidebarContainer.bottomAnchor],
        [sidebarSeparator.widthAnchor constraintEqualToConstant:0.5]
    ]];
}

/// Build a sidebar picker button (title + current value + chevron)
/// The subviews are marked with tags: titleTag=100, valueTag=101, arrowTag=102
/// After creation the labels can be fetched with findSubviewInButton:withTag:
- (UIButton *)createSidebarSelectButtonWithTitle:(NSString *)title
                                           value:(NSString *)value
                                         selector:(SEL)selector {
    UIButton *button = [UIButton buttonWithType:UIButtonTypeSystem];
    button.translatesAutoresizingMaskIntoConstraints = NO;
    button.backgroundColor = [UIColor tertiarySystemFillColor];
    button.layer.cornerRadius = 8;
    [button addTarget:self action:selector forControlEvents:UIControlEventTouchUpInside];
    button.contentHorizontalAlignment = UIControlContentHorizontalAlignmentLeft;
    button.contentEdgeInsets = UIEdgeInsetsMake(0, 12, 0, 12);

    UILabel *titleLabel = [[UILabel alloc] init];
    titleLabel.translatesAutoresizingMaskIntoConstraints = NO;
    titleLabel.text = title;
    titleLabel.font = [UIFont systemFontOfSize:12 weight:UIFontWeightSemibold];
    titleLabel.textColor = [UIColor secondaryLabelColor];
    titleLabel.tag = 100;
    [button addSubview:titleLabel];

    UILabel *valueLabel = [[UILabel alloc] init];
    valueLabel.translatesAutoresizingMaskIntoConstraints = NO;
    valueLabel.text = value;
    valueLabel.font = [UIFont systemFontOfSize:12];
    valueLabel.textColor = [UIColor labelColor];
    valueLabel.adjustsFontSizeToFitWidth = YES;
    valueLabel.minimumScaleFactor = 0.7;
    valueLabel.textAlignment = NSTextAlignmentRight;
    valueLabel.tag = 101;
    [button addSubview:valueLabel];

    UIImageView *arrow = [[UIImageView alloc] initWithImage:[UIImage systemImageNamed:@"chevron.right"]];
    arrow.translatesAutoresizingMaskIntoConstraints = NO;
    arrow.tintColor = [UIColor tertiaryLabelColor];
    arrow.contentMode = UIViewContentModeScaleAspectFit;
    arrow.tag = 102;
    [button addSubview:arrow];

    [NSLayoutConstraint activateConstraints:@[
        [titleLabel.leadingAnchor constraintEqualToAnchor:button.leadingAnchor constant:12],
        [titleLabel.centerYAnchor constraintEqualToAnchor:button.centerYAnchor],

        [valueLabel.trailingAnchor constraintEqualToAnchor:arrow.leadingAnchor constant:-4],
        [valueLabel.centerYAnchor constraintEqualToAnchor:button.centerYAnchor],
        [valueLabel.widthAnchor constraintLessThanOrEqualToConstant:80],

        [arrow.trailingAnchor constraintEqualToAnchor:button.trailingAnchor constant:-12],
        [arrow.centerYAnchor constraintEqualToAnchor:button.centerYAnchor],
        [arrow.widthAnchor constraintEqualToConstant:12],
        [arrow.heightAnchor constraintEqualToConstant:12]
    ]];

    return button;
}

/// Fetch a subview from a button by tag (for buttons created by createSidebarSelectButtonWithTitle:)
- (UILabel *)findSubviewInButton:(UIButton *)button withTag:(NSInteger)tag {
    for (UIView *sub in button.subviews) {
        if (sub.tag == tag && [sub isKindOfClass:[UILabel class]]) {
            return (UILabel *)sub;
        }
    }
    return nil;
}

- (void)setupLoadingIndicator {
    self.loadingIndicator = [[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleLarge];
    self.loadingIndicator.translatesAutoresizingMaskIntoConstraints = NO;
    self.loadingIndicator.hidesWhenStopped = YES;
    self.loadingIndicator.color = [UIColor labelColor];
    [self.view addSubview:self.loadingIndicator];
    
    [NSLayoutConstraint activateConstraints:@[
        [self.loadingIndicator.centerXAnchor constraintEqualToAnchor:self.view.centerXAnchor],
        [self.loadingIndicator.centerYAnchor constraintEqualToAnchor:self.view.centerYAnchor]
    ]];
}

- (void)setupEmptyLabel {
    self.emptyLabel = [[UILabel alloc] init];
    self.emptyLabel.translatesAutoresizingMaskIntoConstraints = NO;
    self.emptyLabel.text = @"Nothing here";
    self.emptyLabel.textAlignment = NSTextAlignmentCenter;
    self.emptyLabel.textColor = [UIColor secondaryLabelColor];
    self.emptyLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleBody];
    self.emptyLabel.hidden = YES;
    [self.view addSubview:self.emptyLabel];
    
    [NSLayoutConstraint activateConstraints:@[
        [self.emptyLabel.centerXAnchor constraintEqualToAnchor:self.view.centerXAnchor],
        [self.emptyLabel.centerYAnchor constraintEqualToAnchor:self.view.centerYAnchor]
    ]];
}

#pragma mark - Tab Switching

- (void)tabChanged:(UISegmentedControl *)sender {
    [self switchToTab:sender.selectedSegmentIndex];
}

- (void)switchToTab:(NSInteger)index {
    // Switch lists with a cross-fade, avoiding a harsh instant hidden toggle
    [UIView transitionWithView:self.view duration:0.2 options:UIViewAnimationOptionTransitionCrossDissolve animations:^{
        self.versionFilterSegment.hidden = (index != 0);
        self.versionCollectionView.hidden = (index != 0);
        // The search box is shown on every tab (on the version tab it filters the local and remote version lists by version number prefix)
        self.searchBar.hidden = NO;
        // The filter button is shown only on the version tab (for the version type filter/sort options)
        self.filterButton.hidden = (index != 0);
        self.modTableView.hidden = (index != 1);
        self.shaderTableView.hidden = (index != 2);
        self.resourcepackTableView.hidden = (index != 3);
        self.datapackTableView.hidden = (index != 4);
        self.modpackTableView.hidden = (index != 5);
        self.worldTableView.hidden = (index != 6);
    } completion:nil];

    // The source switch is shown only on non-version tabs; the world tab always uses CurseForge, so it needs no switch
    // Note: the top sourceSwitchContainer is deprecated (the download source moved into the sidebar) and is always hidden
    // The property is kept so other methods referencing it do not crash, but its height stays 0
    BOOL showSourceSwitch = (index != 0 && index != 6);
    self.sourceSwitchContainer.hidden = YES;
    self.sourceSwitchHeightConstraint.constant = 0;

    // ===== Showing/hiding the FCL/ZL2-style sidebar =====
    // FCL page_download.xml: the 5 asset tabs (mod/modpack/resourcepack/world/shaderpack) share
    // a 30% filter bar on the left. The version tab has its own layout (versionFilterSegment + collectionView) with no sidebar.
    // This matches FCL exactly: every non-version tab shows the sidebar (including the world tab).
    BOOL showSidebar = (index != 0);
    self.filterSidebarContainer.hidden = !showSidebar;
    // Compute the sidebar width as 30% of the screen width (FCL constraintWidth_percent=0.3)
    CGFloat screenWidth = self.view.bounds.size.width;
    CGFloat sidebarWidth = 0;
    if (showSidebar) {
        sidebarWidth = screenWidth * 0.3;
        sidebarWidth = MAX(120.0, MIN(280.0, sidebarWidth));
    }
    self.sidebarWidthConstraint.constant = sidebarWidth;

    // The mod loader button is shown only on the mod tab (the other tabs have no concept of a loader)
    self.sidebarLoaderButton.hidden = (index != 1);
    self.sidebarLoaderTitleLabel.hidden = (index != 1);
    self.sidebarLoaderValueLabel.hidden = (index != 1);

    // Download source switch: the world tab always uses CurseForge and hides it; the other non-version tabs show it
    // FCL page_download.xml: the source spinner is only shown when there is more than one source
    self.sidebarSourceContainer.hidden = (index == 0 || index == 6);

    // The versionFilterSegment height switches with it: 32pt on the version tab and 0 on the others so it takes no space,
    // This avoids hidden=YES still taking up space and leaving "a big white band" between tabSegment and searchBar
    self.versionFilterHeightConstraint.constant = (index == 0) ? 32 : 0;

    // The modpack tab shows the "Import local modpack" button (as in FCL for Android); the other tabs hide it and collapse its width to 0
    BOOL showImportButton = (index == 5);
    self.importModpackButton.hidden = !showImportButton;
    self.importModpackButtonWidthConstraint.constant = showImportButton ? 80 : 0;

    [UIView animateWithDuration:0.2 animations:^{
        [self.view layoutIfNeeded];
    }];

    if (index == 0) {
        // Version tab: filter the version list by version number prefix
        self.searchBar.placeholder = @"Search versions...";
        // The version tab does not need the source switch
    } else if (index == 1) {
        self.searchBar.placeholder = @"Search mods...";
        [self updateSourceSwitchButtonsForType:@"mod"];
        // FCL style: preselect the current profile's version and loader the first time the mod tab is opened
        // so search results match the current game setup (e.g. neoforge + 1.21.1) without manual filtering
        [self autoApplyProfileFiltersIfNeeded];
        if (self.modList.count == 0) {
            [self loadModList];
        }
    } else if (index == 2) {
        self.searchBar.placeholder = @"Search shaders...";
        [self updateSourceSwitchButtonsForType:@"shader"];
        [self autoApplyProfileFiltersIfNeeded];
        if (self.shaderList.count == 0) {
            [self loadShaderList];
        }
    } else if (index == 3) {
        self.searchBar.placeholder = @"Search resource packs...";
        [self updateSourceSwitchButtonsForType:@"resourcepack"];
        [self autoApplyProfileFiltersIfNeeded];
        if (self.resourcepackList.count == 0) {
            [self loadResourcePackList];
        }
    } else if (index == 4) {
        self.searchBar.placeholder = @"Search data packs...";
        [self updateSourceSwitchButtonsForType:@"datapack"];
        [self autoApplyProfileFiltersIfNeeded];
        if (self.datapackList.count == 0) {
            [self loadDataPackList];
        }
    } else if (index == 5) {
        self.searchBar.placeholder = @"Search modpacks...";
        [self updateSourceSwitchButtonsForType:@"modpack"];
        [self autoApplyProfileFiltersIfNeeded];
        if (self.modpackList.count == 0) {
            [self loadModpackList];
        }
    } else if (index == 6) {
        self.searchBar.placeholder = @"Search worlds...";
        [self updateSourceSwitchButtonsForType:@"world"];
        if (self.worldList.count == 0) {
            [self loadWorldList];
        }
    }

    // Update the current value shown for each sidebar filter
    [self updateSidebarFilterValues];
}

#pragma mark - Source Switch

- (void)updateSourceSwitchButtonsForType:(NSString *)type {
    NSString *currentSource = [PLPreferences currentDownloadSourceForType:type];
    BOOL isModrinth = [currentSource isEqualToString:@"modrinth"];

    // Selected item text is white and unselected uses labelColor (the top sourceSwitch is deprecated but kept in sync)
    [self.modrinthSourceButton setTitleColor:isModrinth ? [UIColor whiteColor] : [UIColor labelColor] forState:UIControlStateNormal];
    [self.curseforgeSourceButton setTitleColor:isModrinth ? [UIColor labelColor] : [UIColor whiteColor] forState:UIControlStateNormal];

    // Slider position: switched by activating either the left or right constraint, alongside a color animation
    self.sliderLeftPosConstraint.active = isModrinth;
    self.sliderRightPosConstraint.active = !isModrinth;
    UIColor *sliderColor = isModrinth ? [UIColor systemGreenColor] : [UIColor systemOrangeColor];

    [UIView animateWithDuration:0.25 delay:0 options:UIViewAnimationOptionCurveEaseInOut animations:^{
        self.sourceSwitchSlider.backgroundColor = sliderColor;
        [self.sourceSwitchTrack layoutIfNeeded];
    } completion:nil];

    self.modrinthSourceButton.tag = [self tagForType:type];
    self.curseforgeSourceButton.tag = [self tagForType:type];

    // ===== Keep the sidebar download source picker in sync =====
    [self.sidebarModrinthButton setTitleColor:isModrinth ? [UIColor whiteColor] : [UIColor labelColor] forState:UIControlStateNormal];
    [self.sidebarCurseforgeButton setTitleColor:isModrinth ? [UIColor labelColor] : [UIColor whiteColor] forState:UIControlStateNormal];

    self.sidebarSliderLeftConstraint.active = isModrinth;
    self.sidebarSliderRightConstraint.active = !isModrinth;
    UIColor *sidebarSliderColor = isModrinth ? [UIColor systemGreenColor] : [UIColor systemOrangeColor];

    [UIView animateWithDuration:0.25 delay:0 options:UIViewAnimationOptionCurveEaseInOut animations:^{
        self.sidebarSourceSlider.backgroundColor = sidebarSliderColor;
        [self.sidebarSourceTrack layoutIfNeeded];
    } completion:nil];

    // Record the current type in the sidebar button tag, so the tap handler can read it back
    self.sidebarModrinthButton.tag = [self tagForType:type];
    self.sidebarCurseforgeButton.tag = [self tagForType:type];
}

- (NSInteger)tagForType:(NSString *)type {
    if ([type isEqualToString:@"mod"]) return 1;
    if ([type isEqualToString:@"shader"]) return 2;
    if ([type isEqualToString:@"resourcepack"]) return 3;
    if ([type isEqualToString:@"datapack"]) return 4;
    if ([type isEqualToString:@"modpack"]) return 5;
    if ([type isEqualToString:@"world"]) return 6;
    return 0;
}

- (NSString *)typeForTag:(NSInteger)tag {
    switch (tag) {
        case 1: return @"mod";
        case 2: return @"shader";
        case 3: return @"resourcepack";
        case 4: return @"datapack";
        case 5: return @"modpack";
        case 6: return @"world";
        default: return @"mod";
    }
}

- (NSString *)currentTabType {
    NSInteger index = self.tabSegment.selectedSegmentIndex;
    switch (index) {
        case 1: return @"mod";
        case 2: return @"shader";
        case 3: return @"resourcepack";
        case 4: return @"datapack";
        case 5: return @"modpack";
        case 6: return @"world";
        default: return @"mod";
    }
}

- (void)modrinthSourceButtonClicked:(UIButton *)sender {
    NSString *type = [self typeForTag:sender.tag];
    NSString *currentSource = [PLPreferences currentDownloadSourceForType:type];
    if ([currentSource isEqualToString:@"modrinth"]) return;

    [PLPreferences setDownloadSource:@"modrinth" forType:type];
    [self updateSourceSwitchButtonsForType:type];
    [self reloadCurrentList];
}

- (void)curseforgeSourceButtonClicked:(UIButton *)sender {
    NSString *type = [self typeForTag:sender.tag];
    NSString *currentSource = [PLPreferences currentDownloadSourceForType:type];
    if ([currentSource isEqualToString:@"curseforge"]) return;

    // Show a hint in the content area when no API key is configured (instead of an alert)
    if (![CurseForgeAPI isAPIKeyConfigured]) {
        InlineMessageView *msgView = [InlineMessageView showInViewController:self
                                                                       title:@"CurseForge API key required"
                                                                    message:@"No CurseForge API key is configured. Tap to open Settings"
                                                                       type:InlineMessageTypeInfo];
        // Jump to the settings page automatically after 2 seconds
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            [msgView dismiss];
            [self openCurseForgeAPIKeySettings];
        });
        return;
    }

    [PLPreferences setDownloadSource:@"curseforge" forType:type];
    [self updateSourceSwitchButtonsForType:type];
    [self reloadCurrentList];
}

#pragma mark - Sidebar download source tap handling

/// Sidebar Modrinth source button tapped
- (void)sidebarModrinthClicked:(UIButton *)sender {
    NSString *type = [self typeForTag:sender.tag];
    NSString *currentSource = [PLPreferences currentDownloadSourceForType:type];
    if ([currentSource isEqualToString:@"modrinth"]) return;

    [PLPreferences setDownloadSource:@"modrinth" forType:type];
    [self updateSourceSwitchButtonsForType:type];
    [self reloadCurrentList];
}

/// Sidebar CurseForge source button tapped
- (void)sidebarCurseforgeClicked:(UIButton *)sender {
    NSString *type = [self typeForTag:sender.tag];
    NSString *currentSource = [PLPreferences currentDownloadSourceForType:type];
    if ([currentSource isEqualToString:@"curseforge"]) return;

    // Hint shown when no API key is configured
    if (![CurseForgeAPI isAPIKeyConfigured]) {
        InlineMessageView *msgView = [InlineMessageView showInViewController:self
                                                                       title:@"CurseForge API key required"
                                                                    message:@"No CurseForge API key is configured. Tap to open Settings"
                                                                       type:InlineMessageTypeInfo];
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            [msgView dismiss];
            [self openCurseForgeAPIKeySettings];
        });
        return;
    }

    [PLPreferences setDownloadSource:@"curseforge" forType:type];
    [self updateSourceSwitchButtonsForType:type];
    [self reloadCurrentList];
}

#pragma mark - Sidebar filter button tap handling

/// Sidebar game version button tapped
- (void)sidebarVersionButtonClicked:(UIButton *)sender {
    [self showGameVersionPicker];
}

/// Sidebar mod loader button tapped
- (void)sidebarLoaderButtonClicked:(UIButton *)sender {
    [self showModLoaderPicker];
}

/// Sidebar sort button tapped
- (void)sidebarSortButtonClicked:(UIButton *)sender {
    [self showSortOptions];
}

/// Sidebar reset filters button tapped
- (void)sidebarResetButtonClicked:(UIButton *)sender {
    [self resetFilters];
}

/// Update the current value shown for each sidebar filter
- (void)updateSidebarFilterValues {
    // Game version
    if (self.currentGameVersion.length > 0) {
        self.sidebarVersionValueLabel.text = self.currentGameVersion;
    } else {
        self.sidebarVersionValueLabel.text = @"All versions";
    }

    // Mod loader
    if (self.currentModLoader.length > 0) {
        // Display it capitalized
        NSString *loader = self.currentModLoader;
        NSString *capitalized = [[loader substringToIndex:1].uppercaseString stringByAppendingString:[loader substringFromIndex:1]];
        self.sidebarLoaderValueLabel.text = capitalized;
    } else {
        self.sidebarLoaderValueLabel.text = @"All";
    }

    // Sort
    if (self.currentSortField.length > 0) {
        // Convert the sort field into its display text
        NSDictionary *sortDisplayMap = @{
            @"relevance": @"Relevance",
            @"downloads": @"Downloads",
            @"follows": @"Follows",
            @"newest": @"Newest",
            @"updated": @"Recently updated"
        };
        NSString *display = sortDisplayMap[self.currentSortField];
        self.sidebarSortValueLabel.text = display ?: self.currentSortField;
    } else {
        self.sidebarSortValueLabel.text = @"Relevance";
    }
}

- (id)currentAPIForTabType:(NSString *)type {
    // Modrinth has no project_type:world facet (its project_type is only mod/modpack/shader/resourcepack/plugin)
    // The world tab therefore always uses CurseForge (classID 17 = Worlds, which does exist)
    if ([type isEqualToString:@"world"]) {
        return [CurseForgeAPI sharedInstance];
    }
    NSString *source = [PLPreferences currentDownloadSourceForType:type];
    if ([source isEqualToString:@"curseforge"]) {
        return [CurseForgeAPI sharedInstance];
    }
    return [ModrinthAPI sharedInstance];
}

// API key entry point in the navigation bar: push the settings page directly, without the alert detour
- (void)openCurseForgeAPIKeySettings {
    CurseForgeAPIKeyViewController *vc = [[CurseForgeAPIKeyViewController alloc] init];
    UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:vc];
    nav.modalPresentationStyle = UIModalPresentationFormSheet;
    [self presentViewController:nav animated:YES completion:nil];
}

#pragma mark - Data Loading

- (void)loadVersionList {
    [self.loadingIndicator startAnimating];
    
    NSString *downloadSource = getPrefObject(@"general.download_source");
    NSString *versionManifestURL;
    
    if ([downloadSource isEqualToString:@"bmclapi"]) {
        versionManifestURL = @"https://bmclapi2.bangbang93.com/mc/game/version_manifest_v2.json";
    } else {
        versionManifestURL = @"https://piston-meta.mojang.com/mc/game/version_manifest_v2.json";
    }
    
    NSURL *url = [NSURL URLWithString:versionManifestURL];
    __weak typeof(self) weakSelf = self;
    NSURLSessionDataTask *task = [[NSURLSession sharedSession] dataTaskWithURL:url completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        dispatch_async(dispatch_get_main_queue(), ^{
            __strong typeof(weakSelf) strongSelf = weakSelf;
            if (!strongSelf) return;
            [strongSelf.loadingIndicator stopAnimating];
            
            if (data && !error) {
                NSError *jsonError;
                NSDictionary *json = [NSJSONSerialization JSONObjectWithData:data options:0 error:&jsonError];
                if (json && !jsonError) {
                    strongSelf.versionList = json[@"versions"];
                    [strongSelf applyVersionFilter];
                } else {
                    strongSelf.emptyLabel.text = @"Failed to load the version list";
                    strongSelf.emptyLabel.hidden = NO;
                }
            } else {
                strongSelf.emptyLabel.text = @"Network error, could not load versions";
                strongSelf.emptyLabel.hidden = NO;
            }
        });
    }];
    [task resume];
}

- (void)versionFilterChanged:(UISegmentedControl *)sender {
    [self applyVersionFilter];
}

- (void)applyVersionFilter {
    if (!self.versionList) return;
    
    NSInteger filterIndex = self.versionFilterSegment.selectedSegmentIndex;
    // Search term: case-insensitive, trimmed, matched against the version number prefix
    NSString *query = [self.versionSearchQuery stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    NSString *lowerQuery = query.lowercaseString;
    BOOL hasQuery = (lowerQuery.length > 0);
    
    NSMutableArray *filtered = [NSMutableArray array];
    
    for (NSDictionary *version in self.versionList) {
        NSString *type = version[@"type"];
        
        BOOL typeMatch = NO;
        if (filterIndex == 0) {
            typeMatch = YES;
        } else if (filterIndex == 1 && [type isEqualToString:@"release"]) {
            typeMatch = YES;
        } else if (filterIndex == 2 && [type isEqualToString:@"snapshot"]) {
            typeMatch = YES;
        } else if (filterIndex == 3 && ([type isEqualToString:@"old_alpha"] || [type isEqualToString:@"old_beta"])) {
            typeMatch = YES;
        }
        if (!typeMatch) continue;
        
        // Apply the search term filter (matching the id prefix, e.g. "1.2" matches "1.20.4")
        if (hasQuery) {
            NSString *versionId = version[@"id"];
            if (![versionId isKindOfClass:[NSString class]] || versionId.length == 0) continue;
            if (![versionId.lowercaseString hasPrefix:lowerQuery]) continue;
        }
        
        [filtered addObject:version];
    }
    
    self.filteredVersions = filtered;
    [self.versionCollectionView reloadData];
    
    self.emptyLabel.hidden = (self.filteredVersions.count > 0);
    if (self.filteredVersions.count == 0) {
        self.emptyLabel.text = hasQuery ? @"No matching versions" : @"No versions";
        self.emptyLabel.hidden = NO;
    } else {
        self.emptyLabel.hidden = YES;
    }
}

#pragma mark - Mod Search & Loading

- (void)refreshModList {
    self.currentModOffset = 0;
    self.hasMoreMods = YES;
    [self.modList removeAllObjects];
    [self loadModList];
}

- (void)loadModList {
    if (self.isLoadingMore) return;
    self.isLoadingMore = YES;
    
    if (self.currentModOffset == 0) {
        [self.loadingIndicator startAnimating];
    }
    
    NSMutableDictionary *filters = [NSMutableDictionary dictionary];
    filters[@"limit"] = @30;
    filters[@"offset"] = @(self.currentModOffset);
    
    if (self.currentSearchQuery.length > 0) {
        filters[@"query"] = self.currentSearchQuery;
    }
    if (self.currentGameVersion.length > 0) {
        filters[@"version"] = self.currentGameVersion;
    }
    if (self.currentModLoader.length > 0) {
        filters[@"loader"] = self.currentModLoader;
    }
    if (self.currentSortField.length > 0) {
        filters[@"sort"] = self.currentSortField;
    }
    
    __weak typeof(self) weakSelf = self;
    id api = [self currentAPIForTabType:@"mod"];
    [api searchModWithFilters:filters completion:^(NSArray * _Nullable results, NSError * _Nullable error) {
        dispatch_async(dispatch_get_main_queue(), ^{
            __strong typeof(weakSelf) strongSelf = weakSelf;
            if (!strongSelf) return;
            [strongSelf.loadingIndicator stopAnimating];
            [strongSelf.modTableView.refreshControl endRefreshing];
            strongSelf.isLoadingMore = NO;
            
            if (results) {
                if (strongSelf.currentModOffset == 0) {
                    [strongSelf.modList removeAllObjects];
                }
                [strongSelf.modList addObjectsFromArray:results];
                strongSelf.hasMoreMods = (results.count >= 30);
                strongSelf.currentModOffset += results.count;
                
                [strongSelf.modTableView reloadData];
                strongSelf.emptyLabel.hidden = (strongSelf.modList.count > 0);
                if (strongSelf.modList.count == 0) {
                    strongSelf.emptyLabel.text = @"No mods";
                    strongSelf.emptyLabel.hidden = NO;
                }
            } else if (error) {
                [strongSelf showError:error.localizedDescription];
            }
        });
    }];
}

- (void)searchMods:(NSString *)query {
    self.currentSearchQuery = query;
    self.currentModOffset = 0;
    self.hasMoreMods = YES;
    [self.modList removeAllObjects];
    [self.modTableView reloadData];
    [self loadModList];
}

#pragma mark - Shader Search & Loading

- (void)refreshShaderList {
    self.currentShaderOffset = 0;
    self.hasMoreShaders = YES;
    [self.shaderList removeAllObjects];
    [self loadShaderList];
}

- (void)loadShaderList {
    if (self.isLoadingMore) return;
    self.isLoadingMore = YES;
    
    if (self.currentShaderOffset == 0) {
        [self.loadingIndicator startAnimating];
    }
    
    NSMutableDictionary *filters = [NSMutableDictionary dictionary];
    filters[@"limit"] = @30;
    filters[@"offset"] = @(self.currentShaderOffset);
    filters[@"projectType"] = @"shader";

    if (self.currentSearchQuery.length > 0) {
        filters[@"query"] = self.currentSearchQuery;
    }
    if (self.currentGameVersion.length > 0) {
        filters[@"version"] = self.currentGameVersion;
    }

    __weak typeof(self) weakSelf = self;
    id api = [self currentAPIForTabType:@"shader"];
    [api searchModWithFilters:filters completion:^(NSArray * _Nullable results, NSError * _Nullable error) {
        dispatch_async(dispatch_get_main_queue(), ^{
            __strong typeof(weakSelf) strongSelf = weakSelf;
            if (!strongSelf) return;
            [strongSelf.loadingIndicator stopAnimating];
            [strongSelf.shaderTableView.refreshControl endRefreshing];
            strongSelf.isLoadingMore = NO;
            
            if (results) {
                if (strongSelf.currentShaderOffset == 0) {
                    [strongSelf.shaderList removeAllObjects];
                }
                [strongSelf.shaderList addObjectsFromArray:results];
                strongSelf.hasMoreShaders = (results.count >= 30);
                strongSelf.currentShaderOffset += results.count;
                
                [strongSelf.shaderTableView reloadData];
                strongSelf.emptyLabel.hidden = (strongSelf.shaderList.count > 0);
                if (strongSelf.shaderList.count == 0) {
                    strongSelf.emptyLabel.text = @"No shaders";
                    strongSelf.emptyLabel.hidden = NO;
                }
            } else if (error) {
                [strongSelf showError:error.localizedDescription];
            }
        });
    }];
}

- (void)searchShaders:(NSString *)query {
    self.currentSearchQuery = query;
    self.currentShaderOffset = 0;
    self.hasMoreShaders = YES;
    [self.shaderList removeAllObjects];
    [self.shaderTableView reloadData];
    [self loadShaderList];
}

#pragma mark - Modpack Search & Loading

- (void)refreshModpackList {
    self.currentModpackOffset = 0;
    self.hasMoreModpacks = YES;
    [self.modpackList removeAllObjects];
    [self loadModpackList];
}

- (void)loadModpackList {
    if (self.isLoadingModpacks) return;
    self.isLoadingModpacks = YES;
    
    if (self.currentModpackOffset == 0) {
        [self.loadingIndicator startAnimating];
    }
    
    NSMutableDictionary *filters = [NSMutableDictionary dictionary];
    filters[@"isModpack"] = @YES;
    filters[@"projectType"] = @"modpack";
    filters[@"limit"] = @30;
    filters[@"offset"] = @(self.currentModpackOffset);
    if (self.modpackSearchQuery.length > 0) {
        filters[@"query"] = self.modpackSearchQuery;
    }
    if (self.currentGameVersion.length > 0) {
        filters[@"version"] = self.currentGameVersion;
    }
    
    __weak typeof(self) weakSelf = self;
    id api = [self currentAPIForTabType:@"modpack"];
    [api searchModWithFilters:filters completion:^(NSArray * _Nullable results, NSError * _Nullable error) {
        dispatch_async(dispatch_get_main_queue(), ^{
            __strong typeof(weakSelf) strongSelf = weakSelf;
            if (!strongSelf) return;
            [strongSelf.loadingIndicator stopAnimating];
            [strongSelf.modpackTableView.refreshControl endRefreshing];
            strongSelf.isLoadingModpacks = NO;
            
            if (results) {
                if (strongSelf.currentModpackOffset == 0) {
                    [strongSelf.modpackList removeAllObjects];
                }
                [strongSelf.modpackList addObjectsFromArray:results];
                strongSelf.hasMoreModpacks = (results.count >= 30);
                strongSelf.currentModpackOffset += results.count;
                
                [strongSelf.modpackTableView reloadData];
                strongSelf.emptyLabel.hidden = (strongSelf.modpackList.count > 0);
                if (strongSelf.modpackList.count == 0) {
                    strongSelf.emptyLabel.text = @"No modpacks";
                    strongSelf.emptyLabel.hidden = NO;
                }
            } else if (error) {
                [strongSelf showError:error.localizedDescription];
            }
        });
    }];
}

- (void)searchModpacks:(NSString *)query {
    self.modpackSearchQuery = query;
    self.currentModpackOffset = 0;
    self.hasMoreModpacks = YES;
    [self.modpackList removeAllObjects];
    [self.modpackTableView reloadData];
    [self loadModpackList];
}

#pragma mark - Resourcepack Search & Loading

- (void)refreshResourcepackList {
    self.currentResourcepackOffset = 0;
    self.hasMoreResourcepacks = YES;
    [self.resourcepackList removeAllObjects];
    [self loadResourcePackList];
}

- (void)loadResourcePackList {
    if (self.isLoadingResourcepacks) return;
    self.isLoadingResourcepacks = YES;

    if (self.currentResourcepackOffset == 0) {
        [self.loadingIndicator startAnimating];
    }

    NSMutableDictionary *filters = [NSMutableDictionary dictionary];
    filters[@"limit"] = @30;
    filters[@"offset"] = @(self.currentResourcepackOffset);
    filters[@"projectType"] = @"resourcepack";

    if (self.resourcepackSearchQuery.length > 0) {
        filters[@"query"] = self.resourcepackSearchQuery;
    }
    if (self.currentGameVersion.length > 0) {
        filters[@"version"] = self.currentGameVersion;
    }

    __weak typeof(self) weakSelf = self;
    id api = [self currentAPIForTabType:@"resourcepack"];
    [api searchModWithFilters:filters completion:^(NSArray * _Nullable results, NSError * _Nullable error) {
        dispatch_async(dispatch_get_main_queue(), ^{
            __strong typeof(weakSelf) strongSelf = weakSelf;
            if (!strongSelf) return;
            [strongSelf.loadingIndicator stopAnimating];
            [strongSelf.resourcepackTableView.refreshControl endRefreshing];
            strongSelf.isLoadingResourcepacks = NO;

            if (results) {
                if (strongSelf.currentResourcepackOffset == 0) {
                    [strongSelf.resourcepackList removeAllObjects];
                }
                [strongSelf.resourcepackList addObjectsFromArray:results];
                strongSelf.hasMoreResourcepacks = (results.count >= 30);
                strongSelf.currentResourcepackOffset += results.count;

                [strongSelf.resourcepackTableView reloadData];
                strongSelf.emptyLabel.hidden = (strongSelf.resourcepackList.count > 0);
                if (strongSelf.resourcepackList.count == 0) {
                    strongSelf.emptyLabel.text = @"No resource packs";
                    strongSelf.emptyLabel.hidden = NO;
                }
            } else if (error) {
                [strongSelf showError:error.localizedDescription];
            }
        });
    }];
}

- (void)searchResourcepacks:(NSString *)query {
    self.resourcepackSearchQuery = query;
    self.currentResourcepackOffset = 0;
    self.hasMoreResourcepacks = YES;
    [self.resourcepackList removeAllObjects];
    [self.resourcepackTableView reloadData];
    [self loadResourcePackList];
}

#pragma mark - Datapack Search & Loading

- (void)refreshDatapackList {
    self.currentDatapackOffset = 0;
    self.hasMoreDatapacks = YES;
    [self.datapackList removeAllObjects];
    [self loadDataPackList];
}

- (void)loadDataPackList {
    if (self.isLoadingDatapacks) return;
    self.isLoadingDatapacks = YES;

    if (self.currentDatapackOffset == 0) {
        [self.loadingIndicator startAnimating];
    }

    NSMutableDictionary *filters = [NSMutableDictionary dictionary];
    filters[@"limit"] = @30;
    filters[@"offset"] = @(self.currentDatapackOffset);
    filters[@"projectType"] = @"datapack";

    if (self.datapackSearchQuery.length > 0) {
        filters[@"query"] = self.datapackSearchQuery;
    }
    if (self.currentGameVersion.length > 0) {
        filters[@"version"] = self.currentGameVersion;
    }

    __weak typeof(self) weakSelf = self;
    id api = [self currentAPIForTabType:@"datapack"];
    [api searchModWithFilters:filters completion:^(NSArray * _Nullable results, NSError * _Nullable error) {
        dispatch_async(dispatch_get_main_queue(), ^{
            __strong typeof(weakSelf) strongSelf = weakSelf;
            if (!strongSelf) return;
            [strongSelf.loadingIndicator stopAnimating];
            [strongSelf.datapackTableView.refreshControl endRefreshing];
            strongSelf.isLoadingDatapacks = NO;

            if (results) {
                if (strongSelf.currentDatapackOffset == 0) {
                    [strongSelf.datapackList removeAllObjects];
                }
                [strongSelf.datapackList addObjectsFromArray:results];
                strongSelf.hasMoreDatapacks = (results.count >= 30);
                strongSelf.currentDatapackOffset += results.count;

                [strongSelf.datapackTableView reloadData];
                strongSelf.emptyLabel.hidden = (strongSelf.datapackList.count > 0);
                if (strongSelf.datapackList.count == 0) {
                    strongSelf.emptyLabel.text = @"No data packs";
                    strongSelf.emptyLabel.hidden = NO;
                }
            } else if (error) {
                [strongSelf showError:error.localizedDescription];
            }
        });
    }];
}

- (void)searchDatapacks:(NSString *)query {
    self.datapackSearchQuery = query;
    self.currentDatapackOffset = 0;
    self.hasMoreDatapacks = YES;
    [self.datapackList removeAllObjects];
    [self.datapackTableView reloadData];
    [self loadDataPackList];
}

#pragma mark - World loading

- (void)refreshWorldList {
    self.currentWorldOffset = 0;
    self.hasMoreWorlds = YES;
    [self.worldList removeAllObjects];
    [self loadWorldList];
}

- (void)loadWorldList {
    if (self.isLoadingWorlds) return;
    self.isLoadingWorlds = YES;

    if (self.currentWorldOffset == 0) {
        [self.loadingIndicator startAnimating];
    }

    // The world tab always uses CurseForge but needs an API key (checked through the same three-level fallback as the real request); when it is missing, point the user at where to set it
    if (![CurseForgeAPI isAPIKeyConfigured]) {
        [self.loadingIndicator stopAnimating];
        [self.worldTableView.refreshControl endRefreshing];
        self.isLoadingWorlds = NO;
        [self.worldList removeAllObjects];
        [self.worldTableView reloadData];
        self.emptyLabel.text = @"The world list requires a CurseForge API key\nConfigure one in Settings";
        self.emptyLabel.hidden = NO;
        return;
    }

    NSMutableDictionary *filters = [NSMutableDictionary dictionary];
    filters[@"limit"] = @30;
    filters[@"offset"] = @(self.currentWorldOffset);
    filters[@"projectType"] = @"world";

    if (self.worldSearchQuery.length > 0) {
        filters[@"query"] = self.worldSearchQuery;
    }
    if (self.currentGameVersion.length > 0) {
        filters[@"version"] = self.currentGameVersion;
    }

    __weak typeof(self) weakSelf = self;
    id api = [self currentAPIForTabType:@"world"];
    [api searchModWithFilters:filters completion:^(NSArray * _Nullable results, NSError * _Nullable error) {
        dispatch_async(dispatch_get_main_queue(), ^{
            __strong typeof(weakSelf) strongSelf = weakSelf;
            if (!strongSelf) return;
            [strongSelf.loadingIndicator stopAnimating];
            [strongSelf.worldTableView.refreshControl endRefreshing];
            strongSelf.isLoadingWorlds = NO;

            if (results) {
                if (strongSelf.currentWorldOffset == 0) {
                    [strongSelf.worldList removeAllObjects];
                }
                [strongSelf.worldList addObjectsFromArray:results];
                strongSelf.hasMoreWorlds = (results.count >= 30);
                strongSelf.currentWorldOffset += results.count;

                [strongSelf.worldTableView reloadData];
                strongSelf.emptyLabel.hidden = (strongSelf.worldList.count > 0);
                if (strongSelf.worldList.count == 0) {
                    strongSelf.emptyLabel.text = @"No worlds";
                    strongSelf.emptyLabel.hidden = NO;
                }
            } else if (error) {
                [strongSelf showError:error.localizedDescription];
            }
        });
    }];
}

- (void)searchWorlds:(NSString *)query {
    self.worldSearchQuery = query;
    self.currentWorldOffset = 0;
    self.hasMoreWorlds = YES;
    [self.worldList removeAllObjects];
    [self.worldTableView reloadData];
    [self loadWorldList];
}

#pragma mark - Filter Options

- (void)showFilterOptions {
    NSInteger tabIndex = self.tabSegment.selectedSegmentIndex;

    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Options"
                                                                   message:nil
                                                            preferredStyle:UIAlertControllerStyleActionSheet];

    if (tabIndex == 1 || tabIndex == 2 || tabIndex == 3 || tabIndex == 4) {
        [alert addAction:[UIAlertAction actionWithTitle:@"Select game version"
                                                  style:UIAlertActionStyleDefault
                                                handler:^(UIAlertAction * _Nonnull action) {
            [self showGameVersionPicker];
        }]];

        [alert addAction:[UIAlertAction actionWithTitle:@"Sort by"
                                                  style:UIAlertActionStyleDefault
                                                handler:^(UIAlertAction * _Nonnull action) {
            [self showSortOptions];
        }]];

        if (tabIndex == 1) {
            [alert addAction:[UIAlertAction actionWithTitle:@"Mod loader"
                                                      style:UIAlertActionStyleDefault
                                                    handler:^(UIAlertAction * _Nonnull action) {
                [self showModLoaderPicker];
            }]];
        }

        [alert addAction:[UIAlertAction actionWithTitle:@"Reset filters"
                                                  style:UIAlertActionStyleDestructive
                                                handler:^(UIAlertAction * _Nonnull action) {
            [self resetFilters];
        }]];
    } else if (tabIndex == 5) {
        [alert addAction:[UIAlertAction actionWithTitle:@"Import local modpack"
                                                  style:UIAlertActionStyleDefault
                                                handler:^(UIAlertAction * _Nonnull action) {
            [self openImportModpackView];
        }]];
        [alert addAction:[UIAlertAction actionWithTitle:@"Select game version"
                                                  style:UIAlertActionStyleDefault
                                                handler:^(UIAlertAction * _Nonnull action) {
            [self showGameVersionPicker];
        }]];
        [alert addAction:[UIAlertAction actionWithTitle:@"Reset filters"
                                                  style:UIAlertActionStyleDestructive
                                                handler:^(UIAlertAction * _Nonnull action) {
            self.currentGameVersion = nil;
            [self refreshModpackList];
        }]];
    } else if (tabIndex == 6) {
        // World tab: always CurseForge, offering the API key entry point and a version filter
        [alert addAction:[UIAlertAction actionWithTitle:@"Set CurseForge API key"
                                                  style:UIAlertActionStyleDefault
                                                handler:^(UIAlertAction * _Nonnull action) {
            [self openCurseForgeAPIKeySettings];
        }]];
        [alert addAction:[UIAlertAction actionWithTitle:@"Select game version"
                                                  style:UIAlertActionStyleDefault
                                                handler:^(UIAlertAction * _Nonnull action) {
            [self showGameVersionPicker];
        }]];
        [alert addAction:[UIAlertAction actionWithTitle:@"Reset filters"
                                                  style:UIAlertActionStyleDestructive
                                                handler:^(UIAlertAction * _Nonnull action) {
            self.currentGameVersion = nil;
            [self refreshWorldList];
        }]];
    }
    
    [alert addAction:[UIAlertAction actionWithTitle:@"Cancel"
                                              style:UIAlertActionStyleCancel
                                            handler:nil]];
    
    if (UIDevice.currentDevice.userInterfaceIdiom == UIUserInterfaceIdiomPad) {
        alert.popoverPresentationController.sourceView = self.filterButton;
        alert.popoverPresentationController.sourceRect = self.filterButton.bounds;
    }
    
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)showGameVersionPicker {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Select game version"
                                                                   message:nil
                                                            preferredStyle:UIAlertControllerStyleActionSheet];

    // Build the version list dynamically, preferring the release versions from the already-loaded Mojang version_manifest,
    // so it follows Minecraft updates automatically (no more hardcoded list).
    // The current profile's Minecraft version (if any) is pinned to the top for quick selection.
    NSMutableArray<NSString *> *versions = [NSMutableArray arrayWithObject:@"All versions"];

    // The current profile's Minecraft version (if any) goes second, for quick selection
    NSString *profileMcVersion = [self currentProfileMinecraftVersion];
    if (profileMcVersion.length > 0 && ![versions containsObject:profileMcVersion]) {
        [versions addObject:profileMcVersion];
    }

    // Extract the release versions from the Mojang version_manifest
    if (self.versionList && [self.versionList isKindOfClass:[NSArray class]]) {
        for (NSDictionary *version in self.versionList) {
            NSString *type = version[@"type"];
            if (![type isEqualToString:@"release"]) continue;
            NSString *versionId = version[@"id"];
            if (![versionId isKindOfClass:[NSString class]] || versionId.length == 0) continue;
            // Skip very old versions (mods rarely support anything before 1.8)
            if ([versionId hasPrefix:@"1."] == NO) continue;
            // Skip versions already in the list (so profileMcVersion is not duplicated)
            if ([versions containsObject:versionId]) continue;
            [versions addObject:versionId];
        }
    }

    // If versionList has not loaded yet or is empty, use a basic fallback (so the picker can at least appear)
    if (versions.count <= 1) {
        [versions addObjectsFromArray:@[@"1.21", @"1.20.1", @"1.19.2", @"1.18.2", @"1.16.5"]];
    }

    // Cap the list length so the alert does not get too long (the 30 most recent versions + All + the profile version)
    if (versions.count > 32) {
        NSArray *tail = [versions subarrayWithRange:NSMakeRange(0, 32)];
        versions = [NSMutableArray arrayWithArray:tail];
    }

    for (NSString *version in versions) {
        [alert addAction:[UIAlertAction actionWithTitle:version
                                                  style:UIAlertActionStyleDefault
                                                handler:^(UIAlertAction * _Nonnull action) {
            if ([version isEqualToString:@"All versions"]) {
                self.currentGameVersion = nil;
            } else {
                self.currentGameVersion = version;
            }
            // Mark it once the user chooses manually, so it is no longer overwritten automatically
            self.hasUserTouchedFilters = YES;
            [self updateSidebarFilterValues];
            [self reloadCurrentList];
        }]];
    }

    [alert addAction:[UIAlertAction actionWithTitle:@"Cancel"
                                              style:UIAlertActionStyleCancel
                                            handler:nil]];

    // For the iPad popover sourceView, prefer the sidebar button (filterButton is hidden on non-version tabs)
    UIView *sourceView = self.sidebarVersionButton.hidden ? self.filterButton : self.sidebarVersionButton;
    if (UIDevice.currentDevice.userInterfaceIdiom == UIUserInterfaceIdiomPad) {
        alert.popoverPresentationController.sourceView = sourceView;
        alert.popoverPresentationController.sourceRect = sourceView.bounds;
    }

    [self presentViewController:alert animated:YES completion:nil];
}

/// Resolve the Minecraft version of the current profile (used to preselect the mod download version)
/// Reuses ModpackExportService.parseVersionId: to decode it from lastVersionId
- (NSString *)currentProfileMinecraftVersion {
    NSDictionary *profile = PLProfiles.current.selectedProfile;
    NSString *lastVersionId = profile[@"lastVersionId"];
    if (lastVersionId.length == 0) return nil;
    NSDictionary *parsed = [ModpackExportService parseVersionId:lastVersionId];
    NSString *mcVersion = parsed[@"minecraft"];
    return mcVersion;
}

/// Resolve the mod loader of the current profile (fabric/forge/neoforge/quilt)
/// Reuses ModpackExportService.parseVersionId: to decode it from lastVersionId
- (NSString *)currentProfileLoader {
    NSDictionary *profile = PLProfiles.current.selectedProfile;
    NSString *lastVersionId = profile[@"lastVersionId"];
    if (lastVersionId.length == 0) return nil;
    NSDictionary *parsed = [ModpackExportService parseVersionId:lastVersionId];
    NSString *loader = parsed[@"loader"];
    return loader;
}

/// FCL style: apply the current profile's version and loader filters the first time the mod/shader/resource pack tabs are opened
/// so search results match the current game setup (e.g. neoforge + 1.21.1)
/// Once the user changes the filters by hand they are no longer overwritten (tracked by hasUserTouchedFilters)
- (void)autoApplyProfileFiltersIfNeeded {
    if (self.hasUserTouchedFilters) return;

    NSString *profileMcVersion = [self currentProfileMinecraftVersion];
    NSString *profileLoader = [self currentProfileLoader];

    BOOL changed = NO;
    // Only apply automatically when no version is set yet (a user choice is preserved)
    if (profileMcVersion.length > 0 && ![self.currentGameVersion isEqualToString:profileMcVersion]) {
        self.currentGameVersion = profileMcVersion;
        changed = YES;
    }
    // The loader is only applied automatically on the mod tab (other tabs such as shaders/resource packs may have no loader concept)
    // However Modrinth facets apply categories to every project_type, so it is applied uniformly
    if (profileLoader.length > 0 && ![self.currentModLoader isEqualToString:profileLoader]) {
        self.currentModLoader = profileLoader;
        changed = YES;
    }

    if (changed) {
        [self updateSidebarFilterValues];
    }
}

- (void)showSortOptions {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Sort by"
                                                                   message:nil
                                                            preferredStyle:UIAlertControllerStyleActionSheet];

    NSDictionary *sortOptions = @{
        @"Follows": @"follows",
        @"Downloads": @"downloads",
        @"Recently updated": @"updated",
        @"Newest": @"newest",
        @"Relevance": @"relevance"
    };

    for (NSString *title in sortOptions) {
        [alert addAction:[UIAlertAction actionWithTitle:title
                                                  style:UIAlertActionStyleDefault
                                                handler:^(UIAlertAction * _Nonnull action) {
            self.currentSortField = sortOptions[title];
            [self updateSidebarFilterValues];
            [self reloadCurrentList];
        }]];
    }

    [alert addAction:[UIAlertAction actionWithTitle:@"Cancel"
                                              style:UIAlertActionStyleCancel
                                            handler:nil]];

    UIView *sourceView = self.sidebarSortButton.hidden ? self.filterButton : self.sidebarSortButton;
    if (UIDevice.currentDevice.userInterfaceIdiom == UIUserInterfaceIdiomPad) {
        alert.popoverPresentationController.sourceView = sourceView;
        alert.popoverPresentationController.sourceRect = sourceView.bounds;
    }

    [self presentViewController:alert animated:YES completion:nil];
}

- (void)showModLoaderPicker {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Mod loader"
                                                                   message:nil
                                                            preferredStyle:UIAlertControllerStyleActionSheet];

    NSArray *loaderNames = @[@"All", @"Fabric", @"Forge", @"Quilt", @"NeoForge"];
    NSArray *loaderValues = @[[NSNull null], @"fabric", @"forge", @"quilt", @"neoforge"];

    for (NSInteger i = 0; i < loaderNames.count; i++) {
        NSString *name = loaderNames[i];
        id value = loaderValues[i];

        [alert addAction:[UIAlertAction actionWithTitle:name
                                                  style:UIAlertActionStyleDefault
                                                handler:^(UIAlertAction * _Nonnull action) {
            self.currentModLoader = (value == [NSNull null]) ? nil : value;
            // Mark it once the user chooses manually, so it is no longer overwritten automatically
            self.hasUserTouchedFilters = YES;
            [self updateSidebarFilterValues];
            [self reloadCurrentList];
        }]];
    }

    [alert addAction:[UIAlertAction actionWithTitle:@"Cancel"
                                              style:UIAlertActionStyleCancel
                                            handler:nil]];

    UIView *sourceView = self.sidebarLoaderButton.hidden ? self.filterButton : self.sidebarLoaderButton;
    if (UIDevice.currentDevice.userInterfaceIdiom == UIUserInterfaceIdiomPad) {
        alert.popoverPresentationController.sourceView = sourceView;
        alert.popoverPresentationController.sourceRect = sourceView.bounds;
    }

    [self presentViewController:alert animated:YES completion:nil];
}

- (void)resetFilters {
    self.currentGameVersion = nil;
    self.currentModLoader = nil;
    self.currentSortField = @"follows";
    self.currentSearchQuery = nil;
    self.resourcepackSearchQuery = nil;
    self.datapackSearchQuery = nil;
    self.searchBar.text = nil;
    [self updateSidebarFilterValues];
    [self reloadCurrentList];
}

- (void)reloadCurrentList {
    NSInteger tabIndex = self.tabSegment.selectedSegmentIndex;
    // Fade the current list out, load, then fade back in when switching API source, avoiding an abrupt blank
    UITableView *targetTable = nil;
    if (tabIndex == 1) {
        targetTable = self.modTableView;
        self.currentModOffset = 0;
        [self.modList removeAllObjects];
    } else if (tabIndex == 2) {
        targetTable = self.shaderTableView;
        self.currentShaderOffset = 0;
        [self.shaderList removeAllObjects];
    } else if (tabIndex == 3) {
        targetTable = self.resourcepackTableView;
        self.currentResourcepackOffset = 0;
        [self.resourcepackList removeAllObjects];
    } else if (tabIndex == 4) {
        targetTable = self.datapackTableView;
        self.currentDatapackOffset = 0;
        [self.datapackList removeAllObjects];
    } else if (tabIndex == 5) {
        targetTable = self.modpackTableView;
        self.currentModpackOffset = 0;
        [self.modpackList removeAllObjects];
    } else if (tabIndex == 6) {
        targetTable = self.worldTableView;
        self.currentWorldOffset = 0;
        [self.worldList removeAllObjects];
    }

    [UIView animateWithDuration:0.15 animations:^{
        targetTable.alpha = 0;
    } completion:^(BOOL finished) {
        switch (tabIndex) {
            case 1: [self loadModList]; break;
            case 2: [self loadShaderList]; break;
            case 3: [self loadResourcePackList]; break;
            case 4: [self loadDataPackList]; break;
            case 5: [self loadModpackList]; break;
            case 6: [self loadWorldList]; break;
        }
        [UIView animateWithDuration:0.2 animations:^{
            targetTable.alpha = 1;
        }];
    }];
}

- (void)showError:(NSString *)message {
    // Show the error in the content area instead of an alert
    [InlineMessageView showInViewController:self
                                       title:@"Error"
                                    message:message
                                       type:InlineMessageTypeError];
}

#pragma mark - UISearchBarDelegate

- (void)searchBarSearchButtonClicked:(UISearchBar *)searchBar {
    [searchBar resignFirstResponder];

    NSInteger tabIndex = self.tabSegment.selectedSegmentIndex;
    if (tabIndex == 0) {
        // Version tab: search filtering already runs live in textDidChange, so this only dismisses the keyboard
        // applyVersionFilter is not called again
    } else if (tabIndex == 1) {
        [self searchMods:searchBar.text];
    } else if (tabIndex == 2) {
        [self searchShaders:searchBar.text];
    } else if (tabIndex == 3) {
        [self searchResourcepacks:searchBar.text];
    } else if (tabIndex == 4) {
        [self searchDatapacks:searchBar.text];
    } else if (tabIndex == 5) {
        [self searchModpacks:searchBar.text];
    } else if (tabIndex == 6) {
        [self searchWorlds:searchBar.text];
    }
}

- (void)searchBarCancelButtonClicked:(UISearchBar *)searchBar {
    searchBar.text = nil;
    self.currentSearchQuery = nil;
    self.modpackSearchQuery = nil;
    self.resourcepackSearchQuery = nil;
    self.datapackSearchQuery = nil;
    self.worldSearchQuery = nil;
    self.versionSearchQuery = nil;
    [searchBar resignFirstResponder];
    [self reloadCurrentList];
}

- (void)searchBar:(UISearchBar *)searchBar textDidChange:(NSString *)searchText {
    NSInteger tabIndex = self.tabSegment.selectedSegmentIndex;
    if (tabIndex == 0) {
        // Version tab: filter live by version number prefix (no need to tap the search button)
        self.versionSearchQuery = searchText;
        [self applyVersionFilter];
    }
}

#pragma mark - UICollectionView DataSource

- (NSInteger)collectionView:(UICollectionView *)collectionView numberOfItemsInSection:(NSInteger)section {
    return self.filteredVersions.count;
}

- (UICollectionViewCell *)collectionView:(UICollectionView *)collectionView cellForItemAtIndexPath:(NSIndexPath *)indexPath {
    VersionCardCell *cell = [collectionView dequeueReusableCellWithReuseIdentifier:@"VersionCard" forIndexPath:indexPath];

    NSDictionary *version = self.filteredVersions[indexPath.row];
    NSString *versionId = version[@"id"];
    NSString *releaseTime = version[@"releaseTime"];
    NSString *versionType = version[@"type"];

    NSString *formattedDate = [self formatDate:releaseTime];
    [cell configureWithVersionId:versionId date:formattedDate type:versionType];

    // FCL style: mark the installed versions (walking PLProfiles and matching lastVersionId)
    [cell setInstalled:[self isVersionInstalled:versionId]];

    return cell;
}

/// Check whether the given versionId is installed locally (a match on any profile's lastVersionId counts as installed)
- (BOOL)isVersionInstalled:(NSString *)versionId {
    if (!versionId.length) return NO;
    NSDictionary *profiles = PLProfiles.current.profiles;
    for (NSString *name in profiles.allKeys) {
        NSDictionary *profile = profiles[name];
        NSString *lastVersionId = profile[@"lastVersionId"];
        if ([lastVersionId isKindOfClass:[NSString class]] && [lastVersionId isEqualToString:versionId]) {
            return YES;
        }
    }
    return NO;
}

- (NSString *)formatDate:(NSString *)dateString {
    if (dateString.length >= 10) {
        return [dateString substringToIndex:10];
    }
    return dateString;
}

- (void)collectionView:(UICollectionView *)collectionView didSelectItemAtIndexPath:(NSIndexPath *)indexPath {
    NSDictionary *version = self.filteredVersions[indexPath.row];
    [self showLoaderSelectionForVersion:version];
}

#pragma mark - Loader Selection (pushed into the middle content area)

- (void)showLoaderSelectionForVersion:(NSDictionary *)version {
    ModLoaderInstallViewController *loaderVC = [[ModLoaderInstallViewController alloc] init];
    loaderVC.gameVersion = version[@"id"];

    __weak typeof(self) weakSelf = self;
    loaderVC.completion = ^(NSString *loaderType, BOOL installFabricAPI, BOOL installOptiFine, NSString *loaderVersion) {
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf) return;

        // Fix for "the previous page does not disappear in time":
        // this previously used popViewControllerAnimated:YES + dispatch_async(main_queue) to run proceedWithVersion: immediately,
        // but proceedWithVersion: could push a new VC (such as InstallerProgressViewController) before the pop animation (~0.35s) finished,
        // so the navigation controller received a push mid-pop, its state conflicted, and the previous page (the mod installer) stayed stuck on screen.
        // Fix: wrap the pop in a CATransaction and run proceedWithVersion: in the completion block of the pop animation,
        //      keeping the navigation stack consistent.
        [CATransaction begin];
        [CATransaction setCompletionBlock:^{
            __strong typeof(weakSelf) ss = weakSelf;
            if (!ss) return;
            [ss proceedWithVersion:version
                        loaderType:loaderType
                  installFabricAPI:installFabricAPI
                   installOptiFine:installOptiFine
                      loaderVersion:loaderVersion];
        }];
        [strongSelf.navigationController popViewControllerAnimated:YES];
        [CATransaction commit];
    };

    loaderVC.cancelled = ^{
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (strongSelf) {
            [strongSelf.navigationController popViewControllerAnimated:YES];
        }
    };

    // Already inside the DownloadVC navigation stack, so push directly rather than presenting a FormSheet
    [self.navigationController pushViewController:loaderVC animated:YES];
}

#pragma mark - Installation

- (void)proceedWithVersion:(NSDictionary *)version loaderType:(NSString *)loaderType installFabricAPI:(BOOL)installFabricAPI installOptiFine:(BOOL)installOptiFine loaderVersion:(NSString *)loaderVersion {
    NSString *versionId = version[@"id"];

    if ([loaderType isEqualToString:@"vanilla"]) {
        // Vanilla also goes through ensureVanillaInstalled, so version.json is downloaded correctly with the BMCLAPI substitution
        // Fix: this previously called downloadVanillaVersion: directly without ensureVanillaInstalled:,
        //   so in BMCLAPI mode version.json went straight to piston-meta.mojang.com and timed out in mainland China,
        //   leaving the spinner up with no download. ensureVanillaInstalled: calls ensureVanillaVersionJSONExists: internally,
        //   which correctly rewrites piston-meta.mojang.com to bmclapi2.bangbang93.com.
        // Note: ensureVanillaInstalled: returns immediately when the JSON already exists, so nothing is downloaded twice;
        //   downloadVanillaVersion: also skips already-downloaded files via the SHA1 check in createDownloadTask:.
        //
        // Fix for "nothing happens when the install button is tapped":
        // when the version JSON does not exist (a first install), ensureVanillaInstalled: -> ensureVanillaVersionJSONExists:
        // downloads the version manifest and version JSON on a background thread, which can take several seconds up to 30.
        // Meanwhile ModLoaderInstallViewController has already been popped, so the user stares at a blank page and thinks "nothing happened".
        // Fix: show the progress card before calling ensureVanillaInstalled: so the user gets immediate feedback.
        //      When the JSON already exists ensureVanillaInstalled: returns synchronously, and progressCardView is handled
        //      correctly by the old-card cleanup inside startVersionDownload:.
        if (self.progressCardView) {
            [self.progressCardView dismiss];
            self.progressCardView = nil;
        }
        // Following ZL2: the vanilla branch also says "preparing the runtime environment", matching the loader prerequisite preinstall
        NSString *vanillaTitle = [NSString stringWithFormat:@"Preparing the runtime environment %@", versionId];
        self.progressCardView = [DownloadProgressCardView showInParentView:self.view title:vanillaTitle];
        [self.progressCardView startDownloadWithTitle:vanillaTitle
                                              subtitle:@"Vanilla Minecraft"];
        [self.progressCardView updateProgress:-1 downloaded:0 total:-1 speed:0 eta:-1 currentFile:@"Fetching version information..."];

        __weak typeof(self) weakSelf = self;
        [self ensureVanillaInstalled:version completion:^(BOOL success) {
            __strong typeof(weakSelf) strongSelf = weakSelf;
            if (!strongSelf) return;
            if (success) {
                // Once ensureVanillaInstalled: finishes, startVersionDownload: clears the old card and creates a new one
                [strongSelf downloadVanillaVersion:version];
            } else {
                // Clear the progress card and show the error on failure
                if (strongSelf.progressCardView) {
                    NSError *err = [NSError errorWithDomain:@"DownloadError" code:-1
                                                     userInfo:@{NSLocalizedDescriptionKey: [NSString stringWithFormat:@"Could not install vanilla %@. Check your network connection and try again", versionId]}];
                    [strongSelf.progressCardView failWithError:err];
                    strongSelf.progressCardView = nil;
                }
                [strongSelf showError:[NSString stringWithFormat:@"Could not install vanilla %@. Check your network connection and try again", versionId]];
            }
        }];
        return;
    }

    // Following FCL: fully install the matching vanilla version (client.jar + libraries + assets) before installing a mod loader.
    // The version JSON of Fabric/Quilt/OptiFine contains an "inheritsFrom" field, and at launch the Java side
    // Tools.getVersionInfo() reads versions/{inheritsFrom}/{inheritsFrom}.json and merges it.
    // Without the vanilla version installed, launching crashes with FileNotFoundException; downloading the JSON alone is not enough,
    // client.jar/assets/libraries are needed too, otherwise the first launch still has to fetch them and the experience is disjointed.
    // The Forge/NeoForge direct installers already have ensureParentVersionExists (JSON only); this fills in the complete vanilla install.
    //
    // Improvement 2 (following the unified progress flow of ZL2): setting vanillaPreinstallForLoader=YES means the progress page is not
    // popped when the vanilla preinstall finishes but handed to the later install* methods, so "vanilla + loader" run on one progress page.
    self.vanillaPreinstallForLoader = YES;
    __weak typeof(self) weakSelf = self;
    [self ensureVanillaInstalled:version completion:^(BOOL success) {
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf) return;
        if (!success) {
            [strongSelf showError:[NSString stringWithFormat:@"Could not install vanilla %@. Check your network connection and try again", versionId]];
            return;
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            if ([loaderType isEqualToString:@"fabric"]) {
                [strongSelf installFabric:versionId loaderVersion:loaderVersion installAPI:installFabricAPI];
            } else if ([loaderType isEqualToString:@"forge"]) {
                [strongSelf installForge:versionId installOptiFine:installOptiFine loaderVersion:loaderVersion];
            } else if ([loaderType isEqualToString:@"neoforge"]) {
                [strongSelf installNeoForge:versionId loaderVersion:loaderVersion];
            } else if ([loaderType isEqualToString:@"quilt"]) {
                [strongSelf installQuilt:versionId loaderVersion:loaderVersion];
            } else if ([loaderType isEqualToString:@"optifine"]) {
                [strongSelf installOptiFineAsPatch:versionId loaderVersion:loaderVersion];
            } else {
                [strongSelf showError:[NSString stringWithFormat:@"The %@ installer is not implemented yet", loaderType]];
            }
        });
    }];
}

/// Following FCL: make sure the version JSON of the vanilla version exists.
/// If versions/{versionId}/{versionId}.json is missing, download it from the Mojang/BMCLAPI version manifest.
/// Only the version JSON is downloaded (client.jar/assets/libraries are fetched by the Java side on first launch).
/// The Forge/NeoForge direct installers have the same logic internally (ensureParentVersionExists), but Fabric/Quilt/OptiFine do not,
/// so proceedWithVersion calls this for all of them up front.
- (void)ensureVanillaVersionJSONExists:(NSString *)versionId completion:(void (^)(BOOL success))completion {
    // Fix: POJAV_GAME_DIR must be used (matching ensureVanillaInstalled: and MinecraftResourceDownloadTask),
    // not POJAV_HOME. POJAV_GAME_DIR is the directory Minecraft actually reads versions/ from.
    // With POJAV_HOME the version JSON lands in the wrong place, so MinecraftResourceDownloadTask
    // cannot find the JSON and crashes, and at launch the Java side Tools.getVersionInfo() also throws FileNotFoundException.
    NSString *gameDir = @(getenv("POJAV_GAME_DIR"));
    if (gameDir.length == 0) {
        gameDir = @(getenv("POJAV_HOME"));
    }
    NSString *versionDir = [gameDir stringByAppendingPathComponent:
                            [NSString stringWithFormat:@"versions/%@", versionId]];
    NSString *versionJsonPath = [versionDir stringByAppendingPathComponent:
                                 [NSString stringWithFormat:@"%@.json", versionId]];

    // 1. The version JSON already exists, so there is nothing to download
    if ([NSFileManager.defaultManager fileExistsAtPath:versionJsonPath]) {
        if (completion) completion(YES);
        return;
    }

    NSLog(@"[DownloadVC] Vanilla version JSON missing, downloading: %@", versionId);

    // 2. Fetch the Mojang version manifest and download the version JSON on a background thread
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        NSString *downloadSource = getPrefObject(@"general.download_source") ?: @"official";
        BOOL useBMCLAPI = [downloadSource isEqualToString:@"bmclapi"];
        NSString *manifestURL = useBMCLAPI
            ? @"https://bmclapi2.bangbang93.com/mc/game/version_manifest_v2.json"
            : @"https://piston-meta.mojang.com/mc/game/version_manifest_v2.json";

        NSURL *url = [NSURL URLWithString:manifestURL];
        if (!url) {
            if (completion) dispatch_async(dispatch_get_main_queue(), ^{ completion(NO); });
            return;
        }

        NSMutableURLRequest *manifestRequest = [NSMutableURLRequest requestWithURL:url];
        manifestRequest.timeoutInterval = 30.0;
        manifestRequest.cachePolicy = NSURLRequestReloadIgnoringLocalCacheData;
        [manifestRequest setValue:@"Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15" forHTTPHeaderField:@"User-Agent"];

        // Use NSURLSession instead of the deprecated NSURLConnection sendSynchronousRequest
        dispatch_semaphore_t manifestSem = dispatch_semaphore_create(0);
        __block NSData *manifestData = nil;
        NSURLSessionDataTask *manifestTask = [[NSURLSession sharedSession] dataTaskWithRequest:manifestRequest
                                                                              completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
            manifestData = data;
            dispatch_semaphore_signal(manifestSem);
        }];
        [manifestTask resume];
        dispatch_semaphore_wait(manifestSem, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(30 * NSEC_PER_SEC)));

        if (!manifestData) {
            NSLog(@"[DownloadVC] Failed to download version manifest");
            if (completion) dispatch_async(dispatch_get_main_queue(), ^{ completion(NO); });
            return;
        }

        NSDictionary *manifest = [NSJSONSerialization JSONObjectWithData:manifestData options:0 error:nil];
        NSArray *versions = [manifest isKindOfClass:[NSDictionary class]] ? manifest[@"versions"] : nil;
        if (![versions isKindOfClass:[NSArray class]]) {
            NSLog(@"[DownloadVC] Invalid version manifest format");
            if (completion) dispatch_async(dispatch_get_main_queue(), ^{ completion(NO); });
            return;
        }

        // 3. Find the matching version entry and get the version JSON URL
        NSString *versionJSONURL = nil;
        for (NSDictionary *v in versions) {
            if ([v isKindOfClass:[NSDictionary class]] && [v[@"id"] isEqualToString:versionId]) {
                versionJSONURL = [v[@"url"] isKindOfClass:[NSString class]] ? v[@"url"] : nil;
                break;
            }
        }
        if (!versionJSONURL) {
            NSLog(@"[DownloadVC] Version %@ not found in manifest", versionId);
            if (completion) dispatch_async(dispatch_get_main_queue(), ^{ completion(NO); });
            return;
        }

        // BMCLAPI mirror: rewrite the official Mojang domain
        if (useBMCLAPI) {
            versionJSONURL = [versionJSONURL stringByReplacingOccurrencesOfString:@"piston-meta.mojang.com"
                                                                        withString:@"bmclapi2.bangbang93.com"];
            versionJSONURL = [versionJSONURL stringByReplacingOccurrencesOfString:@"launchermeta.mojang.com"
                                                                        withString:@"bmclapi2.bangbang93.com"];
        }

        // 4. Download the version JSON (using NSURLSession instead of the deprecated NSURLConnection)
        NSURL *jsonURL = [NSURL URLWithString:versionJSONURL];
        if (!jsonURL) {
            if (completion) dispatch_async(dispatch_get_main_queue(), ^{ completion(NO); });
            return;
        }

        NSMutableURLRequest *jsonRequest = [NSMutableURLRequest requestWithURL:jsonURL];
        jsonRequest.timeoutInterval = 30.0;
        jsonRequest.cachePolicy = NSURLRequestReloadIgnoringLocalCacheData;
        [jsonRequest setValue:@"Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15" forHTTPHeaderField:@"User-Agent"];

        // Use NSURLSession dataTaskWithCompletionHandler instead of the deprecated NSURLConnection sendSynchronousRequest
        // Already dispatched to a background queue above, so a semaphore is used to wait for the result here
        dispatch_semaphore_t sem = dispatch_semaphore_create(0);
        __block NSData *jsonData = nil;
        NSURLSessionDataTask *jsonTask = [[NSURLSession sharedSession] dataTaskWithRequest:jsonRequest
                                                                          completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
            jsonData = data;
            dispatch_semaphore_signal(sem);
        }];
        [jsonTask resume];
        // Wait at most 30 seconds (matching timeoutInterval)
        dispatch_semaphore_wait(sem, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(30 * NSEC_PER_SEC)));

        if (!jsonData) {
            NSLog(@"[DownloadVC] Failed to download version JSON for %@", versionId);
            if (completion) dispatch_async(dispatch_get_main_queue(), ^{ completion(NO); });
            return;
        }

        // 5. Create the version directory and write the JSON
        NSError *dirError = nil;
        [NSFileManager.defaultManager createDirectoryAtPath:versionDir
                                withIntermediateDirectories:YES
                                                 attributes:nil
                                                      error:&dirError];
        if (dirError) {
            NSLog(@"[DownloadVC] Failed to create version dir: %@", dirError.localizedDescription);
            if (completion) dispatch_async(dispatch_get_main_queue(), ^{ completion(NO); });
            return;
        }

        NSError *writeErr = nil;
        if (![jsonData writeToFile:versionJsonPath options:NSDataWritingAtomic error:&writeErr]) {
            NSLog(@"[DownloadVC] Failed to write version JSON: %@", writeErr.localizedDescription);
            if (completion) dispatch_async(dispatch_get_main_queue(), ^{ completion(NO); });
            return;
        }

        NSLog(@"[DownloadVC] Vanilla version JSON saved: %@ (%lu bytes)", versionJsonPath, (unsigned long)jsonData.length);
        if (completion) dispatch_async(dispatch_get_main_queue(), ^{ completion(YES); });
    });
}

/// Following FCL: fully install the matching vanilla version (version JSON + libraries + assets) before installing a mod loader.
/// If vanilla is already installed (versions/{id}/{id}.json exists under POJAV_GAME_DIR), call completion(YES) straight away.
/// Otherwise: 1) make sure the version JSON exists; 2) download the full vanilla files (libraries + assets) with MinecraftResourceDownloadTask;
/// 3) show FCL-style progress through InstallerProgressViewController.
/// Note: client.jar is downloaded on demand by the Java side at launch and is not checked here; MinecraftResourceDownloadTask
/// skips files that already exist with the right SHA1, so calling this repeatedly is safe.
- (void)ensureVanillaInstalled:(NSDictionary *)version completion:(void (^)(BOOL success))completion {
    if (![version isKindOfClass:[NSDictionary class]]) {
        if (completion) completion(NO);
        return;
    }
    NSString *versionId = version[@"id"];
    if (![versionId isKindOfClass:[NSString class]] || versionId.length == 0) {
        if (completion) completion(NO);
        return;
    }

    // Use POJAV_GAME_DIR (matching MinecraftResourceDownloadTask), not POJAV_HOME
    NSString *gameDir = @(getenv("POJAV_GAME_DIR"));
    if (gameDir.length == 0) {
        // In the edge case where the environment variable is missing, fall back to POJAV_HOME
        gameDir = @(getenv("POJAV_HOME"));
    }
    NSString *versionJsonPath = [gameDir stringByAppendingPathComponent:
                                 [NSString stringWithFormat:@"versions/%@/%@.json", versionId, versionId]];

    // 1. The vanilla JSON already exists (so vanilla was downloaded before). Improvement 3 (finer-grained skipping):
    //    the JSON existing does not mean the install is complete — an interrupted download may leave the JSON without client.jar or libraries.
    //    Following ZL2: check whether client.jar exists; if it is missing, continue the preinstall to fill in the gaps, and only truly skip when it is there.
    //    MinecraftResourceDownloadTask skips files that already exist with the right SHA1, so calling it again is safe.
    if ([NSFileManager.defaultManager fileExistsAtPath:versionJsonPath]) {
        NSString *versionDir = [gameDir stringByAppendingPathComponent:
                               [NSString stringWithFormat:@"versions/%@", versionId]];
        NSString *clientJarPath = [versionDir stringByAppendingPathComponent:
                                   [NSString stringWithFormat:@"%@.jar", versionId]];
        if ([NSFileManager.defaultManager fileExistsAtPath:clientJarPath]) {
            NSLog(@"[DownloadVC] Vanilla %@ already installed (JSON + jar exist), skip preinstall", versionId);
            self.vanillaPreinstallForLoader = NO; // The KVO handover branch will not be reached, so reset the flag
            if (completion) completion(YES);
            return;
        }
        NSLog(@"[DownloadVC] Vanilla %@ JSON exists but client.jar missing, resuming preinstall", versionId);
        // Carry on: create a download task to fill in the missing files (existing ones are skipped)
    }

    NSLog(@"[DownloadVC] Vanilla %@ not installed, preinstalling...", versionId);

    // Save the completion so it can be called when KVO reports completion
    __weak typeof(self) weakSelf = self;
    self.vanillaPreinstallCompletion = completion;

    // 2. Make sure the version JSON exists first (reusing the existing logic)
    [self ensureVanillaVersionJSONExists:versionId completion:^(BOOL jsonSuccess) {
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf) {
            if (completion) completion(NO);
            return;
        }
        if (!jsonSuccess) {
            strongSelf.vanillaPreinstallForLoader = NO; // Reset the handover flag
            strongSelf.vanillaPreinstallCompletion = nil;
            if (completion) completion(NO);
            return;
        }

        // 3. Create and push the FCL-style progress VC
        dispatch_async(dispatch_get_main_queue(), ^{
            __strong typeof(weakSelf) s = weakSelf;
            if (!s) {
                if (completion) completion(NO);
                return;
            }
            InstallerProgressViewController *progressVC = [[InstallerProgressViewController alloc] init];
            // Following ZL2: the vanilla preinstall is a prerequisite of the loader install, so the wording says "preparing the runtime environment" rather than "installing vanilla"
            progressVC.titleText = [NSString stringWithFormat:@"Preparing the runtime environment %@", versionId];
            progressVC.stageMessage = @"Downloading required files...";
            progressVC.progress = -1; // Indeterminate at first, switching to determinate once the total byte count is known
            // Phase 12 enhancement: category icon + stage list (modelled on the FCL vanilla install steps)
            progressVC.categoryIconName = @"cube.box.fill";
            progressVC.categoryIconColor = [UIColor systemGreenColor];
            progressVC.stageSteps = @[
                @{@"title": @"Fetch version manifest", @"status": @2},
                @{@"title": @"Download version JSON", @"status": @2},
                @{@"title": @"Download game libraries", @"status": @1},
                @{@"title": @"Download asset files", @"status": @0},
                @{@"title": @"Verify file integrity", @"status": @0},
            ];
            progressVC.cancelHandler = ^{
                __strong typeof(weakSelf) ss = weakSelf;
                if (!ss) return;
                if (ss.vanillaPreinstallTask) {
                    if (ss.isObservingVanillaPreinstall) {
                        @try {
                            [ss.vanillaPreinstallTask.progress removeObserver:ss forKeyPath:@"fractionCompleted"];
                        } @catch (NSException *exception) {
                            NSLog(@"[DownloadVC] vanillaPreinstall cancel: removeObserver failed: %@", exception.reason);
                        }
                        ss.isObservingVanillaPreinstall = NO;
                    }
                    [ss.vanillaPreinstallTask.progress cancel];
                    ss.vanillaPreinstallTask = nil;
                }
                ss.vanillaPreinstallForLoader = NO; // Reset the handover flag
                ss.vanillaPreinstallProgressVC = nil;
                ss.vanillaPreinstallCompletion = nil;
            };
            s.vanillaPreinstallProgressVC = progressVC;
            [s.navigationController pushViewController:progressVC animated:YES];

            // 4. Create the download task
            MinecraftResourceDownloadTask *task = [MinecraftResourceDownloadTask new];
            task.maxRetryCount = 3;
            s.vanillaPreinstallTask = task;

            task.handleError = ^{
                dispatch_async(dispatch_get_main_queue(), ^{
                    __strong typeof(weakSelf) ss = weakSelf;
                    if (!ss) return;
                    if (ss.isObservingVanillaPreinstall) {
                        @try {
                            [ss.vanillaPreinstallTask.progress removeObserver:ss forKeyPath:@"fractionCompleted"];
                        } @catch (NSException *exception) {
                            NSLog(@"[DownloadVC] vanillaPreinstall handleError: removeObserver failed: %@", exception.reason);
                        }
                        ss.isObservingVanillaPreinstall = NO;
                    }
                    if (ss.vanillaPreinstallProgressVC && [ss.navigationController.viewControllers containsObject:ss.vanillaPreinstallProgressVC]) {
                        [ss.navigationController popViewControllerAnimated:YES];
                    }
                    ss.vanillaPreinstallTask = nil;
                    ss.vanillaPreinstallForLoader = NO; // Reset the handover flag
                    ss.vanillaPreinstallProgressVC = nil;
                    void (^cb)(BOOL) = ss.vanillaPreinstallCompletion;
                    ss.vanillaPreinstallCompletion = nil;
                    if (cb) cb(NO);
                });
            };

            // 5. Observe the progress via KVO (with its own context, to distinguish it from the main download flow)
            [task.progress addObserver:s
                            forKeyPath:@"fractionCompleted"
                               options:NSKeyValueObservingOptionInitial
                               context:(void *)@"VanillaPreinstallContext"];
            s.isObservingVanillaPreinstall = YES;

            // 6. Start the download on a background thread
            dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
                __strong typeof(weakSelf) ss = weakSelf;
                if (!ss) return;
                [ss.vanillaPreinstallTask downloadVersion:version];
            });
        });
    }];
}

#pragma mark - Vanilla Installation

- (void)downloadVanillaVersion:(NSDictionary *)version {
    if (![self isNetworkAvailable]) {
        [self showError:@"Network unavailable. Please check your network connection"];
        return;
    }

    NSString *versionId = version[@"id"];

    NSMutableDictionary *profile = [NSMutableDictionary dictionary];
    profile[@"name"] = versionId;
    profile[@"lastVersionId"] = versionId;
    // Back to the original "switch game directory" model: every version shares the root directory (gameDir=".")
    // The user switches between game directories manually with the "Switch game directory" feature in settings
    profile[@"gameDir"] = @".";
    profile[@"type"] = @"custom";
    profile[@"created"] = [NSDate date].description;

    [PLProfiles.current saveProfile:profile withName:versionId];
    PLProfiles.current.selectedProfileName = versionId;

    [self startVersionDownload:version];
}

- (void)startVersionDownload:(NSDictionary *)version {
    __weak DownloadViewController *weakSelf = self;

    // Following FCL/ZL2/HMCL: use a download progress card instead of a spinner and plain text progress
    // Clear the old progress card (if there is one)
    if (self.progressCardView) {
        [self.progressCardView dismiss];
        self.progressCardView = nil;
    }
    if (self.downloadingAlert) {
        [self.downloadingAlert dismiss];
        self.downloadingAlert = nil;
    }

    NSString *versionId = version[@"id"] ?: @"Version";
    NSString *versionType = version[@"type"] ?: @"";
    NSString *subtitle = [versionType isEqualToString:@"release"] ? @"Minecraft release" :
                         [versionType isEqualToString:@"snapshot"] ? @"Minecraft snapshot" : @"Minecraft";

    // Create and show the download progress card
    self.progressCardView = [DownloadProgressCardView showInParentView:self.view
                                                                 title:[NSString stringWithFormat:@"Downloading %@", versionId]];
    [self.progressCardView startDownloadWithTitle:[NSString stringWithFormat:@"Downloading %@", versionId]
                                          subtitle:subtitle];

    // Remove the KVO observer from the old task before reassigning downloadTask.
    // Otherwise self.downloadTask.progress is already the new object at dealloc time, and removeObserver throws
    // "not registered as an observer".
    if (self.isObservingProgress && self.downloadTask) {
        @try {
            [self.downloadTask.progress removeObserver:self forKeyPath:@"fractionCompleted"];
        } @catch (NSException *exception) {
            NSLog(@"[DownloadVC] startVersionDownload: removeObserver on old task failed: %@", exception.reason);
        }
        self.isObservingProgress = NO;
    }

    self.downloadTask = [MinecraftResourceDownloadTask new];
    self.downloadTask.maxRetryCount = 3;

    self.downloadTask.retryCallback = ^(NSInteger retryCount, NSInteger maxRetryCount) {
        dispatch_async(dispatch_get_main_queue(), ^{
            if (weakSelf.progressCardView) {
                // Show indeterminate mode (a spinner) while retrying, so the user knows a retry is under way
                [weakSelf.progressCardView updateProgress:-1
                                               downloaded:0
                                                     total:-1
                                                    speed:0
                                                      eta:-1
                                              currentFile:[NSString stringWithFormat:@"Download failed, retrying (%ld/%ld)...", (long)retryCount, (long)maxRetryCount]];
            }
        });
    };

    self.downloadTask.handleError = ^{
        dispatch_async(dispatch_get_main_queue(), ^{
            if (weakSelf.isObservingProgress) {
                @try {
                    [weakSelf.downloadTask.progress removeObserver:weakSelf forKeyPath:@"fractionCompleted"];
                } @catch (NSException *exception) {
                    NSLog(@"[DownloadVC] handleError: removeObserver failed: %@", exception.reason);
                }
                weakSelf.isObservingProgress = NO;
            }
            weakSelf.view.userInteractionEnabled = YES;

            // Show the failure state on the progress card
            if (weakSelf.progressCardView) {
                NSError *error = [NSError errorWithDomain:@"DownloadError" code:-1
                                                 userInfo:@{NSLocalizedDescriptionKey: @"Version download failed. Please check your network connection"}];
                [weakSelf.progressCardView failWithError:error];
                weakSelf.progressCardView = nil;
            }
            weakSelf.downloadTask = nil;
            weakSelf.progressVC = nil;
        });
    };

    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        [self.downloadTask downloadVersion:version];

        dispatch_async(dispatch_get_main_queue(), ^{
            if (self.isObservingProgress) {
                @try {
                    [self.downloadTask.progress removeObserver:self forKeyPath:@"fractionCompleted"];
                } @catch (NSException *exception) {
                    NSLog(@"[DownloadVC] re-register: removeObserver failed: %@", exception.reason);
                }
                self.isObservingProgress = NO;
            }
            [self.downloadTask.progress addObserver:self
                                         forKeyPath:@"fractionCompleted"
                                            options:NSKeyValueObservingOptionInitial
                                            context:(void *)@"DownloadProgressContext"];
            self.isObservingProgress = YES;
        });
    });
}

#pragma mark - Fabric Installation

- (void)installFabric:(NSString *)gameVersion loaderVersion:(NSString *)loaderVersion installAPI:(BOOL)installAPI {
    [self installFabricLikeLoader:gameVersion loaderVersion:loaderVersion installAPI:installAPI vendor:@"fabric"];
}

- (void)installQuilt:(NSString *)gameVersion loaderVersion:(NSString *)loaderVersion {
    // Quilt does not install Fabric API (it uses QSL/QFAPI), so installAPI is forced to NO
    [self installFabricLikeLoader:gameVersion loaderVersion:loaderVersion installAPI:NO vendor:@"quilt"];
}

/// The shared meta API install implementation for Fabric/Quilt
/// - vendor: @"fabric" or @"quilt", which decides the meta URL and the display text
- (void)installFabricLikeLoader:(NSString *)gameVersion loaderVersion:(NSString *)loaderVersion installAPI:(BOOL)installAPI vendor:(NSString *)vendor {
    BOOL isQuilt = [vendor isEqualToString:@"quilt"];
    NSString *displayName = isQuilt ? @"Quilt" : @"Fabric";
    NSString *metaBase = isQuilt ? @"https://meta.quiltmc.org/v3/versions/loader"
                                 : @"https://meta.fabricmc.net/v2/versions/loader";
    NSString *loaderTag = isQuilt ? @"quilt" : @"fabric";

    // Improvement 2 (following the unified progress flow of ZL2): reuse the progress VC handed over by the vanilla preinstall (if there is one),
    // otherwise create a new one; the title is always "Preparing the runtime environment", and the step list merges in the completed vanilla steps.
    InstallerProgressViewController *progressVC = [self obtainInstallerProgressVC];
    progressVC.titleText = [NSString stringWithFormat:@"Preparing the runtime environment %@", gameVersion];
    progressVC.progress = -1; // Indeterminate mode while the profile JSON is being fetched
    progressVC.stageMessage = [NSString stringWithFormat:@"Fetching the %@ profile...\nGame version: %@  Loader: %@", displayName, gameVersion, loaderVersion];
    // Phase 12 enhancement: loader icon + stage list (using ModLoaderIconHelper for consistent icons)
    progressVC.categoryIconName = [ModLoaderIconHelper symbolNameForLoader:loaderTag];
    progressVC.categoryIconColor = [ModLoaderIconHelper brandColorForLoader:loaderTag];
    // Merged step list: the 5 vanilla steps marked complete + the loader install steps
    progressVC.stageSteps = @[
        @{@"title": @"Fetch version manifest", @"status": @2},
        @{@"title": @"Download version JSON", @"status": @2},
        @{@"title": @"Download game libraries", @"status": @2},
        @{@"title": @"Download asset files", @"status": @2},
        @{@"title": @"Verify file integrity", @"status": @2},
        @{@"title": @"Fetch loader profile", @"status": @1},
        @{@"title": @"Download loader libraries", @"status": @0},
        @{@"title": @"Write version JSON", @"status": @0},
    ];

    __weak typeof(self) weakSelf = self;
    __block NSURLSessionDataTask *dataTask = nil;
    progressVC.cancelHandler = ^{
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (dataTask) [dataTask cancel];
        if (strongSelf) {
            [strongSelf.navigationController popViewControllerAnimated:YES];
            strongSelf.installerProgressVC = nil;
        }
    };

    // Note: obtainInstallerProgressVC already pushes it on creation, so a reused VC is not pushed again

    NSString *urlString = [NSString stringWithFormat:@"%@/%@/%@/profile/json", metaBase, gameVersion, loaderVersion];
    NSURL *url = [NSURL URLWithString:urlString];

    // Register with the shared download task manager
    NSString *source = getPrefObject(@"general.download_source") ?: @"official";
    NSString *fabricTaskName = [NSString stringWithFormat:@"%@-%@-%@", loaderTag, gameVersion, loaderVersion];
    DownloadTaskItem *fabricTaskItem = [[DownloadTaskManager sharedManager]
        registerTaskWithResourceType:DownloadTaskResourceTypeModloader
                        resourceName:fabricTaskName
                         displayName:[NSString stringWithFormat:@"%@ %@ (%@)", displayName, loaderVersion, gameVersion]
                      downloadSource:source
                             rawTask:nil
                      supportsResume:YES
                             iconURL:nil];
    __block NSString *fabricTaskId = fabricTaskItem.taskId;

    // The profile JSON is small, so a dataTask is used; progress is driven by stages (it cannot be measured precisely)
    dataTask = [[NSURLSession sharedSession] dataTaskWithURL:url completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        dispatch_async(dispatch_get_main_queue(), ^{
            __strong typeof(weakSelf) strongSelf = weakSelf;
            if (!strongSelf) return;

            if (error) {
                if (error.code == NSURLErrorCancelled) {
                    [[DownloadTaskManager sharedManager] setTaskWithId:fabricTaskId completedWithError:nil];
                    [[DownloadTaskManager sharedManager] setTaskWithId:fabricTaskId state:DownloadTaskStateCancelled];
                } else {
                    NSError *err = [NSError errorWithDomain:@"FabricInstall" code:error.code userInfo:@{NSLocalizedDescriptionKey: error.localizedDescription ?: @"Network error"}];
                    [[DownloadTaskManager sharedManager] setTaskWithId:fabricTaskId completedWithError:err];
                }
                [strongSelf finishInstallerProgressWithError:[NSString stringWithFormat:@"%@ installation failed: %@", displayName, error.localizedDescription ?: @"Network error"]];
                return;
            }

            if (!data) {
                NSError *err = [NSError errorWithDomain:@"FabricInstall" code:2 userInfo:@{NSLocalizedDescriptionKey: @"The returned data was empty"}];
                [[DownloadTaskManager sharedManager] setTaskWithId:fabricTaskId completedWithError:err];
                [strongSelf finishInstallerProgressWithError:[NSString stringWithFormat:@"%@ installation failed: returned data was empty", displayName]];
                return;
            }

            [[DownloadTaskManager sharedManager] updateTaskWithId:fabricTaskId progress:0.5 totalBytes:-1 downloadedBytes:0];

            // Parse the JSON
            strongSelf.installerProgressVC.progress = 0.5;
            strongSelf.installerProgressVC.stageMessage = [NSString stringWithFormat:@"Parsing the %@ profile...", displayName];

            NSError *jsonError;
            NSDictionary *profileJson = [NSJSONSerialization JSONObjectWithData:data options:0 error:&jsonError];
            if (!profileJson || jsonError) {
                NSError *err = [NSError errorWithDomain:@"FabricInstall" code:3 userInfo:@{NSLocalizedDescriptionKey: jsonError.localizedDescription ?: @"Parse failed"}];
                [[DownloadTaskManager sharedManager] setTaskWithId:fabricTaskId completedWithError:err];
                [strongSelf finishInstallerProgressWithError:[NSString stringWithFormat:@"Failed to parse the %@ profile", displayName]];
                return;
            }

            [[DownloadTaskManager sharedManager] updateTaskWithId:fabricTaskId progress:0.7 totalBytes:-1 downloadedBytes:0];

            // Write the version JSON
            strongSelf.installerProgressVC.progress = 0.7;
            strongSelf.installerProgressVC.stageMessage = @"Writing version files...";

            NSString *versionId = profileJson[@"id"];
            NSString *jsonPath = [NSString stringWithFormat:@"%s/versions/%@/%@.json", getenv("POJAV_GAME_DIR"), versionId, versionId];
            [[NSFileManager defaultManager] createDirectoryAtPath:[jsonPath stringByDeletingLastPathComponent]
                                      withIntermediateDirectories:YES
                                                       attributes:nil
                                                            error:nil];

            NSError *saveError;
            NSData *jsonData = [NSJSONSerialization dataWithJSONObject:profileJson options:NSJSONWritingPrettyPrinted error:&saveError];
            [jsonData writeToFile:jsonPath options:NSDataWritingAtomic error:&saveError];
            if (saveError) {
                NSError *err = [NSError errorWithDomain:@"FabricInstall" code:4 userInfo:@{NSLocalizedDescriptionKey: saveError.localizedDescription}];
                [[DownloadTaskManager sharedManager] setTaskWithId:fabricTaskId completedWithError:err];
                [strongSelf finishInstallerProgressWithError:[NSString stringWithFormat:@"Failed to save profile: %@", saveError.localizedDescription]];
                return;
            }

            [[DownloadTaskManager sharedManager] updateTaskWithId:fabricTaskId progress:0.85 totalBytes:-1 downloadedBytes:0];

            // Register the profile
            strongSelf.installerProgressVC.progress = 0.85;
            strongSelf.installerProgressVC.stageMessage = @"Registering profile...";

            NSMutableDictionary *profile = [NSMutableDictionary dictionary];
            profile[@"name"] = versionId;
            profile[@"lastVersionId"] = versionId;
            // Back to the original "switch game directory" model: every version shares the root directory (gameDir=".")
            // The user switches between game directories manually with the "Switch game directory" feature in settings
            profile[@"gameDir"] = @".";
            profile[@"type"] = @"custom";
            profile[@"created"] = [NSDate date].description;
            [PLProfiles.current saveProfile:profile withName:versionId];
            PLProfiles.current.selectedProfileName = versionId;

            // Only Fabric installs Fabric API; Quilt uses QSL/QFAPI and skips it
            if (installAPI && !isQuilt) {
                strongSelf.installerProgressVC.progress = 0.9;
                strongSelf.installerProgressVC.stageMessage = @"Downloading Fabric API...";
                [strongSelf downloadFabricAPI:gameVersion completion:^(BOOL success, NSError *apiError) {
                    dispatch_async(dispatch_get_main_queue(), ^{
                        __strong typeof(weakSelf) strongSelf2 = weakSelf;
                        if (!strongSelf2) return;
                        if (success) {
                            [[DownloadTaskManager sharedManager] setTaskWithId:fabricTaskId completedWithError:nil];
                            [strongSelf2 finishInstallerProgressWithSuccess:[NSString stringWithFormat:@"%@ %@ installed successfully\nFabric API installed automatically", displayName, loaderVersion]];
                        } else {
                            NSError *err = [NSError errorWithDomain:@"FabricInstall" code:5 userInfo:@{NSLocalizedDescriptionKey: apiError.localizedDescription ?: @"Fabric API download failed"}];
                            [[DownloadTaskManager sharedManager] setTaskWithId:fabricTaskId completedWithError:err];
                            [strongSelf2 finishInstallerProgressWithSuccess:[NSString stringWithFormat:@"%@ %@ installed successfully\nFabric API install failed: %@", displayName, loaderVersion, apiError.localizedDescription ?: @"Unknown error"]];
                        }
                    });
                }];
            } else {
                [[DownloadTaskManager sharedManager] setTaskWithId:fabricTaskId completedWithError:nil];
                [strongSelf finishInstallerProgressWithSuccess:[NSString stringWithFormat:@"%@ %@ installed successfully", displayName, loaderVersion]];
            }
        });
    }];
    fabricTaskItem.rawTask = dataTask;
    [[DownloadTaskManager sharedManager] setTaskWithId:fabricTaskId state:DownloadTaskStateDownloading];
    [dataTask resume];
}

// Shared handling when the install progress VC succeeds: fill the progress bar -> show it briefly -> pop and show the success message
- (void)finishInstallerProgressWithSuccess:(NSString *)message {
    if (!self.installerProgressVC) return;
    self.installerProgressVC.progress = 1.0;
    self.installerProgressVC.stageMessage = @"Installation complete";
    __weak typeof(self) weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.8 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf) return;
        [strongSelf.navigationController popViewControllerAnimated:YES];
        strongSelf.installerProgressVC = nil;
        [strongSelf showSuccessMessage:message];
        // Key fix (issue #61): Fabric/Forge/NeoForge/OptiFine did not post the ReloadProfileList notification after installing,
        // so the "Installed versions" list did not refresh, new version cards did not appear, and loader icons were missing.
        // The notification is now posted here after every install, prompting listeners such as LauncherRootViewController / VersionManagerViewController to reload the version list.
        [[NSNotificationCenter defaultCenter] postNotificationName:@"ReloadProfileList" object:nil];
    });
}

// Shared handling when the install progress VC fails: show the error -> pop
- (void)finishInstallerProgressWithError:(NSString *)errorMessage {
    __weak typeof(self) weakSelf = self;
    dispatch_async(dispatch_get_main_queue(), ^{
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf) return;
        if (strongSelf.installerProgressVC) {
            [strongSelf.navigationController popViewControllerAnimated:YES];
            strongSelf.installerProgressVC = nil;
        }
        [strongSelf showError:errorMessage];
    });
}

/// Improvement 2 (following the unified progress flow of ZL2): obtain the loader install progress VC.
/// If self.installerProgressVC already exists (handed over after the vanilla preinstall), reuse it directly
/// without creating or pushing a new VC, so "vanilla + loader" run continuously on one progress page;
/// otherwise create and push a new VC as before.
- (InstallerProgressViewController *)obtainInstallerProgressVC {
    if (self.installerProgressVC) {
        return self.installerProgressVC;
    }
    InstallerProgressViewController *progressVC = [[InstallerProgressViewController alloc] init];
    self.installerProgressVC = progressVC;
    [self.navigationController pushViewController:progressVC animated:YES];
    return progressVC;
}

- (void)downloadFabricAPI:(NSString *)gameVersion completion:(void (^)(BOOL success, NSError *error))completion {
    NSMutableDictionary *filters = [NSMutableDictionary dictionary];
    filters[@"query"] = @"fabric api";
    filters[@"version"] = gameVersion;
    
    __weak typeof(self) weakSelf = self;
    id api = [self currentAPIForTabType:@"mod"];
    [api searchModWithFilters:filters completion:^(NSArray *results, NSError *error) {
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf) {
            if (completion) completion(NO, [NSError errorWithDomain:@"AppError" code:-1 userInfo:nil]);
            return;
        }
        if (error || results.count == 0) {
            if (completion) completion(NO, error ?: [NSError errorWithDomain:@"DownloadError" code:1 userInfo:@{NSLocalizedDescriptionKey: @"Fabric API not found"}]);
            return;
        }
        
        NSDictionary *fabricAPI = nil;
        for (NSDictionary *mod in results) {
            NSString *title = mod[@"title"] ?: @"";
            if ([title.lowercaseString containsString:@"fabric api"] && ![title.lowercaseString containsString:@"kotlin"]) {
                fabricAPI = mod;
                break;
            }
        }
        
        if (!fabricAPI) {
            if (completion) completion(NO, [NSError errorWithDomain:@"DownloadError" code:2 userInfo:@{NSLocalizedDescriptionKey: @"No suitable Fabric API version found"}]);
            return;
        }
        
        [api getVersionsForModWithID:fabricAPI[@"id"] completion:^(NSArray<ModVersion *> *versions, NSError *versionError) {
            if (versionError || versions.count == 0) {
                if (completion) completion(NO, versionError ?: [NSError errorWithDomain:@"DownloadError" code:3 userInfo:@{NSLocalizedDescriptionKey: @"Failed to fetch Fabric API versions"}]);
                return;
            }
            
            ModVersion *matchingVersion = nil;
            for (ModVersion *ver in versions) {
                if ([ver.gameVersions containsObject:gameVersion]) {
                    matchingVersion = ver;
                    break;
                }
            }
            
            if (!matchingVersion) {
                matchingVersion = versions.firstObject;
            }
            
            [strongSelf downloadModVersion:matchingVersion modInfo:fabricAPI completion:completion];
        }];
    }];
}

#pragma mark - Forge Installation

- (LauncherNavigationController *)activeLauncherNavigationController {
    // First try the existing logic
    UISplitViewController *splitVC = self.splitViewController;
    if (!splitVC && [self.presentingViewController isKindOfClass:[UISplitViewController class]]) {
        splitVC = (UISplitViewController *)self.presentingViewController;
    }
    if (splitVC.viewControllers.count > 1) {
        UIViewController *candidate = splitVC.viewControllers[1];
        if ([candidate isKindOfClass:[LauncherNavigationController class]]) {
            return (LauncherNavigationController *)candidate;
        }
        if ([candidate isKindOfClass:[UINavigationController class]]) {
            for (UIViewController *vc in ((UINavigationController *)candidate).viewControllers) {
                if ([vc isKindOfClass:[LauncherNavigationController class]]) {
                    return (LauncherNavigationController *)vc;
                }
            }
        }
    }
    if ([self.navigationController isKindOfClass:[LauncherNavigationController class]]) {
        return (LauncherNavigationController *)self.navigationController;
    }

    // Fallback: traverse from key window root view controller
    UIWindow *keyWindow = nil;
    if (@available(iOS 13.0, *)) {
        for (UIWindowScene *scene in [UIApplication sharedApplication].connectedScenes) {
            if (scene.activationState == UISceneActivationStateForegroundActive) {
                keyWindow = scene.windows.firstObject;
                break;
            }
        }
    }
    if (!keyWindow) {
        keyWindow = [[UIApplication sharedApplication] windows].firstObject;
    }

    UIViewController *rootVC = keyWindow.rootViewController;
    if (rootVC) {
        LauncherNavigationController *found = [self findLauncherNavigationControllerIn:rootVC];
        if (found) return found;
    }

    return nil;
}

- (LauncherNavigationController *)findLauncherNavigationControllerIn:(UIViewController *)vc {
    if ([vc isKindOfClass:[LauncherNavigationController class]]) {
        return (LauncherNavigationController *)vc;
    }
    if ([vc isKindOfClass:[UINavigationController class]]) {
        for (UIViewController *child in ((UINavigationController *)vc).viewControllers) {
            LauncherNavigationController *found = [self findLauncherNavigationControllerIn:child];
            if (found) return found;
        }
    }
    if ([vc isKindOfClass:[UISplitViewController class]]) {
        for (UIViewController *child in ((UISplitViewController *)vc).viewControllers) {
            LauncherNavigationController *found = [self findLauncherNavigationControllerIn:child];
            if (found) return found;
        }
    }
    if ([vc isKindOfClass:[UITabBarController class]]) {
        for (UIViewController *child in ((UITabBarController *)vc).viewControllers) {
            LauncherNavigationController *found = [self findLauncherNavigationControllerIn:child];
            if (found) return found;
        }
    }
    if (vc.presentedViewController) {
        LauncherNavigationController *found = [self findLauncherNavigationControllerIn:vc.presentedViewController];
        if (found) return found;
    }
    for (UIViewController *child in vc.childViewControllers) {
        LauncherNavigationController *found = [self findLauncherNavigationControllerIn:child];
        if (found) return found;
    }
    return nil;
}

#pragma mark - Mod Installer (Fallback when LauncherNavigationController is not available)

- (void)launchModInstallerWithPath:(NSString *)path hitEnterAfterWindowShown:(BOOL)hitEnter {
    JavaGUIViewController *vc = [[JavaGUIViewController alloc] init];
    vc.filepath = path;
    vc.hitEnterAfterWindowShown = hitEnter;
    if (!vc.requiredJavaVersion) {
        // Report parse failures (a missing manifest or an invalid main class) explicitly, instead of returning silently and letting the user think the installer started
        showDialog(localize(@"Error", nil),
            [NSString stringWithFormat:@"Could not determine the installer main class or Java version: %@", path.lastPathComponent]);
        return;
    }
    // The execute_jar path: the Caciocavallo17 jar is now consistently compiled for Java 17,
    // so both Java 17 and 21 can load it and requiredJavaVersion no longer has to be forced up to 25.
    // - Java 8 JARs (such as the OptiFine installer) take the Caciocavallo (non-17) path and use Java 8
    // - Java 17+ JARs take the Caciocavallo17 path and can use Java 17 or 21
    // This matches the launchJar branch in JavaLauncher.m.
    int requiredJavaVersion = vc.requiredJavaVersion;
    // Check up front whether a JRE is configured for the execute_jar tag, so a missing JRE is not discovered after presenting and left as a black screen
    // This matches the behavior of LauncherRightPanelViewController.enterModInstallerWithPath:
    NSString *javaHome = getSelectedJavaHome(@"execute_jar", requiredJavaVersion);
    if (!javaHome) {
        showDialog(localize(@"Error", nil),
            [NSString stringWithFormat:@"Running this JAR requires Java %d or later, but no matching runtime is configured.\n\nGo to Settings → Manage runtimes and assign a Java %d+ runtime to the \"Execute Jar\" tag.", requiredJavaVersion, requiredJavaVersion]);
        return;
    }
    [self invokeAfterJITEnabled:^{
        vc.modalPresentationStyle = UIModalPresentationFullScreen;
        NSLog(@"[ModInstaller] launching %@", vc.filepath);
        [self presentViewController:vc animated:YES completion:nil];
    }];
}

- (void)invokeAfterJITEnabled:(void(^)(void))handler {
    BOOL hasTrollStoreJIT = getEntitlementValue(@"jb.pmap_cs.custom_trust");
    
    if (isJITEnabled(false)) {
        [ALTServerManager.sharedManager stopDiscovering];
        handler();
        return;
    } else if (hasTrollStoreJIT) {
        NSURL *jitURL = [NSURL URLWithString:[NSString stringWithFormat:@"apple-magnifier://enable-jit?bundle-id=%@", NSBundle.mainBundle.bundleIdentifier]];
        [UIApplication.sharedApplication openURL:jitURL options:@{} completionHandler:nil];
    } else if (getPrefBool(@"debug.debug_skip_wait_jit")) {
        NSLog(@"Debug option skipped waiting for JIT. Java might not work.");
        handler();
        return;
    } else if (@available(iOS 17.4, *)) {
        NSString *scriptDataString = @"";
        if (DeviceNeedsDebugJITMapping()) {
            NSData *scriptData = [NSData dataWithContentsOfFile:[NSBundle.mainBundle.bundlePath stringByAppendingPathComponent:@"UniversalJIT26.js"]];
            scriptDataString = [@"&script-data=" stringByAppendingString:[scriptData base64EncodedStringWithOptions:0]];
        }
        [UIApplication.sharedApplication openURL:[NSURL URLWithString:[NSString stringWithFormat:@"stikjit://enable-jit?bundle-id=%@&pid=%d%@", NSBundle.mainBundle.bundleIdentifier, getpid(), scriptDataString]] options:@{} completionHandler:nil];
    } else {
        // Assuming 16.7-17.3.1. SideStore still lacks this URL scheme at the time of writing, so it only jumps to SideStore.
        [UIApplication.sharedApplication openURL:[NSURL URLWithString:[NSString stringWithFormat:@"sidestore://sidejit-enable?pid=%d", getpid()]] options:@{} completionHandler:nil];
    }
    
    // Show the JIT waiting hint in the content area instead of an alert
    InlineMessageView *jitAlert = [InlineMessageView showInViewController:self
                                                                    title:localize(@"launcher.wait_jit.title", nil)
                                                                 message:hasTrollStoreJIT ? localize(@"launcher.wait_jit_trollstore.message", nil) : localize(@"launcher.wait_jit.message", nil)
                                                                    type:InlineMessageTypeLoading];

    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        while (!isJITEnabled(false)) {
            usleep(1000 * 200);
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            [jitAlert dismiss];
            if (handler) handler();
        });
    });
}

- (void)handleInstallerDownloadResultWithVendorName:(NSString *)vendorName
                                        gameVersion:(NSString *)gameVersion
                                        profileName:(NSString *)profileName
                                    resultOrError:(id)resultOrError
                                     installAction:(void (^)(void))installAction {
    if ([resultOrError isKindOfClass:[NSError class]]) {
        NSError *error = (NSError *)resultOrError;
        if ([error.domain isEqualToString:ForgeInstallerFlowErrorDomain] && error.code == ForgeInstallerFlowErrorCodeCancelled) {
            return;
        }
        [self showError:error.localizedDescription ?: [NSString stringWithFormat:@"%@ installation failed", vendorName]];
        return;
    }
    
    NSString *filePath = nil;
    if ([resultOrError isKindOfClass:[NSDictionary class]]) {
        filePath = ((NSDictionary *)resultOrError)[@"filePath"];
    } else if ([resultOrError isKindOfClass:[NSString class]]) {
        filePath = (NSString *)resultOrError;
    }
    if (filePath.length == 0) {
        [self showError:[NSString stringWithFormat:@"%@ installer download result is invalid", vendorName]];
        return;
    }
    
    LauncherNavigationController *navVC = [self activeLauncherNavigationController];
    
    NSString *message = [NSString stringWithFormat:@"The %@ installer has been downloaded and is starting. Follow the prompts once installation finishes.", vendorName];
    
    void (^launchInstaller)(void) = ^{
        if (navVC) {
            [navVC enterModInstallerWithPath:filePath hitEnterAfterWindowShown:YES];
        } else {
            [self launchModInstallerWithPath:filePath hitEnterAfterWindowShown:YES];
        }
        
        if (installAction) {
            installAction();
        } else {
            [self showSuccessMessage:[NSString stringWithFormat:@"%@ installer started\nProfile: %@", vendorName, profileName ?: gameVersion]];
        }
    };
    
    void (^showAlertAndLaunch)(void) = ^{
        // Show the download-complete hint in the content area instead of an alert
        InlineMessageView *msgView = [InlineMessageView showInViewController:self
                                                                       title:@"Download complete"
                                                                    message:message
                                                                       type:InlineMessageTypeSuccess];

        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            [msgView dismiss];
            if (launchInstaller) launchInstaller();
        });
    };

    if (self.presentedViewController) {
        [self dismissViewControllerAnimated:YES completion:showAlertAndLaunch];
    } else {
        showAlertAndLaunch();
    }
}

- (void)installForge:(NSString *)gameVersion installOptiFine:(BOOL)installOptiFine loaderVersion:(NSString *)loaderVersion {
    ForgeInstallViewController *forgeVC = [[ForgeInstallViewController alloc] init];
    forgeVC.gameVersion = gameVersion;
    // ModLoaderInstallViewController has already picked a version, which is passed in to skip the duplicate version list UI
    forgeVC.presetVersionString = loaderVersion;

    __weak typeof(self) weakSelf = self;
    void (^completion)(BOOL, NSString *, id) = ^(BOOL success, NSString *profileName, id resultOrError) {
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf) return;

        // Parse the callback result packed by ForgeInstallViewController (it has to be parsed either way)
        NSInteger selectedScheme = 0;
        NSString *filePath = nil;
        if ([resultOrError isKindOfClass:[NSDictionary class]]) {
            NSDictionary *result = (NSDictionary *)resultOrError;
            filePath = result[@"filePath"];
            selectedScheme = [result[@"selectedScheme"] integerValue];
        } else if ([resultOrError isKindOfClass:[NSString class]]) {
            filePath = (NSString *)resultOrError;
        }

        // Pop ForgeInstallViewController first and continue once the pop completes,
        // otherwise presenting an alert / pushing the progress page during the pop animation fails or shows the wrong VC
        void (^continuation)(void) = ^{
            __strong typeof(weakSelf) strongSelf2 = weakSelf;
            if (!strongSelf2) return;

            if (!success) {
                [strongSelf2 handleInstallerDownloadResultWithVendorName:@"Forge"
                                                              gameVersion:gameVersion
                                                              profileName:profileName
                                                            resultOrError:resultOrError
                                                             installAction:nil];
                return;
            }

            if (selectedScheme == 1 && filePath.length > 0) {
                // Direct install: reuse or create the progress VC, driven by the progress callback of ForgeDirectInstaller
                NSLog(@"[ForgeDirect] DownloadViewController: starting direct install with progress UI");
                // Improvement 2 (following the unified progress flow of ZL2): reuse the progress VC handed over by the vanilla preinstall (if there is one)
                InstallerProgressViewController *progressVC = [strongSelf2 obtainInstallerProgressVC];
                progressVC.titleText = [NSString stringWithFormat:@"Preparing the runtime environment %@", gameVersion];
                progressVC.progress = 0.0;
                progressVC.stageMessage = @"Preparing...";
                // Phase 12 enhancement: Forge icon + stage list
                progressVC.categoryIconName = [ModLoaderIconHelper symbolNameForLoader:@"forge"];
                progressVC.categoryIconColor = [ModLoaderIconHelper brandColorForLoader:@"forge"];
                // Merged step list: the 5 vanilla steps marked complete + the Forge install steps
                progressVC.stageSteps = @[
                    @{@"title": @"Fetch version manifest", @"status": @2},
                    @{@"title": @"Download version JSON", @"status": @2},
                    @{@"title": @"Download game libraries", @"status": @2},
                    @{@"title": @"Download asset files", @"status": @2},
                    @{@"title": @"Verify file integrity", @"status": @2},
                    @{@"title": @"Parse installer JAR", @"status": @1},
                    @{@"title": @"Download Forge libraries", @"status": @0},
                    @{@"title": @"Write version JSON", @"status": @0},
                ];
                // Note: obtainInstallerProgressVC already pushes it on creation, so a reused VC is not pushed again

                dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
                    NSError *directError = nil;
                    BOOL installed = [ForgeDirectInstaller installForgeFromInstaller:filePath
                                                                           versionId:profileName
                                                                             progress:^(double progress, NSString *stageMessage) {
                        dispatch_async(dispatch_get_main_queue(), ^{
                            __strong typeof(weakSelf) strongSelf3 = weakSelf;
                            if (!strongSelf3 || !strongSelf3.installerProgressVC) return;
                            strongSelf3.installerProgressVC.progress = progress;
                            NSString *stage = stageMessage ?: @"";
                            strongSelf3.installerProgressVC.stageMessage = [NSString stringWithFormat:@"%@ - %.0f%%", stage, progress * 100];
                        });
                    }
                                                                               error:&directError];

                    dispatch_async(dispatch_get_main_queue(), ^{
                        __strong typeof(weakSelf) strongSelf3 = weakSelf;
                        if (!strongSelf3) return;
                        if (!installed) {
                            [strongSelf3 finishInstallerProgressWithError:[NSString stringWithFormat:@"Direct Forge install failed: %@", directError.localizedDescription ?: @"Unknown error"]];
                            return;
                        }
                        // After a successful direct install, continue downloading OptiFine if the user ticked it (the previous implementation returned here and skipped OptiFine)
                        if (installOptiFine) {
                            strongSelf3.installerProgressVC.stageMessage = @"Downloading OptiFine...";
                            strongSelf3.installerProgressVC.progress = -1; // The OptiFine download cannot be measured precisely, so switch to indeterminate mode
                            [strongSelf3 downloadOptiFine:gameVersion completion:^(BOOL optiSuccess, NSError *optiError) {
                                dispatch_async(dispatch_get_main_queue(), ^{
                                    __strong typeof(weakSelf) strongSelf4 = weakSelf;
                                    if (!strongSelf4) return;
                                    if (optiSuccess) {
                                        [strongSelf4 finishInstallerProgressWithSuccess:[NSString stringWithFormat:@"Direct Forge install succeeded\nOptiFine installed automatically\nProfile: %@", profileName ?: gameVersion]];
                                    } else {
                                        [strongSelf4 finishInstallerProgressWithSuccess:[NSString stringWithFormat:@"Direct Forge install succeeded\nOptiFine install failed: %@\nProfile: %@", optiError.localizedDescription ?: @"Unknown error", profileName ?: gameVersion]];
                                    }
                                });
                            }];
                        } else {
                            [strongSelf3 finishInstallerProgressWithSuccess:[NSString stringWithFormat:@"Direct Forge install succeeded\nProfile: %@", profileName ?: gameVersion]];
                        }
                    });
                });
                return;
            }

            // Vanilla method (running the installer): enter the AWT installer GUI flow
            [strongSelf2 handleInstallerDownloadResultWithVendorName:@"Forge"
                                                          gameVersion:gameVersion
                                                          profileName:profileName
                                                        resultOrError:resultOrError
                                                         installAction:^{
                if (installOptiFine) {
                    [strongSelf2 downloadOptiFine:gameVersion completion:^(BOOL optiSuccess, NSError *optiError) {
                        dispatch_async(dispatch_get_main_queue(), ^{
                            if (optiSuccess) {
                                [strongSelf2 showSuccessMessage:[NSString stringWithFormat:@"Forge installer started\nOptiFine installed automatically\nProfile: %@", profileName ?: gameVersion]];
                            } else {
                                [strongSelf2 showSuccessMessage:[NSString stringWithFormat:@"Forge installer started\nOptiFine install failed: %@\nProfile: %@", optiError.localizedDescription ?: @"Unknown error", profileName ?: gameVersion]];
                            }
                        });
                    }];
                } else {
                    [strongSelf2 showSuccessMessage:[NSString stringWithFormat:@"Forge installer started\nProfile: %@", profileName ?: gameVersion]];
                }
            }];
        };

        if (strongSelf.navigationController.topViewController != strongSelf) {
            [strongSelf.navigationController popViewControllerAnimated:YES];
            // Wait for the pop animation to finish before presenting/pushing, to avoid animation conflicts
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.35 * NSEC_PER_SEC)), dispatch_get_main_queue(), continuation);
        } else {
            continuation();
        }
    };
    forgeVC.completionHandler = completion;

    // Push straight into the middle content area rather than presenting a FormSheet
    [self.navigationController pushViewController:forgeVC animated:YES];
}

- (void)downloadOptiFine:(NSString *)gameVersion completion:(void (^)(BOOL success, NSError *error))completion {
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        // Fix: no longer rely on a hardcoded version map (which goes stale); query BMCLAPI dynamically for the newest OptiFine version for the game version
        NSString *listURL = [NSString stringWithFormat:@"https://bmclapi2.bangbang93.com/optifine/%@", gameVersion];
        // Phase 6 fix (following FCL): use a synchronous NSURLSession download with a User-Agent instead of NSData dataWithContentsOfURL:
        // BMCLAPI/Cloudflare block requests with no UA or the default UA, returning 403 or an HTML error page
        NSError *listError = nil;
        NSData *listData = [self downloadDataWithURLString:listURL error:&listError];
        NSString *optiFineType = nil;
        NSString *optiFinePatch = nil;
        NSString *filename = nil;

        if (listData && !listError) {
            NSError *jsonError = nil;
            NSArray *versions = [NSJSONSerialization JSONObjectWithData:listData options:0 error:&jsonError];
            if (!jsonError && [versions isKindOfClass:[NSArray class]] && versions.count > 0) {
                // Take the first entry in the list (usually the newest release)
                NSDictionary *first = versions.firstObject;
                if ([first isKindOfClass:[NSDictionary class]]) {
                    optiFineType = first[@"type"] ?: @"HD_U";
                    optiFinePatch = first[@"patch"];
                    filename = first[@"filename"];
                }
            }
        }

        // Fallback: fall back to the local hardcoded map when the list API fails
        if (!optiFinePatch) {
            NSString *mapped = [self mapGameVersionToOptiFine:gameVersion];
            if (mapped) {
                // The map stores entries like "HD_U_I6", so split it into type=HD_U and patch=I6
                NSRange range = [mapped rangeOfString:@"_"];
                if (range.location != NSNotFound) {
                    optiFineType = [mapped substringToIndex:range.location];
                    optiFinePatch = [mapped substringFromIndex:range.location + 1];
                }
            }
        }

        if (!optiFinePatch) {
            dispatch_async(dispatch_get_main_queue(), ^{
                if (completion) completion(NO, [NSError errorWithDomain:@"DownloadError" code:1 userInfo:@{NSLocalizedDescriptionKey: [NSString stringWithFormat:@"Unsupported OptiFine version: %@ (the BMCLAPI listing failed and there is no local mapping)", gameVersion]}]);
            });
            return;
        }

        // BMCLAPI OptiFine download URL: /optifine/{mcversion}/{type}/{patch}
        NSString *downloadURL = [NSString stringWithFormat:@"https://bmclapi2.bangbang93.com/optifine/%@/%@/%@",
                                 gameVersion, optiFineType, optiFinePatch];
        // Phase 6 fix: use the download method that sends a UA
        NSError *downloadError = nil;
        NSData *data = [self downloadDataWithURLString:downloadURL error:&downloadError];

        // Fallback: the official OptiFine source
        if ((!data || downloadError) && filename) {
            NSString *officialURL = [NSString stringWithFormat:@"https://optifine.net/downloadx?f=%@", filename];
            // Phase 6 fix: use the download method that sends a UA
            NSError *officialError = nil;
            NSData *officialData = [self downloadDataWithURLString:officialURL error:&officialError];
            if (officialData && !officialError) {
                data = officialData;
                downloadError = nil;
            }
        }

        if (!data || downloadError) {
            dispatch_async(dispatch_get_main_queue(), ^{
                NSString *errDesc = downloadError.localizedDescription;
                if (downloadError.code == NSURLErrorFileDoesNotExist || [errDesc containsString:@"404"]) {
                    errDesc = [NSString stringWithFormat:@"OptiFine %@ %@ does not exist on the BMCLAPI mirror (404). OptiFine may not have been released for this game version yet.", optiFineType, optiFinePatch];
                }
                if (completion) completion(NO, [NSError errorWithDomain:@"DownloadError" code:2 userInfo:@{NSLocalizedDescriptionKey: errDesc ?: @"Failed to download OptiFine"}]);
            });
            return;
        }

        NSString *modsDir = [self currentInstanceModsPath];
        // Prefer the filename returned by the API; otherwise build it from type_patch
        NSString *saveFilename = filename ?: [NSString stringWithFormat:@"OptiFine_%@_%@_%@.jar", gameVersion, optiFineType, optiFinePatch];
        NSString *savePath = [modsDir stringByAppendingPathComponent:saveFilename];

        NSError *saveError;
        BOOL success = [data writeToFile:savePath options:NSDataWritingAtomic error:&saveError];

        // A 200 response is not proof this is a jar: a mirror answering with an error page still
        // returns 200, and that page written into mods/ under a .jar name stops the game starting
        // with an error that names no file. Check before leaving it there.
        if (success) {
            NSString *corruption = [ArchiveIntegrity validationFailureForArchiveAtPath:savePath];
            if (corruption) {
                [NSFileManager.defaultManager removeItemAtPath:savePath error:nil];
                success = NO;
                saveError = [NSError errorWithDomain:@"DownloadError" code:3 userInfo:@{
                    NSLocalizedDescriptionKey: [NSString stringWithFormat:
                        @"The OptiFine download was damaged (%@). Nothing was added to your mods folder.", corruption]
                }];
                NSLog(@"[DownloadVC] Discarded damaged OptiFine download: %@", corruption);
            }
        }

        dispatch_async(dispatch_get_main_queue(), ^{
            if (completion) completion(success, saveError);
        });
    });
}

- (NSString *)mapGameVersionToOptiFine:(NSString *)gameVersion {
    NSDictionary *versionMap = @{
        @"1.21.4": @"HD_U_J3",
        @"1.21.3": @"HD_U_J2",
        @"1.21.1": @"HD_U_J1",
        @"1.21": @"HD_U_I9",
        @"1.20.4": @"HD_U_I7",
        @"1.20.2": @"HD_U_I6",
        @"1.20.1": @"HD_U_I6",
        @"1.20": @"HD_U_I5",
        @"1.19.4": @"HD_U_I4",
        @"1.19.3": @"HD_U_I3",
        @"1.19.2": @"HD_U_H9",
        @"1.18.2": @"HD_U_H7",
        @"1.17.1": @"HD_U_H1",
        @"1.16.5": @"HD_U_G8",
        @"1.16.4": @"HD_U_G7",
        @"1.15.2": @"HD_U_G6",
        @"1.14.4": @"HD_U_G5",
        @"1.12.2": @"HD_U_G5",
        @"1.8.9": @"HD_U_L5",
    };
    
    NSString *optiFineVersion = versionMap[gameVersion];
    if (optiFineVersion) return optiFineVersion;
    
    for (NSString *key in versionMap) {
        if ([gameVersion hasPrefix:key]) {
            return versionMap[key];
        }
    }
    
    return nil;
}

#pragma mark - OptiFine as Patch Installation (standalone install, modeled on FCL OptiFineInstallTask)

/// Install OptiFine on its own as a version patch (without Forge)
/// loaderVersion is in the packed format: type\x1fpatch\x1ffilename\x1fdisplay
- (void)installOptiFineAsPatch:(NSString *)gameVersion loaderVersion:(NSString *)loaderVersion {
    // Parse the packed format
    NSArray *parts = [loaderVersion componentsSeparatedByString:@"\x1f"];
    if (parts.count < 3) {
        [self showError:@"OptiFine version information is invalid"];
        return;
    }
    NSString *optiType = parts[0];
    NSString *optiPatch = parts[1];
    NSString *filename = parts[2];

    NSString *versionId = [NSString stringWithFormat:@"%@-OptiFine_%@_%@", gameVersion, optiType, optiPatch];

    // Improvement 2 (following the unified progress flow of ZL2): reuse the progress VC handed over by the vanilla preinstall (if there is one)
    InstallerProgressViewController *progressVC = [self obtainInstallerProgressVC];
    progressVC.titleText = [NSString stringWithFormat:@"Preparing the runtime environment %@", gameVersion];
    progressVC.progress = -1;
    progressVC.stageMessage = [NSString stringWithFormat:@"Downloading OptiFine %@_%@...", optiType, optiPatch];
    // Phase 12 enhancement: OptiFine icon + stage list
    progressVC.categoryIconName = [ModLoaderIconHelper symbolNameForLoader:@"optifine"];
    progressVC.categoryIconColor = [ModLoaderIconHelper brandColorForLoader:@"optifine"];
    // Merged step list: the 5 vanilla steps marked complete + the OptiFine install steps
    progressVC.stageSteps = @[
        @{@"title": @"Fetch version manifest", @"status": @2},
        @{@"title": @"Download version JSON", @"status": @2},
        @{@"title": @"Download game libraries", @"status": @2},
        @{@"title": @"Download asset files", @"status": @2},
        @{@"title": @"Verify file integrity", @"status": @2},
        @{@"title": @"Download OptiFine JAR", @"status": @1},
        @{@"title": @"Install OptiFine", @"status": @0},
        @{@"title": @"Write version JSON", @"status": @0},
    ];

    __weak typeof(self) weakSelf = self;
    progressVC.cancelHandler = ^{
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (strongSelf) {
            [strongSelf.navigationController popViewControllerAnimated:YES];
            strongSelf.installerProgressVC = nil;
        }
    };

    // Note: obtainInstallerProgressVC already pushes it on creation, so a reused VC is not pushed again

    // Register with the download task manager
    NSString *source = getPrefObject(@"general.download_source") ?: @"official";
    NSString *taskName = [NSString stringWithFormat:@"optifine-%@-%@-%@", gameVersion, optiType, optiPatch];
    DownloadTaskItem *taskItem = [[DownloadTaskManager sharedManager]
        registerTaskWithResourceType:DownloadTaskResourceTypeModloader
                        resourceName:taskName
                         displayName:[NSString stringWithFormat:@"OptiFine %@_%@ (%@)", optiType, optiPatch, gameVersion]
                      downloadSource:source
                             rawTask:nil
                      supportsResume:NO
                             iconURL:nil];
    __block NSString *taskId = taskItem.taskId;

    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        // 1. Download the OptiFine jar
        // Phase 6 fix (following FCL): use a synchronous NSURLSession download with a User-Agent instead of NSData dataWithContentsOfURL:
        // Some BMCLAPI mirrors (especially the CurseForge/optifine forwarders) sit behind Cloudflare,
        // which blocks the default UA with a 403. A browser UA is required.
        NSString *bmclURL = [NSString stringWithFormat:@"https://bmclapi2.bangbang93.com/optifine/%@/%@/%@", gameVersion, optiType, optiPatch];
        NSError *downloadError = nil;
        NSData *jarData = [self downloadDataWithURLString:bmclURL error:&downloadError];

        // Fall back to the official source
        if ((!jarData || downloadError) && filename.length > 0) {
            NSString *officialURL = [NSString stringWithFormat:@"https://optifine.net/downloadx?f=%@", filename];
            NSError *officialError = nil;
            NSData *officialData = [self downloadDataWithURLString:officialURL error:&officialError];
            if (officialData && !officialError) {
                jarData = officialData;
                downloadError = nil;
            }
        }

        if (!jarData || downloadError) {
            NSError *err = [NSError errorWithDomain:@"OptiFineInstall" code:1 userInfo:@{NSLocalizedDescriptionKey: downloadError.localizedDescription ?: @"Failed to download OptiFine"}];
            [[DownloadTaskManager sharedManager] setTaskWithId:taskId completedWithError:err];
            dispatch_async(dispatch_get_main_queue(), ^{
                __strong typeof(weakSelf) strongSelf = weakSelf;
                if (!strongSelf) return;
                [strongSelf finishInstallerProgressWithError:[NSString stringWithFormat:@"Failed to download OptiFine: %@", downloadError.localizedDescription ?: @"Unknown error"]];
            });
            return;
        }

        [[DownloadTaskManager sharedManager] updateTaskWithId:taskId progress:0.5 totalBytes:-1 downloadedBytes:0];
        dispatch_async(dispatch_get_main_queue(), ^{
            __strong typeof(weakSelf) strongSelf = weakSelf;
            if (!strongSelf) return;
            strongSelf.installerProgressVC.progress = 0.5;
            strongSelf.installerProgressVC.stageMessage = @"Writing version files...";
        });

        // 2. Create the version directory
        const char *env = getenv("POJAV_GAME_DIR");
        NSString *gameDir = env ? [NSString stringWithUTF8String:env] : NSHomeDirectory();
        NSString *versionDir = [gameDir stringByAppendingPathComponent:[NSString stringWithFormat:@"versions/%@", versionId]];
        [[NSFileManager defaultManager] createDirectoryAtPath:versionDir withIntermediateDirectories:YES attributes:nil error:nil];

        // 3. Write the jar into the libraries directory (modelled on FCL OptiFineInstallTask / HMCL OptiFineInstallTask)
        // OptiFine uses launchwrapper as its entry point and is loaded through a tweaker, so the jar is no longer used as client.jar
        // but written as an ordinary library entry at libraries/optifine/OptiFine/{gameVersion}/{versionId}.jar
        // The reasons are:
        //   1. the vanilla client.jar can still be referenced through inheritsFrom (keeping the vanilla jar)
        //   2. the OptiFine jar becomes the tweakClass input for launchwrapper
        //   3. mainClass is set to net.minecraft.launchwrapper.Launcher and loaded via --tweakClass optifine.OptiFineTweaker
        NSString *optifineJarPath = [NSString stringWithFormat:@"optifine/OptiFine/%@/%@.jar", gameVersion, versionId];
        NSString *optifineJarAbsPath = [NSString stringWithFormat:@"%s/libraries/%@", getenv("POJAV_GAME_DIR"), optifineJarPath];
        // Make sure the jar is written to the correct libraries path
        NSString *jarDir = [optifineJarAbsPath stringByDeletingLastPathComponent];
        [[NSFileManager defaultManager] createDirectoryAtPath:jarDir withIntermediateDirectories:YES attributes:nil error:nil];
        NSError *writeError = nil;
        [jarData writeToFile:optifineJarAbsPath options:NSDataWritingAtomic error:&writeError];
        if (writeError) {
            NSError *err = [NSError errorWithDomain:@"OptiFineInstall" code:2 userInfo:@{NSLocalizedDescriptionKey: writeError.localizedDescription}];
            [[DownloadTaskManager sharedManager] setTaskWithId:taskId completedWithError:err];
            dispatch_async(dispatch_get_main_queue(), ^{
                __strong typeof(weakSelf) strongSelf = weakSelf;
                if (!strongSelf) return;
                [strongSelf finishInstallerProgressWithError:[NSString stringWithFormat:@"Failed to write the OptiFine jar: %@", writeError.localizedDescription]];
            });
            return;
        }

        // 4. Create version.json (modelled on FCL OptiFineInstallTask / HMCL OptiFineInstallTask)
        // OptiFine uses launchwrapper as its entry point and is loaded through a tweaker
        // Crucially: mainClass must be net.minecraft.launchwrapper.Launcher,
        //            --tweakClass optifine.OptiFineTweaker must be added,
        //            and the OptiFine jar must be in the libraries list
        NSDictionary *versionJson = @{
            @"id": versionId,
            @"inheritsFrom": gameVersion,
            @"type": @"release",
            @"mainClass": @"net.minecraft.launchwrapper.Launcher",
            @"minecraftArguments": @"--username ${auth_player_name} --version ${version_name} --gameDir ${game_directory} --assetsDir ${assets_root} --assetIndex ${assets_index_name} --uuid ${auth_uuid} --accessToken ${auth_access_token} --userType ${user_type} --versionType ${version_type} --tweakClass optifine.OptiFineTweaker",
            @"libraries": @[
                @{
                    @"name": [NSString stringWithFormat:@"optifine:OptiFine:%@", gameVersion],
                    @"downloads": @{
                        @"artifact": @{
                            @"path": optifineJarPath,
                            @"url": @"",  // Already downloaded, so the URL is left empty
                            @"size": @(jarData.length),
                            @"sha1": @""
                        }
                    }
                }
            ],
            @"jar": gameVersion,  // Use the vanilla jar
            @"minimumLauncherVersion": @21
        };
        NSString *jsonPath = [versionDir stringByAppendingPathComponent:[NSString stringWithFormat:@"%@.json", versionId]];
        NSData *jsonData = [NSJSONSerialization dataWithJSONObject:versionJson options:NSJSONWritingPrettyPrinted error:nil];
        [jsonData writeToFile:jsonPath options:NSDataWritingAtomic error:nil];

        // 4.1 Make sure the version JSON of the parent (vanilla) version exists
        NSString *parentJsonPath = [gameDir stringByAppendingPathComponent:
                                    [NSString stringWithFormat:@"versions/%@/%@.json", gameVersion, gameVersion]];
        if (![[NSFileManager defaultManager] fileExistsAtPath:parentJsonPath]) {
            // The parent version is missing, so tell the user to install vanilla first
            NSError *err = [NSError errorWithDomain:@"OptiFineInstall" code:3
                                         userInfo:@{NSLocalizedDescriptionKey: [NSString stringWithFormat:@"No version information found for vanilla %@. Install vanilla %@ from the download page first, then install OptiFine.", gameVersion, gameVersion]}];
            [[DownloadTaskManager sharedManager] setTaskWithId:taskId completedWithError:err];
            dispatch_async(dispatch_get_main_queue(), ^{
                __strong typeof(weakSelf) strongSelf = weakSelf;
                if (!strongSelf) return;
                [strongSelf finishInstallerProgressWithError:err.localizedDescription];
            });
            return;
        }

        [[DownloadTaskManager sharedManager] updateTaskWithId:taskId progress:0.85 totalBytes:-1 downloadedBytes:0];
        dispatch_async(dispatch_get_main_queue(), ^{
            __strong typeof(weakSelf) strongSelf = weakSelf;
            if (!strongSelf) return;
            strongSelf.installerProgressVC.progress = 0.85;
            strongSelf.installerProgressVC.stageMessage = @"Registering profile...";
        });

        // 5. Register the profile
        dispatch_async(dispatch_get_main_queue(), ^{
            __strong typeof(weakSelf) strongSelf = weakSelf;
            if (!strongSelf) return;

            NSMutableDictionary *profile = [NSMutableDictionary dictionary];
            profile[@"name"] = versionId;
            profile[@"lastVersionId"] = versionId;
            profile[@"gameDir"] = @".";
            profile[@"type"] = @"custom";
            profile[@"created"] = [NSDate date].description;
            [PLProfiles.current saveProfile:profile withName:versionId];
            PLProfiles.current.selectedProfileName = versionId;

            [[DownloadTaskManager sharedManager] setTaskWithId:taskId completedWithError:nil];
            [strongSelf finishInstallerProgressWithSuccess:[NSString stringWithFormat:@"OptiFine installed successfully\nVersion: %@\nProfile: %@", versionId, versionId]];
        });
    });
}

#pragma mark - NeoForge Installation

- (void)installNeoForge:(NSString *)gameVersion loaderVersion:(NSString *)loaderVersion {
    ForgeInstallViewController *neoForgeVC = [[ForgeInstallViewController alloc] init];
    neoForgeVC.gameVersion = gameVersion;
    neoForgeVC.isNeoForge = YES;
    // ModLoaderInstallViewController has already picked a version, which is passed in to skip the duplicate version list UI
    neoForgeVC.presetVersionString = loaderVersion;

    __weak typeof(self) weakSelf = self;
    void (^completion)(BOOL, NSString *, id) = ^(BOOL success, NSString *profileName, id resultOrError) {
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf) return;

        // Parse the callback result packed by ForgeInstallViewController (it has to be parsed either way)
        NSInteger selectedScheme = 0;
        NSString *filePath = nil;
        if ([resultOrError isKindOfClass:[NSDictionary class]]) {
            NSDictionary *result = (NSDictionary *)resultOrError;
            filePath = result[@"filePath"];
            selectedScheme = [result[@"selectedScheme"] integerValue];
        } else if ([resultOrError isKindOfClass:[NSString class]]) {
            filePath = (NSString *)resultOrError;
        }

        // Pop the NeoForge installer picker first and continue once the pop completes, so presenting/pushing does not fail mid-animation
        void (^continuation)(void) = ^{
            __strong typeof(weakSelf) strongSelf2 = weakSelf;
            if (!strongSelf2) return;

            if (!success) {
                [strongSelf2 handleInstallerDownloadResultWithVendorName:@"NeoForge"
                                                              gameVersion:gameVersion
                                                              profileName:profileName
                                                            resultOrError:resultOrError
                                                             installAction:nil];
                return;
            }

            if (selectedScheme == 1 && filePath.length > 0) {
                // Direct install: reuse or create the progress VC, driven by the progress callback of NeoForgeDirectInstaller
                NSLog(@"[NeoForgeDirect] DownloadViewController: starting direct install with progress UI");
                // Improvement 2 (following the unified progress flow of ZL2): reuse the progress VC handed over by the vanilla preinstall (if there is one)
                InstallerProgressViewController *progressVC = [strongSelf2 obtainInstallerProgressVC];
                progressVC.titleText = [NSString stringWithFormat:@"Preparing the runtime environment %@", gameVersion];
                progressVC.progress = 0.0;
                progressVC.stageMessage = @"Preparing...";
                // Phase 12 enhancement: NeoForge icon + stage list
                progressVC.categoryIconName = [ModLoaderIconHelper symbolNameForLoader:@"neoforge"];
                progressVC.categoryIconColor = [ModLoaderIconHelper brandColorForLoader:@"neoforge"];
                // Merged step list: the 5 vanilla steps marked complete + the NeoForge install steps
                progressVC.stageSteps = @[
                    @{@"title": @"Fetch version manifest", @"status": @2},
                    @{@"title": @"Download version JSON", @"status": @2},
                    @{@"title": @"Download game libraries", @"status": @2},
                    @{@"title": @"Download asset files", @"status": @2},
                    @{@"title": @"Verify file integrity", @"status": @2},
                    @{@"title": @"Parse installer JAR", @"status": @1},
                    @{@"title": @"Download NeoForge libraries", @"status": @0},
                    @{@"title": @"Write version JSON", @"status": @0},
                ];
                // Note: obtainInstallerProgressVC already pushes it on creation, so a reused VC is not pushed again

                dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
                    NSError *directError = nil;
                    BOOL installed = [NeoForgeDirectInstaller installNeoForgeFromInstaller:filePath
                                                                                   versionId:profileName
                                                                                    progress:^(double progress, NSString *stageMessage) {
                        dispatch_async(dispatch_get_main_queue(), ^{
                            __strong typeof(weakSelf) strongSelf3 = weakSelf;
                            if (!strongSelf3 || !strongSelf3.installerProgressVC) return;
                            strongSelf3.installerProgressVC.progress = progress;
                            NSString *stage = stageMessage ?: @"";
                            strongSelf3.installerProgressVC.stageMessage = [NSString stringWithFormat:@"%@ - %.0f%%", stage, progress * 100];
                        });
                    }
                                                                                       error:&directError];

                    dispatch_async(dispatch_get_main_queue(), ^{
                        __strong typeof(weakSelf) strongSelf3 = weakSelf;
                        if (!strongSelf3) return;
                        if (installed) {
                            [strongSelf3 finishInstallerProgressWithSuccess:[NSString stringWithFormat:@"Direct NeoForge install succeeded\nProfile: %@", profileName ?: gameVersion]];
                        } else {
                            [strongSelf3 finishInstallerProgressWithError:[NSString stringWithFormat:@"Direct NeoForge install failed: %@", directError.localizedDescription ?: @"Unknown error"]];
                        }
                    });
                });
                return;
            }

            // Vanilla method (running the installer)
            [strongSelf2 handleInstallerDownloadResultWithVendorName:@"NeoForge"
                                                          gameVersion:gameVersion
                                                          profileName:profileName
                                                        resultOrError:resultOrError
                                                         installAction:^{
                [strongSelf2 showSuccessMessage:[NSString stringWithFormat:@"NeoForge installer started\nProfile: %@", profileName ?: gameVersion]];
            }];
        };

        if (strongSelf.navigationController.topViewController != strongSelf) {
            [strongSelf.navigationController popViewControllerAnimated:YES];
            // Wait for the pop animation to finish before presenting/pushing, to avoid animation conflicts
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.35 * NSEC_PER_SEC)), dispatch_get_main_queue(), continuation);
        } else {
            continuation();
        }
    };
    neoForgeVC.completionHandler = completion;

    // Push straight into the middle content area rather than presenting a FormSheet
    [self.navigationController pushViewController:neoForgeVC animated:YES];
}

- (void)showSuccessMessage:(NSString *)message {
    // Show the success message in the content area instead of an alert
    [InlineMessageView showInViewController:self
                                       title:@"Installation successful"
                                    message:message
                                       type:InlineMessageTypeSuccess];
}

#pragma mark - Mod Download Helper (Shared)

- (void)downloadModVersion:(ModVersion *)version modInfo:(NSDictionary *)modInfo completion:(void (^)(BOOL success, NSError *error))completion {
    NSString *downloadURL = version.primaryFile[@"url"];
    NSString *filename = version.primaryFile[@"filename"];
    
    if (!downloadURL || downloadURL.length == 0) {
        if (completion) completion(NO, [NSError errorWithDomain:@"DownloadError" code:4 userInfo:@{NSLocalizedDescriptionKey: @"Invalid download link"}]);
        return;
    }
    
    NSString *modsDir = [self currentInstanceModsPath];
    NSString *savePath = [modsDir stringByAppendingPathComponent:filename];
    
    NSURL *url = [NSURL URLWithString:downloadURL];
    NSURLSessionDownloadTask *downloadTask = [[NSURLSession sharedSession] downloadTaskWithURL:url completionHandler:^(NSURL *location, NSURLResponse *response, NSError *error) {
        if (error || !location) {
            if (completion) completion(NO, error);
            return;
        }
        
        [[NSFileManager defaultManager] removeItemAtPath:savePath error:nil];
        NSError *moveError;
        [[NSFileManager defaultManager] moveItemAtPath:location.path toPath:savePath error:&moveError];
        
        if (completion) completion(moveError == nil, moveError);
    }];
    
    [downloadTask resume];
}

#pragma mark - Modpack Installation

- (void)openImportModpackView {
    // Fix: push into the middle content area, consistent with the other download sub-flows, instead of presenting a FormSheet
    ModpackImportViewController *importVC = [[ModpackImportViewController alloc] init];
    [self.navigationController pushViewController:importVC animated:YES];
}

- (void)installModpack:(UIButton *)sender {
    NSIndexPath *indexPath = [NSIndexPath indexPathForRow:sender.tag inSection:0];
    [self installModpackAtIndexPath:indexPath];
}

- (void)installModpackAtIndexPath:(NSIndexPath *)indexPath {
    NSDictionary *modpack = self.modpackList[indexPath.row];

    // Mirroring FCL/ZL2: modpacks also get their own version picker page (reusing ModVersionViewController + AssetDetailHeaderView)
    // replacing the old ActionSheet version picker and adding the project cover image, description, author, downloads and tags
    ModItem *modItem = [[ModItem alloc] initWithOnlineData:modpack];

    ModVersionViewController *versionVC = [[ModVersionViewController alloc] init];
    versionVC.modItem = modItem;
    versionVC.delegate = self;
    versionVC.title = modItem.displayName;
    // FCL style: pass in the preferred version and loader of the current profile, so the matching chip is selected and pinned to the top
    versionVC.preferredGameVersion = [self currentProfileMinecraftVersion];
    versionVC.preferredLoader = [self currentProfileLoader];

    // Mark this as a modpack download, so the version callback runs the modpack install flow (rather than the mod download flow)
    self.pendingDownloadType = @"modpack";
    self.pendingModpackDict = modpack;

    // Push it into the middle content area, matching the interaction of mods/shaders/resource packs
    [self.navigationController pushViewController:versionVC animated:YES];
}

- (void)startModpackInstallation:(ModVersion *)version modpack:(NSDictionary *)modpack {
    NSString *downloadURL = version.primaryFile[@"url"];
    if (!downloadURL) {
        [self showError:@"Invalid download link"];
        return;
    }

    // Fix: push a progress VC (FCL style) instead of a spinner alert
    InstallerProgressViewController *progressVC = [[InstallerProgressViewController alloc] init];
    progressVC.titleText = [NSString stringWithFormat:@"Downloading modpack %@", modpack[@"title"] ?: @""];
    progressVC.progress = -1;
    progressVC.stageMessage = @"Downloading modpack files...";
    // Phase 12 enhancement: modpack icon + stage list (modelled on the FCL modpack install flow)
    progressVC.categoryIconName = @"archivebox.fill";
    progressVC.categoryIconColor = [UIColor systemOrangeColor];
    progressVC.stageSteps = @[
        @{@"title": @"Download modpack files", @"status": @1},
        @{@"title": @"Parse modpack structure", @"status": @0},
        @{@"title": @"Install vanilla Minecraft", @"status": @0},
        @{@"title": @"Download mod files", @"status": @0},
        @{@"title": @"Install mod loader", @"status": @0},
        @{@"title": @"Write profile", @"status": @0},
    ];
    [self.navigationController pushViewController:progressVC animated:YES];

    NSURL *url = [NSURL URLWithString:downloadURL];
    NSString *downloadSource = getPrefObject(@"general.download_source") ?: @"official";
    __block DownloadTaskItem *taskItem = nil;

    // Key fix (following the modpack download resilience of FCL/ZL2): the original implementation downloaded once with no retry,
    // so a brief network hiccup or a 5xx from a mirror failed the whole modpack download. It now retries up to 3 times.
    __block NSInteger downloadAttempt = 0;
    __block NSURL *downloadLocation = nil;
    __block NSError *downloadError = nil;
    __weak typeof(self) weakSelf = self;

    void (^attemptDownload)(void) = ^{
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf) return;
        downloadAttempt++;
        NSLog(@"[ModpackDownload] Modpack download attempt %ld: %@", (long)downloadAttempt, downloadURL);
        NSURLSessionDownloadTask *task = [[NSURLSession sharedSession] downloadTaskWithURL:url completionHandler:^(NSURL *location, NSURLResponse *response, NSError *error) {
            dispatch_async(dispatch_get_main_queue(), ^{
                __strong typeof(weakSelf) strongSelf2 = weakSelf;
                if (!strongSelf2) return;
                if (error || !location) {
                    downloadError = error ?: [NSError errorWithDomain:@"DownloadError" code:1 userInfo:@{NSLocalizedDescriptionKey: @"Download returned empty data"}];
                    NSLog(@"[ModpackDownload] Attempt %ld failed: %@", (long)downloadAttempt, downloadError.localizedDescription);
                    if (downloadAttempt < 3) {
                        // Retry after 1.5s, so back-to-back requests do not trip rate limiting
                        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                            attemptDownload();
                        });
                    } else {
                        [[DownloadTaskManager sharedManager] setTaskWithId:taskItem.taskId completedWithError:downloadError];
                        [strongSelf2.navigationController popViewControllerAnimated:YES];
                        [strongSelf2 showError:[NSString stringWithFormat:@"Modpack download failed (retried %ld times): %@", (long)downloadAttempt, downloadError.localizedDescription ?: @"Unknown error"]];
                    }
                    return;
                }
                downloadLocation = location;
                downloadError = nil;

                // Move it to a temporary file
                NSString *tempPath = [NSTemporaryDirectory() stringByAppendingPathComponent:[NSString stringWithFormat:@"%@_%@.mrpack", modpack[@"id"] ?: @"modpack", [[NSUUID UUID] UUIDString]]];
                [[NSFileManager defaultManager] removeItemAtPath:tempPath error:nil];
                NSError *moveError = nil;
                [[NSFileManager defaultManager] moveItemAtPath:downloadLocation.path toPath:tempPath error:&moveError];
                if (moveError) {
                    if (downloadAttempt < 3) {
                        NSLog(@"[ModpackDownload] File move failed, retrying: %@", moveError.localizedDescription);
                        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                            attemptDownload();
                        });
                        return;
                    }
                    [[DownloadTaskManager sharedManager] setTaskWithId:taskItem.taskId completedWithError:moveError];
                    [strongSelf2.navigationController popViewControllerAnimated:YES];
                    [strongSelf2 showError:moveError.localizedDescription];
                    return;
                }

                [[DownloadTaskManager sharedManager] setTaskWithId:taskItem.taskId completedWithError:nil];

                // Reuse ModpackImportService to parse and import it
                progressVC.progress = 0.1;
                progressVC.stageMessage = @"Parsing modpack...";
                // Phase 12 enhancement: update the step state (download complete, parsing)
                progressVC.stageSteps = @[
                    @{@"title": @"Download modpack files", @"status": @2},
                    @{@"title": @"Parse modpack structure", @"status": @1},
                    @{@"title": @"Install vanilla Minecraft", @"status": @0},
                    @{@"title": @"Download mod files", @"status": @0},
                    @{@"title": @"Install mod loader", @"status": @0},
                    @{@"title": @"Write profile", @"status": @0},
                ];
                ModpackImportService *importService = [[ModpackImportService alloc] init];
            dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
                NSError *parseError = nil;
                NSDictionary *modpackInfo = [importService parseModpackAtURL:[NSURL fileURLWithPath:tempPath] error:&parseError];
                if (!modpackInfo) {
                    dispatch_async(dispatch_get_main_queue(), ^{
                        [self.navigationController popViewControllerAnimated:YES];
                        [self showError:parseError.localizedDescription ?: @"Failed to parse the modpack"];
                    });
                    return;
                }
                // Fill in the online modpack information (title, icon, etc.)
                NSMutableDictionary *mutableInfo = [modpackInfo mutableCopy];
                if (!mutableInfo[@"name"] || [mutableInfo[@"name"] isEqualToString:[tempPath.lastPathComponent stringByDeletingPathExtension]]) {
                    mutableInfo[@"name"] = modpack[@"title"] ?: mutableInfo[@"name"];
                }
                if (modpack[@"imageUrl"]) {
                    // Do not force the icon to download; keep the one inside the modpack
                }

                // Phase 14 enhancement: following FCL/ZL2/HMCL, install the matching vanilla Minecraft before installing the modpack
                // ModpackImportService only downloads mod files and installs the loader; it does not fetch the vanilla client.jar/libraries/assets
                // Without the vanilla preinstall, the Java side Tools.getVersionInfo() crashes with FileNotFoundException at launch
                NSString *mcVersion = mutableInfo[@"minecraftVersion"];
                if (![mcVersion isKindOfClass:[NSString class]] || mcVersion.length == 0) {
                    mcVersion = mutableInfo[@"dependencies"][@"minecraft"];
                }
                if ([mcVersion isKindOfClass:[NSString class]] && mcVersion.length > 0) {
                    dispatch_async(dispatch_get_main_queue(), ^{
                        // Update the progress: parsing done, about to install vanilla
                        progressVC.stageSteps = @[
                            @{@"title": @"Download modpack files", @"status": @2},
                            @{@"title": @"Parse modpack structure", @"status": @2},
                            @{@"title": @"Install vanilla Minecraft", @"status": @1},
                            @{@"title": @"Download mod files", @"status": @0},
                            @{@"title": @"Install mod loader", @"status": @0},
                            @{@"title": @"Write profile", @"status": @0},
                        ];
                        progressVC.stageMessage = [NSString stringWithFormat:@"Installing vanilla Minecraft %@...", mcVersion];

                        // Run the vanilla preinstall (ensureVanillaInstalled checks whether it is already installed and skips if so)
                        NSDictionary *vanillaVersion = @{@"id": mcVersion};
                        __weak typeof(self) weakSelf = self;
                        [self ensureVanillaInstalled:vanillaVersion completion:^(BOOL vanillaSuccess) {
                            __strong typeof(weakSelf) strongSelf = weakSelf;
                            if (!strongSelf) return;
                            if (!vanillaSuccess) {
                                dispatch_async(dispatch_get_main_queue(), ^{
                                    [strongSelf.navigationController popViewControllerAnimated:YES];
                                    [strongSelf showError:[NSString stringWithFormat:@"Could not install vanilla %@. Check your network connection and try again", mcVersion]];
                                });
                                return;
                            }
                            // Vanilla installed, so continue importing the modpack
                            dispatch_async(dispatch_get_main_queue(), ^{
                                progressVC.stageSteps = @[
                                    @{@"title": @"Download modpack files", @"status": @2},
                                    @{@"title": @"Parse modpack structure", @"status": @2},
                                    @{@"title": @"Install vanilla Minecraft", @"status": @2},
                                    @{@"title": @"Download mod files", @"status": @1},
                                    @{@"title": @"Install mod loader", @"status": @0},
                                    @{@"title": @"Write profile", @"status": @0},
                                ];
                                progressVC.stageMessage = @"Downloading mod files...";
                            });
                            // Run the modpack import on a background thread
                            dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
                                [strongSelf importModpackWithService:importService info:mutableInfo progressVC:progressVC tempPath:tempPath];
                            });
                        }];
                    });
                } else {
                    // The game version could not be determined, so skip the vanilla preinstall and import directly
                    dispatch_async(dispatch_get_main_queue(), ^{
                        progressVC.stageMessage = @"No game version detected, skipping the vanilla install and importing the modpack...";
                        progressVC.stageSteps = @[
                            @{@"title": @"Download modpack files", @"status": @2},
                            @{@"title": @"Parse modpack structure", @"status": @2},
                            @{@"title": @"Install vanilla Minecraft", @"status": @2},
                            @{@"title": @"Download mod files", @"status": @1},
                            @{@"title": @"Install mod loader", @"status": @0},
                            @{@"title": @"Write profile", @"status": @0},
                        ];
                    });
                    [self importModpackWithService:importService info:mutableInfo progressVC:progressVC tempPath:tempPath];
                }
            });
        });
    }];

        // Register with the download task manager (re-registered on every retry; taskId stays the same because taskItem is a __block in the outer scope)
        if (!taskItem) {
            taskItem = [[DownloadTaskManager sharedManager]
                registerTaskWithResourceType:DownloadTaskResourceTypeModpack
                                resourceName:modpack[@"title"] ?: @"modpack"
                                 displayName:modpack[@"title"] ?: @"Modpack"
                              downloadSource:downloadSource
                                     rawTask:task
                              supportsResume:YES
                                     iconURL:modpack[@"imageUrl"]];
            [[DownloadTaskManager sharedManager] setTaskWithId:taskItem.taskId state:DownloadTaskStateDownloading];
        }

        [task resume];
    };

    // Start the first download attempt
    attemptDownload();
}

/// Phase 14: modpack import helper method
/// Following FCL/ZL2/HMCL: run the actual modpack import once the vanilla preinstall finishes (or is skipped).
/// This calls ModpackImportService to download the mod files, install the loader and write the profile,
/// showing the 6 steps live through progressVC (with the vanilla install step marked complete).
/// Temporary files are cleaned up afterwards and the success/failure result is shown on the main thread.
/// Note: this must be called on a background thread (QOS_CLASS_USER_INITIATED); the progress callbacks dispatch to the main thread themselves.
- (void)importModpackWithService:(ModpackImportService *)importService
                            info:(NSDictionary *)info
                      progressVC:(InstallerProgressViewController *)progressVC
                        tempPath:(NSString *)tempPath {
    NSError *importError = nil;
    __weak typeof(self) weakSelf = self;
    BOOL success = [importService importModpack:info
                                       progress:^(double p, NSString *stage) {
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf) return;
        dispatch_async(dispatch_get_main_queue(), ^{
            progressVC.progress = p;
            progressVC.stageMessage = stage;
            // Phase 14 enhancement: a 6-step progress list (with "Install vanilla Minecraft" marked complete)
            // ModpackImportService progress ranges: 0.1-0.3 = downloading mods, 0.3-0.7 = installing the loader, 0.7-1.0 = writing the profile
            NSArray *steps;
            if (p < 0.3) {
                steps = @[
                    @{@"title": @"Download modpack files", @"status": @2},
                    @{@"title": @"Parse modpack structure", @"status": @2},
                    @{@"title": @"Install vanilla Minecraft", @"status": @2},
                    @{@"title": @"Download mod files", @"status": @1},
                    @{@"title": @"Install mod loader", @"status": @0},
                    @{@"title": @"Write profile", @"status": @0},
                ];
            } else if (p < 0.7) {
                steps = @[
                    @{@"title": @"Download modpack files", @"status": @2},
                    @{@"title": @"Parse modpack structure", @"status": @2},
                    @{@"title": @"Install vanilla Minecraft", @"status": @2},
                    @{@"title": @"Download mod files", @"status": @2},
                    @{@"title": @"Install mod loader", @"status": @1},
                    @{@"title": @"Write profile", @"status": @0},
                ];
            } else if (p < 1.0) {
                steps = @[
                    @{@"title": @"Download modpack files", @"status": @2},
                    @{@"title": @"Parse modpack structure", @"status": @2},
                    @{@"title": @"Install vanilla Minecraft", @"status": @2},
                    @{@"title": @"Download mod files", @"status": @2},
                    @{@"title": @"Install mod loader", @"status": @2},
                    @{@"title": @"Write profile", @"status": @1},
                ];
            } else {
                steps = @[
                    @{@"title": @"Download modpack files", @"status": @2},
                    @{@"title": @"Parse modpack structure", @"status": @2},
                    @{@"title": @"Install vanilla Minecraft", @"status": @2},
                    @{@"title": @"Download mod files", @"status": @2},
                    @{@"title": @"Install mod loader", @"status": @2},
                    @{@"title": @"Write profile", @"status": @2},
                ];
            }
            progressVC.stageSteps = steps;
        });
    } error:&importError];

    // Clean up the temporary files
    [[NSFileManager defaultManager] removeItemAtPath:tempPath error:nil];

    dispatch_async(dispatch_get_main_queue(), ^{
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf) return;
        if (success) {
            progressVC.progress = 1.0;
            progressVC.stageMessage = @"Installation complete";
            progressVC.stageSteps = @[
                @{@"title": @"Download modpack files", @"status": @2},
                @{@"title": @"Parse modpack structure", @"status": @2},
                @{@"title": @"Install vanilla Minecraft", @"status": @2},
                @{@"title": @"Download mod files", @"status": @2},
                @{@"title": @"Install mod loader", @"status": @2},
                @{@"title": @"Write profile", @"status": @2},
            ];
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.8 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                __strong typeof(weakSelf) s = weakSelf;
                if (!s) return;
                [s.navigationController popViewControllerAnimated:YES];
                NSString *loader = info[@"loader"];
                NSString *msg = [NSString stringWithFormat:@"Modpack %@ installed", info[@"name"]];
                if ([loader isEqualToString:@"Forge"] || [loader isEqualToString:@"NeoForge"]) {
                    msg = [msg stringByAppendingFormat:@"\n\nNote: this modpack uses the %@ %@ loader. Please install that loader version manually from the download screen first.", loader, info[@"loaderVersion"]];
                }
                [s showSuccessMessage:msg];
            });
        } else {
            [strongSelf.navigationController popViewControllerAnimated:YES];
            [strongSelf showError:importError.localizedDescription ?: @"Import failed"];
        }
    });
}

- (void)installModpackFromFile:(NSString *)filePath modpack:(NSDictionary *)modpack {
    // Fix: this method is deprecated; the online download flow now uses startModpackInstallation:modpack: and goes through ModpackImportService
    // Kept in case something else calls it, but it goes through ModpackImportService internally too
    InstallerProgressViewController *progressVC = [[InstallerProgressViewController alloc] init];
    progressVC.titleText = @"Importing modpack";
    progressVC.progress = -1;
    progressVC.stageMessage = @"Parsing modpack...";
    // Phase 12 enhancement: modpack import icon + stage list
    progressVC.categoryIconName = @"archivebox.fill";
    progressVC.categoryIconColor = [UIColor systemOrangeColor];
    progressVC.stageSteps = @[
        @{@"title": @"Parse modpack structure", @"status": @1},
        @{@"title": @"Download mod files", @"status": @0},
        @{@"title": @"Install mod loader", @"status": @0},
        @{@"title": @"Write profile", @"status": @0},
    ];
    [self.navigationController pushViewController:progressVC animated:YES];

    ModpackImportService *importService = [[ModpackImportService alloc] init];
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSError *parseError = nil;
        NSDictionary *modpackInfo = [importService parseModpackAtURL:[NSURL fileURLWithPath:filePath] error:&parseError];
        if (!modpackInfo) {
            dispatch_async(dispatch_get_main_queue(), ^{
                [self.navigationController popViewControllerAnimated:YES];
                [self showError:parseError.localizedDescription ?: @"Parse failed"];
            });
            return;
        }
        NSError *importError = nil;
        BOOL success = [importService importModpack:modpackInfo
                                           progress:^(double p, NSString *stage) {
            dispatch_async(dispatch_get_main_queue(), ^{
                progressVC.progress = p;
                progressVC.stageMessage = stage;
                // Phase 12 enhancement: update the step state as the progress advances
                NSArray *steps;
                if (p < 0.3) {
                    steps = @[
                        @{@"title": @"Parse modpack structure", @"status": @2},
                        @{@"title": @"Download mod files", @"status": @1},
                        @{@"title": @"Install mod loader", @"status": @0},
                        @{@"title": @"Write profile", @"status": @0},
                    ];
                } else if (p < 0.7) {
                    steps = @[
                        @{@"title": @"Parse modpack structure", @"status": @2},
                        @{@"title": @"Download mod files", @"status": @2},
                        @{@"title": @"Install mod loader", @"status": @1},
                        @{@"title": @"Write profile", @"status": @0},
                    ];
                } else if (p < 1.0) {
                    steps = @[
                        @{@"title": @"Parse modpack structure", @"status": @2},
                        @{@"title": @"Download mod files", @"status": @2},
                        @{@"title": @"Install mod loader", @"status": @2},
                        @{@"title": @"Write profile", @"status": @1},
                    ];
                } else {
                    steps = @[
                        @{@"title": @"Parse modpack structure", @"status": @2},
                        @{@"title": @"Download mod files", @"status": @2},
                        @{@"title": @"Install mod loader", @"status": @2},
                        @{@"title": @"Write profile", @"status": @2},
                    ];
                }
                progressVC.stageSteps = steps;
            });
        } error:&importError];
        dispatch_async(dispatch_get_main_queue(), ^{
            if (success) {
                progressVC.progress = 1.0;
                progressVC.stageMessage = @"Import complete";
                progressVC.stageSteps = @[
                    @{@"title": @"Parse modpack structure", @"status": @2},
                    @{@"title": @"Download mod files", @"status": @2},
                    @{@"title": @"Install mod loader", @"status": @2},
                    @{@"title": @"Write profile", @"status": @2},
                ];
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.8 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                    [self.navigationController popViewControllerAnimated:YES];
                    [self showSuccessMessage:[NSString stringWithFormat:@"Modpack %@ imported", modpackInfo[@"name"]]];
                });
            } else {
                [self.navigationController popViewControllerAnimated:YES];
                [self showError:importError.localizedDescription ?: @"Import failed"];
            }
        });
    });
}

#pragma mark - UITableView DataSource

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    if (tableView == self.modTableView) {
        return self.modList.count + (self.hasMoreMods ? 1 : 0);
    } else if (tableView == self.shaderTableView) {
        return self.shaderList.count + (self.hasMoreShaders ? 1 : 0);
    } else if (tableView == self.modpackTableView) {
        return self.modpackList.count + (self.hasMoreModpacks ? 1 : 0);
    } else if (tableView == self.resourcepackTableView) {
        return self.resourcepackList.count + (self.hasMoreResourcepacks ? 1 : 0);
    } else if (tableView == self.datapackTableView) {
        return self.datapackList.count + (self.hasMoreDatapacks ? 1 : 0);
    } else if (tableView == self.worldTableView) {
        return self.worldList.count + (self.hasMoreWorlds ? 1 : 0);
    }
    return 0;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    if (tableView == self.modTableView && indexPath.row == self.modList.count && self.hasMoreMods) {
        UITableViewCell *cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:@"LoadingCell"];
        cell.textLabel.text = @"Load more...";
        cell.textLabel.textAlignment = NSTextAlignmentCenter;
        cell.textLabel.textColor = [UIColor secondaryLabelColor];
        cell.backgroundColor = [UIColor clearColor];
        return cell;
    }

    if (tableView == self.shaderTableView && indexPath.row == self.shaderList.count && self.hasMoreShaders) {
        UITableViewCell *cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:@"LoadingCell"];
        cell.textLabel.text = @"Load more...";
        cell.textLabel.textAlignment = NSTextAlignmentCenter;
        cell.textLabel.textColor = [UIColor secondaryLabelColor];
        cell.backgroundColor = [UIColor clearColor];
        return cell;
    }

    if (tableView == self.modpackTableView && indexPath.row == self.modpackList.count && self.hasMoreModpacks) {
        UITableViewCell *cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:@"LoadingCell"];
        cell.textLabel.text = @"Load more...";
        cell.textLabel.textAlignment = NSTextAlignmentCenter;
        cell.textLabel.textColor = [UIColor secondaryLabelColor];
        cell.backgroundColor = [UIColor clearColor];
        return cell;
    }

    if (tableView == self.resourcepackTableView && indexPath.row == self.resourcepackList.count && self.hasMoreResourcepacks) {
        UITableViewCell *cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:@"LoadingCell"];
        cell.textLabel.text = @"Load more...";
        cell.textLabel.textAlignment = NSTextAlignmentCenter;
        cell.textLabel.textColor = [UIColor secondaryLabelColor];
        cell.backgroundColor = [UIColor clearColor];
        return cell;
    }

    if (tableView == self.datapackTableView && indexPath.row == self.datapackList.count && self.hasMoreDatapacks) {
        UITableViewCell *cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:@"LoadingCell"];
        cell.textLabel.text = @"Load more...";
        cell.textLabel.textAlignment = NSTextAlignmentCenter;
        cell.textLabel.textColor = [UIColor secondaryLabelColor];
        cell.backgroundColor = [UIColor clearColor];
        return cell;
    }

    if (tableView == self.worldTableView && indexPath.row == self.worldList.count && self.hasMoreWorlds) {
        UITableViewCell *cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:@"LoadingCell"];
        cell.textLabel.text = @"Load more...";
        cell.textLabel.textAlignment = NSTextAlignmentCenter;
        cell.textLabel.textColor = [UIColor secondaryLabelColor];
        cell.backgroundColor = [UIColor clearColor];
        return cell;
    }

    ModernAssetCell *cell;
    if (tableView == self.modTableView) {
        cell = [tableView dequeueReusableCellWithIdentifier:@"ModCell" forIndexPath:indexPath];
        NSDictionary *mod = self.modList[indexPath.row];
        [cell configureWithMod:mod];
        [cell.downloadButton addTarget:self action:@selector(downloadMod:) forControlEvents:UIControlEventTouchUpInside];
        cell.downloadButton.tag = indexPath.row;
    } else if (tableView == self.shaderTableView) {
        cell = [tableView dequeueReusableCellWithIdentifier:@"ShaderCell" forIndexPath:indexPath];
        NSDictionary *shader = self.shaderList[indexPath.row];
        [cell configureWithShader:shader];
        [cell.downloadButton addTarget:self action:@selector(downloadShader:) forControlEvents:UIControlEventTouchUpInside];
        cell.downloadButton.tag = indexPath.row;
    } else if (tableView == self.resourcepackTableView) {
        cell = [tableView dequeueReusableCellWithIdentifier:@"ResourcepackCell" forIndexPath:indexPath];
        NSDictionary *resourcepack = self.resourcepackList[indexPath.row];
        [cell configureWithResourcepack:resourcepack];
        [cell.downloadButton addTarget:self action:@selector(downloadResourcepack:) forControlEvents:UIControlEventTouchUpInside];
        cell.downloadButton.tag = indexPath.row;
    } else if (tableView == self.datapackTableView) {
        cell = [tableView dequeueReusableCellWithIdentifier:@"DatapackCell" forIndexPath:indexPath];
        NSDictionary *datapack = self.datapackList[indexPath.row];
        [cell configureWithDatapack:datapack];
        [cell.downloadButton addTarget:self action:@selector(downloadDatapack:) forControlEvents:UIControlEventTouchUpInside];
        cell.downloadButton.tag = indexPath.row;
    } else if (tableView == self.worldTableView) {
        cell = [tableView dequeueReusableCellWithIdentifier:@"WorldCell" forIndexPath:indexPath];
        NSDictionary *world = self.worldList[indexPath.row];
        [cell configureWithWorld:world];
        [cell.downloadButton addTarget:self action:@selector(downloadWorld:) forControlEvents:UIControlEventTouchUpInside];
        cell.downloadButton.tag = indexPath.row;
    } else {
        cell = [tableView dequeueReusableCellWithIdentifier:@"ModpackCell" forIndexPath:indexPath];
        NSDictionary *modpack = self.modpackList[indexPath.row];
        [cell configureWithModpack:modpack];
        [cell.downloadButton addTarget:self action:@selector(installModpack:) forControlEvents:UIControlEventTouchUpInside];
        cell.downloadButton.tag = indexPath.row;
    }
    return cell;
}

- (void)tableView:(UITableView *)tableView willDisplayCell:(UITableViewCell *)cell forRowAtIndexPath:(NSIndexPath *)indexPath {
    if (tableView == self.modTableView && indexPath.row == self.modList.count - 5 && self.hasMoreMods && !self.isLoadingMore) {
        [self loadModList];
    }

    if (tableView == self.shaderTableView && indexPath.row == self.shaderList.count - 5 && self.hasMoreShaders && !self.isLoadingMore) {
        [self loadShaderList];
    }

    if (tableView == self.modpackTableView && indexPath.row == self.modpackList.count - 5 && self.hasMoreModpacks && !self.isLoadingModpacks) {
        [self loadModpackList];
    }

    if (tableView == self.resourcepackTableView && indexPath.row == self.resourcepackList.count - 5 && self.hasMoreResourcepacks && !self.isLoadingResourcepacks) {
        [self loadResourcePackList];
    }

    if (tableView == self.datapackTableView && indexPath.row == self.datapackList.count - 5 && self.hasMoreDatapacks && !self.isLoadingDatapacks) {
        [self loadDataPackList];
    }

    if (tableView == self.worldTableView && indexPath.row == self.worldList.count - 5 && self.hasMoreWorlds && !self.isLoadingWorlds) {
        [self loadWorldList];
    }

    // ===== Icon prefetching (modelled on FCL Glide prefetch + ZL2 Coil enqueue) =====
    // When a cell is about to appear, prefetch the icons of the next 5 cells into the disk cache.
    // As the user scrolls, those icons are already cached and appear instantly, which greatly reduces the "icons load too slowly" feeling.
    // Prefetching only downloads and caches; it does not bind to an imageView and does not affect what is on screen.
    [self prefetchIconsForTableView:tableView currentIndex:indexPath.row];
}

/// Prefetch the icons of the upcoming cells into the cache
/// @param tableView The current tableView
/// @param currentIndex Index of the cell being shown
- (void)prefetchIconsForTableView:(UITableView *)tableView currentIndex:(NSInteger)currentIndex {
    // Prefetch the icons of the next 5 cells
    NSInteger prefetchCount = 5;
    NSInteger startIndex = currentIndex + 1;
    NSInteger endIndex = currentIndex + prefetchCount;

    for (NSInteger row = startIndex; row <= endIndex; row++) {
        NSString *iconUrl = nil;

        if (tableView == self.modTableView && row < (NSInteger)self.modList.count) {
            NSDictionary *mod = self.modList[row];
            iconUrl = mod[@"imageUrl"] ?: mod[@"icon_url"];
        } else if (tableView == self.shaderTableView && row < (NSInteger)self.shaderList.count) {
            NSDictionary *shader = self.shaderList[row];
            iconUrl = shader[@"imageUrl"] ?: shader[@"icon_url"];
        } else if (tableView == self.modpackTableView && row < (NSInteger)self.modpackList.count) {
            NSDictionary *modpack = self.modpackList[row];
            iconUrl = modpack[@"imageUrl"] ?: modpack[@"icon_url"];
        } else if (tableView == self.resourcepackTableView && row < (NSInteger)self.resourcepackList.count) {
            NSDictionary *resourcepack = self.resourcepackList[row];
            iconUrl = resourcepack[@"imageUrl"] ?: resourcepack[@"icon_url"];
        } else if (tableView == self.datapackTableView && row < (NSInteger)self.datapackList.count) {
            NSDictionary *datapack = self.datapackList[row];
            iconUrl = datapack[@"imageUrl"] ?: datapack[@"icon_url"];
        } else if (tableView == self.worldTableView && row < (NSInteger)self.worldList.count) {
            NSDictionary *world = self.worldList[row];
            iconUrl = world[@"imageUrl"] ?: world[@"icon_url"];
        }

        if (iconUrl && iconUrl.length > 0) {
            [IconLoader prefetchIconWithURL:iconUrl targetSize:CGSizeMake(56, 56)];
        }
    }
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];

    if (tableView == self.modTableView) {
        if (indexPath.row == self.modList.count && self.hasMoreMods) {
            [self loadModList];
            return;
        }
        [self downloadModAtIndexPath:indexPath];
    } else if (tableView == self.shaderTableView) {
        if (indexPath.row == self.shaderList.count && self.hasMoreShaders) {
            [self loadShaderList];
            return;
        }
        [self downloadShaderAtIndexPath:indexPath];
    } else if (tableView == self.resourcepackTableView) {
        if (indexPath.row == self.resourcepackList.count && self.hasMoreResourcepacks) {
            [self loadResourcePackList];
            return;
        }
        [self downloadResourcepackAtIndexPath:indexPath];
    } else if (tableView == self.datapackTableView) {
        if (indexPath.row == self.datapackList.count && self.hasMoreDatapacks) {
            [self loadDataPackList];
            return;
        }
        [self downloadDatapackAtIndexPath:indexPath];
    } else if (tableView == self.worldTableView) {
        if (indexPath.row == self.worldList.count && self.hasMoreWorlds) {
            [self loadWorldList];
            return;
        }
        [self downloadWorldAtIndexPath:indexPath];
    } else if (tableView == self.modpackTableView) {
        if (indexPath.row == self.modpackList.count && self.hasMoreModpacks) {
            [self loadModpackList];
            return;
        }
        [self installModpackAtIndexPath:indexPath];
    }
}

#pragma mark - Download Actions

- (void)downloadMod:(UIButton *)sender {
    NSIndexPath *indexPath = [NSIndexPath indexPathForRow:sender.tag inSection:0];
    [self downloadModAtIndexPath:indexPath];
}

- (void)downloadModAtIndexPath:(NSIndexPath *)indexPath {
    if (indexPath.row >= self.modList.count) return;

    NSDictionary *mod = self.modList[indexPath.row];
    ModItem *modItem = [[ModItem alloc] initWithOnlineData:mod];

    ModVersionViewController *versionVC = [[ModVersionViewController alloc] init];
    versionVC.modItem = modItem;
    versionVC.delegate = self;
    versionVC.title = modItem.displayName;
    // FCL style: pass in the preferred version and loader of the current profile, so the matching chip is selected and pinned to the top
    versionVC.preferredGameVersion = [self currentProfileMinecraftVersion];
    versionVC.preferredLoader = [self currentProfileLoader];

    // Push it into the middle content area instead of a modal over the download list (matching FCL for Android)
    [self.navigationController pushViewController:versionVC animated:YES];
}

- (void)downloadShader:(UIButton *)sender {
    NSIndexPath *indexPath = [NSIndexPath indexPathForRow:sender.tag inSection:0];
    [self downloadShaderAtIndexPath:indexPath];
}

- (void)downloadShaderAtIndexPath:(NSIndexPath *)indexPath {
    if (indexPath.row >= self.shaderList.count) return;

    NSDictionary *shader = self.shaderList[indexPath.row];
    ShaderItem *shaderItem = [[ShaderItem alloc] initWithOnlineData:shader];

    ShaderVersionViewController *versionVC = [[ShaderVersionViewController alloc] init];
    versionVC.shaderItem = shaderItem;
    versionVC.delegate = self;
    versionVC.title = shaderItem.displayName;
    // FCL style: pass in the preferred version and loader of the current profile, so the matching chip is selected and the matching version pinned to the top
    // Add the preferred parameters that were missing compared with ModVersionViewController (phase 3 alignment)
    versionVC.preferredGameVersion = [self currentProfileMinecraftVersion];
    versionVC.preferredLoader = [self currentProfileLoader];

    [self.navigationController pushViewController:versionVC animated:YES];
}

- (void)downloadResourcepack:(UIButton *)sender {
    NSIndexPath *indexPath = [NSIndexPath indexPathForRow:sender.tag inSection:0];
    [self downloadResourcepackAtIndexPath:indexPath];
}

- (void)downloadResourcepackAtIndexPath:(NSIndexPath *)indexPath {
    if (indexPath.row >= self.resourcepackList.count) return;

    NSDictionary *resourcepack = self.resourcepackList[indexPath.row];
    ResourcePackItem *item = [[ResourcePackItem alloc] initWithOnlineData:resourcepack];

    self.pendingDownloadType = @"resourcepack";
    self.pendingResourcePackItem = item;

    AssetVersionViewController *versionVC = [[AssetVersionViewController alloc] init];
    versionVC.assetType = AssetVersionTypeResourcePack;
    versionVC.projectID = item.onlineID;
    versionVC.projectDisplayName = item.displayName;
    versionVC.delegate = self;
    versionVC.title = item.displayName;
    // Pass in the project display information (for the detail header: cover image, author, downloads, tags, description)
    versionVC.projectIconURL = item.iconURL;
    versionVC.projectAuthor = item.author;
    versionVC.projectDownloads = item.downloads;
    versionVC.projectLikes = item.likes;
    versionVC.projectDescription = item.resourcePackDescription;
    versionVC.projectCategories = item.categories;
    versionVC.projectLastUpdated = item.lastUpdated;
    // FCL style: pass in the preferred version of the current profile, so the matching chip is selected and the matching version pinned to the top (phase 3 alignment)
    versionVC.preferredGameVersion = [self currentProfileMinecraftVersion];

    [self.navigationController pushViewController:versionVC animated:YES];
}

- (void)downloadDatapack:(UIButton *)sender {
    NSIndexPath *indexPath = [NSIndexPath indexPathForRow:sender.tag inSection:0];
    [self downloadDatapackAtIndexPath:indexPath];
}

- (void)downloadDatapackAtIndexPath:(NSIndexPath *)indexPath {
    if (indexPath.row >= self.datapackList.count) return;

    NSDictionary *datapack = self.datapackList[indexPath.row];
    DataPackItem *item = [[DataPackItem alloc] initWithOnlineData:datapack];

    self.pendingDownloadType = @"datapack";
    self.pendingDataPackItem = item;

    AssetVersionViewController *versionVC = [[AssetVersionViewController alloc] init];
    versionVC.assetType = AssetVersionTypeDataPack;
    versionVC.projectID = item.onlineID;
    versionVC.projectDisplayName = item.displayName;
    versionVC.delegate = self;
    versionVC.title = item.displayName;
    // Pass in the project display information (for the detail header: cover image, author, downloads, tags, description)
    versionVC.projectIconURL = item.iconURL;
    versionVC.projectAuthor = item.author;
    versionVC.projectDownloads = item.downloads;
    versionVC.projectLikes = item.likes;
    versionVC.projectDescription = item.dataPackDescription;
    versionVC.projectCategories = item.categories;
    versionVC.projectLastUpdated = item.lastUpdated;
    // FCL style: pass in the preferred version of the current profile, so the matching chip is selected and the matching version pinned to the top (phase 3 alignment)
    versionVC.preferredGameVersion = [self currentProfileMinecraftVersion];

    [self.navigationController pushViewController:versionVC animated:YES];
}

- (void)downloadWorld:(UIButton *)sender {
    NSIndexPath *indexPath = [NSIndexPath indexPathForRow:sender.tag inSection:0];
    [self downloadWorldAtIndexPath:indexPath];
}

- (void)downloadWorldAtIndexPath:(NSIndexPath *)indexPath {
    if (indexPath.row >= self.worldList.count) return;

    NSDictionary *world = self.worldList[indexPath.row];
    WorldItem *item = [[WorldItem alloc] initWithOnlineData:world];

    self.pendingDownloadType = @"world";
    self.pendingWorldItem = item;

    AssetVersionViewController *versionVC = [[AssetVersionViewController alloc] init];
    versionVC.assetType = AssetVersionTypeWorld;
    versionVC.projectID = item.onlineID;
    versionVC.projectDisplayName = item.displayName;
    versionVC.delegate = self;
    versionVC.title = item.displayName;
    // Pass in the project display information (for the detail header: cover image, author, downloads, tags, description)
    versionVC.projectIconURL = item.iconURL;
    versionVC.projectAuthor = item.author;
    versionVC.projectDownloads = item.downloads;
    versionVC.projectLikes = item.likes;
    versionVC.projectDescription = item.worldDescription;
    versionVC.projectCategories = item.categories;
    versionVC.projectLastUpdated = item.lastUpdated;
    // FCL style: pass in the preferred version of the current profile, so the matching chip is selected and the matching version pinned to the top (phase 3 alignment)
    versionVC.preferredGameVersion = [self currentProfileMinecraftVersion];

    [self.navigationController pushViewController:versionVC animated:YES];
}

#pragma mark - ModVersionViewControllerDelegate

- (void)modVersionViewController:(ModVersionViewController *)viewController didSelectVersion:(ModVersion *)version {
    NSDictionary *primaryFile = version.primaryFile;
    if (!primaryFile || ![primaryFile[@"url"] isKindOfClass:[NSString class]]) {
        [self showError:@"No valid download link found"];
        return;
    }

    // Modpacks use their own install flow (download + parse + import), unlike an ordinary mod download
    if ([self.pendingDownloadType isEqualToString:@"modpack"]) {
        NSDictionary *modpack = self.pendingModpackDict;
        self.pendingDownloadType = nil;
        self.pendingModpackDict = nil;
        // The child page is already on the navigation stack, so it pops back to the download list once a version is chosen
        [self.navigationController popViewControllerAnimated:YES];
        [self startModpackInstallation:version modpack:modpack];
        return;
    }

    ModItem *itemToDownload = viewController.modItem;
    itemToDownload.selectedVersionDownloadURL = primaryFile[@"url"];
    itemToDownload.fileName = primaryFile[@"filename"] ?: [NSString stringWithFormat:@"%@.jar", itemToDownload.displayName];

    // Mod downloads go through ModService (resourcepack/datapack/world now use AssetVersionViewController)
    self.pendingDownloadType = nil;

    // The child page is already on the navigation stack, so it pops back to the download list once a version is chosen
    [self.navigationController popViewControllerAnimated:YES];
    [self startDownloadForModItem:itemToDownload];
}

#pragma mark - AssetVersionViewControllerDelegate

- (void)assetVersionViewController:(AssetVersionViewController *)viewController didSelectVersion:(ModVersion *)version {
    NSDictionary *primaryFile = version.primaryFile;
    if (!primaryFile || ![primaryFile[@"url"] isKindOfClass:[NSString class]]) {
        [self showError:@"No valid download link found"];
        return;
    }

    NSString *downloadType = self.pendingDownloadType;
    self.pendingDownloadType = nil;

    // The child page is already on the navigation stack, so it pops back to the download list once a version is chosen
    [self.navigationController popViewControllerAnimated:YES];

    if ([downloadType isEqualToString:@"resourcepack"]) {
        ResourcePackItem *item = self.pendingResourcePackItem;
        self.pendingResourcePackItem = nil;
        if (!item) return;
        item.selectedVersionDownloadURL = primaryFile[@"url"];
        item.fileName = primaryFile[@"filename"] ?: [NSString stringWithFormat:@"%@.zip", item.displayName];
        [self startDownloadForResourcePackItem:item];
    } else if ([downloadType isEqualToString:@"datapack"]) {
        DataPackItem *item = self.pendingDataPackItem;
        self.pendingDataPackItem = nil;
        if (!item) return;
        item.selectedVersionDownloadURL = primaryFile[@"url"];
        item.fileName = primaryFile[@"filename"] ?: [NSString stringWithFormat:@"%@.zip", item.displayName];
        [self startDownloadForDataPackItem:item];
    } else if ([downloadType isEqualToString:@"world"]) {
        WorldItem *item = self.pendingWorldItem;
        self.pendingWorldItem = nil;
        if (!item) return;
        item.selectedVersionDownloadURL = primaryFile[@"url"];
        [self startDownloadForWorldItem:item];
    }
}

- (void)startDownloadForModItem:(ModItem *)item {
    // FCL style: use the floating bottom progress card (consistent with Minecraft version downloads),
    // replacing the earlier indeterminate InstallerProgressViewController.
    // Previously downloadMod:toProfile:completion: was called without the progress variant, so the progress page spun forever
    // and the user felt it was "stuck". It now uses the variant with progress and feeds the callback into the card.
    if (self.progressCardView) {
        [self.progressCardView dismiss];
        self.progressCardView = nil;
    }

    NSString *modTitle = [NSString stringWithFormat:@"Downloading %@", item.displayName ?: @""];
    self.progressCardView = [DownloadProgressCardView showInParentView:self.view title:modTitle];
    [self.progressCardView startDownloadWithTitle:modTitle
                                          subtitle:@"Minecraft mod"];
    // Show indeterminate mode immediately and switch to a real percentage after the first progress callback
    [self.progressCardView updateProgress:-1 downloaded:0 total:-1 speed:0 eta:-1 currentFile:@"Preparing download..."];

    NSString *profileName = PLProfiles.current.selectedProfileName ?: @"default";

    __weak typeof(self) weakSelf = self;
    __weak DownloadProgressCardView *weakCard = self.progressCardView;
    [[ModService sharedService] downloadMod:item
                                  toProfile:profileName
                                    progress:^(NSProgress * _Nullable downloadProgress) {
        dispatch_async(dispatch_get_main_queue(), ^{
            __strong typeof(weakSelf) strongSelf = weakSelf;
            if (!strongSelf || !weakCard) return;
            double fraction = downloadProgress.fractionCompleted;
            long long total = downloadProgress.totalUnitCount;
            long long downloaded = downloadProgress.completedUnitCount;
            long long speed = 0;
            NSInteger eta = -1;
            if ([downloadProgress.throughput isKindOfClass:[NSNumber class]]) {
                speed = [downloadProgress.throughput longLongValue];
            }
            if ([downloadProgress.estimatedTimeRemaining isKindOfClass:[NSNumber class]]) {
                eta = [downloadProgress.estimatedTimeRemaining integerValue];
            }
            [weakCard updateProgress:fraction
                         downloaded:downloaded
                               total:total
                              speed:speed
                                eta:eta
                        currentFile:item.fileName];
        });
    } completion:^(NSError * _Nullable error) {
        dispatch_async(dispatch_get_main_queue(), ^{
            __strong typeof(weakSelf) strongSelf = weakSelf;
            if (!strongSelf) return;
            if (error) {
                if (strongSelf.progressCardView) {
                    [strongSelf.progressCardView failWithError:error];
                    strongSelf.progressCardView = nil;
                }
                [strongSelf showError:error.localizedDescription];
            } else {
                if (strongSelf.progressCardView) {
                    [strongSelf.progressCardView completeWithTitle:[NSString stringWithFormat:@"%@ installed", item.displayName]];
                    strongSelf.progressCardView = nil;
                }
                [strongSelf showSuccessMessage:[NSString stringWithFormat:@"%@ installed", item.displayName]];
            }
        });
    }];
}

// Download a resource pack (using ResourcePackService, NSString profileName)
- (void)startDownloadForResourcePackItem:(ResourcePackItem *)item {
    InstallerProgressViewController *progressVC = [[InstallerProgressViewController alloc] init];
    progressVC.titleText = [NSString stringWithFormat:@"Downloading %@", item.displayName ?: @""];
    progressVC.progress = -1;
    progressVC.stageMessage = @"Downloading resource pack...";
    // Phase 12 enhancement: resource pack icon
    progressVC.categoryIconName = @"paintpalette.fill";
    progressVC.categoryIconColor = [UIColor systemPurpleColor];
    [self.navigationController pushViewController:progressVC animated:YES];

    NSString *profileName = PLProfiles.current.selectedProfileName ?: @"default";
    __weak typeof(self) weakSelf = self;
    __weak InstallerProgressViewController *weakProgressVC = progressVC;
    [[ResourcePackService sharedService] downloadResourcePack:item
                                                    toProfile:profileName
                                                     progress:^(NSProgress * _Nullable downloadProgress) {
        dispatch_async(dispatch_get_main_queue(), ^{
            if (downloadProgress && weakProgressVC) {
                weakProgressVC.progress = downloadProgress.fractionCompleted;
            }
        });
    } completion:^(BOOL success, NSError * _Nullable error) {
        dispatch_async(dispatch_get_main_queue(), ^{
            __strong typeof(weakSelf) strongSelf = weakSelf;
            if (!strongSelf) return;
            [strongSelf.navigationController popViewControllerAnimated:YES];
            if (success && !error) {
                [strongSelf showSuccessMessage:[NSString stringWithFormat:@"%@ installed into resourcepacks", item.displayName]];
            } else {
                [strongSelf showError:error.localizedDescription ?: @"Resource pack download failed"];
            }
        });
    }];
}

// Download a data pack (using DataPackService, NSString profileName)
- (void)startDownloadForDataPackItem:(DataPackItem *)item {
    InstallerProgressViewController *progressVC = [[InstallerProgressViewController alloc] init];
    progressVC.titleText = [NSString stringWithFormat:@"Downloading %@", item.displayName ?: @""];
    progressVC.progress = -1;
    progressVC.stageMessage = @"Downloading data pack...";
    // Phase 12 enhancement: data pack icon
    progressVC.categoryIconName = @"doc.text.fill";
    progressVC.categoryIconColor = [UIColor systemTealColor];
    [self.navigationController pushViewController:progressVC animated:YES];

    NSString *profileName = PLProfiles.current.selectedProfileName ?: @"default";
    __weak typeof(self) weakSelf = self;
    __weak InstallerProgressViewController *weakProgressVC = progressVC;
    [[DataPackService sharedService] downloadDataPack:item
                                            toProfile:profileName
                                             progress:^(NSProgress * _Nullable downloadProgress) {
        dispatch_async(dispatch_get_main_queue(), ^{
            if (downloadProgress && weakProgressVC) {
                weakProgressVC.progress = downloadProgress.fractionCompleted;
            }
        });
    } completion:^(BOOL success, NSError * _Nullable error) {
        dispatch_async(dispatch_get_main_queue(), ^{
            __strong typeof(weakSelf) strongSelf = weakSelf;
            if (!strongSelf) return;
            [strongSelf.navigationController popViewControllerAnimated:YES];
            if (success && !error) {
                [strongSelf showSuccessMessage:[NSString stringWithFormat:@"%@ installed into datapacks\nPlease move it manually into the matching world folder", item.displayName]];
            } else {
                [strongSelf showError:error.localizedDescription ?: @"Data pack download failed"];
            }
        });
    }];
}

// Download a world save and extract it into the saves folder (using WorldService, with progress callbacks and robust extraction)
- (void)startDownloadForWorldItem:(WorldItem *)item {
    InstallerProgressViewController *progressVC = [[InstallerProgressViewController alloc] init];
    progressVC.titleText = [NSString stringWithFormat:@"Downloading %@", item.displayName ?: @""];
    progressVC.progress = -1;
    progressVC.stageMessage = @"Downloading world save...";
    // Phase 12 enhancement: world icon
    progressVC.categoryIconName = @"globe.asia.australia.fill";
    progressVC.categoryIconColor = [UIColor systemGreenColor];
    [self.navigationController pushViewController:progressVC animated:YES];

    NSString *profileName = PLProfiles.current.selectedProfileName ?: @"default";
    __weak typeof(self) weakSelf = self;
    __weak InstallerProgressViewController *weakProgressVC = progressVC;
    [[WorldService sharedService] downloadWorld:item
                                        toProfile:profileName
                                         progress:^(NSProgress * _Nullable downloadProgress) {
        dispatch_async(dispatch_get_main_queue(), ^{
            if (downloadProgress && weakProgressVC) {
                weakProgressVC.progress = downloadProgress.fractionCompleted;
            }
        });
    } completion:^(BOOL success, NSError * _Nullable error) {
        dispatch_async(dispatch_get_main_queue(), ^{
            __strong typeof(weakSelf) strongSelf = weakSelf;
            if (!strongSelf) return;
            [strongSelf.navigationController popViewControllerAnimated:YES];
            if (success && !error) {
                [strongSelf showSuccessMessage:[NSString stringWithFormat:@"%@ extracted into the saves folder", item.displayName]];
            } else {
                [strongSelf showError:error.localizedDescription ?: @"World download failed"];
            }
        });
    }];
}

#pragma mark - ShaderVersionViewControllerDelegate

- (void)shaderVersionViewController:(ShaderVersionViewController *)viewController didSelectVersion:(ShaderVersion *)version {
    ShaderItem *itemToDownload = viewController.shaderItem;
    
    NSDictionary *primaryFile = version.primaryFile;
    if (!primaryFile || ![primaryFile[@"url"] isKindOfClass:[NSString class]]) {
        [self showError:@"No valid download link found"];
        return;
    }
    
    itemToDownload.selectedVersionDownloadURL = primaryFile[@"url"];
    itemToDownload.fileName = primaryFile[@"filename"] ?: [NSString stringWithFormat:@"%@.zip", itemToDownload.displayName];

    // The child page is already on the navigation stack, so it pops back to the download list once a version is chosen
    [self.navigationController popViewControllerAnimated:YES];
    [self startDownloadForShaderItem:itemToDownload];
}

- (void)startDownloadForShaderItem:(ShaderItem *)item {
    // FCL style: use the floating bottom progress card (consistent with Minecraft version and mod downloads),
    // replacing the earlier indeterminate InstallerProgressViewController.
    // Previously downloadShader:toProfile:completion: was called without the progress variant, so the progress page spun forever,
    // and the user felt it was "stuck". It now uses the variant with progress and feeds the callback into the card.
    if (self.progressCardView) {
        [self.progressCardView dismiss];
        self.progressCardView = nil;
    }

    NSString *shaderTitle = [NSString stringWithFormat:@"Downloading %@", item.displayName ?: @""];
    self.progressCardView = [DownloadProgressCardView showInParentView:self.view title:shaderTitle];
    [self.progressCardView startDownloadWithTitle:shaderTitle
                                          subtitle:@"Minecraft shader pack"];
    [self.progressCardView updateProgress:-1 downloaded:0 total:-1 speed:0 eta:-1 currentFile:@"Preparing download..."];

    NSString *profileName = PLProfiles.current.selectedProfileName ?: @"default";

    __weak typeof(self) weakSelf = self;
    __weak DownloadProgressCardView *weakCard = self.progressCardView;
    [[ShaderService sharedService] downloadShader:item
                                         toProfile:profileName
                                           progress:^(NSProgress * _Nullable downloadProgress) {
        dispatch_async(dispatch_get_main_queue(), ^{
            __strong typeof(weakSelf) strongSelf = weakSelf;
            if (!strongSelf || !weakCard) return;
            double fraction = downloadProgress.fractionCompleted;
            long long total = downloadProgress.totalUnitCount;
            long long downloaded = downloadProgress.completedUnitCount;
            long long speed = 0;
            NSInteger eta = -1;
            if ([downloadProgress.throughput isKindOfClass:[NSNumber class]]) {
                speed = [downloadProgress.throughput longLongValue];
            }
            if ([downloadProgress.estimatedTimeRemaining isKindOfClass:[NSNumber class]]) {
                eta = [downloadProgress.estimatedTimeRemaining integerValue];
            }
            [weakCard updateProgress:fraction
                         downloaded:downloaded
                               total:total
                              speed:speed
                                eta:eta
                        currentFile:item.fileName];
        });
    } completion:^(NSError * _Nullable error) {
        dispatch_async(dispatch_get_main_queue(), ^{
            __strong typeof(weakSelf) strongSelf = weakSelf;
            if (!strongSelf) return;
            if (error) {
                if (strongSelf.progressCardView) {
                    [strongSelf.progressCardView failWithError:error];
                    strongSelf.progressCardView = nil;
                }
                [strongSelf showError:error.localizedDescription];
            } else {
                if (strongSelf.progressCardView) {
                    [strongSelf.progressCardView completeWithTitle:[NSString stringWithFormat:@"%@ installed", item.displayName]];
                    strongSelf.progressCardView = nil;
                }
                [strongSelf showSuccessMessage:[NSString stringWithFormat:@"%@ installed", item.displayName]];
            }
        });
    }];
}

#pragma mark - Network & Progress

- (BOOL)isNetworkAvailable {
    struct sockaddr_in zeroAddress;
    bzero(&zeroAddress, sizeof(zeroAddress));
    zeroAddress.sin_len = sizeof(zeroAddress);
    zeroAddress.sin_family = AF_INET;
    
    SCNetworkReachabilityRef reachability = SCNetworkReachabilityCreateWithAddress(kCFAllocatorDefault, (const struct sockaddr *)&zeroAddress);
    if (!reachability) return NO;
    
    SCNetworkReachabilityFlags flags;
    BOOL success = SCNetworkReachabilityGetFlags(reachability, &flags);
    CFRelease(reachability);
    
    return success && (flags & kSCNetworkReachabilityFlagsReachable) && !(flags & kSCNetworkReachabilityFlagsConnectionRequired);
}

- (void)observeValueForKeyPath:(NSString *)keyPath ofObject:(id)object change:(NSDictionary *)change context:(void *)context {
    // Progress of the vanilla prerequisite install (its own context, so it does not clash with the main download flow)
    if ([(__bridge NSString *)context isEqualToString:@"VanillaPreinstallContext"]) {
        [self handleVanillaPreinstallProgress];
        return;
    }
    if (![(__bridge NSString *)context isEqualToString:@"DownloadProgressContext"]) {
        [super observeValueForKeyPath:keyPath ofObject:object change:change context:context];
        return;
    }
    
    NSProgress *progress = self.downloadTask.progress;
    NSProgress *textProgress = self.downloadTask.textProgress;
    if (!textProgress) return;
    
    NSInteger completedUnitCount = progress.totalUnitCount * progress.fractionCompleted;
    textProgress.completedUnitCount = completedUnitCount;
    
    static CGFloat lastMsTime = 0;
    static NSUInteger lastSecTime = 0;
    static NSInteger lastCompletedUnitCount = 0;
    
    struct timeval tv;
    gettimeofday(&tv, NULL);
    
    if (lastSecTime < tv.tv_sec) {
        CGFloat currentTime = tv.tv_sec + tv.tv_usec / 1000000.0;
        if (lastMsTime > 0) {
            NSInteger throughput = (completedUnitCount - lastCompletedUnitCount) / (currentTime - lastMsTime);
            textProgress.throughput = @(throughput);
            if (throughput > 0) {
                NSInteger remaining = (progress.totalUnitCount - completedUnitCount) / throughput;
                textProgress.estimatedTimeRemaining = @(remaining);
            }
        }
        lastCompletedUnitCount = completedUnitCount;
        lastSecTime = tv.tv_sec;
        lastMsTime = currentTime;
    }
    
    dispatch_async(dispatch_get_main_queue(), ^{
        // Following FCL/ZL2/HMCL: show the progress on a download progress card
        if (self.progressCardView) {
            long long totalBytes = progress.totalUnitCount;
            long long downloadedBytes = completedUnitCount;
            long long speed = 0;
            NSInteger eta = -1;

            if (textProgress.throughput) {
                speed = [textProgress.throughput integerValue];
            }
            if (textProgress.estimatedTimeRemaining) {
                eta = [textProgress.estimatedTimeRemaining integerValue];
            }

            // Get the name of the file currently downloading (extracted from the description of textProgress)
            NSString *currentFile = nil;
            if (textProgress.localizedDescription && textProgress.localizedDescription.length > 0) {
                currentFile = textProgress.localizedDescription;
            }

            [self.progressCardView updateProgress:progress.fractionCompleted
                                      downloaded:downloadedBytes
                                            total:totalBytes
                                           speed:speed
                                             eta:eta
                                     currentFile:currentFile];
        }

        if (progress.finished) {
            if (self.isObservingProgress) {
                @try {
                    [self.downloadTask.progress removeObserver:self forKeyPath:@"fractionCompleted"];
                } @catch (NSException *exception) {
                    NSLog(@"[DownloadVC] progress.finished: removeObserver failed: %@", exception.reason);
                }
                self.isObservingProgress = NO;
            }

            lastMsTime = 0;
            lastSecTime = 0;
            lastCompletedUnitCount = 0;

            self.view.userInteractionEnabled = YES;

            // Show the completed state on the progress card
            if (self.progressCardView) {
                NSString *completeTitle = [NSString stringWithFormat:@"%@ download complete",
                                           self.downloadTask.metadata[@"id"] ?: @"Version"];
                [self.progressCardView completeWithTitle:completeTitle];
                self.progressCardView = nil;
            }

            if (self.progressVC) {
                [self.progressVC dismissViewControllerAnimated:YES completion:nil];
                self.progressVC = nil;
            }

            self.downloadTask = nil;

            // Key fix (issue #61): the ReloadProfileList notification was not posted after a vanilla version finished downloading,
            // so the "Installed versions" list did not refresh and the new version card did not appear.
            // downloadVanillaVersion: already calls saveProfile + setSelectedProfileName (which posts SelectedProfileChanged),
            // but the version card lists (LauncherRootViewController/VersionManagerViewController) listen for ReloadProfileList,
            // so without posting it too the UI never refreshes.
            [[NSNotificationCenter defaultCenter] postNotificationName:@"ReloadProfileList" object:nil];
        }
    });
}

/// Progress handling for the vanilla prerequisite install: update the FCL-style progress VC, and on completion pop it and start the mod loader install.
- (void)handleVanillaPreinstallProgress {
    MinecraftResourceDownloadTask *task = self.vanillaPreinstallTask;
    if (!task) return;
    NSProgress *progress = task.progress;
    NSProgress *textProgress = task.textProgress;
    double fraction = progress.fractionCompleted;

    // Compute speed / ETA (as in the main download flow)
    static CGFloat lastMsTime = 0;
    static NSUInteger lastSecTime = 0;
    static NSInteger lastCompletedUnitCount = 0;
    if (textProgress) {
        NSInteger completedUnitCount = progress.totalUnitCount * fraction;
        textProgress.completedUnitCount = completedUnitCount;
        struct timeval tv;
        gettimeofday(&tv, NULL);
        if (lastSecTime < tv.tv_sec) {
            CGFloat currentTime = tv.tv_sec + tv.tv_usec / 1000000.0;
            if (lastMsTime > 0) {
                NSInteger throughput = (completedUnitCount - lastCompletedUnitCount) / (currentTime - lastMsTime);
                textProgress.throughput = @(throughput);
                if (throughput > 0) {
                    NSInteger remaining = (progress.totalUnitCount - completedUnitCount) / throughput;
                    textProgress.estimatedTimeRemaining = @(remaining);
                }
            }
            lastCompletedUnitCount = completedUnitCount;
            lastSecTime = tv.tv_sec;
            lastMsTime = currentTime;
        }
    }

    dispatch_async(dispatch_get_main_queue(), ^{
        __strong typeof(self) s = self;
        if (!s) return;
        InstallerProgressViewController *pvc = s.vanillaPreinstallProgressVC;
        if (pvc) {
            if (fraction >= 0.0 && progress.totalUnitCount > 1) {
                pvc.progress = fraction;
            } else {
                pvc.progress = -1; // Indeterminate mode
            }

            // Phase 12 enhancement: detail info line (downloaded / total • speed)
            NSInteger completedBytes = progress.totalUnitCount * fraction;
            NSString *sizeInfo = [NSString stringWithFormat:@"%@ / %@",
                                  [NSByteCountFormatter stringFromByteCount:completedBytes countStyle:NSByteCountFormatterCountStyleFile],
                                  [NSByteCountFormatter stringFromByteCount:progress.totalUnitCount countStyle:NSByteCountFormatterCountStyleFile]];
            NSString *speedInfo = @"";
            if (textProgress.throughput) {
                NSInteger speed = [textProgress.throughput integerValue];
                if (speed > 1024 * 1024) {
                    speedInfo = [NSString stringWithFormat:@" • %.1f MB/s", speed / (1024.0 * 1024.0)];
                } else if (speed > 1024) {
                    speedInfo = [NSString stringWithFormat:@" • %.1f KB/s", speed / 1024.0];
                } else if (speed > 0) {
                    speedInfo = [NSString stringWithFormat:@" • %ld B/s", (long)speed];
                }
            }
            pvc.detailInfoText = [NSString stringWithFormat:@"%@%@", sizeInfo, speedInfo];

            // Phase 12 enhancement: time remaining (ETA) shown separately
            if (textProgress.estimatedTimeRemaining) {
                NSInteger eta = [textProgress.estimatedTimeRemaining integerValue];
                if (eta > 3600) {
                    pvc.etaText = [NSString stringWithFormat:@"%ldh %ldm left", (long)(eta / 3600), (long)((eta % 3600) / 60)];
                } else if (eta > 60) {
                    pvc.etaText = [NSString stringWithFormat:@"%ldm %lds left", (long)(eta / 60), (long)(eta % 60)];
                } else if (eta > 0) {
                    pvc.etaText = [NSString stringWithFormat:@"%lds left", (long)eta];
                } else {
                    pvc.etaText = nil;
                }
            } else {
                pvc.etaText = nil;
            }

            // Phase 12 enhancement: update the stage states from the progress percentage
            // Vanilla install steps: fetch version manifest (✓) -> download version JSON (✓) -> download game libraries -> download assets -> verify files
            // Roughly split by progress: 0-30% = libraries, 30-90% = assets, 90-100% = verification
            NSArray *steps;
            if (fraction < 0.3) {
                steps = @[
                    @{@"title": @"Fetch version manifest", @"status": @2},
                    @{@"title": @"Download version JSON", @"status": @2},
                    @{@"title": @"Download game libraries", @"status": @1},
                    @{@"title": @"Download asset files", @"status": @0},
                    @{@"title": @"Verify file integrity", @"status": @0},
                ];
            } else if (fraction < 0.9) {
                steps = @[
                    @{@"title": @"Fetch version manifest", @"status": @2},
                    @{@"title": @"Download version JSON", @"status": @2},
                    @{@"title": @"Download game libraries", @"status": @2},
                    @{@"title": @"Download asset files", @"status": @1},
                    @{@"title": @"Verify file integrity", @"status": @0},
                ];
            } else {
                steps = @[
                    @{@"title": @"Fetch version manifest", @"status": @2},
                    @{@"title": @"Download version JSON", @"status": @2},
                    @{@"title": @"Download game libraries", @"status": @2},
                    @{@"title": @"Download asset files", @"status": @2},
                    @{@"title": @"Verify file integrity", @"status": @1},
                ];
            }
            pvc.stageSteps = steps;

            // Stage text: the name of the file currently downloading (with a simplified percentage)
            pvc.stageMessage = [NSString stringWithFormat:@"Downloading vanilla files... %.1f%%", fraction * 100.0];
        }

        if (progress.finished) {
            // Reset the static variables used for the speed statistics
            lastMsTime = 0;
            lastSecTime = 0;
            lastCompletedUnitCount = 0;

            if (s.isObservingVanillaPreinstall) {
                @try {
                    [s.vanillaPreinstallTask.progress removeObserver:s forKeyPath:@"fractionCompleted"];
                } @catch (NSException *exception) {
                    NSLog(@"[DownloadVC] vanillaPreinstall progress.finished: removeObserver failed: %@", exception.reason);
                }
                s.isObservingVanillaPreinstall = NO;
            }
            // Improvement 2 (following the unified progress flow of ZL2): in the loader prerequisite case the preinstall VC is not popped
            // but handed to self.installerProgressVC, so the later install* methods reuse the same progress page
            // and "vanilla + loader" advance continuously on one page.
            if (s.vanillaPreinstallForLoader && s.vanillaPreinstallProgressVC) {
                InstallerProgressViewController *pvc = s.vanillaPreinstallProgressVC;
                pvc.progress = -1; // Back to indeterminate mode while waiting for the loader install stage
                pvc.stageMessage = @"Vanilla files are ready, preparing to install the loader...";
                // Step list: all 5 vanilla steps marked complete + "Install mod loader" in progress
                pvc.stageSteps = @[
                    @{@"title": @"Fetch version manifest", @"status": @2},
                    @{@"title": @"Download version JSON", @"status": @2},
                    @{@"title": @"Download game libraries", @"status": @2},
                    @{@"title": @"Download asset files", @"status": @2},
                    @{@"title": @"Verify file integrity", @"status": @2},
                    @{@"title": @"Install mod loader", @"status": @1},
                ];
                s.installerProgressVC = pvc;
                s.vanillaPreinstallForLoader = NO;
            } else {
                // Non-loader cases (a direct vanilla install or a modpack preinstall): keep the original behavior and pop the preinstall VC
                if (s.vanillaPreinstallProgressVC && [s.navigationController.viewControllers containsObject:s.vanillaPreinstallProgressVC]) {
                    [s.navigationController popViewControllerAnimated:YES];
                }
            }
            s.vanillaPreinstallTask = nil;
            s.vanillaPreinstallProgressVC = nil;
            // Key fix (issue #61): the ReloadProfileList notification must also be posted after the vanilla prerequisite install,
            // so the "Installed versions" list shows the newly ready vanilla version promptly.
            [[NSNotificationCenter defaultCenter] postNotificationName:@"ReloadProfileList" object:nil];
            void (^cb)(BOOL) = s.vanillaPreinstallCompletion;
            s.vanillaPreinstallCompletion = nil;
            if (cb) cb(YES);
        }
    });
}

#pragma mark - Orientation

- (BOOL)shouldAutorotate {
    return YES;
}

- (UIInterfaceOrientationMask)supportedInterfaceOrientations {
    return UIInterfaceOrientationMaskLandscape;
}

#pragma mark - Helper Methods

/// Phase 6 fix (following FCL): a synchronous download helper that sends a User-Agent
///
/// OptiFine downloads previously used [NSData dataWithContentsOfURL:] throughout, which sends no User-Agent or
/// the system default, and BMCLAPI/Cloudflare block such requests with a 403 or an HTML error page,
/// making the OptiFine install fail. The Forge/NeoForge direct installers correctly use NSURLSession with a browser UA,
/// and this method makes OptiFine downloads do the same.
///
/// This call blocks, so it must be made on a background thread.
- (NSData *)downloadDataWithURLString:(NSString *)urlString error:(NSError **)error {
    if (!urlString.length) {
        if (error) *error = [NSError errorWithDomain:@"DownloadError" code:1 userInfo:@{NSLocalizedDescriptionKey: @"Empty URL"}];
        return nil;
    }
    NSURL *url = [NSURL URLWithString:urlString];
    if (!url) {
        // Try again after percent-encoding it
        NSString *encoded = [urlString stringByAddingPercentEncodingWithAllowedCharacters:[NSCharacterSet URLQueryAllowedCharacterSet]];
        url = [NSURL URLWithString:encoded];
    }
    if (!url) {
        if (error) *error = [NSError errorWithDomain:@"DownloadError" code:1 userInfo:@{NSLocalizedDescriptionKey: [NSString stringWithFormat:@"Invalid URL: %@", urlString]}];
        return nil;
    }

    NSURLSessionConfiguration *cfg = [NSURLSessionConfiguration defaultSessionConfiguration];
    cfg.timeoutIntervalForRequest = 60;
    cfg.timeoutIntervalForResource = 180;
    // Browser UA (BMCLAPI/Cloudflare require a non-default UA; see ForgeDirectInstaller.m)
    cfg.HTTPAdditionalHeaders = @{
        @"User-Agent": @"Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36",
        @"Accept": @"*/*"
    };

    __block NSData *result = nil;
    __block NSError *blockError = nil;
    dispatch_semaphore_t sem = dispatch_semaphore_create(0);

    NSURLSession *session = [NSURLSession sessionWithConfiguration:cfg];
    NSURLSessionDataTask *task = [session dataTaskWithURL:url completionHandler:^(NSData *data, NSURLResponse *response, NSError *err) {
        if (err) {
            blockError = err;
        } else if ([response isKindOfClass:[NSHTTPURLResponse class]]) {
            NSHTTPURLResponse *httpResp = (NSHTTPURLResponse *)response;
            NSInteger statusCode = httpResp.statusCode;
            if (statusCode >= 400) {
                blockError = [NSError errorWithDomain:@"DownloadError" code:statusCode userInfo:@{
                    NSLocalizedDescriptionKey: [NSString stringWithFormat:@"HTTP %ld", (long)statusCode]
                }];
            } else {
                result = data;
            }
        } else {
            result = data;
        }
        dispatch_semaphore_signal(sem);
    }];
    [task resume];

    // Wait for the download to finish (the 60s timeout comes from the session configuration)
    dispatch_semaphore_wait(sem, DISPATCH_TIME_FOREVER);
    [session finishTasksAndInvalidate];

    if (error) *error = blockError;
    return result;
}

- (NSString *)currentInstanceModsPath {
    // Mirrors the existingModsFolderForProfile: logic in ModService.m:
    // 1. Prefer the profile gameDir, with /mods appended
    // 2. If the profile has no gameDir, or gameDir is ".", fall back to $POJAV_GAME_DIR/mods
    NSString *instanceName = PLProfiles.current.selectedProfileName;
    if (!instanceName) instanceName = @"default";

    NSString *modsDir = nil;

    @try {
        NSDictionary *profiles = PLProfiles.current.profiles;
        NSDictionary *prof = profiles[instanceName];
        if ([prof isKindOfClass:[NSDictionary class]]) {
            NSString *gameDir = prof[@"gameDir"];
            if ([gameDir isKindOfClass:[NSString class]] && gameDir.length > 0 && ![gameDir isEqualToString:@"."]) {
                // A relative gameDir is resolved against POJAV_GAME_DIR
                NSString *baseDir;
                const char *env = getenv("POJAV_GAME_DIR");
                if (env) {
                    baseDir = [NSString stringWithUTF8String:env];
                } else {
                    baseDir = NSHomeDirectory();
                }

                if ([gameDir isAbsolutePath]) {
                    modsDir = [gameDir stringByAppendingPathComponent:@"mods"];
                } else {
                    modsDir = [[baseDir stringByAppendingPathComponent:gameDir] stringByAppendingPathComponent:@"mods"];
                }
            }
        }
    } @catch (NSException *ex) { }

    if (!modsDir) {
        // Fall back to $POJAV_GAME_DIR/mods (matching the FCL default)
        const char *env = getenv("POJAV_GAME_DIR");
        NSString *gameDir = env ? [NSString stringWithUTF8String:env] : NSHomeDirectory();
        modsDir = [gameDir stringByAppendingPathComponent:@"mods"];
    }

    [[NSFileManager defaultManager] createDirectoryAtPath:modsDir withIntermediateDirectories:YES attributes:nil error:nil];
    return modsDir;
}

- (void)handleBackgroundUIEffectChanged:(NSNotification *)notification {
    dispatch_async(dispatch_get_main_queue(), ^{
        // Re-apply the transparent background effect (as in LauncherRightPanelViewController.reapplyBackgroundEffect)
        [[BackgroundManager sharedManager] makeViewControllerTransparent:self];
        // Re-apply the sidebar effect (the frosted-glass/translucent effect of filterSidebarContainer has to follow the settings)
        if (self.filterSidebarContainer) {
            [[BackgroundManager sharedManager] applyEffectToView:self.filterSidebarContainer];
        }
        // Apply the effect to the navigation bar
        UINavigationController *nav = self.navigationController;
        if (nav) {
            nav.view.backgroundColor = [UIColor clearColor];
            [[BackgroundManager sharedManager] applyEffectToNavigationBar:nav.navigationBar];
        }
        // Refresh every list so the cells pick up the new background effect
        [self.versionCollectionView reloadData];
        [self.modTableView reloadData];
        [self.shaderTableView reloadData];
        [self.modpackTableView reloadData];
        [self.resourcepackTableView reloadData];
        [self.datapackTableView reloadData];
        [self.worldTableView reloadData];
    });
}

@end