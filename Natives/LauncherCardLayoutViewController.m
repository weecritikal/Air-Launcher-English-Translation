#import "LauncherCardLayoutViewController.h"
#import "LauncherMenuViewController.h"
#import "LauncherNewsViewController.h"
#import "LauncherRightPanelViewController.h"
#import "DownloadViewController.h"
#import "VersionManagerViewController.h"
#import "ProfileSettingsViewController.h"
#import "LauncherPreferencesViewController.h"
#import "LauncherNavigationController.h"
#import "LauncherPreferences.h"
#import "BackgroundManager.h"
#import "PLProfiles.h"
#import "utils.h"
#import "ModsManagerViewController.h"
#import "ShadersManagerViewController.h"
#import "ModpackImportViewController.h"
#import "LauncherPrefGameDirViewController.h"
#import "CustomControlsViewController.h"
// ZeroTier/Terracotta multiplayer temporarily removed (while a startup crash is investigated)
// #import "MultiplayerViewController.h"
// #import "TerracottaViewController.h"
// #import "TerracottaManager.h"
// #import "TerracottaBridge.h"
#import "AccountListViewController.h"

// Layout constants (the iPad/wide-screen baseline; they shrink on iPhone via traitCollection)
static const CGFloat kSidebarWidthPad = 70.0;      // Left sidebar card width on iPad
static const CGFloat kSidebarWidthPhone = 56.0;    // Left sidebar card width on iPhone (icons only)
static const CGFloat kRightPanelWidthPad = 220.0;  // Right panel card width on iPad
static const CGFloat kRightPanelWidthPhone = 168.0; // Right panel card width on iPhone (wide enough for the Play/JAR buttons to stay readable)
static const CGFloat kCardSpacing = 12.0;          // Spacing between cards
static const CGFloat kCardOuterMarginPad = 12.0;   // Margin from the cards to the outer edge on iPad
static const CGFloat kCardOuterMarginPhone = 8.0;  // Margin from the cards to the outer edge on iPhone (less whitespace on narrow screens)
static const CGFloat kCardCornerRadius = 16.0;     // Card corner radius

/// Detect whether the physical device is an iPhone (unaffected by the idiom hook of debug.debug_ipad_ui).
/// UIKit+hook.m forces the idiom to Pad, which makes trait.userInterfaceIdiom unreliable.
/// UIDevice.model is used here to detect the real device type.
static BOOL LauncherCardLayoutIsPhysicalPhone(void) {
    NSString *model = [[UIDevice currentDevice].model lowercaseString];
    return [model containsString:@"iphone"];
}

/// Decide the card outer margin from the physical device type
static CGFloat LauncherCardLayoutOuterMargin(UITraitCollection *trait) {
    if (LauncherCardLayoutIsPhysicalPhone()) return kCardOuterMarginPhone;
    return kCardOuterMarginPad;
}

/// Decide the sidebar width from the physical device type
/// - iPhone landscape (SE/8/Plus/X/Pro Max included): 56pt (the menu is icons only, so 56pt is enough)
/// - iPad：70pt
static CGFloat LauncherCardLayoutSidebarWidth(UITraitCollection *trait) {
    if (LauncherCardLayoutIsPhysicalPhone()) return kSidebarWidthPhone;
    return kSidebarWidthPad;
}

/// Decide the right panel width from the physical device type
/// - iPhone landscape: 168pt (so the Play/Edit controls/Execute Jar button text is not truncated)
/// - iPad：220pt
static CGFloat LauncherCardLayoutRightPanelWidth(UITraitCollection *trait) {
    if (LauncherCardLayoutIsPhysicalPhone()) return kRightPanelWidthPhone;
    return kRightPanelWidthPad;
}

@interface LauncherCardLayoutViewController ()

@property(nonatomic, strong) UIView *sidebarCard;
@property(nonatomic, strong) UIView *contentCard;
@property(nonatomic, strong) UIView *rightPanelCard;

@property(nonatomic, strong) NSLayoutConstraint *sidebarWidthConstraint;
@property(nonatomic, strong) NSLayoutConstraint *rightPanelWidthConstraint;
// Store the outer margin constraints, so they can be updated when traitCollection changes
@property(nonatomic, strong) NSArray<NSLayoutConstraint *> *outerMarginConstraints;
// Key fix (cumulative UI glitch): as in LauncherRootViewController, hold the constraints of the current content VC
// and deactivate them before activating new ones, so cached reused child VC constraints do not stack up when tmpRootVC is retained.
@property(nonatomic, strong) NSArray<NSLayoutConstraint *> *currentContentConstraints;

@property(nonatomic, assign) BOOL isShowingProfileEditor;
@property(nonatomic, strong) ProfileSettingsViewController *profileEditorVC;

