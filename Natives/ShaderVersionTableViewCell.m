// ShaderVersionTableViewCell.m
// Modeled on the FCL/ZL2 version list row design for stronger visual hierarchy (consistent with ModVersionTableViewCell):
// - Rounded card container (14pt corner radius + light shadow + translucent background)
// - left: the version name (15pt semibold) + version number (12pt secondary)
// - Loader badge row: colored pill labels for fabric/iris/optifine etc. (modeled on ZL2 LittleTextLabel)
// - right: publication date + file size + game version (right-aligned vertically)
// - a chevron showing it can be tapped to download
//
// Compact variant: smaller card padding/font sizes/badge height, close to the density of VersionCardCell
// (cardContainer vertical spacing 6->4, inner padding 12->10, every font size down 1pt, badge height 18->16)

#import "ShaderVersionTableViewCell.h"
#import "BackgroundManager.h"
#import "ModLoaderIconHelper.h"

@interface ShaderVersionTableViewCell ()
// Card container: rounded corners + shadow + translucent background (the shared visual spec)
@property (nonatomic, strong) UIView *cardContainer;
// Left information area (the version name row + version number + loader badge row)
@property (nonatomic, strong) UIStackView *leftStackView;
// Version name row (horizontal: nameLabel + releaseTypeBadge)
@property (nonatomic, strong) UIStackView *nameRowStack;
// Loader badge container (colored pills laid out horizontally)
@property (nonatomic, strong) UIStackView *loaderBadgeStack;
// Right information area (date + size + game version)
@property (nonatomic, strong) UIStackView *rightStackView;
// Subviews
@property (nonatomic, strong) UILabel *nameLabel;
@property (nonatomic, strong) UILabel *releaseTypeBadge; // Release type badge (Release/Beta/Alpha)
@property (nonatomic, strong) UILabel *versionNumberLabel;
@property (nonatomic, strong) UILabel *datePublishedLabel;
@property (nonatomic, strong) UILabel *fileSizeLabel;
@property (nonatomic, strong) UILabel *gameVersionsLabel;
@end

@implementation ShaderVersionTableViewCell

- (instancetype)initWithStyle:(UITableViewCellStyle)style reuseIdentifier:(NSString *)reuseIdentifier {
    self = [super initWithStyle:style reuseIdentifier:reuseIdentifier];
    if (self) {
        [self setupUI];
    }
    return self;
}

