//
//  EasyTierMultiplayerViewController.m
//  Amethyst
//
//  EasyTier 联机界面实现（参照 FCL 和 ZL2 的陶瓦联机风格）
//
//  本文件实现基于 EasyTier 的 Minecraft 联机功能界面，主要包含：
//
//  1. 联机服务（EasyTier 状态）（Section 0）
//     - 检测 EasyTier app 是否已安装
//     - 显示安装状态（绿色/红色指示灯）
//     - 如果 iOS 版本 < 16.0，显示"EasyTier 需要 iOS 16.0 及以上系统"警告
//     - "打开 EasyTier App" 按钮（如果未安装则显示"下载 EasyTier"）
//     - 系统要求说明：EasyTier 支持 iOS 16+，ZeroTier 支持 iOS 13+，本启动器支持 iOS 14+
//
//  2. 联机房间（Section 1）
//     - 房间列表（每个房间显示：名称、邀请码、角色标签[房主/房客]、状态）
//     - 点击房间卡片：展开操作选项（连接/断开、分享邀请码、编辑、删除）
//     - 右上角"+"按钮：创建房间对话框
//       - 选择"我要当房主"→ 输入房间名 → 生成邀请码 → 显示邀请码供分享
//       - 选择"我要当房客"→ 输入邀请码（实时验证）→ 保存房间
//     - 滑动删除房间
//
//  3. 快速直连（Section 2）
//     - IP 地址输入框
//     - 端口输入框 + 加入游戏按钮
//     - 直接将服务器地址写入当前 profile，启动游戏后自动加入
//
//  自定义 Cell：
//  - EasyTierStatusCell：EasyTier 状态展示（含打开/下载按钮）
//  - EasyTierInfoCell：系统要求与 iOS 版本警告
//  - EasyTierRoomCell：房间列表项（含角色标签）
//  - EasyTierInputCell：直连输入框
//
//  背景适配：
//  - 通过 BackgroundManager 透明化视图控制器
//  - 监听 BackgroundUIEffectChanged 通知动态刷新
//  - 有自定义背景时使用白色文字，无背景时使用系统默认色
//
//  邀请码格式：U/XXXX-XXXX-XXXX-XXXX（21 字符，与 HMCL/FCL/ZL2/PCL2 互通）
//

#import "EasyTierMultiplayerViewController.h"
#import "EasyTierMultiplayerManager.h"
#import "BackgroundManager.h"
#import "LauncherPreferences.h"
#import "PLProfiles.h"

#pragma mark - EasyTierStatusCell

/// EasyTier 状态展示 Cell（Section 0, Row 0）
/// 左侧图标 + 中间标题/状态 + 右侧打开/下载按钮
@interface EasyTierStatusCell : UITableViewCell

@property (nonatomic, strong) UIView *iconView;
@property (nonatomic, strong) UIImageView *iconImageView;
@property (nonatomic, strong) UILabel *titleLabel;
@property (nonatomic, strong) UILabel *subtitleLabel;
@property (nonatomic, strong) UIButton *actionButton;

- (void)configureWithInstalled:(BOOL)installed;

@end

@implementation EasyTierStatusCell

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
    // 左侧图标容器：40x40 圆角方块，紫色背景
    _iconView = [[UIView alloc] init];
    _iconView.translatesAutoresizingMaskIntoConstraints = NO;
    _iconView.backgroundColor = [UIColor systemPurpleColor];
    _iconView.layer.cornerRadius = 10;
    _iconView.layer.masksToBounds = YES;
    [self.contentView addSubview:_iconView];

    // 图标：SF Symbol antenna.radiowaves.left.and.right，白色
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
    _titleLabel.text = @"EasyTier 虚拟局域网";
    [self.contentView addSubview:_titleLabel];

    // 副标题：12pt secondary，显示安装状态
    _subtitleLabel = [[UILabel alloc] init];
    _subtitleLabel.translatesAutoresizingMaskIntoConstraints = NO;
    _subtitleLabel.font = [UIFont systemFontOfSize:12];
    _subtitleLabel.textColor = [UIColor secondaryLabelColor];
    [self.contentView addSubview:_subtitleLabel];

    // 右侧操作按钮：打开 EasyTier / 下载 EasyTier
    _actionButton = [UIButton buttonWithType:UIButtonTypeSystem];
    _actionButton.translatesAutoresizingMaskIntoConstraints = NO;
    _actionButton.titleLabel.font = [UIFont systemFontOfSize:14 weight:UIFontWeightMedium];
    _actionButton.layer.cornerRadius = 8;
    _actionButton.layer.masksToBounds = YES;
    _actionButton.contentEdgeInsets = UIEdgeInsetsMake(6, 12, 6, 12);
    [self.contentView addSubview:_actionButton];

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

        [_actionButton.trailingAnchor constraintEqualToAnchor:self.contentView.trailingAnchor constant:-16],
        [_actionButton.centerYAnchor constraintEqualToAnchor:self.contentView.centerYAnchor],

        [_titleLabel.trailingAnchor constraintEqualToAnchor:_actionButton.leadingAnchor constant:-12],
        [_subtitleLabel.trailingAnchor constraintEqualToAnchor:_actionButton.leadingAnchor constant:-12],
    ]];
}

