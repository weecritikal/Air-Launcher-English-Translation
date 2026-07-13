//
//  MultiplayerViewController.m
//  Amethyst
//
//  MC 联机界面实现（参照 FCL 和 HMCL 联机界面风格重制版）
//
//  本文件实现基于 ZeroTier 的 Minecraft 联机功能界面，主要包含：
//
//  1. ZeroTier 状态卡片（Section 0，MultiplayerStatusCell）
//     - 检测 ZeroTier 联机核心是否可用（zt.framework 非 stub）
//     - 显示 ZeroTier 节点 ID（如果已上线）
//     - 显示当前本地 IP 地址（在 ZeroTier 网络中分配到的 IP）
//     - 显示已连接的 ZeroTier 网络数量
//     - 提供"刷新状态"按钮，手动刷新节点信息
//     - 通过 MultiplayerManagerDelegate 实时接收节点/网络状态变化
//
//  2. 联机房间列表（Section 1，MultiplayerRoomCell）
//     - 展示所有已保存的联机房间
//     - 每个房间显示名称、Network ID、IP:端口、连接状态
//     - 增加房间状态指示点（连接中/已连接/断开/错误）
//     - 增加房主/成员标识徽章
//     - 增加在线人数显示（已连接时为 1，否则为 0）
//     - 连接按钮采用更醒目的设计（圆角 + 状态色）
//     - 支持连接/断开、编辑、分享、删除操作
//     - 右上角 + 按钮创建新房间，扫描按钮扫描/导入房间
//     - 空状态提示
//
//  3. 快速直连（Section 2，MultiplayerInputCell）
//     - IP 地址输入框
//     - 端口输入框 + 加入游戏按钮
//     - 直接将服务器地址写入当前 profile，启动游戏后自动加入
//
//  自定义 ViewController（内联实现，不单独拆分文件）：
//  - CreateRoomViewController：创建/编辑房间的卡片式表单界面
//    · 房间名称、ZeroTier Network ID、服务器地址、端口、服务器密码
//    · 卡片式布局，圆角输入框，底部带渐变色的创建按钮
//    · 支持创建模式与编辑模式（编辑模式预填已有数据）
//    · 自动检测 LAN 端口并预填
//  - ScanImportRoomViewController：扫描/粘贴导入房间界面
//    · 多行文本输入框，支持粘贴分享文本或二维码扫描内容
//    · 一键从剪贴板粘贴
//    · 实时解析预览房间信息
//    · 底部带渐变色的导入按钮
//
//  自定义 Cell：
//  - MultiplayerStatusCell：ZeroTier 状态展示（含节点 ID/IP/网络数/刷新按钮）
//  - MultiplayerRoomCell：房间列表项（含状态点/房主徽章/在线人数）
//  - MultiplayerInputCell：直连输入框
//
//  背景适配：
//  - 通过 BackgroundManager 透明化视图控制器
//  - 监听 BackgroundUIEffectChanged 通知动态刷新
//  - 有自定义背景时使用白色文字，无背景时使用系统默认色
//
//  本地化：
//  - 所有新增 UI 文本通过 MPLocalized() 宏进行本地化包装
//  - MPLocalized() 优先使用 localize() 查找本地化资源，
//    若未找到则回退到传入的中文 fallback，保证用户可见文本始终可读
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

#pragma mark - MultiplayerStatusCell

/// ZeroTier 状态展示 Cell（Section 0）
///
/// 布局结构（参照 FCL 状态卡片风格）：
///   ┌──────────────────────────────────────────────────────┐
///   │ [icon]  ZeroTier 虚拟局域网            [●]  [刷新]   │
///   │         联机核心已加载，可直接连接房间               │
///   │         节点 ID: xxxxxx · IP: x.x.x.x · 网络: 1      │
///   └──────────────────────────────────────────────────────┘
///
/// - 左侧：40x40 圆角图标（蓝色背景 + 白色 SF Symbol）
/// - 中间上：标题（16pt semibold）
/// - 中间中：副标题（12pt secondary，描述当前状态）
/// - 中间下：信息行（12pt tertiary，节点 ID/IP/网络数）
/// - 右侧上：状态指示灯（10x10 圆形，绿/灰/红）
/// - 右侧下：刷新按钮（28x28 圆形，带 refresh SF Symbol）
@interface MultiplayerStatusCell : UITableViewCell

/// 左侧图标容器（40x40 圆角方块）
@property (nonatomic, strong) UIView *iconView;
/// 图标内容（SF Symbol network）
@property (nonatomic, strong) UIImageView *iconImageView;
/// 标题标签
@property (nonatomic, strong) UILabel *titleLabel;
/// 副标题标签（状态描述）
@property (nonatomic, strong) UILabel *subtitleLabel;
/// 底部信息标签（节点 ID/IP/网络数）
@property (nonatomic, strong) UILabel *infoLabel;
/// 状态指示灯
@property (nonatomic, strong) UIView *statusDot;
/// 刷新按钮
@property (nonatomic, strong) UIButton *refreshButton;

/// 刷新按钮回调
@property (nonatomic, copy) void (^onRefreshTapped)(void);

/// 配置 Cell
/// @param available ZeroTier 联机核心是否可用
/// @param online 节点是否已上线
/// @param nodeId 节点 ID（10 位十六进制字符串，nil 表示未上线）
/// @param localIP 当前本地 IP 地址（nil 表示未分配）
/// @param networkCount 已连接的 ZeroTier 网络数量
- (void)configureWithAvailable:(BOOL)available
                        online:(BOOL)online
                        nodeId:(NSString *)nodeId
                      localIP:(NSString *)localIP
                  networkCount:(NSInteger)networkCount;

@end

@implementation MultiplayerStatusCell

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
    // 左侧图标容器：40x40 圆角方块，蓝色背景
    _iconView = [[UIView alloc] init];
    _iconView.translatesAutoresizingMaskIntoConstraints = NO;
    _iconView.backgroundColor = [UIColor systemBlueColor];
    _iconView.layer.cornerRadius = 10;
    _iconView.layer.masksToBounds = YES;
    [self.contentView addSubview:_iconView];

    // 图标：SF Symbol antenna，白色
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
    _titleLabel.text = MPLocalized(@"mp.status.title", @"ZeroTier 虚拟局域网");
    [self.contentView addSubview:_titleLabel];

    // 副标题：12pt secondary
    _subtitleLabel = [[UILabel alloc] init];
    _subtitleLabel.translatesAutoresizingMaskIntoConstraints = NO;
    _subtitleLabel.font = [UIFont systemFontOfSize:12];
    _subtitleLabel.textColor = [UIColor secondaryLabelColor];
    _subtitleLabel.numberOfLines = 0;
    [self.contentView addSubview:_subtitleLabel];

    // 底部信息标签：12pt tertiary，显示节点 ID/IP/网络数
    _infoLabel = [[UILabel alloc] init];
    _infoLabel.translatesAutoresizingMaskIntoConstraints = NO;
    _infoLabel.font = [UIFont systemFontOfSize:11];
    _infoLabel.textColor = [UIColor tertiaryLabelColor];
    _infoLabel.numberOfLines = 0;
    [self.contentView addSubview:_infoLabel];

    // 状态指示灯：10x10 圆形
    _statusDot = [[UIView alloc] init];
    _statusDot.translatesAutoresizingMaskIntoConstraints = NO;
    _statusDot.layer.cornerRadius = 5;
    _statusDot.layer.masksToBounds = YES;
    [self.contentView addSubview:_statusDot];

    // 刷新按钮：28x28 圆形按钮，带 refresh SF Symbol
    _refreshButton = [UIButton buttonWithType:UIButtonTypeSystem];
    _refreshButton.translatesAutoresizingMaskIntoConstraints = NO;
    [_refreshButton setImage:[UIImage systemImageNamed:@"arrow.clockwise"] forState:UIControlStateNormal];
    _refreshButton.tintColor = [UIColor systemBlueColor];
    _refreshButton.layer.cornerRadius = 14;
    _refreshButton.layer.masksToBounds = YES;
    _refreshButton.backgroundColor = [[UIColor systemBlueColor] colorWithAlphaComponent:0.1];
    _refreshButton.accessibilityLabel = MPLocalized(@"mp.status.refresh", @"刷新状态");
    [_refreshButton addTarget:self action:@selector(refreshButtonTapped) forControlEvents:UIControlEventTouchUpInside];
    [self.contentView addSubview:_refreshButton];

    [NSLayoutConstraint activateConstraints:@[
        // 图标容器：左侧 16pt，垂直居中于标题区
        [_iconView.leadingAnchor constraintEqualToAnchor:self.contentView.leadingAnchor constant:16],
        [_iconView.topAnchor constraintEqualToAnchor:self.contentView.topAnchor constant:16],
        [_iconView.widthAnchor constraintEqualToConstant:40],
        [_iconView.heightAnchor constraintEqualToConstant:40],

        // 图标内容居中
        [_iconImageView.centerXAnchor constraintEqualToAnchor:_iconView.centerXAnchor],
        [_iconImageView.centerYAnchor constraintEqualToAnchor:_iconView.centerYAnchor],
        [_iconImageView.widthAnchor constraintEqualToConstant:22],
        [_iconImageView.heightAnchor constraintEqualToConstant:22],

        // 标题：图标右侧 12pt，顶部 16pt
        [_titleLabel.leadingAnchor constraintEqualToAnchor:_iconView.trailingAnchor constant:12],
        [_titleLabel.topAnchor constraintEqualToAnchor:self.contentView.topAnchor constant:14],
        [_titleLabel.trailingAnchor constraintLessThanOrEqualToAnchor:_statusDot.leadingAnchor constant:-8],

        // 副标题：标题下方 2pt
        [_subtitleLabel.leadingAnchor constraintEqualToAnchor:_titleLabel.leadingAnchor],
        [_subtitleLabel.topAnchor constraintEqualToAnchor:_titleLabel.bottomAnchor constant:2],
        [_subtitleLabel.trailingAnchor constraintLessThanOrEqualToAnchor:_refreshButton.leadingAnchor constant:-8],

        // 信息标签：副标题下方 4pt
        [_infoLabel.leadingAnchor constraintEqualToAnchor:_titleLabel.leadingAnchor],
        [_infoLabel.topAnchor constraintEqualToAnchor:_subtitleLabel.bottomAnchor constant:4],
        [_infoLabel.trailingAnchor constraintLessThanOrEqualToAnchor:_refreshButton.leadingAnchor constant:-8],
        [_infoLabel.bottomAnchor constraintEqualToAnchor:self.contentView.bottomAnchor constant:-14],

        // 状态指示灯：右上角，与标题对齐
        [_statusDot.trailingAnchor constraintEqualToAnchor:self.contentView.trailingAnchor constant:-16],
        [_statusDot.topAnchor constraintEqualToAnchor:self.contentView.topAnchor constant:20],
        [_statusDot.widthAnchor constraintEqualToConstant:10],
        [_statusDot.heightAnchor constraintEqualToConstant:10],

        // 刷新按钮：状态灯下方
        [_refreshButton.trailingAnchor constraintEqualToAnchor:self.contentView.trailingAnchor constant:-12],
        [_refreshButton.topAnchor constraintEqualToAnchor:_statusDot.bottomAnchor constant:8],
        [_refreshButton.widthAnchor constraintEqualToConstant:28],
        [_refreshButton.heightAnchor constraintEqualToConstant:28],
    ]];
}

- (void)refreshButtonTapped {
    // 触发刷新回调，由 Controller 处理实际的状态刷新逻辑
    if (self.onRefreshTapped) {
        // 添加按钮按压动画反馈
        [UIView animateWithDuration:0.1 animations:^{
            self.refreshButton.transform = CGAffineTransformMakeRotation(M_PI);
        } completion:^(BOOL finished) {
            [UIView animateWithDuration:0.3 animations:^{
                self.refreshButton.transform = CGAffineTransformIdentity;
            }];
        }];
        self.onRefreshTapped();
    }
}

