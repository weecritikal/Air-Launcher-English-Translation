#import "LauncherMenuViewController.h"
#import "LauncherNavigationController.h"
#import "LauncherPreferences.h"
#import "LauncherPrefGameDirViewController.h"
#import "LauncherPrefManageJREViewController.h"
#import "LauncherProfileEditorViewController.h"
#import "LauncherProfilesViewController.h"
#import "PLProfiles.h"
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wunguarded-availability-new"
#import "UIKit+AFNetworking.h"
#pragma clang diagnostic pop
#import "UIKit+hook.h"
#import "installer/FabricInstallViewController.h"
#import "installer/ForgeInstallViewController.h"
#import "installer/ModpackInstallViewController.h"
#import "ios_uikit_bridge.h"
#import "utils.h"
#import "ModsManagerViewController.h"
#import "ShadersManagerViewController.h"
#import "authenticator/BaseAuthenticator.h"
#import "AccountListViewController.h"

// 版本类型
typedef NS_ENUM(NSInteger, VersionType) {
    VersionTypeRelease,
    VersionTypeSnapshot,
    VersionTypeOld,
    VersionTypeAll
};

// 版本卡片Cell
@interface VersionCardCell : UICollectionViewCell
@property (nonatomic, strong) UIImageView *iconImageView;
@property (nonatomic, strong) UILabel *versionLabel;
@property (nonatomic, strong) UILabel *dateLabel;
@property (nonatomic, strong) UILabel *typeLabel;
@end

@implementation VersionCardCell

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        self.backgroundColor = [UIColor secondarySystemBackgroundColor];
        self.layer.cornerRadius = 12;
        self.layer.masksToBounds = YES;
        
        // 图标
        self.iconImageView = [[UIImageView alloc] init];
        self.iconImageView.translatesAutoresizingMaskIntoConstraints = NO;
        self.iconImageView.contentMode = UIViewContentModeScaleAspectFit;
        self.iconImageView.image = [UIImage imageNamed:@"DefaultProfile"] ?: [UIImage systemImageNamed:@"cube.fill"];
        [self.contentView addSubview:self.iconImageView];
        
        // 版本号
        self.versionLabel = [[UILabel alloc] init];
        self.versionLabel.translatesAutoresizingMaskIntoConstraints = NO;
        self.versionLabel.font = [UIFont boldSystemFontOfSize:16];
        self.versionLabel.textAlignment = NSTextAlignmentCenter;
        [self.contentView addSubview:self.versionLabel];
        
        // 日期
        self.dateLabel = [[UILabel alloc] init];
        self.dateLabel.translatesAutoresizingMaskIntoConstraints = NO;
        self.dateLabel.font = [UIFont systemFontOfSize:11];
        self.dateLabel.textColor = [UIColor secondaryLabelColor];
        self.dateLabel.textAlignment = NSTextAlignmentCenter;
        [self.contentView addSubview:self.dateLabel];
        
        // 类型标签
        self.typeLabel = [[UILabel alloc] init];
        self.typeLabel.translatesAutoresizingMaskIntoConstraints = NO;
        self.typeLabel.font = [UIFont systemFontOfSize:10];
        self.typeLabel.textColor = [UIColor whiteColor];
        self.typeLabel.backgroundColor = [UIColor systemBlueColor];
        self.typeLabel.textAlignment = NSTextAlignmentCenter;
        self.typeLabel.layer.cornerRadius = 4;
        self.typeLabel.layer.masksToBounds = YES;
        [self.contentView addSubview:self.typeLabel];
        
        [NSLayoutConstraint activateConstraints:@[
            [self.iconImageView.topAnchor constraintEqualToAnchor:self.contentView.topAnchor constant:12],
            [self.iconImageView.centerXAnchor constraintEqualToAnchor:self.contentView.centerXAnchor],
            [self.iconImageView.widthAnchor constraintEqualToConstant:50],
            [self.iconImageView.heightAnchor constraintEqualToConstant:50],
            
            [self.versionLabel.topAnchor constraintEqualToAnchor:self.iconImageView.bottomAnchor constant:8],
            [self.versionLabel.leadingAnchor constraintEqualToAnchor:self.contentView.leadingAnchor constant:8],
            [self.versionLabel.trailingAnchor constraintEqualToAnchor:self.contentView.trailingAnchor constant:-8],
            
            [self.dateLabel.topAnchor constraintEqualToAnchor:self.versionLabel.bottomAnchor constant:4],
            [self.dateLabel.leadingAnchor constraintEqualToAnchor:self.contentView.leadingAnchor constant:8],
            [self.dateLabel.trailingAnchor constraintEqualToAnchor:self.contentView.trailingAnchor constant:-8],
            
            [self.typeLabel.bottomAnchor constraintEqualToAnchor:self.contentView.bottomAnchor constant:-8],
            [self.typeLabel.centerXAnchor constraintEqualToAnchor:self.contentView.centerXAnchor],
            [self.typeLabel.widthAnchor constraintEqualToConstant:50],
            [self.typeLabel.heightAnchor constraintEqualToConstant:18]
        ]];
    }
    return self;
}

@end

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
    
    // 设置导航栏
    [self setupNavigationBar];
    
    // 设置筛选器
    [self setupFilterSegment];
    
    // 设置集合视图
    [self setupCollectionView];
    
    // 设置加载指示器
    [self setupLoadingIndicator];
    
    // 加载版本列表
    [self loadVersionList];
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
    layout.minimumInteritemSpacing = 12;
    layout.minimumLineSpacing = 12;
    
    // 计算单元格大小 (每行4个)
    CGFloat itemWidth = (self.view.bounds.size.width - 60) / 4;
    layout.itemSize = CGSizeMake(itemWidth, 140);
    layout.sectionInset = UIEdgeInsetsMake(12, 12, 12, 12);
    
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
    
    // 从 Mojang API 获取版本列表
    NSURL *url = [NSURL URLWithString:@"https://launchermeta.mojang.com/mc/game/version_manifest.json"];
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
    NSString *type = version[@"releaseTime"];
    NSString *versionType = version[@"type"];
    
    cell.versionLabel.text = versionId;
    cell.dateLabel.text = [self formatDate:type];
    
    // 设置类型标签
    if ([versionType isEqualToString:@"release"]) {
        cell.typeLabel.text = @"正式版";
        cell.typeLabel.backgroundColor = [UIColor systemGreenColor];
    } else if ([versionType isEqualToString:@"snapshot"]) {
        cell.typeLabel.text = @"测试版";
        cell.typeLabel.backgroundColor = [UIColor systemOrangeColor];
    } else {
        cell.typeLabel.text = @"远古版";
        cell.typeLabel.backgroundColor = [UIColor systemPurpleColor];
    }
    
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
    [self presentNavigatedViewController:vc];
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

@end
