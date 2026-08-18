#import "ProfileSettingsViewController.h"
#import "ModsManagerViewController.h"
#import "ShadersManagerViewController.h"
#import "ResourcePacksManagerViewController.h"
#import "DataPacksManagerViewController.h"
#import "WorldsManagerViewController.h"
#import "PLProfiles.h"
#import "LauncherPreferences.h"
#import "LauncherNavigationController.h" // for localVersionList/remoteVersionList
#import "MinecraftResourceUtils.h"
#import "installer/modpack/ModrinthAPI.h"
#import "ModVersion.h"
#import "ios_uikit_bridge.h" // for showDialog
#import "utils.h"
#import "BackgroundManager.h"
#import "DownloadProgressCardView.h"
#import "ModpackExportService.h" // for parseVersionId:

@interface ProfileSettingsViewController () <UITextFieldDelegate, UIPickerViewDataSource, UIPickerViewDelegate>

@property (nonatomic, strong) NSArray<NSArray *> *sections;
@property (nonatomic, strong) NSString *selectedRenderer;
@property (nonatomic, strong) NSString *selectedGraphicsApi;  // The MC 26.2+ graphics API: default/prefer_vulkan/prefer_opengl
@property (nonatomic, strong) NSString *selectedJavaVersion;
@property (nonatomic, assign) NSInteger allocatedMemory;
@property (nonatomic, assign) NSInteger maxMemory;
// The server address (FCL style: leave it empty to skip joining automatically)
@property (nonatomic, strong) NSString *serverIp;
// JVM arguments (such as -Dfoo=bar -Xnoclassgc; Xms/Xmx/d32/d64 are filtered out, since the memory allocation controls them)
@property (nonatomic, strong) NSString *javaArgs;
// The JVM arguments field
@property (nonatomic, strong) UITextField *javaArgsTextField;
// The version picker
@property (nonatomic, strong) UITextField *versionTextField;
@property (nonatomic, strong) UITextField *nameTextField;
@property (nonatomic, strong) UISegmentedControl *versionTypeControl;
@property (nonatomic, strong) UIPickerView *versionPickerView;
@property (nonatomic, strong) UIToolbar *versionPickerToolbar;
@property (nonatomic, strong) NSArray *versionList;
@property (nonatomic, assign) NSInteger versionSelectedAt;
// The original name, used to detect a rename
@property (nonatomic, copy) NSString *originalName;
// The hero card (the profile information card at the top)
@property (nonatomic, strong, nullable) UIView *heroCard;

// The two table views (the two-column landscape layout)
// leftTableView: shows every section (0-4) in portrait; in landscape it only shows sections 0 and 1 (version info, content)
// rightTableView: only shown in landscape, holding sections 2, 3 and 4 (install components, advanced, server)
@property (nonatomic, strong, nullable) UITableView *leftTableView;
@property (nonatomic, strong, nullable) UITableView *rightTableView;
// The hero card container (holding heroCard, used as the tableHeaderView of leftTableView)
@property (nonatomic, strong, nullable) UIView *heroContainer;

@end

@implementation ProfileSettingsViewController

#pragma mark - Lifecycle

- (void)viewDidLoad {
    [super viewDidLoad];

    // If only profileName was passed and not profile, load it from PLProfiles
    if (!self.profile && self.profileName) {
        self.profile = [PLProfiles.current.profiles[self.profileName] mutableCopy];
        if (!self.profile) {
            self.profile = [NSMutableDictionary dictionary];
            self.profile[@"name"] = self.profileName;
        }
    }
    // Safety net: if the caller passed neither profileName nor profile, create an empty dictionary so nothing is written into nil later
    if (!self.profile) {
        self.profile = [NSMutableDictionary dictionary];
    }

    // Make sure the profile has a name field
    self.originalName = self.profile[@"name"];
    if ([self.originalName length] == 0) {
        self.originalName = self.profileName ?: @"New Profile";
        self.profile[@"name"] = self.originalName;
    }

    self.title = [NSString stringWithFormat:@"%@ settings", self.originalName];

    // Navigation bar buttons
    self.navigationItem.leftBarButtonItem = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemDone target:self action:@selector(actionDone)];
    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemClose target:self action:@selector(actionClose)];

    // Set up the tables (the two-column layout: leftTableView is the main table and rightTableView appears only in landscape)
    // self.view of the UIViewController is the container holding both table views
    self.leftTableView = [[UITableView alloc] initWithFrame:CGRectZero style:UITableViewStyleInsetGrouped];
    self.leftTableView.keyboardDismissMode = UIScrollViewKeyboardDismissModeInteractive;
    self.leftTableView.dataSource = self;
    self.leftTableView.delegate = self;
    self.leftTableView.backgroundColor = [UIColor clearColor];
    // Automatic lets the system avoid the navigation bar (fixing the content sliding up under it)
    // Together with edgesForExtendedLayout = UIRectEdgeAll, the background extends behind the navigation bar
    self.leftTableView.contentInsetAdjustmentBehavior = UIScrollViewContentInsetAdjustmentAutomatic;
    [self.view addSubview:self.leftTableView];

    self.rightTableView = [[UITableView alloc] initWithFrame:CGRectZero style:UITableViewStyleInsetGrouped];
    self.rightTableView.keyboardDismissMode = UIScrollViewKeyboardDismissModeInteractive;
    self.rightTableView.dataSource = self;
    self.rightTableView.delegate = self;
    self.rightTableView.backgroundColor = [UIColor clearColor];
    self.rightTableView.contentInsetAdjustmentBehavior = UIScrollViewContentInsetAdjustmentAutomatic;
    self.rightTableView.hidden = YES; // Hidden by default, shown in landscape
    [self.view addSubview:self.rightTableView];

    // Adapt to the custom launcher background: a transparent background lets the frosted glass beneath show through.
    // Both entry paths (push and the showProfileEditor modal) use clearColor,
    // with BackgroundManager managing the background effect throughout.
    // Adapt to the custom launcher background: give the tableView a frosted-glass backgroundView that hides the VC beneath.
    // Fix for "the previous page does not disappear in time when opening version settings from the version manager":
    // with a fully transparent tableView, the cards of VersionManagerViewController show through after the push, so the previous page seems to linger.
    // Setting a UIVisualEffectView (frosted glass) as backgroundView both blurs and reveals the global background image
    // and hides the VC beneath, while keeping the look consistent.
    [self applyBackgroundBlurToTableView];
    // Adapt to the custom launcher background: a frosted-glass navigation bar and a transparent view
    if (self.navigationController) {
        [[BackgroundManager sharedManager] applyEffectToNavigationBar:self.navigationController.navigationBar];
    }
    [[BackgroundManager sharedManager] makeViewControllerTransparent:self];
    self.extendedLayoutIncludesOpaqueBars = YES;
    self.edgesForExtendedLayout = UIRectEdgeAll;

    // Work out the maximum memory
    [self calculateMaxMemory];

    // Load the settings
    [self loadSettings];

    // Set up the version picker
    [self setupVersionPicker];

    // Set up the sections
    [self setupSections];

    // The hero card at the top (the profile name + the current version pill + the game directory)
    [self setupHeroCard];

    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(handleBackgroundUIEffectChanged:)
                                                 name:@"BackgroundUIEffectChanged"
                                               object:nil];

    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(reloadVersionList)
                                                 name:@"ReloadProfileList"
                                               object:nil];
}

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    // Fix for "the previous page does not disappear in time": tableView.bounds can be zero in viewDidLoad,
    // so the backgroundView frame applyBackgroundBlurToTableView sets is zero
    // and cannot hide the VersionManagerViewController content in the first frames of the push.
    // Re-applying it in viewWillAppear (where bounds are correct) makes sure the cover is in place before the transition.
    [self applyBackgroundBlurToTableView];
}

- (void)viewWillTransitionToSize:(CGSize)size withTransitionCoordinator:(id<UIViewControllerTransitionCoordinator>)coordinator {
    [super viewWillTransitionToSize:size withTransitionCoordinator:coordinator];
    // On rotation, recompute the tableHeaderView (hero card) height and switch the two-column layout
    [coordinator animateAlongsideTransition:^(id<UIViewControllerTransitionCoordinatorContext>  _Nonnull context) {
        // Show or hide rightTableView (it appears in landscape)
        BOOL landscape = size.width > size.height;
        self.rightTableView.hidden = !landscape;

        // Recompute the hero card height (only leftTableView shows the hero card)
        UIView *header = self.leftTableView.tableHeaderView;
        if (header) {
            // In landscape, leftTableView is half the total width (minus the gap)
            CGFloat headerWidth = landscape ? (size.width / 2.0 - 8.0) : size.width;
            header.frame = CGRectMake(0, 0, headerWidth, 0);
            [header setNeedsLayout];
            [header layoutIfNeeded];
            CGFloat fittingHeight = [header systemLayoutSizeFittingSize:CGSizeMake(headerWidth, 0)
                                                    withHorizontalFittingPriority:UILayoutPriorityRequired
                                                          verticalFittingPriority:UILayoutPriorityFittingSizeLevel].height;
            header.frame = CGRectMake(0, 0, headerWidth, fittingHeight);
            self.leftTableView.tableHeaderView = header;
        }

        // Reload both table views (the visible sections change with the orientation)
        [self.leftTableView reloadData];
        [self.rightTableView reloadData];
    } completion:^(id<UIViewControllerTransitionCoordinatorContext>  _Nonnull context) {
        // Re-apply the background blur once the transition finishes (the frame has settled)
        [self applyBackgroundBlurToTableView];
    }];
}

- (void)viewWillLayoutSubviews {
    [super viewWillLayoutSubviews];
    [self layoutDualTableViews];
}

/// Lay out the two table views
/// - portrait: leftTableView fills the view and rightTableView is hidden
/// - landscape: leftTableView takes the left half and rightTableView the right, with a 16pt gap
- (void)layoutDualTableViews {
    CGRect bounds = self.view.bounds;
    BOOL landscape = [self isLandscape];

    if (landscape) {
        // The two-column landscape layout
        CGFloat spacing = 16.0;
        CGFloat halfWidth = (bounds.size.width - spacing) / 2.0;
        self.leftTableView.frame = CGRectMake(0, 0, halfWidth, bounds.size.height);
        self.rightTableView.frame = CGRectMake(halfWidth + spacing, 0, halfWidth, bounds.size.height);
        self.rightTableView.hidden = NO;
    } else {
        // The single-column portrait layout
        self.leftTableView.frame = bounds;
        self.rightTableView.hidden = YES;
    }

    // Recompute the width and height of the hero card (the tableHeaderView)
    [self relayoutHeroHeader];

    // Keep the frame of the background blur view in sync
    [self syncBackgroundBlurFrames];
}

/// Recompute the width and height of the hero card (the tableHeaderView)
- (void)relayoutHeroHeader {
    UIView *header = self.leftTableView.tableHeaderView;
    if (!header) return;
    CGFloat width = self.leftTableView.bounds.size.width;
    if (width == 0) return;
    header.frame = CGRectMake(0, 0, width, 0);
    [header setNeedsLayout];
    [header layoutIfNeeded];
    CGFloat fittingHeight = [header systemLayoutSizeFittingSize:CGSizeMake(width, 0)
                                            withHorizontalFittingPriority:UILayoutPriorityRequired
                                                  verticalFittingPriority:UILayoutPriorityFittingSizeLevel].height;
    header.frame = CGRectMake(0, 0, width, fittingHeight);
    self.leftTableView.tableHeaderView = header;
}

/// Keep the backgroundView frames of leftTableView and rightTableView in sync
- (void)syncBackgroundBlurFrames {
    for (UITableView *tv in @[self.leftTableView, self.rightTableView]) {
        if (!tv || tv.hidden) continue;
        if (tv.backgroundView) {
            tv.backgroundView.frame = tv.bounds;
        }
    }
}

- (void)reloadVersionList {
    self.versionList = nil;
    self.versionSelectedAt = -1;
    if (self.versionPickerView && self.versionPickerView.window) {
        [self changeVersionType:nil];
    }
}

#pragma mark - Hero Card