- (void)configureWithAvailable:(BOOL)available
                        online:(BOOL)online
                        nodeId:(NSString *)nodeId
                      localIP:(NSString *)localIP
                  networkCount:(NSInteger)networkCount {
    BOOL hasBackground = [[BackgroundManager sharedManager] hasBackground];

    if (!available) {
        // 联机核心不可用（CI 构建版本，链接了 zt_stub）
        self.subtitleLabel.text = MPLocalized(@"mp.status.unavailable", @"联机核心未加载（CI 构建版本）");
        self.infoLabel.text = MPLocalized(@"mp.status.unavailable_hint", @"请使用包含 zt.framework 的构建版本");
        self.statusDot.backgroundColor = [UIColor systemRedColor];
        self.refreshButton.hidden = YES;
    } else if (online) {
        // 节点已上线，显示节点 ID/IP/网络数
        self.subtitleLabel.text = MPLocalized(@"mp.status.online", @"ZeroTier 节点已上线，可直接连接房间");
        self.statusDot.backgroundColor = [UIColor systemGreenColor];
        self.refreshButton.hidden = NO;

        NSString *nodeIdText = nodeId.length ? nodeId : @"—";
        NSString *ipText = localIP.length ? localIP : @"—";
        self.infoLabel.text = [NSString stringWithFormat:@"%@ %@ · %@ %@ · %@ %ld",
                               MPLocalized(@"mp.status.node_id", @"节点 ID"), nodeIdText,
                               MPLocalized(@"mp.status.ip", @"IP"), ipText,
                               MPLocalized(@"mp.status.networks", @"网络"), (long)networkCount];
    } else {
        // 节点未上线
        self.subtitleLabel.text = MPLocalized(@"mp.status.offline", @"ZeroTier 节点未上线");
        self.infoLabel.text = MPLocalized(@"mp.status.offline_hint", @"连接房间后会自动启动节点");
        self.statusDot.backgroundColor = [UIColor systemGrayColor];
        self.refreshButton.hidden = NO;
    }

    // 适配自定义背景：有背景时使用白色文字
    if (hasBackground) {
        self.titleLabel.textColor = [UIColor whiteColor];
        self.subtitleLabel.textColor = [UIColor whiteColor];
        self.infoLabel.textColor = [UIColor whiteColor];
    } else {
        self.titleLabel.textColor = [UIColor labelColor];
        self.subtitleLabel.textColor = [UIColor secondaryLabelColor];
        self.infoLabel.textColor = [UIColor tertiaryLabelColor];
    }
}

@end

#pragma mark - MultiplayerRoomCell

/// 联机房间列表 Cell（Section 1）
///
/// 布局结构（参照 FCL/HMCL 房间列表项风格）：
///   ┌──────────────────────────────────────────────────────────┐
///   │ [icon] 房间名 [房主/成员]                       [连接按钮] │
///   │        Network ID: a84ac5c10a1b2c3d                     │
///   │        ● 已连接 · 10.147.17.1:25565 · 在线 1            │
///   └──────────────────────────────────────────────────────────┘
///
/// - 左侧：36x36 圆角图标（绿色背景 + 白色 person.3 SF Symbol）
/// - 第一行：房间名（16pt semibold）+ 房主/成员徽章
/// - 第二行：Network ID（12pt secondary）
/// - 第三行：状态点 + 状态文本 + IP:端口 + 在线人数
/// - 右侧：连接按钮（更醒目的设计，状态色背景）
@interface MultiplayerRoomCell : UITableViewCell

/// 左侧图标容器
@property (nonatomic, strong) UIView *iconView;
/// 图标内容
@property (nonatomic, strong) UIImageView *iconImageView;
/// 房间名标签
@property (nonatomic, strong) UILabel *nameLabel;
/// 房主/成员徽章容器
@property (nonatomic, strong) UIView *ownerBadgeView;
/// 房主/成员徽章标签
@property (nonatomic, strong) UILabel *ownerBadgeLabel;
/// Network ID 标签
@property (nonatomic, strong) UILabel *networkIdLabel;
/// 状态信息标签（含状态点、IP:端口、在线人数）
@property (nonatomic, strong) UILabel *statusInfoLabel;
/// 状态指示点
@property (nonatomic, strong) UIView *statusDot;
/// 连接按钮
@property (nonatomic, strong) UIButton *connectButton;
/// 连接中指示器
@property (nonatomic, strong) UIActivityIndicatorView *activityIndicator;

/// 连接按钮回调
@property (nonatomic, copy) void (^onConnectTapped)(MultiplayerRoom *room);

@end

@implementation MultiplayerRoomCell

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

    // 房主/成员徽章容器：圆角胶囊
    _ownerBadgeView = [[UIView alloc] init];
    _ownerBadgeView.translatesAutoresizingMaskIntoConstraints = NO;
    _ownerBadgeView.layer.cornerRadius = 8;
    _ownerBadgeView.layer.masksToBounds = YES;
    [self.contentView addSubview:_ownerBadgeView];

    // 房主/成员徽章标签
    _ownerBadgeLabel = [[UILabel alloc] init];
    _ownerBadgeLabel.translatesAutoresizingMaskIntoConstraints = NO;
    _ownerBadgeLabel.font = [UIFont systemFontOfSize:10 weight:UIFontWeightSemibold];
    _ownerBadgeLabel.textAlignment = NSTextAlignmentCenter;
    [_ownerBadgeView addSubview:_ownerBadgeLabel];

    // Network ID：12pt secondary，截断
    _networkIdLabel = [[UILabel alloc] init];
    _networkIdLabel.translatesAutoresizingMaskIntoConstraints = NO;
    _networkIdLabel.font = [UIFont systemFontOfSize:12];
    _networkIdLabel.textColor = [UIColor secondaryLabelColor];
    _networkIdLabel.lineBreakMode = NSLineBreakByTruncatingTail;
    [self.contentView addSubview:_networkIdLabel];

    // 状态信息行：状态点 + 状态文本 + IP:端口 + 在线人数
    _statusInfoLabel = [[UILabel alloc] init];
    _statusInfoLabel.translatesAutoresizingMaskIntoConstraints = NO;
    _statusInfoLabel.font = [UIFont systemFontOfSize:12];
    _statusInfoLabel.textColor = [UIColor secondaryLabelColor];
    [self.contentView addSubview:_statusInfoLabel];

    // 状态指示点：8x8 圆形
    _statusDot = [[UIView alloc] init];
    _statusDot.translatesAutoresizingMaskIntoConstraints = NO;
    _statusDot.layer.cornerRadius = 4;
    _statusDot.layer.masksToBounds = YES;
    [self.contentView addSubview:_statusDot];

    // 连接按钮：更醒目的设计，84pt 宽，圆角，带阴影
    _connectButton = [UIButton buttonWithType:UIButtonTypeSystem];
    _connectButton.translatesAutoresizingMaskIntoConstraints = NO;
    _connectButton.titleLabel.font = [UIFont systemFontOfSize:14 weight:UIFontWeightSemibold];
    _connectButton.layer.cornerRadius = 10;
    _connectButton.layer.masksToBounds = NO;
    _connectButton.layer.shadowColor = [UIColor blackColor].CGColor;
    _connectButton.layer.shadowOpacity = 0.1;
    _connectButton.layer.shadowOffset = CGSizeMake(0, 2);
    _connectButton.layer.shadowRadius = 4;
    [_connectButton addTarget:self action:@selector(connectButtonTapped) forControlEvents:UIControlEventTouchUpInside];
    [self.contentView addSubview:_connectButton];

    // 连接中指示器
    _activityIndicator = [[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleMedium];
    _activityIndicator.translatesAutoresizingMaskIntoConstraints = NO;
    _activityIndicator.hidesWhenStopped = YES;
    [self.contentView addSubview:_activityIndicator];

    [NSLayoutConstraint activateConstraints:@[
        // 图标容器：左侧 16pt，垂直居中
        [_iconView.leadingAnchor constraintEqualToAnchor:self.contentView.leadingAnchor constant:16],
        [_iconView.centerYAnchor constraintEqualToAnchor:self.contentView.centerYAnchor],
        [_iconView.widthAnchor constraintEqualToConstant:36],
        [_iconView.heightAnchor constraintEqualToConstant:36],

        // 图标内容居中
        [_iconImageView.centerXAnchor constraintEqualToAnchor:_iconView.centerXAnchor],
        [_iconImageView.centerYAnchor constraintEqualToAnchor:_iconView.centerYAnchor],
        [_iconImageView.widthAnchor constraintEqualToConstant:20],
        [_iconImageView.heightAnchor constraintEqualToConstant:20],

        // 房间名：图标右侧 12pt，顶部 12pt
        [_nameLabel.leadingAnchor constraintEqualToAnchor:_iconView.trailingAnchor constant:12],
        [_nameLabel.topAnchor constraintEqualToAnchor:self.contentView.topAnchor constant:12],
        [_nameLabel.trailingAnchor constraintLessThanOrEqualToAnchor:_connectButton.leadingAnchor constant:-8],

        // 房主/成员徽章：房间名右侧 6pt，与房间名基线对齐
        [_ownerBadgeView.leadingAnchor constraintEqualToAnchor:_nameLabel.trailingAnchor constant:6],
        [_ownerBadgeView.centerYAnchor constraintEqualToAnchor:_nameLabel.centerYAnchor],
        [_ownerBadgeView.widthAnchor constraintGreaterThanOrEqualToConstant:32],

        [_ownerBadgeLabel.topAnchor constraintEqualToAnchor:_ownerBadgeView.topAnchor constant:2],
        [_ownerBadgeLabel.bottomAnchor constraintEqualToAnchor:_ownerBadgeView.bottomAnchor constant:-2],
        [_ownerBadgeLabel.leadingAnchor constraintEqualToAnchor:_ownerBadgeView.leadingAnchor constant:6],
        [_ownerBadgeLabel.trailingAnchor constraintEqualToAnchor:_ownerBadgeView.trailingAnchor constant:-6],

        // Network ID：房间名下方 2pt
        [_networkIdLabel.leadingAnchor constraintEqualToAnchor:_nameLabel.leadingAnchor],
        [_networkIdLabel.topAnchor constraintEqualToAnchor:_nameLabel.bottomAnchor constant:2],
        [_networkIdLabel.trailingAnchor constraintLessThanOrEqualToAnchor:_connectButton.leadingAnchor constant:-8],

        // 状态点：Network ID 下方
        [_statusDot.leadingAnchor constraintEqualToAnchor:_nameLabel.leadingAnchor],
        [_statusDot.topAnchor constraintEqualToAnchor:_networkIdLabel.bottomAnchor constant:6],
        [_statusDot.widthAnchor constraintEqualToConstant:8],
        [_statusDot.heightAnchor constraintEqualToConstant:8],

        // 状态信息标签：状态点右侧 6pt，与状态点垂直居中
        [_statusInfoLabel.leadingAnchor constraintEqualToAnchor:_statusDot.trailingAnchor constant:6],
        [_statusInfoLabel.centerYAnchor constraintEqualToAnchor:_statusDot.centerYAnchor],
        [_statusInfoLabel.trailingAnchor constraintLessThanOrEqualToAnchor:_connectButton.leadingAnchor constant:-8],
        [_statusInfoLabel.bottomAnchor constraintEqualToAnchor:self.contentView.bottomAnchor constant:-12],

        // 连接按钮：右侧固定
        [_connectButton.trailingAnchor constraintEqualToAnchor:self.contentView.trailingAnchor constant:-16],
        [_connectButton.centerYAnchor constraintEqualToAnchor:self.contentView.centerYAnchor],
        [_connectButton.widthAnchor constraintEqualToConstant:84],
        [_connectButton.heightAnchor constraintEqualToConstant:36],

        // 指示器居中于连接按钮
        [_activityIndicator.centerXAnchor constraintEqualToAnchor:_connectButton.centerXAnchor],
        [_activityIndicator.centerYAnchor constraintEqualToAnchor:_connectButton.centerYAnchor],
    ]];
}

- (void)connectButtonTapped {
    if (self.onConnectTapped) {
        // 触发回调，实际 room 由 Controller 在 configure 时通过闭包捕获注入
        self.onConnectTapped(nil);
    }
}

