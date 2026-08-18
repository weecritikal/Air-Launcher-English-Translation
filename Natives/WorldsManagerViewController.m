//
//  WorldsManagerViewController.m
//  Amethyst
//
//  世界存档管理视图控制器实现，参照 ModsManagerViewController
//  使用 WorldService 进行本地扫描与下载（含健壮解压）
//  Uses AssetVersionViewController for picking an online version
//  使用 ModrinthAPI 进行在线搜索（projectType=world）
//  支持通过 UIDocumentPicker 导入本地世界 zip
//

#import "WorldsManagerViewController.h"
#import "WorldService.h"
#import "WorldItem.h"
#import "AssetVersionViewController.h"
#import "ModVersion.h"
#import "installer/modpack/ModrinthAPI.h"
#import "PLProfiles.h"
#import "LauncherPreferences.h"
#import "BackgroundManager.h"

@interface WorldsManagerViewController () <UITableViewDataSource, UITableViewDelegate, UISearchBarDelegate, AssetVersionViewControllerDelegate, UIDocumentPickerDelegate>

@property (nonatomic, strong) UISegmentedControl *modeSwitcher;
@property (nonatomic, strong) UISearchBar *searchBar;
@property (nonatomic, strong) UITableView *tableView;
@property (nonatomic, strong) UIActivityIndicatorView *activityIndicator;
@property (nonatomic, strong) UILabel *emptyLabel;
@property (nonatomic, strong) UIBarButtonItem *refreshButton;
@property (nonatomic, strong) UIBarButtonItem *importButton;

@property (nonatomic, strong) NSMutableArray<WorldItem *> *localItems;
@property (nonatomic, strong) NSMutableArray<WorldItem *> *filteredLocalItems;
@property (nonatomic, strong, nullable) WorldItem *pendingDownloadItem;

@end

@implementation WorldsManagerViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"Manage worlds";
    self.view.backgroundColor = [UIColor systemBackgroundColor];
    // Adapt to the custom launcher background: make this VC transparent so the global background image/blur shows through
    [[BackgroundManager sharedManager] makeViewControllerTransparent:self];
    self.currentMode = self.initialMode;
    self.localItems = [NSMutableArray array];
    self.filteredLocalItems = [NSMutableArray array];
    self.onlineSearchResults = [NSMutableArray array];
    [self setupUI];
    // Fix for "the previous page does not disappear in time": add a frosted-glass cover layer to the view
    // so the ProfileSettingsViewController underneath does not show through during the push transition
    [[BackgroundManager sharedManager] applyEffectToView:self.view];
    // Make the tableView background and backgroundView transparent so they do not hide the global background
    self.tableView.backgroundColor = [UIColor clearColor];
    self.tableView.backgroundView = nil;
    [self updateUIForCurrentMode];
    if (self.currentMode == WorldsManagerModeLocal) {
        [self refreshLocalList];
    }
    // Listen for background effect changes so transparency is re-applied when the background is switched
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(reapplyBackgroundEffect)
                                                 name:@"BackgroundUIEffectChanged"
                                               object:nil];
}

/// Re-apply transparency when the background effect changes, so the global background still shows through
- (void)reapplyBackgroundEffect {
    // Make this VC transparent again
    [[BackgroundManager sharedManager] makeViewControllerTransparent:self];
    // Re-apply the frosted-glass cover layer on the view
    [[BackgroundManager sharedManager] applyEffectToView:self.view];
    // Reset the tableView background to transparent so the global background still shows after an effect switch
    self.tableView.backgroundColor = [UIColor clearColor];
    self.tableView.backgroundView = nil;
    // Re-apply the searchBar transparency (the text field background needs refreshing after a frosted glass <-> translucent switch)
    [[BackgroundManager sharedManager] applyEffectToSearchBar:self.searchBar];
    // Reload the cells so each one re-applies applyEffectToCell: (frosted glass/translucent)
    [self.tableView reloadData];
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    // Fix for "the previous page does not disappear in time":
    // self.view.bounds can be zero in viewDidLoad, so the blurView inserted by applyEffectToView:
    // has a zero frame and cannot cover the VersionManagerViewController cards underneath on the first frame of the push.
    // Re-applying it in viewWillAppear (where bounds are correct) makes sure the cover is in place before the transition.
    [[BackgroundManager sharedManager] applyEffectToView:self.view];
    self.tableView.backgroundColor = [UIColor clearColor];
    self.tableView.backgroundView = nil;
}

