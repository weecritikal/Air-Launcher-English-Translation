//
//  DownloadProgressCardView.m
//  Amethyst
//
//  Implementation of the download progress card view (modelled on the download progress style of FCL/ZL2/HMCL)
//
//  ============================================================================
//  Design rationale
//  ============================================================================
//
//  This component gives downloads of versions and assets a single, information-rich progress display,
//  replacing the old UIActivityIndicatorView (a spinner) in the middle of the screen and the bottom InlineMessageView
//  (text-only progress).
//
//  It draws on the download progress design of three popular Minecraft launchers:
//
//  1. FCL (FoldCraftLauncher) style:
//     - a floating card at the bottom that does not block the rest of the launcher
//     - shows progress bar + percentage + speed + time remaining (ETA) + current file name together
//     - high information density, so the user can take in the whole download at a glance
//
//  2. ZL2 (ZalithLauncher) style:
//     - rounded frosted-glass background (which layers nicely over the content below)
//     - colored progress bar (blue while downloading, green when complete, red on failure)
//     - smooth animated progress transitions instead of abrupt jumps
//
//  3. HMCL style:
//     - a clean information layout, with status icon + title + subtitle clearly separated
//     - a status icon that clearly indicates the current stage (downloading/complete/failed/cancelled)
//
//  This component combines the strengths of all three:
//  - floating at the bottom + rounded frosted glass + shadow (FCL + ZL2)
//  - colored progress bar + smooth animation (ZL2)
//  - status icon + layered information layout (HMCL)
//  - support for indeterminate mode (progress = -1), showing a spinner while the download is being prepared
//
//  It also adapts to the launcher's custom background feature:
//  - when BackgroundManager reports a global background, frosted glass is used so it shows through
//  - with no background it falls back to secondarySystemGroupedBackgroundColor for readability
//  - it listens for BackgroundUIEffectChanged and refreshes live when the effect changes
//
//  ============================================================================

#import "DownloadProgressCardView.h"

#import "BackgroundManager.h"

/// Card visual constants
static const CGFloat kCardCornerRadius    = 16.0;
static const CGFloat kCardSideInset        = 16.0;
static const CGFloat kCardBottomInset      = 16.0;
static const CGFloat kCardInternalPadding  = 16.0;
static const CGFloat kCardShadowRadius     = 12.0;
static const CGFloat kCardShadowOpacity    = 0.18;
static const CGFloat kCardShadowOffsetY    = 4.0;

/// Progress bar visual constants
static const CGFloat kProgressBarHeight    = 6.0;
static const CGFloat kProgressBarCornerRadius = 3.0;

/// Status icon size
static const CGFloat kStatusIconSize       = 24.0;

/// Progress bar animation duration
static const NSTimeInterval kProgressAnimationDuration = 0.3;
/// Show/hide animation duration
static const NSTimeInterval kShowAnimationDuration     = 0.3;
static const NSTimeInterval kHideAnimationDuration     = 0.3;
/// How long the completed state stays before disappearing
static const NSTimeInterval kAutoDismissAfterComplete  = 1.8;
static const NSTimeInterval kAutoDismissAfterFail      = 3.0;

/// Name of the BackgroundUIEffectChanged notification (kept in sync with the rest of the project)
static NSString *const kBackgroundUIEffectChangedNotification = @"BackgroundUIEffectChanged";

/// Download state enum (used internally)
typedef NS_ENUM(NSInteger, DownloadCardState) {
    DownloadCardStateIdle        = 0,  // Idle (not started)
    DownloadCardStateDownloading = 1,  // Downloading
    DownloadCardStateIndeterminate = 2, // Indeterminate (preparing)
    DownloadCardStateCompleted   = 3,  // Complete
    DownloadCardStateFailed      = 4,  // Failed
    DownloadCardStateCancelled   = 5,  // Cancelled
};

#pragma mark - 自定义进度条视图

/// Custom progress bar view supporting smooth animation and color changes.
/// Compared with UIProgressView, this gives finer control over corner radius, color and animation curve,
/// so it can match the ZL2 look.
@interface DPCProgressBar : UIView

/// Progress from 0.0 to 1.0
@property (nonatomic, assign) CGFloat progress;
/// Fill color
@property (nonatomic, strong) UIColor *fillColor;
/// Track color
@property (nonatomic, strong) UIColor *trackColor;

/// Set the progress, optionally animated
- (void)setProgress:(CGFloat)progress animated:(BOOL)animated;

@end

@implementation DPCProgressBar {
    CAShapeLayer *_trackLayer;
    CAShapeLayer *_fillLayer;
}

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        [self setupLayers];
    }
    return self;
}

- (void)awakeFromNib {
    [super awakeFromNib];
    [self setupLayers];
}

/// Initialize the track and fill layers
- (void)setupLayers {
    _trackLayer = [CAShapeLayer layer];
    _trackLayer.fillColor = [UIColor systemGray5Color].CGColor;
    _trackLayer.lineWidth = 0;
    [self.layer addSublayer:_trackLayer];

    _fillLayer = [CAShapeLayer layer];
    _fillLayer.fillColor = [UIColor systemBlueColor].CGColor;
    _fillLayer.lineWidth = 0;
    [self.layer addSublayer:_fillLayer];

    // Defaults
    _progress = 0.0;
    _fillColor = [UIColor systemBlueColor];
    _trackColor = [UIColor systemGray5Color];

    // Clip the fill layer so it does not spill past the rounded corners
    self.layer.masksToBounds = YES;

    // Set the track color via backgroundColor, keeping the implementation simple
    self.backgroundColor = _trackColor;
}

