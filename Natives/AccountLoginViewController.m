//
//  AccountLoginViewController.m
//  Flux
//
//  Modelled on the account login screens of FCL (Fold Craft Launcher) and HMCL:
//  - Title area at the top (large title + subtitle)
//  - Four tappable login-method cards (Microsoft / LittleSkin / custom third-party / local)
//  - Each card: colored icon circle on the left + title/description in the middle + chevron on the right
//  - Adapts to the custom launcher background (transparent view + frosted-glass cards)
//  - Uses UIButton instead of UIControl to avoid touch-interception problems
//

#import "AccountLoginViewController.h"
#import "BackgroundManager.h"
#import "ScreenUtils.h"
#import "utils.h"

@interface AccountLoginViewController () <UIScrollViewDelegate>
@property (nonatomic, strong) UIScrollView *scrollView;
@property (nonatomic, strong) UIStackView *cardStack;
@property (nonatomic, strong) UIView *headerContainer;
@property (nonatomic, strong) UILabel *headerTitleLabel;
@property (nonatomic, strong) UILabel *headerSubtitleLabel;
@end

@implementation AccountLoginViewController

#pragma mark - Lifecycle

- (void)viewDidLoad {
    [super viewDidLoad];
    // Adapt to the custom launcher background: make this view controller transparent so the global wallpaper shows through
    [[BackgroundManager sharedManager] makeViewControllerTransparent:self];
    self.title = @"Add account";
    // Transparent background so the custom launcher background shows through (applyBackgroundToView adds it beneath the window/splitVC)
    self.view.backgroundColor = [UIColor clearColor];

    [self setupUI];
    // Apply the background (walk the responder chain to find splitVC/window and insert the background at the very bottom)
    [[BackgroundManager sharedManager] applyBackgroundToView:self.view];

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

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    // Make sure the scrollView contentSize is correct
    [self.scrollView layoutIfNeeded];
}

#pragma mark - Setup