/// The hero card at the top: the profile name + the current version pill + the game directory (an Air-Design v1.2 L3 large card)
- (void)setupHeroCard {
    // ===== The hero card container (L3: 16pt radius + translucent background + frosted glass + light border + medium shadow) =====
    UIView *heroCard = [[UIView alloc] init];
    heroCard.backgroundColor = [[UIColor whiteColor] colorWithAlphaComponent:0.14]; // surface-bright
    heroCard.layer.cornerRadius = 16;
    heroCard.layer.cornerCurve = kCACornerCurveContinuous;
    heroCard.layer.borderWidth = 0.5;
    heroCard.layer.borderColor = [[UIColor whiteColor] colorWithAlphaComponent:0.10].CGColor;
    heroCard.layer.shadowColor = [UIColor blackColor].CGColor;
    heroCard.layer.shadowOpacity = 0.12;
    heroCard.layer.shadowRadius = 8;
    heroCard.layer.shadowOffset = CGSizeMake(0, 3);
    [[BackgroundManager sharedManager] applyEffectToView:heroCard];

    // ===== The hero icon (56x56, 14pt radius, an accentColor background and a white cube.fill SF Symbol) =====
    UIImageView *iconView = [[UIImageView alloc] init];
    iconView.image = [UIImage systemImageNamed:@"cube.fill"];
    iconView.tintColor = [UIColor whiteColor];
    iconView.contentMode = UIViewContentModeCenter;
    iconView.backgroundColor = accentColor();
    iconView.layer.cornerRadius = 14;
    iconView.layer.cornerCurve = kCACornerCurveContinuous;
    iconView.layer.masksToBounds = YES;
    [heroCard addSubview:iconView];

    // ===== The title (the profile name, 17pt bold, labelColor) =====
    UILabel *titleLabel = [[UILabel alloc] init];
    titleLabel.text = self.profile[@"name"] ?: self.originalName ?: @"New Profile";
    titleLabel.font = [UIFont systemFontOfSize:17 weight:UIFontWeightBold];
    titleLabel.textColor = [UIColor labelColor];
    titleLabel.adjustsFontSizeToFitWidth = YES;
    titleLabel.minimumScaleFactor = 0.8;
    [heroCard addSubview:titleLabel];

    // ===== The version pill (11pt bold, white on green, checkmark.circle.fill + the version number) =====
    UIView *versionPill = [[UIView alloc] init];
    versionPill.backgroundColor = [UIColor systemGreenColor];
    versionPill.layer.cornerRadius = 9;
    versionPill.layer.cornerCurve = kCACornerCurveContinuous;
    versionPill.layer.masksToBounds = YES;
    [heroCard addSubview:versionPill];

    UIImageView *pillIcon = [[UIImageView alloc] init];
    pillIcon.image = [UIImage systemImageNamed:@"checkmark.circle.fill"];
    pillIcon.tintColor = [UIColor whiteColor];
    pillIcon.contentMode = UIViewContentModeScaleAspectFit;
    [versionPill addSubview:pillIcon];

    UILabel *pillLabel = [[UILabel alloc] init];
    NSString *currentVersion = self.profile[@"lastVersionId"];
    pillLabel.text = currentVersion.length > 0 ? currentVersion : @"Not selected";
    pillLabel.font = [UIFont systemFontOfSize:11 weight:UIFontWeightBold];
    pillLabel.textColor = [UIColor whiteColor];
    pillLabel.adjustsFontSizeToFitWidth = YES;
    pillLabel.minimumScaleFactor = 0.7;
    [versionPill addSubview:pillLabel];

    // ===== The subtitle (the game directory, 12pt regular, secondaryLabelColor) =====
    UILabel *subtitleLabel = [[UILabel alloc] init];
    NSString *gameDir = self.profile[@"gameDir"] ?: @".";
    NSString *instanceName = getPrefObject(@"general.game_directory") ?: @"default";
    subtitleLabel.text = [NSString stringWithFormat:@"%@ → /instances/%@", gameDir, instanceName];
    subtitleLabel.font = [UIFont systemFontOfSize:12 weight:UIFontWeightRegular];
    subtitleLabel.textColor = [UIColor secondaryLabelColor];
    subtitleLabel.adjustsFontSizeToFitWidth = YES;
    subtitleLabel.minimumScaleFactor = 0.7;
    [heroCard addSubview:subtitleLabel];

    self.heroCard = heroCard;

    // ===== Layout: wrapped in a container and set as the tableHeaderView =====
    UIView *container = [[UIView alloc] init];
    [container addSubview:heroCard];

    heroCard.translatesAutoresizingMaskIntoConstraints = NO;
    iconView.translatesAutoresizingMaskIntoConstraints = NO;
    titleLabel.translatesAutoresizingMaskIntoConstraints = NO;
    versionPill.translatesAutoresizingMaskIntoConstraints = NO;
    pillIcon.translatesAutoresizingMaskIntoConstraints = NO;
    pillLabel.translatesAutoresizingMaskIntoConstraints = NO;
    subtitleLabel.translatesAutoresizingMaskIntoConstraints = NO;

    [NSLayoutConstraint activateConstraints:@[
        // heroCard: 16pt margin on each side, 8pt top and bottom
        [heroCard.topAnchor constraintEqualToAnchor:container.topAnchor constant:8],
        [heroCard.leadingAnchor constraintEqualToAnchor:container.leadingAnchor constant:16],
        [heroCard.trailingAnchor constraintEqualToAnchor:container.trailingAnchor constant:-16],
        [heroCard.bottomAnchor constraintEqualToAnchor:container.bottomAnchor constant:-8],

        // iconView: 56x56, 16pt from the left, 16pt top and bottom
        [iconView.leadingAnchor constraintEqualToAnchor:heroCard.leadingAnchor constant:16],
        [iconView.topAnchor constraintEqualToAnchor:heroCard.topAnchor constant:16],
        [iconView.bottomAnchor constraintEqualToAnchor:heroCard.bottomAnchor constant:-16],
        [iconView.widthAnchor constraintEqualToConstant:56],
        [iconView.heightAnchor constraintEqualToConstant:56],

        // titleLabel: 14pt to the right of iconView, 16pt from the top
        [titleLabel.leadingAnchor constraintEqualToAnchor:iconView.trailingAnchor constant:14],
        [titleLabel.topAnchor constraintEqualToAnchor:heroCard.topAnchor constant:16],
        [titleLabel.trailingAnchor constraintLessThanOrEqualToAnchor:heroCard.trailingAnchor constant:-16],

        // versionPill: 4pt below titleLabel, 18pt tall, left-aligned with titleLabel
        [versionPill.leadingAnchor constraintEqualToAnchor:titleLabel.leadingAnchor],
        [versionPill.topAnchor constraintEqualToAnchor:titleLabel.bottomAnchor constant:4],
        [versionPill.heightAnchor constraintEqualToConstant:18],

        // pillIcon: 8x8, 6pt from the left, vertically centered
        [pillIcon.leadingAnchor constraintEqualToAnchor:versionPill.leadingAnchor constant:6],
        [pillIcon.centerYAnchor constraintEqualToAnchor:versionPill.centerYAnchor],
        [pillIcon.widthAnchor constraintEqualToConstant:10],
        [pillIcon.heightAnchor constraintEqualToConstant:10],

        // pillLabel: 2pt to the right of pillIcon, 6pt from the right, vertically centered
        [pillLabel.leadingAnchor constraintEqualToAnchor:pillIcon.trailingAnchor constant:2],
        [pillLabel.centerYAnchor constraintEqualToAnchor:versionPill.centerYAnchor],
        [pillLabel.trailingAnchor constraintEqualToAnchor:versionPill.trailingAnchor constant:-6],

        // subtitleLabel: 4pt below versionPill, 16pt from the bottom
        [subtitleLabel.leadingAnchor constraintEqualToAnchor:titleLabel.leadingAnchor],
        [subtitleLabel.topAnchor constraintEqualToAnchor:versionPill.bottomAnchor constant:4],
        [subtitleLabel.trailingAnchor constraintLessThanOrEqualToAnchor:heroCard.trailingAnchor constant:-16],
        [subtitleLabel.bottomAnchor constraintEqualToAnchor:heroCard.bottomAnchor constant:-16],
    ]];

    // Compute the container height by hand and set it as the tableHeaderView
    CGFloat width = self.leftTableView.bounds.size.width;
    if (width == 0) width = [UIScreen mainScreen].bounds.size.width;
    container.frame = CGRectMake(0, 0, width, 0);
    [container setNeedsLayout];
    [container layoutIfNeeded];
    CGFloat fittingHeight = [container systemLayoutSizeFittingSize:CGSizeMake(width, 0)
                                               withHorizontalFittingPriority:UILayoutPriorityRequired
                                                     verticalFittingPriority:UILayoutPriorityFittingSizeLevel].height;
    container.frame = CGRectMake(0, 0, width, fittingHeight);
    self.heroContainer = container;
    self.leftTableView.tableHeaderView = container;
}

/// Update the hero card content (called after the user changes the name or version)
- (void)updateHeroCard {
    if (!self.heroCard) return;
    // Walk the heroCard subviews to find titleLabel/versionPill/subtitleLabel and update them
    for (UIView *sub in self.heroCard.subviews) {
        if ([sub isKindOfClass:[UILabel class]]) {
            UILabel *label = (UILabel *)sub;
            // Told apart by their fonts: 17pt bold = the title, 12pt regular = the subtitle, 11pt bold = the version pill label
            if (label.font.pointSize >= 16) {
                label.text = self.profile[@"name"] ?: self.originalName ?: @"New Profile";
            } else if (label.font.pointSize <= 11) {
                NSString *currentVersion = self.profile[@"lastVersionId"];
                label.text = currentVersion.length > 0 ? currentVersion : @"Not selected";
            } else {
                NSString *gameDir = self.profile[@"gameDir"] ?: @".";
                NSString *instanceName = getPrefObject(@"general.game_directory") ?: @"default";
                label.text = [NSString stringWithFormat:@"%@ → /instances/%@", gameDir, instanceName];
            }
        }
    }
}

#pragma mark - Memory

- (void)calculateMaxMemory {
    long long totalMemory = [NSProcessInfo processInfo].physicalMemory;
    self.maxMemory = (NSInteger)(totalMemory / (1024 * 1024));
    self.maxMemory = (NSInteger)(self.maxMemory * 0.8);
    if (self.maxMemory < 1024) {
        self.maxMemory = 1024;
    }
}

#pragma mark - Load Settings

- (void)loadSettings {
    // Renderer
    self.selectedRenderer = self.profile[@"renderer"] ?: @"auto";

    // Graphics API (in-game OpenGL/Vulkan switching on MC 26.2+)
    self.selectedGraphicsApi = self.profile[@"graphicsApi"] ?: @"default";

    // Java version (handling the NSDictionary format written by older direct installers)
    id javaVerRaw = self.profile[@"javaVersion"];
    if ([javaVerRaw isKindOfClass:[NSDictionary class]]) {
        id major = javaVerRaw[@"majorVersion"];
        self.selectedJavaVersion = major ? [major description] : @"0";
    } else {
        self.selectedJavaVersion = [javaVerRaw isKindOfClass:[NSString class]] ? javaVerRaw : @"0";
    }

    // Memory allocation (MB)
    self.allocatedMemory = [self.profile[@"allocatedMemory"] integerValue];
    if (self.allocatedMemory == 0) {
        self.allocatedMemory = MIN(self.maxMemory / 2, 2048);
    }
    if (self.allocatedMemory > self.maxMemory) {
        self.allocatedMemory = self.maxMemory;
    }

    // The server address (an empty string by default; leave it empty to skip joining automatically)
    NSString *profName = self.profile[@"name"] ?: self.profileName;
    self.serverIp = [PLProfiles.current serverIpForProfile:profName] ?: @"";

    // JVM arguments: as on the main branch, only the profile field itself is read;
    // when it is empty the UI shows the "(default)" placeholder, and at launch PLProfiles.resolveKeyForCurrentProfile
    // falls back to the global java.java_args (see JavaLauncher.init_loadCustomJvmFlags).
    id rawArgs = self.profile[@"javaArgs"];
    if ([rawArgs isKindOfClass:[NSString class]]) {
        self.javaArgs = rawArgs;
    } else {
        self.javaArgs = @"";
    }
}

#pragma mark - Sections

- (void)setupSections {
    // The advanced section: renderer + graphics API (MC 26.2+ only) + Java/memory/JVM
    NSMutableArray *advancedRows = [NSMutableArray arrayWithArray:@[@"Renderer"]];
    if ([self isCurrentProfileModernVersion]) {
        [advancedRows addObject:@"Graphics API"];
    }
    [advancedRows addObjectsFromArray:@[@"Java version", @"Memory allocation", @"JVM arguments", @"Clear JVM arguments"]];

    // Rework (Air-Design v1.2): 5 Bento groups
    // The order matches the landscape layout: left (0,1) + right (2,3,4)
    //   0: Version info  - name / game version / game directory
    //   1: Content       - mods / shaders / resource packs / data packs / worlds
    //   2: Components    - Fabric API / OptiFine
    //   3: Advanced      - renderer / graphics API / Java / memory / JVM arguments
    //   4: Server        - the server address
    self.sections = @[
        @[@"Name", @"Game version", @"Game directory"],
        @[@"Mod manager", @"Shader manager", @"Resource pack manager", @"Data pack manager", @"World manager"],
        @[@"Fabric API", @"OptiFine"],
        [advancedRows copy],
        @[@"Server address"]
    ];
}

#pragma mark - Dual Table View Helpers

/// Whether we are in landscape (wider than tall)
- (BOOL)isLandscape {
    CGSize size = self.view.bounds.size;
    return size.width > size.height;
}

