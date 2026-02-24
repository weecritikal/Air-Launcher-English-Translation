//
//  ShadersManagerViewController.m
//  Amethyst
//
//  Shader manager implementation - mirrors ModsManagerViewController
//

#import "ShadersManagerViewController.h"
#import "ShaderTableViewCell.h"
#import "ShaderService.h"
#import "ShaderItem.h"
#import "installer/modpack/ModrinthAPI.h"

@interface ShadersManagerViewController () <UITableViewDataSource, UITableViewDelegate, ShaderTableViewCellDelegate, UISearchBarDelegate, ShaderVersionViewControllerDelegate>

@property (nonatomic, strong) UISegmentedControl *modeSwitcher;
@property (nonatomic, strong) UISearchBar *searchBar;
@property (nonatomic, strong) UITableView *tableView;
@property (nonatomic, strong) UIActivityIndicatorView *activityIndicator;
@property (nonatomic, strong) UILabel *emptyLabel;
@property (nonatomic, strong) UIBarButtonItem *refreshButton;
@property (nonatomic, strong) NSMutableArray<ShaderItem *> *localShaders;
@property (nonatomic, strong) NSMutableArray<ShaderItem *> *filteredLocalShaders;

@end

@implementation ShadersManagerViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"管理光影";
    self.view.backgroundColor = [UIColor systemBackgroundColor];
    self.currentMode = ShadersManagerModeLocal;
    self.localShaders = [NSMutableArray array];
    self.filteredLocalShaders = [NSMutableArray array];
    self.onlineSearchResults = [NSMutableArray array];
    [self setupUI];
    [self refreshLocalShadersList];
}

- (void)setupUI {
    self.modeSwitcher = [[UISegmentedControl alloc] initWithItems:@[@"本地光影", @"在线搜索 (Modrinth)"]];
    self.modeSwitcher.translatesAutoresizingMaskIntoConstraints = NO;
    self.modeSwitcher.selectedSegmentIndex = 0;
    [self.modeSwitcher addTarget:self action:@selector(modeChanged:) forControlEvents:UIControlEventValueChanged];
    [self.view addSubview:self.modeSwitcher];

    self.searchBar = [[UISearchBar alloc] initWithFrame:CGRectZero];
    self.searchBar.translatesAutoresizingMaskIntoConstraints = NO;
    self.searchBar.delegate = self;
    self.searchBar.placeholder = @"搜索本地光影...";
    [self.view addSubview:self.searchBar];

    self.tableView = [[UITableView alloc] initWithFrame:CGRectZero style:UITableViewStylePlain];
    self.tableView.translatesAutoresizingMaskIntoConstraints = NO;
    [self.tableView registerClass:[ShaderTableViewCell class] forCellReuseIdentifier:@"ShaderCell"];
    self.tableView.dataSource = self;
    self.tableView.delegate = self;
    self.tableView.rowHeight = 80;
    self.tableView.tableFooterView = [UIView new];
    [self.view addSubview:self.tableView];

    UIRefreshControl *rc = [UIRefreshControl new];
    [rc addTarget:self action:@selector(handleRefresh:) forControlEvents:UIControlEventValueChanged];
    self.tableView.refreshControl = rc;

    self.activityIndicator = [[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleLarge];
    self.activityIndicator.translatesAutoresizingMaskIntoConstraints = NO;
    self.activityIndicator.hidesWhenStopped = YES;
    [self.view addSubview:self.activityIndicator];

    self.emptyLabel = [[UILabel alloc] initWithFrame:CGRectZero];
    self.emptyLabel.translatesAutoresizingMaskIntoConstraints = NO;
    self.emptyLabel.textAlignment = NSTextAlignmentCenter;
    self.emptyLabel.textColor = [UIColor secondaryLabelColor];
    self.emptyLabel.hidden = YES;
    [self.view addSubview:self.emptyLabel];

    self.refreshButton = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemRefresh target:self action:@selector(handleRefresh:)];
    [self updateNavigationButtons];

    [NSLayoutConstraint activateConstraints:@[
        [self.modeSwitcher.topAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.topAnchor constant:8],
        [self.modeSwitcher.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor constant:16],
        [self.modeSwitcher.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor constant:-16],

        [self.searchBar.topAnchor constraintEqualToAnchor:self.modeSwitcher.bottomAnchor constant:8],
        [self.searchBar.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [self.searchBar.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],

        [self.tableView.topAnchor constraintEqualToAnchor:self.searchBar.bottomAnchor],
        [self.tableView.bottomAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.bottomAnchor],
        [self.tableView.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [self.tableView.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],

        [self.activityIndicator.centerXAnchor constraintEqualToAnchor:self.tableView.centerXAnchor],
        [self.activityIndicator.centerYAnchor constraintEqualToAnchor:self.tableView.centerYAnchor],

        [self.emptyLabel.centerXAnchor constraintEqualToAnchor:self.tableView.centerXAnchor],
        [self.emptyLabel.centerYAnchor constraintEqualToAnchor:self.tableView.centerYAnchor]
    ]];
}

- (void)modeChanged:(UISegmentedControl *)sender {
    self.currentMode = (ShadersManagerMode)sender.selectedSegmentIndex;
    [self.searchBar resignFirstResponder];
    self.searchBar.text = @"";
    [self.onlineSearchResults removeAllObjects];
    [self filterLocalShaders];
    [self.tableView reloadData];
    [self updateUIForCurrentMode];
}

- (void)updateUIForCurrentMode {
    if (self.currentMode == ShadersManagerModeLocal) {
        self.searchBar.placeholder = @"搜索本地光影...";
        self.emptyLabel.text = @"未发现光影";
        self.emptyLabel.hidden = self.localShaders.count > 0;
    } else {
        self.searchBar.placeholder = @"在线搜索 Modrinth...";
        self.emptyLabel.text = @"输入关键词进行在线搜索";
        self.emptyLabel.hidden = self.onlineSearchResults.count > 0;
    }
    self.tableView.refreshControl.enabled = YES;
    [self updateNavigationButtons];
    [self.tableView reloadData];
}

- (void)updateNavigationButtons {
    if (self.currentMode == ShadersManagerModeLocal) {
        self.navigationItem.rightBarButtonItems = @[self.refreshButton];
    } else {
        self.navigationItem.rightBarButtonItems = nil;
    }
}

#pragma mark - Data Loading

- (void)handleRefresh:(id)sender {
    if (self.currentMode == ShadersManagerModeLocal) {
        [self refreshLocalShadersList];
    } else {
        if (self.searchBar.text.length > 0) {
            [self performOnlineSearch];
        } else {
            [self.tableView.refreshControl endRefreshing];
        }
    }
}

- (void)setLoading:(BOOL)loading {
    dispatch_async(dispatch_get_main_queue(), ^{
        if (loading) {
            self.emptyLabel.hidden = YES;
            [self.activityIndicator startAnimating];
        } else {
            [self.activityIndicator stopAnimating];
            [self.tableView.refreshControl endRefreshing];
        }
    });
}

- (void)refreshLocalShadersList {
    if (self.currentMode != ShadersManagerModeLocal) return;

    [self setLoading:YES];
    NSString *profile = self.profileName ?: @"default";
    [[ShaderService sharedService] scanShadersForProfile:profile completion:^(NSArray<ShaderItem *> *shaders) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [self.localShaders removeAllObjects];
            [self.localShaders addObjectsFromArray:shaders];
            [self filterLocalShaders];
            [self setLoading:NO];
        });
    }];
}

