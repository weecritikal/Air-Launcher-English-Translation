// ============================================================================
// DownloadProgressViewController.m
// Download progress screen (reworked in the FCL/ZL2 style)
// ============================================================================
//
// Design rationale
// ============================================================================
// This controller shows live progress while Minecraft assets download, drawing on the download progress
// screens of FCL (FoldCraftLauncher) and ZL2 (ZalithLauncher):
//
// 1. FCL style:
//    - the summary card at the top shows progress percentage + progress bar + download speed + time remaining (ETA) together
//    - high information density, so the user takes in everything at a glance
//    - speed visualization: a live mini speed chart that makes fluctuations obvious
//
// 2. ZL2 style:
//    - a rounded frosted-glass card background that layers over the content below
//    - a colored progress bar (theme color) with smooth animated transitions
//    - 16pt radius + 0.5pt border + translucent background + frosted glass
//
// 3. HMCL style:
//    - a per-file list that clearly shows the progress of each individual file
//    - file-type icon + file size + speed information laid out in clear layers
//
// Visual spec (matching the other cards in the project):
//    - corner radius: 16pt
//    - border: 0.5pt (UIColor.separatorColor)
//    - background: 8% translucent white + frosted glass (via BackgroundManager)
//    - progress bar: theme color (tintColor), capsule-shaped
// ============================================================================

#import <objc/runtime.h>
#import <sys/time.h>
#import "DownloadProgressViewController.h"
#import "BackgroundManager.h"
#import "utils.h"
#import "FluxTheme.h"

// ============================================================================
// Visual constants
// ============================================================================

/// Card corner radius (matching the other cards in the project)
static const CGFloat kCardCornerRadius     = 16.0;
/// Card border width
static const CGFloat kCardBorderWidth      = 0.5;
/// Total height of the summary header view
static const CGFloat kSummaryHeaderHeight  = 210.0;
/// Height of a single-file cell
static const CGFloat kCellHeight           = 80.0;
/// Height of the linear progress bar
static const CGFloat kProgressBarHeight    = 8.0;
/// Height of the mini speed chart
static const CGFloat kSpeedSparklineHeight = 36.0;
/// Maximum number of samples in the mini speed chart (older samples scroll off beyond this)
static const NSInteger kMaxSpeedSamples    = 40;
/// Progress bar animation duration
static const NSTimeInterval kProgressAnimDuration = 0.3;
/// File-type icon size
static const CGFloat kFileIconSize         = 28.0;
/// Circular progress view size
static const CGFloat kCircularProgressSize = 34.0;
/// Summary header icon size
static const CGFloat kSummaryIconSize      = 32.0;

// KVO observation contexts (distinguishing per-file progress from total progress)
static void *CellProgressObserverContext = &CellProgressObserverContext;
static void *TotalProgressObserverContext = &TotalProgressObserverContext;

// ============================================================================
// Custom linear progress bar (modelled on DPCProgressBar, with smooth animation + theme color)
// ============================================================================
// Compared with the system UIProgressView, this gives finer control over corner radius, color and animation curve,
// so it can match the capsule-shaped progress bar of ZL2.

@interface DPVCProgressBar : UIView
/// Progress value from 0.0 to 1.0
@property (nonatomic, assign) CGFloat progress;
/// Fill color (the filled part of the bar)
@property (nonatomic, strong) UIColor *fillColor;
/// Track color (the unfilled part of the bar)
@property (nonatomic, strong) UIColor *trackColor;
/// Set the progress, optionally animated
- (void)setProgress:(CGFloat)progress animated:(BOOL)animated;
@end