@end

@implementation LauncherCardLayoutViewController

#pragma mark - Lifecycle

- (BOOL)prefersStatusBarHidden {
    return YES;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    
    self.view.backgroundColor = [UIColor clearColor];
    
    // Initialize the version list (this must come before the other view controllers)
    [self initializeVersionLists];
    
    // Create the three card container views
    [self setupCardContainers];
    
    // Add the child view controllers
    [self setupChildViewControllers];
    
    // Apply the background
    [[BackgroundManager sharedManager] applyBackgroundToView:self.view];

    // Listen for launcher appearance changes (custom font/card color) and refresh the card backgrounds
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(applyCustomAppearance)
                                                 name:@"LauncherAppearanceChanged"
                                               object:nil];
}

- (void)initializeVersionLists {
    // Initialize the local version list
    if (!localVersionList) {
        localVersionList = [NSMutableArray new];
    }
    [localVersionList removeAllObjects];
    
    NSFileManager *fileManager = [NSFileManager defaultManager];
    NSString *versionPath = [NSString stringWithFormat:@"%s/versions/", getenv("POJAV_GAME_DIR")];
    NSArray *list = [fileManager contentsOfDirectoryAtPath:versionPath error:nil];
    for (NSString *versionId in list) {
        NSString *localPath = [NSString stringWithFormat:@"%s/versions/%@", getenv("POJAV_GAME_DIR"), versionId];
        BOOL isDirectory;
        if ([fileManager fileExistsAtPath:localPath isDirectory:&isDirectory] && isDirectory) {
            [localVersionList addObject:@{
                @"id": versionId,
                @"type": @"custom"
            }];
        }
    }
    
    // Initialize the remote version list
    if (!remoteVersionList) {
        remoteVersionList = [NSMutableArray new];
    }
    [remoteVersionList removeAllObjects];
    [remoteVersionList addObjectsFromArray:@[
        @{@"id": @"latest-release", @"type": @"release"},
        @{@"id": @"latest-snapshot", @"type": @"snapshot"}
    ]];
    
    // Fetch the remote version list asynchronously
    [self fetchRemoteVersionList];
}

- (void)fetchRemoteVersionList {
    NSString *downloadSource = getPrefObject(@"general.download_source");
    NSString *versionManifestURL;
    
    if ([downloadSource isEqualToString:@"bmclapi"]) {
        versionManifestURL = @"https://bmclapi2.bangbang93.com/mc/game/version_manifest_v2.json";
    } else {
        versionManifestURL = @"https://piston-meta.mojang.com/mc/game/version_manifest_v2.json";
    }
    
    NSURL *url = [NSURL URLWithString:versionManifestURL];
    NSURLSessionDataTask *task = [[NSURLSession sharedSession] dataTaskWithURL:url completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        if (data && !error) {
            NSError *jsonError;
            NSDictionary *json = [NSJSONSerialization JSONObjectWithData:data options:0 error:&jsonError];
            if (json && json[@"versions"]) {
                dispatch_async(dispatch_get_main_queue(), ^{
                    [remoteVersionList addObjectsFromArray:json[@"versions"]];
                    setPrefObject(@"internal.latest_version", json[@"latest"]);
                    NSDebugLog(@"[LauncherCardVC] Loaded %d remote versions", remoteVersionList.count);
                });
            }
        } else {
            NSDebugLog(@"[LauncherCardVC] Failed to fetch version list: %@", error.localizedDescription);
        }
    }];
    [task resume];
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    [[BackgroundManager sharedManager] resumeVideo];
}

- (void)viewWillDisappear:(BOOL)animated {
    [super viewWillDisappear:animated];
    [[BackgroundManager sharedManager] pauseVideo];
}

- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    // The constraints guarantee equal outer margins on all four sides (using view.edgeAnchor + kCardOuterMargin
    // rather than safeAreaLayoutGuide), so no extra compensation is needed here.
    // additionalSafeAreaInsets was previously used to compensate for an asymmetric safe area, but that made the margin
    // max(safeArea) + kCardOuterMargin, which is larger still ("the bottom and side gaps are too wide"),
    // so the compensation was removed in favor of constraining directly to view.edgeAnchor.
    //
    // Key fix (phase 4: the Card layout crashed on entering settings, with no log):
    // aligned with LauncherRootViewController by clearing accumulated additionalSafeAreaInsets.
    // This method body used to be empty, so with LauncherPreferencesViewController (which contains a UISearchController)
    // on the nav stack, additionalSafeAreaInsets could accumulate incorrectly, the frame of UISearchController.searchBar
    // (used as the tableHeaderView) was miscalculated -> EXC_BAD_ACCESS (which NSUncaughtExceptionHandler does not
    // catch, hence no log). The VS layout did not crash because the viewDidLayoutSubviews of Root kept clearing the inset.
    UIViewController *contentVC = _contentViewController;
    if (!contentVC) return;
    if ([contentVC isKindOfClass:[UINavigationController class]]) {
        UINavigationController *nav = (UINavigationController *)contentVC;
        for (UIViewController *vc in nav.viewControllers) {
            UIEdgeInsets insets = vc.additionalSafeAreaInsets;
            if (insets.top != 0 || insets.left != 0 || insets.right != 0 || insets.bottom != 0) {
                vc.additionalSafeAreaInsets = UIEdgeInsetsZero;
            }
        }
    } else {
        UIEdgeInsets insets = contentVC.additionalSafeAreaInsets;
        if (insets.top != 0 || insets.left != 0 || insets.right != 0 || insets.bottom != 0) {
            contentVC.additionalSafeAreaInsets = UIEdgeInsetsZero;
        }
    }
}

- (void)traitCollectionDidChange:(UITraitCollection *)previousTraitCollection {
    [super traitCollectionDidChange:previousTraitCollection];
    // Update the sidebar and right panel widths when switching between iPhone and iPad, or when a split view is resized
    CGFloat sidebarWidth = LauncherCardLayoutSidebarWidth(self.traitCollection);
    CGFloat rightPanelWidth = LauncherCardLayoutRightPanelWidth(self.traitCollection);
    if (self.sidebarWidthConstraint.constant != sidebarWidth) {
        self.sidebarWidthConstraint.constant = sidebarWidth;
    }
    if (self.rightPanelWidthConstraint.constant != rightPanelWidth) {
        self.rightPanelWidthConstraint.constant = rightPanelWidth;
    }
    // Update the outer margin constraints (outerMargin differs between iPhone and iPad)
    CGFloat outerMargin = LauncherCardLayoutOuterMargin(self.traitCollection);
    for (NSLayoutConstraint *c in self.outerMarginConstraints) {
        // The first, fourth and seventh constraints are leading/trailing (a positive outer margin); the rest are top/bottom
        // leading uses a positive outerMargin, trailing a negative one, top positive and bottom negative
        // Simplification: derive the sign from the sign of the original constant
        if (c.constant >= 0) {
            c.constant = outerMargin;
        } else {
            c.constant = -outerMargin;
        }
    }
    // Key fix (phase 4: the Card layout crashed on entering settings, with no log):
    // Aligned with LauncherRootViewController: only the direct child VCs are walked, avoiding the risk of a stack overflow.
    // Previously every descendant VC was walked recursively (adjustChildLayoutForTraitCollection:), so a cycle in the VC tree
    // would overflow the stack (SIGSEGV, which NSUncaughtExceptionHandler does not catch, hence no log).
    // The respondsToSelector:@selector(viewWillAppear:) check is always true (every UIViewController responds),
    // so it was redundant and has been removed too.
    for (UIViewController *child in self.childViewControllers) {
        [child.view setNeedsLayout];
    }
}

#pragma mark - Setup

- (UIView *)createCardContainer {
    UIView *card = [[UIView alloc] init];
    card.translatesAutoresizingMaskIntoConstraints = NO;
    card.layer.cornerRadius = kCardCornerRadius;
    card.layer.masksToBounds = YES;
    [[BackgroundManager sharedManager] applyEffectToView:card];
    [self applyCustomCardColorToCard:card];
    return card;
}

/// Read the general.card_color preference and, when set, overlay a translucent color on top of the frosted glass.
///
/// This follows the Haze + tint approach of ZL2 and the applySemiTransparentColor: implementation of RootVC:
/// the frosted-glass UIVisualEffectView from BackgroundManager is kept (so the background image shows through),
/// and the user's translucent color is layered onto the container background.
///
/// CardVC used to remove the frosted glass and cover it with a solid color, which caused:
/// 1. inconsistency with RootVC (which keeps the frosted glass and overlays a translucent color)
/// 2. the custom background image being completely hidden
/// 3. a look that did not match FCL/ZL2 (both of which keep the blur and overlay a color)
///
/// It is now unified: keep the frosted glass and overlay a translucent color (exactly as RootVC does)
- (void)applyCustomCardColorToCard:(UIView *)card {
    NSString *hex = getPrefObject(@"general.card_color");
    UIColor *color = [self colorFromHexString:hex];
    if (!color) return;
    // Keep the frosted-glass UIVisualEffectView inserted by BackgroundManager and only overlay a translucent color
    // This shows the user's card color while still letting the background image through (matching RootVC)
    // An alpha of 0.7 lets the background image show through moderately (following the influencedByBackgroundColor idea of ZL2)
    card.backgroundColor = [color colorWithAlphaComponent:0.7];
}

