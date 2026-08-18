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

// ===== Selection mode =====
@property (nonatomic, assign) BOOL isSelectMode; // Whether selection mode is active
@property (nonatomic, strong) NSMutableArray<ModItem *> *selectedMods; // The list of selected mods
@property (nonatomic, strong) UIToolbar *bottomToolbar; // The bottom toolbar (shown in selection mode)
@property (nonatomic, strong) UIBarButtonItem *selectButtonItem; // The navigation bar "Select" button (entering selection mode from normal mode)
@property (nonatomic, strong) UIBarButtonItem *doneButtonItem; // The navigation bar "Done" button (leaving selection mode)
@property (nonatomic, strong) UIBarButtonItem *navSelectAllButtonItem; // The "Select all" button on the left of the navigation bar
@property (nonatomic, strong) UIBarButtonItem *toolbarSelectAllButtonItem; // The "Select all" button in the bottom toolbar
@property (nonatomic, strong) UIBarButtonItem *toolbarDeselectAllButtonItem; // The "Deselect all" button in the bottom toolbar
@property (nonatomic, strong) UIBarButtonItem *toolbarDeleteButtonItem; // The "Delete selected" button in the bottom toolbar
@property (nonatomic, strong) UIBarButtonItem *flexibleSpaceItem; // Flexible spacing in the toolbar
@property (nonatomic, copy) NSString *originalTitle; // The title before entering selection mode, restored on exit

@end

@implementation ModsManagerViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"Manage mods";
    self.originalTitle = self.title; // Save the original title, restored when leaving selection mode
    self.view.backgroundColor = [UIColor systemBackgroundColor];
    // Adapt to the custom launcher background: make this VC transparent so the global background image/blur shows through
    [[BackgroundManager sharedManager] makeViewControllerTransparent:self];
    self.currentMode = ModsManagerModeLocal; // Always local mode (the online download entry has moved to the download screen)
    self.localMods = [NSMutableArray array];
    self.filteredLocalMods = [NSMutableArray array];
    self.onlineSearchResults = [NSMutableArray array];
    self.selectedMods = [NSMutableArray array]; // Initialize the selected mod list
    self.isSelectMode = NO;
    [self setupUI];
    // Fix for "the previous page does not disappear in time": add a frosted-glass cover layer to the view
    // so the ProfileSettingsViewController underneath does not show through during the push transition
    [[BackgroundManager sharedManager] applyEffectToView:self.view];
    // Make the tableView background transparent so it does not hide the global background
    self.tableView.backgroundColor = [UIColor clearColor];
    self.tableView.backgroundView = nil;
    [self updateUIForCurrentMode];
    [self refreshLocalModsList];

    // Listen for background effect changes so transparency is re-applied when the background is switched
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(reapplyBackgroundEffect)
                                                 name:@"BackgroundUIEffectChanged"
                                               object:nil];
}

