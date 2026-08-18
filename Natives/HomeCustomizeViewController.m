#import "HomeCustomizeViewController.h"
#import "LauncherNewsViewController.h"
#import "BackgroundManager.h"
#import <QuartzCore/QuartzCore.h>

// MARK: - Available Shortcut Definitions

static NSDictionary *availableShortcuts(void) {
    return @{
        kShortcutActionMods:       @{@"title": @"Mod manager",    @"icon": @"puzzlepiece.extension.fill", @"color": @"#14B8A6"},
        kShortcutActionShaders:    @{@"title": @"Shader manager",    @"icon": @"sun.max.fill",              @"color": @"#F97316"},
        kShortcutActionModpack:    @{@"title": @"Import modpack",  @"icon": @"shippingbox.fill",           @"color": @"#8B5CF6"},
        kShortcutActionBackground: @{@"title": @"Wallpaper settings",    @"icon": @"photo.fill.on.rectangle.fill",@"color": @"#EC4899"},
        kShortcutActionVersions:   @{@"title": @"Version manager",    @"icon": @"square.stack.3d.up.fill",    @"color": @"#6366F1"},
    };
}

static UIColor *hexColor(NSString *hex) {
    hex = [hex stringByReplacingOccurrencesOfString:@"#" withString:@""];
    unsigned int rgb = 0;
    [[NSScanner scannerWithString:hex] scanHexInt:&rgb];
    return [UIColor colorWithRed:((rgb >> 16) & 0xFF) / 255.0
                           green:((rgb >> 8) & 0xFF) / 255.0
                            blue:(rgb & 0xFF) / 255.0
                           alpha:1.0];
}

// MARK: - Customization Tile Cell

@interface CustomizeTileCell : UITableViewCell
@property (nonatomic, strong) UIView *accentStrip;
@property (nonatomic, strong) UIImageView *tileIconView;
@property (nonatomic, strong) UILabel *tileTitleLabel;
@property (nonatomic, strong) UILabel *tileDetailLabel;
@property (nonatomic, strong) UISwitch *visibilitySwitch;
@property (nonatomic, strong) UILabel *sizeLabel;
@end

@implementation CustomizeTileCell

