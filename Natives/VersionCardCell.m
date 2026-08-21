// VersionCardCell.m
// Modeled on the single-column horizontal list row design of FCL (item_remote_version.xml) and ZL2 (VersionItemLayout):
// - Left: type icon container (40x40 rounded square, type-colored background + white SF Symbol)
// - Middle: version number (16pt semibold) + small type label (pill) on one line / release date (12pt secondary) on the next
// - Right: a chevron indicating it is tappable
// - Installed marker: a small green dot badge at the top right of the icon container (ZL2 style, so it does not cover the chevron on the right)
// It replaces the old 100x120 vertical grid card, with higher information density and visuals closer to FCL/ZL2.

#import "VersionCardCell.h"
#import "BackgroundManager.h"
#import "FluxTheme.h"

// Fix for problem 3: a UILabel subclass with inner padding, so that type label text such as "Release/Snapshot"
// is perfectly centered inside the background block and no longer overlaps the background edges.
// Overriding textRectForBounds: and drawTextInRect: injects 8pt horizontal / 0pt vertical padding
// while keeping the UILabel interface unchanged, so the typeLabel declaration in VersionCardCell.h needs no modification.
@interface InsetTypeLabel : UILabel
@property (nonatomic, assign) UIEdgeInsets textInsets;
@end

@implementation InsetTypeLabel
- (instancetype)init {
    self = [super init];
    if (self) {
        // Fix for the problem of "Release/Snapshot" text turning into "…":
        // the font size was reduced from 13pt to 11pt and the padding from (3,10,3,10) to (2,6,2,6),
        // making the pill label more compact and reducing its competition for space with versionLabel.
        // adjustsFontSizeToFitWidth is also set to make sure it is never truncated even in extreme cases.
        _textInsets = UIEdgeInsetsMake(2, 6, 2, 6);
    }
    return self;
}
- (CGRect)textRectForBounds:(CGRect)bounds limitedToNumberOfLines:(NSInteger)numberOfLines {
    CGRect insetRect = UIEdgeInsetsInsetRect(bounds, self.textInsets);
    CGRect textRect = [super textRectForBounds:insetRect limitedToNumberOfLines:numberOfLines];
    textRect.origin.x -= self.textInsets.left;
    textRect.origin.y -= self.textInsets.top;
    return textRect;
}
- (void)drawTextInRect:(CGRect)rect {
    [super drawTextInRect:UIEdgeInsetsInsetRect(rect, self.textInsets)];
}
@end

@interface VersionCardCell ()
// Container view: the rounded background of the whole card (frosted glass + translucent)
@property (nonatomic, strong) UIView *cardContainer;
// Left type icon container (with rounded corners and a type-colored background)
@property (nonatomic, strong) UIView *iconContainer;
// Top row horizontal stack: holds versionLabel + typeLabel, handling spacing and clipping automatically
@property (nonatomic, strong) UIStackView *topRowStack;
// Chevron indicator on the right
@property (nonatomic, strong) UIImageView *chevronView;
@end

