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
#import "AccountListViewController.h"

// 布局常量（iPad 基准值；iPhone 上通过 LauncherRootLayoutWidth 适配后会变窄）
static const CGFloat kSidebarWidthPad = 70.0;      // iPad 左侧边栏宽度
static const CGFloat kSidebarWidthPhone = 56.0;    // iPhone 左侧边栏宽度（仅图标）
static const CGFloat kRightPanelWidthPad = 220.0;  // iPad 右侧面板宽度
static const CGFloat kRightPanelWidthPhone = 168.0; // iPhone 右侧面板宽度（保证按钮文字可读）

/// 根据当前 traitCollection 决定侧栏宽度（与 LauncherCardLayoutViewController 保持一致）
static CGFloat LauncherRootLayoutSidebarWidth(UITraitCollection *trait) {
    if (!trait) return kSidebarWidthPad;
    if (trait.userInterfaceIdiom == UIUserInterfaceIdiomPhone) return kSidebarWidthPhone;
    return kSidebarWidthPad;
}

/// 根据当前 traitCollection 决定右侧面板宽度
static CGFloat LauncherRootLayoutRightPanelWidth(UITraitCollection *trait) {
    if (!trait) return kRightPanelWidthPad;
    if (trait.userInterfaceIdiom == UIUserInterfaceIdiomPhone) return kRightPanelWidthPhone;
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

@property(nonatomic, assign) BOOL isShowingProfileEditor;
@property(nonatomic, strong) ProfileSettingsViewController *profileEditorVC;

@end

@implementation LauncherRootViewController

#pragma mark - Lifecycle

- (void)viewDidLoad {
    [super viewDidLoad];

    self.view.backgroundColor = [UIColor clearColor];

    // 初始化版本列表（必须在其他视图控制器之前）
    [self initializeVersionLists];

    // 创建三个容器视图
    [self setupContainers];

    // 添加子视图控制器
    [self setupChildViewControllers];

    // 应用背景
    [[BackgroundManager sharedManager] applyBackgroundToView:self.view];

    // 监听外观变更（字体颜色 / 卡片颜色），与 Card 布局保持一致
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
    // iPhone 与 iPad 切换、或分屏调整大小时，更新侧栏与右侧面板宽度
    CGFloat sidebarWidth = LauncherRootLayoutSidebarWidth(self.traitCollection);
    CGFloat rightPanelWidth = LauncherRootLayoutRightPanelWidth(self.traitCollection);
    if (self.sidebarWidthConstraint.constant != sidebarWidth) {
        self.sidebarWidthConstraint.constant = sidebarWidth;
    }
    if (self.rightPanelWidthConstraint.constant != rightPanelWidth) {
        self.rightPanelWidthConstraint.constant = rightPanelWidth;
    }
    // 通知子 VC 重新布局
    for (UIViewController *child in self.childViewControllers) {
        [child.view setNeedsLayout];
    }
}

- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    // 消除内容区子 VC 的顶部 safeArea 留白（"大白条"）。
    // 内容 VC 内部用 safeAreaLayoutGuide.topAnchor 布局，顶部会留出状态栏高度的空间，
    // 该空间透出 window 的 systemBackgroundColor（浅色模式=白），形成刺眼的"大白条"。
    // 通过 additionalSafeAreaInsets 负值抵消顶部 safeArea，让子 VC 内容延伸到顶部。
    CGFloat topInset = self.contentContainer.safeAreaInsets.top;
    UIEdgeInsets target = (topInset > 0) ? UIEdgeInsetsMake(-topInset, 0, 0, 0) : UIEdgeInsetsZero;
    UIViewController *contentVC = _contentViewController;
    if (!contentVC) return;
    if ([contentVC isKindOfClass:[UINavigationController class]]) {
        UINavigationController *nav = (UINavigationController *)contentVC;
        for (UIViewController *vc in nav.viewControllers) {
            if (!UIEdgeInsetsEqualToEdgeInsets(vc.additionalSafeAreaInsets, target)) {
                vc.additionalSafeAreaInsets = target;
            }
        }
    } else {
        if (!UIEdgeInsetsEqualToEdgeInsets(contentVC.additionalSafeAreaInsets, target)) {
            contentVC.additionalSafeAreaInsets = target;
        }
    }
}

#pragma mark - Setup

