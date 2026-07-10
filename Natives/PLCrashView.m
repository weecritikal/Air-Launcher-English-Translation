#import "PLCrashView.h"
#import "PLLogOutputView.h"
#import "SurfaceViewController.h"
#import "ios_uikit_bridge.h"
#import "utils.h"
#import "AIFixViewController.h"
#import "AIFixService.h"

@interface PLCrashView ()
// 数据
@property (nonatomic, assign) int exitCode;
@property (nonatomic, copy) NSString *customTitle;
@property (nonatomic, copy) NSString *customReason;

// UI 组件
@property (nonatomic, strong) UIScrollView *mainScrollView;
@property (nonatomic, strong) UIStackView *mainStackView;
@property (nonatomic, strong) UIView *errorCardView;
@property (nonatomic, strong) UIImageView *errorIconView;
@property (nonatomic, strong) UILabel *errorTitleLabel;
@property (nonatomic, strong) UILabel *errorCodeLabel;
@property (nonatomic, strong) UILabel *reasonLabel;
@property (nonatomic, strong) UILabel *oomSuggestionLabel;
@property (nonatomic, strong) UIView *logCardView;
@property (nonatomic, strong) UILabel *logTitleLabel;
@property (nonatomic, strong) UITextView *logTextView;
@property (nonatomic, strong) UILabel *logPlaceholderLabel;
@property (nonatomic, strong) UIButton *restartButton;
@property (nonatomic, strong) UIButton *shareButton;
@property (nonatomic, strong) UIButton *aiFixButton;
@property (nonatomic, strong) UIButton *githubButton;
@property (nonatomic, strong) UIButton *fullLogButton;
@property (nonatomic, strong) UIButton *exitButton;
// 日志卡片高度约束（根据屏幕高度动态调整）
@property (nonatomic, strong) NSLayoutConstraint *logCardHeightConstraint;
@end

@implementation PLCrashView

// 当前正在显示的崩溃 VC 实例（单例）
static PLCrashView *currentCrashVC = nil;
static NSString *const kGitHubIssuesURL = @"https://github.com/herbrine8403/Amethyst-iOS-MyRemastered/issues";

#pragma mark - Public Methods

+ (void)showWithExitCode:(int)exitCode {
    [self showWithExitCode:exitCode customTitle:nil customReason:nil];
}

+ (void)showWithExitCode:(int)exitCode customTitle:(NSString *)customTitle customReason:(NSString *)customReason {
    dispatch_async(dispatch_get_main_queue(), ^{
        // 如果已经存在崩溃界面，先 dismiss，避免叠加
        if (currentCrashVC) {
            [currentCrashVC dismissViewControllerAnimated:NO completion:nil];
            currentCrashVC = nil;
        }

        UIWindow *keyWindow = nil;
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

        if (!keyWindow) return;

        // 找到最顶层的 presented VC 来 present 崩溃界面。
        // 旧实现把 UIView 直接 addSubview 到 keyWindow，存在生命周期无人管理、
        // 旋转/安全区不跟随等问题。改为 UIViewController 后由系统管理生命周期。
        UIViewController *rootVC = keyWindow.rootViewController;
        while (rootVC.presentedViewController) {
            rootVC = rootVC.presentedViewController;
        }

        PLCrashView *crashVC = [[PLCrashView alloc] init];
        crashVC.exitCode = exitCode;
        crashVC.customTitle = customTitle;
        crashVC.customReason = customReason;
        crashVC.modalPresentationStyle = UIModalPresentationOverFullScreen;
        crashVC.modalTransitionStyle = UIModalTransitionStyleCrossDissolve;

        currentCrashVC = crashVC;
        [rootVC presentViewController:crashVC animated:NO completion:nil];
    });
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _exitCode = 0;
        _customTitle = nil;
        _customReason = nil;
    }
    return self;
}

#pragma mark - Lifecycle

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = [UIColor clearColor];
    [self setupBackground];
    [self setupUI];
    [self loadLogContent];
}

- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    // 根据屏幕高度动态调整日志卡片高度，避免小屏挤压按钮或大屏浪费空间
    [self adjustLogCardHeight];
}

#pragma mark - Background

