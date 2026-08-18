//
//  CurseForgeAPIKeyViewController.m
//  Amethyst
//
//  Implementation of the runtime CurseForge API key settings page
//  UI style: Bento Grid + Material Design 3
//

// Foundation/UIKit must be imported first so macros in other headers do not clash with Objective-C keywords
#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>

// Undefine any existing "interface" macro so it does not clash with the Objective-C @interface keyword
#ifdef interface
#undef interface
#endif

#import "CurseForgeAPIKeyViewController.h"
#import "PLPreferences.h"
#import "CurseForgeAPI.h"
#import "config.h"
#import "BackgroundManager.h"

/// Material Design 3 primary color (a CurseForge orange, echoing the brand)
static UIColor *CFKMD3PrimaryColor(void) {
    return [UIColor colorWithDynamicProvider:^UIColor * _Nonnull(UITraitCollection * _Nonnull traitCollection) {
        if (traitCollection.userInterfaceStyle == UIUserInterfaceStyleDark) {
            return [UIColor colorWithRed:0.85 green:0.55 blue:0.30 alpha:1.0];
        }
        return [UIColor colorWithRed:0.80 green:0.42 blue:0.16 alpha:1.0];
    }];
}

/// Text color on the Material Design 3 primary color (always white)
static UIColor *CFKMD3OnPrimaryColor(void) {
    return [UIColor whiteColor];
}

/// Outline color of Material Design 3 outlined buttons
static UIColor *CFKMD3OutlineColor(void) {
    return [UIColor colorWithDynamicProvider:^UIColor * _Nonnull(UITraitCollection * _Nonnull traitCollection) {
        if (traitCollection.userInterfaceStyle == UIUserInterfaceStyleDark) {
            return [UIColor colorWithWhite:1.0 alpha:0.32];
        }
        return [UIColor colorWithWhite:0.0 alpha:0.24];
    }];
}

/// Card background color (adapts to light/dark)
static UIColor *CFKCardBackgroundColor(void) {
    return [UIColor colorWithDynamicProvider:^UIColor * _Nonnull(UITraitCollection * _Nonnull traitCollection) {
        if (traitCollection.userInterfaceStyle == UIUserInterfaceStyleDark) {
            return [UIColor colorWithWhite:1.0 alpha:0.06];
        }
        return [UIColor colorWithWhite:1.0 alpha:0.75];
    }];
}

/// Card border color
static UIColor *CFKCardBorderColor(void) {
    return [UIColor colorWithDynamicProvider:^UIColor * _Nonnull(UITraitCollection * _Nonnull traitCollection) {
        if (traitCollection.userInterfaceStyle == UIUserInterfaceStyleDark) {
            return [UIColor colorWithWhite:1.0 alpha:0.10];
        }
        return [UIColor colorWithWhite:0.0 alpha:0.08];
    }];
}

/// Page background color
static UIColor *CFKPageBackgroundColor(void) {
    return [UIColor colorWithDynamicProvider:^UIColor * _Nonnull(UITraitCollection * _Nonnull traitCollection) {
        if (traitCollection.userInterfaceStyle == UIUserInterfaceStyleDark) {
            return [UIColor colorWithRed:0.05 green:0.05 blue:0.07 alpha:1.0];
        }
        return [UIColor colorWithRed:0.96 green:0.96 blue:0.98 alpha:1.0];
    }];
}

/// Primary text color
static UIColor *CFKPrimaryTextColor(void) {
    return [UIColor colorWithDynamicProvider:^UIColor * _Nonnull(UITraitCollection * _Nonnull traitCollection) {
        if (traitCollection.userInterfaceStyle == UIUserInterfaceStyleDark) {
            return [UIColor whiteColor];
        }
        return [UIColor colorWithRed:0.10 green:0.10 blue:0.12 alpha:1.0];
    }];
}

