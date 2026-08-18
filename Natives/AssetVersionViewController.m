//
//  AssetVersionViewController.m
//  Amethyst
//
// Implementation of the generic asset version picker view controller
// Phase 3 alignment: reworked into an FCL-style chip filter bar (game version + sort), matching ModVersionViewController
// Asset types (resource pack/data pack/world) have no loader, so there is no loader filter row and no source switch (Modrinth only)
// Reuses ModrinthAPI's getVersionsForModWithID: (the API endpoint is the same for every project_type)
//

#import "AssetVersionViewController.h"
#import "installer/modpack/ModrinthAPI.h"
#import "ModVersion.h"
#import "ModVersionTableViewCell.h"
#import "AssetDetailHeaderView.h"
#import "BackgroundManager.h"

// ============================================================================
// Sort constants (kept in sync with ModVersionViewController, phase 3 alignment)
// ============================================================================
static NSString *const kSortRelevance = @"relevance"; // Relevance (keeps the original API order)
static NSString *const kSortDownloads = @"downloads"; // Downloads (not available at version level, so it falls back to the original order)
static NSString *const kSortUpdated   = @"updated";   // Recently updated (datePublished descending)
static NSString *const kSortCreated   = @"created";   // Created (datePublished ascending)

// Display text for the sort options (one per constant, used to render the chips)
static NSArray<NSDictionary *> *SortOptionItems(void) {
    static NSArray *items = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        items = @[
            @{ @"key": kSortRelevance, @"title": @"Relevance" },
            @{ @"key": kSortDownloads, @"title": @"Downloads" },
            @{ @"key": kSortUpdated,   @"title": @"Recently updated" },
            @{ @"key": kSortCreated,   @"title": @"Created" },
        ];
    });
    return items;
}

@interface AssetVersionViewController () <UITableViewDataSource, UITableViewDelegate>

// Main table view (shows the version list)
@property (nonatomic, strong) UITableView *tableView;
@property (nonatomic, strong) UIActivityIndicatorView *activityIndicator;

// ===== Side filter panel (phase 3 alignment: modelled on the horizontally scrolling chip bar of ModVersionViewController) =====
// Filter panel container (translucent + frosted glass, pinned above the tableView and not scrolling with the list)
@property (nonatomic, strong) UIView *filterContainerView;
// Main vertical stack (holds the 2 filter rows: version / sort; asset types have no loader or download source)
@property (nonatomic, strong) UIStackView *filterMainStack;

// --- Game version filter row ---
@property (nonatomic, strong) UIScrollView *versionScrollView;
@property (nonatomic, strong) UIStackView  *versionChipStack;

// --- Sort filter row ---
@property (nonatomic, strong) UIScrollView *sortScrollView;
@property (nonatomic, strong) UIStackView  *sortChipStack;

// ===== Currently selected filter state =====
@property (nonatomic, copy)   NSString *selectedSort;    // Sort key

// ===== Data sources =====
@property (nonatomic, strong) NSArray<ModVersion *> *allVersions;
@property (nonatomic, strong) NSArray<ModVersion *> *filteredVersions;

// The available filter options (extracted dynamically from the version data)
@property (nonatomic, strong) NSArray<NSString *> *availableGameVersions;

// Currently selected version ("All" means no filtering)
@property (nonatomic, strong) NSString *selectedGameVersion;

// Project detail header view (shows the cover image, title, author, downloads, tags and description, filling the information gap)
@property (nonatomic, strong) AssetDetailHeaderView *detailHeaderView;

@end

@implementation AssetVersionViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = [UIColor systemBackgroundColor];
    self.title = self.projectDisplayName ?: [self titleForAssetType];
    // Adapt to the custom launcher background: make this VC transparent so the global background image/blur shows through
    [[BackgroundManager sharedManager] makeViewControllerTransparent:self];

    // Initialize the filter state (sorted by relevance by default, matching ModVersionViewController)
    self.selectedSort = kSortRelevance;

    [self setupSideFilterPanel];
    [self setupTableView];
    [self setupActivityIndicator];
    [self setupDetailHeader];

    // Make the tableView background transparent so it does not hide the global background
    self.tableView.backgroundColor = [UIColor clearColor];
    self.tableView.backgroundView = nil;

    [self fetchVersions];

    // Listen for background effect changes so transparency is re-applied when the background is switched
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(reapplyBackgroundEffect)
                                                 name:@"BackgroundUIEffectChanged"
                                               object:nil];
}

