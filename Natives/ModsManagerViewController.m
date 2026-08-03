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

// ===== 选择模式相关 =====
@property (nonatomic, assign) BOOL isSelectMode; // 是否处于选择模式
@property (nonatomic, strong) NSMutableArray<ModItem *> *selectedMods; // 已选中的 Mod 列表
@property (nonatomic, strong) UIToolbar *bottomToolbar; // 底部工具栏（选择模式下显示）
@property (nonatomic, strong) UIBarButtonItem *selectButtonItem; // 导航栏"选择"按钮（普通模式进入选择模式）
@property (nonatomic, strong) UIBarButtonItem *doneButtonItem; // 导航栏"完成"按钮（退出选择模式）
@property (nonatomic, strong) UIBarButtonItem *navSelectAllButtonItem; // 导航栏左侧"全选"按钮
@property (nonatomic, strong) UIBarButtonItem *toolbarSelectAllButtonItem; // 底部工具栏"全选"按钮
@property (nonatomic, strong) UIBarButtonItem *toolbarDeselectAllButtonItem; // 底部工具栏"取消全选"按钮
@property (nonatomic, strong) UIBarButtonItem *toolbarDeleteButtonItem; // 底部工具栏"删除选中"按钮
@property (nonatomic, strong) UIBarButtonItem *flexibleSpaceItem; // 工具栏弹性间距
@property (nonatomic, copy) NSString *originalTitle; // 进入选择模式前的原始标题，用于退出时恢复

@end

@implementation ModsManagerViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"管理 Mod";
    self.originalTitle = self.title; // 保存原始标题，退出选择模式时恢复
    self.view.backgroundColor = [UIColor systemBackgroundColor];
    // 适配自定义启动器背景：透明化当前 VC，让全局背景图/毛玻璃透出
    [[BackgroundManager sharedManager] makeViewControllerTransparent:self];
    self.currentMode = ModsManagerModeLocal; // 始终使用本地模式（在线下载入口已移至下载界面）
    self.localMods = [NSMutableArray array];
    self.filteredLocalMods = [NSMutableArray array];
    self.onlineSearchResults = [NSMutableArray array];
    self.selectedMods = [NSMutableArray array]; // 初始化已选中 Mod 列表
    self.isSelectMode = NO;
    [self setupUI];
    // 修复"前一个页面没有及时消失"：给 view 添加毛玻璃遮挡层，
    // 防止 push 转场时透出栈底 ProfileSettingsViewController 的内容
    [[BackgroundManager sharedManager] applyEffectToView:self.view];
    // 透明化 tableView 背景，避免遮挡全局背景
    self.tableView.backgroundColor = [UIColor clearColor];
    self.tableView.backgroundView = nil;
    [self updateUIForCurrentMode];
    [self refreshLocalModsList];

    // 监听背景效果变化通知，背景切换时重新应用透明效果
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(reapplyBackgroundEffect)
                                                 name:@"BackgroundUIEffectChanged"
                                               object:nil];
}

