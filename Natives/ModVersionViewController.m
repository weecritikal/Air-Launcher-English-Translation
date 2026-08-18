#import "ModVersionViewController.h"
#import "installer/modpack/ModrinthAPI.h"
#import "installer/modpack/CurseForgeAPI.h"
#import "ModVersion.h"
#import "ModVersionTableViewCell.h"
#import "AssetDetailHeaderView.h"
#import "BackgroundManager.h"

// ============================================================================
// Download source constants (matching the ModVersion.apiSource field: 1=Modrinth, 2=CurseForge)
// ============================================================================
static const NSInteger kSourceModrinth    = 1;
static const NSInteger kSourceCurseForge  = 2;

// ============================================================================
// Sort constants (following the sort options of FCL/ZL2)
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

@interface ModVersionViewController () <UITableViewDataSource, UITableViewDelegate>

// Main table view (shows the version list)
@property (nonatomic, strong) UITableView *tableView;

// ===== Side filter panel (following the horizontally scrolling chip bar of FCL/ZL2) =====
// Filter panel container (translucent + frosted glass, pinned above the tableView and not scrolling with the list)
@property (nonatomic, strong) UIView *filterContainerView;
// Main vertical stack (holding the 4 filter rows: source / version / loader / sort)
@property (nonatomic, strong) UIStackView *filterMainStack;

// --- Download source filter row ---
@property (nonatomic, strong) UIScrollView *sourceScrollView;   // Horizontal scroll container
@property (nonatomic, strong) UIStackView  *sourceChipStack;    // Chips laid out horizontally

// --- Game version filter row ---
@property (nonatomic, strong) UIScrollView *versionScrollView;
@property (nonatomic, strong) UIStackView  *versionChipStack;

// --- Mod loader filter row ---
@property (nonatomic, strong) UIScrollView *loaderScrollView;
@property (nonatomic, strong) UIStackView  *loaderChipStack;

// --- Sort filter row ---
@property (nonatomic, strong) UIScrollView *sortScrollView;
@property (nonatomic, strong) UIStackView  *sortChipStack;

// ===== Currently selected filter state =====
@property (nonatomic, assign) NSInteger selectedSource;  // 1=Modrinth, 2=CurseForge
@property (nonatomic, copy)   NSString *selectedSort;    // Sort key

// ===== Data sources =====
@property (nonatomic, strong) NSArray<ModVersion *> *allVersions;
@property (nonatomic, strong) NSArray<ModVersion *> *filteredVersions;

// The available filter options (extracted dynamically from the version data)
@property (nonatomic, strong) NSArray<NSString *> *availableGameVersions;
@property (nonatomic, strong) NSArray<NSString *> *availableLoaders;

// The version / loader currently selected ("All" means no filtering)
@property (nonatomic, strong) NSString *selectedGameVersion;
@property (nonatomic, strong) NSString *selectedLoader;

// Project detail header view (shows the cover image, title, author, downloads, tags and description, filling the information gap)
@property (nonatomic, strong) AssetDetailHeaderView *detailHeaderView;

@end

@implementation ModVersionViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = self.modItem.displayName;
    self.view.backgroundColor = [UIColor systemBackgroundColor];
    // Adapt to the custom launcher background: make this VC transparent so the global background image/blur shows through
    [[BackgroundManager sharedManager] makeViewControllerTransparent:self];

    // Initialize the filter state (the Modrinth source and relevance sorting by default)
    self.selectedSource = kSourceModrinth;
    self.selectedSort = kSortRelevance;

    [self setupSideFilterPanel];
    [self setupTableView];
    [self setupActivityIndicator];
    [self setupDetailHeader];

    // Make the tableView background transparent so it does not hide the global background
    self.tableView.backgroundColor = [UIColor clearColor];
    self.tableView.backgroundView = nil;

    [self fetchVersionsFromCurrentSource];

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

