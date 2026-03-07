#import "PLCrashView.h"
#import "PLLogOutputView.h"
#import "SurfaceViewController.h"
#import "ios_uikit_bridge.h"
#import "utils.h"

@interface PLCrashView ()
@property (nonatomic, strong) UIView *containerView;
@property (nonatomic, strong) UIView *errorCardView;
@property (nonatomic, strong) UIView *infoCardView;
@property (nonatomic, strong) UIView *logContainerView;
@property (nonatomic, strong) UITextView *logTextView;
@property (nonatomic, strong) UILabel *titleLabel;
@property (nonatomic, strong) UILabel *subtitleLabel;
@property (nonatomic, strong) UIImageView *iconView;
@property (nonatomic, strong) UIButton *logToggleBtn;
@property (nonatomic, strong) UIStackView *buttonStackView;
@property (nonatomic, assign) int exitCode;
@property (nonatomic, assign) BOOL logExpanded;
@property (nonatomic, copy) NSString *customTitle;
@property (nonatomic, copy) NSString *customReason;
@end

@implementation PLCrashView

static PLCrashView *currentCrashView = nil;

#pragma mark - Public Methods

+ (void)showWithExitCode:(int)exitCode {
    [self showWithExitCode:exitCode customTitle:nil customReason:nil];
}

+ (void)showWithExitCode:(int)exitCode customTitle:(NSString *)customTitle customReason:(NSString *)customReason {
    dispatch_async(dispatch_get_main_queue(), ^{
        // 如果已经存在崩溃界面，先移除
        if (currentCrashView) {
            [currentCrashView removeFromSuperview];
        }
        
        UIWindow *keyWindow = nil;
        
        // iOS 13+ 使用 connectedScenes
        if (@available(iOS 13.0, *)) {
            for (UIScene *scene in [UIApplication sharedApplication].connectedScenes) {
                if (scene.activationState == UISceneActivationStateForegroundActive ||
                    scene.activationState == UISceneActivationStateForegroundInactive) {
                    UIWindowScene *windowScene = (UIWindowScene *)scene;
                    for (UIWindow *window in windowScene.windows) {
                        if (window.isKeyWindow) {
                            keyWindow = window;
                            break;
                        }
                    }
                    if (keyWindow) break;
                }
            }
        }
        
        if (!keyWindow) {
            keyWindow = [UIApplication sharedApplication].keyWindow;
        }
        
        if (!keyWindow) {
            return;
        }
        
        PLCrashView *crashView = [[PLCrashView alloc] initWithFrame:keyWindow.bounds];
        crashView.exitCode = exitCode;
        crashView.customTitle = customTitle;
        crashView.customReason = customReason;
        
        [keyWindow addSubview:crashView];
        currentCrashView = crashView;
    });
}

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        [self setupUI];
    }
    return self;
}

#pragma mark - UI Setup

- (void)setupUI {
    self.backgroundColor = [[UIColor blackColor] colorWithAlphaComponent:0.85];
    self.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    
    // 毛玻璃背景
    UIBlurEffect *blurEffect = [UIBlurEffect effectWithStyle:UIBlurEffectStyleDark];
    UIVisualEffectView *blurView = [[UIVisualEffectView alloc] initWithEffect:blurEffect];
    blurView.frame = self.bounds;
    blurView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    [self addSubview:blurView];
    
    // 容器视图
    CGFloat containerWidth = MIN(self.bounds.size.width - 32, 420);
    _containerView = [[UIView alloc] initWithFrame:CGRectMake((self.bounds.size.width - containerWidth) / 2, 60, containerWidth, self.bounds.size.height - 120)];
    _containerView.autoresizingMask = UIViewAutoresizingFlexibleLeftMargin | UIViewAutoresizingFlexibleRightMargin | UIViewAutoresizingFlexibleTopMargin | UIViewAutoresizingFlexibleBottomMargin;
    [self addSubview:_containerView];
    
    [self setupErrorCard];
    [self setupInfoCard];
    [self setupLogContainer];
    [self setupButtons];
}