- (void)layoutSubviews {
    [super layoutSubviews];
    [self updateLayerFrames];
}

/// Update the layer frames (rounded-rectangle paths)
- (void)updateLayerFrames {
    CGRect bounds = self.bounds;
    CGFloat cornerRadius = bounds.size.height / 2.0;

    // The track fills the whole view
    UIBezierPath *trackPath =
        [UIBezierPath bezierPathWithRoundedRect:bounds
                                  cornerRadius:cornerRadius];
    _trackLayer.path = trackPath.CGPath;
    _trackLayer.frame = bounds;

    // The fill width is derived from the progress
    CGFloat fillWidth = MAX(0.0, bounds.size.width * _progress);
    CGRect fillRect = CGRectMake(0, 0, fillWidth, bounds.size.height);
    // Use a rounded rectangle as the fill path so the right edge is not square
    UIBezierPath *fillPath =
        [UIBezierPath bezierPathWithRoundedRect:fillRect
                                  cornerRadius:cornerRadius];
    _fillLayer.path = fillPath.CGPath;
    _fillLayer.frame = bounds;
}

- (void)setProgress:(CGFloat)progress {
    [self setProgress:progress animated:NO];
}

- (void)setProgress:(CGFloat)progress animated:(BOOL)animated {
    // clamp 0.0~1.0
    progress = MAX(0.0, MIN(1.0, progress));
    _progress = progress;

    if (animated) {
        // Use CABasicAnimation to transition the fill width smoothly.
        // This is done by regenerating the path and letting it animate implicitly.
        [CATransaction begin];
        [CATransaction setAnimationDuration:kProgressAnimationDuration];
        [CATransaction setAnimationTimingFunction:
            [CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionEaseInEaseOut]];

        CGFloat fillWidth = MAX(0.0, self.bounds.size.width * progress);
        CGRect fillRect = CGRectMake(0, 0, fillWidth, self.bounds.size.height);
        CGFloat cornerRadius = self.bounds.size.height / 2.0;
        UIBezierPath *fillPath =
            [UIBezierPath bezierPathWithRoundedRect:fillRect
                                      cornerRadius:cornerRadius];
        _fillLayer.path = fillPath.CGPath;

        [CATransaction commit];
    } else {
        [self updateLayerFrames];
    }
}

- (void)setFillColor:(UIColor *)fillColor {
    if (!fillColor) return;
    _fillColor = fillColor;
    _fillLayer.fillColor = fillColor.CGColor;
}

- (void)setTrackColor:(UIColor *)trackColor {
    if (!trackColor) return;
    _trackColor = trackColor;
    _trackLayer.fillColor = trackColor.CGColor;
    self.backgroundColor = trackColor;
}

@end

#pragma mark - 主视图私有接口

@interface DownloadProgressCardView ()

// Background container (frosted glass or solid color)
@property (nonatomic, strong) UIVisualEffectView *blurEffectView;
@property (nonatomic, strong) UIView *solidBackgroundView;

// Content container (holds every subview, so padding can be applied in one place)
@property (nonatomic, strong) UIView *contentContainer;

// Top row
@property (nonatomic, strong) UIImageView *statusIconView;
@property (nonatomic, strong) UIActivityIndicatorView *spinnerView;
@property (nonatomic, strong) UILabel *percentLabel;

// Title row
@property (nonatomic, strong) UILabel *titleLabel;
@property (nonatomic, strong) UILabel *subtitleLabel;

// Progress bar
@property (nonatomic, strong) DPCProgressBar *progressBar;

// Info row (downloaded/total size + speed)
@property (nonatomic, strong) UILabel *downloadedLabel;
@property (nonatomic, strong) UILabel *speedLabel;

// ETA row
@property (nonatomic, strong) UILabel *etaLabel;

// Current file row
@property (nonatomic, strong) UILabel *currentFileLabel;

// State
@property (nonatomic, assign) DownloadCardState state;
@property (nonatomic, copy, nullable) NSString *currentTitle;
@property (nonatomic, copy, nullable) NSString *currentSubtitle;

// Byte count formatter (reused)
@property (nonatomic, strong) NSByteCountFormatter *byteFormatter;

// Whether it has been added to a superview
@property (nonatomic, assign) BOOL isShown;
// Auto-dismiss timer
@property (nonatomic, strong, nullable) NSTimer *autoDismissTimer;

// Constraint: the bottom constraint (adjusted for the show/hide animation)
@property (nonatomic, strong) NSLayoutConstraint *bottomConstraint;

@end

@implementation DownloadProgressCardView

#pragma mark - Lifecycle

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        [self commonInit];
    }
    return self;
}

- (instancetype)initWithCoder:(NSCoder *)coder {
    self = [super initWithCoder:coder];
    if (self) {
        [self commonInit];
    }
    return self;
}

