#import "TerracottaViewController.h"
#import "TerracottaManager.h"
#import "TerracottaBridge.h"
#import "LauncherPreferences.h"
#import "utils.h"

/// FCL 风格的陶瓦联机界面
///
/// 布局参考 FoldCraftLauncher 的 multiplayer 模块：
/// - 顶部：状态卡片（圆形状态图标 + 状态文字 + 阶段描述 + 邀请码/直连地址）
/// - 中部：UISegmentedControl 切换「创建房间」/「加入房间」
/// - 创建房间面板：端口输入框 + 大按钮
/// - 加入房间面板：邀请码输入框 + 大按钮
/// - 会话进行中：显示「断开连接」按钮 + 玩家列表
///
/// 状态监听通过 TerracottaManagerStateDidChangeNotification 通知刷新 UI。
@interface TerracottaViewController () <UITextFieldDelegate>

/* 顶部状态卡片 */
@property(nonatomic, strong) UIView *statusCard;
@property(nonatomic, strong) UIImageView *statusIcon;
@property(nonatomic, strong) UILabel *statusLabel;
@property(nonatomic, strong) UILabel *stageLabel;
@property(nonatomic, strong) UIActivityIndicatorView *activityIndicator;
@property(nonatomic, strong) UILabel *inviteCodeLabel;
@property(nonatomic, strong) UIButton *inviteCopyButton;
@property(nonatomic, strong) UILabel *directConnectLabel;
@property(nonatomic, strong) UIButton *directCopyButton;

/* Tab 切换 */
@property(nonatomic, strong) UISegmentedControl *tabControl;
@property(nonatomic, strong) UIView *createPanel;
@property(nonatomic, strong) UIView *joinPanel;

/* 创建房间面板 */
@property(nonatomic, strong) UILabel *createHintLabel;
@property(nonatomic, strong) UITextField *portField;
@property(nonatomic, strong) UIButton *createButton;

/* 加入房间面板 */
@property(nonatomic, strong) UILabel *joinHintLabel;
@property(nonatomic, strong) UITextField *inviteField;
@property(nonatomic, strong) UIButton *joinButton;

/* 会话中底部 */
@property(nonatomic, strong) UIButton *disconnectButton;
@property(nonatomic, strong) UILabel *playersTitleLabel;
@property(nonatomic, strong) UIStackView *playersList;

/* 容器滚动视图（小屏适配） */
@property(nonatomic, strong) UIScrollView *scrollView;
@property(nonatomic, strong) UIView *contentView;

@end

@implementation TerracottaViewController

#pragma mark - Lifecycle

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"陶瓦联机";
    self.view.backgroundColor = [UIColor systemBackgroundColor];

    /* 关闭按钮（modal） */
    UIBarButtonItem *closeItem = [[UIBarButtonItem alloc]
        initWithBarButtonSystemItem:UIBarButtonSystemItemClose
                            target:self
                            action:@selector(close)];
    self.navigationItem.leftBarButtonItem = closeItem;

    [self setupViews];
    [self registerNotifications];
    [self refreshUI];
}

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

#pragma mark - UI Setup

