#import "authenticator/BaseAuthenticator.h"
#import "AccountListViewController.h"
#import "AFNetworking.h"
#import "ALTServerConnection.h"
#import "LauncherNavigationController.h"
#import "LauncherMenuViewController.h"
#import "LauncherNewsViewController.h"
#import "LauncherPreferences.h"
#import "LauncherPreferencesViewController.h"
#import "LauncherProfilesViewController.h"
#import "ModsManagerViewController.h"
#import "ShadersManagerViewController.h"
#import "ModpackImportViewController.h"
#import "PLProfiles.h"
#import "UIButton+AFNetworking.h"
#import "UIImageView+AFNetworking.h"
#import "UIKit+hook.h"
#import "ios_uikit_bridge.h"
#import "utils.h"
#include <dlfcn.h>

@implementation LauncherMenuCustomItem

+ (LauncherMenuCustomItem *)title:(NSString *)title imageName:(NSString *)imageName action:(id)action {
    LauncherMenuCustomItem *item = [[LauncherMenuCustomItem alloc] init];
    item.title = title;
    item.imageName = imageName;
    item.action = action;
    return item;
}

+ (LauncherMenuCustomItem *)vcClass:(Class)class {
    id vc = [class new];
    LauncherMenuCustomItem *item = [[LauncherMenuCustomItem alloc] init];
    item.title = [vc title];
    item.imageName = [vc imageName];
    item.vcArray = @[vc];
    return item;
}

@end

@interface LauncherMenuViewController()
@property(nonatomic) NSMutableArray<LauncherMenuCustomItem*> *options;
@property(nonatomic) UILabel *statusLabel;
@property(nonatomic) int lastSelectedIndex;
@property(nonatomic, weak) NSLayoutConstraint *announcementContainerHeightConstraint;
@property(nonatomic, weak) UIView *announcementContainer;
@property(nonatomic, weak) UILabel *announcementLabel;
@property(nonatomic, weak) UIButton *downloadButton;

// FCL Style UI
@property(nonatomic, strong) UIView *sidebarView;
@property(nonatomic, strong) UIView *contentContainer;
@property(nonatomic, strong) UIView *rightPanel;
@property(nonatomic, strong) UIButton *launchButton;
@property(nonatomic, strong) UIImageView *avatarImageView;
@property(nonatomic, strong) UILabel *usernameLabel;
@property(nonatomic, strong) UILabel *versionLabel;
@property(nonatomic, strong) UISegmentedControl *rendererSwitcher;
@end

@implementation LauncherMenuViewController

#define contentNavigationController ((LauncherNavigationController *)self.splitViewController.viewControllers[1])

- (void)viewDidLoad {
    [super viewDidLoad];
    self.isInitialVc = YES;
    
    // Hide default navigation bar for FCL style
    self.navigationController.navigationBarHidden = YES;
    
    // Setup FCL style UI
    [self setupFCLInterface];
    
    // Setup sidebar menu
    [self setupSidebar];
    
    // Setup content area
    [self setupContentArea];
    
    // Setup right panel (avatar + launch button)
    [self setupRightPanel];
    
    // Load initial data
    [self updateAccountInfo];
    [self updateVersionInfo];
    
    // JIT check
    if (getEntitlementValue(@"get-task-allow")) {
        [self checkJITStatus];
    }
}

#pragma mark - FCL Interface Setup

- (void)setupFCLInterface {
    self.view.backgroundColor = [UIColor clearColor];
    
    // Main container with three columns: sidebar | content | right panel
    // Sidebar: ~60pt width
    // Content: flexible
    // Right panel: ~200pt width
}

