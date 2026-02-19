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
    // View controllers are put into an array to keep its state
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
@end

@implementation LauncherMenuViewController

#define contentNavigationController ((LauncherNavigationController *)self.splitViewController.viewControllers[1])

- (void)viewDidLoad {
    [super viewDidLoad];
    self.isInitialVc = YES;
    
    UIImageView *titleView = [[UIImageView alloc] initWithImage:[UIImage imageNamed:@"AppLogo"]];
    [titleView setContentMode:UIViewContentModeScaleAspectFit];
    self.navigationItem.titleView = titleView;
    [titleView sizeToFit];
    
    self.options = @[
        [LauncherMenuCustomItem vcClass:LauncherNewsViewController.class],
        [LauncherMenuCustomItem vcClass:LauncherProfilesViewController.class],
        [LauncherMenuCustomItem vcClass:LauncherPreferencesViewController.class],
    ].mutableCopy;
    
    if (realUIIdiom != UIUserInterfaceIdiomTV) {
        [self.options addObject:(id)[LauncherMenuCustomItem
            title:localize(@"launcher.menu.custom_controls", nil)
            imageName:@"MenuCustomControls" action:^{
                [contentNavigationController performSelector:@selector(enterCustomControls)];
            }]];
    }
    
    [self.options addObject:
        (id)[LauncherMenuCustomItem
            title:localize(@"launcher.menu.execute_jar", nil)
            imageName:@"MenuInstallJar" action:^{
                [contentNavigationController performSelector:@selector(enterModInstaller)];
            }]];
    
    // Mod Manager entry
    [self.options addObject:
        (id)[LauncherMenuCustomItem
            title:@"管理模组"
            imageName:@"puzzlepiece.extension" action:^{
                ModsManagerViewController *modsVC = [[ModsManagerViewController alloc] init];
                modsVC.profileName = PLProfiles.current.selectedProfileName;
                UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:modsVC];
                nav.modalPresentationStyle = UIModalPresentationFormSheet;
                [self presentViewController:nav animated:YES completion:nil];
            }]];
    
    // Shader Manager entry
    [self.options addObject:
        (id)[LauncherMenuCustomItem
            title:@"管理光影"
            imageName:@"photo" action:^{
                ShadersManagerViewController *shadersVC = [[ShadersManagerViewController alloc] init];
                shadersVC.profileName = PLProfiles.current.selectedProfileName;
                UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:shadersVC];
                nav.modalPresentationStyle = UIModalPresentationFormSheet;
                [self presentViewController:nav animated:YES completion:nil];
            }]];
    
    // Modpack Import entry
    [self.options addObject:
        (id)[LauncherMenuCustomItem
            title:@"导入整合包"
            imageName:@"archivebox" action:^{
                ModpackImportViewController *modpackVC = [[ModpackImportViewController alloc] init];
                modpackVC.profileName = PLProfiles.current.selectedProfileName;
                UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:modpackVC];
                nav.modalPresentationStyle = UIModalPresentationFormSheet;
                [self presentViewController:nav animated:YES completion:nil];
            }]];
    
    // TODO: Finish log-uploading service integration
    [self.options addObject:
        (id)[LauncherMenuCustomItem
            title:localize(@"login.menu.sendlogs", nil)
            imageName:@"square.and.arrow.up" action:^{
                NSString *latestlogPath = [NSString stringWithFormat:@"file://%s/latestlog.old.txt", getenv("POJAV_HOME")];
                NSLog(@"Path is %@", latestlogPath);
                UIActivityViewController *activityVC;
                if (realUIIdiom != UIUserInterfaceIdiomTV) {
                    activityVC = [[UIActivityViewController alloc]
                        initWithActivityItems:@[[NSURL URLWithString:latestlogPath]]
                        applicationActivities:nil];
                } else {
                    dlopen("/System/Library/PrivateFrameworks/SharingUI.framework/SharingUI", RTLD_GLOBAL);
                    activityVC =
                        [[NSClassFromString(@"SFAirDropSharingViewControllerTV") alloc]
                            performSelector:@selector(initWithSharingItems:)
                            withObject:@[[NSURL URLWithString:latestlogPath]]];
                }
                activityVC.popoverPresentationController.sourceView = titleView;
                activityVC.popoverPresentationController.sourceRect = titleView.bounds;
                [self presentViewController:activityVC animated:YES completion:nil];
            }]];
    
    NSDateFormatter *dateFormatter = [[NSDateFormatter alloc] init];
    dateFormatter.dateFormat = @"MM-dd";
    NSString *date = [dateFormatter stringFromDate:NSDate.date];
    
    if([date isEqualToString:@"06-29"] || [date isEqualToString:@"06-30"] || [date isEqualToString:@"07-01"]) {
        [self.options addObject:(id)[LauncherMenuCustomItem
            title:@"Technoblade never dies!"
            imageName:@"" action:^{
                openLink(self, [NSURL URLWithString:@"https://www.bilibili.com/video/BV1RG411s7fw"]);
            }]];
    }
    
    // Fogg05 Easter Egg - Display on Dec 27, 28, 29
    if([date isEqualToString:@"12-27"] || [date isEqualToString:@"12-28"] || [date isEqualToString:@"12-29"]) {
        [self.options addObject:(id)[LauncherMenuCustomItem
            title:@"To the one who colored the blocks"
            imageName:@"" action:^{
                NSString *urlString = @"https://wiki.easecation.net/零雾05_Fogg05";
                NSString *encodedUrlString = [urlString stringByAddingPercentEncodingWithAllowedCharacters:[NSCharacterSet URLPathAllowedCharacterSet]];
                openLink(self, [NSURL URLWithString:encodedUrlString]);
            }]];
    }
    
    self.tableView.separatorStyle = UITableViewCellSeparatorStyleNone;
    self.navigationController.toolbarHidden = NO;
    
    UIActivityIndicatorViewStyle indicatorStyle = UIActivityIndicatorViewStyleMedium;
    UIActivityIndicatorView *toolbarIndicator = [[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:indicatorStyle];
    [toolbarIndicator startAnimating];
    
    self.toolbarItems = @[
        [[UIBarButtonItem alloc] initWithCustomView:toolbarIndicator],
        [[UIBarButtonItem alloc] init]
    ];
    self.toolbarItems[1].tintColor = UIColor.labelColor;
    
    // Setup the account button
    self.accountBtnItem = [self drawAccountButton];
    [self updateAccountInfo];
    
    NSUInteger initialIndex = 0;
    UIViewController *currentRoot = contentNavigationController.viewControllers.firstObject;
    for (NSUInteger i = 0; i < self.options.count; i++) {
        LauncherMenuCustomItem *opt = self.options[i];
        if (opt.vcArray.count > 0 && [currentRoot isKindOfClass:[opt.vcArray[0] class]]) {
            initialIndex = i;
            break;
        }
    }
    
    NSIndexPath *indexPath = [NSIndexPath indexPathForRow:initialIndex inSection:0];
    [self.tableView selectRowAtIndexPath:indexPath animated:YES scrollPosition:UITableViewScrollPositionNone];
    [self tableView:self.tableView didSelectRowAtIndexPath:indexPath];
    
    // Get current app version
    NSString *currentVersion = [[[NSBundle mainBundle] infoDictionary] objectForKey:@"CFBundleShortVersionString"];
    
    // Create announcement banner
    UILabel *announcementLabel = [[UILabel alloc] init];
    announcementLabel.textAlignment = NSTextAlignmentLeft;
    announcementLabel.textColor = [UIColor labelColor];
    announcementLabel.font = [UIFont systemFontOfSize:14 weight:UIFontWeightMedium];
    announcementLabel.translatesAutoresizingMaskIntoConstraints = NO;
    announcementLabel.numberOfLines = 0;
    
    // Create announcement container view
    UIView *announcementContainer = [[UIView alloc] init];
    announcementContainer.translatesAutoresizingMaskIntoConstraints = NO;
    
    // Set container style - compatible with iOS 14.0
    if (@available(iOS 13.0, *)) {
        announcementContainer.backgroundColor = [[UIColor systemBackgroundColor] colorWithAlphaComponent:0.95];
    } else {
        announcementContainer.backgroundColor = [[UIColor whiteColor] colorWithAlphaComponent:0.95];
    }
    
    announcementContainer.layer.cornerRadius = 12;
    announcementContainer.layer.masksToBounds = YES;
    
    // Add border
    announcementContainer.layer.borderWidth = 1.0;
    if (@available(iOS 13.0, *)) {
        announcementContainer.layer.borderColor = [[UIColor separatorColor] colorWithAlphaComponent:0.3].CGColor;
    } else {
        announcementContainer.layer.borderColor = [[UIColor lightGrayColor] colorWithAlphaComponent:0.3].CGColor;
    }
    
    // Add shadow effect
    announcementContainer.layer.shadowColor = [UIColor blackColor].CGColor;
    announcementContainer.layer.shadowOffset = CGSizeMake(0, 2);
    announcementContainer.layer.shadowRadius = 4;
    announcementContainer.layer.shadowOpacity = 0.1;
    
    // Add info icon
    UIImageView *infoIcon = [[UIImageView alloc] init];
    infoIcon.translatesAutoresizingMaskIntoConstraints = NO;
    
    // Use system icon, compatible with iOS 14.0
    if (@available(iOS 13.0, *)) {
        infoIcon.image = [UIImage systemImageNamed:@"info.circle.fill"];
        infoIcon.tintColor = [UIColor systemBlueColor];
    } else {
        // Fallback for iOS below 13
        infoIcon.image = [UIImage imageNamed:@"MenuInfo"];
        if (!infoIcon.image) {
            // Create a simple circle if no image asset
            UIGraphicsBeginImageContextWithOptions(CGSizeMake(20, 20), NO, 0.0);
            CGContextRef context = UIGraphicsGetCurrentContext();
            [[UIColor blueColor] setFill];
            CGContextFillEllipseInRect(context, CGRectMake(0, 0, 20, 20));
            UIImage *circleImage = UIGraphicsGetImageFromCurrentImageContext();
            UIGraphicsEndImageContext();
            infoIcon.image = circleImage;
        }
    }
    [announcementContainer addSubview:infoIcon];
    
    // Add announcement label to container
    [announcementContainer addSubview:announcementLabel];
    
    // Set icon constraints - fixed at top
    [NSLayoutConstraint activateConstraints:@[
        [infoIcon.leadingAnchor constraintEqualToAnchor:announcementContainer.leadingAnchor constant:8],
        [infoIcon.topAnchor constraintEqualToAnchor:announcementContainer.topAnchor constant:12],
        [infoIcon.widthAnchor constraintEqualToConstant:20],
        [infoIcon.heightAnchor constraintEqualToConstant:20]
    ]];
    
    // Set announcement label constraints (right of icon, top aligned)
    [NSLayoutConstraint activateConstraints:@[
        [announcementLabel.topAnchor constraintEqualToAnchor:announcementContainer.topAnchor constant:12],
        [announcementLabel.leadingAnchor constraintEqualToAnchor:infoIcon.trailingAnchor constant:8],
        [announcementLabel.trailingAnchor constraintEqualToAnchor:announcementContainer.trailingAnchor constant:-8]
    ]];
    
    // Add announcement container to view, below navigation bar, above table view
    [self.view addSubview:announcementContainer];
    
    // Set announcement container constraints - adapt to sidebar layout
    NSLayoutConstraint *heightConstraint = [announcementContainer.heightAnchor constraintEqualToConstant:60];
    self.announcementContainerHeightConstraint = heightConstraint;
    [NSLayoutConstraint activateConstraints:@[
        [announcementContainer.topAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.topAnchor constant:8],
        [announcementContainer.leadingAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.leadingAnchor constant:8],
        [announcementContainer.trailingAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.trailingAnchor constant:-8],
        heightConstraint
    ]];
    
    // Store announcement banner reference
    self.announcementContainer = announcementContainer;
    self.announcementLabel = announcementLabel;
    
    // Adjust table view top inset to make room for announcement banner
    // Initial setting: 60 (container height) + 16 (top/bottom margin) = 76
    self.tableView.contentInset = UIEdgeInsetsMake(76, 0, 0, 0);
    
    // Check if current version contains "Preview"
    if ([currentVersion rangeOfString:@"Preview" options:NSCaseInsensitiveSearch].location != NSNotFound) {
        announcementLabel.text = localize(@"announcement.preview_version", @"Welcome to Amethyst iOS Remastered Preview!");
    } else {
        // Try to get latest GitHub Release version
        [self checkForUpdateWithCurrentVersion:currentVersion announcementLabel:announcementLabel announcementContainer:announcementContainer retryCount:0];
    }
    
    // JIT check - only for supported installations
    if (getEntitlementValue(@"get-task-allow")) {
        [self displayProgress:localize(@"login.jit.checking", nil)];
        if (isJITEnabled(false)) {
            [self displayProgress:localize(@"login.jit.enabled", nil)];
            [self displayProgress:nil];
        } else {
            [self enableJITWithAltKit];
        }
    }
    
    // DISABLED: JIT installation check popup for enterprise certificate testing
    // The popup that shows "Unsupported installation method" has been removed
    // to allow testing with enterprise certificates
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    [self restoreHighlightedSelection];
}

- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    
    // Ensure table view contentInset is correctly set
    if (self.tableView.contentInset.top < 70) {
        self.tableView.contentInset = UIEdgeInsetsMake(76, 0, 0, 0);
    }
    
    // Recalculate announcement banner height for sidebar width changes
    if (self.announcementContainer && self.announcementLabel) {
        static CGFloat previousWidth = 0;
        CGFloat currentWidth = self.announcementContainer.frame.size.width;
        
        if (fabs(currentWidth - previousWidth) > 1.0 && currentWidth > 50) {
            previousWidth = currentWidth;
            
            if (self.downloadButton) {
                [self adjustAnnouncementContainerHeight:self.announcementContainer forLabel:self.announcementLabel withButton:self.downloadButton];
            } else {
                [self adjustAnnouncementContainerHeight:self.announcementContainer forLabel:self.announcementLabel];
            }
        }
    }
}

- (UIBarButtonItem *)drawAccountButton {
    if (!self.accountBtnItem) {
        self.accountButton = [UIButton buttonWithType:UIButtonTypeCustom];
        [self.accountButton addTarget:self action:@selector(selectAccount:) forControlEvents:UIControlEventPrimaryActionTriggered];
        self.accountButton.contentHorizontalAlignment = UIControlContentHorizontalAlignmentLeft;
        
        self.accountButton.titleEdgeInsets = UIEdgeInsetsMake(0, 4, 0, -4);
        self.accountButton.imageView.contentMode = UIViewContentModeScaleAspectFit;
        self.accountButton.titleLabel.lineBreakMode = NSLineBreakByWordWrapping;
        
        self.accountBtnItem = [[UIBarButtonItem alloc] initWithCustomView:self.accountButton];
    }
    [self updateAccountInfo];
    return self.accountBtnItem;
}