- (void)dealloc {
    // Remove the background-effect notification observer so a notification after dealloc cannot crash on a dangling pointer
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

- (void)setupUI {
    self.modeSwitcher = [[UISegmentedControl alloc] initWithItems:@[@"Local worlds", @"Search online (Modrinth)"]];
    self.modeSwitcher.translatesAutoresizingMaskIntoConstraints = NO;
    self.modeSwitcher.selectedSegmentIndex = self.currentMode;
    [self.modeSwitcher addTarget:self action:@selector(modeChanged:) forControlEvents:UIControlEventValueChanged];
    [self.view addSubview:self.modeSwitcher];

    self.searchBar = [[UISearchBar alloc] initWithFrame:CGRectZero];
    self.searchBar.translatesAutoresizingMaskIntoConstraints = NO;
    self.searchBar.delegate = self;
    self.searchBar.placeholder = @"Search local worlds...";
    // Adapt to the custom launcher background: clear the searchBar's opaque default background so the global image/blur shows through
    [[BackgroundManager sharedManager] applyEffectToSearchBar:self.searchBar];
    [self.view addSubview:self.searchBar];

    self.tableView = [[UITableView alloc] initWithFrame:CGRectZero style:UITableViewStylePlain];
    self.tableView.translatesAutoresizingMaskIntoConstraints = NO;
    [self.tableView registerClass:[UITableViewCell class] forCellReuseIdentifier:@"WorldCell"];
    self.tableView.dataSource = self;
    self.tableView.delegate = self;
    self.tableView.rowHeight = 72;
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
    self.importButton.accessibilityLabel = @"Import world";

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
        [self.emptyLabel.centerYAnchor constraintEqualToAnchor:self.tableView.centerYAnchor],
        [self.emptyLabel.leadingAnchor constraintGreaterThanOrEqualToAnchor:self.view.leadingAnchor constant:16],
        [self.emptyLabel.trailingAnchor constraintLessThanOrEqualToAnchor:self.view.trailingAnchor constant:-16],
    ]];
}

- (void)modeChanged:(UISegmentedControl *)sender {
    self.currentMode = (WorldsManagerMode)sender.selectedSegmentIndex;
    [self.searchBar resignFirstResponder];
    self.searchBar.text = @"";
    [self.onlineSearchResults removeAllObjects];
    [self filterLocalItems];
    [self.tableView reloadData];
    [self updateUIForCurrentMode];
}

- (void)updateUIForCurrentMode {
    if (self.currentMode == WorldsManagerModeLocal) {
        self.searchBar.placeholder = @"Search local worlds...";
        self.emptyLabel.text = @"No world saves found";
        self.emptyLabel.hidden = self.localItems.count > 0;
    } else {
        self.searchBar.placeholder = @"Search Modrinth online...";
        self.emptyLabel.text = @"Enter a keyword to search online";
        self.emptyLabel.hidden = self.onlineSearchResults.count > 0;
    }
    self.tableView.refreshControl.enabled = YES;
    [self updateNavigationButtons];
    [self.tableView reloadData];
}

- (void)updateNavigationButtons {
    UIBarButtonItem *closeButton = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemDone target:self action:@selector(closeTapped)];
    if (self.currentMode == WorldsManagerModeLocal) {
        self.navigationItem.rightBarButtonItems = @[self.importButton, self.refreshButton];
    } else {
        self.navigationItem.rightBarButtonItems = nil;
    }
    self.navigationItem.leftBarButtonItem = closeButton;
}

