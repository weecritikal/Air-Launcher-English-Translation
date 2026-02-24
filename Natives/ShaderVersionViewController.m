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

@end

@implementation ShaderVersionViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = self.shaderItem.displayName;
    self.view.backgroundColor = [UIColor systemBackgroundColor];

    [self setupFilterControls];
    [self setupTableView];
    [self setupActivityIndicator];

    [self fetchVersions];
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