- (void)setupUI {
    self.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
    self.selectionStyle = UITableViewCellSelectionStyleNone;
    self.backgroundColor = [UIColor clearColor];
    self.contentView.backgroundColor = [UIColor clearColor];

    // ===== Card container: rounded corners + translucent background + a light shadow (phase 3 UI tweak: radius 14->12, a lighter shadow) =====
    self.cardContainer = [[UIView alloc] init];
    self.cardContainer.translatesAutoresizingMaskIntoConstraints = NO;
    self.cardContainer.backgroundColor = [[UIColor whiteColor] colorWithAlphaComponent:0.08];
    self.cardContainer.layer.cornerRadius = 12;
    self.cardContainer.layer.cornerCurve = kCACornerCurveContinuous;
    self.cardContainer.layer.borderWidth = 0.5;
    self.cardContainer.layer.borderColor = [[UIColor whiteColor] colorWithAlphaComponent:0.10].CGColor;
    self.cardContainer.layer.shadowColor = [UIColor blackColor].CGColor;
    self.cardContainer.layer.shadowOffset = CGSizeMake(0, 2);
    self.cardContainer.layer.shadowOpacity = 0.10;
    self.cardContainer.layer.shadowRadius = 4;
    [self.contentView addSubview:self.cardContainer];

    // ===== Left: the version name row (with the release type badge) + the version number =====
    self.nameLabel = [[UILabel alloc] init];
    self.nameLabel.font = [UIFont systemFontOfSize:15 weight:UIFontWeightSemibold];
    self.nameLabel.textColor = [UIColor labelColor];
    self.nameLabel.numberOfLines = 1;
    self.nameLabel.adjustsFontSizeToFitWidth = YES;
    self.nameLabel.minimumScaleFactor = 0.7;
    self.nameLabel.lineBreakMode = NSLineBreakByTruncatingTail;
    [self.nameLabel setContentHuggingPriority:UILayoutPriorityDefaultLow forAxis:UILayoutConstraintAxisHorizontal];
    [self.nameLabel setContentCompressionResistancePriority:UILayoutPriorityDefaultLow forAxis:UILayoutConstraintAxisHorizontal];

    // Release type badge (Release/Beta/Alpha, following the release type tags on FCL/ZL2 version rows)
    self.releaseTypeBadge = [[UILabel alloc] init];
    self.releaseTypeBadge.font = [UIFont systemFontOfSize:8 weight:UIFontWeightBold];
    self.releaseTypeBadge.textColor = [UIColor whiteColor];
    self.releaseTypeBadge.textAlignment = NSTextAlignmentCenter;
    self.releaseTypeBadge.layer.cornerRadius = 4;
    self.releaseTypeBadge.layer.cornerCurve = kCACornerCurveContinuous;
    self.releaseTypeBadge.layer.masksToBounds = YES;
    self.releaseTypeBadge.translatesAutoresizingMaskIntoConstraints = NO;
    [self.releaseTypeBadge.heightAnchor constraintEqualToConstant:14].active = YES;
    self.releaseTypeBadge.hidden = YES;
    [self.releaseTypeBadge setContentHuggingPriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisHorizontal];
    [self.releaseTypeBadge setContentCompressionResistancePriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisHorizontal];

    // Version name row (horizontal: nameLabel + releaseTypeBadge)
    self.nameRowStack = [[UIStackView alloc] initWithArrangedSubviews:@[self.nameLabel, self.releaseTypeBadge]];
    self.nameRowStack.axis = UILayoutConstraintAxisHorizontal;
    self.nameRowStack.spacing = 6;
    self.nameRowStack.alignment = UIStackViewAlignmentCenter;
    self.nameRowStack.distribution = UIStackViewDistributionFill;
    self.nameRowStack.translatesAutoresizingMaskIntoConstraints = NO;

    self.versionNumberLabel = [[UILabel alloc] init];
    self.versionNumberLabel.font = [UIFont systemFontOfSize:12];
    self.versionNumberLabel.textColor = [UIColor secondaryLabelColor];
    self.versionNumberLabel.numberOfLines = 1;
    self.versionNumberLabel.adjustsFontSizeToFitWidth = YES;
    self.versionNumberLabel.minimumScaleFactor = 0.7;
    self.versionNumberLabel.lineBreakMode = NSLineBreakByTruncatingTail;

    // Loader badge stack (horizontal, filled in dynamically by configureWithVersion)
    self.loaderBadgeStack = [[UIStackView alloc] init];
    self.loaderBadgeStack.axis = UILayoutConstraintAxisHorizontal;
    self.loaderBadgeStack.spacing = 5;
    self.loaderBadgeStack.alignment = UIStackViewAlignmentCenter;
    self.loaderBadgeStack.distribution = UIStackViewDistributionFill;
    self.loaderBadgeStack.translatesAutoresizingMaskIntoConstraints = NO;

    // Main left stack (vertical: version name row -> version number -> loader badge row)
    self.leftStackView = [[UIStackView alloc] initWithArrangedSubviews:@[self.nameRowStack, self.versionNumberLabel, self.loaderBadgeStack]];
    self.leftStackView.axis = UILayoutConstraintAxisVertical;
    self.leftStackView.spacing = 3;
    self.leftStackView.alignment = UIStackViewAlignmentLeading;
    self.leftStackView.translatesAutoresizingMaskIntoConstraints = NO;
    [self.cardContainer addSubview:self.leftStackView];

    // ===== Right: date + file size + game version =====
    self.datePublishedLabel = [[UILabel alloc] init];
    self.datePublishedLabel.font = [UIFont systemFontOfSize:11];
    self.datePublishedLabel.textColor = [UIColor tertiaryLabelColor];
    self.datePublishedLabel.textAlignment = NSTextAlignmentRight;

    self.fileSizeLabel = [[UILabel alloc] init];
    self.fileSizeLabel.font = [UIFont systemFontOfSize:11];
    self.fileSizeLabel.textColor = [UIColor tertiaryLabelColor];
    self.fileSizeLabel.textAlignment = NSTextAlignmentRight;

    self.gameVersionsLabel = [[UILabel alloc] init];
    self.gameVersionsLabel.font = [UIFont systemFontOfSize:11];
    self.gameVersionsLabel.textColor = [UIColor tertiaryLabelColor];
    self.gameVersionsLabel.textAlignment = NSTextAlignmentRight;
    self.gameVersionsLabel.numberOfLines = 1;
    self.gameVersionsLabel.lineBreakMode = NSLineBreakByTruncatingTail;
    self.gameVersionsLabel.adjustsFontSizeToFitWidth = YES;
    self.gameVersionsLabel.minimumScaleFactor = 0.7;

    self.rightStackView = [[UIStackView alloc] initWithArrangedSubviews:@[self.datePublishedLabel, self.fileSizeLabel, self.gameVersionsLabel]];
    self.rightStackView.axis = UILayoutConstraintAxisVertical;
    self.rightStackView.spacing = 3;
    self.rightStackView.alignment = UIStackViewAlignmentTrailing;
    self.rightStackView.translatesAutoresizingMaskIntoConstraints = NO;
    [self.cardContainer addSubview:self.rightStackView];

    // ===== Layout constraints (phase 3 UI tweak: card side margins 16->10, inner padding 14->10) =====
    [NSLayoutConstraint activateConstraints:@[
        // The card container fills contentView, with a 4pt gap above and below
        [self.cardContainer.topAnchor constraintEqualToAnchor:self.contentView.topAnchor constant:4],
        [self.cardContainer.leadingAnchor constraintEqualToAnchor:self.contentView.leadingAnchor constant:10],
        [self.cardContainer.trailingAnchor constraintEqualToAnchor:self.contentView.trailingAnchor constant:-10],
        [self.cardContainer.bottomAnchor constraintEqualToAnchor:self.contentView.bottomAnchor constant:-4],

        // Left stack: 10 from the left, 8 top and bottom (phase 3 UI tweak: down from 10 to 8)
        [self.leftStackView.leadingAnchor constraintEqualToAnchor:self.cardContainer.leadingAnchor constant:10],
        [self.leftStackView.topAnchor constraintEqualToAnchor:self.cardContainer.topAnchor constant:8],
        [self.leftStackView.bottomAnchor constraintEqualToAnchor:self.cardContainer.bottomAnchor constant:-8],
        [self.leftStackView.trailingAnchor constraintLessThanOrEqualToAnchor:self.rightStackView.leadingAnchor constant:-8],

        // Right stack: -28 from the right (leaving room for the chevron), vertically centered
        [self.rightStackView.trailingAnchor constraintEqualToAnchor:self.cardContainer.trailingAnchor constant:-28],
        [self.rightStackView.centerYAnchor constraintEqualToAnchor:self.cardContainer.centerYAnchor]
    ]];

    // Apply the frosted-glass background effect
    [[BackgroundManager sharedManager] applyEffectToView:self.cardContainer];
}