- (void)setupViews {
    /* ScrollView 容器（小屏适配） */
    self.scrollView = [[UIScrollView alloc] init];
    self.scrollView.translatesAutoresizingMaskIntoConstraints = NO;
    self.scrollView.alwaysBounceVertical = YES;
    self.scrollView.keyboardDismissMode = UIScrollViewKeyboardDismissModeOnDrag;
    [self.view addSubview:self.scrollView];

    self.contentView = [[UIView alloc] init];
    self.contentView.translatesAutoresizingMaskIntoConstraints = NO;
    [self.scrollView addSubview:self.contentView];

    [NSLayoutConstraint activateConstraints:@[
        [self.scrollView.topAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.topAnchor],
        [self.scrollView.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [self.scrollView.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [self.scrollView.bottomAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.bottomAnchor],
        [self.contentView.topAnchor constraintEqualToAnchor:self.scrollView.contentLayoutGuide.topAnchor],
        [self.contentView.leadingAnchor constraintEqualToAnchor:self.scrollView.contentLayoutGuide.leadingAnchor],
        [self.contentView.trailingAnchor constraintEqualToAnchor:self.scrollView.contentLayoutGuide.trailingAnchor],
        [self.contentView.bottomAnchor constraintEqualToAnchor:self.scrollView.contentLayoutGuide.bottomAnchor],
        [self.contentView.widthAnchor constraintEqualToAnchor:self.scrollView.frameLayoutGuide.widthAnchor],
    ]];

    [self setupStatusCard];
    [self setupTabControl];
    [self setupCreatePanel];
    [self setupJoinPanel];
    [self setupSessionFooter];
}

- (void)setupStatusCard {
    self.statusCard = [[UIView alloc] init];
    self.statusCard.translatesAutoresizingMaskIntoConstraints = NO;
    self.statusCard.backgroundColor = [UIColor secondarySystemBackgroundColor];
    self.statusCard.layer.cornerRadius = 16;
    self.statusCard.layer.masksToBounds = YES;
    [self.contentView addSubview:self.statusCard];

    self.statusIcon = [[UIImageView alloc] init];
    self.statusIcon.translatesAutoresizingMaskIntoConstraints = NO;
    self.statusIcon.tintColor = [UIColor systemGrayColor];
    self.statusIcon.contentMode = UIViewContentModeScaleAspectFit;
    [self.statusCard addSubview:self.statusIcon];

    self.activityIndicator = [[UIActivityIndicatorView alloc]
        initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleMedium];
    self.activityIndicator.translatesAutoresizingMaskIntoConstraints = NO;
    self.activityIndicator.hidesWhenStopped = YES;
    [self.statusCard addSubview:self.activityIndicator];

    self.statusLabel = [self makeLabelWithFont:[UIFont systemFontOfSize:18 weight:UIFontWeightSemibold]
                                     textColor:[UIColor labelColor]];
    [self.statusCard addSubview:self.statusLabel];

    self.stageLabel = [self makeLabelWithFont:[UIFont systemFontOfSize:13]
                                    textColor:[UIColor secondaryLabelColor]];
    self.stageLabel.numberOfLines = 0;
    [self.statusCard addSubview:self.stageLabel];

    /* 邀请码行 */
    self.inviteCodeLabel = [self makeLabelWithFont:[UIFont fontWithName:@"Menlo" size:14]
                                        textColor:[UIColor labelColor]];
    self.inviteCodeLabel.numberOfLines = 0;
    [self.statusCard addSubview:self.inviteCodeLabel];

    self.inviteCopyButton = [self makeCopyButtonWithSelector:@selector(copyInviteCode:)];
    [self.statusCard addSubview:self.inviteCopyButton];

    /* 直连地址行 */
    self.directConnectLabel = [self makeLabelWithFont:[UIFont fontWithName:@"Menlo" size:13]
                                          textColor:[UIColor secondaryLabelColor]];
    self.directConnectLabel.numberOfLines = 0;
    [self.statusCard addSubview:self.directConnectLabel];

    self.directCopyButton = [self makeCopyButtonWithSelector:@selector(copyDirectURL:)];
    [self.statusCard addSubview:self.directCopyButton];

    [NSLayoutConstraint activateConstraints:@[
        [self.statusCard.topAnchor constraintEqualToAnchor:self.contentView.topAnchor constant:16],
        [self.statusCard.leadingAnchor constraintEqualToAnchor:self.contentView.leadingAnchor constant:16],
        [self.statusCard.trailingAnchor constraintEqualToAnchor:self.contentView.trailingAnchor constant:-16],

        [self.statusIcon.topAnchor constraintEqualToAnchor:self.statusCard.topAnchor constant:16],
        [self.statusIcon.leadingAnchor constraintEqualToAnchor:self.statusCard.leadingAnchor constant:16],
        [self.statusIcon.widthAnchor constraintEqualToConstant:28],
        [self.statusIcon.heightAnchor constraintEqualToConstant:28],

        [self.activityIndicator.centerYAnchor constraintEqualToAnchor:self.statusIcon.centerYAnchor],
        [self.activityIndicator.leadingAnchor constraintEqualToAnchor:self.statusIcon.trailingAnchor constant:8],

        [self.statusLabel.centerYAnchor constraintEqualToAnchor:self.statusIcon.centerYAnchor],
        [self.statusLabel.leadingAnchor constraintEqualToAnchor:self.activityIndicator.trailingAnchor constant:8],
        [self.statusLabel.trailingAnchor constraintEqualToAnchor:self.statusCard.trailingAnchor constant:-16],

        [self.stageLabel.topAnchor constraintEqualToAnchor:self.statusIcon.bottomAnchor constant:8],
        [self.stageLabel.leadingAnchor constraintEqualToAnchor:self.statusCard.leadingAnchor constant:16],
        [self.stageLabel.trailingAnchor constraintEqualToAnchor:self.statusCard.trailingAnchor constant:-16],

        [self.inviteCodeLabel.topAnchor constraintEqualToAnchor:self.stageLabel.bottomAnchor constant:8],
        [self.inviteCodeLabel.leadingAnchor constraintEqualToAnchor:self.statusCard.leadingAnchor constant:16],
        [self.inviteCodeLabel.trailingAnchor constraintEqualToAnchor:self.inviteCopyButton.leadingAnchor constant:-8],

        [self.inviteCopyButton.centerYAnchor constraintEqualToAnchor:self.inviteCodeLabel.centerYAnchor],
        [self.inviteCopyButton.trailingAnchor constraintEqualToAnchor:self.statusCard.trailingAnchor constant:-16],

        [self.directConnectLabel.topAnchor constraintEqualToAnchor:self.inviteCodeLabel.bottomAnchor constant:4],
        [self.directConnectLabel.leadingAnchor constraintEqualToAnchor:self.statusCard.leadingAnchor constant:16],
        [self.directConnectLabel.trailingAnchor constraintEqualToAnchor:self.directCopyButton.leadingAnchor constant:-8],

        [self.directCopyButton.centerYAnchor constraintEqualToAnchor:self.directConnectLabel.centerYAnchor],
        [self.directCopyButton.trailingAnchor constraintEqualToAnchor:self.statusCard.trailingAnchor constant:-16],

        [self.statusCard.bottomAnchor constraintEqualToAnchor:self.directConnectLabel.bottomAnchor constant:16],
    ]];
}

- (void)setupTabControl {
    self.tabControl = [[UISegmentedControl alloc] initWithItems:@[@"创建房间", @"加入房间"]];
    self.tabControl.translatesAutoresizingMaskIntoConstraints = NO;
    self.tabControl.selectedSegmentIndex = 0;
    [self.tabControl addTarget:self action:@selector(tabChanged:)
                 forControlEvents:UIControlEventValueChanged];
    [self.contentView addSubview:self.tabControl];

    [NSLayoutConstraint activateConstraints:@[
        [self.tabControl.topAnchor constraintEqualToAnchor:self.statusCard.bottomAnchor constant:16],
        [self.tabControl.leadingAnchor constraintEqualToAnchor:self.contentView.leadingAnchor constant:16],
        [self.tabControl.trailingAnchor constraintEqualToAnchor:self.contentView.trailingAnchor constant:-16],
        [self.tabControl.heightAnchor constraintEqualToConstant:32],
    ]];
}

- (void)setupCreatePanel {
    self.createPanel = [[UIView alloc] init];
    self.createPanel.translatesAutoresizingMaskIntoConstraints = NO;
    [self.contentView addSubview:self.createPanel];

    self.createHintLabel = [self makeLabelWithFont:[UIFont systemFontOfSize:13]
                                        textColor:[UIColor secondaryLabelColor]];
    self.createHintLabel.numberOfLines = 0;
    self.createHintLabel.text = @"先在 Minecraft 中点击「对局域网开放」，记下显示的端口号，填入下方后点击创建。";
    [self.createPanel addSubview:self.createHintLabel];

    self.portField = [self makeTextFieldWithPlaceholder:@"MC LAN 端口（如 25565）"
                                            keyboardType:UIKeyboardTypeNumberPad];
    self.portField.text = @"25565";
    self.portField.delegate = self;
    [self.createPanel addSubview:self.portField];

    self.createButton = [self makePrimaryButtonWithTitle:@"创建房间"
                                                  action:@selector(createRoomTapped:)];
    [self.createPanel addSubview:self.createButton];

    [NSLayoutConstraint activateConstraints:@[
        [self.createPanel.topAnchor constraintEqualToAnchor:self.tabControl.bottomAnchor constant:16],
        [self.createPanel.leadingAnchor constraintEqualToAnchor:self.contentView.leadingAnchor constant:16],
        [self.createPanel.trailingAnchor constraintEqualToAnchor:self.contentView.trailingAnchor constant:-16],

        [self.createHintLabel.topAnchor constraintEqualToAnchor:self.createPanel.topAnchor],
        [self.createHintLabel.leadingAnchor constraintEqualToAnchor:self.createPanel.leadingAnchor],
        [self.createHintLabel.trailingAnchor constraintEqualToAnchor:self.createPanel.trailingAnchor],

        [self.portField.topAnchor constraintEqualToAnchor:self.createHintLabel.bottomAnchor constant:8],
        [self.portField.leadingAnchor constraintEqualToAnchor:self.createPanel.leadingAnchor],
        [self.portField.trailingAnchor constraintEqualToAnchor:self.createPanel.trailingAnchor],
        [self.portField.heightAnchor constraintEqualToConstant:44],

        [self.createButton.topAnchor constraintEqualToAnchor:self.portField.bottomAnchor constant:12],
        [self.createButton.leadingAnchor constraintEqualToAnchor:self.createPanel.leadingAnchor],
        [self.createButton.trailingAnchor constraintEqualToAnchor:self.createPanel.trailingAnchor],
        [self.createButton.heightAnchor constraintEqualToConstant:48],

        [self.createPanel.bottomAnchor constraintEqualToAnchor:self.createButton.bottomAnchor],
    ]];
}

- (void)setupJoinPanel {
    self.joinPanel = [[UIView alloc] init];
    self.joinPanel.translatesAutoresizingMaskIntoConstraints = NO;
    self.joinPanel.hidden = YES;
    [self.contentView addSubview:self.joinPanel];

    self.joinHintLabel = [self makeLabelWithFont:[UIFont systemFontOfSize:13]
                                       textColor:[UIColor secondaryLabelColor]];
    self.joinHintLabel.numberOfLines = 0;
    self.joinHintLabel.text = @"输入房主分享的邀请码，加入后在 Minecraft 多人游戏界面直接连接 127.0.0.1:25565。";
    [self.joinPanel addSubview:self.joinHintLabel];

    self.inviteField = [self makeTextFieldWithPlaceholder:@"邀请码"
                                              keyboardType:UIKeyboardTypeDefault];
    self.inviteField.autocapitalizationType = UITextAutocapitalizationTypeNone;
    self.inviteField.autocorrectionType = UITextAutocorrectionTypeNo;
    self.inviteField.delegate = self;
    [self.joinPanel addSubview:self.inviteField];

    self.joinButton = [self makePrimaryButtonWithTitle:@"加入房间"
                                                 action:@selector(joinRoomTapped:)];
    [self.joinPanel addSubview:self.joinButton];

    [NSLayoutConstraint activateConstraints:@[
        [self.joinPanel.topAnchor constraintEqualToAnchor:self.tabControl.bottomAnchor constant:16],
        [self.joinPanel.leadingAnchor constraintEqualToAnchor:self.contentView.leadingAnchor constant:16],
        [self.joinPanel.trailingAnchor constraintEqualToAnchor:self.contentView.trailingAnchor constant:-16],

        [self.joinHintLabel.topAnchor constraintEqualToAnchor:self.joinPanel.topAnchor],
        [self.joinHintLabel.leadingAnchor constraintEqualToAnchor:self.joinPanel.leadingAnchor],
        [self.joinHintLabel.trailingAnchor constraintEqualToAnchor:self.joinPanel.trailingAnchor],

        [self.inviteField.topAnchor constraintEqualToAnchor:self.joinHintLabel.bottomAnchor constant:8],
        [self.inviteField.leadingAnchor constraintEqualToAnchor:self.joinPanel.leadingAnchor],
        [self.inviteField.trailingAnchor constraintEqualToAnchor:self.joinPanel.trailingAnchor],
        [self.inviteField.heightAnchor constraintEqualToConstant:44],

        [self.joinButton.topAnchor constraintEqualToAnchor:self.inviteField.bottomAnchor constant:12],
        [self.joinButton.leadingAnchor constraintEqualToAnchor:self.joinPanel.leadingAnchor],
        [self.joinButton.trailingAnchor constraintEqualToAnchor:self.joinPanel.trailingAnchor],
        [self.joinButton.heightAnchor constraintEqualToConstant:48],

        [self.joinPanel.bottomAnchor constraintEqualToAnchor:self.joinButton.bottomAnchor],
    ]];
}

- (void)setupSessionFooter {
    self.playersTitleLabel = [self makeLabelWithFont:[UIFont systemFontOfSize:15 weight:UIFontWeightSemibold]
                                          textColor:[UIColor labelColor]];
    self.playersTitleLabel.text = @"玩家列表";
    [self.contentView addSubview:self.playersTitleLabel];

    self.playersList = [[UIStackView alloc] init];
    self.playersList.translatesAutoresizingMaskIntoConstraints = NO;
    self.playersList.axis = UILayoutConstraintAxisVertical;
    self.playersList.spacing = 6;
    self.playersList.alignment = UIStackViewAlignmentFill;
    [self.contentView addSubview:self.playersList];

    self.disconnectButton = [UIButton buttonWithType:UIButtonTypeSystem];
    self.disconnectButton.translatesAutoresizingMaskIntoConstraints = NO;
    [self.disconnectButton setTitle:@"断开连接" forState:UIControlStateNormal];
    [self.disconnectButton setTitleColor:[UIColor systemRedColor] forState:UIControlStateNormal];
    self.disconnectButton.titleLabel.font = [UIFont systemFontOfSize:16 weight:UIFontWeightMedium];
    self.disconnectButton.layer.cornerRadius = 12;
    self.disconnectButton.layer.borderWidth = 1;
    self.disconnectButton.layer.borderColor = [UIColor systemRedColor].CGColor;
    [self.disconnectButton addTarget:self action:@selector(disconnectTapped:)
                    forControlEvents:UIControlEventTouchUpInside];
    [self.contentView addSubview:self.disconnectButton];

    [NSLayoutConstraint activateConstraints:@[
        [self.playersTitleLabel.topAnchor constraintEqualToAnchor:self.createPanel.bottomAnchor constant:20],
        [self.playersTitleLabel.leadingAnchor constraintEqualToAnchor:self.contentView.leadingAnchor constant:16],
        [self.playersTitleLabel.trailingAnchor constraintEqualToAnchor:self.contentView.trailingAnchor constant:-16],

        [self.playersList.topAnchor constraintEqualToAnchor:self.playersTitleLabel.bottomAnchor constant:8],
        [self.playersList.leadingAnchor constraintEqualToAnchor:self.contentView.leadingAnchor constant:16],
        [self.playersList.trailingAnchor constraintEqualToAnchor:self.contentView.trailingAnchor constant:-16],

        [self.disconnectButton.topAnchor constraintEqualToAnchor:self.playersList.bottomAnchor constant:16],
        [self.disconnectButton.leadingAnchor constraintEqualToAnchor:self.contentView.leadingAnchor constant:16],
        [self.disconnectButton.trailingAnchor constraintEqualToAnchor:self.contentView.trailingAnchor constant:-16],
        [self.disconnectButton.heightAnchor constraintEqualToConstant:44],
        [self.disconnectButton.bottomAnchor constraintEqualToAnchor:self.contentView.bottomAnchor constant:-16],
    ]];
}

#pragma mark - UI Helpers

- (UILabel *)makeLabelWithFont:(UIFont *)font textColor:(UIColor *)color {
    UILabel *label = [[UILabel alloc] init];
    label.translatesAutoresizingMaskIntoConstraints = NO;
    label.font = font;
    label.textColor = color;
    return label;
}

- (UITextField *)makeTextFieldWithPlaceholder:(NSString *)placeholder
                                  keyboardType:(UIKeyboardType)keyboardType {
    UITextField *field = [[UITextField alloc] init];
    field.translatesAutoresizingMaskIntoConstraints = NO;
    field.placeholder = placeholder;
    field.borderStyle = UITextBorderStyleRoundedRect;
    field.keyboardType = keyboardType;
    field.font = [UIFont systemFontOfSize:16];
    field.backgroundColor = [UIColor secondarySystemBackgroundColor];
    return field;
}

- (UIButton *)makePrimaryButtonWithTitle:(NSString *)title action:(SEL)action {
    UIButton *btn = [UIButton buttonWithType:UIButtonTypeSystem];
    btn.translatesAutoresizingMaskIntoConstraints = NO;
    [btn setTitle:title forState:UIControlStateNormal];
    [btn setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    btn.titleLabel.font = [UIFont systemFontOfSize:16 weight:UIFontWeightSemibold];
    btn.backgroundColor = accentColor();
    btn.layer.cornerRadius = 12;
    btn.layer.masksToBounds = YES;
    [btn addTarget:self action:action forControlEvents:UIControlEventTouchUpInside];
    return btn;
}

- (UIButton *)makeCopyButtonWithSelector:(SEL)action {
    UIButton *btn = [UIButton buttonWithType:UIButtonTypeSystem];
    btn.translatesAutoresizingMaskIntoConstraints = NO;
    UIImage *img = [UIImage systemImageNamed:@"doc.on.doc"];
    [btn setImage:img forState:UIControlStateNormal];
    btn.tintColor = [UIColor secondaryLabelColor];
    [btn addTarget:self action:action forControlEvents:UIControlEventTouchUpInside];
    return btn;
}

#pragma mark - Tab Switching

- (void)tabChanged:(UISegmentedControl *)sender {
    BOOL isCreate = (sender.selectedSegmentIndex == 0);
    self.createPanel.hidden = !isCreate;
    self.joinPanel.hidden = isCreate;
}

#pragma mark - Actions

- (void)createRoomTapped:(UIButton *)sender {
    uint16_t port = (uint16_t)[self.portField.text integerValue];
    if (port == 0) {
        [self showToast:@"请输入有效端口"];
        return;
    }
    [self.view endEditing:YES];
    NSString *playerName = [self currentPlayerName];
    [[TerracottaManager shared] createRoomWithPort:port
                                        inviteCode:nil
                                        playerName:playerName];
}

- (void)joinRoomTapped:(UIButton *)sender {
    NSString *code = [self.inviteField.text stringByTrimmingCharactersInSet:
                      [NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (code.length == 0) {
        [self showToast:@"请输入邀请码"];
        return;
    }
    [self.view endEditing:YES];
    NSString *playerName = [self currentPlayerName];
    BOOL ok = [[TerracottaManager shared] joinRoomWithInviteCode:code
                                                      playerName:playerName];
    if (!ok) {
        [self showToast:[[TerracottaManager shared] lastError] ?: @"邀请码无效"];
    }
}

- (void)disconnectTapped:(UIButton *)sender {
    [[TerracottaManager shared] stopSession];
}

- (void)copyInviteCode:(UIButton *)sender {
    NSString *code = [TerracottaManager shared].currentInviteCode;
    if (code.length == 0) return;
    [UIPasteboard generalPasteboard].string = code;
    [self showToast:@"邀请码已复制"];
}

- (void)copyDirectURL:(UIButton *)sender {
    NSString *url = [TerracottaManager shared].directConnectURL;
    if (url.length == 0) return;
    [UIPasteboard generalPasteboard].string = url;
    [self showToast:@"地址已复制"];
}

- (void)close {
    [self dismissViewControllerAnimated:YES completion:nil];
}

#pragma mark - Player Name

- (NSString *)currentPlayerName {
    /* 优先用启动器当前账户名，否则用设备名 */
    NSString *name = getPrefObject(@"launcher.account_selected_name");
    if (name.length > 0) return name;
    return [UIDevice currentDevice].name ?: @"iOSPlayer";
}

#pragma mark - UI Refresh

- (void)registerNotifications {
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(stateDidChange:)
                                                 name:TerracottaManagerStateDidChangeNotification
                                               object:nil];
}

- (void)stateDidChange:(NSNotification *)notification {
    [self refreshUI];
}

- (void)refreshUI {
    TerracottaManager *mgr = [TerracottaManager shared];

    /* 状态文字 + 图标 */
    NSString *statusText = [self statusDisplayText:mgr.status role:mgr.role];
    self.statusLabel.text = statusText;
    self.statusIcon.image = [UIImage systemImageNamed:[self statusIconName:mgr.status]];
    self.statusIcon.tintColor = [self statusColor:mgr.status];

    /* 活动指示器 */
    if (mgr.status == TerracottaStatusConnecting) {
        [self.activityIndicator startAnimating];
    } else {
        [self.activityIndicator stopAnimating];
    }

    /* 阶段描述 */
    self.stageLabel.text = mgr.stageDescription ?: @"";

    /* 邀请码 */
    if (mgr.currentInviteCode.length > 0) {
        self.inviteCodeLabel.text = [NSString stringWithFormat:@"邀请码：%@", mgr.currentInviteCode];
        self.inviteCopyButton.hidden = NO;
    } else {
        self.inviteCodeLabel.text = nil;
        self.inviteCopyButton.hidden = YES;
    }

    /* 直连地址 */
    if (mgr.directConnectURL.length > 0) {
        self.directConnectLabel.text = [NSString stringWithFormat:@"MC 直连：%@", mgr.directConnectURL];
        self.directCopyButton.hidden = NO;
    } else {
        self.directConnectLabel.text = nil;
        self.directCopyButton.hidden = YES;
    }

    /* 会话进行中：隐藏 Tab 和面板，显示断开按钮和玩家列表 */
    BOOL sessionActive = (mgr.status != TerracottaStatusDisconnected);
    self.tabControl.hidden = sessionActive;
    self.createPanel.hidden = sessionActive ?: (self.tabControl.selectedSegmentIndex != 0);
    self.joinPanel.hidden = sessionActive ?: (self.tabControl.selectedSegmentIndex != 1);
    self.disconnectButton.hidden = !sessionActive;
    self.playersTitleLabel.hidden = !sessionActive;

    /* 玩家列表 */
    [self refreshPlayersList:mgr.players role:mgr.role];

    /* 错误提示（仅首次出现错误时弹 toast） */
    if (mgr.status == TerracottaStatusError && mgr.lastError.length > 0) {
        self.stageLabel.text = mgr.lastError;
    }
}

- (void)refreshPlayersList:(NSArray<TerracottaPlayerProfile *> *)players
                      role:(TerracottaRole)role {
    /* 清空旧条目 */
    for (UIView *v in self.playersList.arrangedSubviews) {
        [self.playersList removeArrangedSubview:v];
        [v removeFromSuperview];
    }
    if (players.count == 0) {
        UILabel *empty = [self makeLabelWithFont:[UIFont systemFontOfSize:13]
                                       textColor:[UIColor tertiaryLabelColor]];
        empty.text = (role == TerracottaRoleHost) ? @"等待玩家加入…" : @"暂无玩家信息";
        [self.playersList addArrangedSubview:empty];
        return;
    }
    for (TerracottaPlayerProfile *p in players) {
        [self.playersList addArrangedSubview:[self makePlayerRow:p role:role]];
    }
}

- (UIView *)makePlayerRow:(TerracottaPlayerProfile *)profile role:(TerracottaRole)role {
    UIView *row = [[UIView alloc] init];
    row.translatesAutoresizingMaskIntoConstraints = NO;
    row.backgroundColor = [UIColor secondarySystemBackgroundColor];
    row.layer.cornerRadius = 8;

    UIImageView *avatar = [[UIImageView alloc] init];
    avatar.translatesAutoresizingMaskIntoConstraints = NO;
    avatar.image = [UIImage systemImageNamed:@"person.circle.fill"];
    avatar.tintColor = accentColor();
    [row addSubview:avatar];

    UILabel *nameLabel = [self makeLabelWithFont:[UIFont systemFontOfSize:15]
                                      textColor:[UIColor labelColor]];
    nameLabel.text = profile.name.length > 0 ? profile.name : @"(unknown)";
    [row addSubview:nameLabel];

    UILabel *roleLabel = [self makeLabelWithFont:[UIFont systemFontOfSize:12]
                                      textColor:[UIColor secondaryLabelColor]];
    roleLabel.text = [self playerRoleText:profile role:role];
    roleLabel.textAlignment = NSTextAlignmentRight;
    [row addSubview:roleLabel];

    [NSLayoutConstraint activateConstraints:@[
        [avatar.leadingAnchor constraintEqualToAnchor:row.leadingAnchor constant:12],
        [avatar.centerYAnchor constraintEqualToAnchor:row.centerYAnchor],
        [avatar.widthAnchor constraintEqualToConstant:28],
        [avatar.heightAnchor constraintEqualToConstant:28],

        [nameLabel.leadingAnchor constraintEqualToAnchor:avatar.trailingAnchor constant:10],
        [nameLabel.centerYAnchor constraintEqualToAnchor:row.centerYAnchor],
        [nameLabel.trailingAnchor constraintEqualToAnchor:roleLabel.leadingAnchor constant:-8],

        [roleLabel.trailingAnchor constraintEqualToAnchor:row.trailingAnchor constant:-12],
        [roleLabel.centerYAnchor constraintEqualToAnchor:row.centerYAnchor],
        [roleLabel.widthAnchor constraintGreaterThanOrEqualToConstant:60],

        [row.heightAnchor constraintEqualToConstant:44],
    ]];
    return row;
}

- (NSString *)playerRoleText:(TerracottaPlayerProfile *)profile role:(TerracottaRole)myRole {
    NSString *kind = profile.kind;
    if ([kind isEqualToString:@"host"]) return @"房主";
    if ([kind isEqualToString:@"guest"]) return @"访客";
    /* 没有 kind 字段时用 profile_index == 0 推断房主 */
    return @"玩家";
}

- (NSString *)statusDisplayText:(TerracottaStatus)status role:(TerracottaRole)role {
    switch (status) {
        case TerracottaStatusDisconnected: return @"未联机";
        case TerracottaStatusConnecting:
            return (role == TerracottaRoleHost) ? @"创建房间中…" : @"加入房间中…";
        case TerracottaStatusConnected:
            return (role == TerracottaRoleHost) ? @"房主已就绪" : @"已加入房间";
        case TerracottaStatusError: return @"联机出错";
    }
    return @"";
}

- (NSString *)statusIconName:(TerracottaStatus)status {
    switch (status) {
        case TerracottaStatusDisconnected: return @"antenna.radiowaves.left.and.right.slash";
        case TerracottaStatusConnecting: return @"arrow.triangle.2.circlepath";
        case TerracottaStatusConnected: return @"antenna.radiowaves.left.and.right";
        case TerracottaStatusError: return @"exclamationmark.triangle.fill";
    }
    return @"questionmark.circle";
}

- (UIColor *)statusColor:(TerracottaStatus)status {
    switch (status) {
        case TerracottaStatusDisconnected: return [UIColor systemGrayColor];
        case TerracottaStatusConnecting: return [UIColor systemOrangeColor];
        case TerracottaStatusConnected: return [UIColor systemGreenColor];
        case TerracottaStatusError: return [UIColor systemRedColor];
    }
    return [UIColor systemGrayColor];
}

#pragma mark - Toast

- (void)showToast:(NSString *)message {
    UIAlertController *alert = [UIAlertController
        alertControllerWithTitle:nil
                          message:message
                   preferredStyle:UIAlertControllerStyleAlert];
    [self presentViewController:alert animated:YES completion:^{
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.2 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            [alert dismissViewControllerAnimated:YES completion:nil];
        });
    }];
}

#pragma mark - TextField Delegate

- (BOOL)textFieldShouldReturn:(UITextField *)textField {
    [textField resignFirstResponder];
    return YES;
}

@end
