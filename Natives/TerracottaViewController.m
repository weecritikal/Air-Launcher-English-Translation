#import "TerracottaViewController.h"
#import "TerracottaManager.h"
#import "TerracottaBridge.h"
#import "LauncherPreferences.h"
#import "utils.h"
#import "BackgroundManager.h"
#import "MultiplayerViewController.h"

/// FCL style Terracotta multiplayer screen (fully adapted to the custom launcher background)
///
/// The layout is modeled on the multiplayer module of FoldCraftLauncher:
/// - Top: status card (round status icon + status text + stage description + invite code/direct connect address)
/// - Middle: a UISegmentedControl to switch between "Create room" and "Join room"
/// - Create room panel: port input field + large button
/// - Join room panel: invite code input field + large button
/// - Session in progress: shows a "Disconnect" button + the player list
///
/// State observation refreshes the UI through the TerracottaManagerStateDidChangeNotification notification.
///
/// Background adaptation (modeled on MultiplayerViewController):
/// - viewDidLoad/viewWillAppear call makeViewControllerTransparent to make the VC transparent
/// - Every card/player row uses applyEffectToView: to inject frosted glass (or a translucent color in translucent mode)
/// - Text color switches between white (background image mode) and labelColor (system background mode) based on hasBackground
/// - Listens for the BackgroundUIEffectChanged notification and reapplies when the background changes
@interface TerracottaViewController () <UITextFieldDelegate>

/* Top status card */
@property(nonatomic, strong) UIView *statusCard;
@property(nonatomic, strong) UIImageView *statusIcon;
@property(nonatomic, strong) UILabel *statusLabel;
@property(nonatomic, strong) UILabel *stageLabel;
@property(nonatomic, strong) UIActivityIndicatorView *activityIndicator;
@property(nonatomic, strong) UILabel *inviteCodeLabel;
@property(nonatomic, strong) UIButton *inviteCopyButton;
@property(nonatomic, strong) UILabel *directConnectLabel;
@property(nonatomic, strong) UIButton *directCopyButton;

/* Tab switching */
@property(nonatomic, strong) UISegmentedControl *tabControl;
@property(nonatomic, strong) UIView *createPanel;
@property(nonatomic, strong) UIView *joinPanel;

/* Create room panel */
@property(nonatomic, strong) UILabel *createHintLabel;
@property(nonatomic, strong) UITextField *portField;
@property(nonatomic, strong) UIButton *createButton;

/* Join room panel */
@property(nonatomic, strong) UILabel *joinHintLabel;
@property(nonatomic, strong) UITextField *inviteField;
@property(nonatomic, strong) UIButton *joinButton;

/* Bottom area during a session */
@property(nonatomic, strong) UIButton *disconnectButton;
@property(nonatomic, strong) UILabel *playersTitleLabel;
@property(nonatomic, strong) UIStackView *playersList;

/* Container scroll view (for small screens) */
@property(nonatomic, strong) UIScrollView *scrollView;
@property(nonatomic, strong) UIView *contentView;

@end

@implementation TerracottaViewController

#pragma mark - Lifecycle