- (void)configureWithInstalled:(BOOL)installed {
    if (installed) {
        self.subtitleLabel.text = @"已安装";
        [self.actionButton setTitle:@"打开" forState:UIControlStateNormal];
        [self.actionButton setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
        self.actionButton.backgroundColor = [UIColor systemBlueColor];
    } else {
        self.subtitleLabel.text = @"未安装";
        [self.actionButton setTitle:@"下载" forState:UIControlStateNormal];
        [self.actionButton setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
        self.actionButton.backgroundColor = [UIColor systemOrangeColor];
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

#pragma mark - EasyTierInfoCell

/// 系统信息 Cell（Section 0, Row 1）
/// 显示系统要求说明和 iOS 版本警告
@interface EasyTierInfoCell : UITableViewCell

@property (nonatomic, strong) UIImageView *iconImageView;
@property (nonatomic, strong) UILabel *infoLabel;

- (void)configureWithIOSVersion;

@end

@implementation EasyTierInfoCell

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
    _iconImageView = [[UIImageView alloc] init];
    _iconImageView.translatesAutoresizingMaskIntoConstraints = NO;
    _iconImageView.contentMode = UIViewContentModeScaleAspectFit;
    [self.contentView addSubview:_iconImageView];

    _infoLabel = [[UILabel alloc] init];
    _infoLabel.translatesAutoresizingMaskIntoConstraints = NO;
    _infoLabel.font = [UIFont systemFontOfSize:12];
    _infoLabel.numberOfLines = 0;
    [self.contentView addSubview:_infoLabel];

    [NSLayoutConstraint activateConstraints:@[
        [_iconImageView.leadingAnchor constraintEqualToAnchor:self.contentView.leadingAnchor constant:16],
        [_iconImageView.topAnchor constraintEqualToAnchor:self.contentView.topAnchor constant:14],
        [_iconImageView.widthAnchor constraintEqualToConstant:18],
        [_iconImageView.heightAnchor constraintEqualToConstant:18],

        [_infoLabel.leadingAnchor constraintEqualToAnchor:_iconImageView.trailingAnchor constant:8],
        [_infoLabel.topAnchor constraintEqualToAnchor:self.contentView.topAnchor constant:12],
        [_infoLabel.bottomAnchor constraintEqualToAnchor:self.contentView.bottomAnchor constant:-12],
        [_infoLabel.trailingAnchor constraintEqualToAnchor:self.contentView.trailingAnchor constant:-16],
    ]];
}

- (void)configureWithIOSVersion {
    BOOL hasBackground = [[BackgroundManager sharedManager] hasBackground];

    // 检查 iOS 版本是否满足 EasyTier 要求（iOS 16.0+）
    if (@available(iOS 16.0, *)) {
        // iOS 16+，显示系统要求说明
        self.iconImageView.image = [UIImage systemImageNamed:@"info.circle"];
        self.iconImageView.tintColor = [UIColor secondaryLabelColor];
        self.infoLabel.text = @"EasyTier 支持 iOS 16+，ZeroTier 支持 iOS 13+，本启动器支持 iOS 14+。"
                              @"EasyTier 邀请码与 HMCL/FCL/ZL2/PCL2 陶瓦联机互通。";
        if (hasBackground) {
            self.infoLabel.textColor = [UIColor colorWithWhite:1.0 alpha:0.85];
        } else {
            self.infoLabel.textColor = [UIColor secondaryLabelColor];
        }
    } else {
        // iOS < 16.0，显示警告
        self.iconImageView.image = [UIImage systemImageNamed:@"exclamationmark.triangle.fill"];
        self.iconImageView.tintColor = [UIColor systemOrangeColor];
        self.infoLabel.text = @"EasyTier app 需要 iOS 16.0 及以上系统，当前系统版本不满足要求。"
                              @"可使用 ZeroTier（支持 iOS 13+）或在「快速直连」中直接输入 IP 加入。";
        if (hasBackground) {
            self.infoLabel.textColor = [UIColor systemYellowColor];
        } else {
            self.infoLabel.textColor = [UIColor systemOrangeColor];
        }
    }
}

@end

#pragma mark - EasyTierRoomCell

/// EasyTier 联机房间列表 Cell（Section 1）
/// 左侧房间图标 + 中间房间名/角色标签/邀请码 + 右侧状态指示
@interface EasyTierRoomCell : UITableViewCell

@property (nonatomic, strong) UIView *iconView;
@property (nonatomic, strong) UIImageView *iconImageView;
@property (nonatomic, strong) UILabel *nameLabel;
@property (nonatomic, strong) UILabel *roleTagLabel;
@property (nonatomic, strong) UILabel *codeLabel;
@property (nonatomic, strong) UIView *statusDot;
@property (nonatomic, strong) UILabel *statusLabel;

- (void)configureWithRoom:(EasyTierRoom *)room hasBackground:(BOOL)hasBackground;

@end

@implementation EasyTierRoomCell

- (instancetype)initWithStyle:(UITableViewCellStyle)style reuseIdentifier:(NSString *)reuseIdentifier {
    self = [super initWithStyle:style reuseIdentifier:reuseIdentifier];
    if (self) {
        self.backgroundColor = [UIColor secondarySystemGroupedBackgroundColor];
        [self setupSubviews];
    }
    return self;
}

- (void)setupSubviews {
    // 左侧图标容器：36x36 圆角方块
    _iconView = [[UIView alloc] init];
    _iconView.translatesAutoresizingMaskIntoConstraints = NO;
    _iconView.layer.cornerRadius = 10;
    _iconView.layer.masksToBounds = YES;
    [self.contentView addSubview:_iconView];

    // 图标：SF Symbol，白色
    _iconImageView = [[UIImageView alloc] init];
    _iconImageView.translatesAutoresizingMaskIntoConstraints = NO;
    _iconImageView.tintColor = [UIColor whiteColor];
    _iconImageView.contentMode = UIViewContentModeScaleAspectFit;
    [_iconView addSubview:_iconImageView];

    // 房间名：16pt semibold
    _nameLabel = [[UILabel alloc] init];
    _nameLabel.translatesAutoresizingMaskIntoConstraints = NO;
    _nameLabel.font = [UIFont systemFontOfSize:16 weight:UIFontWeightSemibold];
    [self.contentView addSubview:_nameLabel];

    // 角色标签：小尺寸圆角标签（房主/房客）
    _roleTagLabel = [[UILabel alloc] init];
    _roleTagLabel.translatesAutoresizingMaskIntoConstraints = NO;
    _roleTagLabel.font = [UIFont systemFontOfSize:10 weight:UIFontWeightMedium];
    _roleTagLabel.textColor = [UIColor whiteColor];
    _roleTagLabel.textAlignment = NSTextAlignmentCenter;
    _roleTagLabel.layer.cornerRadius = 4;
    _roleTagLabel.layer.masksToBounds = YES;
    [self.contentView addSubview:_roleTagLabel];

    // 邀请码：12pt monospace secondary
    _codeLabel = [[UILabel alloc] init];
    _codeLabel.translatesAutoresizingMaskIntoConstraints = NO;
    _codeLabel.font = [UIFont fontWithName:@"Menlo" size:12] ?: [UIFont systemFontOfSize:12];
    _codeLabel.textColor = [UIColor secondaryLabelColor];
    _codeLabel.lineBreakMode = NSLineBreakByTruncatingTail;
    [self.contentView addSubview:_codeLabel];

    // 状态指示灯：8x8 圆形
    _statusDot = [[UIView alloc] init];
    _statusDot.translatesAutoresizingMaskIntoConstraints = NO;
    _statusDot.layer.cornerRadius = 4;
    _statusDot.layer.masksToBounds = YES;
    [self.contentView addSubview:_statusDot];

    // 状态文字
    _statusLabel = [[UILabel alloc] init];
    _statusLabel.translatesAutoresizingMaskIntoConstraints = NO;
    _statusLabel.font = [UIFont systemFontOfSize:11];
    [self.contentView addSubview:_statusLabel];

    [NSLayoutConstraint activateConstraints:@[
        [_iconView.leadingAnchor constraintEqualToAnchor:self.contentView.leadingAnchor constant:16],
        [_iconView.centerYAnchor constraintEqualToAnchor:self.contentView.centerYAnchor],
        [_iconView.widthAnchor constraintEqualToConstant:36],
        [_iconView.heightAnchor constraintEqualToConstant:36],

        [_iconImageView.centerXAnchor constraintEqualToAnchor:_iconView.centerXAnchor],
        [_iconImageView.centerYAnchor constraintEqualToAnchor:_iconView.centerYAnchor],
        [_iconImageView.widthAnchor constraintEqualToConstant:20],
        [_iconImageView.heightAnchor constraintEqualToConstant:20],

        // 房间名在图标右侧
        [_nameLabel.leadingAnchor constraintEqualToAnchor:_iconView.trailingAnchor constant:12],
        [_nameLabel.topAnchor constraintEqualToAnchor:self.contentView.topAnchor constant:12],

        // 角色标签紧跟房间名右侧
        [_roleTagLabel.leadingAnchor constraintEqualToAnchor:_nameLabel.trailingAnchor constant:8],
        [_roleTagLabel.centerYAnchor constraintEqualToAnchor:_nameLabel.centerYAnchor],
        [_roleTagLabel.heightAnchor constraintEqualToConstant:18],

        // 邀请码在房间名下方
        [_codeLabel.leadingAnchor constraintEqualToAnchor:_nameLabel.leadingAnchor],
        [_codeLabel.topAnchor constraintEqualToAnchor:_nameLabel.bottomAnchor constant:4],
        [_codeLabel.bottomAnchor constraintEqualToAnchor:self.contentView.bottomAnchor constant:-12],

        // 状态指示灯和文字在右侧
        [_statusLabel.trailingAnchor constraintEqualToAnchor:self.contentView.trailingAnchor constant:-16],
        [_statusLabel.centerYAnchor constraintEqualToAnchor:self.contentView.centerYAnchor],

        [_statusDot.trailingAnchor constraintEqualToAnchor:_statusLabel.leadingAnchor constant:-4],
        [_statusDot.centerYAnchor constraintEqualToAnchor:self.contentView.centerYAnchor],
        [_statusDot.widthAnchor constraintEqualToConstant:8],
        [_statusDot.heightAnchor constraintEqualToConstant:8],

        // 房间名和邀请码不延伸到状态区域
        [_nameLabel.trailingAnchor constraintLessThanOrEqualToAnchor:_statusDot.leadingAnchor constant:-12],
        [_codeLabel.trailingAnchor constraintLessThanOrEqualToAnchor:_statusDot.leadingAnchor constant:-12],
    ]];
}

- (void)configureWithRoom:(EasyTierRoom *)room hasBackground:(BOOL)hasBackground {
    self.nameLabel.text = room.name.length ? room.name : @"未命名房间";
    self.codeLabel.text = room.invitationCode ?: @"-";

    // 角色标签与图标颜色
    if (room.role == EasyTierRoomRoleHost) {
        self.roleTagLabel.text = @" 房主 ";
        self.roleTagLabel.backgroundColor = [UIColor systemOrangeColor];
        _iconView.backgroundColor = [UIColor systemOrangeColor];
        _iconImageView.image = [UIImage systemImageNamed:@"crown.fill"];
    } else {
        self.roleTagLabel.text = @" 房客 ";
        self.roleTagLabel.backgroundColor = [UIColor systemBlueColor];
        _iconView.backgroundColor = [UIColor systemBlueColor];
        _iconImageView.image = [UIImage systemImageNamed:@"person.2.fill"];
    }

    // 状态指示
    UIColor *statusColor;
    NSString *statusText;
    switch (room.status) {
        case EasyTierRoomStatusDisconnected:
            statusColor = [UIColor systemGrayColor];
            statusText = @"未连接";
            break;
        case EasyTierRoomStatusConnecting:
            statusColor = [UIColor systemYellowColor];
            statusText = @"连接中";
            break;
        case EasyTierRoomStatusConnected:
            statusColor = [UIColor systemGreenColor];
            statusText = @"已连接";
            break;
        case EasyTierRoomStatusError:
            statusColor = [UIColor systemRedColor];
            statusText = @"错误";
            break;
        default:
            statusColor = [UIColor systemGrayColor];
            statusText = @"-";
            break;
    }
    self.statusDot.backgroundColor = statusColor;
    self.statusLabel.text = statusText;

    // 适配自定义背景
    if (hasBackground) {
        self.nameLabel.textColor = [UIColor whiteColor];
        self.codeLabel.textColor = [UIColor colorWithWhite:1.0 alpha:0.85];
        self.statusLabel.textColor = [UIColor whiteColor];
    } else {
        self.nameLabel.textColor = [UIColor labelColor];
        self.codeLabel.textColor = [UIColor secondaryLabelColor];
        self.statusLabel.textColor = [UIColor secondaryLabelColor];
    }
}

@end

#pragma mark - EasyTierInputCell

/// 快速直连输入 Cell（Section 2）
/// 文本输入框 + 可选的尾部按钮
@interface EasyTierInputCell : UITableViewCell <UITextFieldDelegate>

@property (nonatomic, strong) UITextField *textField;
@property (nonatomic, strong) UIButton *trailingButton;
@property (nonatomic, strong) NSLayoutConstraint *textFieldTrailingConstraint;

@property (nonatomic, copy) void (^onTextChanged)(NSString *text);
@property (nonatomic, copy) void (^onButtonTapped)(NSString *text);

@end

@implementation EasyTierInputCell

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

#pragma mark - EasyTierMultiplayerViewController

@interface EasyTierMultiplayerViewController () <UITableViewDataSource, UITableViewDelegate>

@property (nonatomic, strong) UITableView *tableView;
@property (nonatomic, strong) NSArray<EasyTierRoom *> *rooms;

// 快速直连输入缓存
@property (nonatomic, copy) NSString *directIP;
@property (nonatomic, copy) NSString *directPort;

// 房客创建弹窗的实时验证支持
@property (nonatomic, strong, nullable) UIAlertController *guestAlert;
@property (nonatomic, strong, nullable) UIAlertAction *guestSaveAction;

@end

@implementation EasyTierMultiplayerViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = NSLocalizedString(@"multiplayer.easytier.title", @"EasyTier 联机");

    // 适配自定义启动器背景：透明化当前 VC 和 tableView，让全局背景图/毛玻璃透出
    [[BackgroundManager sharedManager] makeViewControllerTransparent:self];
    [self makeViewControllerTransparent:self.tableView];

    // 初始化数据
    self.rooms = [[EasyTierMultiplayerManager sharedManager] savedRooms] ?: @[];
    self.directIP = @"";
    self.directPort = @"25565";

    [self setupUI];

    // 监听背景效果变化通知，背景切换时重新应用透明效果并刷新表格
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(onBackgroundEffectChanged:)
                                                 name:@"BackgroundUIEffectChanged"
                                               object:nil];
}

- (void)dealloc {
    // 移除通知观察者，避免 dealloc 后收到通知导致崩溃
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

#pragma mark - 背景适配

- (void)makeViewControllerTransparent:(UIView *)view {
    view.backgroundColor = [UIColor clearColor];
    self.view.backgroundColor = [UIColor clearColor];
}

- (void)applyEffectToCell:(UITableViewCell *)cell {
    // 移除旧的背景效果，避免叠加
    for (UIView *subview in cell.contentView.subviews) {
        if ([subview isKindOfClass:[UIVisualEffectView class]]) {
            [subview removeFromSuperview];
        }
    }
    // 应用 BackgroundManager 的效果
    [[BackgroundManager sharedManager] applyEffectToView:cell.contentView];
}

- (void)reapplyBackgroundEffect {
    // 遍历所有可见 cell 重新应用效果
    for (UITableViewCell *cell in self.tableView.visibleCells) {
        [self applyEffectToCell:cell];
    }
}

- (void)onBackgroundEffectChanged:(NSNotification *)notification {
    dispatch_async(dispatch_get_main_queue(), ^{
        // 重新透明化当前 VC
        [[BackgroundManager sharedManager] makeViewControllerTransparent:self];
        self.tableView.backgroundColor = [UIColor clearColor];
        self.tableView.backgroundView = nil;
        // 重新应用导航栏毛玻璃效果
        [[BackgroundManager sharedManager] applyEffectToNavigationBar:self.navigationController.navigationBar];
        // 刷新所有可见 cell 的背景效果和文字颜色
        [self reapplyBackgroundEffect];
        [self.tableView reloadData];
    });
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
    self.tableView.estimatedRowHeight = 84;
    // 注册自定义 cell
    [self.tableView registerClass:[EasyTierStatusCell class] forCellReuseIdentifier:@"StatusCell"];
    [self.tableView registerClass:[EasyTierInfoCell class] forCellReuseIdentifier:@"InfoCell"];
    [self.tableView registerClass:[EasyTierRoomCell class] forCellReuseIdentifier:@"RoomCell"];
    [self.tableView registerClass:[EasyTierInputCell class] forCellReuseIdentifier:@"InputCell"];
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
    // 弹出 ActionSheet 让用户选择：我要当房主 / 我要当房客
    UIAlertController *sheet = [UIAlertController alertControllerWithTitle:nil
                                                                   message:@"添加 EasyTier 联机房间"
                                                            preferredStyle:UIAlertControllerStyleActionSheet];

    [sheet addAction:[UIAlertAction actionWithTitle:@"我要当房主" style:UIAlertActionStyleDefault handler:^(UIAlertAction * _Nonnull action) {
        [self showCreateAsHostDialog];
    }]];

    [sheet addAction:[UIAlertAction actionWithTitle:@"我要当房客" style:UIAlertActionStyleDefault handler:^(UIAlertAction * _Nonnull action) {
        [self showCreateAsGuestDialog];
    }]];

    [sheet addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];

    // iPad 适配：popover 指向 + 按钮
    if (sheet.popoverPresentationController) {
        sheet.popoverPresentationController.barButtonItem = self.navigationItem.rightBarButtonItem;
    }

    [self presentViewController:sheet animated:YES completion:nil];
}

#pragma mark - 创建房间：房主模式

- (void)showCreateAsHostDialog {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"创建房间（房主）"
                                                                   message:@"输入房间名称，系统将自动生成邀请码供朋友加入"
                                                            preferredStyle:UIAlertControllerStyleAlert];

    // 1. 房间名称
    [alert addTextFieldWithConfigurationHandler:^(UITextField * _Nonnull textField) {
        textField.placeholder = @"房间名称，如：和朋友的生存世界";
        textField.autocapitalizationType = UITextAutocapitalizationTypeNone;
        textField.autocorrectionType = UITextAutocorrectionTypeNo;
    }];

    // 2. 服务器端口
    [alert addTextFieldWithConfigurationHandler:^(UITextField * _Nonnull textField) {
        textField.placeholder = @"MC 服务器端口（默认 25565）";
        textField.text = @"25565";
        textField.keyboardType = UIKeyboardTypeNumberPad;
    }];

    [alert addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];

    [alert addAction:[UIAlertAction actionWithTitle:@"创建" style:UIAlertActionStyleDefault handler:^(UIAlertAction * _Nonnull action) {
        NSString *name = alert.textFields[0].text;
        NSString *port = alert.textFields[1].text;

        // 输入验证
        if (!name || name.length == 0) {
            [self showSimpleAlertWithTitle:@"提示" message:@"请输入房间名称"];
            return;
        }
        if (!port || port.length == 0) {
            port = @"25565";
        }

        // 房主模式：使用 initAsHostWithName:hostPort: 创建房间（内部生成邀请码）
        EasyTierRoom *room = [[EasyTierRoom alloc] initAsHostWithName:name hostPort:port];
        if (!room || !room.invitationCode) {
            [self showSimpleAlertWithTitle:@"创建失败" message:@"无法生成邀请码，请稍后重试"];
            return;
        }

        // 保存到本地列表
        [[EasyTierMultiplayerManager sharedManager] addRoom:room];
        [self refreshRooms];

        // 显示邀请码供分享
        [self showInvitationCodeDialog:room.invitationCode roomName:room.name];
    }]];

    [self presentViewController:alert animated:YES completion:nil];
}

#pragma mark - 创建房间：房客模式

- (void)showCreateAsGuestDialog {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"加入房间（房客）"
                                                                   message:@"输入房主分享的邀请码（U/XXXX-XXXX-XXXX-XXXX）"
                                                            preferredStyle:UIAlertControllerStyleAlert];

    // 1. 邀请码
    [alert addTextFieldWithConfigurationHandler:^(UITextField * _Nonnull textField) {
        textField.placeholder = @"U/XXXX-XXXX-XXXX-XXXX";
        textField.autocapitalizationType = UITextAutocapitalizationTypeNone;
        textField.autocorrectionType = UITextAutocorrectionTypeNo;
        textField.keyboardType = UIKeyboardTypeASCIICapable;
        textField.clearButtonMode = UITextFieldViewModeWhileEditing;
    }];

    // 2. 房间名称（可选）
    [alert addTextFieldWithConfigurationHandler:^(UITextField * _Nonnull textField) {
        textField.placeholder = @"房间名称（可选，如：和小明联机）";
        textField.autocapitalizationType = UITextAutocapitalizationTypeNone;
        textField.autocorrectionType = UITextAutocorrectionTypeNo;
    }];

    // 保存按钮（初始禁用，待邀请码验证通过后启用）
    UIAlertAction *saveAction = [UIAlertAction actionWithTitle:@"保存" style:UIAlertActionStyleDefault handler:^(UIAlertAction * _Nonnull action) {
        [self cleanupGuestAlertObserver];

        NSString *code = alert.textFields[0].text;
        NSString *name = alert.textFields[1].text;

        // 最终验证
        if (![[EasyTierMultiplayerManager sharedManager] isValidInvitationCode:code]) {
            [self showSimpleAlertWithTitle:@"邀请码无效" message:@"请检查邀请码格式是否正确（U/XXXX-XXXX-XXXX-XXXX）"];
            return;
        }

        // 如果未填写房间名，使用默认名称
        if (!name || name.length == 0) {
            name = [NSString stringWithFormat:@"房客-%@", code];
        }

        // 房客模式：使用 initAsGuestWithName:invitationCode: 创建房间（内部解析邀请码）
        EasyTierRoom *room = [[EasyTierRoom alloc] initAsGuestWithName:name invitationCode:code];
        if (!room) {
            [self showSimpleAlertWithTitle:@"加入失败" message:@"无法解析邀请码，请检查格式后重试"];
            return;
        }

        // 保存到本地列表
        [[EasyTierMultiplayerManager sharedManager] addRoom:room];
        [self refreshRooms];

        [self showSimpleAlertWithTitle:@"加入成功"
                               message:[NSString stringWithFormat:@"房间「%@」已添加，点击房间卡片可连接网络", room.name]];
    }];
    saveAction.enabled = NO;

    UIAlertAction *cancelAction = [UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:^(UIAlertAction * _Nonnull action) {
        [self cleanupGuestAlertObserver];
    }];

    [alert addAction:cancelAction];
    [alert addAction:saveAction];

    // 保存引用以供实时验证使用
    self.guestAlert = alert;
    self.guestSaveAction = saveAction;

    // 注册文本变化通知，实现邀请码实时验证
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(onGuestCodeTextChanged:)
                                                 name:UITextFieldTextDidChangeNotification
                                               object:nil];

    [self presentViewController:alert animated:YES completion:nil];
}