/// Return the global section indexes shown by a given table view
/// - leftTableView: every section (0,1,2,3,4) in portrait, and only (0,1) in landscape
/// - rightTableView: (2,3,4), and only in landscape
- (NSArray<NSNumber *> *)visibleSectionsForTableView:(UITableView *)tableView {
    if (tableView == self.rightTableView) {
        return @[@2, @3, @4];
    }
    // leftTableView
    if ([self isLandscape]) {
        return @[@0, @1];
    }
    return @[@0, @1, @2, @3, @4];
}

/// Convert a table view local section index into a global section index
- (NSInteger)globalSectionForTableView:(UITableView *)tableView localSection:(NSInteger)localSection {
    NSArray<NSNumber *> *visible = [self visibleSectionsForTableView:tableView];
    if (localSection < 0 || localSection >= (NSInteger)visible.count) return -1;
    return visible[localSection].integerValue;
}

/// The main table view (used by external code, such as the hero card and the background blur)
- (UITableView *)mainTableView {
    return self.leftTableView;
}

/// Reload the data of every table view
- (void)reloadAllTableViews {
    [self.leftTableView reloadData];
    if (self.rightTableView && !self.rightTableView.hidden) {
        [self.rightTableView reloadData];
    }
}

/// Find the cell for a global section and row (used for a popover sourceView and the like)
/// Walks leftTableView and rightTableView to find the one holding that global section
- (UITableViewCell *)cellForGlobalSection:(NSInteger)globalSection row:(NSInteger)row {
    // Check leftTableView
    NSArray<NSNumber *> *leftVisible = [self visibleSectionsForTableView:self.leftTableView];
    NSInteger leftLocal = [leftVisible indexOfObject:@(globalSection)];
    if (leftLocal != NSNotFound) {
        NSIndexPath *ip = [NSIndexPath indexPathForRow:row inSection:leftLocal];
        return [self.leftTableView cellForRowAtIndexPath:ip];
    }
    // Check rightTableView
    if (self.rightTableView && !self.rightTableView.hidden) {
        NSArray<NSNumber *> *rightVisible = [self visibleSectionsForTableView:self.rightTableView];
        NSInteger rightLocal = [rightVisible indexOfObject:@(globalSection)];
        if (rightLocal != NSNotFound) {
            NSIndexPath *ip = [NSIndexPath indexPathForRow:row inSection:rightLocal];
            return [self.rightTableView cellForRowAtIndexPath:ip];
        }
    }
    return nil;
}

#pragma mark - Save

- (void)saveSettings {
    // Only the renderer/Java/memory/server settings are saved here; renaming is not handled
    // The rename logic lives in actionDone
    // Note: originalName must be used as the key, and the name the user is editing must not be written into PLProfiles,
    // otherwise closing after a rename (without tapping Done) leaves profile.name in PLProfiles as the new name while the key is still the old one
    NSString *profName = self.originalName ?: self.profile[@"name"];
    if (!profName) return;

    // Save the fields the user is editing (name and lastVersionId may be mid-edit and unconfirmed)
    NSString *userInputName = self.profile[@"name"];
    NSString *userInputVersion = self.profile[@"lastVersionId"];

    NSMutableDictionary *existing = [PLProfiles.current.profiles[profName] mutableCopy];
    if (!existing) {
        existing = [NSMutableDictionary dictionary];
    }
    existing[@"renderer"] = self.selectedRenderer;
    existing[@"graphicsApi"] = self.selectedGraphicsApi;
    existing[@"javaVersion"] = self.selectedJavaVersion;
    existing[@"allocatedMemory"] = @(self.allocatedMemory);
    existing[@"serverIp"] = self.serverIp ?: @"";
    // As on the main branch: when javaArgs is empty the key is removed, so the profile falls back to the global java.java_args
    if (self.javaArgs.length > 0) {
        existing[@"javaArgs"] = self.javaArgs;
    } else {
        [existing removeObjectForKey:@"javaArgs"];
    }
    // Save the game directory (used for version isolation): a nil gameDir defaults to ".", matching the main branch
    existing[@"gameDir"] = self.profile[@"gameDir"] ?: @".";
    // The name and lastVersionId fields in existing keep their original values
    PLProfiles.current.profiles[profName] = existing;
    [PLProfiles.current save];

    // Sync to the working copy (a deep copy, so nothing is shared with PLProfiles)
    // Restore the name and lastVersionId the user is editing, so actionDone still sees their changes
    self.profile = [existing mutableCopy];
    if (userInputName.length > 0) {
        self.profile[@"name"] = userInputName;
    }
    if (userInputVersion.length > 0) {
        self.profile[@"lastVersionId"] = userInputVersion;
    }
}

#pragma mark - Table View Data Source

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView {
    return [[self visibleSectionsForTableView:tableView] count];
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    NSInteger globalSection = [self globalSectionForTableView:tableView localSection:section];
    if (globalSection < 0 || globalSection >= (NSInteger)self.sections.count) return 0;
    return [self.sections[globalSection] count];
}

- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section {
    NSInteger globalSection = [self globalSectionForTableView:tableView localSection:section];
    switch (globalSection) {
        case 0: return @"Version info";
        case 1: return @"Content";
        case 2: return @"Install components";
        case 3: return @"Advanced";
        case 4: return @"Server";
        default: return nil;
    }
}

- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section {
    NSInteger globalSection = [self globalSectionForTableView:tableView localSection:section];
    if (globalSection == 0) {
        return @"The game directory decides where saves, mods, and config files are kept\n\".\" = use the current game directory for the selected instance\nTap to set a relative or absolute path for per-version isolation";
    }
    if (globalSection == 2) {
        return @"Fabric API: a dependency for Fabric mods (Fabric loader only)\nOptiFine: the OptiFine optimization mod (vanilla/Forge only)";
    }
    if (globalSection == 4) {
        return @"Join this server automatically when the game starts (as in FCL)\nFormat: host or host:port (for IPv6, [host]:port). Leave empty to disable.";
    }
    return nil;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    static NSString *cellIdentifier = @"SettingsCell";
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:cellIdentifier];
    if (!cell) {
        cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleValue1 reuseIdentifier:cellIdentifier];
        [[BackgroundManager sharedManager] applyEffectToCell:cell];
    }

    // Reset the state of a reused cell
    cell.accessoryView = nil;
    cell.accessoryType = UITableViewCellAccessoryNone;
    cell.imageView.image = nil;
    cell.textLabel.text = nil;
    cell.detailTextLabel.text = nil;
    // Reset the color "Clear JVM arguments" may have changed
    cell.imageView.tintColor = nil;
    cell.textLabel.textColor = [UIColor labelColor];

    NSInteger globalSection = [self globalSectionForTableView:tableView localSection:indexPath.section];
    if (globalSection < 0 || globalSection >= (NSInteger)self.sections.count) return cell;

    NSString *title = self.sections[globalSection][indexPath.row];
    cell.textLabel.text = title;

    switch (globalSection) {
        case 0: // Version info
            if ([title isEqualToString:@"Name"]) {
                cell.imageView.image = [UIImage systemImageNamed:@"tag"];
                cell.accessoryView = [self buildNameTextField];
            } else if ([title isEqualToString:@"Game version"]) {
                cell.imageView.image = [UIImage systemImageNamed:@"archivebox"];
                cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
                cell.accessoryView = [self buildVersionTextField];
                cell.detailTextLabel.text = nil;
            } else if ([title isEqualToString:@"Game directory"]) {
                cell.imageView.image = [UIImage systemImageNamed:@"folder"];
                cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
                NSString *gameDir = self.profile[@"gameDir"] ?: @".";
                cell.detailTextLabel.text = gameDir;
            }
            break;

        case 1: // Content
            if ([title isEqualToString:@"Mod manager"]) {
                cell.imageView.image = [UIImage systemImageNamed:@"puzzlepiece.fill"];
                cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
            } else if ([title isEqualToString:@"Shader manager"]) {
                cell.imageView.image = [UIImage systemImageNamed:@"paintbrush.fill"];
                cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
            } else if ([title isEqualToString:@"Resource pack manager"]) {
                cell.imageView.image = [UIImage systemImageNamed:@"rectangle.stack.fill"];
                cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
            } else if ([title isEqualToString:@"Data pack manager"]) {
                cell.imageView.image = [UIImage systemImageNamed:@"shippingbox.fill"];
                cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
            } else if ([title isEqualToString:@"World manager"]) {
                cell.imageView.image = [UIImage systemImageNamed:@"globe.asia.australia.fill"];
                cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
            }
            break;

        case 2: // Components
            if ([title isEqualToString:@"Fabric API"]) {
                cell.imageView.image = [UIImage systemImageNamed:@"bolt.fill"];
                cell.imageView.tintColor = [UIColor systemOrangeColor];
                cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
                cell.detailTextLabel.text = [self isFabricProfile] ? @"Tap to install" : @"Fabric only";
            } else if ([title isEqualToString:@"OptiFine"]) {
                cell.imageView.image = [UIImage systemImageNamed:@"speedometer"];
                cell.imageView.tintColor = [UIColor systemRedColor];
                cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
                cell.detailTextLabel.text = [self isOptiFineCompatibleProfile] ? @"Tap to install" : @"Vanilla/Forge only";
            }
            break;

        case 3: // Advanced
            if ([title isEqualToString:@"Renderer"]) {
                cell.imageView.image = [UIImage systemImageNamed:@"cpu"];
                cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
                cell.detailTextLabel.text = [self rendererDisplayName:self.selectedRenderer];
            } else if ([title isEqualToString:@"Graphics API"]) {
                cell.imageView.image = [UIImage systemImageNamed:@"rectangle.dashed"];
                cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
                cell.detailTextLabel.text = [self graphicsApiDisplayName:self.selectedGraphicsApi];
            } else if ([title isEqualToString:@"Java version"]) {
                cell.imageView.image = [UIImage systemImageNamed:@"j.square"];
                cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
                cell.detailTextLabel.text = [self.selectedJavaVersion isEqualToString:@"0"] ? @"Automatic" : [NSString stringWithFormat:@"Java %@", self.selectedJavaVersion];
            } else if ([title isEqualToString:@"Memory allocation"]) {
                cell.imageView.image = [UIImage systemImageNamed:@"memorychip"];
                cell.accessoryType = UITableViewCellAccessoryNone;
                cell.detailTextLabel.text = [NSString stringWithFormat:@"%ld MB / %ld MB", (long)self.allocatedMemory, (long)self.maxMemory];
            } else if ([title isEqualToString:@"JVM arguments"]) {
                cell.imageView.image = [UIImage systemImageNamed:@"slider.vertical.3"];
                cell.accessoryView = [self buildJavaArgsTextField];
                cell.detailTextLabel.text = nil;
            } else if ([title isEqualToString:@"Clear JVM arguments"]) {
                cell.imageView.image = [UIImage systemImageNamed:@"trash"];
                cell.imageView.tintColor = [UIColor systemRedColor];
                cell.textLabel.textColor = [UIColor systemRedColor];
                cell.detailTextLabel.text = self.javaArgs.length > 0 ? @"Tap to clear" : @"(no arguments)";
            }
            break;

        case 4: // The server address (FCL style)
            cell.imageView.image = [UIImage systemImageNamed:@"antenna.radiowaves.left.and.right"];
            cell.accessoryView = [self buildServerIpTextField];
            break;
    }

    return cell;
}

#pragma mark - 名称输入框

- (UITextField *)buildNameTextField {
    // Reuse the existing textField
    if (self.nameTextField) {
        // Check whether another cell already holds it (it has to be re-added under cell reuse)
        if (!self.nameTextField.superview || self.nameTextField.superview == self.view) {
            return self.nameTextField;
        }
    }
    UITextField *textField = [[UITextField alloc] initWithFrame:CGRectMake(0, 0, 200, 30)];
    textField.placeholder = @"Version name";
    textField.text = self.profile[@"name"];
    textField.font = [UIFont systemFontOfSize:14];
    textField.adjustsFontSizeToFitWidth = YES;
    textField.minimumFontSize = 10;
    textField.clearButtonMode = UITextFieldViewModeWhileEditing;
    textField.returnKeyType = UIReturnKeyDone;
    textField.autocorrectionType = UITextAutocorrectionTypeNo;
    textField.autocapitalizationType = UITextAutocapitalizationTypeNone;
    textField.textAlignment = NSTextAlignmentRight;
    textField.tag = 1001;
    textField.delegate = self;
    [textField addTarget:self action:@selector(nameTextFieldChanged:) forControlEvents:UIControlEventEditingChanged];
    [textField addTarget:self action:@selector(nameTextFieldDidEnd:) forControlEvents:UIControlEventEditingDidEnd];
    self.nameTextField = textField;
    return textField;
}

- (void)nameTextFieldChanged:(UITextField *)textField {
    self.profile[@"name"] = textField.text ?: @"";
    [self updateHeroCard];
}

- (void)nameTextFieldDidEnd:(UITextField *)textField {
    NSString *trimmed = [textField.text stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet] ?: @"";
    self.profile[@"name"] = trimmed;
    textField.text = trimmed;
    [self updateHeroCard];
}

