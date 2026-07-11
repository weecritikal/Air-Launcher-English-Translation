//
//  MultiplayerViewController.m
//  Amethyst
//
//  MC 联机界面实现（参照 FCL 和 ZL2 风格）
//
//  本文件实现基于 ZeroTier 的 Minecraft 联机功能界面，主要包含：
//
//  1. ZeroTier 状态卡片（Section 0）
//     - 检测 ZeroTier One app 是否已安装
//     - 显示安装状态（绿色/红色指示灯）
//     - 点击跳转至 ZeroTier One app 或 App Store
//
//  2. 联机房间列表（Section 1）
//     - 展示所有已保存的联机房间
//     - 每个房间显示名称、Network ID、IP:端口、连接状态
//     - 支持连接/断开、编辑、分享、删除操作
//     - 右上角 + 按钮创建新房间
//     - 空状态提示
//
//  3. 快速直连（Section 2）
//     - IP 地址输入框
//     - 端口输入框 + 加入游戏按钮
//     - 直接将服务器地址写入当前 profile，启动游戏后自动加入
//
//  自定义 Cell：
//  - MultiplayerStatusCell：ZeroTier 状态展示
//  - MultiplayerRoomCell：房间列表项
//  - MultiplayerInputCell：直连输入框
//
//  背景适配：
//  - 通过 BackgroundManager 透明化视图控制器
//  - 监听 BackgroundUIEffectChanged 通知动态刷新
//  - 有自定义背景时使用白色文字，无背景时使用系统默认色
//

#import "MultiplayerViewController.h"
#import "MultiplayerManager.h"
#import "BackgroundManager.h"
#import "LauncherPreferences.h"
#import "PLProfiles.h"
#import "LanPortDetector.h"

#pragma mark - MultiplayerStatusCell

/// ZeroTier 状态展示 Cell（Section 0）
/// 左侧图标 + 中间标题/副标题 + 右侧状态指示灯
@interface MultiplayerStatusCell : UITableViewCell

@property (nonatomic, strong) UIView *iconView;
@property (nonatomic, strong) UIImageView *iconImageView;
@property (nonatomic, strong) UILabel *titleLabel;
@property (nonatomic, strong) UILabel *subtitleLabel;
@property (nonatomic, strong) UIView *statusDot;

- (void)configureWithInstalled:(BOOL)installed;

@end

@implementation MultiplayerStatusCell

- (instancetype)initWithStyle:(UITableViewCellStyle)style reuseIdentifier:(NSString *)reuseIdentifier {
    self = [super initWithStyle:style reuseIdentifier:reuseIdentifier];
    if (self) {
        self.backgroundColor = [UIColor secondarySystemGroupedBackgroundColor];
        [self setupSubviews];
    }
    return self;
}

- (void)setupSubviews {
    // 左侧图标容器：40x40 圆角方块，蓝色背景
    _iconView = [[UIView alloc] init];
    _iconView.translatesAutoresizingMaskIntoConstraints = NO;
    _iconView.backgroundColor = [UIColor systemBlueColor];
    _iconView.layer.cornerRadius = 10;
    _iconView.layer.masksToBounds = YES;
    [self.contentView addSubview:_iconView];

    // 图标：SF Symbol network，白色
    _iconImageView = [[UIImageView alloc] init];
    _iconImageView.translatesAutoresizingMaskIntoConstraints = NO;
    _iconImageView.image = [UIImage systemImageNamed:@"antenna.radiowaves.left.and.right"];
    _iconImageView.tintColor = [UIColor whiteColor];
    _iconImageView.contentMode = UIViewContentModeScaleAspectFit;
    [_iconView addSubview:_iconImageView];

    // 标题：16pt semibold
    _titleLabel = [[UILabel alloc] init];
    _titleLabel.translatesAutoresizingMaskIntoConstraints = NO;
    _titleLabel.font = [UIFont systemFontOfSize:16 weight:UIFontWeightSemibold];
    _titleLabel.text = @"ZeroTier 虚拟局域网";
    [self.contentView addSubview:_titleLabel];

    // 副标题：12pt secondary
    _subtitleLabel = [[UILabel alloc] init];
    _subtitleLabel.translatesAutoresizingMaskIntoConstraints = NO;
    _subtitleLabel.font = [UIFont systemFontOfSize:12];
    _subtitleLabel.textColor = [UIColor secondaryLabelColor];
    [self.contentView addSubview:_subtitleLabel];

    // 状态指示灯：10x10 圆形
    _statusDot = [[UIView alloc] init];
    _statusDot.translatesAutoresizingMaskIntoConstraints = NO;
    _statusDot.layer.cornerRadius = 5;
    _statusDot.layer.masksToBounds = YES;
    [self.contentView addSubview:_statusDot];

    [NSLayoutConstraint activateConstraints:@[
        [_iconView.leadingAnchor constraintEqualToAnchor:self.contentView.leadingAnchor constant:16],
        [_iconView.centerYAnchor constraintEqualToAnchor:self.contentView.centerYAnchor],
        [_iconView.widthAnchor constraintEqualToConstant:40],
        [_iconView.heightAnchor constraintEqualToConstant:40],

        [_iconImageView.centerXAnchor constraintEqualToAnchor:_iconView.centerXAnchor],
        [_iconImageView.centerYAnchor constraintEqualToAnchor:_iconView.centerYAnchor],
        [_iconImageView.widthAnchor constraintEqualToConstant:22],
        [_iconImageView.heightAnchor constraintEqualToConstant:22],

        [_titleLabel.leadingAnchor constraintEqualToAnchor:_iconView.trailingAnchor constant:12],
        [_titleLabel.topAnchor constraintEqualToAnchor:self.contentView.topAnchor constant:12],

        [_subtitleLabel.leadingAnchor constraintEqualToAnchor:_titleLabel.leadingAnchor],
        [_subtitleLabel.topAnchor constraintEqualToAnchor:_titleLabel.bottomAnchor constant:2],
        [_subtitleLabel.bottomAnchor constraintEqualToAnchor:self.contentView.bottomAnchor constant:-12],

        [_statusDot.trailingAnchor constraintEqualToAnchor:self.contentView.trailingAnchor constant:-16],
        [_statusDot.centerYAnchor constraintEqualToAnchor:self.contentView.centerYAnchor],
        [_statusDot.widthAnchor constraintEqualToConstant:10],
        [_statusDot.heightAnchor constraintEqualToConstant:10],

        [_titleLabel.trailingAnchor constraintEqualToAnchor:_statusDot.leadingAnchor constant:-12],
        [_subtitleLabel.trailingAnchor constraintEqualToAnchor:_statusDot.leadingAnchor constant:-12],
    ]];
}

