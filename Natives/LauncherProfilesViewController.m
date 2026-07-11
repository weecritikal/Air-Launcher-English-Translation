#import "LauncherMenuViewController.h"
#import "LauncherNavigationController.h"
#import "LauncherPreferences.h"
#import "LauncherPrefGameDirViewController.h"
#import "LauncherPrefManageJREViewController.h"
#import "ProfileSettingsViewController.h"
#import "LauncherProfilesViewController.h"
#import "PLProfiles.h"
#import "VersionCardCell.h"  // 新增：导入独立的 VersionCardCell
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wunguarded-availability-new"
#import "UIKit+AFNetworking.h"
#pragma clang diagnostic pop
#import "UIKit+hook.h"
#import "installer/FabricInstallViewController.h"
#import "installer/ForgeInstallViewController.h"
#import "installer/ForgeDirectInstaller.h"
#import "installer/NeoForgeDirectInstaller.h"
#import "installer/ModpackInstallViewController.h"
#import "ios_uikit_bridge.h"
#import "utils.h"
#import "ModsManagerViewController.h"
#import "ShadersManagerViewController.h"
#import "authenticator/BaseAuthenticator.h"
#import "AccountListViewController.h"
#import "BackgroundManager.h"

// 版本类型
typedef NS_ENUM(NSInteger, VersionType) {
    VersionTypeRelease,
    VersionTypeSnapshot,
    VersionTypeOld,
    VersionTypeAll
};

@interface LauncherProfilesViewController () <UICollectionViewDataSource, UICollectionViewDelegate>
@property(nonatomic) UIBarButtonItem *createButtonItem;
@property(nonatomic, strong) UICollectionView *collectionView;
@property(nonatomic, strong) UISegmentedControl *filterSegment;
@property(nonatomic, strong) NSArray *versionList;
@property(nonatomic, strong) NSArray *filteredVersions;
@property(nonatomic, strong) UIActivityIndicatorView *loadingIndicator;
@end

@implementation LauncherProfilesViewController

- (id)init {
    self = [super init];
    self.title = @"下载";
    return self;
}

- (NSString *)imageName {
    return @"MenuProfiles";
}

- (void)viewDidLoad {
    [super viewDidLoad];

    self.view.backgroundColor = [UIColor systemBackgroundColor];
    // 适配自定义启动器背景：将当前视图控制器透明化，让全局背景（图片/视频）能够透出显示。
    // 放在 view.backgroundColor 设置之后调用，确保透明效果不会被不透明背景色覆盖。
    [[BackgroundManager sharedManager] makeViewControllerTransparent:self];

    // 设置导航栏
    [self setupNavigationBar];

    // 设置筛选器
    [self setupFilterSegment];

    // 设置集合视图
    [self setupCollectionView];
    // 确保 collectionView 背景透明，让全局背景能够透出
    // （UICollectionView 没有 backgroundView 属性，仅需清空 backgroundColor）
    self.collectionView.backgroundColor = [UIColor clearColor];

    // 设置加载指示器
    [self setupLoadingIndicator];

    // 加载版本列表
    [self loadVersionList];

    // 监听背景 UI 效果变化通知：当用户在背景设置中切换毛玻璃/半透明或调整透明度时，
    // 重新调用 makeViewControllerTransparent 以应用最新的视觉效果，保证背景始终正确透出。
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(reapplyBackgroundEffect)
                                                 name:@"BackgroundUIEffectChanged"
                                               object:nil];
}

- (void)setupNavigationBar {
    // 添加按钮
    UIMenu *createMenu = [UIMenu menuWithTitle:@"新建" image:nil identifier:nil
    options:UIMenuOptionsDisplayInline
    children:@[
        [UIAction actionWithTitle:@"Vanilla" image:nil identifier:@"vanilla" handler:^(UIAction *action) {
            [self actionCreateVanillaProfile];
        }],
        [UIAction actionWithTitle:@"Fabric/Quilt" image:nil identifier:@"fabric" handler:^(UIAction *action) {
            [self actionCreateFabricProfile];
        }],
        [UIAction actionWithTitle:@"Forge" image:nil identifier:@"forge" handler:^(UIAction *action) {
            [self actionCreateForgeProfile];
        }],
        [UIAction actionWithTitle:@"整合包" image:nil identifier:@"modpack" handler:^(UIAction *action) {
            [self actionCreateModpackProfile];
        }]
    ]];
    
    self.createButtonItem = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemAdd menu:createMenu];
    self.navigationItem.rightBarButtonItem = self.createButtonItem;
}