#pragma mark - 版本选择器

- (void)setupVersionPicker {
    self.versionPickerView = [[UIPickerView alloc] init];
    self.versionPickerView.delegate = self;
    self.versionPickerView.dataSource = self;

    self.versionPickerToolbar = [[UIToolbar alloc] initWithFrame:CGRectMake(0, 0, self.view.frame.size.width, 44)];
    self.versionTypeControl = [[UISegmentedControl alloc] initWithItems:@[
        @"Installed", @"Release", @"Snapshot", @"Old-beta", @"Old-alpha"
    ]];
    [self.versionTypeControl addTarget:self action:@selector(changeVersionType:) forControlEvents:UIControlEventValueChanged];
    self.versionPickerToolbar.items = @[
        [[UIBarButtonItem alloc] initWithCustomView:self.versionTypeControl],
        [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemFlexibleSpace target:nil action:nil],
        [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemDone target:self action:@selector(versionClosePicker)]
    ];

    // Choose the version type automatically
    NSString *currentVersion = self.profile[@"lastVersionId"];
    if (currentVersion) {
        if ([MinecraftResourceUtils findVersion:currentVersion inList:localVersionList]) {
            self.versionTypeControl.selectedSegmentIndex = 0;
        } else {
            NSDictionary *selected = (id)[MinecraftResourceUtils findVersion:currentVersion inList:remoteVersionList];
            if (selected) {
                NSArray *types = @[@"installed", @"release", @"snapshot", @"old_beta", @"old_alpha"];
                NSString *type = selected[@"type"];
                self.versionTypeControl.selectedSegmentIndex = [types indexOfObject:type];
                if (self.versionTypeControl.selectedSegmentIndex == NSNotFound) {
                    self.versionTypeControl.selectedSegmentIndex = 0;
                }
            } else {
                self.versionTypeControl.selectedSegmentIndex = 0;
            }
        }
    } else {
        self.versionTypeControl.selectedSegmentIndex = 0;
    }
    self.versionSelectedAt = -1;
}

- (UITextField *)buildVersionTextField {
    if (self.versionTextField) {
        if (!self.versionTextField.superview || self.versionTextField.superview == self.view) {
            return self.versionTextField;
        }
    }
    UITextField *textField = [[UITextField alloc] initWithFrame:CGRectMake(0, 0, 200, 30)];
    textField.text = self.profile[@"lastVersionId"] ?: @"";
    textField.font = [UIFont systemFontOfSize:13];
    textField.adjustsFontSizeToFitWidth = YES;
    textField.minimumFontSize = 9;
    textField.textAlignment = NSTextAlignmentRight;
    textField.tag = 1002;
    textField.delegate = self;
    textField.inputView = self.versionPickerView;
    textField.inputAccessoryView = self.versionPickerToolbar;
    [textField addTarget:self action:@selector(versionTextFieldDidEnd:) forControlEvents:UIControlEventEditingDidEnd];
    self.versionTextField = textField;

    // Initialize the version list
    [self changeVersionType:nil];
    return textField;
}

- (void)versionTextFieldDidEnd:(UITextField *)textField {
    // Update the version in the profile
    self.profile[@"lastVersionId"] = textField.text ?: @"";
}

- (void)versionClosePicker {
    [self.versionTextField endEditing:YES];
    [self pickerView:self.versionPickerView didSelectRow:[self.versionPickerView selectedRowInComponent:0] inComponent:0];
}

- (void)changeVersionType:(UISegmentedControl *)sender {
    NSArray *newVersionList = self.versionList;
    if (sender || !self.versionList) {
        if (self.versionTypeControl.selectedSegmentIndex == 0) {
            // nil-safe: localVersionList may not have loaded yet just after the launcher starts
            newVersionList = localVersionList ?: @[];
        } else {
            NSString *type = @[@"installed", @"release", @"snapshot", @"old_beta", @"old_alpha"][self.versionTypeControl.selectedSegmentIndex];
            // nil-safe: use an empty array when remoteVersionList is nil, so filteredArrayUsingPredicate cannot crash
            NSArray *remote = remoteVersionList ?: @[];
            newVersionList = [remote filteredArrayUsingPredicate:[NSPredicate predicateWithFormat:@"(type == %@)", type]];
        }
    }

    if (self.versionSelectedAt == -1) {
        NSDictionary *selected = (id)[MinecraftResourceUtils findVersion:self.versionTextField.text inList:newVersionList];
        self.versionSelectedAt = [newVersionList indexOfObject:selected];
    } else {
        NSObject *lastSelected = nil;
        if (self.versionList.count > self.versionSelectedAt) {
            lastSelected = self.versionList[self.versionSelectedAt];
        }
        if (lastSelected != nil) {
            NSObject *nearest = [MinecraftResourceUtils findNearestVersion:lastSelected expectedType:self.versionTypeControl.selectedSegmentIndex];
            if (nearest != nil) {
                self.versionSelectedAt = [newVersionList indexOfObject:(id)nearest];
            }
        }
        self.versionSelectedAt = MIN(labs(self.versionSelectedAt), (NSInteger)newVersionList.count - 1);
    }

    self.versionList = newVersionList;
    [self.versionPickerView reloadAllComponents];
    if (self.versionSelectedAt != -1 && self.versionSelectedAt < (NSInteger)newVersionList.count) {
        [self.versionPickerView selectRow:self.versionSelectedAt inComponent:0 animated:NO];
        [self pickerView:self.versionPickerView didSelectRow:self.versionSelectedAt inComponent:0];
    }
}

#pragma mark - UIPickerView DataSource/Delegate

- (NSInteger)numberOfComponentsInPickerView:(UIPickerView *)pickerView {
    return 1;
}

- (NSInteger)pickerView:(UIPickerView *)pickerView numberOfRowsInComponent:(NSInteger)component {
    return self.versionList.count;
}

- (NSString *)pickerView:(UIPickerView *)pickerView titleForRow:(NSInteger)row forComponent:(NSInteger)component {
    if (self.versionList.count <= row) return nil;
    NSObject *object = self.versionList[row];
    if ([object isKindOfClass:[NSString class]]) {
        return (NSString *)object;
    } else {
        return [object valueForKey:@"id"];
    }
}

- (void)pickerView:(UIPickerView *)pickerView didSelectRow:(NSInteger)row inComponent:(NSInteger)component {
    if (self.versionList.count == 0) {
        self.versionTextField.text = @"";
        return;
    }
    self.versionSelectedAt = row;
    self.versionTextField.text = [self pickerView:pickerView titleForRow:row forComponent:component];
    self.profile[@"lastVersionId"] = self.versionTextField.text;
    [self updateHeroCard];
}

#pragma mark - 服务器地址输入框

- (UITextField *)buildServerIpTextField {
    UITextField *textField = [[UITextField alloc] initWithFrame:CGRectMake(0, 0, 220, 30)];
    textField.placeholder = @"e.g. example.com:25565 (leave empty to disable)";
    textField.text = self.serverIp;
    textField.font = [UIFont systemFontOfSize:13];
    textField.adjustsFontSizeToFitWidth = YES;
    textField.minimumFontSize = 9;
    textField.clearButtonMode = UITextFieldViewModeWhileEditing;
    textField.returnKeyType = UIReturnKeyDone;
    textField.autocorrectionType = UITextAutocorrectionTypeNo;
    textField.autocapitalizationType = UITextAutocapitalizationTypeNone;
    textField.keyboardType = UIKeyboardTypeURL;
    textField.tag = 9527;
    textField.delegate = self;
    [textField addTarget:self action:@selector(serverIpTextFieldEditingChanged:) forControlEvents:UIControlEventEditingChanged];
    [textField addTarget:self action:@selector(serverIpTextFieldEditingDidEnd:) forControlEvents:UIControlEventEditingDidEnd];
    return textField;
}

#pragma mark - JVM 启动参数输入框

- (UITextField *)buildJavaArgsTextField {
    if (self.javaArgsTextField) {
        if (!self.javaArgsTextField.superview || self.javaArgsTextField.superview == self.view) {
            return self.javaArgsTextField;
        }
    }
    UITextField *textField = [[UITextField alloc] initWithFrame:CGRectMake(0, 0, 200, 30)];
    // As in LauncherProfileEditorViewController on the main branch: the placeholder is "(default)",
    // meaning it falls back to the global java.java_args when unset.
    textField.placeholder = @"(default)";
    // Only shown when the profile sets javaArgs explicitly; otherwise it is left empty to show the placeholder
    textField.text = self.profile[@"javaArgs"] ?: @"";
    textField.font = [UIFont systemFontOfSize:13];
    textField.adjustsFontSizeToFitWidth = YES;
    textField.minimumFontSize = 9;
    textField.clearButtonMode = UITextFieldViewModeWhileEditing;
    textField.returnKeyType = UIReturnKeyDone;
    textField.autocorrectionType = UITextAutocorrectionTypeNo;
    textField.autocapitalizationType = UITextAutocapitalizationTypeNone;
    textField.tag = 1003;
    textField.delegate = self;
    [textField addTarget:self action:@selector(javaArgsTextFieldEditingChanged:) forControlEvents:UIControlEventEditingChanged];
    [textField addTarget:self action:@selector(javaArgsTextFieldEditingDidEnd:) forControlEvents:UIControlEventEditingDidEnd];
    self.javaArgsTextField = textField;
    return textField;
}

- (void)javaArgsTextFieldEditingChanged:(UITextField *)textField {
    self.javaArgs = textField.text ?: @"";
}

- (void)javaArgsTextFieldEditingDidEnd:(UITextField *)textField {
    // As on the main branch: an empty string or "(default)" counts as unset, and the key is removed on save so it falls back to the global java.java_args
    NSString *trimmed = [textField.text stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet] ?: @"";
    if (trimmed.length == 0 || [trimmed isEqualToString:@"(default)"]) {
        self.javaArgs = @"";
        textField.text = @"";
    } else {
        self.javaArgs = trimmed;
        textField.text = trimmed;
    }
    [self saveSettings];
}

/// Clear the JVM arguments set for this version in one tap
- (void)clearJavaArgs {
    if (self.javaArgs.length == 0) {
        UIAlertController *tip = [UIAlertController alertControllerWithTitle:@"Notice"
                                                                     message:@"No JVM arguments are currently set"
                                                              preferredStyle:UIAlertControllerStyleAlert];
        [tip addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
        [self presentViewController:tip animated:YES completion:nil];
        return;
    }
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Clear JVM arguments"
                                                                   message:@"Clear the JVM arguments for this profile? This cannot be undone."
                                                            preferredStyle:UIAlertControllerStyleActionSheet];
    [alert addAction:[UIAlertAction actionWithTitle:@"Clear" style:UIAlertActionStyleDestructive handler:^(UIAlertAction * _Nonnull action) {
        self.javaArgs = @"";
        self.javaArgsTextField.text = @"";
        [self saveSettings];
        [self reloadAllTableViews];
    }]];
    [alert addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    if (alert.popoverPresentationController) {
        alert.popoverPresentationController.sourceView = self.view;
        alert.popoverPresentationController.sourceRect = CGRectMake(self.view.bounds.size.width / 2.0, self.view.bounds.size.height / 2.0, 1, 1);
    }
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)serverIpTextFieldEditingChanged:(UITextField *)textField {
    self.serverIp = textField.text ?: @"";
}

- (void)serverIpTextFieldEditingDidEnd:(UITextField *)textField {
    self.serverIp = [textField.text stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet] ?: @"";
    textField.text = self.serverIp;
    [self saveSettings];
}

#pragma mark - UITextFieldDelegate

- (BOOL)textFieldShouldReturn:(UITextField *)textField {
    [textField resignFirstResponder];
    return YES;
}

#pragma mark - Helpers

- (NSString *)rendererDisplayName:(NSString *)renderer {
    NSArray *keys = getRendererKeys(NO);
    NSArray *names = getRendererNames(NO);
    NSUInteger idx = [keys indexOfObject:renderer];
    if (idx != NSNotFound && idx < names.count) {
        return names[idx];
    }
    return renderer ?: @"auto";
}

- (NSString *)currentProfileName {
    return self.profile[@"name"] ?: self.profileName;
}

#pragma mark - Table View Delegate

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];

    NSInteger globalSection = [self globalSectionForTableView:tableView localSection:indexPath.section];
    if (globalSection < 0 || globalSection >= (NSInteger)self.sections.count) return;

    NSString *title = self.sections[globalSection][indexPath.row];

    switch (globalSection) {
        case 0: // Version info
            if ([title isEqualToString:@"Name"]) {
                // Focus the name field
                if (self.nameTextField) [self.nameTextField becomeFirstResponder];
            } else if ([title isEqualToString:@"Game version"]) {
                // Focus the version picker
                if (self.versionTextField) [self.versionTextField becomeFirstResponder];
            } else if ([title isEqualToString:@"Game directory"]) {
                [self editGameDir];
            }
            break;

        case 1: // Content
            if ([title isEqualToString:@"Mod manager"]) {
                [self openModsManager];
            } else if ([title isEqualToString:@"Shader manager"]) {
                [self openShadersManager];
            } else if ([title isEqualToString:@"Resource pack manager"]) {
                [self openResourcePacksManager];
            } else if ([title isEqualToString:@"Data pack manager"]) {
                [self openDataPacksManager];
            } else if ([title isEqualToString:@"World manager"]) {
                [self openWorldsManager];
            }
            break;

        case 2: // Components
            if ([title isEqualToString:@"Fabric API"]) {
                [self installFabricAPIStandalone];
            } else if ([title isEqualToString:@"OptiFine"]) {
                [self installOptiFineStandalone];
            }
            break;

        case 3: // Advanced
            if ([title isEqualToString:@"Renderer"]) {
                [self showRendererSelector];
            } else if ([title isEqualToString:@"Graphics API"]) {
                [self showGraphicsApiSelector];
            } else if ([title isEqualToString:@"Java version"]) {
                [self showJavaVersionSelector];
            } else if ([title isEqualToString:@"Memory allocation"]) {
                [self showMemoryAllocator];
            } else if ([title isEqualToString:@"JVM arguments"]) {
                if (self.javaArgsTextField) [self.javaArgsTextField becomeFirstResponder];
            } else if ([title isEqualToString:@"Clear JVM arguments"]) {
                [self clearJavaArgs];
            }
            break;

        case 4: // The server address
            [self focusTextFieldInCellAtIndexPath:indexPath inTableView:tableView];
            break;
    }
}