/// 邀请码实时验证回调
/// 检查格式：U/ 开头，总长度 21 字符，并通过管理器完整验证
- (void)onGuestCodeTextChanged:(NSNotification *)notification {
    UITextField *field = notification.object;
    // 只处理当前弹窗中的文本框
    if (!self.guestAlert || ![self.guestAlert.textFields containsObject:field]) {
        return;
    }

    NSString *code = self.guestAlert.textFields[0].text;

    // 格式预检：U/ 开头且长度为 21（U/XXXX-XXXX-XXXX-XXXX = 2+4+1+4+1+4+1+4 = 21）
    BOOL formatOk = NO;
    if (code.length > 0) {
        BOOL hasPrefix = [code hasPrefix:@"U/"] || [code hasPrefix:@"u/"];
        if (hasPrefix) {
            // 通过管理器完整验证（包含校验和检查）
            formatOk = [[EasyTierMultiplayerManager sharedManager] isValidInvitationCode:code];
        }
    }

    self.guestSaveAction.enabled = formatOk;
}

/// 清理房客弹窗的实时验证观察者
- (void)cleanupGuestAlertObserver {
    [[NSNotificationCenter defaultCenter] removeObserver:self name:UITextFieldTextDidChangeNotification object:nil];
    self.guestAlert = nil;
    self.guestSaveAction = nil;
}

