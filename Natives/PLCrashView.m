#import "PLCrashView.h"
#import "PLLogOutputView.h"
#import "SurfaceViewController.h"
#import "ios_uikit_bridge.h"
#import "utils.h"
#import "BackgroundManager.h"

@interface PLCrashView ()
// Data
@property (nonatomic, assign) int exitCode;
@property (nonatomic, copy) NSString *customTitle;
@property (nonatomic, copy) NSString *customReason;

// Crash type analysis (following the HMCL crash analyzer, for more precise classification and advice)
typedef NS_ENUM(NSInteger, CrashType) {
    CrashTypeNormal = 0,         // Exited normally
    CrashTypeOOM,                // Out of memory
    CrashTypeSegfault,           // Segmentation fault (JNI/a native library)
    CrashTypeAbort,              // The program aborted
    CrashTypeTerminated,         // Terminated by an external signal
    CrashTypeModConflict,        // A mod conflict
    CrashTypeMissingLibrary,     // A missing library file
    CrashTypeUnsignedDylib,      // iOS refused to load a .dylib a mod extracted at runtime
    CrashTypeJavaVersionMismatch,// A Java version mismatch
    CrashTypeRendererError,      // A renderer error
    CrashTypeGraphicsMemoryPressure, // The graphics driver crashed because the device ran out of memory
    CrashTypeModLoadingFailure,  // A mod failed to load
    CrashTypeJavaException,      // A Java exception
    CrashTypeUnknown             // An unknown error
};
@property (nonatomic, assign) CrashType crashType;
@property (nonatomic, strong, nullable) NSString *crashDetail; // Crash details (the key lines extracted from the log)

// UI components
@property (nonatomic, strong) UIScrollView *mainScrollView;
@property (nonatomic, strong) UIStackView *mainStackView;
@property (nonatomic, strong) UIView *errorCardView;
@property (nonatomic, strong) UIImageView *errorIconView;
@property (nonatomic, strong) UILabel *errorTitleLabel;
@property (nonatomic, strong) UILabel *errorCodeLabel;
@property (nonatomic, strong) UILabel *reasonLabel;
@property (nonatomic, strong) UILabel *oomSuggestionLabel;
// The quick fix card (following the "quick fix" panel of FCL/HMCL)
@property (nonatomic, strong) UIView *suggestionsCardView;
@property (nonatomic, strong) UILabel *suggestionsTitleLabel;
@property (nonatomic, strong) UIStackView *suggestionsStackView;
@property (nonatomic, strong) UIView *logCardView;
@property (nonatomic, strong) UILabel *logTitleLabel;
@property (nonatomic, strong) UITextView *logTextView;
@property (nonatomic, strong) UILabel *logPlaceholderLabel;
@property (nonatomic, strong) UIButton *restartButton;
@property (nonatomic, strong) UIButton *shareButton;
@property (nonatomic, strong) UIButton *githubButton;
@property (nonatomic, strong) UIButton *fullLogButton;
@property (nonatomic, strong) UIButton *exitButton;
// The red accent bar at the top of the error card
@property (nonatomic, strong) CAGradientLayer *accentGradientLayer;
// The yellow accent bar at the top of the suggestion card
@property (nonatomic, strong) CAGradientLayer *suggestionAccentLayer;
// The log card height constraint (adjusted dynamically from the screen height)
@property (nonatomic, strong) NSLayoutConstraint *logCardHeightConstraint;
@end

@implementation PLCrashView

// The crash VC instance currently on screen (a singleton)
static PLCrashView *currentCrashVC = nil;
static NSString *const kGitHubIssuesURL = @"https://github.com/weecritikal/Air-Launcher-English-Translation/issues";

#pragma mark - Public Methods

+ (void)showWithExitCode:(int)exitCode {
    [self showWithExitCode:exitCode customTitle:nil customReason:nil];
}

