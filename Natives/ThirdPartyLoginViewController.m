//
//  ThirdPartyLoginViewController.m
//  Flux
//
//  Modeled on Android FCL: the LittleSkin / custom third-party login form page
//

#import "ThirdPartyLoginViewController.h"
#import "authenticator/ThirdPartyAuthenticator.h"
#import "BackgroundManager.h"
#import "ios_uikit_bridge.h"
#import "utils.h"

@interface ThirdPartyLoginViewController () <UITextFieldDelegate>

@property (nonatomic, strong) UIScrollView *scrollView;
@property (nonatomic, strong) UIStackView *contentStack;

@property (nonatomic, strong) UIView *headerCard;
@property (nonatomic, strong) UIImageView *headerIcon;
@property (nonatomic, strong) UILabel *headerTitle;
@property (nonatomic, strong) UILabel *headerSubtitle;

@property (nonatomic, strong) UIView *usernameCard;
@property (nonatomic, strong) UITextField *usernameField;

@property (nonatomic, strong) UIView *passwordCard;
@property (nonatomic, strong) UITextField *passwordField;

@property (nonatomic, strong) UIView *serverCard; // Shown in Custom mode only
@property (nonatomic, strong) UITextField *serverField;

@property (nonatomic, strong) UIButton *loginButton;
@property (nonatomic, strong) UIActivityIndicatorView *loginIndicator;
@property (nonatomic, strong) UILabel *errorLabel;

@end

@implementation ThirdPartyLoginViewController

#pragma mark - Lifecycle

- (void)viewDidLoad {
    [super viewDidLoad];
    // Adapt to the custom launcher background: make this view controller transparent so the global wallpaper shows through
    [[BackgroundManager sharedManager] makeViewControllerTransparent:self];
    self.view.backgroundColor = [UIColor clearColor];
    self.title = (self.mode == ThirdPartyLoginModeLittleSkin) ? @"LittleSkin sign-in" : @"Third-party sign-in";

    [self setupUI];
    [[BackgroundManager sharedManager] applyBackgroundToView:self.view];

    // Tap on empty space to dismiss the keyboard
    UITapGestureRecognizer *tap = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(dismissKeyboard)];
    tap.cancelsTouchesInView = NO;
    [self.view addGestureRecognizer:tap];

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

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    [self.navigationController setNavigationBarHidden:NO animated:YES];
}

#pragma mark - Setup