/// Shared initializer
- (void)commonInit {
    _progress = -1.0; // Indeterminate by default
    _state = DownloadCardStateIdle;
    _isShown = NO;

    _byteFormatter = [[NSByteCountFormatter alloc] init];
    _byteFormatter.allowedUnits = NSByteCountFormatterUseAll;
    _byteFormatter.countStyle = NSByteCountFormatterCountStyleFile;
    _byteFormatter.includesUnit = YES;
    _byteFormatter.allowsNonnumericFormatting = YES;

    [self setupSubviews];
    [self setupConstraints];
    [self applyBackgroundStyle];
    [self registerNotifications];
    [self applyState:DownloadCardStateIdle];
}

- (void)dealloc {
    [self.autoDismissTimer invalidate];
    self.autoDismissTimer = nil;
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

#pragma mark - UI Setup

/// Create and add every subview
- (void)setupSubviews {
    // The card itself is transparent; the inner background view carries the color/frosted glass
    self.backgroundColor = [UIColor clearColor];
    self.layer.cornerRadius = kCardCornerRadius;
    self.layer.masksToBounds = NO; // The shadow needs clipping disabled

    // Frosted-glass background view
    UIBlurEffect *blurEffect = [UIBlurEffect effectWithStyle:UIBlurEffectStyleSystemMaterial];
    self.blurEffectView = [[UIVisualEffectView alloc] initWithEffect:blurEffect];
    self.blurEffectView.translatesAutoresizingMaskIntoConstraints = NO;
    self.blurEffectView.layer.cornerRadius = kCardCornerRadius;
    self.blurEffectView.layer.masksToBounds = YES;
    [self addSubview:self.blurEffectView];

    // Solid background view (used when there is no custom background)
    self.solidBackgroundView = [[UIView alloc] init];
    self.solidBackgroundView.translatesAutoresizingMaskIntoConstraints = NO;
    self.solidBackgroundView.backgroundColor = [UIColor secondarySystemGroupedBackgroundColor];
    self.solidBackgroundView.layer.cornerRadius = kCardCornerRadius;
    self.solidBackgroundView.layer.masksToBounds = YES;
    self.solidBackgroundView.hidden = YES;
    [self addSubview:self.solidBackgroundView];

    // Shadow (set on self.layer)
    self.layer.shadowColor = [UIColor blackColor].CGColor;
    self.layer.shadowOffset = CGSizeMake(0, kCardShadowOffsetY);
    self.layer.shadowRadius = kCardShadowRadius;
    self.layer.shadowOpacity = (float)kCardShadowOpacity;

    // Content container
    self.contentContainer = [[UIView alloc] init];
    self.contentContainer.translatesAutoresizingMaskIntoConstraints = NO;
    self.contentContainer.backgroundColor = [UIColor clearColor];
    [self addSubview:self.contentContainer];

    // Status icon
    self.statusIconView = [[UIImageView alloc] init];
    self.statusIconView.translatesAutoresizingMaskIntoConstraints = NO;
    self.statusIconView.contentMode = UIViewContentModeScaleAspectFit;
    self.statusIconView.tintColor = [UIColor systemBlueColor];
    self.statusIconView.preferredSymbolConfiguration =
        [UIImageSymbolConfiguration configurationWithPointSize:20 weight:UIFontWeightMedium];
    self.statusIconView.image = [UIImage systemImageNamed:@"arrow.down.circle.fill"];
    [self.contentContainer addSubview:self.statusIconView];

    // Spinner view (shown in indeterminate mode)
    self.spinnerView = [[UIActivityIndicatorView alloc]
        initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleMedium];
    self.spinnerView.translatesAutoresizingMaskIntoConstraints = NO;
    self.spinnerView.hidesWhenStopped = YES;
    self.spinnerView.color = [UIColor systemBlueColor];
    [self.contentContainer addSubview:self.spinnerView];

    // Percentage label
    self.percentLabel = [[UILabel alloc] init];
    self.percentLabel.translatesAutoresizingMaskIntoConstraints = NO;
    self.percentLabel.font = [UIFont systemFontOfSize:18 weight:UIFontWeightSemibold];
    self.percentLabel.textColor = [UIColor labelColor];
    self.percentLabel.textAlignment = NSTextAlignmentRight;
    self.percentLabel.text = @"0%";
    [self.contentContainer addSubview:self.percentLabel];

    // Title label
    self.titleLabel = [[UILabel alloc] init];
    self.titleLabel.translatesAutoresizingMaskIntoConstraints = NO;
    self.titleLabel.font = [UIFont systemFontOfSize:16 weight:UIFontWeightSemibold];
    self.titleLabel.textColor = [UIColor labelColor];
    self.titleLabel.numberOfLines = 1;
    self.titleLabel.lineBreakMode = NSLineBreakByTruncatingTail;
    self.titleLabel.text = @"Preparing download...";
    [self.contentContainer addSubview:self.titleLabel];

    // Subtitle label
    self.subtitleLabel = [[UILabel alloc] init];
    self.subtitleLabel.translatesAutoresizingMaskIntoConstraints = NO;
    self.subtitleLabel.font = [UIFont systemFontOfSize:12];
    self.subtitleLabel.textColor = [UIColor secondaryLabelColor];
    self.subtitleLabel.numberOfLines = 1;
    self.subtitleLabel.lineBreakMode = NSLineBreakByTruncatingTail;
    [self.contentContainer addSubview:self.subtitleLabel];

    // Progress bar
    self.progressBar = [[DPCProgressBar alloc] init];
    self.progressBar.translatesAutoresizingMaskIntoConstraints = NO;
    self.progressBar.fillColor = [UIColor systemBlueColor];
    self.progressBar.trackColor = [UIColor systemGray5Color];
    [self.contentContainer addSubview:self.progressBar];

    // Downloaded label
    self.downloadedLabel = [[UILabel alloc] init];
    self.downloadedLabel.translatesAutoresizingMaskIntoConstraints = NO;
    self.downloadedLabel.font = [UIFont systemFontOfSize:12];
    self.downloadedLabel.textColor = [UIColor secondaryLabelColor];
    self.downloadedLabel.text = @"0 KB / 0 KB";
    [self.contentContainer addSubview:self.downloadedLabel];

    // Speed label
    self.speedLabel = [[UILabel alloc] init];
    self.speedLabel.translatesAutoresizingMaskIntoConstraints = NO;
    self.speedLabel.font = [UIFont systemFontOfSize:12 weight:UIFontWeightMedium];
    self.speedLabel.textColor = [UIColor systemBlueColor];
    self.speedLabel.textAlignment = NSTextAlignmentRight;
    self.speedLabel.text = @"0 KB/s";
    [self.contentContainer addSubview:self.speedLabel];

    // ETA label
    self.etaLabel = [[UILabel alloc] init];
    self.etaLabel.translatesAutoresizingMaskIntoConstraints = NO;
    self.etaLabel.font = [UIFont systemFontOfSize:12];
    self.etaLabel.textColor = [UIColor secondaryLabelColor];
    self.etaLabel.text = @"";
    [self.contentContainer addSubview:self.etaLabel];

    // Current file label
    self.currentFileLabel = [[UILabel alloc] init];
    self.currentFileLabel.translatesAutoresizingMaskIntoConstraints = NO;
    self.currentFileLabel.font = [UIFont systemFontOfSize:11];
    self.currentFileLabel.textColor = [UIColor tertiaryLabelColor];
    self.currentFileLabel.numberOfLines = 1;
    self.currentFileLabel.lineBreakMode = NSLineBreakByTruncatingMiddle;
    self.currentFileLabel.text = @"";
    [self.contentContainer addSubview:self.currentFileLabel];
}

/// Set up the Auto Layout constraints
- (void)setupConstraints {
    // The background view is pinned to all four edges of the card
    [NSLayoutConstraint activateConstraints:@[
        [self.blurEffectView.topAnchor constraintEqualToAnchor:self.topAnchor],
        [self.blurEffectView.leadingAnchor constraintEqualToAnchor:self.leadingAnchor],
        [self.blurEffectView.trailingAnchor constraintEqualToAnchor:self.trailingAnchor],
        [self.blurEffectView.bottomAnchor constraintEqualToAnchor:self.bottomAnchor],

        [self.solidBackgroundView.topAnchor constraintEqualToAnchor:self.topAnchor],
        [self.solidBackgroundView.leadingAnchor constraintEqualToAnchor:self.leadingAnchor],
        [self.solidBackgroundView.trailingAnchor constraintEqualToAnchor:self.trailingAnchor],
        [self.solidBackgroundView.bottomAnchor constraintEqualToAnchor:self.bottomAnchor],

        // Content container: 16pt padding
        [self.contentContainer.topAnchor constraintEqualToAnchor:self.topAnchor
                                                       constant:kCardInternalPadding],
        [self.contentContainer.leadingAnchor constraintEqualToAnchor:self.leadingAnchor
                                                           constant:kCardInternalPadding],
        [self.contentContainer.trailingAnchor constraintEqualToAnchor:self.trailingAnchor
                                                            constant:-kCardInternalPadding],
        [self.contentContainer.bottomAnchor constraintEqualToAnchor:self.bottomAnchor
                                                           constant:-kCardInternalPadding],
    ]];

    // Top row: status icon/spinner on the left, percentage on the right
    [NSLayoutConstraint activateConstraints:@[
        [self.statusIconView.leadingAnchor constraintEqualToAnchor:self.contentContainer.leadingAnchor],
        [self.statusIconView.topAnchor constraintEqualToAnchor:self.contentContainer.topAnchor],
        [self.statusIconView.widthAnchor constraintEqualToConstant:kStatusIconSize],
        [self.statusIconView.heightAnchor constraintEqualToConstant:kStatusIconSize],

        // The spinner sits in the same place as statusIcon (only one is visible at a time)
        [self.spinnerView.leadingAnchor constraintEqualToAnchor:self.contentContainer.leadingAnchor],
        [self.spinnerView.centerYAnchor constraintEqualToAnchor:self.statusIconView.centerYAnchor],
        [self.spinnerView.widthAnchor constraintEqualToConstant:kStatusIconSize],
        [self.spinnerView.heightAnchor constraintEqualToConstant:kStatusIconSize],

        [self.percentLabel.trailingAnchor constraintEqualToAnchor:self.contentContainer.trailingAnchor],
        [self.percentLabel.centerYAnchor constraintEqualToAnchor:self.statusIconView.centerYAnchor],
        [self.percentLabel.leadingAnchor constraintEqualToAnchor:self.statusIconView.trailingAnchor
                                                        constant:8],
    ]];

    // Title row
    [NSLayoutConstraint activateConstraints:@[
        [self.titleLabel.topAnchor constraintEqualToAnchor:self.statusIconView.bottomAnchor
                                                  constant:10],
        [self.titleLabel.leadingAnchor constraintEqualToAnchor:self.contentContainer.leadingAnchor],
        [self.titleLabel.trailingAnchor constraintEqualToAnchor:self.contentContainer.trailingAnchor],

        [self.subtitleLabel.topAnchor constraintEqualToAnchor:self.titleLabel.bottomAnchor
                                                     constant:2],
        [self.subtitleLabel.leadingAnchor constraintEqualToAnchor:self.contentContainer.leadingAnchor],
        [self.subtitleLabel.trailingAnchor constraintEqualToAnchor:self.contentContainer.trailingAnchor],
    ]];

    // Progress bar
    [NSLayoutConstraint activateConstraints:@[
        [self.progressBar.topAnchor constraintEqualToAnchor:self.subtitleLabel.bottomAnchor
                                                   constant:10],
        [self.progressBar.leadingAnchor constraintEqualToAnchor:self.contentContainer.leadingAnchor],
        [self.progressBar.trailingAnchor constraintEqualToAnchor:self.contentContainer.trailingAnchor],
        [self.progressBar.heightAnchor constraintEqualToConstant:kProgressBarHeight],
    ]];

    // Info row (downloaded + speed)
    [NSLayoutConstraint activateConstraints:@[
        [self.downloadedLabel.topAnchor constraintEqualToAnchor:self.progressBar.bottomAnchor
                                                       constant:8],
        [self.downloadedLabel.leadingAnchor constraintEqualToAnchor:self.contentContainer.leadingAnchor],

        [self.speedLabel.topAnchor constraintEqualToAnchor:self.progressBar.bottomAnchor
                                                  constant:8],
        [self.speedLabel.trailingAnchor constraintEqualToAnchor:self.contentContainer.trailingAnchor],
        [self.speedLabel.leadingAnchor constraintEqualToAnchor:self.downloadedLabel.trailingAnchor
                                                      constant:8],
    ]];

    // ETA row
    [NSLayoutConstraint activateConstraints:@[
        [self.etaLabel.topAnchor constraintEqualToAnchor:self.downloadedLabel.bottomAnchor
                                                constant:4],
        [self.etaLabel.leadingAnchor constraintEqualToAnchor:self.contentContainer.leadingAnchor],
        [self.etaLabel.trailingAnchor constraintEqualToAnchor:self.contentContainer.trailingAnchor],
    ]];

    // Current file row
    [NSLayoutConstraint activateConstraints:@[
        [self.currentFileLabel.topAnchor constraintEqualToAnchor:self.etaLabel.bottomAnchor
                                                        constant:4],
        [self.currentFileLabel.leadingAnchor constraintEqualToAnchor:self.contentContainer.leadingAnchor],
        [self.currentFileLabel.trailingAnchor constraintEqualToAnchor:self.contentContainer.trailingAnchor],
        [self.currentFileLabel.bottomAnchor constraintEqualToAnchor:self.contentContainer.bottomAnchor],
    ]];
}

#pragma mark - 背景适配

/// Apply the background style: frosted glass when there is a custom background, otherwise a solid color
- (void)applyBackgroundStyle {
    BOOL hasBg = [[BackgroundManager sharedManager] hasBackground];

    if (hasBg) {
        // Global background present: use frosted glass so it shows through, and hide the solid background
        self.blurEffectView.hidden = NO;
        self.solidBackgroundView.hidden = YES;
    } else {
        // No global background: use a solid color for readability, and hide the frosted glass
        self.blurEffectView.hidden = YES;
        self.solidBackgroundView.hidden = NO;
    }

    // Text color follows the background: white-ish when there is a background, the system default otherwise
    UIColor *titleColor = hasBg ? [UIColor whiteColor] : [UIColor labelColor];
    UIColor *subtitleColor = hasBg ?
        [UIColor colorWithWhite:1.0 alpha:0.75] : [UIColor secondaryLabelColor];
    UIColor *tertiaryColor = hasBg ?
        [UIColor colorWithWhite:1.0 alpha:0.6] : [UIColor tertiaryLabelColor];

    self.titleLabel.textColor = titleColor;
    self.subtitleLabel.textColor = subtitleColor;
    self.downloadedLabel.textColor = subtitleColor;
    self.etaLabel.textColor = subtitleColor;
    self.currentFileLabel.textColor = tertiaryColor;
    self.percentLabel.textColor = titleColor;

    // The speed label stays system blue (still readable on frosted glass) and turns red in the failed state
    // The status icon color is driven by the state, so it is not adjusted here
}

#pragma mark - 通知

- (void)registerNotifications {
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(handleBackgroundUIEffectChanged:)
                                                 name:kBackgroundUIEffectChangedNotification
                                               object:nil];
}

