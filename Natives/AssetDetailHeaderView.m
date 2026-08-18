//
//  AssetDetailHeaderView.m
//  Amethyst
//
//  Implementation of the asset detail header view (modelled on the project detail header in FCL/ZL2)
//
//  Visual spec (matching ModernAssetCell / ModVersionTableViewCell):
//    - Rounded card container: 16pt radius + 0.5pt light border + light shadow (offset 0,4 / opacity 0.12 / radius 8) + translucent background + frosted glass
//    - Project cover image: 72x72, 14pt radius, ScaleAspectFill + clipsToBounds, with an SF Symbol placeholder background
//    - Tag pills: 8pt radius, 18pt tall, 10pt bold white text, colored by loader/category brand color
//

#import "AssetDetailHeaderView.h"
#import "BackgroundManager.h"
// Note: UIKit+AFNetworking has been replaced by the unified IconLoader
// (AFNetworking only caches in memory and does not downsample; IconLoader adds a two-level cache, downsampling, CDN mirrors and concurrency control)
#import "IconLoader.h"
#import "ModLoaderIconHelper.h"

@interface AssetDetailHeaderView ()

// Card container (rounded corners + shadow + translucent background + frosted glass)
@property (nonatomic, strong) UIView *cardContainer;

// Top horizontal area: cover image + title/author
@property (nonatomic, strong) UIImageView *iconImageView;
@property (nonatomic, strong) UIView *iconPlaceholderContainer; // Shows an SF Symbol when there is no image
@property (nonatomic, strong) UIImageView *placeholderSymbolView;
@property (nonatomic, strong) UILabel *titleLabel;
@property (nonatomic, strong) UILabel *authorLabel;

// Meta row: downloads / follows / last updated
@property (nonatomic, strong) UIStackView *metaInfoStack;

// Tag container (multi-line horizontal stack that wraps automatically)
@property (nonatomic, strong) UIStackView *categoriesStack;

// Description area
@property (nonatomic, strong) UILabel *descriptionLabel;
@property (nonatomic, strong) UIButton *expandToggleButton;

// Current expanded state
@property (nonatomic, assign) BOOL descriptionExpanded;
// Whether the description exceeds 3 lines (decides whether the expand button is shown)
@property (nonatomic, assign) BOOL descriptionTruncated;

// Cached placeholder configuration
@property (nonatomic, copy, nullable) NSString *placeholderSymbolName;
@property (nonatomic, strong, nullable) UIColor *placeholderColor;

@end

@implementation AssetDetailHeaderView

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        self.backgroundColor = [UIColor clearColor];
        [self setupViews];
    }
    return self;
}

#pragma mark - Setup

