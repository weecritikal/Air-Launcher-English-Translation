//
//  DownloadProgressCardView.m
//  Amethyst
//
//  下载进度卡片视图实现（参照 FCL/ZL2/HMCL 的下载进度显示风格）
//
//  ============================================================================
//  设计理念
//  ============================================================================
//
//  本组件用于在启动器下载版本/资源时，提供统一的、信息丰富的下载进度显示，
//  替代原先屏幕中央的 UIActivityIndicatorView（转圈圈）和底部 InlineMessageView
//  （纯文字进度）。
//
//  参考了三款主流 Minecraft 启动器的下载进度设计：
//
//  1. FCL (FoldCraftLauncher) 风格：
//     - 底部悬浮卡片，不阻挡用户对启动器其他区域的操作
//     - 同时展示：进度条 + 百分比 + 下载速度 + 剩余时间（ETA）+ 当前文件名
//     - 信息密度高，用户可以一眼掌握下载全部关键信息
//
//  2. ZL2 (ZalithLauncher) 风格：
//     - 圆角毛玻璃背景（毛玻璃与下方内容形成层次感）
//     - 彩色进度条（下载中蓝色，完成绿色，失败红色）
//     - 进度变化时带平滑动画过渡，避免突兀的跳变
//
//  3. HMCL 风格：
//     - 简洁的信息布局，状态图标 + 标题 + 副标题清晰分层
//     - 状态图标明确指示当前阶段（下载/完成/失败/取消）
//
//  本组件综合了上述三者的优点：
//  - 底部悬浮 + 毛玻璃圆角 + 阴影（FCL + ZL2）
//  - 彩色进度条 + 平滑动画（ZL2）
//  - 状态图标 + 信息分层布局（HMCL）
//  - 不确定模式（progress = -1）支持，下载准备阶段显示转圈
//
//  此外，本组件适配启动器的自定义背景功能：
//  - 当 BackgroundManager 检测到全局背景存在时，使用毛玻璃效果让背景透出
//  - 无背景时回退到 secondarySystemGroupedBackgroundColor，保证可读性
//  - 监听 BackgroundUIEffectChanged 通知，背景效果切换时实时刷新
//
//  ============================================================================

#import "DownloadProgressCardView.h"

#import "BackgroundManager.h"

/// 卡片视觉常量
static const CGFloat kCardCornerRadius    = 16.0;
static const CGFloat kCardSideInset        = 16.0;
static const CGFloat kCardBottomInset      = 16.0;
static const CGFloat kCardInternalPadding  = 16.0;
static const CGFloat kCardShadowRadius     = 12.0;
static const CGFloat kCardShadowOpacity    = 0.18;
static const CGFloat kCardShadowOffsetY    = 4.0;

/// 进度条视觉常量
static const CGFloat kProgressBarHeight    = 6.0;
static const CGFloat kProgressBarCornerRadius = 3.0;

/// 状态图标尺寸
static const CGFloat kStatusIconSize       = 24.0;

/// 进度条动画时长
static const NSTimeInterval kProgressAnimationDuration = 0.3;
/// 显示/隐藏动画时长
static const NSTimeInterval kShowAnimationDuration     = 0.3;
static const NSTimeInterval kHideAnimationDuration     = 0.3;
/// 完成态自动消失时长
static const NSTimeInterval kAutoDismissAfterComplete  = 1.8;
static const NSTimeInterval kAutoDismissAfterFail      = 3.0;

/// BackgroundUIEffectChanged 通知名（与项目中其他位置保持一致）
static NSString *const kBackgroundUIEffectChangedNotification = @"BackgroundUIEffectChanged";

/// 下载状态枚举（内部使用）
typedef NS_ENUM(NSInteger, DownloadCardState) {
    DownloadCardStateIdle        = 0,  // 空闲（未开始）
    DownloadCardStateDownloading = 1,  // 下载中
    DownloadCardStateIndeterminate = 2, // 不确定模式（准备中）
    DownloadCardStateCompleted   = 3,  // 完成
    DownloadCardStateFailed      = 4,  // 失败
    DownloadCardStateCancelled   = 5,  // 取消
};

#pragma mark - 自定义进度条视图