- (void)handleBackgroundUIEffectChanged:(NSNotification *)notification {
    dispatch_async(dispatch_get_main_queue(), ^{
        [self applyBackgroundStyle];
    });
}

#pragma mark - Public API

+ (instancetype)showInParentView:(UIView *)parentView title:(NSString *)title {
    DownloadProgressCardView *card = [[DownloadProgressCardView alloc] init];
    card.translatesAutoresizingMaskIntoConstraints = NO;
    [parentView addSubview:card];

    // Constraints: 16pt on each side, bottom at safeArea + 16
    [NSLayoutConstraint activateConstraints:@[
        [card.leadingAnchor constraintEqualToAnchor:parentView.leadingAnchor
                                           constant:kCardSideInset],
        [card.trailingAnchor constraintEqualToAnchor:parentView.trailingAnchor
                                            constant:-kCardSideInset],
    ]];

    // Bottom constraint: prefer safeAreaLayoutGuide, falling back to layoutMarginsGuide
    NSLayoutAnchor *bottomAnchor = nil;
    if (parentView.safeAreaLayoutGuide.bottomAnchor) {
        bottomAnchor = parentView.safeAreaLayoutGuide.bottomAnchor;
    } else {
        bottomAnchor = parentView.bottomAnchor;
    }
    card.bottomConstraint =
        [card.bottomAnchor constraintEqualToAnchor:bottomAnchor
                                          constant:kCardBottomInset];
    [card.bottomConstraint setActive:YES];

    [card startDownloadWithTitle:title subtitle:nil];
    [card showAnimated:YES];
    return card;
}