- (instancetype)initWithStyle:(UITableViewCellStyle)style reuseIdentifier:(NSString *)reuseIdentifier {
    self = [super initWithStyle:style reuseIdentifier:reuseIdentifier];
    if (self) {
        self.backgroundColor = [UIColor clearColor];
        self.contentView.backgroundColor = [UIColor clearColor];
        self.selectionStyle = UITableViewCellSelectionStyleNone;
        
        // Decorative bar on the left
        self.accentStrip = [[UIView alloc] init];
        self.accentStrip.translatesAutoresizingMaskIntoConstraints = NO;
        self.accentStrip.layer.cornerRadius = 2;
        [self.contentView addSubview:self.accentStrip];
        
        // Icon
        self.tileIconView = [[UIImageView alloc] init];
        self.tileIconView.translatesAutoresizingMaskIntoConstraints = NO;
        self.tileIconView.contentMode = UIViewContentModeScaleAspectFit;
        self.tileIconView.tintColor = [UIColor labelColor];
        [self.contentView addSubview:self.tileIconView];
        
        // Title
        self.tileTitleLabel = [[UILabel alloc] init];
        self.tileTitleLabel.translatesAutoresizingMaskIntoConstraints = NO;
        self.tileTitleLabel.font = [UIFont systemFontOfSize:15 weight:UIFontWeightSemibold];
        self.tileTitleLabel.textColor = [UIColor labelColor];
        [self.contentView addSubview:self.tileTitleLabel];
        
        // Detail (type + size)
        self.tileDetailLabel = [[UILabel alloc] init];
        self.tileDetailLabel.translatesAutoresizingMaskIntoConstraints = NO;
        self.tileDetailLabel.font = [UIFont systemFontOfSize:11 weight:UIFontWeightMedium];
        self.tileDetailLabel.textColor = [UIColor tertiaryLabelColor];
        [self.contentView addSubview:self.tileDetailLabel];
        
        // Size label
        self.sizeLabel = [[UILabel alloc] init];
        self.sizeLabel.translatesAutoresizingMaskIntoConstraints = NO;
        self.sizeLabel.font = [UIFont systemFontOfSize:10 weight:UIFontWeightBold];
        self.sizeLabel.textColor = [UIColor secondaryLabelColor];
        self.sizeLabel.textAlignment = NSTextAlignmentCenter;
        self.sizeLabel.layer.cornerRadius = 4;
        self.sizeLabel.layer.masksToBounds = YES;
        self.sizeLabel.backgroundColor = [UIColor colorWithWhite:0.2 alpha:0.5];
        [self.contentView addSubview:self.sizeLabel];
        
        // Visibility switch
        self.visibilitySwitch = [[UISwitch alloc] init];
        self.visibilitySwitch.translatesAutoresizingMaskIntoConstraints = NO;
        self.visibilitySwitch.transform = CGAffineTransformMakeScale(0.7, 0.7);
        self.visibilitySwitch.onTintColor = hexColor(@"#8B5CF6");
        [self.contentView addSubview:self.visibilitySwitch];
        
        [NSLayoutConstraint activateConstraints:@[
            [self.accentStrip.leadingAnchor constraintEqualToAnchor:self.contentView.leadingAnchor constant:16],
            [self.accentStrip.topAnchor constraintEqualToAnchor:self.contentView.topAnchor constant:12],
            [self.accentStrip.bottomAnchor constraintEqualToAnchor:self.contentView.bottomAnchor constant:-12],
            [self.accentStrip.widthAnchor constraintEqualToConstant:4],
            
            [self.tileIconView.leadingAnchor constraintEqualToAnchor:self.accentStrip.trailingAnchor constant:12],
            [self.tileIconView.centerYAnchor constraintEqualToAnchor:self.contentView.centerYAnchor],
            [self.tileIconView.widthAnchor constraintEqualToConstant:26],
            [self.tileIconView.heightAnchor constraintEqualToConstant:26],
            
            [self.tileTitleLabel.leadingAnchor constraintEqualToAnchor:self.tileIconView.trailingAnchor constant:12],
            [self.tileTitleLabel.topAnchor constraintEqualToAnchor:self.contentView.topAnchor constant:16],
            [self.tileTitleLabel.trailingAnchor constraintEqualToAnchor:self.sizeLabel.leadingAnchor constant:-8],
            
            [self.tileDetailLabel.leadingAnchor constraintEqualToAnchor:self.tileTitleLabel.leadingAnchor],
            [self.tileDetailLabel.topAnchor constraintEqualToAnchor:self.tileTitleLabel.bottomAnchor constant:2],
            [self.tileDetailLabel.trailingAnchor constraintEqualToAnchor:self.tileTitleLabel.trailingAnchor],
            
            [self.sizeLabel.centerYAnchor constraintEqualToAnchor:self.contentView.centerYAnchor],
            [self.sizeLabel.widthAnchor constraintEqualToConstant:40],
            [self.sizeLabel.heightAnchor constraintEqualToConstant:18],
            [self.sizeLabel.trailingAnchor constraintEqualToAnchor:self.visibilitySwitch.leadingAnchor constant:-6],
            
            [self.visibilitySwitch.centerYAnchor constraintEqualToAnchor:self.contentView.centerYAnchor],
            [self.visibilitySwitch.trailingAnchor constraintEqualToAnchor:self.contentView.trailingAnchor constant:-28],
        ]];
        
        [[BackgroundManager sharedManager] applyEffectToView:self.contentView];
    }
    return self;
}

- (void)configureWithTile:(HomeTileConfig *)tile {
    self.tileTitleLabel.text = [self displayTitleForTile:tile];
    self.tileDetailLabel.text = [self displayDetailForTile:tile];
    self.tileIconView.image = [UIImage systemImageNamed:tile.iconName ?: @"square.grid.2x2"];
    self.tileIconView.tintColor = [tile accentColor];
    self.accentStrip.backgroundColor = [tile accentColor];
    self.visibilitySwitch.on = tile.visible;
    self.sizeLabel.text = tile.tileSize == HomeTileSizeCompact ? @"Half width" : @"Full width";
    
    CGFloat alpha = tile.visible ? 1.0 : 0.45;
    self.tileTitleLabel.alpha = alpha;
    self.tileIconView.alpha = alpha;
    self.tileDetailLabel.alpha = alpha;
}