#pragma mark - Detail Header (project information display)

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

    // Filled in from the modItem data already gathered during the search (so no extra API call is needed)
    [self.detailHeaderView configureWithIconURL:self.modItem.iconURL
                                          title:self.modItem.displayName
                                         author:self.modItem.author
                                      downloads:self.modItem.downloads
                                          likes:self.modItem.likes
                                descriptionText:self.modItem.modDescription
                                    categories:self.modItem.categories
                                   lastUpdated:self.modItem.lastUpdated
                           placeholderSymbolName:@"puzzlepiece.extension.fill"
                               placeholderColor:[UIColor systemOrangeColor]];

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

#pragma mark - Side filter panel (modeled on the horizontally scrolling chips of FCL/ZL2)

/// Build the side filter panel: 4 rows of horizontally scrolling chips (download source / game version / loader / sort)
/// Following the filter bar design of FCL for Android: one row per category, with an icon and label prefix, chips scrolling horizontally,
/// the selected chip highlighted (a theme-colored background with white text) and unselected ones on a translucent background with a light border.
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

    // ===== Main vertical stack (4 filter rows, each = icon label + horizontally scrolling chips) =====
    self.filterMainStack = [[UIStackView alloc] init];
    self.filterMainStack.translatesAutoresizingMaskIntoConstraints = NO;
    self.filterMainStack.axis = UILayoutConstraintAxisVertical;
    self.filterMainStack.spacing = 4;
    self.filterMainStack.alignment = UIStackViewAlignmentFill;
    [self.filterContainerView addSubview:self.filterMainStack];

    // ----- Row 1: download source filter (Modrinth / CurseForge) -----
    {
        UIScrollView *scrollOut = nil;
        UIStackView *chipOut = nil;
        UIStackView *sourceRow = [self createFilterRowWithIconName:@"globe"
                                                             label:@"Source"
                                                        scrollStackOut:&scrollOut
                                                          chipStackOut:&chipOut];
        self.sourceScrollView = scrollOut;
        self.sourceChipStack = chipOut;
        [self.filterMainStack addArrangedSubview:sourceRow];
    }
    [self rebuildSourceChips];

    // ----- Row 2: game version filter (filled in dynamically, showing "Loading" at first) -----
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

    // ----- Row 3: mod loader filter (filled in dynamically, showing "Loading" at first) -----
    {
        UIScrollView *scrollOut = nil;
        UIStackView *chipOut = nil;
        UIStackView *loaderRow = [self createFilterRowWithIconName:@"puzzlepiece.extension.fill"
                                                             label:@"Loader"
                                                        scrollStackOut:&scrollOut
                                                          chipStackOut:&chipOut];
        self.loaderScrollView = scrollOut;
        self.loaderChipStack = chipOut;
        [self.filterMainStack addArrangedSubview:loaderRow];
    }
    [self addChipToStack:self.loaderChipStack title:@"Loading..." selected:NO action:NULL];

    // ----- Row 4: sort filter (relevance / downloads / recently updated / created) -----
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
/// Following the row structure of the FCL filter panel: icon + label + horizontal scroll view
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
    // Fixed row height, so the total height of the 4 rows stays predictable
    [row.heightAnchor constraintEqualToConstant:30].active = YES;
    return row;
}

/// Build a single filter chip button (pill style, following the tag bars of FCL/ZL2)
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

/// Apply the selected/unselected chip style
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

/// Add a chip to chipStack (a shortcut used for the initial placeholders)
- (void)addChipToStack:(UIStackView *)stack title:(NSString *)title selected:(BOOL)selected action:(SEL)action {
    UIButton *chip = [self createFilterChipWithTitle:title selected:selected];
    if (action) {
        [chip addTarget:self action:action forControlEvents:UIControlEventTouchUpInside];
    }
    [stack addArrangedSubview:chip];
}

/// Remove every arranged subview from chipStack (used when rebuilding the chips)
- (void)clearChipStack:(UIStackView *)stack {
    [stack.arrangedSubviews makeObjectsPerformSelector:@selector(removeFromSuperview)];
}

#pragma mark - Rebuilding the chips of each filter row

