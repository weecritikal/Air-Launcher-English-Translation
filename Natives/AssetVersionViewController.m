//
//  AssetVersionViewController.m
//  Amethyst
//
//  通用资源版本选择视图控制器实现
//  参照 ModVersionViewController，但仅保留游戏版本过滤按钮（无加载器过滤）
//  复用 ModrinthAPI 的 getVersionsForModWithID: 方法（API 端点对所有 project_type 通用）
//

#import "AssetVersionViewController.h"
#import "installer/modpack/ModrinthAPI.h"
#import "ModVersion.h"
#import "ModVersionTableViewCell.h"
#import "AssetDetailHeaderView.h"

@interface AssetVersionViewController () <UITableViewDataSource, UITableViewDelegate>

@property (nonatomic, strong) UITableView *tableView;
@property (nonatomic, strong) UIButton *gameVersionFilterButton;
@property (nonatomic, strong) UIActivityIndicatorView *activityIndicator;

@property (nonatomic, strong) NSArray<ModVersion *> *allVersions;
@property (nonatomic, strong) NSArray<ModVersion *> *filteredVersions;

@property (nonatomic, strong) NSArray<NSString *> *availableGameVersions;
@property (nonatomic, strong) NSString *selectedGameVersion;

// 项目详情头部视图（展示项目封面图/标题/作者/下载量/标签/描述，补齐信息显示缺口）
@property (nonatomic, strong) AssetDetailHeaderView *detailHeaderView;

@end

@implementation AssetVersionViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = [UIColor systemBackgroundColor];
    self.title = self.projectDisplayName ?: [self titleForAssetType];

    [self setupFilterControls];
    [self setupTableView];
    [self setupActivityIndicator];
    [self setupDetailHeader];

    [self fetchVersions];
}

#pragma mark - Detail Header（项目信息展示）

/// 创建并配置项目详情头部视图，设置为 tableView.tableHeaderView
/// 补齐之前版本页缺少的项目封面图/标题/作者/下载量/标签/描述等信息显示
- (void)setupDetailHeader {
    self.detailHeaderView = [[AssetDetailHeaderView alloc] init];

    // 描述展开/收起时重新计算 header 高度（避免循环引用，用 weak）
    __weak typeof(self) weakSelf = self;
    self.detailHeaderView.onSizeChanged = ^{
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (strongSelf) [strongSelf updateTableHeaderHeight];
    };

    // 根据 assetType 选占位 SF Symbol + 配色（与 ModernAssetCell 的资源类型配色一致）
    NSString *placeholderSymbol = @"doc.fill";
    UIColor *placeholderColor = [UIColor systemBlueColor];
    switch (self.assetType) {
        case AssetVersionTypeResourcePack:
            placeholderSymbol = @"photo.stack.fill";
            placeholderColor = [UIColor systemBlueColor];
            break;
        case AssetVersionTypeDataPack:
            placeholderSymbol = @"doc.text.fill";
            placeholderColor = [UIColor systemTealColor];
            break;
        case AssetVersionTypeWorld:
            placeholderSymbol = @"globe";
            placeholderColor = [UIColor systemGreenColor];
            break;
    }

    // 用 DownloadViewController 传入的项目展示信息填充
    [self.detailHeaderView configureWithIconURL:self.projectIconURL
                                          title:self.projectDisplayName ?: @"未知项目"
                                         author:self.projectAuthor
                                      downloads:self.projectDownloads
                                          likes:self.projectLikes
                                descriptionText:self.projectDescription
                                    categories:self.projectCategories
                                   lastUpdated:self.projectLastUpdated
                           placeholderSymbolName:placeholderSymbol
                               placeholderColor:placeholderColor];

    [self updateTableHeaderHeight];
    self.tableView.tableHeaderView = self.detailHeaderView;
}