@implementation VersionCardCell

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        // The outer cell is transparent; cardContainer provides the visuals
        self.backgroundColor = [UIColor clearColor];
        self.contentView.backgroundColor = [UIColor clearColor];
        self.layer.masksToBounds = NO;

        // ----- Card container: rounded corners + background + light shadow (matching the VMTileBaseCell shadow standard) -----
        //
        // Key fix (card too transparent):
        // A hardcoded white 8% alpha translucent background used to be used, which made the card almost invisible
        // after switching to certain custom background wallpapers, leaving extremely low text/background contrast and badly hurting readability.
        // Now BackgroundManager.applyEffectToView: applies the same effect as the launcher's other cards
        // (such as mod/shader resource cards and version management tiles):
        //   - Frosted glass mode: insert a UIBlurEffect (SystemThinMaterial), adapting to light/dark mode
        //   - Translucent mode: use secondarySystemBackgroundColor + the user's custom opacity
        // This way the card background adapts to the user's background settings and is no longer too transparent.
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

        // Apply the BackgroundManager effect (frosted glass/translucent, adaptive), fixing the too-transparent problem
        [[BackgroundManager sharedManager] applyEffectToView:self.cardContainer];

        // ----- Left icon container: 40x40 rounded square with a type-colored background -----
        self.iconContainer = [[UIView alloc] init];
        self.iconContainer.translatesAutoresizingMaskIntoConstraints = NO;
        self.iconContainer.layer.cornerRadius = 10;
        self.iconContainer.layer.cornerCurve = kCACornerCurveContinuous;
        self.iconContainer.layer.masksToBounds = YES;
        self.iconContainer.backgroundColor = [UIColor systemGreenColor];
        [self.cardContainer addSubview:self.iconContainer];

        // The icon itself: a white SF Symbol, centered
        self.iconImageView = [[UIImageView alloc] init];
        self.iconImageView.translatesAutoresizingMaskIntoConstraints = NO;
        self.iconImageView.contentMode = UIViewContentModeScaleAspectFit;
        self.iconImageView.tintColor = [UIColor whiteColor];
        self.iconImageView.image = [UIImage systemImageNamed:@"cube.fill"];
        [self.iconContainer addSubview:self.iconImageView];

        // ----- Version number -----
        self.versionLabel = [[UILabel alloc] init];
        self.versionLabel.translatesAutoresizingMaskIntoConstraints = NO;
        self.versionLabel.font = [UIFont systemFontOfSize:16 weight:UIFontWeightSemibold];
        self.versionLabel.textColor = [UIColor labelColor];
        self.versionLabel.adjustsFontSizeToFitWidth = YES;
        self.versionLabel.minimumScaleFactor = 0.7;
        self.versionLabel.lineBreakMode = NSLineBreakByTruncatingTail;
        // The version number has high hugging (does not stretch on its own) and low compression resistance (it is compressed first when space runs out → triggering the font size reduction)
        [self.versionLabel setContentHuggingPriority:UILayoutPriorityDefaultHigh forAxis:UILayoutConstraintAxisHorizontal];
        [self.versionLabel setContentCompressionResistancePriority:UILayoutPriorityDefaultLow forAxis:UILayoutConstraintAxisHorizontal];

        // ----- Type label (pill style, fixing the problem of "Release/Snapshot" text turning into "…") -----
        // the font size was reduced from 13pt to 11pt and the padding from (3,10,3,10) to (2,6,2,6),
        // cornerRadius was reduced from 10 to 8 to make the pill more compact.
        // adjustsFontSizeToFitWidth + minimumScaleFactor=0.8 are set as a fallback,
        // making sure the text is never truncated to "…" under any circumstances.
        self.typeLabel = [[InsetTypeLabel alloc] init];
        self.typeLabel.translatesAutoresizingMaskIntoConstraints = NO;
        self.typeLabel.font = [UIFont systemFontOfSize:11 weight:UIFontWeightBold];
        self.typeLabel.textColor = [UIColor whiteColor];
        self.typeLabel.textAlignment = NSTextAlignmentCenter;
        self.typeLabel.adjustsFontSizeToFitWidth = YES;
        self.typeLabel.minimumScaleFactor = 0.8;
        self.typeLabel.lineBreakMode = NSLineBreakByClipping;
        self.typeLabel.layer.cornerRadius = 8;
        self.typeLabel.layer.cornerCurve = kCACornerCurveContinuous;
        self.typeLabel.layer.masksToBounds = YES;
        // The type label has both high hugging and high compression resistance (keeping the full pill shape uncompressed)
        [self.typeLabel setContentHuggingPriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisHorizontal];
        [self.typeLabel setContentCompressionResistancePriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisHorizontal];

        // ----- Top row stack: version number + type label laid out horizontally -----
        // Fix for the "wrong position" problem: alignment changed from FirstBaseline to Center,
        // avoiding the visual offset of typeLabel caused by InsetTypeLabel's vertical padding.
        // distribution changed to Fill so that versionLabel is compressed first while typeLabel stays intact.
        self.topRowStack = [[UIStackView alloc] initWithArrangedSubviews:@[self.versionLabel, self.typeLabel]];
        self.topRowStack.translatesAutoresizingMaskIntoConstraints = NO;
        self.topRowStack.axis = UILayoutConstraintAxisHorizontal;
        self.topRowStack.alignment = UIStackViewAlignmentCenter;
        self.topRowStack.distribution = UIStackViewDistributionFill;
        self.topRowStack.spacing = 8;
        [self.cardContainer addSubview:self.topRowStack];

        // ----- Date -----
        self.dateLabel = [[UILabel alloc] init];
        self.dateLabel.translatesAutoresizingMaskIntoConstraints = NO;
        self.dateLabel.font = [UIFont systemFontOfSize:12];
        self.dateLabel.textColor = [UIColor secondaryLabelColor];
        self.dateLabel.adjustsFontSizeToFitWidth = YES;
        self.dateLabel.minimumScaleFactor = 0.7;
        self.dateLabel.lineBreakMode = NSLineBreakByTruncatingTail;
        [self.cardContainer addSubview:self.dateLabel];

        // ----- Chevron on the right: hints that tapping enters loader selection -----
        self.chevronView = [[UIImageView alloc] initWithImage:[UIImage systemImageNamed:@"chevron.right"]];
        self.chevronView.translatesAutoresizingMaskIntoConstraints = NO;
        self.chevronView.tintColor = [UIColor tertiaryLabelColor];
        self.chevronView.contentMode = UIViewContentModeScaleAspectFit;
        // The chevron has a fixed size and is not stretched
        [self.chevronView setContentHuggingPriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisHorizontal];
        [self.chevronView setContentCompressionResistancePriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisHorizontal];
        [self.cardContainer addSubview:self.chevronView];

        // ----- Installed badge: a small green dot at the top right of the icon container (ZL2 style) -----
        // Instead of a large green ✓ occupying the top-right corner of the card, a 14pt dot is placed at the top right of iconContainer,
        // which keeps the "installed" indication without covering the chevron and the version number on the right.
        self.installedBadge = [[UIView alloc] init];
        self.installedBadge.translatesAutoresizingMaskIntoConstraints = NO;
        self.installedBadge.backgroundColor = [UIColor systemGreenColor];
        self.installedBadge.layer.cornerRadius = 7;
        self.installedBadge.layer.masksToBounds = YES;
        self.installedBadge.layer.borderColor = [UIColor systemBackgroundColor].CGColor;
        self.installedBadge.layer.borderWidth = 1.5;
        self.installedBadge.hidden = YES;
        [self.cardContainer addSubview:self.installedBadge];

        // The small ✓ inside (white, centered)
        UIImageView *checkmark = [[UIImageView alloc] init];
        checkmark.translatesAutoresizingMaskIntoConstraints = NO;
        checkmark.image = [UIImage systemImageNamed:@"checkmark"
                                  withConfiguration:[UIImageSymbolConfiguration configurationWithPointSize:7 weight:UIFontWeightBold]];
        checkmark.tintColor = [UIColor whiteColor];
        [self.installedBadge addSubview:checkmark];

        // ----- Layout constraints -----
        [NSLayoutConstraint activateConstraints:@[
            // cardContainer fills contentView (0 outer margin; spacing is controlled by the collection layout's sectionInset)
            [self.cardContainer.topAnchor constraintEqualToAnchor:self.contentView.topAnchor constant:4],
            [self.cardContainer.leadingAnchor constraintEqualToAnchor:self.contentView.leadingAnchor constant:0],
            [self.cardContainer.trailingAnchor constraintEqualToAnchor:self.contentView.trailingAnchor constant:0],
            [self.cardContainer.bottomAnchor constraintEqualToAnchor:self.contentView.bottomAnchor constant:-4],

            // Icon container: 14 from the left, vertically centered, 40x40
            [self.iconContainer.leadingAnchor constraintEqualToAnchor:self.cardContainer.leadingAnchor constant:14],
            [self.iconContainer.centerYAnchor constraintEqualToAnchor:self.cardContainer.centerYAnchor],
            [self.iconContainer.widthAnchor constraintEqualToConstant:40],
            [self.iconContainer.heightAnchor constraintEqualToConstant:40],

            // The icon is centered in the container, 22x22
            [self.iconImageView.centerXAnchor constraintEqualToAnchor:self.iconContainer.centerXAnchor],
            [self.iconImageView.centerYAnchor constraintEqualToAnchor:self.iconContainer.centerYAnchor],
            [self.iconImageView.widthAnchor constraintEqualToConstant:22],
            [self.iconImageView.heightAnchor constraintEqualToConstant:22],

            // Top row stack: +14 to the right of the icon container, top aligned to the top of cardContainer +14
            // 8pt of room is left between it and the chevron on the right; the stack distributes the versionLabel/typeLabel widths automatically
            [self.topRowStack.leadingAnchor constraintEqualToAnchor:self.iconContainer.trailingAnchor constant:14],
            [self.topRowStack.topAnchor constraintEqualToAnchor:self.cardContainer.topAnchor constant:14],
            [self.topRowStack.trailingAnchor constraintEqualToAnchor:self.chevronView.leadingAnchor constant:-8],

            // Date: left aligned with the top row stack, +3 below it
            [self.dateLabel.leadingAnchor constraintEqualToAnchor:self.topRowStack.leadingAnchor],
            [self.dateLabel.topAnchor constraintEqualToAnchor:self.topRowStack.bottomAnchor constant:3],
            [self.dateLabel.trailingAnchor constraintEqualToAnchor:self.topRowStack.trailingAnchor],
            [self.dateLabel.bottomAnchor constraintLessThanOrEqualToAnchor:self.cardContainer.bottomAnchor constant:-12],

            // chevron: -14 from the right, vertically centered, 14x14
            [self.chevronView.trailingAnchor constraintEqualToAnchor:self.cardContainer.trailingAnchor constant:-14],
            [self.chevronView.centerYAnchor constraintEqualToAnchor:self.cardContainer.centerYAnchor],
            [self.chevronView.widthAnchor constraintEqualToConstant:14],
            [self.chevronView.heightAnchor constraintEqualToConstant:14],

            // Installed badge: attached to the top right of iconContainer, 14x14
            [self.installedBadge.topAnchor constraintEqualToAnchor:self.iconContainer.topAnchor constant:-4],
            [self.installedBadge.trailingAnchor constraintEqualToAnchor:self.iconContainer.trailingAnchor constant:4],
            [self.installedBadge.widthAnchor constraintEqualToConstant:14],
            [self.installedBadge.heightAnchor constraintEqualToConstant:14],
            [checkmark.centerXAnchor constraintEqualToAnchor:self.installedBadge.centerXAnchor],
            [checkmark.centerYAnchor constraintEqualToAnchor:self.installedBadge.centerYAnchor]
        ]];
    }
    return self;
}