- (NSString *)displayTitleForTile:(HomeTileConfig *)tile {
    if (tile.customTitle.length > 0) return tile.customTitle;
    switch (tile.tileType) {
        case HomeTileTypeProfile:        return @"Profile";
        case HomeTileTypeAnnouncement:   return @"Announcements";
        case HomeTileTypeVersionRelease: return @"Latest release";
        case HomeTileTypeVersionSnapshot:return @"Latest snapshot";
        case HomeTileTypeNews:           return @"Minecraft news";
        case HomeTileTypeShortcut:       return tile.shortcutAction ?: @"Shortcut";
        default:                         return @"Tile";
    }
}

- (NSString *)displayDetailForTile:(HomeTileConfig *)tile {
    NSString *type;
    switch (tile.tileType) {
        case HomeTileTypeProfile:        type = @"Profile card"; break;
        case HomeTileTypeAnnouncement:   type = @"Announcements"; break;
        case HomeTileTypeVersionRelease: type = @"Version info"; break;
        case HomeTileTypeVersionSnapshot:type = @"Version info"; break;
        case HomeTileTypeNews:           type = @"News"; break;
        case HomeTileTypeShortcut:       type = @"Shortcut"; break;
        default:                         type = @"Unknown"; break;
    }
    NSString *size = tile.tileSize == HomeTileSizeCompact ? @"Compact" : @"Full width";
    return [NSString stringWithFormat:@"%@ · %@", type, size];
}

@end

// MARK: - HomeCustomizeViewController

@interface HomeCustomizeViewController () <UITableViewDataSource, UITableViewDelegate>

@property (nonatomic, strong) UITableView *tableView;
@property (nonatomic, strong) NSMutableArray<HomeTileConfig *> *editingConfigs;

@end

@implementation HomeCustomizeViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    
    self.title = @"Customize home";
    self.editingConfigs = [self.tileConfigs mutableCopy];
    
    // Navigation bar buttons
    self.navigationItem.leftBarButtonItem = [[UIBarButtonItem alloc] initWithTitle:@"Cancel"
                                                                            style:UIBarButtonItemStylePlain
                                                                           target:self
                                                                           action:@selector(cancelTapped)];
    
    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithTitle:@"Save"
                                                                             style:UIBarButtonItemStyleDone
                                                                            target:self
                                                                            action:@selector(saveTapped)];
    
    // Toolbar buttons
    UIBarButtonItem *addBtn = [[UIBarButtonItem alloc] initWithTitle:@"Add shortcut"
                                                              style:UIBarButtonItemStylePlain
                                                             target:self
                                                             action:@selector(addShortcutTapped)];
    UIBarButtonItem *resetBtn = [[UIBarButtonItem alloc] initWithTitle:@"Reset to default"
                                                                style:UIBarButtonItemStylePlain
                                                               target:self
                                                               action:@selector(resetTapped)];
    resetBtn.tintColor = [UIColor systemRedColor];
    UIBarButtonItem *flex = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemFlexibleSpace target:nil action:nil];
    
    self.toolbarItems = @[addBtn, flex, resetBtn];
    self.navigationController.toolbarHidden = NO;
    
    // Background
    if ([[BackgroundManager sharedManager] hasBackground]) {
        self.view.backgroundColor = [UIColor clearColor];
    } else {
        self.view.backgroundColor = [UIColor systemGroupedBackgroundColor];
    }
    
    [self setupTableView];

    // Adapt to the custom launcher background: make this view controller transparent so the global background (image/video) shows through.
    // This controller subclasses UIViewController (not UITableViewController) and creates its tableView by hand,
    // so makeViewControllerTransparent clears the view background; the tableView background is already cleared in setupTableView.
    [[BackgroundManager sharedManager] makeViewControllerTransparent:self];

    // Listen for background UI effect changes: when the user switches between frosted glass and translucent, or adjusts the opacity,
    // call makeViewControllerTransparent again to apply the latest look and keep the background showing correctly.
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(reapplyBackgroundEffect)
                                                 name:@"BackgroundUIEffectChanged"
                                               object:nil];

    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(handleBackgroundUIEffectChanged:)
                                                 name:@"BackgroundUIEffectChanged"
                                               object:nil];
}

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self name:@"BackgroundUIEffectChanged" object:nil];
}

