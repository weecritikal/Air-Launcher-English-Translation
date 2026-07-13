// ============================================================================
// DownloadProgressViewController.m
// 下载进度显示界面（参照 FCL/ZL2 风格重构）
// ============================================================================
//
// 设计理念
// ============================================================================
// 本控制器用于展示 Minecraft 资源下载的实时进度，综合参考了 FCL（FoldCraftLauncher）
// 和 ZL2（ZalithLauncher）的下载进度界面设计：
//
// 1. FCL 风格：
//    - 顶部摘要卡片同时展示：进度百分比 + 进度条 + 下载速度 + 剩余时间（ETA）
//    - 信息密度高，用户一眼掌握全部关键信息
//    - 速度可视化：实时速度迷你图表，直观反映速度波动
//
// 2. ZL2 风格：
//    - 圆角毛玻璃卡片背景，与下方内容形成层次感
//    - 彩色进度条（主题色），平滑动画过渡
//    - 16pt 圆角 + 0.5pt 边框 + 半透明背景 + 毛玻璃
//
// 3. HMCL 风格：
//    - 单文件列表清晰展示每个文件的独立进度
//    - 文件类型图标 + 文件大小 + 速度信息分层展示
//
// 视觉规范（与项目其他卡片统一）：
//    - 圆角：16pt
//    - 边框：0.5pt（UIColor.separatorColor）
//    - 背景：半透明白色 8% + 毛玻璃效果（通过 BackgroundManager）
//    - 进度条：主题色（tintColor），圆角胶囊形
// ============================================================================

#import <objc/runtime.h>
#import <sys/time.h>
#import "DownloadProgressViewController.h"
#import "BackgroundManager.h"
#import "utils.h"

// ============================================================================
// 视觉常量
// ============================================================================

/// 卡片圆角半径（与项目其他卡片统一）
static const CGFloat kCardCornerRadius     = 16.0;
/// 卡片边框宽度
static const CGFloat kCardBorderWidth      = 0.5;
/// 摘要头部视图总高度
static const CGFloat kSummaryHeaderHeight  = 210.0;
/// 单文件 Cell 高度
static const CGFloat kCellHeight           = 80.0;
/// 线性进度条高度
static const CGFloat kProgressBarHeight    = 8.0;
/// 速度迷你图表高度
static const CGFloat kSpeedSparklineHeight = 36.0;
/// 速度迷你图表最大样本数（超过后滚动移除最旧样本）
static const NSInteger kMaxSpeedSamples    = 40;
/// 进度条动画时长
static const NSTimeInterval kProgressAnimDuration = 0.3;
/// 文件类型图标尺寸
static const CGFloat kFileIconSize         = 28.0;
/// 圆形进度视图尺寸
static const CGFloat kCircularProgressSize = 34.0;
/// 摘要头部图标尺寸
static const CGFloat kSummaryIconSize      = 32.0;

// KVO 观察上下文（区分单文件进度与总进度）
static void *CellProgressObserverContext = &CellProgressObserverContext;
static void *TotalProgressObserverContext = &TotalProgressObserverContext;

// ============================================================================
// 自定义线性进度条（参照 DPCProgressBar，支持平滑动画 + 主题色）
// ============================================================================
// 相比系统 UIProgressView，本视图可以更精细地控制圆角、颜色和动画曲线，
// 以匹配 ZL2 风格的胶囊形进度条视觉效果。

@interface DPVCProgressBar : UIView
/// 进度值 0.0 ~ 1.0
@property (nonatomic, assign) CGFloat progress;
/// 填充颜色（进度条已填充部分）
@property (nonatomic, strong) UIColor *fillColor;
/// 轨道颜色（进度条未填充部分）
@property (nonatomic, strong) UIColor *trackColor;
/// 设置进度，可选择是否带动画
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

/// 初始化轨道和填充图层
- (void)setupLayers {
    // 轨道：铺满整个视图，圆角胶囊形
    _trackLayer = [CAShapeLayer layer];
    _trackLayer.fillColor = [UIColor systemGray5Color].CGColor;
    _trackLayer.lineWidth = 0;
    [self.layer addSublayer:_trackLayer];

    // 填充：宽度按进度计算，圆角胶囊形
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
    // 限制在 0.0 ~ 1.0 范围
    progress = MAX(0.0, MIN(1.0, progress));
    _progress = progress;

    if (animated) {
        // 使用 CABasicAnimation 让填充宽度平滑过渡
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
// 速度迷你图表（实时速度可视化）
// ============================================================================
// 在摘要卡片中展示最近 N 次速度采样的柱状图，让用户直观感知速度波动趋势。
// 采样值会被归一化到 0.0~1.0 范围（基于历史最大值）， newest 在最右侧。

@interface DPVCSpeedSparkline : UIView

/// 添加一个速度采样（归一化值 0.0~1.0，超出范围会被 clamp）
- (void)addSpeedSample:(CGFloat)normalizedSpeed;
/// 清空所有采样
- (void)reset;
/// 设置柱状图颜色
@property (nonatomic, strong) UIColor *barColor;

@end

@implementation DPVCSpeedSparkline {
    NSMutableArray<NSNumber *> *_samples;
}

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        // 预分配容量，避免频繁扩容
        _samples = [[NSMutableArray alloc] initWithCapacity:kMaxSpeedSamples];
        _barColor = [UIColor systemBlueColor];
        self.backgroundColor = [UIColor clearColor];
    }
    return self;
}

