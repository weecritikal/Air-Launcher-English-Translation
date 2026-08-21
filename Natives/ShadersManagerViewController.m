//
//  ShadersManagerViewController.m
//  Flux
//
//  Shader manager implementation - mirrors ModsManagerViewController
//

#import "ShadersManagerViewController.h"
#import "ShaderTableViewCell.h"
#import "ShaderService.h"
#import "ShaderItem.h"
#import "ModItem.h"
#import "ModUpdateViewController.h"
#import "PLProfiles.h"
#import "installer/modpack/ModrinthAPI.h"
#import "LauncherPreferences.h"
#import "BackgroundManager.h"
#import "utils.h"

@interface ShadersManagerViewController () <UITableViewDataSource, UITableViewDelegate, ShaderTableViewCellDelegate, UISearchBarDelegate, ShaderVersionViewControllerDelegate, UIDocumentPickerDelegate>

@property (nonatomic, strong) UISearchBar *searchBar;
@property (nonatomic, strong) UITableView *tableView;
@property (nonatomic, strong) UIActivityIndicatorView *activityIndicator;
@property (nonatomic, strong) UILabel *emptyLabel;
@property (nonatomic, strong) UIBarButtonItem *refreshButton;
@property (nonatomic, strong) UIBarButtonItem *checkUpdateButton;
@property (nonatomic, strong) UIBarButtonItem *importButton;
@property (nonatomic, strong) NSMutableArray<ShaderItem *> *localShaders;
@property (nonatomic, strong) NSMutableArray<ShaderItem *> *filteredLocalShaders;

// ===== Selection mode =====
@property (nonatomic, assign) BOOL isSelectMode; // Whether selection mode is active
@property (nonatomic, strong) NSMutableArray<ShaderItem *> *selectedShaders; // List of selected shaders
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

@implementation ShadersManagerViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"Manage shader packs";
    self.originalTitle = self.title; // Save the original title, restored when leaving selection mode
    self.view.backgroundColor = [UIColor systemBackgroundColor];
    // Adapt to the custom launcher background: make this VC transparent so the global background image/blur shows through
    [[BackgroundManager sharedManager] makeViewControllerTransparent:self];
    self.currentMode = ShadersManagerModeLocal; // Always use local mode (the online download entry point has moved to the download screen)
    self.localShaders = [NSMutableArray array];
    self.filteredLocalShaders = [NSMutableArray array];
    self.onlineSearchResults = [NSMutableArray array];
    self.selectedShaders = [NSMutableArray array]; // Initialize the selected shader list
    self.isSelectMode = NO;
    [self setupUI];
    // Fix for "the previous page does not disappear in time": add a frosted-glass cover layer to the view
    // so the ProfileSettingsViewController underneath does not show through during the push transition
    [[BackgroundManager sharedManager] applyEffectToView:self.view];
    // Make the tableView background transparent so it does not hide the global background
    self.tableView.backgroundColor = [UIColor clearColor];
    self.tableView.backgroundView = nil;
    [self updateUIForCurrentMode];
    [self refreshLocalShadersList];

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
    self.searchBar.placeholder = @"Search local shader packs...";
    // Adapt to the custom launcher background: clear the searchBar's opaque default background so the global image/blur shows through
    [[BackgroundManager sharedManager] applyEffectToSearchBar:self.searchBar];
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

    UIImage *checkImage = [UIImage systemImageNamed:@"arrow.triangle.2.circlepath"];
    self.checkUpdateButton = [[UIBarButtonItem alloc] initWithImage:checkImage style:UIBarButtonItemStylePlain target:self action:@selector(checkForUpdates)];
    self.checkUpdateButton.accessibilityLabel = @"Check for updates";

    UIImage *importImage = [UIImage systemImageNamed:@"square.and.arrow.down"] ?: [UIImage systemImageNamed:@"plus"];
    self.importButton = [[UIBarButtonItem alloc] initWithImage:importImage style:UIBarButtonItemStylePlain target:self action:@selector(importShaderTapped)];
    self.importButton.accessibilityLabel = @"Import shader pack";

    // Initialize the selection mode buttons
    UIImage *selectImage = [UIImage systemImageNamed:@"checklist"] ?: [UIImage systemImageNamed:@"checkmark.circle"];
    self.selectButtonItem = [[UIBarButtonItem alloc] initWithImage:selectImage style:UIBarButtonItemStylePlain target:self action:@selector(enterSelectMode)];
    self.selectButtonItem.accessibilityLabel = @"Select";

    self.doneButtonItem = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemDone target:self action:@selector(exitSelectMode)];
    self.doneButtonItem.accessibilityLabel = @"Done";

    self.navSelectAllButtonItem = [[UIBarButtonItem alloc] initWithTitle:@"Select all" style:UIBarButtonItemStylePlain target:self action:@selector(toggleSelectAll)];
    self.toolbarSelectAllButtonItem = [[UIBarButtonItem alloc] initWithTitle:@"Select all" style:UIBarButtonItemStylePlain target:self action:@selector(selectAll)];
    self.toolbarDeselectAllButtonItem = [[UIBarButtonItem alloc] initWithTitle:@"Deselect all" style:UIBarButtonItemStylePlain target:self action:@selector(deselectAll)];
    self.toolbarDeleteButtonItem = [[UIBarButtonItem alloc] initWithTitle:@"Delete selected" style:UIBarButtonItemStylePlain target:self action:@selector(deleteSelectedShaders)];
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
    self.searchBar.placeholder = @"Search local shader packs...";
    self.emptyLabel.text = @"No shader packs found";
    self.emptyLabel.hidden = self.localShaders.count > 0;
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
        self.selectButtonItem.enabled = self.filteredLocalShaders.count > 0;
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

