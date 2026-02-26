#import "LauncherRootViewController.h"
#import "LauncherMenuViewController.h"
#import "LauncherNewsViewController.h"
#import "LauncherRightPanelViewController.h"
#import "DownloadViewController.h"
#import "VersionManagerViewController.h"
#import "LauncherProfileEditorViewController.h"
#import "LauncherPreferencesViewController.h"
#import "LauncherNavigationController.h"
#import "LauncherPreferences.h"
#import "BackgroundManager.h"
#import "PLProfiles.h"
#import "utils.h"

// 布局常量
static const CGFloat kSidebarWidth = 70.0;      // 左侧边栏宽度
static const CGFloat kRightPanelWidth = 220.0;  // 右侧面板宽度

@interface LauncherRootViewController ()

@property(nonatomic, strong) UIView *sidebarContainer;
@property(nonatomic, strong) UIView *contentContainer;
@property(nonatomic, strong) UIView *rightPanelContainer;

@property(nonatomic, strong) NSLayoutConstraint *contentLeadingConstraint;
@property(nonatomic, strong) NSLayoutConstraint *contentTrailingConstraint;

@property(nonatomic, assign) BOOL isShowingProfileEditor;
@property(nonatomic, strong) LauncherProfileEditorViewController *profileEditorVC;

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

#pragma mark - Setup

- (void)setupContainers {
    // 左侧边栏容器 - 半透明
    self.sidebarContainer = [[UIView alloc] init];
    self.sidebarContainer.translatesAutoresizingMaskIntoConstraints = NO;
    self.sidebarContainer.backgroundColor = [UIColor colorWithWhite:0.08 alpha:0.7];
    [self.view addSubview:self.sidebarContainer];
    
    // 中间内容容器 - 完全透明
    self.contentContainer = [[UIView alloc] init];
    self.contentContainer.translatesAutoresizingMaskIntoConstraints = NO;
    self.contentContainer.backgroundColor = [UIColor clearColor];
    [self.view addSubview:self.contentContainer];
    
    // 右侧面板容器 - 半透明
    self.rightPanelContainer = [[UIView alloc] init];
    self.rightPanelContainer.translatesAutoresizingMaskIntoConstraints = NO;
    self.rightPanelContainer.backgroundColor = [UIColor colorWithWhite:0.08 alpha:0.7];
    [self.view addSubview:self.rightPanelContainer];
    
    // 设置约束
    [NSLayoutConstraint activateConstraints:@[
        // 左侧边栏
        [self.sidebarContainer.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [self.sidebarContainer.topAnchor constraintEqualToAnchor:self.view.topAnchor],
        [self.sidebarContainer.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor],
        [self.sidebarContainer.widthAnchor constraintEqualToConstant:kSidebarWidth],
        
        // 右侧面板
        [self.rightPanelContainer.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [self.rightPanelContainer.topAnchor constraintEqualToAnchor:self.view.topAnchor],
        [self.rightPanelContainer.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor],
        [self.rightPanelContainer.widthAnchor constraintEqualToConstant:kRightPanelWidth],
        
        // 中间内容区
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
                                             selector:@selector(executeJarFile:)
                                                 name:@"ExecuteJarFile"
                                               object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(backgroundChanged)
                                                 name:@"BackgroundChanged"
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
    // 在中间内容区显示下载页面
    DownloadViewController *downloadVC = [[DownloadViewController alloc] init];
    [self setContentViewController:downloadVC animated:YES];
}

- (void)showVersionManager {
    // 在中间内容区显示版本管理页面
    VersionManagerViewController *vc = [[VersionManagerViewController alloc] init];
    [self setContentViewController:vc animated:YES];
}

- (void)showProfileEditor:(NSNotification *)notification {
    // 在中间内容区显示版本编辑器页面
    NSString *profileName = notification.object;
    
    LauncherProfileEditorViewController *vc = [[LauncherProfileEditorViewController alloc] init];
    vc.profile = [PLProfiles.current.profiles[profileName] mutableCopy];
    if (!vc.profile) {
        vc.profile = [NSMutableDictionary dictionary];
        vc.profile[@"name"] = profileName;
    }
    
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
    [self setContentViewController:vc animated:YES];
}

- (void)executeJarFile:(NSNotification *)notification {
    NSURL *jarURL = notification.object;
    if (jarURL) {
        // 调用LauncherNavigationController的enterModInstaller方法
        // 这里需要通过通知或其他方式传递给LauncherNavigationController
        [[NSNotificationCenter defaultCenter] postNotificationName:@"EnterModInstaller" object:jarURL];
    }
}

- (void)backgroundChanged {
    // 重新应用背景
    [[BackgroundManager sharedManager] applyBackgroundToView:self.view];
}

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

#pragma mark - Content Switching

- (void)setContentViewController:(UIViewController *)viewController animated:(BOOL)animated {
    if (!viewController) return;
    
    // 检查是否切换到非编辑器页面
    if (![viewController isKindOfClass:[UINavigationController class]] ||
        ![((UINavigationController *)viewController).topViewController isKindOfClass:[LauncherProfileEditorViewController class]]) {
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