- (void)setupSidebar {
    // Sidebar container
    self.sidebarView = [[UIView alloc] init];
    self.sidebarView.translatesAutoresizingMaskIntoConstraints = NO;
    self.sidebarView.backgroundColor = [UIColor colorWithWhite:0.08 alpha:0.95];
    [self.view addSubview:self.sidebarView];
    
    // Sidebar items (FCL style icons)
    NSArray *menuItems = @[
        @{@"icon": @"house.fill", @"title": @"ä¸»é¡µ"},
        @{@"icon": @"arrow.down.circle.fill", @"title": @"ä¸è½½"},
        @{@"icon": @"puzzlepiece.fill", @"title": @"æ¨¡ç»"},
        @{@"icon": @"gearshape.fill", @"title": @"è®¾ç½®"}
    ];
    
    CGFloat buttonSize = 50;
    CGFloat spacing = 20;
    CGFloat startY = 40;
    
    for (NSInteger i = 0; i < menuItems.count; i++) {
        NSDictionary *item = menuItems[i];
        UIButton *btn = [UIButton buttonWithType:UIButtonTypeSystem];
        btn.translatesAutoresizingMaskIntoConstraints = NO;
        [btn setImage:[UIImage systemImageNamed:item[@"icon"]] forState:UIControlStateNormal];
        btn.tintColor = (i == 0) ? [UIColor colorWithRed:0.26 green:0.63 blue:0.96 alpha:1.0] : [UIColor systemGrayColor];
        btn.tag = i;
        [btn addTarget:self action:@selector(sidebarButtonTapped:) forControlEvents:UIControlEventTouchUpInside];
        [self.sidebarView addSubview:btn];
        
        [NSLayoutConstraint activateConstraints:@[
            [btn.topAnchor constraintEqualToAnchor:self.sidebarView.topAnchor constant:startY + i * (buttonSize + spacing)],
            [btn.centerXAnchor constraintEqualToAnchor:self.sidebarView.centerXAnchor],
            [btn.widthAnchor constraintEqualToConstant:buttonSize],
            [btn.heightAnchor constraintEqualToConstant:buttonSize]
        ]];
    }
    
    // Sidebar constraints
    [NSLayoutConstraint activateConstraints:@[
        [self.sidebarView.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [self.sidebarView.topAnchor constraintEqualToAnchor:self.view.topAnchor],
        [self.sidebarView.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor],
        [self.sidebarView.widthAnchor constraintEqualToConstant:70]
    ]];
}

- (void)setupContentArea {
    // Content container (middle area)
    self.contentContainer = [[UIView alloc] init];
    self.contentContainer.translatesAutoresizingMaskIntoConstraints = NO;
    self.contentContainer.backgroundColor = [UIColor clearColor];
    [self.view addSubview:self.contentContainer];
    
    // Add News view controller as child
    LauncherNewsViewController *newsVC = [[LauncherNewsViewController alloc] init];
    [self addChildViewController:newsVC];
    newsVC.view.translatesAutoresizingMaskIntoConstraints = NO;
    [self.contentContainer addSubview:newsVC.view];
    [newsVC didMoveToParentViewController:self];
    
    [NSLayoutConstraint activateConstraints:@[
        [newsVC.view.leadingAnchor constraintEqualToAnchor:self.contentContainer.leadingAnchor],
        [newsVC.view.trailingAnchor constraintEqualToAnchor:self.contentContainer.trailingAnchor],
        [newsVC.view.topAnchor constraintEqualToAnchor:self.contentContainer.topAnchor],
        [newsVC.view.bottomAnchor constraintEqualToAnchor:self.contentContainer.bottomAnchor]
    ]];
    
    // Content constraints
    [NSLayoutConstraint activateConstraints:@[
        [self.contentContainer.leadingAnchor constraintEqualToAnchor:self.sidebarView.trailingAnchor],
        [self.contentContainer.topAnchor constraintEqualToAnchor:self.view.topAnchor],
        [self.contentContainer.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor]
    ]];
}

- (void)setupRightPanel {
    // Right panel container
    self.rightPanel = [[UIView alloc] init];
    self.rightPanel.translatesAutoresizingMaskIntoConstraints = NO;
    self.rightPanel.backgroundColor = [UIColor colorWithWhite:0.08 alpha:0.95];
    [self.view addSubview:self.rightPanel];
    
    // Renderer switcher (Pojav/Boat)
    self.rendererSwitcher = [[UISegmentedControl alloc] initWithItems:@[@"Pojav", @"Boat"]];
    self.rendererSwitcher.translatesAutoresizingMaskIntoConstraints = NO;
    self.rendererSwitcher.selectedSegmentIndex = 0;
    self.rendererSwitcher.backgroundColor = [UIColor colorWithWhite:0.2 alpha:1.0];
    [self.rightPanel addSubview:self.rendererSwitcher];
    
    // Avatar image
    self.avatarImageView = [[UIImageView alloc] init];
    self.avatarImageView.translatesAutoresizingMaskIntoConstraints = NO;
    self.avatarImageView.contentMode = UIViewContentModeScaleAspectFit;
    self.avatarImageView.layer.cornerRadius = 40;
    self.avatarImageView.layer.masksToBounds = YES;
    self.avatarImageView.backgroundColor = [UIColor colorWithWhite:0.2 alpha:1.0];
    self.avatarImageView.image = [UIImage systemImageNamed:@"person.circle.fill"];
    [self.rightPanel addSubview:self.avatarImageView];
    
    // Username label
    self.usernameLabel = [[UILabel alloc] init];
    self.usernameLabel.translatesAutoresizingMaskIntoConstraints = NO;
    self.usernameLabel.font = [UIFont boldSystemFontOfSize:16];
    self.usernameLabel.textColor = [UIColor labelColor];
    self.usernameLabel.textAlignment = NSTextAlignmentCenter;
    self.usernameLabel.text = @"æªç»å½";
    [self.rightPanel addSubview:self.usernameLabel];
    
    // Version label
    self.versionLabel = [[UILabel alloc] init];
    self.versionLabel.translatesAutoresizingMaskIntoConstraints = NO;
    self.versionLabel.font = [UIFont systemFontOfSize:13];
    self.versionLabel.textColor = [UIColor secondaryLabelColor];
    self.versionLabel.textAlignment = NSTextAlignmentCenter;
    self.versionLabel.text = @"æªéæ©çæ¬";
    [self.rightPanel addSubview:self.versionLabel];
    
    // Launch button (FCL style)
    self.launchButton = [UIButton buttonWithType:UIButtonTypeSystem];
    self.launchButton.translatesAutoresizingMaskIntoConstraints = NO;
    [self.launchButton setTitle:@"å¯å¨æ¸¸æ" forState:UIControlStateNormal];
    [self.launchButton setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    self.launchButton.titleLabel.font = [UIFont boldSystemFontOfSize:18];
    self.launchButton.backgroundColor = [UIColor colorWithRed:0.26 green:0.63 blue:0.96 alpha:1.0];
    self.launchButton.layer.cornerRadius = 12;
    self.launchButton.layer.masksToBounds = YES;
    [self.launchButton addTarget:self action:@selector(launchGame) forControlEvents:UIControlEventTouchUpInside];
    [self.rightPanel addSubview:self.launchButton];
    
    // Version management button
    UIButton *manageVersionBtn = [UIButton buttonWithType:UIButtonTypeSystem];
    manageVersionBtn.translatesAutoresizingMaskIntoConstraints = NO;
    [manageVersionBtn setTitle:@"ç®¡ççæ¬" forState:UIControlStateNormal];
    [manageVersionBtn setTitleColor:[UIColor labelColor] forState:UIControlStateNormal];
    manageVersionBtn.backgroundColor = [UIColor colorWithWhite:0.2 alpha:1.0];
    manageVersionBtn.layer.cornerRadius = 8;
    [manageVersionBtn addTarget:self action:@selector(showVersionManager) forControlEvents:UIControlEventTouchUpInside];
    [self.rightPanel addSubview:manageVersionBtn];
    
    // Execute JAR button
    UIButton *executeJarBtn = [UIButton buttonWithType:UIButtonTypeSystem];
    executeJarBtn.translatesAutoresizingMaskIntoConstraints = NO;
    [executeJarBtn setTitle:@"æ§è¡Jar" forState:UIControlStateNormal];
    [executeJarBtn setTitleColor:[UIColor labelColor] forState:UIControlStateNormal];
    executeJarBtn.backgroundColor = [UIColor colorWithWhite:0.2 alpha:1.0];
    executeJarBtn.layer.cornerRadius = 8;
    [executeJarBtn addTarget:self action:@selector(executeJar) forControlEvents:UIControlEventTouchUpInside];
    [self.rightPanel addSubview:executeJarBtn];
    
    // Right panel constraints
    [NSLayoutConstraint activateConstraints:@[
        [self.rightPanel.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [self.rightPanel.topAnchor constraintEqualToAnchor:self.view.topAnchor],
        [self.rightPanel.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor],
        [self.rightPanel.widthAnchor constraintEqualToConstant:220],
        [self.rightPanel.leadingAnchor constraintEqualToAnchor:self.contentContainer.trailingAnchor],
        
        // Renderer switcher
        [self.rendererSwitcher.topAnchor constraintEqualToAnchor:self.rightPanel.topAnchor constant:20],
        [self.rendererSwitcher.leadingAnchor constraintEqualToAnchor:self.rightPanel.leadingAnchor constant:16],
        [self.rendererSwitcher.trailingAnchor constraintEqualToAnchor:self.rightPanel.trailingAnchor constant:-16],
        
        // Avatar
        [self.avatarImageView.topAnchor constraintEqualToAnchor:self.rendererSwitcher.bottomAnchor constant:30],
        [self.avatarImageView.centerXAnchor constraintEqualToAnchor:self.rightPanel.centerXAnchor],
        [self.avatarImageView.widthAnchor constraintEqualToConstant:80],
        [self.avatarImageView.heightAnchor constraintEqualToConstant:80],
        
        // Username
        [self.usernameLabel.topAnchor constraintEqualToAnchor:self.avatarImageView.bottomAnchor constant:12],
        [self.usernameLabel.leadingAnchor constraintEqualToAnchor:self.rightPanel.leadingAnchor constant:16],
        [self.usernameLabel.trailingAnchor constraintEqualToAnchor:self.rightPanel.trailingAnchor constant:-16],
        
        // Version
        [self.versionLabel.topAnchor constraintEqualToAnchor:self.usernameLabel.bottomAnchor constant:4],
        [self.versionLabel.leadingAnchor constraintEqualToAnchor:self.rightPanel.leadingAnchor constant:16],
        [self.versionLabel.trailingAnchor constraintEqualToAnchor:self.rightPanel.trailingAnchor constant:-16],
        
        // Launch button
        [self.launchButton.bottomAnchor constraintEqualToAnchor:manageVersionBtn.topAnchor constant:-16],
        [self.launchButton.leadingAnchor constraintEqualToAnchor:self.rightPanel.leadingAnchor constant:16],
        [self.launchButton.trailingAnchor constraintEqualToAnchor:self.rightPanel.trailingAnchor constant:-16],
        [self.launchButton.heightAnchor constraintEqualToConstant:50],
        
        // Manage version button
        [manageVersionBtn.bottomAnchor constraintEqualToAnchor:executeJarBtn.topAnchor constant:-8],
        [manageVersionBtn.leadingAnchor constraintEqualToAnchor:self.rightPanel.leadingAnchor constant:16],
        [manageVersionBtn.trailingAnchor constraintEqualToAnchor:self.rightPanel.trailingAnchor constant:-16],
        [manageVersionBtn.heightAnchor constraintEqualToConstant:40],
        
        // Execute JAR button
        [executeJarBtn.bottomAnchor constraintEqualToAnchor:self.rightPanel.safeAreaLayoutGuide.bottomAnchor constant:-20],
        [executeJarBtn.leadingAnchor constraintEqualToAnchor:self.rightPanel.leadingAnchor constant:16],
        [executeJarBtn.trailingAnchor constraintEqualToAnchor:self.rightPanel.trailingAnchor constant:-16],
        [executeJarBtn.heightAnchor constraintEqualToConstant:40]
    ]];
}

#pragma mark - Actions

- (void)sidebarButtonTapped:(UIButton *)sender {
    NSInteger index = sender.tag;
    
    // Update button colors
    for (UIView *view in self.sidebarView.subviews) {
        if ([view isKindOfClass:[UIButton class]]) {
            UIButton *btn = (UIButton *)view;
            btn.tintColor = (btn.tag == index) ? [UIColor colorWithRed:0.26 green:0.63 blue:0.96 alpha:1.0] : [UIColor systemGrayColor];
        }
    }
    
    // Handle navigation
    switch (index) {
        case 0: // Home
            // Already on home
            break;
        case 1: // Download
            [self showDownloadView];
            break;
        case 2: // Mods
            [self showModsView];
            break;
        case 3: // Settings
            [self showSettingsView];
            break;
    }
}

- (void)showDownloadView {
    // Show download view
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"ä¸è½½"
                                                                   message:@"åè½å¼åä¸­"
                                                            preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"ç¡®å®" style:UIAlertActionStyleDefault handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)showModsView {
    ModsManagerViewController *vc = [[ModsManagerViewController alloc] init];
    vc.profileName = PLProfiles.current.selectedProfileName ?: @"default";
    UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:vc];
    nav.modalPresentationStyle = UIModalPresentationFormSheet;
    [self presentViewController:nav animated:YES completion:nil];
}

- (void)showSettingsView {
    LauncherPreferencesViewController *vc = [[LauncherPreferencesViewController alloc] init];
    UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:vc];
    nav.modalPresentationStyle = UIModalPresentationFormSheet;
    [self presentViewController:nav animated:YES completion:nil];
}

- (void)showVersionManager {
    LauncherProfilesViewController *vc = [[LauncherProfilesViewController alloc] init];
    UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:vc];
    nav.modalPresentationStyle = UIModalPresentationFormSheet;
    [self presentViewController:nav animated:YES completion:nil];
}