#pragma mark - Select Mode

// Enter selection mode
- (void)enterSelectMode {
    if (self.filteredLocalShaders.count == 0) return; // Do not allow entering selection mode when there is no data

    self.isSelectMode = YES;
    [self.selectedShaders removeAllObjects]; // Clear the selection list when entering selection mode
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
    [self.selectedShaders removeAllObjects]; // Clear all selections on exit
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
    if (self.selectedShaders.count == self.filteredLocalShaders.count) {
        [self deselectAll];
    } else {
        [self selectAll];
    }
}

// Select all: add every shader in the currently filtered list to the selection list
- (void)selectAll {
    [self.selectedShaders removeAllObjects];
    [self.selectedShaders addObjectsFromArray:self.filteredLocalShaders];
    [self updateNavigationButtons];
    [self reloadVisibleCellsCheckbox];
}

// Deselect all: clear the selection
- (void)deselectAll {
    [self.selectedShaders removeAllObjects];
    [self updateNavigationButtons];
    [self reloadVisibleCellsCheckbox];
}

// Delete the selected shaders (with a confirmation dialog)
- (void)deleteSelectedShaders {
    if (self.selectedShaders.count == 0) {
        [self showSimpleAlertWithTitle:@"Notice" message:@"No shader packs selected yet"];
        return;
    }

    NSString *message = [NSString stringWithFormat:@"Delete the %ld selected shader pack(s)?\nThis cannot be undone.", (long)self.selectedShaders.count];
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Delete multiple" message:message preferredStyle:UIAlertControllerStyleAlert];

    [alert addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    __weak typeof(self) weakSelf = self;
    [alert addAction:[UIAlertAction actionWithTitle:@"Delete" style:UIAlertActionStyleDestructive handler:^(UIAlertAction * _Nonnull action) {
        [weakSelf performDeleteSelectedShaders];
    }]];
    [self presentViewController:alert animated:YES completion:nil];
}

// Perform the bulk delete
- (void)performDeleteSelectedShaders {
    NSArray<ShaderItem *> *shadersToDelete = [self.selectedShaders copy];
    NSMutableArray<ShaderItem *> *failedShaders = [NSMutableArray array];

    for (ShaderItem *shader in shadersToDelete) {
        NSError *error = nil;
        BOOL success = [[ShaderService sharedService] deleteShader:shader error:&error];
        if (!success || error) {
            NSLog(@"[ShadersManager] Batch delete failed: %@ - %@", shader.displayName, error);
            [failedShaders addObject:shader];
        }
    }

    // Remove the successfully deleted shaders from the data source
    for (ShaderItem *shader in shadersToDelete) {
        if ([failedShaders containsObject:shader]) continue; // Skip the ones that failed to delete
        NSUInteger idxInFull = [self.localShaders indexOfObject:shader];
        if (idxInFull != NSNotFound) [self.localShaders removeObjectAtIndex:idxInFull];
        NSUInteger idxInFiltered = [self.filteredLocalShaders indexOfObject:shader];
        if (idxInFiltered != NSNotFound) [self.filteredLocalShaders removeObjectAtIndex:idxInFiltered];
    }

    // Clear the selection (the failed entries are no longer marked as selected)
    [self.selectedShaders removeAllObjects];

    if (failedShaders.count > 0) {
        // On a partial failure, stay in selection mode and tell the user which ones failed
        NSMutableArray<NSString *> *names = [NSMutableArray array];
        for (ShaderItem *s in failedShaders) [names addObject:s.displayName];
        [self showSimpleAlertWithTitle:[NSString stringWithFormat:@"Deletion finished, %ld item(s) failed", (long)failedShaders.count]
                               message:[names componentsJoinedByString:@"\n"]];
        [self updateNavigationButtons];
        [self.tableView reloadData];
    } else {
        // Everything was deleted, so leave selection mode
        [self exitSelectMode];
    }
}

// Determine whether the given shader is selected
- (BOOL)isShaderSelected:(ShaderItem *)shader {
    return [self.selectedShaders containsObject:shader];
}

// Toggle the selected state of a shader (triggered by a row tap)
- (void)toggleSelectionForShader:(ShaderItem *)shader {
    if ([self.selectedShaders containsObject:shader]) {
        [self.selectedShaders removeObject:shader];
    } else {
        [self.selectedShaders addObject:shader];
    }
    [self updateNavigationButtons];
}

// Update the navigation bar title with the number selected
- (void)updateSelectModeTitle {
    if (self.isSelectMode) {
        self.title = [NSString stringWithFormat:@"%ld selected", (long)self.selectedShaders.count];
    }
}

// Update the title of the "Select all" button (showing "Deselect all" when everything is selected)
- (void)updateSelectAllButtonTitle {
    if (self.selectedShaders.count > 0 && self.selectedShaders.count == self.filteredLocalShaders.count && self.filteredLocalShaders.count > 0) {
        self.navSelectAllButtonItem.title = @"Deselect all";
        self.toolbarSelectAllButtonItem.enabled = NO;
        self.toolbarDeselectAllButtonItem.enabled = YES;
    } else if (self.selectedShaders.count == 0) {
        self.navSelectAllButtonItem.title = @"Select all";
        self.toolbarSelectAllButtonItem.enabled = YES;
        self.toolbarDeselectAllButtonItem.enabled = NO;
    } else {
        self.navSelectAllButtonItem.title = @"Select all";
        self.toolbarSelectAllButtonItem.enabled = YES;
        self.toolbarDeselectAllButtonItem.enabled = YES;
    }
    // Disable the select-all buttons when there is no data
    if (self.filteredLocalShaders.count == 0) {
        self.navSelectAllButtonItem.enabled = NO;
        self.toolbarSelectAllButtonItem.enabled = NO;
        self.toolbarDeselectAllButtonItem.enabled = NO;
    } else {
        self.navSelectAllButtonItem.enabled = YES;
    }
    // Delete button: disabled when nothing is selected
    self.toolbarDeleteButtonItem.enabled = self.selectedShaders.count > 0;
}

// Refresh the checkbox state of every visible cell (avoiding the flicker of a full reloadData)
- (void)reloadVisibleCellsCheckbox {
    for (NSIndexPath *indexPath in [self.tableView indexPathsForVisibleRows]) {
        UITableViewCell *cell = [self.tableView cellForRowAtIndexPath:indexPath];
        if (!cell) continue;
        ShaderItem *shader = self.filteredLocalShaders[indexPath.row];
        [self applyCheckboxToCell:cell selected:[self isShaderSelected:shader]];
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
        // Hide openLinkButton to avoid a visual clash with the checkbox (a shader's enableSwitch is hidden by default)
        if ([cell isKindOfClass:[ShaderTableViewCell class]]) {
            ShaderTableViewCell *shaderCell = (ShaderTableViewCell *)cell;
            shaderCell.openLinkButton.hidden = YES;
        }
    } else {
        // Normal mode: clear the checkbox and restore the original controls
        cell.accessoryView = nil;
        cell.selectionStyle = UITableViewCellSelectionStyleNone;
        if ([cell isKindOfClass:[ShaderTableViewCell class]]) {
            ShaderTableViewCell *shaderCell = (ShaderTableViewCell *)cell;
            // The final visibility of openLinkButton is determined by what configureWithShader sets
            shaderCell.openLinkButton.hidden = NO;
        }
    }
}

#pragma mark - Import Shader

- (void)importShaderTapped {
    NSError *dirError = nil;
    NSString *shadersDir = [[ShaderService sharedService] ensureShadersFolderForProfile:nil error:&dirError];
    if (!shadersDir) {
        [self showSimpleAlertWithTitle:@"Cannot import" message:dirError.localizedDescription ?: @"Could not determine the shaderpacks folder"];
        return;
    }

    // Shader packs are usually in zip format
    UIDocumentPickerViewController *picker = [[UIDocumentPickerViewController alloc] initWithDocumentTypes:@[@"public.zip-archive", @"public.item"] inMode:UIDocumentPickerModeImport];
    picker.allowsMultipleSelection = YES;
    picker.delegate = self;
    picker.title = @"Choose shader pack file";
    [self presentViewController:picker animated:YES completion:nil];
}

- (void)documentPicker:(UIDocumentPickerViewController *)controller didPickDocumentsAtURLs:(NSArray<NSURL *> *)urls {
    if (urls.count == 0) return;

    NSError *dirError = nil;
    NSString *shadersDir = [[ShaderService sharedService] ensureShadersFolderForProfile:nil error:&dirError];
    if (!shadersDir) {
        [self showSimpleAlertWithTitle:@"Import failed" message:dirError.localizedDescription ?: @"Could not determine the shaderpacks folder"];
        return;
    }

    NSFileManager *fm = [NSFileManager defaultManager];
    NSInteger successCount = 0;
    NSMutableArray<NSString *> *failedFiles = [NSMutableArray array];

    for (NSURL *url in urls) {
        BOOL accessing = [url startAccessingSecurityScopedResource];
        @try {
            NSString *fileName = url.lastPathComponent;
            NSString *destPath = [shadersDir stringByAppendingPathComponent:fileName];

            if ([fm fileExistsAtPath:destPath]) {
                NSString *baseName = [fileName stringByDeletingPathExtension];
                NSString *ext = [fileName pathExtension];
                destPath = [shadersDir stringByAppendingPathComponent:[NSString stringWithFormat:@"%@_copy.%@", baseName, ext]];
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

    [self refreshLocalShadersList];

    if (failedFiles.count > 0) {
        [self showSimpleAlertWithTitle:[NSString stringWithFormat:@"Import finished (%ld succeeded, %ld failed)", (long)successCount, (long)failedFiles.count]
                               message:[failedFiles componentsJoinedByString:@"\n"]];
    } else {
        NSLog(@"[ShadersManager] Successfully imported %ld shader packs", (long)successCount);
    }
}



#pragma mark - Check for Updates

- (void)checkForUpdates {
    // Convert the local ShaderItem list into a ModItem list to fit ModUpdateViewController
    NSArray<ModItem *> *mods = [self convertShadersToMods:self.localShaders];
    if (mods.count == 0) {
        [self showSimpleAlertWithTitle:@"Notice" message:@"There are no local shader packs, so there is nothing to check for updates."];
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

- (NSArray<ModItem *> *)convertShadersToMods:(NSArray<ShaderItem *> *)shaders {
    NSMutableArray<ModItem *> *result = [NSMutableArray arrayWithCapacity:shaders.count];
    for (ShaderItem *shader in shaders) {
        ModItem *mod = [[ModItem alloc] init];
        mod.filePath = shader.filePath;
        mod.fileSHA1 = shader.fileSHA1;
        mod.version = shader.version;
        mod.fileName = shader.fileName;
        mod.displayName = shader.displayName;
        [result addObject:mod];
    }
    return result;
}

- (void)presentModUpdateViewControllerWithMods:(NSArray *)mods gameVersion:(NSString *)gameVersion loader:(NSString *)loader {
    ModUpdateViewController *vc = [[ModUpdateViewController alloc] initWithMods:mods gameVersion:gameVersion loader:loader projectType:@"shader"];
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
    [self refreshLocalShadersList];
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

#pragma mark - UISearchBarDelegate

- (void)searchBar:(UISearchBar *)searchBar textDidChange:(NSString *)searchText {
    [self filterLocalShaders];
}

- (void)searchBarSearchButtonClicked:(UISearchBar *)searchBar {
    [searchBar resignFirstResponder];
}

- (void)searchBarCancelButtonClicked:(UISearchBar *)searchBar {
    searchBar.text = @"";
    [searchBar resignFirstResponder];
    [self filterLocalShaders];
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
        self.emptyLabel.text = @"No local shader packs found";
    }
    // Update the navigation button state (whether "Select" is enabled, the "Select all" title and so on)
    [self updateNavigationButtons];
    [self.tableView reloadData];
}

#pragma mark - UITableView DataSource & Delegate

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    return self.filteredLocalShaders.count;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    ShaderTableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"ShaderCell" forIndexPath:indexPath];
    cell.delegate = self;

    ShaderItem *shader = self.filteredLocalShaders[indexPath.row];
    [cell configureWithShader:shader displayMode:ShaderTableViewCellDisplayModeLocal];

    // Show or hide the checkboxes according to selection mode
    if (self.isSelectMode) {
        [self applyCheckboxToCell:cell selected:[self isShaderSelected:shader]];
    } else {
        [self applyCheckboxToCell:cell selected:NO];
    }

    // Adapt to the custom launcher background: give the cell a frosted-glass/translucent effect
    // ShaderTableViewCell sets its own contentView background to clearColor; BackgroundManager injects it uniformly
    [[BackgroundManager sharedManager] applyEffectToCell:cell];

    return cell;
}

- (UISwipeActionsConfiguration *)tableView:(UITableView *)tableView trailingSwipeActionsConfigurationForRowAtIndexPath:(NSIndexPath *)indexPath {
    // Disable swipe-to-delete in selection mode, to avoid mistakes
    if (self.isSelectMode) return nil;

    UIContextualAction *deleteAction = [UIContextualAction contextualActionWithStyle:UIContextualActionStyleDestructive title:@"Delete" handler:^(UIContextualAction * _Nonnull action, __kindof UIView * _Nonnull sourceView, void (^ _Nonnull completionHandler)(BOOL)) {

        ShaderItem *shaderToDelete = self.filteredLocalShaders[indexPath.row];

        UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Confirm delete" message:[NSString stringWithFormat:@"Delete %@?\nThis cannot be undone.", shaderToDelete.displayName] preferredStyle:UIAlertControllerStyleAlert];

        [alert addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:^(UIAlertAction * _Nonnull action) {
            completionHandler(NO);
        }]];

        [alert addAction:[UIAlertAction actionWithTitle:@"Delete" style:UIAlertActionStyleDestructive handler:^(UIAlertAction * _Nonnull action) {
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
    // The online download entry has been removed (use the download screen); this method is kept to satisfy the protocol
}

#pragma mark - ShaderVersionViewControllerDelegate

- (void)shaderVersionViewController:(ShaderVersionViewController *)viewController didSelectVersion:(ShaderVersion *)version {
    ShaderItem *itemToDownload = viewController.shaderItem;

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

- (void)startDownloadForItem:(ShaderItem *)item {
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

    [[ShaderService sharedService] downloadShader:item toProfile:self.profileName completion:^(NSError * _Nullable error) {
        dispatch_async(dispatch_get_main_queue(), ^{
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

- (void)showDownloadResultAlertForItem:(ShaderItem *)item error:(NSError *)error {
    if (error) {
        [self showSimpleAlertWithTitle:@"Download failed" message:error.localizedDescription];
    } else {
        UIAlertController *successAlert = [UIAlertController alertControllerWithTitle:@"Download complete"
                                                                              message:[NSString stringWithFormat:@"%@ was installed successfully.", item.displayName]
                                                                       preferredStyle:UIAlertControllerStyleAlert];
        [successAlert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:^(UIAlertAction * _Nonnull action) {
            // After user acknowledges, refresh local shaders list
            [self refreshLocalShadersList];
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
        // In selection mode: tapping a row toggles that shader's selected state
        ShaderItem *shader = self.filteredLocalShaders[indexPath.row];
        [self toggleSelectionForShader:shader];
        // Update the checkbox of that cell directly, avoiding the flicker of a full reload
        UITableViewCell *cell = [tableView cellForRowAtIndexPath:indexPath];
        if (cell) {
            [self applyCheckboxToCell:cell selected:[self isShaderSelected:shader]];
        }
        // Clear the selection highlight
        [tableView deselectRowAtIndexPath:indexPath animated:YES];
    } else {
        // Normal mode: only clear the highlight, with no other action
        [tableView deselectRowAtIndexPath:indexPath animated:YES];
    }
}

// Shader toggle feature disabled - shader management is only for viewing and deleting
- (void)shaderCellDidTapToggle:(UITableViewCell *)cell {
    // Feature disabled
}

- (void)shaderCellDidTapOpenLink:(UITableViewCell *)cell {
    NSIndexPath *indexPath = [self.tableView indexPathForCell:cell];
    if (!indexPath) return;

    ShaderItem *shaderItem = self.filteredLocalShaders[indexPath.row];

    if (shaderItem.onlineID && shaderItem.onlineID.length > 0) {
        NSString *urlString = [NSString stringWithFormat:@"https://modrinth.com/shader/%@", shaderItem.onlineID];
        NSURL *url = [NSURL URLWithString:urlString];
        if (url) {
            [[UIApplication sharedApplication] openURL:url options:@{} completionHandler:nil];
        }
    } else {
        UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Link unavailable" message:@"This shader pack has no online link available." preferredStyle:UIAlertControllerStyleAlert];
        [alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
        [self presentViewController:alert animated:YES completion:nil];
    }
}

@end
