#import "TerracottaViewController.h"
#import "TerracottaManager.h"
#import "TerracottaBridge.h"
#import "SilentAudioPlayer.h"

@interface TerracottaViewController ()
/* 顶部状态卡片 */
@property(nonatomic, strong) UIView *statusCard;
@property(nonatomic, strong) UILabel *statusLabel;
@property(nonatomic, strong) UILabel *stageLabel;
@property(nonatomic, strong) UILabel *inviteCodeLabel;
@property(nonatomic, strong) UIButton *copyInviteButton;
@property(nonatomic, strong) UILabel *directConnectLabel;
@property(nonatomic, strong) UIActivityIndicatorView *activityIndicator;

/* Tab 切换 */
@property(nonatomic, strong) UISegmentedControl *tabControl;
@property(nonatomic, strong) UIView *createRoomPanel;
@property(nonatomic, strong) UIView *joinRoomPanel;

/* 创建房间面板 */
@property(nonatomic, strong) UITextField *portTextField;
@property(nonatomic, strong) UISwitch *manualPortSwitch;
@property(nonatomic, strong) UIButton *createRoomButton;

/* 加入房间面板 */
@property(nonatomic, strong) UITextField *inviteCodeTextField;
@property(nonatomic, strong) UIButton *joinRoomButton;

/* 房间操作 */
@property(nonatomic, strong) UIButton *disconnectButton;

/* 玩家列表 */
@property(nonatomic, strong) UILabel *playersSectionTitle;
@property(nonatomic, strong) UIStackView *playersStackView;

/* 状态监听 */
@property(nonatomic, weak) NSObject *stateObserver;
@end

@implementation TerracottaViewController

#pragma mark - Lifecycle

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"陶瓦联机";
    self.view.backgroundColor = [UIColor systemBackgroundColor];

    /* 关闭按钮 */
    self.navigationItem.leftBarButtonItem = [[UIBarButtonItem alloc]
        initWithBarButtonSystemItem:UIBarButtonSystemItemClose
                             target:self
                             action:@selector(closeTapped)];

    [self setupUI];
    [self startObservingState];
    [self refreshUI];
}

- (void)dealloc {
    [self stopObservingState];
}

#pragma mark - UI Setup