- (void)focusTextFieldInCellAtIndexPath:(NSIndexPath *)indexPath inTableView:(UITableView *)tableView {
    UITableViewCell *cell = [tableView cellForRowAtIndexPath:indexPath];
    if (!cell) return;
    UITextField *textField = [self findTextFieldInView:cell.contentView];
    if ([textField canBecomeFirstResponder]) {
        [textField becomeFirstResponder];
    }
}

- (UITextField *)findTextFieldInView:(UIView *)view {
    for (UIView *sub in view.subviews) {
        if ([sub isKindOfClass:[UITextField class]]) {
            return (UITextField *)sub;
        }
        UITextField *found = [self findTextFieldInView:sub];
        if (found) return found;
    }
    return nil;
}

#pragma mark - Actions

/// Edit the game directory (mirroring the gameDir text field of LauncherProfileEditorViewController on the main branch)
/// gameDir="." means the current POJAV_GAME_DIR (the instance folder selected by "switch game directory")
/// A relative path (against POJAV_GAME_DIR) or an absolute path can also be entered, for version isolation
- (void)editGameDir {
    NSString *currentGameDir = self.profile[@"gameDir"] ?: @".";
    NSString *currentInstance = getPrefObject(@"general.game_directory") ?: @"default";

    UIAlertController *alert = [UIAlertController
        alertControllerWithTitle:@"Game directory"
                         message:[NSString stringWithFormat:
                                  @"Sets the game directory this version uses.\n\n"
                                   "\".\" = use the current game directory for the selected instance (%@)\n"
                                   "Relative path = a subfolder of the current game directory (used for version isolation)\n"
                                   "Absolute path = use the path you specify",
                                  currentInstance]
                  preferredStyle:UIAlertControllerStyleAlert];

    [alert addTextFieldWithConfigurationHandler:^(UITextField *textField) {
        textField.text = currentGameDir;
        textField.placeholder = [NSString stringWithFormat:@". -> /Documents/instances/%@", currentInstance];
        textField.autocorrectionType = UITextAutocorrectionTypeNo;
        textField.autocapitalizationType = UITextAutocapitalizationTypeNone;
        textField.clearButtonMode = UITextFieldViewModeWhileEditing;
    }];

    [alert addAction:[UIAlertAction actionWithTitle:@"Restore defaults" style:UIAlertActionStyleDestructive handler:^(UIAlertAction * _Nonnull action) {
        self.profile[@"gameDir"] = @".";
        [self saveSettings];
        [self reloadAllTableViews];
        [self updateHeroCard];
    }]];

    [alert addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];

    [alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:^(UIAlertAction * _Nonnull action) {
        NSString *newGameDir = alert.textFields.firstObject.text;
        newGameDir = [newGameDir stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
        if (newGameDir.length == 0) {
            newGameDir = @".";
        }
        self.profile[@"gameDir"] = newGameDir;
        [self saveSettings];
        [self reloadAllTableViews];
        [self updateHeroCard];
    }]];

    [self presentViewController:alert animated:YES completion:nil];
}

- (void)openModsManager {
    ModsManagerViewController *vc = [[ModsManagerViewController alloc] init];
    vc.profileName = [self currentProfileName];
    vc.initialMode = ModsManagerModeLocal;
    [self.navigationController pushViewController:vc animated:YES];
}

- (void)openShadersManager {
    ShadersManagerViewController *vc = [[ShadersManagerViewController alloc] init];
    vc.profileName = [self currentProfileName];
    vc.initialMode = ShadersManagerModeLocal;
    [self.navigationController pushViewController:vc animated:YES];
}

- (void)openResourcePacksManager {
    ResourcePacksManagerViewController *vc = [[ResourcePacksManagerViewController alloc] init];
    vc.profileName = [self currentProfileName];
    vc.initialMode = ResourcePacksManagerModeLocal;
    [self.navigationController pushViewController:vc animated:YES];
}

- (void)openDataPacksManager {
    DataPacksManagerViewController *vc = [[DataPacksManagerViewController alloc] init];
    vc.profileName = [self currentProfileName];
    [self.navigationController pushViewController:vc animated:YES];
}

- (void)openWorldsManager {
    WorldsManagerViewController *vc = [[WorldsManagerViewController alloc] init];
    vc.profileName = [self currentProfileName];
    [self.navigationController pushViewController:vc animated:YES];
}

#pragma mark - 组件独立安装（Fabric API / OptiFine）

- (BOOL)isFabricProfile {
    NSString *lastVersionId = self.profile[@"lastVersionId"];
    if (![lastVersionId isKindOfClass:[NSString class]] || lastVersionId.length == 0) return NO;
    // A Fabric profile id looks like "fabric-loader-0.16.0-1.21" and contains "fabric"
    // A Quilt profile id contains "quilt"
    return [lastVersionId.lowercaseString containsString:@"fabric"];
}

- (BOOL)isOptiFineCompatibleProfile {
    return [self isVanillaProfile] || [self isForgeProfile];
}

/// Whether this is a vanilla profile
/// lastVersionId contains no forge/fabric/quilt/neoforge loader marker
- (BOOL)isVanillaProfile {
    NSString *lastVersionId = self.profile[@"lastVersionId"];
    if (![lastVersionId isKindOfClass:[NSString class]] || lastVersionId.length == 0) return NO;
    NSString *lower = lastVersionId.lowercaseString;
    return ![lower containsString:@"forge"]
        && ![lower containsString:@"fabric"]
        && ![lower containsString:@"quilt"];
}

/// Whether this is a Forge profile (excluding NeoForge)
/// Key fix: `containsString:@"forge"` used to treat neoforge as forge,
/// so neoforge is now excluded explicitly (following the OptiFine compatibility test of FCL/HMCL)
- (BOOL)isForgeProfile {
    NSString *lastVersionId = self.profile[@"lastVersionId"];
    if (![lastVersionId isKindOfClass:[NSString class]] || lastVersionId.length == 0) return NO;
    NSString *lower = lastVersionId.lowercaseString;
    return [lower containsString:@"forge"] && ![lower containsString:@"neoforge"];
}

/// The mods folder path of the current profile
- (NSString *)currentProfileModsPath {
    NSString *gameDir = self.profile[@"gameDir"];
    NSString *baseDir;
    const char *env = getenv("POJAV_GAME_DIR");
    if (env) {
        baseDir = [NSString stringWithUTF8String:env];
    } else {
        baseDir = NSHomeDirectory();
    }

    NSString *modsBase;
    if ([gameDir isKindOfClass:[NSString class]] && gameDir.length > 0 && ![gameDir isEqualToString:@"."]) {
        if ([gameDir isAbsolutePath]) {
            modsBase = gameDir;
        } else {
            modsBase = [baseDir stringByAppendingPathComponent:gameDir];
        }
    } else {
        modsBase = baseDir;
    }

    NSString *modsDir = [modsBase stringByAppendingPathComponent:@"mods"];
    [[NSFileManager defaultManager] createDirectoryAtPath:modsDir withIntermediateDirectories:YES attributes:nil error:nil];
    return modsDir;
}

/// The game version of the current profile (parsed from lastVersionId)
- (NSString *)currentGameVersion {
    NSString *lastVersionId = self.profile[@"lastVersionId"];
    if (![lastVersionId isKindOfClass:[NSString class]] || lastVersionId.length == 0) return nil;
    // The game version before the loader: 1.21.1-forge-47.3.0 -> 1.21.1
    // fabric-loader-0.16.0-1.21 → 1.21
    NSArray<NSString *> *loaders = @[@"forge", @"fabric", @"neoforge", @"quilt", @"fabric-loader"];
    NSString *result = lastVersionId;
    for (NSString *loader in loaders) {
        NSString *delimiter = [NSString stringWithFormat:@"-%@-", loader];
        NSRange range = [result rangeOfString:delimiter options:NSCaseInsensitiveSearch];
        if (range.location != NSNotFound) {
            result = [result substringToIndex:range.location];
            break;
        }
        // Handling the "fabric-loader-0.16.0-1.21" form: take the last version number
        if ([result.lowercaseString hasPrefix:[NSString stringWithFormat:@"%@-", loader]]) {
            // fabric-loader-0.16.0-1.21 -> take the trailing "1.21"
            NSArray *parts = [result componentsSeparatedByString:@"-"];
            if (parts.count >= 2) {
                // Find the part shaped like 1.x.x
                for (NSString *part in [parts reverseObjectEnumerator]) {
                    if ([part hasPrefix:@"1."]) {
                        return part;
                    }
                }
            }
        }
    }
    return result;
}