- (void)setupTableView {
    self.tableView = [[UITableView alloc] initWithFrame:CGRectZero style:UITableViewStylePlain];
    self.tableView.translatesAutoresizingMaskIntoConstraints = NO;
    self.tableView.backgroundColor = [UIColor clearColor];
    self.tableView.dataSource = self;
    self.tableView.delegate = self;
    self.tableView.separatorStyle = UITableViewCellSeparatorStyleNone;
    self.tableView.rowHeight = 68;
    self.tableView.editing = YES;  // Always in editing mode so rows can be dragged
    self.tableView.allowsSelectionDuringEditing = YES;
    self.tableView.showsVerticalScrollIndicator = NO;
    self.tableView.contentInset = UIEdgeInsetsMake(8, 0, 20, 0);
    
    [self.tableView registerClass:[CustomizeTileCell class] forCellReuseIdentifier:@"TileCell"];
    
    [self.view addSubview:self.tableView];
    
    [NSLayoutConstraint activateConstraints:@[
        [self.tableView.topAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.topAnchor],
        [self.tableView.bottomAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.bottomAnchor],
        [self.tableView.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [self.tableView.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
    ]];
}

// MARK: - Navigation Actions

- (void)cancelTapped {
    [self dismissViewControllerAnimated:YES completion:nil];
}

- (void)saveTapped {
    if (self.onConfigsChanged) {
        self.onConfigsChanged([self.editingConfigs copy]);
    }
    [self dismissViewControllerAnimated:YES completion:nil];
}

- (void)resetTapped {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Reset layout"
                                                                   message:@"Restore the default home layout? All of your customizations will be lost."
                                                            preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    [alert addAction:[UIAlertAction actionWithTitle:@"Reset" style:UIAlertActionStyleDestructive handler:^(UIAlertAction *action) {
        self.editingConfigs = [[HomeTileConfig defaultTileConfigs] mutableCopy];
        [self.tableView reloadData];
    }]];
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)addShortcutTapped {
    UIAlertController *sheet = [UIAlertController alertControllerWithTitle:@"Add shortcut"
                                                                   message:@"Choose a feature to add"
                                                            preferredStyle:UIAlertControllerStyleActionSheet];
    
    NSDictionary *shortcuts = availableShortcuts();
    for (NSString *key in shortcuts) {
        NSDictionary *info = shortcuts[key];
        
        // Check whether it already exists
        BOOL exists = NO;
        for (HomeTileConfig *c in self.editingConfigs) {
            if ([c.shortcutAction isEqualToString:key]) {
                exists = YES;
                break;
            }
        }
        if (exists) continue;
        
        [sheet addAction:[UIAlertAction actionWithTitle:info[@"title"] style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
            HomeTileConfig *newTile = [[HomeTileConfig alloc] init];
            newTile.tileId = [NSString stringWithFormat:@"shortcut_%@_%@", key, [[NSUUID UUID] UUIDString]];
            newTile.tileType = HomeTileTypeShortcut;
            newTile.tileSize = HomeTileSizeCompact;
            newTile.visible = YES;
            newTile.customTitle = info[@"title"];
            newTile.iconName = info[@"icon"];
            newTile.shortcutAction = key;
            newTile.accentColorHex = info[@"color"];
            
            [self.editingConfigs addObject:newTile];
            [self.tableView insertRowsAtIndexPaths:@[[NSIndexPath indexPathForRow:self.editingConfigs.count - 1 inSection:0]]
                                  withRowAnimation:UITableViewRowAnimationAutomatic];
        }]];
    }
    
    [sheet addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    
    // iPad popover support
    sheet.popoverPresentationController.barButtonItem = self.toolbarItems.firstObject;
    
    [self presentViewController:sheet animated:YES completion:nil];
}

// MARK: - UITableView DataSource

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    return self.editingConfigs.count;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    CustomizeTileCell *cell = [tableView dequeueReusableCellWithIdentifier:@"TileCell" forIndexPath:indexPath];
    HomeTileConfig *config = self.editingConfigs[indexPath.row];
    [cell configureWithTile:config];
    
    // Wire up the switch handler
    [cell.visibilitySwitch removeTarget:nil action:nil forControlEvents:UIControlEventValueChanged];
    cell.visibilitySwitch.tag = indexPath.row;
    [cell.visibilitySwitch addTarget:self action:@selector(visibilitySwitchChanged:) forControlEvents:UIControlEventValueChanged];
    
    return cell;
}

// MARK: - UITableView Delegate

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    
    HomeTileConfig *config = self.editingConfigs[indexPath.row];
    [self showEditOptionsForTile:config atIndex:indexPath.row];
}

