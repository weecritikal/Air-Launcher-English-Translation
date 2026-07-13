//
//  MultiplayerViewController.m
//  Amethyst
//
//  MC 联机界面实现（FCL 风格重制版）
//
//  本文件参照 FCL (FoldCraftLauncher) 的联机流程重新设计：
//
//  模式 1：启动器模式（MultiplayerVCModeLauncher）
//    用户在启动游戏前在此界面启用联机、设置预设 Network ID、管理房间、配置直连。
//    Section 0「联机设置」：UISwitch 启用联机开关 + 预设 Network ID 显示/编辑
//    Section 1「我的房间」：保存的房间列表（每行显示 房间名 + Network ID + 状态 + 连接/断开按钮）
//    Section 2「直连」：IP+端口输入 + 加入游戏按钮（写入 PLProfiles）
//
//  模式 2：游戏内模式（MultiplayerVCModeInGame）
//    用户启动游戏后通过悬浮球菜单进入，选择当房主或房客。
//    Section 0「选择角色」：当房主按钮 + 当房客按钮（大卡片样式）
//    Section 1「联机状态」：当前联机状态 + Network ID + 本地 IP
//
//  房主流程：
//    1. 检查 ZeroTier 框架可用性 + 预设 Network ID 是否已设置
//    2. 连接到预设 Network ID 房间（调用 connectToRoom:completion:）
//    3. 连接成功后监听 LanPortDetectorDidDetectPortNotification
//    4. 自动检测 LAN 端口并生成分享代码（调用 generateShareCodeForRoom:）
//    5. 显示分享代码（可复制、可分享）
//
//  房客流程：
//    1. 弹出输入框（UIAlertController with textField）
//    2. 解析分享代码（调用 parseShareCode:）
//    3. 连接到房间（调用 connectToRoom:completion:）
//    4. 连接成功后提示并显示服务器地址（房主 IP:端口）
//

#import "MultiplayerViewController.h"
#import "MultiplayerManager.h"
#import "BackgroundManager.h"
#import "LauncherPreferences.h"
#import "PLProfiles.h"
#import "LanPortDetector.h"
#import "ZeroTierBridge.h"
#import "utils.h"

/// 本地化辅助函数
/// 优先通过 localize() 查找本地化文本；若未找到（返回值等于 key），则使用传入的 fallback。
/// 这样既满足"所有新增文本需要本地化"的要求，又避免 key 未注册时用户看到原始 key。
NS_INLINE NSString *MPLocalized(NSString *key, NSString *fallback) {
    NSString *value = localize(key, nil);
    return [value isEqualToString:key] ? (fallback ?: key) : value;
}

@interface MultiplayerViewController () <UITableViewDataSource, UITableViewDelegate, UITextFieldDelegate, MultiplayerManagerDelegate>

/// 当前界面模式（启动器 / 游戏内）
@property (nonatomic, assign) MultiplayerVCMode mode;

/// 主表格视图（InsetGrouped 风格）
@property (nonatomic, strong) UITableView *tableView;

/// 当前已保存的房间列表
@property (nonatomic, strong) NSArray<MultiplayerRoom *> *rooms;

#pragma mark - 启动器模式专用控件

/// Section 0 Row 0 的"启用联机"开关
@property (nonatomic, strong) UISwitch *enableSwitch;

/// Section 2 Row 0 的 IP 地址输入框（强引用，确保跨 cell 复用时数据不丢失）
@property (nonatomic, strong) UITextField *directIPField;

/// Section 2 Row 0 的端口输入框（强引用）
@property (nonatomic, strong) UITextField *directPortField;

#pragma mark - 游戏内模式专用状态

/// 房主流程是否激活（已点击"当房主"且正在等待/已连接）
@property (nonatomic, assign) BOOL isHostFlowActive;

/// 房客流程是否激活（已点击"当房客"且正在等待/已连接）
@property (nonatomic, assign) BOOL isGuestFlowActive;

/// 房主流程中最新生成的分享代码（用于显示与复制）
@property (nonatomic, copy, nullable) NSString *lastShareCode;

/// 房客流程中最新解析出的服务器地址（hostIP:hostPort，用于显示给用户）
@property (nonatomic, copy, nullable) NSString *lastServerAddress;

/// 房主流程中正在使用的房间对象（用于生成分享代码）
@property (nonatomic, strong, nullable) MultiplayerRoom *hostRoom;

/// 房客流程中正在连接的房间对象（用于显示连接状态）
@property (nonatomic, strong, nullable) MultiplayerRoom *guestRoom;

@end

@implementation MultiplayerViewController

#pragma mark - Init

/// 通过模式初始化联机界面
/// @param mode 界面模式（启动器 / 游戏内）
- (instancetype)initWithMode:(MultiplayerVCMode)mode {
    self = [super initWithNibName:nil bundle:nil];
    if (self) {
        _mode = mode;
    }
    return self;
}

/// 兜底初始化：未指定模式时默认使用启动器模式
- (instancetype)init {
    return [self initWithMode:MultiplayerVCModeLauncher];
}

#pragma mark - Lifecycle

- (void)viewDidLoad {
    [super viewDidLoad];

    // 根据模式设置标题
    if (self.mode == MultiplayerVCModeInGame) {
        self.title = MPLocalized(@"mp.title.ingame", @"联机");
    } else {
        self.title = MPLocalized(@"mp.title", @"联机");
    }

    // 适配自定义启动器背景：透明化当前 VC，让全局背景图/毛玻璃透出
    [[BackgroundManager sharedManager] makeViewControllerTransparent:self];

    // 初始化数据：从 MultiplayerManager 读取已保存的房间列表
    self.rooms = [[MultiplayerManager sharedManager] savedRooms] ?: @[];

    // 构建 UI
    [self setupUI];

    // 注册为 MultiplayerManager 代理，接收节点/网络状态变化的实时回调
    [MultiplayerManager sharedManager].delegate = self;

    // 监听背景效果变化通知，背景切换时重新应用透明效果并刷新表格
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(backgroundEffectChanged)
                                                 name:@"BackgroundUIEffectChanged"
                                               object:nil];

    // 游戏内模式：监听 LAN 端口检测通知（房主流程依赖）
    if (self.mode == MultiplayerVCModeInGame) {
        [[NSNotificationCenter defaultCenter] addObserver:self
                                                 selector:@selector(lanPortDidDetect:)
                                                     name:LanPortDetectorDidDetectPortNotification
                                                   object:nil];
    }
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];

    // 进入界面时重新应用背景效果（背景可能在其他界面被修改）
    [[BackgroundManager sharedManager] makeViewControllerTransparent:self];
    self.tableView.backgroundColor = [UIColor clearColor];
    self.tableView.backgroundView = nil;

    // 重新应用导航栏毛玻璃效果
    [[BackgroundManager sharedManager] applyEffectToNavigationBar:self.navigationController.navigationBar];

    // 刷新房间列表（可能在其他界面修改过）
    [self refreshRooms];

    // 启动器模式：根据节点状态同步开关初始值
    if (self.mode == MultiplayerVCModeLauncher) {
        BOOL started = [[MultiplayerManager sharedManager] isNodeStarted];
        [self.enableSwitch setOn:started animated:NO];
    }
}

- (void)backgroundEffectChanged {
    // 背景效果改变时重新透明化当前 VC 并刷新表格，让所有 cell 重新适配文字颜色
    dispatch_async(dispatch_get_main_queue(), ^{
        [[BackgroundManager sharedManager] makeViewControllerTransparent:self];
        self.tableView.backgroundColor = [UIColor clearColor];
        self.tableView.backgroundView = nil;
        // 重新应用导航栏毛玻璃效果
        [[BackgroundManager sharedManager] applyEffectToNavigationBar:self.navigationController.navigationBar];
        // 刷新表格，让所有 cell 重新读取背景状态并适配颜色
        [self.tableView reloadData];
    });
}

- (void)dealloc {
    // 移除通知观察者，避免 dealloc 后收到通知导致崩溃
    [[NSNotificationCenter defaultCenter] removeObserver:self];
    // 清除代理引用，避免悬空指针
    if ([MultiplayerManager sharedManager].delegate == self) {
        [MultiplayerManager sharedManager].delegate = nil;
    }
}

#pragma mark - UI Setup