/// Secondary text color
static UIColor *CFKSecondaryTextColor(void) {
    return [UIColor colorWithDynamicProvider:^UIColor * _Nonnull(UITraitCollection * _Nonnull traitCollection) {
        if (traitCollection.userInterfaceStyle == UIUserInterfaceStyleDark) {
            return [UIColor colorWithWhite:1.0 alpha:0.60];
        }
        return [UIColor colorWithWhite:0.0 alpha:0.55];
    }];
}

/// Text field background color
static UIColor *CFKFieldBackgroundColor(void) {
    return [UIColor colorWithDynamicProvider:^UIColor * _Nonnull(UITraitCollection * _Nonnull traitCollection) {
        if (traitCollection.userInterfaceStyle == UIUserInterfaceStyleDark) {
            return [UIColor colorWithWhite:1.0 alpha:0.08];
        }
        return [UIColor colorWithWhite:0.0 alpha:0.04];
    }];
}

/// Success state color
static UIColor *CFKSuccessColor(void) {
    return [UIColor colorWithRed:0.18 green:0.69 blue:0.45 alpha:1.0];
}

/// Failure state color
static UIColor *CFKErrorColor(void) {
    return [UIColor colorWithRed:0.86 green:0.27 blue:0.27 alpha:1.0];
}

@interface CurseForgeAPIKeyViewController () <UITextFieldDelegate>

// Container and scrolling
@property (nonatomic, strong) UIScrollView *scrollView;
@property (nonatomic, strong) UIView *contentView;

// Info card (Bento Grid style)
@property (nonatomic, strong) UIView *infoCardView;
@property (nonatomic, strong) UILabel *infoTitleLabel;
@property (nonatomic, strong) UILabel *infoDescLabel;

// Input card
@property (nonatomic, strong) UIView *inputCardView;
@property (nonatomic, strong) UILabel *inputCardTitleLabel;
@property (nonatomic, strong) UITextField *apiKeyTextField;
@property (nonatomic, strong) UILabel *sourceHintLabel;

// Button card
@property (nonatomic, strong) UIView *actionCardView;
@property (nonatomic, strong) UIButton *saveButton;
@property (nonatomic, strong) UIButton *testButton;
@property (nonatomic, strong) UIButton *clearButton;
@property (nonatomic, strong) UIActivityIndicatorView *testActivityIndicator;

// Status label
@property (nonatomic, strong) UILabel *statusLabel;

// Keyboard handling
@property (nonatomic, assign) CGFloat keyboardOffset;
@property (nonatomic, strong) NSLayoutConstraint *scrollViewBottomConstraint;

// State
@property (nonatomic, assign) BOOL isTesting;

@end

@implementation CurseForgeAPIKeyViewController

#pragma mark - Lifecycle

- (void)viewDidLoad {
    [super viewDidLoad];
    // Adapt to the custom launcher background: make this view controller transparent so the global wallpaper shows through
    [[BackgroundManager sharedManager] makeViewControllerTransparent:self];

    self.title = @"CurseForge API Key";
    self.view.backgroundColor = CFKPageBackgroundColor();

    [self setupUI];
    [self loadInitialValue];
    [self registerKeyboardNotifications];

    // Listen for background UI effect changes so transparency is re-applied when the user switches effect (translucent/frosted)
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(reapplyBackgroundEffect)
                                                 name:@"BackgroundUIEffectChanged"
                                               object:nil];
}

/// Re-apply transparency when the background effect changes (triggered by the BackgroundUIEffectChanged notification)
- (void)reapplyBackgroundEffect {
    [[BackgroundManager sharedManager] makeViewControllerTransparent:self];
}

- (void)viewWillTransitionToSize:(CGSize)size
       withTransitionCoordinator:(id<UIViewControllerTransitionCoordinator>)coordinator {
    [super viewWillTransitionToSize:size withTransitionCoordinator:coordinator];
    [coordinator animateAlongsideTransition:^(id<UIViewControllerTransitionCoordinatorContext> _Nonnull context) {
        [self updateLayoutForWidth:size.width];
    } completion:nil];
}

#pragma mark - UI construction

