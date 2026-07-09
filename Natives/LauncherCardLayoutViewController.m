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
#import "AccountListViewController.h"

// 布局常量（iPad/宽屏基准值；iPhone 上通过 traitCollection 适配后会变窄）
static const CGFloat kSidebarWidthPad = 70.0;      // iPad 左侧边栏卡片宽度
static const CGFloat kSidebarWidthPhone = 56.0;    // iPhone 左侧边栏卡片宽度（仅图标）
static const CGFloat kRightPanelWidthPad = 220.0;  // iPad 右侧面板卡片宽度
static const CGFloat kRightPanelWidthPhone = 168.0; // iPhone 右侧面板卡片宽度（保证启动/JAR 按钮可读）
static const CGFloat kCardSpacing = 12.0;          // 卡片间距
static const CGFloat kCardOuterMargin = 12.0;      // 卡片到外边缘的间距
static const CGFloat kCardCornerRadius = 16.0;     // 卡片圆角

/// 根据当前 traitCollection 与屏幕宽度决定侧栏宽度
/// - iPhone 横屏（含 SE/8/Plus/X/Pro Max）：56pt（菜单只有图标，56pt 足够）
/// - iPad：70pt
static CGFloat LauncherCardLayoutSidebarWidth(UITraitCollection *trait) {
    if (!trait) return kSidebarWidthPad;
    if (trait.userInterfaceIdiom == UIUserInterfaceIdiomPhone) return kSidebarWidthPhone;
    return kSidebarWidthPad;
}

/// 根据当前 traitCollection 与屏幕宽度决定右侧面板宽度
/// - iPhone 横屏：168pt（保证启动/编辑控件/执行 Jar 按钮文字不截断）
/// - iPad：220pt
static CGFloat LauncherCardLayoutRightPanelWidth(UITraitCollection *trait) {
    if (!trait) return kRightPanelWidthPad;
    if (trait.userInterfaceIdiom == UIUserInterfaceIdiomPhone) return kRightPanelWidthPhone;
    return kRightPanelWidthPad;
}

@interface LauncherCardLayoutViewController ()

@property(nonatomic, strong) UIView *sidebarCard;
@property(nonatomic, strong) UIView *contentCard;
@property(nonatomic, strong) UIView *rightPanelCard;

@property(nonatomic, strong) NSLayoutConstraint *sidebarWidthConstraint;
@property(nonatomic, strong) NSLayoutConstraint *rightPanelWidthConstraint;

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
    
    // 初始化版本列表（必须在其他视图控制器之前）
    [self initializeVersionLists];
    
    // 创建三个卡片容器视图
    [self setupCardContainers];
    
    // 添加子视图控制器
    [self setupChildViewControllers];
    
    // 应用背景
    [[BackgroundManager sharedManager] applyBackgroundToView:self.view];

    // 监听启动器外观变化（自定义字体/卡片颜色），刷新卡片背景
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(applyCustomAppearance)
                                                 name:@"LauncherAppearanceChanged"
                                               object:nil];
}