- (void)addSpeedSample:(CGFloat)normalizedSpeed {
    // clamp 到 0.0 ~ 1.0
    normalizedSpeed = MAX(0.0, MIN(1.0, normalizedSpeed));

    // 超过最大样本数时移除最旧的
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
        // 无数据时绘制占位底线
        CGContextSetStrokeColorWithColor(ctx, [[UIColor systemGray4Color] CGColor]);
        CGContextSetLineWidth(ctx, 1.0);
        CGFloat y = rect.size.height - 1.0;
        CGContextMoveToPoint(ctx, 0, y);
        CGContextAddLineToPoint(ctx, rect.size.width, y);
        CGContextStrokePath(ctx);
        return;
    }

    // 计算每个柱子的宽度和间距
    CGFloat totalWidth = rect.size.width;
    CGFloat spacing = 2.0;
    CGFloat barWidth = MAX(1.0, (totalWidth - spacing * (count - 1)) / count);
    CGFloat minHeight = 2.0; // 最小高度，确保至少可见

    for (NSInteger i = 0; i < count; i++) {
        CGFloat value = _samples[i].floatValue;
        CGFloat barHeight = MAX(minHeight, value * (rect.size.height - minHeight));
        CGFloat x = i * (barWidth + spacing);
        CGFloat y = rect.size.height - barHeight;

        CGRect barRect = CGRectMake(x, y, barWidth, barHeight);
        // 圆角柱子（顶部圆角）
        CGFloat cornerR = MIN(barWidth / 2.0, 2.0);
        UIBezierPath *barPath =
            [UIBezierPath bezierPathWithRoundedRect:barRect
                                   byRoundingCorners:UIRectCornerTopLeft | UIRectCornerTopRight
                                         cornerRadii:CGSizeMake(cornerR, cornerR)];

        // 最右侧（最新）的柱子使用不透明颜色，其余使用半透明以区分新旧
        BOOL isLatest = (i == count - 1);
        UIColor *color = isLatest ? _barColor : [_barColor colorWithAlphaComponent:0.5];
        CGContextSetFillColorWithColor(ctx, color.CGColor);
        CGContextAddPath(ctx, barPath.CGPath);
        CGContextFillPath(ctx);
    }
}

@end

// ============================================================================
// 自定义圆形进度视图（保留原有设计，增强完成态动画）
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
    CAShapeLayer *_completedLayer; // 完成时的对勾
    BOOL _completedVisible;
    BOOL _runningVisible;
}

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        self.backgroundColor = [UIColor clearColor];
        _resolvedTintColor = [UIColor systemBlueColor];
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

        // 轨道层（灰色背景圆环）
        _trackLayer = [CAShapeLayer layer];
        _trackLayer.path = circlePath.CGPath;
        _trackLayer.fillColor = nil;
        _trackLayer.strokeColor = [[UIColor whiteColor] colorWithAlphaComponent:0.15].CGColor;
        _trackLayer.lineWidth = lineWidth;
        _trackLayer.strokeStart = 0.0;
        _trackLayer.strokeEnd = 1.0;
        [self.layer addSublayer:_trackLayer];

        // 进度层（主题色进度圆环）
        _progressLayer = [CAShapeLayer layer];
        _progressLayer.path = circlePath.CGPath;
        _progressLayer.fillColor = nil;
        _progressLayer.strokeColor = _resolvedTintColor.CGColor;
        _progressLayer.lineWidth = lineWidth;
        _progressLayer.lineCap = kCALineCapRound;
        _progressLayer.strokeStart = 0.0;
        _progressLayer.strokeEnd = 0.0;
        [self.layer addSublayer:_progressLayer];

        // 完成对勾（默认隐藏）
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
    _resolvedTintColor = resolvedTintColor ?: [UIColor systemBlueColor];
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
        // 隐藏运行中状态但未完成：显示暂停状态
        _progressLayer.opacity = 0.5;
    } else {
        _progressLayer.opacity = visible ? 1.0 : 0.5;
    }
    [CATransaction commit];
}

@end