- (void)performOnlineSearch {
    NSString *searchText = self.searchBar.text;
    if (searchText.length == 0) return;

    [self setLoading:YES];
    [self.onlineSearchResults removeAllObjects];
    [self.tableView reloadData];

    NSDictionary *filters = @{@"name": searchText};

    [[ModrinthAPI sharedInstance] searchShaderWithFilters:filters completion:^(NSArray * _Nullable results, NSError * _Nullable error) {
        dispatch_async(dispatch_get_main_queue(), ^{
            if (results) {
                [self.onlineSearchResults addObjectsFromArray:results];
            }
            [self setLoading:NO];
            self.emptyLabel.hidden = self.onlineSearchResults.count > 0;
            if (self.onlineSearchResults.count == 0) {
                self.emptyLabel.text = @"未找到在线结果";
            }
            [self.tableView reloadData];
        });
    }];
}

#pragma mark - UISearchBarDelegate

- (void)searchBar:(UISearchBar *)searchBar textDidChange:(NSString *)searchText {
    if (self.currentMode == ShadersManagerModeLocal) {
        [self filterLocalShaders];
    }
}

- (void)searchBarSearchButtonClicked:(UISearchBar *)searchBar {
    [searchBar resignFirstResponder];
    if (self.currentMode == ShadersManagerModeOnline) {
        [self performOnlineSearch];
    }
}

- (void)searchBarCancelButtonClicked:(UISearchBar *)searchBar {
    searchBar.text = @"";
    [searchBar resignFirstResponder];
    if (self.currentMode == ShadersManagerModeLocal) {
        [self filterLocalShaders];
    } else {
        [self.onlineSearchResults removeAllObjects];
        [self.tableView reloadData];
        [self updateUIForCurrentMode];
    }
}