- (void)setupUI {
    [self setupScrollView];
    [self setupInfoCard];
    [self setupInputCard];
    [self setupActionCard];
    [self setupStatusLabel];
    [self installLayoutConstraintsForWidth:self.view.bounds.size.width];
}

- (void)setupScrollView {
    _scrollView = [[UIScrollView alloc] init];
    _scrollView.translatesAutoresizingMaskIntoConstraints = NO;
    _scrollView.alwaysBounceVertical = YES;
    _scrollView.keyboardDismissMode = UIScrollViewKeyboardDismissModeInteractive;
    [self.view addSubview:_scrollView];

    _contentView = [[UIView alloc] init];
    _contentView.translatesAutoresizingMaskIntoConstraints = NO;
    [_scrollView addSubview:_contentView];

    // Base constraints (width adapts)
    _scrollViewBottomConstraint = [_scrollView.bottomAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.bottomAnchor];
    [NSLayoutConstraint activateConstraints:@[
        [_scrollView.topAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.topAnchor],
        [_scrollView.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [_scrollView.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        _scrollViewBottomConstraint,
        [_contentView.topAnchor constraintEqualToAnchor:_scrollView.contentLayoutGuide.topAnchor],
        [_contentView.bottomAnchor constraintEqualToAnchor:_scrollView.contentLayoutGuide.bottomAnchor],
        [_contentView.leadingAnchor constraintEqualToAnchor:_scrollView.contentLayoutGuide.leadingAnchor],
        [_contentView.trailingAnchor constraintEqualToAnchor:_scrollView.contentLayoutGuide.trailingAnchor],
        [_contentView.widthAnchor constraintEqualToAnchor:_scrollView.frameLayoutGuide.widthAnchor],
    ]];
}

- (void)setupInfoCard {
    _infoCardView = [self makeCardView];
    [_contentView addSubview:_infoCardView];

    _infoTitleLabel = [[UILabel alloc] init];
    _infoTitleLabel.translatesAutoresizingMaskIntoConstraints = NO;
    _infoTitleLabel.text = @"CurseForge API Key";
    _infoTitleLabel.font = [UIFont systemFontOfSize:20 weight:UIFontWeightSemibold];
    _infoTitleLabel.textColor = CFKPrimaryTextColor();
    _infoTitleLabel.numberOfLines = 1;
    [_infoCardView addSubview:_infoTitleLabel];

    _infoDescLabel = [[UILabel alloc] init];
    _infoDescLabel.translatesAutoresizingMaskIntoConstraints = NO;
    _infoDescLabel.text = @"Configure a CurseForge API key to use CurseForge as a source. A key set at runtime overrides the compile-time default. To request a key, visit curseforge.com";
    _infoDescLabel.font = [UIFont systemFontOfSize:13 weight:UIFontWeightRegular];
    _infoDescLabel.textColor = CFKSecondaryTextColor();
    _infoDescLabel.numberOfLines = 0;
    [_infoCardView addSubview:_infoDescLabel];
}

- (void)setupInputCard {
    _inputCardView = [self makeCardView];
    [_contentView addSubview:_inputCardView];

    _inputCardTitleLabel = [[UILabel alloc] init];
    _inputCardTitleLabel.translatesAutoresizingMaskIntoConstraints = NO;
    _inputCardTitleLabel.text = @"API Key";
    _inputCardTitleLabel.font = [UIFont systemFontOfSize:15 weight:UIFontWeightSemibold];
    _inputCardTitleLabel.textColor = CFKPrimaryTextColor();
    [_inputCardView addSubview:_inputCardTitleLabel];

    _apiKeyTextField = [[UITextField alloc] init];
    _apiKeyTextField.translatesAutoresizingMaskIntoConstraints = NO;
    _apiKeyTextField.placeholder = @"Enter CurseForge API key";
    _apiKeyTextField.font = [UIFont systemFontOfSize:15 weight:UIFontWeightRegular];
    _apiKeyTextField.textColor = CFKPrimaryTextColor();
    _apiKeyTextField.backgroundColor = CFKFieldBackgroundColor();
    _apiKeyTextField.secureTextEntry = YES;
    _apiKeyTextField.autocapitalizationType = UITextAutocapitalizationTypeNone;
    _apiKeyTextField.autocorrectionType = UITextAutocorrectionTypeNo;
    _apiKeyTextField.spellCheckingType = UITextSpellCheckingTypeNo;
    _apiKeyTextField.keyboardType = UIKeyboardTypeASCIICapable;
    _apiKeyTextField.returnKeyType = UIReturnKeyDone;
    _apiKeyTextField.clearButtonMode = UITextFieldViewModeWhileEditing;
    _apiKeyTextField.delegate = self;
    _apiKeyTextField.layer.cornerRadius = 12;
    _apiKeyTextField.layer.cornerCurve = kCACornerCurveContinuous;
    // Left inset for the text
    _apiKeyTextField.leftView = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 12, 1)];
    _apiKeyTextField.leftViewMode = UITextFieldViewModeAlways;
    _apiKeyTextField.rightView = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 12, 1)];
    _apiKeyTextField.rightViewMode = UITextFieldViewModeAlways;
    [_inputCardView addSubview:_apiKeyTextField];

    _sourceHintLabel = [[UILabel alloc] init];
    _sourceHintLabel.translatesAutoresizingMaskIntoConstraints = NO;
    _sourceHintLabel.font = [UIFont systemFontOfSize:11 weight:UIFontWeightRegular];
    _sourceHintLabel.textColor = CFKSecondaryTextColor();
    _sourceHintLabel.numberOfLines = 0;
    [_inputCardView addSubview:_sourceHintLabel];
}