- (void)setupUI {
    // 使用 InsetGrouped 风格，卡片式布局，与系统设置界面一致
    self.tableView = [[UITableView alloc] initWithFrame:CGRectZero style:UITableViewStyleInsetGrouped];
    self.tableView.translatesAutoresizingMaskIntoConstraints = NO;
    self.tableView.dataSource = self;
    self.tableView.delegate = self;
    self.tableView.backgroundColor = [UIColor clearColor];
    self.tableView.backgroundView = nil;
    // 启用自动尺寸计算
    self.tableView.rowHeight = UITableViewAutomaticDimension;
    self.tableView.estimatedRowHeight = 56;
    // 注册复用的 cell 类型
    [self.tableView registerClass:[UITableViewCell class] forCellReuseIdentifier:@"DefaultCell"];
    [self.tableView registerClass:[UITableViewCell class] forCellReuseIdentifier:@"ButtonCell"];
    [self.tableView registerClass:[UITableViewCell class] forCellReuseIdentifier:@"EmptyCell"];
    [self.tableView registerClass:[UITableViewCell class] forCellReuseIdentifier:@"SwitchCell"];
    [self.tableView registerClass:[UITableViewCell class] forCellReuseIdentifier:@"NetworkIdCell"];
    [self.tableView registerClass:[UITableViewCell class] forCellReuseIdentifier:@"DirectInputCell"];
    [self.tableView registerClass:[UITableViewCell class] forCellReuseIdentifier:@"RoleCardCell"];
    [self.tableView registerClass:[UITableViewCell class] forCellReuseIdentifier:@"StatusCell"];
    [self.view addSubview:self.tableView];

    [NSLayoutConstraint activateConstraints:@[
        [self.tableView.topAnchor constraintEqualToAnchor:self.view.topAnchor],
        [self.tableView.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor],
        [self.tableView.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [self.tableView.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
    ]];

    // 导航栏左上角：关闭按钮（xmark），两种模式都需要
    UIBarButtonItem *closeButton = [[UIBarButtonItem alloc] initWithImage:[UIImage systemImageNamed:@"xmark"]
                                                                     style:UIBarButtonItemStylePlain
                                                                    target:self
                                                                    action:@selector(closeTapped)];
    closeButton.accessibilityLabel = MPLocalized(@"mp.close", @"关闭");
    self.navigationItem.leftBarButtonItem = closeButton;

    // 注意：启动器模式右上角不需要按钮（Network ID 通过 Section 0 设置）
    // 注意：游戏内模式右上角也不需要按钮（房主/房客通过 Section 0 选择）

    // 应用导航栏毛玻璃效果
    [[BackgroundManager sharedManager] applyEffectToNavigationBar:self.navigationController.navigationBar];
}

#pragma mark - Navigation Actions

/// 关闭按钮回调：兼容 push 和 present 两种容器
- (void)closeTapped {
    [self.view endEditing:YES];
    if (self.navigationController && self.navigationController.viewControllers.firstObject != self) {
        [self.navigationController popViewControllerAnimated:YES];
    } else {
        [self dismissViewControllerAnimated:YES completion:nil];
    }
}

#pragma mark - 启动器模式：启用联机开关

/// "启用联机"开关状态变化回调
///
/// 对标 FCL 启动器界面顶部的联机总开关：
///   - 打开：调用 ensureNodeStartedWithCompletion: 启动 ZeroTier 节点
///   - 关闭：调用 disconnectCurrentRoom 停止所有联机活动（节点保持运行，可再次打开）
- (void)enableSwitchChanged:(UISwitch *)sender {
    if (sender.on) {
        // 检查 ZeroTier 框架可用性
        if (![[MultiplayerManager sharedManager] isFrameworkAvailable]) {
            [sender setOn:NO animated:YES];
            [self showSimpleAlertWithTitle:MPLocalized(@"mp.core.unavailable_title", @"联机核心不可用")
                                    message:MPLocalized(@"mp.core.unavailable_msg", @"ZeroTier 联机核心未加载，无法启用联机。请使用包含真实 zt.framework 的构建版本。")];
            return;
        }

        // 启动 ZeroTier 节点
        __weak typeof(self) weakSelf = self;
        [[MultiplayerManager sharedManager] ensureNodeStartedWithCompletion:^(BOOL success, NSError *error) {
            __strong typeof(weakSelf) strongSelf = weakSelf;
            if (!strongSelf) return;

            if (!success) {
                // 启动失败：回退开关状态
                [strongSelf.enableSwitch setOn:NO animated:YES];
                [strongSelf showSimpleAlertWithTitle:MPLocalized(@"mp.node.start_failed_title", @"启动失败")
                                              message:error.localizedDescription ?: MPLocalized(@"mp.node.start_failed_msg", @"ZeroTier 节点启动失败，请重试。")];
            } else {
                // 启动成功：刷新表格以更新开关行的辅助文字
                [strongSelf.tableView reloadData];
            }
        }];
    } else {
        // 关闭联机：断开当前房间（如有）
        if ([[MultiplayerManager sharedManager] currentRoom]) {
            [[MultiplayerManager sharedManager] disconnectCurrentRoom];
        }
        [self refreshRooms];
    }
}

#pragma mark - 启动器模式：预设 Network ID 编辑

/// 点击 Network ID 行：弹出 UIAlertController 让用户输入预设 Network ID
///
/// 对标 FCL：房主首次设置一次 Network ID（在 my.zerotier.com 创建后填入），
/// 之后每次开房自动使用，分享代码中自动包含此 Network ID。
- (void)networkIdCellTapped {
    [self.view endEditing:YES];

    // 检查 ZeroTier 框架可用性
    if (![[MultiplayerManager sharedManager] isFrameworkAvailable]) {
        [self showSimpleAlertWithTitle:MPLocalized(@"mp.core.unavailable_title", @"联机核心不可用")
                                message:MPLocalized(@"mp.core.unavailable_msg", @"ZeroTier 联机核心未加载，无法设置 Network ID。")];
        return;
    }

    NSString *current = [[MultiplayerManager sharedManager] presetNetworkId] ?: @"";

    UIAlertController *alert = [UIAlertController alertControllerWithTitle:MPLocalized(@"mp.network_id.title", @"设置 Network ID")
                                                                   message:MPLocalized(@"mp.network_id.message", @"在 my.zerotier.com 创建网络后填入 16 位 Network ID，开房时自动使用")
                                                            preferredStyle:UIAlertControllerStyleAlert];

    [alert addTextFieldWithConfigurationHandler:^(UITextField *textField) {
        textField.text = current;
        textField.placeholder = MPLocalized(@"mp.network_id.placeholder", @"16 位十六进制 Network ID");
        textField.autocapitalizationType = UITextAutocapitalizationTypeNone;
        textField.autocorrectionType = UITextAutocorrectionTypeNo;
        textField.keyboardType = UIKeyboardTypeASCIICapable;
        textField.clearButtonMode = UITextFieldViewModeWhileEditing;
    }];

    [alert addAction:[UIAlertAction actionWithTitle:MPLocalized(@"common.cancel", @"取消")
                                              style:UIAlertActionStyleCancel
                                            handler:nil]];

    __weak typeof(self) weakSelf = self;
    [alert addAction:[UIAlertAction actionWithTitle:MPLocalized(@"common.save", @"保存")
                                              style:UIAlertActionStyleDefault
                                            handler:^(UIAlertAction *action) {
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf) return;

        UITextField *field = alert.textFields.firstObject;
        NSString *value = [field.text stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];

        if (value.length == 0) {
            // 空字符串：清除预设
            [[MultiplayerManager sharedManager] setPresetNetworkId:nil];
            [strongSelf.tableView reloadData];
            return;
        }

        // 校验格式
        if (![[MultiplayerManager sharedManager] isValidNetworkId:value]) {
            [strongSelf showSimpleAlertWithTitle:MPLocalized(@"mp.network_id.invalid_title", @"格式不正确")
                                          message:MPLocalized(@"mp.network_id.invalid_msg", @"Network ID 应为 16 位十六进制字符串")];
            return;
        }

        [[MultiplayerManager sharedManager] setPresetNetworkId:value];
        [strongSelf.tableView reloadData];
    }]];

    [self presentViewController:alert animated:YES completion:nil];
}

#pragma mark - 房间连接

/// 连接到指定房间
///
/// 内部调用 MultiplayerManager 的 connectToRoom:completion:，
/// 并在主线程更新房间状态和 UI。连接成功后回调 completion。
- (void)connectToRoom:(MultiplayerRoom *)room completion:(void (^)(BOOL success, NSError *error))completion {
    // 设置状态为连接中
    room.status = MultiplayerRoomStatusConnecting;
    [[MultiplayerManager sharedManager] updateRoom:room];
    [self refreshRooms];

    __weak typeof(self) weakSelf = self;
    [[MultiplayerManager sharedManager] connectToRoom:room completion:^(BOOL success, NSError *error) {
        dispatch_async(dispatch_get_main_queue(), ^{
            __strong typeof(weakSelf) strongSelf = weakSelf;
            if (!strongSelf) return;

            // 根据连接结果更新房间状态
            if (success) {
                room.status = MultiplayerRoomStatusConnected;
                room.lastConnectedAt = [NSDate date];
            } else {
                room.status = MultiplayerRoomStatusError;
            }
            [[MultiplayerManager sharedManager] updateRoom:room];
            [strongSelf refreshRooms];

            if (completion) {
                completion(success, error);
            }
        });
    }];
}

/// 断开当前房间连接
- (void)disconnectRoom:(MultiplayerRoom *)room {
    [[MultiplayerManager sharedManager] disconnectCurrentRoom];
    room.status = MultiplayerRoomStatusDisconnected;
    [[MultiplayerManager sharedManager] updateRoom:room];
    [self refreshRooms];
}

#pragma mark - 房间行按钮回调

/// 房间行的"连接/断开"按钮回调
///
/// 通过 button.tag 找到对应的房间索引
- (void)roomButtonTapped:(UIButton *)button {
    NSInteger row = button.tag;
    if (row < 0 || row >= (NSInteger)self.rooms.count) {
        return;
    }

    MultiplayerRoom *room = self.rooms[row];

    // 防止连接中重复点击
    if (room.status == MultiplayerRoomStatusConnecting) {
        return;
    }

    if (room.status == MultiplayerRoomStatusConnected) {
        // 已连接则断开
        [self disconnectRoom:room];
    } else {
        // 未连接则连接
        [self connectToRoom:room completion:^(BOOL success, NSError *error) {
            if (!success) {
                [self showSimpleAlertWithTitle:MPLocalized(@"mp.connect.failed", @"连接失败")
                                        message:error.localizedDescription ?: MPLocalized(@"mp.connect.failed_msg", @"无法连接到房间，请检查 Network ID 是否正确以及网络是否畅通。")];
            }
        }];
    }
}

#pragma mark - 房间详情 ActionSheet

/// 显示房间详情 ActionSheet
///
/// 提供以下操作：
///   - 连接 / 断开（根据当前状态显示）
///   - 分享房间（生成分享文本，调用系统分享面板）
///   - 删除房间（二次确认后删除）
- (void)showRoomActionsForRoom:(MultiplayerRoom *)room {
    [self.view endEditing:YES];

    NSString *title = room.name.length ? room.name : MPLocalized(@"mp.room.unnamed", @"未命名房间");
    NSString *message = [NSString stringWithFormat:@"%@: %@",
                         MPLocalized(@"mp.room.network_id", @"Network ID"),
                         room.networkId ?: @"-"];

    UIAlertController *sheet = [UIAlertController alertControllerWithTitle:title
                                                                   message:message
                                                            preferredStyle:UIAlertControllerStyleActionSheet];

    // 连接 / 断开按钮（根据当前状态切换标题）
    NSString *connectTitle = (room.status == MultiplayerRoomStatusConnected)
        ? MPLocalized(@"mp.room.action.disconnect", @"断开连接")
        : MPLocalized(@"mp.room.action.connect", @"连接房间");

    __weak typeof(self) weakSelf = self;
    [sheet addAction:[UIAlertAction actionWithTitle:connectTitle style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf) return;

        if (room.status == MultiplayerRoomStatusConnected) {
            [strongSelf disconnectRoom:room];
        } else {
            [strongSelf connectToRoom:room completion:^(BOOL success, NSError *error) {
                if (!success) {
                    [strongSelf showSimpleAlertWithTitle:MPLocalized(@"mp.connect.failed", @"连接失败")
                                                  message:error.localizedDescription ?: MPLocalized(@"mp.connect.failed_msg", @"无法连接到房间，请检查 Network ID 是否正确以及网络是否畅通。")];
                }
            }];
        }
    }]];

    // 分享房间按钮（使用 shareTextForRoom: 生成可读分享文本）
    [sheet addAction:[UIAlertAction actionWithTitle:MPLocalized(@"mp.room.action.share", @"分享房间")
                                              style:UIAlertActionStyleDefault
                                            handler:^(UIAlertAction *action) {
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf) return;

        NSString *shareText = [[MultiplayerManager sharedManager] shareTextForRoom:room];
        UIActivityViewController *activityVC = [[UIActivityViewController alloc] initWithActivityItems:@[shareText] applicationActivities:nil];

        // iPad 适配：popover 指向屏幕中央
        if (activityVC.popoverPresentationController) {
            activityVC.popoverPresentationController.sourceView = strongSelf.view;
            activityVC.popoverPresentationController.sourceRect = CGRectMake(strongSelf.view.bounds.size.width / 2.0,
                                                                              strongSelf.view.bounds.size.height / 2.0,
                                                                              1, 1);
        }
        [strongSelf presentViewController:activityVC animated:YES completion:nil];
    }]];

    // 删除房间按钮（destructive 红色）
    [sheet addAction:[UIAlertAction actionWithTitle:MPLocalized(@"mp.room.action.delete", @"删除房间")
                                              style:UIAlertActionStyleDestructive
                                            handler:^(UIAlertAction *action) {
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf) return;

        // 二次确认对话框
        UIAlertController *confirm = [UIAlertController alertControllerWithTitle:MPLocalized(@"mp.room.delete.confirm_title", @"确认删除")
                                                                         message:[NSString stringWithFormat:@"%@「%@」？\n%@",
                                                                                  MPLocalized(@"mp.room.delete.confirm_prefix", @"确定要删除房间"),
                                                                                  room.name,
                                                                                  MPLocalized(@"mp.room.delete.confirm_warning", @"此操作无法撤销。")]
                                                                  preferredStyle:UIAlertControllerStyleAlert];
        [confirm addAction:[UIAlertAction actionWithTitle:MPLocalized(@"common.cancel", @"取消") style:UIAlertActionStyleCancel handler:nil]];
        [confirm addAction:[UIAlertAction actionWithTitle:MPLocalized(@"mp.room.delete.button", @"删除") style:UIAlertActionStyleDestructive handler:^(UIAlertAction *action) {
            __strong typeof(weakSelf) strongSelf = weakSelf;
            if (!strongSelf) return;

            // 如果该房间已连接，先断开连接
            if (room.status == MultiplayerRoomStatusConnected) {
                [[MultiplayerManager sharedManager] disconnectCurrentRoom];
            }
            [[MultiplayerManager sharedManager] removeRoom:room.roomId];
            [strongSelf refreshRooms];
        }]];
        [strongSelf presentViewController:confirm animated:YES completion:nil];
    }]];

    // 取消按钮
    [sheet addAction:[UIAlertAction actionWithTitle:MPLocalized(@"common.cancel", @"取消") style:UIAlertActionStyleCancel handler:nil]];

    // iPad 适配：popover 指向屏幕中央
    if (sheet.popoverPresentationController) {
        sheet.popoverPresentationController.sourceView = self.view;
        sheet.popoverPresentationController.sourceRect = CGRectMake(self.view.bounds.size.width / 2.0,
                                                                    self.view.bounds.size.height / 2.0,
                                                                    1, 1);
    }

    [self presentViewController:sheet animated:YES completion:nil];
}