- (void)configureWithInstalled:(BOOL)installed {
    if (installed) {
        self.subtitleLabel.text = @"已安装，点击打开";
        self.statusDot.backgroundColor = [UIColor systemGreenColor];
    } else {
        self.subtitleLabel.text = @"未安装，点击前往 App Store";
        self.statusDot.backgroundColor = [UIColor systemRedColor];
    }
    // 适配自定义背景：有背景时使用白色文字
    if ([[BackgroundManager sharedManager] hasBackground]) {
        self.titleLabel.textColor = [UIColor whiteColor];
        self.subtitleLabel.textColor = [UIColor whiteColor];
    } else {
        self.titleLabel.textColor = [UIColor labelColor];
        self.subtitleLabel.textColor = [UIColor secondaryLabelColor];
    }
}

@end

#pragma mark - MultiplayerRoomCell

/// 联机房间列表 Cell（Section 1）
/// 左侧房间图标 + 中间房间名/Network ID/IP:端口 + 右侧连接按钮
@interface MultiplayerRoomCell : UITableViewCell

@property (nonatomic, strong) UIView *iconView;
@property (nonatomic, strong) UIImageView *iconImageView;
@property (nonatomic, strong) UILabel *nameLabel;
@property (nonatomic, strong) UILabel *networkIdLabel;
@property (nonatomic, strong) UILabel *addressLabel;
@property (nonatomic, strong) UIButton *connectButton;
@property (nonatomic, strong) UIActivityIndicatorView *activityIndicator;

@property (nonatomic, copy) void (^onConnectTapped)(MultiplayerRoom *room);

@end

@implementation MultiplayerRoomCell

- (instancetype)initWithStyle:(UITableViewCellStyle)style reuseIdentifier:(NSString *)reuseIdentifier {
    self = [super initWithStyle:style reuseIdentifier:reuseIdentifier];
    if (self) {
        self.backgroundColor = [UIColor secondarySystemGroupedBackgroundColor];
        [self setupSubviews];
    }
    return self;
}

