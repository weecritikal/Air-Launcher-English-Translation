//
//  ShadersManagerViewController.m
//  Amethyst
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

// ===== 选择模式相关 =====
@property (nonatomic, assign) BOOL isSelectMode; // 是否处于选择模式
@property (nonatomic, strong) NSMutableArray<ShaderItem *> *selectedShaders; // 已选中的光影列表
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

@implementation ShadersManagerViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"管理光影";
    self.originalTitle = self.title; // 保存原始标题，退出选择模式时恢复
    self.view.backgroundColor = [UIColor systemBackgroundColor];
    // 适配自定义启动器背景：透明化当前 VC，让全局背景图/毛玻璃透出
    [[BackgroundManager sharedManager] makeViewControllerTransparent:self];
    self.currentMode = ShadersManagerModeLocal; // 始终使用本地模式（在线下载入口已移至下载界面）
    self.localShaders = [NSMutableArray array];
    self.filteredLocalShaders = [NSMutableArray array];
    self.onlineSearchResults = [NSMutableArray array];
    self.selectedShaders = [NSMutableArray array]; // 初始化已选中光影列表
    self.isSelectMode = NO;
    [self setupUI];
    // 修复"前一个页面没有及时消失"：给 view 添加毛玻璃遮挡层，
    // 防止 push 转场时透出栈底 ProfileSettingsViewController 的内容
    [[BackgroundManager sharedManager] applyEffectToView:self.view];
    // 透明化 tableView 背景，避免遮挡全局背景
    self.tableView.backgroundColor = [UIColor clearColor];
    self.tableView.backgroundView = nil;
    [self updateUIForCurrentMode];
    [self refreshLocalShadersList];

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
    self.searchBar.placeholder = @"搜索本地光影...";
    // 适配自定义启动器背景：透明化 searchBar 默认不透明背景，让全局背景图/毛玻璃透出
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
    self.checkUpdateButton.accessibilityLabel = @"检查更新";

    UIImage *importImage = [UIImage systemImageNamed:@"square.and.arrow.down"] ?: [UIImage systemImageNamed:@"plus"];
    self.importButton = [[UIBarButtonItem alloc] initWithImage:importImage style:UIBarButtonItemStylePlain target:self action:@selector(importShaderTapped)];
    self.importButton.accessibilityLabel = @"导入光影";

    // 选择模式相关按钮初始化
    UIImage *selectImage = [UIImage systemImageNamed:@"checklist"] ?: [UIImage systemImageNamed:@"checkmark.circle"];
    self.selectButtonItem = [[UIBarButtonItem alloc] initWithImage:selectImage style:UIBarButtonItemStylePlain target:self action:@selector(enterSelectMode)];
    self.selectButtonItem.accessibilityLabel = @"选择";

    self.doneButtonItem = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemDone target:self action:@selector(exitSelectMode)];
    self.doneButtonItem.accessibilityLabel = @"完成";

    self.navSelectAllButtonItem = [[UIBarButtonItem alloc] initWithTitle:@"全选" style:UIBarButtonItemStylePlain target:self action:@selector(toggleSelectAll)];
    self.toolbarSelectAllButtonItem = [[UIBarButtonItem alloc] initWithTitle:@"全选" style:UIBarButtonItemStylePlain target:self action:@selector(selectAll)];
    self.toolbarDeselectAllButtonItem = [[UIBarButtonItem alloc] initWithTitle:@"取消全选" style:UIBarButtonItemStylePlain target:self action:@selector(deselectAll)];
    self.toolbarDeleteButtonItem = [[UIBarButtonItem alloc] initWithTitle:@"删除选中" style:UIBarButtonItemStylePlain target:self action:@selector(deleteSelectedShaders)];
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
    self.searchBar.placeholder = @"搜索本地光影...";
    self.emptyLabel.text = @"未发现光影";
    self.emptyLabel.hidden = self.localShaders.count > 0;
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
        self.selectButtonItem.enabled = self.filteredLocalShaders.count > 0;
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
    if (self.filteredLocalShaders.count == 0) return; // 没有数据时不允许进入选择模式

    self.isSelectMode = YES;
    [self.selectedShaders removeAllObjects]; // 进入选择模式时清空已选列表
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
    [self.selectedShaders removeAllObjects]; // 退出时清除所有选择
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
    if (self.selectedShaders.count == self.filteredLocalShaders.count) {
        [self deselectAll];
    } else {
        [self selectAll];
    }
}