#pragma mark - 启动器模式：直连

/// 点击"加入游戏"按钮：将 IP:端口 写入当前 profile，启动游戏后自动加入
- (void)joinDirectConnect {
    [self.view endEditing:YES];

    NSString *ip = [self.directIPField.text stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    NSString *port = [self.directPortField.text stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];

    // 校验：IP 非空
    if (ip.length == 0) {
        [self showSimpleAlertWithTitle:MPLocalized(@"mp.direct.error_title", @"提示")
                                message:MPLocalized(@"mp.direct.error.ip_empty", @"请输入服务器 IP 地址")];
        return;
    }

    // 端口默认值
    if (port.length == 0) {
        port = @"25565";
    }

    // 校验：IP 格式
    if (![[MultiplayerManager sharedManager] isValidIPAddress:ip]) {
        [self showSimpleAlertWithTitle:MPLocalized(@"mp.direct.error_title", @"提示")
                                message:MPLocalized(@"mp.direct.error.ip_invalid", @"IP 地址格式不正确，请检查输入")];
        return;
    }

    // 拼接服务器地址 "IP:端口"
    NSString *serverAddress = [NSString stringWithFormat:@"%@:%@", ip, port];

    // 将服务器地址写入当前 profile
    NSString *profileName = [PLProfiles current].selectedProfileName;
    if (!profileName || profileName.length == 0) {
        [self showSimpleAlertWithTitle:MPLocalized(@"mp.direct.error_title", @"提示")
                                message:MPLocalized(@"mp.direct.error.no_profile", @"未找到当前 profile，请先选择一个游戏配置")];
        return;
    }
    [[PLProfiles current] setServerIp:serverAddress forProfile:profileName];

    // 显示成功提示
    [self showSimpleAlertWithTitle:MPLocalized(@"mp.direct.success_title", @"已添加服务器")
                           message:[NSString stringWithFormat:@"%@ %@",
                                    MPLocalized(@"mp.direct.success_msg_prefix", @"已添加服务器"),
                                    serverAddress]];
}

#pragma mark - 游戏内模式：房主流程

/// 点击"当房主"按钮：进入房主流程
///
/// 对标 FCL 房主流程：
///   1. 检查 ZeroTier 框架可用性
///   2. 检查预设 Network ID 是否已设置（未设置则提示去启动器设置）
///   3. 自动连接到预设 Network ID 的房间
///   4. 连接成功后监听 LanPortDetectorDidDetectPortNotification
///   5. 自动检测 LAN 端口
///   6. 生成分享代码（generateShareCodeForRoom:）
///   7. 显示分享代码（可复制、可分享）
- (void)hostButtonTapped {
    [self.view endEditing:YES];

    // 检查 1：ZeroTier 框架可用性
    if (![[MultiplayerManager sharedManager] isFrameworkAvailable]) {
        [self showSimpleAlertWithTitle:MPLocalized(@"mp.core.unavailable_title", @"联机核心不可用")
                                message:MPLocalized(@"mp.core.unavailable_msg", @"ZeroTier 联机核心未加载，无法作为房主开房。请使用包含真实 zt.framework 的构建版本。")];
        return;
    }

    // 检查 2：预设 Network ID 是否已设置
    NSString *presetNetId = [[MultiplayerManager sharedManager] presetNetworkId];
    if (!presetNetId.length) {
        // 未设置：提示用户去启动器设置
        UIAlertController *alert = [UIAlertController alertControllerWithTitle:MPLocalized(@"mp.host.no_network_id_title", @"未设置 Network ID")
                                                                       message:MPLocalized(@"mp.host.no_network_id_msg", @"房主需要先设置预设 ZeroTier Network ID。请在启动器联机界面中设置后再来。")
                                                                preferredStyle:UIAlertControllerStyleAlert];
        [alert addAction:[UIAlertAction actionWithTitle:MPLocalized(@"common.ok", @"好") style:UIAlertActionStyleDefault handler:nil]];
        [self presentViewController:alert animated:YES completion:nil];
        return;
    }

    // 校验 Network ID 格式
    if (![[MultiplayerManager sharedManager] isValidNetworkId:presetNetId]) {
        [self showSimpleAlertWithTitle:MPLocalized(@"mp.network_id.invalid_title", @"Network ID 格式不正确")
                                message:MPLocalized(@"mp.network_id.invalid_msg", @"请在启动器联机界面设置正确的 16 位十六进制 Network ID")];
        return;
    }

    // 标记房主流程激活
    self.isHostFlowActive = YES;
    self.lastShareCode = nil;
    self.lastServerAddress = nil;

    // 构建/复用房主房间对象
    MultiplayerRoom *room = self.hostRoom;
    if (!room || ![room.networkId isEqualToString:presetNetId]) {
        room = [[MultiplayerRoom alloc] init];
        room.roomId = [[MultiplayerManager sharedManager] generateRoomId];
        room.name = MPLocalized(@"mp.host.default_room_name", @"我的联机房间");
        room.networkId = presetNetId;
        room.hostIP = @"";
        room.hostPort = @"25565";
        room.roomDescription = @"";
        room.ownerName = @"";
        room.status = MultiplayerRoomStatusDisconnected;
        room.createdAt = [NSDate date];
        self.hostRoom = room;
    }

    // 如果当前已连接到其他房间，先断开
    MultiplayerRoom *currentRoom = [[MultiplayerManager sharedManager] currentRoom];
    if (currentRoom && ![currentRoom.networkId isEqualToString:presetNetId]) {
        [[MultiplayerManager sharedManager] disconnectCurrentRoom];
    }

    // 显示"正在连接"提示
    [self showSimpleAlertWithTitle:MPLocalized(@"mp.host.connecting_title", @"正在开启联机")
                           message:MPLocalized(@"mp.host.connecting_msg", @"正在连接到 ZeroTier 网络，请稍候...")];

    // 启动 LAN 端口检测器（房主在 MC 中开放局域网后会被自动检测到）
    [[LanPortDetector sharedDetector] startDetecting];

    // 连接到预设房间
    __weak typeof(self) weakSelf = self;
    [self connectToRoom:room completion:^(BOOL success, NSError *error) {
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf) return;

        if (success) {
            // 连接成功：显示房主提示
            [strongSelf showHostConnectedAlert];
        } else {
            // 连接失败
            strongSelf.isHostFlowActive = NO;
            [strongSelf showSimpleAlertWithTitle:MPLocalized(@"mp.connect.failed", @"连接失败")
                                          message:error.localizedDescription ?: MPLocalized(@"mp.connect.failed_msg", @"无法连接到 ZeroTier 网络，请检查 Network ID 是否正确以及网络是否畅通。")];
        }
        [strongSelf.tableView reloadData];
    }];

    [self.tableView reloadData];
}