- (void)reapplyBackgroundEffect {
    // Re-apply transparency to this VC when the background effect changes
    [[BackgroundManager sharedManager] makeViewControllerTransparent:self];
    // Reset the tableView background to transparent so the global background still shows after an effect switch
    self.tableView.backgroundColor = [UIColor clearColor];
    self.tableView.backgroundView = nil;
}

- (void)dealloc {
    // Remove the notification observer to avoid crashing on notifications delivered after dealloc
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

#pragma mark - Detail Header（项目信息展示）

/// Build and configure the project detail header view and set it as tableView.tableHeaderView
/// Fills the gap where earlier version pages showed no project cover image, title, author, downloads, tags or description
- (void)setupDetailHeader {
    self.detailHeaderView = [[AssetDetailHeaderView alloc] init];

    // Recompute the header height when the description expands/collapses (weak reference to avoid a retain cycle)
    __weak typeof(self) weakSelf = self;
    self.detailHeaderView.onSizeChanged = ^{
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (strongSelf) [strongSelf updateTableHeaderHeight];
    };

    // Pick the placeholder SF Symbol and color based on assetType (matching the asset-type colors of ModernAssetCell)
    NSString *placeholderSymbol = @"doc.fill";
    UIColor *placeholderColor = [UIColor systemBlueColor];
    switch (self.assetType) {
        case AssetVersionTypeResourcePack:
            placeholderSymbol = @"photo.stack.fill";
            placeholderColor = [UIColor systemBlueColor];
            break;
        case AssetVersionTypeDataPack:
            placeholderSymbol = @"doc.text.fill";
            placeholderColor = [UIColor systemTealColor];
            break;
        case AssetVersionTypeWorld:
            placeholderSymbol = @"globe";
            placeholderColor = [UIColor systemGreenColor];
            break;
    }

    // Fill in the project display information passed by DownloadViewController
    [self.detailHeaderView configureWithIconURL:self.projectIconURL
                                          title:self.projectDisplayName ?: @"Unknown project"
                                         author:self.projectAuthor
                                      downloads:self.projectDownloads
                                          likes:self.projectLikes
                                descriptionText:self.projectDescription
                                    categories:self.projectCategories
                                   lastUpdated:self.projectLastUpdated
                           placeholderSymbolName:placeholderSymbol
                               placeholderColor:placeholderColor];

    [self updateTableHeaderHeight];
    self.tableView.tableHeaderView = self.detailHeaderView;
}

/// Recompute the tableHeaderView height and refresh (called from viewDidLayoutSubviews and when the description expands/collapses)
- (void)updateTableHeaderHeight {
    if (!self.detailHeaderView) return;
    CGFloat width = self.tableView.bounds.size.width;
    if (width <= 0) width = self.view.bounds.size.width;
    if (width <= 0) width = [UIScreen mainScreen].bounds.size.width;
    CGFloat height = [self.detailHeaderView fittingHeightForWidth:width];
    CGRect frame = self.detailHeaderView.frame;
    if (fabs(frame.size.height - height) < 1) return; // Skip if the height has not changed
    frame.size.height = height;
    self.detailHeaderView.frame = frame;
    // Reassigning triggers the tableView to lay the header out again
    self.tableView.tableHeaderView = self.detailHeaderView;
}

- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    // The tableView width is only known after the first layout, so update the header height once here
    if (self.detailHeaderView) {
        [self updateTableHeaderHeight];
    }
}

// Return the default navigation bar title for the asset type
- (NSString *)titleForAssetType {
    switch (self.assetType) {
        case AssetVersionTypeResourcePack: return @"Select resource pack version";
        case AssetVersionTypeDataPack:     return @"Select data pack version";
        case AssetVersionTypeWorld:        return @"Select world version";
    }
    return @"Select version";
}

#pragma mark - 侧边筛选面板（chips 筛选条，阶段3统一）