- (void)configureWithRoom:(MultiplayerRoom *)room {
    // 房间名：空则显示"未命名房间"
    self.nameLabel.text = room.name.length ? room.name : MPLocalized(@"mp.room.unnamed", @"未命名房间");

    // Network ID
    self.networkIdLabel.text = [NSString stringWithFormat:@"%@: %@",
                                MPLocalized(@"mp.room.network_id", @"Network ID"),
                                room.networkId ?: @"-"];

    // 判断房主/成员：ownerName 为空表示本地创建（房主），非空表示导入（成员）
    BOOL isOwner = (room.ownerName.length == 0);
    if (isOwner) {
        self.ownerBadgeLabel.text = MPLocalized(@"mp.badge.host", @"房主");
        self.ownerBadgeView.backgroundColor = [[UIColor systemBlueColor] colorWithAlphaComponent:0.15];
        self.ownerBadgeLabel.textColor = [UIColor systemBlueColor];
    } else {
        self.ownerBadgeLabel.text = MPLocalized(@"mp.badge.member", @"成员");
        self.ownerBadgeView.backgroundColor = [[UIColor systemPurpleColor] colorWithAlphaComponent:0.15];
        self.ownerBadgeLabel.textColor = [UIColor systemPurpleColor];
    }

    // 状态文本与状态点颜色
    NSString *statusText;
    UIColor *statusColor;
    UIColor *buttonColor;
    NSString *buttonTitle;
    UIColor *buttonTitleColor = [UIColor whiteColor];

    switch (room.status) {
        case MultiplayerRoomStatusDisconnected:
            statusText = MPLocalized(@"mp.room.status.disconnected", @"未连接");
            statusColor = [UIColor systemGrayColor];
            buttonTitle = MPLocalized(@"mp.room.button.connect", @"连接");
            buttonColor = [UIColor systemBlueColor];
            [self.activityIndicator stopAnimating];
            break;
        case MultiplayerRoomStatusConnecting:
            statusText = MPLocalized(@"mp.room.status.connecting", @"连接中");
            statusColor = [UIColor systemOrangeColor];
            buttonTitle = MPLocalized(@"mp.room.button.connecting", @"连接中");
            buttonColor = [UIColor systemGrayColor];
            [self.activityIndicator startAnimating];
            break;
        case MultiplayerRoomStatusConnected:
            statusText = MPLocalized(@"mp.room.status.connected", @"已连接");
            statusColor = [UIColor systemGreenColor];
            buttonTitle = MPLocalized(@"mp.room.button.disconnect", @"断开");
            buttonColor = [UIColor systemRedColor];
            [self.activityIndicator stopAnimating];
            break;
        case MultiplayerRoomStatusError:
            statusText = MPLocalized(@"mp.room.status.error", @"错误");
            statusColor = [UIColor systemRedColor];
            buttonTitle = MPLocalized(@"mp.room.button.retry", @"重试");
            buttonColor = [UIColor systemOrangeColor];
            [self.activityIndicator stopAnimating];
            break;
    }

    self.statusDot.backgroundColor = statusColor;
    self.statusInfoLabel.text = [NSString stringWithFormat:@"%@ · %@:%@ · %@ %ld",
                                 statusText,
                                 room.hostIP ?: @"-",
                                 room.hostPort ?: @"25565",
                                 MPLocalized(@"mp.room.online", @"在线"),
                                 (long)(room.status == MultiplayerRoomStatusConnected ? 1 : 0)];

    // 连接按钮样式
    [self.connectButton setTitle:buttonTitle forState:UIControlStateNormal];
    [self.connectButton setTitleColor:buttonTitleColor forState:UIControlStateNormal];
    self.connectButton.backgroundColor = buttonColor;

    // 适配自定义背景
    BOOL hasBackground = [[BackgroundManager sharedManager] hasBackground];
    if (hasBackground) {
        self.nameLabel.textColor = [UIColor whiteColor];
        self.networkIdLabel.textColor = [UIColor whiteColor];
        self.statusInfoLabel.textColor = [UIColor whiteColor];
    } else {
        self.nameLabel.textColor = [UIColor labelColor];
        self.networkIdLabel.textColor = [UIColor secondaryLabelColor];
        self.statusInfoLabel.textColor = [UIColor secondaryLabelColor];
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

#pragma mark - CreateRoomViewController

/// 创建/编辑房间的卡片式表单 ViewController
///
/// 参照 FCL（Fold Craft Launcher）和 HMCL（Hello Minecraft! Launcher）的多人联机界面风格设计：
/// - 整体使用 UIScrollView 承载，键盘弹出时自动避让
/// - 表单分为两张卡片："房间信息"和"服务器配置"
/// - 每个输入框带左侧图标和下方说明文字
/// - 底部"创建房间"按钮使用渐变色背景（参照 FCL 的主操作按钮风格）
/// - 服务器密码输入框带安全输入切换按钮（眼睛图标）
/// - 端口输入框自动检测 LAN 端口并预填
///
/// 支持两种模式：
/// - 创建模式（默认）：表单为空，按钮标题"创建房间"
/// - 编辑模式（initWithRoom:）：预填已有房间数据，按钮标题"保存修改"
@interface CreateRoomViewController () <UITextFieldDelegate>

/// 主滚动视图
@property (nonatomic, strong) UIScrollView *scrollView;
/// 内容容器
@property (nonatomic, strong) UIView *contentView;
/// 房间名称输入框
@property (nonatomic, strong) UITextField *nameField;
/// ZeroTier Network ID 输入框
@property (nonatomic, strong) UITextField *networkIdField;
/// 服务器地址输入框
@property (nonatomic, strong) UITextField *serverField;
/// 端口输入框
@property (nonatomic, strong) UITextField *portField;
/// 服务器密码输入框
@property (nonatomic, strong) UITextField *passwordField;
/// 密码显示/隐藏切换按钮
@property (nonatomic, strong) UIButton *passwordToggleButton;
/// 底部创建按钮
@property (nonatomic, strong) UIButton *createButton;
/// 创建按钮的渐变背景层
@property (nonatomic, strong) CAGradientLayer *createButtonGradient;
/// 端口检测提示标签
@property (nonatomic, strong) UILabel *portHintLabel;
/// 创建按钮底部约束（用于键盘避让）
@property (nonatomic, strong) NSLayoutConstraint *createButtonBottomConstraint;

/// 编辑模式下的原始房间对象（nil 表示创建模式）
@property (nonatomic, strong) MultiplayerRoom *editingRoom;
/// 房间创建/保存完成回调
@property (nonatomic, copy) void (^onRoomSaved)(MultiplayerRoom *room);

@end

@implementation CreateRoomViewController

- (instancetype)init {
    self = [super init];
    if (self) {
        _editingRoom = nil;
    }
    return self;
}

- (instancetype)initWithRoom:(MultiplayerRoom *)room {
    self = [super init];
    if (self) {
        _editingRoom = room;
    }
    return self;
}

- (void)viewDidLoad {
    [super viewDidLoad];

    // 标题区分创建/编辑模式
    if (self.editingRoom) {
        self.title = MPLocalized(@"mp.create_room.edit_title", @"编辑房间");
    } else {
        self.title = MPLocalized(@"mp.create_room.title", @"创建房间");
    }

    // 适配自定义启动器背景
    [[BackgroundManager sharedManager] makeViewControllerTransparent:self];

    [self setupUI];
    [self setupKeyboardObservers];
    [self prefillData];

    // 导航栏左侧取消按钮
    UIBarButtonItem *cancelButton = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemCancel
                                                                                   target:self
                                                                                   action:@selector(cancelTapped)];
    self.navigationItem.leftBarButtonItem = cancelButton;

    // 应用导航栏毛玻璃效果
    [[BackgroundManager sharedManager] applyEffectToNavigationBar:self.navigationController.navigationBar];
}

- (void)dealloc {
    // 移除键盘通知观察者
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

#pragma mark - UI Setup

- (void)setupUI {
    self.view.backgroundColor = [UIColor systemGroupedBackgroundColor];

    // 主滚动视图：承载表单内容，键盘弹出时自动避让
    _scrollView = [[UIScrollView alloc] init];
    _scrollView.translatesAutoresizingMaskIntoConstraints = NO;
    _scrollView.alwaysBounceVertical = YES;
    _scrollView.keyboardDismissMode = UIScrollViewKeyboardDismissModeInteractive;
    _scrollView.backgroundColor = [UIColor clearColor];
    [self.view addSubview:_scrollView];

    // 内容容器：固定宽度等于滚动视图宽度
    _contentView = [[UIView alloc] init];
    _contentView.translatesAutoresizingMaskIntoConstraints = NO;
    [_scrollView addSubview:_contentView];

    // 构建"房间信息"卡片
    UIView *roomInfoHeader = [self makeSectionHeaderWithTitle:MPLocalized(@"mp.create_room.section.room_info", @"房间信息")];
    UIView *roomInfoCard = [self makeCardContainer];
    [self.contentView addSubview:roomInfoHeader];
    [self.contentView addSubview:roomInfoCard];

    // 房间名称行
    _nameField = [self makeStyledTextFieldWithPlaceholder:MPLocalized(@"mp.create_room.name.placeholder", @"如：和朋友的生存世界")
                                            keyboardType:UIKeyboardTypeDefault
                                              secureEntry:NO
                                                   icon:@"person.fill"];
    UIView *nameHint = [self makeHintLabelWithText:MPLocalized(@"mp.create_room.name.hint", @"给这个联机房间起个好记的名字")];

    // ZeroTier Network ID 行
    _networkIdField = [self makeStyledTextFieldWithPlaceholder:MPLocalized(@"mp.create_room.network_id.placeholder", @"a84ac5c10a1b2c3d")
                                                 keyboardType:UIKeyboardTypeASCIICapable
                                                   secureEntry:NO
                                                        icon:@"network"];
    UIView *networkIdHint = [self makeHintLabelWithText:MPLocalized(@"mp.create_room.network_id.hint", @"16 位十六进制网络 ID，可在 ZeroTier 后台查看")];

    // 组装房间信息卡片
    UIView *nameRow = [self makeFieldRowWithField:self.nameField hint:nameHint];
    UIView *networkIdRow = [self makeFieldRowWithField:self.networkIdField hint:networkIdHint];
    UIView *divider1 = [self makeDivider];

    [self stackViewsInContainer:roomInfoCard
                          views:@[nameRow, divider1, networkIdRow]
                          insets:UIEdgeInsetsMake(0, 0, 0, 0)];

    // 构建"服务器配置"卡片
    UIView *serverConfigHeader = [self makeSectionHeaderWithTitle:MPLocalized(@"mp.create_room.section.server_config", @"服务器配置")];
    UIView *serverConfigCard = [self makeCardContainer];
    [self.contentView addSubview:serverConfigHeader];
    [self.contentView addSubview:serverConfigCard];

    // 服务器地址行
    _serverField = [self makeStyledTextFieldWithPlaceholder:MPLocalized(@"mp.create_room.server.placeholder", @"如 10.147.17.1")
                                              keyboardType:UIKeyboardTypeNumbersAndPunctuation
                                                secureEntry:NO
                                                     icon:@"server.rack"];
    UIView *serverHint = [self makeHintLabelWithText:MPLocalized(@"mp.create_room.server.hint", @"Minecraft 服务器 IP（房主在 ZeroTier 网络中的 IP）")];

    // 端口行
    _portField = [self makeStyledTextFieldWithPlaceholder:MPLocalized(@"mp.create_room.port.placeholder", @"25565")
                                            keyboardType:UIKeyboardTypeNumberPad
                                              secureEntry:NO
                                                   icon:@"number.circle"];
    _portHintLabel = [[UILabel alloc] init];
    _portHintLabel.translatesAutoresizingMaskIntoConstraints = NO;
    _portHintLabel.font = [UIFont systemFontOfSize:12];
    _portHintLabel.textColor = [UIColor tertiaryLabelColor];
    _portHintLabel.numberOfLines = 0;
    [self updatePortHint];

    // 服务器密码行（带显示/隐藏切换按钮）
    _passwordField = [self makeStyledTextFieldWithPlaceholder:MPLocalized(@"mp.create_room.password.placeholder", @"（可选）")
                                                 keyboardType:UIKeyboardTypeDefault
                                                   secureEntry:YES
                                                        icon:@"lock"];
    _passwordToggleButton = [UIButton buttonWithType:UIButtonTypeSystem];
    // 注意：rightView/leftView 内部使用 frame 布局，不要设置 translatesAutoresizingMaskIntoConstraints = NO
    [_passwordToggleButton setImage:[UIImage systemImageNamed:@"eye"] forState:UIControlStateNormal];
    [_passwordToggleButton setImage:[UIImage systemImageNamed:@"eye.slash"] forState:UIControlStateSelected];
    _passwordToggleButton.tintColor = [UIColor secondaryLabelColor];
    [_passwordToggleButton addTarget:self action:@selector(passwordToggleTapped) forControlEvents:UIControlEventTouchUpInside];
    // 将切换按钮设置为密码输入框的 rightView
    UIView *passwordRightContainer = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 36, 24)];
    _passwordToggleButton.frame = CGRectMake(6, 0, 24, 24);
    [passwordRightContainer addSubview:_passwordToggleButton];
    self.passwordField.rightView = passwordRightContainer;
    self.passwordField.rightViewMode = UITextFieldViewModeAlways;

    UIView *passwordHint = [self makeHintLabelWithText:MPLocalized(@"mp.create_room.password.hint", @"留空表示无密码，部分服务器可能需要")];

    // 组装服务器配置卡片
    UIView *serverRow = [self makeFieldRowWithField:self.serverField hint:serverHint];
    UIView *portRow = [self makeFieldRowWithField:self.portField hint:_portHintLabel];
    UIView *passwordRow = [self makeFieldRowWithField:self.passwordField hint:passwordHint];
    UIView *divider2 = [self makeDivider];
    UIView *divider3 = [self makeDivider];

    [self stackViewsInContainer:serverConfigCard
                          views:@[serverRow, divider2, portRow, divider3, passwordRow]
                          insets:UIEdgeInsetsMake(0, 0, 0, 0)];

    // 底部创建按钮（带渐变色背景）
    _createButton = [UIButton buttonWithType:UIButtonTypeSystem];
    _createButton.translatesAutoresizingMaskIntoConstraints = NO;
    _createButton.titleLabel.font = [UIFont systemFontOfSize:16 weight:UIFontWeightSemibold];
    if (self.editingRoom) {
        [_createButton setTitle:MPLocalized(@"mp.create_room.save_button", @"保存修改") forState:UIControlStateNormal];
    } else {
        [_createButton setTitle:MPLocalized(@"mp.create_room.button", @"创建房间") forState:UIControlStateNormal];
    }
    [_createButton setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    _createButton.layer.cornerRadius = 14;
    _createButton.layer.masksToBounds = NO;
    _createButton.layer.shadowColor = [UIColor systemBlueColor].CGColor;
    _createButton.layer.shadowOpacity = 0.35;
    _createButton.layer.shadowOffset = CGSizeMake(0, 6);
    _createButton.layer.shadowRadius = 10;
    [_createButton addTarget:self action:@selector(createButtonTapped) forControlEvents:UIControlEventTouchUpInside];
    [self.view addSubview:_createButton];

    // 渐变背景层
    _createButtonGradient = [CAGradientLayer layer];
    _createButtonGradient.colors = @[(id)[UIColor systemBlueColor].CGColor,
                                     (id)[UIColor systemIndigoColor].CGColor];
    _createButtonGradient.startPoint = CGPointMake(0, 0);
    _createButtonGradient.endPoint = CGPointMake(1, 1);
    [_createButton.layer insertSublayer:_createButtonGradient atIndex:0];

    // 设置代理
    self.nameField.delegate = self;
    self.networkIdField.delegate = self;
    self.serverField.delegate = self;
    self.portField.delegate = self;
    self.passwordField.delegate = self;

    // 创建按钮底部约束（键盘弹出时调整）
    self.createButtonBottomConstraint = [_createButton.bottomAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.bottomAnchor constant:-16];

    [NSLayoutConstraint activateConstraints:@[
        // 滚动视图：填充整个视图
        [_scrollView.topAnchor constraintEqualToAnchor:self.view.topAnchor],
        [_scrollView.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [_scrollView.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [_scrollView.bottomAnchor constraintEqualToAnchor:_createButton.topAnchor constant:-12],

        // 内容容器：固定宽度
        [_contentView.topAnchor constraintEqualToAnchor:_scrollView.contentLayoutGuide.topAnchor constant:16],
        [_contentView.leadingAnchor constraintEqualToAnchor:_scrollView.contentLayoutGuide.leadingAnchor constant:16],
        [_contentView.trailingAnchor constraintEqualToAnchor:_scrollView.contentLayoutGuide.trailingAnchor constant:-16],
        [_contentView.bottomAnchor constraintEqualToAnchor:_scrollView.contentLayoutGuide.bottomAnchor constant:-16],
        [_contentView.widthAnchor constraintEqualToAnchor:_scrollView.frameLayoutGuide.widthAnchor constant:-32],

        // 房间信息区段标题
        [roomInfoHeader.topAnchor constraintEqualToAnchor:self.contentView.topAnchor],
        [roomInfoHeader.leadingAnchor constraintEqualToAnchor:self.contentView.leadingAnchor],
        [roomInfoHeader.trailingAnchor constraintEqualToAnchor:self.contentView.trailingAnchor],
        [roomInfoHeader.heightAnchor constraintEqualToConstant:20],

        // 房间信息卡片
        [roomInfoCard.topAnchor constraintEqualToAnchor:roomInfoHeader.bottomAnchor constant:6],
        [roomInfoCard.leadingAnchor constraintEqualToAnchor:self.contentView.leadingAnchor],
        [roomInfoCard.trailingAnchor constraintEqualToAnchor:self.contentView.trailingAnchor],

        // 服务器配置区段标题
        [serverConfigHeader.topAnchor constraintEqualToAnchor:roomInfoCard.bottomAnchor constant:24],
        [serverConfigHeader.leadingAnchor constraintEqualToAnchor:self.contentView.leadingAnchor],
        [serverConfigHeader.trailingAnchor constraintEqualToAnchor:self.contentView.trailingAnchor],
        [serverConfigHeader.heightAnchor constraintEqualToConstant:20],

        // 服务器配置卡片
        [serverConfigCard.topAnchor constraintEqualToAnchor:serverConfigHeader.bottomAnchor constant:6],
        [serverConfigCard.leadingAnchor constraintEqualToAnchor:self.contentView.leadingAnchor],
        [serverConfigCard.trailingAnchor constraintEqualToAnchor:self.contentView.trailingAnchor],
        [serverConfigCard.bottomAnchor constraintEqualToAnchor:self.contentView.bottomAnchor],

        // 创建按钮：左右各留 20pt 边距，高度 50pt
        [_createButton.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor constant:20],
        [_createButton.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor constant:-20],
        self.createButtonBottomConstraint,
        [_createButton.heightAnchor constraintEqualToConstant:50],
    ]];

    // 适配自定义背景：调整文字颜色
    [self adaptToBackground];
}

- (void)adaptToBackground {
    // 适配自定义启动器背景
    BOOL hasBackground = [[BackgroundManager sharedManager] hasBackground];
    if (hasBackground) {
        self.scrollView.backgroundColor = [UIColor clearColor];
        self.contentView.backgroundColor = [UIColor clearColor];
    }
}

#pragma mark - UI Helper Methods

/// 创建区段标题标签
- (UILabel *)makeSectionHeaderWithTitle:(NSString *)title {
    UILabel *label = [[UILabel alloc] init];
    label.translatesAutoresizingMaskIntoConstraints = NO;
    label.text = title;
    label.font = [UIFont systemFontOfSize:13 weight:UIFontWeightSemibold];
    label.textColor = [UIColor secondaryLabelColor];
    return label;
}

/// 创建卡片容器（圆角白底）
- (UIView *)makeCardContainer {
    UIView *card = [[UIView alloc] init];
    card.translatesAutoresizingMaskIntoConstraints = NO;
    card.backgroundColor = [UIColor secondarySystemGroupedBackgroundColor];
    card.layer.cornerRadius = 12;
    card.layer.masksToBounds = YES;
    return card;
}

/// 创建带图标的样式化文本输入框
- (UITextField *)makeStyledTextFieldWithPlaceholder:(NSString *)placeholder
                                      keyboardType:(UIKeyboardType)type
                                        secureEntry:(BOOL)secure
                                             icon:(NSString *)iconName {
    UITextField *field = [[UITextField alloc] init];
    field.translatesAutoresizingMaskIntoConstraints = NO;
    field.placeholder = placeholder;
    field.font = [UIFont systemFontOfSize:15];
    field.keyboardType = type;
    field.secureTextEntry = secure;
    field.autocapitalizationType = UITextAutocapitalizationTypeNone;
    field.autocorrectionType = UITextAutocorrectionTypeNo;
    field.clearButtonMode = secure ? UITextFieldViewModeNever : UITextFieldViewModeWhileEditing;
    field.returnKeyType = UIReturnKeyNext;
    field.backgroundColor = [UIColor clearColor];

    // 左侧图标视图（作为 leftView）
    UIView *leftContainer = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 36, 24)];
    UIImageView *icon = [[UIImageView alloc] initWithImage:[UIImage systemImageNamed:iconName]];
    icon.frame = CGRectMake(8, 0, 20, 24);
    icon.contentMode = UIViewContentModeScaleAspectFit;
    icon.tintColor = [UIColor secondaryLabelColor];
    [leftContainer addSubview:icon];
    field.leftView = leftContainer;
    field.leftViewMode = UITextFieldViewModeAlways;

    return field;
}

/// 创建提示标签
- (UILabel *)makeHintLabelWithText:(NSString *)text {
    UILabel *label = [[UILabel alloc] init];
    label.translatesAutoresizingMaskIntoConstraints = NO;
    label.text = text;
    label.font = [UIFont systemFontOfSize:12];
    label.textColor = [UIColor tertiaryLabelColor];
    label.numberOfLines = 0;
    return label;
}

/// 创建分割线
- (UIView *)makeDivider {
    UIView *divider = [[UIView alloc] init];
    divider.translatesAutoresizingMaskIntoConstraints = NO;
    divider.backgroundColor = [UIColor separatorColor];
    // 使用 tag 标记分割线，便于在 stackViews 时识别并设置固定高度
    divider.tag = 9527;
    return divider;
}

/// 将字段和提示文字组装为一行
- (UIView *)makeFieldRowWithField:(UITextField *)field hint:(UIView *)hint {
    UIView *row = [[UIView alloc] init];
    row.translatesAutoresizingMaskIntoConstraints = NO;
    [row addSubview:field];
    [row addSubview:hint];

    [NSLayoutConstraint activateConstraints:@[
        [field.topAnchor constraintEqualToAnchor:row.topAnchor constant:12],
        [field.leadingAnchor constraintEqualToAnchor:row.leadingAnchor constant:16],
        [field.trailingAnchor constraintEqualToAnchor:row.trailingAnchor constant:-16],
        [field.heightAnchor constraintEqualToConstant:36],

        [hint.topAnchor constraintEqualToAnchor:field.bottomAnchor constant:4],
        [hint.leadingAnchor constraintEqualToAnchor:row.leadingAnchor constant:16],
        [hint.trailingAnchor constraintEqualToAnchor:row.trailingAnchor constant:-16],
        [hint.bottomAnchor constraintEqualToAnchor:row.bottomAnchor constant:-10],
    ]];

    return row;
}

/// 将多个视图垂直堆叠到容器中
- (void)stackViewsInContainer:(UIView *)container
                        views:(NSArray<UIView *> *)views
                      insets:(UIEdgeInsets)insets {
    UIView *previous = nil;
    for (UIView *view in views) {
        view.translatesAutoresizingMaskIntoConstraints = NO;
        [container addSubview:view];
        if (!previous) {
            // 第一个视图
            [view.topAnchor constraintEqualToAnchor:container.topAnchor constant:insets.top].active = YES;
        } else {
            [view.topAnchor constraintEqualToAnchor:previous.bottomAnchor].active = YES;
        }

        if (view.tag == 9527) {
            // 分割线：高度固定为 0.5pt，左右各留 16pt 边距
            [view.heightAnchor constraintEqualToConstant:0.5].active = YES;
            [view.leadingAnchor constraintEqualToAnchor:container.leadingAnchor constant:16].active = YES;
            [view.trailingAnchor constraintEqualToAnchor:container.trailingAnchor constant:-16].active = YES;
        } else {
            // 普通视图：左右贴齐容器边缘
            [view.leadingAnchor constraintEqualToAnchor:container.leadingAnchor].active = YES;
            [view.trailingAnchor constraintEqualToAnchor:container.trailingAnchor].active = YES;
        }

        previous = view;
    }
    if (previous) {
        [previous.bottomAnchor constraintEqualToAnchor:container.bottomAnchor constant:insets.bottom].active = YES;
    }
}

#pragma mark - Data Prefill

- (void)prefillData {
    if (self.editingRoom) {
        // 编辑模式：预填已有数据
        self.nameField.text = self.editingRoom.name;
        self.networkIdField.text = self.editingRoom.networkId;
        self.serverField.text = self.editingRoom.hostIP;
        self.portField.text = self.editingRoom.hostPort;
        // 密码从 NSUserDefaults 读取
        self.passwordField.text = [self passwordForRoomId:self.editingRoom.roomId];
    } else {
        // 创建模式：自动检测 LAN 端口并预填
        LanPortDetector *detector = [LanPortDetector sharedDetector];
        NSString *detectedPort = detector.detectedPort ?: @"25565";
        self.portField.text = detectedPort;
    }
}

/// 更新端口检测提示文字
- (void)updatePortHint {
    LanPortDetector *detector = [LanPortDetector sharedDetector];
    if (detector.detectedPort) {
        if (detector.source == LanPortSourceAuto) {
            self.portHintLabel.text = [NSString stringWithFormat:@"%@ %@",
                                       MPLocalized(@"mp.create_room.port.hint_auto", @"已自动检测到 LAN 端口"),
                                       detector.detectedPort];
        } else {
            self.portHintLabel.text = [NSString stringWithFormat:@"%@ %@",
                                       MPLocalized(@"mp.create_room.port.hint_manual", @"上次输入的端口"),
                                       detector.detectedPort];
        }
    } else {
        self.portHintLabel.text = MPLocalized(@"mp.create_room.port.hint_default", @"默认端口 25565，可手动修改");
    }
}

#pragma mark - Password Storage

/// 房间密码存储前缀（存储在 NSUserDefaults 中）
- (NSString *)passwordDefaultsKeyForRoomId:(NSString *)roomId {
    return [NSString stringWithFormat:@"mp_room_password_%@", roomId ?: @""];
}

/// 读取房间密码
- (NSString *)passwordForRoomId:(NSString *)roomId {
    return [[NSUserDefaults standardUserDefaults] stringForKey:[self passwordDefaultsKeyForRoomId:roomId]];
}

/// 保存房间密码
- (void)setPassword:(NSString *)password forRoomId:(NSString *)roomId {
    NSString *key = [self passwordDefaultsKeyForRoomId:roomId];
    if (password.length == 0) {
        [[NSUserDefaults standardUserDefaults] removeObjectForKey:key];
    } else {
        [[NSUserDefaults standardUserDefaults] setObject:password forKey:key];
    }
    [[NSUserDefaults standardUserDefaults] synchronize];
}

#pragma mark - Actions

- (void)cancelTapped {
    [self.view endEditing:YES];
    [self dismissViewControllerAnimated:YES completion:nil];
}

- (void)passwordToggleTapped {
    // 切换密码显示/隐藏
    self.passwordToggleButton.selected = !self.passwordToggleButton.selected;
    self.passwordField.secureTextEntry = !self.passwordToggleButton.selected;
}

- (void)createButtonTapped {
    [self.view endEditing:YES];

    // 收集输入
    NSString *name = [self.nameField.text stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    NSString *networkId = [self.networkIdField.text stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    NSString *serverIP = [self.serverField.text stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    NSString *port = [self.portField.text stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    NSString *password = self.passwordField.text;

    // 输入验证：房间名称
    if (name.length == 0) {
        [self showValidationErrorWithTitle:MPLocalized(@"mp.create_room.error.title", @"输入不完整")
                                    message:MPLocalized(@"mp.create_room.error.name", @"请输入房间名称")];
        return;
    }
    // 输入验证：Network ID
    if (networkId.length == 0) {
        [self showValidationErrorWithTitle:MPLocalized(@"mp.create_room.error.title", @"输入不完整")
                                    message:MPLocalized(@"mp.create_room.error.network_id", @"请输入 ZeroTier Network ID")];
        return;
    }
    // 输入验证：Network ID 格式（16 位十六进制）
    if (![[MultiplayerManager sharedManager] isValidNetworkId:networkId]) {
        [self showValidationErrorWithTitle:MPLocalized(@"mp.create_room.error.title", @"输入不完整")
                                    message:MPLocalized(@"mp.create_room.error.network_id_format", @"Network ID 格式不正确，应为 16 位十六进制")];
        return;
    }
    // 输入验证：服务器 IP
    if (serverIP.length == 0) {
        [self showValidationErrorWithTitle:MPLocalized(@"mp.create_room.error.title", @"输入不完整")
                                    message:MPLocalized(@"mp.create_room.error.server", @"请输入服务器 IP 地址")];
        return;
    }
    // 端口默认值
    if (port.length == 0) {
        port = @"25565";
    }

    // 保存端口到 LanPortDetector（下次创建房间时预填）
    [[LanPortDetector sharedDetector] setManualPort:port];

    MultiplayerRoom *room;
    if (self.editingRoom) {
        // 编辑模式：更新已有房间
        room = self.editingRoom;
        room.name = name;
        room.networkId = networkId;
        room.hostIP = serverIP;
        room.hostPort = port;
        [[MultiplayerManager sharedManager] updateRoom:room];
    } else {
        // 创建模式：新建房间
        room = [[MultiplayerRoom alloc] init];
        room.roomId = [[MultiplayerManager sharedManager] generateRoomId];
        room.name = name;
        room.networkId = networkId;
        room.hostIP = serverIP;
        room.hostPort = port;
        room.roomDescription = @"";
        // ownerName 留空表示本地创建（房主）
        room.ownerName = @"";
        room.status = MultiplayerRoomStatusDisconnected;
        room.createdAt = [NSDate date];
        [[MultiplayerManager sharedManager] addRoom:room];
    }

    // 保存密码到 NSUserDefaults（与 roomId 关联）
    [self setPassword:password forRoomId:room.roomId];

    // 触发回调
    if (self.onRoomSaved) {
        self.onRoomSaved(room);
    }

    // 关闭界面
    [self dismissViewControllerAnimated:YES completion:nil];
}

- (void)showValidationErrorWithTitle:(NSString *)title message:(NSString *)message {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:title
                                                                   message:message
                                                            preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:MPLocalized(@"common.ok", @"好")
                                              style:UIAlertActionStyleDefault
                                            handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
}

#pragma mark - Keyboard Handling

- (void)setupKeyboardObservers {
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(keyboardWillShow:)
                                                 name:UIKeyboardWillShowNotification
                                               object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(keyboardWillHide:)
                                                 name:UIKeyboardWillHideNotification
                                               object:nil];
}

- (void)keyboardWillShow:(NSNotification *)notification {
    CGRect keyboardFrame = [notification.userInfo[UIKeyboardFrameEndUserInfoKey] CGRectValue];
    CGFloat keyboardHeight = keyboardFrame.size.height;
    NSTimeInterval duration = [notification.userInfo[UIKeyboardAnimationDurationUserInfoKey] doubleValue];

    // 调整创建按钮位置，上移到键盘上方
    [UIView animateWithDuration:duration animations:^{
        self.createButtonBottomConstraint.constant = -keyboardHeight - 16;
        [self.view layoutIfNeeded];
    }];

    // 调整滚动视图内容 inset
    UIEdgeInsets insets = self.scrollView.contentInset;
    insets.bottom = keyboardHeight + 80;
    self.scrollView.contentInset = insets;
    self.scrollView.scrollIndicatorInsets = insets;
}

- (void)keyboardWillHide:(NSNotification *)notification {
    NSTimeInterval duration = [notification.userInfo[UIKeyboardAnimationDurationUserInfoKey] doubleValue];

    [UIView animateWithDuration:duration animations:^{
        self.createButtonBottomConstraint.constant = -16;
        [self.view layoutIfNeeded];
    }];

    UIEdgeInsets insets = self.scrollView.contentInset;
    insets.bottom = 80;
    self.scrollView.contentInset = insets;
    self.scrollView.scrollIndicatorInsets = insets;
}

#pragma mark - UITextFieldDelegate

- (BOOL)textFieldShouldReturn:(UITextField *)textField {
    // 按顺序切换焦点
    if (textField == self.nameField) {
        [self.networkIdField becomeFirstResponder];
    } else if (textField == self.networkIdField) {
        [self.serverField becomeFirstResponder];
    } else if (textField == self.serverField) {
        [self.portField becomeFirstResponder];
    } else if (textField == self.portField) {
        [self.passwordField becomeFirstResponder];
    } else if (textField == self.passwordField) {
        [textField resignFirstResponder];
        [self createButtonTapped];
    }
    return YES;
}

- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    // 更新渐变层 frame 以匹配按钮尺寸
    if (self.createButtonGradient) {
        self.createButtonGradient.frame = self.createButton.bounds;
    }
}

@end

#pragma mark - ScanImportRoomViewController

/// 扫描/粘贴导入房间 ViewController
///
/// 参照 HMCL 的导入房间界面风格设计：
/// - 顶部说明卡片，告知用户可粘贴分享文本或扫描二维码得到的内容
/// - 中间多行文本输入框，支持粘贴
/// - 实时解析预览：用户输入后即时显示解析出的房间信息
/// - "从剪贴板粘贴"快捷按钮
/// - 底部"导入房间"按钮（渐变色背景）
///
/// 由于 iOS 相机权限需要 Info.plist 中配置 NSCameraUsageDescription，
/// 本界面不直接调用相机，而是让用户粘贴二维码扫描结果或分享文本。
/// 用户可使用系统相机或任何二维码扫描 App 扫描后，将内容粘贴到此处。
@interface ScanImportRoomViewController () <UITextViewDelegate>

/// 主滚动视图
@property (nonatomic, strong) UIScrollView *scrollView;
/// 内容容器
@property (nonatomic, strong) UIView *contentView;
/// 多行文本输入框
@property (nonatomic, strong) UITextView *textView;
/// 占位文字标签（textVield 没有原生 placeholder）
@property (nonatomic, strong) UILabel *placeholderLabel;
/// 解析预览容器
@property (nonatomic, strong) UIView *previewContainer;
/// 解析预览内容标签
@property (nonatomic, strong) UILabel *previewLabel;
/// 从剪贴板粘贴按钮
@property (nonatomic, strong) UIButton *pasteButton;
/// 底部导入按钮
@property (nonatomic, strong) UIButton *importButton;
/// 导入按钮渐变层
@property (nonatomic, strong) CAGradientLayer *importButtonGradient;
/// 导入按钮底部约束（键盘避让）
@property (nonatomic, strong) NSLayoutConstraint *importButtonBottomConstraint;
/// 当前解析出的房间对象（nil 表示未解析成功）
@property (nonatomic, strong) MultiplayerRoom *parsedRoom;

/// 导入完成回调
@property (nonatomic, copy) void (^onRoomImported)(MultiplayerRoom *room);

@end

@implementation ScanImportRoomViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = MPLocalized(@"mp.scan_import.title", @"扫描/导入房间");
    [[BackgroundManager sharedManager] makeViewControllerTransparent:self];

    [self setupUI];
    [self setupKeyboardObservers];

    // 导航栏左侧取消按钮
    UIBarButtonItem *cancelButton = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemCancel
                                                                                   target:self
                                                                                   action:@selector(cancelTapped)];
    self.navigationItem.leftBarButtonItem = cancelButton;

    [[BackgroundManager sharedManager] applyEffectToNavigationBar:self.navigationController.navigationBar];
}

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

#pragma mark - UI Setup

- (void)setupUI {
    self.view.backgroundColor = [UIColor systemGroupedBackgroundColor];

    _scrollView = [[UIScrollView alloc] init];
    _scrollView.translatesAutoresizingMaskIntoConstraints = NO;
    _scrollView.alwaysBounceVertical = YES;
    _scrollView.keyboardDismissMode = UIScrollViewKeyboardDismissModeInteractive;
    _scrollView.backgroundColor = [UIColor clearColor];
    [self.view addSubview:_scrollView];

    _contentView = [[UIView alloc] init];
    _contentView.translatesAutoresizingMaskIntoConstraints = NO;
    [_scrollView addSubview:_contentView];

    // 区段标题：使用说明
    UILabel *instructionHeader = [[UILabel alloc] init];
    instructionHeader.translatesAutoresizingMaskIntoConstraints = NO;
    instructionHeader.text = MPLocalized(@"mp.scan_import.section.instruction", @"使用说明");
    instructionHeader.font = [UIFont systemFontOfSize:13 weight:UIFontWeightSemibold];
    instructionHeader.textColor = [UIColor secondaryLabelColor];
    [self.contentView addSubview:instructionHeader];

    // 说明卡片
    UIView *instructionCard = [self makeCardContainer];
    [self.contentView addSubview:instructionCard];

    UILabel *instructionLabel = [[UILabel alloc] init];
    instructionLabel.translatesAutoresizingMaskIntoConstraints = NO;
    instructionLabel.font = [UIFont systemFontOfSize:13];
    instructionLabel.textColor = [UIColor secondaryLabelColor];
    instructionLabel.numberOfLines = 0;
    instructionLabel.text = MPLocalized(@"mp.scan_import.instruction_text",
                                        @"粘贴朋友分享的房间文本，或使用二维码扫描工具扫描后粘贴内容到下方输入框。系统会自动解析并预览房间信息。");
    [instructionCard addSubview:instructionLabel];

    // 区段标题：输入框
    UILabel *inputHeader = [[UILabel alloc] init];
    inputHeader.translatesAutoresizingMaskIntoConstraints = NO;
    inputHeader.text = MPLocalized(@"mp.scan_import.section.input", @"房间分享文本");
    inputHeader.font = [UIFont systemFontOfSize:13 weight:UIFontWeightSemibold];
    inputHeader.textColor = [UIColor secondaryLabelColor];
    [self.contentView addSubview:inputHeader];

    // 输入卡片（含 textVield）
    UIView *inputCard = [self makeCardContainer];
    [self.contentView addSubview:inputCard];

    _textView = [[UITextView alloc] init];
    _textView.translatesAutoresizingMaskIntoConstraints = NO;
    _textView.font = [UIFont systemFontOfSize:14];
    _textView.backgroundColor = [UIColor clearColor];
    _textView.delegate = self;
    _textView.autocorrectionType = UITextAutocorrectionTypeNo;
    _textView.autocapitalizationType = UITextAutocapitalizationTypeNone;
    _textView.layer.cornerRadius = 8;
    _textView.layer.masksToBounds = YES;
    [inputCard addSubview:_textView];

    // placeholder 标签
    _placeholderLabel = [[UILabel alloc] init];
    _placeholderLabel.translatesAutoresizingMaskIntoConstraints = NO;
    _placeholderLabel.text = MPLocalized(@"mp.scan_import.placeholder", @"在此粘贴分享文本或二维码内容…");
    _placeholderLabel.font = [UIFont systemFontOfSize:14];
    _placeholderLabel.textColor = [UIColor placeholderTextColor];
    _placeholderLabel.numberOfLines = 0;
    [_textView addSubview:_placeholderLabel];

    // 从剪贴板粘贴按钮
    _pasteButton = [UIButton buttonWithType:UIButtonTypeSystem];
    _pasteButton.translatesAutoresizingMaskIntoConstraints = NO;
    [_pasteButton setImage:[UIImage systemImageNamed:@"doc.on.clipboard"] forState:UIControlStateNormal];
    [_pasteButton setTitle:MPLocalized(@"mp.scan_import.paste_button", @"从剪贴板粘贴") forState:UIControlStateNormal];
    _pasteButton.titleLabel.font = [UIFont systemFontOfSize:14 weight:UIFontWeightMedium];
    _pasteButton.tintColor = [UIColor systemBlueColor];
    _pasteButton.layer.cornerRadius = 8;
    _pasteButton.layer.masksToBounds = YES;
    _pasteButton.backgroundColor = [[UIColor systemBlueColor] colorWithAlphaComponent:0.1];
    _pasteButton.imageEdgeInsets = UIEdgeInsetsMake(0, -4, 0, 4);
    [_pasteButton addTarget:self action:@selector(pasteButtonTapped) forControlEvents:UIControlEventTouchUpInside];
    [self.contentView addSubview:_pasteButton];

    // 区段标题：解析预览
    UILabel *previewHeader = [[UILabel alloc] init];
    previewHeader.translatesAutoresizingMaskIntoConstraints = NO;
    previewHeader.text = MPLocalized(@"mp.scan_import.section.preview", @"解析预览");
    previewHeader.font = [UIFont systemFontOfSize:13 weight:UIFontWeightSemibold];
    previewHeader.textColor = [UIColor secondaryLabelColor];
    [self.contentView addSubview:previewHeader];

    // 预览卡片
    _previewContainer = [self makeCardContainer];
    [self.contentView addSubview:_previewContainer];

    _previewLabel = [[UILabel alloc] init];
    _previewLabel.translatesAutoresizingMaskIntoConstraints = NO;
    _previewLabel.font = [UIFont systemFontOfSize:14];
    _previewLabel.textColor = [UIColor secondaryLabelColor];
    _previewLabel.numberOfLines = 0;
    _previewLabel.text = MPLocalized(@"mp.scan_import.preview_empty", @"输入内容后将显示解析结果");
    [_previewContainer addSubview:_previewLabel];

    // 底部导入按钮
    _importButton = [UIButton buttonWithType:UIButtonTypeSystem];
    _importButton.translatesAutoresizingMaskIntoConstraints = NO;
    _importButton.titleLabel.font = [UIFont systemFontOfSize:16 weight:UIFontWeightSemibold];
    [_importButton setTitle:MPLocalized(@"mp.scan_import.import_button", @"导入房间") forState:UIControlStateNormal];
    [_importButton setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    _importButton.layer.cornerRadius = 14;
    _importButton.layer.masksToBounds = NO;
    _importButton.layer.shadowColor = [UIColor systemBlueColor].CGColor;
    _importButton.layer.shadowOpacity = 0.35;
    _importButton.layer.shadowOffset = CGSizeMake(0, 6);
    _importButton.layer.shadowRadius = 10;
    _importButton.alpha = 0.5; // 默认禁用状态（半透明）
    _importButton.enabled = NO;
    [_importButton addTarget:self action:@selector(importButtonTapped) forControlEvents:UIControlEventTouchUpInside];
    [self.view addSubview:_importButton];

    _importButtonGradient = [CAGradientLayer layer];
    _importButtonGradient.colors = @[(id)[UIColor systemBlueColor].CGColor,
                                     (id)[UIColor systemIndigoColor].CGColor];
    _importButtonGradient.startPoint = CGPointMake(0, 0);
    _importButtonGradient.endPoint = CGPointMake(1, 1);
    [_importButton.layer insertSublayer:_importButtonGradient atIndex:0];

    self.importButtonBottomConstraint = [_importButton.bottomAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.bottomAnchor constant:-16];

    [NSLayoutConstraint activateConstraints:@[
        // 滚动视图
        [_scrollView.topAnchor constraintEqualToAnchor:self.view.topAnchor],
        [_scrollView.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [_scrollView.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [_scrollView.bottomAnchor constraintEqualToAnchor:_importButton.topAnchor constant:-12],

        // 内容容器
        [_contentView.topAnchor constraintEqualToAnchor:_scrollView.contentLayoutGuide.topAnchor constant:16],
        [_contentView.leadingAnchor constraintEqualToAnchor:_scrollView.contentLayoutGuide.leadingAnchor constant:16],
        [_contentView.trailingAnchor constraintEqualToAnchor:_scrollView.contentLayoutGuide.trailingAnchor constant:-16],
        [_contentView.bottomAnchor constraintEqualToAnchor:_scrollView.contentLayoutGuide.bottomAnchor constant:-16],
        [_contentView.widthAnchor constraintEqualToAnchor:_scrollView.frameLayoutGuide.widthAnchor constant:-32],

        // 说明区段
        [instructionHeader.topAnchor constraintEqualToAnchor:self.contentView.topAnchor],
        [instructionHeader.leadingAnchor constraintEqualToAnchor:self.contentView.leadingAnchor],
        [instructionHeader.trailingAnchor constraintEqualToAnchor:self.contentView.trailingAnchor],
        [instructionHeader.heightAnchor constraintEqualToConstant:20],

        [instructionCard.topAnchor constraintEqualToAnchor:instructionHeader.bottomAnchor constant:6],
        [instructionCard.leadingAnchor constraintEqualToAnchor:self.contentView.leadingAnchor],
        [instructionCard.trailingAnchor constraintEqualToAnchor:self.contentView.trailingAnchor],

        [instructionLabel.topAnchor constraintEqualToAnchor:instructionCard.topAnchor constant:12],
        [instructionLabel.leadingAnchor constraintEqualToAnchor:instructionCard.leadingAnchor constant:16],
        [instructionLabel.trailingAnchor constraintEqualToAnchor:instructionCard.trailingAnchor constant:-16],
        [instructionLabel.bottomAnchor constraintEqualToAnchor:instructionCard.bottomAnchor constant:-12],

        // 输入区段
        [inputHeader.topAnchor constraintEqualToAnchor:instructionCard.bottomAnchor constant:24],
        [inputHeader.leadingAnchor constraintEqualToAnchor:self.contentView.leadingAnchor],
        [inputHeader.trailingAnchor constraintEqualToAnchor:self.contentView.trailingAnchor],
        [inputHeader.heightAnchor constraintEqualToConstant:20],

        [inputCard.topAnchor constraintEqualToAnchor:inputHeader.bottomAnchor constant:6],
        [inputCard.leadingAnchor constraintEqualToAnchor:self.contentView.leadingAnchor],
        [inputCard.trailingAnchor constraintEqualToAnchor:self.contentView.trailingAnchor],

        [_textView.topAnchor constraintEqualToAnchor:inputCard.topAnchor constant:12],
        [_textView.leadingAnchor constraintEqualToAnchor:inputCard.leadingAnchor constant:12],
        [_textView.trailingAnchor constraintEqualToAnchor:inputCard.trailingAnchor constant:-12],
        [_textView.bottomAnchor constraintEqualToAnchor:inputCard.bottomAnchor constant:-12],
        [_textView.heightAnchor constraintGreaterThanOrEqualToConstant:120],

        [_placeholderLabel.topAnchor constraintEqualToAnchor:_textView.topAnchor constant:8],
        [_placeholderLabel.leadingAnchor constraintEqualToAnchor:_textView.leadingAnchor constant:4],
        [_placeholderLabel.trailingAnchor constraintEqualToAnchor:_textView.trailingAnchor constant:-4],

        // 粘贴按钮
        [_pasteButton.topAnchor constraintEqualToAnchor:inputCard.bottomAnchor constant:12],
        [_pasteButton.leadingAnchor constraintEqualToAnchor:self.contentView.leadingAnchor],
        [_pasteButton.heightAnchor constraintEqualToConstant:36],
        [_pasteButton.widthAnchor constraintGreaterThanOrEqualToConstant:160],

        // 预览区段
        [previewHeader.topAnchor constraintEqualToAnchor:_pasteButton.bottomAnchor constant:24],
        [previewHeader.leadingAnchor constraintEqualToAnchor:self.contentView.leadingAnchor],
        [previewHeader.trailingAnchor constraintEqualToAnchor:self.contentView.trailingAnchor],
        [previewHeader.heightAnchor constraintEqualToConstant:20],

        [_previewContainer.topAnchor constraintEqualToAnchor:previewHeader.bottomAnchor constant:6],
        [_previewContainer.leadingAnchor constraintEqualToAnchor:self.contentView.leadingAnchor],
        [_previewContainer.trailingAnchor constraintEqualToAnchor:self.contentView.trailingAnchor],
        [_previewContainer.bottomAnchor constraintEqualToAnchor:self.contentView.bottomAnchor],

        [_previewLabel.topAnchor constraintEqualToAnchor:_previewContainer.topAnchor constant:12],
        [_previewLabel.leadingAnchor constraintEqualToAnchor:_previewContainer.leadingAnchor constant:16],
        [_previewLabel.trailingAnchor constraintEqualToAnchor:_previewContainer.trailingAnchor constant:-16],
        [_previewLabel.bottomAnchor constraintEqualToAnchor:_previewContainer.bottomAnchor constant:-12],

        // 导入按钮
        [_importButton.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor constant:20],
        [_importButton.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor constant:-20],
        self.importButtonBottomConstraint,
        [_importButton.heightAnchor constraintEqualToConstant:50],
    ]];
}

- (UIView *)makeCardContainer {
    UIView *card = [[UIView alloc] init];
    card.translatesAutoresizingMaskIntoConstraints = NO;
    card.backgroundColor = [UIColor secondarySystemGroupedBackgroundColor];
    card.layer.cornerRadius = 12;
    card.layer.masksToBounds = YES;
    return card;
}

#pragma mark - Actions

- (void)cancelTapped {
    [self.view endEditing:YES];
    [self dismissViewControllerAnimated:YES completion:nil];
}

- (void)pasteButtonTapped {
    // 从系统剪贴板读取文本
    NSString *clipboardText = [UIPasteboard generalPasteboard].string;
    if (clipboardText.length == 0) {
        [self showSimpleAlertWithTitle:MPLocalized(@"mp.scan_import.clipboard_empty", @"剪贴板为空")
                                message:MPLocalized(@"mp.scan_import.clipboard_empty_msg", @"请先复制分享文本或二维码内容")];
        return;
    }
    self.textView.text = clipboardText;
    [self updatePlaceholderVisibility];
    [self parseAndPreview];
}

- (void)importButtonTapped {
    [self.view endEditing:YES];

    if (!self.parsedRoom) {
        [self showSimpleAlertWithTitle:MPLocalized(@"mp.scan_import.parse_failed", @"解析失败")
                                message:MPLocalized(@"mp.scan_import.parse_failed_msg", @"无法解析输入的文本，请确认格式正确")];
        return;
    }

    // 补充房间 ID 和创建时间
    if (!self.parsedRoom.roomId || self.parsedRoom.roomId.length == 0) {
        self.parsedRoom.roomId = [[MultiplayerManager sharedManager] generateRoomId];
    }
    if (!self.parsedRoom.hostPort || self.parsedRoom.hostPort.length == 0) {
        self.parsedRoom.hostPort = @"25565";
    }
    self.parsedRoom.status = MultiplayerRoomStatusDisconnected;
    self.parsedRoom.createdAt = [NSDate date];

    // 保存到本地列表
    [[MultiplayerManager sharedManager] addRoom:self.parsedRoom];

    // 触发回调
    if (self.onRoomImported) {
        self.onRoomImported(self.parsedRoom);
    }

    [self dismissViewControllerAnimated:YES completion:nil];
}

- (void)showSimpleAlertWithTitle:(NSString *)title message:(NSString *)message {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:title message:message preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:MPLocalized(@"common.ok", @"好") style:UIAlertActionStyleDefault handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
}

#pragma mark - Parse & Preview

/// 解析输入文本并更新预览
- (void)parseAndPreview {
    NSString *text = self.textView.text;
    if (text.length == 0) {
        self.parsedRoom = nil;
        self.previewLabel.text = MPLocalized(@"mp.scan_import.preview_empty", @"输入内容后将显示解析结果");
        self.previewLabel.textColor = [UIColor secondaryLabelColor];
        self.importButton.enabled = NO;
        self.importButton.alpha = 0.5;
        return;
    }

    MultiplayerRoom *parsed = [[MultiplayerManager sharedManager] parseRoomFromShareText:text];
    if (parsed) {
        self.parsedRoom = parsed;
        // 构建预览文本
        NSString *preview = [NSString stringWithFormat:@"%@: %@\n%@: %@\n%@: %@\n%@: %@",
                             MPLocalized(@"mp.scan_import.preview.name", @"房间名称"), parsed.name ?: @"-",
                             MPLocalized(@"mp.scan_import.preview.network_id", @"Network ID"), parsed.networkId ?: @"-",
                             MPLocalized(@"mp.scan_import.preview.address", @"服务器地址"),
                             [NSString stringWithFormat:@"%@:%@", parsed.hostIP ?: @"-", parsed.hostPort ?: @"25565"],
                             MPLocalized(@"mp.scan_import.preview.owner", @"房主"), parsed.ownerName.length ? parsed.ownerName : @"-"];
        self.previewLabel.text = preview;
        self.previewLabel.textColor = [UIColor labelColor];
        self.importButton.enabled = YES;
        self.importButton.alpha = 1.0;
    } else {
        self.parsedRoom = nil;
        self.previewLabel.text = MPLocalized(@"mp.scan_import.preview_invalid", @"无法解析输入的文本，请确认格式正确");
        self.previewLabel.textColor = [UIColor systemRedColor];
        self.importButton.enabled = NO;
        self.importButton.alpha = 0.5;
    }
}

/// 更新 placeholder 显隐
- (void)updatePlaceholderVisibility {
    self.placeholderLabel.hidden = self.textView.text.length > 0;
}

#pragma mark - UITextViewDelegate

- (void)textViewDidChange:(UITextView *)textView {
    [self updatePlaceholderVisibility];
    [self parseAndPreview];
}

#pragma mark - Keyboard Handling

- (void)setupKeyboardObservers {
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(keyboardWillShow:)
                                                 name:UIKeyboardWillShowNotification
                                               object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(keyboardWillHide:)
                                                 name:UIKeyboardWillHideNotification
                                               object:nil];
}

- (void)keyboardWillShow:(NSNotification *)notification {
    CGRect keyboardFrame = [notification.userInfo[UIKeyboardFrameEndUserInfoKey] CGRectValue];
    CGFloat keyboardHeight = keyboardFrame.size.height;
    NSTimeInterval duration = [notification.userInfo[UIKeyboardAnimationDurationUserInfoKey] doubleValue];

    [UIView animateWithDuration:duration animations:^{
        self.importButtonBottomConstraint.constant = -keyboardHeight - 16;
        [self.view layoutIfNeeded];
    }];

    UIEdgeInsets insets = self.scrollView.contentInset;
    insets.bottom = keyboardHeight + 80;
    self.scrollView.contentInset = insets;
    self.scrollView.scrollIndicatorInsets = insets;
}

- (void)keyboardWillHide:(NSNotification *)notification {
    NSTimeInterval duration = [notification.userInfo[UIKeyboardAnimationDurationUserInfoKey] doubleValue];

    [UIView animateWithDuration:duration animations:^{
        self.importButtonBottomConstraint.constant = -16;
        [self.view layoutIfNeeded];
    }];

    UIEdgeInsets insets = self.scrollView.contentInset;
    insets.bottom = 80;
    self.scrollView.contentInset = insets;
    self.scrollView.scrollIndicatorInsets = insets;
}

- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    if (self.importButtonGradient) {
        self.importButtonGradient.frame = self.importButton.bounds;
    }
}

@end

#pragma mark - MultiplayerViewController

@interface MultiplayerViewController () <UITableViewDataSource, UITableViewDelegate, MultiplayerManagerDelegate>

@property (nonatomic, strong) UITableView *tableView;
@property (nonatomic, strong) NSArray<MultiplayerRoom *> *rooms;

// 快速直连输入缓存
@property (nonatomic, copy) NSString *directIP;
@property (nonatomic, copy) NSString *directPort;

@end

@implementation MultiplayerViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = MPLocalized(@"mp.title", @"联机");

    // 适配自定义启动器背景：透明化当前 VC，让全局背景图/毛玻璃透出
    [[BackgroundManager sharedManager] makeViewControllerTransparent:self];

    // 初始化数据
    self.rooms = [[MultiplayerManager sharedManager] savedRooms] ?: @[];
    self.directIP = @"";
    self.directPort = @"25565";

    [self setupUI];

    // 注册为 MultiplayerManager 代理，接收节点/网络状态变化的实时回调
    [MultiplayerManager sharedManager].delegate = self;

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
    // 清除代理引用
    if ([MultiplayerManager sharedManager].delegate == self) {
        [MultiplayerManager sharedManager].delegate = nil;
    }
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

    // 导航栏按钮：左上角关闭
    UIBarButtonItem *closeButton = [[UIBarButtonItem alloc] initWithImage:[UIImage systemImageNamed:@"xmark"]
                                                                     style:UIBarButtonItemStylePlain
                                                                    target:self
                                                                    action:@selector(closeTapped)];
    closeButton.accessibilityLabel = MPLocalized(@"mp.close", @"关闭");
    self.navigationItem.leftBarButtonItem = closeButton;

    // 右上角按钮组：扫描加入 + 创建房间（+）
    UIBarButtonItem *scanButton = [[UIBarButtonItem alloc] initWithImage:[UIImage systemImageNamed:@"qrcode.viewfinder"]
                                                                    style:UIBarButtonItemStylePlain
                                                                   target:self
                                                                   action:@selector(scanJoinTapped)];
    scanButton.accessibilityLabel = MPLocalized(@"mp.scan_join", @"扫描加入");

    UIBarButtonItem *addButton = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemAdd
                                                                               target:self
                                                                               action:@selector(addButtonTapped)];
    // rightBarButtonItems 数组中第一个元素显示在最右侧
    self.navigationItem.rightBarButtonItems = @[addButton, scanButton];

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
    // 推入 CreateRoomViewController（创建模式）
    [self showCreateRoom];
}