- (void)initializeVersionLists {
    // 初始化本地版本列表
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
    
    // 初始化远程版本列表
    if (!remoteVersionList) {
        remoteVersionList = [NSMutableArray new];
    }
    [remoteVersionList removeAllObjects];
    [remoteVersionList addObjectsFromArray:@[
        @{@"id": @"latest-release", @"type": @"release"},
        @{@"id": @"latest-snapshot", @"type": @"snapshot"}
    ]];
    
    // 异步获取远程版本列表
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

- (void)traitCollectionDidChange:(UITraitCollection *)previousTraitCollection {
    [super traitCollectionDidChange:previousTraitCollection];
    // iPhone 与 iPad 切换、或分屏调整大小时，更新侧栏与右侧面板宽度
    CGFloat sidebarWidth = LauncherCardLayoutSidebarWidth(self.traitCollection);
    CGFloat rightPanelWidth = LauncherCardLayoutRightPanelWidth(self.traitCollection);
    if (self.sidebarWidthConstraint.constant != sidebarWidth) {
        self.sidebarWidthConstraint.constant = sidebarWidth;
    }
    if (self.rightPanelWidthConstraint.constant != rightPanelWidth) {
        self.rightPanelWidthConstraint.constant = rightPanelWidth;
    }
    // 同时通知子视图控制器（右侧面板内的按钮文字大小可能需要适配）
    [self.childViewControllers enumerateObjectsUsingBlock:^(UIViewController *child, NSUInteger idx, BOOL *stop) {
        [self adjustChildLayoutForTraitCollection:child];
    }];
}

/// 递归调整子视图控制器（主要针对右侧面板的按钮字体/边距）
- (void)adjustChildLayoutForTraitCollection:(UIViewController *)vc {
    if (!vc) return;
    if ([vc respondsToSelector:@selector(viewWillAppear:)]) {
        // 通知子 VC 重新布局：通过 setNeedsLayout 触发布局更新
        [vc.view setNeedsLayout];
    }
    for (UIViewController *child in vc.childViewControllers) {
        [self adjustChildLayoutForTraitCollection:child];
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

/// 读取 general.card_color 偏好，若已设置则用纯色覆盖毛玻璃背景。
/// 用户设置浅色卡片时需同时在设置里设置深色字体颜色，否则白色文字不可见。
- (void)applyCustomCardColorToCard:(UIView *)card {
    NSString *hex = getPrefObject(@"general.card_color");
    UIColor *color = [self colorFromHexString:hex];
    if (!color) return;
    // 移除 BackgroundManager 插入的毛玻璃子视图，用纯色覆盖
    for (UIView *sub in [card.subviews copy]) {
        if ([sub isKindOfClass:[UIVisualEffectView class]]) {
            [sub removeFromSuperview];
        }
    }
    card.backgroundColor = color;
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

/// 外观变化时重新应用卡片颜色（保留圆角，重建背景）
- (void)applyCustomAppearance {
    [self applyCustomCardColorToCard:self.sidebarCard];
    [self applyCustomCardColorToCard:self.contentCard];
    [self applyCustomCardColorToCard:self.rightPanelCard];
}

- (void)setupCardContainers {
    // 左侧菜单卡片
    self.sidebarCard = [self createCardContainer];
    [self.view addSubview:self.sidebarCard];

    // 中间内容卡片
    self.contentCard = [self createCardContainer];
    [self.view addSubview:self.contentCard];

    // 右侧信息/启动卡片
    self.rightPanelCard = [self createCardContainer];
    [self.view addSubview:self.rightPanelCard];

    // 用自适应宽度创建可变宽度约束，便于 traitCollection 变化时更新
    self.sidebarWidthConstraint = [self.sidebarCard.widthAnchor constraintEqualToConstant:LauncherCardLayoutSidebarWidth(self.traitCollection)];
    self.rightPanelWidthConstraint = [self.rightPanelCard.widthAnchor constraintEqualToConstant:LauncherCardLayoutRightPanelWidth(self.traitCollection)];

    // 设置约束
    // FCL 风格：中间内容卡片水平居中于屏幕，侧栏贴左、右面板贴右，
    // 两侧间距均等（kCardSpacing），内容卡片填满侧栏与右面板之间的空间。
    [NSLayoutConstraint activateConstraints:@[
        // 左侧菜单卡片
        [self.sidebarCard.leadingAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.leadingAnchor constant:kCardOuterMargin],
        [self.sidebarCard.topAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.topAnchor constant:kCardOuterMargin],
        [self.sidebarCard.bottomAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.bottomAnchor constant:-kCardOuterMargin],
        self.sidebarWidthConstraint,

        // 右侧面板卡片
        [self.rightPanelCard.trailingAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.trailingAnchor constant:-kCardOuterMargin],
        [self.rightPanelCard.topAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.topAnchor constant:kCardOuterMargin],
        [self.rightPanelCard.bottomAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.bottomAnchor constant:-kCardOuterMargin],
        self.rightPanelWidthConstraint,

        // 中间内容卡片——填满侧栏与右面板之间的空间，两侧间距均等为 kCardSpacing
        [self.contentCard.leadingAnchor constraintEqualToAnchor:self.sidebarCard.trailingAnchor constant:kCardSpacing],
        [self.contentCard.trailingAnchor constraintEqualToAnchor:self.rightPanelCard.leadingAnchor constant:-kCardSpacing],
        [self.contentCard.topAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.topAnchor constant:kCardOuterMargin],
        [self.contentCard.bottomAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.bottomAnchor constant:-kCardOuterMargin]
    ]];
}

- (void)setupChildViewControllers {
    // 左侧边栏 - 功能菜单
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
    
    // 中间内容 - 默认显示新闻页
    LauncherNewsViewController *newsVC = [[LauncherNewsViewController alloc] init];
    [self setContentViewController:newsVC animated:NO];
    
    // 右侧面板 - 账户和启动
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
    
    // 注册通知监听
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
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(showControlSettings)
                                                 name:@"ShowControlSettings"
                                               object:nil];
    // 账户管理：右侧面板点击头像会发 ShowAccountManager 通知。
    // 原实现遗漏此监听，导致卡片布局下点头像无反应、无法登录账号。
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(showAccountManager)
                                                 name:@"ShowAccountManager"
                                               object:nil];
    // 首页快捷瓷砖触发：切到对应内容区子页面（不再 FormSheet 弹窗）
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
    // 监听版本切换，重新加载编辑器
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(reloadProfileEditorIfNeeded)
                                                 name:@"SelectedProfileChanged"
                                               object:nil];
    // 监听游戏目录切换，重新加载版本列表
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(reloadVersionLists)
                                                 name:@"ReloadProfileList"
                                               object:nil];
    // 监听查找版本请求
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
    
    // 在远程版本列表中查找
    NSDictionary *versionObject = nil;
    for (NSDictionary *version in remoteVersionList) {
        if ([version[@"id"] isEqualToString:versionId]) {
            versionObject = version;
            break;
        }
    }
    
    // 如果在远程列表中找不到，检查是否是本地版本
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
    // 重新加载版本列表
    [self initializeVersionLists];
    // 通知右侧面板刷新版本显示
    [[NSNotificationCenter defaultCenter] postNotificationName:@"SelectedProfileChanged" object:nil];
}