- (void)setupContainers {
    // 左侧边栏容器 - 半透明（圆角，与 Card 布局保持一致）
    self.sidebarContainer = [[UIView alloc] init];
    self.sidebarContainer.translatesAutoresizingMaskIntoConstraints = NO;
    self.sidebarContainer.layer.cornerRadius = 16;
    self.sidebarContainer.layer.masksToBounds = YES;
    [[BackgroundManager sharedManager] applyEffectToView:self.sidebarContainer];
    [self.view addSubview:self.sidebarContainer];

    // 中间内容容器 - 完全透明（防御性补 16pt 圆角，保持与左右容器一致）
    self.contentContainer = [[UIView alloc] init];
    self.contentContainer.translatesAutoresizingMaskIntoConstraints = NO;
    self.contentContainer.backgroundColor = [UIColor clearColor];
    self.contentContainer.layer.cornerRadius = 16;
    self.contentContainer.layer.masksToBounds = YES;
    [self.view addSubview:self.contentContainer];

    // 右侧面板容器 - 半透明（圆角，与 Card 布局保持一致）
    self.rightPanelContainer = [[UIView alloc] init];
    self.rightPanelContainer.translatesAutoresizingMaskIntoConstraints = NO;
    self.rightPanelContainer.layer.cornerRadius = 16;
    self.rightPanelContainer.layer.masksToBounds = YES;
    [[BackgroundManager sharedManager] applyEffectToView:self.rightPanelContainer];
    [self.view addSubview:self.rightPanelContainer];
    
    // 设置约束
    // 使用可变宽度约束，便于 traitCollection 变化时更新（iPhone/iPad 适配）
    self.sidebarWidthConstraint = [self.sidebarContainer.widthAnchor constraintEqualToConstant:LauncherRootLayoutSidebarWidth(self.traitCollection)];
    self.rightPanelWidthConstraint = [self.rightPanelContainer.widthAnchor constraintEqualToConstant:LauncherRootLayoutRightPanelWidth(self.traitCollection)];

    [NSLayoutConstraint activateConstraints:@[
        // 左侧边栏
        [self.sidebarContainer.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [self.sidebarContainer.topAnchor constraintEqualToAnchor:self.view.topAnchor],
        [self.sidebarContainer.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor],
        self.sidebarWidthConstraint,

        // 右侧面板
        [self.rightPanelContainer.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [self.rightPanelContainer.topAnchor constraintEqualToAnchor:self.view.topAnchor],
        [self.rightPanelContainer.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor],
        self.rightPanelWidthConstraint,

        // 中间内容区——填满侧栏与右面板之间的空间
        [self.contentContainer.leadingAnchor constraintEqualToAnchor:self.sidebarContainer.trailingAnchor],
        [self.contentContainer.trailingAnchor constraintEqualToAnchor:self.rightPanelContainer.leadingAnchor],
        [self.contentContainer.topAnchor constraintEqualToAnchor:self.view.topAnchor],
        [self.contentContainer.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor]
    ]];
}

- (void)setupChildViewControllers {
    // 左侧边栏 - 功能菜单
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
    
    // 中间内容 - 默认显示新闻页
    LauncherNewsViewController *newsVC = [[LauncherNewsViewController alloc] init];
    [self setContentViewController:newsVC animated:NO];
    
    // 右侧面板 - 账户和启动
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
    // FCL 风格：账户管理在中间内容区显示（不再 FormSheet 弹窗）
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

/// FCL 风格：账户管理在中间内容区显示（不再 FormSheet 弹窗）
- (void)showAccountManager {
    AccountListViewController *vc = [[AccountListViewController alloc] init];
    // 账户选择后通知右侧面板刷新（使用已有的 UpdateAccountInfo 通知）
    vc.whenItemSelected = ^void() {
        [[NSNotificationCenter defaultCenter] postNotificationName:@"UpdateAccountInfo" object:nil];
    };
    // 账户删除后也通知右侧面板刷新
    vc.whenDelete = ^void(NSString *name) {
        [[NSNotificationCenter defaultCenter] postNotificationName:@"UpdateAccountInfo" object:nil];
    };
    UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:vc];
    nav.navigationBar.prefersLargeTitles = NO;
    [self setContentViewController:nav animated:YES];
}

- (void)backgroundChanged {
    // 重新应用背景
    [[BackgroundManager sharedManager] applyBackgroundToView:self.view];
}

- (void)uiEffectChanged:(NSNotification *)notification {
    // 重新应用毛玻璃/半透明效果到容器视图
    [[BackgroundManager sharedManager] applyEffectToView:self.sidebarContainer];
    [[BackgroundManager sharedManager] applyEffectToView:self.rightPanelContainer];
}

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

#pragma mark - Custom Appearance（字体颜色 / 卡片颜色，与 Card 布局一致）

- (void)applyCustomAppearance {
    // 应用自定义卡片颜色（半透明覆盖 BackgroundManager 的毛玻璃，而非完全替换）
    NSString *cardColor = getPrefObject(@"general.card_color");
    if (cardColor.length > 0) {
        UIColor *color = [self colorFromHexString:cardColor];
        if (color) {
            // 使用半透明颜色覆盖毛玻璃，alpha 提升到 0.85 增强可见度。
            // 之前 0.7 太淡，浅色背景几乎看不出效果。
            // 保留毛玻璃（backgroundColor 叠加在 UIVisualEffectView 之上），
            // 既显示卡片色调又透出背景图。
            CGFloat r, g, b, a;
            if ([color getRed:&r green:&g blue:&b alpha:&a]) {
                UIColor *semiColor = [UIColor colorWithRed:r green:g blue:b alpha:MIN(a, 0.85)];
                [self applySemiTransparentColor:semiColor toContainer:self.sidebarContainer];
                [self applySemiTransparentColor:semiColor toContainer:self.rightPanelContainer];
            }
        }
    } else {
        // 未设置自定义颜色时，恢复毛玻璃效果
        [self restoreEffectToContainer:self.sidebarContainer];
        [self restoreEffectToContainer:self.rightPanelContainer];
    }
    // 通知右侧面板、菜单等子 VC 同步刷新外观（text_color / card_color 联动）
    [[NSNotificationCenter defaultCenter] postNotificationName:@"LauncherAppearanceApplied" object:nil];
}

- (void)applySemiTransparentColor:(UIColor *)color toContainer:(UIView *)container {
    // 保留 BackgroundManager 的毛玻璃 UIVisualEffectView，在其上叠加半透明纯色
    // 这样既显示用户自定义的卡片颜色，又能透出背景图
    container.backgroundColor = color;
}

- (void)restoreEffectToContainer:(UIView *)container {
    container.backgroundColor = [UIColor clearColor];
    // 检查是否已有毛玻璃，没有则重新应用
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
            [UIView transitionWithView:self.contentContainer
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

    // FCL 风格：对 UINavigationController 应用 nav bar 毛玻璃效果，并对内容 VC 透明化处理，
    // 避免顶部出现默认白色 nav bar 形成"大白条"，同时与两侧深色毛玻璃面板视觉一致。
    if ([viewController isKindOfClass:[UINavigationController class]]) {
        UINavigationController *nav = (UINavigationController *)viewController;
        [[BackgroundManager sharedManager] applyEffectToNavigationBar:nav.navigationBar];
        // 透明化 topViewController，让背景透出 nav bar 毛玻璃
        [[BackgroundManager sharedManager] makeViewControllerTransparent:nav.topViewController];
    } else {
        // 非导航控制器包装的 VC 也透明化，确保与背景融合
        [[BackgroundManager sharedManager] makeViewControllerTransparent:viewController];
    }

    if (animated && oldVC) {
        [UIView transitionWithView:self.contentContainer
                          duration:0.25
                           options:UIViewAnimationOptionTransitionCrossDissolve
                        animations:^{
                            [self.contentContainer addSubview:viewController.view];
                            [NSLayoutConstraint activateConstraints:@[
                                [viewController.view.leadingAnchor constraintEqualToAnchor:self.contentContainer.leadingAnchor],
                                [viewController.view.trailingAnchor constraintEqualToAnchor:self.contentContainer.trailingAnchor],
                                [viewController.view.topAnchor constraintEqualToAnchor:self.contentContainer.topAnchor],
                                [viewController.view.bottomAnchor constraintEqualToAnchor:self.contentContainer.bottomAnchor]
                            ]];
                        } completion:^(BOOL finished) {
                            [viewController didMoveToParentViewController:self];
                        }];
    } else {
        [self.contentContainer addSubview:viewController.view];
        [NSLayoutConstraint activateConstraints:@[
            [viewController.view.leadingAnchor constraintEqualToAnchor:self.contentContainer.leadingAnchor],
            [viewController.view.trailingAnchor constraintEqualToAnchor:self.contentContainer.trailingAnchor],
            [viewController.view.topAnchor constraintEqualToAnchor:self.contentContainer.topAnchor],
            [viewController.view.bottomAnchor constraintEqualToAnchor:self.contentContainer.bottomAnchor]
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