@implementation DPVCProgressBar {
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

/// Initialize the track and fill layers
- (void)setupLayers {
    // Track: fills the whole view, capsule-shaped
    _trackLayer = [CAShapeLayer layer];
    _trackLayer.fillColor = [UIColor systemGray5Color].CGColor;
    _trackLayer.lineWidth = 0;
    [self.layer addSublayer:_trackLayer];

    // Fill: width derived from the progress, capsule-shaped
    _fillLayer = [CAShapeLayer layer];
    _fillLayer.fillColor = FluxTheme.accent.CGColor;
    _fillLayer.lineWidth = 0;
    [self.layer addSublayer:_fillLayer];

    // Defaults
    _progress = 0.0;
    _fillColor = FluxTheme.accent;
    _trackColor = [UIColor systemGray5Color];

    // Clip the fill layer so it does not spill past the rounded corners
    self.layer.masksToBounds = YES;
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
    // Clamp to the 0.0 ~ 1.0 range
    progress = MAX(0.0, MIN(1.0, progress));
    _progress = progress;

    if (animated) {
        // Use CABasicAnimation to transition the fill width smoothly
        [CATransaction begin];
        [CATransaction setAnimationDuration:kProgressAnimDuration];
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

// ============================================================================
// Mini speed chart (live speed visualization)
// ============================================================================
// Shows a bar chart of the last N speed samples in the summary card, so the user can see the trend at a glance.
// Samples are normalized to 0.0~1.0 (against the historical maximum), with the newest on the right.

@interface DPVCSpeedSparkline : UIView

/// Add a speed sample (normalized 0.0~1.0; out-of-range values are clamped)
- (void)addSpeedSample:(CGFloat)normalizedSpeed;
/// Clear every sample
- (void)reset;
/// Set the bar color
@property (nonatomic, strong) UIColor *barColor;

@end

@implementation DPVCSpeedSparkline {
    NSMutableArray<NSNumber *> *_samples;
}

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        // Preallocate capacity to avoid repeated growth
        _samples = [[NSMutableArray alloc] initWithCapacity:kMaxSpeedSamples];
        _barColor = FluxTheme.accent;
        self.backgroundColor = [UIColor clearColor];
    }
    return self;
}

- (void)addSpeedSample:(CGFloat)normalizedSpeed {
    // Clamp to 0.0 ~ 1.0
    normalizedSpeed = MAX(0.0, MIN(1.0, normalizedSpeed));

    // Drop the oldest sample once the maximum is exceeded
    if (_samples.count >= kMaxSpeedSamples) {
        [_samples removeObjectAtIndex:0];
    }
    [_samples addObject:@(normalizedSpeed)];

    [self setNeedsDisplay];
}

- (void)reset {
    [_samples removeAllObjects];
    [self setNeedsDisplay];
}

- (void)drawRect:(CGRect)rect {
    CGContextRef ctx = UIGraphicsGetCurrentContext();
    if (!ctx) return;

    NSInteger count = _samples.count;
    if (count == 0) {
        // Draw a placeholder baseline when there is no data
        CGContextSetStrokeColorWithColor(ctx, [[UIColor systemGray4Color] CGColor]);
        CGContextSetLineWidth(ctx, 1.0);
        CGFloat y = rect.size.height - 1.0;
        CGContextMoveToPoint(ctx, 0, y);
        CGContextAddLineToPoint(ctx, rect.size.width, y);
        CGContextStrokePath(ctx);
        return;
    }

    // Work out the width and spacing of each bar
    CGFloat totalWidth = rect.size.width;
    CGFloat spacing = 2.0;
    CGFloat barWidth = MAX(1.0, (totalWidth - spacing * (count - 1)) / count);
    CGFloat minHeight = 2.0; // Minimum height so a bar is always visible

    for (NSInteger i = 0; i < count; i++) {
        CGFloat value = _samples[i].floatValue;
        CGFloat barHeight = MAX(minHeight, value * (rect.size.height - minHeight));
        CGFloat x = i * (barWidth + spacing);
        CGFloat y = rect.size.height - barHeight;

        CGRect barRect = CGRectMake(x, y, barWidth, barHeight);
        // Rounded bars (rounded at the top)
        CGFloat cornerR = MIN(barWidth / 2.0, 2.0);
        UIBezierPath *barPath =
            [UIBezierPath bezierPathWithRoundedRect:barRect
                                   byRoundingCorners:UIRectCornerTopLeft | UIRectCornerTopRight
                                         cornerRadii:CGSizeMake(cornerR, cornerR)];

        // The rightmost (newest) bar uses an opaque color and the rest are translucent, to separate new from old
        BOOL isLatest = (i == count - 1);
        UIColor *color = isLatest ? _barColor : [_barColor colorWithAlphaComponent:0.5];
        CGContextSetFillColorWithColor(ctx, color.CGColor);
        CGContextAddPath(ctx, barPath.CGPath);
        CGContextFillPath(ctx);
    }
}

@end

// ============================================================================
// Custom circular progress view (keeping the original design, with an enhanced completion animation)
// ============================================================================

@interface CircularProgressView : UIView
@property (nonatomic, assign) CGFloat fractionCompleted;
@property (nonatomic, strong) UIColor *resolvedTintColor;
@property (nonatomic, assign) CGFloat stopSize;
- (void)reset;
- (void)transitionCompletedLayerToVisible:(BOOL)visible animated:(BOOL)animated haptic:(BOOL)haptic;
- (void)transitionRunningLayerToVisible:(BOOL)visible animated:(BOOL)animated;
@end

@implementation CircularProgressView {
    CAShapeLayer *_trackLayer;
    CAShapeLayer *_progressLayer;
    CAShapeLayer *_completedLayer; // The checkmark shown on completion
    BOOL _completedVisible;
    BOOL _runningVisible;
}

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        self.backgroundColor = [UIColor clearColor];
        _resolvedTintColor = FluxTheme.accent;
        _stopSize = 0;
        _fractionCompleted = 0.0;
        _completedVisible = NO;
        _runningVisible = YES;

        CGFloat lineWidth = 3.0;
        CGFloat radius = (MIN(frame.size.width, frame.size.height) - lineWidth) / 2.0 - 1.0;
        CGPoint center = CGPointMake(frame.size.width / 2.0, frame.size.height / 2.0);
        UIBezierPath *circlePath = [UIBezierPath bezierPathWithArcCenter:center
                                                                  radius:radius
                                                              startAngle:-M_PI_2
                                                                endAngle:-M_PI_2 + 2.0 * M_PI
                                                               clockwise:YES];

        // Track layer (the gray background ring)
        _trackLayer = [CAShapeLayer layer];
        _trackLayer.path = circlePath.CGPath;
        _trackLayer.fillColor = nil;
        _trackLayer.strokeColor = [[UIColor whiteColor] colorWithAlphaComponent:0.15].CGColor;
        _trackLayer.lineWidth = lineWidth;
        _trackLayer.strokeStart = 0.0;
        _trackLayer.strokeEnd = 1.0;
        [self.layer addSublayer:_trackLayer];

        // Progress layer (the theme-colored progress ring)
        _progressLayer = [CAShapeLayer layer];
        _progressLayer.path = circlePath.CGPath;
        _progressLayer.fillColor = nil;
        _progressLayer.strokeColor = _resolvedTintColor.CGColor;
        _progressLayer.lineWidth = lineWidth;
        _progressLayer.lineCap = kCALineCapRound;
        _progressLayer.strokeStart = 0.0;
        _progressLayer.strokeEnd = 0.0;
        [self.layer addSublayer:_progressLayer];

        // Completion checkmark (hidden by default)
        UIBezierPath *checkPath = [UIBezierPath bezierPath];
        CGFloat checkSize = radius * 0.7;
        CGPoint checkCenter = center;
        [checkPath moveToPoint:CGPointMake(checkCenter.x - checkSize * 0.4, checkCenter.y)];
        [checkPath addLineToPoint:CGPointMake(checkCenter.x - checkSize * 0.1, checkCenter.y + checkSize * 0.3)];
        [checkPath addLineToPoint:CGPointMake(checkCenter.x + checkSize * 0.4, checkCenter.y - checkSize * 0.3)];

        _completedLayer = [CAShapeLayer layer];
        _completedLayer.path = checkPath.CGPath;
        _completedLayer.fillColor = nil;
        _completedLayer.strokeColor = [UIColor systemGreenColor].CGColor;
        _completedLayer.lineWidth = lineWidth;
        _completedLayer.lineCap = kCALineCapRound;
        _completedLayer.lineJoin = kCALineJoinRound;
        _completedLayer.opacity = 0.0;
        [self.layer addSublayer:_completedLayer];
    }
    return self;
}

- (void)setFractionCompleted:(CGFloat)fractionCompleted {
    _fractionCompleted = MAX(0.0, MIN(1.0, fractionCompleted));
    [CATransaction begin];
    [CATransaction setAnimationDuration:0.3];
    _progressLayer.strokeEnd = _fractionCompleted;
    [CATransaction commit];
}