- (void)showHomePage {
    LauncherNewsViewController *newsVC = [[LauncherNewsViewController alloc] init];
    [self setContentViewController:newsVC animated:YES];
}

- (void)showDownloadPage {
    // 在中间内容区显示下载页面，包在 NavigationController 中以便子流程（版本选择/安装器）push 显示
    DownloadViewController *downloadVC = [[DownloadViewController alloc] init];
    UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:downloadVC];
    nav.navigationBar.prefersLargeTitles = NO;
    [self setContentViewController:nav animated:YES];
}

- (void)showVersionManager {
    // 在中间内容区显示版本管理页面，包在 NavigationController 中以便子流程（模组/光影/游戏目录管理）push
    VersionManagerViewController *vc = [[VersionManagerViewController alloc] init];
    UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:vc];
    nav.navigationBar.prefersLargeTitles = NO;
    [self setContentViewController:nav animated:YES];
}

- (void)showProfileEditor:(NSNotification *)notification {
    // 在中间内容区显示版本编辑器页面（使用 ProfileSettingsViewController）
    NSString *profileName = notification.object;

    ProfileSettingsViewController *vc = [[ProfileSettingsViewController alloc] init];
    vc.profileName = profileName;

    // 包装在导航控制器中
    UINavigationController *navVC = [[UINavigationController alloc] initWithRootViewController:vc];
    navVC.navigationBar.prefersLargeTitles = NO;

    self.profileEditorVC = vc;
    self.isShowingProfileEditor = YES;
    [self setContentViewController:navVC animated:YES];
}

