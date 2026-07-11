//
//  ShaderVersionViewController.m
//  Amethyst
//
//  Shader version selection view controller implementation
//

#import "ShaderVersionViewController.h"
#import "installer/modpack/ModrinthAPI.h"
#import "ShaderVersion.h"
#import "ShaderVersionTableViewCell.h"
#import "AssetDetailHeaderView.h"
#import "BackgroundManager.h"

@interface ShaderVersionViewController () <UITableViewDataSource, UITableViewDelegate>

@property (nonatomic, strong) UITableView *tableView;
@property (nonatomic, strong) UIButton *gameVersionFilterButton;
@property (nonatomic, strong) UIButton *loaderFilterButton;

@property (nonatomic, strong) NSArray<ShaderVersion *> *allVersions;
@property (nonatomic, strong) NSArray<ShaderVersion *> *filteredVersions;

@property (nonatomic, strong) NSArray<NSString *> *availableGameVersions;
@property (nonatomic, strong) NSArray<NSString *> *availableLoaders;

@property (nonatomic, strong) NSString *selectedGameVersion;
@property (nonatomic, strong) NSString *selectedLoader;

// 项目详情头部视图（展示项目封面图/标题/作者/下载量/标签/描述，补齐信息显示缺口）
@property (nonatomic, strong) AssetDetailHeaderView *detailHeaderView;

@end

@implementation ShaderVersionViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = self.shaderItem.displayName;
    self.view.backgroundColor = [UIColor systemBackgroundColor];
    // 适配自定义启动器背景：透明化当前 VC，让全局背景图/毛玻璃透出
    [[BackgroundManager sharedManager] makeViewControllerTransparent:self];

    [self setupFilterControls];
    [self setupTableView];
    [self setupActivityIndicator];
    [self setupDetailHeader];

    // 透明化 tableView 背景，避免遮挡全局背景
    self.tableView.backgroundColor = [UIColor clearColor];
    self.tableView.backgroundView = nil;

    [self fetchVersions];

    // 监听背景效果变化通知，背景切换时重新应用透明效果
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(reapplyBackgroundEffect)
                                                 name:@"BackgroundUIEffectChanged"
                                               object:nil];
}

- (void)reapplyBackgroundEffect {
    // 背景效果改变时重新透明化当前 VC
    [[BackgroundManager sharedManager] makeViewControllerTransparent:self];
    // 重新设置 tableView 背景为透明，确保背景效果切换后仍透出全局背景
    self.tableView.backgroundColor = [UIColor clearColor];
    self.tableView.backgroundView = nil;
}

- (void)dealloc {
    // 移除通知观察者，避免dealloc后收到通知导致崩溃
    [[NSNotificationCenter defaultCenter] removeObserver:self];
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

    // 用搜索阶段已有的 shaderItem 数据填充（无需额外 API 调用）
    [self.detailHeaderView configureWithIconURL:self.shaderItem.iconURL
                                          title:self.shaderItem.displayName
                                         author:self.shaderItem.author
                                      downloads:self.shaderItem.downloads
                                          likes:self.shaderItem.likes
                                descriptionText:self.shaderItem.shaderDescription
                                    categories:self.shaderItem.categories
                                   lastUpdated:self.shaderItem.lastUpdated
                           placeholderSymbolName:@"paintbrush.fill"
                               placeholderColor:[UIColor systemPurpleColor]];

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

- (void)setupFilterControls {
    self.gameVersionFilterButton = [self createFilterButtonWithTitle:@"游戏版本: 加载中..."];
    self.loaderFilterButton = [self createFilterButtonWithTitle:@"加载器: 加载中..."];

    UIStackView *filterStackView = [[UIStackView alloc] initWithArrangedSubviews:@[self.gameVersionFilterButton, self.loaderFilterButton]];
    filterStackView.translatesAutoresizingMaskIntoConstraints = NO;
    filterStackView.axis = UILayoutConstraintAxisHorizontal;
    filterStackView.distribution = UIStackViewDistributionFillEqually;
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
    button.showsMenuAsPrimaryAction = YES;
    return button;
}

- (void)setupTableView {
    self.tableView = [[UITableView alloc] initWithFrame:CGRectZero style:UITableViewStylePlain];
    self.tableView.translatesAutoresizingMaskIntoConstraints = NO;
    self.tableView.dataSource = self;
    self.tableView.delegate = self;
    [self.tableView registerClass:[ShaderVersionTableViewCell class] forCellReuseIdentifier:@"ShaderVersionCell"];
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
    [self.activityIndicator startAnimating];
    [[ModrinthAPI sharedInstance] getVersionsForShaderWithID:self.shaderItem.onlineID completion:^(NSArray<ShaderVersion *> * _Nullable versions, NSError * _Nullable error) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [self.activityIndicator stopAnimating];
            if (error) {
                NSLog(@"[ShaderVersionVC] Error fetching versions: %@", error);
                UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"错误" message:@"无法获取版本信息" preferredStyle:UIAlertControllerStyleAlert];
                [alert addAction:[UIAlertAction actionWithTitle:@"确定" style:UIAlertActionStyleDefault handler:nil]];
                [self presentViewController:alert animated:YES completion:nil];
                return;
            }
            self.allVersions = versions;
            [self processFilters];
            [self filterChanged];
        });
    }];
}