/// Build the filter panel container plus the 2 chip rows (game version + sort)
/// Modelled on setupSideFilterPanel in ModVersionViewController, minus the download source and loader rows
- (void)setupSideFilterPanel {
    // ===== Filter panel container (translucent + frosted glass, pinned at the top and not scrolling with the list) =====
    self.filterContainerView = [[UIView alloc] init];
    self.filterContainerView.translatesAutoresizingMaskIntoConstraints = NO;
    self.filterContainerView.backgroundColor = [[UIColor whiteColor] colorWithAlphaComponent:0.06];
    self.filterContainerView.layer.cornerRadius = 14;
    self.filterContainerView.layer.cornerCurve = kCACornerCurveContinuous;
    self.filterContainerView.layer.borderWidth = 0.5;
    self.filterContainerView.layer.borderColor = [[UIColor whiteColor] colorWithAlphaComponent:0.10].CGColor;
    [self.view addSubview:self.filterContainerView];
    // Apply the frosted-glass background effect for consistency with the launcher style
    [[BackgroundManager sharedManager] applyEffectToView:self.filterContainerView];

    // ===== Main vertical stack (2 filter rows, each = icon label + horizontally scrolling chips) =====
    self.filterMainStack = [[UIStackView alloc] init];
    self.filterMainStack.translatesAutoresizingMaskIntoConstraints = NO;
    self.filterMainStack.axis = UILayoutConstraintAxisVertical;
    self.filterMainStack.spacing = 4;
    self.filterMainStack.alignment = UIStackViewAlignmentFill;
    [self.filterContainerView addSubview:self.filterMainStack];

    // ----- Row 1: game version filter (filled in dynamically, showing "Loading" at first) -----
    {
        UIScrollView *scrollOut = nil;
        UIStackView *chipOut = nil;
        UIStackView *versionRow = [self createFilterRowWithIconName:@"gamecontroller.fill"
                                                              label:@"Version"
                                                         scrollStackOut:&scrollOut
                                                           chipStackOut:&chipOut];
        self.versionScrollView = scrollOut;
        self.versionChipStack = chipOut;
        [self.filterMainStack addArrangedSubview:versionRow];
    }
    [self addChipToStack:self.versionChipStack title:@"Loading..." selected:NO action:NULL];

    // ----- Row 2: sort filter (relevance / downloads / recently updated / created) -----
    {
        UIScrollView *scrollOut = nil;
        UIStackView *chipOut = nil;
        UIStackView *sortRow = [self createFilterRowWithIconName:@"arrow.up.arrow.down"
                                                           label:@"Sort"
                                                      scrollStackOut:&scrollOut
                                                        chipStackOut:&chipOut];
        self.sortScrollView = scrollOut;
        self.sortChipStack = chipOut;
        [self.filterMainStack addArrangedSubview:sortRow];
    }
    [self rebuildSortChips];

    // ===== Container constraints: flush with the top of the safe area, 8pt margin on each side =====
    [NSLayoutConstraint activateConstraints:@[
        [self.filterContainerView.topAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.topAnchor constant:6],
        [self.filterContainerView.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor constant:8],
        [self.filterContainerView.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor constant:-8],
        // Padding inside the main stack
        [self.filterMainStack.topAnchor constraintEqualToAnchor:self.filterContainerView.topAnchor constant:8],
        [self.filterMainStack.bottomAnchor constraintEqualToAnchor:self.filterContainerView.bottomAnchor constant:-8],
        [self.filterMainStack.leadingAnchor constraintEqualToAnchor:self.filterContainerView.leadingAnchor constant:10],
        [self.filterMainStack.trailingAnchor constraintEqualToAnchor:self.filterContainerView.trailingAnchor constant:-10],
    ]];
}