- (void)restoreHighlightedSelection {
    // Restore the selected row when the view appears again
    NSIndexPath *indexPath = [NSIndexPath indexPathForRow:self.lastSelectedIndex inSection:0];
    [self.tableView selectRowAtIndexPath:indexPath animated:NO scrollPosition:UITableViewScrollPositionNone];
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    return self.options.count;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"cell"];
    if (cell == nil) {
        cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:@"cell"];
    }
    
    cell.textLabel.text = [self.options[indexPath.row] title];
    
    UIImage *origImage = [UIImage systemImageNamed:[self.options[indexPath.row] performSelector:@selector(imageName)]];
    if (origImage) {
        UIImage *image;
        if (@available(iOS 10.0, *)) {
            UIGraphicsImageRenderer *renderer = [[UIGraphicsImageRenderer alloc] initWithSize:CGSizeMake(40, 40)];
            image = [renderer imageWithActions:^(UIGraphicsImageRendererContext * _Nonnull myContext) {
                CGFloat scaleFactor = 40.0 / origImage.size.height;
                [origImage drawInRect:CGRectMake(20.0 - (origImage.size.width * scaleFactor / 2.0), 0, origImage.size.width * scaleFactor, 40.0)];
            }];
        } else {
            // Fallback for older iOS versions
            UIGraphicsBeginImageContextWithOptions(CGSizeMake(40, 40), NO, 0.0);
            CGFloat scaleFactor = 40.0 / origImage.size.height;
            [origImage drawInRect:CGRectMake(20.0 - (origImage.size.width * scaleFactor / 2.0), 0, origImage.size.width * scaleFactor, 40.0)];
            image = UIGraphicsGetImageFromCurrentImageContext();
            UIGraphicsEndImageContext();
        }
        cell.imageView.image = [image imageWithRenderingMode:UIImageRenderingModeAlwaysTemplate];
    }
    
    if (cell.imageView.image == nil) {
        cell.imageView.layer.magnificationFilter = kCAFilterNearest;
        cell.imageView.layer.minificationFilter = kCAFilterNearest;
        cell.imageView.image = [UIImage imageNamed:[self.options[indexPath.row] performSelector:@selector(imageName)]];
        cell.imageView.image = [cell.imageView.image _imageWithSize:CGSizeMake(40, 40)];
    }
    
    return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    LauncherMenuCustomItem *selected = self.options[indexPath.row];
    if (selected.action != nil) {
        [self restoreHighlightedSelection];
        ((LauncherMenuCustomItem *)selected).action();
    } else {
        if(self.isInitialVc) {
            self.isInitialVc = NO;
            self.lastSelectedIndex = indexPath.row;
        } else {
            self.options[self.lastSelectedIndex].vcArray = contentNavigationController.viewControllers;
            [contentNavigationController setViewControllers:selected.vcArray animated:NO];
            self.lastSelectedIndex = indexPath.row;
        }
        selected.vcArray[0].navigationItem.rightBarButtonItem = self.accountBtnItem;
        selected.vcArray[0].navigationItem.leftBarButtonItem = self.splitViewController.displayModeButtonItem;
        selected.vcArray[0].navigationItem.leftItemsSupplementBackButton = true;
    }
}

