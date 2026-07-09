#import "PLCrashView.h"
#import "PLLogOutputView.h"
#import "SurfaceViewController.h"
#import "ios_uikit_bridge.h"
#import "utils.h"
#import "AIFixViewController.h"
#import "AIFixService.h"

@interface PLCrashView ()
@property (nonatomic, strong) UIView *leftPanel;
@property (nonatomic, strong) UIView *rightPanel;
@property (nonatomic, strong) UIView *logPanel;
@property (nonatomic, strong) UITextView *logTextView;
@property (nonatomic, strong) UILabel *logPlaceholderLabel;
@property (nonatomic, strong) UIView *errorCardView;
@property (nonatomic, strong) UIView *logDetailContainer;
@property (nonatomic, strong) UIView *githubCard;
@property (nonatomic, strong) UIView *aiCard;
@property (nonatomic, strong) UILabel *experimentalLabel;
@property (nonatomic, strong) UIButton *shareButton;
@property (nonatomic, strong) UIButton *exitButton;
@property (nonatomic, strong) UIButton *restartButton;
@property (nonatomic, strong) UIButton *fullLogButton;
@property (nonatomic, assign) int exitCode;
@property (nonatomic, assign) BOOL logExpanded;
@property (nonatomic, copy) NSString *customTitle;
@property (nonatomic, copy) NSString *customReason;
@end

@implementation PLCrashView

static PLCrashView *currentCrashView = nil;
static NSString *const kGitHubIssuesURL = @"https://github.com/herbrine8403/Amethyst-iOS-MyRemastered/issues";

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
    self.backgroundColor = [UIColor clearColor];
    self.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    
    // 毛玻璃背景
    UIBlurEffect *blurEffect = [UIBlurEffect effectWithStyle:UIBlurEffectStyleDark];
    UIVisualEffectView *blurView = [[UIVisualEffectView alloc] initWithEffect:blurEffect];
    blurView.frame = self.bounds;
    blurView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    [self addSubview:blurView];
    
    // 深色蒙层增强毛玻璃效果
    UIView *overlayView = [[UIView alloc] initWithFrame:self.bounds];
    overlayView.backgroundColor = [[UIColor blackColor] colorWithAlphaComponent:0.5];
    overlayView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    [self addSubview:overlayView];
    
    // 创建左右分栏容器
    CGFloat leftWidth = self.bounds.size.width * 0.58;
    CGFloat rightWidth = self.bounds.size.width - leftWidth;
    CGFloat topPadding = 60;
    CGFloat bottomPadding = 40;
    CGFloat sidePadding = 16;
    
    // 左侧面板
    _leftPanel = [[UIView alloc] initWithFrame:CGRectMake(0, topPadding, leftWidth, self.bounds.size.height - topPadding - bottomPadding)];
    _leftPanel.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    [self addSubview:_leftPanel];
    
    // 右侧面板
    _rightPanel = [[UIView alloc] initWithFrame:CGRectMake(leftWidth, topPadding, rightWidth, self.bounds.size.height - topPadding - bottomPadding)];
    _rightPanel.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    [self addSubview:_rightPanel];
    
    [self setupLeftPanel];
    [self setupRightPanel];
}