- (void)reapplyBackgroundEffect {
    // 背景效果改变时重新透明化当前 VC
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
    // 移除通知观察者，避免dealloc后收到通知导致崩溃
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

- (void)setupUI {
    self.searchBar = [[UISearchBar alloc] initWithFrame:CGRectZero];
    self.searchBar.translatesAutoresizingMaskIntoConstraints = NO;
    self.searchBar.delegate = self;
    self.searchBar.placeholder = @"搜索本地 Mod...";
    // 适配自定义启动器背景：透明化 searchBar 默认不透明背景，让全局背景图/毛玻璃透出
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
    self.checkUpdateButton.accessibilityLabel = @"检查更新";

    UIImage *importImage = [UIImage systemImageNamed:@"square.and.arrow.down"] ?: [UIImage systemImageNamed:@"plus"];
    self.importButton = [[UIBarButtonItem alloc] initWithImage:importImage style:UIBarButtonItemStylePlain target:self action:@selector(importModTapped)];
    self.importButton.accessibilityLabel = @"导入 Mod";

    // 选择模式相关按钮初始化
    UIImage *selectImage = [UIImage systemImageNamed:@"checklist"] ?: [UIImage systemImageNamed:@"checkmark.circle"];
    self.selectButtonItem = [[UIBarButtonItem alloc] initWithImage:selectImage style:UIBarButtonItemStylePlain target:self action:@selector(enterSelectMode)];
    self.selectButtonItem.accessibilityLabel = @"选择";

    self.doneButtonItem = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemDone target:self action:@selector(exitSelectMode)];
    self.doneButtonItem.accessibilityLabel = @"完成";

    self.navSelectAllButtonItem = [[UIBarButtonItem alloc] initWithTitle:@"全选" style:UIBarButtonItemStylePlain target:self action:@selector(toggleSelectAll)];
    self.toolbarSelectAllButtonItem = [[UIBarButtonItem alloc] initWithTitle:@"全选" style:UIBarButtonItemStylePlain target:self action:@selector(selectAll)];
    self.toolbarDeselectAllButtonItem = [[UIBarButtonItem alloc] initWithTitle:@"取消全选" style:UIBarButtonItemStylePlain target:self action:@selector(deselectAll)];
    self.toolbarDeleteButtonItem = [[UIBarButtonItem alloc] initWithTitle:@"删除选中" style:UIBarButtonItemStylePlain target:self action:@selector(deleteSelectedMods)];
    self.toolbarDeleteButtonItem.tintColor = [UIColor systemRedColor];
    self.flexibleSpaceItem = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemFlexibleSpace target:nil action:nil];

    // 底部工具栏（选择模式下显示）
    self.bottomToolbar = [[UIToolbar alloc] initWithFrame:CGRectZero];
    self.bottomToolbar.translatesAutoresizingMaskIntoConstraints = NO;
    self.bottomToolbar.hidden = YES; // 初始隐藏，进入选择模式时显示
    [self.view addSubview:self.bottomToolbar];

    [self updateNavigationButtons];

    [NSLayoutConstraint activateConstraints:@[
        [self.searchBar.topAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.topAnchor constant:8],
        [self.searchBar.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [self.searchBar.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],

        [self.tableView.topAnchor constraintEqualToAnchor:self.searchBar.bottomAnchor],
        [self.tableView.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [self.tableView.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        // tableView 底部根据是否选择模式动态绑定到工具栏顶部或安全区底部
        // 这里默认绑定安全区底部；进入选择模式时通过代码调整
        [self.tableView.bottomAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.bottomAnchor],

        [self.activityIndicator.centerXAnchor constraintEqualToAnchor:self.tableView.centerXAnchor],
        [self.activityIndicator.centerYAnchor constraintEqualToAnchor:self.tableView.centerYAnchor],

        [self.emptyLabel.centerXAnchor constraintEqualToAnchor:self.tableView.centerXAnchor],
        [self.emptyLabel.centerYAnchor constraintEqualToAnchor:self.tableView.centerYAnchor],

        // 底部工具栏布局：贴底显示，左右贴边
        [self.bottomToolbar.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [self.bottomToolbar.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [self.bottomToolbar.bottomAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.bottomAnchor]
    ]];
}

- (void)updateUIForCurrentMode {
    self.searchBar.placeholder = @"搜索本地 Mod...";
    self.emptyLabel.text = @"未发现 Mod";
    self.emptyLabel.hidden = self.localMods.count > 0;
    self.tableView.refreshControl.enabled = YES;
    [self updateNavigationButtons];
    [self.tableView reloadData];
}

- (void)updateNavigationButtons {
    if (self.isSelectMode) {
        // 选择模式：左侧"全选"，右侧"完成"，标题显示已选数量
        [self updateSelectAllButtonTitle];
        self.navigationItem.leftBarButtonItem = self.navSelectAllButtonItem;
        self.navigationItem.rightBarButtonItems = @[self.doneButtonItem];
        [self updateSelectModeTitle];
    } else {
        // 普通模式：左侧关闭按钮，右侧依次为：选择、导入、刷新、检查更新
        UIBarButtonItem *closeButton = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemDone target:self action:@selector(closeTapped)];
        // 列表为空时禁用"选择"按钮
        self.selectButtonItem.enabled = self.filteredLocalMods.count > 0;
        // rightBarButtonItems 从右到左显示：导入、刷新、检查更新、选择
        self.navigationItem.rightBarButtonItems = @[self.importButton, self.refreshButton, self.checkUpdateButton, self.selectButtonItem];
        self.navigationItem.leftBarButtonItem = closeButton;
        self.title = self.originalTitle;
    }
}

- (void)closeTapped {
    // 兼容两种容器：
    // - push 进 UINavigationController（卡片式布局/版本管理跳转）：pop 回上一级
    // - present 弹窗（旧调用路径）：dismiss
    if (self.navigationController && self.navigationController.viewControllers.firstObject != self) {
        [self.navigationController popViewControllerAnimated:YES];
    } else {
        [self dismissViewControllerAnimated:YES completion:nil];
    }
}

#pragma mark - Select Mode (选择模式)

// 进入选择模式
- (void)enterSelectMode {
    if (self.filteredLocalMods.count == 0) return; // 没有数据时不允许进入选择模式

    self.isSelectMode = YES;
    [self.selectedMods removeAllObjects]; // 进入选择模式时清空已选列表
    // 显示底部工具栏
    self.bottomToolbar.hidden = NO;
    self.bottomToolbar.items = @[self.toolbarSelectAllButtonItem,
                                  self.flexibleSpaceItem,
                                  self.toolbarDeselectAllButtonItem,
                                  self.flexibleSpaceItem,
                                  self.toolbarDeleteButtonItem];
    // 调整 tableView 底部内边距，避免最后一行被工具栏遮挡
    CGFloat toolbarHeight = self.bottomToolbar.bounds.size.height;
    if (toolbarHeight <= 0) {
        // 工具栏尚未完成布局时使用估算值
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

// 退出选择模式，清除所有选择
- (void)exitSelectMode {
    self.isSelectMode = NO;
    [self.selectedMods removeAllObjects]; // 退出时清除所有选择
    self.bottomToolbar.hidden = YES;
    self.bottomToolbar.items = nil;
    // 恢复 tableView 底部内边距
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

// 切换全选/取消全选（导航栏左侧按钮使用）
- (void)toggleSelectAll {
    if (self.selectedMods.count == self.filteredLocalMods.count) {
        [self deselectAll];
    } else {
        [self selectAll];
    }
}

// 全选：将当前过滤后列表中的所有 Mod 加入已选列表
- (void)selectAll {
    [self.selectedMods removeAllObjects];
    [self.selectedMods addObjectsFromArray:self.filteredLocalMods];
    [self updateNavigationButtons];
    [self reloadVisibleCellsCheckbox];
}

// 取消全选：清空已选列表
- (void)deselectAll {
    [self.selectedMods removeAllObjects];
    [self updateNavigationButtons];
    [self reloadVisibleCellsCheckbox];
}

// 删除选中的 Mod（带确认弹窗）
- (void)deleteSelectedMods {
    if (self.selectedMods.count == 0) {
        [self showSimpleAlertWithTitle:@"提示" message:@"尚未选择任何 Mod"];
        return;
    }

    NSString *message = [NSString stringWithFormat:@"确定要删除选中的 %ld 个 Mod 吗？\n此操作无法撤销。", (long)self.selectedMods.count];
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"批量删除" message:message preferredStyle:UIAlertControllerStyleAlert];

    [alert addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    __weak typeof(self) weakSelf = self;
    [alert addAction:[UIAlertAction actionWithTitle:@"删除" style:UIAlertActionStyleDestructive handler:^(UIAlertAction * _Nonnull action) {
        [weakSelf performDeleteSelectedMods];
    }]];
    [self presentViewController:alert animated:YES completion:nil];
}

// 执行批量删除
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

    // 从数据源中移除已成功删除的 Mod
    for (ModItem *mod in modsToDelete) {
        if ([failedMods containsObject:mod]) continue; // 跳过删除失败的
        NSUInteger idxInFull = [self.localMods indexOfObject:mod];
        if (idxInFull != NSNotFound) [self.localMods removeObjectAtIndex:idxInFull];
        NSUInteger idxInFiltered = [self.filteredLocalMods indexOfObject:mod];
        if (idxInFiltered != NSNotFound) [self.filteredLocalMods removeObjectAtIndex:idxInFiltered];
    }

    // 清空已选列表（失败的项目不再标记为选中）
    [self.selectedMods removeAllObjects];

    if (failedMods.count > 0) {
        // 部分失败时保留选择模式，提示用户哪些失败
        NSMutableArray<NSString *> *names = [NSMutableArray array];
        for (ModItem *m in failedMods) [names addObject:m.displayName];
        [self showSimpleAlertWithTitle:[NSString stringWithFormat:@"删除完成，%ld 项失败", (long)failedMods.count]
                               message:[names componentsJoinedByString:@"\n"]];
        [self updateNavigationButtons];
        [self.tableView reloadData];
    } else {
        // 全部删除成功，退出选择模式
        [self exitSelectMode];
    }
}

// 判断指定 Mod 是否处于选中状态
- (BOOL)isModSelected:(ModItem *)mod {
    return [self.selectedMods containsObject:mod];
}

// 切换某个 Mod 的选中状态（行点击触发）
- (void)toggleSelectionForMod:(ModItem *)mod {
    if ([self.selectedMods containsObject:mod]) {
        [self.selectedMods removeObject:mod];
    } else {
        [self.selectedMods addObject:mod];
    }
    [self updateNavigationButtons];
}

// 更新导航栏标题，显示已选数量
- (void)updateSelectModeTitle {
    if (self.isSelectMode) {
        self.title = [NSString stringWithFormat:@"已选 %ld 个", (long)self.selectedMods.count];
    }
}

// 更新"全选"按钮的标题（已全选时显示"取消全选"）
- (void)updateSelectAllButtonTitle {
    if (self.selectedMods.count > 0 && self.selectedMods.count == self.filteredLocalMods.count && self.filteredLocalMods.count > 0) {
        self.navSelectAllButtonItem.title = @"取消全选";
        self.toolbarSelectAllButtonItem.enabled = NO;
        self.toolbarDeselectAllButtonItem.enabled = YES;
    } else if (self.selectedMods.count == 0) {
        self.navSelectAllButtonItem.title = @"全选";
        self.toolbarSelectAllButtonItem.enabled = YES;
        self.toolbarDeselectAllButtonItem.enabled = NO;
    } else {
        self.navSelectAllButtonItem.title = @"全选";
        self.toolbarSelectAllButtonItem.enabled = YES;
        self.toolbarDeselectAllButtonItem.enabled = YES;
    }
    // 没有任何数据时禁用全选相关按钮
    if (self.filteredLocalMods.count == 0) {
        self.navSelectAllButtonItem.enabled = NO;
        self.toolbarSelectAllButtonItem.enabled = NO;
        self.toolbarDeselectAllButtonItem.enabled = NO;
    } else {
        self.navSelectAllButtonItem.enabled = YES;
    }
    // 删除按钮：未选中时禁用
    self.toolbarDeleteButtonItem.enabled = self.selectedMods.count > 0;
}

// 刷新所有可见 Cell 的复选框状态（避免整表 reloadData 引起闪烁）
- (void)reloadVisibleCellsCheckbox {
    for (NSIndexPath *indexPath in [self.tableView indexPathsForVisibleRows]) {
        UITableViewCell *cell = [self.tableView cellForRowAtIndexPath:indexPath];
        if (!cell) continue;
        ModItem *mod = self.filteredLocalMods[indexPath.row];
        [self applyCheckboxToCell:cell selected:[self isModSelected:mod]];
    }
}

// 为 Cell 应用复选框（选择模式下显示，普通模式下隐藏）
- (void)applyCheckboxToCell:(UITableViewCell *)cell selected:(BOOL)selected {
    if (self.isSelectMode) {
        // 创建复选框 ImageView 作为 accessoryView
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
        // 隐藏 enableSwitch 和 openLinkButton，避免与复选框视觉冲突
        if ([cell isKindOfClass:[ModTableViewCell class]]) {
            ModTableViewCell *modCell = (ModTableViewCell *)cell;
            modCell.enableSwitch.hidden = YES;
            modCell.openLinkButton.hidden = YES;
        }
    } else {
        // 普通模式：清除复选框，恢复原有控件可见性
        cell.accessoryView = nil;
        cell.selectionStyle = UITableViewCellSelectionStyleNone;
        if ([cell isKindOfClass:[ModTableViewCell class]]) {
            ModTableViewCell *modCell = (ModTableViewCell *)cell;
            // 仅在配置时（已调用 configureWithMod:）恢复可见性，避免重复设置不一致
            // enableSwitch/openLinkButton 的最终可见性以 configureWithMod 的设置为准
            modCell.enableSwitch.hidden = NO;
            modCell.openLinkButton.hidden = NO;
        }
    }
}

#pragma mark - Import Mod

- (void)importModTapped {
    // 确保目录存在
    NSError *dirError = nil;
    NSString *modsDir = [[ModService sharedService] ensureModsFolderForProfile:nil error:&dirError];
    if (!modsDir) {
        [self showSimpleAlertWithTitle:@"无法导入" message:dirError.localizedDescription ?: @"无法确定 mods 目录"];
        return;
    }

    // 弹出文件选择器，允许 jar（Forge/NeoForge/Fabric/Quilt 都用 jar）
    UIDocumentPickerViewController *picker = [[UIDocumentPickerViewController alloc] initWithDocumentTypes:@[@"com.sun.java.jar", @"public.item"] inMode:UIDocumentPickerModeImport];
    picker.allowsMultipleSelection = YES;
    picker.delegate = self;
    picker.title = @"选择 Mod 文件";
    [self presentViewController:picker animated:YES completion:nil];
}

- (void)documentPicker:(UIDocumentPickerViewController *)controller didPickDocumentsAtURLs:(NSArray<NSURL *> *)urls {
    if (urls.count == 0) return;

    NSError *dirError = nil;
    NSString *modsDir = [[ModService sharedService] ensureModsFolderForProfile:nil error:&dirError];
    if (!modsDir) {
        [self showSimpleAlertWithTitle:@"导入失败" message:dirError.localizedDescription ?: @"无法确定 mods 目录"];
        return;
    }

    NSFileManager *fm = [NSFileManager defaultManager];
    NSInteger successCount = 0;
    NSMutableArray<NSString *> *failedFiles = [NSMutableArray array];

    for (NSURL *url in urls) {
        // 开始访问安全资源
        BOOL accessing = [url startAccessingSecurityScopedResource];
        @try {
            NSString *fileName = url.lastPathComponent;
            NSString *destPath = [modsDir stringByAppendingPathComponent:fileName];

            // 同名文件处理
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

    // 刷新列表
    [self refreshLocalModsList];

    if (failedFiles.count > 0) {
        [self showSimpleAlertWithTitle:[NSString stringWithFormat:@"导入完成（%ld 成功，%ld 失败）", (long)successCount, (long)failedFiles.count]
                               message:[failedFiles componentsJoinedByString:@"\n"]];
    } else {
        NSLog(@"[ModsManager] Successfully imported %ld mods", (long)successCount);
    }
}



#pragma mark - Check for Updates

- (void)checkForUpdates {
    // 获取当前 profile 的本地 Mod 列表
    NSMutableArray<ModItem *> *mods = [self.localMods mutableCopy];
    if (mods.count == 0) {
        [self showSimpleAlertWithTitle:@"提示" message:@"当前没有本地 Mod，无法检查更新。"];
        return;
    }

    // 从当前 profile 的 lastVersionId 解析 gameVersion 和 loader
    NSString *lastVersionId = PLProfiles.current.selectedProfile[@"lastVersionId"];
    if (!lastVersionId || lastVersionId.length == 0) {
        [self showSimpleAlertWithTitle:@"提示" message:@"无法获取当前版本信息。"];
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
        // 纯 <mc> 格式，无 loader
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
    // 刷新前若处于选择模式，先退出（数据即将更新，避免选择状态与新数据不一致）
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
        self.emptyLabel.text = @"未找到本地 Mod";
    }
    // 更新导航按钮状态（"选择"按钮的可用性、"全选"按钮标题等）
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

    // 根据选择模式应用复选框显示
    if (self.isSelectMode) {
        [self applyCheckboxToCell:cell selected:[self isModSelected:mod]];
    } else {
        [self applyCheckboxToCell:cell selected:NO];
    }

    // 适配自定义启动器背景：为 cell 注入毛玻璃/半透明效果
    // ModTableViewCell 自身 contentView 背景为 clearColor，由 BackgroundManager 统一注入
    [[BackgroundManager sharedManager] applyEffectToCell:cell];

    return cell;
}

- (UISwipeActionsConfiguration *)tableView:(UITableView *)tableView trailingSwipeActionsConfigurationForRowAtIndexPath:(NSIndexPath *)indexPath {
    // 选择模式下禁用滑动删除，避免误操作
    if (self.isSelectMode) return nil;

    UIContextualAction *deleteAction = [UIContextualAction contextualActionWithStyle:UIContextualActionStyleDestructive title:@"删除" handler:^(UIContextualAction * _Nonnull action, __kindof UIView * _Nonnull sourceView, void (^ _Nonnull completionHandler)(BOOL)) {

        ModItem *modToDelete = self.filteredLocalMods[indexPath.row];

        UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"确认删除" message:[NSString stringWithFormat:@"确定要删除 %@ 吗？\n此操作无法撤销。", modToDelete.displayName] preferredStyle:UIAlertControllerStyleAlert];

        [alert addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:^(UIAlertAction * _Nonnull action) {
            completionHandler(NO);
        }]];

        [alert addAction:[UIAlertAction actionWithTitle:@"删除" style:UIAlertActionStyleDestructive handler:^(UIAlertAction * _Nonnull action) {
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
    // 在线下载入口已移除（请使用下载界面），此方法保留以实现协议
}

#pragma mark - ModVersionViewControllerDelegate

- (void)modVersionViewController:(ModVersionViewController *)viewController didSelectVersion:(ModVersion *)version {
    ModItem *itemToDownload = viewController.modItem;
    
    // Find the primary file to download
    NSDictionary *primaryFile = version.primaryFile;
    if (!primaryFile || ![primaryFile[@"url"] isKindOfClass:[NSString class]]) {
        [self showSimpleAlertWithTitle:@"错误" message:@"未找到有效的下载链接。"];
        return;
    }

    itemToDownload.selectedVersionDownloadURL = primaryFile[@"url"];
    itemToDownload.fileName = primaryFile[@"filename"];

    [self startDownloadForItem:itemToDownload];
}

- (void)startDownloadForItem:(ModItem *)item {
    // 始终显示单独下载进度（悬浮球已移除）
    BOOL showProgressUI = YES;
    UIAlertController *downloadingAlert = nil;
    if (showProgressUI) {
        downloadingAlert = [UIAlertController alertControllerWithTitle:@"正在下载"
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
        [self showSimpleAlertWithTitle:@"下载失败" message:error.localizedDescription];
    } else {
        UIAlertController *successAlert = [UIAlertController alertControllerWithTitle:@"下载成功"
                                                                              message:[NSString stringWithFormat:@"%@ 已成功安装。", item.displayName]
                                                                       preferredStyle:UIAlertControllerStyleAlert];
        [successAlert addAction:[UIAlertAction actionWithTitle:@"好" style:UIAlertActionStyleDefault handler:^(UIAlertAction * _Nonnull action) {
            // After user acknowledges, refresh local mods list
            [self refreshLocalModsList];
        }]];
        [self presentViewController:successAlert animated:YES completion:nil];
    }
}

- (void)showSimpleAlertWithTitle:(NSString *)title message:(NSString *)message {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:title message:message preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"好" style:UIAlertActionStyleDefault handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    if (self.isSelectMode) {
        // 选择模式下：点击行切换该 Mod 的选中状态
        ModItem *mod = self.filteredLocalMods[indexPath.row];
        [self toggleSelectionForMod:mod];
        // 直接更新对应 Cell 的复选框，避免整表刷新造成闪烁
        UITableViewCell *cell = [tableView cellForRowAtIndexPath:indexPath];
        if (cell) {
            [self applyCheckboxToCell:cell selected:[self isModSelected:mod]];
        }
        // 不取消选中高亮，让用户看到当前选中行；但视觉上更轻
        [tableView deselectRowAtIndexPath:indexPath animated:YES];
    } else {
        // 普通模式：仅取消高亮，无具体动作
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
        UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"链接不可用" message:@"该 Mod 没有可用的在线链接。" preferredStyle:UIAlertControllerStyleAlert];
        [alert addAction:[UIAlertAction actionWithTitle:@"好" style:UIAlertActionStyleDefault handler:nil]];
        [self presentViewController:alert animated:YES completion:nil];
    }
}

@end
