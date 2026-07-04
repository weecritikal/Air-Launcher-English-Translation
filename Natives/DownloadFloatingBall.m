#import "DownloadFloatingBall.h"

#import "DownloadTaskManager.h"
#import "DownloadTaskItem.h"
#import "LauncherPreferences.h"
#import "SurfaceViewController.h"
#import "UIKit+hook.h"
#import "utils.h"

static const CGFloat kFloatingBallDefaultSize = 60.0;
static const CGFloat kFloatingBallMinSize     = 40.0;
static const CGFloat kFloatingBallMaxSize     = 100.0;

NSNotificationName const DownloadFloatingBallSettingsDidChangeNotification = @"com.amethyst.DownloadFloatingBall.SettingsDidChange";

@interface DownloadFloatingBall ()

@property(nonatomic, strong) UIButton *floatingButton;
@property(nonatomic, strong) UIImageView *iconImageView;
@property(nonatomic, strong) UIImageView *checkmarkView;
@property(nonatomic, strong) UILabel *badgeLabel;

@property(nonatomic, strong) NSTimer *visibilityTimer;
@property(nonatomic, strong) NSTimer *completedResetTimer;

@property(nonatomic, assign) CGFloat currentSize;
@property(nonatomic, assign) BOOL forceGrayAfterCompletion;

@end

@implementation DownloadFloatingBall

#pragma mark - Lifecycle

+ (instancetype)sharedBall {
    static DownloadFloatingBall *shared = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        shared = [[self alloc] init];
    });
    return shared;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _currentSize = kFloatingBallDefaultSize;
        _forceGrayAfterCompletion = NO;

        NSNotificationCenter *center = [NSNotificationCenter defaultCenter];
        [center addObserver:self
                   selector:@selector(handleAggregateStateChanged:)
                       name:DownloadTaskManagerAggregateStateDidChangeNotification
                     object:nil];
        [center addObserver:self
                   selector:@selector(handleApplicationDidBecomeActive:)
                       name:UIApplicationDidBecomeActiveNotification
                     object:nil];
        [center addObserver:self
                   selector:@selector(handleSettingsChanged:)
                       name:DownloadFloatingBallSettingsDidChangeNotification
                     object:nil];
        [center addObserver:self
                   selector:@selector(handleOrientationChanged:)
                       name:UIDeviceOrientationDidChangeNotification
                     object:nil];
    }
    return self;
}

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
    [self stopVisibilityTimer];
    [self invalidateCompletedResetTimer];
}

#pragma mark - UI Setup

- (void)setupFloatingButtonIfNeeded {
    if (self.floatingButton) return;

    UIButton *button = [UIButton buttonWithType:UIButtonTypeCustom];
    button.backgroundColor = [UIColor systemGrayColor];
    button.layer.cornerRadius = self.currentSize / 2.0;
    button.layer.masksToBounds = YES;
    button.frame = CGRectMake(0, 0, self.currentSize, self.currentSize);

    [button addTarget:self
               action:@selector(handleTap:)
     forControlEvents:UIControlEventTouchUpInside];

    UIPanGestureRecognizer *pan = [[UIPanGestureRecognizer alloc] initWithTarget:self
                                                                          action:@selector(handlePan:)];
    [button addGestureRecognizer:pan];

    UIImageView *icon = [[UIImageView alloc] initWithImage:[UIImage systemImageNamed:@"arrow.down.circle.fill"]];
    icon.tintColor = [UIColor whiteColor];
    icon.contentMode = UIViewContentModeScaleAspectFit;
    icon.frame = CGRectInset(button.bounds, 14.0, 14.0);
    icon.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    [button addSubview:icon];
    self.iconImageView = icon;

    UIImageView *checkmark = [[UIImageView alloc] initWithImage:[UIImage systemImageNamed:@"checkmark"]];
    checkmark.tintColor = [UIColor whiteColor];
    checkmark.contentMode = UIViewContentModeScaleAspectFit;
    checkmark.frame = CGRectInset(button.bounds, 14.0, 14.0);
    checkmark.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    checkmark.hidden = YES;
    [button addSubview:checkmark];
    self.checkmarkView = checkmark;

    UILabel *badge = [[UILabel alloc] init];
    badge.translatesAutoresizingMaskIntoConstraints = NO;
    badge.font = [UIFont boldSystemFontOfSize:12];
    badge.textColor = [UIColor whiteColor];
    badge.backgroundColor = [UIColor systemRedColor];
    badge.textAlignment = NSTextAlignmentCenter;
    badge.layer.cornerRadius = 9.0;
    badge.layer.masksToBounds = YES;
    badge.hidden = YES;
    [button addSubview:badge];
    self.badgeLabel = badge;

    [NSLayoutConstraint activateConstraints:@[
        [badge.topAnchor constraintEqualToAnchor:button.topAnchor constant:2],
        [badge.trailingAnchor constraintEqualToAnchor:button.trailingAnchor constant:-2],
        [badge.widthAnchor constraintGreaterThanOrEqualToConstant:18],
        [badge.heightAnchor constraintEqualToConstant:18]
    ]];

    self.floatingButton = button;
}