- (void)closeTapped {
    // Works in both containers:
    // - pushed onto a UINavigationController (navigated from ProfileSettingsViewController): pop back
    // - presented modally (the old call path): dismiss
    if (self.navigationController && self.navigationController.viewControllers.firstObject != self) {
        [self.navigationController popViewControllerAnimated:YES];
    } else {
        [self dismissViewControllerAnimated:YES completion:nil];
    }
}

#pragma mark - 导入世界 zip

- (void)importTapped {
    NSError *dirError = nil;
    NSString *dir = [[WorldService sharedService] ensureWorldsFolderForProfile:self.profileName error:&dirError];
    if (!dir) {
        [self showSimpleAlertWithTitle:@"Cannot import" message:dirError.localizedDescription ?: @"Could not determine the saves folder"];
        return;
    }

    // 仅允许选择 zip 文件
    UIDocumentPickerViewController *picker = [[UIDocumentPickerViewController alloc] initWithDocumentTypes:@[@"public.zip", @"public.item"] inMode:UIDocumentPickerModeImport];
    picker.allowsMultipleSelection = YES;
    picker.delegate = self;
    picker.title = @"Choose world zip file";
    [self presentViewController:picker animated:YES completion:nil];
}

- (void)documentPicker:(UIDocumentPickerViewController *)controller didPickDocumentsAtURLs:(NSArray<NSURL *> *)urls {
    if (urls.count == 0) return;

    // 第一个文件先导入，后续文件依次排队（每次导入都需要解压，避免并发冲突）
    [self importNextURLFromQueue:[urls mutableCopy] index:0];
}

- (void)importNextURLFromQueue:(NSMutableArray<NSURL *> *)queue index:(NSInteger)index {
    if (index >= (NSInteger)queue.count) {
        // 全部导入完成，刷新列表
        [self refreshLocalList];
        return;
    }

    NSURL *url = queue[index];
    __weak typeof(self) weakSelf = self;

    // 显示导入中提示
    UIAlertController *importingAlert = [UIAlertController alertControllerWithTitle:@"Importing"
                                                                             message:[NSString stringWithFormat:@"%@ (%ld/%ld)...", url.lastPathComponent, (long)(index + 1), (long)queue.count]
                                                                      preferredStyle:UIAlertControllerStyleAlert];
    UIActivityIndicatorView *indicator = [[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleMedium];
    indicator.translatesAutoresizingMaskIntoConstraints = NO;
    [importingAlert.view addSubview:indicator];
    [NSLayoutConstraint activateConstraints:@[
        [indicator.centerXAnchor constraintEqualToAnchor:importingAlert.view.centerXAnchor],
        [indicator.centerYAnchor constraintEqualToAnchor:importingAlert.view.centerYAnchor constant:20]
    ]];
    [indicator startAnimating];
    [self presentViewController:importingAlert animated:YES completion:nil];

    [[WorldService sharedService] importWorldFromURL:url
                                              toProfile:self.profileName
                                               progress:nil
                                             completion:^(BOOL success, NSError * _Nullable error) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [importingAlert dismissViewControllerAnimated:YES completion:^{
                if (!success || error) {
                    [weakSelf showSimpleAlertWithTitle:@"Import failed"
                                                message:[NSString stringWithFormat:@"%@: %@", url.lastPathComponent, error.localizedDescription ?: @"Unknown error"]];
                }
                // 继续处理下一个文件
                [weakSelf importNextURLFromQueue:queue index:index + 1];
            }];
        });
    }];
}

#pragma mark - 数据加载

