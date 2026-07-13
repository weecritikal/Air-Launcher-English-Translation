//
//  MultiplayerViewController.m
//  Amethyst
//
//  MC 联机界面实现（参照 FCL 和 HMCL 联机界面风格简化版）
//
//  本文件实现基于 ZeroTier 的 Minecraft 联机功能界面，采用 TableView InsetGrouped 风格，
//  界面简洁直观，分为 3 个 Section：
//
//  1. 加入房间（Section 0）
//     - 一行 UITextField：输入 ZeroTier Network ID（16 位十六进制）
//     - 一行按钮：点击后自动创建房间并连接，连接成功后保存到房间列表
//
//  2. 我的房间（Section 1）
//     - 没有房间：显示"还没有保存的房间"提示
//     - 有房间：每行显示一个房间（房间名 + Network ID + 状态 + 连接/断开按钮）
//     - 点击房间行弹出 ActionSheet：连接/断开、分享、删除
//
//  3. 直连（Section 2）
//     - 一行：IP 地址输入框 + 端口输入框
//     - 一行按钮：点击后将服务器地址写入当前 profile，启动游戏后自动加入
//
//  实现要点：
//  - 仅保留 1 个 ViewController（MultiplayerViewController），不再使用自定义 Cell / 子 VC
//  - 房间行使用标准 UITableViewCell（subtitle 风格）+ 内联配置
//  - 创建房间使用 UIAlertController（两个文本框：房间名称 + Network ID）
//  - 加入房间：输入 Network ID → 创建临时 MultiplayerRoom → 调用 connectToRoom: → 成功后保存
//  - 连接状态：通过 detailTextLabel 文本 + imageView 状态点 + 按钮文字综合显示
//  - 保留所有 MultiplayerManagerDelegate 回调
//  - 适配自定义启动器背景（BackgroundManager）
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

/// 主表格视图（InsetGrouped 风格）
@property (nonatomic, strong) UITableView *tableView;

/// 当前已保存的房间列表
@property (nonatomic, strong) NSArray<MultiplayerRoom *> *rooms;

/// Section 0 的 Network ID 输入框（强引用，确保跨 cell 复用时数据不丢失）
@property (nonatomic, strong) UITextField *joinNetworkIdField;

/// Section 2 的 IP 地址输入框（强引用）
@property (nonatomic, strong) UITextField *directIPField;

/// Section 2 的端口输入框（强引用）
@property (nonatomic, strong) UITextField *directPortField;

@end

@implementation MultiplayerViewController

#pragma mark - Lifecycle

- (void)viewDidLoad {
    [super viewDidLoad];

    // 设置标题
    self.title = MPLocalized(@"mp.title", @"联机");

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
    // 注意：RoomCell 不注册，以便使用 subtitle 风格手工创建
    // 注意：JoinInputCell / DirectInputCell 分别用独立标识符，避免 cell 在两个输入行之间复用导致 textField 错位
    [self.tableView registerClass:[UITableViewCell class] forCellReuseIdentifier:@"DefaultCell"];
    [self.tableView registerClass:[UITableViewCell class] forCellReuseIdentifier:@"ButtonCell"];
    [self.tableView registerClass:[UITableViewCell class] forCellReuseIdentifier:@"EmptyCell"];
    [self.tableView registerClass:[UITableViewCell class] forCellReuseIdentifier:@"JoinInputCell"];
    [self.tableView registerClass:[UITableViewCell class] forCellReuseIdentifier:@"DirectInputCell"];
    [self.view addSubview:self.tableView];

    [NSLayoutConstraint activateConstraints:@[
        [self.tableView.topAnchor constraintEqualToAnchor:self.view.topAnchor],
        [self.tableView.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor],
        [self.tableView.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [self.tableView.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
    ]];

    // 导航栏左上角：关闭按钮（xmark）
    UIBarButtonItem *closeButton = [[UIBarButtonItem alloc] initWithImage:[UIImage systemImageNamed:@"xmark"]
                                                                     style:UIBarButtonItemStylePlain
                                                                    target:self
                                                                    action:@selector(closeTapped)];
    closeButton.accessibilityLabel = MPLocalized(@"mp.close", @"关闭");
    self.navigationItem.leftBarButtonItem = closeButton;

    // 导航栏右上角：创建房间按钮（+）
    UIBarButtonItem *addButton = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemAdd
                                                                               target:self
                                                                               action:@selector(createRoomTapped)];
    self.navigationItem.rightBarButtonItem = addButton;

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
        [self.dismissViewControllerAnimated:YES completion:nil];
    }
}

#pragma mark - 创建房间（使用 UIAlertController）