- (void)setupViews {
    // ===== Card container: rounded corners + translucent background + light shadow (matching ModernAssetCell / ModVersionTableViewCell) =====
    self.cardContainer = [[UIView alloc] init];
    self.cardContainer.translatesAutoresizingMaskIntoConstraints = NO;
    self.cardContainer.backgroundColor = [[UIColor whiteColor] colorWithAlphaComponent:0.08];
    self.cardContainer.layer.cornerRadius = 16;
    self.cardContainer.layer.cornerCurve = kCACornerCurveContinuous;
    self.cardContainer.layer.borderWidth = 0.5;
    self.cardContainer.layer.borderColor = [[UIColor whiteColor] colorWithAlphaComponent:0.10].CGColor;
    self.cardContainer.layer.shadowColor = [UIColor blackColor].CGColor;
    self.cardContainer.layer.shadowOffset = CGSizeMake(0, 4);
    self.cardContainer.layer.shadowOpacity = 0.12;
    self.cardContainer.layer.shadowRadius = 8;
    [self addSubview:self.cardContainer];

    // Apply the frosted-glass background effect (consistent with the launcher style)
    [[BackgroundManager sharedManager] applyEffectToView:self.cardContainer];

    // ===== Top horizontal area: cover image + title/author =====
    // Cover image container (72x72, 14pt radius, translucent placeholder background)
    self.iconPlaceholderContainer = [[UIView alloc] init];
    self.iconPlaceholderContainer.translatesAutoresizingMaskIntoConstraints = NO;
    self.iconPlaceholderContainer.backgroundColor = [[UIColor whiteColor] colorWithAlphaComponent:0.10];
    self.iconPlaceholderContainer.layer.cornerRadius = 14;
    self.iconPlaceholderContainer.layer.cornerCurve = kCACornerCurveContinuous;
    self.iconPlaceholderContainer.layer.masksToBounds = YES;
    [self.cardContainer addSubview:self.iconPlaceholderContainer];

    // Placeholder SF Symbol (centered inside the cover container, hidden once a real image loads)
    self.placeholderSymbolView = [[UIImageView alloc] init];
    self.placeholderSymbolView.translatesAutoresizingMaskIntoConstraints = NO;
    self.placeholderSymbolView.contentMode = UIViewContentModeScaleAspectFit;
    self.placeholderSymbolView.tintColor = [UIColor systemBlueColor];
    [self.iconPlaceholderContainer addSubview:self.placeholderSymbolView];

    // Real cover ImageView (sits on top of the placeholder container, shown once an image loads)
    self.iconImageView = [[UIImageView alloc] init];
    self.iconImageView.translatesAutoresizingMaskIntoConstraints = NO;
    self.iconImageView.contentMode = UIViewContentModeScaleAspectFill;
    self.iconImageView.clipsToBounds = YES;
    self.iconImageView.layer.cornerRadius = 14;
    self.iconImageView.layer.cornerCurve = kCACornerCurveContinuous;
    self.iconImageView.backgroundColor = [UIColor clearColor];
    // Always visible: on success the real image covers the placeholder SF Symbol below; while loading or on failure it stays transparent so the placeholder shows
    self.iconImageView.hidden = NO;
    [self.iconPlaceholderContainer addSubview:self.iconImageView];

    // Title (18pt bold, at most 2 lines)
    self.titleLabel = [[UILabel alloc] init];
    self.titleLabel.translatesAutoresizingMaskIntoConstraints = NO;
    self.titleLabel.font = [UIFont systemFontOfSize:18 weight:UIFontWeightBold];
    self.titleLabel.textColor = [UIColor labelColor];
    self.titleLabel.numberOfLines = 2;
    self.titleLabel.adjustsFontSizeToFitWidth = YES;
    self.titleLabel.minimumScaleFactor = 0.75;
    self.titleLabel.lineBreakMode = NSLineBreakByTruncatingTail;
    [self.cardContainer addSubview:self.titleLabel];

    // Author (13pt secondary, with a person.crop.circle icon, via NSAttributedString)
    self.authorLabel = [[UILabel alloc] init];
    self.authorLabel.translatesAutoresizingMaskIntoConstraints = NO;
    self.authorLabel.font = [UIFont systemFontOfSize:13];
    self.authorLabel.textColor = [UIColor secondaryLabelColor];
    self.authorLabel.numberOfLines = 1;
    self.authorLabel.lineBreakMode = NSLineBreakByTruncatingTail;
    [self.cardContainer addSubview:self.authorLabel];

    // ===== Meta row: downloads / follows / last updated =====
    self.metaInfoStack = [[UIStackView alloc] init];
    self.metaInfoStack.translatesAutoresizingMaskIntoConstraints = NO;
    self.metaInfoStack.axis = UILayoutConstraintAxisHorizontal;
    self.metaInfoStack.spacing = 14;
    self.metaInfoStack.alignment = UIStackViewAlignmentCenter;
    self.metaInfoStack.distribution = UIStackViewDistributionFill;
    [self.cardContainer addSubview:self.metaInfoStack];

    // ===== Tag container (vertical stack whose rows are horizontal stacks, wrapping automatically) =====
    self.categoriesStack = [[UIStackView alloc] init];
    self.categoriesStack.translatesAutoresizingMaskIntoConstraints = NO;
    self.categoriesStack.axis = UILayoutConstraintAxisVertical;
    self.categoriesStack.spacing = 6;
    self.categoriesStack.alignment = UIStackViewAlignmentLeading;
    [self.cardContainer addSubview:self.categoriesStack];

    // ===== Description area =====
    self.descriptionLabel = [[UILabel alloc] init];
    self.descriptionLabel.translatesAutoresizingMaskIntoConstraints = NO;
    self.descriptionLabel.font = [UIFont systemFontOfSize:14];
    self.descriptionLabel.textColor = [UIColor secondaryLabelColor];
    self.descriptionLabel.numberOfLines = 3; // 3 lines by default
    self.descriptionLabel.lineBreakMode = NSLineBreakByTruncatingTail;
    [self.cardContainer addSubview:self.descriptionLabel];

    // Expand/collapse button
    self.expandToggleButton = [UIButton buttonWithType:UIButtonTypeSystem];
    self.expandToggleButton.translatesAutoresizingMaskIntoConstraints = NO;
    self.expandToggleButton.titleLabel.font = [UIFont systemFontOfSize:13 weight:UIFontWeightSemibold];
    [self.expandToggleButton setTitle:@"Expand" forState:UIControlStateNormal];
    [self.expandToggleButton addTarget:self action:@selector(toggleDescriptionExpanded) forControlEvents:UIControlEventTouchUpInside];
    self.expandToggleButton.hidden = YES; // Hidden by default, shown only when the description exceeds 3 lines
    [self.cardContainer addSubview:self.expandToggleButton];

    // ===== Layout constraints =====
    [NSLayoutConstraint activateConstraints:@[
        // Card container: 16pt margin left and right, 8pt top and bottom
        [self.cardContainer.topAnchor constraintEqualToAnchor:self.topAnchor constant:8],
        [self.cardContainer.leadingAnchor constraintEqualToAnchor:self.leadingAnchor constant:16],
        [self.cardContainer.trailingAnchor constraintEqualToAnchor:self.trailingAnchor constant:-16],
        [self.cardContainer.bottomAnchor constraintEqualToAnchor:self.bottomAnchor constant:-8],

        // Cover container: 72x72, 16pt from the top and left
        [self.iconPlaceholderContainer.topAnchor constraintEqualToAnchor:self.cardContainer.topAnchor constant:16],
        [self.iconPlaceholderContainer.leadingAnchor constraintEqualToAnchor:self.cardContainer.leadingAnchor constant:16],
        [self.iconPlaceholderContainer.widthAnchor constraintEqualToConstant:72],
        [self.iconPlaceholderContainer.heightAnchor constraintEqualToConstant:72],

        // Placeholder SF Symbol centered, 28x28
        [self.placeholderSymbolView.centerXAnchor constraintEqualToAnchor:self.iconPlaceholderContainer.centerXAnchor],
        [self.placeholderSymbolView.centerYAnchor constraintEqualToAnchor:self.iconPlaceholderContainer.centerYAnchor],
        [self.placeholderSymbolView.widthAnchor constraintEqualToConstant:30],
        [self.placeholderSymbolView.heightAnchor constraintEqualToConstant:30],

        // The real cover image fills the placeholder container
        [self.iconImageView.topAnchor constraintEqualToAnchor:self.iconPlaceholderContainer.topAnchor],
        [self.iconImageView.leadingAnchor constraintEqualToAnchor:self.iconPlaceholderContainer.leadingAnchor],
        [self.iconImageView.trailingAnchor constraintEqualToAnchor:self.iconPlaceholderContainer.trailingAnchor],
        [self.iconImageView.bottomAnchor constraintEqualToAnchor:self.iconPlaceholderContainer.bottomAnchor],

        // Title: 12pt to the right of the cover, top-aligned, 16pt margin on the right
        [self.titleLabel.leadingAnchor constraintEqualToAnchor:self.iconPlaceholderContainer.trailingAnchor constant:12],
        [self.titleLabel.topAnchor constraintEqualToAnchor:self.cardContainer.topAnchor constant:18],
        [self.titleLabel.trailingAnchor constraintEqualToAnchor:self.cardContainer.trailingAnchor constant:-16],

        // Author: 4pt below the title
        [self.authorLabel.leadingAnchor constraintEqualToAnchor:self.titleLabel.leadingAnchor],
        [self.authorLabel.topAnchor constraintEqualToAnchor:self.titleLabel.bottomAnchor constant:4],
        [self.authorLabel.trailingAnchor constraintEqualToAnchor:self.titleLabel.trailingAnchor],

        // Meta row: 14pt below the cover image, 16pt from the left
        [self.metaInfoStack.topAnchor constraintEqualToAnchor:self.iconPlaceholderContainer.bottomAnchor constant:14],
        [self.metaInfoStack.leadingAnchor constraintEqualToAnchor:self.cardContainer.leadingAnchor constant:16],
        [self.metaInfoStack.trailingAnchor constraintLessThanOrEqualToAnchor:self.cardContainer.trailingAnchor constant:-16],

        // Tag container: 12pt below the meta row
        [self.categoriesStack.topAnchor constraintEqualToAnchor:self.metaInfoStack.bottomAnchor constant:12],
        [self.categoriesStack.leadingAnchor constraintEqualToAnchor:self.cardContainer.leadingAnchor constant:16],
        [self.categoriesStack.trailingAnchor constraintEqualToAnchor:self.cardContainer.trailingAnchor constant:-16],

        // Description area: 12pt below the tag container
        [self.descriptionLabel.topAnchor constraintEqualToAnchor:self.categoriesStack.bottomAnchor constant:12],
        [self.descriptionLabel.leadingAnchor constraintEqualToAnchor:self.cardContainer.leadingAnchor constant:16],
        [self.descriptionLabel.trailingAnchor constraintEqualToAnchor:self.cardContainer.trailingAnchor constant:-16],

        // Expand button: 6pt below the description, right-aligned
        [self.expandToggleButton.topAnchor constraintEqualToAnchor:self.descriptionLabel.bottomAnchor constant:6],
        [self.expandToggleButton.trailingAnchor constraintEqualToAnchor:self.cardContainer.trailingAnchor constant:-16],
        [self.expandToggleButton.bottomAnchor constraintEqualToAnchor:self.cardContainer.bottomAnchor constant:-16],
    ]];
}