- (void)filterLocalShaders {
    [self.filteredLocalShaders removeAllObjects];
    if (self.searchBar.text.length == 0) {
        [self.filteredLocalShaders addObjectsFromArray:self.localShaders];
    } else {
        NSString *searchText = [self.searchBar.text lowercaseString];
        for (ShaderItem *shader in self.localShaders) {
            if ([shader.displayName.lowercaseString containsString:searchText] ||
                [shader.fileName.lowercaseString containsString:searchText]) {
                [self.filteredLocalShaders addObject:shader];
            }
        }
    }
    self.emptyLabel.hidden = self.filteredLocalShaders.count > 0;
    if (!self.emptyLabel.hidden) {
        self.emptyLabel.text = @"未找到本地光影";
    }
    [self.tableView reloadData];
}

#pragma mark - UITableView DataSource & Delegate

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    return self.currentMode == ShadersManagerModeLocal ? self.filteredLocalShaders.count : self.onlineSearchResults.count;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    ShaderTableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"ShaderCell" forIndexPath:indexPath];
    cell.delegate = self;

    if (self.currentMode == ShadersManagerModeLocal) {
        ShaderItem *shader = self.filteredLocalShaders[indexPath.row];
        [cell configureWithShader:shader displayMode:ShaderTableViewCellDisplayModeLocal];
    } else {
        NSDictionary *shaderData = self.onlineSearchResults[indexPath.row];
        ShaderItem *shaderItem = [[ShaderItem alloc] initWithOnlineData:shaderData];
        [cell configureWithShader:shaderItem displayMode:ShaderTableViewCellDisplayModeOnline];
    }

    return cell;
}

- (UISwipeActionsConfiguration *)tableView:(UITableView *)tableView trailingSwipeActionsConfigurationForRowAtIndexPath:(NSIndexPath *)indexPath {
    if (self.currentMode != ShadersManagerModeLocal) {
        return nil;
    }

    UIContextualAction *deleteAction = [UIContextualAction contextualActionWithStyle:UIContextualActionStyleDestructive title:@"删除" handler:^(UIContextualAction * _Nonnull action, __kindof UIView * _Nonnull sourceView, void (^ _Nonnull completionHandler)(BOOL)) {

        ShaderItem *shaderToDelete = self.filteredLocalShaders[indexPath.row];

        UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"确认删除" message:[NSString stringWithFormat:@"确定要删除 %@ 吗？\n此操作无法撤销。", shaderToDelete.displayName] preferredStyle:UIAlertControllerStyleAlert];

        [alert addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:^(UIAlertAction * _Nonnull action) {
            completionHandler(NO);
        }]];

        [alert addAction:[UIAlertAction actionWithTitle:@"删除" style:UIAlertActionStyleDestructive handler:^(UIAlertAction * _Nonnull action) {
            NSError *error = nil;
            [[ShaderService sharedService] deleteShader:shaderToDelete error:&error];

            if (error) {
                NSLog(@"[ShadersManager] Error deleting shader: %@", error);
                completionHandler(NO);
            } else {
                NSInteger indexInFullList = [self.localShaders indexOfObject:shaderToDelete];
                if (indexInFullList != NSNotFound) {
                    [self.localShaders removeObjectAtIndex:indexInFullList];
                }
                [self.filteredLocalShaders removeObjectAtIndex:indexPath.row];

                [tableView deleteRowsAtIndexPaths:@[indexPath] withRowAnimation:UITableViewRowAnimationAutomatic];

                completionHandler(YES);
            }
        }]];

        [self presentViewController:alert animated:YES completion:nil];
    }];

    deleteAction.backgroundColor = [UIColor systemRedColor];

    UISwipeActionsConfiguration *configuration = [UISwipeActionsConfiguration configurationWithActions:@[deleteAction]];
    configuration.performsFirstActionWithFullSwipe = YES;

    return configuration;
}

#pragma mark - ShaderTableViewCellDelegate (Download Implementation)

- (void)shaderCellDidTapDownload:(UITableViewCell *)cell {
    NSIndexPath *indexPath = [self.tableView indexPathForCell:cell];
    if (!indexPath || self.currentMode != ShadersManagerModeOnline) return;

    NSDictionary *shaderData = self.onlineSearchResults[indexPath.row];
    ShaderItem *shaderItem = [[ShaderItem alloc] initWithOnlineData:shaderData];

    ShaderVersionViewController *versionVC = [[ShaderVersionViewController alloc] init];
    versionVC.shaderItem = shaderItem;
    versionVC.delegate = self;

    [self.navigationController pushViewController:versionVC animated:YES];
}