/// 点击右上角 + 按钮：弹出创建房间对话框
///
/// 对话框包含两个文本框：
///   - 房间名称：用户自定义的房间名
///   - ZeroTier Network ID：16 位十六进制网络 ID
///
/// 点击"创建"后创建 MultiplayerRoom 对象并添加到 MultiplayerManager
- (void)createRoomTapped {
    [self.view endEditing:YES];

    // 检查 ZeroTier 框架可用性
    if (![[MultiplayerManager sharedManager] isFrameworkAvailable]) {
        [self showSimpleAlertWithTitle:MPLocalized(@"mp.core.unavailable_title", @"联机核心不可用")
                                message:MPLocalized(@"mp.core.unavailable_msg", @"ZeroTier 联机核心未加载，无法创建房间。请使用包含真实 zt.framework 的构建版本。")];
        return;
    }

    UIAlertController *alert = [UIAlertController alertControllerWithTitle:MPLocalized(@"mp.create_room.title", @"创建房间")
                                                                   message:MPLocalized(@"mp.create_room.message", @"输入房间信息")
                                                            preferredStyle:UIAlertControllerStyleAlert];

    // 文本框 1：房间名称
    [alert addTextFieldWithConfigurationHandler:^(UITextField *textField) {
        textField.placeholder = MPLocalized(@"mp.create_room.name.placeholder", @"房间名称（如：和朋友的生存世界）");
        textField.autocapitalizationType = UITextAutocapitalizationTypeNone;
        textField.autocorrectionType = UITextAutocorrectionTypeNo;
        textField.clearButtonMode = UITextFieldViewModeWhileEditing;
        textField.returnKeyType = UIReturnKeyNext;
    }];

    // 文本框 2：ZeroTier Network ID
    [alert addTextFieldWithConfigurationHandler:^(UITextField *textField) {
        textField.placeholder = MPLocalized(@"mp.create_room.network_id.placeholder", @"ZeroTier Network ID (16 位十六进制)");
        textField.autocapitalizationType = UITextAutocapitalizationTypeNone;
        textField.autocorrectionType = UITextAutocorrectionTypeNo;
        textField.keyboardType = UIKeyboardTypeASCIICapable;
        textField.clearButtonMode = UITextFieldViewModeWhileEditing;
        textField.returnKeyType = UIReturnKeyDone;
    }];

    // 取消按钮
    [alert addAction:[UIAlertAction actionWithTitle:MPLocalized(@"common.cancel", @"取消")
                                              style:UIAlertActionStyleCancel
                                            handler:nil]];

    // 创建按钮
    __weak typeof(self) weakSelf = self;
    [alert addAction:[UIAlertAction actionWithTitle:MPLocalized(@"mp.create_room.button", @"创建")
                                              style:UIAlertActionStyleDefault
                                            handler:^(UIAlertAction *action) {
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf) return;

        // 收集并校验输入
        UITextField *nameField = alert.textFields.firstObject;
        UITextField *networkIdField = alert.textFields.lastObject;

        NSString *name = [nameField.text stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
        NSString *networkId = [networkIdField.text stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];

        // 校验：房间名称
        if (name.length == 0) {
            [strongSelf showSimpleAlertWithTitle:MPLocalized(@"mp.create_room.error.title", @"输入不完整")
                                         message:MPLocalized(@"mp.create_room.error.name", @"请输入房间名称")];
            return;
        }

        // 校验：Network ID 非空
        if (networkId.length == 0) {
            [strongSelf showSimpleAlertWithTitle:MPLocalized(@"mp.create_room.error.title", @"输入不完整")
                                         message:MPLocalized(@"mp.create_room.error.network_id", @"请输入 ZeroTier Network ID")];
            return;
        }

        // 校验：Network ID 格式（16 位十六进制）
        if (![[MultiplayerManager sharedManager] isValidNetworkId:networkId]) {
            [strongSelf showSimpleAlertWithTitle:MPLocalized(@"mp.create_room.error.title", @"输入不完整")
                                         message:MPLocalized(@"mp.create_room.error.network_id_format", @"Network ID 格式不正确，应为 16 位十六进制")];
            return;
        }

        // 创建房间对象并保存
        MultiplayerRoom *room = [[MultiplayerRoom alloc] init];
        room.roomId = [[MultiplayerManager sharedManager] generateRoomId];
        room.name = name;
        room.networkId = networkId;
        room.hostIP = @"";
        room.hostPort = @"25565";
        room.roomDescription = @"";
        // ownerName 留空表示本地创建（房主）
        room.ownerName = @"";
        room.status = MultiplayerRoomStatusDisconnected;
        room.createdAt = [NSDate date];

        [[MultiplayerManager sharedManager] addRoom:room];
        [strongSelf refreshRooms];
    }]];

    [self presentViewController:alert animated:YES completion:nil];
}