#pragma mark - Configure

- (void)configureWithIconURL:(nullable NSString *)iconURL
                       title:(NSString *)title
                      author:(nullable NSString *)author
                   downloads:(nullable NSNumber *)downloads
                       likes:(nullable NSNumber *)likes
             descriptionText:(nullable NSString *)descriptionText
                 categories:(nullable NSArray<NSString *> *)categories
                lastUpdated:(nullable NSString *)lastUpdated
        placeholderSymbolName:(NSString *)placeholderSymbolName
            placeholderColor:(UIColor *)placeholderColor {
    // Cache the placeholder configuration (used as a fallback if the image fails to load)
    self.placeholderSymbolName = placeholderSymbolName;
    self.placeholderColor = placeholderColor;

    // --- Title ---
    self.titleLabel.text = title ?: @"Unknown project";

    // --- Author ---
    if (author.length > 0) {
        // Combine an SF Symbol with text, following how FCL shows authors
        UIImageSymbolConfiguration *symbolConfig = [UIImageSymbolConfiguration configurationWithPointSize:12 weight:UIFontWeightRegular];
        UIImage *personIcon = [UIImage systemImageNamed:@"person.crop.circle" withConfiguration:symbolConfig];
        NSMutableAttributedString *attrText = [[NSMutableAttributedString alloc] init];
        if (personIcon) {
            NSTextAttachment *attachment = [[NSTextAttachment alloc] init];
            attachment.image = personIcon;
            attachment.bounds = CGRectMake(0, -1, 12, 12);
            [attrText appendAttributedString:[NSAttributedString attributedStringWithAttachment:attachment]];
            [attrText appendAttributedString:[[NSAttributedString alloc] initWithString:@" "]];
        }
        [attrText appendAttributedString:[[NSAttributedString alloc] initWithString:author
                                                                       attributes:@{NSFontAttributeName: [UIFont systemFontOfSize:13],
                                                                                    NSForegroundColorAttributeName: [UIColor secondaryLabelColor]}]];
        self.authorLabel.attributedText = attrText;
    } else {
        self.authorLabel.text = @"Unknown author";
    }

    // --- Meta row ---
    [self rebuildMetaInfoStackWithDownloads:downloads likes:likes lastUpdated:lastUpdated];

    // --- Tag row ---
    [self rebuildCategoriesStackWithCategories:categories];

    // --- Description ---
    NSString *desc = descriptionText.length > 0 ? descriptionText : @"No description";
    self.descriptionLabel.text = desc;
    self.descriptionExpanded = NO;
    self.descriptionLabel.numberOfLines = 3;

    // Detect whether the description exceeds 3 lines (decides whether the expand button is shown)
    [self evaluateDescriptionTruncation];

    // --- Cover image ---
    [self loadIconFromURL:iconURL placeholderSymbolName:placeholderSymbolName placeholderColor:placeholderColor];
}