- (void)setupUI {
    UIScrollView *scrollView = [[UIScrollView alloc] init];
    scrollView.translatesAutoresizingMaskIntoConstraints = NO;
    scrollView.alwaysBounceVertical = YES;
    [self.view addSubview:scrollView];
    [NSLayoutConstraint activateConstraints:@[
        [scrollView.topAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.topAnchor],
        [scrollView.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [scrollView.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [scrollView.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor],
    ]];

    UIView *contentView = [[UIView alloc] init];
    contentView.translatesAutoresizingMaskIntoConstraints = NO;
    [scrollView addSubview:contentView];
    [NSLayoutConstraint activateConstraints:@[
        [contentView.topAnchor constraintEqualToAnchor:scrollView.topAnchor],
        [contentView.leadingAnchor constraintEqualToAnchor:scrollView.leadingAnchor],
        [contentView.trailingAnchor constraintEqualToAnchor:scrollView.trailingAnchor],
        [contentView.bottomAnchor constraintEqualToAnchor:scrollView.bottomAnchor],
        [contentView.widthAnchor constraintEqualToAnchor:scrollView.widthAnchor],
    ]];

    [self buildStatusCardInContainer:contentView];
    [self buildTabControlInContainer:contentView];
    [self buildCreateRoomPanelInContainer:contentView];
    [self buildJoinRoomPanelInContainer:contentView];
    [self buildDisconnectButtonInContainer:contentView];
    [self buildPlayersSectionInContainer:contentView];
}

- (void)buildStatusCardInContainer:(UIView *)container {
    self.statusCard = [[UIView alloc] init];
    self.statusCard.translatesAutoresizingMaskIntoConstraints = NO;
    self.statusCard.backgroundColor = [UIColor secondarySystemBackgroundColor];
    self.statusCard.layer.cornerRadius = 16;
    self.statusCard.layer.masksToBounds = YES;
    [container addSubview:self.statusCard];
    [NSLayoutConstraint activateConstraints:@[
        [self.statusCard.topAnchor constraintEqualToAnchor:container.topAnchor constant:16],
        [self.statusCard.leadingAnchor constraintEqualToAnchor:container.leadingAnchor constant:16],
        [self.statusCard.trailingAnchor constraintEqualToAnchor:container.trailingAnchor constant:-16],
    ]];

    UIStackView *cardStack = [[UIStackView alloc] init];
    cardStack.translatesAutoresizingMaskIntoConstraints = NO;
    cardStack.axis = UILayoutConstraintAxisVertical;
    cardStack.spacing = 8;
    cardStack.alignment = UIStackViewAlignmentFill;
    [self.statusCard addSubview:cardStack];
    [NSLayoutConstraint activateConstraints:@[
        [cardStack.topAnchor constraintEqualToAnchor:self.statusCard.topAnchor constant:16],
        [cardStack.leadingAnchor constraintEqualToAnchor:self.statusCard.leadingAnchor constant:16],
        [cardStack.trailingAnchor constraintEqualToAnchor:self.statusCard.trailingAnchor constant:-16],
        [cardStack.bottomAnchor constraintEqualToAnchor:self.statusCard.bottomAnchor constant:-16],
    ]];

    /* 第一行：状态标签 + 活动指示器 */
    UIStackView *statusRow = [[UIStackView alloc] init];
    statusRow.axis = UILayoutConstraintAxisHorizontal;
    statusRow.spacing = 8;
    statusRow.alignment = UIStackViewAlignmentCenter;

    self.statusLabel = [[UILabel alloc] init];
    self.statusLabel.font = [UIFont systemFontOfSize:18 weight:UIFontWeightSemibold];
    [statusRow addArrangedSubview:self.statusLabel];

    self.activityIndicator = [[UIActivityIndicatorView alloc]
        initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleMedium];
    [statusRow addArrangedSubview:self.activityIndicator];

    [cardStack addArrangedSubview:statusRow];

    self.stageLabel = [[UILabel alloc] init];
    self.stageLabel.font = [UIFont systemFontOfSize:14];
    self.stageLabel.textColor = [UIColor secondaryLabelColor];
    self.stageLabel.numberOfLines = 0;
    [cardStack addArrangedSubview:self.stageLabel];

    /* 邀请码行 */
    UIStackView *inviteRow = [[UIStackView alloc] init];
    inviteRow.axis = UILayoutConstraintAxisHorizontal;
    inviteRow.spacing = 8;
    inviteRow.alignment = UIStackViewAlignmentCenter;

    UILabel *inviteTitleLabel = [[UILabel alloc] init];
    inviteTitleLabel.text = @"邀请码：";
    inviteTitleLabel.font = [UIFont systemFontOfSize:14 weight:UIFontWeightMedium];
    [inviteRow addArrangedSubview:inviteTitleLabel];

    self.inviteCodeLabel = [[UILabel alloc] init];
    self.inviteCodeLabel.font = [UIFont systemFontOfSize:16 weight:UIFontWeightSemibold];
    self.inviteCodeLabel.text = @"—";
    [inviteRow addArrangedSubview:self.inviteCodeLabel];

    self.copyInviteButton = [UIButton buttonWithType:UIButtonTypeSystem];
    [self.copyInviteButton setTitle:@"复制" forState:UIControlStateNormal];
    self.copyInviteButton.titleLabel.font = [UIFont systemFontOfSize:14];
    [self.copyInviteButton addTarget:self action:@selector(copyInviteCode)
                    forControlEvents:UIControlEventTouchUpInside];
    [inviteRow addArrangedSubview:self.copyInviteButton];

    [cardStack addArrangedSubview:inviteRow];

    /* 直连地址行 */
    UIStackView *urlRow = [[UIStackView alloc] init];
    urlRow.axis = UILayoutConstraintAxisHorizontal;
    urlRow.spacing = 8;
    urlRow.alignment = UIStackViewAlignmentCenter;

    UILabel *urlTitleLabel = [[UILabel alloc] init];
    urlTitleLabel.text = @"直连地址：";
    urlTitleLabel.font = [UIFont systemFontOfSize:14 weight:UIFontWeightMedium];
    [urlRow addArrangedSubview:urlTitleLabel];

    self.directConnectLabel = [[UILabel alloc] init];
    self.directConnectLabel.font = [UIFont systemFontOfSize:14];
    self.directConnectLabel.text = @"—";
    self.directConnectLabel.numberOfLines = 0;
    [urlRow addArrangedSubview:self.directConnectLabel];

    [cardStack addArrangedSubview:urlRow];
}

- (void)buildTabControlInContainer:(UIView *)container {
    self.tabControl = [[UISegmentedControl alloc] initWithItems:@[@"创建房间", @"加入房间"]];
    self.tabControl.translatesAutoresizingMaskIntoConstraints = NO;
    self.tabControl.selectedSegmentIndex = 0;
    [self.tabControl addTarget:self action:@selector(tabChanged)
              forControlEvents:UIControlEventValueChanged];
    [container addSubview:self.tabControl];
    [NSLayoutConstraint activateConstraints:@[
        [self.tabControl.topAnchor constraintEqualToAnchor:self.statusCard.bottomAnchor constant:16],
        [self.tabControl.leadingAnchor constraintEqualToAnchor:container.leadingAnchor constant:16],
        [self.tabControl.trailingAnchor constraintEqualToAnchor:container.trailingAnchor constant:-16],
    ]];
}

- (void)buildCreateRoomPanelInContainer:(UIView *)container {
    self.createRoomPanel = [[UIView alloc] init];
    self.createRoomPanel.translatesAutoresizingMaskIntoConstraints = NO;
    [container addSubview:self.createRoomPanel];
    [NSLayoutConstraint activateConstraints:@[
        [self.createRoomPanel.topAnchor constraintEqualToAnchor:self.tabControl.bottomAnchor constant:16],
        [self.createRoomPanel.leadingAnchor constraintEqualToAnchor:container.leadingAnchor constant:16],
        [self.createRoomPanel.trailingAnchor constraintEqualToAnchor:container.trailingAnchor constant:-16],
    ]];

    UIStackView *stack = [[UIStackView alloc] init];
    stack.translatesAutoresizingMaskIntoConstraints = NO;
    stack.axis = UILayoutConstraintAxisVertical;
    stack.spacing = 12;
    stack.alignment = UIStackViewAlignmentFill;
    [self.createRoomPanel addSubview:stack];
    [NSLayoutConstraint activateConstraints:@[
        [stack.topAnchor constraintEqualToAnchor:self.createRoomPanel.topAnchor],
        [stack.leadingAnchor constraintEqualToAnchor:self.createRoomPanel.leadingAnchor],
        [stack.trailingAnchor constraintEqualToAnchor:self.createRoomPanel.trailingAnchor],
        [stack.bottomAnchor constraintEqualToAnchor:self.createRoomPanel.bottomAnchor],
    ]];

    /* 提示标签 */
    UILabel *hintLabel = [[UILabel alloc] init];
    hintLabel.text = @"在 MC 内点「对局域网开放」后会显示端口号（如 25565），填入下方并创建房间。"
                      @"朋友用任意支持陶瓦联机的启动器（HMCL/FCL/ZL2）输入邀请码即可加入。";
    hintLabel.font = [UIFont systemFontOfSize:13];
    hintLabel.textColor = [UIColor secondaryLabelColor];
    hintLabel.numberOfLines = 0;
    [stack addArrangedSubview:hintLabel];

    /* 端口输入 */
    UIStackView *portRow = [[UIStackView alloc] init];
    portRow.axis = UILayoutConstraintAxisHorizontal;
    portRow.spacing = 8;
    portRow.alignment = UIStackViewAlignmentCenter;

    UILabel *portTitleLabel = [[UILabel alloc] init];
    portTitleLabel.text = @"MC LAN 端口：";
    portTitleLabel.font = [UIFont systemFontOfSize:14 weight:UIFontWeightMedium];
    [portRow addArrangedSubview:portTitleLabel];

    self.portTextField = [[UITextField alloc] init];
    self.portTextField.borderStyle = UITextBorderStyleRoundedRect;
    self.portTextField.placeholder = @"25565";
    self.portTextField.keyboardType = UIKeyboardTypeNumberPad;
    self.portTextField.text = @"25565";
    [portRow addArrangedSubview:self.portTextField];

    [stack addArrangedSubview:portRow];

    /* 创建按钮 */
    self.createRoomButton = [UIButton buttonWithType:UIButtonTypeSystem];
    [self.createRoomButton setTitle:@"创建房间" forState:UIControlStateNormal];
    self.createRoomButton.titleLabel.font = [UIFont systemFontOfSize:17 weight:UIFontWeightSemibold];
    self.createRoomButton.backgroundColor = [UIColor systemBlueColor];
    [self.createRoomButton setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    self.createRoomButton.layer.cornerRadius = 12;
    [self.createRoomButton.heightAnchor constraintEqualToConstant:44].active = YES;
    [self.createRoomButton addTarget:self action:@selector(createRoomTapped)
                    forControlEvents:UIControlEventTouchUpInside];
    [stack addArrangedSubview:self.createRoomButton];
}

- (void)buildJoinRoomPanelInContainer:(UIView *)container {
    self.joinRoomPanel = [[UIView alloc] init];
    self.joinRoomPanel.translatesAutoresizingMaskIntoConstraints = NO;
    self.joinRoomPanel.hidden = YES;
    [container addSubview:self.joinRoomPanel];
    [NSLayoutConstraint activateConstraints:@[
        [self.joinRoomPanel.topAnchor constraintEqualToAnchor:self.tabControl.bottomAnchor constant:16],
        [self.joinRoomPanel.leadingAnchor constraintEqualToAnchor:container.leadingAnchor constant:16],
        [self.joinRoomPanel.trailingAnchor constraintEqualToAnchor:container.trailingAnchor constant:-16],
    ]];

    UIStackView *stack = [[UIStackView alloc] init];
    stack.translatesAutoresizingMaskIntoConstraints = NO;
    stack.axis = UILayoutConstraintAxisVertical;
    stack.spacing = 12;
    stack.alignment = UIStackViewAlignmentFill;
    [self.joinRoomPanel addSubview:stack];
    [NSLayoutConstraint activateConstraints:@[
        [stack.topAnchor constraintEqualToAnchor:self.joinRoomPanel.topAnchor],
        [stack.leadingAnchor constraintEqualToAnchor:self.joinRoomPanel.leadingAnchor],
        [stack.trailingAnchor constraintEqualToAnchor:self.joinRoomPanel.trailingAnchor],
        [stack.bottomAnchor constraintEqualToAnchor:self.joinRoomPanel.bottomAnchor],
    ]];

    UILabel *hintLabel = [[UILabel alloc] init];
    hintLabel.text = @"输入房主分享的邀请码（格式如 U/NNNN-NNNN-SSSS-SSSS）即可加入房间，"
                      @"连接成功后在 MC「直接连接」输入 127.0.0.1:25565。";
    hintLabel.font = [UIFont systemFontOfSize:13];
    hintLabel.textColor = [UIColor secondaryLabelColor];
    hintLabel.numberOfLines = 0;
    [stack addArrangedSubview:hintLabel];

    self.inviteCodeTextField = [[UITextField alloc] init];
    self.inviteCodeTextField.borderStyle = UITextBorderStyleRoundedRect;
    self.inviteCodeTextField.placeholder = @"U/XXXX-XXXX-XXXX-XXXX";
    self.inviteCodeTextField.autocapitalizationType = UITextAutocapitalizationTypeNone;
    self.inviteCodeTextField.autocorrectionType = UITextAutocorrectionTypeNo;
    self.inviteCodeTextField.font = [UIFont systemFontOfSize:16];
    [stack addArrangedSubview:self.inviteCodeTextField];

    self.joinRoomButton = [UIButton buttonWithType:UIButtonTypeSystem];
    [self.joinRoomButton setTitle:@"加入房间" forState:UIControlStateNormal];
    self.joinRoomButton.titleLabel.font = [UIFont systemFontOfSize:17 weight:UIFontWeightSemibold];
    self.joinRoomButton.backgroundColor = [UIColor systemBlueColor];
    [self.joinRoomButton setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    self.joinRoomButton.layer.cornerRadius = 12;
    [self.joinRoomButton.heightAnchor constraintEqualToConstant:44].active = YES;
    [self.joinRoomButton addTarget:self action:@selector(joinRoomTapped)
                  forControlEvents:UIControlEventTouchUpInside];
    [stack addArrangedSubview:self.joinRoomButton];
}

- (void)buildDisconnectButtonInContainer:(UIView *)container {
    self.disconnectButton = [UIButton buttonWithType:UIButtonTypeSystem];
    self.disconnectButton.translatesAutoresizingMaskIntoConstraints = NO;
    [self.disconnectButton setTitle:@"断开连接" forState:UIControlStateNormal];
    self.disconnectButton.titleLabel.font = [UIFont systemFontOfSize:16 weight:UIFontWeightMedium];
    self.disconnectButton.backgroundColor = [UIColor systemRedColor];
    [self.disconnectButton setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    self.disconnectButton.layer.cornerRadius = 12;
    [self.disconnectButton.heightAnchor constraintEqualToConstant:44].active = YES;
    [self.disconnectButton addTarget:self action:@selector(disconnectTapped)
                    forControlEvents:UIControlEventTouchUpInside];
    self.disconnectButton.hidden = YES;
    [container addSubview:self.disconnectButton];
    [NSLayoutConstraint activateConstraints:@[
        [self.disconnectButton.topAnchor constraintEqualToAnchor:self.createRoomPanel.bottomAnchor constant:16],
        [self.disconnectButton.leadingAnchor constraintEqualToAnchor:container.leadingAnchor constant:16],
        [self.disconnectButton.trailingAnchor constraintEqualToAnchor:container.trailingAnchor constant:-16],
    ]];
}

- (void)buildPlayersSectionInContainer:(UIView *)container {
    self.playersSectionTitle = [[UILabel alloc] init];
    self.playersSectionTitle.translatesAutoresizingMaskIntoConstraints = NO;
    self.playersSectionTitle.text = @"房间玩家";
    self.playersSectionTitle.font = [UIFont systemFontOfSize:15 weight:UIFontWeightSemibold];
    self.playersSectionTitle.textColor = [UIColor secondaryLabelColor];
    self.playersSectionTitle.hidden = YES;
    [container addSubview:self.playersSectionTitle];
    [NSLayoutConstraint activateConstraints:@[
        [self.playersSectionTitle.topAnchor constraintEqualToAnchor:self.disconnectButton.bottomAnchor constant:16],
        [self.playersSectionTitle.leadingAnchor constraintEqualToAnchor:container.leadingAnchor constant:16],
        [self.playersSectionTitle.trailingAnchor constraintEqualToAnchor:container.trailingAnchor constant:-16],
        [self.playersSectionTitle.bottomAnchor constraintEqualToAnchor:container.bottomAnchor constant:-16],
    ]];

    self.playersStackView = [[UIStackView alloc] init];
    self.playersStackView.translatesAutoresizingMaskIntoConstraints = NO;
    self.playersStackView.axis = UILayoutConstraintAxisVertical;
    self.playersStackView.spacing = 6;
    self.playersStackView.alignment = UIStackViewAlignmentFill;
    [container addSubview:self.playersStackView];
    [NSLayoutConstraint activateConstraints:@[
        [self.playersStackView.topAnchor constraintEqualToAnchor:self.playersSectionTitle.bottomAnchor constant:8],
        [self.playersStackView.leadingAnchor constraintEqualToAnchor:container.leadingAnchor constant:16],
        [self.playersStackView.trailingAnchor constraintEqualToAnchor:container.trailingAnchor constant:-16],
        [self.playersStackView.bottomAnchor constraintLessThanOrEqualToAnchor:container.bottomAnchor constant:-16],
    ]];
}

#pragma mark - Actions

- (void)closeTapped {
    [self dismissViewControllerAnimated:YES completion:nil];
}

- (void)tabChanged {
    BOOL isCreate = (self.tabControl.selectedSegmentIndex == 0);
    self.createRoomPanel.hidden = !isCreate;
    self.joinRoomPanel.hidden = isCreate;
}

- (void)createRoomTapped {
    [self.portTextField resignFirstResponder];
    uint16_t port = (uint16_t)[self.portTextField.text integerValue];
    if (port == 0) {
        [self showAlertWithTitle:@"端口错误" message:@"请输入有效的 MC LAN 端口（1-65535）"];
        return;
    }

    /* 检查 MC 是否已开放 LAN（提示用户） */
    TerracottaManager *mgr = [TerracottaManager shared];
    BOOL ok = [mgr createRoomWithPort:port
                           inviteCode:nil
                           playerName:nil];
    if (!ok) {
        [self showAlertWithTitle:@"创建失败" message:mgr.lastError ?: @"未知错误"];
    }
}

- (void)joinRoomTapped {
    [self.inviteCodeTextField resignFirstResponder];
    NSString *code = [self.inviteCodeTextField.text stringByTrimmingCharactersInSet:
                      [NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (code.length == 0) {
        [self showAlertWithTitle:@"邀请码为空" message:@"请输入房主分享的邀请码"];
        return;
    }

    TerracottaManager *mgr = [TerracottaManager shared];
    BOOL ok = [mgr joinRoomWithInviteCode:code playerName:nil];
    if (!ok) {
        [self showAlertWithTitle:@"加入失败" message:mgr.lastError ?: @"未知错误"];
    }
}

- (void)disconnectTapped {
    [[TerracottaManager shared] stopSession];
}

- (void)copyInviteCode {
    NSString *code = [TerracottaManager shared].currentInviteCode;
    if (code.length == 0) return;
    [UIPasteboard generalPasteboard].string = code;

    /* 简单的视觉反馈：临时改按钮标题 */
    NSString *originalTitle = [self.copyInviteButton titleForState:UIControlStateNormal];
    [self.copyInviteButton setTitle:@"已复制" forState:UIControlStateNormal];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.5 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        [self.copyInviteButton setTitle:originalTitle forState:UIControlStateNormal];
    });
}

#pragma mark - State Observation

- (void)startObservingState {
    __weak typeof(self) weakSelf = self;
    id observer = [[NSNotificationCenter defaultCenter]
        addObserverForName:TerracottaManagerStateDidChangeNotification
                    object:nil
                     queue:[NSOperationQueue mainQueue]
                usingBlock:^(NSNotification *note) {
        [weakSelf refreshUI];
    }];
    self.stateObserver = observer;
}

- (void)stopObservingState {
    if (self.stateObserver != nil) {
        [[NSNotificationCenter defaultCenter] removeObserver:self.stateObserver];
        self.stateObserver = nil;
    }
}

- (void)refreshUI {
    TerracottaManager *mgr = [TerracottaManager shared];

    /* 状态标签 */
    NSString *statusText = nil;
    UIColor *statusColor = nil;
    switch (mgr.status) {
        case TerracottaStatusDisconnected: statusText = @"未连接";  statusColor = [UIColor secondaryLabelColor]; break;
        case TerracottaStatusConnecting:   statusText = @"连接中";  statusColor = [UIColor systemOrangeColor];   break;
        case TerracottaStatusConnected:    statusText = @"已连接";  statusColor = [UIColor systemGreenColor];   break;
        case TerracottaStatusError:        statusText = @"出错";    statusColor = [UIColor systemRedColor];     break;
    }
    self.statusLabel.text = statusText;
    self.statusLabel.textColor = statusColor;

    /* 阶段描述 */
    self.stageLabel.text = mgr.stageDescription;

    /* 活动指示器 */
    if (mgr.status == TerracottaStatusConnecting) {
        [self.activityIndicator startAnimating];
    } else {
        [self.activityIndicator stopAnimating];
    }

    /* 邀请码 */
    self.inviteCodeLabel.text = mgr.currentInviteCode ?: @"—";
    self.copyInviteButton.hidden = (mgr.currentInviteCode.length == 0);

    /* 直连地址 */
    self.directConnectLabel.text = mgr.directConnectURL ?: @"—";

    /* 面板可见性：连接中或已连接时隐藏创建/加入面板，显示断开按钮 */
    BOOL inSession = (mgr.status == TerracottaStatusConnecting || mgr.status == TerracottaStatusConnected);
    self.tabControl.hidden = inSession;
    self.createRoomPanel.hidden = inSession ? YES : (self.tabControl.selectedSegmentIndex != 0);
    self.joinRoomPanel.hidden = inSession ? YES : (self.tabControl.selectedSegmentIndex != 1);
    self.disconnectButton.hidden = !inSession;

    /* 玩家列表 */
    BOOL hasPlayers = (mgr.players.count > 0);
    self.playersSectionTitle.hidden = !hasPlayers;
    [self refreshPlayersList:mgr.players];
}

- (void)refreshPlayersList:(NSArray<TerracottaPlayerProfile *> *)players {
    /* 清空旧的子视图 */
    for (UIView *v in self.playersStackView.arrangedSubviews) {
        [self.playersStackView removeArrangedSubview:v];
        [v removeFromSuperview];
    }

    for (TerracottaPlayerProfile *p in players) {
        UIView *row = [[UIView alloc] init];
        row.backgroundColor = [UIColor secondarySystemBackgroundColor];
        row.layer.cornerRadius = 8;

        UIStackView *rowStack = [[UIStackView alloc] init];
        rowStack.translatesAutoresizingMaskIntoConstraints = NO;
        rowStack.axis = UILayoutConstraintAxisHorizontal;
        rowStack.spacing = 8;
        rowStack.alignment = UIStackViewAlignmentCenter;
        [row addSubview:rowStack];
        [NSLayoutConstraint activateConstraints:@[
            [rowStack.topAnchor constraintEqualToAnchor:row.topAnchor constant:8],
            [rowStack.leadingAnchor constraintEqualToAnchor:row.leadingAnchor constant:12],
            [rowStack.trailingAnchor constraintEqualToAnchor:row.trailingAnchor constant:-12],
            [rowStack.bottomAnchor constraintEqualToAnchor:row.bottomAnchor constant:-8],
        ]];

        UILabel *nameLabel = [[UILabel alloc] init];
        nameLabel.text = p.name;
        nameLabel.font = [UIFont systemFontOfSize:15 weight:UIFontWeightMedium];
        [rowStack addArrangedSubview:nameLabel];

        UILabel *roleLabel = [[UILabel alloc] init];
        roleLabel.text = p.kind;
        roleLabel.font = [UIFont systemFontOfSize:12];
        roleLabel.textColor = [UIColor secondaryLabelColor];
        [rowStack addArrangedSubview:roleLabel];

        /* 占位弹簧让内容靠左 */
        UIView *spacer = [[UIView alloc] init];
        [rowStack addArrangedSubview:spacer];

        [self.playersStackView addArrangedSubview:row];
    }
}

#pragma mark - Helpers

- (void)showAlertWithTitle:(NSString *)title message:(NSString *)message {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:title
                                                                    message:message
                                                             preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"好" style:UIAlertActionStyleDefault handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
}

@end