#pragma mark - 加入房间

/// 点击"加入房间"按钮：根据输入的 Network ID 创建临时房间并连接
///
/// 流程：
///   1. 读取并校验 Network ID
///   2. 检查 ZeroTier 框架可用性
///   3. 如果该 Network ID 已存在于房间列表，复用之；否则创建临时房间（name=Network ID 前 8 位）
///   4. 如果当前已连接其他房间，先断开
///   5. 调用 connectToRoom:completion:
///   6. 连接成功后保存到房间列表（如果是新房间）
- (void)joinRoomTapped {
    [self.view endEditing:YES];

    NSString *networkId = [self.joinNetworkIdField.text stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];

    // 校验：Network ID 非空
    if (networkId.length == 0) {
        [self showSimpleAlertWithTitle:MPLocalized(@"mp.create_room.error.title", @"输入不完整")
                                message:MPLocalized(@"mp.create_room.error.network_id", @"请输入 ZeroTier Network ID")];
        return;
    }

    // 校验：Network ID 格式
    if (![[MultiplayerManager sharedManager] isValidNetworkId:networkId]) {
        [self showSimpleAlertWithTitle:MPLocalized(@"mp.create_room.error.title", @"输入不完整")
                                message:MPLocalized(@"mp.create_room.error.network_id_format", @"Network ID 格式不正确，应为 16 位十六进制")];
        return;
    }

    // 检查 ZeroTier 框架可用性
    if (![[MultiplayerManager sharedManager] isFrameworkAvailable]) {
        [self showSimpleAlertWithTitle:MPLocalized(@"mp.core.unavailable_title", @"联机核心不可用")
                                message:MPLocalized(@"mp.core.unavailable_msg", @"ZeroTier 联机核心未加载，无法加入房间。请使用包含真实 zt.framework 的构建版本。")];
        return;
    }

    // 检查是否已存在该 Network ID 的房间
    MultiplayerRoom *existingRoom = nil;
    for (MultiplayerRoom *r in self.rooms) {
        if ([r.networkId isEqualToString:networkId]) {
            existingRoom = r;
            break;
        }
    }

    MultiplayerRoom *room = existingRoom;
    BOOL isNewRoom = NO;
    if (!room) {
        // 创建临时房间对象：房间名取 Network ID 前 8 位
        room = [[MultiplayerRoom alloc] init];
        room.roomId = [[MultiplayerManager sharedManager] generateRoomId];
        room.name = networkId.length >= 8 ? [networkId substringToIndex:8] : networkId;
        room.networkId = networkId;
        room.hostIP = @"";
        room.hostPort = @"25565";
        room.roomDescription = @"";
        room.ownerName = @"";
        room.status = MultiplayerRoomStatusDisconnected;
        room.createdAt = [NSDate date];
        isNewRoom = YES;
    }

    // 如果该房间正在连接中，提示用户稍候
    if (room.status == MultiplayerRoomStatusConnecting) {
        [self showSimpleAlertWithTitle:MPLocalized(@"mp.connect.in_progress_title", @"正在连接")
                                message:MPLocalized(@"mp.connect.in_progress_msg", @"当前房间正在连接中，请稍候。")];
        return;
    }

    // 如果该房间已连接，提示用户
    if (room.status == MultiplayerRoomStatusConnected) {
        [self showSimpleAlertWithTitle:MPLocalized(@"mp.connect.already_connected_title", @"已连接")
                                message:MPLocalized(@"mp.connect.already_connected_msg", @"该房间已连接，无需重复连接。")];
        return;
    }

    // 如果当前已连接到其他房间，先断开
    MultiplayerRoom *currentRoom = [[MultiplayerManager sharedManager] currentRoom];
    if (currentRoom && ![currentRoom.networkId isEqualToString:networkId]) {
        [[MultiplayerManager sharedManager] disconnectCurrentRoom];
        currentRoom.status = MultiplayerRoomStatusDisconnected;
        [[MultiplayerManager sharedManager] updateRoom:currentRoom];
    }

    // 连接房间
    __weak typeof(self) weakSelf = self;
    __weak MultiplayerRoom *weakRoom = room;
    [self connectToRoom:room completion:^(BOOL success, NSError *error) {
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf) return;

        if (success) {
            // 连接成功后保存到房间列表（如果未保存过）
            if (isNewRoom) {
                [[MultiplayerManager sharedManager] addRoom:weakRoom];
            }
            [strongSelf refreshRooms];
        } else {
            // 连接失败：显示错误信息（临时房间不保存）
            [strongSelf showSimpleAlertWithTitle:MPLocalized(@"mp.connect.failed", @"连接失败")
                                         message:error.localizedDescription ?: MPLocalized(@"mp.connect.failed_msg", @"无法连接到房间，请检查 Network ID 是否正确以及网络是否畅通。")];
        }
    }];

    // 清空输入框，方便用户下次输入
    self.joinNetworkIdField.text = @"";
}