/// 自定义进度条视图，支持平滑动画和颜色切换。
/// 相比 UIProgressView，本视图可以更精细地控制圆角、颜色和动画曲线，
/// 以匹配 ZL2 风格的视觉效果。
@interface DPCProgressBar : UIView

/// 进度 0.0~1.0
@property (nonatomic, assign) CGFloat progress;
/// 填充颜色
@property (nonatomic, strong) UIColor *fillColor;
/// 轨道颜色
@property (nonatomic, strong) UIColor *trackColor;

/// 设置进度，可选择是否带动画
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

/// 初始化轨道和填充图层
- (void)setupLayers {
    _trackLayer = [CAShapeLayer layer];
    _trackLayer.fillColor = [UIColor systemGray5Color].CGColor;
    _trackLayer.lineWidth = 0;
    [self.layer addSublayer:_trackLayer];

    _fillLayer = [CAShapeLayer layer];
    _fillLayer.fillColor = [UIColor systemBlueColor].CGColor;
    _fillLayer.lineWidth = 0;
    [self.layer addSublayer:_fillLayer];

    // 默认值
    _progress = 0.0;
    _fillColor = [UIColor systemBlueColor];
    _trackColor = [UIColor systemGray5Color];

    // 裁剪填充图层，避免超出圆角
    self.layer.masksToBounds = YES;

    // 通过 backgroundColor 设置轨道颜色，简化实现
    self.backgroundColor = _trackColor;
}

- (void)layoutSubviews {
    [super layoutSubviews];
    [self updateLayerFrames];
}