- (void)setupFilterSegment {
    self.filterSegment = [[UISegmentedControl alloc] initWithItems:@[@"全部", @"正式版", @"测试版", @"远古版"]];
    self.filterSegment.translatesAutoresizingMaskIntoConstraints = NO;
    self.filterSegment.selectedSegmentIndex = 0;
    [self.filterSegment addTarget:self action:@selector(filterChanged:) forControlEvents:UIControlEventValueChanged];
    [self.view addSubview:self.filterSegment];
}

- (void)setupCollectionView {
    UICollectionViewFlowLayout *layout = [[UICollectionViewFlowLayout alloc] init];
    layout.scrollDirection = UICollectionViewScrollDirectionVertical;
    // 与 DownloadViewController 一致：单列横向列表行，行高 64pt
    // （VersionCardCell 已改为 FCL/ZL2 风格横向行布局，不再使用 100x140 网格卡片）
    layout.minimumInteritemSpacing = 0;
    layout.minimumLineSpacing = 4;
    layout.itemSize = CGSizeMake(self.view.bounds.size.width - 32, 64);
    layout.sectionInset = UIEdgeInsetsMake(8, 16, 8, 16);

    self.collectionView = [[UICollectionView alloc] initWithFrame:CGRectZero collectionViewLayout:layout];
    self.collectionView.translatesAutoresizingMaskIntoConstraints = NO;
    self.collectionView.backgroundColor = [UIColor clearColor];
    self.collectionView.dataSource = self;
    self.collectionView.delegate = self;
    [self.collectionView registerClass:[VersionCardCell class] forCellWithReuseIdentifier:@"VersionCard"];
    [self.view addSubview:self.collectionView];

    [NSLayoutConstraint activateConstraints:@[
        [self.filterSegment.topAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.topAnchor constant:8],
        [self.filterSegment.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor constant:16],
        [self.filterSegment.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor constant:-16],

        [self.collectionView.topAnchor constraintEqualToAnchor:self.filterSegment.bottomAnchor constant:8],
        [self.collectionView.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [self.collectionView.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [self.collectionView.bottomAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.bottomAnchor]
    ]];
}

// 动态更新 itemSize 宽度，使其填满 collectionView（减去 sectionInset 左右各 16pt）。
// 与 DownloadViewController 的 viewDidLayoutSubviews 保持一致，避免横竖屏切换时 cell 宽度滞后。
- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    if (!self.collectionView) return;
    UICollectionViewFlowLayout *layout = (UICollectionViewFlowLayout *)self.collectionView.collectionViewLayout;
    if (![layout isKindOfClass:[UICollectionViewFlowLayout class]]) return;
    CGFloat horizInset = layout.sectionInset.left + layout.sectionInset.right;
    CGFloat availableWidth = MAX(0, self.collectionView.bounds.size.width - horizInset);
    CGSize target = CGSizeMake(availableWidth, 64);
    if (!CGSizeEqualToSize(layout.itemSize, target)) {
        layout.itemSize = target;
        [layout invalidateLayout];
    }
}

- (void)setupLoadingIndicator {
    self.loadingIndicator = [[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleLarge];
    self.loadingIndicator.translatesAutoresizingMaskIntoConstraints = NO;
    self.loadingIndicator.hidesWhenStopped = YES;
    [self.view addSubview:self.loadingIndicator];
    
    [NSLayoutConstraint activateConstraints:@[
        [self.loadingIndicator.centerXAnchor constraintEqualToAnchor:self.view.centerXAnchor],
        [self.loadingIndicator.centerYAnchor constraintEqualToAnchor:self.view.centerYAnchor]
    ]];
}

- (void)loadVersionList {
    [self.loadingIndicator startAnimating];
    
    // 根据配置选择下载源
    NSString *downloadSource = getPrefObject(@"general.download_source");
    NSString *versionManifestURL;
    
    if ([downloadSource isEqualToString:@"bmclapi"]) {
        versionManifestURL = @"https://bmclapi2.bangbang93.com/mc/game/version_manifest_v2.json";
    } else {
        versionManifestURL = @"https://piston-meta.mojang.com/mc/game/version_manifest_v2.json";
    }
    
    NSURL *url = [NSURL URLWithString:versionManifestURL];
    NSURLSessionDataTask *task = [[NSURLSession sharedSession] dataTaskWithURL:url completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [self.loadingIndicator stopAnimating];
            
            if (data && !error) {
                NSError *jsonError;
                NSDictionary *json = [NSJSONSerialization JSONObjectWithData:data options:0 error:&jsonError];
                if (json && !jsonError) {
                    self.versionList = json[@"versions"];
                    [self applyFilter];
                }
            }
        });
    }];
    [task resume];
}