#pragma mark - Meta Info

/// Rebuild the meta row (downloads / follows / last updated)
- (void)rebuildMetaInfoStackWithDownloads:(nullable NSNumber *)downloads
                                    likes:(nullable NSNumber *)likes
                             lastUpdated:(nullable NSString *)lastUpdated {
    // Clear the old ones
    [self.metaInfoStack.arrangedSubviews makeObjectsPerformSelector:@selector(removeFromSuperview)];

    // Downloads
    if (downloads) {
        UIView *item = [self createMetaInfoItemWithSymbol:@"arrow.down.circle"
                                                    text:[self formatDownloadCount:downloads.integerValue]
                                               tintColor:[UIColor systemBlueColor]];
        [self.metaInfoStack addArrangedSubview:item];
    }

    // Follows
    if (likes) {
        UIView *item = [self createMetaInfoItemWithSymbol:@"heart"
                                                    text:[self formatDownloadCount:likes.integerValue]
                                               tintColor:[UIColor systemPinkColor]];
        [self.metaInfoStack addArrangedSubview:item];
    }

    // Last updated
    if (lastUpdated.length > 0) {
        UIView *item = [self createMetaInfoItemWithSymbol:@"clock"
                                                    text:[self formatDateString:lastUpdated]
                                               tintColor:[UIColor systemOrangeColor]];
        [self.metaInfoStack addArrangedSubview:item];
    }
}