- (void)prepareForReuse {
    [super prepareForReuse];
    // Clear the loader badges, so none linger after reuse
    [self.loaderBadgeStack.arrangedSubviews makeObjectsPerformSelector:@selector(removeFromSuperview)];
}

#pragma mark - 加载器徽章

/// Build one loader badge label (pill style, colored by loader type)
/// Common shader pack loaders: iris/optifine/vanilla, colors modeled on ZL2 LittleTextLabel
/// Compact variant: 16pt tall (was 18pt), 9pt font (was 10pt), 7pt radius (was 8)
- (UILabel *)createLoaderBadge:(NSString *)loaderName {
    UILabel *badge = [[UILabel alloc] init];
    badge.text = loaderName;
    badge.font = [UIFont systemFontOfSize:9 weight:UIFontWeightBold];
    badge.textColor = [UIColor whiteColor];
    badge.textAlignment = NSTextAlignmentCenter;
    badge.backgroundColor = [self colorForLoader:loaderName];
    badge.layer.cornerRadius = 7;
    badge.layer.cornerCurve = kCACornerCurveContinuous;
    badge.layer.masksToBounds = YES;
    badge.translatesAutoresizingMaskIntoConstraints = NO;
    [badge setContentHuggingPriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisHorizontal];
    [badge setContentCompressionResistancePriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisHorizontal];
    // Fixed height of 16pt (the compact variant; it was 18pt)
    [NSLayoutConstraint activateConstraints:@[
        [badge.heightAnchor constraintEqualToConstant:16]
    ]];
    // Width = text width + 10pt of horizontal padding (was 12pt)
    [badge sizeToFit];
    CGFloat textWidth = badge.frame.size.width;
    [badge.widthAnchor constraintEqualToConstant:textWidth + 10].active = YES;
    return badge;
}

/// Loader name -> brand color mapping (delegated to ModLoaderIconHelper, removing the color inconsistencies between files)
- (UIColor *)colorForLoader:(NSString *)loader {
    return [ModLoaderIconHelper brandColorForLoader:loader];
}