#pragma mark - 邀请码展示弹窗

/// 房主创建房间后，弹窗显示邀请码并提供"复制"和"分享"按钮
- (void)showInvitationCodeDialog:(NSString *)code roomName:(NSString *)roomName {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"房间创建成功"
                                                                   message:[NSString stringWithFormat:
                                                                       @"房间「%@」的邀请码：\n\n%@\n\n将此邀请码分享给朋友，他们即可通过「我要当房客」加入你的房间。",
                                                                       roomName, code]
                                                            preferredStyle:UIAlertControllerStyleAlert];

    // 复制邀请码到剪贴板
    [alert addAction:[UIAlertAction actionWithTitle:@"复制" style:UIAlertActionStyleDefault handler:^(UIAlertAction * _Nonnull action) {
        [UIPasteboard generalPasteboard].string = code;
        [self showSimpleAlertWithTitle:@"已复制" message:@"邀请码已复制到剪贴板"];
    }]];

    // 分享邀请码
    [alert addAction:[UIAlertAction actionWithTitle:@"分享" style:UIAlertActionStyleDefault handler:^(UIAlertAction * _Nonnull action) {
        NSString *shareText = [NSString stringWithFormat:
            @"EasyTier 联机邀请码：%@\n房间：%@\n打开 EasyTier app，加入网络即可联机 Minecraft！",
            code, roomName];
        UIActivityViewController *activityVC = [[UIActivityViewController alloc] initWithActivityItems:@[shareText] applicationActivities:nil];
        // iPad 适配
        if (activityVC.popoverPresentationController) {
            activityVC.popoverPresentationController.sourceView = self.view;
            activityVC.popoverPresentationController.sourceRect = CGRectMake(self.view.bounds.size.width / 2.0, self.view.bounds.size.height / 2.0, 1, 1);
        }
        [self presentViewController:activityVC animated:YES completion:nil];
    }]];

    [alert addAction:[UIAlertAction actionWithTitle:@"完成" style:UIAlertActionStyleCancel handler:nil]];

    [self presentViewController:alert animated:YES completion:nil];
}

