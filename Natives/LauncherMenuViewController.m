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
    NSString* date = [dateFormatter stringFromDate:NSDate.date];
    if([date isEqualToString:@"06-29"] || [date isEqualToString:@"06-30"] || [date isEqualToString:@"07-01"]) {
        [self.options addObject:(id)[LauncherMenuCustomItem
                                     title:@"Technoblade never dies!"
                                     imageName:@"" action:^{
            openLink(self, [NSURL URLWithString:@"https://www.bilibili.com/video/BV1RG411s7fw"]);
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
    
    // 获取当前应用版本
    NSString *currentVersion = [[[NSBundle mainBundle] infoDictionary] objectForKey:@"CFBundleShortVersionString"];
    
    // 创建公告栏
    UILabel *announcementLabel = [[UILabel alloc] init];
    announcementLabel.textAlignment = NSTextAlignmentCenter;
    // 使用系统灰色并添加透明度以实现半透明效果
    announcementLabel.backgroundColor = [[UIColor grayColor] colorWithAlphaComponent:0.5];
    announcementLabel.textColor = [UIColor labelColor]; // 使用系统标签颜色，自动适配深色模式
    announcementLabel.font = [UIFont systemFontOfSize:14];
    announcementLabel.translatesAutoresizingMaskIntoConstraints = NO;
    announcementLabel.numberOfLines = 0; // 允许多行文本
    
    // 将公告栏添加到视图中
    [self.view addSubview:announcementLabel];
    
    // 检查当前版本是否包含"Preview"字样
    if ([currentVersion rangeOfString:@"Preview" options:NSCaseInsensitiveSearch].location != NSNotFound) {
        announcementLabel.text = localize(@"announcement.preview_version", @"欢迎使用Amethyst iOS Remastered测试版！");
    } else {
        // 尝试获取GitHub最新的Release版本号
        NSURL *url = [NSURL URLWithString:@"https://api.github.com/repos/herbrine8403/Amethyst-iOS-MyRemastered/releases/latest"];
        NSURLRequest *request = [NSURLRequest requestWithURL:url];
        
        NSURLSessionDataTask *task = [[NSURLSession sharedSession] dataTaskWithRequest:request completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
            if (error) {
                dispatch_async(dispatch_get_main_queue(), ^{
                    announcementLabel.text = localize(@"announcement.latest_version", @"欢迎使用Amethyst iOS Remastered！当前已是最新正式版。");
                });
                return;
            }
            
            NSError *jsonError;
            NSDictionary *jsonResponse = [NSJSONSerialization JSONObjectWithData:data options:0 error:&jsonError];
            
            if (jsonError || !jsonResponse) {
                dispatch_async(dispatch_get_main_queue(), ^{
                    announcementLabel.text = localize(@"announcement.latest_version", @"欢迎使用Amethyst iOS Remastered！当前已是最新正式版。");
                });
                return;
            }
            
            NSString *latestVersion = jsonResponse[@"tag_name"];
            if (!latestVersion) {
                dispatch_async(dispatch_get_main_queue(), ^{
                    announcementLabel.text = localize(@"announcement.latest_version", @"欢迎使用Amethyst iOS Remastered！当前已是最新正式版。");
                });
                return;
            }
            
            // 移除标签前缀（如 "v"）
            if ([latestVersion hasPrefix:@"v"]) {
                latestVersion = [latestVersion substringFromIndex:1];
            }
            
            dispatch_async(dispatch_get_main_queue(), ^{
                NSComparisonResult versionComparison = [self compareVersion:currentVersion withVersion:latestVersion];
                
                if (versionComparison == NSOrderedAscending) {
                    // 当前版本小于最新版本
                    NSString *localizedText = localize(@"announcement.new_version_available", @"发现新版本：%@");
                    announcementLabel.text = [NSString stringWithFormat:@"%@", localizedText];
                    // 将 %@ 替换为实际版本号
                    announcementLabel.text = [NSString stringWithFormat:localizedText, latestVersion];
                    
                    // 创建下载按钮
                    UIButton *downloadButton = [UIButton buttonWithType:UIButtonTypeSystem];
                    [downloadButton setTitle:localize(@"announcement.download_button", @"前往下载") forState:UIControlStateNormal];
                    downloadButton.backgroundColor = [UIColor systemBlueColor];
                    [downloadButton setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
                    downloadButton.titleLabel.font = [UIFont systemFontOfSize:14];
                    downloadButton.layer.cornerRadius = 6;
                    downloadButton.translatesAutoresizingMaskIntoConstraints = NO;
                    
                    [downloadButton addTarget:self action:@selector(downloadLatestVersion:) forControlEvents:UIControlEventTouchUpInside];
                    
                    [self.view addSubview:downloadButton];
                    
                    // 设置下载按钮约束
                    [NSLayoutConstraint activateConstraints:@[
                        [downloadButton.topAnchor constraintEqualToAnchor:announcementLabel.bottomAnchor constant:5],
                        [downloadButton.centerXAnchor constraintEqualToAnchor:self.view.centerXAnchor],
                        [downloadButton.widthAnchor constraintEqualToConstant:100],
                        [downloadButton.heightAnchor constraintEqualToConstant:30]
                    ]];
                    
                    // 更新公告栏的约束以适应按钮
                    [NSLayoutConstraint activateConstraints:@[
                        [announcementLabel.heightAnchor constraintEqualToConstant:60] // 增加高度以适应可能的多行文本
                    ]];
                } else {
                    // 当前版本大于或等于最新版本
                    announcementLabel.text = localize(@"announcement.latest_version", @"欢迎使用Amethyst iOS Remastered！当前已是最新正式版。");
                }
            });
        }];
        
        [task resume];
    }
    
    // 设置公告栏约束
    [NSLayoutConstraint activateConstraints:@[
        [announcementLabel.topAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.topAnchor constant:10],
        [announcementLabel.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor constant:20],
        [announcementLabel.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor constant:-20],
        [announcementLabel.heightAnchor constraintEqualToConstant:30]
    ]];
    
    if (getEntitlementValue(@"get-task-allow")) {
        [self displayProgress:localize(@"login.jit.checking", nil)];
        if (isJITEnabled(false)) {
            [self displayProgress:localize(@"login.jit.enabled", nil)];
            [self displayProgress:nil];
        } else {
            [self enableJITWithAltKit];
        }
    } else if (!NSProcessInfo.processInfo.macCatalystApp && !getenv("SIMULATOR_DEVICE_NAME")) {
        [self displayProgress:localize(@"login.jit.fail", nil)];
        [self displayProgress:nil];
        UIAlertController* alert = [UIAlertController alertControllerWithTitle:localize(@"login.jit.fail.title", nil)
            message:localize(@"login.jit.fail.description_unsupported", nil)
            preferredStyle:UIAlertControllerStyleAlert];
        UIAlertAction* okAction = [UIAlertAction actionWithTitle:localize(@"OK", nil) style:UIAlertActionStyleDefault handler:^(id action){
            exit(-1);
        }];
        [alert addAction:okAction];
        [self presentViewController:alert animated:YES completion:nil];
    }
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    [self restoreHighlightedSelection];
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

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section
{
    return self.options.count;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath
{
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"cell"];
    if (cell == nil) {
        cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:@"cell"];
    }

    cell.textLabel.text = [self.options[indexPath.row] title];
    
    UIImage *origImage = [UIImage systemImageNamed:[self.options[indexPath.row]
        performSelector:@selector(imageName)]];
    if (origImage) {
        UIGraphicsImageRenderer *renderer = [[UIGraphicsImageRenderer alloc] initWithSize:CGSizeMake(40, 40)];
        UIImage *image = [renderer imageWithActions:^(UIGraphicsImageRendererContext*_Nonnull myContext) {
            CGFloat scaleFactor = 40/origImage.size.height;
            [origImage drawInRect:CGRectMake(20 - origImage.size.width*scaleFactor/2, 0, origImage.size.width*scaleFactor, 40)];
        }];
        cell.imageView.image = [image imageWithRenderingMode:UIImageRenderingModeAlwaysTemplate];
    }
    
    if (cell.imageView.image == nil) {
        cell.imageView.layer.magnificationFilter = kCAFilterNearest;
        cell.imageView.layer.minificationFilter = kCAFilterNearest;
        cell.imageView.image = [UIImage imageNamed:[self.options[indexPath.row]
            performSelector:@selector(imageName)]];
        cell.imageView.image = [cell.imageView.image _imageWithSize:CGSizeMake(40, 40)];
    }
    return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath
{
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
    vc.whenDelete = ^void(NSString* name) {
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
    NSMutableAttributedString *title = [[NSMutableAttributedString alloc] initWithString:[selected[@"username"] substringFromIndex:(isDemo?5:0)]];

    // Check if we're switching between demo and full mode
    BOOL shouldUpdateProfiles = (getenv("DEMO_LOCK")!=NULL) != isDemo;

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

// 版本比较方法
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

// 下载最新版本
- (void)downloadLatestVersion:(UIButton *)sender {
    NSString *urlString = @"https://github.com/herbrine8403/Amethyst-iOS-MyRemastered/releases/latest";
    NSURL *url = [NSURL URLWithString:urlString];
    
    if ([[UIApplication sharedApplication] canOpenURL:url]) {
        [[UIApplication sharedApplication] openURL:url options:@{} completionHandler:nil];
    }
}

@end
