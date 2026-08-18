#import "LauncherRootViewController.h"
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

// Layout constants (the iPad baseline; they shrink on iPhone via LauncherRootLayoutWidth)
static const CGFloat kSidebarWidthPad = 70.0;      // Left sidebar width on iPad
static const CGFloat kSidebarWidthPhone = 56.0;    // Left sidebar width on iPhone (icons only)
static const CGFloat kRightPanelWidthPad = 220.0;  // Right panel width on iPad
static const CGFloat kRightPanelWidthPhone = 168.0; // Right panel width on iPhone (wide enough for the button text to stay readable)

/// Detect whether the physical device is an iPhone (unaffected by the idiom hook of debug.debug_ipad_ui).
/// UIKit+hook.m forces the idiom to Pad, which makes trait.userInterfaceIdiom unreliable.
/// UIDevice.model is used here to detect the real device type.
static BOOL LauncherRootIsPhysicalPhone(void) {
    NSString *model = [[UIDevice currentDevice].model lowercaseString];
    return [model containsString:@"iphone"];
}

/// Decide the sidebar width from the physical device type (matching LauncherCardLayoutViewController)
static CGFloat LauncherRootLayoutSidebarWidth(UITraitCollection *trait) {
    if (LauncherRootIsPhysicalPhone()) return kSidebarWidthPhone;
    return kSidebarWidthPad;
}

/// Decide the right panel width from the physical device type
static CGFloat LauncherRootLayoutRightPanelWidth(UITraitCollection *trait) {
    if (LauncherRootIsPhysicalPhone()) return kRightPanelWidthPhone;
    return kRightPanelWidthPad;
}

@interface LauncherRootViewController ()

@property(nonatomic, strong) UIView *sidebarContainer;
@property(nonatomic, strong) UIView *contentContainer;
@property(nonatomic, strong) UIView *rightPanelContainer;

@property(nonatomic, strong) NSLayoutConstraint *contentLeadingConstraint;
@property(nonatomic, strong) NSLayoutConstraint *contentTrailingConstraint;
@property(nonatomic, strong) NSLayoutConstraint *sidebarWidthConstraint;
@property(nonatomic, strong) NSLayoutConstraint *rightPanelWidthConstraint;
// Key fix (cumulative UI glitch): setContentViewController: used to activate 4 new constraints on every switch
// (leading/trailing/top/bottom to contentContainer) without ever deactivating those of the old VC.
// When tmpRootVC was retained, a cached and reused child VC activated its constraints again and again, so the stacked
// leading/trailing constraints widened the contentContainer content area during layout. The current constraints are now held and deactivated before new ones are activated.
@property(nonatomic, strong) NSArray<NSLayoutConstraint *> *currentContentConstraints;

@property(nonatomic, assign) BOOL isShowingProfileEditor;
@property(nonatomic, strong) ProfileSettingsViewController *profileEditorVC;

@end

@implementation LauncherRootViewController

#pragma mark - Lifecycle

- (void)viewDidLoad {
    [super viewDidLoad];

    self.view.backgroundColor = [UIColor clearColor];

    // Initialize the version list (this must come before the other view controllers)
    [self initializeVersionLists];

    // Create the three container views
    [self setupContainers];

    // Add the child view controllers
    [self setupChildViewControllers];

    // Apply the background
    [[BackgroundManager sharedManager] applyBackgroundToView:self.view];

    // Listen for appearance changes (text color / card color), matching the Card layout
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(applyCustomAppearance)
                                                 name:@"LauncherAppearanceChanged"
                                               object:nil];
    [self applyCustomAppearance];
}