- (void)selectAccount:(UIButton *)sender {
    AccountListViewController *vc = [[AccountListViewController alloc] init];
    
    vc.whenDelete = ^void(NSString *name) {
        if ([name isEqualToString:getPrefObject(@"internal.selected_account")]) {
            BaseAuthenticator.current = nil;
            setPrefObject(@"internal.selected_account", @"");
            [self updateAccountInfo];
        }
    };
    
    vc.whenItemSelected = ^void() {
        BaseAuthenticator *currentAuth = BaseAuthenticator.current;
        setPrefObject(@"internal.selected_account", currentAuth.authData[@"username"]);
        [self updateAccountInfo];
        if (sender != self.accountButton) {
            // Called from the play button, so call back to continue
            [sender sendActionsForControlEvents:UIControlEventPrimaryActionTriggered];
        }
    };
    
    vc.modalPresentationStyle = UIModalPresentationPopover;
    vc.preferredContentSize = CGSizeMake(350, 250);
    
    UIPopoverPresentationController *popoverController = vc.popoverPresentationController;
    popoverController.sourceView = sender;
    popoverController.sourceRect = sender.bounds;
    popoverController.permittedArrowDirections = UIPopoverArrowDirectionAny;
    popoverController.delegate = vc;
    
    [self presentViewController:vc animated:YES completion:nil];
}