- (void)filterChanged:(UISegmentedControl *)sender {
    [self applyFilter];
}

- (void)applyFilter {
    if (!self.versionList) return;
    
    VersionType filterType = (VersionType)self.filterSegment.selectedSegmentIndex;
    
    NSMutableArray *filtered = [NSMutableArray array];
    for (NSDictionary *version in self.versionList) {
        NSString *type = version[@"type"];
        
        switch (filterType) {
            case VersionTypeAll:
                [filtered addObject:version];
                break;
            case VersionTypeRelease:
                if ([type isEqualToString:@"release"]) {
                    [filtered addObject:version];
                }
                break;
            case VersionTypeSnapshot:
                if ([type isEqualToString:@"snapshot"]) {
                    [filtered addObject:version];
                }
                break;
            case VersionTypeOld:
                if ([type isEqualToString:@"old_alpha"] || [type isEqualToString:@"old_beta"]) {
                    [filtered addObject:version];
                }
                break;
        }
    }
    
    self.filteredVersions = filtered;
    [self.collectionView reloadData];
}

#pragma mark - UICollectionView DataSource

- (NSInteger)collectionView:(UICollectionView *)collectionView numberOfItemsInSection:(NSInteger)section {
    return self.filteredVersions.count;
}

- (UICollectionViewCell *)collectionView:(UICollectionView *)collectionView cellForItemAtIndexPath:(NSIndexPath *)indexPath {
    VersionCardCell *cell = [collectionView dequeueReusableCellWithReuseIdentifier:@"VersionCard" forIndexPath:indexPath];
    
    NSDictionary *version = self.filteredVersions[indexPath.row];
    NSString *versionId = version[@"id"];
    NSString *releaseTime = version[@"releaseTime"];
    NSString *versionType = version[@"type"];
    
    // 格式化日期
    NSString *formattedDate = [self formatDate:releaseTime];
    
    // 使用新的配置方法
    [cell configureWithVersionId:versionId date:formattedDate type:versionType];
    
    return cell;
}

- (NSString *)formatDate:(NSString *)dateString {
    // 简化日期显示
    if (dateString.length >= 10) {
        return [dateString substringToIndex:10];
    }
    return dateString;
}

#pragma mark - UICollectionView Delegate

- (void)collectionView:(UICollectionView *)collectionView didSelectItemAtIndexPath:(NSIndexPath *)indexPath {
    NSDictionary *version = self.filteredVersions[indexPath.row];
    NSString *versionId = version[@"id"];
    
    // 显示确认对话框
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:versionId
                                                                   message:@"选择操作"
                                                            preferredStyle:UIAlertControllerStyleActionSheet];
    
    [alert addAction:[UIAlertAction actionWithTitle:@"下载此版本"
                                              style:UIAlertActionStyleDefault
                                            handler:^(UIAlertAction * _Nonnull action) {
        [self downloadVersion:version];
    }]];
    
    [alert addAction:[UIAlertAction actionWithTitle:@"取消"
                                              style:UIAlertActionStyleCancel
                                            handler:nil]];
    
    // iPad支持
    if (UIDevice.currentDevice.userInterfaceIdiom == UIUserInterfaceIdiomPad) {
        VersionCardCell *cell = (VersionCardCell *)[collectionView cellForItemAtIndexPath:indexPath];
        alert.popoverPresentationController.sourceView = cell;
        alert.popoverPresentationController.sourceRect = cell.bounds;
    }
    
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)downloadVersion:(NSDictionary *)version {
    NSString *versionId = version[@"id"];
    
    // 创建新的配置文件
    NSMutableDictionary *profile = [NSMutableDictionary dictionary];
    profile[@"name"] = versionId;
    profile[@"lastVersionId"] = versionId;
    profile[@"type"] = @"custom";
    profile[@"created"] = [NSDate date].description;
    
    // 保存配置
    [PLProfiles.current saveProfile:profile withName:versionId];
    PLProfiles.current.selectedProfileName = versionId;
    
    // 显示下载进度
    UIAlertController *progressAlert = [UIAlertController alertControllerWithTitle:@"下载中"
                                                                           message:[NSString stringWithFormat:@"正在下载 %@...", versionId]
                                                                    preferredStyle:UIAlertControllerStyleAlert];
    [self presentViewController:progressAlert animated:YES completion:nil];
    
    // 模拟下载完成
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        [progressAlert dismissViewControllerAnimated:YES completion:^{
            UIAlertController *successAlert = [UIAlertController alertControllerWithTitle:@"下载完成"
                                                                                  message:[NSString stringWithFormat:@"%@ 下载完成", versionId]
                                                                           preferredStyle:UIAlertControllerStyleAlert];
            [successAlert addAction:[UIAlertAction actionWithTitle:@"确定" style:UIAlertActionStyleDefault handler:nil]];
            [self presentViewController:successAlert animated:YES completion:nil];
        }];
    });
}