// ============================================================================
// 文件类型图标工具（根据文件扩展名返回对应的 SF Symbol 图标和颜色）
// ============================================================================

/// 从文件名中提取小写扩展名（不含点）
static NSString *dpvc_fileExtension(NSString *fileName) {
    if (!fileName || fileName.length == 0) return @"";
    NSString *ext = [[fileName pathExtension] lowercaseString];
    return ext ?: @"";
}

/// 根据文件扩展名返回对应的 SF Symbol 图标名称
/// 参照 FCL 的文件列表图标设计，不同类型文件使用不同图标便于快速识别
static UIImage *dpvc_fileTypeIcon(NSString *fileName) {
    NSString *ext = dpvc_fileExtension(fileName);

    // 图标映射表：扩展名 → SF Symbol 名称
    // 所有符号均为 iOS 13+ 可用，确保兼容性
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

    // 兜底：如果指定符号不存在（极端情况），使用通用的 doc 图标
    if (!image) {
        image = [UIImage systemImageNamed:@"doc"];
    }
    return image;
}

/// 根据文件扩展名返回对应的主题颜色
/// 颜色与文件类型对应，便于视觉快速区分
static UIColor *dpvc_fileTypeColor(NSString *fileName) {
    NSString *ext = dpvc_fileExtension(fileName);

    // 颜色映射表：扩展名 → UIColor
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
        @"dat":    [UIColor systemBlueColor],
        @"lock":   [UIColor systemRedColor],
        @"sha1":   [UIColor systemGrayColor],
        @"md5":    [UIColor systemGrayColor],
        @"version": [UIColor systemBrownColor],
        @"pack":   [UIColor systemOrangeColor],
    };

    return colorMap[ext] ?: [UIColor systemGrayColor];
}

// ============================================================================
// 自定义下载文件 Cell（卡片式布局：图标 + 文件名 + 大小/速度 + 圆形进度）
// ============================================================================

@interface DPVCDownloadCell : UITableViewCell

/// 卡片容器视图（承载毛玻璃/边框/圆角样式）
@property (nonatomic, strong) UIView *cardView;
/// 文件类型图标
@property (nonatomic, strong) UIImageView *fileIconView;
/// 文件名标签
@property (nonatomic, strong) UILabel *fileNameLabel;
/// 详情标签（已下载/总大小 • 速度）
@property (nonatomic, strong) UILabel *detailLabel;
/// 圆形进度视图
@property (nonatomic, strong) CircularProgressView *progressView;

/// 配置 Cell 的文件名（设置图标和文件名）
- (void)configureWithFileName:(NSString *)fileName;
/// 用 NSProgress 更新 Cell 的进度、大小、速度显示
- (void)updateWithProgress:(NSProgress *)progress;
/// 应用卡片样式（根据是否有全局背景调整毛玻璃/纯色）
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

/// 创建并添加所有子视图
- (void)setupViews {
    // 卡片容器：16pt 圆角 + 0.5pt 边框 + 半透明背景
    self.cardView = [[UIView alloc] init];
    self.cardView.translatesAutoresizingMaskIntoConstraints = NO;
    self.cardView.layer.cornerRadius = kCardCornerRadius;
    self.cardView.layer.masksToBounds = YES;
    self.cardView.layer.borderWidth = kCardBorderWidth;
    self.cardView.layer.borderColor = [UIColor separatorColor].CGColor;
    self.cardView.backgroundColor = [[UIColor whiteColor] colorWithAlphaComponent:0.08];
    [self.contentView addSubview:self.cardView];

    // 文件类型图标
    self.fileIconView = [[UIImageView alloc] init];
    self.fileIconView.translatesAutoresizingMaskIntoConstraints = NO;
    self.fileIconView.contentMode = UIViewContentModeScaleAspectFit;
    self.fileIconView.tintColor = [UIColor systemGrayColor];
    self.fileIconView.preferredSymbolConfiguration =
        [UIImageSymbolConfiguration configurationWithPointSize:16 weight:UIFontWeightMedium];
    [self.cardView addSubview:self.fileIconView];

    // 文件名标签
    self.fileNameLabel = [[UILabel alloc] init];
    self.fileNameLabel.translatesAutoresizingMaskIntoConstraints = NO;
    self.fileNameLabel.font = [UIFont systemFontOfSize:14 weight:UIFontWeightMedium];
    self.fileNameLabel.textColor = [UIColor labelColor];
    self.fileNameLabel.numberOfLines = 1;
    self.fileNameLabel.lineBreakMode = NSLineBreakByTruncatingMiddle;
    [self.cardView addSubview:self.fileNameLabel];

    // 详情标签（已下载/总大小 • 速度）
    self.detailLabel = [[UILabel alloc] init];
    self.detailLabel.translatesAutoresizingMaskIntoConstraints = NO;
    self.detailLabel.font = [UIFont systemFontOfSize:11];
    self.detailLabel.textColor = [UIColor secondaryLabelColor];
    self.detailLabel.numberOfLines = 1;
    self.detailLabel.lineBreakMode = NSLineBreakByTruncatingTail;
    [self.cardView addSubview:self.detailLabel];

    // 圆形进度视图
    self.progressView = [[CircularProgressView alloc] initWithFrame:CGRectMake(0, 0, kCircularProgressSize, kCircularProgressSize)];
    self.progressView.translatesAutoresizingMaskIntoConstraints = NO;
    self.progressView.resolvedTintColor = [UIColor systemBlueColor];
    [self.cardView addSubview:self.progressView];
}