- (void)setupLeftPanel {
    CGFloat panelWidth = _leftPanel.bounds.size.width;
    CGFloat panelHeight = _leftPanel.bounds.size.height;
    CGFloat sidePadding = 16;
    
    // 顶部标签条 "崩溃界面"
    UIView *labelBar = [[UIView alloc] initWithFrame:CGRectMake(sidePadding, 0, panelWidth - sidePadding * 2, 36)];
    labelBar.backgroundColor = [[UIColor whiteColor] colorWithAlphaComponent:0.15];
    labelBar.layer.cornerRadius = 8;
    [_leftPanel addSubview:labelBar];
    
    UILabel *labelBarText = [[UILabel alloc] initWithFrame:CGRectMake(12, 0, labelBar.bounds.size.width - 24, 36)];
    labelBarText.text = localize(@"crash.interface_title", nil);
    labelBarText.font = [UIFont systemFontOfSize:14 weight:UIFontWeightMedium];
    labelBarText.textColor = [UIColor whiteColor];
    labelBarText.textAlignment = NSTextAlignmentLeft;
    [labelBar addSubview:labelBarText];
    
    // 日志面板（黑色背景）
    CGFloat logTop = 48;
    CGFloat logHeight = panelHeight - logTop;
    _logPanel = [[UIView alloc] initWithFrame:CGRectMake(sidePadding, logTop, panelWidth - sidePadding * 2, logHeight)];
    _logPanel.backgroundColor = [UIColor colorWithWhite:0.08 alpha:1.0];
    _logPanel.layer.cornerRadius = 12;
    _logPanel.layer.masksToBounds = YES;
    [_leftPanel addSubview:_logPanel];
    
    // 日志文本视图
    _logTextView = [[UITextView alloc] initWithFrame:CGRectMake(8, 8, _logPanel.bounds.size.width - 16, _logPanel.bounds.size.height - 16)];
    _logTextView.backgroundColor = [UIColor clearColor];
    _logTextView.textColor = [[UIColor whiteColor] colorWithAlphaComponent:0.85];
    _logTextView.font = [UIFont fontWithName:@"Menlo" size:11];
    _logTextView.editable = NO;
    _logTextView.showsVerticalScrollIndicator = YES;
    _logTextView.indicatorStyle = UIScrollViewIndicatorStyleWhite;
    _logTextView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    [_logPanel addSubview:_logTextView];
    
    // 占位符标签 "日志信息"（日志为空时显示）
    _logPlaceholderLabel = [[UILabel alloc] initWithFrame:_logPanel.bounds];
    _logPlaceholderLabel.text = localize(@"crash.log_info", nil);
    _logPlaceholderLabel.font = [UIFont systemFontOfSize:48 weight:UIFontWeightBold];
    _logPlaceholderLabel.textColor = [[UIColor whiteColor] colorWithAlphaComponent:0.15];
    _logPlaceholderLabel.textAlignment = NSTextAlignmentCenter;
    _logPlaceholderLabel.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    [_logPanel addSubview:_logPlaceholderLabel];
    
    // 加载日志内容
    [self loadLogContent];
}