- (void)installFabricAPIStandalone {
    if (![self isFabricProfile]) {
        [self showComponentAlert:@"Cannot install"
                          message:@"Fabric API only works with the Fabric loader.\n\nThis version does not use the Fabric loader, so Fabric API cannot be installed.\n\nTo use Fabric, install the Fabric loader from the download page."];
        return;
    }

    NSString *gameVersion = [self currentGameVersion];
    if (!gameVersion) {
        [self showComponentAlert:@"Cannot install" message:@"Could not determine the game version number for this profile"];
        return;
    }

    UIAlertController *confirm = [UIAlertController alertControllerWithTitle:@"Install Fabric API"
                                                                     message:[NSString stringWithFormat:@"Fabric API is a dependency for most Fabric mods.\n\nThe latest Fabric API for Minecraft %@ will be downloaded into the mods folder.\n\nGame version: %@", gameVersion, gameVersion]
                                                              preferredStyle:UIAlertControllerStyleAlert];
    [confirm addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    [confirm addAction:[UIAlertAction actionWithTitle:@"Install" style:UIAlertActionStyleDefault handler:^(UIAlertAction * _Nonnull action) {
        [self startInstallFabricAPIWithGameVersion:gameVersion];
    }]];
    [self presentViewController:confirm animated:YES completion:nil];
}

- (void)installOptiFineStandalone {
    if (![self isOptiFineCompatibleProfile]) {
        [self showComponentAlert:@"Cannot install"
                          message:@"OptiFine only works with vanilla and the Forge loader.\n\nThis version is not compatible with OptiFine.\n\nOn Fabric/Quilt/NeoForge, use another optimization mod such as Sodium."];
        return;
    }

    NSString *gameVersion = [self currentGameVersion];
    if (!gameVersion) {
        [self showComponentAlert:@"Cannot install" message:@"Could not determine the game version number for this profile"];
        return;
    }

    // Key fix (following the OptiFine install flows of FCL/HMCL):
    //   - a vanilla profile: OptiFine must be installed as a version patch (launchwrapper + tweakClass),
    //     since dropping the jar into mods/ does nothing on vanilla, which has no mod loading at all.
    //   - a Forge profile: Forge can load the OptiFine jar as a mod, so the mods/ approach still applies.
    BOOL isVanilla = [self isVanillaProfile];
    NSString *message = nil;
    if (isVanilla) {
        message = [NSString stringWithFormat:
                   @"OptiFine is an optimization mod for Minecraft that adds shader support and higher frame rates.\n\n"
                   @"The latest OptiFine for Minecraft %@ will be downloaded and installed as a version patch (as in FCL/HMCL):\n"
                   @"  • Creates a separate version: %@-OptiFine_xxx\n"
                   @"  • Loaded through launchwrapper + optifine.OptiFineTweaker\n"
                   @"  • Switches to the new version once installation finishes\n\n"
                   @"Game version: %@", gameVersion, gameVersion, gameVersion];
    } else {
        message = [NSString stringWithFormat:
                   @"OptiFine is an optimization mod for Minecraft that adds shader support and higher frame rates.\n\n"
                   @"The latest OptiFine for Minecraft %@ will be downloaded into the mods folder (the Forge loader approach).\n\n"
                   @"Game version: %@ (currently using the Forge loader)", gameVersion, gameVersion];
    }

    UIAlertController *confirm = [UIAlertController alertControllerWithTitle:@"Install OptiFine"
                                                                     message:message
                                                              preferredStyle:UIAlertControllerStyleAlert];
    [confirm addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    [confirm addAction:[UIAlertAction actionWithTitle:@"Install" style:UIAlertActionStyleDefault handler:^(UIAlertAction * _Nonnull action) {
        if (isVanilla) {
            [self startInstallOptiFineAsPatch:gameVersion];
        } else {
            [self startInstallOptiFineWithGameVersion:gameVersion];
        }
    }]];
    [self presentViewController:confirm animated:YES completion:nil];
}

- (void)showComponentAlert:(NSString *)title message:(NSString *)message {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:title message:message preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
}

- (UIAlertController *)showProgressAlertWithTitle:(NSString *)title message:(NSString *)message {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:title
                                                                    message:message
                                                             preferredStyle:UIAlertControllerStyleAlert];
    UIActivityIndicatorView *indicator = [[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleMedium];
    indicator.translatesAutoresizingMaskIntoConstraints = NO;
    [alert.view addSubview:indicator];
    [NSLayoutConstraint activateConstraints:@[
        [indicator.centerXAnchor constraintEqualToAnchor:alert.view.centerXAnchor],
        [indicator.centerYAnchor constraintEqualToAnchor:alert.view.centerYAnchor constant:20]
    ]];
    [indicator startAnimating];
    [self presentViewController:alert animated:YES completion:nil];
    return alert;
}

- (void)startInstallFabricAPIWithGameVersion:(NSString *)gameVersion {
    // Use the shared download progress card (DownloadProgressCardView) instead of the scattered alerts and spinners
    UIView *hostView = self.view.window ?: self.view;
    DownloadProgressCardView *progress = [DownloadProgressCardView showInParentView:hostView title:@"Installing Fabric API"];
    [progress updateProgress:-1 downloaded:0 total:0 speed:0 eta:-1 currentFile:[NSString stringWithFormat:@"Searching for a Fabric API build for %@...", gameVersion]];

    NSMutableDictionary *filters = [NSMutableDictionary dictionary];
    filters[@"query"] = @"fabric api";
    filters[@"limit"] = @"20";

    __weak typeof(self) weakSelf = self;
    [[ModrinthAPI sharedInstance] searchModWithFilters:filters completion:^(NSArray *results, NSError *error) {
        dispatch_async(dispatch_get_main_queue(), ^{
            __strong typeof(weakSelf) strongSelf = weakSelf;
            if (!strongSelf) return;

            if (error || results.count == 0) {
                [progress failWithError:[NSError errorWithDomain:@"FabricAPI" code:1 userInfo:@{NSLocalizedDescriptionKey: [NSString stringWithFormat:@"Fabric API not found: %@", error.localizedDescription ?: @"No search results"]}]];
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                    [progress dismiss];
                    [strongSelf showComponentAlert:@"Installation failed" message:[NSString stringWithFormat:@"Fabric API not found: %@", error.localizedDescription ?: @"No search results"]];
                });
                return;
            }

            // Find the project whose title contains "fabric api" and not "kotlin"
            NSDictionary *fabricAPI = nil;
            for (NSDictionary *mod in results) {
                NSString *title = mod[@"title"] ?: @"";
                if ([title.lowercaseString containsString:@"fabric api"] && ![title.lowercaseString containsString:@"kotlin"]) {
                    fabricAPI = mod;
                    break;
                }
            }
            if (!fabricAPI) {
                [progress failWithError:[NSError errorWithDomain:@"FabricAPI" code:2 userInfo:@{NSLocalizedDescriptionKey: @"No suitable Fabric API project found"}]];
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                    [progress dismiss];
                    [strongSelf showComponentAlert:@"Installation failed" message:@"No suitable Fabric API project found"];
                });
                return;
            }

            [progress updateProgress:-1 downloaded:0 total:0 speed:0 eta:-1 currentFile:@"Fetching the Fabric API version list..."];

            [[ModrinthAPI sharedInstance] getVersionsForModWithID:fabricAPI[@"id"] completion:^(NSArray<ModVersion *> *versions, NSError *versionError) {
                dispatch_async(dispatch_get_main_queue(), ^{
                    __strong typeof(weakSelf) strongSelf2 = weakSelf;
                    if (!strongSelf2) return;

                    if (versionError || versions.count == 0) {
                        [progress failWithError:[NSError errorWithDomain:@"FabricAPI" code:3 userInfo:@{NSLocalizedDescriptionKey: [NSString stringWithFormat:@"Failed to fetch Fabric API versions: %@", versionError.localizedDescription ?: @"No version"]}]];
                        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                            [progress dismiss];
                            [strongSelf2 showComponentAlert:@"Installation failed" message:[NSString stringWithFormat:@"Failed to fetch Fabric API versions: %@", versionError.localizedDescription ?: @"No version"]];
                        });
                        return;
                    }

                    // Find the version matching the current gameVersion
                    ModVersion *matchingVersion = nil;
                    for (ModVersion *ver in versions) {
                        if ([ver.gameVersions containsObject:gameVersion]) {
                            matchingVersion = ver;
                            break;
                        }
                    }
                    if (!matchingVersion) {
                        matchingVersion = versions.firstObject;
                    }

                    NSDictionary *primaryFile = matchingVersion.primaryFile;
                    if (!primaryFile || ![primaryFile[@"url"] isKindOfClass:[NSString class]]) {
                        [progress failWithError:[NSError errorWithDomain:@"FabricAPI" code:4 userInfo:@{NSLocalizedDescriptionKey: @"The Fabric API file information is invalid"}]];
                        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                            [progress dismiss];
                            [strongSelf2 showComponentAlert:@"Installation failed" message:@"The Fabric API file information is invalid"];
                        });
                        return;
                    }

                    [strongSelf2 downloadFabricAPIFile:primaryFile[@"url"]
                                                filename:primaryFile[@"filename"]
                                              progress:progress
                                              modInfo:fabricAPI];
                });
            }];
        });
    }];
}

- (void)downloadFabricAPIFile:(NSString *)urlString filename:(NSString *)filename progress:(DownloadProgressCardView *)progress modInfo:(NSDictionary *)modInfo {
    __weak typeof(self) weakSelf = self;
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf) return;

        NSURL *url = [NSURL URLWithString:urlString];
        NSError *downloadError = nil;
        NSData *data = [self downloadDataWithURL:url error:&downloadError];

        dispatch_async(dispatch_get_main_queue(), ^{
            __strong typeof(weakSelf) strongSelf2 = weakSelf;
            if (!strongSelf2) return;

            if (!data || downloadError) {
                [progress failWithError:downloadError ?: [NSError errorWithDomain:@"FabricAPI" code:5 userInfo:@{NSLocalizedDescriptionKey: @"Download failed"}]];
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                    [progress dismiss];
                    [strongSelf2 showComponentAlert:@"Installation failed" message:[NSString stringWithFormat:@"Failed to download Fabric API: %@", downloadError.localizedDescription ?: @"Unknown error"]];
                });
                return;
            }

            NSString *modsDir = [strongSelf2 currentProfileModsPath];
            NSString *saveFilename = filename ?: @"fabric-api.jar";
            NSString *savePath = [modsDir stringByAppendingPathComponent:saveFilename];

            NSError *writeError = nil;
            BOOL success = [data writeToFile:savePath options:NSDataWritingAtomic error:&writeError];

            if (success) {
                [progress completeWithTitle:@"Fabric API installed"];
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.2 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                    [progress dismiss];
                    [strongSelf2 showComponentAlert:@"Installation successful" message:[NSString stringWithFormat:@"Fabric API was installed into the mods folder:\n%@", saveFilename]];
                });
            } else {
                [progress failWithError:writeError ?: [NSError errorWithDomain:@"FabricAPI" code:6 userInfo:@{NSLocalizedDescriptionKey: @"Write failed"}]];
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                    [progress dismiss];
                    [strongSelf2 showComponentAlert:@"Installation failed" message:[NSString stringWithFormat:@"Failed to write the file: %@", writeError.localizedDescription ?: @"Unknown error"]];
                });
            }
        });
    });
}

- (void)startInstallOptiFineWithGameVersion:(NSString *)gameVersion {
    // Use the shared download progress card (DownloadProgressCardView) instead of the scattered alerts and spinners
    UIView *hostView = self.view.window ?: self.view;
    DownloadProgressCardView *progress = [DownloadProgressCardView showInParentView:hostView title:@"Installing OptiFine"];
    [progress updateProgress:-1 downloaded:0 total:0 speed:0 eta:-1 currentFile:[NSString stringWithFormat:@"Looking up OptiFine versions for %@...", gameVersion]];

    __weak typeof(self) weakSelf = self;
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf) return;

        // Query the BMCL API list
        NSString *listURL = [NSString stringWithFormat:@"https://bmclapi2.bangbang93.com/optifine/%@", gameVersion];
        NSURL *url = [NSURL URLWithString:listURL];
        NSError *listError = nil;
        NSData *listData = [self downloadDataWithURL:url error:&listError];

        NSString *optiFineType = nil;
        NSString *optiFinePatch = nil;
        NSString *filename = nil;

        if (listData && !listError) {
            NSError *jsonError = nil;
            NSArray *versions = [NSJSONSerialization JSONObjectWithData:listData options:0 error:&jsonError];
            if (!jsonError && [versions isKindOfClass:[NSArray class]] && versions.count > 0) {
                NSDictionary *first = versions.firstObject;
                if ([first isKindOfClass:[NSDictionary class]]) {
                    optiFineType = first[@"type"] ?: @"HD_U";
                    optiFinePatch = first[@"patch"];
                    filename = first[@"filename"];
                }
            }
        }

        if (!optiFinePatch) {
            dispatch_async(dispatch_get_main_queue(), ^{
                __strong typeof(weakSelf) strongSelf2 = weakSelf;
                if (!strongSelf2) return;
                [progress failWithError:[NSError errorWithDomain:@"OptiFine" code:1 userInfo:@{NSLocalizedDescriptionKey: [NSString stringWithFormat:@"No OptiFine version found for Minecraft %@", gameVersion]}]];
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                    [progress dismiss];
                    [strongSelf2 showComponentAlert:@"Installation failed" message:[NSString stringWithFormat:@"No OptiFine version found for Minecraft %@", gameVersion]];
                });
            });
            return;
        }

        // Switch to the download stage
        [progress updateProgress:-1 downloaded:0 total:0 speed:0 eta:-1 currentFile:[NSString stringWithFormat:@"Downloading OptiFine %@ %@", optiFineType, optiFinePatch]];

        // Download OptiFine
        NSString *downloadURL = [NSString stringWithFormat:@"https://bmclapi2.bangbang93.com/optifine/%@/%@/%@", gameVersion, optiFineType, optiFinePatch];
        NSURL *dlURL = [NSURL URLWithString:downloadURL];
        NSError *downloadError = nil;
        NSData *data = [self downloadDataWithURL:dlURL error:&downloadError];

        // Fallback: the official OptiFine source
        if ((!data || downloadError) && filename) {
            NSString *officialURL = [NSString stringWithFormat:@"https://optifine.net/downloadx?f=%@", filename];
            NSURL *officialURLObject = [NSURL URLWithString:officialURL];
            NSError *officialError = nil;
            NSData *officialData = [self downloadDataWithURL:officialURLObject error:&officialError];
            if (officialData && !officialError) {
                data = officialData;
                downloadError = nil;
            }
        }

        dispatch_async(dispatch_get_main_queue(), ^{
            __strong typeof(weakSelf) strongSelf2 = weakSelf;
            if (!strongSelf2) return;

            if (!data || downloadError) {
                [progress failWithError:downloadError ?: [NSError errorWithDomain:@"OptiFine" code:2 userInfo:@{NSLocalizedDescriptionKey: @"Download failed"}]];
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                    [progress dismiss];
                    [strongSelf2 showComponentAlert:@"Installation failed" message:[NSString stringWithFormat:@"Failed to download OptiFine: %@", downloadError.localizedDescription ?: @"Unknown error"]];
                });
                return;
            }

            NSString *modsDir = [strongSelf2 currentProfileModsPath];
            NSString *saveFilename = filename ?: [NSString stringWithFormat:@"OptiFine_%@_%@_%@.jar", gameVersion, optiFineType, optiFinePatch];
            NSString *savePath = [modsDir stringByAppendingPathComponent:saveFilename];

            NSError *writeError = nil;
            BOOL success = [data writeToFile:savePath options:NSDataWritingAtomic error:&writeError];

            if (success) {
                [progress completeWithTitle:@"OptiFine installed"];
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.2 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                    [progress dismiss];
                    [strongSelf2 showComponentAlert:@"Installation successful" message:[NSString stringWithFormat:@"OptiFine %@ %@ was installed into the mods folder", optiFineType, optiFinePatch]];
                });
            } else {
                [progress failWithError:writeError ?: [NSError errorWithDomain:@"OptiFine" code:3 userInfo:@{NSLocalizedDescriptionKey: @"Write failed"}]];
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                    [progress dismiss];
                    [strongSelf2 showComponentAlert:@"Installation failed" message:[NSString stringWithFormat:@"Failed to write the file: %@", writeError.localizedDescription ?: @"Unknown error"]];
                });
            }
        });
    });
}