- (void)scanJoinTapped {
    // 推入 ScanImportRoomViewController
    [self showScanImportRoom];
}

#pragma mark - 创建房间（推入 CreateRoomViewController）

- (void)showCreateRoom {
    CreateRoomViewController *createVC = [[CreateRoomViewController alloc] init];
    // 使用 Form Sheet 风格呈现，适配 iPad
    createVC.modalPresentationStyle = UIModalPresentationPageSheet;

    __weak typeof(self) weakSelf = self;
    createVC.onRoomSaved = ^(MultiplayerRoom *room) {
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (strongSelf) {
            [strongSelf refreshRooms];
        }
    };

    // 使用导航控制器包裹，以便显示标题栏和取消按钮
    UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:createVC];
    nav.modalPresentationStyle = UIModalPresentationPageSheet;
    [[BackgroundManager sharedManager] applyEffectToNavigationBar:nav.navigationBar];
    [self presentViewController:nav animated:YES completion:nil];
}

#pragma mark - 编辑房间（推入 CreateRoomViewController 编辑模式）

- (void)showEditRoom:(MultiplayerRoom *)room {
    CreateRoomViewController *editVC = [[CreateRoomViewController alloc] initWithRoom:room];
    editVC.modalPresentationStyle = UIModalPresentationPageSheet;

    __weak typeof(self) weakSelf = self;
    editVC.onRoomSaved = ^(MultiplayerRoom *savedRoom) {
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (strongSelf) {
            [strongSelf refreshRooms];
        }
    };

    UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:editVC];
    nav.modalPresentationStyle = UIModalPresentationPageSheet;
    [[BackgroundManager sharedManager] applyEffectToNavigationBar:nav.navigationBar];
    [self presentViewController:nav animated:YES completion:nil];
}