- (void)viewDidLoad {
    [super viewDidLoad];
    // self.title is deliberately not set, to avoid a black "Terracotta multiplayer" title bar at the top (modeled on FCL's title-less style)
    self.view.backgroundColor = [UIColor clearColor];

    // Hide the navigation bar band completely (only when this is a non-modal root page and the only VC on the stack)
    BOOL navBarHidden = NO;
    if (self.navigationController &&
        self.navigationController.viewControllers.firstObject == self &&
        self.navigationController.presentingViewController == nil &&
        self.navigationController.viewControllers.count == 1) {
        self.navigationController.navigationBarHidden = YES;
        navBarHidden = YES;
    }

    if (!navBarHidden) {
        /* Close button (modal mode) */
        UIBarButtonItem *closeItem = [[UIBarButtonItem alloc]
            initWithBarButtonSystemItem:UIBarButtonSystemItemClose
                                target:self
                                action:@selector(close)];
        self.navigationItem.leftBarButtonItem = closeItem;
    }

    /* ZeroTier multiplayer entry point: always a floating button placed at the top right of the view
       (kept even when the navigation bar is visible, to guarantee it is reachable in both modal and pushed modes) */
    UIButton *ztFab = [UIButton buttonWithType:UIButtonTypeSystem];
    [ztFab setImage:[UIImage systemImageNamed:@"network"] forState:UIControlStateNormal];
    ztFab.tintColor = [UIColor whiteColor];
    ztFab.backgroundColor = [UIColor systemBlueColor];
    ztFab.layer.cornerRadius = 18;
    ztFab.layer.masksToBounds = YES;
    ztFab.translatesAutoresizingMaskIntoConstraints = NO;
    ztFab.accessibilityLabel = @"ZeroTier multiplayer";
    [ztFab addTarget:self action:@selector(switchToZeroTier:) forControlEvents:UIControlEventTouchUpInside];
    [self.view addSubview:ztFab];
    [self.view bringSubviewToFront:ztFab];
    [NSLayoutConstraint activateConstraints:@[
        [ztFab.widthAnchor constraintEqualToConstant:36],
        [ztFab.heightAnchor constraintEqualToConstant:36],
        [ztFab.topAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.topAnchor constant:8],
        [ztFab.trailingAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.trailingAnchor constant:-16],
    ]];

    /* Adapt to the custom launcher background: make the VC transparent so the global background image/frosted glass shows through */
    [[BackgroundManager sharedManager] makeViewControllerTransparent:self];

    [self setupViews];
    [self registerNotifications];
    [self applyBackgroundEffects];
    [self refreshUI];
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    /* Hide the navigation bar strip again (topViewController == self when popping back to the root page) */
    if (self.navigationController &&
        self.navigationController.viewControllers.firstObject == self &&
        self.navigationController.presentingViewController == nil &&
        self.navigationController.topViewController == self) {
        self.navigationController.navigationBarHidden = YES;
    }
    /* Consistent with MultiplayerViewController: re-apply transparency and the navigation bar frosted glass on every appearance */
    [[BackgroundManager sharedManager] makeViewControllerTransparent:self];
    [[BackgroundManager sharedManager] applyEffectToNavigationBar:self.navigationController.navigationBar];
    [self applyBackgroundEffects];
}

- (void)viewWillDisappear:(BOOL)animated {
    [super viewWillDisappear:animated];
    /* Show the navigation bar when pushing a child page (the child page needs a back button) */
    if (self.navigationController &&
        self.navigationController.viewControllers.firstObject == self &&
        self.navigationController.presentingViewController == nil) {
        self.navigationController.navigationBarHidden = NO;
    }
}

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

#pragma mark - Background Adaptation

/// Listen for background effect changes (triggered when the user changes the background image/frosted glass mode/opacity)
- (void)registerBackgroundNotifications {
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(backgroundEffectChanged:)
                                                 name:@"BackgroundUIEffectChanged"
                                               object:nil];
}

/// Reapply all effects when the background effect changes, and refresh the player list (so rows re-read the background state)
- (void)backgroundEffectChanged:(NSNotification *)notification {
    dispatch_async(dispatch_get_main_queue(), ^{
        [[BackgroundManager sharedManager] makeViewControllerTransparent:self];
        [[BackgroundManager sharedManager] applyEffectToNavigationBar:self.navigationController.navigationBar];
        [self applyBackgroundEffects];
        [self refreshUI];
    });
}