#pragma mark - OptiFine 版本补丁安装（Vanilla profile，参照 FCL/HMCL OptiFineInstallTask）

/// Install OptiFine as a version patch (for a vanilla profile)
/// Following FCL OptiFineInstallTask and HMCL OptiFineInstallTask:
///   1. download the OptiFine jar to libraries/optifine/OptiFine/<mcVersion>/<versionId>.jar
///   2. create versions/<versionId>/<versionId>.json with mainClass set to
///      net.minecraft.launchwrapper.Launcher, adding --tweakClass optifine.OptiFineTweaker
///   3. point inheritsFrom at the vanilla version (whose parent must already exist)
///   4. create the new profile and make it the current one
- (void)startInstallOptiFineAsPatch:(NSString *)gameVersion {
    UIView *hostView = self.view.window ?: self.view;
    DownloadProgressCardView *progress = [DownloadProgressCardView showInParentView:hostView title:@"Installing OptiFine"];
    [progress updateProgress:-1 downloaded:0 total:0 speed:0 eta:-1 currentFile:[NSString stringWithFormat:@"Looking up OptiFine versions for %@...", gameVersion]];

    __weak typeof(self) weakSelf = self;
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf) return;

        // 1. Query the BMCL API for the OptiFine builds matching the current game version
        NSString *listURL = [NSString stringWithFormat:@"https://bmclapi2.bangbang93.com/optifine/%@", gameVersion];
        NSURL *url = [NSURL URLWithString:listURL];
        NSError *listError = nil;
        NSData *listData = [self downloadDataWithURL:url error:&listError];

        NSString *optiFineType = nil;
        NSString *optiFinePatch = nil;
        NSString *filename = nil;

        if (listData && !listError) {
            NSError *jsonError = nil;
            NSArray *versions = [NSJSONSerialization JSONObjectWithData:listData options:0 error:&jsonError];
            if (!jsonError && [versions isKindOfClass:[NSArray class]] && versions.count > 0) {
                NSDictionary *first = versions.firstObject;
                if ([first isKindOfClass:[NSDictionary class]]) {
                    optiFineType = first[@"type"] ?: @"HD_U";
                    optiFinePatch = first[@"patch"];
                    filename = first[@"filename"];
                }
            }
        }

        if (!optiFinePatch) {
            dispatch_async(dispatch_get_main_queue(), ^{
                __strong typeof(weakSelf) strongSelf2 = weakSelf;
                if (!strongSelf2) return;
                [progress failWithError:[NSError errorWithDomain:@"OptiFine" code:1 userInfo:@{NSLocalizedDescriptionKey: [NSString stringWithFormat:@"No OptiFine version found for Minecraft %@", gameVersion]}]];
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                    [progress dismiss];
                    [strongSelf2 showComponentAlert:@"Installation failed" message:[NSString stringWithFormat:@"No OptiFine version found for Minecraft %@", gameVersion]];
                });
            });
            return;
        }

        // 2. Download the OptiFine jar
        [progress updateProgress:-1 downloaded:0 total:0 speed:0 eta:-1 currentFile:[NSString stringWithFormat:@"Downloading OptiFine %@ %@", optiFineType, optiFinePatch]];
        NSString *downloadURL = [NSString stringWithFormat:@"https://bmclapi2.bangbang93.com/optifine/%@/%@/%@", gameVersion, optiFineType, optiFinePatch];
        NSURL *dlURL = [NSURL URLWithString:downloadURL];
        NSError *downloadError = nil;
        NSData *jarData = [self downloadDataWithURL:dlURL error:&downloadError];

        // Fallback: the official OptiFine source
        if ((!jarData || downloadError) && filename.length > 0) {
            NSString *officialURL = [NSString stringWithFormat:@"https://optifine.net/downloadx?f=%@", filename];
            NSURL *officialURLObject = [NSURL URLWithString:officialURL];
            NSError *officialError = nil;
            NSData *officialData = [self downloadDataWithURL:officialURLObject error:&officialError];
            if (officialData && !officialError) {
                jarData = officialData;
                downloadError = nil;
            }
        }

        if (!jarData || downloadError) {
            dispatch_async(dispatch_get_main_queue(), ^{
                __strong typeof(weakSelf) strongSelf2 = weakSelf;
                if (!strongSelf2) return;
                [progress failWithError:downloadError ?: [NSError errorWithDomain:@"OptiFine" code:2 userInfo:@{NSLocalizedDescriptionKey: @"Download failed"}]];
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                    [progress dismiss];
                    [strongSelf2 showComponentAlert:@"Installation failed" message:[NSString stringWithFormat:@"Failed to download OptiFine: %@", downloadError.localizedDescription ?: @"Unknown error"]];
                });
            });
            return;
        }

        // 3. Check that the vanilla parent version exists (otherwise inheritsFrom fails)
        const char *env = getenv("POJAV_GAME_DIR");
        NSString *gameDir = env ? [NSString stringWithUTF8String:env] : NSHomeDirectory();
        NSString *parentJsonPath = [gameDir stringByAppendingPathComponent:
                                    [NSString stringWithFormat:@"versions/%@/%@.json", gameVersion, gameVersion]];
        if (![[NSFileManager defaultManager] fileExistsAtPath:parentJsonPath]) {
            dispatch_async(dispatch_get_main_queue(), ^{
                __strong typeof(weakSelf) strongSelf2 = weakSelf;
                if (!strongSelf2) return;
                [progress failWithError:[NSError errorWithDomain:@"OptiFine" code:4 userInfo:@{NSLocalizedDescriptionKey: [NSString stringWithFormat:@"No version information found for vanilla %@", gameVersion]}]];
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                    [progress dismiss];
                    [strongSelf2 showComponentAlert:@"Installation failed" message:[NSString stringWithFormat:@"No version information found for vanilla %@.\n\nInstall vanilla %@ from the download page first, then install OptiFine.", gameVersion, gameVersion]];
                });
            });
            return;
        }

        // 4. Write the jar to libraries/optifine/OptiFine/<mcVersion>/<versionId>.jar
        //    Following FCL/HMCL: the OptiFine jar is the tweakClass input for launchwrapper,
        //    with mainClass set to net.minecraft.launchwrapper.Launcher
        NSString *versionId = [NSString stringWithFormat:@"%@-OptiFine_%@_%@", gameVersion, optiFineType, optiFinePatch];
        NSString *optifineJarPath = [NSString stringWithFormat:@"optifine/OptiFine/%@/%@.jar", gameVersion, versionId];
        NSString *optifineJarAbsPath = [NSString stringWithFormat:@"%@/libraries/%@", gameDir, optifineJarPath];
        NSString *jarDir = [optifineJarAbsPath stringByDeletingLastPathComponent];
        [[NSFileManager defaultManager] createDirectoryAtPath:jarDir withIntermediateDirectories:YES attributes:nil error:nil];
        NSError *writeJarError = nil;
        BOOL jarOk = [jarData writeToFile:optifineJarAbsPath options:NSDataWritingAtomic error:&writeJarError];
        if (!jarOk) {
            dispatch_async(dispatch_get_main_queue(), ^{
                __strong typeof(weakSelf) strongSelf2 = weakSelf;
                if (!strongSelf2) return;
                [progress failWithError:writeJarError ?: [NSError errorWithDomain:@"OptiFine" code:5 userInfo:@{NSLocalizedDescriptionKey: @"Failed to write the jar"}]];
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                    [progress dismiss];
                    [strongSelf2 showComponentAlert:@"Installation failed" message:[NSString stringWithFormat:@"Failed to write the OptiFine jar: %@", writeJarError.localizedDescription ?: @"Unknown error"]];
                });
            });
            return;
        }

        // 5. Write the version JSON (launchwrapper + tweakClass + inheritsFrom)
        NSDictionary *versionJson = @{
            @"id": versionId,
            @"inheritsFrom": gameVersion,
            @"type": @"release",
            @"mainClass": @"net.minecraft.launchwrapper.Launcher",
            @"minecraftArguments": @"--username ${auth_player_name} --version ${version_name} --gameDir ${game_directory} --assetsDir ${assets_root} --assetIndex ${assets_index_name} --uuid ${auth_uuid} --accessToken ${auth_access_token} --userType ${user_type} --versionType ${version_type} --tweakClass optifine.OptiFineTweaker",
            @"libraries": @[
                @{
                    @"name": [NSString stringWithFormat:@"optifine:OptiFine:%@", gameVersion],
                    @"downloads": @{
                        @"artifact": @{
                            @"path": optifineJarPath,
                            @"url": @"",
                            @"size": @(jarData.length),
                            @"sha1": @""
                        }
                    }
                }
            ],
            @"jar": gameVersion,
            @"minimumLauncherVersion": @21
        };
        NSString *versionDir = [gameDir stringByAppendingPathComponent:[NSString stringWithFormat:@"versions/%@", versionId]];
        [[NSFileManager defaultManager] createDirectoryAtPath:versionDir withIntermediateDirectories:YES attributes:nil error:nil];
        NSString *jsonPath = [versionDir stringByAppendingPathComponent:[NSString stringWithFormat:@"%@.json", versionId]];
        NSData *jsonData = [NSJSONSerialization dataWithJSONObject:versionJson options:NSJSONWritingPrettyPrinted error:nil];
        NSError *writeJsonError = nil;
        [jsonData writeToFile:jsonPath options:NSDataWritingAtomic error:&writeJsonError];

        if (writeJsonError) {
            dispatch_async(dispatch_get_main_queue(), ^{
                __strong typeof(weakSelf) strongSelf2 = weakSelf;
                if (!strongSelf2) return;
                [progress failWithError:writeJsonError];
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                    [progress dismiss];
                    [strongSelf2 showComponentAlert:@"Installation failed" message:[NSString stringWithFormat:@"Failed to write the version JSON: %@", writeJsonError.localizedDescription ?: @"Unknown error"]];
                });
            });
            return;
        }

        // 6. Register the new profile and make it current (matching FCL/HMCL)
        dispatch_async(dispatch_get_main_queue(), ^{
            __strong typeof(weakSelf) strongSelf2 = weakSelf;
            if (!strongSelf2) return;

            NSMutableDictionary *profile = [NSMutableDictionary dictionary];
            profile[@"name"] = versionId;
            profile[@"lastVersionId"] = versionId;
            profile[@"gameDir"] = @".";
            profile[@"type"] = @"custom";
            profile[@"created"] = [NSDate date].description;
            [PLProfiles.current saveProfile:profile withName:versionId];
            PLProfiles.current.selectedProfileName = versionId;

            [[NSNotificationCenter defaultCenter] postNotificationName:@"ReloadProfileList" object:nil];

            [progress completeWithTitle:@"OptiFine installed"];
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                [progress dismiss];
                [strongSelf2 showComponentAlert:@"Installation successful"
                                         message:[NSString stringWithFormat:
                                                  @"OptiFine %@ %@ was installed as a separate version\n\nVersion ID: %@\n\nThe launcher switched to it, so you can start the game right away.",
                                                  optiFineType, optiFinePatch, versionId]];
            });
        });
    });
}

- (void)showRendererSelector {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Choose renderer"
                                                                   message:nil
                                                            preferredStyle:UIAlertControllerStyleActionSheet];

    NSArray *renderers = getRendererKeys(NO);
    NSArray *displayNames = getRendererNames(NO);

    for (NSInteger i = 0; i < renderers.count; i++) {
        NSString *renderer = renderers[i];
        NSString *name = i < displayNames.count ? displayNames[i] : renderer;
        [alert addAction:[UIAlertAction actionWithTitle:name
                                                  style:UIAlertActionStyleDefault
                                                handler:^(UIAlertAction * _Nonnull action) {
            self.selectedRenderer = renderer;
            [self saveSettings];
            [self reloadAllTableViews];
        }]];
    }

    [alert addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];

    if (UIDevice.currentDevice.userInterfaceIdiom == UIUserInterfaceIdiomPad) {
        UITableViewCell *cell = [self cellForGlobalSection:3 row:0];
        alert.popoverPresentationController.sourceView = cell ?: self.view;
        alert.popoverPresentationController.sourceRect = cell ? cell.bounds : self.view.bounds;
    }

    [self presentViewController:alert animated:YES completion:nil];
}

