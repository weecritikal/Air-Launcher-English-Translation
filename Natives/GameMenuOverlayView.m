//
//  GameMenuOverlayView.m
//  Amethyst
//
//  参照 FCL MenuView.java 与 ZL2 GameScreen.kt 实现
//

#import "GameMenuOverlayView.h"
#import "LauncherPreferences.h"

// 位置持久化的 pref key
static NSString *const kPrefMenuButtonX = @"game.menu_button_x";
static NSString *const kPrefMenuButtonY = @"game.menu_button_y";
static NSString *const kPrefStatsLabelX = @"game.stats_label_x";
static NSString *const kPrefStatsLabelY = @"game.stats_label_y";

// 按钮尺寸
static const CGFloat kMenuButtonSize = 44.0;
// 拖拽阈值：超过此距离算拖动，否则算点击（参照 FCL MenuView 的 10px 阈值）
static const CGFloat kDragThreshold = 10.0;

@interface GameMenuOverlayView ()

// 设置按钮（圆形）
@property (nonatomic, strong) UIButton *menuButton;
// FPS/内存显示标签
@property (nonatomic, strong) UILabel *statsLabel;
// 拖拽相关状态
@property (nonatomic, assign) BOOL isDragging;
@property (nonatomic, assign) CGPoint dragStartPoint;
@property (nonatomic, assign) CGPoint dragStartCenter;
@property (nonatomic, strong) NSTimer *dragIdleTimer;

@end

@implementation GameMenuOverlayView

- (instancetype)initWithParentView:(UIView *)parentView {
    self = [super initWithFrame:parentView.bounds];
    if (self) {
        self.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        self.backgroundColor = [UIColor clearColor];
        self.userInteractionEnabled = YES;

        [self setupMenuButton];
        [self setupStatsLabel];
        [parentView addSubview:self];

        [self restorePositions];
    }
    return self;
}

- (void)setupMenuButton {
    self.menuButton = [UIButton buttonWithType:UIButtonTypeSystem];
    self.menuButton.frame = CGRectMake(0, 0, kMenuButtonSize, kMenuButtonSize);
    self.menuButton.layer.cornerRadius = kMenuButtonSize / 2;
    // 半透明深色背景，确保在游戏画面上可见
    self.menuButton.backgroundColor = [UIColor colorWithRed:0.1 green:0.1 blue:0.1 alpha:0.6];
    self.menuButton.layer.borderWidth = 1.5;
    self.menuButton.layer.borderColor = [UIColor colorWithWhite:1.0 alpha:0.4].CGColor;
    // 参照 FCL：使用设置图标（gearshape）
    UIImage *icon = [UIImage systemImageNamed:@"gearshape.fill"]
                    ?: [UIImage systemImageNamed:@"gear"];
    [self.menuButton setImage:icon forState:UIControlStateNormal];
    self.menuButton.tintColor = [UIColor whiteColor];
    self.menuButton.translatesAutoresizingMaskIntoConstraints = NO;

    // 添加拖拽手势
    UIPanGestureRecognizer *pan = [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(handleMenuButtonPan:)];
    pan.minimumNumberOfTouches = 1;
    [self.menuButton addGestureRecognizer:pan];

    // 点击事件
    [self.menuButton addTarget:self action:@selector(menuButtonTouchedDown:) forControlEvents:UIControlEventTouchDown];
    [self.menuButton addTarget:self action:@selector(menuButtonTouchedUp:) forControlEvents:UIControlEventTouchUpInside];

    [self addSubview:self.menuButton];
}

- (void)setupStatsLabel {
    self.statsLabel = [[UILabel alloc] init];
    self.statsLabel.text = @"FPS: -- | MEM: --";
    self.statsLabel.font = [UIFont monospacedDigitSystemFontOfSize:12 weight:UIFontWeightBold];
    self.statsLabel.textColor = [UIColor whiteColor];
    self.statsLabel.backgroundColor = [UIColor colorWithRed:0 green:0 blue:0 alpha:0.5];
    self.statsLabel.layer.cornerRadius = 4;
    self.statsLabel.layer.masksToBounds = YES;
    self.statsLabel.textAlignment = NSTextAlignmentCenter;
    self.statsLabel.numberOfLines = 1;
    self.statsLabel.translatesAutoresizingMaskIntoConstraints = NO;
    // 内边距
    self.statsLabel.frame = CGRectMake(0, 0, 130, 24);

    // 拖拽手势
    UIPanGestureRecognizer *pan = [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(handleStatsLabelPan:)];
    [self.statsLabel addGestureRecognizer:pan];
    self.statsLabel.userInteractionEnabled = YES;

    [self addSubview:self.statsLabel];
}