/// 重新计算 tableHeaderView 高度并刷新（在 viewDidLayoutSubviews 和描述展开/收起时调用）
- (void)updateTableHeaderHeight {
    if (!self.detailHeaderView) return;
    CGFloat width = self.tableView.bounds.size.width;
    if (width <= 0) width = self.view.bounds.size.width;
    if (width <= 0) width = [UIScreen mainScreen].bounds.size.width;
    CGFloat height = [self.detailHeaderView fittingHeightForWidth:width];
    CGRect frame = self.detailHeaderView.frame;
    if (fabs(frame.size.height - height) < 1) return; // 高度未变化则跳过
    frame.size.height = height;
    self.detailHeaderView.frame = frame;
    // 重新赋值触发 tableView 重新布局 header
    self.tableView.tableHeaderView = self.detailHeaderView;
}

- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    // 首次 layout 后 tableView 宽度才确定，此时更新一次 header 高度
    if (self.detailHeaderView) {
        [self updateTableHeaderHeight];
    }
}

// 根据资产类型返回默认导航栏标题
- (NSString *)titleForAssetType {
    switch (self.assetType) {
        case AssetVersionTypeResourcePack: return @"选择资源包版本";
        case AssetVersionTypeDataPack:     return @"选择数据包版本";
        case AssetVersionTypeWorld:        return @"选择世界版本";
    }
    return @"选择版本";
}

- (void)setupFilterControls {
    self.gameVersionFilterButton = [self createFilterButtonWithTitle:@"游戏版本: 加载中..."];

    // 仅游戏版本过滤按钮（资产类型无加载器概念）
    UIStackView *filterStackView = [[UIStackView alloc] initWithArrangedSubviews:@[self.gameVersionFilterButton]];
    filterStackView.translatesAutoresizingMaskIntoConstraints = NO;
    filterStackView.axis = UILayoutConstraintAxisHorizontal;
    filterStackView.distribution = UIStackViewDistributionFill;
    filterStackView.spacing = 8;

    [self.view addSubview:filterStackView];

    [NSLayoutConstraint activateConstraints:@[
        [filterStackView.topAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.topAnchor constant:8],
        [filterStackView.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor constant:8],
        [filterStackView.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor constant:-8],
    ]];
}

- (UIButton *)createFilterButtonWithTitle:(NSString *)title {
    UIButton *button = [UIButton buttonWithType:UIButtonTypeSystem];
    button.translatesAutoresizingMaskIntoConstraints = NO;
    [button setTitle:title forState:UIControlStateNormal];
    button.layer.cornerRadius = 8;
    button.backgroundColor = [UIColor secondarySystemBackgroundColor];
    button.showsMenuAsPrimaryAction = YES; // 点击弹出 UIMenu
    return button;
}

- (void)setupTableView {
    self.tableView = [[UITableView alloc] initWithFrame:CGRectZero style:UITableViewStylePlain];
    self.tableView.translatesAutoresizingMaskIntoConstraints = NO;
    self.tableView.dataSource = self;
    self.tableView.delegate = self;
    [self.tableView registerClass:[ModVersionTableViewCell class] forCellReuseIdentifier:@"AssetVersionCell"];
    [self.view addSubview:self.tableView];

    UIView *filterStackView = self.gameVersionFilterButton.superview;

    [NSLayoutConstraint activateConstraints:@[
        [self.tableView.topAnchor constraintEqualToAnchor:filterStackView.bottomAnchor constant:8],
        [self.tableView.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [self.tableView.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [self.tableView.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor],
    ]];
}

- (void)setupActivityIndicator {
    self.activityIndicator = [[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleLarge];
    self.activityIndicator.translatesAutoresizingMaskIntoConstraints = NO;
    self.activityIndicator.hidesWhenStopped = YES;
    [self.view addSubview:self.activityIndicator];

    [NSLayoutConstraint activateConstraints:@[
        [self.activityIndicator.centerXAnchor constraintEqualToAnchor:self.view.centerXAnchor],
        [self.activityIndicator.centerYAnchor constraintEqualToAnchor:self.view.centerYAnchor],
    ]];
}

- (void)fetchVersions {
    if (!self.projectID.length) {
        NSLog(@"[AssetVersionVC] 缺少 projectID，无法获取版本列表");
        return;
    }

    [self.activityIndicator startAnimating];
    // 复用 getVersionsForModWithID:（Modrinth /project/<id>/version 端点对所有 project_type 通用）
    [[ModrinthAPI sharedInstance] getVersionsForModWithID:self.projectID completion:^(NSArray<ModVersion *> * _Nullable versions, NSError * _Nullable error) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [self.activityIndicator stopAnimating];
            if (error) {
                NSLog(@"[AssetVersionVC] 获取版本列表失败: %@", error);
                UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"错误"
                                                                                message:@"无法获取版本信息"
                                                                         preferredStyle:UIAlertControllerStyleAlert];
                [alert addAction:[UIAlertAction actionWithTitle:@"确定" style:UIAlertActionStyleDefault handler:nil]];
                [self presentViewController:alert animated:YES completion:nil];
                return;
            }
            self.allVersions = versions ?: @[];
            [self processFilters];
            [self filterAndReload];
        });
    }];
}