- (void)attachToMainWindow {
    UIWindow *window = [UIWindow mainWindow];
    if (!window) return;

    [self setupFloatingButtonIfNeeded];

    BOOL wasAdded = (self.floatingButton.superview != window);
    if (wasAdded) {
        [window addSubview:self.floatingButton];

        // 默认放在右下角
        CGFloat size = self.currentSize;
        CGFloat x = MAX(0, window.bounds.size.width - size - 20.0);
        CGFloat y = MAX(0, window.bounds.size.height - size - 20.0);
        self.floatingButton.frame = CGRectMake(x, y, size, size);
    }

    [window bringSubviewToFront:self.floatingButton];
    [self updateVisibility];
    [self updateAppearance];
}

#pragma mark - Visibility

- (void)show {
    self.floatingButton.hidden = NO;
    [self startVisibilityTimer];
}

- (void)hide {
    self.floatingButton.hidden = YES;
    [self stopVisibilityTimer];
}

- (void)startVisibilityTimer {
    if (self.visibilityTimer.valid) return;
    __weak typeof(self) weakSelf = self;
    self.visibilityTimer = [NSTimer scheduledTimerWithTimeInterval:0.5
                                                           repeats:YES
                                                             block:^(NSTimer * _Nonnull timer) {
        [weakSelf visibilityTimerFired:timer];
    }];
}

- (void)stopVisibilityTimer {
    [self.visibilityTimer invalidate];
    self.visibilityTimer = nil;
}

- (void)visibilityTimerFired:(NSTimer *)timer {
    [self updateVisibility];
    [self updateAppearance];
}

- (void)updateVisibility {
    if (!self.floatingButton) return;

    BOOL enabled = getPrefBool(@"general.floating_ball_enabled");
    BOOL inGame  = [SurfaceViewController isRunning];

    if (!enabled || inGame) {
        [self hide];
    } else {
        if (self.floatingButton.hidden) {
            [self show];
        }
    }
}

#pragma mark - Appearance

- (void)updateAppearance {
    if (!self.floatingButton) return;

    // 尺寸
    NSNumber *sizeValue = getPrefObject(@"general.floating_ball_size");
    CGFloat size = sizeValue ? [sizeValue floatValue] : kFloatingBallDefaultSize;
    size = MAX(kFloatingBallMinSize, MIN(kFloatingBallMaxSize, size));
    if (size != self.currentSize) {
        self.currentSize = size;
        CGPoint center = self.floatingButton.center;
        self.floatingButton.bounds = CGRectMake(0, 0, size, size);
        self.floatingButton.center = center;
        self.floatingButton.layer.cornerRadius = size / 2.0;
    }
    [self clampToScreen];

    // 颜色/图标状态
    DownloadTaskAggregateState state = [[DownloadTaskManager sharedManager] currentAggregateState];

    if (state != DownloadTaskAggregateStateCompleted) {
        [self invalidateCompletedResetTimer];
        self.forceGrayAfterCompletion = NO;
    }

    UIColor *targetColor = [UIColor systemGrayColor];
    BOOL showCheckmark = NO;

    switch (state) {
        case DownloadTaskAggregateStateActive:
            targetColor = [UIColor systemYellowColor];
            break;
        case DownloadTaskAggregateStateCompleted:
            if (!self.forceGrayAfterCompletion) {
                targetColor = [UIColor systemGreenColor];
                showCheckmark = YES;
                [self startCompletedResetTimer];
            }
            break;
        default:
            // None / Idle / Paused / Failed 均保持灰色
            break;
    }

    self.floatingButton.backgroundColor = targetColor;
    self.checkmarkView.hidden = !showCheckmark;
    self.iconImageView.hidden = showCheckmark;

    // 角标：显示正在下载 + 等待中的任务数量
    DownloadTaskManager *manager = [DownloadTaskManager sharedManager];
    NSInteger activeCount = [manager countOfTasksWithState:DownloadTaskStateDownloading] +
                            [manager countOfTasksWithState:DownloadTaskStatePending];
    if (activeCount > 0) {
        self.badgeLabel.text = [NSString stringWithFormat:@"%ld", (long)activeCount];
        self.badgeLabel.hidden = NO;
    } else {
        self.badgeLabel.hidden = YES;
    }
}

- (void)startCompletedResetTimer {
    if (self.completedResetTimer.valid) return;
    __weak typeof(self) weakSelf = self;
    self.completedResetTimer = [NSTimer scheduledTimerWithTimeInterval:10.0
                                                               repeats:NO
                                                                 block:^(NSTimer * _Nonnull timer) {
        [weakSelf completedResetFired:timer];
    }];
}