#pragma mark - 位置持久化

- (void)restorePositions {
    CGFloat bw = self.bounds.size.width;
    CGFloat bh = self.bounds.size.height;

    // 设置按钮默认位置：右上角偏下（避开状态栏和右上角控件）
    CGFloat defaultBtnX = bw - kMenuButtonSize - 20;
    CGFloat defaultBtnY = bh * 0.3;

    NSNumber *savedX = getPrefObject(kPrefMenuButtonX);
    NSNumber *savedY = getPrefObject(kPrefMenuButtonY);
    if (savedX && savedY) {
        CGFloat x = [savedX floatValue] * bw;
        CGFloat y = [savedY floatValue] * bh;
        self.menuButton.center = CGPointMake(x, y);
    } else {
        self.menuButton.center = CGPointMake(defaultBtnX, defaultBtnY);
    }

    // 统计标签默认位置：左上角
    CGFloat defaultLabelX = 70;
    CGFloat defaultLabelY = bh * 0.05 + 30;

    NSNumber *savedLX = getPrefObject(kPrefStatsLabelX);
    NSNumber *savedLY = getPrefObject(kPrefStatsLabelY);
    if (savedLX && savedLY) {
        CGFloat x = [savedLX floatValue] * bw;
        CGFloat y = [savedLY floatValue] * bh;
        self.statsLabel.center = CGPointMake(x, y);
    } else {
        self.statsLabel.center = CGPointMake(defaultLabelX, defaultLabelY);
    }

    [self clampViewsToScreen];
}

- (void)savePositions {
    CGFloat bw = self.bounds.size.width;
    CGFloat bh = self.bounds.size.height;
    if (bw <= 0 || bh <= 0) return;

    // 保存为屏幕宽高的百分比（参照 FCL menuPositionX/Y），旋转后仍正确
    CGFloat btnXPercent = self.menuButton.center.x / bw;
    CGFloat btnYPercent = self.menuButton.center.y / bh;
    setPrefObject(kPrefMenuButtonX, @(btnXPercent));
    setPrefObject(kPrefMenuButtonY, @(btnYPercent));

    CGFloat labelXPercent = self.statsLabel.center.x / bw;
    CGFloat labelYPercent = self.statsLabel.center.y / bh;
    setPrefObject(kPrefStatsLabelX, @(labelXPercent));
    setPrefObject(kPrefStatsLabelY, @(labelYPercent));
}

- (void)clampViewsToScreen {
    CGFloat bw = self.bounds.size.width;
    CGFloat bh = self.bounds.size.height;
    if (bw <= 0 || bh <= 0) return;

    // 设置按钮限制在屏幕内
    CGFloat btnHalf = kMenuButtonSize / 2;
    CGFloat btnX = MAX(btnHalf, MIN(bw - btnHalf, self.menuButton.center.x));
    CGFloat btnY = MAX(btnHalf, MIN(bh - btnHalf, self.menuButton.center.y));
    self.menuButton.center = CGPointMake(btnX, btnY);

    // 统计标签限制在屏幕内
    CGFloat labelHalfW = self.statsLabel.frame.size.width / 2;
    CGFloat labelHalfH = self.statsLabel.frame.size.height / 2;
    CGFloat labelX = MAX(labelHalfW, MIN(bw - labelHalfW, self.statsLabel.center.x));
    CGFloat labelY = MAX(labelHalfH, MIN(bh - labelHalfH, self.statsLabel.center.y));
    self.statsLabel.center = CGPointMake(labelX, labelY);
}

#pragma mark - 设置按钮手势

