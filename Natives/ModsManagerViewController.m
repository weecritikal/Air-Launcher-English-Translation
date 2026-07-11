#import "ModsManagerViewController.h"
#import "ModTableViewCell.h"
#import "ModService.h"
#import "ModItem.h"
#import "installer/modpack/ModrinthAPI.h"
#import "ModUpdateViewController.h"
#import "PLProfiles.h"
#import "LauncherPreferences.h"
#import "BackgroundManager.h"

@interface ModsManagerViewController () <UITableViewDataSource, UITableViewDelegate, ModTableViewCellDelegate, UISearchBarDelegate, ModVersionViewControllerDelegate, UIDocumentPickerDelegate>

@property (nonatomic, strong) UISearchBar *searchBar;
@property (nonatomic, strong) UITableView *tableView;
@property (nonatomic, strong) UIActivityIndicatorView *activityIndicator;
@property (nonatomic, strong) UILabel *emptyLabel;
@property (nonatomic, strong) UIBarButtonItem *refreshButton;
@property (nonatomic, strong) UIBarButtonItem *checkUpdateButton;
@property (nonatomic, strong) UIBarButtonItem *importButton;
@property (nonatomic, strong) NSMutableArray<ModItem *> *localMods;
@property (nonatomic, strong) NSMutableArray<ModItem *> *filteredLocalMods;

@end

@implementation ModsManagerViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"管理 Mod";
    self.view.backgroundColor = [UIColor systemBackgroundColor];
    // 适配自定义启动器背景：透明化当前 VC，让全局背景图/毛玻璃透出
    [[BackgroundManager sharedManager] makeViewControllerTransparent:self];
    self.currentMode = ModsManagerModeLocal; // 始终使用本地模式（在线下载入口已移至下载界面）
    self.localMods = [NSMutableArray array];
    self.filteredLocalMods = [NSMutableArray array];
    self.onlineSearchResults = [NSMutableArray array];
    [self setupUI];
    // 透明化 tableView 背景，避免遮挡全局背景
    self.tableView.backgroundColor = [UIColor clearColor];
    self.tableView.backgroundView = nil;
    [self updateUIForCurrentMode];
    [self refreshLocalModsList];

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