+ (void)showWithExitCode:(int)exitCode customTitle:(NSString *)customTitle customReason:(NSString *)customReason {
    dispatch_async(dispatch_get_main_queue(), ^{
        // If a crash screen already exists, dismiss it first so they do not stack
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

        // Find the topmost presented VC to present the crash screen from.
        // The old implementation added a UIView straight onto keyWindow, so nothing managed its lifecycle
        // and it did not follow rotation or the safe area. As a UIViewController, the system manages its lifecycle.
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
    // Analyze the crash type first, since the suggestion card in setupUI depends on the result
    [self analyzeCrashType];
    [self setupUI];
    [self loadLogContent];
}

- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    // Adjust the log card height from the screen height, so buttons are not squeezed on a small screen and space is not wasted on a large one
    [self adjustLogCardHeight];
    // Update the frame of the red accent bar at the top of the error card
    if (_accentGradientLayer) {
        _accentGradientLayer.frame = CGRectMake(0, 0, _errorCardView.bounds.size.width, 2);
    }
    // Update the frame of the yellow accent bar at the top of the suggestion card
    if (_suggestionAccentLayer && _suggestionsCardView) {
        _suggestionAccentLayer.frame = CGRectMake(0, 0, _suggestionsCardView.bounds.size.width, 2);
    }
}

#pragma mark - Background

- (void)setupBackground {
    // Adapt to the custom background wallpaper: let the global background from BackgroundManager show through
    [[BackgroundManager sharedManager] makeViewControllerTransparent:self];
    self.view.backgroundColor = [UIColor clearColor];

    // With no custom background, fall back to a system material blur (which adapts to light/dark)
    if (![[BackgroundManager sharedManager] hasBackground]) {
        UIBlurEffect *blurEffect;
        if (@available(iOS 13.0, *)) {
            blurEffect = [UIBlurEffect effectWithStyle:UIBlurEffectStyleSystemMaterial];
        } else {
            blurEffect = [UIBlurEffect effectWithStyle:UIBlurEffectStyleLight];
        }
        UIVisualEffectView *blurView = [[UIVisualEffectView alloc] initWithEffect:blurEffect];
        blurView.translatesAutoresizingMaskIntoConstraints = NO;
        [self.view addSubview:blurView];
        [self.view sendSubviewToBack:blurView];

        [NSLayoutConstraint activateConstraints:@[
            [blurView.topAnchor constraintEqualToAnchor:self.view.topAnchor],
            [blurView.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor],
            [blurView.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
            [blurView.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        ]];
    }
}

#pragma mark - UI Setup

- (void)setupUI {
    // ============================================================
    // The FCL-style crash screen: a large log box on the left with a button column on the right
    // ============================================================
    // Following the crash screen layout of FCL (FoldCraftLauncher):
    //   - top: a compact error card (icon + title + error code)
    //   - below, split horizontally:
    //     - left (about 65% of the width): a large log text box showing the crash log
    //     - right (about 35% of the width): a vertical column of buttons
    //       - Restart launcher (highlighted in blue)
    //       - Quit launcher (quits the process without restarting)
    //       - Share log
    //       - Open GitHub Issues
    //       - View the full log
    //
    // Key fix: "Restart launcher" and "Quit launcher" used to do the same thing
    // (both returned to the launcher main screen). They are now clearly different:
    //   - Restart launcher: exit(0) + openURL to relaunch the app (restarting the whole launcher)
    //   - Quit launcher: exit(0) to quit the process outright (without restarting)

    // The main scroll view (scrollable when the content is taller than the screen)
    _mainScrollView = [[UIScrollView alloc] init];
    _mainScrollView.translatesAutoresizingMaskIntoConstraints = NO;
    _mainScrollView.alwaysBounceVertical = YES;
    _mainScrollView.showsVerticalScrollIndicator = YES;
    _mainScrollView.indicatorStyle = UIScrollViewIndicatorStyleWhite;
    _mainScrollView.contentInsetAdjustmentBehavior = UIScrollViewContentInsetAdjustmentNever;
    [self.view addSubview:_mainScrollView];

    // The main vertical StackView (the error card + the horizontal split)
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

    // Margins on each side of the StackView
    _mainStackView.layoutMargins = UIEdgeInsetsMake(16, 20, 16, 20);
    _mainStackView.layoutMarginsRelativeArrangement = YES;

    // 1. The error card (at the top)
    [self setupErrorCard];

    // 2. The quick fix card (optional, shown only when there are suggestions)
    [self setupSuggestionsCard];

    // 3. The horizontal split container: the log on the left, the buttons on the right
    UIStackView *horizontalSplit = [[UIStackView alloc] init];
    horizontalSplit.axis = UILayoutConstraintAxisHorizontal;
    horizontalSplit.spacing = 12;
    horizontalSplit.alignment = UIStackViewAlignmentFill;
    horizontalSplit.distribution = UIStackViewDistributionFill;
    horizontalSplit.translatesAutoresizingMaskIntoConstraints = NO;
    [_mainStackView addArrangedSubview:horizontalSplit];

    // 3a. Left: the log card
    [self setupLogCard];
    // Add the log card to the left of the horizontal split
    [horizontalSplit addArrangedSubview:_logCardView];

    // 3b. Right: the button column container
    UIStackView *buttonColumn = [[UIStackView alloc] init];
    buttonColumn.axis = UILayoutConstraintAxisVertical;
    buttonColumn.spacing = 10;
    buttonColumn.alignment = UIStackViewAlignmentFill;
    buttonColumn.distribution = UIStackViewDistributionFillEqually;
    buttonColumn.translatesAutoresizingMaskIntoConstraints = NO;
    [horizontalSplit addArrangedSubview:buttonColumn];

    // Give the log card on the left about 65% of the width and the button column on the right about 35%
    NSLayoutConstraint *logWidthConstraint = [_logCardView.widthAnchor constraintEqualToAnchor:horizontalSplit.widthAnchor multiplier:0.65];
    logWidthConstraint.priority = UILayoutPriorityDefaultHigh;
    logWidthConstraint.active = YES;

    // A minimum width for the button column (so the button text is not truncated)
    [buttonColumn.widthAnchor constraintGreaterThanOrEqualToConstant:140].active = YES;

    // 4. Create the buttons and add them to the column on the right
    [self setupButtonsIntoContainer:buttonColumn];
}

- (void)setupErrorCard {
    _errorCardView = [[UIView alloc] init];
    _errorCardView.backgroundColor = [[UIColor whiteColor] colorWithAlphaComponent:0.08];
    _errorCardView.layer.cornerRadius = 16;
    _errorCardView.layer.cornerCurve = kCACornerCurveContinuous;
    _errorCardView.layer.borderWidth = 0.5;
    _errorCardView.layer.borderColor = [[UIColor whiteColor] colorWithAlphaComponent:0.10].CGColor;
    _errorCardView.layer.shadowColor = [UIColor blackColor].CGColor;
    _errorCardView.layer.shadowOffset = CGSizeMake(0, 4);
    _errorCardView.layer.shadowOpacity = 0.12;
    _errorCardView.layer.shadowRadius = 8;
    _errorCardView.translatesAutoresizingMaskIntoConstraints = NO;
    [_mainStackView addArrangedSubview:_errorCardView];
    // Apply the frosted-glass effect (adapting to the custom background wallpaper)
    [[BackgroundManager sharedManager] applyEffectToView:_errorCardView];

    // The red accent bar at the top (a 2pt gradient layer, from red to transparent)
    _accentGradientLayer = [CAGradientLayer layer];
    _accentGradientLayer.colors = @[
        (__bridge id)[UIColor systemRedColor].CGColor,
        (__bridge id)[[UIColor systemRedColor] colorWithAlphaComponent:0].CGColor,
    ];
    _accentGradientLayer.locations = @[@0.0, @1.0];
    _accentGradientLayer.startPoint = CGPointMake(0.5, 0.0);
    _accentGradientLayer.endPoint = CGPointMake(0.5, 1.0);
    _accentGradientLayer.cornerRadius = 16;
    _accentGradientLayer.maskedCorners = kCALayerMinXMinYCorner | kCALayerMaxXMinYCorner;
    [_errorCardView.layer addSublayer:_accentGradientLayer];

    // Error icon
    _errorIconView = [[UIImageView alloc] init];
    _errorIconView.translatesAutoresizingMaskIntoConstraints = NO;
    if (@available(iOS 13.0, *)) {
        UIImageSymbolConfiguration *config = [UIImageSymbolConfiguration configurationWithPointSize:36 weight:UIImageSymbolWeightBold];
        _errorIconView.image = [UIImage systemImageNamed:@"exclamationmark.triangle.fill" withConfiguration:config];
    }
    _errorIconView.tintColor = [UIColor systemRedColor];
    _errorIconView.contentMode = UIViewContentModeScaleAspectFit;
    [_errorCardView addSubview:_errorIconView];

    // Error title
    _errorTitleLabel = [[UILabel alloc] init];
    _errorTitleLabel.translatesAutoresizingMaskIntoConstraints = NO;
    _errorTitleLabel.text = _customTitle ?: localize(@"crash.error_title", nil);
    _errorTitleLabel.font = [UIFont boldSystemFontOfSize:18];
    _errorTitleLabel.textColor = [UIColor labelColor];
    _errorTitleLabel.textAlignment = NSTextAlignmentCenter;
    _errorTitleLabel.numberOfLines = 0;
    [_errorCardView addSubview:_errorTitleLabel];

    // Error code
    _errorCodeLabel = [[UILabel alloc] init];
    _errorCodeLabel.translatesAutoresizingMaskIntoConstraints = NO;
    _errorCodeLabel.text = [NSString stringWithFormat:@"%@%d", localize(@"crash.error_code", nil), _exitCode];
    _errorCodeLabel.font = [UIFont systemFontOfSize:14];
    _errorCodeLabel.textColor = [UIColor secondaryLabelColor];
    _errorCodeLabel.textAlignment = NSTextAlignmentCenter;
    [_errorCardView addSubview:_errorCodeLabel];

    // Possible causes
    _reasonLabel = [[UILabel alloc] init];
    _reasonLabel.translatesAutoresizingMaskIntoConstraints = NO;
    _reasonLabel.text = [self crashReasonText];
    _reasonLabel.font = [UIFont systemFontOfSize:13];
    _reasonLabel.textColor = [UIColor secondaryLabelColor];
    _reasonLabel.textAlignment = NSTextAlignmentCenter;
    _reasonLabel.numberOfLines = 0;
    [_errorCardView addSubview:_reasonLabel];

    // The shared constraints (icon/title/code/reason)
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

    // On an OOM crash the suggestion label is shown, so the bottom of errorCardView is anchored to the bottom of oomSuggestionLabel
    if ([self isOOMCrash]) {
        _oomSuggestionLabel = [[UILabel alloc] init];
        _oomSuggestionLabel.translatesAutoresizingMaskIntoConstraints = NO;
        _oomSuggestionLabel.font = [UIFont systemFontOfSize:12];
        _oomSuggestionLabel.textColor = [UIColor secondaryLabelColor];
        _oomSuggestionLabel.textAlignment = NSTextAlignmentCenter;
        _oomSuggestionLabel.numberOfLines = 0;
        NSString *suggestion = [NSString stringWithFormat:@"%@ %@",
                                localize(@"crash.suggestion", @"Suggested actions"),
                                localize(@"crash.suggestion.oom", @"The iOS memory limit caused the crash. Try lifting the limit with GetMoreRam (LiveContainer) and run it again")];
        _oomSuggestionLabel.text = suggestion;
        [_errorCardView addSubview:_oomSuggestionLabel];

        [constraints addObjectsFromArray:@[
            [_oomSuggestionLabel.topAnchor constraintEqualToAnchor:_reasonLabel.bottomAnchor constant:8],
            [_oomSuggestionLabel.leadingAnchor constraintEqualToAnchor:_errorCardView.leadingAnchor constant:16],
            [_oomSuggestionLabel.trailingAnchor constraintEqualToAnchor:_errorCardView.trailingAnchor constant:-16],
            [_oomSuggestionLabel.bottomAnchor constraintEqualToAnchor:_errorCardView.bottomAnchor constant:-16],
        ]];
    } else {
        // Otherwise the bottom of errorCardView is anchored directly to the bottom of reasonLabel
        [constraints addObject:[_reasonLabel.bottomAnchor constraintEqualToAnchor:_errorCardView.bottomAnchor constant:-16]];
    }

    [NSLayoutConstraint activateConstraints:constraints];
}

#pragma mark - Suggestions Card (quick fix suggestion card)

/// Build the quick fix card (following the "quick fix" panel of FCL/HMCL)
///
/// It shows the fixes matching the crash type analyzeCrashType found:
/// - OOM: lower the memory allocation, remove heavy mods, use GetMoreRam
/// - Segfault: switch renderer, check native library compatibility
/// - ModConflict: remove recently added mods, check mod compatibility
/// - MissingLibrary: reinstall the game version, check the library files
/// - JavaVersionMismatch: switch Java version
/// - RendererError: switch renderer, disable shaders
/// - ModLoadingFailure: check the mod loader version, remove the problem mod
///
/// Each suggestion is one line of text with an icon, and tapping it copies it to the clipboard.
- (void)setupSuggestionsCard {
    // Get the suggestions for the current crash type
    NSArray<NSDictionary *> *suggestions = [self suggestionsForCrashType];
    if (suggestions.count == 0) return; // With no suggestions, the card is not shown

    _suggestionsCardView = [[UIView alloc] init];
    _suggestionsCardView.backgroundColor = [[UIColor whiteColor] colorWithAlphaComponent:0.06];
    _suggestionsCardView.layer.cornerRadius = 16;
    _suggestionsCardView.layer.cornerCurve = kCACornerCurveContinuous;
    _suggestionsCardView.layer.borderWidth = 0.5;
    _suggestionsCardView.layer.borderColor = [[UIColor whiteColor] colorWithAlphaComponent:0.10].CGColor;
    _suggestionsCardView.translatesAutoresizingMaskIntoConstraints = NO;
    [_mainStackView addArrangedSubview:_suggestionsCardView];
    // Apply the frosted-glass effect (adapting to the custom background wallpaper)
    [[BackgroundManager sharedManager] applyEffectToView:_suggestionsCardView];

    // The yellow accent bar at the top (advisory rather than fatal)
    CAGradientLayer *suggestionAccent = [CAGradientLayer layer];
    suggestionAccent.colors = @[
        (__bridge id)[UIColor systemYellowColor].CGColor,
        (__bridge id)[[UIColor systemYellowColor] colorWithAlphaComponent:0].CGColor,
    ];
    suggestionAccent.locations = @[@0.0, @1.0];
    suggestionAccent.startPoint = CGPointMake(0.5, 0.0);
    suggestionAccent.endPoint = CGPointMake(0.5, 1.0);
    suggestionAccent.cornerRadius = 16;
    suggestionAccent.maskedCorners = kCALayerMinXMinYCorner | kCALayerMaxXMinYCorner;
    [_suggestionsCardView.layer addSublayer:suggestionAccent];
    self.suggestionAccentLayer = suggestionAccent;
    // The accent bar frame is set in viewDidLayoutSubviews

    // The title row: an icon plus "Quick fixes"
    UIView *titleRow = [[UIView alloc] init];
    titleRow.translatesAutoresizingMaskIntoConstraints = NO;
    [_suggestionsCardView addSubview:titleRow];

    UIImageView *titleIcon = [[UIImageView alloc] init];
    titleIcon.translatesAutoresizingMaskIntoConstraints = NO;
    if (@available(iOS 13.0, *)) {
        UIImageSymbolConfiguration *config = [UIImageSymbolConfiguration configurationWithPointSize:16 weight:UIImageSymbolWeightSemibold];
        titleIcon.image = [UIImage systemImageNamed:@"lightbulb.fill" withConfiguration:config];
    }
    titleIcon.tintColor = [UIColor systemYellowColor];
    titleIcon.contentMode = UIViewContentModeScaleAspectFit;
    [titleRow addSubview:titleIcon];

    _suggestionsTitleLabel = [[UILabel alloc] init];
    _suggestionsTitleLabel.translatesAutoresizingMaskIntoConstraints = NO;
    _suggestionsTitleLabel.text = localize(@"crash.quick_fix", @"Quick fixes");
    _suggestionsTitleLabel.font = [UIFont systemFontOfSize:15 weight:UIFontWeightSemibold];
    _suggestionsTitleLabel.textColor = [UIColor labelColor];
    [titleRow addSubview:_suggestionsTitleLabel];

    // The suggestion list (a vertical StackView)
    _suggestionsStackView = [[UIStackView alloc] init];
    _suggestionsStackView.axis = UILayoutConstraintAxisVertical;
    _suggestionsStackView.spacing = 8;
    _suggestionsStackView.alignment = UIStackViewAlignmentFill;
    _suggestionsStackView.distribution = UIStackViewDistributionFill;
    _suggestionsStackView.translatesAutoresizingMaskIntoConstraints = NO;
    [_suggestionsCardView addSubview:_suggestionsStackView];

    // Build one row per suggestion
    for (NSDictionary *suggestion in suggestions) {
        NSString *icon = suggestion[@"icon"];
        NSString *text = suggestion[@"text"];
        UIView *row = [self createSuggestionRowWithIcon:icon text:text];
        [_suggestionsStackView addArrangedSubview:row];
    }

    // Layout constraints
    [NSLayoutConstraint activateConstraints:@[
        [titleRow.topAnchor constraintEqualToAnchor:_suggestionsCardView.topAnchor constant:14],
        [titleRow.leadingAnchor constraintEqualToAnchor:_suggestionsCardView.leadingAnchor constant:16],
        [titleRow.trailingAnchor constraintEqualToAnchor:_suggestionsCardView.trailingAnchor constant:-16],
        [titleRow.heightAnchor constraintEqualToConstant:22],

        [titleIcon.leadingAnchor constraintEqualToAnchor:titleRow.leadingAnchor],
        [titleIcon.centerYAnchor constraintEqualToAnchor:titleRow.centerYAnchor],
        [titleIcon.widthAnchor constraintEqualToConstant:18],
        [titleIcon.heightAnchor constraintEqualToConstant:18],

        [_suggestionsTitleLabel.leadingAnchor constraintEqualToAnchor:titleIcon.trailingAnchor constant:8],
        [_suggestionsTitleLabel.centerYAnchor constraintEqualToAnchor:titleRow.centerYAnchor],
        [_suggestionsTitleLabel.trailingAnchor constraintEqualToAnchor:titleRow.trailingAnchor],

        [_suggestionsStackView.topAnchor constraintEqualToAnchor:titleRow.bottomAnchor constant:12],
        [_suggestionsStackView.leadingAnchor constraintEqualToAnchor:_suggestionsCardView.leadingAnchor constant:16],
        [_suggestionsStackView.trailingAnchor constraintEqualToAnchor:_suggestionsCardView.trailingAnchor constant:-16],
        [_suggestionsStackView.bottomAnchor constraintEqualToAnchor:_suggestionsCardView.bottomAnchor constant:-14],
    ]];
}

/// Build one suggestion row (an icon plus text)
- (UIView *)createSuggestionRowWithIcon:(NSString *)iconName text:(NSString *)text {
    UIView *row = [[UIView alloc] init];
    row.translatesAutoresizingMaskIntoConstraints = NO;

    UIImageView *icon = [[UIImageView alloc] init];
    icon.translatesAutoresizingMaskIntoConstraints = NO;
    if (@available(iOS 13.0, *)) {
        UIImageSymbolConfiguration *config = [UIImageSymbolConfiguration configurationWithPointSize:13 weight:UIImageSymbolWeightRegular];
        icon.image = [UIImage systemImageNamed:iconName withConfiguration:config] ?: [UIImage systemImageNamed:@"chevron.right.circle" withConfiguration:config];
    }
    icon.tintColor = [UIColor systemYellowColor];
    icon.contentMode = UIViewContentModeScaleAspectFit;
    [row addSubview:icon];

    UILabel *label = [[UILabel alloc] init];
    label.translatesAutoresizingMaskIntoConstraints = NO;
    label.text = text;
    label.font = [UIFont systemFontOfSize:13];
    label.textColor = [UIColor secondaryLabelColor];
    label.numberOfLines = 0;
    [row addSubview:label];

    [NSLayoutConstraint activateConstraints:@[
        [icon.leadingAnchor constraintEqualToAnchor:row.leadingAnchor],
        [icon.topAnchor constraintEqualToAnchor:row.topAnchor constant:2],
        [icon.widthAnchor constraintEqualToConstant:16],
        [icon.heightAnchor constraintEqualToConstant:16],

        [label.leadingAnchor constraintEqualToAnchor:icon.trailingAnchor constant:8],
        [label.topAnchor constraintEqualToAnchor:row.topAnchor],
        [label.trailingAnchor constraintEqualToAnchor:row.trailingAnchor],
        [label.bottomAnchor constraintEqualToAnchor:row.bottomAnchor],
    ]];

    return row;
}

/// Return the list of fixes for a crash type
- (NSArray<NSDictionary *> *)suggestionsForCrashType {
    NSMutableArray *result = [NSMutableArray array];

    switch (self.crashType) {
        case CrashTypeOOM:
            [result addObject:@{@"icon": @"arrow.down.circle", @"text": localize(@"crash.suggestion.oom_ram", @"Lower the memory allocation (1024-2048 MB recommended)")}];
            [result addObject:@{@"icon": @"sparkles", @"text": localize(@"crash.suggestion.oom_getmoream", @"Use GetMoreRam (LiveContainer) to lift the iOS memory limit")}];
            [result addObject:@{@"icon": @"trash", @"text": localize(@"crash.suggestion.oom_mods", @"Remove heavy mods (shaders, high-res textures, etc.)")}];
            [result addObject:@{@"icon": @"arrow.clockwise", @"text": localize(@"crash.suggestion.oom_restart", @"Restart the launcher and try again (to clear memory fragmentation)")}];
            break;
        case CrashTypeSegfault:
            [result addObject:@{@"icon": @"cpu", @"text": localize(@"crash.suggestion.segfault_renderer", @"Try a different renderer (gl4es / MetalGlues / virgil)")}];
            [result addObject:@{@"icon": @"shield", @"text": localize(@"crash.suggestion.segfault_jit", @"Make sure JIT is enabled (TrollStore/SideStore + JIT permission)")}];
            [result addObject:@{@"icon": @"arrow.clockwise", @"text": localize(@"crash.suggestion.segfault_restart", @"Restart the launcher and try again")}];
            break;
        case CrashTypeAbort:
            [result addObject:@{@"icon": @"exclamationmark.bubble", @"text": localize(@"crash.suggestion.abort_mods", @"Check that your mods are compatible (remove recently added ones)")}];
            [result addObject:@{@"icon": @"cpu", @"text": localize(@"crash.suggestion.abort_renderer", @"Try a different renderer")}];
            [result addObject:@{@"icon": @"arrow.clockwise", @"text": localize(@"crash.suggestion.abort_restart", @"Restart the launcher and try again")}];
            break;
        case CrashTypeModConflict:
            [result addObject:@{@"icon": @"trash", @"text": localize(@"crash.suggestion.modconflict_remove", @"Remove recently added mods")}];
            [result addObject:@{@"icon": @"info.circle", @"text": localize(@"crash.suggestion.modconflict_check", @"Check mod version compatibility (Forge/Fabric/API versions)")}];
            [result addObject:@{@"icon": @"doc.text", @"text": localize(@"crash.suggestion.modconflict_log", @"Read the full log to find the conflicting mod")}];
            break;
        case CrashTypeUnsignedDylib:
            [result addObject:@{@"icon": @"app.connected.to.app.below.fill", @"text": localize(@"crash.suggestion.dylib_attached", @"Settings -> Debug: turn on \"Use Universal StikDebug Script\", then \"Keep attached to StikDebug\"")}];
            [result addObject:@{@"icon": @"pip", @"text": localize(@"crash.suggestion.dylib_pip", @"Leave StikDebug's Picture-in-Picture window open while you play - closing it detaches the debugger")}];
            [result addObject:@{@"icon": @"trash", @"text": localize(@"crash.suggestion.dylib_mod", @"If it still crashes, remove the mod named in the message - it needs a native library iOS will not load")}];
            break;

        case CrashTypeMissingLibrary:
            [result addObject:@{@"icon": @"arrow.clockwise.circle", @"text": localize(@"crash.suggestion.missinglib_reinstall", @"Reinstall the current game version")}];
            [result addObject:@{@"icon": @"folder", @"text": localize(@"crash.suggestion.missinglib_check", @"Check that the libraries folder in the instance directory is complete")}];
            [result addObject:@{@"icon": @"wifi", @"text": localize(@"crash.suggestion.missinglib_network", @"Check your network connection and make sure the download source is reachable")}];
            break;
        case CrashTypeJavaVersionMismatch:
            [result addObject:@{@"icon": @"hammer", @"text": localize(@"crash.suggestion.javaver_change", @"Switch the Java version in Settings (8/17/21)")}];
            [result addObject:@{@"icon": @"info.circle", @"text": localize(@"crash.suggestion.javaver_check", @"Check which Java version this game version requires")}];
            break;
        case CrashTypeRendererError:
            [result addObject:@{@"icon": @"cpu", @"text": localize(@"crash.suggestion.renderer_switch", @"Try a different renderer: gl4es / MetalGlues / virgil")}];
            [result addObject:@{@"icon": @"eye.slash", @"text": localize(@"crash.suggestion.renderer_shader", @"Disable your shader pack and try again")}];
            [result addObject:@{@"icon": @"arrow.down.circle", @"text": localize(@"crash.suggestion.renderer_resolution", @"Lower the game's resolution scale")}];
            break;
        case CrashTypeGraphicsMemoryPressure:
            // Ordered by how much memory each one actually gives back on a large pack.
            [result addObject:@{@"icon": @"square.grid.3x3", @"text": localize(@"crash.suggestion.gfxmem_distance", @"Lower the render distance to 6-8 chunks and the simulation distance to 5. This frees more memory than anything else you can change.")}];
            [result addObject:@{@"icon": @"iphone", @"text": localize(@"crash.suggestion.gfxmem_apps", @"Close your other apps and restart the launcher, so the whole device is not already short of memory")}];
            [result addObject:@{@"icon": @"map", @"text": localize(@"crash.suggestion.gfxmem_mods", @"Remove minimap mods and recipe viewers (JourneyMap, Xaero's, JEI, EMI). They hold on to the most memory in a large pack.")}];
            [result addObject:@{@"icon": @"eye.slash", @"text": localize(@"crash.suggestion.gfxmem_shaders", @"Turn off shaders and lower the resolution scale")}];
            [result addObject:@{@"icon": @"slider.horizontal.3", @"text": localize(@"crash.suggestion.gfxmem_ram", @"Raise Settings > Java > Memory allocation only if it is below 2048 MB. Setting it higher than the device can spare makes iOS kill the game instead.")}];
            break;
        case CrashTypeModLoadingFailure:
            [result addObject:@{@"icon": @"trash", @"text": localize(@"crash.suggestion.modload_remove", @"Remove the problem mod (see the error lines in the log)")}];
            [result addObject:@{@"icon": @"arrow.clockwise.circle", @"text": localize(@"crash.suggestion.modload_update", @"Update the mod loader (Forge/Fabric/OptiFine)")}];
            [result addObject:@{@"icon": @"info.circle", @"text": localize(@"crash.suggestion.modload_version", @"Check that the mod supports your Minecraft version")}];
            break;
        case CrashTypeJavaException:
            [result addObject:@{@"icon": @"doc.text", @"text": localize(@"crash.suggestion.java_log", @"Read the full log to find the exception stack trace")}];
            [result addObject:@{@"icon": @"trash", @"text": localize(@"crash.suggestion.java_mods", @"Check that your mods are compatible (remove recently added ones)")}];
            [result addObject:@{@"icon": @"arrow.clockwise", @"text": localize(@"crash.suggestion.java_restart", @"Restart the launcher and try again")}];
            break;
        case CrashTypeNormal:
        case CrashTypeTerminated:
        case CrashTypeUnknown:
            // These types show no suggestion card
            break;
    }

    return result;
}

#pragma mark - Crash Type Analysis (modeled on HMCL)

/// Analyze the crash type (from the exitCode and log keywords)
///
/// Following the HMCL crash analyzer, the exitCode and the exception keywords in the log
/// classify the crash as OOM / segfault / mod conflict / missing library / Java version mismatch / renderer error and so on.
/// The result is used to:
/// 1. show a more precise cause on the error card
/// 2. show the matching fixes on the suggestion card
- (void)analyzeCrashType {
    NSString *logContent = [self readLatestLogForAnalysis];
    NSString *lowerLog = logContent.length > 0 ? [logContent lowercaseString] : @"";

    // 1. Exited normally
    if (_exitCode == 0) {
        self.crashType = CrashTypeNormal;
        self.crashDetail = nil;
        return;
    }

    // 2. A .dylib a mod extracted at runtime that iOS refused to load.
    //    Checked ahead of everything else because it surfaces as an UnsatisfiedLinkError too, and
    //    the generic "reinstall the game version" advice for that is a long dead end here - no
    //    reinstall can help, the file is rejected for how it is signed, not for being absent.
    if ([lowerLog containsString:@"code signature invalid"] ||
        ([lowerLog containsString:@"code signature"] && [lowerLog containsString:@"dylib"])) {
        self.crashType = CrashTypeUnsignedDylib;
        self.crashDetail = [self extractLineContaining:@"code signature" fromLog:lowerLog];
        return;
    }

    // 3. The graphics driver died because the device ran out of memory.
    //    Checked ahead of the exit code because the JVM reports the SIGSEGV and then
    //    calls abort(), so this arrives as a plain "aborted" and would otherwise be
    //    filed under mod conflicts, whose advice is useless here.
    if ([self isGraphicsMemoryPressureCrash]) {
        self.crashType = CrashTypeGraphicsMemoryPressure;

        long long usedMB = 0, totalMB = 0;
        double occupancy = [self heapOccupancyFromCrashReport:&usedMB total:&totalMB];
        if (occupancy >= 0) {
            self.crashDetail = [NSString stringWithFormat:
                localize(@"crash.detail.graphics_memory", @"The game was using %lld MB of its %lld MB memory allowance (%.0f%%) when it stopped."),
                usedMB, totalMB, occupancy * 100.0];
        } else {
            self.crashDetail = nil;
        }
        return;
    }

    // 4. OOM (SIGKILL, or OOM keywords in the log)
    if ([self isOOMCrash]) {
        self.crashType = CrashTypeOOM;
        self.crashDetail = [self extractLineContaining:@"outofmemory" fromLog:lowerLog] ?: [self extractLineContaining:@"cannot allocate" fromLog:lowerLog];
        return;
    }

    // 5. SIGSEGV segmentation fault
    if (_exitCode == 11) {
        self.crashType = CrashTypeSegfault;
        self.crashDetail = nil;
        return;
    }

    // 6. SIGABRT
    if (_exitCode == 6) {
        // Check whether a mod conflict caused it
        if ([lowerLog containsString:@"nosuchmethoderror"] || [lowerLog containsString:@"classcastexception"] ||
            [lowerLog containsString:@"illegalaccessexception"] || [lowerLog containsString:@"nosuchfielderror"]) {
            self.crashType = CrashTypeModConflict;
            self.crashDetail = [self extractLineContaining:@"nosuchmethod" fromLog:lowerLog] ?: [self extractLineContaining:@"classcast" fromLog:lowerLog];
        } else if ([lowerLog containsString:@"unsatisfiedlinkerror"] || [lowerLog containsString:@"noclassdeffounderror"]) {
            self.crashType = CrashTypeMissingLibrary;
            self.crashDetail = [self extractLineContaining:@"unsatisfiedlink" fromLog:lowerLog] ?: [self extractLineContaining:@"noclassdef" fromLog:lowerLog];
        } else if ([lowerLog containsString:@"unsupportedclassversionerror"]) {
            self.crashType = CrashTypeJavaVersionMismatch;
            self.crashDetail = [self extractLineContaining:@"unsupportedclassversion" fromLog:lowerLog];
        } else {
            self.crashType = CrashTypeAbort;
            self.crashDetail = nil;
        }
        return;
    }

    // 7. SIGTERM
    if (_exitCode == 15) {
        self.crashType = CrashTypeTerminated;
        self.crashDetail = nil;
        return;
    }

    // 8. Analyze by log keywords (for other exit codes)
    // Mod conflict
    if ([lowerLog containsString:@"nosuchmethoderror"] || [lowerLog containsString:@"classcastexception"] ||
        [lowerLog containsString:@"illegalaccessexception"] || [lowerLog containsString:@"nosuchfielderror"] ||
        [lowerLog containsString:@"duplicate mod"]) {
        self.crashType = CrashTypeModConflict;
        self.crashDetail = [self extractLineContaining:@"nosuchmethod" fromLog:lowerLog] ?: [self extractLineContaining:@"classcast" fromLog:lowerLog];
        return;
    }

    // Missing library
    if ([lowerLog containsString:@"unsatisfiedlinkerror"] || [lowerLog containsString:@"noclassdeffounderror"] ||
        [lowerLog containsString:@"filenotfoundexception"] && [lowerLog containsString:@"library"]) {
        self.crashType = CrashTypeMissingLibrary;
        self.crashDetail = [self extractLineContaining:@"unsatisfiedlink" fromLog:lowerLog] ?: [self extractLineContaining:@"noclassdef" fromLog:lowerLog];
        return;
    }

    // Java version mismatch
    if ([lowerLog containsString:@"unsupportedclassversionerror"] || [lowerLog containsString:@"unsupported major.minor version"]) {
        self.crashType = CrashTypeJavaVersionMismatch;
        self.crashDetail = [self extractLineContaining:@"unsupportedclassversion" fromLog:lowerLog] ?: [self extractLineContaining:@"unsupported major" fromLog:lowerLog];
        return;
    }

    // Renderer error
    if ([lowerLog containsString:@"gl_invalid"] || [lowerLog containsString:@"egl_error"] ||
        [lowerLog containsString:@"opengl error"] || [lowerLog containsString:@"failed to create context"] ||
        [lowerLog containsString:@"glgeterror"] || [lowerLog containsString:@"metal:"]) {
        self.crashType = CrashTypeRendererError;
        self.crashDetail = [self extractLineContaining:@"gl_invalid" fromLog:lowerLog] ?: [self extractLineContaining:@"egl_error" fromLog:lowerLog] ?: [self extractLineContaining:@"opengl error" fromLog:lowerLog];
        return;
    }

    // A mod failed to load
    if ([lowerLog containsString:@"fml"] && [lowerLog containsString:@"error"] ||
        [lowerLog containsString:@"forge"] && [lowerLog containsString:@"modloading"] ||
        [lowerLog containsString:@"fabric"] && [lowerLog containsString:@"error"] ||
        [lowerLog containsString:@"optifine"] && [lowerLog containsString:@"error"]) {
        self.crashType = CrashTypeModLoadingFailure;
        self.crashDetail = [self extractLineContaining:@"modloading" fromLog:lowerLog] ?: [self extractLineContaining:@"fml" fromLog:lowerLog];
        return;
    }

    // A Java exception
    if ([lowerLog containsString:@"exception"] || [lowerLog containsString:@"stacktrace"]) {
        self.crashType = CrashTypeJavaException;
        self.crashDetail = [self extractLineContaining:@"exception" fromLog:lowerLog];
        return;
    }

    // Fallback: unknown
    self.crashType = CrashTypeUnknown;
    self.crashDetail = nil;
}

/// Extract the first line containing a given keyword from the log (for the crash details)
- (NSString *)extractLineContaining:(NSString *)keyword fromLog:(NSString *)lowerLog {
    if (lowerLog.length == 0) return nil;
    NSArray *lines = [lowerLog componentsSeparatedByCharactersInSet:[NSCharacterSet newlineCharacterSet]];
    for (NSString *line in lines) {
        if ([line containsString:keyword] && line.length < 200) {
            return [line stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
        }
    }
    return nil;
}

- (void)setupLogCard {
    _logCardView = [[UIView alloc] init];
    _logCardView.backgroundColor = [[UIColor whiteColor] colorWithAlphaComponent:0.08];
    _logCardView.layer.cornerRadius = 16;
    _logCardView.layer.cornerCurve = kCACornerCurveContinuous;
    _logCardView.layer.masksToBounds = YES;
    _logCardView.layer.borderWidth = 0.5;
    _logCardView.layer.borderColor = [[UIColor whiteColor] colorWithAlphaComponent:0.10].CGColor;
    _logCardView.translatesAutoresizingMaskIntoConstraints = NO;
    // Note: nothing is added to _mainStackView here; the horizontal split container in setupUI owns it
    // Apply the frosted-glass effect (adapting to the custom background wallpaper)
    [[BackgroundManager sharedManager] applyEffectToView:_logCardView];

    // Log title
    _logTitleLabel = [[UILabel alloc] init];
    _logTitleLabel.translatesAutoresizingMaskIntoConstraints = NO;
    _logTitleLabel.text = localize(@"crash.log_info", nil);
    _logTitleLabel.font = [UIFont systemFontOfSize:15 weight:UIFontWeightSemibold];
    _logTitleLabel.textColor = [UIColor labelColor];
    [_logCardView addSubview:_logTitleLabel];

    // The log text view (which scrolls internally)
    _logTextView = [[UITextView alloc] init];
    _logTextView.translatesAutoresizingMaskIntoConstraints = NO;
    _logTextView.backgroundColor = [UIColor clearColor];
    _logTextView.textColor = [UIColor labelColor];
    _logTextView.font = [UIFont fontWithName:@"Menlo" size:11];
    _logTextView.editable = NO;
    _logTextView.showsVerticalScrollIndicator = YES;
    _logTextView.indicatorStyle = UIScrollViewIndicatorStyleWhite;
    [_logCardView addSubview:_logTextView];

    // Placeholder (shown when the log is empty, with larger centered text)
    _logPlaceholderLabel = [[UILabel alloc] init];
    _logPlaceholderLabel.translatesAutoresizingMaskIntoConstraints = NO;
    _logPlaceholderLabel.text = localize(@"crash.log_info", nil);
    _logPlaceholderLabel.font = [UIFont systemFontOfSize:36 weight:UIFontWeightBold];
    _logPlaceholderLabel.textColor = [UIColor tertiaryLabelColor];
    _logPlaceholderLabel.textAlignment = NSTextAlignmentCenter;
    [_logCardView addSubview:_logPlaceholderLabel];

    // The log card height constraint (240 initially, adjusted from the screen height in viewDidLayoutSubviews)
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

- (void)setupButtonsIntoContainer:(UIStackView *)container {
    // ============================================================
    // The FCL-style button column (arranged vertically on the right)
    // ============================================================
    // Button order (top to bottom):
    //   1. Restart launcher (highlighted in blue) — exit(0) + openURL to relaunch the app
    //   2. Quit launcher (red) — exit(0) to quit the process outright, without restarting
    //   3. Share log
    //   4. Open GitHub Issues
    //   5. View the full log
    //
    // Key fix: "Restart launcher" and "Quit launcher" used to do the same thing
    //   - Restart: calls +restartLauncher (exit + relaunch)
    //   - Quit: called dismissAndReturnToLauncher (which only returned to the launcher main screen without quitting)
    // Users reported both buttons behaving identically (both returning to the launcher), unlike FCL.
    // "Quit launcher" now calls exitLauncherAction (exit(0) outright, with no restart).

    // 1. The restart launcher button (highlighted in blue)
    // Following FCL: many crashes are transient load failures (JIT/dylib/memory fragmentation) that a restart fixes.
    _restartButton = [self createButtonWithTitle:localize(@"crash.restart_launcher", @"Restart launcher")
                                            icon:@"arrow.clockwise"
                                   backgroundColor:[UIColor colorWithRed:0.2 green:0.6 blue:0.95 alpha:1.0]
                                       textColor:[UIColor whiteColor]
                                          bold:YES
                                          action:@selector(restartLauncherAction)];
    [container addArrangedSubview:_restartButton];

    // 2. The quit launcher button (highlighted in red)
    // Key fix: this button used to call dismissAndReturnToLauncher (returning to the launcher main screen),
    // which was the same as "Restart launcher" (both returning to the launcher). It now calls exit(0) to quit the process outright,
    // with no relaunch, matching the FCL "quit" behavior.
    _exitButton = [self createButtonWithTitle:localize(@"crash.return_launcher", @"Quit launcher")
                                         icon:@"xmark.circle.fill"
                                backgroundColor:[UIColor colorWithRed:0.85 green:0.2 blue:0.2 alpha:1.0]
                                    textColor:[UIColor whiteColor]
                                       bold:YES
                                       action:@selector(exitLauncherAction)];
    [container addArrangedSubview:_exitButton];

    // 3. The share log button
    _shareButton = [self createButtonWithTitle:localize(@"crash.share_log", @"Share log")
                                          icon:@"square.and.arrow.up"
                                 backgroundColor:[[UIColor whiteColor] colorWithAlphaComponent:0.15]
                                     textColor:[UIColor labelColor]
                                        bold:NO
                                        action:@selector(shareLog)];
    [container addArrangedSubview:_shareButton];

    // 4. The GitHub Issues button
    _githubButton = [self createButtonWithTitle:localize(@"crash.github_issue", @"Open GitHub Issues")
                                           icon:@"link"
                                  backgroundColor:[[UIColor colorWithRed:0.3 green:0.5 blue:0.9 alpha:1.0] colorWithAlphaComponent:0.3]
                                      textColor:[UIColor whiteColor]
                                         bold:NO
                                         action:@selector(openGitHubIssues)];
    [container addArrangedSubview:_githubButton];

    // 5. The view full log button (a plain text button)
    _fullLogButton = [UIButton buttonWithType:UIButtonTypeSystem];
    _fullLogButton.translatesAutoresizingMaskIntoConstraints = NO;
    [_fullLogButton setTitle:localize(@"crash.view_log", @"View log details") forState:UIControlStateNormal];
    _fullLogButton.titleLabel.font = [UIFont systemFontOfSize:14];
    [_fullLogButton setTitleColor:[UIColor secondaryLabelColor] forState:UIControlStateNormal];
    [_fullLogButton addTarget:self action:@selector(showFullLog) forControlEvents:UIControlEventTouchUpInside];
    [container addArrangedSubview:_fullLogButton];
}

- (UIButton *)createButtonWithTitle:(NSString *)title icon:(NSString *)icon backgroundColor:(UIColor *)bgColor textColor:(UIColor *)textColor bold:(BOOL)bold action:(SEL)action {
    UIButton *button = [UIButton buttonWithType:UIButtonTypeSystem];
    button.translatesAutoresizingMaskIntoConstraints = NO;
    button.backgroundColor = bgColor;
    button.layer.cornerRadius = 12;
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

    // A fixed button height
    [button.heightAnchor constraintEqualToConstant:48].active = YES;

    return button;
}

- (void)adjustLogCardHeight {
    CGFloat screenHeight = self.view.bounds.size.height;
    // Adjust the log card height from the screen height:
    //   on a small screen (iPhone SE) the log area is shorter, leaving room for the buttons
    //   on a large screen (iPad) it is taller, making full use of the space
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

    // Get the last 150 lines
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

    // Scroll to the bottom
    dispatch_async(dispatch_get_main_queue(), ^{
        [self.logTextView scrollRangeToVisible:NSMakeRange(self.logTextView.text.length, 0)];
    });
}

#pragma mark - Crash Analysis

/// Read the contents of latestlog.txt (for the crash cause analysis)
- (NSString *)readLatestLogForAnalysis {
    static NSString *cachedLog = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        NSString *latestlogPath = [NSString stringWithFormat:@"%s/latestlog.txt", getenv("POJAV_HOME")];
        cachedLog = [NSString stringWithContentsOfFile:latestlogPath encoding:NSUTF8StringEncoding error:nil] ?: @"";
    });
    return cachedLog;
}

/// Read the JVM's own crash report, when the log says one was written.
///
/// When the JVM dies in native code it writes an hs_err_pid*.log next to the game and
/// prints the path into the log the launcher captures. That file carries the two things
/// the launcher log does not: which library the crash was actually inside, and how full
/// the Java heap was at the time.
- (NSString *)readCrashReport {
    static NSString *cachedReport = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        cachedReport = @"";
        NSString *log = [self readLatestLogForAnalysis];
        if (log.length == 0) return;

        // The JVM prints "# An error report file with more information is saved as:"
        // and then the absolute path on the following line, both behind a "# " prefix.
        NSRange marker = [log rangeOfString:@"error report file with more information is saved as:"];
        if (marker.location == NSNotFound) return;

        NSRange rest = NSMakeRange(NSMaxRange(marker), log.length - NSMaxRange(marker));
        for (NSString *line in [[log substringWithRange:rest] componentsSeparatedByString:@"\n"]) {
            NSString *candidate = [line stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
            while ([candidate hasPrefix:@"#"]) {
                candidate = [[candidate substringFromIndex:1] stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
            }
            if (candidate.length == 0) continue;
            if (![candidate hasPrefix:@"/"]) break; // The path is the first non-empty line; anything else means it is gone.
            cachedReport = [NSString stringWithContentsOfFile:candidate encoding:NSUTF8StringEncoding error:nil] ?: @"";
            break;
        }
    });
    return cachedReport;
}

/// How full the Java heap was when the JVM died, as a fraction, or -1 when unknown.
///
/// Fills usedMB/totalMB from the crash report's heap summary line, which reads
/// " garbage-first heap   total 1966080K, used 1953683K [...]".
- (double)heapOccupancyFromCrashReport:(long long *)usedMB total:(long long *)totalMB {
    NSString *report = [self readCrashReport];
    if (report.length == 0) return -1;

    NSRange heapSection = [report rangeOfString:@"heap   total "];
    if (heapSection.location == NSNotFound) {
        heapSection = [report rangeOfString:@"heap total "];
        if (heapSection.location == NSNotFound) return -1;
    }

    NSScanner *scanner = [NSScanner scannerWithString:[report substringFromIndex:NSMaxRange(heapSection)]];
    long long totalK = 0, usedK = 0;
    if (![scanner scanLongLong:&totalK]) return -1;
    if (![scanner scanUpToString:@"used " intoString:NULL]) return -1;
    if (![scanner scanString:@"used " intoString:NULL]) return -1;
    if (![scanner scanLongLong:&usedK]) return -1;
    if (totalK <= 0 || usedK < 0) return -1;

    if (usedMB) *usedMB = usedK / 1024;
    if (totalMB) *totalMB = totalK / 1024;
    return (double)usedK / (double)totalK;
}

/// Whether the graphics driver crashed because the device had run out of memory.
///
/// This is the shape a large modpack takes when it outgrows what iOS will give the app.
/// The Java heap fills, the collector cannot keep ahead of it, and the next allocation
/// the Metal driver makes on the render thread is refused. The driver does not check,
/// so the process dies inside Apple's graphics stack with a null dereference - which
/// on its own reads like a driver bug rather than the memory problem it is.
///
/// Two things have to hold before claiming this: the crash was inside the graphics
/// stack, and there is separate evidence the memory was gone. Either alone is not
/// enough - graphics drivers crash for other reasons, and memory gets tight without
/// anything crashing.
- (BOOL)isGraphicsMemoryPressureCrash {
    NSString *log = [self readLatestLogForAnalysis];
    if (log.length == 0) return NO;
    NSString *lowerLog = [log lowercaseString];

    // Part one: the crash was inside the graphics stack. The JVM names the library in
    // its "Problematic frame:" line, which it prints into the launcher log as well.
    NSRange frameMarker = [lowerLog rangeOfString:@"problematic frame:"];
    if (frameMarker.location == NSNotFound) return NO;

    NSUInteger tailStart = NSMaxRange(frameMarker);
    NSUInteger tailLength = MIN((NSUInteger)200, lowerLog.length - tailStart);
    NSString *frame = [lowerLog substringWithRange:NSMakeRange(tailStart, tailLength)];

    BOOL inGraphicsStack = NO;
    for (NSString *library in @[@"agxmetal", @"libglesv2", @"libmobileglues", @"iogpu",
                                @"metal", @"libangle", @"moltenvk", @"libgl4es"]) {
        if ([frame containsString:library]) { inGraphicsStack = YES; break; }
    }
    if (!inGraphicsStack) return NO;

    // Part two: the memory really was gone. Any one of these is enough on its own.
    //  - iOS told the app so, and the launcher logged it while clearing its caches
    //  - the collector had been reduced to emergency full compactions
    //  - the JVM's own crash report shows the heap essentially full
    //
    // The first two are only trusted from the stretch of log leading up to the crash.
    // A long session can survive a tight moment early on and go on to crash hours later
    // for a reason that has nothing to do with memory; reading the whole log would let
    // that stale warning explain away an unrelated crash.
    NSUInteger windowEnd = frameMarker.location;
    NSUInteger windowStart = windowEnd > 40000 ? windowEnd - 40000 : 0;
    NSString *recentLog = [lowerLog substringWithRange:NSMakeRange(windowStart, windowEnd - windowStart)];

    if ([recentLog containsString:@"memory warning"]) return YES;
    if ([recentLog containsString:@"pause full (g1 compaction pause)"]) return YES;
    if ([recentLog containsString:@"g1 preventive collection"]) return YES;

    // The heap figure needs no window - the JVM records it at the moment it died.
    double occupancy = [self heapOccupancyFromCrashReport:NULL total:NULL];
    return occupancy >= 0.95;
}

/// Whether this was an OOM (out of memory) crash
- (BOOL)isOOMCrash {
    // SIGKILL (signal 9) usually means the system killed the process because it ran out of memory
    if (_exitCode == 9) return YES;

    // Check whether the log contains OOM-related keywords
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

/// Return the localized cause description for the crash type analyzeCrashType found
///
/// Following the HMCL crash analyzer, for a more precise description of the cause.
/// The crash types added: mod conflict, missing library, Java version mismatch, renderer error and mod loading failure.
- (NSString *)crashReasonText {
    // Prefer the custom reason
    if (_customReason.length > 0) {
        return [NSString stringWithFormat:@"%@%@", localize(@"crash.possible_reason", nil), _customReason];
    }

    NSString *reason = nil;

    switch (self.crashType) {
        case CrashTypeNormal:
            reason = localize(@"crash.reason.normal", nil);
            break;
        case CrashTypeOOM:
            reason = localize(@"crash.reason.memory", nil);
            break;
        case CrashTypeSegfault:
            reason = localize(@"crash.reason.segmentation", nil);
            break;
        case CrashTypeAbort:
            reason = localize(@"crash.reason.abort", nil);
            break;
        case CrashTypeTerminated:
            reason = localize(@"crash.reason.terminated", nil);
            break;
        case CrashTypeModConflict:
            reason = localize(@"crash.reason.mod_conflict", @"A mod conflict caused the crash (NoSuchMethodError/ClassCastException, etc.)");
            break;
        case CrashTypeMissingLibrary:
            reason = localize(@"crash.reason.missing_library", @"Missing game library files (UnsatisfiedLinkError/NoClassDefFoundError)");
            break;
        case CrashTypeUnsignedDylib:
            reason = localize(@"crash.reason.unsigned_dylib", @"iOS refused to load a library a mod unpacked while running (code signature invalid)");
            break;
        case CrashTypeJavaVersionMismatch:
            reason = localize(@"crash.reason.java_version", @"Java version mismatch (UnsupportedClassVersionError)");
            break;
        case CrashTypeRendererError:
            reason = localize(@"crash.reason.renderer", @"Renderer error (OpenGL/Metal/EGL failed to initialize)");
            break;
        case CrashTypeGraphicsMemoryPressure:
            reason = localize(@"crash.reason.graphics_memory",
                @"The device ran out of memory while the game was drawing. The graphics driver asked iOS for memory, was refused, and took the game down with it.");
            break;
        case CrashTypeModLoadingFailure:
            reason = localize(@"crash.reason.mod_loading", @"A mod failed to load (Forge/Fabric/OptiFine loading error)");
            break;
        case CrashTypeJavaException:
            reason = localize(@"crash.reason.java_exception", nil);
            break;
        case CrashTypeUnknown:
            reason = [NSString stringWithFormat:localize(@"crash.reason.unknown", @"Unknown error (code: %d)"), _exitCode];
            break;
    }

    // If there are crash details, append them to the reason
    if (self.crashDetail.length > 0) {
        reason = [NSString stringWithFormat:@"%@\n%@", reason, self.crashDetail];
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
    // Show the full PLLogOutputView
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

/// Quit the launcher: exit(0) outright, with no relaunch.
///
/// Key fix: the "Quit launcher" button used to call dismissAndReturnToLauncher,
/// which only returned to the launcher main screen (without quitting), so it behaved exactly like "Restart launcher"
/// (both returning to the launcher). Users reported the two buttons doing the same thing, unlike FCL.
///
/// What FCL does:
///   - Restart launcher = exit(0) + relaunch (bringing the app back up)
///   - Quit launcher = exit(0) (quitting outright, with no restart)
///
/// This method now calls exit(0) directly, with no relaunch.
- (void)exitLauncherAction {
    NSLog(@"[PLCrashView] User tapped exit launcher, exiting process directly");
    // Tear down the crash screen first
    if (currentCrashVC) {
        [currentCrashVC dismissViewControllerAnimated:NO completion:nil];
        currentCrashVC = nil;
    }
    // Tell SurfaceViewController to release the game resources
    if ([SurfaceViewController currentInstance]) {
        [[SurfaceViewController currentInstance].logOutputView dismissAndReturnToLauncher];
    }
    // Quit the process outright, with no restart
    exit(0);
}

- (void)dismissAndReturnToLauncher {
    // Call the return logic of PLLogOutputView
    if ([SurfaceViewController currentInstance]) {
        [[SurfaceViewController currentInstance].logOutputView dismissAndReturnToLauncher];
    }

    [self dismissViewControllerAnimated:YES completion:^{
        currentCrashVC = nil;
    }];
}

/// The instance handler of the restart launcher button, delegating to the +restartLauncher class method
- (void)restartLauncherAction {
    [PLCrashView restartLauncher];
}

#pragma mark - Class Methods for External Callers

/// Class method: hide the crash screen and return to the launcher.
/// Safe for external VCs to call, avoiding the crash from performSelector-ing an instance method on the class object.
+ (void)dismissAndReturnToLauncher {
    dispatch_async(dispatch_get_main_queue(), ^{
        if (currentCrashVC) {
            [currentCrashVC dismissAndReturnToLauncher];
        } else if ([SurfaceViewController currentInstance]) {
            [[SurfaceViewController currentInstance].logOutputView dismissAndReturnToLauncher];
        }
    });
}

/// Restart the launcher: tear down the crash screen and the game surface, then trigger a system restart with exit(0) + relaunch.
/// Following the FCL "restart app" button: many crashes are transient load failures that a restart fixes.
+ (void)restartLauncher {
    dispatch_async(dispatch_get_main_queue(), ^{
        // 1. Tear down the crash screen
        if (currentCrashVC) {
            [currentCrashVC dismissViewControllerAnimated:NO completion:nil];
            currentCrashVC = nil;
        }

        // 2. Tell SurfaceViewController to release the game resources
        if ([SurfaceViewController currentInstance]) {
            [[SurfaceViewController currentInstance].logOutputView dismissAndReturnToLauncher];
        }

        // 3. Trigger a relaunch through an NSURL (supported on TrollStore/jailbroken setups)
        //    If the relaunch fails it falls back to exit(0), and the system brings the foreground app back within 10 seconds
        NSString *bundlePath = [NSBundle mainBundle].bundlePath;
        NSURL *appURL = [NSURL fileURLWithPath:bundlePath];
        NSLog(@"[PLCrashView] Restarting launcher from %@", bundlePath);

        // Try to relaunch through openURL (which needs UIApplication.openURL, available on jailbroken/TrollStore setups)
        if (@available(iOS 10.0, *)) {
            [[UIApplication sharedApplication] openURL:appURL
                                               options:@{}
                                     completionHandler:^(BOOL success) {
                if (!success) {
                    NSLog(@"[PLCrashView] openURL failed, falling back to exit(0)");
                }
                // Quit the current process either way, so the system brings it back
                exit(0);
            }];
        } else {
            exit(0);
        }
    });
}

@end