#pragma mark - Actions

- (void)actionCreateVanillaProfile {
    // 创建原版配置
    [self showVersionSelectorForType:@"vanilla"];
}

- (void)actionCreateFabricProfile {
    FabricInstallViewController *vc = [FabricInstallViewController new];
    [self presentNavigatedViewController:vc];
}

- (void)actionCreateForgeProfile {
    ForgeInstallViewController *vc = [ForgeInstallViewController new];
    __weak typeof(self) weakSelf = self;
    vc.completionHandler = ^(BOOL success, NSString *profileName, id resultOrError) {
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf) return;

        // 用户取消：ForgeInstallerFlowErrorDomain/Cancelled 时静默
        if (!success) {
            if ([resultOrError isKindOfClass:[NSError class]]) {
                NSError *err = (NSError *)resultOrError;
                if ([err.domain isEqualToString:ForgeInstallerFlowErrorDomain] && err.code == ForgeInstallerFlowErrorCodeCancelled) {
                    return;
                }
                showDialog(localize(@"Error", nil), err.localizedDescription);
            }
            return;
        }

        // 解析 ForgeInstallVC 打包的结果
        NSInteger selectedScheme = 0;
        NSString *filePath = nil;
        if ([resultOrError isKindOfClass:[NSDictionary class]]) {
            NSDictionary *result = (NSDictionary *)resultOrError;
            filePath = result[@"filePath"];
            selectedScheme = [result[@"selectedScheme"] integerValue];
        } else if ([resultOrError isKindOfClass:[NSString class]]) {
            filePath = (NSString *)resultOrError;
        }

        BOOL isNeoForge = vc.isNeoForge;

        if (selectedScheme == 1 && filePath.length > 0) {
            // 直装方案：纯文件操作，不依赖 LauncherNavigationController
            dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
                NSError *directError = nil;
                BOOL installed = NO;
                if (isNeoForge) {
                    installed = [NeoForgeDirectInstaller installNeoForgeFromInstaller:filePath versionId:profileName error:&directError];
                } else {
                    installed = [ForgeDirectInstaller installForgeFromInstaller:filePath versionId:profileName error:&directError];
                }
                dispatch_async(dispatch_get_main_queue(), ^{
                    if (installed) {
                        showDialog(localize(@"Success", nil), [NSString stringWithFormat:@"%@ 安装成功", isNeoForge ? @"NeoForge" : @"Forge"]);
                    } else {
                        showDialog(localize(@"Error", nil), directError.localizedDescription ?: @"未知错误");
                    }
                });
            });
            return;
        }

        // 原版方案：通过 keyWindow.rootViewController 递归找到 LauncherNavigationController 启动 AWT 安装器
        LauncherNavigationController *launcherNav = [strongSelf findLauncherNavigationController];
        if (launcherNav && filePath.length > 0) {
            [launcherNav enterModInstallerWithPath:filePath hitEnterAfterWindowShown:YES];
            showDialog(localize(@"Info", nil), [NSString stringWithFormat:@"%@ 安装器已启动", isNeoForge ? @"NeoForge" : @"Forge"]);
        } else if (filePath.length > 0) {
            showDialog(localize(@"Error", nil), @"无法启动安装器：未找到主启动器导航控制器");
        }
    };
    [self presentNavigatedViewController:vc];
}