/// Rebuild the download source chips (Modrinth / CurseForge)
- (void)rebuildSourceChips {
    [self clearChipStack:self.sourceChipStack];

    // Modrinth chip
    UIButton *modrinthChip = [self createFilterChipWithTitle:@"Modrinth"
                                                    selected:(self.selectedSource == kSourceModrinth)];
    modrinthChip.tag = kSourceModrinth;
    [modrinthChip addTarget:self action:@selector(sourceChipTapped:) forControlEvents:UIControlEventTouchUpInside];
    [self.sourceChipStack addArrangedSubview:modrinthChip];

    // CurseForge chip
    UIButton *curseforgeChip = [self createFilterChipWithTitle:@"CurseForge"
                                                      selected:(self.selectedSource == kSourceCurseForge)];
    curseforgeChip.tag = kSourceCurseForge;
    [curseforgeChip addTarget:self action:@selector(sourceChipTapped:) forControlEvents:UIControlEventTouchUpInside];
    [self.sourceChipStack addArrangedSubview:curseforgeChip];
}

/// Rebuild the game version chips (filled in dynamically from availableGameVersions, including "All")
- (void)rebuildVersionChips {
    [self clearChipStack:self.versionChipStack];
    if (!self.availableGameVersions || self.availableGameVersions.count == 0) {
        [self addChipToStack:self.versionChipStack title:@"No version" selected:NO action:NULL];
        return;
    }
    for (NSString *version in self.availableGameVersions) {
        BOOL isSelected = [self.selectedGameVersion isEqualToString:version];
        UIButton *chip = [self createFilterChipWithTitle:version selected:isSelected];
        [chip addTarget:self action:@selector(versionChipTapped:) forControlEvents:UIControlEventTouchUpInside];
        [self.versionChipStack addArrangedSubview:chip];
    }
    // Scroll to the selected item (so the user can see which chip is selected)
    [self scrollToSelectedChipInStack:self.versionChipStack withTitle:self.selectedGameVersion];
}

/// Rebuild the loader chips (filled in dynamically from availableLoaders, including "All")
- (void)rebuildLoaderChips {
    [self clearChipStack:self.loaderChipStack];
    if (!self.availableLoaders || self.availableLoaders.count == 0) {
        [self addChipToStack:self.loaderChipStack title:@"No loader" selected:NO action:NULL];
        return;
    }
    for (NSString *loader in self.availableLoaders) {
        BOOL isSelected = [self.selectedLoader isEqualToString:loader];
        UIButton *chip = [self createFilterChipWithTitle:loader selected:isSelected];
        [chip addTarget:self action:@selector(loaderChipTapped:) forControlEvents:UIControlEventTouchUpInside];
        [self.loaderChipStack addArrangedSubview:chip];
    }
    // Scroll to the selected item
    [self scrollToSelectedChipInStack:self.loaderChipStack withTitle:self.selectedLoader];
}

/// Rebuild the sort chips (4 fixed options: relevance / downloads / recently updated / created)
- (void)rebuildSortChips {
    [self clearChipStack:self.sortChipStack];
    for (NSDictionary *item in SortOptionItems()) {
        NSString *key = item[@"key"];
        NSString *title = item[@"title"];
        BOOL isSelected = [self.selectedSort isEqualToString:key];
        UIButton *chip = [self createFilterChipWithTitle:title selected:isSelected];
        chip.accessibilityIdentifier = key; // The sort key is stored in accessibilityIdentifier
        [chip addTarget:self action:@selector(sortChipTapped:) forControlEvents:UIControlEventTouchUpInside];
        [self.sortChipStack addArrangedSubview:chip];
    }
}

/// Scroll the scrollView so the chip with the given title is visible
- (void)scrollToSelectedChipInStack:(UIStackView *)stack withTitle:(NSString *)title {
    if (!title || title.length == 0) return;
    UIScrollView *scrollView = (UIScrollView *)stack.superview;
    if (![scrollView isKindOfClass:[UIScrollView class]]) return;
    for (UIButton *chip in stack.arrangedSubviews) {
        if (![chip isKindOfClass:[UIButton class]]) continue;
        NSString *chipTitle = chip.titleLabel.text;
        if ([chipTitle isEqualToString:title]) {
            CGRect frameInScroll = [chip.superview convertRect:chip.frame toView:scrollView];
            CGFloat targetX = frameInScroll.origin.x - scrollView.bounds.size.width / 2 + frameInScroll.size.width / 2;
            targetX = MAX(0, targetX);
            CGFloat maxOffset = scrollView.contentSize.width - scrollView.bounds.size.width;
            targetX = MIN(targetX, MAX(0, maxOffset));
            [scrollView setContentOffset:CGPointMake(targetX, 0) animated:YES];
            break;
        }
    }
}