/// 显示房主连接成功后的提示
///
/// 对标 FCL 房主开房成功后的引导：
///   - "请在 MC 中创建世界并开放局域网"
///   - "系统会自动检测 LAN 端口并生成分享代码"
- (void)showHostConnectedAlert {
    NSString *localIP = [[MultiplayerManager sharedManager] currentLocalIP] ?: @"-";
    NSString *message = [NSString stringWithFormat:@"%@\n\n%@\n%@\n\n%@: %@",
                         MPLocalized(@"mp.host.connected_msg", @"已连接到联机网络，等待检测 LAN 端口..."),
                         MPLocalized(@"mp.host.tip.create_world", @"请在 MC 中创建世界并开放局域网"),
                         MPLocalized(@"mp.host.tip.auto_detect", @"系统会自动检测 LAN 端口并生成分享代码"),
                         MPLocalized(@"mp.host.local_ip", @"本机 IP"),
                         localIP];
    [self showSimpleAlertWithTitle:MPLocalized(@"mp.host.connected_title", @"联机已开启")
                           message:message];
}

#pragma mark - 游戏内模式：LAN 端口检测回调

/// LanPortDetector 检测到端口后的回调
///
/// 房主流程核心：MC 开放局域网后，LanPortDetector 自动检测到端口号，
/// 触发本回调。本方法负责：
///   1. 将检测到的端口写入房主房间对象
///   2. 生成分享代码（generateShareCodeForRoom:）
///   3. 刷新 UI 显示分享代码
- (void)lanPortDidDetect:(NSNotification *)notification {
    // 仅在房主流程激活时处理
    if (!self.isHostFlowActive) {
        return;
    }

    NSString *port = notification.userInfo[@"port"];
    if (!port.length) {
        return;
    }

    MultiplayerRoom *room = self.hostRoom;
    if (!room) {
        return;
    }

    // 更新房间的端口和本机 IP
    room.hostPort = port;
    NSString *localIP = [[MultiplayerManager sharedManager] currentLocalIP];
    if (localIP.length) {
        room.hostIP = localIP;
    }
    [[MultiplayerManager sharedManager] updateRoom:room];

    // 生成分享代码
    self.lastShareCode = [[MultiplayerManager sharedManager] generateShareCodeForRoom:room];
    self.lastServerAddress = [NSString stringWithFormat:@"%@:%@", room.hostIP, room.hostPort];

    // 刷新表格，让 Section 1 显示最新的分享代码
    [self.tableView reloadData];

    // 弹出提示告知用户分享代码已生成
    [self showHostShareCodeAlert];
}

/// 显示房主分享代码 Alert
///
/// 提供以下操作：
///   - 复制分享代码到剪贴板
///   - 通过系统分享面板分享
- (void)showHostShareCodeAlert {
    NSString *shareCode = self.lastShareCode ?: @"";
    NSString *serverAddr = self.lastServerAddress ?: @"-";

    NSString *message = [NSString stringWithFormat:@"%@\n\n%@\n\n%@\n%@\n\n%@",
                         MPLocalized(@"mp.host.share_code_ready", @"分享代码已生成！将以下代码发给房客："),
                         shareCode,
                         MPLocalized(@"mp.host.tip.wait_guest", @"房客输入此代码即可加入你的联机网络"),
                         [NSString stringWithFormat:@"%@: %@", MPLocalized(@"mp.host.server_address", @"服务器地址"), serverAddr],
                         MPLocalized(@"mp.host.tip.copy_or_share", @"可点击下方按钮复制或分享代码")];

    UIAlertController *alert = [UIAlertController alertControllerWithTitle:MPLocalized(@"mp.host.share_code_title", @"分享代码已生成")
                                                                   message:message
                                                            preferredStyle:UIAlertControllerStyleAlert];

    // 复制按钮
    [alert addAction:[UIAlertAction actionWithTitle:MPLocalized(@"mp.host.copy_code", @"复制代码")
                                              style:UIAlertActionStyleDefault
                                            handler:^(UIAlertAction *action) {
        UIPasteboard *pasteboard = [UIPasteboard generalPasteboard];
        pasteboard.string = shareCode;
    }]];

    // 分享按钮
    __weak typeof(self) weakSelf = self;
    [alert addAction:[UIAlertAction actionWithTitle:MPLocalized(@"mp.host.share_button", @"分享...")
                                              style:UIAlertActionStyleDefault
                                            handler:^(UIAlertAction *action) {
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf) return;

        UIActivityViewController *activityVC = [[UIActivityViewController alloc] initWithActivityItems:@[shareCode] applicationActivities:nil];
        if (activityVC.popoverPresentationController) {
            activityVC.popoverPresentationController.sourceView = strongSelf.view;
            activityVC.popoverPresentationController.sourceRect = CGRectMake(strongSelf.view.bounds.size.width / 2.0,
                                                                              strongSelf.view.bounds.size.height / 2.0,
                                                                              1, 1);
        }
        [strongSelf presentViewController:activityVC animated:YES completion:nil];
    }]];

    // 关闭按钮
    [alert addAction:[UIAlertAction actionWithTitle:MPLocalized(@"common.ok", @"好")
                                              style:UIAlertActionStyleCancel
                                            handler:nil]];

    [self presentViewController:alert animated:YES completion:nil];
}

#pragma mark - 游戏内模式：房客流程

/// 点击"当房客"按钮：进入房客流程
///
/// 对标 FCL 房客流程：
///   1. 弹出输入框（UIAlertController with textField）
///   2. 用户输入分享代码
///   3. 解析代码（parseShareCode:）
///   4. 连接到房间（connectToRoom:completion:）
///   5. 连接成功后提示并显示服务器地址
- (void)guestButtonTapped {
    [self.view endEditing:YES];

    // 检查 ZeroTier 框架可用性
    if (![[MultiplayerManager sharedManager] isFrameworkAvailable]) {
        [self showSimpleAlertWithTitle:MPLocalized(@"mp.core.unavailable_title", @"联机核心不可用")
                                message:MPLocalized(@"mp.core.unavailable_msg", @"ZeroTier 联机核心未加载，无法作为房客加入。请使用包含真实 zt.framework 的构建版本。")];
        return;
    }

    UIAlertController *alert = [UIAlertController alertControllerWithTitle:MPLocalized(@"mp.guest.input_title", @"输入分享代码")
                                                                   message:MPLocalized(@"mp.guest.input_msg", @"请输入房主提供的分享代码")
                                                            preferredStyle:UIAlertControllerStyleAlert];

    [alert addTextFieldWithConfigurationHandler:^(UITextField *textField) {
        textField.placeholder = MPLocalized(@"mp.guest.code_placeholder", @"在此粘贴分享代码");
        textField.autocapitalizationType = UITextAutocapitalizationTypeNone;
        textField.autocorrectionType = UITextAutocorrectionTypeNo;
        textField.keyboardType = UIKeyboardTypeASCIICapable;
        textField.clearButtonMode = UITextFieldViewModeWhileEditing;
    }];

    [alert addAction:[UIAlertAction actionWithTitle:MPLocalized(@"common.cancel", @"取消")
                                              style:UIAlertActionStyleCancel
                                            handler:nil]];

    __weak typeof(self) weakSelf = self;
    [alert addAction:[UIAlertAction actionWithTitle:MPLocalized(@"mp.guest.join_button", @"加入")
                                              style:UIAlertActionStyleDefault
                                            handler:^(UIAlertAction *action) {
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf) return;

        UITextField *field = alert.textFields.firstObject;
        NSString *code = [field.text stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];

        // 校验：代码非空
        if (code.length == 0) {
            [strongSelf showSimpleAlertWithTitle:MPLocalized(@"mp.guest.error_title", @"输入为空")
                                          message:MPLocalized(@"mp.guest.error.empty", @"请输入房主提供的分享代码")];
            return;
        }

        // 解析分享代码
        MultiplayerRoom *parsedRoom = [[MultiplayerManager sharedManager] parseShareCode:code];
        if (!parsedRoom) {
            [strongSelf showSimpleAlertWithTitle:MPLocalized(@"mp.guest.error_title", @"代码无效")
                                          message:MPLocalized(@"mp.guest.error.invalid_code", @"无法解析分享代码，请确认代码完整无误")];
            return;
        }

        // 校验解析出的 Network ID
        if (!parsedRoom.networkId.length || ![[MultiplayerManager sharedManager] isValidNetworkId:parsedRoom.networkId]) {
            [strongSelf showSimpleAlertWithTitle:MPLocalized(@"mp.guest.error_title", @"代码无效")
                                          message:MPLocalized(@"mp.guest.error.invalid_network_id", @"分享代码中的 Network ID 无效")];
            return;
        }

        [strongSelf performGuestJoinWithRoom:parsedRoom shareCode:code];
    }]];

    [self presentViewController:alert animated:YES completion:nil];
}