- (void)setupErrorCard {
    // 错误卡片 - 渐变背景
    _errorCardView = [[UIView alloc] initWithFrame:CGRectMake(0, 0, _containerView.bounds.size.width, 120)];
    _errorCardView.layer.cornerRadius = 16;
    _errorCardView.layer.masksToBounds = YES;
    [_containerView addSubview:_errorCardView];
    
    // 创建渐变背景
    CAGradientLayer *gradientLayer = [CAGradientLayer layer];
    gradientLayer.frame = _errorCardView.bounds;
    gradientLayer.colors = @[
        (id)[UIColor colorWithRed:0.8 green:0.2 blue:0.2 alpha:1.0].CGColor,
        (id)[UIColor colorWithRed:0.9 green:0.4 blue:0.1 alpha:1.0].CGColor
    ];
    gradientLayer.startPoint = CGPointMake(0, 0);
    gradientLayer.endPoint = CGPointMake(1, 1);
    [_errorCardView.layer insertSublayer:gradientLayer atIndex:0];
    
    // 图标
    _iconView = [[UIImageView alloc] initWithFrame:CGRectMake(_containerView.bounds.size.width / 2 - 25, 15, 50, 50)];
    if (@available(iOS 13.0, *)) {
        UIImageSymbolConfiguration *config = [UIImageSymbolConfiguration configurationWithPointSize:40 weight:UIImageSymbolWeightMedium];
        _iconView.image = [UIImage systemImageNamed:@"exclamationmark.triangle.fill" withConfiguration:config];
    }
    _iconView.tintColor = [UIColor whiteColor];
    _iconView.contentMode = UIViewContentModeScaleAspectFit;
    [_errorCardView addSubview:_iconView];
    
    // 标题
    _titleLabel = [[UILabel alloc] initWithFrame:CGRectMake(16, 72, _containerView.bounds.size.width - 32, 24)];
    _titleLabel.text = localize(@"crash.title", nil);
    _titleLabel.font = [UIFont boldSystemFontOfSize:18];
    _titleLabel.textColor = [UIColor whiteColor];
    _titleLabel.textAlignment = NSTextAlignmentCenter;
    [_errorCardView addSubview:_titleLabel];
    
    // 副标题
    _subtitleLabel = [[UILabel alloc] initWithFrame:CGRectMake(16, 96, _containerView.bounds.size.width - 32, 20)];
    _subtitleLabel.text = localize(@"crash.subtitle", nil);
    _subtitleLabel.font = [UIFont systemFontOfSize:14];
    _subtitleLabel.textColor = [[UIColor whiteColor] colorWithAlphaComponent:0.9];
    _subtitleLabel.textAlignment = NSTextAlignmentCenter;
    [_errorCardView addSubview:_subtitleLabel];
}

- (void)setupInfoCard {
    CGFloat topOffset = 136;
    
    _infoCardView = [[UIView alloc] initWithFrame:CGRectMake(0, topOffset, _containerView.bounds.size.width, 120)];
    _infoCardView.backgroundColor = [[UIColor whiteColor] colorWithAlphaComponent:0.08];
    _infoCardView.layer.cornerRadius = 16;
    [_containerView addSubview:_infoCardView];
    
    // 退出代码行
    UILabel *codeTitle = [self createInfoLabel:CGRectMake(16, 16, 80, 20) text:localize(@"crash.exit_code", nil) font:[UIFont systemFontOfSize:13] color:[[UIColor whiteColor] colorWithAlphaComponent:0.6]];
    UILabel *codeValue = [self createInfoLabel:CGRectMake(100, 16, _containerView.bounds.size.width - 116, 20) text:[NSString stringWithFormat:@"%d", _exitCode] font:[UIFont boldSystemFontOfSize:13] color:[UIColor whiteColor]];
    
    [_infoCardView addSubview:codeTitle];
    [_infoCardView addSubview:codeValue];
    
    // 原因
    UILabel *reasonTitle = [self createInfoLabel:CGRectMake(16, 48, _containerView.bounds.size.width - 32, 20) text:localize(@"crash.reason", nil) font:[UIFont systemFontOfSize:13] color:[[UIColor whiteColor] colorWithAlphaComponent:0.6]];
    UILabel *reasonValue = [self createInfoLabel:CGRectMake(16, 72, _containerView.bounds.size.width - 32, 40) text:[self getReasonForExitCode:_exitCode] font:[UIFont systemFontOfSize:13] color:[UIColor whiteColor]];
    reasonValue.numberOfLines = 2;
    
    [_infoCardView addSubview:reasonTitle];
    [_infoCardView addSubview:reasonValue];
}