// 从 keyWindow.rootViewController 递归查找 LauncherNavigationController
- (LauncherNavigationController *)findLauncherNavigationController {
    UIWindow *keyWindow = nil;
    if (@available(iOS 13.0, *)) {
        for (UIWindowScene *scene in [UIApplication sharedApplication].connectedScenes) {
            if (scene.activationState == UISceneActivationStateForegroundActive) {
                keyWindow = scene.windows.firstObject;
                break;
            }
        }
    }
    if (!keyWindow) {
        keyWindow = [[UIApplication sharedApplication] windows].firstObject;
    }
    UIViewController *rootVC = keyWindow.rootViewController;
    return [self findLauncherNavIn:rootVC];
}

- (LauncherNavigationController *)findLauncherNavIn:(UIViewController *)vc {
    if (!vc) return nil;
    if ([vc isKindOfClass:[LauncherNavigationController class]]) {
        return (LauncherNavigationController *)vc;
    }
    if ([vc isKindOfClass:[UINavigationController class]]) {
        for (UIViewController *child in ((UINavigationController *)vc).viewControllers) {
            LauncherNavigationController *found = [self findLauncherNavIn:child];
            if (found) return found;
        }
    }
    if ([vc isKindOfClass:[UISplitViewController class]]) {
        for (UIViewController *child in ((UISplitViewController *)vc).viewControllers) {
            LauncherNavigationController *found = [self findLauncherNavIn:child];
            if (found) return found;
        }
    }
    if ([vc isKindOfClass:[UITabBarController class]]) {
        for (UIViewController *child in ((UITabBarController *)vc).viewControllers) {
            LauncherNavigationController *found = [self findLauncherNavIn:child];
            if (found) return found;
        }
    }
    if (vc.presentedViewController) {
        LauncherNavigationController *found = [self findLauncherNavIn:vc.presentedViewController];
        if (found) return found;
    }
    for (UIViewController *child in vc.childViewControllers) {
        LauncherNavigationController *found = [self findLauncherNavIn:child];
        if (found) return found;
    }
    return nil;
}

- (void)actionCreateModpackProfile {
    ModpackInstallViewController *vc = [ModpackInstallViewController new];
    [self presentNavigatedViewController:vc];
}

- (void)showVersionSelectorForType:(NSString *)type {
    // 显示版本选择器
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"选择版本"
                                                                   message:nil
                                                            preferredStyle:UIAlertControllerStyleActionSheet];
    
    [alert addAction:[UIAlertAction actionWithTitle:@"最新正式版"
                                              style:UIAlertActionStyleDefault
                                            handler:^(UIAlertAction * _Nonnull action) {
        [self createProfileWithVersion:@"latest-release" type:type];
    }]];
    
    [alert addAction:[UIAlertAction actionWithTitle:@"最新测试版"
                                              style:UIAlertActionStyleDefault
                                            handler:^(UIAlertAction * _Nonnull action) {
        [self createProfileWithVersion:@"latest-snapshot" type:type];
    }]];
    
    [alert addAction:[UIAlertAction actionWithTitle:@"取消"
                                              style:UIAlertActionStyleCancel
                                            handler:nil]];
    
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)createProfileWithVersion:(NSString *)versionId type:(NSString *)type {
    NSMutableDictionary *profile = [NSMutableDictionary dictionary];
    profile[@"name"] = versionId;
    profile[@"lastVersionId"] = versionId;
    profile[@"type"] = type;
    
    [PLProfiles.current saveProfile:profile withName:versionId];
    PLProfiles.current.selectedProfileName = versionId;
    
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"创建成功"
                                                                   message:[NSString stringWithFormat:@"已创建 %@ 配置", versionId]
                                                            preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"确定" style:UIAlertActionStyleDefault handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)presentNavigatedViewController:(UIViewController *)vc {
    UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:vc];
    [self presentViewController:nav animated:YES completion:nil];
}

#pragma mark - Orientation

- (BOOL)shouldAutorotate {
    return YES;
}

- (UIInterfaceOrientationMask)supportedInterfaceOrientations {
    return UIInterfaceOrientationMaskLandscape;
}

/// 重新应用背景效果：当 BackgroundUIEffectChanged 通知到达时调用，
/// 通过 BackgroundManager 重新设置当前视图控制器的透明度/毛玻璃效果，
/// 并将 collectionView 背景置为透明，确保全局背景能够正常透出。
- (void)reapplyBackgroundEffect {
    [[BackgroundManager sharedManager] makeViewControllerTransparent:self];
    self.collectionView.backgroundColor = [UIColor clearColor];
}

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

@end
