//
//  DataPacksManagerViewController.m
//  Amethyst
//
//  数据包管理视图控制器实现，参照 ModsManagerViewController
//  使用 DataPackService 进行本地扫描与下载
//  使用 AssetVersionViewController 进行在线版本选择
//  使用 ModrinthAPI 进行在线搜索（projectType=datapack）
//  提示：iOS 上无法选择世界，下载到 <gameDir>/datapacks/，需手动移动到 saves/<世界名>/datapacks/
//

#import "DataPacksManagerViewController.h"
#import "DataPackService.h"
#import "DataPackItem.h"
#import "AssetVersionViewController.h"
#import "ModVersion.h"
#import "installer/modpack/ModrinthAPI.h"
#import "PLProfiles.h"
#import "LauncherPreferences.h"
#import "BackgroundManager.h"

@interface DataPacksManagerViewController () <UITableViewDataSource, UITableViewDelegate, UISearchBarDelegate, AssetVersionViewControllerDelegate, UIDocumentPickerDelegate>

@property (nonatomic, strong) UISegmentedControl *modeSwitcher;
@property (nonatomic, strong) UISearchBar *searchBar;
@property (nonatomic, strong) UITableView *tableView;
@property (nonatomic, strong) UIActivityIndicatorView *activityIndicator;
@property (nonatomic, strong) UILabel *emptyLabel;
@property (nonatomic, strong) UIBarButtonItem *refreshButton;
@property (nonatomic, strong) UIBarButtonItem *importButton;
@property (nonatomic, strong) UILabel *tipLabel;

@property (nonatomic, strong) NSMutableArray<DataPackItem *> *localItems;
@property (nonatomic, strong) NSMutableArray<DataPackItem *> *filteredLocalItems;
@property (nonatomic, strong, nullable) DataPackItem *pendingDownloadItem;

@end

@implementation DataPacksManagerViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"管理数据包";
    self.view.backgroundColor = [UIColor systemBackgroundColor];
    // 适配自定义启动器背景：透明化当前 VC，让全局背景图/毛玻璃透出
    [[BackgroundManager sharedManager] makeViewControllerTransparent:self];
    self.currentMode = self.initialMode;
    self.localItems = [NSMutableArray array];
    self.filteredLocalItems = [NSMutableArray array];
    self.onlineSearchResults = [NSMutableArray array];
    [self setupUI];
    // 修复"前一个页面没有及时消失"：给 view 添加毛玻璃遮挡层，
    // 防止 push 转场时透出栈底 ProfileSettingsViewController 的内容
    [[BackgroundManager sharedManager] applyEffectToView:self.view];
    // 透明化 tableView 背景与 backgroundView，避免遮挡全局背景
    self.tableView.backgroundColor = [UIColor clearColor];
    self.tableView.backgroundView = nil;
    [self updateUIForCurrentMode];
    if (self.currentMode == DataPacksManagerModeLocal) {
        [self refreshLocalList];
    }
    // 监听背景效果变化通知，背景切换时重新应用透明效果
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(reapplyBackgroundEffect)
                                                 name:@"BackgroundUIEffectChanged"
                                               object:nil];
}

/// 背景效果变化时重新应用透明化处理，确保背景切换后仍透出全局背景
- (void)reapplyBackgroundEffect {
    // 重新透明化当前 VC
    [[BackgroundManager sharedManager] makeViewControllerTransparent:self];
    // 重新应用 view 毛玻璃遮挡层
    [[BackgroundManager sharedManager] applyEffectToView:self.view];
    // 重新设置 tableView 背景为透明，确保背景效果切换后仍透出全局背景
    self.tableView.backgroundColor = [UIColor clearColor];
    self.tableView.backgroundView = nil;
    // 重新应用 searchBar 透明化效果（毛玻璃↔半透明切换后输入框背景需刷新）
    [[BackgroundManager sharedManager] applyEffectToSearchBar:self.searchBar];
    // 重新加载 cell，让每个 cell 重新应用 applyEffectToCell:（毛玻璃/半透明）
    [self.tableView reloadData];
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    // 修复"前一个页面没有及时消失"：
    // viewDidLoad 时 self.view.bounds 可能为 zero，applyEffectToView: 插入的 blurView
    // frame 为 zero，push 转场第一帧无法遮挡栈底 VersionManagerViewController 的卡片。
    // 在 viewWillAppear 中重新应用（此时 bounds 已正确），确保转场前遮挡到位。
    [[BackgroundManager sharedManager] applyEffectToView:self.view];
    self.tableView.backgroundColor = [UIColor clearColor];
    self.tableView.backgroundView = nil;
}