- (void)setupLogContainer {
    CGFloat topOffset = 268;
    CGFloat logHeight = 120;
    
    _logContainerView = [[UIView alloc] initWithFrame:CGRectMake(0, topOffset, _containerView.bounds.size.width, logHeight + 44)];
    _logContainerView.backgroundColor = [[UIColor whiteColor] colorWithAlphaComponent:0.05];
    _logContainerView.layer.cornerRadius = 16;
    _logContainerView.layer.masksToBounds = YES;
    [_containerView addSubview:_logContainerView];
    
    // 日志展开按钮
    _logToggleBtn = [UIButton buttonWithType:UIButtonTypeSystem];
    _logToggleBtn.frame = CGRectMake(0, 0, _containerView.bounds.size.width, 44);
    [_logToggleBtn setTitle:localize(@"crash.view_log", nil) forState:UIControlStateNormal];
    [_logToggleBtn setImage:[UIImage systemImageNamed:@"chevron.down"] forState:UIControlStateNormal];
    _logToggleBtn.tintColor = [UIColor whiteColor];
    _logToggleBtn.contentHorizontalAlignment = UIControlContentHorizontalAlignmentLeft;
    _logToggleBtn.contentEdgeInsets = UIEdgeInsetsMake(0, 16, 0, 0);
    _logToggleBtn.titleEdgeInsets = UIEdgeInsetsMake(0, 8, 0, 0);
    _logToggleBtn.imageEdgeInsets = UIEdgeInsetsMake(0, _containerView.bounds.size.width - 44, 0, 0);
    [_logToggleBtn addTarget:self action:@selector(toggleLogView) forControlEvents:UIControlEventTouchUpInside];
    [_logContainerView addSubview:_logToggleBtn];
    
    // 分隔线
    UIView *separator = [[UIView alloc] initWithFrame:CGRectMake(0, 43.5, _containerView.bounds.size.width, 0.5)];
    separator.backgroundColor = [[UIColor whiteColor] colorWithAlphaComponent:0.1];
    [_logContainerView addSubview:separator];
    
    // 日志文本视图
    _logTextView = [[UITextView alloc] initWithFrame:CGRectMake(8, 44, _containerView.bounds.size.width - 16, logHeight)];
    _logTextView.backgroundColor = [UIColor clearColor];
    _logTextView.textColor = [[UIColor whiteColor] colorWithAlphaComponent:0.8];
    _logTextView.font = [UIFont fontWithName:@"Menlo" size:11];
    _logTextView.editable = NO;
    _logTextView.showsVerticalScrollIndicator = YES;
    _logTextView.indicatorStyle = UIScrollViewIndicatorStyleWhite;
    [_logContainerView addSubview:_logTextView];
    
    // 加载日志内容
    [self loadLogContent];
    
    _logExpanded = YES;
}