- (void)startDownloadWithTitle:(NSString *)title subtitle:(NSString *)subtitle {
    self.currentTitle = title;
    self.currentSubtitle = subtitle;

    self.titleLabel.text = title ?: @"Downloading";
    self.subtitleLabel.text = subtitle ?: @"";

    // Start in indeterminate mode and wait for the first updateProgress
    self.progress = -1.0;
    [self applyState:DownloadCardStateIndeterminate];

    // Reset the display
    self.percentLabel.text = @"";
    self.downloadedLabel.text = @"Preparing...";
    self.speedLabel.text = @"";
    self.etaLabel.text = @"";
    self.currentFileLabel.text = @"";
    [self.progressBar setProgress:0.0 animated:NO];

    // Cancel any pending auto-dismiss timer
    [self.autoDismissTimer invalidate];
    self.autoDismissTimer = nil;

    if (self.isShown) {
        [self setNeedsLayout];
    }
}

- (void)updateProgress:(double)progress
            downloaded:(long long)downloadedBytes
                  total:(long long)totalBytes
                 speed:(long long)speedBytesPerSec
                   eta:(NSInteger)etaSeconds
           currentFile:(NSString *)currentFile {
    // Restrict to the main thread (UI updates)
    dispatch_async(dispatch_get_main_queue(), ^{
        [self performProgressUpdate:progress
                         downloaded:downloadedBytes
                               total:totalBytes
                              speed:speedBytesPerSec
                                eta:etaSeconds
                        currentFile:currentFile];
    });
}