/// Whether the MC version of the current profile is 26.2+ (which needs graphics API switching)
- (BOOL)isCurrentProfileModernVersion {
    NSString *versionId = self.profile[@"lastVersionId"] ?: @"";
    // Fix for recognizing the version number of Fabric/Quilt/Forge loader profiles:
    //   the original implementation tested hasPrefix:@"26.", but the lastVersionId of a Fabric profile
    //   looks like "fabric-loader-0.16.0-26.2", whose prefix is "fabric-loader" rather than "26.", so
    //   an MC 26.2+ Fabric profile never showed the "graphics API" option.
    //   The fix: extract the Minecraft version with ModpackExportService.parseVersionId first,
    //   then test the extracted version. That also handles the forge/neoforge form "26.2-forge-...".
    NSDictionary *parsed = [ModpackExportService parseVersionId:versionId];
    NSString *mcVersion = parsed[@"minecraft"] ?: versionId;
    // 26.x versions (snapshots such as 26w02a match too)
    if ([mcVersion hasPrefix:@"26."]) return YES;
    if ([mcVersion hasPrefix:@"26w"]) return YES;
    // 1.21.8+ versions (Mojang introduced the Vulkan API in 1.21.8)
    if ([mcVersion hasPrefix:@"1.21."]) {
        NSString *minorStr = [mcVersion substringFromIndex:5];
        NSInteger minor = [minorStr integerValue];
        if (minor >= 8) return YES;
    }
    return NO;
}

/// The graphics API display name
- (NSString *)graphicsApiDisplayName:(NSString *)api {
    if ([api isEqualToString:@"prefer_vulkan"]) return @"Prefer Vulkan";
    if ([api isEqualToString:@"prefer_opengl"]) return @"Prefer OpenGL";
    return @"Default";
}

/// The graphics API picker (MC 26.2+ only)
- (void)showGraphicsApiSelector {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Choose graphics API"
                                                                   message:@"In-game OpenGL/Vulkan switching on MC 26.2+"
                                                            preferredStyle:UIAlertControllerStyleActionSheet];

    NSArray *keys = @[@"default", @"prefer_vulkan", @"prefer_opengl"];
    NSArray *names = @[@"Default", @"Prefer Vulkan", @"Prefer OpenGL"];

    for (NSInteger i = 0; i < keys.count; i++) {
        NSString *key = keys[i];
        NSString *name = i < names.count ? names[i] : key;
        [alert addAction:[UIAlertAction actionWithTitle:name
                                                  style:UIAlertActionStyleDefault
                                                handler:^(UIAlertAction * _Nonnull action) {
            self.selectedGraphicsApi = key;
            [self saveSettings];
            [self reloadAllTableViews];
        }]];
    }

    [alert addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];

    if (UIDevice.currentDevice.userInterfaceIdiom == UIUserInterfaceIdiomPad) {
        UITableViewCell *cell = [self cellForGlobalSection:3 row:1];
        alert.popoverPresentationController.sourceView = cell ?: self.view;
        alert.popoverPresentationController.sourceRect = cell ? cell.bounds : self.view.bounds;
    }

    [self presentViewController:alert animated:YES completion:nil];
}

- (void)showJavaVersionSelector {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Choose Java version"
                                                                   message:nil
                                                            preferredStyle:UIAlertControllerStyleActionSheet];

    // Read the installed Java versions from the java.java_homes preference
    NSMutableDictionary *javaHomes = [getPrefObject(@"java.java_homes") mutableCopy];
    if (!javaHomes) {
        javaHomes = [NSMutableDictionary dictionary];
    }
    NSMutableArray *versions = [[javaHomes allKeys] mutableCopy];
    // "0" means automatic, so it is handled separately
    [versions removeObject:@"0"];
    [versions sortUsingSelector:@selector(compare:)];
    // The automatic option goes first
    [versions insertObject:@"0" atIndex:0];

    for (NSString *ver in versions) {
        NSString *name = [ver isEqualToString:@"0"] ? @"Choose automatically" : [NSString stringWithFormat:@"Java %@", ver];
        [alert addAction:[UIAlertAction actionWithTitle:name
                                                  style:UIAlertActionStyleDefault
                                                handler:^(UIAlertAction * _Nonnull action) {
            self.selectedJavaVersion = ver;
            [self saveSettings];
            [self reloadAllTableViews];
        }]];
    }

    [alert addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];

    if (UIDevice.currentDevice.userInterfaceIdiom == UIUserInterfaceIdiomPad) {
        UITableViewCell *cell = [self cellForGlobalSection:3 row:1];
        alert.popoverPresentationController.sourceView = cell ?: self.view;
        alert.popoverPresentationController.sourceRect = cell ? cell.bounds : self.view.bounds;
    }

    [self presentViewController:alert animated:YES completion:nil];
}

- (void)showMemoryAllocator {
    NSInteger minMemory = 512;
    NSInteger step = 512;
    NSMutableArray *options = [NSMutableArray array];
    for (NSInteger mem = minMemory; mem <= self.maxMemory; mem += step) {
        [options addObject:@(mem)];
    }

    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Allocate memory"
                                                                   message:[NSString stringWithFormat:@"Total device memory: %ld MB\nMaximum allocatable: %ld MB", (long)(self.maxMemory / 0.8), (long)self.maxMemory]
                                                            preferredStyle:UIAlertControllerStyleActionSheet];

    for (NSNumber *memNum in options) {
        NSInteger mem = [memNum integerValue];
        NSString *title = [NSString stringWithFormat:@"%ld MB", (long)mem];
        [alert addAction:[UIAlertAction actionWithTitle:title
                                                  style:UIAlertActionStyleDefault
                                                handler:^(UIAlertAction * _Nonnull action) {
            self.allocatedMemory = mem;
            [self saveSettings];
            [self reloadAllTableViews];
        }]];
    }

    [alert addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];

    if (UIDevice.currentDevice.userInterfaceIdiom == UIUserInterfaceIdiomPad) {
        UITableViewCell *cell = [self cellForGlobalSection:3 row:2];
        alert.popoverPresentationController.sourceView = cell ?: self.view;
        alert.popoverPresentationController.sourceRect = cell ? cell.bounds : self.view.bounds;
    }

    [self presentViewController:alert animated:YES completion:nil];
}

#pragma mark - Done / Close

- (void)actionClose {
    // Dismiss the keyboard
    [self.view endEditing:YES];
    // Close without saving (the settings are saved automatically as they are edited)
    if (self.navigationController) {
        if (self.navigationController.viewControllers.firstObject == self) {
            [self dismissViewControllerAnimated:YES completion:nil];
        } else {
            [self.navigationController popViewControllerAnimated:YES];
        }
    } else {
        [self dismissViewControllerAnimated:YES completion:nil];
    }
}

- (void)actionDone {
    // Dismiss the keyboard, which fires EditingDidEnd
    [self.view endEditing:YES];

    NSString *newName = self.profile[@"name"];
    if ([newName length] == 0) {
        // The name is empty, so restore the original
        self.profile[@"name"] = self.originalName;
        newName = self.originalName;
    }

    // Check for a rename conflict
    if (![self.originalName isEqualToString:newName]) {
        // The name changed, so check whether the new one is taken
        if (PLProfiles.current.profiles[newName]) {
            // A duplicate name: warn and cancel
            showDialog(@"Error", @"A profile with this name already exists, please use a different one");
            return;
        }
        // Remove the old name and add the new one
        if (self.originalName.length > 0) {
            [PLProfiles.current.profiles removeObjectForKey:self.originalName];
        }
        PLProfiles.current.profiles[newName] = self.profile;
        // If the renamed profile was the selected one, update the selection
        if ([PLProfiles.current.selectedProfileName isEqualToString:self.originalName]) {
            PLProfiles.current.selectedProfileName = newName;
        }
    } else {
        // The name did not change, so just save
        PLProfiles.current.profiles[newName] = self.profile;
    }

    [PLProfiles.current save];

    // Post a notification to refresh the profile list
    [[NSNotificationCenter defaultCenter] postNotificationName:@"SelectedProfileChanged" object:newName];

    // Close
    [self actionClose];
}

#pragma mark - Orientation

- (BOOL)shouldAutorotate {
    return YES;
}

- (UIInterfaceOrientationMask)supportedInterfaceOrientations {
    return UIInterfaceOrientationMaskLandscape;
}

- (void)handleBackgroundUIEffectChanged:(NSNotification *)notification {
    dispatch_async(dispatch_get_main_queue(), ^{
        // Re-apply the frosted-glass tableView backgroundView after the background effect changes,
        // otherwise the old backgroundView lingers after a frosted glass <-> translucent switch and looks inconsistent
        [self applyBackgroundBlurToTableView];
        [self reloadAllTableViews];
    });
}

/// Give self.tableView a background view that hides the VC beneath while still showing the global background.
/// - with a custom launcher background: use a UIVisualEffectView (SystemThinMaterial) frosted-glass background,
///   which blurs the global background image but still lets it through, hiding the VersionManager cards beneath.
/// - with no custom background: use systemBackgroundColor, matching the default system look.
- (void)applyBackgroundBlurToTableView {
    // Apply it to both table views (leftTableView and rightTableView)
    for (UITableView *tv in @[self.leftTableView, self.rightTableView]) {
        if (!tv) continue;
        // Clear the old backgroundView (so they do not stack)
        tv.backgroundView = nil;

        if ([[BackgroundManager sharedManager] hasBackground]) {
            // With a custom background: use a frosted-glass backgroundView to blur it and hide the VC beneath
            UIBlurEffect *blur;
            if (@available(iOS 13.0, *)) {
                blur = [UIBlurEffect effectWithStyle:UIBlurEffectStyleSystemThinMaterial];
            } else {
                blur = [UIBlurEffect effectWithStyle:UIBlurEffectStyleLight];
            }
            UIVisualEffectView *blurView = [[UIVisualEffectView alloc] initWithEffect:blur];
            blurView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
            blurView.frame = tv.bounds;
            // Adjust the opacity from uiEffect: frosted glass keeps the default 0.7 translucency, and translucent mode follows uiOpacity
            BackgroundUIEffect effect = [BackgroundManager sharedManager].uiEffect;
            if (effect == BackgroundUIEffectBlur) {
                blurView.alpha = 0.85;
            } else {
                blurView.alpha = MAX(0.5, [BackgroundManager sharedManager].uiOpacity);
            }
            tv.backgroundView = blurView;
        } else {
            // With no custom background: use the system default color, keeping the original look
            if (@available(iOS 13.0, *)) {
                UIView *bg = [[UIView alloc] initWithFrame:tv.bounds];
                bg.backgroundColor = [UIColor systemBackgroundColor];
                bg.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
                tv.backgroundView = bg;
            }
        }
        // The tableView itself stays transparent, so the backgroundView shows
        tv.backgroundColor = [UIColor clearColor];
    }
}

#pragma mark - UA-aware download helper

/// Phase 6 fix (following FCL): a synchronous download using an NSURLSession with a browser User-Agent,
/// replacing NSData dataWithContentsOfURL:. The optifine/curseforge forwarders of BMCLAPI sit behind Cloudflare, which blocks the default UA with a 403.
/// Equivalent to DownloadViewController.downloadDataWithURLString:error:, but taking an NSURL
/// (every call site in this file already has one).
- (NSData *)downloadDataWithURL:(NSURL *)url error:(NSError **)error {
    if (!url) {
        if (error) {
            *error = [NSError errorWithDomain:@"ProfileSettingsDownload"
                                         code:1
                                     userInfo:@{NSLocalizedDescriptionKey: @"nil URL"}];
        }
        return nil;
    }
    NSURLSessionConfiguration *cfg = [NSURLSessionConfiguration defaultSessionConfiguration];
    cfg.timeoutIntervalForRequest = 60;
    cfg.HTTPAdditionalHeaders = @{
        @"User-Agent": @"Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36",
        @"Accept": @"*/*"
    };
    __block NSData *result = nil;
    __block NSError *resultError = nil;
    dispatch_semaphore_t sem = dispatch_semaphore_create(0);
    NSURLSession *session = [NSURLSession sessionWithConfiguration:cfg];
    NSURLSessionDataTask *task = [session dataTaskWithURL:url completionHandler:^(NSData *data, NSURLResponse *response, NSError *err) {
        if (err) {
            resultError = err;
        } else if ([response isKindOfClass:[NSHTTPURLResponse class]]) {
            NSInteger statusCode = ((NSHTTPURLResponse *)response).statusCode;
            if (statusCode >= 400) {
                resultError = [NSError errorWithDomain:@"ProfileSettingsDownload"
                                                  code:statusCode
                                              userInfo:@{NSLocalizedDescriptionKey: [NSString stringWithFormat:@"HTTP %ld for %@", (long)statusCode, url.absoluteString]}];
            } else {
                result = data;
            }
        } else {
            result = data;
        }
        dispatch_semaphore_signal(sem);
    }];
    [task resume];
    dispatch_semaphore_wait(sem, dispatch_time(DISPATCH_TIME_NOW, 70 * NSEC_PER_SEC));
    if (error) *error = resultError;
    [session finishTasksAndInvalidate];
    return result;
}

@end