- (BOOL)prefersStatusBarHidden {
    return YES;
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
                    NSDebugLog(@"[LauncherRootVC] Loaded %d remote versions", remoteVersionList.count);
                });
            }
        } else {
            NSDebugLog(@"[LauncherRootVC] Failed to fetch version list: %@", error.localizedDescription);
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

- (void)traitCollectionDidChange:(UITraitCollection *)previousTraitCollection {
    [super traitCollectionDidChange:previousTraitCollection];
    // Update the sidebar and right panel widths when switching between iPhone and iPad, or when a split view is resized
    CGFloat sidebarWidth = LauncherRootLayoutSidebarWidth(self.traitCollection);
    CGFloat rightPanelWidth = LauncherRootLayoutRightPanelWidth(self.traitCollection);
    if (self.sidebarWidthConstraint.constant != sidebarWidth) {
        self.sidebarWidthConstraint.constant = sidebarWidth;
    }
    if (self.rightPanelWidthConstraint.constant != rightPanelWidth) {
        self.rightPanelWidthConstraint.constant = rightPanelWidth;
    }
    // Tell the child VCs to lay out again
    for (UIViewController *child in self.childViewControllers) {
        [child.view setNeedsLayout];
    }
}

- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    // Fix: remove the blanket negative additionalSafeAreaInsets.top that was injected into every VC on the nav stack.
    // That negative inset caused two serious problems:
    //   1. VCs laid out against safeAreaLayoutGuide.topAnchor (such as the settings page) had their content pushed above the navigation bar ("flying to the top"),
    //      so options like the appearance settings could not be scrolled or used.
    //   2. On pushed sub-pages such as Java management, the negative inset let the previous page show through below the current one,
    //      leaving the visual residue of "the previous page did not disappear in time".
    // The "big white band" problem is already solved by makeViewControllerTransparent (setting the VC view background to clearColor)
    // plus applyEffectToNavigationBar (the frosted-glass navigation bar), so this hack is no longer needed.
    //
    // Key fix (cumulative UI glitch): only a NEGATIVE .top additionalSafeAreaInsets used to be cleared,
    // leaving .left/.right/.bottom and positive values to accumulate. With tmpRootVC retained, if another path
    // added a left/right inset this method could not catch it, and the contentContainer content area grew wider.
    // Non-zero insets are now cleared in every direction.
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

#pragma mark - Setup

- (void)setupContainers {
    // Left sidebar container - translucent, with rounded corners only on the outer (top-left/bottom-left) side, so no groove forms where it meets the middle container
    self.sidebarContainer = [[UIView alloc] init];
    self.sidebarContainer.translatesAutoresizingMaskIntoConstraints = NO;
    self.sidebarContainer.layer.cornerRadius = 16;
    self.sidebarContainer.layer.maskedCorners = kCALayerMinXMinYCorner | kCALayerMinXMaxYCorner;
    self.sidebarContainer.layer.masksToBounds = YES;
    [[BackgroundManager sharedManager] applyEffectToView:self.sidebarContainer];
    [self.view addSubview:self.sidebarContainer];

    // Middle content container - fully transparent with square corners (it holds a nav controller + table view, and rounded corners would clip the content for no visual gain)
    self.contentContainer = [[UIView alloc] init];
    self.contentContainer.translatesAutoresizingMaskIntoConstraints = NO;
    self.contentContainer.backgroundColor = [UIColor clearColor];
    [self.view addSubview:self.contentContainer];

    // Right panel container - translucent, with rounded corners only on the outer (top-right/bottom-right) side
    self.rightPanelContainer = [[UIView alloc] init];
    self.rightPanelContainer.translatesAutoresizingMaskIntoConstraints = NO;
    self.rightPanelContainer.layer.cornerRadius = 16;
    self.rightPanelContainer.layer.maskedCorners = kCALayerMaxXMinYCorner | kCALayerMaxXMaxYCorner;
    self.rightPanelContainer.layer.masksToBounds = YES;
    [[BackgroundManager sharedManager] applyEffectToView:self.rightPanelContainer];
    [self.view addSubview:self.rightPanelContainer];
    
    // Set up the constraints
    // Use variable-width constraints, so they can be updated when traitCollection changes (iPhone/iPad adaptation)
    self.sidebarWidthConstraint = [self.sidebarContainer.widthAnchor constraintEqualToConstant:LauncherRootLayoutSidebarWidth(self.traitCollection)];
    self.rightPanelWidthConstraint = [self.rightPanelContainer.widthAnchor constraintEqualToConstant:LauncherRootLayoutRightPanelWidth(self.traitCollection)];

    [NSLayoutConstraint activateConstraints:@[
        // Left sidebar
        [self.sidebarContainer.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [self.sidebarContainer.topAnchor constraintEqualToAnchor:self.view.topAnchor],
        [self.sidebarContainer.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor],
        self.sidebarWidthConstraint,

        // Right panel
        [self.rightPanelContainer.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [self.rightPanelContainer.topAnchor constraintEqualToAnchor:self.view.topAnchor],
        [self.rightPanelContainer.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor],
        self.rightPanelWidthConstraint,

        // Middle content area — fills the space between the sidebar and the right panel
        [self.contentContainer.leadingAnchor constraintEqualToAnchor:self.sidebarContainer.trailingAnchor],
        [self.contentContainer.trailingAnchor constraintEqualToAnchor:self.rightPanelContainer.leadingAnchor],
        [self.contentContainer.topAnchor constraintEqualToAnchor:self.view.topAnchor],
        [self.contentContainer.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor]
    ]];
}

- (void)setupChildViewControllers {
    // Left sidebar - the feature menu
    LauncherMenuViewController *sidebarVC = [[LauncherMenuViewController alloc] init];
    [self addChildViewController:sidebarVC];
    sidebarVC.view.translatesAutoresizingMaskIntoConstraints = NO;
    [self.sidebarContainer addSubview:sidebarVC.view];
    [NSLayoutConstraint activateConstraints:@[
        [sidebarVC.view.leadingAnchor constraintEqualToAnchor:self.sidebarContainer.leadingAnchor],
        [sidebarVC.view.trailingAnchor constraintEqualToAnchor:self.sidebarContainer.trailingAnchor],
        [sidebarVC.view.topAnchor constraintEqualToAnchor:self.sidebarContainer.topAnchor],
        [sidebarVC.view.bottomAnchor constraintEqualToAnchor:self.sidebarContainer.bottomAnchor]
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
    [self.rightPanelContainer addSubview:rightPanelVC.view];
    [NSLayoutConstraint activateConstraints:@[
        [rightPanelVC.view.leadingAnchor constraintEqualToAnchor:self.rightPanelContainer.leadingAnchor],
        [rightPanelVC.view.trailingAnchor constraintEqualToAnchor:self.rightPanelContainer.trailingAnchor],
        [rightPanelVC.view.topAnchor constraintEqualToAnchor:self.rightPanelContainer.topAnchor],
        [rightPanelVC.view.bottomAnchor constraintEqualToAnchor:self.rightPanelContainer.bottomAnchor]
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
    // FCL style: account management is shown in the middle content area (no more FormSheet modals)
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(showAccountManager)
                                                 name:@"ShowAccountManager"
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

#pragma mark - Home screen shortcuts (replacing the old FormSheet dialog)

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

/// FCL style: account management is shown in the middle content area (no more FormSheet modals)
- (void)showAccountManager {
    AccountListViewController *vc = [[AccountListViewController alloc] initWithStyle:UITableViewStyleInsetGrouped];
    // Tell the right panel to refresh after an account is selected (reusing the existing UpdateAccountInfo notification)
    vc.whenItemSelected = ^void() {
        [[NSNotificationCenter defaultCenter] postNotificationName:@"UpdateAccountInfo" object:nil];
    };
    // Tell the right panel to refresh after an account is deleted too
    vc.whenDelete = ^void(NSString *name) {
        [[NSNotificationCenter defaultCenter] postNotificationName:@"UpdateAccountInfo" object:nil];
    };
    UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:vc];
    nav.navigationBar.prefersLargeTitles = NO;
    [self setContentViewController:nav animated:YES];
}

- (void)backgroundChanged {
    // Re-apply the background
    [[BackgroundManager sharedManager] applyBackgroundToView:self.view];
}

- (void)uiEffectChanged:(NSNotification *)notification {
    // Re-apply the frosted-glass/translucent effect to the container views
    [[BackgroundManager sharedManager] applyEffectToView:self.sidebarContainer];
    [[BackgroundManager sharedManager] applyEffectToView:self.rightPanelContainer];
}

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

#pragma mark - Custom Appearance (font color / card color, consistent with the Card layout)

- (void)applyCustomAppearance {
    // Apply the custom card color (a translucent overlay on the BackgroundManager frosted glass, rather than replacing it)
    NSString *cardColor = getPrefObject(@"general.card_color");
    if (cardColor.length > 0) {
        UIColor *color = [self colorFromHexString:cardColor];
        if (color) {
            // Overlay the frosted glass with a translucent color, with the alpha raised to 0.85 for visibility.
            // The previous 0.7 was too faint and barely showed on a light background.
            // The frosted glass is kept (backgroundColor is layered on top of the UIVisualEffectView),
            // so the card tint shows while the background image still comes through.
            CGFloat r, g, b, a;
            if ([color getRed:&r green:&g blue:&b alpha:&a]) {
                UIColor *semiColor = [UIColor colorWithRed:r green:g blue:b alpha:MIN(a, 0.85)];
                [self applySemiTransparentColor:semiColor toContainer:self.sidebarContainer];
                [self applySemiTransparentColor:semiColor toContainer:self.rightPanelContainer];
            }
        }
    } else {
        // With no custom color set, restore the frosted-glass effect
        [self restoreEffectToContainer:self.sidebarContainer];
        [self restoreEffectToContainer:self.rightPanelContainer];
    }
    // Tell child VCs such as the right panel and the menu to refresh their appearance (keeping text_color / card_color in sync)
    [[NSNotificationCenter defaultCenter] postNotificationName:@"LauncherAppearanceApplied" object:nil];
}

- (void)applySemiTransparentColor:(UIColor *)color toContainer:(UIView *)container {
    // Keep the frosted-glass UIVisualEffectView from BackgroundManager and overlay a translucent solid color on top
    // This shows the user's card color while still letting the background image through
    container.backgroundColor = color;
}

- (void)restoreEffectToContainer:(UIView *)container {
    container.backgroundColor = [UIColor clearColor];
    // Check whether the frosted glass is already there, and re-apply it if not
    BOOL hasBlur = NO;
    for (UIView *sub in container.subviews) {
        if ([sub isKindOfClass:[UIVisualEffectView class]]) {
            hasBlur = YES;
            break;
        }
    }
    if (!hasBlur) {
        [[BackgroundManager sharedManager] applyEffectToView:container];
    }
}

- (UIColor *)colorFromHexString:(NSString *)hexString {
    NSString *hex = [hexString stringByReplacingOccurrencesOfString:@"#" withString:@""];
    if (hex.length != 6 && hex.length != 8) return nil;
    unsigned int rgb = 0;
    if (![[NSScanner scannerWithString:hex] scanHexInt:&rgb]) return nil;
    unsigned int r, g, b, a;
    if (hex.length == 6) {
        // RRGGBB
        r = (rgb >> 16) & 0xFF;
        g = (rgb >> 8) & 0xFF;
        b = rgb & 0xFF;
        a = 255;
    } else {
        // AARRGGBB
        a = (rgb >> 24) & 0xFF;
        r = (rgb >> 16) & 0xFF;
        g = (rgb >> 8) & 0xFF;
        b = rgb & 0xFF;
    }
    return [UIColor colorWithRed:r/255.0 green:g/255.0 blue:b/255.0 alpha:a/255.0];
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

    // FCL style: apply the frosted-glass nav bar effect to the UINavigationController and make the content VC transparent,
    // so the default white nav bar does not appear as a "big white band" and it matches the dark frosted panels on either side.
    if ([viewController isKindOfClass:[UINavigationController class]]) {
        UINavigationController *nav = (UINavigationController *)viewController;
        nav.delegate = self;
        [[BackgroundManager sharedManager] applyEffectToNavigationBar:nav.navigationBar];
        // Make topViewController transparent, so the background shows through the nav bar blur
        [[BackgroundManager sharedManager] makeViewControllerTransparent:nav.topViewController];
        // Make every VC already on the nav stack transparent (so the previous page cannot show through)
        for (UIViewController *stackVC in nav.viewControllers) {
            [[BackgroundManager sharedManager] makeViewControllerTransparent:stackVC];
        }
    } else {
        // VCs not wrapped in a navigation controller are made transparent too, so they blend with the background
        [[BackgroundManager sharedManager] makeViewControllerTransparent:viewController];
    }

    // Key fix (cumulative UI glitch): deactivate the old constraints, so a cached and reused child VC does not activate
    // a cached and reused child VC activated its constraints again and again, widening the contentContainer content area.
    if (self.currentContentConstraints.count > 0) {
        [NSLayoutConstraint deactivateConstraints:self.currentContentConstraints];
        self.currentContentConstraints = nil;
    }

    NSArray<NSLayoutConstraint *> *newConstraints = @[
        [viewController.view.leadingAnchor constraintEqualToAnchor:self.contentContainer.leadingAnchor],
        [viewController.view.trailingAnchor constraintEqualToAnchor:self.contentContainer.trailingAnchor],
        [viewController.view.topAnchor constraintEqualToAnchor:self.contentContainer.topAnchor],
        [viewController.view.bottomAnchor constraintEqualToAnchor:self.contentContainer.bottomAnchor]
    ];

    if (animated && oldVC) {
        // Fix for issue 5: the original implementation used two separate UIView transitionWithView: calls (one to remove the old view, one to add the new),
        // Two crossDissolves acting on contentContainer at once caused visual conflicts and ghosting (the old frame covering the new screen before it faded out).
        // It now uses a single transition: "remove the old view + add the new view" happen in the same animations block,
        // so crossDissolve captures the before and after snapshots correctly, and the completion block tears down the old VC parent/child relationship.
        //
        // Key fix (the entry animation popped out of the top-left corner): UIKit snapshots the container as soon as the animations block returns,
        // and at that point the new view has been addSubview-ed and had its constraints activated but has not been through a layout pass, so its frame is still
        // (0,0,0,0). Combined with the masksToBounds and rounded-corner clipping of the contentContainer subview (contentCard),
        // the crossDissolve looked like it was "expanding out of a dot in the top-left corner".
        // Calling layoutIfNeeded explicitly inside the animations block forces an immediate layout, so snapshot B already has a full-size frame
        // and the crossDissolve is an ordinary fade. The duration was raised from 0.25 to 0.3 for a softer, more natural transition.
        [UIView transitionWithView:self.contentContainer
                          duration:0.3
                           options:UIViewAnimationOptionTransitionCrossDissolve
                        animations:^{
                            [oldVC willMoveToParentViewController:nil];
                            [oldVC.view removeFromSuperview];
                            [self.contentContainer addSubview:viewController.view];
                            [NSLayoutConstraint activateConstraints:newConstraints];
                            [self.contentContainer layoutIfNeeded];
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
        [self.contentContainer addSubview:viewController.view];
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

/// Once a nav stack push or pop completes, make the newly shown VC transparent,
/// so every pushed sub-page (Java management, mod management, modpack import and so on)
/// shows the custom launcher background rather than the default systemBackgroundColor (white).
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