#pragma mark - 连接房间

/// 连接到指定房间
///
/// 内部调用 MultiplayerManager 的 connectToRoom:completion:，
/// 并在主线程更新房间状态和 UI。连接成功后显示操作引导（对标 FCL/HMCL）。
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

                // 连接成功后显示操作引导（对标 FCL/HMCL 连接成功后的提示）
                // 获取房主 ZeroTier IP（已由 MultiplayerManager 自动同步到 room.hostIP）
                NSString *hostIP = room.hostIP.length ? room.hostIP : [[MultiplayerManager sharedManager] currentLocalIP];
                NSString *hostPort = room.hostPort.length ? room.hostPort : @"25565";
                NSString *serverAddress = [NSString stringWithFormat:@"%@:%@", hostIP, hostPort];

                NSString *successMsg = [NSString stringWithFormat:@"%@\n\n%@\n%@\n\n%@",
                    MPLocalized(@"mp.connect.success_msg", @"ZeroTier 联机网络已连接，SOCKS5 代理已启动"),
                    MPLocalized(@"mp.connect.guide_host", @"房主：启动游戏并开放局域网（或运行服务器），点击分享按钮将地址发给朋友"),
                    [NSString stringWithFormat:@"%@: %@",
                        MPLocalized(@"mp.connect.guide_join", @"加入者：启动游戏，在 MC 中添加服务器"),
                        serverAddress],
                    MPLocalized(@"mp.connect.guide_share", @"点击房间可分享、断开连接或查看详情")];
                [strongSelf showSimpleAlertWithTitle:MPLocalized(@"mp.connect.success_title", @"连接成功")
                                              message:successMsg];
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

#pragma mark - 断开房间

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

    // 分享房间按钮
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

#pragma mark - 快速直连

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

#pragma mark - MultiplayerManagerDelegate

/// ZeroTier 节点已上线：刷新房间列表（状态点可能需要更新）
- (void)multiplayerNodeOnline {
    [self refreshRooms];
}

/// ZeroTier 节点已离线：刷新房间列表
- (void)multiplayerNodeOffline {
    [self refreshRooms];
}

/// 指定房间已连接成功：刷新房间列表
- (void)multiplayerRoomConnected:(MultiplayerRoom *)room {
    [self refreshRooms];
}

/// 指定房间连接失败：刷新房间列表
- (void)multiplayerRoom:(MultiplayerRoom *)room didFailWithError:(NSError *)error {
    [self refreshRooms];
}

/// ZeroTier 框架可用性检测结果：刷新房间列表
- (void)multiplayerFrameworkAvailabilityChecked:(BOOL)available {
    [self refreshRooms];
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
        [self presentViewController:alert animated:YES completion:nil];
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
    if (textField == self.joinNetworkIdField) {
        // 在加入房间输入框按 Return 直接触发加入
        [self joinRoomTapped];
    } else {
        [textField resignFirstResponder];
    }
    return YES;
}