- (void)handleRefresh:(id)sender {
    if (self.currentMode == WorldsManagerModeLocal) {
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
    if (self.currentMode != WorldsManagerModeLocal) return;

    [self setLoading:YES];
    NSString *profile = self.profileName ?: @"default";
    [[WorldService sharedService] scanWorldsForProfile:profile completion:^(NSArray<WorldItem *> *items) {
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
    filters[@"projectType"] = @"world";
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
                self.emptyLabel.text = @"No online results found";
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
    if (self.currentMode == WorldsManagerModeLocal) {
        [self filterLocalItems];
    }
}

- (void)searchBarSearchButtonClicked:(UISearchBar *)searchBar {
    [searchBar resignFirstResponder];
    if (self.currentMode == WorldsManagerModeOnline) {
        [self performOnlineSearch];
    }
}

- (void)searchBarCancelButtonClicked:(UISearchBar *)searchBar {
    searchBar.text = @"";
    [searchBar resignFirstResponder];
    if (self.currentMode == WorldsManagerModeLocal) {
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
        for (WorldItem *item in self.localItems) {
            if ([item.worldName.lowercaseString containsString:searchText] ||
                [item.displayName.lowercaseString containsString:searchText]) {
                [self.filteredLocalItems addObject:item];
            }
        }
    }
    self.emptyLabel.hidden = self.filteredLocalItems.count > 0;
    if (!self.emptyLabel.hidden) {
        self.emptyLabel.text = @"No local worlds found";
    }
    [self.tableView reloadData];
}

#pragma mark - UITableView DataSource & Delegate

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    return self.currentMode == WorldsManagerModeLocal ? self.filteredLocalItems.count : self.onlineSearchResults.count;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"WorldCell" forIndexPath:indexPath];
    cell.accessoryView = nil;
    cell.accessoryType = UITableViewCellAccessoryNone;
    cell.imageView.image = [UIImage systemImageNamed:@"globe.asia.australia.fill"];
    cell.imageView.tintColor = [UIColor systemGreenColor];

    if (self.currentMode == WorldsManagerModeLocal) {
        WorldItem *item = self.filteredLocalItems[indexPath.row];
        cell.textLabel.text = item.worldName ?: item.displayName;

        // 详情：上次游玩 + 世界大小
        NSMutableArray<NSString *> *parts = [NSMutableArray array];
        if (item.lastPlayed.length > 0) {
            [parts addObject:[NSString stringWithFormat:@"Last played %@", item.lastPlayed]];
        }
        if (item.worldSize) {
            unsigned long long bytes = [item.worldSize unsignedLongLongValue];
            NSString *sizeStr;
            if (bytes >= 1024 * 1024) {
                sizeStr = [NSString stringWithFormat:@"%.1f MB", bytes / (1024.0 * 1024.0)];
            } else if (bytes >= 1024) {
                sizeStr = [NSString stringWithFormat:@"%.1f KB", bytes / 1024.0];
            } else {
                sizeStr = [NSString stringWithFormat:@"%llu B", bytes];
            }
            [parts addObject:sizeStr];
        }
        cell.detailTextLabel.text = parts.count > 0 ? [parts componentsJoinedByString:@" · "] : nil;
        cell.detailTextLabel.textColor = [UIColor secondaryLabelColor];
    } else {
        NSDictionary *data = self.onlineSearchResults[indexPath.row];
        cell.textLabel.text = data[@"title"] ?: @"";
        cell.detailTextLabel.text = data[@"description"] ?: @"";
        cell.detailTextLabel.textColor = [UIColor secondaryLabelColor];

        UIButton *downloadButton = [UIButton buttonWithType:UIButtonTypeSystem];
        [downloadButton setTitle:@"Download" forState:UIControlStateNormal];
        downloadButton.titleLabel.font = [UIFont boldSystemFontOfSize:13];
        downloadButton.tag = indexPath.row;
        [downloadButton addTarget:self action:@selector(downloadButtonTapped:) forControlEvents:UIControlEventTouchUpInside];
        downloadButton.contentEdgeInsets = UIEdgeInsetsMake(4, 8, 4, 8);
        cell.accessoryView = downloadButton;
    }
    // Adapt to the custom launcher background: give the cell a frosted-glass/translucent effect
    [[BackgroundManager sharedManager] applyEffectToCell:cell];
    return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    if (self.currentMode == WorldsManagerModeOnline) {
        [self startVersionSelectionForOnlineRow:indexPath.row];
    }
}

- (UISwipeActionsConfiguration *)tableView:(UITableView *)tableView trailingSwipeActionsConfigurationForRowAtIndexPath:(NSIndexPath *)indexPath {
    if (self.currentMode != WorldsManagerModeLocal) {
        return nil;
    }

    __weak typeof(self) weakSelf = self;
    UIContextualAction *deleteAction = [UIContextualAction contextualActionWithStyle:UIContextualActionStyleDestructive title:@"Delete" handler:^(UIContextualAction * _Nonnull action, __kindof UIView * _Nonnull sourceView, void (^ _Nonnull completionHandler)(BOOL)) {
        WorldItem *item = weakSelf.filteredLocalItems[indexPath.row];
        UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Confirm delete"
                                                                        message:[NSString stringWithFormat:@"Delete the world %@?\nThis cannot be undone.", item.worldName ?: item.displayName]
                                                                 preferredStyle:UIAlertControllerStyleAlert];
        [alert addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:^(UIAlertAction * _Nonnull action) {
            completionHandler(NO);
        }]];
        [alert addAction:[UIAlertAction actionWithTitle:@"Delete" style:UIAlertActionStyleDestructive handler:^(UIAlertAction * _Nonnull action) {
            NSError *error = nil;
            if (![[WorldService sharedService] deleteWorld:item error:&error]) {
                [weakSelf showSimpleAlertWithTitle:@"Delete failed" message:error.localizedDescription];
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

#pragma mark - 在线下载

- (void)downloadButtonTapped:(UIButton *)sender {
    [self startVersionSelectionForOnlineRow:sender.tag];
}

- (void)startVersionSelectionForOnlineRow:(NSInteger)row {
    if (row >= (NSInteger)self.onlineSearchResults.count) return;
    NSDictionary *data = self.onlineSearchResults[row];

    WorldItem *item = [[WorldItem alloc] initWithOnlineData:data];
    self.pendingDownloadItem = item;

    AssetVersionViewController *vc = [[AssetVersionViewController alloc] init];
    vc.assetType = AssetVersionTypeWorld;
    vc.projectID = item.onlineID;
    vc.projectDisplayName = item.displayName;
    vc.delegate = self;
    [self.navigationController pushViewController:vc animated:YES];
}

#pragma mark - AssetVersionViewControllerDelegate

- (void)assetVersionViewController:(AssetVersionViewController *)viewController didSelectVersion:(ModVersion *)version {
    WorldItem *item = self.pendingDownloadItem;
    if (!item) return;

    NSDictionary *primaryFile = version.primaryFile;
    if (!primaryFile || ![primaryFile[@"url"] isKindOfClass:[NSString class]]) {
        [self showSimpleAlertWithTitle:@"Error" message:@"No valid download link found."];
        return;
    }
    item.selectedVersionDownloadURL = primaryFile[@"url"];

    [self startDownloadForItem:item];
}

- (void)startDownloadForItem:(WorldItem *)item {
    // Always show the individual download progress (the floating button is gone)
    BOOL showProgressUI = YES;
    UIAlertController *downloadingAlert = nil;
    if (showProgressUI) {
        downloadingAlert = [UIAlertController alertControllerWithTitle:@"Downloading and extracting"
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

    [[WorldService sharedService] downloadWorld:item
                                        toProfile:self.profileName
                                         progress:nil
                                       completion:^(BOOL success, NSError * _Nullable error) {
        dispatch_async(dispatch_get_main_queue(), ^{
            void (^showResult)(void) = ^{
                if (!success || error) {
                    [self showSimpleAlertWithTitle:@"Download failed" message:error.localizedDescription ?: @"Unknown error"];
                } else {
                    UIAlertController *successAlert = [UIAlertController alertControllerWithTitle:@"Download complete"
                                                                                          message:[NSString stringWithFormat:@"%@ was imported successfully.", item.displayName]
                                                                                   preferredStyle:UIAlertControllerStyleAlert];
                    [successAlert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:^(UIAlertAction * _Nonnull action) {
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
    [alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
}

@end