/// Build a single meta item (SF Symbol + text, laid out horizontally)
- (UIView *)createMetaInfoItemWithSymbol:(NSString *)symbolName
                                    text:(NSString *)text
                               tintColor:(UIColor *)tintColor {
    UIImageSymbolConfiguration *config = [UIImageSymbolConfiguration configurationWithPointSize:13 weight:UIFontWeightMedium];
    UIImage *symbolImage = [UIImage systemImageNamed:symbolName withConfiguration:config] ?: [UIImage systemImageNamed:symbolName];

    UIImageView *iconView = [[UIImageView alloc] initWithImage:symbolImage];
    iconView.translatesAutoresizingMaskIntoConstraints = NO;
    iconView.tintColor = tintColor;
    iconView.contentMode = UIViewContentModeScaleAspectFit;

    UILabel *label = [[UILabel alloc] init];
    label.translatesAutoresizingMaskIntoConstraints = NO;
    label.font = [UIFont systemFontOfSize:13 weight:UIFontWeightMedium];
    label.textColor = [UIColor secondaryLabelColor];
    label.text = text;
    label.adjustsFontSizeToFitWidth = YES;
    label.minimumScaleFactor = 0.7;

    UIStackView *item = [[UIStackView alloc] initWithArrangedSubviews:@[iconView, label]];
    item.translatesAutoresizingMaskIntoConstraints = NO;
    item.axis = UILayoutConstraintAxisHorizontal;
    item.spacing = 3;
    item.alignment = UIStackViewAlignmentCenter;

    [NSLayoutConstraint activateConstraints:@[
        [iconView.widthAnchor constraintEqualToConstant:15],
        [iconView.heightAnchor constraintEqualToConstant:15],
    ]];

    [item setContentHuggingPriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisHorizontal];
    [item setContentCompressionResistancePriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisHorizontal];
    return item;
}

#pragma mark - Categories (标签 pill)