// Drag to reorder
- (BOOL)tableView:(UITableView *)tableView canMoveRowAtIndexPath:(NSIndexPath *)indexPath {
    return YES;
}

- (void)tableView:(UITableView *)tableView moveRowAtIndexPath:(NSIndexPath *)sourceIndexPath toIndexPath:(NSIndexPath *)destinationIndexPath {
    HomeTileConfig *tile = self.editingConfigs[sourceIndexPath.row];
    [self.editingConfigs removeObjectAtIndex:sourceIndexPath.row];
    [self.editingConfigs insertObject:tile atIndex:destinationIndexPath.row];
}

// Delete (only shortcuts can be deleted)
- (UITableViewCellEditingStyle)tableView:(UITableView *)tableView editingStyleForRowAtIndexPath:(NSIndexPath *)indexPath {
    HomeTileConfig *config = self.editingConfigs[indexPath.row];
    return config.tileType == HomeTileTypeShortcut ? UITableViewCellEditingStyleDelete : UITableViewCellEditingStyleNone;
}

- (void)tableView:(UITableView *)tableView commitEditingStyle:(UITableViewCellEditingStyle)editingStyle forRowAtIndexPath:(NSIndexPath *)indexPath {
    if (editingStyle == UITableViewCellEditingStyleDelete) {
        [self.editingConfigs removeObjectAtIndex:indexPath.row];
        [tableView deleteRowsAtIndexPaths:@[indexPath] withRowAnimation:UITableViewRowAnimationFade];
    }
}

- (BOOL)tableView:(UITableView *)tableView shouldIndentWhileEditingRowAtIndexPath:(NSIndexPath *)indexPath {
    return NO;
}

// MARK: - Edit Tile Options

- (void)showEditOptionsForTile:(HomeTileConfig *)tile atIndex:(NSInteger)index {
    UIAlertController *sheet = [UIAlertController alertControllerWithTitle:@"Edit tile"
                                                                   message:nil
                                                            preferredStyle:UIAlertControllerStyleActionSheet];
    
    // Change the size
    NSString *sizeTitle = tile.tileSize == HomeTileSizeCompact ? @"Switch to full width" : @"Switch to compact (half width)";
    [sheet addAction:[UIAlertAction actionWithTitle:sizeTitle style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
        tile.tileSize = (tile.tileSize == HomeTileSizeCompact) ? HomeTileSizeFull : HomeTileSizeCompact;
        [self.tableView reloadRowsAtIndexPaths:@[[NSIndexPath indexPathForRow:index inSection:0]]
                              withRowAnimation:UITableViewRowAnimationAutomatic];
    }]];
    
    // Change the title (only shortcuts and some tiles)
    if (tile.tileType == HomeTileTypeShortcut || tile.tileType == HomeTileTypeVersionRelease || tile.tileType == HomeTileTypeVersionSnapshot) {
        [sheet addAction:[UIAlertAction actionWithTitle:@"Change title" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
            [self showEditTitleForTile:tile atIndex:index];
        }]];
    }
    
    // Change the color
    [sheet addAction:[UIAlertAction actionWithTitle:@"Change accent color" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
        [self showColorPickerForTile:tile atIndex:index];
    }]];
    
    // Toggle visibility
    NSString *visTitle = tile.visible ? @"Hide this tile" : @"Show this tile";
    [sheet addAction:[UIAlertAction actionWithTitle:visTitle style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
        tile.visible = !tile.visible;
        [self.tableView reloadRowsAtIndexPaths:@[[NSIndexPath indexPathForRow:index inSection:0]]
                              withRowAnimation:UITableViewRowAnimationAutomatic];
    }]];
    
    // Delete (shortcuts only)
    if (tile.tileType == HomeTileTypeShortcut) {
        [sheet addAction:[UIAlertAction actionWithTitle:@"Delete" style:UIAlertActionStyleDestructive handler:^(UIAlertAction *action) {
            [self.editingConfigs removeObjectAtIndex:index];
            [self.tableView deleteRowsAtIndexPaths:@[[NSIndexPath indexPathForRow:index inSection:0]]
                                  withRowAnimation:UITableViewRowAnimationFade];
        }]];
    }
    
    [sheet addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    
    // iPad popover
    sheet.popoverPresentationController.sourceView = [self.tableView cellForRowAtIndexPath:[NSIndexPath indexPathForRow:index inSection:0]];
    sheet.popoverPresentationController.sourceRect = sheet.popoverPresentationController.sourceView.bounds;
    
    [self presentViewController:sheet animated:YES completion:nil];
}