/// 设置 Auto Layout 约束
- (void)setupConstraints {
    [NSLayoutConstraint activateConstraints:@[
        // 卡片容器：左右各 16pt，上下各 4pt
        [self.cardView.topAnchor constraintEqualToAnchor:self.contentView.topAnchor constant:4],
        [self.cardView.leadingAnchor constraintEqualToAnchor:self.contentView.leadingAnchor constant:16],
        [self.cardView.trailingAnchor constraintEqualToAnchor:self.contentView.trailingAnchor constant:-16],
        [self.cardView.bottomAnchor constraintEqualToAnchor:self.contentView.bottomAnchor constant:-4],

        // 文件类型图标：左侧固定尺寸
        [self.fileIconView.leadingAnchor constraintEqualToAnchor:self.cardView.leadingAnchor constant:12],
        [self.fileIconView.centerYAnchor constraintEqualToAnchor:self.cardView.centerYAnchor],
        [self.fileIconView.widthAnchor constraintEqualToConstant:kFileIconSize],
        [self.fileIconView.heightAnchor constraintEqualToConstant:kFileIconSize],

        // 圆形进度视图：右侧固定尺寸
        [self.progressView.trailingAnchor constraintEqualToAnchor:self.cardView.trailingAnchor constant:-12],
        [self.progressView.centerYAnchor constraintEqualToAnchor:self.cardView.centerYAnchor],
        [self.progressView.widthAnchor constraintEqualToConstant:kCircularProgressSize],
        [self.progressView.heightAnchor constraintEqualToConstant:kCircularProgressSize],

        // 文件名标签：图标右侧 → 进度视图左侧
        [self.fileNameLabel.leadingAnchor constraintEqualToAnchor:self.fileIconView.trailingAnchor constant:10],
        [self.fileNameLabel.trailingAnchor constraintEqualToAnchor:self.progressView.leadingAnchor constant:-10],
        [self.fileNameLabel.topAnchor constraintEqualToAnchor:self.cardView.topAnchor constant:14],

        // 详情标签：文件名下方
        [self.detailLabel.leadingAnchor constraintEqualToAnchor:self.fileIconView.trailingAnchor constant:10],
        [self.detailLabel.trailingAnchor constraintEqualToAnchor:self.progressView.leadingAnchor constant:-10],
        [self.detailLabel.topAnchor constraintEqualToAnchor:self.fileNameLabel.bottomAnchor constant:3],
    ]];
}

/// 应用卡片样式（根据是否有全局背景调整）
- (void)applyCardStyle {
    BOOL hasBg = [[BackgroundManager sharedManager] hasBackground];

    if (hasBg) {
        // 有全局背景：半透明白色 + 毛玻璃效果
        self.cardView.backgroundColor = [[UIColor whiteColor] colorWithAlphaComponent:0.08];
        [[BackgroundManager sharedManager] applyEffectToView:self.cardView];
    } else {
        // 无全局背景：使用系统纯色保证可读性
        self.cardView.backgroundColor = [UIColor secondarySystemGroupedBackgroundColor];
    }

    // 文字颜色随背景调整
    UIColor *titleColor = hasBg ? [UIColor whiteColor] : [UIColor labelColor];
    UIColor *detailColor = hasBg ?
        [UIColor colorWithWhite:1.0 alpha:0.7] : [UIColor secondaryLabelColor];

    self.fileNameLabel.textColor = titleColor;
    self.detailLabel.textColor = detailColor;
}

/// 配置 Cell 的文件名和图标
- (void)configureWithFileName:(NSString *)fileName {
    self.fileNameLabel.text = fileName.lastPathComponent ?: fileName;
    self.fileIconView.image = dpvc_fileTypeIcon(fileName);
    self.fileIconView.tintColor = dpvc_fileTypeColor(fileName);
}