- (void)setupButtons {
    CGFloat topOffset = _containerView.bounds.size.height - 180;
    
    _buttonStackView = [[UIStackView alloc] initWithFrame:CGRectMake(0, topOffset, _containerView.bounds.size.width, 160)];
    _buttonStackView.axis = UILayoutConstraintAxisVertical;
    _buttonStackView.spacing = 12;
    _buttonStackView.distribution = UIStackViewDistributionFill;
    [_containerView addSubview:_buttonStackView];
    
    // 分享日志按钮
    UIButton *shareBtn = [self createButtonWithTitle:localize(@"crash.share_log", nil) icon:@"square.and.arrow.up" action:@selector(shareLog)];
    [_buttonStackView addArrangedSubview:shareBtn];
    
    // 查看完整日志按钮
    UIButton *fullLogBtn = [self createButtonWithTitle:localize(@"crash.full_log", nil) icon:@"doc.text" action:@selector(showFullLog)];
    [_buttonStackView addArrangedSubview:fullLogBtn];
    
    // 返回启动器按钮
    UIButton *returnBtn = [self createButtonWithTitle:localize(@"crash.return_launcher", nil) icon:@"house" action:@selector(dismissAndReturnToLauncher) primary:YES];
    [_buttonStackView addArrangedSubview:returnBtn];
}

#pragma mark - Helper Methods

- (UILabel *)createInfoLabel:(CGRect)frame text:(NSString *)text font:(UIFont *)font color:(UIColor *)color {
    UILabel *label = [[UILabel alloc] initWithFrame:frame];
    label.text = text;
    label.font = font;
    label.textColor = color;
    label.lineBreakMode = NSLineBreakByTruncatingTail;
    return label;
}

