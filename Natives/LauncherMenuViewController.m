#import "LauncherMenuViewController.h"
#import "LauncherPreferencesViewController.h"
#import "LauncherPreferences.h"
#import "VersionManagerViewController.h"
#import "ProfileSettingsViewController.h"
#import "PLProfiles.h"
#import "BackgroundManager.h"
#import "utils.h"

@interface LauncherMenuViewController ()

@property(nonatomic, strong) UIView *sidebarView;
@property(nonatomic, strong) UIStackView *menuStackView;
@property(nonatomic, strong) NSArray<NSDictionary *> *menuItems;
@property(nonatomic, assign) NSInteger selectedIndex;

@end

@implementation LauncherMenuViewController

#pragma mark - Lifecycle

- (void)viewDidLoad {
    [super viewDidLoad];

    self.view.backgroundColor = [UIColor clearColor];

    // Adapt to the custom launcher background: make this view controller transparent so the global background (image/video) shows through.
    // Even though this controller is added as a child VC of LauncherRootViewController, this still has to be called from its own viewDidLoad.
    [[BackgroundManager sharedManager] makeViewControllerTransparent:self];

    // Listen for background UI effect changes: when the user switches between frosted glass and translucent, or adjusts the opacity,
    // call makeViewControllerTransparent again to apply the latest look and keep the background showing correctly.
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(reapplyBackgroundEffect)
                                                 name:@"BackgroundUIEffectChanged"
                                               object:nil];

    // Listen for appearance changes (refreshing the menu button colors when the text color changes)
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(applyCustomAppearance)
                                                 name:@"LauncherAppearanceChanged"
                                               object:nil];

    // Menu item configuration
    // The multiplayer entry points are hidden for now (they need more work)
    // case 3 is "Multiplayer" (Terracotta, interoperable with HMCL/FCL/ZL2)
    // case 4 is "ZeroTier multiplayer" (a separate entry alongside Terracotta, so users can go straight to the ZeroTier screen)
    // case 5 is "Settings"
    // The control layout screen has moved into the settings page
    self.menuItems = @[
        @{@"icon": @"house.fill", @"title": @" ", @"index": @0},
        @{@"icon": @"arrow.down.circle.fill", @"title": @" ", @"index": @1},
        @{@"icon": @"puzzlepiece.fill", @"title": @" ", @"index": @2},
        // The two multiplayer icons are removed for now; to restore them, uncomment the two lines below and change the settings index back to @5
        // @{@"icon": @"antenna.radiowaves.left.and.right", @"title": @" ", @"index": @3},
        // @{@"icon": @"network", @"title": @" ", @"index": @4},
        @{@"icon": @"gearshape.fill", @"title": @" ", @"index": @3}
    ];
    
    self.selectedIndex = 0;
    
    [self setupSidebar];
}

#pragma mark - UI Setup