/// Rebuild the tag row (wrapping automatically: one horizontal stack per row, wrapping when the container width is exceeded)
- (void)rebuildCategoriesStackWithCategories:(nullable NSArray<NSString *> *)categories {
    // Clear the old ones
    [self.categoriesStack.arrangedSubviews makeObjectsPerformSelector:@selector(removeFromSuperview)];

    if (![categories isKindOfClass:[NSArray class]] || categories.count == 0) return;

    // Estimate the available width (card width - 32pt of horizontal padding)
    // Note: layout may not be complete yet, so estimate using the cardContainer constraints
    CGFloat availableWidth = MAX(self.bounds.size.width - 16 * 2 - 16 * 2, 200); // 16pt outside the card + 16pt inside, on each side

    UIStackView *currentLine = [self createCategoriesLineStack];
    CGFloat currentLineWidth = 0;
    CGFloat spacing = 6;

    for (NSString *category in categories) {
        if (![category isKindOfClass:[NSString class]] || category.length == 0) continue;

        UILabel *badge = [self createCategoryBadge:category];
        // sizeToFit to get the actual width
        [badge sizeToFit];
        CGFloat badgeWidth = badge.frame.size.width + 16; // + 8pt padding on each side (already added in createCategoryBadge; recomputed here after sizeToFit)
        // Correction: createCategoryBadge already sets a width constraint, so estimate using the pre-constraint sizeToFit width + padding
        [badge invalidateIntrinsicContentSize];
        CGFloat estimateWidth = [badge systemLayoutSizeFittingSize:UILayoutFittingCompressedSize].width;

        if (currentLineWidth + estimateWidth > availableWidth && currentLine.arrangedSubviews.count > 0) {
            // Does not fit on the current row, so wrap
            [self.categoriesStack addArrangedSubview:currentLine];
            currentLine = [self createCategoriesLineStack];
            currentLineWidth = 0;
        }

        [currentLine addArrangedSubview:badge];
        currentLineWidth += estimateWidth + spacing;
    }

    // Add the last row
    if (currentLine.arrangedSubviews.count > 0) {
        [self.categoriesStack addArrangedSubview:currentLine];
    }
}

/// Build the horizontal stack for one tag row
- (UIStackView *)createCategoriesLineStack {
    UIStackView *line = [[UIStackView alloc] init];
    line.axis = UILayoutConstraintAxisHorizontal;
    line.spacing = 6;
    line.alignment = UIStackViewAlignmentCenter;
    line.distribution = UIStackViewDistributionFill;
    return line;
}

/// Build a single tag pill (8pt radius, 18pt tall, 10pt bold white text, colored by the category brand color)
- (UILabel *)createCategoryBadge:(NSString *)category {
    UILabel *badge = [[UILabel alloc] init];
    badge.text = category;
    badge.font = [UIFont systemFontOfSize:10 weight:UIFontWeightBold];
    badge.textColor = [UIColor whiteColor];
    badge.textAlignment = NSTextAlignmentCenter;
    badge.backgroundColor = [self colorForCategory:category];
    badge.layer.cornerRadius = 8;
    badge.layer.cornerCurve = kCACornerCurveContinuous;
    badge.layer.masksToBounds = YES;
    badge.translatesAutoresizingMaskIntoConstraints = NO;

    [badge setContentHuggingPriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisHorizontal];
    [badge setContentCompressionResistancePriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisHorizontal];

    // Fixed height of 18pt
    [NSLayoutConstraint activateConstraints:@[
        [badge.heightAnchor constraintEqualToConstant:18]
    ]];

    // Width = text width + 12pt of horizontal padding
    [badge sizeToFit];
    CGFloat textWidth = badge.frame.size.width;
    [badge.widthAnchor constraintEqualToConstant:textWidth + 12].active = YES;
    return badge;
}