- (void)configureWithVersionId:(NSString *)versionId
                          date:(NSString *)date
                          type:(NSString *)type {
    self.versionLabel.text = versionId;
    self.dateLabel.text = date;

    // Type → icon + color mapping (modeled on ZL2's VersionIconPreview, which switches the icon by version type):
    // release → cube.fill + systemGreen (stable release)
    // snapshot → hammer.fill + systemOrange (snapshot/in development)
    // old_alpha → clock.fill + systemPurple (ancient alpha)
    // old_beta  → clock.fill + systemPurple (ancient beta)
    NSString *iconName = @"cube.fill";
    UIColor *typeColor = [UIColor systemGreenColor];
    NSString *typeText = @"Release";

    if ([type isEqualToString:@"Release"] || [type isEqualToString:@"release"]) {
        iconName = @"cube.fill";
        typeColor = [UIColor systemGreenColor];
        typeText = @"Release";
    } else if ([type isEqualToString:@"Snapshot"] || [type isEqualToString:@"snapshot"]) {
        iconName = @"hammer.fill";
        typeColor = [UIColor systemOrangeColor];
        typeText = @"Snapshot";
    } else if ([type isEqualToString:@"old_alpha"]) {
        iconName = @"clock.fill";
        typeColor = [UIColor systemPurpleColor];
        typeText = @"Alpha";
    } else if ([type isEqualToString:@"old_beta"]) {
        iconName = @"clock.fill";
        typeColor = [UIColor systemPurpleColor];
        typeText = @"Beta";
    } else {
        // Fallback: ancient versions (used when old_alpha and old_beta are merged)
        iconName = @"clock.fill";
        typeColor = [UIColor systemPurpleColor];
        typeText = @"Ancient";
    }

    UIImage *symbol = [UIImage systemImageNamed:iconName];
    if (symbol) {
        self.iconImageView.image = symbol;
    }
    self.iconImageView.tintColor = [UIColor whiteColor];

    // Fix for problem 4: use the standard grass block icon shipped with the HMCL repository (grass.png/grass@2x.png),
    // which has been imported into the VanillaIcon image set in Assets.xcassets, matching mainstream launchers such as FCL/ZL2/HMCL exactly.
    // The icon fills the container (AspectFill) and the background is transparent to preserve the grass block texture's own colors.
    UIImage *vanillaIcon = [UIImage imageNamed:@"VanillaIcon"];
    if (vanillaIcon) {
        self.iconImageView.image = vanillaIcon;
        self.iconImageView.contentMode = UIViewContentModeScaleAspectFill;
        self.iconImageView.tintColor = nil; // Remove the tint so the grass block's original colors show
        // The grass block icon has its own colors, so the icon container background is set to transparent
        self.iconContainer.backgroundColor = [UIColor clearColor];
    } else {
        // Fallback: revert to the SF Symbol + type-colored background if the image set fails to load
        self.iconImageView.contentMode = UIViewContentModeScaleAspectFit;
        self.iconImageView.tintColor = [UIColor whiteColor];
        self.iconContainer.backgroundColor = [typeColor colorWithAlphaComponent:0.85];
    }

    // Type label: type-colored background + white text
    self.typeLabel.text = typeText;
    self.typeLabel.backgroundColor = typeColor;
}

- (void)setInstalled:(BOOL)installed {
    self.installedBadge.hidden = !installed;
}

- (void)prepareForReuse {
    [super prepareForReuse];
    // Reset to the SF Symbol default state (configureWithVersionId will load VanillaIcon again and override it)
    self.iconImageView.image = [UIImage systemImageNamed:@"cube.fill"];
    self.iconImageView.tintColor = [UIColor whiteColor];
    self.iconImageView.contentMode = UIViewContentModeScaleAspectFit;
    self.iconContainer.backgroundColor = [UIColor systemGreenColor];
    self.versionLabel.text = nil;
    self.dateLabel.text = nil;
    self.typeLabel.text = nil;
    self.typeLabel.backgroundColor = FluxTheme.accent;
    self.installedBadge.hidden = YES;
    self.chevronView.tintColor = [UIColor tertiaryLabelColor];
}

@end
