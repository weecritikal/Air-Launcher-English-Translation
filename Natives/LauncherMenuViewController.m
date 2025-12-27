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
@property(nonatomic, weak) NSLayoutConstraint *announcementContainerHeightConstraint;
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
    announcementLabel.textColor = [UIColor labelColor]; // 使用系统标签颜色，自动适配深色模式
    announcementLabel.font = [UIFont systemFontOfSize:14 weight:UIFontWeightMedium];
    announcementLabel.translatesAutoresizingMaskIntoConstraints = NO;
    announcementLabel.numberOfLines = 0; // 允许多行文本
    
    // 创建公告栏容器视图
    UIView *announcementContainer = [[UIView alloc] init];
    announcementContainer.translatesAutoresizingMaskIntoConstraints = NO;
    
    // 设置容器样式 - 支持iOS14.0的兼容方式
    if (@available(iOS 13.0, *)) {
        announcementContainer.backgroundColor = [[UIColor systemBackgroundColor] colorWithAlphaComponent:0.95];
    } else {
        announcementContainer.backgroundColor = [[UIColor whiteColor] colorWithAlphaComponent:0.95];
    }
    
    announcementContainer.layer.cornerRadius = 12;
    announcementContainer.layer.masksToBounds = YES;
    
    // 添加边框
    announcementContainer.layer.borderWidth = 1.0;
    if (@available(iOS 13.0, *)) {
        announcementContainer.layer.borderColor = [[UIColor separatorColor] colorWithAlphaComponent:0.3].CGColor;
    } else {
        announcementContainer.layer.borderColor = [[UIColor lightGrayColor] colorWithAlphaComponent:0.3].CGColor;
    }
    
    // 添加阴影效果
    announcementContainer.layer.shadowColor = [UIColor blackColor].CGColor;
    announcementContainer.layer.shadowOffset = CGSizeMake(0, 2);
    announcementContainer.layer.shadowRadius = 4;
    announcementContainer.layer.shadowOpacity = 0.1;
    
    // 添加信息图标
    UIImageView *infoIcon = [[UIImageView alloc] init];
    infoIcon.translatesAutoresizingMaskIntoConstraints = NO;
    
    // 使用系统图标，兼容iOS14.0
    if (@available(iOS 13.0, *)) {
        infoIcon.image = [UIImage systemImageNamed:@"info.circle.fill"];
        infoIcon.tintColor = [UIColor systemBlueColor];
    } else {
        // iOS14以下使用自定义图标或文字
        infoIcon.image = [UIImage imageNamed:@"MenuInfo"];
        if (!infoIcon.image) {
            // 如果没有图片资源，创建一个简单的圆形
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
    
    // 添加公告标签到容器
    [announcementContainer addSubview:announcementLabel];
    
    // 设置图标约束
    [NSLayoutConstraint activateConstraints:@[
        [infoIcon.leadingAnchor constraintEqualToAnchor:announcementContainer.leadingAnchor constant:15],
        [infoIcon.centerYAnchor constraintEqualToAnchor:announcementContainer.centerYAnchor],
        [infoIcon.widthAnchor constraintEqualToConstant:20],
        [infoIcon.heightAnchor constraintEqualToConstant:20]
    ]];
    
    // 设置公告标签约束（在图标右侧）
    [NSLayoutConstraint activateConstraints:@[
        [announcementLabel.topAnchor constraintEqualToAnchor:announcementContainer.topAnchor constant:12],
        [announcementLabel.leadingAnchor constraintEqualToAnchor:infoIcon.trailingAnchor constant:12],
        [announcementLabel.trailingAnchor constraintEqualToAnchor:announcementContainer.trailingAnchor constant:-15],
        [announcementLabel.bottomAnchor constraintEqualToAnchor:announcementContainer.bottomAnchor constant:-12]
    ]];
    
    // 将公告容器添加到视图，放在导航栏下方、表格视图上方
    [self.view addSubview:announcementContainer];
    
    // 设置公告容器约束
    NSLayoutConstraint *heightConstraint = [announcementContainer.heightAnchor constraintEqualToConstant:60];
    self.announcementContainerHeightConstraint = heightConstraint;
    
    [NSLayoutConstraint activateConstraints:@[
        [announcementContainer.topAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.topAnchor constant:8],
        [announcementContainer.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor constant:16],
        [announcementContainer.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor constant:-16],
        heightConstraint
    ]];
    
    // 调整表格视图的顶部约束，为公告栏留出空间
    self.tableView.contentInset = UIEdgeInsetsMake(76, 0, 0, 0); // 60高度 + 8上边距 + 8间距
    
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
                    // 调整容器高度
                    [self adjustAnnouncementContainerHeight:announcementContainer forLabel:announcementLabel];
                });
                return;
            }
            
            NSError *jsonError;
            NSDictionary *jsonResponse = [NSJSONSerialization JSONObjectWithData:data options:0 error:&jsonError];
            
            if (jsonError || !jsonResponse) {
                dispatch_async(dispatch_get_main_queue(), ^{
                    announcementLabel.text = localize(@"announcement.latest_version", @"欢迎使用Amethyst iOS Remastered！当前已是最新正式版。");
                    [self adjustAnnouncementContainerHeight:announcementContainer forLabel:announcementLabel];
                });
                return;
            }
            
            NSString *latestVersion = jsonResponse[@"tag_name"];
            if (!latestVersion) {
                dispatch_async(dispatch_get_main_queue(), ^{
                    announcementLabel.text = localize(@"announcement.latest_version", @"欢迎使用Amethyst iOS Remastered！当前已是最新正式版。");
                    [self adjustAnnouncementContainerHeight:announcementContainer forLabel:announcementLabel];
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
                    announcementLabel.text = [NSString stringWithFormat:localizedText, latestVersion];
                    
                    // 创建下载按钮
                    UIButton *downloadButton = [UIButton buttonWithType:UIButtonTypeSystem];
                    [downloadButton setTitle:localize(@"announcement.download_button", @"前往下载") forState:UIControlStateNormal];
                    
                    // 设置按钮样式 - 支持iOS14.0
                    if (@available(iOS 13.0, *)) {
                        downloadButton.backgroundColor = [UIColor systemBlueColor];
                    } else {
                        downloadButton.backgroundColor = [UIColor colorWithRed:0/255.0 green:122/255.0 blue:255/255.0 alpha:1.0];
                    }
                    
                    [downloadButton setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
                    downloadButton.titleLabel.font = [UIFont systemFontOfSize:14 weight:UIFontWeightSemibold];
                    downloadButton.layer.cornerRadius = 8;
                    downloadButton.translatesAutoresizingMaskIntoConstraints = NO;
                    
                    // 添加按钮阴影
                    downloadButton.layer.shadowColor = [UIColor blackColor].CGColor;
                    downloadButton.layer.shadowOffset = CGSizeMake(0, 2);
                    downloadButton.layer.shadowRadius = 4;
                    downloadButton.layer.shadowOpacity = 0.2;
                    
                    // 添加按钮点击效果
                    downloadButton.layer.masksToBounds = NO;
                    
                    // 添加下载图标
                    if (@available(iOS 13.0, *)) {
                        UIImage *downloadImage = [UIImage systemImageNamed:@"arrow.down.circle.fill"];
                        [downloadButton setImage:downloadImage forState:UIControlStateNormal];
                        downloadButton.imageEdgeInsets = UIEdgeInsetsMake(0, -8, 0, 0);
                        downloadButton.titleEdgeInsets = UIEdgeInsetsMake(0, 8, 0, 0);
                        downloadButton.tintColor = [UIColor whiteColor];
                    }
                    
                    [downloadButton addTarget:self action:@selector(downloadLatestVersion:) forControlEvents:UIControlEventTouchUpInside];
                    
                    [announcementContainer addSubview:downloadButton];
                    
                    // 设置下载按钮约束
                    [NSLayoutConstraint activateConstraints:@[
                        [downloadButton.topAnchor constraintEqualToAnchor:announcementLabel.bottomAnchor constant:8],
                        [downloadButton.centerXAnchor constraintEqualToAnchor:announcementContainer.centerXAnchor],
                        [downloadButton.widthAnchor constraintEqualToConstant:100],
                        [downloadButton.heightAnchor constraintEqualToConstant:30],
                        [downloadButton.bottomAnchor constraintEqualToAnchor:announcementContainer.bottomAnchor constant:-10]
                    ]];
                    
                    // 调整容器高度以适应按钮
                    [self adjustAnnouncementContainerHeight:announcementContainer forLabel:announcementLabel withButton:downloadButton];
                } else {
                    // 当前版本大于或等于最新版本
                    announcementLabel.text = localize(@"announcement.latest_version", @"欢迎使用Amethyst iOS Remastered！当前已是最新正式版。");
                    [self adjustAnnouncementContainerHeight:announcementContainer forLabel:announcementLabel];
                }
            });
        }];
        
        [task resume];
    }
    
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

- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    
    // 确保表格视图的contentInset正确设置
    // 这个方法的调用时机在视图布局完成后，可以安全地获取视图的实际尺寸
    if (self.tableView.contentInset.top < 60) {
        // 如果contentInset未正确设置，重新设置默认值
        self.tableView.contentInset = UIEdgeInsetsMake(76, 0, 0, 0);
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

// 调整公告栏容器高度（仅标签）
- (void)adjustAnnouncementContainerHeight:(UIView *)container forLabel:(UILabel *)label {
    // 计算标签所需高度 - 使用视图的实际宽度
    CGFloat maxWidth = self.view.frame.size.width - 64; // 视图宽度 - 左边距(16+20+12) - 右边距(16)
    CGSize labelSize = [label sizeThatFits:CGSizeMake(maxWidth, CGFLOAT_MAX)];
    CGFloat labelHeight = labelSize.height;
    
    // 计算容器高度：标签高度 + 上下边距(各12)
    CGFloat containerHeight = MAX(60, labelHeight + 24);
    
    // 更新容器高度约束
    if (self.announcementContainerHeightConstraint) {
        self.announcementContainerHeightConstraint.constant = containerHeight;
    }
    
    // 更新表格视图的contentInset
    CGFloat topInset = containerHeight + 24; // 容器高度 + 上边距(8) + 下间距(8+8)
    self.tableView.contentInset = UIEdgeInsetsMake(topInset, 0, 0, 0);
    
    // 强制布局更新
    [UIView animateWithDuration:0.3 animations:^{
        [container.superview layoutIfNeeded];
    }];
}

// 调整公告栏容器高度（带按钮）
- (void)adjustAnnouncementContainerHeight:(UIView *)container forLabel:(UILabel *)label withButton:(UIButton *)button {
    // 计算标签所需高度 - 使用视图的实际宽度
    CGFloat maxWidth = self.view.frame.size.width - 64; // 视图宽度 - 左边距(16+20+12) - 右边距(16)
    CGSize labelSize = [label sizeThatFits:CGSizeMake(maxWidth, CGFLOAT_MAX)];
    CGFloat labelHeight = labelSize.height;
    
    // 计算容器高度：标签高度 + 标签上边距(12) + 标签按钮间距(8) + 按钮高度(30) + 按钮下边距(12)
    CGFloat containerHeight = MAX(80, labelHeight + 12 + 8 + 30 + 12);
    
    // 更新容器高度约束
    if (self.announcementContainerHeightConstraint) {
        self.announcementContainerHeightConstraint.constant = containerHeight;
    }
    
    // 更新表格视图的contentInset
    CGFloat topInset = containerHeight + 24; // 容器高度 + 上边距(8) + 下间距(8+8)
    self.tableView.contentInset = UIEdgeInsetsMake(topInset, 0, 0, 0);
    
    // 强制布局更新
    [UIView animateWithDuration:0.3 animations:^{
        [container.superview layoutIfNeeded];
    }];
}

@end