#pragma mark - 扫描/导入房间（推入 ScanImportRoomViewController）

- (void)showScanImportRoom {
    ScanImportRoomViewController *scanVC = [[ScanImportRoomViewController alloc] init];
    scanVC.modalPresentationStyle = UIModalPresentationPageSheet;

    __weak typeof(self) weakSelf = self;
    scanVC.onRoomImported = ^(MultiplayerRoom *room) {
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (strongSelf) {
            [strongSelf refreshRooms];
            [strongSelf showSimpleAlertWithTitle:MPLocalized(@"mp.scan_import.success_title", @"导入成功")
                                         message:[NSString stringWithFormat:@"%@「%@」",
                                                  MPLocalized(@"mp.scan_import.success_prefix", @"房间"),
                                                  room.name]];
        }
    };

    UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:scanVC];
    nav.modalPresentationStyle = UIModalPresentationPageSheet;
    [[BackgroundManager sharedManager] applyEffectToNavigationBar:nav.navigationBar];
    [self presentViewController:nav animated:YES completion:nil];
}

#pragma mark - 房间详情 ActionSheet

- (void)showRoomDetailActionsForRoom:(MultiplayerRoom *)room {
    UIAlertController *sheet = [UIAlertController alertControllerWithTitle:room.name
                                                                   message:[NSString stringWithFormat:@"%@:%@", room.hostIP, room.hostPort]
                                                            preferredStyle:UIAlertControllerStyleActionSheet];

    // 连接/断开
    NSString *connectTitle = (room.status == MultiplayerRoomStatusConnected) ? MPLocalized(@"mp.room.action.disconnect", @"断开连接") : MPLocalized(@"mp.room.action.connect", @"连接房间");
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
                    [self showSimpleAlertWithTitle:MPLocalized(@"mp.connect.failed", @"连接失败") message:error.localizedDescription ?: MPLocalized(@"mp.connect.failed_msg", @"无法连接到房间")];
                }
            }];
        }
    }]];

    // 编辑房间（推入 CreateRoomViewController 编辑模式）
    [sheet addAction:[UIAlertAction actionWithTitle:MPLocalized(@"mp.room.action.edit", @"编辑房间") style:UIAlertActionStyleDefault handler:^(UIAlertAction * _Nonnull action) {
        [self showEditRoom:room];
    }]];

    // 分享房间
    [sheet addAction:[UIAlertAction actionWithTitle:MPLocalized(@"mp.room.action.share", @"分享房间") style:UIAlertActionStyleDefault handler:^(UIAlertAction * _Nonnull action) {
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
    [sheet addAction:[UIAlertAction actionWithTitle:MPLocalized(@"mp.room.action.delete", @"删除房间") style:UIAlertActionStyleDestructive handler:^(UIAlertAction * _Nonnull action) {
        // 二次确认
        UIAlertController *confirm = [UIAlertController alertControllerWithTitle:MPLocalized(@"mp.room.delete.confirm_title", @"确认删除")
                                                                          message:[NSString stringWithFormat:@"%@「%@」？\n%@",
                                                                                   MPLocalized(@"mp.room.delete.confirm_prefix", @"确定要删除房间"),
                                                                                   room.name,
                                                                                   MPLocalized(@"mp.room.delete.confirm_warning", @"此操作无法撤销。")]
                                                                   preferredStyle:UIAlertControllerStyleAlert];
        [confirm addAction:[UIAlertAction actionWithTitle:MPLocalized(@"common.cancel", @"取消") style:UIAlertActionStyleCancel handler:nil]];
        [confirm addAction:[UIAlertAction actionWithTitle:MPLocalized(@"mp.room.delete.button", @"删除") style:UIAlertActionStyleDestructive handler:^(UIAlertAction * _Nonnull action) {
            [[MultiplayerManager sharedManager] removeRoom:room.roomId];
            [self refreshRooms];
        }]];
        [self presentViewController:confirm animated:YES completion:nil];
    }]];

    [sheet addAction:[UIAlertAction actionWithTitle:MPLocalized(@"common.cancel", @"取消") style:UIAlertActionStyleCancel handler:nil]];

    // iPad 适配：popover 指向当前行
    if (sheet.popoverPresentationController) {
        sheet.popoverPresentationController.sourceView = self.view;
        sheet.popoverPresentationController.sourceRect = CGRectMake(self.view.bounds.size.width / 2.0, self.view.bounds.size.height / 2.0, 1, 1);
    }

    [self presentViewController:sheet animated:YES completion:nil];
}

#pragma mark - 连接房间

- (void)connectToRoom:(MultiplayerRoom *)room completion:(void (^)(BOOL success, NSError *error))completion {
    // 先更新状态为连接中
    room.status = MultiplayerRoomStatusConnecting;
    [[MultiplayerManager sharedManager] updateRoom:room];
    [self refreshRooms];

    // 检查 ZeroTier 框架是否可用（进程内联机核心）
    if (![[MultiplayerManager sharedManager] isFrameworkAvailable]) {
        room.status = MultiplayerRoomStatusError;
        [[MultiplayerManager sharedManager] updateRoom:room];
        [self refreshRooms];

        // 提示用户联机核心未加载
        UIAlertController *alert = [UIAlertController alertControllerWithTitle:MPLocalized(@"mp.core.unavailable_title", @"联机核心不可用")
                                                                       message:MPLocalized(@"mp.core.unavailable_msg", @"ZeroTier 联机核心未加载（当前为 stub 实现）。请使用包含真实 zt.framework 的构建版本。")
                                                                preferredStyle:UIAlertControllerStyleAlert];
        [alert addAction:[UIAlertAction actionWithTitle:MPLocalized(@"common.ok", @"好") style:UIAlertActionStyleDefault handler:nil]];
        [self presentViewController:alert animated:YES completion:nil];

        if (completion) {
            NSError *error = [NSError errorWithDomain:@"Multiplayer" code:-1 userInfo:@{NSLocalizedDescriptionKey: MPLocalized(@"mp.core.unavailable_error", @"ZeroTier 联机核心不可用")}];
            completion(NO, error);
        }
        return;
    }

    // 调用管理器连接房间（内部会启动 ZeroTier 节点、加入网络、启动 SOCKS5 代理）
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
        [self showSimpleAlertWithTitle:MPLocalized(@"mp.direct.error_title", @"提示") message:MPLocalized(@"mp.direct.error.ip_empty", @"请输入服务器 IP 地址")];
        return;
    }
    if (!port || port.length == 0) {
        port = @"25565";
    }

    // 验证 IP 格式（简单校验：包含点分十进制或 ZeroTier 风格地址）
    if (![self isValidIPAddress:ip]) {
        [self showSimpleAlertWithTitle:MPLocalized(@"mp.direct.error_title", @"提示") message:MPLocalized(@"mp.direct.error.ip_invalid", @"IP 地址格式不正确，请检查输入")];
        return;
    }

    // 生成服务器地址 "IP:端口"
    NSString *serverAddress = [NSString stringWithFormat:@"%@:%@", ip, port];

    // 将服务器地址添加到当前 profile（使用 PLProfiles 现有 API）
    [self addServerToProfile:[PLProfiles current].selectedProfileName address:serverAddress];

    // 显示成功提示
    [self showSimpleAlertWithTitle:MPLocalized(@"mp.direct.success_title", @"已添加服务器")
                           message:MPLocalized(@"mp.direct.success_msg", @"已添加服务器，请在游戏中点击\"多人游戏\"加入")];
}

/// 将服务器地址写入指定 profile（基于 PLProfiles 的 setServerIp:forProfile: 实现）
- (void)addServerToProfile:(NSString *)profileName address:(NSString *)address {
    if (!profileName || profileName.length == 0) {
        profileName = [PLProfiles current].selectedProfileName;
    }
    [[PLProfiles current] setServerIp:address forProfile:profileName];
}

#pragma mark - 状态刷新

/// 手动刷新状态卡片（由状态卡片的刷新按钮触发）
- (void)refreshStatus {
    dispatch_async(dispatch_get_main_queue(), ^{
        // 仅刷新 Section 0（状态卡片），避免整个表格闪烁
        NSIndexSet *indexSet = [NSIndexSet indexSetWithIndex:0];
        [self.tableView reloadSections:indexSet withRowAnimation:UITableViewRowAnimationAutomatic];
    });
}

#pragma mark - MultiplayerManagerDelegate

/// ZeroTier 节点已上线：刷新状态卡片
- (void)multiplayerNodeOnline {
    [self refreshStatus];
}

/// ZeroTier 节点已离线：刷新状态卡片
- (void)multiplayerNodeOffline {
    [self refreshStatus];
}

/// 指定房间已连接成功：刷新房间列表
- (void)multiplayerRoomConnected:(MultiplayerRoom *)room {
    [self refreshRooms];
    [self refreshStatus];
}

/// 指定房间连接失败：刷新房间列表
- (void)multiplayerRoom:(MultiplayerRoom *)room didFailWithError:(NSError *)error {
    [self refreshRooms];
}

/// ZeroTier 框架可用性检测结果：刷新状态卡片
- (void)multiplayerFrameworkAvailabilityChecked:(BOOL)available {
    [self refreshStatus];
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
        [alert addAction:[UIAlertAction actionWithTitle:MPLocalized(@"common.ok", @"好") style:UIAlertActionStyleDefault handler:nil]];
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
            return MPLocalized(@"mp.section.service", @"联机服务");
        case 1:
            return MPLocalized(@"mp.section.rooms", @"联机房间");
        case 2:
            return MPLocalized(@"mp.section.direct", @"快速直连");
        default:
            return nil;
    }
}

- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section {
    if (section == 2) {
        return MPLocalized(@"mp.section.direct_footer", @"输入朋友的 ZeroTier IP 地址和端口，直接加入游戏");
    }
    return nil;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    switch (indexPath.section) {
        case 0: {
            // Section 0: ZeroTier 联机核心状态（增强版，显示节点 ID/IP/网络数/刷新按钮）
            MultiplayerStatusCell *cell = [tableView dequeueReusableCellWithIdentifier:@"StatusCell" forIndexPath:indexPath];
            BOOL available = [[MultiplayerManager sharedManager] isFrameworkAvailable];
            BOOL online = [[MultiplayerManager sharedManager] isNodeOnline];
            NSString *localIP = [[MultiplayerManager sharedManager] currentLocalIP];
            // 节点 ID：通过 ZeroTierBridge 获取（10 位十六进制）
            NSString *nodeId = nil;
            if (online) {
                uint64_t nodeID = [[ZeroTierBridge sharedInstance] nodeID];
                if (nodeID != 0) {
                    nodeId = [NSString stringWithFormat:@"%010llx", nodeID];
                }
            }
            // 网络数：当前连接的房间为 1，否则为 0
            NSInteger networkCount = [[MultiplayerManager sharedManager] currentRoom] ? 1 : 0;
            [cell configureWithAvailable:available
                                  online:online
                                  nodeId:nodeId
                                localIP:localIP
                            networkCount:networkCount];

            // 注入刷新按钮回调
            __weak typeof(self) weakSelf = self;
            cell.onRefreshTapped = ^{
                __strong typeof(weakSelf) strongSelf = weakSelf;
                if (strongSelf) {
                    [strongSelf refreshStatus];
                }
            };

            [[BackgroundManager sharedManager] applyEffectToCell:cell];
            return cell;
        }
        case 1: {
            // Section 1: 联机房间列表（增强版，含状态点/房主徽章/在线人数）
            if (self.rooms.count == 0) {
                // 空状态提示
                UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"EmptyCell" forIndexPath:indexPath];
                cell.textLabel.text = MPLocalized(@"mp.rooms.empty", @"暂无联机房间，点击右上角 + 创建");
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
                            [strongSelf showSimpleAlertWithTitle:MPLocalized(@"mp.connect.failed", @"连接失败") message:error.localizedDescription ?: MPLocalized(@"mp.connect.failed_msg", @"无法连接到房间")];
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
                [cell configureWithPlaceholder:MPLocalized(@"mp.direct.ip_placeholder", @"如 10.147.17.1")
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
                                   buttonTitle:MPLocalized(@"mp.direct.join_button", @"加入游戏")];
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
            // 点击 ZeroTier 联机核心状态行：显示详细信息
            BOOL available = [[MultiplayerManager sharedManager] isFrameworkAvailable];
            BOOL online = [[MultiplayerManager sharedManager] isNodeOnline];
            NSString *title = available ? MPLocalized(@"mp.core.ready_title", @"联机核心已就绪") : MPLocalized(@"mp.core.unavailable_title", @"联机核心不可用");
            NSString *message = nil;
            if (!available) {
                message = MPLocalized(@"mp.core.unavailable_detail", @"当前构建未集成真实的 ZeroTier Framework (zt.framework)，联机功能不可用。\n请使用包含 zt.framework 的构建版本。");
            } else if (online) {
                NSString *socksInfo = [[MultiplayerManager sharedManager] isSOCKS5ProxyRunning]
                    ? [NSString stringWithFormat:@"%@ %u", MPLocalized(@"mp.core.socks_running", @"SOCKS5 代理运行中，端口"), [[MultiplayerManager sharedManager] currentSOCKS5Port]]
                    : MPLocalized(@"mp.core.socks_stopped", @"SOCKS5 代理未运行");
                message = [NSString stringWithFormat:@"%@\n%@", MPLocalized(@"mp.core.online_detail", @"ZeroTier 节点已上线。"), socksInfo];
            } else {
                message = MPLocalized(@"mp.core.offline_detail", @"ZeroTier 节点未上线。点击\"连接房间\"后会自动启动节点。");
            }
            UIAlertController *alert = [UIAlertController alertControllerWithTitle:title
                                                                           message:message
                                                                    preferredStyle:UIAlertControllerStyleAlert];
            [alert addAction:[UIAlertAction actionWithTitle:MPLocalized(@"common.ok", @"好") style:UIAlertActionStyleDefault handler:nil]];
            [self presentViewController:alert animated:YES completion:nil];
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

/// 显示 ZeroTier 联机核心信息（已废弃，保留方法避免调用方崩溃）
/// 新版本使用进程内 zt.framework，无需外部 app 安装检测
- (void)showZeroTierNotInstalledOptions:(NSIndexPath *)indexPath {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:MPLocalized(@"mp.core.info_title", @"联机核心信息")
                                                                   message:MPLocalized(@"mp.core.info_msg", @"当前启动器使用进程内 ZeroTier Framework 进行联机。\n如果联机核心不可用，请使用包含真实 zt.framework 的构建版本。")
                                                            preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:MPLocalized(@"common.ok", @"好") style:UIAlertActionStyleDefault handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
}

- (CGFloat)tableView:(UITableView *)tableView heightForRowAtIndexPath:(NSIndexPath *)indexPath {
    if (indexPath.section == 0) {
        // 状态卡片：增强后需要更多空间显示节点 ID/IP/网络数
        return 110;
    }
    if (indexPath.section == 1) {
        if (self.rooms.count == 0) {
            return 60;
        }
        // 房间卡片：增强后需要更多空间显示状态点/房主徽章/在线人数
        return 92;
    }
    if (indexPath.section == 2) {
        return 52;
    }
    return UITableViewAutomaticDimension;
}

@end