- (nullable UIColor *)colorFromHexString:(id)hex {
    if (![hex isKindOfClass:[NSString class]] || [(NSString *)hex length] == 0) return nil;
    NSString *clean = [(NSString *)hex stringByReplacingOccurrencesOfString:@"#" withString:@""];
    unsigned int rgb = 0;
    NSScanner *scanner = [NSScanner scannerWithString:clean];
    if (![scanner scanHexInt:&rgb]) return nil;
    return [UIColor colorWithRed:((rgb >> 16) & 0xFF) / 255.0
                           green:((rgb >> 8) & 0xFF) / 255.0
                            blue:(rgb & 0xFF) / 255.0
                           alpha:1.0];
}

/// Re-apply the card color when the appearance changes (keeping the corner radius, rebuilding the background)
- (void)applyCustomAppearance {
    [self applyCustomCardColorToCard:self.sidebarCard];
    [self applyCustomCardColorToCard:self.contentCard];
    [self applyCustomCardColorToCard:self.rightPanelCard];
}

- (void)setupCardContainers {
    // Left menu card
    self.sidebarCard = [self createCardContainer];
    [self.view addSubview:self.sidebarCard];

    // Middle content card
    self.contentCard = [self createCardContainer];
    [self.view addSubview:self.contentCard];

    // Right info/play card
    self.rightPanelCard = [self createCardContainer];
    [self.view addSubview:self.rightPanelCard];

    // Create variable-width constraints from the adaptive width, so they can be updated when traitCollection changes
    self.sidebarWidthConstraint = [self.sidebarCard.widthAnchor constraintEqualToConstant:LauncherCardLayoutSidebarWidth(self.traitCollection)];
    self.rightPanelWidthConstraint = [self.rightPanelCard.widthAnchor constraintEqualToConstant:LauncherCardLayoutRightPanelWidth(self.traitCollection)];

    // Card outer margin: a smaller value on narrow iPhone screens, to reduce whitespace
    CGFloat outerMargin = LauncherCardLayoutOuterMargin(self.traitCollection);

    // Set up the constraints
    // All four sides use view.edgeAnchor (rather than safeAreaLayoutGuide), so the outer margin is controlled purely by outerMargin
    // and is identical on every side (= outerMargin), unaffected by the asymmetric safe area caused by the notch or home indicator.
    //
    // Fix for "the bottom is too wide": the top and bottom previously used safeAreaLayoutGuide + outerMargin,
    // making the bottom margin homeIndicatorInset + outerMargin (about 21+8=29pt)
    // while the top margin was 0 + outerMargin = 8pt, so the bottom was 3.6x the top.
    // With view.topAnchor/view.bottomAnchor the top and bottom margins are both outerMargin and match.
    // The card background extends below the home indicator, which is visually fine (the cards have an opaque/frosted background).
    NSLayoutConstraint *sidebarLeading = [self.sidebarCard.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor constant:outerMargin];
    NSLayoutConstraint *sidebarTop = [self.sidebarCard.topAnchor constraintEqualToAnchor:self.view.topAnchor constant:outerMargin];
    NSLayoutConstraint *sidebarBottom = [self.sidebarCard.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor constant:-outerMargin];
    NSLayoutConstraint *rightTrailing = [self.rightPanelCard.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor constant:-outerMargin];
    NSLayoutConstraint *rightTop = [self.rightPanelCard.topAnchor constraintEqualToAnchor:self.view.topAnchor constant:outerMargin];
    NSLayoutConstraint *rightBottom = [self.rightPanelCard.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor constant:-outerMargin];
    NSLayoutConstraint *contentTop = [self.contentCard.topAnchor constraintEqualToAnchor:self.view.topAnchor constant:outerMargin];
    NSLayoutConstraint *contentBottom = [self.contentCard.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor constant:-outerMargin];

    self.outerMarginConstraints = @[sidebarLeading, sidebarTop, sidebarBottom,
                                    rightTrailing, rightTop, rightBottom,
                                    contentTop, contentBottom];

    [NSLayoutConstraint activateConstraints:@[
        // Left menu card
        sidebarLeading, sidebarTop, sidebarBottom,
        self.sidebarWidthConstraint,

        // Right panel card
        rightTrailing, rightTop, rightBottom,
        self.rightPanelWidthConstraint,

        // Middle content card — fills the space between the sidebar and the right panel, with an equal kCardSpacing gap on each side
        [self.contentCard.leadingAnchor constraintEqualToAnchor:self.sidebarCard.trailingAnchor constant:kCardSpacing],
        [self.contentCard.trailingAnchor constraintEqualToAnchor:self.rightPanelCard.leadingAnchor constant:-kCardSpacing],
        contentTop, contentBottom
    ]];
}