- (void)setupActionCard {
    _actionCardView = [self makeCardView];
    [_contentView addSubview:_actionCardView];

    _saveButton = [self makeFilledButtonWithTitle:@"Save"
                                          primary:YES];
    [_saveButton addTarget:self action:@selector(saveButtonTapped) forControlEvents:UIControlEventTouchUpInside];
    [_actionCardView addSubview:_saveButton];

    _testButton = [self makeOutlinedButtonWithTitle:@"Test"];
    [_testButton addTarget:self action:@selector(testButtonTapped) forControlEvents:UIControlEventTouchUpInside];
    [_actionCardView addSubview:_testButton];

    _clearButton = [self makeOutlinedButtonWithTitle:@"Clear"];
    [_clearButton addTarget:self action:@selector(clearButtonTapped) forControlEvents:UIControlEventTouchUpInside];
    [_actionCardView addSubview:_clearButton];

    _testActivityIndicator = [[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleMedium];
    _testActivityIndicator.translatesAutoresizingMaskIntoConstraints = NO;
    _testActivityIndicator.hidesWhenStopped = YES;
    [_actionCardView addSubview:_testActivityIndicator];
}

- (void)setupStatusLabel {
    _statusLabel = [[UILabel alloc] init];
    _statusLabel.translatesAutoresizingMaskIntoConstraints = NO;
    _statusLabel.font = [UIFont systemFontOfSize:13 weight:UIFontWeightMedium];
    _statusLabel.textAlignment = NSTextAlignmentLeft;
    _statusLabel.numberOfLines = 0;
    _statusLabel.text = @"";
    [_contentView addSubview:_statusLabel];
}

#pragma mark - Card and button factories

- (UIView *)makeCardView {
    UIView *card = [[UIView alloc] init];
    card.translatesAutoresizingMaskIntoConstraints = NO;
    card.backgroundColor = CFKCardBackgroundColor();
    card.layer.cornerRadius = 16;
    card.layer.cornerCurve = kCACornerCurveContinuous;
    card.layer.borderWidth = 0.5;
    card.layer.borderColor = CFKCardBorderColor().CGColor;
    return card;
}

- (UIButton *)makeFilledButtonWithTitle:(NSString *)title primary:(BOOL)primary {
    UIButton *button = [UIButton buttonWithType:UIButtonTypeSystem];
    button.translatesAutoresizingMaskIntoConstraints = NO;
    [button setTitle:title forState:UIControlStateNormal];
    button.titleLabel.font = [UIFont systemFontOfSize:14 weight:UIFontWeightSemibold];
    button.layer.cornerRadius = 12;
    button.layer.cornerCurve = kCACornerCurveContinuous;
    if (primary) {
        button.backgroundColor = CFKMD3PrimaryColor();
        [button setTitleColor:CFKMD3OnPrimaryColor() forState:UIControlStateNormal];
        button.tintColor = CFKMD3OnPrimaryColor();
    } else {
        button.backgroundColor = [UIColor clearColor];
        [button setTitleColor:CFKPrimaryTextColor() forState:UIControlStateNormal];
        button.tintColor = CFKPrimaryTextColor();
    }
    return button;
}

- (UIButton *)makeOutlinedButtonWithTitle:(NSString *)title {
    UIButton *button = [self makeFilledButtonWithTitle:title primary:NO];
    button.layer.borderWidth = 1.0;
    button.layer.borderColor = CFKMD3OutlineColor().CGColor;
    return button;
}

#pragma mark - Layout

- (void)installLayoutConstraintsForWidth:(CGFloat)width {
    // Remove the old constraints (in case of a rebuild)
    [self removeConstraintsOnContentView];

    CGFloat horizontalPadding = MAX(16, (width - 600) / 2.0); // Center and cap the width on large screens
    CGFloat cardSpacing = 12;
    CGFloat contentPadding = 16;

    // Info card
    [NSLayoutConstraint activateConstraints:@[
        [_infoCardView.topAnchor constraintEqualToAnchor:_contentView.topAnchor constant:contentPadding],
        [_infoCardView.leadingAnchor constraintEqualToAnchor:_contentView.leadingAnchor constant:horizontalPadding],
        [_infoCardView.trailingAnchor constraintEqualToAnchor:_contentView.trailingAnchor constant:-horizontalPadding],

        [_infoTitleLabel.topAnchor constraintEqualToAnchor:_infoCardView.topAnchor constant:16],
        [_infoTitleLabel.leadingAnchor constraintEqualToAnchor:_infoCardView.leadingAnchor constant:16],
        [_infoTitleLabel.trailingAnchor constraintEqualToAnchor:_infoCardView.trailingAnchor constant:-16],

        [_infoDescLabel.topAnchor constraintEqualToAnchor:_infoTitleLabel.bottomAnchor constant:8],
        [_infoDescLabel.leadingAnchor constraintEqualToAnchor:_infoCardView.leadingAnchor constant:16],
        [_infoDescLabel.trailingAnchor constraintEqualToAnchor:_infoCardView.trailingAnchor constant:-16],
        [_infoDescLabel.bottomAnchor constraintEqualToAnchor:_infoCardView.bottomAnchor constant:-16],
    ]];

    // Input card
    [NSLayoutConstraint activateConstraints:@[
        [_inputCardView.topAnchor constraintEqualToAnchor:_infoCardView.bottomAnchor constant:cardSpacing],
        [_inputCardView.leadingAnchor constraintEqualToAnchor:_contentView.leadingAnchor constant:horizontalPadding],
        [_inputCardView.trailingAnchor constraintEqualToAnchor:_contentView.trailingAnchor constant:-horizontalPadding],

        [_inputCardTitleLabel.topAnchor constraintEqualToAnchor:_inputCardView.topAnchor constant:16],
        [_inputCardTitleLabel.leadingAnchor constraintEqualToAnchor:_inputCardView.leadingAnchor constant:16],
        [_inputCardTitleLabel.trailingAnchor constraintEqualToAnchor:_inputCardView.trailingAnchor constant:-16],

        [_apiKeyTextField.topAnchor constraintEqualToAnchor:_inputCardTitleLabel.bottomAnchor constant:10],
        [_apiKeyTextField.leadingAnchor constraintEqualToAnchor:_inputCardView.leadingAnchor constant:16],
        [_apiKeyTextField.trailingAnchor constraintEqualToAnchor:_inputCardView.trailingAnchor constant:-16],
        [_apiKeyTextField.heightAnchor constraintEqualToConstant:44],

        [_sourceHintLabel.topAnchor constraintEqualToAnchor:_apiKeyTextField.bottomAnchor constant:8],
        [_sourceHintLabel.leadingAnchor constraintEqualToAnchor:_inputCardView.leadingAnchor constant:16],
        [_sourceHintLabel.trailingAnchor constraintEqualToAnchor:_inputCardView.trailingAnchor constant:-16],
        [_sourceHintLabel.bottomAnchor constraintEqualToAnchor:_inputCardView.bottomAnchor constant:-16],
    ]];

    // Button card
    [NSLayoutConstraint activateConstraints:@[
        [_actionCardView.topAnchor constraintEqualToAnchor:_inputCardView.bottomAnchor constant:cardSpacing],
        [_actionCardView.leadingAnchor constraintEqualToAnchor:_contentView.leadingAnchor constant:horizontalPadding],
        [_actionCardView.trailingAnchor constraintEqualToAnchor:_contentView.trailingAnchor constant:-horizontalPadding],

        [_saveButton.topAnchor constraintEqualToAnchor:_actionCardView.topAnchor constant:16],
        [_saveButton.leadingAnchor constraintEqualToAnchor:_actionCardView.leadingAnchor constant:16],
        [_saveButton.heightAnchor constraintEqualToConstant:44],
        [_saveButton.widthAnchor constraintGreaterThanOrEqualToConstant:88],

        [_testButton.topAnchor constraintEqualToAnchor:_saveButton.topAnchor],
        [_testButton.leadingAnchor constraintEqualToAnchor:_saveButton.trailingAnchor constant:10],
        [_testButton.heightAnchor constraintEqualToConstant:44],
        [_testButton.widthAnchor constraintGreaterThanOrEqualToConstant:88],

        [_clearButton.topAnchor constraintEqualToAnchor:_saveButton.topAnchor],
        [_clearButton.leadingAnchor constraintEqualToAnchor:_testButton.trailingAnchor constant:10],
        [_clearButton.heightAnchor constraintEqualToConstant:44],
        [_clearButton.widthAnchor constraintGreaterThanOrEqualToConstant:88],
        [_clearButton.trailingAnchor constraintLessThanOrEqualToAnchor:_actionCardView.trailingAnchor constant:-16],

        [_testActivityIndicator.centerYAnchor constraintEqualToAnchor:_saveButton.centerYAnchor],
        [_testActivityIndicator.leadingAnchor constraintEqualToAnchor:_clearButton.trailingAnchor constant:8],

        [_saveButton.bottomAnchor constraintEqualToAnchor:_actionCardView.bottomAnchor constant:-16],
    ]];

    // Status label
    [NSLayoutConstraint activateConstraints:@[
        [_statusLabel.topAnchor constraintEqualToAnchor:_actionCardView.bottomAnchor constant:cardSpacing],
        [_statusLabel.leadingAnchor constraintEqualToAnchor:_contentView.leadingAnchor constant:horizontalPadding + 4],
        [_statusLabel.trailingAnchor constraintEqualToAnchor:_contentView.trailingAnchor constant:-(horizontalPadding + 4)],
        [_statusLabel.bottomAnchor constraintEqualToAnchor:_contentView.bottomAnchor constant:-contentPadding],
    ]];
}

- (void)removeConstraintsOnContentView {
    // Only remove the constraints belonging to this layout pass (to avoid conflicts from adding them twice)
    NSArray<UIView *> *related = @[_infoCardView, _infoDescLabel, _infoTitleLabel,
                                    _inputCardView, _inputCardTitleLabel, _apiKeyTextField, _sourceHintLabel,
                                    _actionCardView, _saveButton, _testButton, _clearButton, _testActivityIndicator,
                                    _statusLabel];
    for (UIView *v in related) {
        for (NSLayoutConstraint *c in v.constraints) {
            // Only remove constraints this view takes part in that point into the _contentView hierarchy
            if (c.firstAttribute != NSLayoutAttributeWidth && c.firstAttribute != NSLayoutAttributeHeight) {
                [v removeConstraint:c];
            }
        }
    }
    for (UIView *v in related) {
        [v removeFromSuperview];
    }
    // Add contentView back (keeping the reference and hierarchy)
    [_contentView addSubview:_infoCardView];
    [_infoCardView addSubview:_infoTitleLabel];
    [_infoCardView addSubview:_infoDescLabel];
    [_contentView addSubview:_inputCardView];
    [_inputCardView addSubview:_inputCardTitleLabel];
    [_inputCardView addSubview:_apiKeyTextField];
    [_inputCardView addSubview:_sourceHintLabel];
    [_contentView addSubview:_actionCardView];
    [_actionCardView addSubview:_saveButton];
    [_actionCardView addSubview:_testButton];
    [_actionCardView addSubview:_clearButton];
    [_actionCardView addSubview:_testActivityIndicator];
    [_contentView addSubview:_statusLabel];
}

- (void)updateLayoutForWidth:(CGFloat)width {
    [self installLayoutConstraintsForWidth:width];
}

#pragma mark - Initial value loading

- (void)loadInitialValue {
    // Priority: runtime preference -> compile-time macro -> Info.plist
    NSString *runtimeKey = [PLPreferences curseForgeAPIKey];
    NSString *compiledKey = @CONFIG_CURSEFORGE_API_KEY;
    if ([compiledKey isEqualToString:@"nil"]) {
        compiledKey = @"";
    }
    NSString *infoPlistKey = [NSBundle.mainBundle.infoDictionary[@"CurseForgeAPIKey"] isKindOfClass:NSString.class]
        ? NSBundle.mainBundle.infoDictionary[@"CurseForgeAPIKey"]
        : @"";

    NSString *displayKey = runtimeKey.length > 0 ? runtimeKey : (compiledKey.length > 0 ? compiledKey : infoPlistKey);
    _apiKeyTextField.text = displayKey;

    // Show the source hint
    NSString *sourceHint;
    if (runtimeKey.length > 0) {
        sourceHint = @"Current source: runtime preference (overrides the compile-time default)";
    } else if (compiledKey.length > 0) {
        sourceHint = @"Current source: compile-time default (saving switches to the runtime preference)";
    } else if (infoPlistKey.length > 0) {
        sourceHint = @"Current source: Info.plist";
    } else {
        sourceHint = @"No API key is configured, so the CurseForge source will be unavailable";
    }
    _sourceHintLabel.text = sourceHint;
}

#pragma mark - Button events

- (void)saveButtonTapped {
    NSString *key = [_apiKeyTextField.text stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (key.length == 0) {
        [PLPreferences setCurseForgeAPIKey:nil];
    } else {
        [PLPreferences setCurseForgeAPIKey:key];
    }
    [self loadInitialValue];
    [self setStatusText:@"Saved" success:YES];
}

- (void)clearButtonTapped {
    [PLPreferences setCurseForgeAPIKey:nil];
    // After clearing, echo back the compile-time default for reference
    NSString *compiledKey = @CONFIG_CURSEFORGE_API_KEY;
    if ([compiledKey isEqualToString:@"nil"]) {
        compiledKey = @"";
    }
    _apiKeyTextField.text = compiledKey.length > 0 ? compiledKey : @"";
    [self loadInitialValue];
    [self setStatusText:@"Runtime key cleared" success:YES];
}

- (void)testButtonTapped {
    if (_isTesting) {
        return;
    }
    // 1. Save the key currently entered into the preferences
    NSString *key = [_apiKeyTextField.text stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    [PLPreferences setCurseForgeAPIKey:key.length > 0 ? key : nil];

    if (key.length == 0) {
        [self setStatusText:@"✗ Key invalid: no API key entered" success:NO];
        return;
    }

    [self beginTesting];

    // 2. Use sharedInstance to run a lightweight search (pageSize=1)
    NSDictionary *filters = @{
        @"projectType": @"mod",
        @"query": @"",
        @"limit": @1,
        @"offset": @0
    };
    __weak typeof(self) weakSelf = self;
    [[CurseForgeAPI sharedInstance] searchModWithFilters:filters completion:^(NSArray * _Nullable results, NSError * _Nullable error) {
        dispatch_async(dispatch_get_main_queue(), ^{
            __strong typeof(weakSelf) strongSelf = weakSelf;
            if (!strongSelf) return;
            [strongSelf endTesting];
            if (error) {
                NSString *desc = error.localizedDescription ?: @"Unknown error";
                [strongSelf setStatusText:[NSString stringWithFormat:@"✗ Key invalid: %@", desc] success:NO];
            } else if (results) {
                [strongSelf setStatusText:@"✓ Key valid" success:YES];
            } else {
                [strongSelf setStatusText:@"✗ Key invalid: the server returned no data" success:NO];
            }
            // Refresh the source hint (the state may have changed after saving)
            [strongSelf loadInitialValue];
        });
    }];
}

#pragma mark - Test state

- (void)beginTesting {
    _isTesting = YES;
    _saveButton.enabled = NO;
    _testButton.enabled = NO;
    _clearButton.enabled = NO;
    [_saveButton setAlpha:0.5];
    [_testButton setAlpha:0.5];
    [_clearButton setAlpha:0.5];
    [_testActivityIndicator startAnimating];
    [self setStatusText:@"Testing..." success:YES];
}

- (void)endTesting {
    _isTesting = NO;
    _saveButton.enabled = YES;
    _testButton.enabled = YES;
    _clearButton.enabled = YES;
    [_saveButton setAlpha:1.0];
    [_testButton setAlpha:1.0];
    [_clearButton setAlpha:1.0];
    [_testActivityIndicator stopAnimating];
}

- (void)setStatusText:(NSString *)text success:(BOOL)success {
    if (success) {
        _statusLabel.textColor = CFKSuccessColor();
    } else {
        _statusLabel.textColor = CFKErrorColor();
    }
    _statusLabel.text = text;
}

#pragma mark - UITextFieldDelegate

- (BOOL)textFieldShouldReturn:(UITextField *)textField {
    [textField resignFirstResponder];
    return YES;
}

- (void)textFieldDidEndEditing:(UITextField *)textField {
    // Refresh the source hint immediately
    [self loadInitialValue];
}

#pragma mark - Keyboard adaptation

- (void)registerKeyboardNotifications {
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(keyboardWillChangeFrame:)
                                                 name:UIKeyboardWillChangeFrameNotification
                                               object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(keyboardWillHide:)
                                                 name:UIKeyboardWillHideNotification
                                               object:nil];
}

- (void)keyboardWillChangeFrame:(NSNotification *)notification {
    NSValue *endFrameValue = notification.userInfo[UIKeyboardFrameEndUserInfoKey];
    CGRect endFrame = [endFrameValue CGRectValue];
    NSTimeInterval duration = [notification.userInfo[UIKeyboardAnimationDurationUserInfoKey] doubleValue];
    // Convert into the current view coordinate space
    CGRect converted = [self.view convertRect:endFrame fromView:nil];
    CGFloat overlap = MAX(0, self.view.bounds.size.height - converted.origin.y);
    _keyboardOffset = overlap;
    [self updateScrollViewBottomWithOffset:overlap duration:duration];
}

- (void)keyboardWillHide:(NSNotification *)notification {
    NSTimeInterval duration = [notification.userInfo[UIKeyboardAnimationDurationUserInfoKey] doubleValue];
    _keyboardOffset = 0;
    [self updateScrollViewBottomWithOffset:0 duration:duration];
}

- (void)updateScrollViewBottomWithOffset:(CGFloat)offset duration:(NSTimeInterval)duration {
    // When the keyboard appears, raise the bottom of the scrollView so the text field is not hidden
    [self.view layoutIfNeeded];
    self.scrollViewBottomConstraint.constant = -offset;
    [UIView animateWithDuration:duration animations:^{
        [self.view layoutIfNeeded];
    }];
}

#pragma mark - dealloc

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

@end