- (void)setResolvedTintColor:(UIColor *)resolvedTintColor {
    _resolvedTintColor = resolvedTintColor ?: FluxTheme.accent;
    _progressLayer.strokeColor = _resolvedTintColor.CGColor;
}

- (void)reset {
    [CATransaction begin];
    [CATransaction setAnimationDuration:0.25];
    _progressLayer.strokeEnd = 0.0;
    _completedLayer.opacity = 0.0;
    [CATransaction commit];
    _fractionCompleted = 0.0;
    _completedVisible = NO;
}

- (void)transitionCompletedLayerToVisible:(BOOL)visible animated:(BOOL)animated haptic:(BOOL)haptic {
    _completedVisible = visible;
    [CATransaction begin];
    [CATransaction setAnimationDuration:animated ? 0.3 : 0.0];
    if (visible) {
        _completedLayer.opacity = 1.0;
        _trackLayer.opacity = 0.0;
        _progressLayer.opacity = 0.0;
    } else {
        _completedLayer.opacity = 0.0;
        _trackLayer.opacity = 1.0;
        _progressLayer.opacity = 1.0;
    }
    [CATransaction commit];
}

- (void)transitionRunningLayerToVisible:(BOOL)visible animated:(BOOL)animated {
    _runningVisible = visible;
    [CATransaction begin];
    [CATransaction setAnimationDuration:animated ? 0.25 : 0.0];
    if (!visible && !_completedVisible) {
        // Hidden while running but not complete: show the paused state
        _progressLayer.opacity = 0.5;
    } else {
        _progressLayer.opacity = visible ? 1.0 : 0.5;
    }
    [CATransaction commit];
}

@end

// ============================================================================
// File-type icon helper (returns the matching SF Symbol and color for a file extension)
// ============================================================================

/// Extract the lowercase extension from a file name (without the dot)
static NSString *dpvc_fileExtension(NSString *fileName) {
    if (!fileName || fileName.length == 0) return @"";
    NSString *ext = [[fileName pathExtension] lowercaseString];
    return ext ?: @"";
}

/// Return the SF Symbol name matching a file extension
/// Modelled on the file list icons of FCL, where different file types get different icons for quick recognition
static UIImage *dpvc_fileTypeIcon(NSString *fileName) {
    NSString *ext = dpvc_fileExtension(fileName);

    // Icon map: extension -> SF Symbol name
    // Every symbol here is available on iOS 13+, for compatibility
    NSDictionary<NSString *, NSString *> *iconMap = @{
        @"jar":    @"shippingbox",
        @"json":   @"doc.text",
        @"png":    @"photo",
        @"jpg":    @"photo",
        @"jpeg":   @"photo",
        @"gif":    @"photo",
        @"ogg":    @"music.note",
        @"mp3":    @"music.note",
        @"wav":    @"music.note",
        @"zip":    @"doc",
        @"txt":    @"doc.text",
        @"nbt":    @"map",
        @"dat":    @"doc",
        @"lock":   @"lock",
        @"sha1":   @"number",
        @"md5":    @"number",
        @"version": @"tag",
        @"pack":   @"shippingbox",
    };

    NSString *symbolName = iconMap[ext] ?: @"doc";
    UIImage *image = [UIImage systemImageNamed:symbolName];

    // Fallback: if the given symbol does not exist (an edge case), use the generic doc icon
    if (!image) {
        image = [UIImage systemImageNamed:@"doc"];
    }
    return image;
}

/// Return the theme color matching a file extension
/// The colors correspond to file types, making them easy to tell apart visually
static UIColor *dpvc_fileTypeColor(NSString *fileName) {
    NSString *ext = dpvc_fileExtension(fileName);

    // Color map: extension -> UIColor
    NSDictionary<NSString *, UIColor *> *colorMap = @{
        @"jar":    [UIColor systemOrangeColor],
        @"json":   [UIColor systemTealColor],
        @"png":    [UIColor systemPurpleColor],
        @"jpg":    [UIColor systemPurpleColor],
        @"jpeg":   [UIColor systemPurpleColor],
        @"gif":    [UIColor systemPurpleColor],
        @"ogg":    [UIColor systemPinkColor],
        @"mp3":    [UIColor systemPinkColor],
        @"wav":    [UIColor systemPinkColor],
        @"zip":    [UIColor systemIndigoColor],
        @"txt":    [UIColor systemGrayColor],
        @"nbt":    [UIColor systemGreenColor],
        @"dat":    FluxTheme.accent,
        @"lock":   [UIColor systemRedColor],
        @"sha1":   [UIColor systemGrayColor],
        @"md5":    [UIColor systemGrayColor],
        @"version": [UIColor systemBrownColor],
        @"pack":   [UIColor systemOrangeColor],
    };

    return colorMap[ext] ?: [UIColor systemGrayColor];
}

// ============================================================================
// Custom download file cell (card layout: icon + file name + size/speed + circular progress)
// ============================================================================

@interface DPVCDownloadCell : UITableViewCell

/// Card container view (carrying the frosted glass/border/corner radius styling)
@property (nonatomic, strong) UIView *cardView;
/// File-type icon
@property (nonatomic, strong) UIImageView *fileIconView;
/// File name label
@property (nonatomic, strong) UILabel *fileNameLabel;
/// Detail label (downloaded/total size • speed)
@property (nonatomic, strong) UILabel *detailLabel;
/// Circular progress view
@property (nonatomic, strong) CircularProgressView *progressView;

/// Configure the cell's file name (setting the icon and file name)
- (void)configureWithFileName:(NSString *)fileName;
/// Update the cell's progress, size and speed display from an NSProgress
- (void)updateWithProgress:(NSProgress *)progress;
/// Apply the card style (using frosted glass or a solid color depending on whether a global background is set)
- (void)applyCardStyle;

@end

@implementation DPVCDownloadCell

- (instancetype)initWithStyle:(UITableViewCellStyle)style reuseIdentifier:(NSString *)reuseIdentifier {
    self = [super initWithStyle:UITableViewCellStyleDefault reuseIdentifier:reuseIdentifier];
    if (self) {
        self.selectionStyle = UITableViewCellSelectionStyleNone;
        self.backgroundColor = [UIColor clearColor];
        self.contentView.backgroundColor = [UIColor clearColor];
        [self setupViews];
        [self setupConstraints];
        [self applyCardStyle];
    }
    return self;
}