- (void)setupChildViewControllers {
    // Left sidebar - the feature menu
    LauncherMenuViewController *sidebarVC = [[LauncherMenuViewController alloc] init];
    [self addChildViewController:sidebarVC];
    sidebarVC.view.translatesAutoresizingMaskIntoConstraints = NO;
    [self.sidebarCard addSubview:sidebarVC.view];
    [NSLayoutConstraint activateConstraints:@[
        [sidebarVC.view.leadingAnchor constraintEqualToAnchor:self.sidebarCard.leadingAnchor],
        [sidebarVC.view.trailingAnchor constraintEqualToAnchor:self.sidebarCard.trailingAnchor],
        [sidebarVC.view.topAnchor constraintEqualToAnchor:self.sidebarCard.topAnchor],
        [sidebarVC.view.bottomAnchor constraintEqualToAnchor:self.sidebarCard.bottomAnchor]
    ]];
    [sidebarVC didMoveToParentViewController:self];
    _sidebarViewController = sidebarVC;
    
    // Middle content - shows the news page by default
    LauncherNewsViewController *newsVC = [[LauncherNewsViewController alloc] init];
    [self setContentViewController:newsVC animated:NO];
    
    // Right panel - account and play
    LauncherRightPanelViewController *rightPanelVC = [[LauncherRightPanelViewController alloc] init];
    [self addChildViewController:rightPanelVC];
    rightPanelVC.view.translatesAutoresizingMaskIntoConstraints = NO;
    [self.rightPanelCard addSubview:rightPanelVC.view];
    [NSLayoutConstraint activateConstraints:@[
        [rightPanelVC.view.leadingAnchor constraintEqualToAnchor:self.rightPanelCard.leadingAnchor],
        [rightPanelVC.view.trailingAnchor constraintEqualToAnchor:self.rightPanelCard.trailingAnchor],
        [rightPanelVC.view.topAnchor constraintEqualToAnchor:self.rightPanelCard.topAnchor],
        [rightPanelVC.view.bottomAnchor constraintEqualToAnchor:self.rightPanelCard.bottomAnchor]
    ]];
    [rightPanelVC didMoveToParentViewController:self];
    _rightPanelViewController = rightPanelVC;
    
    // Register the notification observers
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(showHomePage)
                                                 name:@"ShowHomePage"
                                               object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(showDownloadPage)
                                                 name:@"ShowDownloadPage"
                                               object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(showVersionManager)
                                                 name:@"ShowVersionManager"
                                               object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(showProfileEditor:)
                                                 name:@"ShowProfileEditor"
                                               object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(showSettings)
                                                 name:@"ShowSettings"
                                               object:nil];
    // ZeroTier/Terracotta multiplayer temporarily removed (while a startup crash is investigated)
    // [[NSNotificationCenter defaultCenter] addObserver:self
    //                                          selector:@selector(showMultiplayer)
    //                                              name:@"ShowMultiplayer"
    //                                            object:nil];
    // [[NSNotificationCenter defaultCenter] addObserver:self
    //                                          selector:@selector(showZeroTier)
    //                                              name:@"ShowZeroTier"
    //                                            object:nil];
    // Account management: tapping the avatar in the right panel posts a ShowAccountManager notification.
    // The original implementation missed this observer, so tapping the avatar in the card layout did nothing and no account could be signed in.
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(showAccountManager)
                                                 name:@"ShowAccountManager"
                                               object:nil];
    // Home shortcut tile taps: switch the content area to the matching sub-page (no more FormSheet modals)
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(showModsManager)
                                                 name:@"ShowModsManager"
                                               object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(showShadersManager)
                                                 name:@"ShowShadersManager"
                                               object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(showModpackImport)
                                                 name:@"ShowModpackImport"
                                               object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(showGameDirectory)
                                                 name:@"ShowGameDirectory"
                                               object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(backgroundChanged)
                                                 name:@"BackgroundChanged"
                                               object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(uiEffectChanged:)
                                                 name:@"BackgroundUIEffectChanged"
                                               object:nil];
    // Listen for version switches and reload the editor
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(reloadProfileEditorIfNeeded)
                                                 name:@"SelectedProfileChanged"
                                               object:nil];
    // Listen for game directory switches and reload the version list
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(reloadVersionLists)
                                                 name:@"ReloadProfileList"
                                               object:nil];
    // Listen for find-version requests
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(findVersionInRemoteList:)
                                                 name:@"FindVersionInRemoteList"
                                               object:nil];
}