/// Build one filter row: icon + label on the left (fixed width), horizontally scrolling chips on the right
/// Modelled on createFilterRowWithIconName in ModVersionViewController (phase 3 alignment)
- (UIStackView *)createFilterRowWithIconName:(NSString *)iconName
                                       label:(NSString *)labelText
                                scrollStackOut:(UIScrollView **)scrollStackOut
                                  chipStackOut:(UIStackView **)chipStackOut {
    // --- Left: icon + label (fixed width, does not scroll with the chips) ---
    UIImageView *iconView = [[UIImageView alloc] init];
    iconView.translatesAutoresizingMaskIntoConstraints = NO;
    iconView.image = [UIImage systemImageNamed:iconName];
    iconView.tintColor = [UIColor secondaryLabelColor];
    iconView.contentMode = UIViewContentModeScaleAspectFit;
    [iconView setContentHuggingPriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisHorizontal];
    [iconView setContentCompressionResistancePriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisHorizontal];
    [NSLayoutConstraint activateConstraints:@[
        [iconView.widthAnchor constraintEqualToConstant:15],
        [iconView.heightAnchor constraintEqualToConstant:15],
    ]];

    UILabel *label = [[UILabel alloc] init];
    label.translatesAutoresizingMaskIntoConstraints = NO;
    label.text = labelText;
    label.font = [UIFont systemFontOfSize:11 weight:UIFontWeightMedium];
    label.textColor = [UIColor secondaryLabelColor];
    label.textAlignment = NSTextAlignmentLeft;
    [label setContentHuggingPriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisHorizontal];
    [label setContentCompressionResistancePriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisHorizontal];
    [label.widthAnchor constraintEqualToConstant:34].active = YES;

    UIStackView *labelStack = [[UIStackView alloc] initWithArrangedSubviews:@[iconView, label]];
    labelStack.translatesAutoresizingMaskIntoConstraints = NO;
    labelStack.axis = UILayoutConstraintAxisHorizontal;
    labelStack.spacing = 3;
    labelStack.alignment = UIStackViewAlignmentCenter;
    [labelStack setContentHuggingPriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisHorizontal];

    // --- Right: horizontally scrolling chip container ---
    UIScrollView *scrollView = [[UIScrollView alloc] init];
    scrollView.translatesAutoresizingMaskIntoConstraints = NO;
    scrollView.showsHorizontalScrollIndicator = NO;
    scrollView.alwaysBounceHorizontal = YES;

    UIStackView *chipStack = [[UIStackView alloc] init];
    chipStack.translatesAutoresizingMaskIntoConstraints = NO;
    chipStack.axis = UILayoutConstraintAxisHorizontal;
    chipStack.spacing = 6;
    chipStack.alignment = UIStackViewAlignmentCenter;
    [scrollView addSubview:chipStack];

    // chipStack fills the scrollView contentLayoutGuide, with its height matching frameLayoutGuide
    [NSLayoutConstraint activateConstraints:@[
        [chipStack.topAnchor constraintEqualToAnchor:scrollView.contentLayoutGuide.topAnchor],
        [chipStack.bottomAnchor constraintEqualToAnchor:scrollView.contentLayoutGuide.bottomAnchor],
        [chipStack.leadingAnchor constraintEqualToAnchor:scrollView.contentLayoutGuide.leadingAnchor],
        [chipStack.trailingAnchor constraintEqualToAnchor:scrollView.contentLayoutGuide.trailingAnchor],
        [chipStack.heightAnchor constraintEqualToAnchor:scrollView.frameLayoutGuide.heightAnchor],
    ]];

    // Properties handed back to the caller
    if (scrollStackOut) *scrollStackOut = scrollView;
    if (chipStackOut) *chipStackOut = chipStack;

    // --- Row container: label + scroll view laid out horizontally ---
    UIStackView *row = [[UIStackView alloc] initWithArrangedSubviews:@[labelStack, scrollView]];
    row.translatesAutoresizingMaskIntoConstraints = NO;
    row.axis = UILayoutConstraintAxisHorizontal;
    row.spacing = 6;
    row.alignment = UIStackViewAlignmentCenter;
    // Fixed row height so the total height stays predictable
    [row.heightAnchor constraintEqualToConstant:30].active = YES;
    return row;
}