// 全选：将当前过滤后列表中的所有光影加入已选列表
- (void)selectAll {
    [self.selectedShaders removeAllObjects];
    [self.selectedShaders addObjectsFromArray:self.filteredLocalShaders];
    [self updateNavigationButtons];
    [self reloadVisibleCellsCheckbox];
}

// 取消全选：清空已选列表
- (void)deselectAll {
    [self.selectedShaders removeAllObjects];
    [self updateNavigationButtons];
    [self reloadVisibleCellsCheckbox];
}

// 删除选中的光影（带确认弹窗）
- (void)deleteSelectedShaders {
    if (self.selectedShaders.count == 0) {
        [self showSimpleAlertWithTitle:@"提示" message:@"尚未选择任何光影"];
        return;
    }

    NSString *message = [NSString stringWithFormat:@"确定要删除选中的 %ld 个光影吗？\n此操作无法撤销。", (long)self.selectedShaders.count];
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"批量删除" message:message preferredStyle:UIAlertControllerStyleAlert];

    [alert addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    __weak typeof(self) weakSelf = self;
    [alert addAction:[UIAlertAction actionWithTitle:@"删除" style:UIAlertActionStyleDestructive handler:^(UIAlertAction * _Nonnull action) {
        [weakSelf performDeleteSelectedShaders];
    }]];
    [self presentViewController:alert animated:YES completion:nil];
}

// 执行批量删除
- (void)performDeleteSelectedShaders {
    NSArray<ShaderItem *> *shadersToDelete = [self.selectedShaders copy];
    NSMutableArray<ShaderItem *> *failedShaders = [NSMutableArray array];

    for (ShaderItem *shader in shadersToDelete) {
        NSError *error = nil;
        BOOL success = [[ShaderService sharedService] deleteShader:shader error:&error];
        if (!success || error) {
            NSLog(@"[ShadersManager] 批量删除失败：%@ - %@", shader.displayName, error);
            [failedShaders addObject:shader];
        }
    }

    // 从数据源中移除已成功删除的光影
    for (ShaderItem *shader in shadersToDelete) {
        if ([failedShaders containsObject:shader]) continue; // 跳过删除失败的
        NSUInteger idxInFull = [self.localShaders indexOfObject:shader];
        if (idxInFull != NSNotFound) [self.localShaders removeObjectAtIndex:idxInFull];
        NSUInteger idxInFiltered = [self.filteredLocalShaders indexOfObject:shader];
        if (idxInFiltered != NSNotFound) [self.filteredLocalShaders removeObjectAtIndex:idxInFiltered];
    }

    // 清空已选列表（失败的项目不再标记为选中）
    [self.selectedShaders removeAllObjects];

    if (failedShaders.count > 0) {
        // 部分失败时保留选择模式，提示用户哪些失败
        NSMutableArray<NSString *> *names = [NSMutableArray array];
        for (ShaderItem *s in failedShaders) [names addObject:s.displayName];
        [self showSimpleAlertWithTitle:[NSString stringWithFormat:@"删除完成，%ld 项失败", (long)failedShaders.count]
                               message:[names componentsJoinedByString:@"\n"]];
        [self updateNavigationButtons];
        [self.tableView reloadData];
    } else {
        // 全部删除成功，退出选择模式
        [self exitSelectMode];
    }
}

// 判断指定光影是否处于选中状态
- (BOOL)isShaderSelected:(ShaderItem *)shader {
    return [self.selectedShaders containsObject:shader];
}

// 切换某个光影的选中状态（行点击触发）
- (void)toggleSelectionForShader:(ShaderItem *)shader {
    if ([self.selectedShaders containsObject:shader]) {
        [self.selectedShaders removeObject:shader];
    } else {
        [self.selectedShaders addObject:shader];
    }
    [self updateNavigationButtons];
}

// 更新导航栏标题，显示已选数量
- (void)updateSelectModeTitle {
    if (self.isSelectMode) {
        self.title = [NSString stringWithFormat:@"已选 %ld 个", (long)self.selectedShaders.count];
    }
}