- (void)setupSidebar {
    self.sidebarView = [[UIView alloc] init];
    self.sidebarView.translatesAutoresizingMaskIntoConstraints = NO;
    self.sidebarView.backgroundColor = [UIColor clearColor];
    [self.view addSubview:self.sidebarView];

    [NSLayoutConstraint activateConstraints:@[
        [self.sidebarView.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [self.sidebarView.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [self.sidebarView.topAnchor constraintEqualToAnchor:self.view.topAnchor],
        [self.sidebarView.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor]
    ]];

    // Use a vertically distributed UIStackView instead of a fixed-offset layout.
    // Previously startY=60 with a fixed 15pt gap made 5 buttons 370pt tall, so on iPhone in landscape (where the card is not tall enough)
    // the 5th button (Settings) was clipped by the card masksToBounds, and since the buttons were only anchored at the top with no bottom constraint,
    // the large empty area below made "the gap at the bottom is too big" even more obvious.
    // A UIStackView with EqualSpacing distributes the buttons evenly through the available space with equal padding above and below,
    // so every button is fully visible whatever the card height, and the empty area caused by the fixed startY is gone.
    self.menuStackView = [[UIStackView alloc] init];
    self.menuStackView.translatesAutoresizingMaskIntoConstraints = NO;
    self.menuStackView.axis = UILayoutConstraintAxisVertical;
    self.menuStackView.distribution = UIStackViewDistributionEqualSpacing;
    self.menuStackView.alignment = UIStackViewAlignmentCenter;
    self.menuStackView.spacing = 8;
    [self.sidebarView addSubview:self.menuStackView];

    CGFloat buttonSize = 50;
    for (NSInteger i = 0; i < self.menuItems.count; i++) {
        NSDictionary *item = self.menuItems[i];
        UIButton *btn = [self createMenuButtonWithItem:item index:i];
        [self.menuStackView addArrangedSubview:btn];
        [NSLayoutConstraint activateConstraints:@[
            [btn.widthAnchor constraintEqualToConstant:buttonSize],
            [btn.heightAnchor constraintEqualToConstant:buttonSize]
        ]];
    }

    [NSLayoutConstraint activateConstraints:@[
        [self.menuStackView.leadingAnchor constraintEqualToAnchor:self.sidebarView.leadingAnchor],
        [self.menuStackView.trailingAnchor constraintEqualToAnchor:self.sidebarView.trailingAnchor],
        [self.menuStackView.topAnchor constraintEqualToAnchor:self.sidebarView.topAnchor constant:8],
        [self.menuStackView.bottomAnchor constraintEqualToAnchor:self.sidebarView.bottomAnchor constant:-8],
        [self.menuStackView.centerXAnchor constraintEqualToAnchor:self.sidebarView.centerXAnchor]
    ]];
}

- (UIButton *)createMenuButtonWithItem:(NSDictionary *)item index:(NSInteger)index {
    UIButton *btn = [UIButton buttonWithType:UIButtonTypeSystem];
    btn.translatesAutoresizingMaskIntoConstraints = NO;
    btn.tag = index;

    // Set the icon
    UIImage *icon = [UIImage systemImageNamed:item[@"icon"]];
    [btn setImage:icon forState:UIControlStateNormal];

    // Set the color - the selected item is highlighted
    // Custom text color support: once the user sets general.text_color in settings,
    // unselected items use that color while the selected one stays highlight blue
    UIColor *normalColor = [self menuNormalColor];
    UIColor *accent = accentColor();
    if (index == self.selectedIndex) {
        btn.tintColor = accent;
    } else {
        btn.tintColor = normalColor;
    }

    // Set the title (below the icon)
    btn.titleLabel.font = [UIFont systemFontOfSize:10];
    [btn setTitle:item[@"title"] forState:UIControlStateNormal];
    [btn setTitleColor:(index == self.selectedIndex) ? accent : normalColor forState:UIControlStateNormal];
    
    // Vertical layout: icon on top, text underneath
    btn.contentHorizontalAlignment = UIControlContentHorizontalAlignmentCenter;
    btn.contentVerticalAlignment = UIControlContentVerticalAlignmentCenter;
    btn.titleEdgeInsets = UIEdgeInsetsMake(30, -30, 0, 0);
    btn.imageEdgeInsets = UIEdgeInsetsMake(-10, 0, 0, 0);
    
    [btn addTarget:self action:@selector(menuButtonTapped:) forControlEvents:UIControlEventTouchUpInside];

    // Uniform corner radius: 10pt set defensively, so adding a highlight background to the selected state later does not produce square blocks
    btn.layer.cornerRadius = 10;
    btn.layer.masksToBounds = YES;

    return btn;
}

#pragma mark - Actions

- (void)menuButtonTapped:(UIButton *)sender {
    NSInteger index = sender.tag;

    // FCL style: add a bounce animation when a menu item is selected (a ScaleX/ScaleY bounce, like an OvershootInterpolator)
    [UIView animateWithDuration:0.3
                          delay:0
         usingSpringWithDamping:0.5
          initialSpringVelocity:0.8
                        options:UIViewAnimationOptionAllowUserInteraction
                     animations:^{
        sender.transform = CGAffineTransformMakeScale(1.2, 1.2);
    } completion:^(BOOL finished) {
        [UIView animateWithDuration:0.2
                              delay:0
                            options:UIViewAnimationOptionCurveEaseOut
                         animations:^{
            sender.transform = CGAffineTransformIdentity;
        } completion:nil];
    }];

    // Update the selected state
    self.selectedIndex = index;
    [self updateButtonColors];

    // Callback
    NSString *title = self.menuItems[index][@"title"];
    if (self.onMenuItemSelected) {
        self.onMenuItemSelected(index, title);
    }

    // Handle the navigation
    [self handleMenuSelection:index];
}

- (void)updateButtonColors {
    UIColor *normalColor = [self menuNormalColor];
    UIColor *accent = accentColor();
    // The buttons now live in menuStackView.arrangedSubviews (after the UIStackView rework)
    for (UIView *view in self.menuStackView.arrangedSubviews) {
        if ([view isKindOfClass:[UIButton class]]) {
            UIButton *btn = (UIButton *)view;
            NSInteger index = btn.tag;

            if (index == self.selectedIndex) {
                btn.tintColor = accent;
                [btn setTitleColor:accent forState:UIControlStateNormal];
                // FCL style: give the selected item a translucent background highlight
                btn.backgroundColor = [accent colorWithAlphaComponent:0.15];
            } else {
                btn.tintColor = normalColor;
                [btn setTitleColor:normalColor forState:UIControlStateNormal];
                btn.backgroundColor = [UIColor clearColor];
            }
        }
    }
}

// Refresh every menu button when the text color changes
- (void)applyCustomAppearance {
    [self updateButtonColors];
}

/// Re-apply the background effect: called when the BackgroundUIEffectChanged notification arrives.
/// Re-applies the opacity/frosted-glass effect to this view controller via BackgroundManager,
/// so the global background shows through correctly.
- (void)reapplyBackgroundEffect {
    [[BackgroundManager sharedManager] makeViewControllerTransparent:self];
}

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

// Color of unselected menu items: the user-defined general.text_color when set, otherwise systemGray
- (UIColor *)menuNormalColor {
    NSString *hex = getPrefObject(@"general.text_color");
    if (hex.length > 0) {
        UIColor *custom = [self colorFromHexString:hex];
        if (custom) return custom;
    }
    return [UIColor systemGrayColor];
}

- (UIColor *)colorFromHexString:(NSString *)hexString {
    NSString *hex = [hexString stringByReplacingOccurrencesOfString:@"#" withString:@""];
    if (hex.length != 6 && hex.length != 8) return nil;
    unsigned int r, g, b, a = 255;
    if (hex.length == 6) {
        [[NSScanner scannerWithString:hex] scanHexInt:&r];
        b = r & 0xFF;
        g = (r >> 8) & 0xFF;
        r = (r >> 16) & 0xFF;
    } else {
        [[NSScanner scannerWithString:hex] scanHexInt:&r];
        a = r & 0xFF;
        b = (r >> 8) & 0xFF;
        g = (r >> 16) & 0xFF;
        r = (r >> 24) & 0xFF;
    }
    return [UIColor colorWithRed:r/255.0 green:g/255.0 blue:b/255.0 alpha:a/255.0];
}

- (void)handleMenuSelection:(NSInteger)index {
    switch (index) {
        case 0: // Home
            // Tell the parent controller to switch to the news page
            [[NSNotificationCenter defaultCenter] postNotificationName:@"ShowHomePage" object:nil];
            break;

        case 1: // Download
            [[NSNotificationCenter defaultCenter] postNotificationName:@"ShowDownloadPage" object:nil];
            break;

        case 2: // Version manager (which absorbed the old "current version settings" feature)
            [self showVersionManager];
            break;

        case 3: // Settings (the multiplayer entry is removed for now; change this back to case 5 when restoring it)
            [self showSettings];
            break;
    }
}

- (void)showVersionManager {
    // Post a notification so LauncherRootViewController shows it in the middle content area
    [[NSNotificationCenter defaultCenter] postNotificationName:@"ShowVersionManager" object:nil];
}

- (void)showMultiplayer {
    // Post a notification so LauncherRootViewController shows the Terracotta multiplayer screen
    [[NSNotificationCenter defaultCenter] postNotificationName:@"ShowMultiplayer" object:nil];
}

- (void)showZeroTier {
    // Post a notification so LauncherRootViewController shows the ZeroTier multiplayer screen
    // ZeroTier and Terracotta are two parallel multiplayer options, so a separate menu entry saves the user going through Terracotta first.
    [[NSNotificationCenter defaultCenter] postNotificationName:@"ShowZeroTier" object:nil];
}

- (void)showSettings {
    // Post a notification so LauncherRootViewController shows it in the middle content area
    [[NSNotificationCenter defaultCenter] postNotificationName:@"ShowSettings" object:nil];
}

#pragma mark - Data Updates

- (void)updateAccountInfo {
    // The account information is shown in the right panel, so nothing is needed here
}

#pragma mark - Orientation

- (BOOL)shouldAutorotate {
    return YES;
}

- (UIInterfaceOrientationMask)supportedInterfaceOrientations {
    return UIInterfaceOrientationMaskLandscape;
}

@end