- (UIButton *)createButtonWithTitle:(NSString *)title icon:(NSString *)icon action:(SEL)action primary:(BOOL)primary {
    UIButton *button = [UIButton buttonWithType:UIButtonTypeSystem];
    button.frame = CGRectMake(0, 0, _containerView.bounds.size.width, 44);
    
    if (primary) {
        button.backgroundColor = [UIColor colorWithRed:0.26 green:0.63 blue:0.96 alpha:1.0];
        [button setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    } else {
        button.backgroundColor = [[UIColor whiteColor] colorWithAlphaComponent:0.1];
        [button setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    }
    
    button.layer.cornerRadius = 12;
    button.titleLabel.font = [UIFont boldSystemFontOfSize:15];
    
    if (@available(iOS 13.0, *)) {
        UIImageSymbolConfiguration *config = [UIImageSymbolConfiguration configurationWithPointSize:15 weight:UIImageSymbolWeightMedium];
        UIImage *iconImage = [UIImage systemImageNamed:icon withConfiguration:config];
        [button setImage:iconImage forState:UIControlStateNormal];
    }
    
    button.titleEdgeInsets = UIEdgeInsetsMake(0, 8, 0, 0);
    button.imageEdgeInsets = UIEdgeInsetsMake(0, -8, 0, 0);
    [button setTitle:title forState:UIControlStateNormal];
    [button addTarget:self action:action forControlEvents:UIControlEventTouchUpInside];
    
    return button;
}

- (UIButton *)createButtonWithTitle:(NSString *)title icon:(NSString *)icon action:(SEL)action {
    return [self createButtonWithTitle:title icon:icon action:action primary:NO];
}

- (NSString *)getReasonForExitCode:(int)code {
    if (_customReason) {
        return _customReason;
    }
    
    switch (code) {
        case 0:
            return localize(@"crash.reason.normal", nil);
        case 1:
            return localize(@"crash.reason.java_exception", nil);
        case 137:
            return localize(@"crash.reason.memory", nil);
        case 139:
            return localize(@"crash.reason.segmentation", nil);
        case 134:
            return localize(@"crash.reason.abort", nil);
        case 143:
            return localize(@"crash.reason.terminated", nil);
        default:
            return [NSString stringWithFormat:localize(@"crash.reason.unknown", nil), code];
    }
}

- (void)loadLogContent {
    NSString *latestlogPath = [NSString stringWithFormat:@"%s/latestlog.txt", getenv("POJAV_HOME")];
    NSString *logContent = [NSString stringWithContentsOfFile:latestlogPath encoding:NSUTF8StringEncoding error:nil];
    
    if (!logContent) {
        _logTextView.text = localize(@"crash.log_unavailable", nil);
        return;
    }
    
    // 获取最后100行
    NSArray *lines = [logContent componentsSeparatedByCharactersInSet:[NSCharacterSet newlineCharacterSet]];
    NSInteger startIndex = MAX(0, (NSInteger)lines.count - 100);
    NSMutableArray *lastLines = [NSMutableArray array];
    for (NSInteger i = startIndex; i < (NSInteger)lines.count; i++) {
        if (lines[i].length > 0) {
            [lastLines addObject:lines[i]];
        }
    }
    
    _logTextView.text = [lastLines componentsJoinedByString:@"\n"];
    
    // 滚动到底部
    dispatch_async(dispatch_get_main_queue(), ^{
        [_logTextView scrollRangeToVisible:NSMakeRange(_logTextView.text.length, 0)];
    });
}

#pragma mark - Actions

- (void)toggleLogView {
    _logExpanded = !_logExpanded;
    
    NSString *imageName = _logExpanded ? @"chevron.up" : @"chevron.down";
    [_logToggleBtn setImage:[UIImage systemImageNamed:imageName] forState:UIControlStateNormal];
    
    [UIView animateWithDuration:0.25 animations:^{
        self.logContainerView.frame = CGRectMake(0, 268, self.containerView.bounds.size.width, self.logExpanded ? 164 : 44);
        self.logTextView.hidden = !self.logExpanded;
    }];
}

- (void)shareLog {
    NSString *latestlogPath = [NSString stringWithFormat:@"file://%s/latestlog.txt", getenv("POJAV_HOME")];
    UIActivityViewController *activityVC = [[UIActivityViewController alloc] initWithActivityItems:@[@"latestlog.txt", [NSURL URLWithString:latestlogPath]] applicationActivities:nil];
    
    UIViewController *presentingVC = [self nextViewController];
    if (!presentingVC) {
        presentingVC = currentVC();
    }
    
    activityVC.popoverPresentationController.sourceView = self;
    activityVC.popoverPresentationController.sourceRect = CGRectMake(self.bounds.size.width / 2, self.bounds.size.height / 2, 1, 1);
    
    [presentingVC presentViewController:activityVC animated:YES completion:nil];
}

- (void)showFullLog {
    // 显示完整的 PLLogOutputView
    if ([SurfaceViewController currentInstance]) {
        [[SurfaceViewController currentInstance].logOutputView actionToggleLogOutput];
    }
}

- (void)dismissAndReturnToLauncher {
    // 调用 PLLogOutputView 的返回逻辑
    if ([SurfaceViewController currentInstance]) {
        [[SurfaceViewController currentInstance].logOutputView dismissAndReturnToLauncher];
    }
    
    [UIView animateWithDuration:0.3 animations:^{
        self.alpha = 0;
    } completion:^(BOOL finished) {
        [self removeFromSuperview];
        currentCrashView = nil;
    }];
}

- (UIViewController *)nextViewController {
    UIResponder *responder = self;
    while (responder) {
        responder = [responder nextResponder];
        if ([responder isKindOfClass:[UIViewController class]]) {
            return (UIViewController *)responder;
        }
    }
    return nil;
}

#pragma mark - Layout

- (void)layoutSubviews {
    [super layoutSubviews];
    
    // 更新渐变层 frame
    for (CALayer *layer in _errorCardView.layer.sublayers) {
        if ([layer isKindOfClass:[CAGradientLayer class]]) {
            layer.frame = _errorCardView.bounds;
        }
    }
}

@end