/// Build a single filter chip button (pill style, modelled on ModVersionViewController)
/// Selected: theme color (systemBlue) background + white text. Unselected: translucent background + label-colored text + light border
- (UIButton *)createFilterChipWithTitle:(NSString *)title selected:(BOOL)selected {
    UIButton *chip = [UIButton buttonWithType:UIButtonTypeSystem];
    chip.translatesAutoresizingMaskIntoConstraints = NO;
    [chip setTitle:title forState:UIControlStateNormal];
    chip.titleLabel.font = [UIFont systemFontOfSize:12 weight:UIFontWeightMedium];
    chip.titleLabel.adjustsFontSizeToFitWidth = YES;
    chip.titleLabel.minimumScaleFactor = 0.75;
    chip.contentEdgeInsets = UIEdgeInsetsMake(4, 12, 4, 12);
    chip.layer.cornerRadius = 14;
    chip.layer.cornerCurve = kCACornerCurveContinuous;
    chip.layer.masksToBounds = YES;
    // Fixed height so the row does not jump when the content changes
    [chip.heightAnchor constraintEqualToConstant:28].active = YES;
    [chip setContentHuggingPriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisHorizontal];
    [chip setContentCompressionResistancePriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisHorizontal];
    [self applyChipStyle:chip selected:selected];
    return chip;
}