- (void)setupRightPanel {
    CGFloat panelWidth = _rightPanel.bounds.size.width;
    CGFloat panelHeight = _rightPanel.bounds.size.height;
    CGFloat sidePadding = 12;
    CGFloat cardSpacing = 12;
    
    // 红色错误提示卡片
    _errorCardView = [[UIView alloc] initWithFrame:CGRectMake(sidePadding, 0, panelWidth - sidePadding * 2, 140)];
    _errorCardView.backgroundColor = [UIColor colorWithRed:1.0 green:0.278 blue:0.318 alpha:1.0]; // #FF4757
    _errorCardView.layer.cornerRadius = 12;
    [_rightPanel addSubview:_errorCardView];
    
    // 感叹号图标
    UIImageView *iconView = [[UIImageView alloc] initWithFrame:CGRectMake(_errorCardView.bounds.size.width / 2 - 20, 16, 40, 40)];
    if (@available(iOS 13.0, *)) {
        UIImageSymbolConfiguration *config = [UIImageSymbolConfiguration configurationWithPointSize:32 weight:UIImageSymbolWeightSemibold];
        iconView.image = [UIImage systemImageNamed:@"exclamationmark.triangle.fill" withConfiguration:config];
    }
    iconView.tintColor = [UIColor whiteColor];
    iconView.contentMode = UIViewContentModeScaleAspectFit;
    [_errorCardView addSubview:iconView];
    
    // 错误标题
    UILabel *errorTitle = [[UILabel alloc] initWithFrame:CGRectMake(16, 62, _errorCardView.bounds.size.width - 32, 24)];
    errorTitle.text = localize(@"crash.error_title", nil);
    errorTitle.font = [UIFont boldSystemFontOfSize:15];
    errorTitle.textColor = [UIColor whiteColor];
    errorTitle.textAlignment = NSTextAlignmentCenter;
    [_errorCardView addSubview:errorTitle];
    
    // 错误代码
    UILabel *errorCode = [[UILabel alloc] initWithFrame:CGRectMake(16, 90, _errorCardView.bounds.size.width - 32, 20)];
    errorCode.text = [NSString stringWithFormat:@"%@%d", localize(@"crash.error_code", nil), _exitCode];
    errorCode.font = [UIFont systemFontOfSize:13];
    errorCode.textColor = [[UIColor whiteColor] colorWithAlphaComponent:0.9];
    errorCode.textAlignment = NSTextAlignmentCenter;
    [_errorCardView addSubview:errorCode];
    
    // 可能原因——根据 exitCode 和日志关键词智能识别崩溃类型（OOM/段错误/abort 等）
    UILabel *reasonLabel = [[UILabel alloc] initWithFrame:CGRectMake(16, 112, _errorCardView.bounds.size.width - 32, 20)];
    reasonLabel.text = [self crashReasonText];
    reasonLabel.font = [UIFont systemFontOfSize:12];
    reasonLabel.textColor = [[UIColor whiteColor] colorWithAlphaComponent:0.75];
    reasonLabel.textAlignment = NSTextAlignmentCenter;
    reasonLabel.adjustsFontSizeToFitWidth = YES;
    reasonLabel.numberOfLines = 2;
    [_errorCardView addSubview:reasonLabel];

    // OOM 崩溃时显示针对性建议（提示用户使用 GetMoreRam 解除内存限制）
    if ([self isOOMCrash]) {
        UILabel *oomSuggestionLabel = [[UILabel alloc] initWithFrame:CGRectMake(16, 132, _errorCardView.bounds.size.width - 32, 0)];
        NSString *suggestion = [NSString stringWithFormat:@"%@ %@",
                                localize(@"crash.suggestion", @"建议操作"),
                                localize(@"crash.suggestion.oom", @"iOS 内存限制导致崩溃，建议使用 GetMoreRam (LiveContainer) 解除内存限制后重试")];
        oomSuggestionLabel.text = suggestion;
        oomSuggestionLabel.font = [UIFont systemFontOfSize:10];
        oomSuggestionLabel.textColor = [[UIColor whiteColor] colorWithAlphaComponent:0.6];
        oomSuggestionLabel.textAlignment = NSTextAlignmentCenter;
        oomSuggestionLabel.adjustsFontSizeToFitWidth = YES;
        oomSuggestionLabel.minimumScaleFactor = 0.7;
        oomSuggestionLabel.numberOfLines = 0;
        // 自动计算高度
        CGSize maxSize = CGSizeMake(_errorCardView.bounds.size.width - 32, CGFLOAT_MAX);
        CGRect textRect = [suggestion boundingRectWithSize:maxSize
                                                   options:NSStringDrawingUsesLineFragmentOrigin
                                                attributes:@{NSFontAttributeName: oomSuggestionLabel.font}
                                                   context:nil];
        oomSuggestionLabel.frame = CGRectMake(16, 132, _errorCardView.bounds.size.width - 32, ceil(textRect.size.height));
        [_errorCardView addSubview:oomSuggestionLabel];
        // 扩展 errorCardView 高度以容纳建议文字
        CGRect cardFrame = _errorCardView.frame;
        cardFrame.size.height = 132 + ceil(textRect.size.height) + 12;
        _errorCardView.frame = cardFrame;
    }
    
    // 分享日志按钮（OOM 时下移以避开扩展的错误卡片）
    CGFloat shareBtnTop = _errorCardView.frame.origin.y + _errorCardView.frame.size.height + cardSpacing;
    _shareButton = [self createPrimaryButton:CGRectMake(sidePadding, shareBtnTop, panelWidth - sidePadding * 2, 48)
                                             title:localize(@"crash.share_log", nil)
                                              icon:@"square.and.arrow.up"
                                            action:@selector(shareLog)];
    [_rightPanel addSubview:_shareButton];
    
    // 卡片容器（GitHub Issues 和 AI 解决问题）
    CGFloat cardsTop = shareBtnTop + 48 + cardSpacing;
    CGFloat cardWidth = (panelWidth - sidePadding * 3) / 2;
    CGFloat cardHeight = 80;
    
    // GitHub Issues 卡片
    _githubCard = [self createActionCard:CGRectMake(sidePadding, cardsTop, cardWidth, cardHeight)
                                          title:localize(@"crash.github_issue", nil)
                                      iconName:@"link"
                                     iconColor:[UIColor colorWithRed:0.3 green:0.5 blue:0.9 alpha:1.0]
                                        action:@selector(openGitHubIssues)];
    [_rightPanel addSubview:_githubCard];
    
    // AI 解决问题卡片
    _aiCard = [self createActionCard:CGRectMake(sidePadding * 2 + cardWidth, cardsTop, cardWidth, cardHeight)
                                      title:localize(@"crash.ai_solve", nil)
                                  iconName:@"cpu"
                                 iconColor:[UIColor colorWithRed:0.6 green:0.4 blue:0.9 alpha:1.0]
                                    action:@selector(useAIToSolve)];
    [_rightPanel addSubview:_aiCard];
    
    // 实验性标签
    _experimentalLabel = [[UILabel alloc] initWithFrame:CGRectMake(_aiCard.frame.origin.x + 8, _aiCard.frame.origin.y + 60, cardWidth - 16, 16)];
    _experimentalLabel.text = [NSString stringWithFormat:@"(%@)", localize(@"crash.experimental", nil)];
    _experimentalLabel.font = [UIFont systemFontOfSize:10];
    _experimentalLabel.textColor = [[UIColor whiteColor] colorWithAlphaComponent:0.5];
    _experimentalLabel.textAlignment = NSTextAlignmentRight;
    [_rightPanel addSubview:_experimentalLabel];
    
    // 重启启动器按钮（参照 FCL 的"重启软件"，优先放置，蓝色强调）
    CGFloat restartBtnTop = cardsTop + cardHeight + cardSpacing + 20;
    _restartButton = [self createPrimaryButton:CGRectMake(sidePadding, restartBtnTop, panelWidth - sidePadding * 2, 48)
                                          title:localize(@"crash.restart_launcher", @"重启启动器")
                                           icon:@"arrow.clockwise"
                                         action:@selector(restartLauncherAction)];
    [_rightPanel addSubview:_restartButton];

    // 退出启动器按钮
    CGFloat exitBtnTop = restartBtnTop + 48 + 8;
    _exitButton = [self createSecondaryButton:CGRectMake(sidePadding, exitBtnTop, panelWidth - sidePadding * 2, 48)
                                              title:localize(@"crash.return_launcher", nil)
                                               icon:@"rectangle.portrait.and.arrow.right"
                                             action:@selector(dismissAndReturnToLauncher)];
    [_rightPanel addSubview:_exitButton];
    
    // 查看完整日志按钮（小按钮）
    CGFloat fullLogBtnTop = exitBtnTop + 48 + 8;
    _fullLogButton = [UIButton buttonWithType:UIButtonTypeSystem];
    _fullLogButton.frame = CGRectMake(sidePadding, fullLogBtnTop, panelWidth - sidePadding * 2, 32);
    [_fullLogButton setTitle:localize(@"crash.view_log", nil) forState:UIControlStateNormal];
    _fullLogButton.titleLabel.font = [UIFont systemFontOfSize:13];
    _fullLogButton.tintColor = [[UIColor whiteColor] colorWithAlphaComponent:0.6];
    [_fullLogButton addTarget:self action:@selector(showFullLog) forControlEvents:UIControlEventTouchUpInside];
    [_rightPanel addSubview:_fullLogButton];
}