/// Create and add every subview
- (void)setupViews {
    // Card container: 16pt radius + 0.5pt border + translucent background
    self.cardView = [[UIView alloc] init];
    self.cardView.translatesAutoresizingMaskIntoConstraints = NO;
    self.cardView.layer.cornerRadius = kCardCornerRadius;
    self.cardView.layer.masksToBounds = YES;
    self.cardView.layer.borderWidth = kCardBorderWidth;
    self.cardView.layer.borderColor = [UIColor separatorColor].CGColor;
    self.cardView.backgroundColor = [[UIColor whiteColor] colorWithAlphaComponent:0.08];
    [self.contentView addSubview:self.cardView];

    // File-type icon
    self.fileIconView = [[UIImageView alloc] init];
    self.fileIconView.translatesAutoresizingMaskIntoConstraints = NO;
    self.fileIconView.contentMode = UIViewContentModeScaleAspectFit;
    self.fileIconView.tintColor = [UIColor systemGrayColor];
    self.fileIconView.preferredSymbolConfiguration =
        [UIImageSymbolConfiguration configurationWithPointSize:16 weight:UIFontWeightMedium];
    [self.cardView addSubview:self.fileIconView];

    // File name label
    self.fileNameLabel = [[UILabel alloc] init];
    self.fileNameLabel.translatesAutoresizingMaskIntoConstraints = NO;
    self.fileNameLabel.font = [UIFont systemFontOfSize:14 weight:UIFontWeightMedium];
    self.fileNameLabel.textColor = [UIColor labelColor];
    self.fileNameLabel.numberOfLines = 1;
    self.fileNameLabel.lineBreakMode = NSLineBreakByTruncatingMiddle;
    [self.cardView addSubview:self.fileNameLabel];

    // Detail label (downloaded/total size • speed)
    self.detailLabel = [[UILabel alloc] init];
    self.detailLabel.translatesAutoresizingMaskIntoConstraints = NO;
    self.detailLabel.font = [UIFont systemFontOfSize:11];
    self.detailLabel.textColor = [UIColor secondaryLabelColor];
    self.detailLabel.numberOfLines = 1;
    self.detailLabel.lineBreakMode = NSLineBreakByTruncatingTail;
    [self.cardView addSubview:self.detailLabel];

    // Circular progress view
    self.progressView = [[CircularProgressView alloc] initWithFrame:CGRectMake(0, 0, kCircularProgressSize, kCircularProgressSize)];
    self.progressView.translatesAutoresizingMaskIntoConstraints = NO;
    self.progressView.resolvedTintColor = FluxTheme.accent;
    [self.cardView addSubview:self.progressView];
}

/// Set up the Auto Layout constraints
- (void)setupConstraints {
    [NSLayoutConstraint activateConstraints:@[
        // Card container: 16pt on each side, 4pt top and bottom
        [self.cardView.topAnchor constraintEqualToAnchor:self.contentView.topAnchor constant:4],
        [self.cardView.leadingAnchor constraintEqualToAnchor:self.contentView.leadingAnchor constant:16],
        [self.cardView.trailingAnchor constraintEqualToAnchor:self.contentView.trailingAnchor constant:-16],
        [self.cardView.bottomAnchor constraintEqualToAnchor:self.contentView.bottomAnchor constant:-4],

        // File-type icon: fixed size on the left
        [self.fileIconView.leadingAnchor constraintEqualToAnchor:self.cardView.leadingAnchor constant:12],
        [self.fileIconView.centerYAnchor constraintEqualToAnchor:self.cardView.centerYAnchor],
        [self.fileIconView.widthAnchor constraintEqualToConstant:kFileIconSize],
        [self.fileIconView.heightAnchor constraintEqualToConstant:kFileIconSize],

        // Circular progress view: fixed size on the right
        [self.progressView.trailingAnchor constraintEqualToAnchor:self.cardView.trailingAnchor constant:-12],
        [self.progressView.centerYAnchor constraintEqualToAnchor:self.cardView.centerYAnchor],
        [self.progressView.widthAnchor constraintEqualToConstant:kCircularProgressSize],
        [self.progressView.heightAnchor constraintEqualToConstant:kCircularProgressSize],

        // File name label: from the right of the icon to the left of the progress view
        [self.fileNameLabel.leadingAnchor constraintEqualToAnchor:self.fileIconView.trailingAnchor constant:10],
        [self.fileNameLabel.trailingAnchor constraintEqualToAnchor:self.progressView.leadingAnchor constant:-10],
        [self.fileNameLabel.topAnchor constraintEqualToAnchor:self.cardView.topAnchor constant:14],

        // Detail label: below the file name
        [self.detailLabel.leadingAnchor constraintEqualToAnchor:self.fileIconView.trailingAnchor constant:10],
        [self.detailLabel.trailingAnchor constraintEqualToAnchor:self.progressView.leadingAnchor constant:-10],
        [self.detailLabel.topAnchor constraintEqualToAnchor:self.fileNameLabel.bottomAnchor constant:3],
    ]];
}

/// Apply the card style (depending on whether a global background is set)
- (void)applyCardStyle {
    BOOL hasBg = [[BackgroundManager sharedManager] hasBackground];

    if (hasBg) {
        // Global background present: translucent white + frosted glass
        self.cardView.backgroundColor = [[UIColor whiteColor] colorWithAlphaComponent:0.08];
        [[BackgroundManager sharedManager] applyEffectToView:self.cardView];
    } else {
        // No global background: use a solid system color for readability
        self.cardView.backgroundColor = [UIColor secondarySystemGroupedBackgroundColor];
    }

    // Text color follows the background
    UIColor *titleColor = hasBg ? [UIColor whiteColor] : [UIColor labelColor];
    UIColor *detailColor = hasBg ?
        [UIColor colorWithWhite:1.0 alpha:0.7] : [UIColor secondaryLabelColor];

    self.fileNameLabel.textColor = titleColor;
    self.detailLabel.textColor = detailColor;
}

/// Configure the cell's file name and icon
- (void)configureWithFileName:(NSString *)fileName {
    self.fileNameLabel.text = fileName.lastPathComponent ?: fileName;
    self.fileIconView.image = dpvc_fileTypeIcon(fileName);
    self.fileIconView.tintColor = dpvc_fileTypeColor(fileName);
}