/// 房客流程：执行加入房间
///
/// @param parsedRoom 从分享代码解析出的房间对象
/// @param shareCode 原始分享代码（用于显示）
- (void)performGuestJoinWithRoom:(MultiplayerRoom *)parsedRoom shareCode:(NSString *)shareCode {
    // 标记房客流程激活
    self.isGuestFlowActive = YES;
    self.lastShareCode = shareCode;
    self.lastServerAddress = [NSString stringWithFormat:@"%@:%@", parsedRoom.hostIP, parsedRoom.hostPort];

    // 设置房客房间对象（保存以便显示状态）
    self.guestRoom = parsedRoom;

    // 如果当前已连接到其他房间，先断开
    MultiplayerRoom *currentRoom = [[MultiplayerManager sharedManager] currentRoom];
    if (currentRoom && ![currentRoom.networkId isEqualToString:parsedRoom.networkId]) {
        [[MultiplayerManager sharedManager] disconnectCurrentRoom];
    }

    // 显示"正在连接"提示
    [self showSimpleAlertWithTitle:MPLocalized(@"mp.guest.connecting_title", @"正在加入联机")
                           message:MPLocalized(@"mp.guest.connecting_msg", @"正在连接到房主的 ZeroTier 网络，请稍候...")];

    // 连接到房间
    __weak typeof(self) weakSelf = self;
    [self connectToRoom:parsedRoom completion:^(BOOL success, NSError *error) {
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf) return;

        if (success) {
            // 连接成功：显示房客加入成功提示
            [strongSelf showGuestConnectedAlert];
        } else {
            // 连接失败
            strongSelf.isGuestFlowActive = NO;
            [strongSelf showSimpleAlertWithTitle:MPLocalized(@"mp.connect.failed", @"连接失败")
                                          message:error.localizedDescription ?: MPLocalized(@"mp.connect.failed_msg", @"无法连接到房主的网络，请检查分享代码是否正确以及网络是否畅通。")];
        }
        [strongSelf.tableView reloadData];
    }];

    [self.tableView reloadData];
}

/// 显示房客连接成功后的提示
///
/// 对标 FCL 房客加入成功后的引导：
///   - "已连接到房主的联机网络"
///   - "请在 MC 多人游戏界面查看房间"
///   - 显示服务器地址（房主 IP:端口）
- (void)showGuestConnectedAlert {
    MultiplayerRoom *room = self.guestRoom;
    NSString *hostIP = room.hostIP.length ? room.hostIP : ([[MultiplayerManager sharedManager] currentLocalIP] ?: @"-");
    NSString *hostPort = room.hostPort.length ? room.hostPort : @"25565";
    NSString *serverAddress = [NSString stringWithFormat:@"%@:%@", hostIP, hostPort];
    self.lastServerAddress = serverAddress;

    NSString *message = [NSString stringWithFormat:@"%@\n\n%@\n%@\n\n%@: %@",
                         MPLocalized(@"mp.guest.connected_msg", @"已连接到房主的联机网络"),
                         MPLocalized(@"mp.guest.tip.open_multiplayer", @"请在 MC 多人游戏界面查看房间"),
                         MPLocalized(@"mp.guest.tip.add_server", @"若未自动发现房间，可手动添加下方服务器地址"),
                         MPLocalized(@"mp.guest.server_address", @"服务器地址"),
                         serverAddress];

    [self showSimpleAlertWithTitle:MPLocalized(@"mp.guest.connected_title", @"已加入联机")
                           message:message];
}

#pragma mark - MultiplayerManagerDelegate

/// ZeroTier 节点已上线：刷新房间列表与状态
- (void)multiplayerNodeOnline {
    [self refreshRooms];
    [self.tableView reloadData];
}

/// ZeroTier 节点已离线：刷新房间列表与状态
- (void)multiplayerNodeOffline {
    [self refreshRooms];
    [self.tableView reloadData];
}

/// 指定房间已连接成功：刷新房间列表与状态
- (void)multiplayerRoomConnected:(MultiplayerRoom *)room {
    [self refreshRooms];
    [self.tableView reloadData];
}

/// 指定房间连接失败：刷新房间列表与状态
- (void)multiplayerRoom:(MultiplayerRoom *)room didFailWithError:(NSError *)error {
    [self refreshRooms];
    [self.tableView reloadData];
}

/// ZeroTier 框架可用性检测结果：刷新房间列表
- (void)multiplayerFrameworkAvailabilityChecked:(BOOL)available {
    [self refreshRooms];
    [self.tableView reloadData];
}

#pragma mark - 工具方法

/// 刷新房间列表（主线程）
- (void)refreshRooms {
    dispatch_async(dispatch_get_main_queue(), ^{
        self.rooms = [[MultiplayerManager sharedManager] savedRooms] ?: @[];
        [self.tableView reloadData];
    });
}

/// 显示简单的 Alert 提示
- (void)showSimpleAlertWithTitle:(NSString *)title message:(NSString *)message {
    dispatch_async(dispatch_get_main_queue(), ^{
        UIAlertController *alert = [UIAlertController alertControllerWithTitle:title message:message preferredStyle:UIAlertControllerStyleAlert];
        [alert addAction:[UIAlertAction actionWithTitle:MPLocalized(@"common.ok", @"好") style:UIAlertActionStyleDefault handler:nil]];
        // 避免重复 present
        if (self.presentedViewController) {
            [self.presentedViewController dismissViewControllerAnimated:NO completion:^{
                [self presentViewController:alert animated:YES completion:nil];
            }];
        } else {
            [self presentViewController:alert animated:YES completion:nil];
        }
    });
}

/// 生成纯色圆形小图标（用于状态指示点）
/// @param color 圆形颜色
/// @param size 圆形直径（pt）
/// @return 圆形 UIImage
- (UIImage *)circleImageWithColor:(UIColor *)color size:(CGFloat)size {
    CGRect rect = CGRectMake(0, 0, size, size);
    UIGraphicsBeginImageContextWithOptions(rect.size, NO, [UIScreen mainScreen].scale);
    CGContextRef context = UIGraphicsGetCurrentContext();
    CGContextSetFillColorWithColor(context, color.CGColor);
    CGContextFillEllipseInRect(context, rect);
    UIImage *image = UIGraphicsGetImageFromCurrentImageContext();
    UIGraphicsEndImageContext();
    return image;
}

/// 获取房间状态对应的颜色
/// @param status 房间状态
/// @return 状态颜色（连接中=橙、已连接=绿、断开=灰、错误=红）
- (UIColor *)colorForRoomStatus:(MultiplayerRoomStatus)status {
    switch (status) {
        case MultiplayerRoomStatusDisconnected:
            return [UIColor systemGrayColor];
        case MultiplayerRoomStatusConnecting:
            return [UIColor systemOrangeColor];
        case MultiplayerRoomStatusConnected:
            return [UIColor systemGreenColor];
        case MultiplayerRoomStatusError:
            return [UIColor systemRedColor];
    }
    return [UIColor systemGrayColor];
}

/// 获取房间状态对应的本地化文本
/// @param status 房间状态
/// @return 状态文本（"未连接" / "连接中" / "已连接" / "错误"）
- (NSString *)textForRoomStatus:(MultiplayerRoomStatus)status {
    switch (status) {
        case MultiplayerRoomStatusDisconnected:
            return MPLocalized(@"mp.room.status.disconnected", @"未连接");
        case MultiplayerRoomStatusConnecting:
            return MPLocalized(@"mp.room.status.connecting", @"连接中");
        case MultiplayerRoomStatusConnected:
            return MPLocalized(@"mp.room.status.connected", @"已连接");
        case MultiplayerRoomStatusError:
            return MPLocalized(@"mp.room.status.error", @"错误");
    }
    return @"";
}