- (void)setupBackground {
    // 毛玻璃背景
    UIBlurEffect *blurEffect = [UIBlurEffect effectWithStyle:UIBlurEffectStyleDark];
    UIVisualEffectView *blurView = [[UIVisualEffectView alloc] initWithEffect:blurEffect];
    blurView.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:blurView];

    // 深色蒙层增强毛玻璃效果
    UIView *overlayView = [[UIView alloc] init];
    overlayView.backgroundColor = [[UIColor blackColor] colorWithAlphaComponent:0.5];
    overlayView.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:overlayView];

    [NSLayoutConstraint activateConstraints:@[
        [blurView.topAnchor constraintEqualToAnchor:self.view.topAnchor],
        [blurView.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor],
        [blurView.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [blurView.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [overlayView.topAnchor constraintEqualToAnchor:self.view.topAnchor],
        [overlayView.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor],
        [overlayView.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [overlayView.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
    ]];
}

#pragma mark - UI Setup

- (void)setupUI {
    // 主滚动视图（内容超出屏幕时可滚动）
    _mainScrollView = [[UIScrollView alloc] init];
    _mainScrollView.translatesAutoresizingMaskIntoConstraints = NO;
    _mainScrollView.alwaysBounceVertical = YES;
    _mainScrollView.showsVerticalScrollIndicator = YES;
    _mainScrollView.indicatorStyle = UIScrollViewIndicatorStyleWhite;
    _mainScrollView.contentInsetAdjustmentBehavior = UIScrollViewContentInsetAdjustmentNever;
    [self.view addSubview:_mainScrollView];

    // 主垂直 StackView（所有卡片和按钮垂直排列）
    _mainStackView = [[UIStackView alloc] init];
    _mainStackView.axis = UILayoutConstraintAxisVertical;
    _mainStackView.spacing = 16;
    _mainStackView.alignment = UIStackViewAlignmentFill;
    _mainStackView.distribution = UIStackViewDistributionFill;
    _mainStackView.translatesAutoresizingMaskIntoConstraints = NO;
    [_mainScrollView addSubview:_mainStackView];

    [NSLayoutConstraint activateConstraints:@[
        [_mainScrollView.topAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.topAnchor constant:16],
        [_mainScrollView.bottomAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.bottomAnchor constant:-16],
        [_mainScrollView.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [_mainScrollView.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [_mainStackView.topAnchor constraintEqualToAnchor:_mainScrollView.contentLayoutGuide.topAnchor],
        [_mainStackView.bottomAnchor constraintEqualToAnchor:_mainScrollView.contentLayoutGuide.bottomAnchor],
        [_mainStackView.leadingAnchor constraintEqualToAnchor:_mainScrollView.contentLayoutGuide.leadingAnchor],
        [_mainStackView.trailingAnchor constraintEqualToAnchor:_mainScrollView.contentLayoutGuide.trailingAnchor],
        [_mainStackView.widthAnchor constraintEqualToAnchor:_mainScrollView.frameLayoutGuide.widthAnchor],
    ]];

    // StackView 左右留白（卡片不贴边）
    _mainStackView.layoutMargins = UIEdgeInsetsMake(16, 20, 16, 20);
    _mainStackView.layoutMarginsRelativeArrangement = YES;

    [self setupErrorCard];
    [self setupLogCard];
    [self setupButtons];
}

- (void)setupErrorCard {
    _errorCardView = [[UIView alloc] init];
    _errorCardView.backgroundColor = [UIColor colorWithRed:1.0 green:0.278 blue:0.318 alpha:1.0]; // #FF4757
    _errorCardView.layer.cornerRadius = 16;
    _errorCardView.layer.cornerCurve = kCACornerCurveContinuous;
    _errorCardView.layer.shadowColor = [UIColor blackColor].CGColor;
    _errorCardView.layer.shadowOffset = CGSizeMake(0, 4);
    _errorCardView.layer.shadowOpacity = 0.15;
    _errorCardView.layer.shadowRadius = 8;
    _errorCardView.translatesAutoresizingMaskIntoConstraints = NO;
    [_mainStackView addArrangedSubview:_errorCardView];

    // 错误图标
    _errorIconView = [[UIImageView alloc] init];
    _errorIconView.translatesAutoresizingMaskIntoConstraints = NO;
    if (@available(iOS 13.0, *)) {
        UIImageSymbolConfiguration *config = [UIImageSymbolConfiguration configurationWithPointSize:36 weight:UIImageSymbolWeightBold];
        _errorIconView.image = [UIImage systemImageNamed:@"exclamationmark.triangle.fill" withConfiguration:config];
    }
    _errorIconView.tintColor = [UIColor whiteColor];
    _errorIconView.contentMode = UIViewContentModeScaleAspectFit;
    [_errorCardView addSubview:_errorIconView];

    // 错误标题
    _errorTitleLabel = [[UILabel alloc] init];
    _errorTitleLabel.translatesAutoresizingMaskIntoConstraints = NO;
    _errorTitleLabel.text = _customTitle ?: localize(@"crash.error_title", nil);
    _errorTitleLabel.font = [UIFont boldSystemFontOfSize:18];
    _errorTitleLabel.textColor = [UIColor whiteColor];
    _errorTitleLabel.textAlignment = NSTextAlignmentCenter;
    _errorTitleLabel.numberOfLines = 0;
    [_errorCardView addSubview:_errorTitleLabel];

    // 错误代码
    _errorCodeLabel = [[UILabel alloc] init];
    _errorCodeLabel.translatesAutoresizingMaskIntoConstraints = NO;
    _errorCodeLabel.text = [NSString stringWithFormat:@"%@%d", localize(@"crash.error_code", nil), _exitCode];
    _errorCodeLabel.font = [UIFont systemFontOfSize:14];
    _errorCodeLabel.textColor = [[UIColor whiteColor] colorWithAlphaComponent:0.9];
    _errorCodeLabel.textAlignment = NSTextAlignmentCenter;
    [_errorCardView addSubview:_errorCodeLabel];

    // 可能原因
    _reasonLabel = [[UILabel alloc] init];
    _reasonLabel.translatesAutoresizingMaskIntoConstraints = NO;
    _reasonLabel.text = [self crashReasonText];
    _reasonLabel.font = [UIFont systemFontOfSize:13];
    _reasonLabel.textColor = [[UIColor whiteColor] colorWithAlphaComponent:0.75];
    _reasonLabel.textAlignment = NSTextAlignmentCenter;
    _reasonLabel.numberOfLines = 0;
    [_errorCardView addSubview:_reasonLabel];

    // 通用约束（图标/标题/代码/原因）
    NSMutableArray<NSLayoutConstraint *> *constraints = [NSMutableArray arrayWithArray:@[
        [_errorIconView.topAnchor constraintEqualToAnchor:_errorCardView.topAnchor constant:16],
        [_errorIconView.centerXAnchor constraintEqualToAnchor:_errorCardView.centerXAnchor],
        [_errorIconView.widthAnchor constraintEqualToConstant:40],
        [_errorIconView.heightAnchor constraintEqualToConstant:40],

        [_errorTitleLabel.topAnchor constraintEqualToAnchor:_errorIconView.bottomAnchor constant:12],
        [_errorTitleLabel.leadingAnchor constraintEqualToAnchor:_errorCardView.leadingAnchor constant:16],
        [_errorTitleLabel.trailingAnchor constraintEqualToAnchor:_errorCardView.trailingAnchor constant:-16],

        [_errorCodeLabel.topAnchor constraintEqualToAnchor:_errorTitleLabel.bottomAnchor constant:6],
        [_errorCodeLabel.leadingAnchor constraintEqualToAnchor:_errorCardView.leadingAnchor constant:16],
        [_errorCodeLabel.trailingAnchor constraintEqualToAnchor:_errorCardView.trailingAnchor constant:-16],

        [_reasonLabel.topAnchor constraintEqualToAnchor:_errorCodeLabel.bottomAnchor constant:6],
        [_reasonLabel.leadingAnchor constraintEqualToAnchor:_errorCardView.leadingAnchor constant:16],
        [_reasonLabel.trailingAnchor constraintEqualToAnchor:_errorCardView.trailingAnchor constant:-16],
    ]];

    // OOM 崩溃时显示建议标签，errorCardView 底部锚定到 oomSuggestionLabel 底部
    if ([self isOOMCrash]) {
        _oomSuggestionLabel = [[UILabel alloc] init];
        _oomSuggestionLabel.translatesAutoresizingMaskIntoConstraints = NO;
        _oomSuggestionLabel.font = [UIFont systemFontOfSize:12];
        _oomSuggestionLabel.textColor = [[UIColor whiteColor] colorWithAlphaComponent:0.65];
        _oomSuggestionLabel.textAlignment = NSTextAlignmentCenter;
        _oomSuggestionLabel.numberOfLines = 0;
        NSString *suggestion = [NSString stringWithFormat:@"%@ %@",
                                localize(@"crash.suggestion", @"建议操作"),
                                localize(@"crash.suggestion.oom", @"iOS 内存限制导致崩溃，建议使用 GetMoreRam (LiveContainer) 解除内存限制后重试")];
        _oomSuggestionLabel.text = suggestion;
        [_errorCardView addSubview:_oomSuggestionLabel];

        [constraints addObjectsFromArray:@[
            [_oomSuggestionLabel.topAnchor constraintEqualToAnchor:_reasonLabel.bottomAnchor constant:8],
            [_oomSuggestionLabel.leadingAnchor constraintEqualToAnchor:_errorCardView.leadingAnchor constant:16],
            [_oomSuggestionLabel.trailingAnchor constraintEqualToAnchor:_errorCardView.trailingAnchor constant:-16],
            [_oomSuggestionLabel.bottomAnchor constraintEqualToAnchor:_errorCardView.bottomAnchor constant:-16],
        ]];
    } else {
        // 非 OOM 时，errorCardView 底部直接锚定到 reasonLabel 底部
        [constraints addObject:[_reasonLabel.bottomAnchor constraintEqualToAnchor:_errorCardView.bottomAnchor constant:-16]];
    }

    [NSLayoutConstraint activateConstraints:constraints];
}

- (void)setupLogCard {
    _logCardView = [[UIView alloc] init];
    _logCardView.backgroundColor = [UIColor colorWithWhite:0.08 alpha:1.0];
    _logCardView.layer.cornerRadius = 16;
    _logCardView.layer.cornerCurve = kCACornerCurveContinuous;
    _logCardView.layer.masksToBounds = YES;
    _logCardView.translatesAutoresizingMaskIntoConstraints = NO;
    [_mainStackView addArrangedSubview:_logCardView];

    // 日志标题
    _logTitleLabel = [[UILabel alloc] init];
    _logTitleLabel.translatesAutoresizingMaskIntoConstraints = NO;
    _logTitleLabel.text = localize(@"crash.log_info", nil);
    _logTitleLabel.font = [UIFont systemFontOfSize:15 weight:UIFontWeightSemibold];
    _logTitleLabel.textColor = [UIColor whiteColor];
    [_logCardView addSubview:_logTitleLabel];

    // 日志文本视图（可内部滚动）
    _logTextView = [[UITextView alloc] init];
    _logTextView.translatesAutoresizingMaskIntoConstraints = NO;
    _logTextView.backgroundColor = [UIColor clearColor];
    _logTextView.textColor = [[UIColor whiteColor] colorWithAlphaComponent:0.85];
    _logTextView.font = [UIFont fontWithName:@"Menlo" size:11];
    _logTextView.editable = NO;
    _logTextView.showsVerticalScrollIndicator = YES;
    _logTextView.indicatorStyle = UIScrollViewIndicatorStyleWhite;
    [_logCardView addSubview:_logTextView];

    // 占位符（日志为空时显示，居中放大文字）
    _logPlaceholderLabel = [[UILabel alloc] init];
    _logPlaceholderLabel.translatesAutoresizingMaskIntoConstraints = NO;
    _logPlaceholderLabel.text = localize(@"crash.log_info", nil);
    _logPlaceholderLabel.font = [UIFont systemFontOfSize:36 weight:UIFontWeightBold];
    _logPlaceholderLabel.textColor = [[UIColor whiteColor] colorWithAlphaComponent:0.15];
    _logPlaceholderLabel.textAlignment = NSTextAlignmentCenter;
    [_logCardView addSubview:_logPlaceholderLabel];

    // 日志卡片高度约束（初始 240，viewDidLayoutSubviews 中根据屏幕高度调整）
    self.logCardHeightConstraint = [_logCardView.heightAnchor constraintEqualToConstant:240];
    self.logCardHeightConstraint.priority = UILayoutPriorityDefaultHigh;

    [NSLayoutConstraint activateConstraints:@[
        [_logTitleLabel.topAnchor constraintEqualToAnchor:_logCardView.topAnchor constant:12],
        [_logTitleLabel.leadingAnchor constraintEqualToAnchor:_logCardView.leadingAnchor constant:16],
        [_logTitleLabel.trailingAnchor constraintEqualToAnchor:_logCardView.trailingAnchor constant:-16],

        [_logTextView.topAnchor constraintEqualToAnchor:_logTitleLabel.bottomAnchor constant:8],
        [_logTextView.leadingAnchor constraintEqualToAnchor:_logCardView.leadingAnchor constant:8],
        [_logTextView.trailingAnchor constraintEqualToAnchor:_logCardView.trailingAnchor constant:-8],
        [_logTextView.bottomAnchor constraintEqualToAnchor:_logCardView.bottomAnchor constant:-8],

        [_logPlaceholderLabel.topAnchor constraintEqualToAnchor:_logCardView.topAnchor],
        [_logPlaceholderLabel.bottomAnchor constraintEqualToAnchor:_logCardView.bottomAnchor],
        [_logPlaceholderLabel.leadingAnchor constraintEqualToAnchor:_logCardView.leadingAnchor],
        [_logPlaceholderLabel.trailingAnchor constraintEqualToAnchor:_logCardView.trailingAnchor],

        self.logCardHeightConstraint,
    ]];
}

- (void)setupButtons {
    // 重启启动器按钮（蓝色强调，FCL 风格优先放置）
    // 参照 FCL：很多崩溃是临时加载失败（JIT/dylib/内存碎片），重启即可解决。
    _restartButton = [self createButtonWithTitle:localize(@"crash.restart_launcher", @"重启启动器")
                                            icon:@"arrow.clockwise"
                                   backgroundColor:[UIColor colorWithRed:0.2 green:0.6 blue:0.95 alpha:1.0]
                                       textColor:[UIColor whiteColor]
                                          bold:YES
                                          action:@selector(restartLauncherAction)];
    [_mainStackView addArrangedSubview:_restartButton];

    // 分享日志按钮
    _shareButton = [self createButtonWithTitle:localize(@"crash.share_log", nil)
                                          icon:@"square.and.arrow.up"
                                 backgroundColor:[[UIColor whiteColor] colorWithAlphaComponent:0.15]
                                     textColor:[UIColor whiteColor]
                                        bold:YES
                                        action:@selector(shareLog)];
    [_mainStackView addArrangedSubview:_shareButton];

    // AI 修复按钮（实验性）
    _aiFixButton = [self createButtonWithTitle:[NSString stringWithFormat:@"%@ (%@)", localize(@"crash.ai_solve", nil), localize(@"crash.experimental", nil)]
                                          icon:@"cpu"
                                 backgroundColor:[[UIColor colorWithRed:0.6 green:0.4 blue:0.9 alpha:1.0] colorWithAlphaComponent:0.3]
                                     textColor:[UIColor whiteColor]
                                        bold:NO
                                        action:@selector(useAIToSolve)];
    [_mainStackView addArrangedSubview:_aiFixButton];

    // GitHub Issues 按钮
    _githubButton = [self createButtonWithTitle:localize(@"crash.github_issue", nil)
                                            icon:@"link"
                                   backgroundColor:[[UIColor colorWithRed:0.3 green:0.5 blue:0.9 alpha:1.0] colorWithAlphaComponent:0.3]
                                       textColor:[UIColor whiteColor]
                                          bold:NO
                                          action:@selector(openGitHubIssues)];
    [_mainStackView addArrangedSubview:_githubButton];

    // 查看完整日志按钮（透明，只文字）
    _fullLogButton = [UIButton buttonWithType:UIButtonTypeSystem];
    _fullLogButton.translatesAutoresizingMaskIntoConstraints = NO;
    [_fullLogButton setTitle:localize(@"crash.view_log", nil) forState:UIControlStateNormal];
    _fullLogButton.titleLabel.font = [UIFont systemFontOfSize:14];
    _fullLogButton.tintColor = [[UIColor whiteColor] colorWithAlphaComponent:0.6];
    [_fullLogButton addTarget:self action:@selector(showFullLog) forControlEvents:UIControlEventTouchUpInside];
    [_mainStackView addArrangedSubview:_fullLogButton];

    // 返回启动器按钮
    _exitButton = [self createButtonWithTitle:localize(@"crash.return_launcher", nil)
                                          icon:@"rectangle.portrait.and.arrow.right"
                                 backgroundColor:[[UIColor whiteColor] colorWithAlphaComponent:0.1]
                                     textColor:[UIColor whiteColor]
                                        bold:NO
                                        action:@selector(dismissAndReturnToLauncher)];
    [_mainStackView addArrangedSubview:_exitButton];
}

- (UIButton *)createButtonWithTitle:(NSString *)title icon:(NSString *)icon backgroundColor:(UIColor *)bgColor textColor:(UIColor *)textColor bold:(BOOL)bold action:(SEL)action {
    UIButton *button = [UIButton buttonWithType:UIButtonTypeSystem];
    button.translatesAutoresizingMaskIntoConstraints = NO;
    button.backgroundColor = bgColor;
    button.layer.cornerRadius = 10;
    button.layer.cornerCurve = kCACornerCurveContinuous;

    [button setTitleColor:textColor forState:UIControlStateNormal];
    button.titleLabel.font = bold ? [UIFont boldSystemFontOfSize:15] : [UIFont systemFontOfSize:15];

    if (@available(iOS 13.0, *)) {
        UIImageSymbolConfiguration *config = [UIImageSymbolConfiguration configurationWithPointSize:15 weight:bold ? UIImageSymbolWeightMedium : UIImageSymbolWeightRegular];
        UIImage *iconImage = [UIImage systemImageNamed:icon withConfiguration:config];
        [button setImage:iconImage forState:UIControlStateNormal];
    }

    button.titleEdgeInsets = UIEdgeInsetsMake(0, 8, 0, 0);
    button.imageEdgeInsets = UIEdgeInsetsMake(0, -8, 0, 0);
    [button setTitle:title forState:UIControlStateNormal];
    [button addTarget:self action:action forControlEvents:UIControlEventTouchUpInside];

    // 固定按钮高度
    [button.heightAnchor constraintEqualToConstant:48].active = YES;

    return button;
}

- (void)adjustLogCardHeight {
    CGFloat screenHeight = self.view.bounds.size.height;
    // 根据屏幕高度调整日志卡片高度：
    //   小屏幕（iPhone SE）日志区较矮，给按钮留空间
    //   大屏幕（iPad）日志区较高，充分利用空间
    CGFloat logHeight;
    if (screenHeight < 600) {
        logHeight = 160;
    } else if (screenHeight < 800) {
        logHeight = 220;
    } else {
        logHeight = 300;
    }
    self.logCardHeightConstraint.constant = logHeight;
}

#pragma mark - Log Content

- (void)loadLogContent {
    NSString *latestlogPath = [NSString stringWithFormat:@"%s/latestlog.txt", getenv("POJAV_HOME")];
    NSString *logContent = [NSString stringWithContentsOfFile:latestlogPath encoding:NSUTF8StringEncoding error:nil];

    if (!logContent || logContent.length == 0) {
        _logTextView.text = nil;
        _logPlaceholderLabel.hidden = NO;
        return;
    }

    // 获取最后150行
    NSArray *lines = [logContent componentsSeparatedByCharactersInSet:[NSCharacterSet newlineCharacterSet]];
    NSInteger startIndex = MAX(0, (NSInteger)lines.count - 150);
    NSMutableArray *lastLines = [NSMutableArray array];
    for (NSInteger i = startIndex; i < (NSInteger)lines.count; i++) {
        NSString *line = lines[i];
        if (line.length > 0) {
            [lastLines addObject:line];
        }
    }

    _logTextView.text = [lastLines componentsJoinedByString:@"\n"];
    _logPlaceholderLabel.hidden = _logTextView.text.length > 0;

    // 滚动到底部
    dispatch_async(dispatch_get_main_queue(), ^{
        [self.logTextView scrollRangeToVisible:NSMakeRange(self.logTextView.text.length, 0)];
    });
}

#pragma mark - Crash Analysis

/// 读取 latestlog.txt 的内容（用于崩溃原因分析）
- (NSString *)readLatestLogForAnalysis {
    static NSString *cachedLog = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        NSString *latestlogPath = [NSString stringWithFormat:@"%s/latestlog.txt", getenv("POJAV_HOME")];
        cachedLog = [NSString stringWithContentsOfFile:latestlogPath encoding:NSUTF8StringEncoding error:nil] ?: @"";
    });
    return cachedLog;
}

/// 判断是否为 OOM（内存不足）崩溃
- (BOOL)isOOMCrash {
    // SIGKILL (信号 9) 通常是系统因内存不足强制终止进程
    if (_exitCode == 9) return YES;

    // 检查日志中是否包含 OOM 相关关键词
    NSString *logContent = [self readLatestLogForAnalysis];
    if (logContent.length > 0) {
        NSString *lowerLog = [logContent lowercaseString];
        NSArray<NSString *> *oomKeywords = @[
            @"outofmemoryerror",
            @"cannot allocate memory",
            @"failed to allocate",
            @"java.lang.outofmemory",
            @"insufficient memory",
            @"mmap failed",
            @"out of memory"
        ];
        for (NSString *keyword in oomKeywords) {
            if ([lowerLog containsString:keyword]) return YES;
        }
    }
    return NO;
}

/// 根据 exitCode 和日志关键词智能识别崩溃类型，返回本地化的原因描述
- (NSString *)crashReasonText {
    // 优先使用自定义原因
    if (_customReason.length > 0) {
        return [NSString stringWithFormat:@"%@%@", localize(@"crash.possible_reason", nil), _customReason];
    }

    NSString *reason = nil;

    // 正常退出（exitCode == 0）
    if (_exitCode == 0) {
        reason = localize(@"crash.reason.normal", nil);
    }
    // OOM 内存不足（SIGKILL 或日志含 OOM 关键词）
    else if ([self isOOMCrash]) {
        reason = localize(@"crash.reason.memory", nil);
    }
    // SIGSEGV 段错误（信号 11）
    else if (_exitCode == 11) {
        reason = localize(@"crash.reason.segmentation", nil);
    }
    // SIGABRT 程序异常终止（信号 6）
    else if (_exitCode == 6) {
        reason = localize(@"crash.reason.abort", nil);
    }
    // SIGTERM 被外部信号终止（信号 15）
    else if (_exitCode == 15) {
        reason = localize(@"crash.reason.terminated", nil);
    }
    // 检查日志是否含 Java 异常关键词
    else {
        NSString *logContent = [self readLatestLogForAnalysis];
        if (logContent.length > 0) {
            NSString *lowerLog = [logContent lowercaseString];
            if ([lowerLog containsString:@"exception"] || [lowerLog containsString:@"stacktrace"]) {
                reason = localize(@"crash.reason.java_exception", nil);
            }
        }
    }

    // 兜底：未知错误
    if (reason.length == 0) {
        reason = [NSString stringWithFormat:localize(@"crash.reason.unknown", @"未知错误 (代码: %d)"), _exitCode];
    }

    return [NSString stringWithFormat:@"%@%@", localize(@"crash.possible_reason", nil), reason];
}

#pragma mark - Actions

- (void)shareLog {
    NSString *latestlogPath = [NSString stringWithFormat:@"file://%s/latestlog.txt", getenv("POJAV_HOME")];
    UIActivityViewController *activityVC = [[UIActivityViewController alloc] initWithActivityItems:@[@"latestlog.txt", [NSURL URLWithString:latestlogPath]] applicationActivities:nil];

    activityVC.popoverPresentationController.sourceView = self.view;
    activityVC.popoverPresentationController.sourceRect = CGRectMake(self.view.bounds.size.width / 2, self.view.bounds.size.height / 2, 1, 1);

    [self presentViewController:activityVC animated:YES completion:nil];
}

- (void)showFullLog {
    // 显示完整的 PLLogOutputView
    if ([SurfaceViewController currentInstance]) {
        [[SurfaceViewController currentInstance].logOutputView actionToggleLogOutput];
    }
}

- (void)openGitHubIssues {
    NSURL *url = [NSURL URLWithString:kGitHubIssuesURL];
    if ([[UIApplication sharedApplication] canOpenURL:url]) {
        [[UIApplication sharedApplication] openURL:url options:@{} completionHandler:nil];
    }
}

- (void)useAIToSolve {
    // 获取崩溃日志路径
    NSString *logPath = [NSString stringWithFormat:@"%s/latestlog.txt", getenv("POJAV_HOME")];

    // 创建 AI 修复界面
    AIFixViewController *aiFixVC = [[AIFixViewController alloc] initWithLogPath:logPath];
    aiFixVC.modalPresentationStyle = UIModalPresentationOverFullScreen;

    [self presentViewController:aiFixVC animated:YES completion:nil];
}

- (void)dismissAndReturnToLauncher {
    // 调用 PLLogOutputView 的返回逻辑
    if ([SurfaceViewController currentInstance]) {
        [[SurfaceViewController currentInstance].logOutputView dismissAndReturnToLauncher];
    }

    [self dismissViewControllerAnimated:YES completion:^{
        currentCrashVC = nil;
    }];
}

/// 重启启动器按钮的实例回调，委托给类方法 +restartLauncher
- (void)restartLauncherAction {
    [PLCrashView restartLauncher];
}

#pragma mark - Class Methods for External Callers

/// 类方法：隐藏崩溃界面并返回启动器。
/// 供 AIFixViewController 等外部 VC 安全调用，避免直接对类对象 performSelector
/// 实例方法导致的 unrecognized selector 崩溃。
+ (void)dismissAndReturnToLauncher {
    dispatch_async(dispatch_get_main_queue(), ^{
        if (currentCrashVC) {
            [currentCrashVC dismissAndReturnToLauncher];
        } else if ([SurfaceViewController currentInstance]) {
            [[SurfaceViewController currentInstance].logOutputView dismissAndReturnToLauncher];
        }
    });
}

/// 重启启动器：清理崩溃界面与游戏 surface，通过 exit(0) + relaunch 触发系统重启。
/// 参照 FCL 的"重启软件"按钮：很多崩溃是临时加载失败，重启即可解决。
+ (void)restartLauncher {
    dispatch_async(dispatch_get_main_queue(), ^{
        // 1. 停止 AI 修复服务（若运行中）
        if ([[AIFixService sharedService] isRunning]) {
            [[AIFixService sharedService] stopFix];
        }

        // 2. 清理崩溃界面
        if (currentCrashVC) {
            [currentCrashVC dismissViewControllerAnimated:NO completion:nil];
            currentCrashVC = nil;
        }

        // 3. 通知 SurfaceViewController 释放游戏资源
        if ([SurfaceViewController currentInstance]) {
            [[SurfaceViewController currentInstance].logOutputView dismissAndReturnToLauncher];
        }

        // 4. 通过 NSURL relaunch 触发系统重新拉起应用（TrollStore/越狱环境支持）
        //    若 relaunch 失败则回退到 exit(0)，系统在 10 秒内会重新唤起前台 App
        NSString *bundlePath = [NSBundle mainBundle].bundlePath;
        NSURL *appURL = [NSURL fileURLWithPath:bundlePath];
        NSLog(@"[PLCrashView] Restarting launcher from %@", bundlePath);

        // 尝试通过 openURL 拉起（需要 UIApplication.openURL，越狱/TrollStore 可用）
        if (@available(iOS 10.0, *)) {
            [[UIApplication sharedApplication] openURL:appURL
                                               options:@{}
                                     completionHandler:^(BOOL success) {
                if (!success) {
                    NSLog(@"[PLCrashView] openURL failed, falling back to exit(0)");
                }
                // 无论如何都退出当前进程，让系统重新拉起
                exit(0);
            }];
        } else {
            exit(0);
        }
    });
}

@end