/// Update the progress, size and speed display from an NSProgress
- (void)updateWithProgress:(NSProgress *)progress {
    // Update the circular progress
    self.progressView.fractionCompleted = progress.fractionCompleted;

    // Switch to the completed state
    if (progress.finished) {
        [self.progressView transitionCompletedLayerToVisible:YES animated:YES haptic:NO];
    }

    // Build the detail text: downloaded/total size • speed
    NSMutableString *detail = [NSMutableString string];

    // Downloaded/total size
    if (progress.totalUnitCount > 0) {
        int64_t completed = progress.completedUnitCount;
        int64_t total = progress.totalUnitCount;
        NSString *completedStr = [NSByteCountFormatter stringFromByteCount:completed
                                                               countStyle:NSByteCountFormatterCountStyleFile];
        NSString *totalStr = [NSByteCountFormatter stringFromByteCount:total
                                                           countStyle:NSByteCountFormatterCountStyleFile];
        [detail appendFormat:@"%@ / %@", completedStr, totalStr];
    } else if (progress.completedUnitCount > 0) {
        // Total size unknown, so only show what has been downloaded
        NSString *completedStr = [NSByteCountFormatter stringFromByteCount:progress.completedUnitCount
                                                               countStyle:NSByteCountFormatterCountStyleFile];
        [detail appendFormat:@"%@ / ?", completedStr];
    }

    // Speed
    if (progress.throughput) {
        NSInteger speed = [progress.throughput integerValue];
        if (speed > 1024 * 1024) {
            [detail appendFormat:@" • %.1f MB/s", speed / (1024.0 * 1024.0)];
        } else if (speed > 1024) {
            [detail appendFormat:@" • %.1f KB/s", speed / 1024.0];
        } else if (speed > 0) {
            [detail appendFormat:@" • %ld B/s", (long)speed];
        }
    }

    self.detailLabel.text = detail.length > 0 ? detail : progress.localizedAdditionalDescription;
}

- (void)prepareForReuse {
    [super prepareForReuse];
    [self.progressView reset];
    self.fileNameLabel.text = @"";
    self.detailLabel.text = @"";
    self.fileIconView.image = nil;
}

@end

// ============================================================================
// Main controller implementation
// ============================================================================

@interface DownloadProgressViewController ()
// File list count (used to detect list changes and refresh the table)
@property NSInteger fileListCount;
// Summary card subviews
@property (nonatomic, strong) UIView *summaryHeaderView;
@property (nonatomic, strong) UIView *summaryCardView;
@property (nonatomic, strong) UIImageView *summaryIconView;
@property (nonatomic, strong) UILabel *summaryPercentLabel;
@property (nonatomic, strong) UILabel *summaryTitleLabel;
@property (nonatomic, strong) DPVCProgressBar *summaryProgressBar;
@property (nonatomic, strong) DPVCSpeedSparkline *speedSparkline;
@property (nonatomic, strong) UILabel *summarySizeLabel;
@property (nonatomic, strong) UILabel *summarySpeedLabel;
@property (nonatomic, strong) UILabel *summaryETALabel;
@property (nonatomic, strong) NSByteCountFormatter *byteFormatter;
@end

@implementation DownloadProgressViewController {
    // Speed sampling: used to compute the live speed and update the mini chart
    CGFloat _lastSpeedSampleTime;
    int64_t _lastCompletedBytes;
    CGFloat _maxObservedSpeed; // Used to normalize the speed samples
}

- (instancetype)initWithTask:(MinecraftResourceDownloadTask *)task {
    self = [super init];
    self.task = task;
    return self;
}

- (void)loadView {
    [super loadView];
    // Adapt to the custom launcher background
    [[BackgroundManager sharedManager] makeViewControllerTransparent:self];
    self.tableView.backgroundColor = [UIColor clearColor];

    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemClose target:self action:@selector(actionClose)];
    self.tableView.allowsSelection = NO;

    // Initialize the byte formatter (reused, to avoid creating it repeatedly)
    _byteFormatter = [[NSByteCountFormatter alloc] init];
    _byteFormatter.allowedUnits = NSByteCountFormatterUseAll;
    _byteFormatter.countStyle = NSByteCountFormatterCountStyleFile;
    _byteFormatter.includesUnit = YES;

    // Initialize the speed sampling state
    _lastSpeedSampleTime = 0;
    _lastCompletedBytes = 0;
    _maxObservedSpeed = 1.0; // A small initial value, to avoid dividing by zero

    // Build the table header summary card (modelled on the total-progress summary at the top of the FCL download page)
    [self setupSummaryHeader];
}

// ============================================================================
// Building the table header summary card
// ============================================================================

