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

@interface AssetVersionViewController () <UITableViewDataSource, UITableViewDelegate>

@property (nonatomic, strong) UITableView *tableView;
@property (nonatomic, strong) UIButton *gameVersionFilterButton;
@property (nonatomic, strong) UIActivityIndicatorView *activityIndicator;

@property (nonatomic, strong) NSArray<ModVersion *> *allVersions;
@property (nonatomic, strong) NSArray<ModVersion *> *filteredVersions;

@property (nonatomic, strong) NSArray<NSString *> *availableGameVersions;
@property (nonatomic, strong) NSString *selectedGameVersion;

@end

@implementation AssetVersionViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = [UIColor systemBackgroundColor];
    self.title = self.projectDisplayName ?: [self titleForAssetType];

    [self setupFilterControls];
    [self setupTableView];
    [self setupActivityIndicator];

    [self fetchVersions];
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