- (void)setupUI {
    self.searchBar = [[UISearchBar alloc] initWithFrame:CGRectZero];
    self.searchBar.translatesAutoresizingMaskIntoConstraints = NO;
    self.searchBar.delegate = self;
    self.searchBar.placeholder = @"搜索本地 Mod...";
    [self.view addSubview:self.searchBar];

    self.tableView = [[UITableView alloc] initWithFrame:CGRectZero style:UITableViewStylePlain];
    self.tableView.translatesAutoresizingMaskIntoConstraints = NO;
    [self.tableView registerClass:[ModTableViewCell class] forCellReuseIdentifier:@"ModCell"];
    self.tableView.dataSource = self;
    self.tableView.delegate = self;
    self.tableView.rowHeight = 50;
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

    UIImage *checkImage = [UIImage systemImageNamed:@"arrow.triangle.2.circlepath"];
    self.checkUpdateButton = [[UIBarButtonItem alloc] initWithImage:checkImage style:UIBarButtonItemStylePlain target:self action:@selector(checkForUpdates)];
    self.checkUpdateButton.accessibilityLabel = @"检查更新";

    UIImage *importImage = [UIImage systemImageNamed:@"square.and.arrow.down"] ?: [UIImage systemImageNamed:@"plus"];
    self.importButton = [[UIBarButtonItem alloc] initWithImage:importImage style:UIBarButtonItemStylePlain target:self action:@selector(importModTapped)];
    self.importButton.accessibilityLabel = @"导入 Mod";

    [self updateNavigationButtons];

    [NSLayoutConstraint activateConstraints:@[
        [self.searchBar.topAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.topAnchor constant:8],
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

- (void)updateUIForCurrentMode {
    self.searchBar.placeholder = @"搜索本地 Mod...";
    self.emptyLabel.text = @"未发现 Mod";
    self.emptyLabel.hidden = self.localMods.count > 0;
    self.tableView.refreshControl.enabled = YES;
    [self updateNavigationButtons];
    [self.tableView reloadData];
}

- (void)updateNavigationButtons {
    UIBarButtonItem *closeButton = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemDone target:self action:@selector(closeTapped)];
    // rightBarButtonItems 从右到左显示：导入、刷新、检查更新
    self.navigationItem.rightBarButtonItems = @[self.importButton, self.refreshButton, self.checkUpdateButton];
    self.navigationItem.leftBarButtonItem = closeButton;
}

- (void)closeTapped {
    // 兼容两种容器：
    // - push 进 UINavigationController（卡片式布局/版本管理跳转）：pop 回上一级
    // - present 弹窗（旧调用路径）：dismiss
    if (self.navigationController && self.navigationController.viewControllers.firstObject != self) {
        [self.navigationController popViewControllerAnimated:YES];
    } else {
        [self dismissViewControllerAnimated:YES completion:nil];
    }
}

#pragma mark - Import Mod

- (void)importModTapped {
    // 确保目录存在
    NSError *dirError = nil;
    NSString *modsDir = [[ModService sharedService] ensureModsFolderForProfile:nil error:&dirError];
    if (!modsDir) {
        [self showSimpleAlertWithTitle:@"无法导入" message:dirError.localizedDescription ?: @"无法确定 mods 目录"];
        return;
    }

    // 弹出文件选择器，允许 jar（Forge/NeoForge/Fabric/Quilt 都用 jar）
    UIDocumentPickerViewController *picker = [[UIDocumentPickerViewController alloc] initWithDocumentTypes:@[@"com.sun.java.jar", @"public.item"] inMode:UIDocumentPickerModeImport];
    picker.allowsMultipleSelection = YES;
    picker.delegate = self;
    picker.title = @"选择 Mod 文件";
    [self presentViewController:picker animated:YES completion:nil];
}

- (void)documentPicker:(UIDocumentPickerViewController *)controller didPickDocumentsAtURLs:(NSArray<NSURL *> *)urls {
    if (urls.count == 0) return;

    NSError *dirError = nil;
    NSString *modsDir = [[ModService sharedService] ensureModsFolderForProfile:nil error:&dirError];
    if (!modsDir) {
        [self showSimpleAlertWithTitle:@"导入失败" message:dirError.localizedDescription ?: @"无法确定 mods 目录"];
        return;
    }

    NSFileManager *fm = [NSFileManager defaultManager];
    NSInteger successCount = 0;
    NSMutableArray<NSString *> *failedFiles = [NSMutableArray array];

    for (NSURL *url in urls) {
        // 开始访问安全资源
        BOOL accessing = [url startAccessingSecurityScopedResource];
        @try {
            NSString *fileName = url.lastPathComponent;
            NSString *destPath = [modsDir stringByAppendingPathComponent:fileName];

            // 同名文件处理
            if ([fm fileExistsAtPath:destPath]) {
                NSString *baseName = [fileName stringByDeletingPathExtension];
                NSString *ext = [fileName pathExtension];
                destPath = [modsDir stringByAppendingPathComponent:[NSString stringWithFormat:@"%@_copy.%@", baseName, ext]];
            }

            NSError *copyError = nil;
            [fm copyItemAtPath:url.path toPath:destPath error:&copyError];
            if (copyError) {
                [failedFiles addObject:[NSString stringWithFormat:@"%@: %@", fileName, copyError.localizedDescription]];
            } else {
                successCount++;
            }
        } @finally {
            if (accessing) [url stopAccessingSecurityScopedResource];
        }
    }

    // 刷新列表
    [self refreshLocalModsList];

    if (failedFiles.count > 0) {
        [self showSimpleAlertWithTitle:[NSString stringWithFormat:@"导入完成（%ld 成功，%ld 失败）", (long)successCount, (long)failedFiles.count]
                               message:[failedFiles componentsJoinedByString:@"\n"]];
    } else {
        NSLog(@"[ModsManager] 成功导入 %ld 个 Mod", (long)successCount);
    }
}



#pragma mark - Check for Updates

- (void)checkForUpdates {
    // 获取当前 profile 的本地 Mod 列表
    NSMutableArray<ModItem *> *mods = [self.localMods mutableCopy];
    if (mods.count == 0) {
        [self showSimpleAlertWithTitle:@"提示" message:@"当前没有本地 Mod，无法检查更新。"];
        return;
    }

    // 从当前 profile 的 lastVersionId 解析 gameVersion 和 loader
    NSString *lastVersionId = PLProfiles.current.selectedProfile[@"lastVersionId"];
    if (!lastVersionId || lastVersionId.length == 0) {
        [self showSimpleAlertWithTitle:@"提示" message:@"无法获取当前版本信息。"];
        return;
    }

    NSString *gameVersion = nil;
    NSString *loader = nil;
    NSArray<NSString *> *loaders = @[@"forge", @"fabric", @"neoforge", @"quilt"];
    for (NSString *name in loaders) {
        NSString *delimiter = [NSString stringWithFormat:@"-%@-", name];
        NSRange range = [lastVersionId rangeOfString:delimiter];
        if (range.location != NSNotFound) {
            gameVersion = [lastVersionId substringToIndex:range.location];
            loader = name;
            break;
        }
    }
    if (!gameVersion) {
        // 纯 <mc> 格式，无 loader
        gameVersion = lastVersionId;
        loader = nil;
    }

    [self presentModUpdateViewControllerWithMods:mods gameVersion:gameVersion loader:loader];
}

- (void)presentModUpdateViewControllerWithMods:(NSArray *)mods gameVersion:(NSString *)gameVersion loader:(NSString *)loader {
    ModUpdateViewController *vc = [[ModUpdateViewController alloc] initWithMods:mods gameVersion:gameVersion loader:loader projectType:@"mod"];
    UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:vc];
    nav.modalPresentationStyle = UIModalPresentationFullScreen;
    [self presentViewController:nav animated:YES completion:nil];
}

#pragma mark - Data Loading

- (void)handleRefresh:(id)sender {
    [self refreshLocalModsList];
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

- (void)refreshLocalModsList {
    [self setLoading:YES];
    NSString *profile = self.profileName ?: @"default";
    [[ModService sharedService] scanModsForProfile:profile completion:^(NSArray<ModItem *> *mods) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [self.localMods removeAllObjects];
            [self.localMods addObjectsFromArray:mods];
            [self filterLocalMods];
            [self setLoading:NO];
        });
    }];
}