- (void)processFilters {
    NSMutableSet<NSString *> *gameVersions = [NSMutableSet setWithObject:@"全部"];

    for (ModVersion *version in self.allVersions) {
        for (NSString *gameVersion in version.gameVersions) {
            [gameVersions addObject:gameVersion];
        }
    }

    // 游戏版本按语义版本号倒序排列（新版本在前）
    self.availableGameVersions = [[gameVersions allObjects] sortedArrayUsingComparator:^NSComparisonResult(NSString *obj1, NSString *obj2) {
        if ([obj1 isEqualToString:@"全部"]) return NSOrderedAscending;
        if ([obj2 isEqualToString:@"全部"]) return NSOrderedDescending;
        return [obj2 compare:obj1 options:NSNumericSearch];
    }];

    self.selectedGameVersion = self.availableGameVersions.firstObject ?: @"全部";
    [self updateFilterButtons];
}

- (void)updateFilterButtons {
    NSMutableArray<UIAction *> *gameVersionActions = [NSMutableArray array];
    for (NSString *version in self.availableGameVersions) {
        UIAction *action = [UIAction actionWithTitle:version image:nil identifier:nil handler:^(__kindof UIAction * _Nonnull action) {
            self.selectedGameVersion = action.title;
            [self filterAndReload];
            [self updateFilterButtons];
        }];
        if ([self.selectedGameVersion isEqualToString:version]) {
            action.state = UIMenuElementStateOn;
        }
        [gameVersionActions addObject:action];
    }
    self.gameVersionFilterButton.menu = [UIMenu menuWithTitle:@"选择游戏版本" children:gameVersionActions];
    [self.gameVersionFilterButton setTitle:[NSString stringWithFormat:@"游戏版本: %@", self.selectedGameVersion] forState:UIControlStateNormal];
}

- (void)filterAndReload {
    NSPredicate *predicate = [NSPredicate predicateWithBlock:^BOOL(ModVersion *evaluatedObject, NSDictionary *bindings) {
        // 仅按游戏版本过滤（资产类型无加载器概念）
        return [self.selectedGameVersion isEqualToString:@"全部"] || [evaluatedObject.gameVersions containsObject:self.selectedGameVersion];
    }];

    self.filteredVersions = [self.allVersions filteredArrayUsingPredicate:predicate];
    [self.tableView reloadData];
}

#pragma mark - UITableViewDataSource

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    return self.filteredVersions.count;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    ModVersionTableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"AssetVersionCell" forIndexPath:indexPath];
    ModVersion *version = self.filteredVersions[indexPath.row];
    [cell configureWithVersion:version];
    return cell;
}

#pragma mark - UITableViewDelegate

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    ModVersion *selectedVersion = self.filteredVersions[indexPath.row];
    if ([self.delegate respondsToSelector:@selector(assetVersionViewController:didSelectVersion:)]) {
        [self.delegate assetVersionViewController:self didSelectVersion:selectedVersion];
    }
    [self.navigationController popViewControllerAnimated:YES];
}

@end