#pragma mark - Chip tap handling

/// Download source chip tapped: switch between Modrinth / CurseForge and fetch the version list again
- (void)sourceChipTapped:(UIButton *)sender {
    NSInteger newSource = sender.tag;
    if (newSource == self.selectedSource) return; // Nothing changed, so ignore it

    // The CurseForge source: check whether an API key is configured
    if (newSource == kSourceCurseForge && ![CurseForgeAPI isAPIKeyConfigured]) {
        [self showSourceAlertWithTitle:@"CurseForge unavailable"
                                message:@"No CurseForge API key is configured. Set one in Settings and try again, or keep using the Modrinth source."];
        return;
    }

    self.selectedSource = newSource;
    // Update the chip selection styles
    for (UIButton *chip in self.sourceChipStack.arrangedSubviews) {
        if (![chip isKindOfClass:[UIButton class]]) continue;
        [self applyChipStyle:chip selected:(chip.tag == self.selectedSource)];
    }
    // Clear the existing data and fetch it again
    self.allVersions = nil;
    self.filteredVersions = nil;
    [self.tableView reloadData];
    [self fetchVersionsFromCurrentSource];
}

/// Game version chip tapped: change the selected version and filter again
- (void)versionChipTapped:(UIButton *)sender {
    NSString *newVersion = sender.titleLabel.text;
    if ([newVersion isEqualToString:self.selectedGameVersion]) return;
    self.selectedGameVersion = newVersion;
    // Update the chip selection styles
    for (UIButton *chip in self.versionChipStack.arrangedSubviews) {
        if (![chip isKindOfClass:[UIButton class]]) continue;
        [self applyChipStyle:chip selected:[chip.titleLabel.text isEqualToString:self.selectedGameVersion]];
    }
    [self applyFiltersAndSort];
}

/// Loader chip tapped: change the selected loader and filter again
- (void)loaderChipTapped:(UIButton *)sender {
    NSString *newLoader = sender.titleLabel.text;
    if ([newLoader isEqualToString:self.selectedLoader]) return;
    self.selectedLoader = newLoader;
    // Update the chip selection styles
    for (UIButton *chip in self.loaderChipStack.arrangedSubviews) {
        if (![chip isKindOfClass:[UIButton class]]) continue;
        [self applyChipStyle:chip selected:[chip.titleLabel.text isEqualToString:self.selectedLoader]];
    }
    [self applyFiltersAndSort];
}

/// Sort chip tapped: change the sort order, re-sort and refresh the list
- (void)sortChipTapped:(UIButton *)sender {
    NSString *newSort = sender.accessibilityIdentifier;
    if (!newSort || [newSort isEqualToString:self.selectedSort]) return;
    self.selectedSort = newSort;
    // Update the chip selection styles
    for (UIButton *chip in self.sortChipStack.arrangedSubviews) {
        if (![chip isKindOfClass:[UIButton class]]) continue;
        [self applyChipStyle:chip selected:[chip.accessibilityIdentifier isEqualToString:self.selectedSort]];
    }
    [self applyFiltersAndSort];
}

/// Show the "could not switch source" message
- (void)showSourceAlertWithTitle:(NSString *)title message:(NSString *)message {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:title
                                                                    message:message
                                                             preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
}

#pragma mark - TableView setup