/// 用 NSProgress 更新进度、大小、速度显示
- (void)updateWithProgress:(NSProgress *)progress {
    // 更新圆形进度
    self.progressView.fractionCompleted = progress.fractionCompleted;

    // 完成态切换
    if (progress.finished) {
        [self.progressView transitionCompletedLayerToVisible:YES animated:YES haptic:NO];
    }

    // 构建详情文本：已下载/总大小 • 速度
    NSMutableString *detail = [NSMutableString string];

    // 已下载/总大小
    if (progress.totalUnitCount > 0) {
        int64_t completed = progress.completedUnitCount;
        int64_t total = progress.totalUnitCount;
        NSString *completedStr = [NSByteCountFormatter stringFromByteCount:completed
                                                               countStyle:NSByteCountFormatterCountStyleFile];
        NSString *totalStr = [NSByteCountFormatter stringFromByteCount:total
                                                           countStyle:NSByteCountFormatterCountStyleFile];
        [detail appendFormat:@"%@ / %@", completedStr, totalStr];
    } else if (progress.completedUnitCount > 0) {
        // 总大小未知，只显示已下载
        NSString *completedStr = [NSByteCountFormatter stringFromByteCount:progress.completedUnitCount
                                                               countStyle:NSByteCountFormatterCountStyleFile];
        [detail appendFormat:@"%@ / ?", completedStr];
    }

    // 速度
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
// 主控制器实现
// ============================================================================

@interface DownloadProgressViewController ()
// 文件列表计数（用于检测文件列表变化并刷新表格）
@property NSInteger fileListCount;
// 摘要卡片子视图
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
    // 速度采样相关：用于计算实时速度并更新迷你图表
    CGFloat _lastSpeedSampleTime;
    int64_t _lastCompletedBytes;
    CGFloat _maxObservedSpeed; // 用于归一化速度采样
}

- (instancetype)initWithTask:(MinecraftResourceDownloadTask *)task {
    self = [super init];
    self.task = task;
    return self;
}

- (void)loadView {
    [super loadView];
    // 适配自定义启动器背景
    [[BackgroundManager sharedManager] makeViewControllerTransparent:self];
    self.tableView.backgroundColor = [UIColor clearColor];

    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemClose target:self action:@selector(actionClose)];
    self.tableView.allowsSelection = NO;

    // 初始化字节格式化器（复用，避免频繁创建）
    _byteFormatter = [[NSByteCountFormatter alloc] init];
    _byteFormatter.allowedUnits = NSByteCountFormatterUseAll;
    _byteFormatter.countStyle = NSByteCountFormatterCountStyleFile;
    _byteFormatter.includesUnit = YES;

    // 初始化速度采样状态
    _lastSpeedSampleTime = 0;
    _lastCompletedBytes = 0;
    _maxObservedSpeed = 1.0; // 避免除零，初始给一个最小值

    // 创建表头摘要卡片（参照 FCL 下载页顶部的总进度摘要）
    [self setupSummaryHeader];
}

// ============================================================================
// 表头摘要卡片构建
// ============================================================================

