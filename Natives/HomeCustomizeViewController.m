#import "HomeCustomizeViewController.h"
#import "LauncherNewsViewController.h"
#import "BackgroundManager.h"
#import <QuartzCore/QuartzCore.h>

// MARK: - Available Shortcut Definitions

static NSDictionary *availableShortcuts(void) {
    return @{
        kShortcutActionMods:       @{@"title": @"Mod 管理",    @"icon": @"puzzlepiece.extension.fill", @"color": @"#14B8A6"},
        kShortcutActionShaders:    @{@"title": @"光影管理",    @"icon": @"sun.max.fill",              @"color": @"#F97316"},
        kShortcutActionModpack:    @{@"title": @"整合包导入",  @"icon": @"shippingbox.fill",           @"color": @"#8B5CF6"},
        kShortcutActionBackground: @{@"title": @"壁纸设置",    @"icon": @"photo.fill.on.rectangle.fill",@"color": @"#EC4899"},
        kShortcutActionVersions:   @{@"title": @"版本管理",    @"icon": @"square.stack.3d.up.fill",    @"color": @"#6366F1"},
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
        
        // 左侧装饰条
        self.accentStrip = [[UIView alloc] init];
        self.accentStrip.translatesAutoresizingMaskIntoConstraints = NO;
        self.accentStrip.layer.cornerRadius = 2;
        [self.contentView addSubview:self.accentStrip];
        
        // 图标
        self.tileIconView = [[UIImageView alloc] init];
        self.tileIconView.translatesAutoresizingMaskIntoConstraints = NO;
        self.tileIconView.contentMode = UIViewContentModeScaleAspectFit;
        self.tileIconView.tintColor = [UIColor labelColor];
        [self.contentView addSubview:self.tileIconView];
        
        // 标题
        self.tileTitleLabel = [[UILabel alloc] init];
        self.tileTitleLabel.translatesAutoresizingMaskIntoConstraints = NO;
        self.tileTitleLabel.font = [UIFont systemFontOfSize:15 weight:UIFontWeightSemibold];
        self.tileTitleLabel.textColor = [UIColor labelColor];
        [self.contentView addSubview:self.tileTitleLabel];
        
        // 详情（类型+大小）
        self.tileDetailLabel = [[UILabel alloc] init];
        self.tileDetailLabel.translatesAutoresizingMaskIntoConstraints = NO;
        self.tileDetailLabel.font = [UIFont systemFontOfSize:11 weight:UIFontWeightMedium];
        self.tileDetailLabel.textColor = [UIColor tertiaryLabelColor];
        [self.contentView addSubview:self.tileDetailLabel];
        
        // 尺寸标签
        self.sizeLabel = [[UILabel alloc] init];
        self.sizeLabel.translatesAutoresizingMaskIntoConstraints = NO;
        self.sizeLabel.font = [UIFont systemFontOfSize:10 weight:UIFontWeightBold];
        self.sizeLabel.textColor = [UIColor secondaryLabelColor];
        self.sizeLabel.textAlignment = NSTextAlignmentCenter;
        self.sizeLabel.layer.cornerRadius = 4;
        self.sizeLabel.layer.masksToBounds = YES;
        self.sizeLabel.backgroundColor = [UIColor colorWithWhite:0.2 alpha:0.5];
        [self.contentView addSubview:self.sizeLabel];
        
        // 可见性开关
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
    self.sizeLabel.text = tile.tileSize == HomeTileSizeCompact ? @"半宽" : @"全宽";
    
    CGFloat alpha = tile.visible ? 1.0 : 0.45;
    self.tileTitleLabel.alpha = alpha;
    self.tileIconView.alpha = alpha;
    self.tileDetailLabel.alpha = alpha;
}

- (NSString *)displayTitleForTile:(HomeTileConfig *)tile {
    if (tile.customTitle.length > 0) return tile.customTitle;
    switch (tile.tileType) {
        case HomeTileTypeProfile:        return @"用户资料";
        case HomeTileTypeAnnouncement:   return @"公告";
        case HomeTileTypeVersionRelease: return @"最新正式版";
        case HomeTileTypeVersionSnapshot:return @"最新快照";
        case HomeTileTypeNews:           return @"Minecraft 新闻";
        case HomeTileTypeShortcut:       return tile.shortcutAction ?: @"快捷入口";
        default:                         return @"磁贴";
    }
}

- (NSString *)displayDetailForTile:(HomeTileConfig *)tile {
    NSString *type;
    switch (tile.tileType) {
        case HomeTileTypeProfile:        type = @"资料卡"; break;
        case HomeTileTypeAnnouncement:   type = @"公告"; break;
        case HomeTileTypeVersionRelease: type = @"版本信息"; break;
        case HomeTileTypeVersionSnapshot:type = @"版本信息"; break;
        case HomeTileTypeNews:           type = @"新闻"; break;
        case HomeTileTypeShortcut:       type = @"快捷入口"; break;
        default:                         type = @"未知"; break;
    }
    NSString *size = tile.tileSize == HomeTileSizeCompact ? @"紧凑" : @"全宽";
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
    
    self.title = @"自定义主页";
    self.editingConfigs = [self.tileConfigs mutableCopy];
    
    // 导航栏按钮
    self.navigationItem.leftBarButtonItem = [[UIBarButtonItem alloc] initWithTitle:@"取消"
                                                                            style:UIBarButtonItemStylePlain
                                                                           target:self
                                                                           action:@selector(cancelTapped)];
    
    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithTitle:@"保存"
                                                                             style:UIBarButtonItemStyleDone
                                                                            target:self
                                                                            action:@selector(saveTapped)];
    
    // 工具栏按钮
    UIBarButtonItem *addBtn = [[UIBarButtonItem alloc] initWithTitle:@"添加快捷入口"
                                                              style:UIBarButtonItemStylePlain
                                                             target:self
                                                             action:@selector(addShortcutTapped)];
    UIBarButtonItem *resetBtn = [[UIBarButtonItem alloc] initWithTitle:@"重置默认"
                                                                style:UIBarButtonItemStylePlain
                                                               target:self
                                                               action:@selector(resetTapped)];
    resetBtn.tintColor = [UIColor systemRedColor];
    UIBarButtonItem *flex = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemFlexibleSpace target:nil action:nil];
    
    self.toolbarItems = @[addBtn, flex, resetBtn];
    self.navigationController.toolbarHidden = NO;
    
    // 背景
    if ([[BackgroundManager sharedManager] hasBackground]) {
        self.view.backgroundColor = [UIColor clearColor];
    } else {
        self.view.backgroundColor = [UIColor systemGroupedBackgroundColor];
    }
    
    [self setupTableView];

    // 适配自定义启动器背景：将当前视图控制器透明化，让全局背景（图片/视频）能够透出显示。
    // 本控制器为 UIViewController 子类（非 UITableViewController），其 tableView 为手动创建，
    // makeViewControllerTransparent 会设置 view 背景透明；tableView 背景已在 setupTableView 中清空。
    [[BackgroundManager sharedManager] makeViewControllerTransparent:self];

    // 监听背景 UI 效果变化通知：当用户在背景设置中切换毛玻璃/半透明或调整透明度时，
    // 重新调用 makeViewControllerTransparent 以应用最新的视觉效果，保证背景始终正确透出。
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
    self.tableView.editing = YES;  // 始终处于编辑模式以支持拖拽
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
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"重置布局"
                                                                   message:@"确定要恢复默认主页布局吗？所有自定义设置将丢失。"
                                                            preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    [alert addAction:[UIAlertAction actionWithTitle:@"重置" style:UIAlertActionStyleDestructive handler:^(UIAlertAction *action) {
        self.editingConfigs = [[HomeTileConfig defaultTileConfigs] mutableCopy];
        [self.tableView reloadData];
    }]];
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)addShortcutTapped {
    UIAlertController *sheet = [UIAlertController alertControllerWithTitle:@"添加快捷入口"
                                                                   message:@"选择要添加的功能"
                                                            preferredStyle:UIAlertControllerStyleActionSheet];
    
    NSDictionary *shortcuts = availableShortcuts();
    for (NSString *key in shortcuts) {
        NSDictionary *info = shortcuts[key];
        
        // 检查是否已存在
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
    
    [sheet addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    
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
    
    // 绑定开关事件
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

// 拖拽排序
- (BOOL)tableView:(UITableView *)tableView canMoveRowAtIndexPath:(NSIndexPath *)indexPath {
    return YES;
}

- (void)tableView:(UITableView *)tableView moveRowAtIndexPath:(NSIndexPath *)sourceIndexPath toIndexPath:(NSIndexPath *)destinationIndexPath {
    HomeTileConfig *tile = self.editingConfigs[sourceIndexPath.row];
    [self.editingConfigs removeObjectAtIndex:sourceIndexPath.row];
    [self.editingConfigs insertObject:tile atIndex:destinationIndexPath.row];
}

// 删除 (仅快捷入口可删除)
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
    UIAlertController *sheet = [UIAlertController alertControllerWithTitle:@"编辑磁贴"
                                                                   message:nil
                                                            preferredStyle:UIAlertControllerStyleActionSheet];
    
    // 切换大小
    NSString *sizeTitle = tile.tileSize == HomeTileSizeCompact ? @"切换为全宽" : @"切换为紧凑(半宽)";
    [sheet addAction:[UIAlertAction actionWithTitle:sizeTitle style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
        tile.tileSize = (tile.tileSize == HomeTileSizeCompact) ? HomeTileSizeFull : HomeTileSizeCompact;
        [self.tableView reloadRowsAtIndexPaths:@[[NSIndexPath indexPathForRow:index inSection:0]]
                              withRowAnimation:UITableViewRowAnimationAutomatic];
    }]];
    
    // 修改标题 (仅快捷入口和部分磁贴)
    if (tile.tileType == HomeTileTypeShortcut || tile.tileType == HomeTileTypeVersionRelease || tile.tileType == HomeTileTypeVersionSnapshot) {
        [sheet addAction:[UIAlertAction actionWithTitle:@"修改标题" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
            [self showEditTitleForTile:tile atIndex:index];
        }]];
    }
    
    // 修改颜色
    [sheet addAction:[UIAlertAction actionWithTitle:@"修改装饰色" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
        [self showColorPickerForTile:tile atIndex:index];
    }]];
    
    // 切换可见性
    NSString *visTitle = tile.visible ? @"隐藏此磁贴" : @"显示此磁贴";
    [sheet addAction:[UIAlertAction actionWithTitle:visTitle style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
        tile.visible = !tile.visible;
        [self.tableView reloadRowsAtIndexPaths:@[[NSIndexPath indexPathForRow:index inSection:0]]
                              withRowAnimation:UITableViewRowAnimationAutomatic];
    }]];
    
    // 删除 (仅快捷入口)
    if (tile.tileType == HomeTileTypeShortcut) {
        [sheet addAction:[UIAlertAction actionWithTitle:@"删除" style:UIAlertActionStyleDestructive handler:^(UIAlertAction *action) {
            [self.editingConfigs removeObjectAtIndex:index];
            [self.tableView deleteRowsAtIndexPaths:@[[NSIndexPath indexPathForRow:index inSection:0]]
                                  withRowAnimation:UITableViewRowAnimationFade];
        }]];
    }
    
    [sheet addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    
    // iPad popover
    sheet.popoverPresentationController.sourceView = [self.tableView cellForRowAtIndexPath:[NSIndexPath indexPathForRow:index inSection:0]];
    sheet.popoverPresentationController.sourceRect = sheet.popoverPresentationController.sourceView.bounds;
    
    [self presentViewController:sheet animated:YES completion:nil];
}