- (void)setupTableView {
    self.tableView = [[UITableView alloc] initWithFrame:CGRectZero style:UITableViewStylePlain];
    self.tableView.translatesAutoresizingMaskIntoConstraints = NO;
    self.tableView.dataSource = self;
    self.tableView.delegate = self;
    // Enable automatic row heights, so the compact cards size themselves to their content
    self.tableView.rowHeight = UITableViewAutomaticDimension;
    self.tableView.estimatedRowHeight = 78;
    self.tableView.separatorStyle = UITableViewCellSeparatorStyleNone;
    [self.tableView registerClass:[ModVersionTableViewCell class] forCellReuseIdentifier:@"ModVersionCell"];
    [self.view addSubview:self.tableView];

    // The tableView sits directly below the filter panel
    [NSLayoutConstraint activateConstraints:@[
        [self.tableView.topAnchor constraintEqualToAnchor:self.filterContainerView.bottomAnchor constant:6],
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

#pragma mark - Data fetching

/// Fetch the version list from the currently selected download source
/// The Modrinth source -> ModrinthAPI; the CurseForge source -> CurseForgeAPI
- (void)fetchVersionsFromCurrentSource {
    [self.activityIndicator startAnimating];

    if (self.selectedSource == kSourceCurseForge) {
        // ===== The CurseForge source =====
        // CurseForgeAPI.getVersionsForModWithID: returns an array of ModVersion (carrying the CurseForge fileId/projectId)
        [[CurseForgeAPI sharedInstance] getVersionsForModWithID:self.modItem.onlineID
                                                     completion:^(NSArray<ModVersion *> * _Nullable versions, NSError * _Nullable error) {
            dispatch_async(dispatch_get_main_queue(), ^{
                [self handleVersionsResponse:versions error:error];
            });
        }];
    } else {
        // ===== The Modrinth source (the default) =====
        [[ModrinthAPI sharedInstance] getVersionsForModWithID:self.modItem.onlineID
                                                   completion:^(NSArray<ModVersion *> * _Nullable versions, NSError * _Nullable error) {
            dispatch_async(dispatch_get_main_queue(), ^{
                [self handleVersionsResponse:versions error:error];
            });
        }];
    }
}

/// Shared handling of the version fetch callback
- (void)handleVersionsResponse:(NSArray<ModVersion *> *)versions error:(NSError *)error {
    [self.activityIndicator stopAnimating];
    if (error) {
        NSLog(@"[ModVersionVC] Error fetching versions (source=%ld): %@", (long)self.selectedSource, error);
        // Fix for "tapping the download button on the version list did nothing":
        // a failed version list fetch used to only NSLog, so the user saw a blank list with no feedback and assumed the button was broken.
        // A UIAlertController message has been added (matching ShaderVersionViewController).
        UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Error"
                                                                        message:@"Could not fetch version information. Check your network connection or switch download source"
                                                                 preferredStyle:UIAlertControllerStyleAlert];
        [alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
        [self presentViewController:alert animated:YES completion:nil];
        return;
    }
    if (!versions || versions.count == 0) {
        // Give feedback for an empty list too, so the user does not assume "the button does nothing"
        UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Notice"
                                                                        message:@"No downloadable versions found. Try switching the download source (Modrinth/CurseForge) or changing the filters"
                                                                 preferredStyle:UIAlertControllerStyleAlert];
        [alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
        [self presentViewController:alert animated:YES completion:nil];
        return;
    }
    self.allVersions = versions;
    [self processFilters];
    [self applyFiltersAndSort];
}

- (void)processFilters {
    // Extract every available game version and loader from the version data
    NSMutableSet<NSString *> *gameVersions = [NSMutableSet setWithObject:@"All"];
    NSMutableSet<NSString *> *loaders = [NSMutableSet setWithObject:@"All"];

    for (ModVersion *version in self.allVersions) {
        for (NSString *gameVersion in version.gameVersions) {
            [gameVersions addObject:gameVersion];
        }
        for (NSString *loader in version.loaders) {
            [loaders addObject:[loader capitalizedString]]; // Capitalized for display
        }
    }

    // Game versions are sorted by semantic version descending (newest first), with "All" always in front
    self.availableGameVersions = [[gameVersions allObjects] sortedArrayUsingComparator:^NSComparisonResult(NSString *obj1, NSString *obj2) {
        if ([obj1 isEqualToString:@"All"]) return NSOrderedAscending;
        if ([obj2 isEqualToString:@"All"]) return NSOrderedDescending;
        return [obj2 compare:obj1 options:NSNumericSearch];
    }];

    // Loaders are sorted alphabetically, with "All" always in front
    self.availableLoaders = [[loaders allObjects] sortedArrayUsingSelector:@selector(compare:)];

    // FCL style: "All" is selected by default, but if preferredGameVersion/preferredLoader
    // are in the list they are selected automatically (so the user does not have to filter by hand)
    self.selectedGameVersion = self.availableGameVersions.firstObject ?: @"All";
    self.selectedLoader = self.availableLoaders.firstObject ?: @"All";

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
    // Auto-select the preferred loader (preferredLoader is lowercase, such as "fabric",
    // while availableLoaders is capitalized, such as "Fabric")
    if (self.preferredLoader.length > 0) {
        NSString *preferredCapitalized = [self.preferredLoader capitalizedString];
        for (NSString *ld in self.availableLoaders) {
            if ([ld caseInsensitiveCompare:preferredCapitalized] == NSOrderedSame) {
                self.selectedLoader = ld;
                break;
            }
        }
    }

    // Rebuild the version/loader chips (replacing "Loading..." with the real data)
    [self rebuildVersionChips];
    [self rebuildLoaderChips];
}

#pragma mark - Filtering + sorting

/// Apply the filters and sorting, then refresh the table
/// Filter by game version/loader first, then sort
- (void)applyFiltersAndSort {
    // ----- 1. Filter: game version + loader -----
    NSPredicate *predicate = [NSPredicate predicateWithBlock:^BOOL(ModVersion *evaluatedObject, NSDictionary *bindings) {
        BOOL gameVersionMatch = [self.selectedGameVersion isEqualToString:@"All"] ||
                                 [evaluatedObject.gameVersions containsObject:self.selectedGameVersion];
        BOOL loaderMatch = [self.selectedLoader isEqualToString:@"All"] ||
                            [evaluatedObject.loaders containsObject:self.selectedLoader.lowercaseString];
        return gameVersionMatch && loaderMatch;
    }];
    NSArray<ModVersion *> *filtered = [self.allVersions filteredArrayUsingPredicate:predicate];

    // ----- 2. Sort: by the selected sort option -----
    NSArray<ModVersion *> *sorted = [self sortVersions:filtered];

    // ----- 3. FCL style: pin the versions matching the preferred version + loader to the top -----
    // When the user opens the version list from a profile (such as neoforge + 1.21.1),
    // exact matches are pinned to the top so they do not have to be hunted for in a long list
    if (self.preferredGameVersion.length > 0 || self.preferredLoader.length > 0) {
        NSMutableArray<ModVersion *> *pinned = [NSMutableArray array];
        NSMutableArray<ModVersion *> *rest = [NSMutableArray array];
        for (ModVersion *v in sorted) {
            BOOL versionMatch = (self.preferredGameVersion.length == 0) ||
                                [v.gameVersions containsObject:self.preferredGameVersion];
            BOOL loaderMatch = (self.preferredLoader.length == 0) ||
                               [v.loaders containsObject:self.preferredLoader.lowercaseString];
            if (versionMatch && loaderMatch) {
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

/// Sort the version array by the currently selected sort option
- (NSArray<ModVersion *> *)sortVersions:(NSArray<ModVersion *> *)versions {
    if (!versions || versions.count <= 1) return versions;

    // Relevance / downloads: keep the original API order
    // (The ModVersion model has no per-version download count, so sorting by downloads falls back to the original order;
    //  download counts only exist at project level, in ModItem.downloads)
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
        } else if ([strongSelf.selectedSort isEqualToString:kSortCreated]) {
            // Created: ascending (oldest first)
            return [d1 compare:d2];
        }
        return NSOrderedSame;
    }];
    return [sorted copy];
}


#pragma mark - UITableViewDataSource

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    return self.filteredVersions.count;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    ModVersionTableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"ModVersionCell" forIndexPath:indexPath];
    ModVersion *version = self.filteredVersions[indexPath.row];
    [cell configureWithVersion:version];
    return cell;
}

#pragma mark - UITableViewDelegate

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    ModVersion *selectedVersion = self.filteredVersions[indexPath.row];
    if ([self.delegate respondsToSelector:@selector(modVersionViewController:didSelectVersion:)]) {
        [self.delegate modVersionViewController:self didSelectVersion:selectedVersion];
    }
    [self.navigationController popViewControllerAnimated:YES];
}

@end