/// 创建表头摘要视图：文件图标 + 百分比 + 进度条 + 速度图表 + 大小/速度/ETA
/// 布局结构：
/// ┌─────────────────────────────────────┐
/// │ [icon] 正在下载...           [45%] │
/// │ Minecraft 1.20.4                    │
/// │ ████████████░░░░░░░░░░░░░░          │
/// │ ▁▂▃▅▇▅▃▂▃▅▇█▇▅▃▂ (速度图表)        │
/// │ 1.2 GB / 2.5 GB   3.4 MB/s   约2分 │
/// └─────────────────────────────────────┘
- (void)setupSummaryHeader {
    self.summaryHeaderView = [[UIView alloc] initWithFrame:CGRectMake(0, 0, CGRectGetWidth(self.view.bounds), kSummaryHeaderHeight)];
    self.summaryHeaderView.backgroundColor = [UIColor clearColor];

    // 卡片容器：16pt 圆角 + 0.5pt 边框 + 半透明背景 + 毛玻璃
    self.summaryCardView = [[UIView alloc] init];
    self.summaryCardView.translatesAutoresizingMaskIntoConstraints = NO;
    self.summaryCardView.layer.cornerRadius = kCardCornerRadius;
    self.summaryCardView.layer.masksToBounds = YES;
    self.summaryCardView.layer.borderWidth = kCardBorderWidth;
    self.summaryCardView.layer.borderColor = [UIColor separatorColor].CGColor;
    self.summaryCardView.backgroundColor = [[UIColor whiteColor] colorWithAlphaComponent:0.08];
    [[BackgroundManager sharedManager] applyEffectToView:self.summaryCardView];
    [self.summaryHeaderView addSubview:self.summaryCardView];

    // 文件/下载图标（左上角，下载中带呼吸动画）
    self.summaryIconView = [[UIImageView alloc] init];
    self.summaryIconView.translatesAutoresizingMaskIntoConstraints = NO;
    self.summaryIconView.contentMode = UIViewContentModeScaleAspectFit;
    self.summaryIconView.tintColor = self.view.tintColor ?: [UIColor systemBlueColor];
    self.summaryIconView.image = [UIImage systemImageNamed:@"arrow.down.circle.fill"];
    self.summaryIconView.preferredSymbolConfiguration =
        [UIImageSymbolConfiguration configurationWithPointSize:24 weight:UIFontWeightMedium];
    [self.summaryCardView addSubview:self.summaryIconView];

    // 百分比标签（右上角，大字体醒目显示）
    self.summaryPercentLabel = [[UILabel alloc] init];
    self.summaryPercentLabel.translatesAutoresizingMaskIntoConstraints = NO;
    self.summaryPercentLabel.font = [UIFont systemFontOfSize:22 weight:UIFontWeightBold];
    self.summaryPercentLabel.textColor = [UIColor labelColor];
    self.summaryPercentLabel.textAlignment = NSTextAlignmentRight;
    self.summaryPercentLabel.text = @"0%";
    [self.summaryCardView addSubview:self.summaryPercentLabel];

    // 标题标签（图标下方，显示状态文本）
    self.summaryTitleLabel = [[UILabel alloc] init];
    self.summaryTitleLabel.translatesAutoresizingMaskIntoConstraints = NO;
    self.summaryTitleLabel.font = [UIFont systemFontOfSize:14 weight:UIFontWeightMedium];
    self.summaryTitleLabel.textColor = [UIColor secondaryLabelColor];
    self.summaryTitleLabel.text = localize(@"download.progress.downloading", @"正在下载...");
    [self.summaryCardView addSubview:self.summaryTitleLabel];

    // 自定义线性进度条（主题色，胶囊形，平滑动画）
    self.summaryProgressBar = [[DPVCProgressBar alloc] init];
    self.summaryProgressBar.translatesAutoresizingMaskIntoConstraints = NO;
    self.summaryProgressBar.fillColor = self.view.tintColor ?: [UIColor systemBlueColor];
    self.summaryProgressBar.trackColor = [[UIColor whiteColor] colorWithAlphaComponent:0.12];
    [self.summaryCardView addSubview:self.summaryProgressBar];

    // 速度迷你图表（实时速度可视化）
    self.speedSparkline = [[DPVCSpeedSparkline alloc] init];
    self.speedSparkline.translatesAutoresizingMaskIntoConstraints = NO;
    self.speedSparkline.barColor = self.view.tintColor ?: [UIColor systemBlueColor];
    [self.summaryCardView addSubview:self.speedSparkline];

    // 底部信息行：大小（左）+ 速度（中）+ ETA（右）
    self.summarySizeLabel = [[UILabel alloc] init];
    self.summarySizeLabel.translatesAutoresizingMaskIntoConstraints = NO;
    self.summarySizeLabel.font = [UIFont systemFontOfSize:12];
    self.summarySizeLabel.textColor = [UIColor secondaryLabelColor];
    self.summarySizeLabel.text = @"";
    [self.summaryCardView addSubview:self.summarySizeLabel];

    self.summarySpeedLabel = [[UILabel alloc] init];
    self.summarySpeedLabel.translatesAutoresizingMaskIntoConstraints = NO;
    self.summarySpeedLabel.font = [UIFont systemFontOfSize:12 weight:UIFontWeightMedium];
    self.summarySpeedLabel.textColor = self.view.tintColor ?: [UIColor systemBlueColor];
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

    // 激活所有约束
    [NSLayoutConstraint activateConstraints:@[
        // 卡片容器：左右各 16pt，上下各 8pt
        [self.summaryCardView.topAnchor constraintEqualToAnchor:self.summaryHeaderView.topAnchor constant:8],
        [self.summaryCardView.leadingAnchor constraintEqualToAnchor:self.summaryHeaderView.leadingAnchor constant:16],
        [self.summaryCardView.trailingAnchor constraintEqualToAnchor:self.summaryHeaderView.trailingAnchor constant:-16],
        [self.summaryCardView.bottomAnchor constraintEqualToAnchor:self.summaryHeaderView.bottomAnchor constant:-8],

        // 图标：左上角
        [self.summaryIconView.topAnchor constraintEqualToAnchor:self.summaryCardView.topAnchor constant:16],
        [self.summaryIconView.leadingAnchor constraintEqualToAnchor:self.summaryCardView.leadingAnchor constant:16],
        [self.summaryIconView.widthAnchor constraintEqualToConstant:kSummaryIconSize],
        [self.summaryIconView.heightAnchor constraintEqualToConstant:kSummaryIconSize],

        // 百分比标签：右上角，与图标垂直居中对齐
        [self.summaryPercentLabel.topAnchor constraintEqualToAnchor:self.summaryCardView.topAnchor constant:14],
        [self.summaryPercentLabel.trailingAnchor constraintEqualToAnchor:self.summaryCardView.trailingAnchor constant:-16],
        [self.summaryPercentLabel.leadingAnchor constraintEqualToAnchor:self.summaryIconView.trailingAnchor constant:8],

        // 标题标签：图标下方
        [self.summaryTitleLabel.topAnchor constraintEqualToAnchor:self.summaryIconView.bottomAnchor constant:8],
        [self.summaryTitleLabel.leadingAnchor constraintEqualToAnchor:self.summaryCardView.leadingAnchor constant:16],
        [self.summaryTitleLabel.trailingAnchor constraintEqualToAnchor:self.summaryCardView.trailingAnchor constant:-16],

        // 进度条：标题下方
        [self.summaryProgressBar.topAnchor constraintEqualToAnchor:self.summaryTitleLabel.bottomAnchor constant:10],
        [self.summaryProgressBar.leadingAnchor constraintEqualToAnchor:self.summaryCardView.leadingAnchor constant:16],
        [self.summaryProgressBar.trailingAnchor constraintEqualToAnchor:self.summaryCardView.trailingAnchor constant:-16],
        [self.summaryProgressBar.heightAnchor constraintEqualToConstant:kProgressBarHeight],

        // 速度迷你图表：进度条下方
        [self.speedSparkline.topAnchor constraintEqualToAnchor:self.summaryProgressBar.bottomAnchor constant:10],
        [self.speedSparkline.leadingAnchor constraintEqualToAnchor:self.summaryCardView.leadingAnchor constant:16],
        [self.speedSparkline.trailingAnchor constraintEqualToAnchor:self.summaryCardView.trailingAnchor constant:-16],
        [self.speedSparkline.heightAnchor constraintEqualToConstant:kSpeedSparklineHeight],

        // 底部信息行：大小（左）+ 速度（中）+ ETA（右）
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

    // 启动下载图标的呼吸动画（表示下载进行中）
    [self startIconPulseAnimation];
}

/// 给摘要图标添加呼吸动画（缩放脉动，表示下载进行中）
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
// KVO 观察
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
        // 单文件进度更新：更新对应 Cell 的显示
        DPVCDownloadCell *cell = objc_getAssociatedObject(progress, @"cell");
        if (!cell) return;
        dispatch_async(dispatch_get_main_queue(), ^{
            [cell updateWithProgress:progress];
        });
    } else if (context == TotalProgressObserverContext) {
        // 总进度更新：更新摘要卡片
        dispatch_async(dispatch_get_main_queue(), ^{
            self.title = progress.localizedDescription;

            double fraction = progress.fractionCompleted;

            // 更新百分比
            NSInteger percent = (NSInteger)(fraction * 100.0 + 0.5);
            percent = MAX(0, MIN(100, percent));
            self.summaryPercentLabel.text = [NSString stringWithFormat:@"%ld%%", (long)percent];

            // 更新标题
            if (progress.finished) {
                self.summaryTitleLabel.text = localize(@"download.progress.completed", @"下载完成");
                self.summaryIconView.image = [UIImage systemImageNamed:@"checkmark.circle.fill"];
                self.summaryIconView.tintColor = [UIColor systemGreenColor];
                [self.summaryIconView.layer removeAllAnimations]; // 停止呼吸动画
                self.summaryProgressBar.fillColor = [UIColor systemGreenColor];
            } else {
                self.summaryTitleLabel.text = localize(@"download.progress.downloading", @"正在下载...");
            }

            // 更新进度条
            [self.summaryProgressBar setProgress:(CGFloat)fraction animated:YES];

            // 更新大小标签：已下载 / 总大小
            NSMutableString *sizeText = [NSMutableString string];
            if (progress.totalUnitCount > 0) {
                int64_t completed = progress.completedUnitCount;
                int64_t total = progress.totalUnitCount;
                NSString *completedStr = [self.byteFormatter stringFromByteCount:completed];
                NSString *totalStr = [self.byteFormatter stringFromByteCount:total];
                [sizeText appendFormat:@"%@ / %@", completedStr, totalStr];
            }
            self.summarySizeLabel.text = sizeText.length > 0 ? sizeText : @"";

            // 更新速度标签 + 速度迷你图表
            double currentSpeed = 0.0;
            if (progress.throughput) {
                currentSpeed = [progress.throughput doubleValue];
            }

            // 计算瞬时速度（基于 completedUnitCount 的时间差，作为 throughput 的补充/回退）
            struct timeval tv;
            gettimeofday(&tv, NULL);
            CGFloat nowMs = (CGFloat)(tv.tv_sec * 1000.0 + tv.tv_usec / 1000.0);
            if (_lastSpeedSampleTime > 0 && nowMs > _lastSpeedSampleTime) {
                double elapsedSec = (nowMs - _lastSpeedSampleTime) / 1000.0;
                int64_t deltaBytes = progress.completedUnitCount - _lastCompletedBytes;
                if (deltaBytes > 0 && elapsedSec > 0) {
                    double instantSpeed = deltaBytes / elapsedSec;
                    // 取 throughput 和瞬时速度的较大值（throughput 有时更新滞后）
                    currentSpeed = MAX(currentSpeed, instantSpeed);
                }
            }
            _lastSpeedSampleTime = nowMs;
            _lastCompletedBytes = progress.completedUnitCount;

            // 格式化并显示速度
            self.summarySpeedLabel.text = [self formatSpeed:currentSpeed];

            // 更新速度迷你图表
            if (currentSpeed > _maxObservedSpeed) {
                _maxObservedSpeed = currentSpeed;
            }
            CGFloat normalizedSpeed = (currentSpeed > 0 && _maxObservedSpeed > 0)
                ? (currentSpeed / _maxObservedSpeed)
                : 0.0;
            [self.speedSparkline addSpeedSample:normalizedSpeed];

            // 更新 ETA 标签（友好格式："约 2 分钟" 而非 "120s"）
            NSInteger etaSeconds = 0;
            if (progress.estimatedTimeRemaining) {
                etaSeconds = [progress.estimatedTimeRemaining integerValue];
            } else if (currentSpeed > 0 && progress.totalUnitCount > 0) {
                // throughput 的 ETA 不可用时，手动计算
                int64_t remaining = progress.totalUnitCount - progress.completedUnitCount;
                if (remaining > 0) {
                    etaSeconds = (NSInteger)(remaining / currentSpeed);
                }
            }
            self.summaryETALabel.text = [self formatETA:etaSeconds];

            // 文件列表变化时刷新表格
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
// 格式化工具
// ============================================================================

/// 格式化下载速度（bytes/s → B/s / KB/s / MB/s）
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

/// 格式化剩余时间（ETA），使用友好的中文表达
/// 规则：
///   0 秒或负值 → "即将完成"
///   < 60 秒   → "约 X 秒"
///   < 3600 秒  → "约 X 分钟"（四舍五入到分钟）
///   >= 3600 秒 → "约 X 小时 Y 分"
- (NSString *)formatETA:(NSInteger)etaSeconds {
    if (etaSeconds <= 0) {
        return localize(@"download.progress.eta.soon", @"即将完成");
    }

    if (etaSeconds < 60) {
        return [NSString stringWithFormat:localize(@"download.progress.eta.about_seconds", @"约 %ld 秒"), (long)etaSeconds];
    }

    if (etaSeconds < 3600) {
        // 四舍五入到分钟（< 60 秒部分 > 30 秒则进位）
        NSInteger minutes = (etaSeconds + 30) / 60;
        return [NSString stringWithFormat:localize(@"download.progress.eta.about_minutes", @"约 %ld 分钟"), (long)minutes];
    }

    // >= 1 小时
    NSInteger hours = etaSeconds / 3600;
    NSInteger minutes = (etaSeconds % 3600) / 60;
    if (minutes > 0) {
        return [NSString stringWithFormat:localize(@"download.progress.eta.about_hours_minutes", @"约 %ld 小时 %ld 分"), (long)hours, (long)minutes];
    }
    return [NSString stringWithFormat:localize(@"download.progress.eta.about_hours", @"约 %ld 小时"), (long)hours];
}

// ============================================================================
// UITableView 数据源与代理
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
        cell.progressView.resolvedTintColor = self.view.tintColor ?: [UIColor systemBlueColor];
    }

    // 清除上一个 Cell 关联的进度观察
    NSProgress *lastProgress = objc_getAssociatedObject(cell, @"progress");
    if (lastProgress) {
        objc_setAssociatedObject(lastProgress, @"cell", nil, OBJC_ASSOCIATION_ASSIGN);
        @try {
            [lastProgress removeObserver:self forKeyPath:@"fractionCompleted"];
        } @catch(id anException) {}
    }

    // 配置当前 Cell 的文件名和图标
    NSString *fileName = self.task.fileList[indexPath.row];
    [cell configureWithFileName:fileName];

    // 关联当前文件进度并添加 KVO 观察
    NSProgress *progress = self.task.progressList[indexPath.row];
    objc_setAssociatedObject(cell, @"progress", progress, OBJC_ASSOCIATION_ASSIGN);
    objc_setAssociatedObject(progress, @"cell", cell, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    [progress addObserver:self
        forKeyPath:@"fractionCompleted"
        options:NSKeyValueObservingOptionInitial
        context:CellProgressObserverContext];

    // 重置圆形进度视图状态
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