- (void)findVersionInRemoteList:(NSNotification *)notification {
    NSDictionary *userInfo = notification.userInfo;
    NSString *versionId = userInfo[@"versionId"];
    void (^callback)(NSDictionary *) = userInfo[@"callback"];
    
    if (!versionId || !callback) {
        return;
    }
    
    // Look in the remote version list
    NSDictionary *versionObject = nil;
    for (NSDictionary *version in remoteVersionList) {
        if ([version[@"id"] isEqualToString:versionId]) {
            versionObject = version;
            break;
        }
    }
    
    // If it is not in the remote list, check whether it is a local version
    if (!versionObject) {
        for (NSDictionary *version in localVersionList) {
            if ([version[@"id"] isEqualToString:versionId]) {
                versionObject = version;
                break;
            }
        }
    }
    
    callback(versionObject);
}

- (void)reloadVersionLists {
    // Reload the version list
    [self initializeVersionLists];
    // Tell the right panel to refresh the version display
    [[NSNotificationCenter defaultCenter] postNotificationName:@"SelectedProfileChanged" object:nil];
}

- (void)showHomePage {
    LauncherNewsViewController *newsVC = [[LauncherNewsViewController alloc] init];
    [self setContentViewController:newsVC animated:YES];
}

- (void)showDownloadPage {
    // Show the download page in the middle content area, wrapped in a NavigationController so sub-flows (version picker/installer) can push
    DownloadViewController *downloadVC = [[DownloadViewController alloc] init];
    UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:downloadVC];
    nav.navigationBar.prefersLargeTitles = NO;
    [self setContentViewController:nav animated:YES];
}

- (void)showVersionManager {
    // Show the version manager in the middle content area, wrapped in a NavigationController so sub-flows (mod/shader/game directory management) can push
    VersionManagerViewController *vc = [[VersionManagerViewController alloc] init];
    UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:vc];
    nav.navigationBar.prefersLargeTitles = NO;
    [self setContentViewController:nav animated:YES];
}

- (void)showProfileEditor:(NSNotification *)notification {
    // Show the version editor in the middle content area (using ProfileSettingsViewController)
    NSString *profileName = notification.object;

    ProfileSettingsViewController *vc = [[ProfileSettingsViewController alloc] init];
    vc.profileName = profileName;

    // Wrap it in a navigation controller
    UINavigationController *navVC = [[UINavigationController alloc] initWithRootViewController:vc];
    navVC.navigationBar.prefersLargeTitles = NO;

    self.profileEditorVC = vc;
    self.isShowingProfileEditor = YES;
    [self setContentViewController:navVC animated:YES];
}

- (void)reloadProfileEditorIfNeeded {
    // If the editor page is currently showing, reload it
    if (self.isShowingProfileEditor) {
        NSString *currentProfile = PLProfiles.current.selectedProfileName;
        if (currentProfile) {
            [[NSNotificationCenter defaultCenter] postNotificationName:@"ShowProfileEditor" object:currentProfile];
        }
    }
}

- (void)showSettings {
    // Show the settings page in the middle content area
    LauncherPreferencesViewController *vc = [[LauncherPreferencesViewController alloc] init];
    // Wrap it in a navigation controller so its sub-pages can navigate normally
    UINavigationController *navVC = [[UINavigationController alloc] initWithRootViewController:vc];
    navVC.navigationBar.prefersLargeTitles = YES;
    [self setContentViewController:navVC animated:YES];
}

// ZeroTier/Terracotta multiplayer temporarily removed (while a startup crash is investigated)
// - (void)showMultiplayer { ... TerracottaViewController ... }
// - (void)showZeroTier { ... MultiplayerViewController ... TerracottaManager ... }
- (void)showMultiplayer {
    [self showMultiplayerDisabledAlert];
}
- (void)showZeroTier {
    [self showMultiplayerDisabledAlert];
}
- (void)showMultiplayerDisabledAlert {
    UIAlertController *alert = [UIAlertController
        alertControllerWithTitle:@"Multiplayer is temporarily unavailable"
                          message:@"The multiplayer module (ZeroTier/Terracotta) is disabled for now while a startup crash is being investigated. Please wait for a future release."
                   preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)showAccountManager {
    // In the card layout, account management is shown in the middle content area (matching LauncherRootViewController in the VS layout).
    // Tapping the avatar in the right panel posts ShowAccountManager, which calls this method.
    // The insetGrouped style gives the account list rounded grouped cards (the default plain style had square-edged rows).
    AccountListViewController *vc = [[AccountListViewController alloc] initWithStyle:UITableViewStyleInsetGrouped];
    vc.whenItemSelected = ^void() {
        [[NSNotificationCenter defaultCenter] postNotificationName:@"UpdateAccountInfo" object:nil];
    };
    vc.whenDelete = ^void(NSString *name) {
        [[NSNotificationCenter defaultCenter] postNotificationName:@"UpdateAccountInfo" object:nil];
    };
    UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:vc];
    nav.navigationBar.prefersLargeTitles = NO;
    [self setContentViewController:nav animated:YES];
}