#pragma mark - 房间详情 ActionSheet

- (void)showRoomDetailActionsForRoom:(EasyTierRoom *)room {
    UIAlertController *sheet = [UIAlertController alertControllerWithTitle:room.name
                                                                   message:room.invitationCode
                                                            preferredStyle:UIAlertControllerStyleActionSheet];

    // 连接/断开
    NSString *connectTitle = (room.status == EasyTierRoomStatusConnected) ? @"断开连接" : @"连接房间";
    [sheet addAction:[UIAlertAction actionWithTitle:connectTitle style:UIAlertActionStyleDefault handler:^(UIAlertAction * _Nonnull action) {
        if (room.status == EasyTierRoomStatusConnected) {
            [[EasyTierMultiplayerManager sharedManager] disconnectCurrentRoom];
            room.status = EasyTierRoomStatusDisconnected;
            [[EasyTierMultiplayerManager sharedManager] updateRoom:room];
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

    // 分享邀请码
    [sheet addAction:[UIAlertAction actionWithTitle:@"分享邀请码" style:UIAlertActionStyleDefault handler:^(UIAlertAction * _Nonnull action) {
        NSString *shareText = [[EasyTierMultiplayerManager sharedManager] shareTextForRoom:room];
        UIActivityViewController *activityVC = [[UIActivityViewController alloc] initWithActivityItems:@[shareText] applicationActivities:nil];
        // iPad 适配
        if (activityVC.popoverPresentationController) {
            activityVC.popoverPresentationController.sourceView = self.view;
            activityVC.popoverPresentationController.sourceRect = CGRectMake(self.view.bounds.size.width / 2.0, self.view.bounds.size.height / 2.0, 1, 1);
        }
        [self presentViewController:activityVC animated:YES completion:nil];
    }]];

    // 编辑房间
    [sheet addAction:[UIAlertAction actionWithTitle:@"编辑房间" style:UIAlertActionStyleDefault handler:^(UIAlertAction * _Nonnull action) {
        [self showEditRoomDialog:room];
    }]];

    // 删除房间（destructive）
    [sheet addAction:[UIAlertAction actionWithTitle:@"删除房间" style:UIAlertActionStyleDestructive handler:^(UIAlertAction * _Nonnull action) {
        // 二次确认
        UIAlertController *confirm = [UIAlertController alertControllerWithTitle:@"确认删除"
                                                                          message:[NSString stringWithFormat:@"确定要删除房间「%@」吗？\n此操作无法撤销。", room.name]
                                                                   preferredStyle:UIAlertControllerStyleAlert];
        [confirm addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
        [confirm addAction:[UIAlertAction actionWithTitle:@"删除" style:UIAlertActionStyleDestructive handler:^(UIAlertAction * _Nonnull action) {
            [[EasyTierMultiplayerManager sharedManager] removeRoom:room.roomId];
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

- (void)showEditRoomDialog:(EasyTierRoom *)room {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"编辑房间"
                                                                   message:nil
                                                            preferredStyle:UIAlertControllerStyleAlert];

    // 1. 房间名称（可编辑）
    [alert addTextFieldWithConfigurationHandler:^(UITextField * _Nonnull textField) {
        textField.placeholder = @"房间名称";
        textField.text = room.name;
        textField.autocapitalizationType = UITextAutocapitalizationTypeNone;
        textField.autocorrectionType = UITextAutocorrectionTypeNo;
    }];

    // 2. 邀请码（只读展示，不可修改）
    [alert addTextFieldWithConfigurationHandler:^(UITextField * _Nonnull textField) {
        textField.placeholder = @"邀请码（不可修改）";
        textField.text = room.invitationCode;
        textField.enabled = NO;
    }];

    // 3. 服务器端口（可编辑）
    [alert addTextFieldWithConfigurationHandler:^(UITextField * _Nonnull textField) {
        textField.placeholder = @"MC 服务器端口";
        textField.text = room.hostPort ?: @"25565";
        textField.keyboardType = UIKeyboardTypeNumberPad;
    }];

    [alert addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];

    [alert addAction:[UIAlertAction actionWithTitle:@"保存" style:UIAlertActionStyleDefault handler:^(UIAlertAction * _Nonnull action) {
        NSString *name = alert.textFields[0].text;
        NSString *port = alert.textFields[2].text;

        // 输入验证
        if (!name || name.length == 0) {
            [self showSimpleAlertWithTitle:@"提示" message:@"请输入房间名称"];
            return;
        }
        if (!port || port.length == 0) {
            port = @"25565";
        }

        // 更新房间对象（邀请码和网络信息不可修改）
        room.name = name;
        room.hostPort = port;

        [[EasyTierMultiplayerManager sharedManager] updateRoom:room];
        [self refreshRooms];
    }]];

    [self presentViewController:alert animated:YES completion:nil];
}

#pragma mark - 连接房间

- (void)connectToRoom:(EasyTierRoom *)room completion:(void (^)(BOOL success, NSError *error))completion {
    // 先更新状态为连接中
    room.status = EasyTierRoomStatusConnecting;
    [[EasyTierMultiplayerManager sharedManager] updateRoom:room];
    [self refreshRooms];

    // 检查 EasyTier app 是否已安装
    if (![[EasyTierMultiplayerManager sharedManager] isEasyTierAppInstalled]) {
        room.status = EasyTierRoomStatusError;
        [[EasyTierMultiplayerManager sharedManager] updateRoom:room];
        [self refreshRooms];

        // 提示用户安装 EasyTier
        UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"需要 EasyTier"
                                                                       message:@"未检测到 EasyTier 应用，请先通过 TestFlight 安装后再联机。"
                                                                preferredStyle:UIAlertControllerStyleAlert];
        [alert addAction:[UIAlertAction actionWithTitle:@"下载 EasyTier" style:UIAlertActionStyleDefault handler:^(UIAlertAction * _Nonnull action) {
            [[EasyTierMultiplayerManager sharedManager] openEasyTierApp];
        }]];
        [alert addAction:[UIAlertAction actionWithTitle:@"好" style:UIAlertActionStyleCancel handler:nil]];
        [self presentViewController:alert animated:YES completion:nil];

        if (completion) {
            NSError *error = [NSError errorWithDomain:@"EasyTierMultiplayer" code:-1 userInfo:@{NSLocalizedDescriptionKey: @"未安装 EasyTier"}];
            completion(NO, error);
        }
        return;
    }

    // 调用管理器连接房间（内部会唤起 EasyTier app 加入网络）
    __weak typeof(self) weakSelf = self;
    [[EasyTierMultiplayerManager sharedManager] connectToRoom:room completion:^(BOOL success, NSError * _Nullable error) {
        dispatch_async(dispatch_get_main_queue(), ^{
            __strong typeof(weakSelf) strongSelf = weakSelf;
            if (!strongSelf) return;

            if (success) {
                room.status = EasyTierRoomStatusConnected;
                room.lastConnectedAt = [NSDate date];
            } else {
                room.status = EasyTierRoomStatusError;
            }
            [[EasyTierMultiplayerManager sharedManager] updateRoom:room];
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

    // 验证 IP 格式
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
    // 非标准 IP（如 EasyTier 分配的地址也可能是域名形式），允许通过
    return ip.length > 0;
}

- (void)refreshRooms {
    dispatch_async(dispatch_get_main_queue(), ^{
        self.rooms = [[EasyTierMultiplayerManager sharedManager] savedRooms] ?: @[];
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
            // 联机服务：状态 + 系统信息
            return 2;
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
    switch (section) {
        case 0:
            return @"EasyTier 邀请码与 HMCL/FCL/ZL2/PCL2 陶瓦联机互通";
        case 2:
            return @"输入朋友的 EasyTier IP 地址和端口，直接加入游戏";
        default:
            return nil;
    }
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    switch (indexPath.section) {
        case 0: {
            // Section 0: 联机服务
            if (indexPath.row == 0) {
                // EasyTier 状态
                EasyTierStatusCell *cell = [tableView dequeueReusableCellWithIdentifier:@"StatusCell" forIndexPath:indexPath];
                BOOL installed = [[EasyTierMultiplayerManager sharedManager] isEasyTierAppInstalled];
                [cell configureWithInstalled:installed];
                return cell;
            } else {
                // 系统信息与 iOS 版本警告
                EasyTierInfoCell *cell = [tableView dequeueReusableCellWithIdentifier:@"InfoCell" forIndexPath:indexPath];
                [cell configureWithIOSVersion];
                return cell;
            }
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
                return cell;
            }

            EasyTierRoomCell *cell = [tableView dequeueReusableCellWithIdentifier:@"RoomCell" forIndexPath:indexPath];
            EasyTierRoom *room = self.rooms[indexPath.row];
            BOOL hasBackground = [[BackgroundManager sharedManager] hasBackground];
            [cell configureWithRoom:room hasBackground:hasBackground];
            return cell;
        }
        case 2: {
            // Section 2: 快速直连
            EasyTierInputCell *cell = [tableView dequeueReusableCellWithIdentifier:@"InputCell" forIndexPath:indexPath];
            if (indexPath.row == 0) {
                // IP 地址输入框
                [cell configureWithPlaceholder:@"如 10.144.144.1"
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
            return cell;
        }
        default:
            return [UITableViewCell new];
    }
}

#pragma mark - UITableViewDelegate

- (void)tableView:(UITableView *)tableView willDisplayCell:(UITableViewCell *)cell forRowAtIndexPath:(NSIndexPath *)indexPath {
    // 为每个 cell 应用背景毛玻璃效果
    [self applyEffectToCell:cell];
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];

    switch (indexPath.section) {
        case 0: {
            // 点击 EasyTier 状态行：打开 EasyTier app
            if (indexPath.row == 0) {
                [[EasyTierMultiplayerManager sharedManager] openEasyTierApp];
                // 刷新状态
                [self.tableView reloadRowsAtIndexPaths:@[[NSIndexPath indexPathForRow:0 inSection:0]] withRowAnimation:UITableViewRowAnimationAutomatic];
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
            EasyTierRoom *room = self.rooms[indexPath.row];
            [self showRoomDetailActionsForRoom:room];
            break;
        }
        case 2: {
            // 点击直连输入行：让输入框获得焦点
            EasyTierInputCell *cell = [tableView cellForRowAtIndexPath:indexPath];
            [cell.textField becomeFirstResponder];
            break;
        }
        default:
            break;
    }
}

/// 滑动删除房间
- (UISwipeActionsConfiguration *)tableView:(UITableView *)tableView trailingSwipeActionsConfigurationForRowAtIndexPath:(NSIndexPath *)indexPath {
    // 仅房间列表行支持滑动删除
    if (indexPath.section != 1 || self.rooms.count == 0) {
        return nil;
    }

    EasyTierRoom *room = self.rooms[indexPath.row];

    UIContextualAction *deleteAction = [UIContextualAction contextualActionWithStyle:UIContextualActionStyleDestructive
                                                                               title:@"删除"
                                                                             handler:^(UIContextualAction * _Nonnull action, __kindof UIView * _Nonnull sourceView, void (^ _Nonnull completionHandler)(BOOL)) {
        // 二次确认
        UIAlertController *confirm = [UIAlertController alertControllerWithTitle:@"确认删除"
                                                                          message:[NSString stringWithFormat:@"确定要删除房间「%@」吗？\n此操作无法撤销。", room.name]
                                                                   preferredStyle:UIAlertControllerStyleAlert];
        [confirm addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:^(UIAlertAction * _Nonnull action) {
            completionHandler(NO);
        }]];
        [confirm addAction:[UIAlertAction actionWithTitle:@"删除" style:UIAlertActionStyleDestructive handler:^(UIAlertAction * _Nonnull action) {
            [[EasyTierMultiplayerManager sharedManager] removeRoom:room.roomId];
            [self refreshRooms];
            completionHandler(YES);
        }]];
        [self presentViewController:confirm animated:YES completion:nil];
    }];
    deleteAction.image = [UIImage systemImageNamed:@"trash"];

    return [UISwipeActionsConfiguration configurationWithActions:@[deleteAction]];
}

- (CGFloat)tableView:(UITableView *)tableView heightForRowAtIndexPath:(NSIndexPath *)indexPath {
    if (indexPath.section == 0) {
        if (indexPath.row == 0) {
            // 状态卡片
            return 72;
        } else {
            // 系统信息卡片（多行文本，使用自动尺寸）
            return UITableViewAutomaticDimension;
        }
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