- (void)reloadProfileEditorIfNeeded {
    // 如果当前正在显示编辑器页面，重新加载
    if (self.isShowingProfileEditor) {
        NSString *currentProfile = PLProfiles.current.selectedProfileName;
        if (currentProfile) {
            [[NSNotificationCenter defaultCenter] postNotificationName:@"ShowProfileEditor" object:currentProfile];
        }
    }
}

- (void)showSettings {
    // 在中间内容区显示设置页面
    LauncherPreferencesViewController *vc = [[LauncherPreferencesViewController alloc] init];
    // 包装在导航控制器中，使其子页面能够正常导航
    UINavigationController *navVC = [[UINavigationController alloc] initWithRootViewController:vc];
    navVC.navigationBar.prefersLargeTitles = YES;
    [self setContentViewController:navVC animated:YES];
}

- (void)showControlSettings {
    // 在中间内容区显示自定义控制布局编辑器（原右侧面板"编辑控件"挪到这里）
    CustomControlsViewController *vc = [[CustomControlsViewController alloc] init];
    vc.modalPresentationStyle = UIModalPresentationOverFullScreen;
    vc.setDefaultCtrl = ^(NSString *name){
        setPrefObject(@"control.default_ctrl", name);
    };
    vc.getDefaultCtrl = ^{
        return getPrefObject(@"control.default_ctrl");
    };
    UINavigationController *navVC = [[UINavigationController alloc] initWithRootViewController:vc];
    navVC.navigationBar.prefersLargeTitles = NO;
    [self setContentViewController:navVC animated:YES];
}

- (void)showAccountManager {
    // 卡片布局下账户管理在中间内容区显示（与 VS 布局 LauncherRootViewController 行为一致）。
    // 右侧面板点击头像发 ShowAccountManager 通知触发此方法。
    // 使用 insetGrouped 样式让账户列表呈现圆角分组卡片（原默认 plain 为直角行）。
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
    // 切到版本管理页并直接 push 模组管理
    VersionManagerViewController *vm = [[VersionManagerViewController alloc] init];
    UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:vm];
    nav.navigationBar.prefersLargeTitles = NO;
    [self setContentViewController:nav animated:YES];
    ModsManagerViewController *m = [[ModsManagerViewController alloc] init];
    m.initialMode = ModsManagerModeLocal;
    [nav pushViewController:m animated:NO];
}

- (void)showShadersManager {
    VersionManagerViewController *vm = [[VersionManagerViewController alloc] init];
    UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:vm];
    nav.navigationBar.prefersLargeTitles = NO;
    [self setContentViewController:nav animated:YES];
    ShadersManagerViewController *s = [[ShadersManagerViewController alloc] init];
    s.initialMode = ShadersManagerModeLocal;
    [nav pushViewController:s animated:NO];
}

- (void)showGameDirectory {
    VersionManagerViewController *vm = [[VersionManagerViewController alloc] init];
    UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:vm];
    nav.navigationBar.prefersLargeTitles = NO;
    [self setContentViewController:nav animated:YES];
    LauncherPrefGameDirViewController *g = [[LauncherPrefGameDirViewController alloc] init];
    [nav pushViewController:g animated:NO];
}

- (void)showModpackImport {
    // 切到下载页并直接 push 整合包导入界面
    DownloadViewController *d = [[DownloadViewController alloc] init];
    UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:d];
    nav.navigationBar.prefersLargeTitles = NO;
    [self setContentViewController:nav animated:YES];
    ModpackImportViewController *m = [[ModpackImportViewController alloc] init];
    [nav pushViewController:m animated:NO];
}