#pragma mark - UISearchBarDelegate

- (void)searchBar:(UISearchBar *)searchBar textDidChange:(NSString *)searchText {
    [self filterLocalMods];
}

- (void)searchBarSearchButtonClicked:(UISearchBar *)searchBar {
    [searchBar resignFirstResponder];
}

- (void)searchBarCancelButtonClicked:(UISearchBar *)searchBar {
    searchBar.text = @"";
    [searchBar resignFirstResponder];
    [self filterLocalMods];
}

- (void)filterLocalMods {
    [self.filteredLocalMods removeAllObjects];
    if (self.searchBar.text.length == 0) {
        [self.filteredLocalMods addObjectsFromArray:self.localMods];
    } else {
        NSString *searchText = [self.searchBar.text lowercaseString];
        for (ModItem *mod in self.localMods) {
            if ([mod.displayName.lowercaseString containsString:searchText] ||
                [mod.fileName.lowercaseString containsString:searchText]) {
                [self.filteredLocalMods addObject:mod];
            }
        }
    }
    self.emptyLabel.hidden = self.filteredLocalMods.count > 0;
    if (!self.emptyLabel.hidden) {
        self.emptyLabel.text = @"未找到本地 Mod";
    }
    [self.tableView reloadData];
}

#pragma mark - UITableView DataSource & Delegate

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    return self.filteredLocalMods.count;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    ModTableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"ModCell" forIndexPath:indexPath];
    cell.delegate = self;

    ModItem *mod = self.filteredLocalMods[indexPath.row];
    [cell configureWithMod:mod displayMode:ModTableViewCellDisplayModeLocal];

    return cell;
}

- (UISwipeActionsConfiguration *)tableView:(UITableView *)tableView trailingSwipeActionsConfigurationForRowAtIndexPath:(NSIndexPath *)indexPath {
    UIContextualAction *deleteAction = [UIContextualAction contextualActionWithStyle:UIContextualActionStyleDestructive title:@"删除" handler:^(UIContextualAction * _Nonnull action, __kindof UIView * _Nonnull sourceView, void (^ _Nonnull completionHandler)(BOOL)) {

        ModItem *modToDelete = self.filteredLocalMods[indexPath.row];

        UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"确认删除" message:[NSString stringWithFormat:@"确定要删除 %@ 吗？\n此操作无法撤销。", modToDelete.displayName] preferredStyle:UIAlertControllerStyleAlert];

        [alert addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:^(UIAlertAction * _Nonnull action) {
            completionHandler(NO);
        }]];

        [alert addAction:[UIAlertAction actionWithTitle:@"删除" style:UIAlertActionStyleDestructive handler:^(UIAlertAction * _Nonnull action) {
            NSError *error = nil;
            [[ModService sharedService] deleteMod:modToDelete error:&error];

            if (error) {
                NSLog(@"[ModsManager] Error deleting mod: %@", error);
                // Optionally show an alert to the user
                completionHandler(NO);
            } else {
                // Remove from data source
                NSInteger indexInFullList = [self.localMods indexOfObject:modToDelete];
                if (indexInFullList != NSNotFound) {
                    [self.localMods removeObjectAtIndex:indexInFullList];
                }
                [self.filteredLocalMods removeObjectAtIndex:indexPath.row];

                // Perform the table view update
                [tableView deleteRowsAtIndexPaths:@[indexPath] withRowAnimation:UITableViewRowAnimationAutomatic];

                completionHandler(YES);
            }
        }]];

        [self presentViewController:alert animated:YES completion:nil];
    }];

    deleteAction.backgroundColor = [UIColor systemRedColor];

    UISwipeActionsConfiguration *configuration = [UISwipeActionsConfiguration configurationWithActions:@[deleteAction]];
    configuration.performsFirstActionWithFullSwipe = YES; // Allow full swipe to delete

    return configuration;
}