/// 创建房间行的连接/断开按钮
///
/// 按钮样式：圆角矩形，宽 64pt 高 32pt
/// - 已连接：显示"断开"，红色背景
/// - 连接中：显示"连接中"，灰色背景，禁用点击
/// - 其他：显示"连接"，蓝色背景
///
/// @param room 房间对象
/// @return 配置好的按钮
- (UIButton *)makeActionButtonForRoom:(MultiplayerRoom *)room {
    UIButton *button = [UIButton buttonWithType:UIButtonTypeSystem];
    button.frame = CGRectMake(0, 0, 64, 32);
    button.titleLabel.font = [UIFont systemFontOfSize:14 weight:UIFontWeightMedium];
    button.layer.cornerRadius = 8;
    button.layer.masksToBounds = YES;

    NSString *title;
    UIColor *bgColor;

    if (room.status == MultiplayerRoomStatusConnected) {
        title = MPLocalized(@"mp.room.button.disconnect", @"断开");
        bgColor = [UIColor systemRedColor];
        button.enabled = YES;
    } else if (room.status == MultiplayerRoomStatusConnecting) {
        title = MPLocalized(@"mp.room.button.connecting", @"连接中");
        bgColor = [UIColor systemGrayColor];
        button.enabled = NO;
    } else {
        title = MPLocalized(@"mp.room.button.connect", @"连接");
        bgColor = [UIColor systemBlueColor];
        button.enabled = YES;
    }

    [button setTitle:title forState:UIControlStateNormal];
    [button setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    button.backgroundColor = bgColor;

    return button;
}

#pragma mark - UITextFieldDelegate

/// 点击 Return 键时收起键盘
- (BOOL)textFieldShouldReturn:(UITextField *)textField {
    if (textField == self.directIPField) {
        // 在 IP 输入框按 Return 切换到端口输入框
        [self.directPortField becomeFirstResponder];
    } else {
        [textField resignFirstResponder];
    }
    return YES;
}

#pragma mark - UITableViewDataSource

/// Section 数量：根据模式返回
- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView {
    if (self.mode == MultiplayerVCModeInGame) {
        // 游戏内模式：选择角色 + 联机状态
        return 2;
    }
    // 启动器模式：联机设置 + 我的房间 + 直连
    return 3;
}

/// 每个 Section 的行数：根据模式和 Section 返回
- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    if (self.mode == MultiplayerVCModeInGame) {
        switch (section) {
            case 0:
                // 选择角色：当房主 + 当房客
                return 2;
            case 1:
                // 联机状态：1 行综合状态
                return 1;
            default:
                return 0;
        }
    }
    // 启动器模式
    switch (section) {
        case 0:
            // 联机设置：启用联机开关 + Network ID
            return 2;
        case 1:
            // 我的房间：至少 1 行（空状态提示）
            return MAX(1, (NSInteger)self.rooms.count);
        case 2:
            // 直连：IP+端口输入 + 加入游戏按钮
            return 2;
        default:
            return 0;
    }
}

/// Section 标题：根据模式返回
- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section {
    if (self.mode == MultiplayerVCModeInGame) {
        switch (section) {
            case 0:
                return MPLocalized(@"mp.ingame.section.role", @"选择角色");
            case 1:
                return MPLocalized(@"mp.ingame.section.status", @"联机状态");
            default:
                return nil;
        }
    }
    switch (section) {
        case 0:
            return MPLocalized(@"mp.section.settings", @"联机设置");
        case 1:
            return MPLocalized(@"mp.section.rooms", @"我的房间");
        case 2:
            return MPLocalized(@"mp.section.direct", @"直连");
        default:
            return nil;
    }
}

/// Section 脚注：根据模式返回
- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section {
    if (self.mode == MultiplayerVCModeInGame) {
        switch (section) {
            case 0:
                return MPLocalized(@"mp.ingame.section.role_footer", @"房主需在 MC 中开放局域网，房客输入分享代码即可加入");
            case 1:
                return MPLocalized(@"mp.ingame.section.status_footer", @"显示当前联机网络的状态信息");
            default:
                return nil;
        }
    }
    switch (section) {
        case 0:
            return MPLocalized(@"mp.section.settings_footer", @"启用联机后可设置 Network ID，房主开房时自动使用");
        case 2:
            return MPLocalized(@"mp.section.direct_footer", @"输入服务器 IP 和端口，写入当前 profile，启动游戏后自动加入");
        default:
            return nil;
    }
}

/// 根据 IndexPath 配置对应的 cell
- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    if (self.mode == MultiplayerVCModeInGame) {
        return [self cellForInGameSection:indexPath];
    }
    return [self cellForLauncherSection:indexPath];
}

#pragma mark - 启动器模式 Cell 配置

/// 启动器模式 cell 配置分发
- (UITableViewCell *)cellForLauncherSection:(NSIndexPath *)indexPath {
    switch (indexPath.section) {
        case 0:
            return [self cellForSettingsSectionAtRow:indexPath.row];
        case 1:
            return [self cellForRoomsSectionAtRow:indexPath.row];
        case 2:
            return [self cellForDirectSectionAtRow:indexPath.row];
        default:
            return [UITableViewCell new];
    }
}

/// Section 0「联机设置」的 cell 配置
/// @param row 行号（0=启用联机开关，1=预设 Network ID）
- (UITableViewCell *)cellForSettingsSectionAtRow:(NSInteger)row {
    if (row == 0) {
        // 启用联机开关行
        UITableViewCell *cell = [self.tableView dequeueReusableCellWithIdentifier:@"SwitchCell"];
        cell.selectionStyle = UITableViewCellSelectionStyleNone;
        cell.textLabel.text = MPLocalized(@"mp.settings.enable_multiplayer", @"启用联机");
        cell.textLabel.font = [UIFont systemFontOfSize:16];

        // 懒初始化 UISwitch
        if (!self.enableSwitch) {
            self.enableSwitch = [[UISwitch alloc] init];
            [self.enableSwitch addTarget:self action:@selector(enableSwitchChanged:) forControlEvents:UIControlEventValueChanged];
        }
        // 初始状态：根据节点是否已启动设置开关
        BOOL started = [[MultiplayerManager sharedManager] isNodeStarted];
        [self.enableSwitch setOn:started animated:NO];
        cell.accessoryView = self.enableSwitch;

        // 辅助文字：显示节点状态
        if (started) {
            if ([[MultiplayerManager sharedManager] isNodeOnline]) {
                cell.detailTextLabel.text = MPLocalized(@"mp.settings.node_online", @"节点已上线");
            } else {
                cell.detailTextLabel.text = MPLocalized(@"mp.settings.node_starting", @"节点启动中...");
            }
        } else {
            cell.detailTextLabel.text = MPLocalized(@"mp.settings.node_offline", @"节点未启动");
        }
        cell.detailTextLabel.font = [UIFont systemFontOfSize:12];

        // 适配自定义背景
        if ([[BackgroundManager sharedManager] hasBackground]) {
            cell.textLabel.textColor = [UIColor whiteColor];
            cell.detailTextLabel.textColor = [UIColor whiteColor];
        } else {
            cell.textLabel.textColor = [UIColor labelColor];
            cell.detailTextLabel.textColor = [UIColor secondaryLabelColor];
        }

        [[BackgroundManager sharedManager] applyEffectToCell:cell];
        return cell;
    } else {
        // 预设 Network ID 行
        UITableViewCell *cell = [self.tableView dequeueReusableCellWithIdentifier:@"NetworkIdCell"];
        cell.selectionStyle = UITableViewCellSelectionStyleDefault;
        cell.textLabel.text = MPLocalized(@"mp.settings.preset_network_id", @"预设 Network ID");
        cell.textLabel.font = [UIFont systemFontOfSize:16];

        // 显示当前预设的 Network ID（脱敏显示：前 4 + ... + 后 4）
        NSString *presetNetId = [[MultiplayerManager sharedManager] presetNetworkId];
        NSString *displayValue;
        if (presetNetId.length >= 16) {
            displayValue = [NSString stringWithFormat:@"%@...%@",
                            [presetNetId substringToIndex:4],
                            [presetNetId substringFromIndex:presetNetId.length - 4]];
        } else if (presetNetId.length > 0) {
            displayValue = presetNetId;
        } else {
            displayValue = MPLocalized(@"mp.settings.not_set", @"未设置");
        }

        // 使用 detailTextLabel 显示值
        cell.detailTextLabel.text = displayValue;
        cell.detailTextLabel.font = [UIFont systemFontOfSize:14];
        cell.detailTextLabel.numberOfLines = 1;
        cell.detailTextLabel.adjustsFontSizeToFitWidth = YES;
        cell.detailTextLabel.minimumScaleFactor = 0.7;

        // 右侧显示编辑图标
        cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;

        // 适配自定义背景
        if ([[BackgroundManager sharedManager] hasBackground]) {
            cell.textLabel.textColor = [UIColor whiteColor];
            cell.detailTextLabel.textColor = [UIColor whiteColor];
        } else {
            cell.textLabel.textColor = [UIColor labelColor];
            cell.detailTextLabel.textColor = [UIColor secondaryLabelColor];
        }

        [[BackgroundManager sharedManager] applyEffectToCell:cell];
        return cell;
    }
}