// 更新"全选"按钮的标题（已全选时显示"取消全选"）
- (void)updateSelectAllButtonTitle {
    if (self.selectedShaders.count > 0 && self.selectedShaders.count == self.filteredLocalShaders.count && self.filteredLocalShaders.count > 0) {
        self.navSelectAllButtonItem.title = @"取消全选";
        self.toolbarSelectAllButtonItem.enabled = NO;
        self.toolbarDeselectAllButtonItem.enabled = YES;
    } else if (self.selectedShaders.count == 0) {
        self.navSelectAllButtonItem.title = @"全选";
        self.toolbarSelectAllButtonItem.enabled = YES;
        self.toolbarDeselectAllButtonItem.enabled = NO;
    } else {
        self.navSelectAllButtonItem.title = @"全选";
        self.toolbarSelectAllButtonItem.enabled = YES;
        self.toolbarDeselectAllButtonItem.enabled = YES;
    }
    // 没有任何数据时禁用全选相关按钮
    if (self.filteredLocalShaders.count == 0) {
        self.navSelectAllButtonItem.enabled = NO;
        self.toolbarSelectAllButtonItem.enabled = NO;
        self.toolbarDeselectAllButtonItem.enabled = NO;
    } else {
        self.navSelectAllButtonItem.enabled = YES;
    }
    // 删除按钮：未选中时禁用
    self.toolbarDeleteButtonItem.enabled = self.selectedShaders.count > 0;
}

// 刷新所有可见 Cell 的复选框状态（避免整表 reloadData 引起闪烁）
- (void)reloadVisibleCellsCheckbox {
    for (NSIndexPath *indexPath in [self.tableView indexPathsForVisibleRows]) {
        UITableViewCell *cell = [self.tableView cellForRowAtIndexPath:indexPath];
        if (!cell) continue;
        ShaderItem *shader = self.filteredLocalShaders[indexPath.row];
        [self applyCheckboxToCell:cell selected:[self isShaderSelected:shader]];
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
        // 隐藏 openLinkButton，避免与复选框视觉冲突（光影的 enableSwitch 默认已隐藏）
        if ([cell isKindOfClass:[ShaderTableViewCell class]]) {
            ShaderTableViewCell *shaderCell = (ShaderTableViewCell *)cell;
            shaderCell.openLinkButton.hidden = YES;
        }
    } else {
        // 普通模式：清除复选框，恢复原有控件可见性
        cell.accessoryView = nil;
        cell.selectionStyle = UITableViewCellSelectionStyleNone;
        if ([cell isKindOfClass:[ShaderTableViewCell class]]) {
            ShaderTableViewCell *shaderCell = (ShaderTableViewCell *)cell;
            // openLinkButton 的最终可见性以 configureWithShader 的设置为准
            shaderCell.openLinkButton.hidden = NO;
        }
    }
}

#pragma mark - Import Shader

- (void)importShaderTapped {
    NSError *dirError = nil;
    NSString *shadersDir = [[ShaderService sharedService] ensureShadersFolderForProfile:nil error:&dirError];
    if (!shadersDir) {
        [self showSimpleAlertWithTitle:@"无法导入" message:dirError.localizedDescription ?: @"无法确定 shaderpacks 目录"];
        return;
    }

    // 光影包通常是 zip 格式
    UIDocumentPickerViewController *picker = [[UIDocumentPickerViewController alloc] initWithDocumentTypes:@[@"public.zip-archive", @"public.item"] inMode:UIDocumentPickerModeImport];
    picker.allowsMultipleSelection = YES;
    picker.delegate = self;
    picker.title = @"选择光影包文件";
    [self presentViewController:picker animated:YES completion:nil];
}

- (void)documentPicker:(UIDocumentPickerViewController *)controller didPickDocumentsAtURLs:(NSArray<NSURL *> *)urls {
    if (urls.count == 0) return;

    NSError *dirError = nil;
    NSString *shadersDir = [[ShaderService sharedService] ensureShadersFolderForProfile:nil error:&dirError];
    if (!shadersDir) {
        [self showSimpleAlertWithTitle:@"导入失败" message:dirError.localizedDescription ?: @"无法确定 shaderpacks 目录"];
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
        [self showSimpleAlertWithTitle:[NSString stringWithFormat:@"导入完成（%ld 成功，%ld 失败）", (long)successCount, (long)failedFiles.count]
                               message:[failedFiles componentsJoinedByString:@"\n"]];
    } else {
        NSLog(@"[ShadersManager] 成功导入 %ld 个光影包", (long)successCount);
    }
}



#pragma mark - Check for Updates