- (void)handleMenuButtonPan:(UIPanGestureRecognizer *)sender {
    CGPoint translation = [sender translationInView:self];

    if (sender.state == UIGestureRecognizerStateBegan) {
        self.isDragging = NO;
        self.dragStartPoint = [sender locationInView:self];
        self.dragStartCenter = self.menuButton.center;
        // 拖拽时高亮
        self.menuButton.backgroundColor = [UIColor colorWithRed:0.2 green:0.5 blue:0.9 alpha:0.8];
    } else if (sender.state == UIGestureRecognizerStateChanged) {
        CGFloat dx = [sender locationInView:self].x - self.dragStartPoint.x;
        CGFloat dy = [sender locationInView:self].y - self.dragStartPoint.y;
        CGFloat distance = sqrt(dx * dx + dy * dy);
        if (distance > kDragThreshold) {
            self.isDragging = YES;
        }
        if (self.isDragging) {
            CGPoint newCenter = CGPointMake(self.dragStartCenter.x + translation.x,
                                            self.dragStartCenter.y + translation.y);
            // 限制在屏幕内
            CGFloat half = kMenuButtonSize / 2;
            newCenter.x = MAX(half, MIN(self.bounds.size.width - half, newCenter.x));
            newCenter.y = MAX(half, MIN(self.bounds.size.height - half, newCenter.y));
            self.menuButton.center = newCenter;
        }
    } else if (sender.state == UIGestureRecognizerStateEnded || sender.state == UIGestureRecognizerStateCancelled) {
        // 恢复背景
        self.menuButton.backgroundColor = [UIColor colorWithRed:0.1 green:0.1 blue:0.1 alpha:0.6];
        if (self.isDragging) {
            // 拖拽结束保存位置
            [self savePositions];
        }
        self.isDragging = NO;
    }
}

- (void)menuButtonTouchedDown:(UIButton *)sender {
    // 按下时缩小动画
    [UIView animateWithDuration:0.1 animations:^{
        sender.transform = CGAffineTransformMakeScale(0.9, 0.9);
    }];
}

- (void)menuButtonTouchedUp:(UIButton *)sender {
    [UIView animateWithDuration:0.1 animations:^{
        sender.transform = CGAffineTransformIdentity;
    }];
    // 如果是拖拽则不触发点击
    if (!self.isDragging) {
        if (self.onMenuButtonTapped) {
            self.onMenuButtonTapped();
        }
    }
}

#pragma mark - 统计标签手势

- (void)handleStatsLabelPan:(UIPanGestureRecognizer *)sender {
    CGPoint translation = [sender translationInView:self];

    if (sender.state == UIGestureRecognizerStateBegan) {
        self.isDragging = NO;
        self.dragStartCenter = self.statsLabel.center;
    } else if (sender.state == UIGestureRecognizerStateChanged) {
        self.isDragging = YES;
        CGPoint newCenter = CGPointMake(self.dragStartCenter.x + translation.x,
                                        self.dragStartCenter.y + translation.y);
        CGFloat halfW = self.statsLabel.frame.size.width / 2;
        CGFloat halfH = self.statsLabel.frame.size.height / 2;
        newCenter.x = MAX(halfW, MIN(self.bounds.size.width - halfW, newCenter.x));
        newCenter.y = MAX(halfH, MIN(self.bounds.size.height - halfH, newCenter.y));
        self.statsLabel.center = newCenter;
    } else if (sender.state == UIGestureRecognizerStateEnded || sender.state == UIGestureRecognizerStateCancelled) {
        if (self.isDragging) {
            [self savePositions];
        }
        self.isDragging = NO;
    }
}

#pragma mark - 公共方法

- (void)setOverlayHidden:(BOOL)overlayHidden {
    _overlayHidden = overlayHidden;
    self.menuButton.hidden = overlayHidden;
    self.statsLabel.hidden = overlayHidden;
}

- (void)updateFPS:(NSInteger)fps memoryUsageMB:(double)memoryMB {
    // 在主线程更新（参照 FCL/ZL2 由游戏循环驱动）
    // 使用 dispatch_async 避免阻塞调用方
    dispatch_async(dispatch_get_main_queue(), ^{
        if (fps >= 0) {
            self.statsLabel.text = [NSString stringWithFormat:@"FPS: %ld | MEM: %.0fMB",
                                    (long)fps, memoryMB];
        }
    });
}

- (void)layoutSubviews {
    [super layoutSubviews];
    // 屏幕旋转后重新约束位置
    [self clampViewsToScreen];
}

@end