/// Section 1「我的房间」的 cell 配置
/// @param row 行号
- (UITableViewCell *)cellForRoomsSectionAtRow:(NSInteger)row {
    // 空状态：显示提示文字
    if (self.rooms.count == 0) {
        UITableViewCell *cell = [self.tableView dequeueReusableCellWithIdentifier:@"EmptyCell"];
        cell.selectionStyle = UITableViewCellSelectionStyleNone;
        cell.textLabel.text = MPLocalized(@"mp.rooms.empty", @"还没有保存的房间");
        cell.textLabel.textAlignment = NSTextAlignmentCenter;
        cell.textLabel.font = [UIFont systemFontOfSize:14];
        // 适配自定义背景
        if ([[BackgroundManager sharedManager] hasBackground]) {
            cell.textLabel.textColor = [UIColor whiteColor];
        } else {
            cell.textLabel.textColor = [UIColor secondaryLabelColor];
        }
        [[BackgroundManager sharedManager] applyEffectToCell:cell];
        return cell;
    }

    // 有房间：使用 subtitle 风格的标准 UITableViewCell
    MultiplayerRoom *room = self.rooms[row];
    // 不注册 RoomCell，使用 dequeueReusableCellWithIdentifier: 手工创建 subtitle 风格的 cell
    UITableViewCell *cell = [self.tableView dequeueReusableCellWithIdentifier:@"RoomCell"];
    if (!cell) {
        cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:@"RoomCell"];
    }
    cell.selectionStyle = UITableViewCellSelectionStyleDefault;

    // 房间名
    cell.textLabel.text = room.name.length ? room.name : MPLocalized(@"mp.room.unnamed", @"未命名房间");
    cell.textLabel.font = [UIFont systemFontOfSize:16 weight:UIFontWeightMedium];

    // 详情：Network ID + 状态 + 服务器地址（已连接时显示完整地址方便分享）
    NSString *statusText = [self textForRoomStatus:room.status];
    NSMutableString *detail = [NSMutableString string];
    [detail appendFormat:@"%@: %@",
        MPLocalized(@"mp.room.network_id", @"Network ID"),
        room.networkId ?: @"-"];
    [detail appendFormat:@"\n%@", statusText];
    if (room.status == MultiplayerRoomStatusConnected) {
        // 已连接时显示完整服务器地址
        NSString *hostIP = room.hostIP.length ? room.hostIP : [[MultiplayerManager sharedManager] currentLocalIP];
        NSString *hostPort = room.hostPort.length ? room.hostPort : @"25565";
        if (hostIP.length) {
            [detail appendFormat:@"\n%@: %@:%@",
                MPLocalized(@"mp.room.server_address", @"服务器地址"),
                hostIP, hostPort];
        }
    }
    cell.detailTextLabel.text = detail;
    cell.detailTextLabel.font = [UIFont systemFontOfSize:12];
    cell.detailTextLabel.numberOfLines = 0;

    // 状态指示点（imageView 显示彩色小圆点）
    UIColor *statusColor = [self colorForRoomStatus:room.status];
    UIImage *dotImage = [self circleImageWithColor:statusColor size:10];
    cell.imageView.image = dotImage;

    // 连接 / 断开按钮（accessoryView）
    UIButton *actionButton = [self makeActionButtonForRoom:room];
    [actionButton addTarget:self action:@selector(roomButtonTapped:) forControlEvents:UIControlEventTouchUpInside];
    actionButton.tag = row;
    cell.accessoryView = actionButton;

    // 适配自定义背景
    if ([[BackgroundManager sharedManager] hasBackground]) {
        cell.textLabel.textColor = [UIColor whiteColor];
        cell.detailTextLabel.textColor = [UIColor whiteColor];
    } else {
        cell.textLabel.textColor = [UIColor labelColor];
        cell.detailTextLabel.textColor = [UIColor secondaryLabelColor];
    }

    [[BackgroundManager sharedManager] applyEffectToCell:cell];
    return cell;
}

/// Section 2「直连」的 cell 配置
/// @param row 行号（0=IP+端口输入，1=加入游戏按钮）
- (UITableViewCell *)cellForDirectSectionAtRow:(NSInteger)row {
    if (row == 0) {
        // IP + 端口输入行
        UITableViewCell *cell = [self.tableView dequeueReusableCellWithIdentifier:@"DirectInputCell"];
        cell.selectionStyle = UITableViewCellSelectionStyleNone;

        // 懒初始化 IP 输入框
        if (!self.directIPField) {
            self.directIPField = [[UITextField alloc] init];
            self.directIPField.placeholder = MPLocalized(@"mp.direct.ip_placeholder", @"服务器 IP");
            self.directIPField.font = [UIFont systemFontOfSize:15];
            self.directIPField.autocapitalizationType = UITextAutocapitalizationTypeNone;
            self.directIPField.autocorrectionType = UITextAutocorrectionTypeNo;
            self.directIPField.keyboardType = UIKeyboardTypeNumbersAndPunctuation;
            self.directIPField.clearButtonMode = UITextFieldViewModeWhileEditing;
            self.directIPField.returnKeyType = UIReturnKeyNext;
            self.directIPField.delegate = self;
            self.directIPField.translatesAutoresizingMaskIntoConstraints = NO;
        }

        // 懒初始化端口输入框
        if (!self.directPortField) {
            self.directPortField = [[UITextField alloc] init];
            self.directPortField.placeholder = @"25565";
            self.directPortField.font = [UIFont systemFontOfSize:15];
            self.directPortField.autocapitalizationType = UITextAutocapitalizationTypeNone;
            self.directPortField.autocorrectionType = UITextAutocorrectionTypeNo;
            self.directPortField.keyboardType = UIKeyboardTypeNumberPad;
            self.directPortField.clearButtonMode = UITextFieldViewModeWhileEditing;
            self.directPortField.returnKeyType = UIReturnKeyDone;
            self.directPortField.delegate = self;
            self.directPortField.translatesAutoresizingMaskIntoConstraints = NO;
        }

        // 懒初始化冒号分隔标签
        UILabel *colonLabel = (UILabel *)[cell.contentView viewWithTag:9528];
        if (!colonLabel) {
            colonLabel = [[UILabel alloc] init];
            colonLabel.tag = 9528;
            colonLabel.text = @":";
            colonLabel.font = [UIFont systemFontOfSize:15];
            colonLabel.translatesAutoresizingMaskIntoConstraints = NO;
            [cell.contentView addSubview:colonLabel];
        }

        // 如果 textField 已在别的 cell 上（cell 复用场景），先移除
        if (self.directIPField.superview && self.directIPField.superview != cell.contentView) {
            [self.directIPField removeFromSuperview];
        }
        if (self.directPortField.superview && self.directPortField.superview != cell.contentView) {
            [self.directPortField removeFromSuperview];
        }

        BOOL needsNewConstraints = NO;
        if (!self.directIPField.superview) {
            [cell.contentView addSubview:self.directIPField];
            needsNewConstraints = YES;
        }
        if (!self.directPortField.superview) {
            [cell.contentView addSubview:self.directPortField];
            needsNewConstraints = YES;
        }

        // 仅在 textField 首次添加到 cell 时设置约束（避免重复激活导致冲突）
        if (needsNewConstraints) {
            [NSLayoutConstraint activateConstraints:@[
                [self.directIPField.leadingAnchor constraintEqualToAnchor:cell.contentView.leadingAnchor constant:16],
                [self.directIPField.topAnchor constraintEqualToAnchor:cell.contentView.topAnchor constant:12],
                [self.directIPField.bottomAnchor constraintEqualToAnchor:cell.contentView.bottomAnchor constant:-12],
                [self.directIPField.trailingAnchor constraintEqualToAnchor:colonLabel.leadingAnchor constant:-4],

                [colonLabel.centerYAnchor constraintEqualToAnchor:cell.contentView.centerYAnchor],
                [colonLabel.widthAnchor constraintEqualToConstant:8],

                [self.directPortField.leadingAnchor constraintEqualToAnchor:colonLabel.trailingAnchor constant:4],
                [self.directPortField.trailingAnchor constraintEqualToAnchor:cell.contentView.trailingAnchor constant:-16],
                [self.directPortField.centerYAnchor constraintEqualToAnchor:cell.contentView.centerYAnchor],
                [self.directPortField.widthAnchor constraintEqualToConstant:80],
            ]];
        }

        // 适配自定义背景
        BOOL hasBackground = [[BackgroundManager sharedManager] hasBackground];
        if (hasBackground) {
            self.directIPField.textColor = [UIColor whiteColor];
            self.directPortField.textColor = [UIColor whiteColor];
            colonLabel.textColor = [UIColor whiteColor];
        } else {
            self.directIPField.textColor = [UIColor labelColor];
            self.directPortField.textColor = [UIColor labelColor];
            colonLabel.textColor = [UIColor labelColor];
        }

        [[BackgroundManager sharedManager] applyEffectToCell:cell];
        return cell;
    } else {
        // 加入游戏按钮行
        UITableViewCell *cell = [self.tableView dequeueReusableCellWithIdentifier:@"ButtonCell"];
        cell.selectionStyle = UITableViewCellSelectionStyleNone;
        cell.textLabel.text = MPLocalized(@"mp.direct.join_button", @"加入游戏");
        cell.textLabel.textAlignment = NSTextAlignmentCenter;
        cell.textLabel.font = [UIFont systemFontOfSize:16 weight:UIFontWeightSemibold];
        // 适配自定义背景
        if ([[BackgroundManager sharedManager] hasBackground]) {
            cell.textLabel.textColor = [UIColor whiteColor];
        } else {
            cell.textLabel.textColor = [UIColor systemBlueColor];
        }
        [[BackgroundManager sharedManager] applyEffectToCell:cell];
        return cell;
    }
}

#pragma mark - 游戏内模式 Cell 配置

/// 游戏内模式 cell 配置分发
- (UITableViewCell *)cellForInGameSection:(NSIndexPath *)indexPath {
    switch (indexPath.section) {
        case 0:
            return [self cellForRoleSectionAtRow:indexPath.row];
        case 1:
            return [self cellForInGameStatusSection];
        default:
            return [UITableViewCell new];
    }
}

