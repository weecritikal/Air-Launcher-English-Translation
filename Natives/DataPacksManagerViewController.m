//
//  DataPacksManagerViewController.m
//  Amethyst
//
//  Data pack manager view controller implementation, modelled on ModsManagerViewController
//  Uses DataPackService for local scanning and downloads
//  Uses AssetVersionViewController for picking an online version
//  Uses ModrinthAPI for online search (projectType=datapack)
//  Note: a world cannot be picked on iOS, so downloads go to <gameDir>/datapacks/ and must be moved to saves/<world name>/datapacks/ manually
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
    self.title = @"Manage data packs";
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
    if (self.currentMode == DataPacksManagerModeLocal) {
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
    self.modeSwitcher = [[UISegmentedControl alloc] initWithItems:@[@"Local data packs", @"Search online (Modrinth)"]];
    self.modeSwitcher.translatesAutoresizingMaskIntoConstraints = NO;
    self.modeSwitcher.selectedSegmentIndex = self.currentMode;
    [self.modeSwitcher addTarget:self action:@selector(modeChanged:) forControlEvents:UIControlEventValueChanged];
    [self.view addSubview:self.modeSwitcher];

    self.searchBar = [[UISearchBar alloc] initWithFrame:CGRectZero];
    self.searchBar.translatesAutoresizingMaskIntoConstraints = NO;
    self.searchBar.delegate = self;
    self.searchBar.placeholder = @"Search local data packs...";
    // Adapt to the custom launcher background: clear the searchBar's opaque default background so the global image/blur shows through
    [[BackgroundManager sharedManager] applyEffectToSearchBar:self.searchBar];
    [self.view addSubview:self.searchBar];

    // Hint label: on iOS data packs must be moved into the right world folder manually
    self.tipLabel = [[UILabel alloc] initWithFrame:CGRectZero];
    self.tipLabel.translatesAutoresizingMaskIntoConstraints = NO;
    self.tipLabel.text = @"Tip: data packs only take effect in saves/<world name>/datapacks/. Downloaded data packs go to the shared datapacks folder by default, so move them into the matching world folder manually.";
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
    self.importButton.accessibilityLabel = @"Import data pack";

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
        self.searchBar.placeholder = @"Search local data packs...";
        self.emptyLabel.text = @"No data packs found";
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
    if (self.currentMode == DataPacksManagerModeLocal) {
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

#pragma mark - Importing data packs

- (void)importTapped {
    NSError *dirError = nil;
    NSString *dir = [[DataPackService sharedService] ensureDataPacksFolderForProfile:self.profileName error:&dirError];
    if (!dir) {
        [self showSimpleAlertWithTitle:@"Cannot import" message:dirError.localizedDescription ?: @"Could not determine the datapacks folder"];
        return;
    }

    UIDocumentPickerViewController *picker = [[UIDocumentPickerViewController alloc] initWithDocumentTypes:@[@"public.zip", @"public.item"] inMode:UIDocumentPickerModeImport];
    picker.allowsMultipleSelection = YES;
    picker.delegate = self;
    picker.title = @"Choose data pack file";
    [self presentViewController:picker animated:YES completion:nil];
}

- (void)documentPicker:(UIDocumentPickerViewController *)controller didPickDocumentsAtURLs:(NSArray<NSURL *> *)urls {
    if (urls.count == 0) return;

    NSError *dirError = nil;
    NSString *dir = [[DataPackService sharedService] ensureDataPacksFolderForProfile:self.profileName error:&dirError];
    if (!dir) {
        [self showSimpleAlertWithTitle:@"Import failed" message:dirError.localizedDescription ?: @"Could not determine the datapacks folder"];
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
        [self showSimpleAlertWithTitle:[NSString stringWithFormat:@"Import finished (%ld succeeded, %ld failed)", (long)successCount, (long)failedFiles.count]
                               message:[failedFiles componentsJoinedByString:@"\n"]];
    }
}

#pragma mark - Data loading

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
        self.emptyLabel.text = @"No local data packs found";
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
            [parts addObject:[NSString stringWithFormat:@"Format %@", item.packFormat]];
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
    if (self.currentMode == DataPacksManagerModeOnline) {
        [self startVersionSelectionForOnlineRow:indexPath.row];
    }
}

- (UISwipeActionsConfiguration *)tableView:(UITableView *)tableView trailingSwipeActionsConfigurationForRowAtIndexPath:(NSIndexPath *)indexPath {
    if (self.currentMode != DataPacksManagerModeLocal) {
        return nil;
    }

    __weak typeof(self) weakSelf = self;
    UIContextualAction *deleteAction = [UIContextualAction contextualActionWithStyle:UIContextualActionStyleDestructive title:@"Delete" handler:^(UIContextualAction * _Nonnull action, __kindof UIView * _Nonnull sourceView, void (^ _Nonnull completionHandler)(BOOL)) {
        DataPackItem *item = weakSelf.filteredLocalItems[indexPath.row];
        UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Confirm delete"
                                                                        message:[NSString stringWithFormat:@"Delete %@?", item.displayName ?: item.fileName]
                                                                 preferredStyle:UIAlertControllerStyleAlert];
        [alert addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:^(UIAlertAction * _Nonnull action) {
            completionHandler(NO);
        }]];
        [alert addAction:[UIAlertAction actionWithTitle:@"Delete" style:UIAlertActionStyleDestructive handler:^(UIAlertAction * _Nonnull action) {
            NSError *error = nil;
            if (![[DataPackService sharedService] deleteDataPack:item error:&error]) {
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

#pragma mark - Local enable/disable toggle

- (void)toggleSwitchChanged:(UISwitch *)sender {
    NSInteger row = sender.tag;
    if (row >= (NSInteger)self.filteredLocalItems.count) return;
    DataPackItem *item = self.filteredLocalItems[row];
    NSError *error = nil;
    if (![[DataPackService sharedService] toggleEnableForDataPack:item error:&error]) {
        sender.on = !sender.on;
        [self showSimpleAlertWithTitle:@"Operation failed" message:error.localizedDescription];
    } else {
        NSIndexPath *ip = [NSIndexPath indexPathForRow:row inSection:0];
        UITableViewCell *cell = [self.tableView cellForRowAtIndexPath:ip];
        cell.contentView.alpha = item.disabled ? 0.5 : 1.0;
    }
}

#pragma mark - Online downloads

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
        [self showSimpleAlertWithTitle:@"Error" message:@"No valid download link found."];
        return;
    }
    item.selectedVersionDownloadURL = primaryFile[@"url"];
    item.fileName = primaryFile[@"filename"];

    [self startDownloadForItem:item];
}

- (void)startDownloadForItem:(DataPackItem *)item {
    // Always show the individual download progress (the floating button is gone)
    BOOL showProgressUI = YES;
    UIAlertController *downloadingAlert = nil;
    if (showProgressUI) {
        downloadingAlert = [UIAlertController alertControllerWithTitle:@"Downloading"
                                                                                  message:[NSString stringWithFormat:@"%@...\nWhen the download finishes, move it manually into the matching world folder.", item.displayName]
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
                    [self showSimpleAlertWithTitle:@"Download failed" message:error.localizedDescription ?: @"Unknown error"];
                } else {
                    UIAlertController *successAlert = [UIAlertController alertControllerWithTitle:@"Download complete"
                                                                                          message:[NSString stringWithFormat:@"%@ was downloaded to the shared datapacks folder.\nPlease move it manually into the matching world folder (saves/<world name>/datapacks/).", item.displayName]
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

#pragma mark - Utility methods

- (void)showSimpleAlertWithTitle:(NSString *)title message:(NSString *)message {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:title message:message preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
}

@end