/// Actually perform the progress update (main thread)
- (void)performProgressUpdate:(double)progress
                   downloaded:(long long)downloadedBytes
                         total:(long long)totalBytes
                        speed:(long long)speedBytesPerSec
                          eta:(NSInteger)etaSeconds
                  currentFile:(NSString *)currentFile {
    self.progress = progress;

    // Decide whether to switch to determinate mode
    if (progress >= 0.0) {
        [self applyState:DownloadCardStateDownloading];
    } else {
        [self applyState:DownloadCardStateIndeterminate];
    }

    // Percentage
    if (progress >= 0.0) {
        NSInteger percent = (NSInteger)(progress * 100.0 + 0.5);
        percent = MAX(0, MIN(100, percent));
        self.percentLabel.text = [NSString stringWithFormat:@"%ld%%", (long)percent];
    } else {
        self.percentLabel.text = @"";
    }

    // Progress bar
    if (progress >= 0.0) {
        [self.progressBar setProgress:(CGFloat)progress animated:YES];
    } else {
        [self.progressBar setProgress:0.0 animated:NO];
    }

    // Downloaded/total size
    NSString *downloadedStr = [self formatBytes:downloadedBytes];
    if (totalBytes > 0) {
        NSString *totalStr = [self formatBytes:totalBytes];
        self.downloadedLabel.text =
            [NSString stringWithFormat:@"%@ / %@", downloadedStr, totalStr];
    } else if (totalBytes < 0) {
        // Total size unknown, so only show what has been downloaded
        self.downloadedLabel.text =
            [NSString stringWithFormat:@"%@ / unknown", downloadedStr];
    } else {
        self.downloadedLabel.text = downloadedStr;
    }

    // Speed
    self.speedLabel.text = [self formatSpeed:speedBytesPerSec];

    // ETA
    self.etaLabel.text = [self formatETA:etaSeconds];

    // Name of the current file
    self.currentFileLabel.text = currentFile ?: @"";
}