- (void)checkForUpdates {
    // 将本地 ShaderItem 列表转换为 ModItem 列表，适配 ModUpdateViewController
    NSArray<ModItem *> *mods = [self convertShadersToMods:self.localShaders];
    if (mods.count == 0) {
        [self showSimpleAlertWithTitle:@"提示" message:@"当前没有本地光影，无法检查更新。"];
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
    // 刷新前若处于选择模式，先退出（数据即将更新，避免选择状态与新数据不一致）
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
        self.emptyLabel.text = @"未找到本地光影";
    }
    // 更新导航按钮状态（"选择"按钮的可用性、"全选"按钮标题等）
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

    // 根据选择模式应用复选框显示
    if (self.isSelectMode) {
        [self applyCheckboxToCell:cell selected:[self isShaderSelected:shader]];
    } else {
        [self applyCheckboxToCell:cell selected:NO];
    }

    // 适配自定义启动器背景：为 cell 注入毛玻璃/半透明效果
    // ShaderTableViewCell 自身 contentView 背景为 clearColor，由 BackgroundManager 统一注入
    [[BackgroundManager sharedManager] applyEffectToCell:cell];

    return cell;
}

- (UISwipeActionsConfiguration *)tableView:(UITableView *)tableView trailingSwipeActionsConfigurationForRowAtIndexPath:(NSIndexPath *)indexPath {
    // 选择模式下禁用滑动删除，避免误操作
    if (self.isSelectMode) return nil;

    UIContextualAction *deleteAction = [UIContextualAction contextualActionWithStyle:UIContextualActionStyleDestructive title:@"删除" handler:^(UIContextualAction * _Nonnull action, __kindof UIView * _Nonnull sourceView, void (^ _Nonnull completionHandler)(BOOL)) {

        ShaderItem *shaderToDelete = self.filteredLocalShaders[indexPath.row];

        UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"确认删除" message:[NSString stringWithFormat:@"确定要删除 %@ 吗？\n此操作无法撤销。", shaderToDelete.displayName] preferredStyle:UIAlertControllerStyleAlert];

        [alert addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:^(UIAlertAction * _Nonnull action) {
            completionHandler(NO);
        }]];

        [alert addAction:[UIAlertAction actionWithTitle:@"删除" style:UIAlertActionStyleDestructive handler:^(UIAlertAction * _Nonnull action) {
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
    // 在线下载入口已移除（请使用下载界面），此方法保留以实现协议
}

#pragma mark - ShaderVersionViewControllerDelegate

- (void)shaderVersionViewController:(ShaderVersionViewController *)viewController didSelectVersion:(ShaderVersion *)version {
    ShaderItem *itemToDownload = viewController.shaderItem;

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

- (void)startDownloadForItem:(ShaderItem *)item {
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
        [self showSimpleAlertWithTitle:@"下载失败" message:error.localizedDescription];
    } else {
        UIAlertController *successAlert = [UIAlertController alertControllerWithTitle:@"下载成功"
                                                                              message:[NSString stringWithFormat:@"%@ 已成功安装。", item.displayName]
                                                                       preferredStyle:UIAlertControllerStyleAlert];
        [successAlert addAction:[UIAlertAction actionWithTitle:@"好" style:UIAlertActionStyleDefault handler:^(UIAlertAction * _Nonnull action) {
            // After user acknowledges, refresh local shaders list
            [self refreshLocalShadersList];
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
        // 选择模式下：点击行切换该光影的选中状态
        ShaderItem *shader = self.filteredLocalShaders[indexPath.row];
        [self toggleSelectionForShader:shader];
        // 直接更新对应 Cell 的复选框，避免整表刷新造成闪烁
        UITableViewCell *cell = [tableView cellForRowAtIndexPath:indexPath];
        if (cell) {
            [self applyCheckboxToCell:cell selected:[self isShaderSelected:shader]];
        }
        // 取消选中高亮
        [tableView deselectRowAtIndexPath:indexPath animated:YES];
    } else {
        // 普通模式：仅取消高亮，无具体动作
        [tableView deselectRowAtIndexPath:indexPath animated:YES];
    }
}

// 禁用光影切换功能 - 光影管理只用于查看和删除
- (void)shaderCellDidTapToggle:(UITableViewCell *)cell {
    // 功能已禁用
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
        UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"链接不可用" message:@"该光影没有可用的在线链接。" preferredStyle:UIAlertControllerStyleAlert];
        [alert addAction:[UIAlertAction actionWithTitle:@"好" style:UIAlertActionStyleDefault handler:nil]];
        [self presentViewController:alert animated:YES completion:nil];
    }
}

@end