#pragma mark - UITableViewDataSource

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView {
    return 3;
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    switch (section) {
        case 0:
            // 加入房间：Network ID 输入框 + 加入按钮
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

- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section {
    switch (section) {
        case 0:
            return MPLocalized(@"mp.section.join", @"加入房间");
        case 1:
            return MPLocalized(@"mp.section.rooms", @"我的房间");
        case 2:
            return MPLocalized(@"mp.section.direct", @"直连");
        default:
            return nil;
    }
}

- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section {
    switch (section) {
        case 0:
            return MPLocalized(@"mp.section.join_footer", @"输入 16 位 ZeroTier Network ID，点击加入房间即可联机");
        case 2:
            return MPLocalized(@"mp.section.direct_footer", @"输入朋友的 ZeroTier IP 地址和端口，直接加入游戏");
        default:
            return nil;
    }
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    switch (indexPath.section) {
        case 0:
            return [self cellForJoinSectionAtRow:indexPath.row];
        case 1:
            return [self cellForRoomsSectionAtRow:indexPath.row];
        case 2:
            return [self cellForDirectSectionAtRow:indexPath.row];
        default:
            return [UITableViewCell new];
    }
}

/// Section 0「加入房间」的 cell 配置
/// @param row 行号（0=Network ID 输入框，1=加入按钮）
- (UITableViewCell *)cellForJoinSectionAtRow:(NSInteger)row {
    if (row == 0) {
        // Network ID 输入框行
        UITableViewCell *cell = [self.tableView dequeueReusableCellWithIdentifier:@"JoinInputCell"];
        cell.selectionStyle = UITableViewCellSelectionStyleNone;

        // 懒初始化 textField
        if (!self.joinNetworkIdField) {
            self.joinNetworkIdField = [[UITextField alloc] init];
            self.joinNetworkIdField.placeholder = MPLocalized(@"mp.join.network_id_placeholder", @"ZeroTier Network ID (16 位十六进制)");
            self.joinNetworkIdField.font = [UIFont systemFontOfSize:15];
            self.joinNetworkIdField.autocapitalizationType = UITextAutocapitalizationTypeNone;
            self.joinNetworkIdField.autocorrectionType = UITextAutocorrectionTypeNo;
            self.joinNetworkIdField.keyboardType = UIKeyboardTypeASCIICapable;
            self.joinNetworkIdField.clearButtonMode = UITextFieldViewModeWhileEditing;
            self.joinNetworkIdField.returnKeyType = UIReturnKeyDone;
            self.joinNetworkIdField.delegate = self;
            self.joinNetworkIdField.translatesAutoresizingMaskIntoConstraints = NO;
        }

        // 若 textField 已在别的 cell 上（cell 复用场景），先移除
        if (self.joinNetworkIdField.superview && self.joinNetworkIdField.superview != cell.contentView) {
            [self.joinNetworkIdField removeFromSuperview];
        }
        if (!self.joinNetworkIdField.superview) {
            [cell.contentView addSubview:self.joinNetworkIdField];
            [NSLayoutConstraint activateConstraints:@[
                [self.joinNetworkIdField.leadingAnchor constraintEqualToAnchor:cell.contentView.leadingAnchor constant:16],
                [self.joinNetworkIdField.trailingAnchor constraintEqualToAnchor:cell.contentView.trailingAnchor constant:-16],
                [self.joinNetworkIdField.topAnchor constraintEqualToAnchor:cell.contentView.topAnchor constant:12],
                [self.joinNetworkIdField.bottomAnchor constraintEqualToAnchor:cell.contentView.bottomAnchor constant:-12],
            ]];
        }

        // 适配自定义背景：有背景时使用白色文字
        if ([[BackgroundManager sharedManager] hasBackground]) {
            self.joinNetworkIdField.textColor = [UIColor whiteColor];
        } else {
            self.joinNetworkIdField.textColor = [UIColor labelColor];
        }

        [[BackgroundManager sharedManager] applyEffectToCell:cell];
        return cell;
    } else {
        // 加入房间按钮行
        UITableViewCell *cell = [self.tableView dequeueReusableCellWithIdentifier:@"ButtonCell"];
        cell.selectionStyle = UITableViewCellSelectionStyleNone;
        cell.textLabel.text = MPLocalized(@"mp.join.button", @"加入房间");
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
        // 已连接时显示完整服务器地址（对标 FCL/HMCL，让房主能直接看到并分享给朋友）
        // 房主的 hostIP 已由 MultiplayerManager.connectToRoomFlow: 自动同步为本机 ZeroTier IP
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

        // 懒初始化冒号分隔标签（与 textField 不同，colonLabel 没有 superview 引用问题，直接放在 cell 上）
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

#pragma mark - UITableViewDelegate

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];

    switch (indexPath.section) {
        case 0:
            if (indexPath.row == 0) {
                // 点击输入框行：让输入框获得焦点
                [self.joinNetworkIdField becomeFirstResponder];
            } else if (indexPath.row == 1) {
                // 点击加入房间按钮
                [self joinRoomTapped];
            }
            break;
        case 1:
            if (self.rooms.count == 0) {
                // 空状态：引导用户创建房间
                [self createRoomTapped];
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

- (CGFloat)tableView:(UITableView *)tableView heightForRowAtIndexPath:(NSIndexPath *)indexPath {
    if (indexPath.section == 0) {
        // Network ID 输入框行 / 加入按钮行
        return 48;
    }
    if (indexPath.section == 1) {
        if (self.rooms.count == 0) {
            // 空状态提示行
            return 60;
        }
        // 房间行：subtitle 显示 2 行，需要更多空间
        return 76;
    }
    if (indexPath.section == 2) {
        // IP+端口输入行 / 加入按钮行
        return 48;
    }
    return UITableViewAutomaticDimension;
}

@end