- (void)setupUI {
    // ScrollView container
    self.scrollView = [[UIScrollView alloc] init];
    self.scrollView.translatesAutoresizingMaskIntoConstraints = NO;
    self.scrollView.alwaysBounceVertical = YES;
    self.scrollView.backgroundColor = [UIColor clearColor];
    self.scrollView.delegate = self;
    self.scrollView.showsVerticalScrollIndicator = NO;
    [self.view addSubview:self.scrollView];

    // Card stack
    self.cardStack = [[UIStackView alloc] init];
    self.cardStack.translatesAutoresizingMaskIntoConstraints = NO;
    self.cardStack.axis = UILayoutConstraintAxisVertical;
    self.cardStack.spacing = [ScreenUtils dp:14];
    self.cardStack.alignment = UIStackViewAlignmentFill;
    [self.scrollView addSubview:self.cardStack];

    [NSLayoutConstraint activateConstraints:@[
        [self.scrollView.topAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.topAnchor],
        [self.scrollView.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [self.scrollView.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [self.scrollView.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor],

        [self.cardStack.topAnchor constraintEqualToAnchor:self.scrollView.contentLayoutGuide.topAnchor constant:[ScreenUtils dp:20]],
        [self.cardStack.leadingAnchor constraintEqualToAnchor:self.scrollView.contentLayoutGuide.leadingAnchor constant:[ScreenUtils dp:20]],
        [self.cardStack.trailingAnchor constraintEqualToAnchor:self.scrollView.contentLayoutGuide.trailingAnchor constant:-[ScreenUtils dp:20]],
        [self.cardStack.bottomAnchor constraintEqualToAnchor:self.scrollView.contentLayoutGuide.bottomAnchor constant:-[ScreenUtils dp:20]],
        [self.cardStack.widthAnchor constraintEqualToAnchor:self.scrollView.frameLayoutGuide.widthAnchor constant:-[ScreenUtils dp:40]],
    ]];

    // Title area
    [self setupHeader];

    // Spacing
    [self.cardStack addArrangedSubview:[self spacerViewWithHeight:[ScreenUtils dp:8]]];

    // The four login cards
    [self.cardStack addArrangedSubview:[self createLoginCardWithType:AccountLoginTypeMicrosoft
                                                                title:@"Microsoft account"
                                                          description:@"Sign in with a Microsoft account (genuine copy)"
                                                           iconName:@"xbox.logo"
                                                       fallbackIcon:@"person.crop.circle.fill"
                                                          accentColor:[UIColor colorWithRed:0.0 green:0.45 blue:0.93 alpha:1.0]]];
    [self.cardStack addArrangedSubview:[self createLoginCardWithType:AccountLoginTypeLittleSkin
                                                                title:@"LittleSkin"
                                                          description:@"Sign in with a LittleSkin skin-site account (registration required)"
                                                           iconName:@"person.fill.viewfinder"
                                                       fallbackIcon:@"person.crop.circle.fill"
                                                          accentColor:[UIColor colorWithRed:0.55 green:0.30 blue:0.85 alpha:1.0]]];
    [self.cardStack addArrangedSubview:[self createLoginCardWithType:AccountLoginTypeThirdParty
                                                                title:@"Custom third-party"
                                                          description:@"Supports any Yggdrasil-compatible authlib-injector server"
                                                           iconName:@"globe"
                                                       fallbackIcon:@"globe"
                                                          accentColor:[UIColor colorWithRed:0.90 green:0.55 blue:0.15 alpha:1.0]]];
    [self.cardStack addArrangedSubview:[self createLoginCardWithType:AccountLoginTypeLocal
                                                                title:@"Local account"
                                                          description:@"Offline mode, just enter a username (cannot join genuine servers)"
                                                           iconName:@"person.fill"
                                                       fallbackIcon:@"person.fill"
                                                          accentColor:[UIColor colorWithRed:0.50 green:0.55 blue:0.60 alpha:1.0]]];
}

/// Title area at the top (FCL/HMCL style: large title + subtitle)
- (void)setupHeader {
    self.headerContainer = [[UIView alloc] init];
    self.headerContainer.translatesAutoresizingMaskIntoConstraints = NO;
    [self.cardStack addArrangedSubview:self.headerContainer];

    self.headerTitleLabel = [[UILabel alloc] init];
    self.headerTitleLabel.translatesAutoresizingMaskIntoConstraints = NO;
    self.headerTitleLabel.text = @"Choose sign-in method";
    self.headerTitleLabel.font = [UIFont systemFontOfSize:[ScreenUtils sp:26] weight:UIFontWeightBold];
    self.headerTitleLabel.textColor = [UIColor whiteColor];
    self.headerTitleLabel.numberOfLines = 1;
    [self.headerContainer addSubview:self.headerTitleLabel];

    self.headerSubtitleLabel = [[UILabel alloc] init];
    self.headerSubtitleLabel.translatesAutoresizingMaskIntoConstraints = NO;
    self.headerSubtitleLabel.text = @"Choose a way to sign in to your Minecraft account";
    self.headerSubtitleLabel.font = [UIFont systemFontOfSize:[ScreenUtils sp:14] weight:UIFontWeightRegular];
    self.headerSubtitleLabel.textColor = [[UIColor whiteColor] colorWithAlphaComponent:0.65];
    self.headerSubtitleLabel.numberOfLines = 0;
    [self.headerContainer addSubview:self.headerSubtitleLabel];

    [NSLayoutConstraint activateConstraints:@[
        [self.headerTitleLabel.topAnchor constraintEqualToAnchor:self.headerContainer.topAnchor],
        [self.headerTitleLabel.leadingAnchor constraintEqualToAnchor:self.headerContainer.leadingAnchor],
        [self.headerTitleLabel.trailingAnchor constraintEqualToAnchor:self.headerContainer.trailingAnchor],

        [self.headerSubtitleLabel.topAnchor constraintEqualToAnchor:self.headerTitleLabel.bottomAnchor constant:[ScreenUtils dp:6]],
        [self.headerSubtitleLabel.leadingAnchor constraintEqualToAnchor:self.headerContainer.leadingAnchor],
        [self.headerSubtitleLabel.trailingAnchor constraintEqualToAnchor:self.headerContainer.trailingAnchor],
        [self.headerSubtitleLabel.bottomAnchor constraintEqualToAnchor:self.headerContainer.bottomAnchor],
    ]];
}

/// Build one login-method card (FCL/HMCL style)
/// Uses UIButton instead of UIControl so touch events fire reliably
- (UIView *)createLoginCardWithType:(AccountLoginType)type
                              title:(NSString *)title
                        description:(NSString *)description
                         iconName:(NSString *)iconName
                     fallbackIcon:(NSString *)fallbackIcon
                        accentColor:(UIColor *)accentColor {
    // Card container (UIView + gesture); a plain UIButton is not used because the internal layout is complex
    // UIView + UITapGestureRecognizer instead of UIControl, to avoid UIVisualEffectView intercepting touches
    UIView *card = [[UIView alloc] init];
    card.translatesAutoresizingMaskIntoConstraints = NO;
    card.layer.cornerRadius = [ScreenUtils dp:16];
    card.layer.cornerCurve = kCACornerCurveContinuous;
    card.layer.borderWidth = 0.5;
    card.layer.borderColor = [[UIColor whiteColor] colorWithAlphaComponent:0.12].CGColor;
    // Enable touch interaction
    card.userInteractionEnabled = YES;

    // Frosted-glass background (applyEffectToView guarantees blurView.userInteractionEnabled = NO)
    [[BackgroundManager sharedManager] applyEffectToView:card];

    // Icon circle on the left (light accentColor fill + SF Symbol)
    UIView *iconCircle = [[UIView alloc] init];
    iconCircle.translatesAutoresizingMaskIntoConstraints = NO;
    iconCircle.backgroundColor = [accentColor colorWithAlphaComponent:0.18];
    iconCircle.layer.cornerRadius = [ScreenUtils dp:24];
    iconCircle.userInteractionEnabled = NO;
    [card addSubview:iconCircle];

    UIImageView *iconView = [[UIImageView alloc] init];
    iconView.translatesAutoresizingMaskIntoConstraints = NO;
    UIImage *icon = [UIImage systemImageNamed:iconName] ?: [UIImage systemImageNamed:fallbackIcon];
    iconView.image = icon;
    iconView.tintColor = accentColor;
    iconView.contentMode = UIViewContentModeScaleAspectFit;
    iconView.userInteractionEnabled = NO;
    [iconCircle addSubview:iconView];

    // Title in the middle
    UILabel *titleLabel = [[UILabel alloc] init];
    titleLabel.translatesAutoresizingMaskIntoConstraints = NO;
    titleLabel.text = title;
    titleLabel.font = [UIFont systemFontOfSize:[ScreenUtils sp:17] weight:UIFontWeightSemibold];
    titleLabel.textColor = [UIColor whiteColor];
    titleLabel.numberOfLines = 1;
    titleLabel.userInteractionEnabled = NO;
    [card addSubview:titleLabel];

    // Description in the middle
    UILabel *descLabel = [[UILabel alloc] init];
    descLabel.translatesAutoresizingMaskIntoConstraints = NO;
    descLabel.text = description;
    descLabel.font = [UIFont systemFontOfSize:[ScreenUtils sp:13] weight:UIFontWeightRegular];
    descLabel.textColor = [[UIColor whiteColor] colorWithAlphaComponent:0.60];
    descLabel.numberOfLines = 0;
    descLabel.userInteractionEnabled = NO;
    [card addSubview:descLabel];

    // Chevron on the right
    UIImageView *chevron = [[UIImageView alloc] init];
    chevron.translatesAutoresizingMaskIntoConstraints = NO;
    chevron.image = [UIImage systemImageNamed:@"chevron.right"];
    chevron.tintColor = [[UIColor whiteColor] colorWithAlphaComponent:0.40];
    chevron.contentMode = UIViewContentModeScaleAspectFit;
    chevron.userInteractionEnabled = NO;
    [card addSubview:chevron];

    // Layout constraints
    CGFloat padding = [ScreenUtils dp:16];
    CGFloat iconSize = [ScreenUtils dp:48];
    CGFloat iconInset = [ScreenUtils dp:24];

    [NSLayoutConstraint activateConstraints:@[
        [iconCircle.leadingAnchor constraintEqualToAnchor:card.leadingAnchor constant:padding],
        [iconCircle.centerYAnchor constraintEqualToAnchor:card.centerYAnchor],
        [iconCircle.widthAnchor constraintEqualToConstant:iconSize],
        [iconCircle.heightAnchor constraintEqualToConstant:iconSize],

        [iconView.centerXAnchor constraintEqualToAnchor:iconCircle.centerXAnchor],
        [iconView.centerYAnchor constraintEqualToAnchor:iconCircle.centerYAnchor],
        [iconView.widthAnchor constraintEqualToConstant:iconInset],
        [iconView.heightAnchor constraintEqualToConstant:iconInset],

        [titleLabel.leadingAnchor constraintEqualToAnchor:iconCircle.trailingAnchor constant:[ScreenUtils dp:14]],
        [titleLabel.topAnchor constraintEqualToAnchor:card.topAnchor constant:[ScreenUtils dp:18]],
        [titleLabel.trailingAnchor constraintEqualToAnchor:chevron.leadingAnchor constant:-[ScreenUtils dp:8]],

        [descLabel.leadingAnchor constraintEqualToAnchor:titleLabel.leadingAnchor],
        [descLabel.topAnchor constraintEqualToAnchor:titleLabel.bottomAnchor constant:[ScreenUtils dp:4]],
        [descLabel.trailingAnchor constraintEqualToAnchor:titleLabel.trailingAnchor],
        [descLabel.bottomAnchor constraintEqualToAnchor:card.bottomAnchor constant:-[ScreenUtils dp:18]],

        [chevron.trailingAnchor constraintEqualToAnchor:card.trailingAnchor constant:-padding],
        [chevron.centerYAnchor constraintEqualToAnchor:card.centerYAnchor],
        [chevron.widthAnchor constraintEqualToConstant:[ScreenUtils dp:14]],
        [chevron.heightAnchor constraintEqualToConstant:[ScreenUtils dp:20]],
    ]];

    // Use UITapGestureRecognizer for taps (more reliable than UIControlEventTouchUpInside,
    // and not intercepted by the contentView of UIVisualEffectView)
    // Tags start at 1 so that 0 is not treated by UIKit as "no tag set"
    card.tag = type + 1;
    UITapGestureRecognizer *tapGesture = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(cardTapped:)];
    tapGesture.cancelsTouchesInView = NO;
    [card addGestureRecognizer:tapGesture];

    return card;
}

- (UIView *)spacerViewWithHeight:(CGFloat)height {
    UIView *spacer = [[UIView alloc] init];
    spacer.translatesAutoresizingMaskIntoConstraints = NO;
    [spacer.heightAnchor constraintEqualToConstant:height].active = YES;
    return spacer;
}

#pragma mark - Actions

/// Card tap handler (fired by the UITapGestureRecognizer)
- (void)cardTapped:(UITapGestureRecognizer *)gesture {
    UIView *card = gesture.view;
    if (!card) return;
    // Undo the tag offset (createLoginCardWithType stores it +1)
    AccountLoginType type = (AccountLoginType)(card.tag - 1);

    // Subtle highlight feedback (FCL style)
    [UIView animateWithDuration:0.1 animations:^{
        card.alpha = 0.65;
    } completion:^(BOOL finished) {
        [UIView animateWithDuration:0.1 animations:^{
            card.alpha = 1.0;
        } completion:^(BOOL finished2) {
            if (self.onSelectLoginType) {
                self.onSelectLoginType(type);
            }
        }];
    }];
}

@end