#pragma mark - ShaderVersionViewControllerDelegate

- (void)shaderVersionViewController:(ShaderVersionViewController *)viewController didSelectVersion:(ShaderVersion *)version {
    ShaderItem *itemToDownload = viewController.shaderItem;

    // Find the primary file to download
    NSDictionary *primaryFile = version.primaryFile;
    if (!primaryFile || ![primaryFile[@"url"] isKindOfClass:[NSString class]]) {
        [self showSimpleAlertWithTitle:@"错误" message:@"未找到有效的下载链接。"];
        return;
    }

    itemToDownload.selectedVersionDownloadURL = primaryFile[@"url"];
    itemToDownload.fileName = primaryFile[@"filename"];

    [self startDownloadForItem:itemToDownload];
}

- (void)startDownloadForItem:(ShaderItem *)item {
    // Show a temporary "downloading" alert
    UIAlertController *downloadingAlert = [UIAlertController alertControllerWithTitle:@"正在下载"
                                                                              message:[NSString stringWithFormat:@"%@...", item.displayName]
                                                                       preferredStyle:UIAlertControllerStyleAlert];

    UIActivityIndicatorView *indicator = [[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleMedium];
    indicator.translatesAutoresizingMaskIntoConstraints = NO;
    [downloadingAlert.view addSubview:indicator];
    [NSLayoutConstraint activateConstraints:@[
        [indicator.centerXAnchor constraintEqualToAnchor:downloadingAlert.view.centerXAnchor],
        [indicator.centerYAnchor constraintEqualToAnchor:downloadingAlert.view.centerYAnchor constant:20]
    ]];
    [indicator startAnimating];

    [self presentViewController:downloadingAlert animated:YES completion:nil];

    [[ShaderService sharedService] downloadShader:item toProfile:self.profileName completion:^(NSError * _Nullable error) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [downloadingAlert dismissViewControllerAnimated:YES completion:^{
                if (error) {
                    [self showSimpleAlertWithTitle:@"下载失败" message:error.localizedDescription];
                } else {
                    UIAlertController *successAlert = [UIAlertController alertControllerWithTitle:@"下载成功"
                                                                                          message:[NSString stringWithFormat:@"%@ 已成功安装。", item.displayName]
                                                                                   preferredStyle:UIAlertControllerStyleAlert];
                    [successAlert addAction:[UIAlertAction actionWithTitle:@"好" style:UIAlertActionStyleDefault handler:^(UIAlertAction * _Nonnull action) {
                        [self.modeSwitcher setSelectedSegmentIndex:0];
                        [self modeChanged:self.modeSwitcher];
                        [self refreshLocalShadersList];
                    }]];
                    [self presentViewController:successAlert animated:YES completion:nil];
                }
            }];
        });
    }];
}

- (void)showSimpleAlertWithTitle:(NSString *)title message:(NSString *)message {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:title message:message preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"好" style:UIAlertActionStyleDefault handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    if (self.currentMode == ShadersManagerModeOnline) {
        [tableView deselectRowAtIndexPath:indexPath animated:YES];
    }
}

// 禁用光影切换功能 - 光影管理只用于查看和删除
- (void)shaderCellDidTapToggle:(UITableViewCell *)cell {
    // 功能已禁用
}

- (void)shaderCellDidTapOpenLink:(UITableViewCell *)cell {
    NSIndexPath *indexPath = [self.tableView indexPathForCell:cell];
    if (!indexPath) return;

    ShaderItem *shaderItem = nil;
    if (self.currentMode == ShadersManagerModeLocal) {
        shaderItem = self.filteredLocalShaders[indexPath.row];
    } else {
        NSDictionary *shaderData = self.onlineSearchResults[indexPath.row];
        shaderItem = [[ShaderItem alloc] initWithOnlineData:shaderData];
    }

    if (shaderItem.onlineID && shaderItem.onlineID.length > 0) {
        NSString *urlString = [NSString stringWithFormat:@"https://modrinth.com/shader/%@", shaderItem.onlineID];
        NSURL *url = [NSURL URLWithString:urlString];
        if (url) {
            [[UIApplication sharedApplication] openURL:url options:@{} completionHandler:nil];
        }
    } else {
        UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"链接不可用" message:@"该光影没有可用的在线链接。" preferredStyle:UIAlertControllerStyleAlert];
        [alert addAction:[UIAlertAction actionWithTitle:@"好" style:UIAlertActionStyleDefault handler:nil]];
        [self presentViewController:alert animated:YES completion:nil];
    }
}

@end