- (void)processFilters {
    NSMutableSet<NSString *> *gameVersions = [NSMutableSet setWithObject:@"全部"];
    NSMutableSet<NSString *> *loaders = [NSMutableSet setWithObject:@"全部"];

    for (ShaderVersion *version in self.allVersions) {
        for (NSString *gameVersion in version.gameVersions) {
            [gameVersions addObject:gameVersion];
        }
        for (NSString *loader in version.loaders) {
            [loaders addObject:[loader capitalizedString]];
        }
    }

    // Sort game versions with semantic versioning
    self.availableGameVersions = [[gameVersions allObjects] sortedArrayUsingComparator:^NSComparisonResult(NSString *obj1, NSString *obj2) {
        if ([obj1 isEqualToString:@"全部"]) return NSOrderedAscending;
        if ([obj2 isEqualToString:@"全部"]) return NSOrderedDescending;
        return [obj2 compare:obj1 options:NSNumericSearch];
    }];

    self.availableLoaders = [[loaders allObjects] sortedArrayUsingSelector:@selector(compare:)];

    self.selectedGameVersion = self.availableGameVersions.firstObject;
    self.selectedLoader = self.availableLoaders.firstObject;

    [self updateFilterButtons];
}

- (void)updateFilterButtons {
    // Game Version Button Menu
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

    // Loader Button Menu
    NSMutableArray<UIAction *> *loaderActions = [NSMutableArray array];
    for (NSString *loader in self.availableLoaders) {
        UIAction *action = [UIAction actionWithTitle:loader image:nil identifier:nil handler:^(__kindof UIAction * _Nonnull action) {
            self.selectedLoader = action.title;
            [self filterAndReload];
            [self updateFilterButtons];
        }];
        if ([self.selectedLoader isEqualToString:loader]) {
            action.state = UIMenuElementStateOn;
        }
        [loaderActions addObject:action];
    }
    self.loaderFilterButton.menu = [UIMenu menuWithTitle:@"选择加载器" children:loaderActions];
    [self.loaderFilterButton setTitle:[NSString stringWithFormat:@"加载器: %@", self.selectedLoader] forState:UIControlStateNormal];
}

- (void)filterChanged {
    [self filterAndReload];
}

- (void)filterAndReload {
    NSPredicate *predicate = [NSPredicate predicateWithBlock:^BOOL(ShaderVersion *evaluatedObject, NSDictionary *bindings) {
        BOOL gameVersionMatch = [self.selectedGameVersion isEqualToString:@"全部"] || [evaluatedObject.gameVersions containsObject:self.selectedGameVersion];
        BOOL loaderMatch = [self.selectedLoader isEqualToString:@"全部"] || [evaluatedObject.loaders containsObject:self.selectedLoader.lowercaseString];
        return gameVersionMatch && loaderMatch;
    }];

    self.filteredVersions = [self.allVersions filteredArrayUsingPredicate:predicate];
    [self.tableView reloadData];
}

#pragma mark - UITableViewDataSource

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    return self.filteredVersions.count;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    ShaderVersionTableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"ShaderVersionCell" forIndexPath:indexPath];
    ShaderVersion *version = self.filteredVersions[indexPath.row];
    [cell configureWithVersion:version];
    return cell;
}

#pragma mark - UITableViewDelegate

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    ShaderVersion *selectedVersion = self.filteredVersions[indexPath.row];
    if ([self.delegate respondsToSelector:@selector(shaderVersionViewController:didSelectVersion:)]) {
        [self.delegate shaderVersionViewController:self didSelectVersion:selectedVersion];
    }
    [self.navigationController popViewControllerAnimated:YES];
}

@end