#pragma mark - 首页快捷入口 (替换原 FormSheet 弹窗)

- (void)showModsManager {
    // Switch to the version manager page and push mod management straight away
    // Fix for the "previous screen did not disappear" race: build the full nav stack first, then call setContentViewController,
    // so the loop inside setContentViewController can make every VC on the stack transparent in one pass,
    // instead of pushing animated:NO while the animated:YES crossDissolve is still running and leaving the new VC opaque.
    VersionManagerViewController *vm = [[VersionManagerViewController alloc] init];
    UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:vm];
    nav.navigationBar.prefersLargeTitles = NO;
    ModsManagerViewController *m = [[ModsManagerViewController alloc] init];
    m.initialMode = ModsManagerModeLocal;
    [nav pushViewController:m animated:NO];
    [self setContentViewController:nav animated:YES];
}

- (void)showShadersManager {
    VersionManagerViewController *vm = [[VersionManagerViewController alloc] init];
    UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:vm];
    nav.navigationBar.prefersLargeTitles = NO;
    ShadersManagerViewController *s = [[ShadersManagerViewController alloc] init];
    s.initialMode = ShadersManagerModeLocal;
    [nav pushViewController:s animated:NO];
    [self setContentViewController:nav animated:YES];
}

- (void)showGameDirectory {
    VersionManagerViewController *vm = [[VersionManagerViewController alloc] init];
    UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:vm];
    nav.navigationBar.prefersLargeTitles = NO;
    LauncherPrefGameDirViewController *g = [[LauncherPrefGameDirViewController alloc] init];
    [nav pushViewController:g animated:NO];
    [self setContentViewController:nav animated:YES];
}

- (void)showModpackImport {
    // Switch to the download page and push the modpack import screen straight away
    DownloadViewController *d = [[DownloadViewController alloc] init];
    UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:d];
    nav.navigationBar.prefersLargeTitles = NO;
    ModpackImportViewController *m = [[ModpackImportViewController alloc] init];
    [nav pushViewController:m animated:NO];
    [self setContentViewController:nav animated:YES];
}

- (void)backgroundChanged {
    // Re-apply the background
    [[BackgroundManager sharedManager] applyBackgroundToView:self.view];
}

- (void)uiEffectChanged:(NSNotification *)notification {
    // Re-apply the frosted-glass/translucent effect to the card container views
    [[BackgroundManager sharedManager] applyEffectToView:self.sidebarCard];
    [[BackgroundManager sharedManager] applyEffectToView:self.contentCard];
    [[BackgroundManager sharedManager] applyEffectToView:self.rightPanelCard];
}

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

#pragma mark - Content Switching