- (void)showEditTitleForTile:(HomeTileConfig *)tile atIndex:(NSInteger)index {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"修改标题"
                                                                   message:@"输入新的磁贴标题"
                                                            preferredStyle:UIAlertControllerStyleAlert];
    [alert addTextFieldWithConfigurationHandler:^(UITextField *tf) {
        tf.text = tile.customTitle;
        tf.placeholder = @"磁贴标题";
        tf.clearButtonMode = UITextFieldViewModeWhileEditing;
    }];
    
    [alert addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    [alert addAction:[UIAlertAction actionWithTitle:@"确定" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
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
    UIAlertController *sheet = [UIAlertController alertControllerWithTitle:@"选择装饰色"
                                                                   message:nil
                                                            preferredStyle:UIAlertControllerStyleActionSheet];
    
    NSDictionary *colors = @{
        @"紫色":   @"#8B5CF6",
        @"蓝色":   @"#3B82F6",
        @"青色":   @"#14B8A6",
        @"绿色":   @"#10B981",
        @"黄色":   @"#F59E0B",
        @"橙色":   @"#F97316",
        @"红色":   @"#EF4444",
        @"粉色":   @"#EC4899",
        @"靛蓝":   @"#6366F1",
    };
    
    for (NSString *name in @[@"紫色", @"蓝色", @"青色", @"绿色", @"黄色", @"橙色", @"红色", @"粉色", @"靛蓝"]) {
        NSString *hex = colors[name];
        [sheet addAction:[UIAlertAction actionWithTitle:name style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
            tile.accentColorHex = hex;
            [self.tableView reloadRowsAtIndexPaths:@[[NSIndexPath indexPathForRow:index inSection:0]]
                                  withRowAnimation:UITableViewRowAnimationAutomatic];
        }]];
    }
    
    [sheet addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    
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

/// 重新应用背景效果：当 BackgroundUIEffectChanged 通知到达时调用，
/// 通过 BackgroundManager 重新设置当前视图控制器的透明度/毛玻璃效果，
/// 并手动清空 tableView 背景色，确保全局背景能够正常透出。
- (void)reapplyBackgroundEffect {
    [[BackgroundManager sharedManager] makeViewControllerTransparent:self];
    self.tableView.backgroundColor = [UIColor clearColor];
}

@end