- (void)updateAccountInfo {
    BaseAuthenticator *currentAuth = BaseAuthenticator.current;
    NSDictionary *selected = currentAuth.authData;
    
    CGSize size = CGSizeMake(contentNavigationController.view.frame.size.width, contentNavigationController.view.frame.size.height);
    
    if (selected == nil) {
        if((size.width / 3) > 200) {
            [self.accountButton setAttributedTitle:[[NSAttributedString alloc] initWithString:localize(@"login.option.select", nil)] forState:UIControlStateNormal];
        } else {
            [self.accountButton setAttributedTitle:(NSAttributedString *)@"" forState:UIControlStateNormal];
        }
        [self.accountButton setImage:[UIImage imageNamed:@"DefaultAccount"] forState:UIControlStateNormal];
        [self.accountButton sizeToFit];
        return;
    }
    
    // Remove the prefix "Demo." if there is
    BOOL isDemo = [selected[@"username"] hasPrefix:@"Demo."];
    NSMutableAttributedString *title = [[NSMutableAttributedString alloc] initWithString:[selected[@"username"] substringFromIndex:(isDemo ? 5 : 0)]];
    
    // Check if we're switching between demo and full mode
    BOOL shouldUpdateProfiles = (getenv("DEMO_LOCK") != NULL) != isDemo;
    
    // Reset states
    unsetenv("DEMO_LOCK");
    setenv("POJAV_GAME_DIR", [NSString stringWithFormat:@"%s/Library/Application Support/minecraft", getenv("POJAV_HOME")].UTF8String, 1);
    
    id subtitle;
    if (isDemo) {
        subtitle = localize(@"login.option.demo", nil);
        setenv("DEMO_LOCK", "1", 1);
        setenv("POJAV_GAME_DIR", [NSString stringWithFormat:@"%s/.demo", getenv("POJAV_HOME")].UTF8String, 1);
    } else if (selected[@"clientToken"] != nil) {
        // This is a third-party account
        subtitle = localize(@"login.option.3rdparty", nil);
    } else if (selected[@"xboxGamertag"] == nil) {
        subtitle = localize(@"login.option.local", nil);
    } else {
        // Display the Xbox gamertag for online accounts
        subtitle = selected[@"xboxGamertag"];
    }
    
    subtitle = [[NSAttributedString alloc] initWithString:subtitle attributes:@{NSFontAttributeName: [UIFont systemFontOfSize:12]}];
    [title appendAttributedString:[[NSAttributedString alloc] initWithString:@"\n" attributes:nil]];
    [title appendAttributedString:subtitle];
    
    if((size.width / 3) > 200) {
        [self.accountButton setAttributedTitle:title forState:UIControlStateNormal];
    } else {
        [self.accountButton setAttributedTitle:(NSAttributedString *)@"" forState:UIControlStateNormal];
    }
    
    // TODO: Add caching mechanism for profile pictures
    NSURL *url = [NSURL URLWithString:[selected[@"profilePicURL"] stringByReplacingOccurrencesOfString:@"\\/" withString:@"/"]];
    UIImage *placeholder = [UIImage imageNamed:@"DefaultAccount"];
    [self.accountButton setImageForState:UIControlStateNormal withURL:url placeholderImage:placeholder];
    [self.accountButton.imageView setImageWithURL:url placeholderImage:placeholder];
    [self.accountButton sizeToFit];
    
    // Update profiles and local version list if needed
    if (shouldUpdateProfiles) {
        [contentNavigationController fetchLocalVersionList];
        [contentNavigationController performSelector:@selector(reloadProfileList)];
    }
    
    // Update tableView whenever we have
    UITableViewController *tableVC = contentNavigationController.viewControllers.lastObject;
    if ([tableVC isKindOfClass:UITableViewController.class]) {
        [tableVC.tableView reloadData];
    }
}