- (void)showEditTitleForTile:(HomeTileConfig *)tile atIndex:(NSInteger)index {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Change title"
                                                                   message:@"Enter a new tile title"
                                                            preferredStyle:UIAlertControllerStyleAlert];
    [alert addTextFieldWithConfigurationHandler:^(UITextField *tf) {
        tf.text = tile.customTitle;
        tf.placeholder = @"Tile title";
        tf.clearButtonMode = UITextFieldViewModeWhileEditing;
    }];
    
    [alert addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    [alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
        NSString *newTitle = alert.textFields.firstObject.text;
        if (newTitle.length > 0) {
            tile.customTitle = newTitle;
            [self.tableView reloadRowsAtIndexPaths:@[[NSIndexPath indexPathForRow:index inSection:0]]
                                  withRowAnimation:UITableViewRowAnimationAutomatic];
        }
    }]];
    
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)showColorPickerForTile:(HomeTileConfig *)tile atIndex:(NSInteger)index {
    UIAlertController *sheet = [UIAlertController alertControllerWithTitle:@"Choose accent color"
                                                                   message:nil
                                                            preferredStyle:UIAlertControllerStyleActionSheet];
    
    NSDictionary *colors = @{
        @"Purple":   @"#8B5CF6",
        @"Blue":   @"#3B82F6",
        @"Teal":   @"#14B8A6",
        @"Green":   @"#10B981",
        @"Yellow":   @"#F59E0B",
        @"Orange":   @"#F97316",
        @"Red":   @"#EF4444",
        @"Pink":   @"#EC4899",
        @"Indigo":   @"#6366F1",
    };
    
    for (NSString *name in @[@"Purple", @"Blue", @"Teal", @"Green", @"Yellow", @"Orange", @"Red", @"Pink", @"Indigo"]) {
        NSString *hex = colors[name];
        [sheet addAction:[UIAlertAction actionWithTitle:name style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
            tile.accentColorHex = hex;
            [self.tableView reloadRowsAtIndexPaths:@[[NSIndexPath indexPathForRow:index inSection:0]]
                                  withRowAnimation:UITableViewRowAnimationAutomatic];
        }]];
    }
    
    [sheet addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    
    sheet.popoverPresentationController.sourceView = [self.tableView cellForRowAtIndexPath:[NSIndexPath indexPathForRow:index inSection:0]];
    sheet.popoverPresentationController.sourceRect = sheet.popoverPresentationController.sourceView.bounds;
    
    [self presentViewController:sheet animated:YES completion:nil];
}

// MARK: - Switch Actions

- (void)visibilitySwitchChanged:(UISwitch *)sender {
    NSInteger index = sender.tag;
    if (index < self.editingConfigs.count) {
        self.editingConfigs[index].visible = sender.on;
        [self.tableView reloadRowsAtIndexPaths:@[[NSIndexPath indexPathForRow:index inSection:0]]
                              withRowAnimation:UITableViewRowAnimationAutomatic];
    }
}

// MARK: - Orientation

- (BOOL)shouldAutorotate {
    return YES;
}

- (UIInterfaceOrientationMask)supportedInterfaceOrientations {
    return UIInterfaceOrientationMaskLandscape;
}

- (void)handleBackgroundUIEffectChanged:(NSNotification *)notification {
    dispatch_async(dispatch_get_main_queue(), ^{
        [self.tableView reloadData];
    });
}

/// Re-apply the background effect: called when the BackgroundUIEffectChanged notification arrives.
/// Re-applies the opacity/frosted-glass effect to this view controller via BackgroundManager,
/// and clear the tableView background color manually, so the global background shows through.
- (void)reapplyBackgroundEffect {
    [[BackgroundManager sharedManager] makeViewControllerTransparent:self];
    self.tableView.backgroundColor = [UIColor clearColor];
}

@end