/// Apply the selected/unselected chip style (matching ModVersionViewController, phase 3 alignment)
- (void)applyChipStyle:(UIButton *)chip selected:(BOOL)selected {
    if (selected) {
        // Selected: theme color background + white text (following how FCL highlights selected tags)
        chip.backgroundColor = [UIColor systemBlueColor];
        [chip setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
        chip.layer.borderWidth = 0;
    } else {
        // Unselected: translucent background + label-colored text + light border
        chip.backgroundColor = [[UIColor whiteColor] colorWithAlphaComponent:0.08];
        [chip setTitleColor:[UIColor labelColor] forState:UIControlStateNormal];
        chip.layer.borderWidth = 0.5;
        chip.layer.borderColor = [[UIColor whiteColor] colorWithAlphaComponent:0.15].CGColor;
    }
}

/// Add a chip to chipStack (applying the style and wiring up the tap handler)
- (void)addChipToStack:(UIStackView *)stack title:(NSString *)title selected:(BOOL)selected action:(void(^)(void))action {
    UIButton *chip = [self createFilterChipWithTitle:title selected:selected];
    if (action) {
        [chip addAction:[UIAction actionWithTitle:title image:nil identifier:nil handler:^(__kindof UIAction * _Nonnull act) {
            action();
        }] forControlEvents:UIControlEventTouchUpInside];
    }
    [stack addArrangedSubview:chip];
}

/// Rebuild the game version chips (replacing "Loading..." with the real data)
- (void)rebuildVersionChips {
    // Clear the old chips
    for (UIView *v in self.versionChipStack.arrangedSubviews) {
        [self.versionChipStack removeArrangedSubview:v];
        [v removeFromSuperview];
    }
    // Add the new chips
    for (NSString *version in self.availableGameVersions) {
        BOOL isSelected = [self.selectedGameVersion isEqualToString:version];
        __weak typeof(self) weakSelf = self;
        [self addChipToStack:self.versionChipStack title:version selected:isSelected action:^{
            __strong typeof(weakSelf) strongSelf = weakSelf;
            if (!strongSelf) return;
            if ([strongSelf.selectedGameVersion isEqualToString:version]) return;
            strongSelf.selectedGameVersion = version;
            // Update the chip selection state
            for (UIView *v in strongSelf.versionChipStack.arrangedSubviews) {
                if ([v isKindOfClass:[UIButton class]]) {
                    UIButton *chip = (UIButton *)v;
                    [strongSelf applyChipStyle:chip selected:[chip.titleLabel.text isEqualToString:version]];
                }
            }
            [strongSelf applyFiltersAndSort];
        }];
    }
    // Scroll to the selected chip
    [self scrollToSelectedChipInStack:self.versionChipStack withTitle:self.selectedGameVersion];
}

/// Rebuild the sort chips (static options)
- (void)rebuildSortChips {
    // Clear the old chips
    for (UIView *v in self.sortChipStack.arrangedSubviews) {
        [self.sortChipStack removeArrangedSubview:v];
        [v removeFromSuperview];
    }
    // Add the new chips
    for (NSDictionary *item in SortOptionItems()) {
        NSString *key = item[@"key"];
        NSString *title = item[@"title"];
        BOOL isSelected = [self.selectedSort isEqualToString:key];
        __weak typeof(self) weakSelf = self;
        [self addChipToStack:self.sortChipStack title:title selected:isSelected action:^{
            __strong typeof(weakSelf) strongSelf = weakSelf;
            if (!strongSelf) return;
            if ([strongSelf.selectedSort isEqualToString:key]) return;
            strongSelf.selectedSort = key;
            // Update the chip selection state (the key is stored in accessibilityIdentifier)
            for (UIView *v in strongSelf.sortChipStack.arrangedSubviews) {
                if ([v isKindOfClass:[UIButton class]]) {
                    UIButton *chip = (UIButton *)v;
                    [strongSelf applyChipStyle:chip selected:[chip.titleLabel.text isEqualToString:title]];
                }
            }
            [strongSelf applyFiltersAndSort];
        }];
    }
    [self scrollToSelectedChipInStack:self.sortChipStack withTitle:nil];
}

/// Scroll to the selected chip (if it is outside the visible area)
- (void)scrollToSelectedChipInStack:(UIStackView *)stack withTitle:(NSString *)title {
    if (!title) return;
    for (UIView *v in stack.arrangedSubviews) {
        if ([v isKindOfClass:[UIButton class]]) {
            UIButton *chip = (UIButton *)v;
            if ([chip.titleLabel.text isEqualToString:title]) {
                UIScrollView *scrollView = (UIScrollView *)stack.superview;
                if ([scrollView isKindOfClass:[UIScrollView class]]) {
                    CGRect chipFrame = [chip convertRect:chip.bounds toView:scrollView];
                    CGFloat targetX = chipFrame.origin.x - scrollView.bounds.size.width / 2 + chipFrame.size.width / 2;
                    targetX = MAX(0, targetX);
                    [scrollView scrollRectToVisible:CGRectMake(targetX, 0, scrollView.bounds.size.width, scrollView.bounds.size.height) animated:YES];
                }
                break;
            }
        }
    }
}

#pragma mark - TableView Setup

- (void)setupTableView {
    self.tableView = [[UITableView alloc] initWithFrame:CGRectZero style:UITableViewStylePlain];
    self.tableView.translatesAutoresizingMaskIntoConstraints = NO;
    self.tableView.dataSource = self;
    self.tableView.delegate = self;
    self.tableView.separatorStyle = UITableViewCellSeparatorStyleNone;
    [self.tableView registerClass:[ModVersionTableViewCell class] forCellReuseIdentifier:@"AssetVersionCell"];
    [self.view addSubview:self.tableView];

    [NSLayoutConstraint activateConstraints:@[
        [self.tableView.topAnchor constraintEqualToAnchor:self.filterContainerView.bottomAnchor constant:8],
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

#pragma mark - 数据获取

- (void)fetchVersions {
    if (!self.projectID.length) {
        NSLog(@"[AssetVersionVC] Missing projectID, cannot fetch version list");
        return;
    }

    [self.activityIndicator startAnimating];
    // Reuses getVersionsForModWithID: (the Modrinth /project/<id>/version endpoint is the same for every project_type)
    [[ModrinthAPI sharedInstance] getVersionsForModWithID:self.projectID completion:^(NSArray<ModVersion *> * _Nullable versions, NSError * _Nullable error) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [self.activityIndicator stopAnimating];
            if (error) {
                NSLog(@"[AssetVersionVC] Failed to fetch version list: %@", error);
                UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Error"
                                                                                message:@"Could not fetch version information"
                                                                         preferredStyle:UIAlertControllerStyleAlert];
                [alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
                [self presentViewController:alert animated:YES completion:nil];
                return;
            }
            self.allVersions = versions ?: @[];
            [self processFilters];
            [self applyFiltersAndSort];
        });
    }];
}

#pragma mark - 筛选 + 排序

- (void)processFilters {
    NSMutableSet<NSString *> *gameVersions = [NSMutableSet setWithObject:@"All"];

    for (ModVersion *version in self.allVersions) {
        for (NSString *gameVersion in version.gameVersions) {
            [gameVersions addObject:gameVersion];
        }
    }

    // Game versions are sorted by semantic version, newest first, with "All" always in front
    self.availableGameVersions = [[gameVersions allObjects] sortedArrayUsingComparator:^NSComparisonResult(NSString *obj1, NSString *obj2) {
        if ([obj1 isEqualToString:@"All"]) return NSOrderedAscending;
        if ([obj2 isEqualToString:@"All"]) return NSOrderedDescending;
        return [obj2 compare:obj1 options:NSNumericSearch];
    }];

    // FCL style: "All" is selected by default, but if preferredGameVersion is in the list it is selected automatically
    // Phase 3 alignment: add the preferred auto-selection logic that was missing compared with ModVersionViewController
    self.selectedGameVersion = self.availableGameVersions.firstObject ?: @"All";

    // Auto-select the preferred version (case-insensitive comparison)
    if (self.preferredGameVersion.length > 0) {
        NSString *preferred = self.preferredGameVersion;
        for (NSString *gv in self.availableGameVersions) {
            if ([gv caseInsensitiveCompare:preferred] == NSOrderedSame) {
                self.selectedGameVersion = gv;
                break;
            }
        }
    }

    // Rebuild the version chips (replacing "Loading..." with the real data)
    [self rebuildVersionChips];
}

/// Apply the filters and sorting, then refresh the table
/// Filter by game version first, then sort, then move versions matching preferred to the top
- (void)applyFiltersAndSort {
    // ----- 1. Filter: game version (asset types have no loader) -----
    NSPredicate *predicate = [NSPredicate predicateWithBlock:^BOOL(ModVersion *evaluatedObject, NSDictionary *bindings) {
        return [self.selectedGameVersion isEqualToString:@"All"] ||
               [evaluatedObject.gameVersions containsObject:self.selectedGameVersion];
    }];
    NSArray<ModVersion *> *filtered = [self.allVersions filteredArrayUsingPredicate:predicate];

    // ----- 2. Sort: by the selected sort option -----
    NSArray<ModVersion *> *sorted = [self sortVersions:filtered];

    // ----- 3. FCL style: move versions matching preferred to the top -----
    // Phase 3 alignment: add the preferred pin-to-top logic that was missing compared with ModVersionViewController
    if (self.preferredGameVersion.length > 0) {
        NSMutableArray<ModVersion *> *pinned = [NSMutableArray array];
        NSMutableArray<ModVersion *> *rest = [NSMutableArray array];
        for (ModVersion *v in sorted) {
            if ([v.gameVersions containsObject:self.preferredGameVersion]) {
                [pinned addObject:v];
            } else {
                [rest addObject:v];
            }
        }
        // The pinned entries keep their original order, and the rest follow
        if (pinned.count > 0 && pinned.count < sorted.count) {
            sorted = [pinned arrayByAddingObjectsFromArray:rest];
        }
    }

    self.filteredVersions = sorted;
    [self.tableView reloadData];
}

/// Sort the version array by the currently selected sort option (matching ModVersionViewController)
- (NSArray<ModVersion *> *)sortVersions:(NSArray<ModVersion *> *)versions {
    if (!versions || versions.count <= 1) return versions;

    // Relevance / downloads: keep the original API order
    if ([self.selectedSort isEqualToString:kSortRelevance] ||
        [self.selectedSort isEqualToString:kSortDownloads]) {
        return versions;
    }

    // Recently updated / created: sort by datePublished
    NSISO8601DateFormatter *dateFormatter = [[NSISO8601DateFormatter alloc] init];
    NSMutableArray<ModVersion *> *sorted = [versions mutableCopy];
    __weak typeof(self) weakSelf = self;
    [sorted sortUsingComparator:^NSComparisonResult(ModVersion *v1, ModVersion *v2) {
        __strong typeof(weakSelf) strongSelf = weakSelf;
        NSDate *d1 = [dateFormatter dateFromString:v1.datePublished];
        NSDate *d2 = [dateFormatter dateFromString:v2.datePublished];
        if (!d1) d1 = [NSDate distantPast];
        if (!d2) d2 = [NSDate distantPast];

        if ([strongSelf.selectedSort isEqualToString:kSortUpdated]) {
            // Recently updated: descending (newest first)
            return [d2 compare:d1];
        }
        if ([strongSelf.selectedSort isEqualToString:kSortCreated]) {
            // Created: ascending (oldest first)
            return [d1 compare:d2];
        }
        return NSOrderedSame;
    }];
    return sorted;
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