/// Build the header summary view: file icon + percentage + progress bar + speed chart + size/speed/ETA
/// Layout:
/// ┌─────────────────────────────────────┐
/// | [icon] Downloading...        [45%] |
/// │ Minecraft 1.20.4                    │
/// │ ████████████░░░░░░░░░░░░░░          │
/// | ▁▂▃▅▇▅▃▂▃▅▇█▇▅▃▂ (speed chart)     |
/// | 1.2 GB / 2.5 GB  3.4 MB/s  ~2 min  |
/// └─────────────────────────────────────┘
- (void)setupSummaryHeader {
    self.summaryHeaderView = [[UIView alloc] initWithFrame:CGRectMake(0, 0, CGRectGetWidth(self.view.bounds), kSummaryHeaderHeight)];
    self.summaryHeaderView.backgroundColor = [UIColor clearColor];

    // Card container: 16pt radius + 0.5pt border + translucent background + frosted glass
    self.summaryCardView = [[UIView alloc] init];
    self.summaryCardView.translatesAutoresizingMaskIntoConstraints = NO;
    self.summaryCardView.layer.cornerRadius = kCardCornerRadius;
    self.summaryCardView.layer.masksToBounds = YES;
    self.summaryCardView.layer.borderWidth = kCardBorderWidth;
    self.summaryCardView.layer.borderColor = [UIColor separatorColor].CGColor;
    self.summaryCardView.backgroundColor = [[UIColor whiteColor] colorWithAlphaComponent:0.08];
    [[BackgroundManager sharedManager] applyEffectToView:self.summaryCardView];
    [self.summaryHeaderView addSubview:self.summaryCardView];

    // File/download icon (top left, with a breathing animation while downloading)
    self.summaryIconView = [[UIImageView alloc] init];
    self.summaryIconView.translatesAutoresizingMaskIntoConstraints = NO;
    self.summaryIconView.contentMode = UIViewContentModeScaleAspectFit;
    self.summaryIconView.tintColor = self.view.tintColor ?: FluxTheme.accent;
    self.summaryIconView.image = [UIImage systemImageNamed:@"arrow.down.circle.fill"];
    self.summaryIconView.preferredSymbolConfiguration =
        [UIImageSymbolConfiguration configurationWithPointSize:24 weight:UIFontWeightMedium];
    [self.summaryCardView addSubview:self.summaryIconView];

    // Percentage label (top right, in a large prominent font)
    self.summaryPercentLabel = [[UILabel alloc] init];
    self.summaryPercentLabel.translatesAutoresizingMaskIntoConstraints = NO;
    self.summaryPercentLabel.font = [UIFont systemFontOfSize:22 weight:UIFontWeightBold];
    self.summaryPercentLabel.textColor = [UIColor labelColor];
    self.summaryPercentLabel.textAlignment = NSTextAlignmentRight;
    self.summaryPercentLabel.text = @"0%";
    [self.summaryCardView addSubview:self.summaryPercentLabel];

    // Title label (below the icon, showing the status text)
    self.summaryTitleLabel = [[UILabel alloc] init];
    self.summaryTitleLabel.translatesAutoresizingMaskIntoConstraints = NO;
    self.summaryTitleLabel.font = [UIFont systemFontOfSize:14 weight:UIFontWeightMedium];
    self.summaryTitleLabel.textColor = [UIColor secondaryLabelColor];
    self.summaryTitleLabel.text = localize(@"download.progress.downloading", @"Downloading...");
    [self.summaryCardView addSubview:self.summaryTitleLabel];

    // Custom linear progress bar (theme color, capsule-shaped, smoothly animated)
    self.summaryProgressBar = [[DPVCProgressBar alloc] init];
    self.summaryProgressBar.translatesAutoresizingMaskIntoConstraints = NO;
    self.summaryProgressBar.fillColor = self.view.tintColor ?: FluxTheme.accent;
    self.summaryProgressBar.trackColor = [[UIColor whiteColor] colorWithAlphaComponent:0.12];
    [self.summaryCardView addSubview:self.summaryProgressBar];

    // Mini speed chart (live speed visualization)
    self.speedSparkline = [[DPVCSpeedSparkline alloc] init];
    self.speedSparkline.translatesAutoresizingMaskIntoConstraints = NO;
    self.speedSparkline.barColor = self.view.tintColor ?: FluxTheme.accent;
    [self.summaryCardView addSubview:self.speedSparkline];

    // Bottom info row: size (left) + speed (middle) + ETA (right)
    self.summarySizeLabel = [[UILabel alloc] init];
    self.summarySizeLabel.translatesAutoresizingMaskIntoConstraints = NO;
    self.summarySizeLabel.font = [UIFont systemFontOfSize:12];
    self.summarySizeLabel.textColor = [UIColor secondaryLabelColor];
    self.summarySizeLabel.text = @"";
    [self.summaryCardView addSubview:self.summarySizeLabel];

    self.summarySpeedLabel = [[UILabel alloc] init];
    self.summarySpeedLabel.translatesAutoresizingMaskIntoConstraints = NO;
    self.summarySpeedLabel.font = [UIFont systemFontOfSize:12 weight:UIFontWeightMedium];
    self.summarySpeedLabel.textColor = self.view.tintColor ?: FluxTheme.accent;
    self.summarySpeedLabel.textAlignment = NSTextAlignmentCenter;
    self.summarySpeedLabel.text = @"";
    [self.summaryCardView addSubview:self.summarySpeedLabel];

    self.summaryETALabel = [[UILabel alloc] init];
    self.summaryETALabel.translatesAutoresizingMaskIntoConstraints = NO;
    self.summaryETALabel.font = [UIFont systemFontOfSize:12];
    self.summaryETALabel.textColor = [UIColor secondaryLabelColor];
    self.summaryETALabel.textAlignment = NSTextAlignmentRight;
    self.summaryETALabel.text = @"";
    [self.summaryCardView addSubview:self.summaryETALabel];

    // Activate every constraint
    [NSLayoutConstraint activateConstraints:@[
        // Card container: 16pt on each side, 8pt top and bottom
        [self.summaryCardView.topAnchor constraintEqualToAnchor:self.summaryHeaderView.topAnchor constant:8],
        [self.summaryCardView.leadingAnchor constraintEqualToAnchor:self.summaryHeaderView.leadingAnchor constant:16],
        [self.summaryCardView.trailingAnchor constraintEqualToAnchor:self.summaryHeaderView.trailingAnchor constant:-16],
        [self.summaryCardView.bottomAnchor constraintEqualToAnchor:self.summaryHeaderView.bottomAnchor constant:-8],

        // Icon: top left
        [self.summaryIconView.topAnchor constraintEqualToAnchor:self.summaryCardView.topAnchor constant:16],
        [self.summaryIconView.leadingAnchor constraintEqualToAnchor:self.summaryCardView.leadingAnchor constant:16],
        [self.summaryIconView.widthAnchor constraintEqualToConstant:kSummaryIconSize],
        [self.summaryIconView.heightAnchor constraintEqualToConstant:kSummaryIconSize],

        // Percentage label: top right, vertically centered with the icon
        [self.summaryPercentLabel.topAnchor constraintEqualToAnchor:self.summaryCardView.topAnchor constant:14],
        [self.summaryPercentLabel.trailingAnchor constraintEqualToAnchor:self.summaryCardView.trailingAnchor constant:-16],
        [self.summaryPercentLabel.leadingAnchor constraintEqualToAnchor:self.summaryIconView.trailingAnchor constant:8],

        // Title label: below the icon
        [self.summaryTitleLabel.topAnchor constraintEqualToAnchor:self.summaryIconView.bottomAnchor constant:8],
        [self.summaryTitleLabel.leadingAnchor constraintEqualToAnchor:self.summaryCardView.leadingAnchor constant:16],
        [self.summaryTitleLabel.trailingAnchor constraintEqualToAnchor:self.summaryCardView.trailingAnchor constant:-16],

        // Progress bar: below the title
        [self.summaryProgressBar.topAnchor constraintEqualToAnchor:self.summaryTitleLabel.bottomAnchor constant:10],
        [self.summaryProgressBar.leadingAnchor constraintEqualToAnchor:self.summaryCardView.leadingAnchor constant:16],
        [self.summaryProgressBar.trailingAnchor constraintEqualToAnchor:self.summaryCardView.trailingAnchor constant:-16],
        [self.summaryProgressBar.heightAnchor constraintEqualToConstant:kProgressBarHeight],

        // Mini speed chart: below the progress bar
        [self.speedSparkline.topAnchor constraintEqualToAnchor:self.summaryProgressBar.bottomAnchor constant:10],
        [self.speedSparkline.leadingAnchor constraintEqualToAnchor:self.summaryCardView.leadingAnchor constant:16],
        [self.speedSparkline.trailingAnchor constraintEqualToAnchor:self.summaryCardView.trailingAnchor constant:-16],
        [self.speedSparkline.heightAnchor constraintEqualToConstant:kSpeedSparklineHeight],

        // Bottom info row: size (left) + speed (middle) + ETA (right)
        [self.summarySizeLabel.topAnchor constraintEqualToAnchor:self.speedSparkline.bottomAnchor constant:10],
        [self.summarySizeLabel.leadingAnchor constraintEqualToAnchor:self.summaryCardView.leadingAnchor constant:16],
        [self.summarySizeLabel.bottomAnchor constraintEqualToAnchor:self.summaryCardView.bottomAnchor constant:-14],

        [self.summarySpeedLabel.topAnchor constraintEqualToAnchor:self.speedSparkline.bottomAnchor constant:10],
        [self.summarySpeedLabel.centerXAnchor constraintEqualToAnchor:self.summaryCardView.centerXAnchor],
        [self.summarySpeedLabel.bottomAnchor constraintEqualToAnchor:self.summaryCardView.bottomAnchor constant:-14],

        [self.summaryETALabel.topAnchor constraintEqualToAnchor:self.speedSparkline.bottomAnchor constant:10],
        [self.summaryETALabel.trailingAnchor constraintEqualToAnchor:self.summaryCardView.trailingAnchor constant:-16],
        [self.summaryETALabel.bottomAnchor constraintEqualToAnchor:self.summaryCardView.bottomAnchor constant:-14],
    ]];

    self.tableView.tableHeaderView = self.summaryHeaderView;

    // Start the breathing animation on the download icon (indicating a download in progress)
    [self startIconPulseAnimation];
}