/// Section 0「选择角色」的 cell 配置
/// @param row 行号（0=当房主，1=当房客）
- (UITableViewCell *)cellForRoleSectionAtRow:(NSInteger)row {
    UITableViewCell *cell = [self.tableView dequeueReusableCellWithIdentifier:@"RoleCardCell"];
    cell.selectionStyle = UITableViewCellSelectionStyleNone;

    // 自定义卡片式布局：左侧大图标 + 右侧标题和说明
    if (row == 0) {
        // 当房主
        cell.imageView.image = [UIImage systemImageNamed:@"crown"];
        cell.imageView.tintColor = [UIColor systemOrangeColor];
        cell.textLabel.text = MPLocalized(@"mp.ingame.host_title", @"当房主");
        cell.textLabel.font = [UIFont systemFontOfSize:18 weight:UIFontWeightSemibold];
        cell.detailTextLabel.text = MPLocalized(@"mp.ingame.host_desc", @"创建联机房间，开放局域网后生成分享代码");
        cell.detailTextLabel.font = [UIFont systemFontOfSize:13];
        cell.detailTextLabel.numberOfLines = 0;

        // 房主流程激活时显示状态指示
        if (self.isHostFlowActive) {
            cell.accessoryType = UITableViewCellAccessoryCheckmark;
        } else {
            cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
        }
    } else {
        // 当房客
        cell.imageView.image = [UIImage systemImageNamed:@"person.2"];
        cell.imageView.tintColor = [UIColor systemBlueColor];
        cell.textLabel.text = MPLocalized(@"mp.ingame.guest_title", @"当房客");
        cell.textLabel.font = [UIFont systemFontOfSize:18 weight:UIFontWeightSemibold];
        cell.detailTextLabel.text = MPLocalized(@"mp.ingame.guest_desc", @"输入分享代码，加入房主的联机网络");
        cell.detailTextLabel.font = [UIFont systemFontOfSize:13];
        cell.detailTextLabel.numberOfLines = 0;

        // 房客流程激活时显示状态指示
        if (self.isGuestFlowActive) {
            cell.accessoryType = UITableViewCellAccessoryCheckmark;
        } else {
            cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
        }
    }

    // 适配自定义背景
    if ([[BackgroundManager sharedManager] hasBackground]) {
        cell.textLabel.textColor = [UIColor whiteColor];
        cell.detailTextLabel.textColor = [UIColor whiteColor];
    } else {
        cell.textLabel.textColor = [UIColor labelColor];
        cell.detailTextLabel.textColor = [UIColor secondaryLabelColor];
    }

    [[BackgroundManager sharedManager] applyEffectToCell:cell];
    return cell;
}

/// Section 1「联机状态」的 cell 配置
///
/// 综合显示：
///   - 当前联机状态（已连接/未连接）
///   - Network ID
///   - 本地 IP
///   - 房主流程：分享代码
///   - 房客流程：服务器地址
- (UITableViewCell *)cellForInGameStatusSection {
    UITableViewCell *cell = [self.tableView dequeueReusableCellWithIdentifier:@"StatusCell"];
    cell.selectionStyle = UITableViewCellSelectionStyleNone;

    MultiplayerManager *manager = [MultiplayerManager sharedManager];
    MultiplayerRoom *currentRoom = manager.currentRoom;
    BOOL connected = (currentRoom != nil) && (currentRoom.status == MultiplayerRoomStatusConnected);

    // 标题：联机状态
    cell.textLabel.text = connected ? MPLocalized(@"mp.ingame.status.connected", @"已连接") : MPLocalized(@"mp.ingame.status.disconnected", @"未连接");
    cell.textLabel.font = [UIFont systemFontOfSize:16 weight:UIFontWeightMedium];

    // 详情：Network ID + 本地 IP + （房主）分享代码 / （房客）服务器地址
    NSMutableString *detail = [NSMutableString string];

    // 状态指示
    if (self.isHostFlowActive) {
        [detail appendString:MPLocalized(@"mp.ingame.status.host_mode", @"房主模式")];
    } else if (self.isGuestFlowActive) {
        [detail appendString:MPLocalized(@"mp.ingame.status.guest_mode", @"房客模式")];
    } else {
        [detail appendString:MPLocalized(@"mp.ingame.status.idle", @"未开始")];
    }

    // Network ID
    NSString *networkId = currentRoom.networkId.length ? currentRoom.networkId : [manager presetNetworkId];
    if (networkId.length) {
        [detail appendFormat:@"\n%@: %@", MPLocalized(@"mp.ingame.status.network_id", @"Network ID"), networkId];
    } else {
        [detail appendFormat:@"\n%@: %@", MPLocalized(@"mp.ingame.status.network_id", @"Network ID"), MPLocalized(@"mp.settings.not_set", @"未设置")];
    }

    // 本地 IP
    NSString *localIP = manager.currentLocalIP;
    if (localIP.length) {
        [detail appendFormat:@"\n%@: %@", MPLocalized(@"mp.ingame.status.local_ip", @"本地 IP"), localIP];
    }

    // 房主流程：显示分享代码
    if (self.isHostFlowActive && self.lastShareCode.length) {
        [detail appendFormat:@"\n%@: %@",
            MPLocalized(@"mp.ingame.status.share_code", @"分享代码"),
            self.lastShareCode];
    }

    // 房客流程：显示服务器地址
    if (self.isGuestFlowActive && self.lastServerAddress.length) {
        [detail appendFormat:@"\n%@: %@",
            MPLocalized(@"mp.ingame.status.server_address", @"服务器地址"),
            self.lastServerAddress];
    }

    cell.detailTextLabel.text = detail;
    cell.detailTextLabel.font = [UIFont systemFontOfSize:13];
    cell.detailTextLabel.numberOfLines = 0;

    // 状态指示点
    UIColor *statusColor = connected ? [UIColor systemGreenColor] : [UIColor systemGrayColor];
    UIImage *dotImage = [self circleImageWithColor:statusColor size:10];
    cell.imageView.image = dotImage;

    // 适配自定义背景
    if ([[BackgroundManager sharedManager] hasBackground]) {
        cell.textLabel.textColor = [UIColor whiteColor];
        cell.detailTextLabel.textColor = [UIColor whiteColor];
    } else {
        cell.textLabel.textColor = [UIColor labelColor];
        cell.detailTextLabel.textColor = [UIColor secondaryLabelColor];
    }

    [[BackgroundManager sharedManager] applyEffectToCell:cell];
    return cell;
}

#pragma mark - UITableViewDelegate

/// 点击行回调：根据模式和 Section 分发
- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];

    if (self.mode == MultiplayerVCModeInGame) {
        [self handleInGameSelectionAtIndexPath:indexPath];
        return;
    }
    [self handleLauncherSelectionAtIndexPath:indexPath];
}

/// 启动器模式点击处理
- (void)handleLauncherSelectionAtIndexPath:(NSIndexPath *)indexPath {
    switch (indexPath.section) {
        case 0:
            if (indexPath.row == 0) {
                // 点击开关行：让开关获得焦点（切换开关状态）
                // 不做处理，开关自身会响应
            } else if (indexPath.row == 1) {
                // 点击 Network ID 行：弹出编辑对话框
                [self networkIdCellTapped];
            }
            break;
        case 1:
            if (self.rooms.count == 0) {
                // 空状态：提示用户先设置 Network ID 或直接加入房间
                [self showSimpleAlertWithTitle:MPLocalized(@"mp.rooms.empty_title", @"暂无房间")
                                         message:MPLocalized(@"mp.rooms.empty_msg", @"请先在 Section 0 设置 Network ID，然后在游戏内模式中选择当房主或房客")];
            } else {
                // 点击房间行：弹出 ActionSheet
                MultiplayerRoom *room = self.rooms[indexPath.row];
                [self showRoomActionsForRoom:room];
            }
            break;
        case 2:
            if (indexPath.row == 0) {
                // 点击直连输入行：让 IP 输入框获得焦点
                [self.directIPField becomeFirstResponder];
            } else if (indexPath.row == 1) {
                // 点击加入游戏按钮
                [self joinDirectConnect];
            }
            break;
        default:
            break;
    }
}

/// 游戏内模式点击处理
- (void)handleInGameSelectionAtIndexPath:(NSIndexPath *)indexPath {
    switch (indexPath.section) {
        case 0:
            if (indexPath.row == 0) {
                // 当房主
                [self hostButtonTapped];
            } else if (indexPath.row == 1) {
                // 当房客
                [self guestButtonTapped];
            }
            break;
        case 1:
            // 联机状态行：无操作（仅显示信息）
            // 房主流程激活时点击可重新显示分享代码
            if (self.isHostFlowActive && self.lastShareCode.length) {
                [self showHostShareCodeAlert];
            }
            break;
        default:
            break;
    }
}

/// 行高：根据模式和 IndexPath 返回
- (CGFloat)tableView:(UITableView *)tableView heightForRowAtIndexPath:(NSIndexPath *)indexPath {
    if (self.mode == MultiplayerVCModeInGame) {
        if (indexPath.section == 0) {
            // 选择角色卡片行：大卡片样式，更高
            return 76;
        }
        if (indexPath.section == 1) {
            // 联机状态行：动态高度（多行详情）
            return UITableViewAutomaticDimension;
        }
        return 56;
    }
    // 启动器模式
    if (indexPath.section == 0) {
        // 联机设置行
        return 56;
    }
    if (indexPath.section == 1) {
        if (self.rooms.count == 0) {
            // 空状态提示行
            return 60;
        }
        // 房间行：subtitle 显示 2-3 行，需要更多空间
        return 76;
    }
    if (indexPath.section == 2) {
        // IP+端口输入行 / 加入按钮行
        return 48;
    }
    return UITableViewAutomaticDimension;
}

@end