#pragma mark - Helper Methods

- (UIButton *)createPrimaryButton:(CGRect)frame title:(NSString *)title icon:(NSString *)icon action:(SEL)action {
    UIButton *button = [UIButton buttonWithType:UIButtonTypeSystem];
    button.frame = frame;
    button.backgroundColor = [[UIColor whiteColor] colorWithAlphaComponent:0.15];
    button.layer.cornerRadius = 10;
    
    [button setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
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

- (UIButton *)createSecondaryButton:(CGRect)frame title:(NSString *)title icon:(NSString *)icon action:(SEL)action {
    UIButton *button = [UIButton buttonWithType:UIButtonTypeSystem];
    button.frame = frame;
    button.backgroundColor = [[UIColor whiteColor] colorWithAlphaComponent:0.1];
    button.layer.cornerRadius = 10;
    
    [button setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    button.titleLabel.font = [UIFont systemFontOfSize:15];
    
    if (@available(iOS 13.0, *)) {
        UIImageSymbolConfiguration *config = [UIImageSymbolConfiguration configurationWithPointSize:15 weight:UIFontWeightRegular];
        UIImage *iconImage = [UIImage systemImageNamed:icon withConfiguration:config];
        [button setImage:iconImage forState:UIControlStateNormal];
    }
    
    button.titleEdgeInsets = UIEdgeInsetsMake(0, 8, 0, 0);
    button.imageEdgeInsets = UIEdgeInsetsMake(0, -8, 0, 0);
    [button setTitle:title forState:UIControlStateNormal];
    [button addTarget:self action:action forControlEvents:UIControlEventTouchUpInside];
    
    return button;
}

- (UIView *)createActionCard:(CGRect)frame title:(NSString *)title iconName:(NSString *)iconName iconColor:(UIColor *)iconColor action:(SEL)action {
    UIView *card = [[UIView alloc] initWithFrame:frame];
    card.backgroundColor = [[UIColor whiteColor] colorWithAlphaComponent:0.08];
    card.layer.cornerRadius = 12;
    
    // 添加点击手势
    UITapGestureRecognizer *tapGesture = [[UITapGestureRecognizer alloc] initWithTarget:self action:action];
    [card addGestureRecognizer:tapGesture];
    
    // 图标
    UIImageView *iconView = [[UIImageView alloc] initWithFrame:CGRectMake((card.bounds.size.width - 28) / 2, 14, 28, 28)];
    if (@available(iOS 13.0, *)) {
        UIImageSymbolConfiguration *config = [UIImageSymbolConfiguration configurationWithPointSize:20 weight:UIImageSymbolWeightMedium];
        iconView.image = [UIImage systemImageNamed:iconName withConfiguration:config];
    }
    iconView.tintColor = iconColor;
    iconView.contentMode = UIViewContentModeScaleAspectFit;
    [card addSubview:iconView];
    
    // 标题
    UILabel *titleLabel = [[UILabel alloc] initWithFrame:CGRectMake(8, 46, card.bounds.size.width - 16, 24)];
    titleLabel.text = title;
    titleLabel.font = [UIFont systemFontOfSize:12 weight:UIFontWeightMedium];
    titleLabel.textColor = [UIColor whiteColor];
    titleLabel.textAlignment = NSTextAlignmentCenter;
    titleLabel.numberOfLines = 2;
    titleLabel.adjustsFontSizeToFitWidth = YES;
    [card addSubview:titleLabel];
    
    return card;
}

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

- (void)openGitHubIssues {
    NSURL *url = [NSURL URLWithString:kGitHubIssuesURL];
    if ([[UIApplication sharedApplication] canOpenURL:url]) {
        [[UIApplication sharedApplication] openURL:url options:@{} completionHandler:nil];
    }
}

- (void)useAIToSolve {
    // 获取当前视图控制器
    UIViewController *presentingVC = [self nextViewController];
    if (!presentingVC) {
        presentingVC = currentVC();
    }
    
    // 获取崩溃日志路径
    NSString *logPath = [NSString stringWithFormat:@"%s/latestlog.txt", getenv("POJAV_HOME")];
    
    // 创建 AI 修复界面
    AIFixViewController *aiFixVC = [[AIFixViewController alloc] initWithLogPath:logPath];
    aiFixVC.modalPresentationStyle = UIModalPresentationOverFullScreen;
    
    // 非线性动画展示
    aiFixVC.view.alpha = 0;
    aiFixVC.view.transform = CGAffineTransformMakeScale(0.9, 0.9);
    
    [presentingVC presentViewController:aiFixVC animated:NO completion:^{
        // 使用弹性动画
        [UIView animateWithDuration:0.4 
                              delay:0 
             usingSpringWithDamping:0.8 
              initialSpringVelocity:0.5 
                            options:UIViewAnimationOptionCurveEaseOut 
                         animations:^{
            aiFixVC.view.alpha = 1;
            aiFixVC.view.transform = CGAffineTransformIdentity;
        } completion:nil];
    }];
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
        if (currentCrashView) {
            [currentCrashView dismissAndReturnToLauncher];
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
        if (currentCrashView) {
            [currentCrashView removeFromSuperview];
            currentCrashView = nil;
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
    
    // 重新计算布局
    CGFloat leftWidth = self.bounds.size.width * 0.58;
    CGFloat rightWidth = self.bounds.size.width - leftWidth;
    CGFloat topPadding = 60;
    CGFloat bottomPadding = 40;
    
    _leftPanel.frame = CGRectMake(0, topPadding, leftWidth, self.bounds.size.height - topPadding - bottomPadding);
    _rightPanel.frame = CGRectMake(leftWidth, topPadding, rightWidth, self.bounds.size.height - topPadding - bottomPadding);
    
    // 更新左侧面板内部布局
    CGFloat panelWidth = _leftPanel.bounds.size.width;
    CGFloat panelHeight = _leftPanel.bounds.size.height;
    CGFloat sidePadding = 16;
    
    // 更新标签条
    UIView *labelBar = _leftPanel.subviews.firstObject;
    labelBar.frame = CGRectMake(sidePadding, 0, panelWidth - sidePadding * 2, 36);
    
    // 更新日志面板
    CGFloat logTop = 48;
    _logPanel.frame = CGRectMake(sidePadding, logTop, panelWidth - sidePadding * 2, panelHeight - logTop);
    _logTextView.frame = CGRectMake(8, 8, _logPanel.bounds.size.width - 16, _logPanel.bounds.size.height - 16);
    _logPlaceholderLabel.frame = _logPanel.bounds;
    
    // 更新右侧面板内部布局
    CGFloat rightPanelWidth = _rightPanel.bounds.size.width;
    CGFloat rightSidePadding = 12;
    CGFloat cardSpacing = 12;
    
    // 更新错误卡片
    _errorCardView.frame = CGRectMake(rightSidePadding, 0, rightPanelWidth - rightSidePadding * 2, 140);
    
    // 更新错误卡片内部元素
    for (UIView *subview in _errorCardView.subviews) {
        if ([subview isKindOfClass:[UIImageView class]]) {
            subview.center = CGPointMake(_errorCardView.bounds.size.width / 2, 36);
        } else if ([subview isKindOfClass:[UILabel class]]) {
            UILabel *label = (UILabel *)subview;
            label.frame = CGRectMake(16, label.frame.origin.y, _errorCardView.bounds.size.width - 32, label.frame.size.height);
        }
    }
    
    // 更新按钮和卡片位置
    CGFloat currentY = 156;
    CGFloat cardWidth = (rightPanelWidth - rightSidePadding * 3) / 2;
    CGFloat cardHeight = 80;
    
    // 分享日志按钮
    if (_shareButton) {
        _shareButton.frame = CGRectMake(rightSidePadding, currentY, rightPanelWidth - rightSidePadding * 2, 48);
        currentY += 48 + cardSpacing;
    }
    
    // GitHub 卡片
    if (_githubCard) {
        _githubCard.frame = CGRectMake(rightSidePadding, currentY, cardWidth, cardHeight);
        // 更新卡片内部图标位置
        for (UIView *cardSubview in _githubCard.subviews) {
            if ([cardSubview isKindOfClass:[UIImageView class]]) {
                cardSubview.center = CGPointMake(_githubCard.bounds.size.width / 2, 28);
            } else if ([cardSubview isKindOfClass:[UILabel class]]) {
                UILabel *label = (UILabel *)cardSubview;
                label.frame = CGRectMake(8, 46, _githubCard.bounds.size.width - 16, 24);
            }
        }
    }
    
    // AI 卡片
    if (_aiCard) {
        _aiCard.frame = CGRectMake(rightSidePadding * 2 + cardWidth, currentY, cardWidth, cardHeight);
        // 更新卡片内部图标位置
        for (UIView *cardSubview in _aiCard.subviews) {
            if ([cardSubview isKindOfClass:[UIImageView class]]) {
                cardSubview.center = CGPointMake(_aiCard.bounds.size.width / 2, 28);
            } else if ([cardSubview isKindOfClass:[UILabel class]]) {
                UILabel *label = (UILabel *)cardSubview;
                label.frame = CGRectMake(8, 46, _aiCard.bounds.size.width - 16, 24);
            }
        }
    }
    
    currentY += cardHeight + cardSpacing;
    
    // 实验性标签
    if (_experimentalLabel) {
        _experimentalLabel.frame = CGRectMake(rightSidePadding * 2 + cardWidth + 8, currentY - cardSpacing - 16, cardWidth - 16, 16);
    }
    
    currentY += 20; // 添加间距

    // 重启启动器按钮（FCL 风格，位于退出按钮上方）
    if (_restartButton) {
        _restartButton.frame = CGRectMake(rightSidePadding, currentY, rightPanelWidth - rightSidePadding * 2, 48);
        currentY += 48 + 8;
    }

    // 退出启动器按钮
    if (_exitButton) {
        _exitButton.frame = CGRectMake(rightSidePadding, currentY, rightPanelWidth - rightSidePadding * 2, 48);
        currentY += 48 + 8;
    }

    // 查看完整日志按钮
    if (_fullLogButton) {
        _fullLogButton.frame = CGRectMake(rightSidePadding, currentY, rightPanelWidth - rightSidePadding * 2, 32);
    }
}

@end