/// Category name -> brand color mapping (loader brand colors are delegated to ModLoaderIconHelper; category colors stay local)
- (UIColor *)colorForCategory:(NSString *)category {
    NSString *lower = category.lowercaseString;

    // Loader brand colors: delegated to ModLoaderIconHelper (which prefers the official colors of the PNG icons)
    if ([ModLoaderIconHelper isKnownLoader:category]) {
        return [ModLoaderIconHelper brandColorForLoader:category];
    }

    // Common category colors
    if ([lower containsString:@"performance"])   return [UIColor colorWithRed:0.30 green:0.80 blue:0.40 alpha:1.0]; // green
    if ([lower containsString:@"optimization"])  return [UIColor colorWithRed:0.30 green:0.80 blue:0.40 alpha:1.0];
    if ([lower containsString:@"utility"])       return [UIColor colorWithRed:0.35 green:0.60 blue:0.85 alpha:1.0]; // blue
    if ([lower containsString:@"tech"])          return [UIColor colorWithRed:0.75 green:0.55 blue:0.20 alpha:1.0]; // brownish yellow
    if ([lower containsString:@"magic"])         return [UIColor colorWithRed:0.65 green:0.40 blue:0.85 alpha:1.0]; // purple
    if ([lower containsString:@"adventure"])     return [UIColor colorWithRed:0.80 green:0.45 blue:0.30 alpha:1.0]; // orange red
    if ([lower containsString:@"worldgen"])      return [UIColor colorWithRed:0.40 green:0.70 blue:0.40 alpha:1.0]; // green
    if ([lower containsString:@"decoration"])    return [UIColor colorWithRed:0.90 green:0.55 blue:0.65 alpha:1.0]; // pink
    if ([lower containsString:@"storage"])       return [UIColor colorWithRed:0.55 green:0.55 blue:0.60 alpha:1.0]; // gray
    if ([lower containsString:@"food"])          return [UIColor colorWithRed:0.85 green:0.65 blue:0.30 alpha:1.0]; // yellow orange
    if ([lower containsString:@"transportation"]) return [UIColor colorWithRed:0.30 green:0.70 blue:0.80 alpha:1.0]; // cyan
    if ([lower containsString:@"mobs"])          return [UIColor colorWithRed:0.80 green:0.35 blue:0.40 alpha:1.0]; // red
    if ([lower containsString:@"equipment"])     return [UIColor colorWithRed:0.70 green:0.60 blue:0.45 alpha:1.0]; // brown
    if ([lower containsString:@"social"])        return [UIColor colorWithRed:0.55 green:0.45 blue:0.75 alpha:1.0]; // purple

    // Fallback: use the theme accent color (so it does not blend into the background)
    return [UIColor colorWithRed:0.45 green:0.55 blue:0.65 alpha:1.0];
}

#pragma mark - Description Expand/Collapse

/// Detect whether the description exceeds 3 lines (decides whether the expand button is shown)
- (void)evaluateDescriptionTruncation {
    [self.descriptionLabel layoutIfNeeded];

    // Method: compare the height at numberOfLines=0 (unlimited) with the height at numberOfLines=3
    // If the unlimited height is greater than the 3-line height, the text is being truncated
    CGFloat unlimitedHeight = [self calculateDescriptionHeightWithLines:0];
    CGFloat limitedHeight = [self calculateDescriptionHeightWithLines:3];

    self.descriptionTruncated = (unlimitedHeight > limitedHeight + 1);
    self.expandToggleButton.hidden = !self.descriptionTruncated;

    if (self.descriptionTruncated) {
        [self.expandToggleButton setTitle:@"Expand" forState:UIControlStateNormal];
    }
}

/// Compute the height of the description label under a given line limit
- (CGFloat)calculateDescriptionHeightWithLines:(NSInteger)lines {
    UILabel *measureLabel = [[UILabel alloc] init];
    measureLabel.font = self.descriptionLabel.font;
    measureLabel.numberOfLines = lines;
    measureLabel.text = self.descriptionLabel.text;
    measureLabel.lineBreakMode = NSLineBreakByTruncatingTail;

    // Use the actual current width of descriptionLabel
    CGFloat width = self.descriptionLabel.bounds.size.width;
    if (width <= 0) {
        // Layout is not finished, so use an estimated width (screen width - the card margins and padding)
        width = MAX([UIScreen mainScreen].bounds.size.width - 16 * 2 - 16 * 2, 200);
    }

    CGSize size = [measureLabel sizeThatFits:CGSizeMake(width, CGFLOAT_MAX)];
    return size.height;
}

/// Toggle the description between expanded and collapsed
- (void)toggleDescriptionExpanded {
    self.descriptionExpanded = !self.descriptionExpanded;
    self.descriptionLabel.numberOfLines = self.descriptionExpanded ? 0 : 3;
    [self.expandToggleButton setTitle:self.descriptionExpanded ? @"Collapse" : @"Expand" forState:UIControlStateNormal];

    // Tell the controller to recompute the tableHeaderView height
    if (self.onSizeChanged) {
        self.onSizeChanged();
    }
}