/// 更新图层 frame（圆角矩形路径）
- (void)updateLayerFrames {
    CGRect bounds = self.bounds;
    CGFloat cornerRadius = bounds.size.height / 2.0;

    // 轨道铺满整个视图
    UIBezierPath *trackPath =
        [UIBezierPath bezierPathWithRoundedRect:bounds
                                  cornerRadius:cornerRadius];
    _trackLayer.path = trackPath.CGPath;
    _trackLayer.frame = bounds;

    // 填充宽度按进度计算
    CGFloat fillWidth = MAX(0.0, bounds.size.width * _progress);
    CGRect fillRect = CGRectMake(0, 0, fillWidth, bounds.size.height);
    // 用圆角矩形作为填充路径，避免右侧出现直角
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
        // 使用 CABasicAnimation 让填充宽度平滑过渡。
        // 这里通过重新生成 path 并对 path 做隐式动画实现。
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

// 背景容器（毛玻璃或纯色）
@property (nonatomic, strong) UIVisualEffectView *blurEffectView;
@property (nonatomic, strong) UIView *solidBackgroundView;

// 内容容器（承载所有子视图，便于统一 padding）
@property (nonatomic, strong) UIView *contentContainer;

// 顶部行
@property (nonatomic, strong) UIImageView *statusIconView;
@property (nonatomic, strong) UIActivityIndicatorView *spinnerView;
@property (nonatomic, strong) UILabel *percentLabel;

// 标题行
@property (nonatomic, strong) UILabel *titleLabel;
@property (nonatomic, strong) UILabel *subtitleLabel;

// 进度条
@property (nonatomic, strong) DPCProgressBar *progressBar;

// 信息行（已下载/总大小 + 速度）
@property (nonatomic, strong) UILabel *downloadedLabel;
@property (nonatomic, strong) UILabel *speedLabel;

// ETA 行
@property (nonatomic, strong) UILabel *etaLabel;

// 当前文件行
@property (nonatomic, strong) UILabel *currentFileLabel;

// 状态
@property (nonatomic, assign) DownloadCardState state;
@property (nonatomic, copy, nullable) NSString *currentTitle;
@property (nonatomic, copy, nullable) NSString *currentSubtitle;

// 字节计数格式化器（复用）
@property (nonatomic, strong) NSByteCountFormatter *byteFormatter;

// 是否已加入父视图
@property (nonatomic, assign) BOOL isShown;
// 自动消失定时器
@property (nonatomic, strong, nullable) NSTimer *autoDismissTimer;

// 约束：底部约束（用于显示/隐藏动画时调整）
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

/// 公共初始化
- (void)commonInit {
    _progress = -1.0; // 默认不确定模式
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

/// 创建并添加所有子视图
- (void)setupSubviews {
    // 整个卡片背景透明，靠内部背景视图承载颜色/毛玻璃
    self.backgroundColor = [UIColor clearColor];
    self.layer.cornerRadius = kCardCornerRadius;
    self.layer.masksToBounds = NO; // 阴影需要不裁剪

    // 毛玻璃背景视图
    UIBlurEffect *blurEffect = [UIBlurEffect effectWithStyle:UIBlurEffectStyleSystemMaterial];
    self.blurEffectView = [[UIVisualEffectView alloc] initWithEffect:blurEffect];
    self.blurEffectView.translatesAutoresizingMaskIntoConstraints = NO;
    self.blurEffectView.layer.cornerRadius = kCardCornerRadius;
    self.blurEffectView.layer.masksToBounds = YES;
    [self addSubview:self.blurEffectView];

    // 纯色背景视图（无自定义背景时使用）
    self.solidBackgroundView = [[UIView alloc] init];
    self.solidBackgroundView.translatesAutoresizingMaskIntoConstraints = NO;
    self.solidBackgroundView.backgroundColor = [UIColor secondarySystemGroupedBackgroundColor];
    self.solidBackgroundView.layer.cornerRadius = kCardCornerRadius;
    self.solidBackgroundView.layer.masksToBounds = YES;
    self.solidBackgroundView.hidden = YES;
    [self addSubview:self.solidBackgroundView];

    // 阴影（通过 self.layer 设置）
    self.layer.shadowColor = [UIColor blackColor].CGColor;
    self.layer.shadowOffset = CGSizeMake(0, kCardShadowOffsetY);
    self.layer.shadowRadius = kCardShadowRadius;
    self.layer.shadowOpacity = (float)kCardShadowOpacity;

    // 内容容器
    self.contentContainer = [[UIView alloc] init];
    self.contentContainer.translatesAutoresizingMaskIntoConstraints = NO;
    self.contentContainer.backgroundColor = [UIColor clearColor];
    [self addSubview:self.contentContainer];

    // 状态图标
    self.statusIconView = [[UIImageView alloc] init];
    self.statusIconView.translatesAutoresizingMaskIntoConstraints = NO;
    self.statusIconView.contentMode = UIViewContentModeScaleAspectFit;
    self.statusIconView.tintColor = [UIColor systemBlueColor];
    self.statusIconView.preferredSymbolConfiguration =
        [UIImageSymbolConfiguration configurationWithPointSize:20 weight:UIFontWeightMedium];
    self.statusIconView.image = [UIImage systemImageNamed:@"arrow.down.circle.fill"];
    [self.contentContainer addSubview:self.statusIconView];

    // 转圈视图（不确定模式时显示）
    self.spinnerView = [[UIActivityIndicatorView alloc]
        initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleMedium];
    self.spinnerView.translatesAutoresizingMaskIntoConstraints = NO;
    self.spinnerView.hidesWhenStopped = YES;
    self.spinnerView.color = [UIColor systemBlueColor];
    [self.contentContainer addSubview:self.spinnerView];

    // 百分比标签
    self.percentLabel = [[UILabel alloc] init];
    self.percentLabel.translatesAutoresizingMaskIntoConstraints = NO;
    self.percentLabel.font = [UIFont systemFontOfSize:18 weight:UIFontWeightSemibold];
    self.percentLabel.textColor = [UIColor labelColor];
    self.percentLabel.textAlignment = NSTextAlignmentRight;
    self.percentLabel.text = @"0%";
    [self.contentContainer addSubview:self.percentLabel];

    // 标题标签
    self.titleLabel = [[UILabel alloc] init];
    self.titleLabel.translatesAutoresizingMaskIntoConstraints = NO;
    self.titleLabel.font = [UIFont systemFontOfSize:16 weight:UIFontWeightSemibold];
    self.titleLabel.textColor = [UIColor labelColor];
    self.titleLabel.numberOfLines = 1;
    self.titleLabel.lineBreakMode = NSLineBreakByTruncatingTail;
    self.titleLabel.text = @"准备下载...";
    [self.contentContainer addSubview:self.titleLabel];

    // 副标题标签
    self.subtitleLabel = [[UILabel alloc] init];
    self.subtitleLabel.translatesAutoresizingMaskIntoConstraints = NO;
    self.subtitleLabel.font = [UIFont systemFontOfSize:12];
    self.subtitleLabel.textColor = [UIColor secondaryLabelColor];
    self.subtitleLabel.numberOfLines = 1;
    self.subtitleLabel.lineBreakMode = NSLineBreakByTruncatingTail;
    [self.contentContainer addSubview:self.subtitleLabel];

    // 进度条
    self.progressBar = [[DPCProgressBar alloc] init];
    self.progressBar.translatesAutoresizingMaskIntoConstraints = NO;
    self.progressBar.fillColor = [UIColor systemBlueColor];
    self.progressBar.trackColor = [UIColor systemGray5Color];
    [self.contentContainer addSubview:self.progressBar];

    // 已下载标签
    self.downloadedLabel = [[UILabel alloc] init];
    self.downloadedLabel.translatesAutoresizingMaskIntoConstraints = NO;
    self.downloadedLabel.font = [UIFont systemFontOfSize:12];
    self.downloadedLabel.textColor = [UIColor secondaryLabelColor];
    self.downloadedLabel.text = @"0 KB / 0 KB";
    [self.contentContainer addSubview:self.downloadedLabel];

    // 速度标签
    self.speedLabel = [[UILabel alloc] init];
    self.speedLabel.translatesAutoresizingMaskIntoConstraints = NO;
    self.speedLabel.font = [UIFont systemFontOfSize:12 weight:UIFontWeightMedium];
    self.speedLabel.textColor = [UIColor systemBlueColor];
    self.speedLabel.textAlignment = NSTextAlignmentRight;
    self.speedLabel.text = @"0 KB/s";
    [self.contentContainer addSubview:self.speedLabel];

    // ETA 标签
    self.etaLabel = [[UILabel alloc] init];
    self.etaLabel.translatesAutoresizingMaskIntoConstraints = NO;
    self.etaLabel.font = [UIFont systemFontOfSize:12];
    self.etaLabel.textColor = [UIColor secondaryLabelColor];
    self.etaLabel.text = @"";
    [self.contentContainer addSubview:self.etaLabel];

    // 当前文件标签
    self.currentFileLabel = [[UILabel alloc] init];
    self.currentFileLabel.translatesAutoresizingMaskIntoConstraints = NO;
    self.currentFileLabel.font = [UIFont systemFontOfSize:11];
    self.currentFileLabel.textColor = [UIColor tertiaryLabelColor];
    self.currentFileLabel.numberOfLines = 1;
    self.currentFileLabel.lineBreakMode = NSLineBreakByTruncatingMiddle;
    self.currentFileLabel.text = @"";
    [self.contentContainer addSubview:self.currentFileLabel];
}

/// 设置 Auto Layout 约束
- (void)setupConstraints {
    // 背景视图与卡片自身四边对齐
    [NSLayoutConstraint activateConstraints:@[
        [self.blurEffectView.topAnchor constraintEqualToAnchor:self.topAnchor],
        [self.blurEffectView.leadingAnchor constraintEqualToAnchor:self.leadingAnchor],
        [self.blurEffectView.trailingAnchor constraintEqualToAnchor:self.trailingAnchor],
        [self.blurEffectView.bottomAnchor constraintEqualToAnchor:self.bottomAnchor],

        [self.solidBackgroundView.topAnchor constraintEqualToAnchor:self.topAnchor],
        [self.solidBackgroundView.leadingAnchor constraintEqualToAnchor:self.leadingAnchor],
        [self.solidBackgroundView.trailingAnchor constraintEqualToAnchor:self.trailingAnchor],
        [self.solidBackgroundView.bottomAnchor constraintEqualToAnchor:self.bottomAnchor],

        // 内容容器：内边距 16pt
        [self.contentContainer.topAnchor constraintEqualToAnchor:self.topAnchor
                                                       constant:kCardInternalPadding],
        [self.contentContainer.leadingAnchor constraintEqualToAnchor:self.leadingAnchor
                                                           constant:kCardInternalPadding],
        [self.contentContainer.trailingAnchor constraintEqualToAnchor:self.trailingAnchor
                                                            constant:-kCardInternalPadding],
        [self.contentContainer.bottomAnchor constraintEqualToAnchor:self.bottomAnchor
                                                           constant:-kCardInternalPadding],
    ]];

    // 顶部行：状态图标/转圈 居左，百分比居右
    [NSLayoutConstraint activateConstraints:@[
        [self.statusIconView.leadingAnchor constraintEqualToAnchor:self.contentContainer.leadingAnchor],
        [self.statusIconView.topAnchor constraintEqualToAnchor:self.contentContainer.topAnchor],
        [self.statusIconView.widthAnchor constraintEqualToConstant:kStatusIconSize],
        [self.statusIconView.heightAnchor constraintEqualToConstant:kStatusIconSize],

        // spinner 与 statusIcon 同位置（两者互斥显示）
        [self.spinnerView.leadingAnchor constraintEqualToAnchor:self.contentContainer.leadingAnchor],
        [self.spinnerView.centerYAnchor constraintEqualToAnchor:self.statusIconView.centerYAnchor],
        [self.spinnerView.widthAnchor constraintEqualToConstant:kStatusIconSize],
        [self.spinnerView.heightAnchor constraintEqualToConstant:kStatusIconSize],

        [self.percentLabel.trailingAnchor constraintEqualToAnchor:self.contentContainer.trailingAnchor],
        [self.percentLabel.centerYAnchor constraintEqualToAnchor:self.statusIconView.centerYAnchor],
        [self.percentLabel.leadingAnchor constraintEqualToAnchor:self.statusIconView.trailingAnchor
                                                        constant:8],
    ]];

    // 标题行
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

    // 进度条
    [NSLayoutConstraint activateConstraints:@[
        [self.progressBar.topAnchor constraintEqualToAnchor:self.subtitleLabel.bottomAnchor
                                                   constant:10],
        [self.progressBar.leadingAnchor constraintEqualToAnchor:self.contentContainer.leadingAnchor],
        [self.progressBar.trailingAnchor constraintEqualToAnchor:self.contentContainer.trailingAnchor],
        [self.progressBar.heightAnchor constraintEqualToConstant:kProgressBarHeight],
    ]];

    // 信息行（已下载 + 速度）
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

    // ETA 行
    [NSLayoutConstraint activateConstraints:@[
        [self.etaLabel.topAnchor constraintEqualToAnchor:self.downloadedLabel.bottomAnchor
                                                constant:4],
        [self.etaLabel.leadingAnchor constraintEqualToAnchor:self.contentContainer.leadingAnchor],
        [self.etaLabel.trailingAnchor constraintEqualToAnchor:self.contentContainer.trailingAnchor],
    ]];

    // 当前文件行
    [NSLayoutConstraint activateConstraints:@[
        [self.currentFileLabel.topAnchor constraintEqualToAnchor:self.etaLabel.bottomAnchor
                                                        constant:4],
        [self.currentFileLabel.leadingAnchor constraintEqualToAnchor:self.contentContainer.leadingAnchor],
        [self.currentFileLabel.trailingAnchor constraintEqualToAnchor:self.contentContainer.trailingAnchor],
        [self.currentFileLabel.bottomAnchor constraintEqualToAnchor:self.contentContainer.bottomAnchor],
    ]];
}

#pragma mark - 背景适配

/// 应用背景样式：有自定义背景时用毛玻璃，否则用纯色
- (void)applyBackgroundStyle {
    BOOL hasBg = [[BackgroundManager sharedManager] hasBackground];

    if (hasBg) {
        // 有全局背景：使用毛玻璃，让背景透出，隐藏纯色背景
        self.blurEffectView.hidden = NO;
        self.solidBackgroundView.hidden = YES;
    } else {
        // 无全局背景：使用纯色，保证可读性，隐藏毛玻璃
        self.blurEffectView.hidden = YES;
        self.solidBackgroundView.hidden = NO;
    }

    // 文字颜色随背景调整：有背景时倾向白色，无背景时用系统默认色
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

    // 速度标签颜色保持系统蓝色（在毛玻璃上仍可读），失败态会变红
    // 状态图标颜色由状态决定，不在这里调整
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

    // 约束：左右各 16pt，底部到 safeArea + 16
    [NSLayoutConstraint activateConstraints:@[
        [card.leadingAnchor constraintEqualToAnchor:parentView.leadingAnchor
                                           constant:kCardSideInset],
        [card.trailingAnchor constraintEqualToAnchor:parentView.trailingAnchor
                                            constant:-kCardSideInset],
    ]];

    // 底部约束：优先用 safeAreaLayoutGuide，回退到 layoutMarginsGuide
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

    self.titleLabel.text = title ?: @"正在下载";
    self.subtitleLabel.text = subtitle ?: @"";

    // 默认进入不确定模式，等待第一次 updateProgress
    self.progress = -1.0;
    [self applyState:DownloadCardStateIndeterminate];

    // 重置显示
    self.percentLabel.text = @"";
    self.downloadedLabel.text = @"准备中...";
    self.speedLabel.text = @"";
    self.etaLabel.text = @"";
    self.currentFileLabel.text = @"";
    [self.progressBar setProgress:0.0 animated:NO];

    // 取消可能存在的自动消失定时器
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
    // 限制在主线程执行（UI 更新）
    dispatch_async(dispatch_get_main_queue(), ^{
        [self performProgressUpdate:progress
                         downloaded:downloadedBytes
                               total:totalBytes
                              speed:speedBytesPerSec
                                eta:etaSeconds
                        currentFile:currentFile];
    });
}

/// 实际执行进度更新（主线程）
- (void)performProgressUpdate:(double)progress
                   downloaded:(long long)downloadedBytes
                         total:(long long)totalBytes
                        speed:(long long)speedBytesPerSec
                          eta:(NSInteger)etaSeconds
                  currentFile:(NSString *)currentFile {
    self.progress = progress;

    // 判断是否进入确定模式
    if (progress >= 0.0) {
        [self applyState:DownloadCardStateDownloading];
    } else {
        [self applyState:DownloadCardStateIndeterminate];
    }

    // 百分比
    if (progress >= 0.0) {
        NSInteger percent = (NSInteger)(progress * 100.0 + 0.5);
        percent = MAX(0, MIN(100, percent));
        self.percentLabel.text = [NSString stringWithFormat:@"%ld%%", (long)percent];
    } else {
        self.percentLabel.text = @"";
    }

    // 进度条
    if (progress >= 0.0) {
        [self.progressBar setProgress:(CGFloat)progress animated:YES];
    } else {
        [self.progressBar setProgress:0.0 animated:NO];
    }

    // 已下载/总大小
    NSString *downloadedStr = [self formatBytes:downloadedBytes];
    if (totalBytes > 0) {
        NSString *totalStr = [self formatBytes:totalBytes];
        self.downloadedLabel.text =
            [NSString stringWithFormat:@"%@ / %@", downloadedStr, totalStr];
    } else if (totalBytes < 0) {
        // 总大小未知，只显示已下载
        self.downloadedLabel.text =
            [NSString stringWithFormat:@"%@ / 未知", downloadedStr];
    } else {
        self.downloadedLabel.text = downloadedStr;
    }

    // 速度
    self.speedLabel.text = [self formatSpeed:speedBytesPerSec];

    // ETA
    self.etaLabel.text = [self formatETA:etaSeconds];

    // 当前文件名
    self.currentFileLabel.text = currentFile ?: @"";
}

- (void)completeWithTitle:(NSString *)title {
    dispatch_async(dispatch_get_main_queue(), ^{
        self.currentTitle = title;
        self.titleLabel.text = title ?: @"下载完成";

        // 进度条置满
        self.progress = 1.0;
        [self.progressBar setProgress:1.0 animated:YES];
        self.percentLabel.text = @"100%";

        [self applyState:DownloadCardStateCompleted];

        // 停止转圈
        [self.spinnerView stopAnimating];

        // 清空速度/ETA
        self.speedLabel.text = @"完成";
        self.etaLabel.text = @"";

        // 自动消失
        [self scheduleAutoDismissAfter:kAutoDismissAfterComplete];
    });
}

- (void)failWithError:(NSError *)error {
    dispatch_async(dispatch_get_main_queue(), ^{
        NSString *failTitle = @"下载失败";
        if (error && error.localizedDescription.length > 0) {
            failTitle = [NSString stringWithFormat:@"下载失败：%@",
                         error.localizedDescription];
        }
        self.titleLabel.text = failTitle;
        self.currentTitle = failTitle;

        [self applyState:DownloadCardStateFailed];
        [self.spinnerView stopAnimating];

        self.speedLabel.text = @"失败";
        self.etaLabel.text = @"";

        // 自动消失（失败态停留更久，让用户看清错误）
        [self scheduleAutoDismissAfter:kAutoDismissAfterFail];
    });
}

- (void)cancel {
    dispatch_async(dispatch_get_main_queue(), ^{
        self.titleLabel.text = @"已取消下载";
        self.currentTitle = @"已取消下载";

        [self applyState:DownloadCardStateCancelled];
        [self.spinnerView stopAnimating];

        self.speedLabel.text = @"已取消";
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

/// 应用状态：更新图标、颜色、可见性
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
            // 默认值：蓝色 + 下载图标
            animateIcon = YES;
            break;
        case DownloadCardStateIndeterminate:
            // 不确定模式：转圈 + 隐藏百分比和进度条
            showPercent = NO;
            showProgressBar = NO;
            showSpinner = YES;
            // 副标题位置显示 "正在准备..."
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

    // 更新图标
    UIImageSymbolConfiguration *config =
        [UIImageSymbolConfiguration configurationWithPointSize:20 weight:UIFontWeightMedium];
    self.statusIconView.preferredSymbolConfiguration = config;
    self.statusIconView.image = [UIImage systemImageNamed:imageName];
    self.statusIconView.tintColor = iconColor;

    // 更新进度条颜色
    self.progressBar.fillColor = fillColor;

    // 更新速度颜色
    self.speedLabel.textColor = speedColor;

    // 显隐控制
    self.percentLabel.hidden = !showPercent;
    self.progressBar.hidden = !showProgressBar;
    self.statusIconView.hidden = showSpinner;

    // 转圈
    if (showSpinner) {
        [self.spinnerView startAnimating];
    } else {
        [self.spinnerView stopAnimating];
    }

    // 下载中状态图标的呼吸动画（缩放）
    [self.statusIconView.layer removeAllAnimations];
    if (animateIcon) {
        [self addPulseAnimationToIcon];
    }

    // 不确定模式下，将标题改为"正在准备..."
    if (state == DownloadCardStateIndeterminate && self.currentTitle) {
        // 保留用户设置的标题，仅在没有更新过进度时显示提示
        // 这里不改写 titleLabel，由 startDownloadWithTitle 设置
    }
}

/// 给状态图标添加呼吸动画
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

/// 显示动画：从底部向上滑入 + 淡入（spring）
- (void)showAnimated:(BOOL)animated {
    if (self.isShown) return;

    self.isShown = YES;
    self.hidden = NO;
    self.alpha = 0.0;

    // 初始位置：向下偏移一个卡片高度（模拟从屏幕外滑入）
    if (self.bottomConstraint) {
        // 临时将底部 constraint 设为负值（向下偏移），然后动画回到目标值
        CGFloat offset = self.bounds.size.height;
        if (offset <= 0) {
            offset = 120; // 兜底值
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

/// 隐藏动画：向下滑出 + 淡出
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

/// 调度自动消失
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

/// 格式化字节数（使用 NSByteCountFormatter）
- (NSString *)formatBytes:(long long)bytes {
    if (bytes < 0) return @"0 B";
    return [self.byteFormatter stringFromByteCount:bytes];
}

/// 格式化下载速度
/// 规则：>1MB 显示 MB/s，>1KB 显示 KB/s，否则 B/s
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

/// 格式化剩余时间（ETA）
/// 规则：
///   >1小时：X小时Y分
///   >1分钟：X分Y秒
///   否则：X秒
- (NSString *)formatETA:(NSInteger)etaSeconds {
    if (etaSeconds < 0) return @"";
    if (etaSeconds == 0) return @"即将完成";

    NSInteger hours = etaSeconds / 3600;
    NSInteger minutes = (etaSeconds % 3600) / 60;
    NSInteger seconds = etaSeconds % 60;

    if (hours >= 1) {
        return [NSString stringWithFormat:@"剩余 %ld小时%ld分",
                (long)hours, (long)minutes];
    } else if (minutes >= 1) {
        return [NSString stringWithFormat:@"剩余 %ld分%ld秒",
                (long)minutes, (long)seconds];
    } else {
        return [NSString stringWithFormat:@"剩余 %ld秒", (long)seconds];
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