- (void)executeJar {
    [contentNavigationController performSelector:@selector(enterModInstaller)];
}

- (void)launchGame {
    BaseAuthenticator *currentAuth = BaseAuthenticator.current;
    if (!currentAuth) {
        [self showAlert:@"è¯·åç»å½è´¦æ·"];
        return;
    }
    
    NSString *selectedProfile = PLProfiles.current.selectedProfileName;
    if (!selectedProfile) {
        [self showAlert:@"è¯·åéæ©ä¸ä¸ªçæ¬"];
        return;
    }
    
    SurfaceViewController *gameVC = [[SurfaceViewController alloc] init];
    gameVC.modalPresentationStyle = UIModalPresentationFullScreen;
    [self presentViewController:gameVC animated:YES completion:nil];
}

- (void)showAlert:(NSString *)message {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"æç¤º"
                                                                   message:message
                                                            preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"ç¡®å®" style:UIAlertActionStyleDefault handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
}

#pragma mark - Data Updates

- (void)updateAccountInfo {
    BaseAuthenticator *currentAuth = BaseAuthenticator.current;
    if (currentAuth && currentAuth.authData) {
        NSString *username = currentAuth.authData[@"username"];
        if (username) {
            if ([username hasPrefix:@"Demo."]) {
                username = [username substringFromIndex:5];
            }
            self.usernameLabel.text = username;
        }
        
        // Account type
        if (currentAuth.authData[@"xboxGamertag"]) {
            // Microsoft account
        } else if (currentAuth.authData[@"clientToken"]) {
            // Third-party
        }
        
        // Avatar
        NSString *avatarURL = currentAuth.authData[@"profilePicURL"];
        if (avatarURL) {
            avatarURL = [avatarURL stringByReplacingOccurrencesOfString:@"\\/" withString:@"/"];
            dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
                NSData *imageData = [NSData dataWithContentsOfURL:[NSURL URLWithString:avatarURL]];
                if (imageData) {
                    UIImage *image = [UIImage imageWithData:imageData];
                    dispatch_async(dispatch_get_main_queue(), ^{
                        self.avatarImageView.image = image;
                    });
                }
            });
        }
    } else {
        self.usernameLabel.text = @"æªç»å½";
        self.avatarImageView.image = [UIImage systemImageNamed:@"person.circle.fill"];
    }
}