- (void)dealloc {
    // 移除背景效果变化通知的观察者，避免 dealloc 后收到通知导致野指针崩溃
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

- (void)setupUI {
    self.modeSwitcher = [[UISegmentedControl alloc] initWithItems:@[@"本地数据包", @"在线搜索 (Modrinth)"]];
    self.modeSwitcher.translatesAutoresizingMaskIntoConstraints = NO;
    self.modeSwitcher.selectedSegmentIndex = self.currentMode;
    [self.modeSwitcher addTarget:self action:@selector(modeChanged:) forControlEvents:UIControlEventValueChanged];
    [self.view addSubview:self.modeSwitcher];

    self.searchBar = [[UISearchBar alloc] initWithFrame:CGRectZero];
    self.searchBar.translatesAutoresizingMaskIntoConstraints = NO;
    self.searchBar.delegate = self;
    self.searchBar.placeholder = @"搜索本地数据包...";
    // 适配自定义启动器背景：透明化 searchBar 默认不透明背景，让全局背景图/毛玻璃透出
    [[BackgroundManager sharedManager] applyEffectToSearchBar:self.searchBar];
    [self.view addSubview:self.searchBar];

    // 提示标签：iOS 上需手动移动数据包到对应世界目录
    self.tipLabel = [[UILabel alloc] initWithFrame:CGRectZero];
    self.tipLabel.translatesAutoresizingMaskIntoConstraints = NO;
    self.tipLabel.text = @"提示：数据包需放在 saves/<世界名>/datapacks/ 才生效。下载的数据包默认放在通用 datapacks 目录，请手动移动到对应世界目录。";
    self.tipLabel.font = [UIFont systemFontOfSize:11];
    self.tipLabel.textColor = [UIColor systemOrangeColor];
    self.tipLabel.numberOfLines = 0;
    self.tipLabel.textAlignment = NSTextAlignmentCenter;
    self.tipLabel.backgroundColor = [UIColor secondarySystemBackgroundColor];
    self.tipLabel.layer.cornerRadius = 6;
    self.tipLabel.clipsToBounds = YES;
    [self.view addSubview:self.tipLabel];

    self.tableView = [[UITableView alloc] initWithFrame:CGRectZero style:UITableViewStylePlain];
    self.tableView.translatesAutoresizingMaskIntoConstraints = NO;
    [self.tableView registerClass:[UITableViewCell class] forCellReuseIdentifier:@"DataPackCell"];
    self.tableView.dataSource = self;
    self.tableView.delegate = self;
    self.tableView.rowHeight = 64;
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
    self.emptyLabel.numberOfLines = 0;
    self.emptyLabel.hidden = YES;
    [self.view addSubview:self.emptyLabel];

    self.refreshButton = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemRefresh target:self action:@selector(handleRefresh:)];
    UIImage *importImage = [UIImage systemImageNamed:@"square.and.arrow.down"] ?: [UIImage systemImageNamed:@"plus"];
    self.importButton = [[UIBarButtonItem alloc] initWithImage:importImage style:UIBarButtonItemStylePlain target:self action:@selector(importTapped)];
    self.importButton.accessibilityLabel = @"导入数据包";

    [self updateNavigationButtons];

    [NSLayoutConstraint activateConstraints:@[
        [self.modeSwitcher.topAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.topAnchor constant:8],
        [self.modeSwitcher.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor constant:16],
        [self.modeSwitcher.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor constant:-16],

        [self.searchBar.topAnchor constraintEqualToAnchor:self.modeSwitcher.bottomAnchor constant:8],
        [self.searchBar.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [self.searchBar.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],

        [self.tipLabel.topAnchor constraintEqualToAnchor:self.searchBar.bottomAnchor constant:4],
        [self.tipLabel.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor constant:8],
        [self.tipLabel.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor constant:-8],

        [self.tableView.topAnchor constraintEqualToAnchor:self.tipLabel.bottomAnchor constant:4],
        [self.tableView.bottomAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.bottomAnchor],
        [self.tableView.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [self.tableView.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],

        [self.activityIndicator.centerXAnchor constraintEqualToAnchor:self.tableView.centerXAnchor],
        [self.activityIndicator.centerYAnchor constraintEqualToAnchor:self.tableView.centerYAnchor],

        [self.emptyLabel.centerXAnchor constraintEqualToAnchor:self.tableView.centerXAnchor],
        [self.emptyLabel.centerYAnchor constraintEqualToAnchor:self.tableView.centerYAnchor],
        [self.emptyLabel.leadingAnchor constraintGreaterThanOrEqualToAnchor:self.view.leadingAnchor constant:16],
        [self.emptyLabel.trailingAnchor constraintLessThanOrEqualToAnchor:self.view.trailingAnchor constant:-16],
    ]];
}

- (void)modeChanged:(UISegmentedControl *)sender {
    self.currentMode = (DataPacksManagerMode)sender.selectedSegmentIndex;
    [self.searchBar resignFirstResponder];
    self.searchBar.text = @"";
    [self.onlineSearchResults removeAllObjects];
    [self filterLocalItems];
    [self.tableView reloadData];
    [self updateUIForCurrentMode];
}

- (void)updateUIForCurrentMode {
    if (self.currentMode == DataPacksManagerModeLocal) {
        self.searchBar.placeholder = @"搜索本地数据包...";
        self.emptyLabel.text = @"未发现数据包";
        self.emptyLabel.hidden = self.localItems.count > 0;
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
    UIBarButtonItem *closeButton = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemDone target:self action:@selector(closeTapped)];
    if (self.currentMode == DataPacksManagerModeLocal) {
        self.navigationItem.rightBarButtonItems = @[self.importButton, self.refreshButton];
    } else {
        self.navigationItem.rightBarButtonItems = nil;
    }
    self.navigationItem.leftBarButtonItem = closeButton;
}

- (void)closeTapped {
    // 兼容两种容器：
    // - push 进 UINavigationController（ProfileSettingsViewController 跳转）：pop 回上一级
    // - present 弹窗（旧调用路径）：dismiss
    if (self.navigationController && self.navigationController.viewControllers.firstObject != self) {
        [self.navigationController popViewControllerAnimated:YES];
    } else {
        [self dismissViewControllerAnimated:YES completion:nil];
    }
}

#pragma mark - 导入数据包

- (void)importTapped {
    NSError *dirError = nil;
    NSString *dir = [[DataPackService sharedService] ensureDataPacksFolderForProfile:self.profileName error:&dirError];
    if (!dir) {
        [self showSimpleAlertWithTitle:@"无法导入" message:dirError.localizedDescription ?: @"无法确定 datapacks 目录"];
        return;
    }

    UIDocumentPickerViewController *picker = [[UIDocumentPickerViewController alloc] initWithDocumentTypes:@[@"public.zip", @"public.item"] inMode:UIDocumentPickerModeImport];
    picker.allowsMultipleSelection = YES;
    picker.delegate = self;
    picker.title = @"选择数据包文件";
    [self presentViewController:picker animated:YES completion:nil];
}

- (void)documentPicker:(UIDocumentPickerViewController *)controller didPickDocumentsAtURLs:(NSArray<NSURL *> *)urls {
    if (urls.count == 0) return;

    NSError *dirError = nil;
    NSString *dir = [[DataPackService sharedService] ensureDataPacksFolderForProfile:self.profileName error:&dirError];
    if (!dir) {
        [self showSimpleAlertWithTitle:@"导入失败" message:dirError.localizedDescription ?: @"无法确定 datapacks 目录"];
        return;
    }

    NSFileManager *fm = [NSFileManager defaultManager];
    NSInteger successCount = 0;
    NSMutableArray<NSString *> *failedFiles = [NSMutableArray array];

    for (NSURL *url in urls) {
        BOOL accessing = [url startAccessingSecurityScopedResource];
        @try {
            NSString *fileName = url.lastPathComponent;
            NSString *destPath = [dir stringByAppendingPathComponent:fileName];
            if ([fm fileExistsAtPath:destPath]) {
                NSString *baseName = [fileName stringByDeletingPathExtension];
                NSString *ext = [fileName pathExtension];
                destPath = [dir stringByAppendingPathComponent:[NSString stringWithFormat:@"%@_copy.%@", baseName, ext]];
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

    [self refreshLocalList];

    if (failedFiles.count > 0) {
        [self showSimpleAlertWithTitle:[NSString stringWithFormat:@"导入完成（%ld 成功，%ld 失败）", (long)successCount, (long)failedFiles.count]
                               message:[failedFiles componentsJoinedByString:@"\n"]];
    }
}

#pragma mark - 数据加载

- (void)handleRefresh:(id)sender {
    if (self.currentMode == DataPacksManagerModeLocal) {
        [self refreshLocalList];
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

- (void)refreshLocalList {
    if (self.currentMode != DataPacksManagerModeLocal) return;

    [self setLoading:YES];
    NSString *profile = self.profileName ?: @"default";
    [[DataPackService sharedService] scanDataPacksForProfile:profile completion:^(NSArray<DataPackItem *> *items) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [self.localItems removeAllObjects];
            [self.localItems addObjectsFromArray:items];
            [self filterLocalItems];
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

    NSString *gameVersion = nil;
    [self resolveCurrentGameVersion:&gameVersion];

    NSMutableDictionary *filters = [NSMutableDictionary dictionary];
    filters[@"name"] = searchText;
    filters[@"projectType"] = @"datapack";
    if (gameVersion.length > 0) {
        filters[@"mcVersion"] = gameVersion;
    }

    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSMutableArray *results = [[ModrinthAPI sharedInstance] searchModWithFilters:filters previousPageResult:nil];

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
    });
}

- (void)resolveCurrentGameVersion:(NSString **)outGameVersion {
    if (outGameVersion) *outGameVersion = nil;
    NSDictionary *selectedProfile = PLProfiles.current.selectedProfile;
    NSString *lastVersionId = selectedProfile[@"lastVersionId"];
    if (![lastVersionId isKindOfClass:[NSString class]] || lastVersionId.length == 0) return;

    NSArray<NSString *> *loaders = @[@"forge", @"fabric", @"neoforge", @"quilt"];
    for (NSString *name in loaders) {
        NSString *delimiter = [NSString stringWithFormat:@"-%@-", name];
        NSRange range = [lastVersionId rangeOfString:delimiter];
        if (range.location != NSNotFound) {
            if (outGameVersion) *outGameVersion = [lastVersionId substringToIndex:range.location];
            return;
        }
    }
    if (outGameVersion) *outGameVersion = lastVersionId;
}

#pragma mark - UISearchBarDelegate

- (void)searchBar:(UISearchBar *)searchBar textDidChange:(NSString *)searchText {
    if (self.currentMode == DataPacksManagerModeLocal) {
        [self filterLocalItems];
    }
}

- (void)searchBarSearchButtonClicked:(UISearchBar *)searchBar {
    [searchBar resignFirstResponder];
    if (self.currentMode == DataPacksManagerModeOnline) {
        [self performOnlineSearch];
    }
}

- (void)searchBarCancelButtonClicked:(UISearchBar *)searchBar {
    searchBar.text = @"";
    [searchBar resignFirstResponder];
    if (self.currentMode == DataPacksManagerModeLocal) {
        [self filterLocalItems];
    } else {
        [self.onlineSearchResults removeAllObjects];
        [self.tableView reloadData];
        [self updateUIForCurrentMode];
    }
}

- (void)filterLocalItems {
    [self.filteredLocalItems removeAllObjects];
    if (self.searchBar.text.length == 0) {
        [self.filteredLocalItems addObjectsFromArray:self.localItems];
    } else {
        NSString *searchText = [self.searchBar.text lowercaseString];
        for (DataPackItem *item in self.localItems) {
            if ([item.displayName.lowercaseString containsString:searchText] ||
                [item.fileName.lowercaseString containsString:searchText]) {
                [self.filteredLocalItems addObject:item];
            }
        }
    }
    self.emptyLabel.hidden = self.filteredLocalItems.count > 0;
    if (!self.emptyLabel.hidden) {
        self.emptyLabel.text = @"未找到本地数据包";
    }
    [self.tableView reloadData];
}

#pragma mark - UITableView DataSource & Delegate

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    return self.currentMode == DataPacksManagerModeLocal ? self.filteredLocalItems.count : self.onlineSearchResults.count;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"DataPackCell" forIndexPath:indexPath];
    cell.accessoryView = nil;
    cell.accessoryType = UITableViewCellAccessoryNone;
    cell.imageView.image = [UIImage systemImageNamed:@"shippingbox.fill"];
    cell.imageView.tintColor = [UIColor systemPurpleColor];

    if (self.currentMode == DataPacksManagerModeLocal) {
        DataPackItem *item = self.filteredLocalItems[indexPath.row];
        cell.textLabel.text = item.displayName ?: item.fileName;
        NSMutableArray<NSString *> *parts = [NSMutableArray array];
        if (item.packFormat) {
            [parts addObject:[NSString stringWithFormat:@"格式 %@", item.packFormat]];
        }
        if (item.dataPackDescription.length > 0) {
            [parts addObject:item.dataPackDescription];
        }
        cell.detailTextLabel.text = parts.count > 0 ? [parts componentsJoinedByString:@" · "] : item.fileName;
        cell.detailTextLabel.textColor = [UIColor secondaryLabelColor];
        cell.contentView.alpha = item.disabled ? 0.5 : 1.0;

        UISwitch *switchView = [[UISwitch alloc] init];
        switchView.tag = indexPath.row;
        [switchView setOn:!item.disabled animated:NO];
        [switchView addTarget:self action:@selector(toggleSwitchChanged:) forControlEvents:UIControlEventValueChanged];
        cell.accessoryView = switchView;
    } else {
        NSDictionary *data = self.onlineSearchResults[indexPath.row];
        cell.textLabel.text = data[@"title"] ?: @"";
        cell.detailTextLabel.text = data[@"description"] ?: @"";
        cell.detailTextLabel.textColor = [UIColor secondaryLabelColor];

        UIButton *downloadButton = [UIButton buttonWithType:UIButtonTypeSystem];
        [downloadButton setTitle:@"下载" forState:UIControlStateNormal];
        downloadButton.titleLabel.font = [UIFont boldSystemFontOfSize:13];
        downloadButton.tag = indexPath.row;
        [downloadButton addTarget:self action:@selector(downloadButtonTapped:) forControlEvents:UIControlEventTouchUpInside];
        downloadButton.contentEdgeInsets = UIEdgeInsetsMake(4, 8, 4, 8);
        cell.accessoryView = downloadButton;
    }
    // 适配自定义启动器背景：为 cell 注入毛玻璃/半透明效果
    [[BackgroundManager sharedManager] applyEffectToCell:cell];
    return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    if (self.currentMode == DataPacksManagerModeOnline) {
        [self startVersionSelectionForOnlineRow:indexPath.row];
    }
}

- (UISwipeActionsConfiguration *)tableView:(UITableView *)tableView trailingSwipeActionsConfigurationForRowAtIndexPath:(NSIndexPath *)indexPath {
    if (self.currentMode != DataPacksManagerModeLocal) {
        return nil;
    }

    __weak typeof(self) weakSelf = self;
    UIContextualAction *deleteAction = [UIContextualAction contextualActionWithStyle:UIContextualActionStyleDestructive title:@"删除" handler:^(UIContextualAction * _Nonnull action, __kindof UIView * _Nonnull sourceView, void (^ _Nonnull completionHandler)(BOOL)) {
        DataPackItem *item = weakSelf.filteredLocalItems[indexPath.row];
        UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"确认删除"
                                                                        message:[NSString stringWithFormat:@"确定要删除 %@ 吗？", item.displayName ?: item.fileName]
                                                                 preferredStyle:UIAlertControllerStyleAlert];
        [alert addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:^(UIAlertAction * _Nonnull action) {
            completionHandler(NO);
        }]];
        [alert addAction:[UIAlertAction actionWithTitle:@"删除" style:UIAlertActionStyleDestructive handler:^(UIAlertAction * _Nonnull action) {
            NSError *error = nil;
            if (![[DataPackService sharedService] deleteDataPack:item error:&error]) {
                [weakSelf showSimpleAlertWithTitle:@"删除失败" message:error.localizedDescription];
                completionHandler(NO);
                return;
            }
            NSInteger indexInFull = [weakSelf.localItems indexOfObject:item];
            if (indexInFull != NSNotFound) {
                [weakSelf.localItems removeObjectAtIndex:indexInFull];
            }
            [weakSelf.filteredLocalItems removeObjectAtIndex:indexPath.row];
            [tableView deleteRowsAtIndexPaths:@[indexPath] withRowAnimation:UITableViewRowAnimationAutomatic];
            completionHandler(YES);
        }]];
        [weakSelf presentViewController:alert animated:YES completion:nil];
    }];
    deleteAction.backgroundColor = [UIColor systemRedColor];

    return [UISwipeActionsConfiguration configurationWithActions:@[deleteAction]];
}

#pragma mark - 本地启用/禁用切换

- (void)toggleSwitchChanged:(UISwitch *)sender {
    NSInteger row = sender.tag;
    if (row >= (NSInteger)self.filteredLocalItems.count) return;
    DataPackItem *item = self.filteredLocalItems[row];
    NSError *error = nil;
    if (![[DataPackService sharedService] toggleEnableForDataPack:item error:&error]) {
        sender.on = !sender.on;
        [self showSimpleAlertWithTitle:@"操作失败" message:error.localizedDescription];
    } else {
        NSIndexPath *ip = [NSIndexPath indexPathForRow:row inSection:0];
        UITableViewCell *cell = [self.tableView cellForRowAtIndexPath:ip];
        cell.contentView.alpha = item.disabled ? 0.5 : 1.0;
    }
}

#pragma mark - 在线下载

- (void)downloadButtonTapped:(UIButton *)sender {
    [self startVersionSelectionForOnlineRow:sender.tag];
}

- (void)startVersionSelectionForOnlineRow:(NSInteger)row {
    if (row >= (NSInteger)self.onlineSearchResults.count) return;
    NSDictionary *data = self.onlineSearchResults[row];

    DataPackItem *item = [[DataPackItem alloc] initWithOnlineData:data];
    self.pendingDownloadItem = item;

    AssetVersionViewController *vc = [[AssetVersionViewController alloc] init];
    vc.assetType = AssetVersionTypeDataPack;
    vc.projectID = item.onlineID;
    vc.projectDisplayName = item.displayName;
    vc.delegate = self;
    [self.navigationController pushViewController:vc animated:YES];
}

#pragma mark - AssetVersionViewControllerDelegate

- (void)assetVersionViewController:(AssetVersionViewController *)viewController didSelectVersion:(ModVersion *)version {
    DataPackItem *item = self.pendingDownloadItem;
    if (!item) return;

    NSDictionary *primaryFile = version.primaryFile;
    if (!primaryFile || ![primaryFile[@"url"] isKindOfClass:[NSString class]]) {
        [self showSimpleAlertWithTitle:@"错误" message:@"未找到有效的下载链接。"];
        return;
    }
    item.selectedVersionDownloadURL = primaryFile[@"url"];
    item.fileName = primaryFile[@"filename"];

    [self startDownloadForItem:item];
}

- (void)startDownloadForItem:(DataPackItem *)item {
    // 始终显示单独下载进度（悬浮球已移除）
    BOOL showProgressUI = YES;
    UIAlertController *downloadingAlert = nil;
    if (showProgressUI) {
        downloadingAlert = [UIAlertController alertControllerWithTitle:@"正在下载"
                                                                                  message:[NSString stringWithFormat:@"%@...\n下载完成后请手动移动到对应世界目录。", item.displayName]
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

    [[DataPackService sharedService] downloadDataPack:item
                                            toProfile:self.profileName
                                             progress:nil
                                           completion:^(BOOL success, NSError * _Nullable error) {
        dispatch_async(dispatch_get_main_queue(), ^{
            void (^showResult)(void) = ^{
                if (!success || error) {
                    [self showSimpleAlertWithTitle:@"下载失败" message:error.localizedDescription ?: @"未知错误"];
                } else {
                    UIAlertController *successAlert = [UIAlertController alertControllerWithTitle:@"下载成功"
                                                                                          message:[NSString stringWithFormat:@"%@ 已下载到通用 datapacks 目录。\n请手动移动到对应世界目录（saves/<世界名>/datapacks/）。", item.displayName]
                                                                                   preferredStyle:UIAlertControllerStyleAlert];
                    [successAlert addAction:[UIAlertAction actionWithTitle:@"好" style:UIAlertActionStyleDefault handler:^(UIAlertAction * _Nonnull action) {
                        self.pendingDownloadItem = nil;
                        [self.modeSwitcher setSelectedSegmentIndex:0];
                        [self modeChanged:self.modeSwitcher];
                        [self refreshLocalList];
                    }]];
                    [self presentViewController:successAlert animated:YES completion:nil];
                }
            };
            if (downloadingAlert) {
                [downloadingAlert dismissViewControllerAnimated:YES completion:showResult];
            } else {
                showResult();
            }
        });
    }];
}

#pragma mark - 工具方法

- (void)showSimpleAlertWithTitle:(NSString *)title message:(NSString *)message {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:title message:message preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"好" style:UIAlertActionStyleDefault handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
}

@end