/// Add a breathing animation to the summary icon (a scale pulse indicating a download in progress)
- (void)startIconPulseAnimation {
    [self.summaryIconView.layer removeAllAnimations];
    CAKeyframeAnimation *pulse = [CAKeyframeAnimation animationWithKeyPath:@"transform.scale"];
    pulse.values = @[@1.0, @1.15, @1.0];
    pulse.duration = 1.2;
    pulse.repeatCount = HUGE_VALF;
    pulse.timingFunction =
        [CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionEaseInEaseOut];
    [self.summaryIconView.layer addAnimation:pulse forKey:@"pulseAnimation"];
}

// ============================================================================
// KVO observation
// ============================================================================

- (void)viewDidAppear:(BOOL)animated {
    [super viewDidAppear:animated];

    [self.task.textProgress addObserver:self
        forKeyPath:@"fractionCompleted"
        options:NSKeyValueObservingOptionInitial
        context:TotalProgressObserverContext];
}

- (void)viewDidDisappear:(BOOL)animated {
    [super viewDidDisappear:animated];

    [self.task.textProgress removeObserver:self forKeyPath:@"fractionCompleted"];
}

- (void)actionClose {
    [self.navigationController dismissViewControllerAnimated:YES completion:nil];
}

- (void)observeValueForKeyPath:(NSString *)keyPath ofObject:(id)object change:(NSDictionary *)change context:(void *)context {
    NSProgress *progress = object;
    if (context == CellProgressObserverContext) {
        // Per-file progress update: refresh the matching cell
        DPVCDownloadCell *cell = objc_getAssociatedObject(progress, @"cell");
        if (!cell) return;
        dispatch_async(dispatch_get_main_queue(), ^{
            [cell updateWithProgress:progress];
        });
    } else if (context == TotalProgressObserverContext) {
        // Total progress update: refresh the summary card
        dispatch_async(dispatch_get_main_queue(), ^{
            self.title = progress.localizedDescription;

            double fraction = progress.fractionCompleted;

            // Update the percentage
            NSInteger percent = (NSInteger)(fraction * 100.0 + 0.5);
            percent = MAX(0, MIN(100, percent));
            self.summaryPercentLabel.text = [NSString stringWithFormat:@"%ld%%", (long)percent];

            // Update the title
            if (progress.finished) {
                self.summaryTitleLabel.text = localize(@"download.progress.completed", @"Download complete");
                self.summaryIconView.image = [UIImage systemImageNamed:@"checkmark.circle.fill"];
                self.summaryIconView.tintColor = [UIColor systemGreenColor];
                [self.summaryIconView.layer removeAllAnimations]; // Stop the breathing animation
                self.summaryProgressBar.fillColor = [UIColor systemGreenColor];
            } else {
                self.summaryTitleLabel.text = localize(@"download.progress.downloading", @"Downloading...");
            }

            // Update the progress bar
            [self.summaryProgressBar setProgress:(CGFloat)fraction animated:YES];

            // Update the size label: downloaded / total
            NSMutableString *sizeText = [NSMutableString string];
            if (progress.totalUnitCount > 0) {
                int64_t completed = progress.completedUnitCount;
                int64_t total = progress.totalUnitCount;
                NSString *completedStr = [self.byteFormatter stringFromByteCount:completed];
                NSString *totalStr = [self.byteFormatter stringFromByteCount:total];
                [sizeText appendFormat:@"%@ / %@", completedStr, totalStr];
            }
            self.summarySizeLabel.text = sizeText.length > 0 ? sizeText : @"";

            // Update the speed label and the mini speed chart
            double currentSpeed = 0.0;
            if (progress.throughput) {
                currentSpeed = [progress.throughput doubleValue];
            }

            // Compute the instantaneous speed (from the time delta of completedUnitCount, complementing/backing up throughput)
            struct timeval tv;
            gettimeofday(&tv, NULL);
            CGFloat nowMs = (CGFloat)(tv.tv_sec * 1000.0 + tv.tv_usec / 1000.0);
            if (_lastSpeedSampleTime > 0 && nowMs > _lastSpeedSampleTime) {
                double elapsedSec = (nowMs - _lastSpeedSampleTime) / 1000.0;
                int64_t deltaBytes = progress.completedUnitCount - _lastCompletedBytes;
                if (deltaBytes > 0 && elapsedSec > 0) {
                    double instantSpeed = deltaBytes / elapsedSec;
                    // Take the larger of throughput and the instantaneous speed (throughput sometimes lags)
                    currentSpeed = MAX(currentSpeed, instantSpeed);
                }
            }
            _lastSpeedSampleTime = nowMs;
            _lastCompletedBytes = progress.completedUnitCount;

            // Format and display the speed
            self.summarySpeedLabel.text = [self formatSpeed:currentSpeed];

            // Update the mini speed chart
            if (currentSpeed > _maxObservedSpeed) {
                _maxObservedSpeed = currentSpeed;
            }
            CGFloat normalizedSpeed = (currentSpeed > 0 && _maxObservedSpeed > 0)
                ? (currentSpeed / _maxObservedSpeed)
                : 0.0;
            [self.speedSparkline addSpeedSample:normalizedSpeed];

            // Update the ETA label (in a friendly format: "About 2 min" rather than "120s")
            NSInteger etaSeconds = 0;
            if (progress.estimatedTimeRemaining) {
                etaSeconds = [progress.estimatedTimeRemaining integerValue];
            } else if (currentSpeed > 0 && progress.totalUnitCount > 0) {
                // Compute it manually when the throughput ETA is unavailable
                int64_t remaining = progress.totalUnitCount - progress.completedUnitCount;
                if (remaining > 0) {
                    etaSeconds = (NSInteger)(remaining / currentSpeed);
                }
            }
            self.summaryETALabel.text = [self formatETA:etaSeconds];

            // Refresh the table when the file list changes
            if (self.fileListCount != self.task.fileList.count) {
                [self.tableView reloadData];
            }
            self.fileListCount = self.task.fileList.count;
        });
    } else {
        [super observeValueForKeyPath:keyPath ofObject:object change:change context:context];
    }
}