/// Fill in the loader badges from the version data (showing at most 4, so they do not overflow)
- (void)configureLoaderBadges:(NSArray<NSString *> *)loaders {
    [self.loaderBadgeStack.arrangedSubviews makeObjectsPerformSelector:@selector(removeFromSuperview)];
    if (![loaders isKindOfClass:[NSArray class]] || loaders.count == 0) return;

    NSInteger maxBadges = MIN(4, loaders.count);
    for (NSInteger i = 0; i < maxBadges; i++) {
        NSString *loader = loaders[i];
        if (![loader isKindOfClass:[NSString class]] || loader.length == 0) continue;
        UILabel *badge = [self createLoaderBadge:loader];
        [self.loaderBadgeStack addArrangedSubview:badge];
    }

    // If there are more than 4, add a "+N" badge (compact variant: height 16, width 24, font 9)
    if (loaders.count > 4) {
        UILabel *moreBadge = [[UILabel alloc] init];
        moreBadge.text = [NSString stringWithFormat:@"+%ld", (long)(loaders.count - 4)];
        moreBadge.font = [UIFont systemFontOfSize:9 weight:UIFontWeightBold];
        moreBadge.textColor = [UIColor whiteColor];
        moreBadge.textAlignment = NSTextAlignmentCenter;
        moreBadge.backgroundColor = [UIColor tertiaryLabelColor];
        moreBadge.layer.cornerRadius = 7;
        moreBadge.layer.masksToBounds = YES;
        moreBadge.translatesAutoresizingMaskIntoConstraints = NO;
        [moreBadge setContentHuggingPriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisHorizontal];
        [moreBadge setContentCompressionResistancePriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisHorizontal];
        [NSLayoutConstraint activateConstraints:@[
            [moreBadge.heightAnchor constraintEqualToConstant:16],
            [moreBadge.widthAnchor constraintEqualToConstant:24]
        ]];
        [self.loaderBadgeStack addArrangedSubview:moreBadge];
    }
}

#pragma mark - 配置

- (void)configureWithVersion:(ShaderVersion *)version {
    self.nameLabel.text = version.name;
    self.versionNumberLabel.text = version.versionNumber;

    // Release type badge (Release/Beta/Alpha, following the release type tags on FCL/ZL2 version rows)
    NSString *vType = version.versionType.lowercaseString;
    if ([vType isEqualToString:@"release"] || vType.length == 0) {
        // Release: a green badge
        self.releaseTypeBadge.text = @" Release ";
        self.releaseTypeBadge.backgroundColor = [UIColor colorWithRed:0.30 green:0.75 blue:0.40 alpha:1.0];
        self.releaseTypeBadge.hidden = NO;
    } else if ([vType isEqualToString:@"beta"]) {
        // Beta: an orange badge
        self.releaseTypeBadge.text = @" Beta ";
        self.releaseTypeBadge.backgroundColor = [UIColor colorWithRed:0.90 green:0.60 blue:0.10 alpha:1.0];
        self.releaseTypeBadge.hidden = NO;
    } else if ([vType isEqualToString:@"alpha"]) {
        // Alpha: a red badge
        self.releaseTypeBadge.text = @" Alpha ";
        self.releaseTypeBadge.backgroundColor = [UIColor colorWithRed:0.85 green:0.30 blue:0.30 alpha:1.0];
        self.releaseTypeBadge.hidden = NO;
    } else {
        self.releaseTypeBadge.hidden = YES;
    }

    // Publication date: ISO 8601 -> a short date format
    NSISO8601DateFormatter *dateFormatter = [[NSISO8601DateFormatter alloc] init];
    NSDate *date = [dateFormatter dateFromString:version.datePublished];
    if (date) {
        NSDateFormatter *displayFormatter = [[NSDateFormatter alloc] init];
        displayFormatter.dateStyle = NSDateFormatterShortStyle;
        displayFormatter.timeStyle = NSDateFormatterNoStyle;
        self.datePublishedLabel.text = [displayFormatter stringFromDate:date];
    } else {
        self.datePublishedLabel.text = @"Unknown date";
    }

    // File size (prefer primaryFile[@"size"], then the fileSize property, finally fall back to unknown)
    if (version.primaryFile && [version.primaryFile[@"size"] longValue] > 0) {
        self.fileSizeLabel.text = [NSByteCountFormatter stringFromByteCount:[version.primaryFile[@"size"] longValue] countStyle:NSByteCountFormatterCountStyleFile];
    } else if (version.fileSize && [version.fileSize longValue] > 0) {
        self.fileSizeLabel.text = [NSByteCountFormatter stringFromByteCount:[version.fileSize longValue] countStyle:NSByteCountFormatterCountStyleFile];
    } else {
        self.fileSizeLabel.text = @"Unknown size";
    }

    // Game version compatibility
    self.gameVersionsLabel.text = [version.gameVersions componentsJoinedByString:@", "];

    // Loader badges (new: following the loader pill tags of ZL2)
    [self configureLoaderBadges:version.loaders];
}

@end