- (void)completeWithTitle:(NSString *)title {
    dispatch_async(dispatch_get_main_queue(), ^{
        self.currentTitle = title;
        self.titleLabel.text = title ?: @"Download complete";

        // Fill the progress bar
        self.progress = 1.0;
        [self.progressBar setProgress:1.0 animated:YES];
        self.percentLabel.text = @"100%";

        [self applyState:DownloadCardStateCompleted];

        // Stop the spinner
        [self.spinnerView stopAnimating];

        // Clear the speed/ETA
        self.speedLabel.text = @"Done";
        self.etaLabel.text = @"";

        // Dismiss automatically
        [self scheduleAutoDismissAfter:kAutoDismissAfterComplete];
    });
}

- (void)failWithError:(NSError *)error {
    dispatch_async(dispatch_get_main_queue(), ^{
        NSString *failTitle = @"Download failed";
        if (error && error.localizedDescription.length > 0) {
            failTitle = [NSString stringWithFormat:@"Download failed: %@",
                         error.localizedDescription];
        }
        self.titleLabel.text = failTitle;
        self.currentTitle = failTitle;

        [self applyState:DownloadCardStateFailed];
        [self.spinnerView stopAnimating];

        self.speedLabel.text = @"Failed";
        self.etaLabel.text = @"";

        // Dismiss automatically (the failed state lingers longer so the user can read the error)
        [self scheduleAutoDismissAfter:kAutoDismissAfterFail];
    });
}

- (void)cancel {
    dispatch_async(dispatch_get_main_queue(), ^{
        self.titleLabel.text = @"Download cancelled";
        self.currentTitle = @"Download cancelled";

        [self applyState:DownloadCardStateCancelled];
        [self.spinnerView stopAnimating];

        self.speedLabel.text = @"Cancelled";
        self.etaLabel.text = @"";

        [self scheduleAutoDismissAfter:kAutoDismissAfterComplete];
    });
}

- (void)dismiss {
    dispatch_async(dispatch_get_main_queue(), ^{
        [self hideAnimated:YES];
    });
}

#pragma mark - 状态切换

/// Apply the state: update the icon, colors and visibility
- (void)applyState:(DownloadCardState)state {
    self.state = state;

    UIColor *fillColor = [UIColor systemBlueColor];
    UIColor *speedColor = [UIColor systemBlueColor];
    UIColor *iconColor = [UIColor systemBlueColor];
    NSString *imageName = @"arrow.down.circle.fill";

    BOOL showPercent = YES;
    BOOL showProgressBar = YES;
    BOOL showSpinner = NO;
    BOOL animateIcon = NO;

    switch (state) {
        case DownloadCardStateIdle:
            showPercent = NO;
            showProgressBar = NO;
            imageName = @"arrow.down.circle";
            iconColor = [UIColor systemGrayColor];
            fillColor = [UIColor systemGrayColor];
            speedColor = [UIColor secondaryLabelColor];
            break;
        case DownloadCardStateDownloading:
            // Defaults: blue + download icon
            animateIcon = YES;
            break;
        case DownloadCardStateIndeterminate:
            // Indeterminate mode: spinner + hide the percentage and progress bar
            showPercent = NO;
            showProgressBar = NO;
            showSpinner = YES;
            // Show "Preparing..." in the subtitle position
            break;
        case DownloadCardStateCompleted:
            imageName = @"checkmark.circle.fill";
            iconColor = [UIColor systemGreenColor];
            fillColor = [UIColor systemGreenColor];
            speedColor = [UIColor systemGreenColor];
            break;
        case DownloadCardStateFailed:
            imageName = @"xmark.circle.fill";
            iconColor = [UIColor systemRedColor];
            fillColor = [UIColor systemRedColor];
            speedColor = [UIColor systemRedColor];
            break;
        case DownloadCardStateCancelled:
            imageName = @"stop.circle.fill";
            iconColor = [UIColor systemGrayColor];
            fillColor = [UIColor systemGrayColor];
            speedColor = [UIColor secondaryLabelColor];
            break;
    }

    // Update the icon
    UIImageSymbolConfiguration *config =
        [UIImageSymbolConfiguration configurationWithPointSize:20 weight:UIFontWeightMedium];
    self.statusIconView.preferredSymbolConfiguration = config;
    self.statusIconView.image = [UIImage systemImageNamed:imageName];
    self.statusIconView.tintColor = iconColor;

    // Update the progress bar color
    self.progressBar.fillColor = fillColor;

    // Update the speed color
    self.speedLabel.textColor = speedColor;

    // Show/hide control
    self.percentLabel.hidden = !showPercent;
    self.progressBar.hidden = !showProgressBar;
    self.statusIconView.hidden = showSpinner;

    // Spinner
    if (showSpinner) {
        [self.spinnerView startAnimating];
    } else {
        [self.spinnerView stopAnimating];
    }

    // Breathing (scale) animation on the downloading status icon
    [self.statusIconView.layer removeAllAnimations];
    if (animateIcon) {
        [self addPulseAnimationToIcon];
    }

    // In indeterminate mode, change the title to "Preparing..."
    if (state == DownloadCardStateIndeterminate && self.currentTitle) {
        // Keep the title the caller set, and only show the hint before any progress update
        // titleLabel is not overwritten here; startDownloadWithTitle sets it
    }
}