// ============================================================================
// Formatting helpers
// ============================================================================

/// Format the download speed (bytes/s -> B/s / KB/s / MB/s)
- (NSString *)formatSpeed:(double)bytesPerSec {
    if (bytesPerSec <= 0) return @"0 B/s";
    if (bytesPerSec < 1024.0) {
        return [NSString stringWithFormat:@"%ld B/s", (long)bytesPerSec];
    }
    if (bytesPerSec < 1024.0 * 1024.0) {
        return [NSString stringWithFormat:@"%.1f KB/s", bytesPerSec / 1024.0];
    }
    return [NSString stringWithFormat:@"%.2f MB/s", bytesPerSec / (1024.0 * 1024.0)];
}

/// Format the time remaining (ETA) in friendly wording
/// Rules:
///   0 or negative -> "Almost done"
///   < 60 s        -> "About X sec"
///   < 3600 s      -> "About X min" (rounded to the nearest minute)
///   >= 3600 s     -> "About X hr Y min"
- (NSString *)formatETA:(NSInteger)etaSeconds {
    if (etaSeconds <= 0) {
        return localize(@"download.progress.eta.soon", @"Almost done");
    }

    if (etaSeconds < 60) {
        return [NSString stringWithFormat:localize(@"download.progress.eta.about_seconds", @"About %ld sec"), (long)etaSeconds];
    }

    if (etaSeconds < 3600) {
        // Round to the nearest minute (the remainder rounds up when it is over 30 seconds)
        NSInteger minutes = (etaSeconds + 30) / 60;
        return [NSString stringWithFormat:localize(@"download.progress.eta.about_minutes", @"About %ld min"), (long)minutes];
    }

    // >= 1 hour
    NSInteger hours = etaSeconds / 3600;
    NSInteger minutes = (etaSeconds % 3600) / 60;
    if (minutes > 0) {
        return [NSString stringWithFormat:localize(@"download.progress.eta.about_hours_minutes", @"About %ld hr %ld min"), (long)hours, (long)minutes];
    }
    return [NSString stringWithFormat:localize(@"download.progress.eta.about_hours", @"About %ld hr"), (long)hours];
}

// ============================================================================
// UITableView data source and delegate
// ============================================================================

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    return self.task.fileList.count;
}

- (CGFloat)tableView:(UITableView *)tableView heightForRowAtIndexPath:(NSIndexPath *)indexPath {
    return kCellHeight;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    DPVCDownloadCell *cell = [tableView dequeueReusableCellWithIdentifier:@"DPVCDownloadCell"];

    if (cell == nil) {
        cell = [[DPVCDownloadCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:@"DPVCDownloadCell"];
        cell.progressView.resolvedTintColor = self.view.tintColor ?: FluxTheme.accent;
    }

    // Clear the progress observation attached to the previous cell
    NSProgress *lastProgress = objc_getAssociatedObject(cell, @"progress");
    if (lastProgress) {
        objc_setAssociatedObject(lastProgress, @"cell", nil, OBJC_ASSOCIATION_ASSIGN);
        @try {
            [lastProgress removeObserver:self forKeyPath:@"fractionCompleted"];
        } @catch(id anException) {}
    }

    // Configure the current cell's file name and icon
    NSString *fileName = self.task.fileList[indexPath.row];
    [cell configureWithFileName:fileName];

    // Attach the current file progress and register the KVO observer
    NSProgress *progress = self.task.progressList[indexPath.row];
    objc_setAssociatedObject(cell, @"progress", progress, OBJC_ASSOCIATION_ASSIGN);
    objc_setAssociatedObject(progress, @"cell", cell, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    [progress addObserver:self
        forKeyPath:@"fractionCompleted"
        options:NSKeyValueObservingOptionInitial
        context:CellProgressObserverContext];

    // Reset the circular progress view state
    CircularProgressView *progressView = cell.progressView;
    if (lastProgress && lastProgress.finished) {
        [progressView reset];
    }
    progressView.fractionCompleted = progress.fractionCompleted;
    [progressView transitionCompletedLayerToVisible:progress.finished animated:NO haptic:NO];
    [progressView transitionRunningLayerToVisible:!progress.finished animated:NO];

    return cell;
}

@end