- (void)backgroundChanged {
    // 重新应用背景
    [[BackgroundManager sharedManager] applyBackgroundToView:self.view];
}

- (void)uiEffectChanged:(NSNotification *)notification {
    // 重新应用毛玻璃/半透明效果到卡片容器视图
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
    
    // 检查是否切换到非编辑器页面
    if (![viewController isKindOfClass:[UINavigationController class]] ||
        ![((UINavigationController *)viewController).topViewController isKindOfClass:[ProfileSettingsViewController class]]) {
        self.isShowingProfileEditor = NO;
        self.profileEditorVC = nil;
    }
    
    UIViewController *oldVC = _contentViewController;
    
    // 移除旧的
    if (oldVC) {
        if (animated) {
            [UIView transitionWithView:self.contentCard
                              duration:0.25
                               options:UIViewAnimationOptionTransitionCrossDissolve
                            animations:^{
                                [oldVC willMoveToParentViewController:nil];
                                [oldVC.view removeFromSuperview];
                                [oldVC removeFromParentViewController];
                            } completion:nil];
        } else {
            [oldVC willMoveToParentViewController:nil];
            [oldVC.view removeFromSuperview];
            [oldVC removeFromParentViewController];
        }
    }
    
    // 添加新的
    _contentViewController = viewController;
    [self addChildViewController:viewController];
    viewController.view.translatesAutoresizingMaskIntoConstraints = NO;

    // 修复：对齐 LauncherRootViewController 的 nav bar 透明化处理。
    // 原卡片布局缺失此逻辑，导致 VersionManagerViewController 等被 UINavigationController
    // 包裹的子页面顶部出现默认不透明 nav bar（白条），与卡片背景不融合。
    if ([viewController isKindOfClass:[UINavigationController class]]) {
        UINavigationController *nav = (UINavigationController *)viewController;
        [[BackgroundManager sharedManager] applyEffectToNavigationBar:nav.navigationBar];
        [[BackgroundManager sharedManager] makeViewControllerTransparent:nav.topViewController];
    } else {
        [[BackgroundManager sharedManager] makeViewControllerTransparent:viewController];
    }

    if (animated && oldVC) {
        [UIView transitionWithView:self.contentCard
                          duration:0.25
                           options:UIViewAnimationOptionTransitionCrossDissolve
                        animations:^{
                            [self.contentCard addSubview:viewController.view];
                            [NSLayoutConstraint activateConstraints:@[
                                [viewController.view.leadingAnchor constraintEqualToAnchor:self.contentCard.leadingAnchor],
                                [viewController.view.trailingAnchor constraintEqualToAnchor:self.contentCard.trailingAnchor],
                                [viewController.view.topAnchor constraintEqualToAnchor:self.contentCard.topAnchor],
                                [viewController.view.bottomAnchor constraintEqualToAnchor:self.contentCard.bottomAnchor]
                            ]];
                        } completion:^(BOOL finished) {
                            [viewController didMoveToParentViewController:self];
                        }];
    } else {
        [self.contentCard addSubview:viewController.view];
        [NSLayoutConstraint activateConstraints:@[
            [viewController.view.leadingAnchor constraintEqualToAnchor:self.contentCard.leadingAnchor],
            [viewController.view.trailingAnchor constraintEqualToAnchor:self.contentCard.trailingAnchor],
            [viewController.view.topAnchor constraintEqualToAnchor:self.contentCard.topAnchor],
            [viewController.view.bottomAnchor constraintEqualToAnchor:self.contentCard.bottomAnchor]
        ]];
        [viewController didMoveToParentViewController:self];
    }
}

#pragma mark - Orientation

- (BOOL)shouldAutorotate {
    return YES;
}

- (UIInterfaceOrientationMask)supportedInterfaceOrientations {
    return UIInterfaceOrientationMaskLandscape;
}

@end