- (void)setContentViewController:(UIViewController *)viewController animated:(BOOL)animated {
    if (!viewController) return;

    // Key fix (cumulative UI glitch): skip immediately for the same instance, so constraints are not added twice to one VC
    // and applyEffectToNavigationBar: is not called repeatedly, which would accumulate hairline UIImageViews.
    if (viewController == _contentViewController) return;

    // Check whether we are switching to a page other than the editor
    if (![viewController isKindOfClass:[UINavigationController class]] ||
        ![((UINavigationController *)viewController).topViewController isKindOfClass:[ProfileSettingsViewController class]]) {
        self.isShowingProfileEditor = NO;
        self.profileEditorVC = nil;
    }

    UIViewController *oldVC = _contentViewController;

    // Remove the old one and add the new one
    _contentViewController = viewController;
    [self addChildViewController:viewController];
    viewController.view.translatesAutoresizingMaskIntoConstraints = NO;

    // Fix: align with the nav bar transparency handling of LauncherRootViewController.
    // The card layout was missing this logic, so sub-pages wrapped in a UINavigationController (such as
    // VersionManagerViewController) showed the default opaque nav bar (a white band) that clashed with the card background.
    //
    // Follow the complete handling of RootVC (make every VC on the nav stack transparent in setContentViewController +
    // set nav.delegate + re-apply transparency in the didShowViewController callback):
    // 1. make every VC on the nav stack transparent (not just topViewController), so a pushed sub-page does not have its style reset
    // 2. set nav.delegate = self and re-apply the nav bar effect in the didShowViewController callback
    // 3. re-apply the nav bar effect, so the style stays consistent after a push/pop
    if ([viewController isKindOfClass:[UINavigationController class]]) {
        UINavigationController *nav = (UINavigationController *)viewController;
        nav.delegate = self;
        [[BackgroundManager sharedManager] applyEffectToNavigationBar:nav.navigationBar];
        // Make every VC on the stack transparent (as RootVC does), so a pushed sub-page does not have an opaque background
        for (UIViewController *vc in nav.viewControllers) {
            [[BackgroundManager sharedManager] makeViewControllerTransparent:vc];
        }
    } else {
        [[BackgroundManager sharedManager] makeViewControllerTransparent:viewController];
    }

    // Key fix (cumulative UI glitch): deactivate the old constraints, so a cached and reused child VC does not activate
    // its constraints repeatedly and widen the contentCard content area when tmpRootVC is retained.
    if (self.currentContentConstraints.count > 0) {
        [NSLayoutConstraint deactivateConstraints:self.currentContentConstraints];
        self.currentContentConstraints = nil;
    }

    NSArray<NSLayoutConstraint *> *newConstraints = @[
        [viewController.view.leadingAnchor constraintEqualToAnchor:self.contentCard.leadingAnchor],
        [viewController.view.trailingAnchor constraintEqualToAnchor:self.contentCard.trailingAnchor],
        [viewController.view.topAnchor constraintEqualToAnchor:self.contentCard.topAnchor],
        [viewController.view.bottomAnchor constraintEqualToAnchor:self.contentCard.bottomAnchor]
    ];

    if (animated && oldVC) {
        // Fix for issue 5: the original implementation used two separate UIView transitionWithView: calls (one to remove the old view, one to add the new),
        // and two crossDissolves acting on contentCard at once caused visual conflicts and ghosting (the old frame covering the new screen before it faded out).
        // It now uses a single transition: "remove the old view + add the new view" happen in the same animations block,
        // so crossDissolve captures the before and after snapshots correctly, and the completion block tears down the old VC parent/child relationship.
        //
        // Key fix (the entry animation popped out of the top-left corner): UIKit snapshots the container as soon as the animations block returns,
        // and at that point the new view has been addSubview-ed and had its constraints activated but has not been through a layout pass, so its frame is still
        // (0,0,0,0). Combined with masksToBounds=YES and the rounded corners of contentCard, the crossDissolve looked like it was
        // "expanding out of a dot in the top-left corner". Calling layoutIfNeeded explicitly inside the animations block forces an immediate
        // layout, so snapshot B already has a full-size frame and the crossDissolve is an ordinary fade.
        // The duration was raised from 0.25 to 0.3 for a softer, more natural transition (matching LauncherRootViewController).
        [UIView transitionWithView:self.contentCard
                          duration:0.3
                           options:UIViewAnimationOptionTransitionCrossDissolve
                        animations:^{
                            [oldVC willMoveToParentViewController:nil];
                            [oldVC.view removeFromSuperview];
                            [self.contentCard addSubview:viewController.view];
                            [NSLayoutConstraint activateConstraints:newConstraints];
                            [self.contentCard layoutIfNeeded];
                        } completion:^(BOOL finished) {
                            [oldVC removeFromParentViewController];
                            [viewController didMoveToParentViewController:self];
                        }];
    } else {
        if (oldVC) {
            [oldVC willMoveToParentViewController:nil];
            [oldVC.view removeFromSuperview];
            [oldVC removeFromParentViewController];
        }
        [self.contentCard addSubview:viewController.view];
        [NSLayoutConstraint activateConstraints:newConstraints];
        [viewController didMoveToParentViewController:self];
    }

    self.currentContentConstraints = newConstraints;
}

#pragma mark - Orientation

- (BOOL)shouldAutorotate {
    return YES;
}

- (UIInterfaceOrientationMask)supportedInterfaceOrientations {
    return UIInterfaceOrientationMaskLandscape;
}

#pragma mark - UINavigationControllerDelegate

/// Re-apply transparency to every VC and re-apply the nav bar effect after a nav push/pop
/// Mirrors the method of the same name in RootVC, keeping pushed sub-pages consistent with the card background
- (void)navigationController:(UINavigationController *)navigationController
       didShowViewController:(UIViewController *)viewController
                    animated:(BOOL)animated {
    // Make the VC that just appeared transparent
    [[BackgroundManager sharedManager] makeViewControllerTransparent:viewController];
    // Make every VC on the stack transparent too (so the previous page cannot show through, fixing "the previous page did not disappear in time")
    for (UIViewController *stackVC in navigationController.viewControllers) {
        [[BackgroundManager sharedManager] makeViewControllerTransparent:stackVC];
    }
    // Re-apply the frosted-glass navigation bar effect (so a push does not reset the nav bar style)
    [[BackgroundManager sharedManager] applyEffectToNavigationBar:navigationController.navigationBar];
}

@end