#pragma mark - ModTableViewCellDelegate (Download Implementation)

- (void)modCellDidTapDownload:(UITableViewCell *)cell {
    // 在线下载入口已移除（请使用下载界面），此方法保留以实现协议
}

#pragma mark - ModVersionViewControllerDelegate

- (void)modVersionViewController:(ModVersionViewController *)viewController didSelectVersion:(ModVersion *)version {
    ModItem *itemToDownload = viewController.modItem;
    
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

- (void)startDownloadForItem:(ModItem *)item {
    // 开启悬浮球时不显示单独下载进度，仅通过悬浮球统一展示
    BOOL showProgressUI = !getPrefBool(@"general.floating_ball_enabled");
    UIAlertController *downloadingAlert = nil;
    if (showProgressUI) {
        downloadingAlert = [UIAlertController alertControllerWithTitle:@"正在下载"
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
    }

    [[ModService sharedService] downloadMod:item toProfile:self.profileName completion:^(NSError * _Nullable error) {
        dispatch_async(dispatch_get_main_queue(), ^{
            // First, dismiss the "downloading" alert
            if (downloadingAlert) {
                [downloadingAlert dismissViewControllerAnimated:YES completion:^{
                    [self showDownloadResultAlertForItem:item error:error];
                }];
            } else {
                [self showDownloadResultAlertForItem:item error:error];
            }
        });
    }];
}

- (void)showDownloadResultAlertForItem:(ModItem *)item error:(NSError *)error {
    if (error) {
        [self showSimpleAlertWithTitle:@"下载失败" message:error.localizedDescription];
    } else {
        UIAlertController *successAlert = [UIAlertController alertControllerWithTitle:@"下载成功"
                                                                              message:[NSString stringWithFormat:@"%@ 已成功安装。", item.displayName]
                                                                       preferredStyle:UIAlertControllerStyleAlert];
        [successAlert addAction:[UIAlertAction actionWithTitle:@"好" style:UIAlertActionStyleDefault handler:^(UIAlertAction * _Nonnull action) {
            // After user acknowledges, refresh local mods list
            [self refreshLocalModsList];
        }]];
        [self presentViewController:successAlert animated:YES completion:nil];
    }
}

- (void)showSimpleAlertWithTitle:(NSString *)title message:(NSString *)message {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:title message:message preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"好" style:UIAlertActionStyleDefault handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
}

- (void)modCellDidTapToggle:(UITableViewCell *)cell {
    NSIndexPath *indexPath = [self.tableView indexPathForCell:cell];
    if (!indexPath) return;

    ModItem *mod = self.filteredLocalMods[indexPath.row];

    NSError *error = nil;
    BOOL success = [[ModService sharedService] toggleEnableForMod:mod error:&error];

    if (!success) {
        NSLog(@"[ModsManager] Error toggling mod: %@", error);
        // Optionally show an alert to the user
        // Revert the switch state if the operation failed
        [(ModTableViewCell *)cell updateToggleState:mod.disabled];
    } else {
        // The service already changed the mod's state, so we just update the UI
        [(ModTableViewCell *)cell updateToggleState:mod.disabled];
    }
}

- (void)modCellDidTapOpenLink:(UITableViewCell *)cell {
    NSIndexPath *indexPath = [self.tableView indexPathForCell:cell];
    if (!indexPath) return;

    ModItem *modItem = self.filteredLocalMods[indexPath.row];

    if (modItem.onlineID && modItem.onlineID.length > 0) {
        NSString *urlString = [NSString stringWithFormat:@"https://modrinth.com/mod/%@", modItem.onlineID];
        NSURL *url = [NSURL URLWithString:urlString];
        if (url) {
            [[UIApplication sharedApplication] openURL:url options:@{} completionHandler:nil];
        }
    } else {
        // Optionally, inform the user that there's no link available
        UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"链接不可用" message:@"该 Mod 没有可用的在线链接。" preferredStyle:UIAlertControllerStyleAlert];
        [alert addAction:[UIAlertAction actionWithTitle:@"好" style:UIAlertActionStyleDefault handler:nil]];
        [self presentViewController:alert animated:YES completion:nil];
    }
}

@end