/// Add a breathing animation to the status icon
- (void)addPulseAnimationToIcon {
    CAKeyframeAnimation *pulse = [CAKeyframeAnimation animationWithKeyPath:@"transform.scale"];
    pulse.values = @[@1.0, @1.15, @1.0];
    pulse.duration = 1.2;
    pulse.repeatCount = HUGE_VALF;
    pulse.timingFunction =
        [CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionEaseInEaseOut];
    [self.statusIconView.layer addAnimation:pulse forKey:@"pulseAnimation"];
}

#pragma mark - 显示/隐藏动画

/// Show animation: slide up from the bottom + fade in (spring)
- (void)showAnimated:(BOOL)animated {
    if (self.isShown) return;

    self.isShown = YES;
    self.hidden = NO;
    self.alpha = 0.0;

    // Starting position: offset down by one card height (as if sliding in from off-screen)
    if (self.bottomConstraint) {
        // Temporarily set the bottom constraint to a negative value (offset downwards), then animate back to the target
        CGFloat offset = self.bounds.size.height;
        if (offset <= 0) {
            offset = 120; // Fallback value
        }
        self.bottomConstraint.constant = -offset - kCardBottomInset;
        [self.superview layoutIfNeeded];
    }

    if (animated) {
        if (self.bottomConstraint) {
            self.bottomConstraint.constant = kCardBottomInset;
        }
        [UIView animateWithDuration:kShowAnimationDuration
                              delay:0
             usingSpringWithDamping:0.85
              initialSpringVelocity:0.4
                            options:UIViewAnimationOptionCurveEaseOut
                         animations:^{
                             self.alpha = 1.0;
                             [self.superview layoutIfNeeded];
                         }
                         completion:nil];
    } else {
        if (self.bottomConstraint) {
            self.bottomConstraint.constant = kCardBottomInset;
        }
        self.alpha = 1.0;
        [self.superview layoutIfNeeded];
    }
}

/// Hide animation: slide down + fade out
- (void)hideAnimated:(BOOL)animated {
    if (!self.isShown) return;
    self.isShown = NO;

    [self.autoDismissTimer invalidate];
    self.autoDismissTimer = nil;
    [self.spinnerView stopAnimating];
    [self.statusIconView.layer removeAllAnimations];

    if (animated && self.superview) {
        CGFloat offset = self.bounds.size.height;
        if (offset <= 0) offset = 120;

        if (self.bottomConstraint) {
            self.bottomConstraint.constant = -offset - kCardBottomInset;
        }
        [UIView animateWithDuration:kHideAnimationDuration
                              delay:0
                            options:UIViewAnimationOptionCurveEaseIn
                         animations:^{
                             self.alpha = 0.0;
                             [self.superview layoutIfNeeded];
                         }
                         completion:^(BOOL finished) {
                             [self removeFromSuperview];
                         }];
    } else {
        [self removeFromSuperview];
    }
}

/// Schedule the automatic dismissal
- (void)scheduleAutoDismissAfter:(NSTimeInterval)delay {
    [self.autoDismissTimer invalidate];
    __weak typeof(self) weakSelf = self;
    self.autoDismissTimer =
        [NSTimer scheduledTimerWithTimeInterval:delay
                                        repeats:NO
                                          block:^(NSTimer * _Nonnull timer) {
        [weakSelf hideAnimated:YES];
    }];
}

#pragma mark - 格式化工具

/// Format a byte count (using NSByteCountFormatter)
- (NSString *)formatBytes:(long long)bytes {
    if (bytes < 0) return @"0 B";
    return [self.byteFormatter stringFromByteCount:bytes];
}

/// Format the download speed
/// Rule: >1MB shows MB/s, >1KB shows KB/s, otherwise B/s
- (NSString *)formatSpeed:(long long)speedBytesPerSec {
    if (speedBytesPerSec <= 0) return @"0 B/s";

    double speed = (double)speedBytesPerSec;
    if (speed >= 1024.0 * 1024.0) {
        // MB/s
        return [NSString stringWithFormat:@"%.2f MB/s", speed / (1024.0 * 1024.0)];
    } else if (speed >= 1024.0) {
        // KB/s
        return [NSString stringWithFormat:@"%.1f KB/s", speed / 1024.0];
    } else {
        // B/s
        return [NSString stringWithFormat:@"%lld B/s", (long long)speed];
    }
}

/// Format the time remaining (ETA)
/// Rules:
///   >1 hour:   Xh Ym
///   >1 minute: Xm Ys
///   otherwise: Xs
- (NSString *)formatETA:(NSInteger)etaSeconds {
    if (etaSeconds < 0) return @"";
    if (etaSeconds == 0) return @"Almost done";

    NSInteger hours = etaSeconds / 3600;
    NSInteger minutes = (etaSeconds % 3600) / 60;
    NSInteger seconds = etaSeconds % 60;

    if (hours >= 1) {
        return [NSString stringWithFormat:@"%ldh %ldm left",
                (long)hours, (long)minutes];
    } else if (minutes >= 1) {
        return [NSString stringWithFormat:@"%ldm %lds left",
                (long)minutes, (long)seconds];
    } else {
        return [NSString stringWithFormat:@"%lds left", (long)seconds];
    }
}

#pragma mark - Overloads

- (void)willMoveToSuperview:(UIView *)newSuperview {
    [super willMoveToSuperview:newSuperview];
    if (newSuperview) {
        self.isShown = YES;
    } else {
        self.isShown = NO;
    }
}

@end