- (void)displayProgress:(NSString *)status {
    if (status == nil) {
        [(UIActivityIndicatorView *)self.toolbarItems[0].customView stopAnimating];
    } else {
        self.toolbarItems[1].title = status;
    }
}

- (void)enableJITWithAltKit {
    [ALTServerManager.sharedManager startDiscovering];
    [ALTServerManager.sharedManager autoconnectWithCompletionHandler:^(ALTServerConnection *connection, NSError *error) {
        if (error) {
            NSLog(@"[AltKit] Could not auto-connect to server. %@", error.localizedRecoverySuggestion);
            [self displayProgress:localize(@"login.jit.fail", nil)];
            [self displayProgress:nil];
            return;
        }
        
        [connection enableUnsignedCodeExecutionWithCompletionHandler:^(BOOL success, NSError *error) {
            if (success) {
                NSLog(@"[AltKit] Successfully enabled JIT compilation!");
                [ALTServerManager.sharedManager stopDiscovering];
                [self displayProgress:localize(@"login.jit.enabled", nil)];
                [self displayProgress:nil];
            } else {
                NSLog(@"[AltKit] Error enabling JIT: %@", error.localizedRecoverySuggestion);
                [self displayProgress:localize(@"login.jit.fail", nil)];
                [self displayProgress:nil];
            }
            [connection disconnect];
        }];
    }];
}

// Version comparison method
- (NSComparisonResult)compareVersion:(NSString *)version1 withVersion:(NSString *)version2 {
    NSArray *v1Components = [version1 componentsSeparatedByString:@"."];
    NSArray *v2Components = [version2 componentsSeparatedByString:@"."];
    
    NSInteger maxComponents = MAX(v1Components.count, v2Components.count);
    
    for (NSInteger i = 0; i < maxComponents; i++) {
        NSInteger v1 = 0;
        NSInteger v2 = 0;
        
        if (i < v1Components.count) {
            v1 = [v1Components[i] integerValue];
        }
        
        if (i < v2Components.count) {
            v2 = [v2Components[i] integerValue];
        }
        
        if (v1 < v2) {
            return NSOrderedAscending;
        } else if (v1 > v2) {
            return NSOrderedDescending;
        }
    }
    
    return NSOrderedSame;
}

// Download latest version
- (void)downloadLatestVersion:(UIButton *)sender {
    NSString *urlString = @"https://github.com/herbrine8403/Amethyst-iOS-MyRemastered/releases/latest";
    NSURL *url = [NSURL URLWithString:urlString];
    if ([[UIApplication sharedApplication] canOpenURL:url]) {
        [[UIApplication sharedApplication] openURL:url options:@{} completionHandler:nil];
    }
}

// Adjust announcement container height (label only)
- (void)adjustAnnouncementContainerHeight:(UIView *)container forLabel:(UILabel *)label {
    CGFloat containerWidth = container.frame.size.width;
    CGFloat maxWidth = containerWidth - 62;
    
    if (maxWidth <= 0) {
        maxWidth = self.view.frame.size.width - 94;
    }
    if (maxWidth <= 0) {
        maxWidth = 200;
    }
    
    [label setNeedsLayout];
    [label layoutIfNeeded];
    
    CGSize labelSize = [label sizeThatFits:CGSizeMake(maxWidth, CGFLOAT_MAX)];
    CGFloat labelHeight = labelSize.height;
    CGFloat containerHeight = MAX(44, labelHeight + 24);
    
    if (self.announcementContainerHeightConstraint) {
        self.announcementContainerHeightConstraint.constant = containerHeight;
    }
    
    CGFloat topInset = containerHeight + 16;
    self.tableView.contentInset = UIEdgeInsetsMake(topInset, 0, 0, 0);
    
    [container.superview layoutIfNeeded];
}