/// Apply the frosted glass or translucent effect to every card/input field/player row
- (void)applyBackgroundEffects {
    /* Status card: inject frosted glass (or a translucent color) */
    [[BackgroundManager sharedManager] applyEffectToView:self.statusCard];

    /* Input fields: transparent background + injected frosted glass (so the background shows through) */
    [[BackgroundManager sharedManager] applyEffectToView:self.portField];
    [[BackgroundManager sharedManager] applyEffectToView:self.inviteField];

    /* Player list rows: inject frosted glass into each row */
    for (UIView *row in self.playersList.arrangedSubviews) {
        [[BackgroundManager sharedManager] applyEffectToView:row];
    }

    /* Text color: white in background image mode to guarantee contrast; labelColor in system background mode */
    BOOL hasBg = [[BackgroundManager sharedManager] hasBackground];
    UIColor *primaryText = hasBg ? [UIColor whiteColor] : [UIColor labelColor];
    UIColor *secondaryText = hasBg ? [UIColor colorWithWhite:1.0 alpha:0.8] : [UIColor secondaryLabelColor];
    UIColor *tertiaryText = hasBg ? [UIColor colorWithWhite:1.0 alpha:0.7] : [UIColor tertiaryLabelColor];

    self.statusLabel.textColor = primaryText;
    self.stageLabel.textColor = secondaryText;
    self.inviteCodeLabel.textColor = primaryText;
    self.directConnectLabel.textColor = secondaryText;
    self.createHintLabel.textColor = secondaryText;
    self.joinHintLabel.textColor = secondaryText;
    self.playersTitleLabel.textColor = primaryText;

    /* Input field text color (the placeholder color is handled by the system) */
    self.portField.textColor = primaryText;
    self.inviteField.textColor = primaryText;

    /* Copy button: white text in background image mode */
    self.inviteCopyButton.tintColor = secondaryText;
    self.directCopyButton.tintColor = secondaryText;

    /* Disconnect button border color (a more prominent white border + translucent red fill in background image mode) */
    if (hasBg) {
        [self.disconnectButton setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
        self.disconnectButton.layer.borderColor = [UIColor colorWithWhite:1.0 alpha:0.6].CGColor;
        self.disconnectButton.backgroundColor = [UIColor colorWithWhite:1.0 alpha:0.15];
    } else {
        [self.disconnectButton setTitleColor:[UIColor systemRedColor] forState:UIControlStateNormal];
        self.disconnectButton.layer.borderColor = [UIColor systemRedColor].CGColor;
        self.disconnectButton.backgroundColor = [UIColor clearColor];
    }
}

#pragma mark - UI Setup

- (void)setupViews {
    /* ScrollView container (for small screens) */
    self.scrollView = [[UIScrollView alloc] init];
    self.scrollView.translatesAutoresizingMaskIntoConstraints = NO;
    self.scrollView.alwaysBounceVertical = YES;
    self.scrollView.keyboardDismissMode = UIScrollViewKeyboardDismissModeOnDrag;
    self.scrollView.backgroundColor = [UIColor clearColor];
    [self.view addSubview:self.scrollView];

    self.contentView = [[UIView alloc] init];
    self.contentView.translatesAutoresizingMaskIntoConstraints = NO;
    self.contentView.backgroundColor = [UIColor clearColor];
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
    self.statusCard.backgroundColor = [UIColor clearColor];
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

    /* Invite code row */
    self.inviteCodeLabel = [self makeLabelWithFont:[UIFont fontWithName:@"Menlo" size:14]
                                        textColor:[UIColor labelColor]];
    self.inviteCodeLabel.numberOfLines = 0;
    [self.statusCard addSubview:self.inviteCodeLabel];

    self.inviteCopyButton = [self makeCopyButtonWithSelector:@selector(copyInviteCode:)];
    [self.statusCard addSubview:self.inviteCopyButton];

    /* Direct connect address row */
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
    self.tabControl = [[UISegmentedControl alloc] initWithItems:@[@"Create room", @"Join room"]];
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
    self.createPanel.backgroundColor = [UIColor clearColor];
    [self.contentView addSubview:self.createPanel];

    self.createHintLabel = [self makeLabelWithFont:[UIFont systemFontOfSize:13]
                                        textColor:[UIColor secondaryLabelColor]];
    self.createHintLabel.numberOfLines = 0;
    self.createHintLabel.text = @"In Minecraft, tap \"Open to LAN\" first, note the port number it shows, enter it below, and tap Create.";
    [self.createPanel addSubview:self.createHintLabel];

    self.portField = [self makeTextFieldWithPlaceholder:@"Minecraft LAN port (e.g. 25565)"
                                            keyboardType:UIKeyboardTypeNumberPad];
    self.portField.text = @"25565";
    self.portField.delegate = self;
    [self.createPanel addSubview:self.portField];

    self.createButton = [self makePrimaryButtonWithTitle:@"Create room"
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
    self.joinPanel.backgroundColor = [UIColor clearColor];
    [self.contentView addSubview:self.joinPanel];

    self.joinHintLabel = [self makeLabelWithFont:[UIFont systemFontOfSize:13]
                                       textColor:[UIColor secondaryLabelColor]];
    self.joinHintLabel.numberOfLines = 0;
    self.joinHintLabel.text = @"Enter the invite code the host shared. Once joined, connect to 127.0.0.1:25565 on Minecraft's multiplayer screen.";
    [self.joinPanel addSubview:self.joinHintLabel];

    self.inviteField = [self makeTextFieldWithPlaceholder:@"Invite code"
                                              keyboardType:UIKeyboardTypeDefault];
    self.inviteField.autocapitalizationType = UITextAutocapitalizationTypeNone;
    self.inviteField.autocorrectionType = UITextAutocorrectionTypeNo;
    self.inviteField.delegate = self;
    [self.joinPanel addSubview:self.inviteField];

    self.joinButton = [self makePrimaryButtonWithTitle:@"Join room"
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
    self.playersTitleLabel.text = @"Players";
    [self.contentView addSubview:self.playersTitleLabel];

    self.playersList = [[UIStackView alloc] init];
    self.playersList.translatesAutoresizingMaskIntoConstraints = NO;
    self.playersList.axis = UILayoutConstraintAxisVertical;
    self.playersList.spacing = 6;
    self.playersList.alignment = UIStackViewAlignmentFill;
    [self.contentView addSubview:self.playersList];

    self.disconnectButton = [UIButton buttonWithType:UIButtonTypeSystem];
    self.disconnectButton.translatesAutoresizingMaskIntoConstraints = NO;
    [self.disconnectButton setTitle:@"Disconnect" forState:UIControlStateNormal];
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
    /* Transparent background: frosted glass is injected by applyEffectToView: */
    field.backgroundColor = [UIColor clearColor];
    field.layer.cornerRadius = 8;
    field.clipsToBounds = YES;
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
        [self showToast:@"Please enter a valid port"];
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
        [self showToast:@"Please enter an invite code"];
        return;
    }
    [self.view endEditing:YES];
    NSString *playerName = [self currentPlayerName];
    BOOL ok = [[TerracottaManager shared] joinRoomWithInviteCode:code
                                                      playerName:playerName];
    if (!ok) {
        [self showToast:[[TerracottaManager shared] lastError] ?: @"Invalid invite code"];
    }
}

- (void)disconnectTapped:(UIButton *)sender {
    [[TerracottaManager shared] stopSession];
}

- (void)copyInviteCode:(UIButton *)sender {
    NSString *code = [TerracottaManager shared].currentInviteCode;
    if (code.length == 0) return;
    [UIPasteboard generalPasteboard].string = code;
    [self showToast:@"Invite code copied"];
}

- (void)copyDirectURL:(UIButton *)sender {
    NSString *url = [TerracottaManager shared].directConnectURL;
    if (url.length == 0) return;
    [UIPasteboard generalPasteboard].string = url;
    [self showToast:@"Address copied"];
}

- (void)close {
    /* Compatible with both containers: pushed into a UINavigationController (the launcher menu path) and presented modally (the in-game menu path) */
    if (self.navigationController && self.navigationController.viewControllers.firstObject != self) {
        [self.navigationController popViewControllerAnimated:YES];
    } else {
        [self dismissViewControllerAnimated:YES completion:nil];
    }
}

/// Switch to the ZeroTier multiplayer screen (both multiplayer solutions are kept and the user can switch freely)
- (void)switchToZeroTier:(UIBarButtonItem *)sender {
    /* Show a confirmation dialog so the user does not interrupt the current session by accident */
    TerracottaStatus status = [TerracottaManager shared].status;
    if (status != TerracottaStatusDisconnected) {
        UIAlertController *alert = [UIAlertController
            alertControllerWithTitle:@"Switch to ZeroTier multiplayer"
                              message:@"A Terracotta session is currently active and switching will disconnect it. Continue?"
                       preferredStyle:UIAlertControllerStyleAlert];
        [alert addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
        [alert addAction:[UIAlertAction actionWithTitle:@"Switch" style:UIAlertActionStyleDestructive handler:^(UIAlertAction *action) {
            [[TerracottaManager shared] stopSession];
            [self presentZeroTierVC];
        }]];
        [self presentViewController:alert animated:YES completion:nil];
        return;
    }
    [self presentZeroTierVC];
}

- (void)presentZeroTierVC {
    MultiplayerViewController *vc = [[MultiplayerViewController alloc] init];
    UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:vc];
    nav.modalPresentationStyle = UIModalPresentationPageSheet;
    /* If it was pushed onto a nav stack, cover it with present; if it is modal, present directly */
    [self presentViewController:nav animated:YES completion:nil];
}

#pragma mark - Player Name

- (NSString *)currentPlayerName {
    /* Prefer the launcher's current account name, otherwise use the device name */
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
    [self registerBackgroundNotifications];
}

- (void)stateDidChange:(NSNotification *)notification {
    [self refreshUI];
}

- (void)refreshUI {
    TerracottaManager *mgr = [TerracottaManager shared];

    /* Status text + icon */
    NSString *statusText = [self statusDisplayText:mgr.status role:mgr.role];
    self.statusLabel.text = statusText;
    self.statusIcon.image = [UIImage systemImageNamed:[self statusIconName:mgr.status]];
    self.statusIcon.tintColor = [self statusColor:mgr.status];

    /* Activity indicator */
    if (mgr.status == TerracottaStatusConnecting) {
        [self.activityIndicator startAnimating];
    } else {
        [self.activityIndicator stopAnimating];
    }

    /* Stage description */
    self.stageLabel.text = mgr.stageDescription ?: @"";

    /* Invite code */
    if (mgr.currentInviteCode.length > 0) {
        self.inviteCodeLabel.text = [NSString stringWithFormat:@"Invite code: %@", mgr.currentInviteCode];
        self.inviteCopyButton.hidden = NO;
    } else {
        self.inviteCodeLabel.text = nil;
        self.inviteCopyButton.hidden = YES;
    }

    /* Direct connect address */
    if (mgr.directConnectURL.length > 0) {
        self.directConnectLabel.text = [NSString stringWithFormat:@"Direct connect: %@", mgr.directConnectURL];
        self.directCopyButton.hidden = NO;
    } else {
        self.directConnectLabel.text = nil;
        self.directCopyButton.hidden = YES;
    }

    /* Session in progress: hide the tabs and panels, show the disconnect button and the player list */
    BOOL sessionActive = (mgr.status != TerracottaStatusDisconnected);
    self.tabControl.hidden = sessionActive;
    self.createPanel.hidden = sessionActive ?: (self.tabControl.selectedSegmentIndex != 0);
    self.joinPanel.hidden = sessionActive ?: (self.tabControl.selectedSegmentIndex != 1);
    self.disconnectButton.hidden = !sessionActive;
    self.playersTitleLabel.hidden = !sessionActive;

    /* Player list */
    [self refreshPlayersList:mgr.players role:mgr.role];

    /* Error notice (a toast is shown only the first time an error occurs) */
    if (mgr.status == TerracottaStatusError && mgr.lastError.length > 0) {
        self.stageLabel.text = mgr.lastError;
    }
}

- (void)refreshPlayersList:(NSArray<TerracottaPlayerProfile *> *)players
                      role:(TerracottaRole)role {
    /* Clear the old entries */
    for (UIView *v in self.playersList.arrangedSubviews) {
        [self.playersList removeArrangedSubview:v];
        [v removeFromSuperview];
    }
    if (players.count == 0) {
        UILabel *empty = [self makeLabelWithFont:[UIFont systemFontOfSize:13]
                                       textColor:[UIColor tertiaryLabelColor]];
        empty.text = (role == TerracottaRoleHost) ? @"Waiting for players to join…" : @"No player information";
        [self.playersList addArrangedSubview:empty];
        return;
    }
    for (TerracottaPlayerProfile *p in players) {
        [self.playersList addArrangedSubview:[self makePlayerRow:p role:role]];
    }
    /* New rows also need the background effect injected */
    for (UIView *row in self.playersList.arrangedSubviews) {
        [[BackgroundManager sharedManager] applyEffectToView:row];
    }
}

- (UIView *)makePlayerRow:(TerracottaPlayerProfile *)profile role:(TerracottaRole)role {
    UIView *row = [[UIView alloc] init];
    row.translatesAutoresizingMaskIntoConstraints = NO;
    row.backgroundColor = [UIColor clearColor];
    row.layer.cornerRadius = 8;
    row.layer.masksToBounds = YES;

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
    if ([kind isEqualToString:@"host"]) return @"Host";
    if ([kind isEqualToString:@"guest"]) return @"Guest";
    /* When there is no kind field, infer the host from profile_index == 0 */
    return @"Player";
}

- (NSString *)statusDisplayText:(TerracottaStatus)status role:(TerracottaRole)role {
    switch (status) {
        case TerracottaStatusDisconnected: return @"Not connected";
        case TerracottaStatusConnecting:
            return (role == TerracottaRoleHost) ? @"Creating room…" : @"Joining room…";
        case TerracottaStatusConnected:
            return (role == TerracottaRoleHost) ? @"Host ready" : @"Joined the room";
        case TerracottaStatusError: return @"Multiplayer error";
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