- (void)setupSubviews {
    // 左侧图标容器：36x36 圆角方块，绿色背景
    _iconView = [[UIView alloc] init];
    _iconView.translatesAutoresizingMaskIntoConstraints = NO;
    _iconView.backgroundColor = [UIColor systemGreenColor];
    _iconView.layer.cornerRadius = 10;
    _iconView.layer.masksToBounds = YES;
    [self.contentView addSubview:_iconView];

    // 图标：SF Symbol person.3.fill，白色
    _iconImageView = [[UIImageView alloc] init];
    _iconImageView.translatesAutoresizingMaskIntoConstraints = NO;
    _iconImageView.image = [UIImage systemImageNamed:@"person.3.fill"];
    _iconImageView.tintColor = [UIColor whiteColor];
    _iconImageView.contentMode = UIViewContentModeScaleAspectFit;
    [_iconView addSubview:_iconImageView];

    // 房间名：16pt semibold
    _nameLabel = [[UILabel alloc] init];
    _nameLabel.translatesAutoresizingMaskIntoConstraints = NO;
    _nameLabel.font = [UIFont systemFontOfSize:16 weight:UIFontWeightSemibold];
    [self.contentView addSubview:_nameLabel];

    // Network ID：12pt secondary，截断
    _networkIdLabel = [[UILabel alloc] init];
    _networkIdLabel.translatesAutoresizingMaskIntoConstraints = NO;
    _networkIdLabel.font = [UIFont systemFontOfSize:12];
    _networkIdLabel.textColor = [UIColor secondaryLabelColor];
    _networkIdLabel.lineBreakMode = NSLineBreakByTruncatingTail;
    [self.contentView addSubview:_networkIdLabel];

    // IP:端口：13pt secondary
    _addressLabel = [[UILabel alloc] init];
    _addressLabel.translatesAutoresizingMaskIntoConstraints = NO;
    _addressLabel.font = [UIFont systemFontOfSize:13];
    _addressLabel.textColor = [UIColor secondaryLabelColor];
    [self.contentView addSubview:_addressLabel];

    // 连接按钮：60pt 宽
    _connectButton = [UIButton buttonWithType:UIButtonTypeSystem];
    _connectButton.translatesAutoresizingMaskIntoConstraints = NO;
    _connectButton.titleLabel.font = [UIFont systemFontOfSize:14 weight:UIFontWeightMedium];
    _connectButton.layer.cornerRadius = 8;
    _connectButton.layer.masksToBounds = YES;
    [_connectButton addTarget:self action:@selector(connectButtonTapped) forControlEvents:UIControlEventTouchUpInside];
    [self.contentView addSubview:_connectButton];

    // 连接中指示器
    _activityIndicator = [[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleMedium];
    _activityIndicator.translatesAutoresizingMaskIntoConstraints = NO;
    _activityIndicator.hidesWhenStopped = YES;
    [self.contentView addSubview:_activityIndicator];

    [NSLayoutConstraint activateConstraints:@[
        [_iconView.leadingAnchor constraintEqualToAnchor:self.contentView.leadingAnchor constant:16],
        [_iconView.centerYAnchor constraintEqualToAnchor:self.contentView.centerYAnchor],
        [_iconView.widthAnchor constraintEqualToConstant:36],
        [_iconView.heightAnchor constraintEqualToConstant:36],

        [_iconImageView.centerXAnchor constraintEqualToAnchor:_iconView.centerXAnchor],
        [_iconImageView.centerYAnchor constraintEqualToAnchor:_iconView.centerYAnchor],
        [_iconImageView.widthAnchor constraintEqualToConstant:20],
        [_iconImageView.heightAnchor constraintEqualToConstant:20],

        [_nameLabel.leadingAnchor constraintEqualToAnchor:_iconView.trailingAnchor constant:12],
        [_nameLabel.topAnchor constraintEqualToAnchor:self.contentView.topAnchor constant:12],

        [_networkIdLabel.leadingAnchor constraintEqualToAnchor:_nameLabel.leadingAnchor],
        [_networkIdLabel.topAnchor constraintEqualToAnchor:_nameLabel.bottomAnchor constant:2],

        [_addressLabel.leadingAnchor constraintEqualToAnchor:_nameLabel.leadingAnchor],
        [_addressLabel.topAnchor constraintEqualToAnchor:_networkIdLabel.bottomAnchor constant:2],
        [_addressLabel.bottomAnchor constraintEqualToAnchor:self.contentView.bottomAnchor constant:-12],

        // 连接按钮右侧固定
        [_connectButton.trailingAnchor constraintEqualToAnchor:self.contentView.trailingAnchor constant:-16],
        [_connectButton.centerYAnchor constraintEqualToAnchor:self.contentView.centerYAnchor],
        [_connectButton.widthAnchor constraintEqualToConstant:72],
        [_connectButton.heightAnchor constraintEqualToConstant:32],

        [_activityIndicator.centerXAnchor constraintEqualToAnchor:_connectButton.centerXAnchor],
        [_activityIndicator.centerYAnchor constraintEqualToAnchor:_connectButton.centerYAnchor],

        // 中间文字不延伸到按钮
        [_nameLabel.trailingAnchor constraintEqualToAnchor:_connectButton.leadingAnchor constant:-8],
        [_networkIdLabel.trailingAnchor constraintEqualToAnchor:_connectButton.leadingAnchor constant:-8],
        [_addressLabel.trailingAnchor constraintEqualToAnchor:_connectButton.leadingAnchor constant:-8],
    ]];
}

- (void)connectButtonTapped {
    if (self.onConnectTapped) {
        // 通过titleLabel找到对应room比较复杂，这里使用 associated pattern
        // 实际由 controller 在 configure 时注入 room
        self.onConnectTapped(nil);
    }
}

- (void)configureWithRoom:(MultiplayerRoom *)room {
    self.nameLabel.text = room.name.length ? room.name : @"未命名房间";
    self.networkIdLabel.text = [NSString stringWithFormat:@"Network ID: %@", room.networkId ?: @"-"];
    self.addressLabel.text = [NSString stringWithFormat:@"%@:%@", room.hostIP ?: @"-", room.hostPort ?: @"25565"];

    BOOL hasBackground = [[BackgroundManager sharedManager] hasBackground];

    switch (room.status) {
        case MultiplayerRoomStatusDisconnected:
            [self.connectButton setTitle:@"连接" forState:UIControlStateNormal];
            [self.connectButton setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
            self.connectButton.backgroundColor = [UIColor systemBlueColor];
            [self.connectButton setHidden:NO];
            [self.activityIndicator stopAnimating];
            break;
        case MultiplayerRoomStatusConnecting:
            [self.connectButton setTitle:@"连接中" forState:UIControlStateNormal];
            [self.connectButton setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
            self.connectButton.backgroundColor = [UIColor systemGrayColor];
            [self.connectButton setHidden:NO];
            [self.activityIndicator startAnimating];
            break;
        case MultiplayerRoomStatusConnected:
            [self.connectButton setTitle:@"已连接" forState:UIControlStateNormal];
            [self.connectButton setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
            self.connectButton.backgroundColor = [UIColor systemGreenColor];
            [self.connectButton setHidden:NO];
            [self.activityIndicator stopAnimating];
            break;
        case MultiplayerRoomStatusError:
            [self.connectButton setTitle:@"重试" forState:UIControlStateNormal];
            [self.connectButton setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
            self.connectButton.backgroundColor = [UIColor systemOrangeColor];
            [self.connectButton setHidden:NO];
            [self.activityIndicator stopAnimating];
            break;
    }

    // 适配自定义背景
    if (hasBackground) {
        self.nameLabel.textColor = [UIColor whiteColor];
        self.networkIdLabel.textColor = [UIColor whiteColor];
        self.addressLabel.textColor = [UIColor whiteColor];
    } else {
        self.nameLabel.textColor = [UIColor labelColor];
        self.networkIdLabel.textColor = [UIColor secondaryLabelColor];
        self.addressLabel.textColor = [UIColor secondaryLabelColor];
    }
}

@end

#pragma mark - MultiplayerInputCell

/// 快速直连输入 Cell（Section 2）
/// 文本输入框 + 可选的尾部按钮
@interface MultiplayerInputCell : UITableViewCell <UITextFieldDelegate>

@property (nonatomic, strong) UIImageView *iconView;
@property (nonatomic, strong) UITextField *textField;
@property (nonatomic, strong) UIButton *trailingButton;
@property (nonatomic, strong) NSLayoutConstraint *textFieldTrailingConstraint;

@property (nonatomic, copy) void (^onTextChanged)(NSString *text);
@property (nonatomic, copy) void (^onButtonTapped)(NSString *text);

@end

@implementation MultiplayerInputCell

- (instancetype)initWithStyle:(UITableViewCellStyle)style reuseIdentifier:(NSString *)reuseIdentifier {
    self = [super initWithStyle:style reuseIdentifier:reuseIdentifier];
    if (self) {
        self.backgroundColor = [UIColor secondarySystemGroupedBackgroundColor];
        self.selectionStyle = UITableViewCellSelectionStyleNone;
        [self setupSubviews];
    }
    return self;
}

- (void)setupSubviews {
    // 可选图标
    _iconView = [[UIImageView alloc] init];
    _iconView.translatesAutoresizingMaskIntoConstraints = NO;
    _iconView.tintColor = [UIColor secondaryLabelColor];
    _iconView.contentMode = UIViewContentModeScaleAspectFit;
    _iconView.hidden = YES;
    [self.contentView addSubview:_iconView];

    // 输入框
    _textField = [[UITextField alloc] init];
    _textField.translatesAutoresizingMaskIntoConstraints = NO;
    _textField.delegate = self;
    _textField.font = [UIFont systemFontOfSize:15];
    _textField.clearButtonMode = UITextFieldViewModeWhileEditing;
    _textField.autocorrectionType = UITextAutocorrectionTypeNo;
    _textField.autocapitalizationType = UITextAutocapitalizationTypeNone;
    [self.contentView addSubview:_textField];

    // 尾部按钮（可选）
    _trailingButton = [UIButton buttonWithType:UIButtonTypeSystem];
    _trailingButton.translatesAutoresizingMaskIntoConstraints = NO;
    _trailingButton.titleLabel.font = [UIFont systemFontOfSize:14 weight:UIFontWeightMedium];
    _trailingButton.layer.cornerRadius = 8;
    _trailingButton.layer.masksToBounds = YES;
    _trailingButton.hidden = YES;
    [_trailingButton addTarget:self action:@selector(buttonTapped) forControlEvents:UIControlEventTouchUpInside];
    [self.contentView addSubview:_trailingButton];

    [NSLayoutConstraint activateConstraints:@[
        [_iconView.leadingAnchor constraintEqualToAnchor:self.contentView.leadingAnchor constant:16],
        [_iconView.centerYAnchor constraintEqualToAnchor:self.contentView.centerYAnchor],
        [_iconView.widthAnchor constraintEqualToConstant:22],
        [_iconView.heightAnchor constraintEqualToConstant:22],

        [_textField.leadingAnchor constraintEqualToAnchor:self.contentView.leadingAnchor constant:16],
        [_textField.centerYAnchor constraintEqualToAnchor:self.contentView.centerYAnchor],
        [_textField.topAnchor constraintEqualToAnchor:self.contentView.topAnchor constant:10],
        [_textField.bottomAnchor constraintEqualToAnchor:self.contentView.bottomAnchor constant:-10],

        [_trailingButton.trailingAnchor constraintEqualToAnchor:self.contentView.trailingAnchor constant:-16],
        [_trailingButton.centerYAnchor constraintEqualToAnchor:self.contentView.centerYAnchor],
        [_trailingButton.heightAnchor constraintEqualToConstant:32],
    ]];
}

- (void)buttonTapped {
    if (self.onButtonTapped) {
        self.onButtonTapped(self.textField.text ?: @"");
    }
}

- (void)configureWithPlaceholder:(NSString *)placeholder
                            text:(NSString *)text
                   keyboardType:(UIKeyboardType)keyboardType
                       hasButton:(BOOL)hasButton
                     buttonTitle:(NSString *)buttonTitle {
    self.textField.placeholder = placeholder;
    self.textField.text = text;
    self.textField.keyboardType = keyboardType;

    if (hasButton) {
        self.trailingButton.hidden = NO;
        [self.trailingButton setTitle:buttonTitle forState:UIControlStateNormal];
        [self.trailingButton setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
        self.trailingButton.backgroundColor = [UIColor systemBlueColor];
        // 设定按钮最小宽度
        [self.trailingButton.widthAnchor constraintGreaterThanOrEqualToConstant:80].active = YES;
        // 调整输入框右边距，给按钮留出空间：先移除旧约束再激活新约束
        if (self.textFieldTrailingConstraint) {
            self.textFieldTrailingConstraint.active = NO;
        }
        self.textFieldTrailingConstraint = [self.textField.trailingAnchor constraintEqualToAnchor:self.trailingButton.leadingAnchor constant:-12];
        self.textFieldTrailingConstraint.active = YES;
    } else {
        self.trailingButton.hidden = YES;
        // 无按钮时，输入框右边距贴到 contentView 右侧
        if (self.textFieldTrailingConstraint) {
            self.textFieldTrailingConstraint.active = NO;
        }
        self.textFieldTrailingConstraint = [self.textField.trailingAnchor constraintEqualToAnchor:self.contentView.trailingAnchor constant:-16];
        self.textFieldTrailingConstraint.active = YES;
    }

    // 适配自定义背景
    if ([[BackgroundManager sharedManager] hasBackground]) {
        self.textField.textColor = [UIColor whiteColor];
    } else {
        self.textField.textColor = [UIColor labelColor];
    }
}

#pragma mark - UITextFieldDelegate

- (BOOL)textField:(UITextField *)textField shouldChangeCharactersInRange:(NSRange)range replacementString:(NSString *)string {
    NSString *newText = [textField.text stringByReplacingCharactersInRange:range withString:string];
    if (self.onTextChanged) {
        self.onTextChanged(newText);
    }
    return YES;
}

- (BOOL)textFieldShouldReturn:(UITextField *)textField {
    if (self.onButtonTapped) {
        self.onButtonTapped(textField.text ?: @"");
    }
    return YES;
}

@end

#pragma mark - MultiplayerViewController

@interface MultiplayerViewController () <UITableViewDataSource, UITableViewDelegate>

@property (nonatomic, strong) UITableView *tableView;
@property (nonatomic, strong) NSArray<MultiplayerRoom *> *rooms;

// 快速直连输入缓存
@property (nonatomic, copy) NSString *directIP;
@property (nonatomic, copy) NSString *directPort;

@end

@implementation MultiplayerViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"联机";

    // 适配自定义启动器背景：透明化当前 VC，让全局背景图/毛玻璃透出
    [[BackgroundManager sharedManager] makeViewControllerTransparent:self];

    // 初始化数据
    self.rooms = [[MultiplayerManager sharedManager] savedRooms] ?: @[];
    self.directIP = @"";
    self.directPort = @"25565";

    [self setupUI];

    // 监听背景效果变化通知，背景切换时重新应用透明效果并刷新表格
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(refreshBackgroundEffect)
                                                 name:@"BackgroundUIEffectChanged"
                                               object:nil];
}

- (void)refreshBackgroundEffect {
    // 背景效果改变时重新透明化当前 VC 并刷新表格，让所有 cell 重新适配文字颜色
    dispatch_async(dispatch_get_main_queue(), ^{
        [[BackgroundManager sharedManager] makeViewControllerTransparent:self];
        self.tableView.backgroundColor = [UIColor clearColor];
        self.tableView.backgroundView = nil;
        // 重新应用导航栏毛玻璃效果
        [[BackgroundManager sharedManager] applyEffectToNavigationBar:self.navigationController.navigationBar];
        [self.tableView reloadData];
    });
}

- (void)dealloc {
    // 移除通知观察者，避免 dealloc 后收到通知导致崩溃
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

#pragma mark - UI Setup

- (void)setupUI {
    // 使用 InsetGrouped 风格，卡片式布局
    self.tableView = [[UITableView alloc] initWithFrame:CGRectZero style:UITableViewStyleInsetGrouped];
    self.tableView.translatesAutoresizingMaskIntoConstraints = NO;
    self.tableView.dataSource = self;
    self.tableView.delegate = self;
    self.tableView.backgroundColor = [UIColor clearColor];
    self.tableView.backgroundView = nil;
    self.tableView.separatorStyle = UITableViewCellSeparatorStyleNone;
    self.tableView.rowHeight = UITableViewAutomaticDimension;
    self.tableView.estimatedRowHeight = 72;
    // 注册自定义 cell
    [self.tableView registerClass:[MultiplayerStatusCell class] forCellReuseIdentifier:@"StatusCell"];
    [self.tableView registerClass:[MultiplayerRoomCell class] forCellReuseIdentifier:@"RoomCell"];
    [self.tableView registerClass:[MultiplayerInputCell class] forCellReuseIdentifier:@"InputCell"];
    [self.tableView registerClass:[UITableViewCell class] forCellReuseIdentifier:@"EmptyCell"];
    [self.view addSubview:self.tableView];

    [NSLayoutConstraint activateConstraints:@[
        [self.tableView.topAnchor constraintEqualToAnchor:self.view.topAnchor],
        [self.tableView.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor],
        [self.tableView.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [self.tableView.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
    ]];

    // 导航栏按钮：左上角关闭，右上角创建房间
    UIBarButtonItem *closeButton = [[UIBarButtonItem alloc] initWithImage:[UIImage systemImageNamed:@"xmark"]
                                                                     style:UIBarButtonItemStylePlain
                                                                    target:self
                                                                    action:@selector(closeTapped)];
    closeButton.accessibilityLabel = @"关闭";
    self.navigationItem.leftBarButtonItem = closeButton;

    UIBarButtonItem *addButton = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemAdd
                                                                               target:self
                                                                               action:@selector(addButtonTapped)];
    self.navigationItem.rightBarButtonItem = addButton;

    // 应用导航栏毛玻璃效果
    [[BackgroundManager sharedManager] applyEffectToNavigationBar:self.navigationController.navigationBar];
}

#pragma mark - Navigation Actions

- (void)closeTapped {
    // 兼容 push 和 present 两种容器
    if (self.navigationController && self.navigationController.viewControllers.firstObject != self) {
        [self.navigationController popViewControllerAnimated:YES];
    } else {
        [self dismissViewControllerAnimated:YES completion:nil];
    }
}

- (void)addButtonTapped {
    // 弹出 ActionSheet 让用户选择：创建房间 / 通过分享文本导入
    UIAlertController *sheet = [UIAlertController alertControllerWithTitle:nil
                                                                   message:@"添加联机房间"
                                                            preferredStyle:UIAlertControllerStyleActionSheet];

    [sheet addAction:[UIAlertAction actionWithTitle:@"创建新房间" style:UIAlertActionStyleDefault handler:^(UIAlertAction * _Nonnull action) {
        [self showCreateRoomDialog];
    }]];

    [sheet addAction:[UIAlertAction actionWithTitle:@"通过分享文本导入" style:UIAlertActionStyleDefault handler:^(UIAlertAction * _Nonnull action) {
        [self showImportRoomDialog];
    }]];

    [sheet addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];

    // iPad 适配：popover 指向 + 按钮
    if (sheet.popoverPresentationController) {
        sheet.popoverPresentationController.barButtonItem = self.navigationItem.rightBarButtonItem;
    }

    [self presentViewController:sheet animated:YES completion:nil];
}

#pragma mark - 创建房间

- (void)showCreateRoomDialog {
    // 检测 LAN 端口（FCL 风格：自动预填端口）
    LanPortDetector *detector = [LanPortDetector sharedDetector];
    NSString *detectedPort = detector.detectedPort ?: @"25565";
    NSString *portHint = @"";
    if (detector.detectedPort) {
        if (detector.source == LanPortSourceAuto) {
            portHint = [NSString stringWithFormat:@"已自动检测到 LAN 端口：%@", detector.detectedPort];
        } else {
            portHint = [NSString stringWithFormat:@"上次输入的端口：%@", detector.detectedPort];
        }
    }

    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"创建联机房间"
                                                                   message:portHint.length > 0 ? portHint : nil
                                                            preferredStyle:UIAlertControllerStyleAlert];

    // 1. 房间名称
    [alert addTextFieldWithConfigurationHandler:^(UITextField * _Nonnull textField) {
        textField.placeholder = @"如：和朋友的生存世界";
        textField.autocapitalizationType = UITextAutocapitalizationTypeNone;
        textField.autocorrectionType = UITextAutocorrectionTypeNo;
    }];

    // 2. ZeroTier Network ID
    [alert addTextFieldWithConfigurationHandler:^(UITextField * _Nonnull textField) {
        textField.placeholder = @"16位十六进制";
        textField.autocapitalizationType = UITextAutocapitalizationTypeNone;
        textField.autocorrectionType = UITextAutocorrectionTypeNo;
        textField.keyboardType = UIKeyboardTypeASCIICapable;
    }];

    // 3. 服务器 IP
    [alert addTextFieldWithConfigurationHandler:^(UITextField * _Nonnull textField) {
        textField.placeholder = @"如 10.147.17.1";
        textField.autocapitalizationType = UITextAutocapitalizationTypeNone;
        textField.autocorrectionType = UITextAutocorrectionTypeNo;
        textField.keyboardType = UIKeyboardTypeNumbersAndPunctuation;
    }];

    // 4. 端口（自动预填检测到的 LAN 端口）
    [alert addTextFieldWithConfigurationHandler:^(UITextField * _Nonnull textField) {
        textField.placeholder = @"25565";
        textField.text = detectedPort;
        textField.keyboardType = UIKeyboardTypeNumberPad;
    }];

    [alert addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];

    [alert addAction:[UIAlertAction actionWithTitle:@"创建" style:UIAlertActionStyleDefault handler:^(UIAlertAction * _Nonnull action) {
        NSString *name = alert.textFields[0].text;
        NSString *networkId = alert.textFields[1].text;
        NSString *ip = alert.textFields[2].text;
        NSString *port = alert.textFields[3].text;

        // 输入验证
        if (!name || name.length == 0) {
            [self showSimpleAlertWithTitle:@"提示" message:@"请输入房间名称"];
            return;
        }
        if (!networkId || networkId.length == 0) {
            [self showSimpleAlertWithTitle:@"提示" message:@"请输入 ZeroTier Network ID"];
            return;
        }
        if (!ip || ip.length == 0) {
            [self showSimpleAlertWithTitle:@"提示" message:@"请输入服务器 IP 地址"];
            return;
        }
        if (!port || port.length == 0) {
            port = @"25565";
        }

        // 保存端口到 LanPortDetector（下次创建房间时预填）
        [[LanPortDetector sharedDetector] setManualPort:port];

        // 创建房间对象
        MultiplayerRoom *room = [[MultiplayerRoom alloc] init];
        room.roomId = [[MultiplayerManager sharedManager] generateRoomId];
        room.name = name;
        room.networkId = networkId;
        room.hostIP = ip;
        room.hostPort = port;
        room.roomDescription = @"";
        room.status = MultiplayerRoomStatusDisconnected;
        room.createdAt = [NSDate date];

        // 保存到本地列表
        [[MultiplayerManager sharedManager] addRoom:room];

        // 刷新表格
        [self refreshRooms];
    }]];

    [self presentViewController:alert animated:YES completion:nil];
}

#pragma mark - 通过分享文本导入房间

- (void)showImportRoomDialog {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"通过分享文本导入"
                                                                   message:@"粘贴朋友分享的房间文本"
                                                            preferredStyle:UIAlertControllerStyleAlert];

    [alert addTextFieldWithConfigurationHandler:^(UITextField * _Nonnull textField) {
        textField.placeholder = @"粘贴分享文本";
        textField.autocapitalizationType = UITextAutocapitalizationTypeNone;
        textField.autocorrectionType = UITextAutocorrectionTypeNo;
        textField.clearButtonMode = UITextFieldViewModeWhileEditing;
    }];

    [alert addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];

    [alert addAction:[UIAlertAction actionWithTitle:@"导入" style:UIAlertActionStyleDefault handler:^(UIAlertAction * _Nonnull action) {
        NSString *shareText = alert.textFields[0].text;
        if (!shareText || shareText.length == 0) {
            [self showSimpleAlertWithTitle:@"提示" message:@"请粘贴分享文本"];
            return;
        }

        // 解析分享文本
        MultiplayerRoom *parsedRoom = [[MultiplayerManager sharedManager] parseRoomFromShareText:shareText];
        if (!parsedRoom) {
            [self showSimpleAlertWithTitle:@"导入失败" message:@"无法解析分享文本，请确认文本格式正确"];
            return;
        }

        // 补充房间 ID 和创建时间
        if (!parsedRoom.roomId || parsedRoom.roomId.length == 0) {
            parsedRoom.roomId = [[MultiplayerManager sharedManager] generateRoomId];
        }
        if (!parsedRoom.hostPort || parsedRoom.hostPort.length == 0) {
            parsedRoom.hostPort = @"25565";
        }
        parsedRoom.status = MultiplayerRoomStatusDisconnected;
        parsedRoom.createdAt = [NSDate date];

        // 保存到本地列表
        [[MultiplayerManager sharedManager] addRoom:parsedRoom];
        [self refreshRooms];

        [self showSimpleAlertWithTitle:@"导入成功" message:[NSString stringWithFormat:@"房间「%@」已添加", parsedRoom.name]];
    }]];

    [self presentViewController:alert animated:YES completion:nil];
}

#pragma mark - 房间详情 ActionSheet

- (void)showRoomDetailActionsForRoom:(MultiplayerRoom *)room {
    UIAlertController *sheet = [UIAlertController alertControllerWithTitle:room.name
                                                                   message:[NSString stringWithFormat:@"%@:%@", room.hostIP, room.hostPort]
                                                            preferredStyle:UIAlertControllerStyleActionSheet];

    // 连接/断开
    NSString *connectTitle = (room.status == MultiplayerRoomStatusConnected) ? @"断开连接" : @"连接房间";
    [sheet addAction:[UIAlertAction actionWithTitle:connectTitle style:UIAlertActionStyleDefault handler:^(UIAlertAction * _Nonnull action) {
        if (room.status == MultiplayerRoomStatusConnected) {
            [[MultiplayerManager sharedManager] disconnectCurrentRoom];
            room.status = MultiplayerRoomStatusDisconnected;
            [[MultiplayerManager sharedManager] updateRoom:room];
            [self refreshRooms];
        } else {
            [self connectToRoom:room completion:^(BOOL success, NSError *error) {
                if (success) {
                    [self refreshRooms];
                } else {
                    [self showSimpleAlertWithTitle:@"连接失败" message:error.localizedDescription ?: @"无法连接到房间"];
                }
            }];
        }
    }]];

    // 编辑房间
    [sheet addAction:[UIAlertAction actionWithTitle:@"编辑房间" style:UIAlertActionStyleDefault handler:^(UIAlertAction * _Nonnull action) {
        [self showEditRoomDialog:room];
    }]];

    // 分享房间
    [sheet addAction:[UIAlertAction actionWithTitle:@"分享房间" style:UIAlertActionStyleDefault handler:^(UIAlertAction * _Nonnull action) {
        NSString *shareText = [[MultiplayerManager sharedManager] shareTextForRoom:room];
        UIActivityViewController *activityVC = [[UIActivityViewController alloc] initWithActivityItems:@[shareText] applicationActivities:nil];
        // iPad 适配
        if (activityVC.popoverPresentationController) {
            activityVC.popoverPresentationController.sourceView = self.view;
            activityVC.popoverPresentationController.sourceRect = CGRectMake(self.view.bounds.size.width / 2.0, self.view.bounds.size.height / 2.0, 1, 1);
        }
        [self presentViewController:activityVC animated:YES completion:nil];
    }]];

    // 删除房间（destructive）
    [sheet addAction:[UIAlertAction actionWithTitle:@"删除房间" style:UIAlertActionStyleDestructive handler:^(UIAlertAction * _Nonnull action) {
        // 二次确认
        UIAlertController *confirm = [UIAlertController alertControllerWithTitle:@"确认删除"
                                                                          message:[NSString stringWithFormat:@"确定要删除房间「%@」吗？\n此操作无法撤销。", room.name]
                                                                   preferredStyle:UIAlertControllerStyleAlert];
        [confirm addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
        [confirm addAction:[UIAlertAction actionWithTitle:@"删除" style:UIAlertActionStyleDestructive handler:^(UIAlertAction * _Nonnull action) {
            [[MultiplayerManager sharedManager] removeRoom:room.roomId];
            [self refreshRooms];
        }]];
        [self presentViewController:confirm animated:YES completion:nil];
    }]];

    [sheet addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];

    // iPad 适配：popover 指向当前行
    if (sheet.popoverPresentationController) {
        sheet.popoverPresentationController.sourceView = self.view;
        sheet.popoverPresentationController.sourceRect = CGRectMake(self.view.bounds.size.width / 2.0, self.view.bounds.size.height / 2.0, 1, 1);
    }

    [self presentViewController:sheet animated:YES completion:nil];
}

#pragma mark - 编辑房间

- (void)showEditRoomDialog:(MultiplayerRoom *)room {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"编辑房间"
                                                                   message:nil
                                                            preferredStyle:UIAlertControllerStyleAlert];

    // 预填已有数据
    [alert addTextFieldWithConfigurationHandler:^(UITextField * _Nonnull textField) {
        textField.placeholder = @"如：和朋友的生存世界";
        textField.text = room.name;
        textField.autocapitalizationType = UITextAutocapitalizationTypeNone;
        textField.autocorrectionType = UITextAutocorrectionTypeNo;
    }];

    [alert addTextFieldWithConfigurationHandler:^(UITextField * _Nonnull textField) {
        textField.placeholder = @"16位十六进制";
        textField.text = room.networkId;
        textField.autocapitalizationType = UITextAutocapitalizationTypeNone;
        textField.autocorrectionType = UITextAutocorrectionTypeNo;
        textField.keyboardType = UIKeyboardTypeASCIICapable;
    }];

    [alert addTextFieldWithConfigurationHandler:^(UITextField * _Nonnull textField) {
        textField.placeholder = @"如 10.147.17.1";
        textField.text = room.hostIP;
        textField.autocapitalizationType = UITextAutocapitalizationTypeNone;
        textField.autocorrectionType = UITextAutocorrectionTypeNo;
        textField.keyboardType = UIKeyboardTypeNumbersAndPunctuation;
    }];

    [alert addTextFieldWithConfigurationHandler:^(UITextField * _Nonnull textField) {
        textField.placeholder = @"25565";
        textField.text = room.hostPort;
        textField.keyboardType = UIKeyboardTypeNumberPad;
    }];

    [alert addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];

    [alert addAction:[UIAlertAction actionWithTitle:@"保存" style:UIAlertActionStyleDefault handler:^(UIAlertAction * _Nonnull action) {
        NSString *name = alert.textFields[0].text;
        NSString *networkId = alert.textFields[1].text;
        NSString *ip = alert.textFields[2].text;
        NSString *port = alert.textFields[3].text;

        // 输入验证
        if (!name || name.length == 0) {
            [self showSimpleAlertWithTitle:@"提示" message:@"请输入房间名称"];
            return;
        }
        if (!networkId || networkId.length == 0) {
            [self showSimpleAlertWithTitle:@"提示" message:@"请输入 ZeroTier Network ID"];
            return;
        }
        if (!ip || ip.length == 0) {
            [self showSimpleAlertWithTitle:@"提示" message:@"请输入服务器 IP 地址"];
            return;
        }
        if (!port || port.length == 0) {
            port = @"25565";
        }

        // 更新房间对象
        room.name = name;
        room.networkId = networkId;
        room.hostIP = ip;
        room.hostPort = port;

        [[MultiplayerManager sharedManager] updateRoom:room];
        [self refreshRooms];
    }]];

    [self presentViewController:alert animated:YES completion:nil];
}

#pragma mark - 连接房间

- (void)connectToRoom:(MultiplayerRoom *)room completion:(void (^)(BOOL success, NSError *error))completion {
    // 先更新状态为连接中
    room.status = MultiplayerRoomStatusConnecting;
    [[MultiplayerManager sharedManager] updateRoom:room];
    [self refreshRooms];

    // 检查 ZeroTier One 是否已安装
    if (![[MultiplayerManager sharedManager] isZeroTierAppInstalled]) {
        room.status = MultiplayerRoomStatusError;
        [[MultiplayerManager sharedManager] updateRoom:room];
        [self refreshRooms];

        // 提示用户安装 ZeroTier One
        UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"需要 ZeroTier One"
                                                                       message:@"未检测到 ZeroTier One 应用，请先从 App Store 安装后再联机。"
                                                                preferredStyle:UIAlertControllerStyleAlert];
        [alert addAction:[UIAlertAction actionWithTitle:@"好" style:UIAlertActionStyleDefault handler:nil]];
        [self presentViewController:alert animated:YES completion:nil];

        if (completion) {
            NSError *error = [NSError errorWithDomain:@"Multiplayer" code:-1 userInfo:@{NSLocalizedDescriptionKey: @"未安装 ZeroTier One"}];
            completion(NO, error);
        }
        return;
    }

    // 调用管理器连接房间（内部会唤起 ZeroTier One app 加入网络）
    __weak typeof(self) weakSelf = self;
    [[MultiplayerManager sharedManager] connectToRoom:room completion:^(BOOL success, NSError * _Nullable error) {
        dispatch_async(dispatch_get_main_queue(), ^{
            __strong typeof(weakSelf) strongSelf = weakSelf;
            if (!strongSelf) return;

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

#pragma mark - 快速直连

- (void)joinDirectConnect {
    // 收起键盘
    [self.view endEditing:YES];

    NSString *ip = self.directIP;
    NSString *port = self.directPort;

    // 验证 IP
    if (!ip || ip.length == 0) {
        [self showSimpleAlertWithTitle:@"提示" message:@"请输入服务器 IP 地址"];
        return;
    }
    if (!port || port.length == 0) {
        port = @"25565";
    }

    // 验证 IP 格式（简单校验：包含点分十进制或 ZeroTier 风格地址）
    if (![self isValidIPAddress:ip]) {
        [self showSimpleAlertWithTitle:@"提示" message:@"IP 地址格式不正确，请检查输入"];
        return;
    }

    // 生成服务器地址 "IP:端口"
    NSString *serverAddress = [NSString stringWithFormat:@"%@:%@", ip, port];

    // 将服务器地址添加到当前 profile（使用 PLProfiles 现有 API）
    [self addServerToProfile:[PLProfiles current].selectedProfileName address:serverAddress];

    // 显示成功提示
    [self showSimpleAlertWithTitle:@"已添加服务器"
                           message:@"已添加服务器，请在游戏中点击\"多人游戏\"加入"];
}

/// 将服务器地址写入指定 profile（基于 PLProfiles 的 setServerIp:forProfile: 实现）
- (void)addServerToProfile:(NSString *)profileName address:(NSString *)address {
    if (!profileName || profileName.length == 0) {
        profileName = [PLProfiles current].selectedProfileName;
    }
    [[PLProfiles current] setServerIp:address forProfile:profileName];
}

#pragma mark - 工具方法

- (BOOL)isValidIPAddress:(NSString *)ip {
    if (!ip || ip.length == 0) return NO;
    // 简单校验：IPv4 点分十进制 或 域名
    NSArray *components = [ip componentsSeparatedByString:@"."];
    if (components.count == 4) {
        for (NSString *component in components) {
            NSInteger value = [component integerValue];
            if (value < 0 || value > 255) return NO;
        }
        return YES;
    }
    // 非标准 IP（如 ZeroTier 分配的地址也可能是域名形式），允许通过
    return ip.length > 0;
}

- (void)refreshRooms {
    dispatch_async(dispatch_get_main_queue(), ^{
        self.rooms = [[MultiplayerManager sharedManager] savedRooms] ?: @[];
        [self.tableView reloadData];
    });
}

- (void)showSimpleAlertWithTitle:(NSString *)title message:(NSString *)message {
    dispatch_async(dispatch_get_main_queue(), ^{
        UIAlertController *alert = [UIAlertController alertControllerWithTitle:title message:message preferredStyle:UIAlertControllerStyleAlert];
        [alert addAction:[UIAlertAction actionWithTitle:@"好" style:UIAlertActionStyleDefault handler:nil]];
        [self presentViewController:alert animated:YES completion:nil];
    });
}

#pragma mark - UITableViewDataSource

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView {
    return 3;
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    switch (section) {
        case 0:
            // ZeroTier 状态：1 行
            return 1;
        case 1:
            // 联机房间列表：至少 1 行（空状态提示）
            return MAX(1, (NSInteger)self.rooms.count);
        case 2:
            // 快速直连：IP + 端口
            return 2;
        default:
            return 0;
    }
}

- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section {
    switch (section) {
        case 0:
            return @"联机服务";
        case 1:
            return @"联机房间";
        case 2:
            return @"快速直连";
        default:
            return nil;
    }
}

- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section {
    if (section == 2) {
        return @"输入朋友的 ZeroTier IP 地址和端口，直接加入游戏";
    }
    return nil;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    switch (indexPath.section) {
        case 0: {
            // Section 0: ZeroTier 状态
            MultiplayerStatusCell *cell = [tableView dequeueReusableCellWithIdentifier:@"StatusCell" forIndexPath:indexPath];
            BOOL installed = [[MultiplayerManager sharedManager] isZeroTierAppInstalled];
            [cell configureWithInstalled:installed];
            [[BackgroundManager sharedManager] applyEffectToCell:cell];
            return cell;
        }
        case 1: {
            // Section 1: 联机房间列表
            if (self.rooms.count == 0) {
                // 空状态提示
                UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"EmptyCell" forIndexPath:indexPath];
                cell.textLabel.text = @"暂无联机房间，点击右上角 + 创建";
                cell.textLabel.textAlignment = NSTextAlignmentCenter;
                cell.textLabel.textColor = [UIColor secondaryLabelColor];
                cell.textLabel.font = [UIFont systemFontOfSize:14];
                cell.selectionStyle = UITableViewCellSelectionStyleNone;
                cell.backgroundColor = [UIColor secondarySystemGroupedBackgroundColor];
                [[BackgroundManager sharedManager] applyEffectToCell:cell];
                return cell;
            }

            MultiplayerRoomCell *cell = [tableView dequeueReusableCellWithIdentifier:@"RoomCell" forIndexPath:indexPath];
            MultiplayerRoom *room = self.rooms[indexPath.row];
            [cell configureWithRoom:room];

            // 注入连接按钮回调
            __weak typeof(self) weakSelf = self;
            __weak MultiplayerRoom *weakRoom = room;
            cell.onConnectTapped = ^(MultiplayerRoom *tappedRoom) {
                __strong typeof(weakSelf) strongSelf = weakSelf;
                MultiplayerRoom *targetRoom = tappedRoom ?: weakRoom;
                if (!strongSelf || !targetRoom) return;
                if (targetRoom.status == MultiplayerRoomStatusConnected) {
                    // 已连接则断开
                    [[MultiplayerManager sharedManager] disconnectCurrentRoom];
                    targetRoom.status = MultiplayerRoomStatusDisconnected;
                    [[MultiplayerManager sharedManager] updateRoom:targetRoom];
                    [strongSelf refreshRooms];
                } else {
                    // 未连接则连接
                    [strongSelf connectToRoom:targetRoom completion:^(BOOL success, NSError *error) {
                        if (!success) {
                            [strongSelf showSimpleAlertWithTitle:@"连接失败" message:error.localizedDescription ?: @"无法连接到房间"];
                        }
                    }];
                }
            };

            [[BackgroundManager sharedManager] applyEffectToCell:cell];
            return cell;
        }
        case 2: {
            // Section 2: 快速直连
            MultiplayerInputCell *cell = [tableView dequeueReusableCellWithIdentifier:@"InputCell" forIndexPath:indexPath];
            if (indexPath.row == 0) {
                // IP 地址输入框
                [cell configureWithPlaceholder:@"如 10.147.17.1"
                                          text:self.directIP
                                 keyboardType:UIKeyboardTypeNumbersAndPunctuation
                                     hasButton:NO
                                   buttonTitle:nil];
                __weak typeof(self) weakSelf = self;
                cell.onTextChanged = ^(NSString *text) {
                    __strong typeof(weakSelf) strongSelf = weakSelf;
                    if (strongSelf) {
                        strongSelf.directIP = text;
                    }
                };
            } else {
                // 端口输入框 + 加入游戏按钮
                [cell configureWithPlaceholder:@"25565"
                                          text:self.directPort
                                 keyboardType:UIKeyboardTypeNumberPad
                                     hasButton:YES
                                   buttonTitle:@"加入游戏"];
                __weak typeof(self) weakSelf = self;
                cell.onTextChanged = ^(NSString *text) {
                    __strong typeof(weakSelf) strongSelf = weakSelf;
                    if (strongSelf) {
                        strongSelf.directPort = text;
                    }
                };
                cell.onButtonTapped = ^(NSString *text) {
                    __strong typeof(weakSelf) strongSelf = weakSelf;
                    if (strongSelf) {
                        strongSelf.directPort = text;
                        [strongSelf joinDirectConnect];
                    }
                };
            }
            [[BackgroundManager sharedManager] applyEffectToCell:cell];
            return cell;
        }
        default:
            return [UITableViewCell new];
    }
}

#pragma mark - UITableViewDelegate

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];

    switch (indexPath.section) {
        case 0: {
            // 点击 ZeroTier 状态行
            BOOL installed = [[MultiplayerManager sharedManager] isZeroTierAppInstalled];
            BOOL overridden = [[MultiplayerManager sharedManager] isZeroTierInstallOverridden];

            if (installed && !overridden) {
                // 已安装（自动检测到）：直接打开
                [[MultiplayerManager sharedManager] openZeroTierApp];
            } else if (overridden) {
                // 用户手动确认已安装：尝试打开，失败则提示
                [[MultiplayerManager sharedManager] openZeroTierApp];
            } else {
                // 未检测到：弹出选项让用户选择
                [self showZeroTierNotInstalledOptions:indexPath];
            }
            break;
        }
        case 1: {
            // 点击房间行：弹出详情 ActionSheet
            if (self.rooms.count == 0) {
                // 空状态，提示创建
                [self addButtonTapped];
                return;
            }
            MultiplayerRoom *room = self.rooms[indexPath.row];
            [self showRoomDetailActionsForRoom:room];
            break;
        }
        case 2: {
            // 点击直连输入行：让输入框获得焦点
            MultiplayerInputCell *cell = [tableView cellForRowAtIndexPath:indexPath];
            [cell.textField becomeFirstResponder];
            break;
        }
        default:
            break;
    }
}

/// 显示 ZeroTier 未安装时的选项（FCL 风格）
/// 提供"前往 App Store"、"手动确认已安装"两个选项
/// 后者用于通过 NB 助手/TrollStore 等非 App Store 方式安装的情况
- (void)showZeroTierNotInstalledOptions:(NSIndexPath *)indexPath {
    UIAlertController *sheet = [UIAlertController alertControllerWithTitle:nil
                                                                   message:@"未检测到 ZeroTier One。\n如果你已通过 NB 助手等工具安装，请选择\"手动确认已安装\"。"
                                                            preferredStyle:UIAlertControllerStyleActionSheet];

    [sheet addAction:[UIAlertAction actionWithTitle:@"前往 App Store 安装" style:UIAlertActionStyleDefault handler:^(UIAlertAction * _Nonnull action) {
        [[MultiplayerManager sharedManager] openZeroTierApp];
    }]];

    [sheet addAction:[UIAlertAction actionWithTitle:@"手动确认已安装" style:UIAlertActionStyleDefault handler:^(UIAlertAction * _Nonnull action) {
        // 设置用户偏好覆盖
        [[MultiplayerManager sharedManager] setZeroTierInstalledOverride:YES];
        // 刷新状态
        [self.tableView reloadRowsAtIndexPaths:@[indexPath] withRowAnimation:UITableViewRowAnimationAutomatic];
        // 尝试打开 ZeroTier
        [[MultiplayerManager sharedManager] openZeroTierApp];
    }]];

    [sheet addAction:[UIAlertAction actionWithTitle:@"取消手动确认" style:UIAlertActionStyleDestructive handler:^(UIAlertAction * _Nonnull action) {
        // 取消手动覆盖
        [[MultiplayerManager sharedManager] setZeroTierInstalledOverride:NO];
        [self.tableView reloadRowsAtIndexPaths:@[indexPath] withRowAnimation:UITableViewRowAnimationAutomatic];
    }]];

    [sheet addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];

    // iPad 适配
    if (sheet.popoverPresentationController) {
        UITableViewCell *cell = [self.tableView cellForRowAtIndexPath:indexPath];
        if (cell) {
            sheet.popoverPresentationController.sourceView = cell.contentView;
            sheet.popoverPresentationController.sourceRect = cell.contentView.bounds;
        }
    }

    [self presentViewController:sheet animated:YES completion:nil];
}

- (CGFloat)tableView:(UITableView *)tableView heightForRowAtIndexPath:(NSIndexPath *)indexPath {
    if (indexPath.section == 0) {
        return 64;
    }
    if (indexPath.section == 1) {
        if (self.rooms.count == 0) {
            return 60;
        }
        return 76;
    }
    if (indexPath.section == 2) {
        return 52;
    }
    return UITableViewAutomaticDimension;
}

@end