- (void)invalidateCompletedResetTimer {
    [self.completedResetTimer invalidate];
    self.completedResetTimer = nil;
}

- (void)completedResetFired:(NSTimer *)timer {
    self.completedResetTimer = nil;
    self.forceGrayAfterCompletion = YES;
    [self updateAppearance];
}

#pragma mark - Positioning

- (CGRect)allowedBounds {
    UIWindow *window = [UIWindow mainWindow];
    if (!window) return CGRectZero;

    CGRect bounds = window.bounds;
    UIEdgeInsets safeArea = window.safeAreaInsets;

    CGFloat insetLeft   = MAX(safeArea.left,   4.0);
    CGFloat insetRight  = MAX(safeArea.right,  4.0);
    CGFloat insetTop    = MAX(safeArea.top,    4.0);
    CGFloat insetBottom = MAX(safeArea.bottom, 4.0);

    return CGRectMake(insetLeft,
                      insetTop,
                      MAX(0, bounds.size.width  - insetLeft - insetRight),
                      MAX(0, bounds.size.height - insetTop  - insetBottom));
}

- (void)clampToScreen {
    CGRect allowed = [self allowedBounds];
    if (CGRectIsEmpty(allowed)) return;

    CGFloat half = self.currentSize / 2.0;
    CGFloat minX = CGRectGetMinX(allowed) + half;
    CGFloat maxX = CGRectGetMaxX(allowed) - half;
    CGFloat minY = CGRectGetMinY(allowed) + half;
    CGFloat maxY = CGRectGetMaxY(allowed) - half;

    if (maxX < minX) maxX = minX;
    if (maxY < minY) maxY = minY;

    CGPoint center = self.floatingButton.center;
    center.x = MAX(minX, MIN(center.x, maxX));
    center.y = MAX(minY, MIN(center.y, maxY));
    self.floatingButton.center = center;
}

- (void)snapToNearestEdge {
    CGRect allowed = [self allowedBounds];
    if (CGRectIsEmpty(allowed)) return;

    CGFloat half = self.currentSize / 2.0;
    CGFloat minX = CGRectGetMinX(allowed) + half;
    CGFloat maxX = CGRectGetMaxX(allowed) - half;
    CGFloat minY = CGRectGetMinY(allowed) + half;
    CGFloat maxY = CGRectGetMaxY(allowed) - half;

    if (maxX < minX) maxX = minX;
    if (maxY < minY) maxY = minY;

    CGPoint center = self.floatingButton.center;
    CGFloat dLeft   = center.x - minX;
    CGFloat dRight  = maxX - center.x;
    CGFloat dTop    = center.y - minY;
    CGFloat dBottom = maxY - center.y;
    CGFloat minDist = MIN(MIN(dLeft, dRight), MIN(dTop, dBottom));

    CGPoint target = center;
    if (minDist == dLeft) {
        target.x = minX;
    } else if (minDist == dRight) {
        target.x = maxX;
    } else if (minDist == dTop) {
        target.y = minY;
    } else {
        target.y = maxY;
    }

    [UIView animateWithDuration:0.25
                          delay:0
         usingSpringWithDamping:0.8
          initialSpringVelocity:0
                        options:UIViewAnimationOptionCurveEaseOut
                     animations:^{
                         self.floatingButton.center = target;
                     }
                     completion:nil];
}

#pragma mark - Interaction

- (void)handlePan:(UIPanGestureRecognizer *)pan {
    UIView *view = pan.view;
    UIWindow *window = view.window;
    if (!window) return;

    CGPoint translation = [pan translationInView:window];
    view.center = CGPointMake(view.center.x + translation.x,
                              view.center.y + translation.y);
    [pan setTranslation:CGPointZero inView:window];

    [self clampToScreen];

    if (pan.state == UIGestureRecognizerStateEnded ||
        pan.state == UIGestureRecognizerStateCancelled) {
        [self snapToNearestEdge];
    }
}

- (void)handleTap:(UIButton *)sender {
    Class tasksVCClass = NSClassFromString(@"DownloadTasksViewController");
    if (!tasksVCClass) return;

    UIViewController *topVC = currentVC();
    if (!topVC || [topVC isKindOfClass:tasksVCClass]) return;

    UIViewController *vc = [[tasksVCClass alloc] init];
    vc.modalPresentationStyle = UIModalPresentationFullScreen;
    [topVC presentViewController:vc animated:YES completion:nil];
}

#pragma mark - Notifications

- (void)handleAggregateStateChanged:(NSNotification *)notification {
    [self updateAppearance];
}

- (void)handleApplicationDidBecomeActive:(NSNotification *)notification {
    [self updateVisibility];
    [self updateAppearance];
}

- (void)handleSettingsChanged:(NSNotification *)notification {
    [self updateVisibility];
    [self updateAppearance];
}

- (void)handleOrientationChanged:(NSNotification *)notification {
    [self clampToScreen];
    [self updateVisibility];
    [self updateAppearance];
}

@end