- (void)reapplyBackgroundEffect {
    // Re-apply transparency to this VC when the background effect changes
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
    // Remove the notification observer to avoid crashing on notifications delivered after dealloc
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

- (void)setupUI {
    self.searchBar = [[UISearchBar alloc] initWithFrame:CGRectZero];
    self.searchBar.translatesAutoresizingMaskIntoConstraints = NO;
    self.searchBar.delegate = self;
    self.searchBar.placeholder = @"Search local mods...";
    // Adapt to the custom launcher background: clear the searchBar's opaque default background so the global image/blur shows through
    [[BackgroundManager sharedManager] applyEffectToSearchBar:self.searchBar];
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
    self.checkUpdateButton.accessibilityLabel = @"Check for updates";

    UIImage *importImage = [UIImage systemImageNamed:@"square.and.arrow.down"] ?: [UIImage systemImageNamed:@"plus"];
    self.importButton = [[UIBarButtonItem alloc] initWithImage:importImage style:UIBarButtonItemStylePlain target:self action:@selector(importModTapped)];
    self.importButton.accessibilityLabel = @"Import mod";

    // Initialize the selection mode buttons
    UIImage *selectImage = [UIImage systemImageNamed:@"checklist"] ?: [UIImage systemImageNamed:@"checkmark.circle"];
    self.selectButtonItem = [[UIBarButtonItem alloc] initWithImage:selectImage style:UIBarButtonItemStylePlain target:self action:@selector(enterSelectMode)];
    self.selectButtonItem.accessibilityLabel = @"Select";

    self.doneButtonItem = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemDone target:self action:@selector(exitSelectMode)];
    self.doneButtonItem.accessibilityLabel = @"Done";

    self.navSelectAllButtonItem = [[UIBarButtonItem alloc] initWithTitle:@"Select all" style:UIBarButtonItemStylePlain target:self action:@selector(toggleSelectAll)];
    self.toolbarSelectAllButtonItem = [[UIBarButtonItem alloc] initWithTitle:@"Select all" style:UIBarButtonItemStylePlain target:self action:@selector(selectAll)];
    self.toolbarDeselectAllButtonItem = [[UIBarButtonItem alloc] initWithTitle:@"Deselect all" style:UIBarButtonItemStylePlain target:self action:@selector(deselectAll)];
    self.toolbarDeleteButtonItem = [[UIBarButtonItem alloc] initWithTitle:@"Delete selected" style:UIBarButtonItemStylePlain target:self action:@selector(deleteSelectedMods)];
    self.toolbarDeleteButtonItem.tintColor = [UIColor systemRedColor];
    self.flexibleSpaceItem = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemFlexibleSpace target:nil action:nil];

    // Bottom toolbar (shown in selection mode)
    self.bottomToolbar = [[UIToolbar alloc] initWithFrame:CGRectZero];
    self.bottomToolbar.translatesAutoresizingMaskIntoConstraints = NO;
    self.bottomToolbar.hidden = YES; // Hidden at first, shown on entering selection mode
    [self.view addSubview:self.bottomToolbar];

    [self updateNavigationButtons];

    [NSLayoutConstraint activateConstraints:@[
        [self.searchBar.topAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.topAnchor constant:8],
        [self.searchBar.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [self.searchBar.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],

        [self.tableView.topAnchor constraintEqualToAnchor:self.searchBar.bottomAnchor],
        [self.tableView.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [self.tableView.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        // The tableView bottom binds either to the top of the toolbar or to the bottom of the safe area, depending on selection mode
        // It binds to the safe area bottom by default and is adjusted in code when selection mode starts
        [self.tableView.bottomAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.bottomAnchor],

        [self.activityIndicator.centerXAnchor constraintEqualToAnchor:self.tableView.centerXAnchor],
        [self.activityIndicator.centerYAnchor constraintEqualToAnchor:self.tableView.centerYAnchor],

        [self.emptyLabel.centerXAnchor constraintEqualToAnchor:self.tableView.centerXAnchor],
        [self.emptyLabel.centerYAnchor constraintEqualToAnchor:self.tableView.centerYAnchor],

        // Bottom toolbar layout: flush with the bottom and both sides
        [self.bottomToolbar.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [self.bottomToolbar.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [self.bottomToolbar.bottomAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.bottomAnchor]
    ]];
}

- (void)updateUIForCurrentMode {
    self.searchBar.placeholder = @"Search local mods...";
    self.emptyLabel.text = @"No mods found";
    self.emptyLabel.hidden = self.localMods.count > 0;
    self.tableView.refreshControl.enabled = YES;
    [self updateNavigationButtons];
    [self.tableView reloadData];
}

- (void)updateNavigationButtons {
    if (self.isSelectMode) {
        // Selection mode: "Select all" on the left, "Done" on the right, with the count in the title
        [self updateSelectAllButtonTitle];
        self.navigationItem.leftBarButtonItem = self.navSelectAllButtonItem;
        self.navigationItem.rightBarButtonItems = @[self.doneButtonItem];
        [self updateSelectModeTitle];
    } else {
        // Normal mode: the close button on the left, and on the right: Select, Import, Refresh, Check for updates
        UIBarButtonItem *closeButton = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemDone target:self action:@selector(closeTapped)];
        // Disable the "Select" button when the list is empty
        self.selectButtonItem.enabled = self.filteredLocalMods.count > 0;
        // rightBarButtonItems are shown right to left: Import, Refresh, Check for updates, Select
        self.navigationItem.rightBarButtonItems = @[self.importButton, self.refreshButton, self.checkUpdateButton, self.selectButtonItem];
        self.navigationItem.leftBarButtonItem = closeButton;
        self.title = self.originalTitle;
    }
}

- (void)closeTapped {
    // Works in both containers:
    // - pushed onto a UINavigationController (from the card layout/version manager): pop back
    // - presented modally (the old call path): dismiss
    if (self.navigationController && self.navigationController.viewControllers.firstObject != self) {
        [self.navigationController popViewControllerAnimated:YES];
    } else {
        [self dismissViewControllerAnimated:YES completion:nil];
    }
}

#pragma mark - Select Mode (选择模式)

// Enter selection mode
- (void)enterSelectMode {
    if (self.filteredLocalMods.count == 0) return; // Selection mode is not allowed with no data

    self.isSelectMode = YES;
    [self.selectedMods removeAllObjects]; // Clear the selection when entering selection mode
    // Show the bottom toolbar
    self.bottomToolbar.hidden = NO;
    self.bottomToolbar.items = @[self.toolbarSelectAllButtonItem,
                                  self.flexibleSpaceItem,
                                  self.toolbarDeselectAllButtonItem,
                                  self.flexibleSpaceItem,
                                  self.toolbarDeleteButtonItem];
    // Adjust the tableView bottom inset, so the last row is not hidden behind the toolbar
    CGFloat toolbarHeight = self.bottomToolbar.bounds.size.height;
    if (toolbarHeight <= 0) {
        // Use an estimate while the toolbar has not been laid out yet
        [self.bottomToolbar layoutIfNeeded];
        toolbarHeight = self.bottomToolbar.bounds.size.height;
        if (toolbarHeight <= 0) toolbarHeight = 44.0;
    }
    {
        UIEdgeInsets inset = self.tableView.contentInset;
        inset.bottom = toolbarHeight;
        self.tableView.contentInset = inset;
        UIEdgeInsets scrollInset = self.tableView.scrollIndicatorInsets;
        scrollInset.bottom = toolbarHeight;
        self.tableView.scrollIndicatorInsets = scrollInset;
    }

    [self updateNavigationButtons];
    [self.tableView reloadData];
}

// Leave selection mode and clear every selection
- (void)exitSelectMode {
    self.isSelectMode = NO;
    [self.selectedMods removeAllObjects]; // Clear the selection on exit
    self.bottomToolbar.hidden = YES;
    self.bottomToolbar.items = nil;
    // Restore the tableView bottom inset
    {
        UIEdgeInsets inset = self.tableView.contentInset;
        inset.bottom = 0;
        self.tableView.contentInset = inset;
        UIEdgeInsets scrollInset = self.tableView.scrollIndicatorInsets;
        scrollInset.bottom = 0;
        self.tableView.scrollIndicatorInsets = scrollInset;
    }

    [self updateNavigationButtons];
    [self.tableView reloadData];
}

// Toggle select all / deselect all (used by the button on the left of the navigation bar)
- (void)toggleSelectAll {
    if (self.selectedMods.count == self.filteredLocalMods.count) {
        [self deselectAll];
    } else {
        [self selectAll];
    }
}

// Select all: add every mod in the current filtered list to the selection
- (void)selectAll {
    [self.selectedMods removeAllObjects];
    [self.selectedMods addObjectsFromArray:self.filteredLocalMods];
    [self updateNavigationButtons];
    [self reloadVisibleCellsCheckbox];
}

// Deselect all: clear the selection
- (void)deselectAll {
    [self.selectedMods removeAllObjects];
    [self updateNavigationButtons];
    [self reloadVisibleCellsCheckbox];
}

// Delete the selected mods (with a confirmation dialog)
- (void)deleteSelectedMods {
    if (self.selectedMods.count == 0) {
        [self showSimpleAlertWithTitle:@"Notice" message:@"No mods selected yet"];
        return;
    }

    NSString *message = [NSString stringWithFormat:@"Delete the %ld selected mod(s)?\nThis cannot be undone.", (long)self.selectedMods.count];
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Delete multiple" message:message preferredStyle:UIAlertControllerStyleAlert];

    [alert addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    __weak typeof(self) weakSelf = self;
    [alert addAction:[UIAlertAction actionWithTitle:@"Delete" style:UIAlertActionStyleDestructive handler:^(UIAlertAction * _Nonnull action) {
        [weakSelf performDeleteSelectedMods];
    }]];
    [self presentViewController:alert animated:YES completion:nil];
}

// Perform the bulk delete
- (void)performDeleteSelectedMods {
    NSArray<ModItem *> *modsToDelete = [self.selectedMods copy];
    NSMutableArray<ModItem *> *failedMods = [NSMutableArray array];

    for (ModItem *mod in modsToDelete) {
        NSError *error = nil;
        BOOL success = [[ModService sharedService] deleteMod:mod error:&error];
        if (!success || error) {
            NSLog(@"[ModsManager] Batch delete failed: %@ - %@", mod.displayName, error);
            [failedMods addObject:mod];
        }
    }

    // Remove the successfully deleted mods from the data source
    for (ModItem *mod in modsToDelete) {
        if ([failedMods containsObject:mod]) continue; // Skip the ones that failed to delete
        NSUInteger idxInFull = [self.localMods indexOfObject:mod];
        if (idxInFull != NSNotFound) [self.localMods removeObjectAtIndex:idxInFull];
        NSUInteger idxInFiltered = [self.filteredLocalMods indexOfObject:mod];
        if (idxInFiltered != NSNotFound) [self.filteredLocalMods removeObjectAtIndex:idxInFiltered];
    }

    // Clear the selection (the failed entries are no longer marked as selected)
    [self.selectedMods removeAllObjects];

    if (failedMods.count > 0) {
        // On a partial failure, stay in selection mode and tell the user which ones failed
        NSMutableArray<NSString *> *names = [NSMutableArray array];
        for (ModItem *m in failedMods) [names addObject:m.displayName];
        [self showSimpleAlertWithTitle:[NSString stringWithFormat:@"Deletion finished, %ld item(s) failed", (long)failedMods.count]
                               message:[names componentsJoinedByString:@"\n"]];
        [self updateNavigationButtons];
        [self.tableView reloadData];
    } else {
        // Everything was deleted, so leave selection mode
        [self exitSelectMode];
    }
}

// Whether the given mod is selected
- (BOOL)isModSelected:(ModItem *)mod {
    return [self.selectedMods containsObject:mod];
}

// Toggle the selection of one mod (triggered by a row tap)
- (void)toggleSelectionForMod:(ModItem *)mod {
    if ([self.selectedMods containsObject:mod]) {
        [self.selectedMods removeObject:mod];
    } else {
        [self.selectedMods addObject:mod];
    }
    [self updateNavigationButtons];
}

// Update the navigation bar title with the number selected
- (void)updateSelectModeTitle {
    if (self.isSelectMode) {
        self.title = [NSString stringWithFormat:@"%ld selected", (long)self.selectedMods.count];
    }
}

// Update the title of the "Select all" button (showing "Deselect all" when everything is selected)
- (void)updateSelectAllButtonTitle {
    if (self.selectedMods.count > 0 && self.selectedMods.count == self.filteredLocalMods.count && self.filteredLocalMods.count > 0) {
        self.navSelectAllButtonItem.title = @"Deselect all";
        self.toolbarSelectAllButtonItem.enabled = NO;
        self.toolbarDeselectAllButtonItem.enabled = YES;
    } else if (self.selectedMods.count == 0) {
        self.navSelectAllButtonItem.title = @"Select all";
        self.toolbarSelectAllButtonItem.enabled = YES;
        self.toolbarDeselectAllButtonItem.enabled = NO;
    } else {
        self.navSelectAllButtonItem.title = @"Select all";
        self.toolbarSelectAllButtonItem.enabled = YES;
        self.toolbarDeselectAllButtonItem.enabled = YES;
    }
    // Disable the select-all buttons when there is no data
    if (self.filteredLocalMods.count == 0) {
        self.navSelectAllButtonItem.enabled = NO;
        self.toolbarSelectAllButtonItem.enabled = NO;
        self.toolbarDeselectAllButtonItem.enabled = NO;
    } else {
        self.navSelectAllButtonItem.enabled = YES;
    }
    // Delete button: disabled when nothing is selected
    self.toolbarDeleteButtonItem.enabled = self.selectedMods.count > 0;
}

// Refresh the checkbox state of every visible cell (avoiding the flicker of a full reloadData)
- (void)reloadVisibleCellsCheckbox {
    for (NSIndexPath *indexPath in [self.tableView indexPathsForVisibleRows]) {
        UITableViewCell *cell = [self.tableView cellForRowAtIndexPath:indexPath];
        if (!cell) continue;
        ModItem *mod = self.filteredLocalMods[indexPath.row];
        [self applyCheckboxToCell:cell selected:[self isModSelected:mod]];
    }
}

// Apply a checkbox to a cell (shown in selection mode, hidden in normal mode)
- (void)applyCheckboxToCell:(UITableViewCell *)cell selected:(BOOL)selected {
    if (self.isSelectMode) {
        // Create the checkbox ImageView as the accessoryView
        UIImageView *checkbox = [[UIImageView alloc] init];
        UIImageSymbolConfiguration *config = [UIImageSymbolConfiguration configurationWithPointSize:22 weight:UIImageSymbolWeightMedium];
        if (selected) {
            checkbox.image = [[UIImage systemImageNamed:@"checkmark.circle.fill"] imageByApplyingSymbolConfiguration:config];
            checkbox.tintColor = [UIColor systemBlueColor];
        } else {
            checkbox.image = [[UIImage systemImageNamed:@"circle"] imageByApplyingSymbolConfiguration:config];
            checkbox.tintColor = [UIColor systemGrayColor];
        }
        checkbox.frame = CGRectMake(0, 0, 24, 24);
        cell.accessoryView = checkbox;
        cell.selectionStyle = UITableViewCellSelectionStyleDefault;
        // Hide enableSwitch and openLinkButton, so they do not clash visually with the checkbox
        if ([cell isKindOfClass:[ModTableViewCell class]]) {
            ModTableViewCell *modCell = (ModTableViewCell *)cell;
            modCell.enableSwitch.hidden = YES;
            modCell.openLinkButton.hidden = YES;
        }
    } else {
        // Normal mode: clear the checkbox and restore the original controls
        cell.accessoryView = nil;
        cell.selectionStyle = UITableViewCellSelectionStyleNone;
        if ([cell isKindOfClass:[ModTableViewCell class]]) {
            ModTableViewCell *modCell = (ModTableViewCell *)cell;
            // Only restore visibility once configured (after configureWithMod: has been called), to avoid setting it inconsistently
            // The final visibility of enableSwitch/openLinkButton is decided by configureWithMod
            modCell.enableSwitch.hidden = NO;
            modCell.openLinkButton.hidden = NO;
        }
    }
}

#pragma mark - Import Mod

- (void)importModTapped {
    // Make sure the folder exists
    NSError *dirError = nil;
    NSString *modsDir = [[ModService sharedService] ensureModsFolderForProfile:nil error:&dirError];
    if (!modsDir) {
        [self showSimpleAlertWithTitle:@"Cannot import" message:dirError.localizedDescription ?: @"Could not determine the mods folder"];
        return;
    }

    // Show the file picker, allowing jar files (Forge/NeoForge/Fabric/Quilt all use jar)
    UIDocumentPickerViewController *picker = [[UIDocumentPickerViewController alloc] initWithDocumentTypes:@[@"com.sun.java.jar", @"public.item"] inMode:UIDocumentPickerModeImport];
    picker.allowsMultipleSelection = YES;
    picker.delegate = self;
    picker.title = @"Choose mod file";
    [self presentViewController:picker animated:YES completion:nil];
}

- (void)documentPicker:(UIDocumentPickerViewController *)controller didPickDocumentsAtURLs:(NSArray<NSURL *> *)urls {
    if (urls.count == 0) return;

    NSError *dirError = nil;
    NSString *modsDir = [[ModService sharedService] ensureModsFolderForProfile:nil error:&dirError];
    if (!modsDir) {
        [self showSimpleAlertWithTitle:@"Import failed" message:dirError.localizedDescription ?: @"Could not determine the mods folder"];
        return;
    }

    NSFileManager *fm = [NSFileManager defaultManager];
    NSInteger successCount = 0;
    NSMutableArray<NSString *> *failedFiles = [NSMutableArray array];

    for (NSURL *url in urls) {
        // Start accessing the security-scoped resource
        BOOL accessing = [url startAccessingSecurityScopedResource];
        @try {
            NSString *fileName = url.lastPathComponent;
            NSString *destPath = [modsDir stringByAppendingPathComponent:fileName];

            // Handle a file with the same name
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

    // Refresh the list
    [self refreshLocalModsList];

    if (failedFiles.count > 0) {
        [self showSimpleAlertWithTitle:[NSString stringWithFormat:@"Import finished (%ld succeeded, %ld failed)", (long)successCount, (long)failedFiles.count]
                               message:[failedFiles componentsJoinedByString:@"\n"]];
    } else {
        NSLog(@"[ModsManager] Successfully imported %ld mods", (long)successCount);
    }
}



#pragma mark - Check for Updates

- (void)checkForUpdates {
    // Get the local mod list of the current profile
    NSMutableArray<ModItem *> *mods = [self.localMods mutableCopy];
    if (mods.count == 0) {
        [self showSimpleAlertWithTitle:@"Notice" message:@"There are no local mods, so there is nothing to check for updates."];
        return;
    }

    // Parse gameVersion and loader out of the lastVersionId of the current profile
    NSString *lastVersionId = PLProfiles.current.selectedProfile[@"lastVersionId"];
    if (!lastVersionId || lastVersionId.length == 0) {
        [self showSimpleAlertWithTitle:@"Notice" message:@"Could not read the current version information."];
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
        // A plain <mc> form, with no loader
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
    // If selection mode is active, leave it before refreshing (the data is about to change, so the selection would not match)
    if (self.isSelectMode) {
        [self exitSelectMode];
    }
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
        self.emptyLabel.text = @"No local mods found";
    }
    // Update the navigation button state (whether "Select" is enabled, the "Select all" title and so on)
    [self updateNavigationButtons];
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

    // Show or hide the checkboxes according to selection mode
    if (self.isSelectMode) {
        [self applyCheckboxToCell:cell selected:[self isModSelected:mod]];
    } else {
        [self applyCheckboxToCell:cell selected:NO];
    }

    // Adapt to the custom launcher background: give the cell a frosted-glass/translucent effect
    // The contentView background of ModTableViewCell is clearColor, with BackgroundManager injecting the effect
    [[BackgroundManager sharedManager] applyEffectToCell:cell];

    return cell;
}

- (UISwipeActionsConfiguration *)tableView:(UITableView *)tableView trailingSwipeActionsConfigurationForRowAtIndexPath:(NSIndexPath *)indexPath {
    // Disable swipe-to-delete in selection mode, to avoid mistakes
    if (self.isSelectMode) return nil;

    UIContextualAction *deleteAction = [UIContextualAction contextualActionWithStyle:UIContextualActionStyleDestructive title:@"Delete" handler:^(UIContextualAction * _Nonnull action, __kindof UIView * _Nonnull sourceView, void (^ _Nonnull completionHandler)(BOOL)) {

        ModItem *modToDelete = self.filteredLocalMods[indexPath.row];

        UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Confirm delete" message:[NSString stringWithFormat:@"Delete %@?\nThis cannot be undone.", modToDelete.displayName] preferredStyle:UIAlertControllerStyleAlert];

        [alert addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:^(UIAlertAction * _Nonnull action) {
            completionHandler(NO);
        }]];

        [alert addAction:[UIAlertAction actionWithTitle:@"Delete" style:UIAlertActionStyleDestructive handler:^(UIAlertAction * _Nonnull action) {
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
    // The online download entry has been removed (use the download screen); this method is kept to satisfy the protocol
}

#pragma mark - ModVersionViewControllerDelegate

- (void)modVersionViewController:(ModVersionViewController *)viewController didSelectVersion:(ModVersion *)version {
    ModItem *itemToDownload = viewController.modItem;
    
    // Find the primary file to download
    NSDictionary *primaryFile = version.primaryFile;
    if (!primaryFile || ![primaryFile[@"url"] isKindOfClass:[NSString class]]) {
        [self showSimpleAlertWithTitle:@"Error" message:@"No valid download link found."];
        return;
    }

    itemToDownload.selectedVersionDownloadURL = primaryFile[@"url"];
    itemToDownload.fileName = primaryFile[@"filename"];

    [self startDownloadForItem:itemToDownload];
}

- (void)startDownloadForItem:(ModItem *)item {
    // Always show the individual download progress (the floating button is gone)
    BOOL showProgressUI = YES;
    UIAlertController *downloadingAlert = nil;
    if (showProgressUI) {
        downloadingAlert = [UIAlertController alertControllerWithTitle:@"Downloading"
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
        [self showSimpleAlertWithTitle:@"Download failed" message:error.localizedDescription];
    } else {
        UIAlertController *successAlert = [UIAlertController alertControllerWithTitle:@"Download complete"
                                                                              message:[NSString stringWithFormat:@"%@ was installed successfully.", item.displayName]
                                                                       preferredStyle:UIAlertControllerStyleAlert];
        [successAlert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:^(UIAlertAction * _Nonnull action) {
            // After user acknowledges, refresh local mods list
            [self refreshLocalModsList];
        }]];
        [self presentViewController:successAlert animated:YES completion:nil];
    }
}

- (void)showSimpleAlertWithTitle:(NSString *)title message:(NSString *)message {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:title message:message preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    if (self.isSelectMode) {
        // In selection mode: tapping a row toggles that mod's selection
        ModItem *mod = self.filteredLocalMods[indexPath.row];
        [self toggleSelectionForMod:mod];
        // Update the checkbox of that cell directly, avoiding the flicker of a full reload
        UITableViewCell *cell = [tableView cellForRowAtIndexPath:indexPath];
        if (cell) {
            [self applyCheckboxToCell:cell selected:[self isModSelected:mod]];
        }
        // The highlight is left in place so the user can see the current row, but toned down visually
        [tableView deselectRowAtIndexPath:indexPath animated:YES];
    } else {
        // Normal mode: only clear the highlight, with no other action
        [tableView deselectRowAtIndexPath:indexPath animated:YES];
    }
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
        UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Link unavailable" message:@"This mod has no online link available." preferredStyle:UIAlertControllerStyleAlert];
        [alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
        [self presentViewController:alert animated:YES completion:nil];
    }
}

@end