- (void)setupUI {
    self.scrollView = [[UIScrollView alloc] init];
    self.scrollView.translatesAutoresizingMaskIntoConstraints = NO;
    self.scrollView.alwaysBounceVertical = YES;
    self.scrollView.keyboardDismissMode = UIScrollViewKeyboardDismissModeInteractive;
    self.scrollView.backgroundColor = [UIColor clearColor];
    [self.view addSubview:self.scrollView];

    self.contentStack = [[UIStackView alloc] init];
    self.contentStack.translatesAutoresizingMaskIntoConstraints = NO;
    self.contentStack.axis = UILayoutConstraintAxisVertical;
    self.contentStack.spacing = 16;
    self.contentStack.alignment = UIStackViewAlignmentFill;
    [self.scrollView addSubview:self.contentStack];

    [NSLayoutConstraint activateConstraints:@[
        [self.scrollView.topAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.topAnchor],
        [self.scrollView.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [self.scrollView.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [self.scrollView.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor],

        [self.contentStack.topAnchor constraintEqualToAnchor:self.scrollView.contentLayoutGuide.topAnchor constant:20],
        [self.contentStack.leadingAnchor constraintEqualToAnchor:self.scrollView.contentLayoutGuide.leadingAnchor constant:20],
        [self.contentStack.trailingAnchor constraintEqualToAnchor:self.scrollView.contentLayoutGuide.trailingAnchor constant:-20],
        [self.contentStack.bottomAnchor constraintEqualToAnchor:self.scrollView.contentLayoutGuide.bottomAnchor constant:-20],
        [self.contentStack.widthAnchor constraintEqualToAnchor:self.scrollView.frameLayoutGuide.widthAnchor constant:-40],
    ]];

    [self buildHeaderCard];
    [self.contentStack addArrangedSubview:self.headerCard];

    [self buildUsernameCard];
    [self.contentStack addArrangedSubview:self.usernameCard];

    [self buildPasswordCard];
    [self.contentStack addArrangedSubview:self.passwordCard];

    if (self.mode == ThirdPartyLoginModeCustom) {
        [self buildServerCard];
        [self.contentStack addArrangedSubview:self.serverCard];
    }

    // Error notice (hidden by default)
    self.errorLabel = [[UILabel alloc] init];
    self.errorLabel.translatesAutoresizingMaskIntoConstraints = NO;
    self.errorLabel.font = [UIFont systemFontOfSize:13];
    self.errorLabel.textColor = [UIColor systemRedColor];
    self.errorLabel.numberOfLines = 0;
    self.errorLabel.textAlignment = NSTextAlignmentCenter;
    self.errorLabel.hidden = YES;
    [self.contentStack addArrangedSubview:self.errorLabel];

    [self buildLoginButton];
    [self.contentStack addArrangedSubview:self.loginButton];

    // Register for keyboard events and scroll so nothing is covered
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(keyboardWillShow:)
                                                 name:UIKeyboardWillShowNotification
                                               object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(keyboardWillHide:)
                                                 name:UIKeyboardWillHideNotification
                                               object:nil];
}

- (void)buildHeaderCard {
    self.headerCard = [[UIView alloc] init];
    self.headerCard.translatesAutoresizingMaskIntoConstraints = NO;
    self.headerCard.backgroundColor = [UIColor secondarySystemBackgroundColor];
    self.headerCard.layer.cornerRadius = 16;
    [[BackgroundManager sharedManager] applyEffectToView:self.headerCard];

    self.headerIcon = [[UIImageView alloc] init];
    self.headerIcon.translatesAutoresizingMaskIntoConstraints = NO;
    self.headerIcon.contentMode = UIViewContentModeScaleAspectFit;

    self.headerTitle = [[UILabel alloc] init];
    self.headerTitle.translatesAutoresizingMaskIntoConstraints = NO;
    self.headerTitle.font = [UIFont systemFontOfSize:18 weight:UIFontWeightBold];
    self.headerTitle.textColor = [UIColor labelColor];

    self.headerSubtitle = [[UILabel alloc] init];
    self.headerSubtitle.translatesAutoresizingMaskIntoConstraints = NO;
    self.headerSubtitle.font = [UIFont systemFontOfSize:13];
    self.headerSubtitle.textColor = [UIColor secondaryLabelColor];
    self.headerSubtitle.numberOfLines = 0;

    if (self.mode == ThirdPartyLoginModeLittleSkin) {
        self.headerIcon.image = [UIImage systemImageNamed:@"person.fill.viewfinder"]
                              ?: [UIImage systemImageNamed:@"person.crop.circle.fill"];
        self.headerIcon.tintColor = [UIColor systemPurpleColor];
        self.headerTitle.text = @"LittleSkin";
        self.headerSubtitle.text = @"A widely used authlib-injector skin site; register at littleskin.cn first";
    } else {
        self.headerIcon.image = [UIImage systemImageNamed:@"globe"];
        self.headerIcon.tintColor = [UIColor systemOrangeColor];
        self.headerTitle.text = @"Custom third-party sign-in";
        self.headerSubtitle.text = @"Supports any Yggdrasil-compatible authlib-injector server (LittleSkin, Blessing Skin, and so on); enter the API root address";
    }

    [self.headerCard addSubview:self.headerIcon];
    [self.headerCard addSubview:self.headerTitle];
    [self.headerCard addSubview:self.headerSubtitle];

    [NSLayoutConstraint activateConstraints:@[
        [self.headerIcon.leadingAnchor constraintEqualToAnchor:self.headerCard.leadingAnchor constant:16],
        [self.headerIcon.topAnchor constraintEqualToAnchor:self.headerCard.topAnchor constant:18],
        [self.headerIcon.widthAnchor constraintEqualToConstant:34],
        [self.headerIcon.heightAnchor constraintEqualToConstant:34],

        [self.headerTitle.leadingAnchor constraintEqualToAnchor:self.headerIcon.trailingAnchor constant:12],
        [self.headerTitle.centerYAnchor constraintEqualToAnchor:self.headerIcon.centerYAnchor],
        [self.headerTitle.trailingAnchor constraintEqualToAnchor:self.headerCard.trailingAnchor constant:-16],

        [self.headerSubtitle.leadingAnchor constraintEqualToAnchor:self.headerCard.leadingAnchor constant:16],
        [self.headerSubtitle.topAnchor constraintEqualToAnchor:self.headerIcon.bottomAnchor constant:10],
        [self.headerSubtitle.trailingAnchor constraintEqualToAnchor:self.headerCard.trailingAnchor constant:-16],
        [self.headerSubtitle.bottomAnchor constraintEqualToAnchor:self.headerCard.bottomAnchor constant:-16],
    ]];
}

/// Build a uniform input card: an SF Symbol icon on the left + a UITextField on the right
/// Returns the card view and assigns the created UITextField to outField (optional)
- (UIView *)buildInputCardWithIcon:(NSString *)iconName
                       accentColor:(UIColor *)accentColor
                        placeholder:(NSString *)placeholder
                            isSecure:(BOOL)isSecure
                        keyboardType:(UIKeyboardType)keyboardType
                         returnField:(UITextField **)outField {
    UIView *card = [[UIView alloc] init];
    card.translatesAutoresizingMaskIntoConstraints = NO;
    card.backgroundColor = [UIColor secondarySystemBackgroundColor];
    card.layer.cornerRadius = 14;
    [[BackgroundManager sharedManager] applyEffectToView:card];

    UIImageView *icon = [[UIImageView alloc] init];
    icon.translatesAutoresizingMaskIntoConstraints = NO;
    icon.image = [UIImage systemImageNamed:iconName];
    icon.tintColor = accentColor;
    icon.contentMode = UIViewContentModeScaleAspectFit;
    [card addSubview:icon];

    UITextField *field = [[UITextField alloc] init];
    field.translatesAutoresizingMaskIntoConstraints = NO;
    field.placeholder = placeholder;
    field.font = [UIFont systemFontOfSize:16];
    field.textColor = [UIColor labelColor];
    field.secureTextEntry = isSecure;
    field.keyboardType = keyboardType;
    field.autocapitalizationType = UITextAutocapitalizationTypeNone;
    field.autocorrectionType = UITextAutocorrectionTypeNo;
    field.clearButtonMode = UITextFieldViewModeWhileEditing;
    field.delegate = self;
    field.returnKeyType = UIReturnKeyNext;
    [card addSubview:field];

    [NSLayoutConstraint activateConstraints:@[
        [icon.leadingAnchor constraintEqualToAnchor:card.leadingAnchor constant:14],
        [icon.centerYAnchor constraintEqualToAnchor:card.centerYAnchor],
        [icon.widthAnchor constraintEqualToConstant:22],
        [icon.heightAnchor constraintEqualToConstant:22],

        [field.leadingAnchor constraintEqualToAnchor:icon.trailingAnchor constant:12],
        [field.trailingAnchor constraintEqualToAnchor:card.trailingAnchor constant:-14],
        [field.topAnchor constraintEqualToAnchor:card.topAnchor constant:14],
        [field.bottomAnchor constraintEqualToAnchor:card.bottomAnchor constant:-14],
    ]];

    if (outField) *outField = field;
    return card;
}

- (void)buildUsernameCard {
    UITextField *field = nil;
    self.usernameCard = [self buildInputCardWithIcon:@"person"
                                         accentColor:[UIColor systemBlueColor]
                                          placeholder:@"Username / email"
                                            isSecure:NO
                                        keyboardType:UIKeyboardTypeDefault
                                         returnField:&field];
    self.usernameField = field;
}

- (void)buildPasswordCard {
    UITextField *field = nil;
    self.passwordCard = [self buildInputCardWithIcon:@"lock"
                                         accentColor:[UIColor systemBlueColor]
                                          placeholder:@"Password"
                                            isSecure:YES
                                        keyboardType:UIKeyboardTypeDefault
                                         returnField:&field];
    self.passwordField = field;
    self.passwordField.returnKeyType = (self.mode == ThirdPartyLoginModeCustom) ? UIReturnKeyNext : UIReturnKeyGo;
}

- (void)buildServerCard {
    UITextField *field = nil;
    self.serverCard = [self buildInputCardWithIcon:@"link"
                                       accentColor:[UIColor systemBlueColor]
                                        placeholder:@"API address (e.g. https://littleskin.cn/api/yggdrasil)"
                                          isSecure:NO
                                      keyboardType:UIKeyboardTypeURL
                                       returnField:&field];
    self.serverField = field;
    self.serverField.text = @"https://littleskin.cn/api/yggdrasil";
    self.serverField.returnKeyType = UIReturnKeyGo;
}

- (void)buildLoginButton {
    self.loginButton = [UIButton buttonWithType:UIButtonTypeSystem];
    self.loginButton.translatesAutoresizingMaskIntoConstraints = NO;
    [self.loginButton setTitle:@"Sign in" forState:UIControlStateNormal];
    [self.loginButton setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    self.loginButton.titleLabel.font = [UIFont boldSystemFontOfSize:17];
    UIColor *accent = (self.mode == ThirdPartyLoginModeLittleSkin)
                        ? [UIColor systemPurpleColor]
                        : [UIColor systemOrangeColor];
    self.loginButton.backgroundColor = accent;
    self.loginButton.layer.cornerRadius = 14;
    [self.loginButton addTarget:self action:@selector(loginTapped) forControlEvents:UIControlEventTouchUpInside];

    self.loginIndicator = [[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleWhite];
    self.loginIndicator.translatesAutoresizingMaskIntoConstraints = NO;
    self.loginIndicator.hidesWhenStopped = YES;
    [self.loginButton addSubview:self.loginIndicator];

    [NSLayoutConstraint activateConstraints:@[
        [self.loginButton.heightAnchor constraintEqualToConstant:50],
        [self.loginIndicator.centerXAnchor constraintEqualToAnchor:self.loginButton.centerXAnchor],
        [self.loginIndicator.centerYAnchor constraintEqualToAnchor:self.loginButton.centerYAnchor],
    ]];
}

#pragma mark - Actions

- (void)dismissKeyboard {
    [self.view endEditing:YES];
}

- (void)loginTapped {
    [self dismissKeyboard];
    [self hideError];

    NSString *username = self.usernameField.text ?: @"";
    NSString *password = self.passwordField.text ?: @"";
    NSString *serverURL = nil;
    if (self.mode == ThirdPartyLoginModeCustom) {
        serverURL = (self.serverField.text.length > 0) ? self.serverField.text : nil;
    } else {
        serverURL = @"https://littleskin.cn/api/yggdrasil";
    }

    // Input validation
    if (username.length == 0 || password.length == 0) {
        [self showError:@"Username and password cannot be empty"];
        return;
    }
    if (self.mode == ThirdPartyLoginModeCustom) {
        if (serverURL.length == 0) {
            [self showError:@"Please enter the server address"];
            return;
        }
        NSURL *url = [NSURL URLWithString:serverURL];
        if (!url || !url.scheme || !url.host) {
            [self showError:@"Invalid server address format"];
            return;
        }
    }

    [self setLoginInProgress:YES];

    // Following the authlib-injector launcher technical specification: resolve the ALI before logging in, expanding the shorthand address into a full API root
    // At the same time prefetch the server metadata, to pass -Dauthlibinjector.yggdrasil.prefetched at launch
    [self showError:@"Resolving the server address..."];
    self.errorLabel.textColor = [UIColor secondaryLabelColor];

    __weak typeof(self) weakSelf = self;
    [ThirdPartyAuthenticator resolveAuthserverURL:serverURL completion:^(NSString *resolvedURL, NSString *metadata) {
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf) return;

        [strongSelf hideError];

        ThirdPartyAuthenticator *auth = [[ThirdPartyAuthenticator alloc] initWithInput:username];
        auth.authData[@"password"] = password;
        auth.authData[@"authserver"] = resolvedURL;
        // Cache the metadata for getJvmArgsForAuthlib to use
        if (metadata.length > 0) {
            auth.authData[@"prefetchedMetadata"] = metadata;
        }

        id callback = ^(id status, BOOL success) {
            dispatch_async(dispatch_get_main_queue(), ^{
                __strong typeof(weakSelf) sSelf = weakSelf;
                if (!sSelf) return;

                // "Progress" messages with status code 0 (such as downloading authlib-injector) are not the final result
                if (success && [status isKindOfClass:[NSError class]] &&
                    [(NSError *)status code] == 0) {
                    NSString *msg = [(NSError *)status localizedDescription];
                    if (msg.length > 0) {
                        [sSelf.errorLabel setText:msg];
                        sSelf.errorLabel.textColor = [UIColor secondaryLabelColor];
                        sSelf.errorLabel.hidden = NO;
                    }
                    return;
                }

                [sSelf setLoginInProgress:NO];

                if (success && (status == nil ||
                                ([status isKindOfClass:[NSString class]] && [status isEqualToString:@"DEMO"]))) {
                    if ([status isKindOfClass:[NSString class]] && [status isEqualToString:@"DEMO"]) {
                        showDialog(localize(@"login.warn.title.demomode", nil),
                                   localize(@"login.warn.message.demomode", nil));
                    }
                    if (sSelf.onLoginComplete) {
                        sSelf.onLoginComplete(YES, nil);
                    }
                    return;
                }

                // Failure
                NSString *errMsg;
                if ([status isKindOfClass:[NSError class]]) {
                    errMsg = [(NSError *)status localizedDescription];
                } else if ([status isKindOfClass:[NSString class]]) {
                    errMsg = status;
                } else {
                    errMsg = @"Sign-in failed, please try again";
                }
                [sSelf showError:errMsg];
                if (sSelf.onLoginComplete) {
                    sSelf.onLoginComplete(NO, errMsg);
                }
            });
        };

        [auth loginWithCallback:callback];
    }];
}

- (void)setLoginInProgress:(BOOL)inProgress {
    self.loginButton.userInteractionEnabled = !inProgress;
    self.usernameField.userInteractionEnabled = !inProgress;
    self.passwordField.userInteractionEnabled = !inProgress;
    self.serverField.userInteractionEnabled = !inProgress;

    if (inProgress) {
        [self.loginIndicator startAnimating];
        [self.loginButton setTitle:@"" forState:UIControlStateNormal];
        self.loginButton.alpha = 0.85;
    } else {
        [self.loginIndicator stopAnimating];
        [self.loginButton setTitle:@"Sign in" forState:UIControlStateNormal];
        self.loginButton.alpha = 1.0;
    }
}

- (void)showError:(NSString *)message {
    self.errorLabel.text = message;
    self.errorLabel.textColor = [UIColor systemRedColor];
    self.errorLabel.hidden = NO;
}

- (void)hideError {
    self.errorLabel.hidden = YES;
    self.errorLabel.text = @"";
}

#pragma mark - UITextFieldDelegate

- (BOOL)textFieldShouldReturn:(UITextField *)textField {
    if (textField == self.usernameField) {
        [self.passwordField becomeFirstResponder];
    } else if (textField == self.passwordField) {
        if (self.mode == ThirdPartyLoginModeCustom && self.serverField) {
            [self.serverField becomeFirstResponder];
        } else {
            [self loginTapped];
        }
    } else if (textField == self.serverField) {
        [self loginTapped];
    }
    return YES;
}

#pragma mark - Keyboard

- (void)keyboardWillShow:(NSNotification *)notification {
    CGRect endFrame = [notification.userInfo[UIKeyboardFrameEndUserInfoKey] CGRectValue];
    CGFloat keyboardHeight = endFrame.size.height;
    UIEdgeInsets insets = self.scrollView.contentInset;
    insets.bottom = keyboardHeight + 20;
    self.scrollView.contentInset = insets;
    self.scrollView.scrollIndicatorInsets = insets;
}

- (void)keyboardWillHide:(NSNotification *)notification {
    UIEdgeInsets insets = UIEdgeInsetsZero;
    self.scrollView.contentInset = insets;
    self.scrollView.scrollIndicatorInsets = insets;
}

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

@end