#pragma mark - Icon Loading

/// Load the project cover image (using the unified IconLoader)
/// Mirrors the loadIcon logic of ZL2 AssetsIcon: two-level cache + downsampling + CDN mirror + placeholder/fallback
- (void)loadIconFromURL:(nullable NSString *)iconURL
   placeholderSymbolName:(NSString *)symbolName
       placeholderColor:(UIColor *)color {
    // Set the placeholder SF Symbol first (always shown underneath, covered once the real image loads)
    UIImageSymbolConfiguration *config = [UIImageSymbolConfiguration configurationWithPointSize:30 weight:UIFontWeightRegular];
    UIImage *placeholderSymbol = [UIImage systemImageNamed:symbolName withConfiguration:config] ?: [UIImage systemImageNamed:@"puzzlepiece.extension.fill" withConfiguration:config];
    self.placeholderSymbolView.image = placeholderSymbol;
    self.placeholderSymbolView.tintColor = color ?: [UIColor systemBlueColor];
    self.iconPlaceholderContainer.backgroundColor = [color ?: [UIColor systemBlueColor] colorWithAlphaComponent:0.18];

    // No URL or an invalid URL: iconImageView stays transparent so the placeholder SF Symbol below shows through
    if (!iconURL || iconURL.length == 0) {
        [IconLoader cancelLoadingForImageView:self.iconImageView];
        self.iconImageView.image = nil;
        return;
    }

    // Load via IconLoader (which brings its own memory+disk cache, downsampling and CDN mirroring), placeholderImage=nil
    // On success: iconImageView shows the real image, covering the placeholder SF Symbol below
    // While loading or on failure: iconImageView is empty (transparent) so the placeholder SF Symbol shows through
    // The cover image is displayed at 72x72 (defined in setupViews); downsample to that size to avoid decoding the full-resolution image
    [IconLoader loadIconForImageView:self.iconImageView
                                 URL:iconURL
                         placeholder:nil
                            fallback:nil
                           targetSize:CGSizeMake(72, 72)];
}

#pragma mark - Formatting Helpers

/// Format a download count (1234 -> "1.2k", 1234567 -> "1.2M")
- (NSString *)formatDownloadCount:(NSInteger)count {
    if (count >= 1000000) {
        return [NSString stringWithFormat:@"%.1fM", count / 1000000.0];
    } else if (count >= 1000) {
        return [NSString stringWithFormat:@"%.1fk", count / 1000.0];
    }
    return [NSString stringWithFormat:@"%ld", (long)count];
}

/// Format a date string (ISO8601 -> short date; non-ISO input is returned unchanged)
- (NSString *)formatDateString:(NSString *)dateString {
    if (dateString.length == 0) return @"";

    // Try to parse it as ISO8601
    NSISO8601DateFormatter *isoFormatter = [[NSISO8601DateFormatter alloc] init];
    NSDate *date = [isoFormatter dateFromString:dateString];
    if (date) {
        NSDateFormatter *displayFormatter = [[NSDateFormatter alloc] init];
        displayFormatter.dateStyle = NSDateFormatterShortStyle;
        displayFormatter.timeStyle = NSDateFormatterNoStyle;
        return [displayFormatter stringFromDate:date];
    }

    // Not ISO format, return it unchanged (it may already be formatted)
    return dateString;
}

#pragma mark - Sizing

/// Compute the height this header needs at the given width
- (CGFloat)fittingHeightForWidth:(CGFloat)width {
    // Give it a generous height and let auto layout compress it to fit
    self.frame = CGRectMake(0, 0, width, 10000);
    [self setNeedsLayout];
    [self layoutIfNeeded];

    CGSize size = [self systemLayoutSizeFittingSize:CGSizeMake(width, UILayoutFittingCompressedSize.height)
                                         withHorizontalFittingPriority:UILayoutPriorityRequired
                                               verticalFittingPriority:UILayoutPriorityFittingSizeLevel];
    return ceil(size.height);
}

@end