- (void)updateVersionInfo {
    NSString *selectedProfile = PLProfiles.current.selectedProfileName;
    if (selectedProfile) {
        NSDictionary *profile = PLProfiles.current.profiles[selectedProfile];
        if (profile) {
            NSString *name = profile[@"name"] ?: selectedProfile;
            NSString *versionId = profile[@"lastVersionId"] ?: @"unknown";
            self.versionLabel.text = [NSString stringWithFormat:@"%@", versionId];
        }
    } else {
        self.versionLabel.text = @"æªéæ©çæ¬";
    }
}

#pragma mark - JIT

- (void)checkJITStatus {
    if (isJITEnabled(false)) {
        NSLog(@"[LauncherMenu] JIT is enabled");
    } else {
        [self enableJITWithAltKit];
    }
}

- (void)enableJITWithAltKit {
    [ALTServerManager.sharedManager startDiscovering];
    [ALTServerManager.sharedManager autoconnectWithCompletionHandler:^(ALTServerConnection *connection, NSError *error) {
        if (error) {
            NSLog(@"[AltKit] Could not auto-connect: %@", error);
            return;
        }
        
        [connection enableUnsignedCodeExecutionWithCompletionHandler:^(BOOL success, NSError *error) {
            if (success) {
                NSLog(@"[AltKit] JIT enabled successfully");
                [ALTServerManager.sharedManager stopDiscovering];
            } else {
                NSLog(@"[AltKit] Error enabling JIT: %@", error);
            }
            [connection disconnect];
        }];
    }];
}

#pragma mark - Legacy methods (kept for compatibility)

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    [self updateAccountInfo];
    [self updateVersionInfo];
}

- (void)restoreHighlightedSelection {
    // Not used in FCL style
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    return 0; // Not used in FCL style
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    return nil; // Not used in FCL style
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    // Not used in FCL style
}

- (void)selectAccount:(UIButton *)sender {
    AccountListViewController *vc = [[AccountListViewController alloc] init];
    vc.whenItemSelected = ^void() {
        [self updateAccountInfo];
    };
    UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:vc];
    nav.modalPresentationStyle = UIModalPresentationFormSheet;
    [self presentViewController:nav animated:YES completion:nil];
}

- (void)displayProgress:(NSString *)status {
    // Not used in FCL style
}

@end