// Adjust announcement container height (with button)
- (void)adjustAnnouncementContainerHeight:(UIView *)container forLabel:(UILabel *)label withButton:(UIButton *)button {
    CGFloat containerWidth = container.frame.size.width;
    CGFloat maxWidth = containerWidth - 62;
    
    if (maxWidth <= 0) {
        maxWidth = self.view.frame.size.width - 94;
    }
    if (maxWidth <= 0) {
        maxWidth = 200;
    }
    
    [label setNeedsLayout];
    [label layoutIfNeeded];
    
    CGSize labelSize = [label sizeThatFits:CGSizeMake(maxWidth, CGFLOAT_MAX)];
    CGFloat labelHeight = labelSize.height;
    CGFloat containerHeight = MAX(72, labelHeight + 12 + 8 + 30 + 10);
    
    if (self.announcementContainerHeightConstraint) {
        self.announcementContainerHeightConstraint.constant = containerHeight;
    }
    
    CGFloat topInset = containerHeight + 16;
    self.tableView.contentInset = UIEdgeInsetsMake(topInset, 0, 0, 0);
    
    [container.superview layoutIfNeeded];
}

// Check for updates (using HTML parsing to avoid GitHub API rate limits)
- (void)checkForUpdateWithCurrentVersion:(NSString *)currentVersion
                       announcementLabel:(UILabel *)announcementLabel
                     announcementContainer:(UIView *)announcementContainer
                              retryCount:(NSInteger)retryCount {
    
    NSInteger maxRetries = 2;
    NSURL *url = [NSURL URLWithString:@"https://github.com/herbrine8403/Amethyst-iOS-MyRemastered/releases/latest"];
    
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:url];
    request.timeoutInterval = 15.0;
    
    NSURLSessionDataTask *task = [[NSURLSession sharedSession] dataTaskWithRequest:request completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        if (error) {
            NSLog(@"[UpdateCheck] Network request failed: %@", error.localizedDescription);
            
            if (retryCount < maxRetries) {
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.0 * (retryCount + 1) * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                    [self checkForUpdateWithCurrentVersion:currentVersion
                                       announcementLabel:announcementLabel
                                     announcementContainer:announcementContainer
                                              retryCount:retryCount + 1];
                });
                return;
            }
            
            dispatch_async(dispatch_get_main_queue(), ^{
                announcementLabel.text = localize(@"announcement.latest_version", @"Welcome to Amethyst iOS Remastered! Current version is up to date.");
                [self adjustAnnouncementContainerHeight:announcementContainer forLabel:announcementLabel];
            });
            return;
        }
        
        NSHTTPURLResponse *httpResponse = (NSHTTPURLResponse *)response;
        NSInteger statusCode = httpResponse.statusCode;
        
        if (statusCode != 200) {
            NSLog(@"[UpdateCheck] HTTP status code error: %ld", (long)statusCode);
            
            if (retryCount < maxRetries) {
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.0 * (retryCount + 1) * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                    [self checkForUpdateWithCurrentVersion:currentVersion
                                       announcementLabel:announcementLabel
                                     announcementContainer:announcementContainer
                                              retryCount:retryCount + 1];
                });
                return;
            }
            
            dispatch_async(dispatch_get_main_queue(), ^{
                announcementLabel.text = localize(@"announcement.latest_version", @"Welcome to Amethyst iOS Remastered! Current version is up to date.");
                [self adjustAnnouncementContainerHeight:announcementContainer forLabel:announcementLabel];
            });
            return;
        }
        
        NSString *htmlString = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
        
        if (!htmlString || htmlString.length == 0) {
            NSLog(@"[UpdateCheck] HTML content is empty");
            
            if (retryCount < maxRetries) {
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.0 * (retryCount + 1) * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                    [self checkForUpdateWithCurrentVersion:currentVersion
                                       announcementLabel:announcementLabel
                                     announcementContainer:announcementContainer
                                              retryCount:retryCount + 1];
                });
                return;
            }
            
            dispatch_async(dispatch_get_main_queue(), ^{
                announcementLabel.text = localize(@"announcement.latest_version", @"Welcome to Amethyst iOS Remastered! Current version is up to date.");
                [self adjustAnnouncementContainerHeight:announcementContainer forLabel:announcementLabel];
            });
            return;
        }
        
        NSString *pattern = @"/herbrine8403/Amethyst-iOS-MyRemastered/releases/tag/([^\"]+)\"";
        NSRegularExpression *regex = [NSRegularExpression regularExpressionWithPattern:pattern options:0 error:nil];
        NSTextCheckingResult *match = [regex firstMatchInString:htmlString options:0 range:NSMakeRange(0, htmlString.length)];
        
        NSString *latestVersion = nil;
        if (match && match.numberOfRanges > 1) {
            latestVersion = [htmlString substringWithRange:[match rangeAtIndex:1]];
        }
        
        if (!latestVersion) {
            NSLog(@"[UpdateCheck] Could not extract version from HTML");
            dispatch_async(dispatch_get_main_queue(), ^{
                announcementLabel.text = localize(@"announcement.latest_version", @"Welcome to Amethyst iOS Remastered! Current version is up to date.");
                [self adjustAnnouncementContainerHeight:announcementContainer forLabel:announcementLabel];
            });
            return;
        }
        
        if ([latestVersion hasPrefix:@"v"]) {
            latestVersion = [latestVersion substringFromIndex:1];
        }
        
        NSLog(@"[UpdateCheck] Current version: %@, Latest version: %@", currentVersion, latestVersion);
        
        dispatch_async(dispatch_get_main_queue(), ^{
            NSComparisonResult versionComparison = [self compareVersion:currentVersion withVersion:latestVersion];
            
            if (versionComparison == NSOrderedAscending) {
                NSString *localizedText = localize(@"announcement.new_version_available", @"New version available: %@");
                announcementLabel.text = [NSString stringWithFormat:localizedText, latestVersion];
                
                [announcementLabel setNeedsLayout];
                [announcementLabel layoutIfNeeded];
                
                UIButton *downloadButton = [UIButton buttonWithType:UIButtonTypeSystem];
                [downloadButton setTitle:localize(@"announcement.download_button", @"Go to Download") forState:UIControlStateNormal];
                
                if (@available(iOS 13.0, *)) {
                    downloadButton.backgroundColor = [UIColor systemBlueColor];
                } else {
                    downloadButton.backgroundColor = [UIColor colorWithRed:0/255.0 green:122/255.0 blue:255/255.0 alpha:1.0];
                }
                
                [downloadButton setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
                downloadButton.titleLabel.font = [UIFont systemFontOfSize:14 weight:UIFontWeightSemibold];
                downloadButton.layer.cornerRadius = 8;
                downloadButton.translatesAutoresizingMaskIntoConstraints = NO;
                
                downloadButton.layer.shadowColor = [UIColor blackColor].CGColor;
                downloadButton.layer.shadowOffset = CGSizeMake(0, 2);
                downloadButton.layer.shadowRadius = 4;
                downloadButton.layer.shadowOpacity = 0.2;
                
                downloadButton.layer.masksToBounds = NO;
                
                if (@available(iOS 13.0, *)) {
                    UIImage *downloadImage = [UIImage systemImageNamed:@"arrow.down.circle.fill"];
                    [downloadButton setImage:downloadImage forState:UIControlStateNormal];
                    downloadButton.imageEdgeInsets = UIEdgeInsetsMake(0, -8, 0, 0);
                    downloadButton.titleEdgeInsets = UIEdgeInsetsMake(0, 8, 0, 0);
                    downloadButton.tintColor = [UIColor whiteColor];
                }
                
                [downloadButton addTarget:self action:@selector(downloadLatestVersion:) forControlEvents:UIControlEventTouchUpInside];
                
                [announcementContainer addSubview:downloadButton];
                
                self.downloadButton = downloadButton;
                
                [NSLayoutConstraint activateConstraints:@[
                    [downloadButton.topAnchor constraintEqualToAnchor:announcementLabel.bottomAnchor constant:8],
                    [downloadButton.leadingAnchor constraintEqualToAnchor:announcementContainer.leadingAnchor constant:8],
                    [downloadButton.trailingAnchor constraintEqualToAnchor:announcementContainer.trailingAnchor constant:-8],
                    [downloadButton.heightAnchor constraintEqualToConstant:30],
                    [downloadButton.bottomAnchor constraintEqualToAnchor:announcementContainer.bottomAnchor constant:-10]
                ]];
                
                [self adjustAnnouncementContainerHeight:announcementContainer forLabel:announcementLabel withButton:downloadButton];
            } else {
                announcementLabel.text = localize(@"announcement.latest_version", @"Welcome to Amethyst iOS Remastered! Current version is up to date.");
                
                [announcementLabel setNeedsLayout];
                [announcementLabel layoutIfNeeded];
                
                [self adjustAnnouncementContainerHeight:announcementContainer forLabel:announcementLabel];
            }
        });
    }];
    
    [task resume];
}

@end
