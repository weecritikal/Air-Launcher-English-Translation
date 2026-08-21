//
//  MultiplayerViewController.m
//  Flux
//
//  Implementation of the Minecraft multiplayer screen (the FCL-style rebuild)
//
//  This file was redesigned after the multiplayer flow of FCL (FoldCraftLauncher):
//
//  Mode 1: launcher mode (MultiplayerVCModeLauncher)
//    Before launching the game, the user enables multiplayer here, sets the preset network ID, manages rooms and configures direct connections.
//    Section 0 "Multiplayer settings": a UISwitch to enable multiplayer + the preset network ID display/editor
//    Section 1 "My rooms": the saved room list (each row showing the room name + network ID + status + a connect/disconnect button)
//    Section 2 "Direct connect": IP+port input + a join button (written into PLProfiles)
//
//  Mode 2: in-game mode (MultiplayerVCModeInGame)
//    Reached from the floating button menu after launching, where the user chooses to host or join.
//    Section 0 "Choose a role": a Host button + a Guest button (large card style)
//    Section 1 "Multiplayer status": the current status + network ID + local IP
//
//  Key change (port detection replaced by manual entry):
//    The host flow used to rely on LanPortDetector detecting the LAN port automatically (by intercepting the Minecraft log or reading
//    latestlog.txt), which had these problems:
//      - latestlog.txt could contain the LAN port from a previous session and be mistaken for the current one
//      - log formats vary widely between Minecraft versions, so automatic detection was unreliable
//      - a share code could be generated before the game had really been opened to LAN
//    The port is now entered by hand: once connected, an input dialog appears, and only after the user opens the world to LAN in Minecraft
//    and enters the port from the chat box is a share code generated.
//  The host flow:
//    1. check that the ZeroTier framework is available and that a preset network ID is set
//    2. connect to the room for the preset network ID (calling connectToRoom:completion:)
//    3. show the manual port input dialog once connected (showManualPortInputAlert)
//    4. the user opens the world to LAN in Minecraft and enters the port from the chat box
//    5. generate the share code (calling generateShareCodeForRoom:)
//    6. show the share code (which can be copied and shared)
//
//  The guest flow:
//    1. show an input dialog (a UIAlertController with a text field)
//    2. parse the share code (calling parseShareCode:)
//    3. connect to the room (calling connectToRoom:completion:)
//    4. confirm on success and show the server address (the host IP:port)
//

#import "MultiplayerViewController.h"
#import "MultiplayerManager.h"
#import "BackgroundManager.h"
#import "LauncherPreferences.h"
#import "PLProfiles.h"
#import "LanPortDetector.h"
#import "ZeroTierBridge.h"
#import "utils.h"
#import "FluxTheme.h"

/// Localization helper
/// It looks the text up with localize() first, and uses the fallback passed in when nothing is found (the return value equals the key).
/// This satisfies the "every new string must be localizable" rule while making sure the user never sees a raw key for an unregistered one.
NS_INLINE NSString *MPLocalized(NSString *key, NSString *fallback) {
    NSString *value = localize(key, nil);
    return [value isEqualToString:key] ? (fallback ?: key) : value;
}

@interface MultiplayerViewController () <UITableViewDataSource, UITableViewDelegate, UITextFieldDelegate, MultiplayerManagerDelegate>

/// The current screen mode (launcher / in-game)
@property (nonatomic, assign) MultiplayerVCMode mode;

/// The main table view (InsetGrouped style)
@property (nonatomic, strong) UITableView *tableView;

/// The saved room list
@property (nonatomic, strong) NSArray<MultiplayerRoom *> *rooms;

#pragma mark - Controls specific to launcher mode

/// The "Enable multiplayer" switch at section 0, row 0
@property (nonatomic, strong) UISwitch *enableSwitch;

/// The IP address field at section 2, row 0 (held strongly, so the data is not lost when cells are reused)
@property (nonatomic, strong) UITextField *directIPField;

/// The port field at section 2, row 0 (held strongly)
@property (nonatomic, strong) UITextField *directPortField;

#pragma mark - State specific to in-game mode

/// Whether the host flow is active (the user tapped "Host" and is waiting or connected)
@property (nonatomic, assign) BOOL isHostFlowActive;

/// Whether the guest flow is active (the user tapped "Guest" and is waiting or connected)
@property (nonatomic, assign) BOOL isGuestFlowActive;

/// The most recent share code generated in the host flow (for display and copying)
@property (nonatomic, copy, nullable) NSString *lastShareCode;

/// The most recent server address parsed in the guest flow (hostIP:hostPort, shown to the user)
@property (nonatomic, copy, nullable) NSString *lastServerAddress;

/// The room object in use in the host flow (used to generate the share code)
@property (nonatomic, strong, nullable) MultiplayerRoom *hostRoom;

/// The room object connecting in the guest flow (used to show the connection state)
@property (nonatomic, strong, nullable) MultiplayerRoom *guestRoom;

/// The connection progress alert (whose progress text is updated live)
///
/// When the host or guest flow starts connecting, this alert is presented and shows the progress text.
/// The multiplayerConnectionProgress: callback updates its message property,
/// so the user sees live progress such as "Step 1/6: starting the ZeroTier node...".
///
/// Key fix: the connection flow used to show a single static "Connecting to the ZeroTier network" message,
/// leaving the user with no idea of the progress and simply waiting 15-30 seconds for success or failure.
/// This alert now updates live, so the user sees the detailed steps.
@property (nonatomic, strong, nullable) UIAlertController *connectionProgressAlert;

@end

@implementation MultiplayerViewController

#pragma mark - Init

/// Initialize the multiplayer screen with a mode
/// @param mode The screen mode (launcher / in-game)
- (instancetype)initWithMode:(MultiplayerVCMode)mode {
    self = [super initWithNibName:nil bundle:nil];
    if (self) {
        _mode = mode;
    }
    return self;
}

/// Fallback initializer: launcher mode is used when no mode is given
- (instancetype)init {
    return [self initWithMode:MultiplayerVCModeLauncher];
}

#pragma mark - Lifecycle

- (void)viewDidLoad {
    [super viewDidLoad];

    // self.title is deliberately not set, to avoid a black "Multiplayer" title band in the navigation bar (matching the title-less FCL style)

    // Adapt to the custom launcher background: make this VC transparent so the global background image/blur shows through
    [[BackgroundManager sharedManager] makeViewControllerTransparent:self];

    // Hide the navigation bar band completely (only as a root page; it is kept when presented modally or pushed)
    [self hideNavBarIfRoot];

    // Initialize the data: read the saved room list from MultiplayerManager
    self.rooms = [[MultiplayerManager sharedManager] savedRooms] ?: @[];

    // Build the UI
    [self setupUI];

    // Register as the MultiplayerManager delegate, to receive live node/network state callbacks
    [MultiplayerManager sharedManager].delegate = self;

    // Listen for background effect changes, re-applying transparency and refreshing the table when the background switches
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(backgroundEffectChanged)
                                                 name:@"BackgroundUIEffectChanged"
                                               object:nil];

    // In-game mode: listen for the LAN port detection notification (which the host flow depends on)
    if (self.mode == MultiplayerVCModeInGame) {
        [[NSNotificationCenter defaultCenter] addObserver:self
                                                 selector:@selector(lanPortDidDetect:)
                                                     name:LanPortDetectorDidDetectPortNotification
                                                   object:nil];
    }
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];

    // Hide the navigation bar band again (when popping back to the root page)
    [self hideNavBarIfRoot];

    // Re-apply the background effect on entry (the background may have been changed elsewhere)
    [[BackgroundManager sharedManager] makeViewControllerTransparent:self];
    self.tableView.backgroundColor = [UIColor clearColor];
    self.tableView.backgroundView = nil;

    // Re-apply the frosted-glass navigation bar effect
    [[BackgroundManager sharedManager] applyEffectToNavigationBar:self.navigationController.navigationBar];

    // Refresh the room list (it may have been changed elsewhere)
    [self refreshRooms];

    // Launcher mode: restore the switch state from the persisted user intent
    //
    // Key fix (the switch state going out of sync):
    // isNodeStarted (the runtime state) used to restore the switch, which had these problems:
    //   - the user turns the switch ON -> the node starts in the background (taking 5+ seconds) -> the user closes the VC ->
    //     reopens the VC -> the node may still be starting (isNodeStarted=NO) -> the switch reads OFF
    //   - the user turns the switch ON -> the node starts successfully -> the user closes the launcher (killing the process) ->
    //     reopens the launcher -> isNodeStarted=NO (the state was lost with the process) -> the switch reads OFF
    //
    // The fix: restore the switch from isMultiplayerEnabled (persisted to NSUserDefaults),
    // which reflects the user's intent rather than the node state. The switch is then right even after closing and reopening the launcher.
    if (self.mode == MultiplayerVCModeLauncher) {
        BOOL enabled = [[MultiplayerManager sharedManager] isMultiplayerEnabled];
        [self.enableSwitch setOn:enabled animated:NO];

        // If the user had enabled multiplayer but the node is not running (after closing and reopening the launcher),
        // restart the node automatically so the experience is seamless.
        if (enabled && ![[MultiplayerManager sharedManager] isNodeStarted]) {
            if ([[MultiplayerManager sharedManager] isFrameworkAvailable]) {
                NSLog(@"[MultiplayerVC] Multiplayer enabled but node not started, auto-restarting node...");
                __weak typeof(self) weakSelf = self;
                [[MultiplayerManager sharedManager] ensureNodeStartedWithCompletion:^(BOOL success, NSError *error) {
                    __strong typeof(weakSelf) strongSelf = weakSelf;
                    if (!strongSelf) return;

                    if (!success) {
                        // Key fix (critical 5): a failed node start must not clear the user's persisted intent.
                        // The old implementation called setMultiplayerEnabled:NO, so the switch was already OFF
                        // the next time the launcher opened and had to be enabled by hand again.
                        // Only the UI switch is reverted now (visually off) while isMultiplayerEnabled stays YES,
                        // so next time the launcher opens the switch reads ON and starting the node is retried automatically.
                        // The intent is only cleared when the framework is unavailable (a permanent condition).
                        NSLog(@"[MultiplayerVC] Auto-restart node failed (preserving user intent, retry next time): %@", error.localizedDescription);
                        [strongSelf.tableView reloadData];
                    } else {
                        NSLog(@"[MultiplayerVC] Auto-restart node succeeded");
                        [strongSelf.tableView reloadData];
                    }
                }];
            } else {
                // An unavailable framework is a permanent failure, so the user intent is cleared
                [[MultiplayerManager sharedManager] setMultiplayerEnabled:NO];
                [self.enableSwitch setOn:NO animated:NO];
            }
        }
    }
}

- (void)viewWillDisappear:(BOOL)animated {
    [super viewWillDisappear:animated];
    // Show the navigation bar when a child page is pushed (it needs a back button)
    if (self.navigationController &&
        self.navigationController.viewControllers.firstObject == self &&
        self.navigationController.presentingViewController == nil) {
        self.navigationController.navigationBarHidden = NO;
    }
}

- (void)backgroundEffectChanged {
    // When the background effect changes, make this VC transparent again and refresh the table so every cell picks up the new text color
    dispatch_async(dispatch_get_main_queue(), ^{
        [[BackgroundManager sharedManager] makeViewControllerTransparent:self];
        self.tableView.backgroundColor = [UIColor clearColor];
        self.tableView.backgroundView = nil;
        // Re-apply the frosted-glass navigation bar effect
        [[BackgroundManager sharedManager] applyEffectToNavigationBar:self.navigationController.navigationBar];
        // Refresh the table so every cell re-reads the background state and adapts its colors
        [self.tableView reloadData];
    });
}

- (void)dealloc {
    // Remove the notification observers, so a notification after dealloc cannot crash
    [[NSNotificationCenter defaultCenter] removeObserver:self];
    // Clear the delegate reference, to avoid a dangling pointer
    if ([MultiplayerManager sharedManager].delegate == self) {
        [MultiplayerManager sharedManager].delegate = nil;
    }
}

#pragma mark - UI Setup

- (void)setupUI {
    // The InsetGrouped style gives a card layout, matching the system Settings app
    self.tableView = [[UITableView alloc] initWithFrame:CGRectZero style:UITableViewStyleInsetGrouped];
    self.tableView.translatesAutoresizingMaskIntoConstraints = NO;
    self.tableView.dataSource = self;
    self.tableView.delegate = self;
    self.tableView.backgroundColor = [UIColor clearColor];
    self.tableView.backgroundView = nil;
    // Enable automatic sizing
    self.tableView.rowHeight = UITableViewAutomaticDimension;
    self.tableView.estimatedRowHeight = 56;
    // Register the reusable cell types
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

    // Top left of the navigation bar: the close button (xmark), needed in both modes
    UIBarButtonItem *closeButton = [[UIBarButtonItem alloc] initWithImage:[UIImage systemImageNamed:@"xmark"]
                                                                     style:UIBarButtonItemStylePlain
                                                                    target:self
                                                                    action:@selector(closeTapped)];
    closeButton.accessibilityLabel = MPLocalized(@"mp.close", @"Close");
    self.navigationItem.leftBarButtonItem = closeButton;

    // Note: launcher mode needs no button on the right (the network ID is set from section 0)
    // Note: in-game mode needs no button on the right either (host/guest are chosen from section 0)

    // Apply the frosted-glass navigation bar effect
    [[BackgroundManager sharedManager] applyEffectToNavigationBar:self.navigationController.navigationBar];
}

#pragma mark - Navigation Actions

/// Close button handler: works whether this was pushed or presented
- (void)closeTapped {
    [self.view endEditing:YES];
    if (self.navigationController && self.navigationController.viewControllers.firstObject != self) {
        [self.navigationController popViewControllerAnimated:YES];
    } else {
        [self dismissViewControllerAnimated:YES completion:nil];
    }
}

/// Hide the navigation bar band completely when this VC is the nav root, was not presented modally and is the only VC on the stack
/// Shortcuts pre-push a child page, so count > 1 and the navigation bar stays visible
- (void)hideNavBarIfRoot {
    if (self.navigationController &&
        self.navigationController.viewControllers.firstObject == self &&
        self.navigationController.presentingViewController == nil &&
        self.navigationController.viewControllers.count == 1) {
        self.navigationController.navigationBarHidden = YES;
    } else if (self.navigationController &&
               self.navigationController.viewControllers.firstObject == self &&
               self.navigationController.presentingViewController == nil &&
               self.navigationController.topViewController == self) {
        // Hide it again when popping back to the root page
        self.navigationController.navigationBarHidden = YES;
    }
}

#pragma mark - Launcher mode: the multiplayer enable switch

/// Handler for the "Enable multiplayer" switch
///
/// Equivalent to the master multiplayer switch at the top of the FCL launcher screen:
///   - on: call ensureNodeStartedWithCompletion: to start the ZeroTier node
///   - off: call disconnectCurrentRoom to stop all multiplayer activity (the node keeps running and can be switched on again)
///
/// Key fix (the switch state going out of sync):
/// setMultiplayerEnabled: persists the user intent to NSUserDefaults on both on and off,
/// so the switch state is restored correctly even after closing and reopening the launcher.
- (void)enableSwitchChanged:(UISwitch *)sender {
    if (sender.on) {
        // Check that the ZeroTier framework is available
        if (![[MultiplayerManager sharedManager] isFrameworkAvailable]) {
            [sender setOn:NO animated:YES];
            [self showSimpleAlertWithTitle:MPLocalized(@"mp.core.unavailable_title", @"Multiplayer core unavailable")
                                    message:MPLocalized(@"mp.core.unavailable_msg", @"The ZeroTier multiplayer core is not loaded, so multiplayer cannot be enabled. Please use a build that includes the real zt.framework.")];
            return;
        }

        // Persist the user's intent to enable multiplayer
        [[MultiplayerManager sharedManager] setMultiplayerEnabled:YES];

        // Start the ZeroTier node
        __weak typeof(self) weakSelf = self;
        [[MultiplayerManager sharedManager] ensureNodeStartedWithCompletion:^(BOOL success, NSError *error) {
            __strong typeof(weakSelf) strongSelf = weakSelf;
            if (!strongSelf) return;

            if (!success) {
                // Key fix (critical 5): keep the user intent when the node fails to start and only revert the UI switch.
                // The switch then still reads ON next time the launcher opens and starting is retried automatically.
                // setMultiplayerEnabled:NO used to be called, forcing the user to re-enable it every time.
                [strongSelf.enableSwitch setOn:NO animated:YES];
                [strongSelf showSimpleAlertWithTitle:MPLocalized(@"mp.node.start_failed_title", @"Failed to start")
                                              message:error.localizedDescription ?: MPLocalized(@"mp.node.start_failed_msg", @"The ZeroTier node failed to start, please try again.")];
            } else {
                // Started successfully: refresh the table to update the detail text on the switch row
                [strongSelf.tableView reloadData];
            }
        }];
    } else {
        // Persist the user's intent to disable multiplayer
        [[MultiplayerManager sharedManager] setMultiplayerEnabled:NO];

        // Disabling multiplayer: disconnect from the current room (if any)
        if ([[MultiplayerManager sharedManager] currentRoom]) {
            [[MultiplayerManager sharedManager] disconnectCurrentRoom];
        }
        [self refreshRooms];
    }
}

#pragma mark - Launcher mode: editing the preset network ID

/// Tapping the network ID row: show a UIAlertController for entering the preset network ID
///
/// Equivalent to FCL: the host sets the network ID once (after creating it at central.zerotier.com),
/// after which it is used automatically every time they host, and the share code carries it.
- (void)networkIdCellTapped {
    [self.view endEditing:YES];

    // Check that the ZeroTier framework is available
    if (![[MultiplayerManager sharedManager] isFrameworkAvailable]) {
        [self showSimpleAlertWithTitle:MPLocalized(@"mp.core.unavailable_title", @"Multiplayer core unavailable")
                                message:MPLocalized(@"mp.core.unavailable_msg", @"The ZeroTier multiplayer core is not loaded, so the network ID cannot be set.")];
        return;
    }

    NSString *current = [[MultiplayerManager sharedManager] presetNetworkId] ?: @"";

    UIAlertController *alert = [UIAlertController alertControllerWithTitle:MPLocalized(@"mp.network_id.title", @"Set network ID")
                                                                   message:MPLocalized(@"mp.network_id.message", @"Create a network at central.zerotier.com, then enter its 16-digit network ID here to use it automatically when hosting")
                                                            preferredStyle:UIAlertControllerStyleAlert];

    [alert addTextFieldWithConfigurationHandler:^(UITextField *textField) {
        textField.text = current;
        textField.placeholder = MPLocalized(@"mp.network_id.placeholder", @"16-digit hexadecimal network ID");
        textField.autocapitalizationType = UITextAutocapitalizationTypeNone;
        textField.autocorrectionType = UITextAutocorrectionTypeNo;
        textField.keyboardType = UIKeyboardTypeASCIICapable;
        textField.clearButtonMode = UITextFieldViewModeWhileEditing;
    }];

    [alert addAction:[UIAlertAction actionWithTitle:MPLocalized(@"common.cancel", @"Cancel")
                                              style:UIAlertActionStyleCancel
                                            handler:nil]];

    // The quick mode button: generate an ad-hoc network ID automatically, with no account needed
    __weak typeof(self) weakSelf = self;
    [alert addAction:[UIAlertAction actionWithTitle:MPLocalized(@"mp.network_id.use_adhoc", @"Use quick mode (no account needed)")
                                              style:UIAlertActionStyleDefault
                                            handler:^(UIAlertAction *action) {
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf) return;

        // Check that the ZeroTier framework is available
        if (![[MultiplayerManager sharedManager] isFrameworkAvailable]) {
            [strongSelf showSimpleAlertWithTitle:MPLocalized(@"mp.core.unavailable_title", @"Multiplayer core unavailable")
                                          message:MPLocalized(@"mp.core.unavailable_msg", @"The ZeroTier multiplayer core is not loaded, so quick mode is unavailable.")];
            return;
        }

        // Generate the ad-hoc network ID
        NSString *adhocNetId = [[MultiplayerManager sharedManager] generateAdhocNetworkId];
        if (!adhocNetId.length) {
            [strongSelf showSimpleAlertWithTitle:MPLocalized(@"mp.network_id.adhoc_failed_title", @"Generation failed")
                                          message:MPLocalized(@"mp.network_id.adhoc_failed_msg", @"Could not generate a quick-mode network ID — please use standard mode instead")];
            return;
        }

        // Save it as the preset network ID
        [[MultiplayerManager sharedManager] setPresetNetworkId:adhocNetId];
        [strongSelf.tableView reloadData];

        // Tell the user
        [strongSelf showSimpleAlertWithTitle:MPLocalized(@"mp.network_id.adhoc_success_title", @"Quick mode enabled")
                                      message:[NSString stringWithFormat:@"%@\n\n%@",
                                               MPLocalized(@"mp.network_id.adhoc_success_msg", @"A network ID was generated automatically, so you can play together without an account. Note that quick mode is less stable than standard mode and the IP may change."),
                                               [NSString stringWithFormat:@"Network ID: %@", adhocNetId]]];
    }]];

    [alert addAction:[UIAlertAction actionWithTitle:MPLocalized(@"common.save", @"Save")
                                              style:UIAlertActionStyleDefault
                                            handler:^(UIAlertAction *action) {
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf) return;

        UITextField *field = alert.textFields.firstObject;
        NSString *value = [field.text stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];

        if (value.length == 0) {
            // An empty string: clear the preset
            [[MultiplayerManager sharedManager] setPresetNetworkId:nil];
            [strongSelf.tableView reloadData];
            return;
        }

        // Validate the format
        if (![[MultiplayerManager sharedManager] isValidNetworkId:value]) {
            [strongSelf showSimpleAlertWithTitle:MPLocalized(@"mp.network_id.invalid_title", @"Invalid format")
                                          message:MPLocalized(@"mp.network_id.invalid_msg", @"The network ID must be a 16-digit hexadecimal string")];
            return;
        }

        [[MultiplayerManager sharedManager] setPresetNetworkId:value];
        [strongSelf.tableView reloadData];
    }]];

    [self presentViewController:alert animated:YES completion:nil];
}

#pragma mark - Launcher mode: the ZeroTier network creation tutorial

/// Show the guide to creating a ZeroTier network
///
/// Equivalent to the FCL "multiplayer help" feature: explains the two multiplayer modes and how to use them.
///
/// The two modes:
///   1. standard mode (stable): register at central.zerotier.com and create a network
///      - pros: a fixed IP, private authorization support, a separate network per person
///      - cons: an account is needed and the setup is more involved
///   2. quick mode (unstable): use an automatically assigned ad-hoc network
///      - pros: no account needed, works immediately
///      - cons: IPv6 only, a public network, and the IP may change
- (void)showZeroTierGuide {
    [self.view endEditing:YES];

    // Build the guide content: a comparison of the two modes
    NSString *modeStandard = [NSString stringWithFormat:@"%@（%@）\n%@",
                              MPLocalized(@"mp.guide.mode_standard", @"Standard mode"),
                              MPLocalized(@"mp.guide.stable", @"Stable"),
                              MPLocalized(@"mp.guide.mode_standard_desc", @"Register at central.zerotier.com and create an organization to get a fixed network ID. The IP is stable, members can be authorized, and everyone gets their own network.")];

    NSString *modeFast = [NSString stringWithFormat:@"%@（%@）\n%@",
                          MPLocalized(@"mp.guide.mode_fast", @"Quick mode"),
                          MPLocalized(@"mp.guide.unstable", @"Unstable"),
                          MPLocalized(@"mp.guide.mode_fast_desc", @"Generates a network ID automatically using an ad-hoc network, with no account needed. However it is IPv6-only, a public network is less secure, and the IP may change.")];

    // The standard mode steps
    NSString *standardTitle = [NSString stringWithFormat:@"\n【%@】", MPLocalized(@"mp.guide.mode_standard", @"Standard mode")];

    NSString *step1 = [NSString stringWithFormat:@"1. %@\n   %@",
                       MPLocalized(@"mp.guide.step1_title", @"Register a ZeroTier account"),
                       MPLocalized(@"mp.guide.step1_desc", @"Go to central.zerotier.com (the new Central), then register and sign in (free; Google/GitHub/Microsoft sign-in supported)")];

    NSString *step2 = [NSString stringWithFormat:@"2. %@\n   %@",
                       MPLocalized(@"mp.guide.step2_title", @"Create an organization"),
                       MPLocalized(@"mp.guide.step2_desc", @"After signing in, enter an organization name and click \"Create Organization\". The free plan includes one network group and one network")];

    NSString *step3 = [NSString stringWithFormat:@"3. %@\n   %@",
                       MPLocalized(@"mp.guide.step3_title", @"Get the network ID"),
                       MPLocalized(@"mp.guide.step3_desc", @"Expand \"Networks\" in the left sidebar, open the default network (for example my-first-network), and copy the 16-digit network ID at the top")];

    NSString *step4 = [NSString stringWithFormat:@"4. %@\n   %@",
                       MPLocalized(@"mp.guide.step4_title", @"Set network access control"),
                       MPLocalized(@"mp.guide.step4_desc", @"Private (recommended): members must be authorized manually, which is safer. Public: anyone can join directly")];

    NSString *step5 = [NSString stringWithFormat:@"5. %@\n   %@",
                       MPLocalized(@"mp.guide.step5_title", @"Enter it in the launcher"),
                       MPLocalized(@"mp.guide.step5_desc", @"Come back to this page, tap the \"Preset network ID\" row, then paste and save")];

    NSString *step6 = [NSString stringWithFormat:@"6. %@\n   %@",
                       MPLocalized(@"mp.guide.step6_title", @"Authorize guest devices"),
                       MPLocalized(@"mp.guide.step6_desc", @"Once a guest joins, open the \"Member Devices\" tab, tap the three-dot menu and choose \"Authorize\" (required in Private mode, not needed in Public mode)")];

    NSString *step7 = [NSString stringWithFormat:@"7. %@\n   %@",
                       MPLocalized(@"mp.guide.step7_title", @"Start playing together"),
                       MPLocalized(@"mp.guide.step7_desc", @"After launching the game, open the multiplayer screen from the floating button and choose \"Host\" to open a room")];

    // The quick mode steps
    NSString *fastTitle = [NSString stringWithFormat:@"\n【%@】", MPLocalized(@"mp.guide.mode_fast", @"Quick mode")];

    NSString *fastStep1 = [NSString stringWithFormat:@"1. %@\n   %@",
                           MPLocalized(@"mp.guide.fast_step1_title", @"Tap \"Preset network ID\""),
                           MPLocalized(@"mp.guide.fast_step1_desc", @"Tap the \"Preset network ID\" row on this page")];

    NSString *fastStep2 = [NSString stringWithFormat:@"2. %@\n   %@",
                           MPLocalized(@"mp.guide.fast_step2_title", @"Choose quick mode"),
                           MPLocalized(@"mp.guide.fast_step2_desc", @"Tap \"Use quick mode (no account needed)\" and a network ID is generated for you")];

    NSString *fastStep3 = [NSString stringWithFormat:@"3. %@\n   %@",
                           MPLocalized(@"mp.guide.fast_step3_title", @"Start playing together"),
                           MPLocalized(@"mp.guide.fast_step3_desc", @"After launching the game, open the multiplayer screen from the floating button and choose \"Host\" to open a room")];

    NSString *message = [NSString stringWithFormat:@"%@\n\n%@\n\n%@\n\n%@%@",
                         MPLocalized(@"mp.guide.intro", @"ZeroTier offers two multiplayer modes — pick the one that suits you:"),
                         modeStandard,
                         modeFast,
                         standardTitle, step1];

    // Join every step into a multi-line string (7 standard mode steps + 3 quick mode steps)
    message = [NSString stringWithFormat:@"%@\n\n%@\n\n%@\n\n%@\n\n%@\n\n%@\n\n%@\n\n%@\n\n%@",
               message,
               step2,
               step3,
               step4,
               step5,
               step6,
               step7,
               fastTitle,
               [NSString stringWithFormat:@"%@\n%@\n%@", fastStep1, fastStep2, fastStep3]];

    // Add the notes
    message = [NSString stringWithFormat:@"%@\n\n%@",
               message,
               MPLocalized(@"mp.guide.note", @"Note: the host and guests must use the same network ID. In standard mode you either authorize members in the dashboard (Private) or set the network to Public. In quick mode everyone shares one public network.")];

    UIAlertController *alert = [UIAlertController alertControllerWithTitle:MPLocalized(@"mp.guide.title", @"ZeroTier multiplayer guide")
                                                                   message:message
                                                            preferredStyle:UIAlertControllerStyleAlert];

    // The "Open central.zerotier.com" button: go straight to the browser (needed for standard mode)
    // The new Central: central.zerotier.com (recommended for new users)
    // The old Central: my.zerotier.com (for existing users)
    [alert addAction:[UIAlertAction actionWithTitle:MPLocalized(@"mp.guide.open_website", @"Open central.zerotier.com (standard mode)")
                                              style:UIAlertActionStyleDefault
                                            handler:^(UIAlertAction *action) {
        NSURL *url = [NSURL URLWithString:@"https://central.zerotier.com/"];
        if (url && [[UIApplication sharedApplication] canOpenURL:url]) {
            [[UIApplication sharedApplication] openURL:url options:@{} completionHandler:nil];
        }
    }]];

    // The "Use quick mode" button: generate an ad-hoc network ID straight away
    __weak typeof(self) weakSelf = self;
    [alert addAction:[UIAlertAction actionWithTitle:MPLocalized(@"mp.guide.use_fast_mode", @"Use quick mode")
                                              style:UIAlertActionStyleDefault
                                            handler:^(UIAlertAction *action) {
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf) return;

        // Check that the ZeroTier framework is available
        if (![[MultiplayerManager sharedManager] isFrameworkAvailable]) {
            [strongSelf showSimpleAlertWithTitle:MPLocalized(@"mp.core.unavailable_title", @"Multiplayer core unavailable")
                                          message:MPLocalized(@"mp.core.unavailable_msg", @"The ZeroTier multiplayer core is not loaded, so quick mode is unavailable.")];
            return;
        }

        // Generate the ad-hoc network ID
        NSString *adhocNetId = [[MultiplayerManager sharedManager] generateAdhocNetworkId];
        if (!adhocNetId.length) {
            [strongSelf showSimpleAlertWithTitle:MPLocalized(@"mp.network_id.adhoc_failed_title", @"Generation failed")
                                          message:MPLocalized(@"mp.network_id.adhoc_failed_msg", @"Could not generate a quick-mode network ID — please use standard mode instead")];
            return;
        }

        // Save it as the preset network ID
        [[MultiplayerManager sharedManager] setPresetNetworkId:adhocNetId];
        [strongSelf.tableView reloadData];

        // Tell the user
        [strongSelf showSimpleAlertWithTitle:MPLocalized(@"mp.network_id.adhoc_success_title", @"Quick mode enabled")
                                      message:[NSString stringWithFormat:@"%@\n\n%@",
                                               MPLocalized(@"mp.network_id.adhoc_success_msg", @"A network ID was generated automatically, so you can play together without an account. Note that quick mode is less stable than standard mode and the IP may change."),
                                               [NSString stringWithFormat:@"Network ID: %@", adhocNetId]]];
    }]];

    // The "Got it" button
    [alert addAction:[UIAlertAction actionWithTitle:MPLocalized(@"common.ok", @"Got it")
                                              style:UIAlertActionStyleCancel
                                            handler:nil]];

    [self presentViewController:alert animated:YES completion:nil];
}

#pragma mark - Room connection

/// Connect to the given room
///
/// Calls connectToRoom:completion: on MultiplayerManager internally
/// and updates the room state and the UI on the main thread. completion fires once connected.
- (void)connectToRoom:(MultiplayerRoom *)room completion:(void (^)(BOOL success, NSError *error))completion {
    // Key fix (do not set status twice):
    // Manager.connectToRoom: already sets room.status = Connecting inside _stateLock,
    // so it is not set again here — the manager owns the state and the VC only reads it.
    // The UI is simply refreshed to show the state the manager already set.
    [self refreshRooms];

    __weak typeof(self) weakSelf = self;
    [[MultiplayerManager sharedManager] connectToRoom:room completion:^(BOOL success, NSError *error) {
        dispatch_async(dispatch_get_main_queue(), ^{
            __strong typeof(weakSelf) strongSelf = weakSelf;
            if (!strongSelf) return;

            // The connection result state has already been updated by the manager (status = Connected/Error),
            // so only the UI and persistence are handled here (keeping the existing lastConnectedAt bookkeeping).
            if (success) {
                room.lastConnectedAt = [NSDate date];
            }
            [[MultiplayerManager sharedManager] updateRoom:room];
            [strongSelf refreshRooms];

            if (completion) {
                completion(success, error);
            }
        });
    }];
}

/// Disconnect from the current room
- (void)disconnectRoom:(MultiplayerRoom *)room {
    [[MultiplayerManager sharedManager] disconnectCurrentRoom];
    room.status = MultiplayerRoomStatusDisconnected;
    [[MultiplayerManager sharedManager] updateRoom:room];
    [self refreshRooms];
}

#pragma mark - Room row button callbacks

/// Handler for the "Connect/Disconnect" button on a room row
///
/// The room index comes from button.tag
- (void)roomButtonTapped:(UIButton *)button {
    NSInteger row = button.tag;
    if (row < 0 || row >= (NSInteger)self.rooms.count) {
        return;
    }

    MultiplayerRoom *room = self.rooms[row];

    // Prevent repeated taps while connecting
    if (room.status == MultiplayerRoomStatusConnecting) {
        return;
    }

    if (room.status == MultiplayerRoomStatusConnected) {
        // Already connected, so disconnect
        [self disconnectRoom:room];
    } else {
        // Not connected, so connect
        [self connectToRoom:room completion:^(BOOL success, NSError *error) {
            if (!success) {
                [self showSimpleAlertWithTitle:MPLocalized(@"mp.connect.failed", @"Connection failed")
                                        message:error.localizedDescription ?: MPLocalized(@"mp.connect.failed_msg", @"Could not connect to the room. Check that the network ID is correct and that your connection is working.")];
            }
        }];
    }
}

#pragma mark - Room detail action sheet

/// Show the room detail action sheet
///
/// It offers:
///   - Connect / Disconnect (depending on the current state)
///   - Share room (generating the share text and opening the system share sheet)
///   - Delete room (after a confirmation)
- (void)showRoomActionsForRoom:(MultiplayerRoom *)room {
    [self.view endEditing:YES];

    NSString *title = room.name.length ? room.name : MPLocalized(@"mp.room.unnamed", @"Untitled room");
    NSString *message = [NSString stringWithFormat:@"%@: %@",
                         MPLocalized(@"mp.room.network_id", @"Network ID"),
                         room.networkId ?: @"-"];

    UIAlertController *sheet = [UIAlertController alertControllerWithTitle:title
                                                                   message:message
                                                            preferredStyle:UIAlertControllerStyleActionSheet];

    // The connect/disconnect button (whose title follows the current state)
    NSString *connectTitle = (room.status == MultiplayerRoomStatusConnected)
        ? MPLocalized(@"mp.room.action.disconnect", @"Disconnect")
        : MPLocalized(@"mp.room.action.connect", @"Connect to room");

    __weak typeof(self) weakSelf = self;
    [sheet addAction:[UIAlertAction actionWithTitle:connectTitle style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf) return;

        if (room.status == MultiplayerRoomStatusConnected) {
            [strongSelf disconnectRoom:room];
        } else {
            [strongSelf connectToRoom:room completion:^(BOOL success, NSError *error) {
                if (!success) {
                    [strongSelf showSimpleAlertWithTitle:MPLocalized(@"mp.connect.failed", @"Connection failed")
                                                  message:error.localizedDescription ?: MPLocalized(@"mp.connect.failed_msg", @"Could not connect to the room. Check that the network ID is correct and that your connection is working.")];
                }
            }];
        }
    }]];

    // The share room button (using shareTextForRoom: to build readable share text)
    [sheet addAction:[UIAlertAction actionWithTitle:MPLocalized(@"mp.room.action.share", @"Share room")
                                              style:UIAlertActionStyleDefault
                                            handler:^(UIAlertAction *action) {
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf) return;

        NSString *shareText = [[MultiplayerManager sharedManager] shareTextForRoom:room];
        UIActivityViewController *activityVC = [[UIActivityViewController alloc] initWithActivityItems:@[shareText] applicationActivities:nil];

        // iPad support: point the popover at the center of the screen
        if (activityVC.popoverPresentationController) {
            activityVC.popoverPresentationController.sourceView = strongSelf.view;
            activityVC.popoverPresentationController.sourceRect = CGRectMake(strongSelf.view.bounds.size.width / 2.0,
                                                                              strongSelf.view.bounds.size.height / 2.0,
                                                                              1, 1);
        }
        [strongSelf presentViewController:activityVC animated:YES completion:nil];
    }]];

    // The delete room button (destructive, in red)
    [sheet addAction:[UIAlertAction actionWithTitle:MPLocalized(@"mp.room.action.delete", @"Delete room")
                                              style:UIAlertActionStyleDestructive
                                            handler:^(UIAlertAction *action) {
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf) return;

        // A confirmation dialog
        UIAlertController *confirm = [UIAlertController alertControllerWithTitle:MPLocalized(@"mp.room.delete.confirm_title", @"Confirm delete")
                                                                         message:[NSString stringWithFormat:@"%@「%@」？\n%@",
                                                                                  MPLocalized(@"mp.room.delete.confirm_prefix", @"Delete the room"),
                                                                                  room.name,
                                                                                  MPLocalized(@"mp.room.delete.confirm_warning", @"This cannot be undone.")]
                                                                  preferredStyle:UIAlertControllerStyleAlert];
        [confirm addAction:[UIAlertAction actionWithTitle:MPLocalized(@"common.cancel", @"Cancel") style:UIAlertActionStyleCancel handler:nil]];
        [confirm addAction:[UIAlertAction actionWithTitle:MPLocalized(@"mp.room.delete.button", @"Delete") style:UIAlertActionStyleDestructive handler:^(UIAlertAction *action) {
            __strong typeof(weakSelf) strongSelf = weakSelf;
            if (!strongSelf) return;

            // If that room is connected, disconnect first
            if (room.status == MultiplayerRoomStatusConnected) {
                [[MultiplayerManager sharedManager] disconnectCurrentRoom];
            }
            [[MultiplayerManager sharedManager] removeRoom:room.roomId];
            [strongSelf refreshRooms];
        }]];
        [strongSelf presentViewController:confirm animated:YES completion:nil];
    }]];

    // Cancel button
    [sheet addAction:[UIAlertAction actionWithTitle:MPLocalized(@"common.cancel", @"Cancel") style:UIAlertActionStyleCancel handler:nil]];

    // iPad support: point the popover at the center of the screen
    if (sheet.popoverPresentationController) {
        sheet.popoverPresentationController.sourceView = self.view;
        sheet.popoverPresentationController.sourceRect = CGRectMake(self.view.bounds.size.width / 2.0,
                                                                    self.view.bounds.size.height / 2.0,
                                                                    1, 1);
    }

    [self presentViewController:sheet animated:YES completion:nil];
}

#pragma mark - Launcher mode: direct connect

/// Tapping "Join game": write the IP:port into the current profile so the game joins automatically at launch
- (void)joinDirectConnect {
    [self.view endEditing:YES];

    NSString *ip = [self.directIPField.text stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    NSString *port = [self.directPortField.text stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];

    // Check: the IP is not empty
    if (ip.length == 0) {
        [self showSimpleAlertWithTitle:MPLocalized(@"mp.direct.error_title", @"Notice")
                                message:MPLocalized(@"mp.direct.error.ip_empty", @"Please enter the server IP address")];
        return;
    }

    // The default port
    if (port.length == 0) {
        port = @"25565";
    }

    // Check: the IP format
    if (![[MultiplayerManager sharedManager] isValidIPAddress:ip]) {
        [self showSimpleAlertWithTitle:MPLocalized(@"mp.direct.error_title", @"Notice")
                                message:MPLocalized(@"mp.direct.error.ip_invalid", @"The IP address format is invalid, please check your input")];
        return;
    }

    // Join them into the server address "IP:port"
    NSString *serverAddress = [NSString stringWithFormat:@"%@:%@", ip, port];

    // Write the server address into the current profile
    NSString *profileName = [PLProfiles current].selectedProfileName;
    if (!profileName || profileName.length == 0) {
        [self showSimpleAlertWithTitle:MPLocalized(@"mp.direct.error_title", @"Notice")
                                message:MPLocalized(@"mp.direct.error.no_profile", @"No current profile found — please select a game profile first")];
        return;
    }
    [[PLProfiles current] setServerIp:serverAddress forProfile:profileName];

    // Show the success message
    [self showSimpleAlertWithTitle:MPLocalized(@"mp.direct.success_title", @"Server added")
                           message:[NSString stringWithFormat:@"%@ %@",
                                    MPLocalized(@"mp.direct.success_msg_prefix", @"Server added"),
                                    serverAddress]];
}

#pragma mark - In-game mode: the host flow

/// Tapping "Host": start the host flow
///
/// Matching the FCL host flow:
///   1. check that the ZeroTier framework is available
///   2. check that a preset network ID is set (telling the user to set one in the launcher if not)
///   3. connect automatically to the room for the preset network ID
///   4. show the manual port input dialog once connected (showManualPortInputAlert)
///   5. the user opens the world to LAN in Minecraft and enters the port from the chat box
///   6. generate the share code (generateShareCodeForRoom:)
///   7. show the share code (which can be copied and shared)
///
/// Key change (port detection replaced by manual entry):
/// Steps 4-5 used to be "observe LanPortDetectorDidDetectPortNotification and
/// detect the LAN port automatically", which had these problems:
///   - latestlog.txt could contain the LAN port from a previous session and be mistaken for the current one
///   - log formats vary widely between Minecraft versions, so automatic detection was unreliable
///   - a share code could be generated before the game had really been opened to LAN
/// The port is now entered by hand, so it is always the real LAN port of the current session.
- (void)hostButtonTapped {
    [self.view endEditing:YES];

    // Check 1: the ZeroTier framework is available
    if (![[MultiplayerManager sharedManager] isFrameworkAvailable]) {
        [self showSimpleAlertWithTitle:MPLocalized(@"mp.core.unavailable_title", @"Multiplayer core unavailable")
                                message:MPLocalized(@"mp.core.unavailable_msg", @"The ZeroTier multiplayer core is not loaded, so you cannot host a room. Please use a build that includes the real zt.framework.")];
        return;
    }

    // Check 2: a preset network ID is set
    NSString *presetNetId = [[MultiplayerManager sharedManager] presetNetworkId];
    if (!presetNetId.length) {
        // Not set: tell the user to set one in the launcher
        UIAlertController *alert = [UIAlertController alertControllerWithTitle:MPLocalized(@"mp.host.no_network_id_title", @"No network ID set")
                                                                       message:MPLocalized(@"mp.host.no_network_id_msg", @"The host must set a preset ZeroTier network ID first. Set one on the launcher's multiplayer screen and come back.")
                                                                preferredStyle:UIAlertControllerStyleAlert];
        [alert addAction:[UIAlertAction actionWithTitle:MPLocalized(@"common.ok", @"OK") style:UIAlertActionStyleDefault handler:nil]];
        [self presentViewController:alert animated:YES completion:nil];
        return;
    }

    // Validate the network ID format
    if (![[MultiplayerManager sharedManager] isValidNetworkId:presetNetId]) {
        [self showSimpleAlertWithTitle:MPLocalized(@"mp.network_id.invalid_title", @"Invalid network ID format")
                                message:MPLocalized(@"mp.network_id.invalid_msg", @"Set a valid 16-digit hexadecimal network ID on the launcher's multiplayer screen")];
        return;
    }

    // ============================================================
    // Idempotency: short-circuit when the host flow is already active
    // ============================================================
    // Key fix: tapping "Host" again used to run the whole connection flow from scratch,
    // and even with a successful connection and a detected LAN port it would:
    //   1. clear lastShareCode/lastServerAddress (losing the share code already generated)
    //   2. show the "Starting multiplayer" progress message again
    //   3. call connectToRoom again (resetting status to Connecting)
    //   4. show "waiting to detect the LAN port..." again once connected (which is misleading)
    //   5. and because LanPortDetector deduplicates the same port, lanPortDidDetect: never fired again,
    //      so the user could not get back to the share code
    //
    // The fix: when the host flow is already active and the room is connected, show the matching message
    // depending on whether a share code exists, without running the connection flow again.
    if (self.isHostFlowActive) {
        MultiplayerRoom *currentRoom = [[MultiplayerManager sharedManager] currentRoom];
        if (currentRoom && [currentRoom.networkId isEqualToString:presetNetId]) {
            // The room is connected
            if (self.lastShareCode.length) {
                // A share code already exists
                //
                // Key fix (multi-guest improvement): detect a change in the host IP
                // If the host IP changed after a ZeroTier reconnect, the hostIP in the old share code is stale
                // and guests cannot join with it, so the share code has to be regenerated from the current IP.
                // The LAN port itself is unaffected by a ZeroTier IP change (it is bound to Minecraft Netty), so it can be reused.
                NSString *currentLocalIP = [[MultiplayerManager sharedManager] currentLocalIP];
                if (currentLocalIP.length > 0 &&
                    currentRoom.hostIP.length > 0 &&
                    ![currentRoom.hostIP isEqualToString:currentLocalIP]) {
                    NSLog(@"[MultiplayerVC] Host flow active but IP changed: %@ -> %@, regenerating share code with existing port",
                          currentRoom.hostIP, currentLocalIP);
                    [self generateShareCodeWithPort:currentRoom.hostPort];
                } else {
                    // The IP has not changed: show the share code directly
                    NSLog(@"[MultiplayerVC] Host flow active and share code exists, displaying directly");
                    [self showHostShareCodeAlert];
                }
            } else {
                // No share code yet: show the manual port input dialog
                // Key fix (port detection replaced by manual entry): the port is no longer detected automatically but entered by the user
                NSLog(@"[MultiplayerVC] Host flow active but share code not yet generated, showing manual port input dialog");
                [self showManualPortInputAlert];
            }
            return;
        }
        // The room is not connected, or the networkId does not match: run the full flow (disconnecting the old connection first)
    }

    // Mark the host flow as active
    self.isHostFlowActive = YES;
    self.lastShareCode = nil;
    self.lastServerAddress = nil;

    // Build or reuse the host room object
    MultiplayerRoom *room = self.hostRoom;
    if (!room || ![room.networkId isEqualToString:presetNetId]) {
        room = [[MultiplayerRoom alloc] init];
        room.roomId = [[MultiplayerManager sharedManager] generateRoomId];
        room.name = MPLocalized(@"mp.host.default_room_name", @"My multiplayer room");
        room.networkId = presetNetId;
        room.hostIP = @"";
        room.hostPort = @"25565";
        room.roomDescription = @"";
        room.ownerName = @"";
        room.status = MultiplayerRoomStatusDisconnected;
        // Key fix: mark the host role explicitly, replacing the IP heuristic
        room.role = MultiplayerRoomRoleHost;
        room.createdAt = [NSDate date];
        self.hostRoom = room;
    } else {
        // Make sure role is right on an existing room too (handling old data with role=Unknown)
        room.role = MultiplayerRoomRoleHost;
    }

    // If another room is connected, disconnect first
    MultiplayerRoom *currentRoom = [[MultiplayerManager sharedManager] currentRoom];
    if (currentRoom && ![currentRoom.networkId isEqualToString:presetNetId]) {
        [[MultiplayerManager sharedManager] disconnectCurrentRoom];
    }

    // Show the "connecting" progress message (whose text updates live)
    //
    // Key fix (no feedback in the foreground):
    // a single static "Connecting to the ZeroTier network, please wait..." message used to be shown,
    // leaving the user with no idea of the progress through a 15-30 second connection.
    // showConnectionProgressWithTitle:message: now shows an alert with a Cancel button,
    // and the multiplayerConnectionProgress: callback updates its message live with "Step 1/6: ..." and so on.
    [self showConnectionProgressWithTitle:MPLocalized(@"mp.host.connecting_title", @"Starting multiplayer")
                                   message:MPLocalized(@"mp.host.connecting_msg", @"Connecting to the ZeroTier network, please wait...")];

    // Key fix (port detection replaced by manual entry):
    // The automatic LanPortDetector detection is no longer started. It had these problems:
    //   - latestlog.txt could contain the LAN port from a previous session and be mistaken for the current one
    //   - log formats vary widely between Minecraft versions, so automatic detection was unreliable
    //   - a share code could be generated before the game had really been opened to LAN
    // The port is now entered by hand: an input dialog appears once connected, and only after the user opens the world to LAN
    // and enters the port from the chat box is a share code generated.

    // Connect to the preset room
    __weak typeof(self) weakSelf = self;
    [self connectToRoom:room completion:^(BOOL success, NSError *error) {
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf) return;

        // Dismiss the progress alert first, then show the result
        [strongSelf dismissConnectionProgressAlertWithCompletion:^{
            if (success) {
                // Connected successfully
                //
                // Key fix (port detection replaced by manual entry):
                // It used to rely on LanPortDetector finding the LAN port automatically (by intercepting the Minecraft log or reading latestlog.txt),
                // which had these problems:
                //   1. unreliable detection: log formats vary widely between Minecraft versions and some never match
                //   2. stale logs: latestlog.txt could contain the LAN port from a previous session,
                //      so a wrong share code was generated before Minecraft had really been opened to LAN
                //   3. a code could be generated before the game had even started, because LanPortDetector read the port
                //      from an old log and immediately triggered share code generation
                //
                // The fix: enter the port by hand. Once connected, an input dialog appears, and only after the user opens the world
                // to LAN in Minecraft and enters the port from the chat box is a share code generated.
                // That keeps the port accurate and stops a wrong code being generated before the world is
                // really open to LAN.
                NSLog(@"[MultiplayerVC] Connection successful, waiting for user to manually enter LAN port");
                [strongSelf showManualPortInputAlert];
            } else {
                // Connection failed
                strongSelf.isHostFlowActive = NO;
                [strongSelf showSimpleAlertWithTitle:MPLocalized(@"mp.connect.failed", @"Connection failed")
                                              message:error.localizedDescription ?: MPLocalized(@"mp.connect.failed_msg", @"Could not connect to the ZeroTier network. Check that the network ID is correct and that your connection is working.")];
            }
        }];
        [strongSelf.tableView reloadData];
    }];

    [self.tableView reloadData];
}

/// Show the manual port input dialog after the host connects
///
/// Key fix (port detection replaced by manual entry):
/// LanPortDetector used to find the LAN port automatically once connected, which had these problems:
///   - latestlog.txt could contain the LAN port from a previous session and be mistaken for the current one
///   - log formats vary widely between Minecraft versions, so automatic detection was unreliable
///   - a share code could be generated before the game had really been opened to LAN
///
/// The port is now entered by hand: once connected, an input dialog appears asking the user to open the world
/// to LAN in Minecraft and enter the port from the chat box. Only after they enter it
/// is a share code generated. That keeps the port accurate and stops a wrong code being generated
/// before the world is really open to LAN.
- (void)showManualPortInputAlert {
    NSString *localIP = [[MultiplayerManager sharedManager] currentLocalIP] ?: @"-";
    NSString *message = [NSString stringWithFormat:@"%@\n\n%@\n%@\n\n%@: %@",
                         MPLocalized(@"mp.host.connected_msg", @"Connected to the multiplayer network. Open your world to LAN in Minecraft, then enter the port number"),
                         MPLocalized(@"mp.host.tip.create_world", @"In Minecraft, create a world and tap \"Open to LAN\""),
                         MPLocalized(@"mp.host.tip.manual_port", @"After opening to LAN, Minecraft shows the port number in the chat box — enter it below"),
                         MPLocalized(@"mp.host.local_ip", @"This device's IP"),
                         localIP];

    UIAlertController *alert = [UIAlertController alertControllerWithTitle:MPLocalized(@"mp.host.connected_title", @"Multiplayer started")
                                                                   message:message
                                                            preferredStyle:UIAlertControllerStyleAlert];

    [alert addTextFieldWithConfigurationHandler:^(UITextField *textField) {
        textField.placeholder = MPLocalized(@"mp.host.port_placeholder", @"Port number (e.g. 54321)");
        textField.keyboardType = UIKeyboardTypeNumberPad;
        textField.autocapitalizationType = UITextAutocapitalizationTypeNone;
        textField.autocorrectionType = UITextAutocorrectionTypeNo;
        textField.clearButtonMode = UITextFieldViewModeWhileEditing;
    }];

    [alert addAction:[UIAlertAction actionWithTitle:MPLocalized(@"common.cancel", @"Cancel")
                                              style:UIAlertActionStyleCancel
                                            handler:nil]];

    __weak typeof(self) weakSelf = self;
    [alert addAction:[UIAlertAction actionWithTitle:MPLocalized(@"mp.host.generate_code", @"Generate share code")
                                              style:UIAlertActionStyleDefault
                                            handler:^(UIAlertAction *action) {
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf) return;

        UITextField *field = alert.textFields.firstObject;
        NSString *port = [field.text stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];

        // Check: the port is not empty
        if (port.length == 0) {
            [strongSelf showSimpleAlertWithTitle:MPLocalized(@"mp.host.port_empty_title", @"Port is empty")
                                          message:MPLocalized(@"mp.host.port_empty_msg", @"Please enter the LAN port number")];
            return;
        }

        // Check: the port range (1-65535)
        NSInteger portNum = [port integerValue];
        if (portNum < 1 || portNum > 65535) {
            [strongSelf showSimpleAlertWithTitle:MPLocalized(@"mp.host.port_invalid_title", @"Invalid port")
                                          message:MPLocalized(@"mp.host.port_invalid_msg", @"The port number must be between 1 and 65535")];
            return;
        }

        NSLog(@"[MultiplayerVC] User manually entered LAN port: %@", port);
        // Set the port on LanPortDetector (manual entry), so other modules can read it
        // Note: the LanPortDetector API is sharedInstance + setManualPort:(uint16_t)
        [[LanPortDetector sharedInstance] setManualPort:(uint16_t)portNum];
        // Generate the share code (which starts PortForwarder in host mode internally)
        [strongSelf generateShareCodeWithPort:port];
    }]];

    [self presentViewController:alert animated:YES completion:nil];
}

#pragma mark - In-game mode: the LAN port detection callback

/// Callback for LanPortDetector detecting a port
///
/// Note: automatic detection is disabled (the port is entered by hand), so this normally never fires.
/// It is kept for compatibility: if automatic detection is ever re-enabled, or external code calls it after
/// setting the port with setManualPort:, a share code is still generated correctly.
///
/// The core of the host flow: once Minecraft opens the world to LAN, LanPortDetector finds the port
/// and fires this callback, which:
///   1. writes the detected port into the host room object
///   2. generates the share code (generateShareCodeForRoom:)
///   3. refreshes the UI to show the share code
- (void)lanPortDidDetect:(NSNotification *)notification {
    // Only handled while the host flow is active
    if (!self.isHostFlowActive) {
        return;
    }

    // The port in the userInfo posted by LanPortDetector.setManualPort: is an NSNumber (@(port)),
    // not an NSString, so it is converted to an NSString here.
    id portValue = notification.userInfo[@"port"];
    NSString *port = nil;
    if ([portValue isKindOfClass:[NSString class]]) {
        port = portValue;
    } else if ([portValue isKindOfClass:[NSNumber class]]) {
        port = [(NSNumber *)portValue stringValue];
    }
    if (!port.length) {
        return;
    }

    // Key fix (avoid generating the share code twice):
    // in the manual entry flow, showManualPortInputAlert already calls generateShareCodeWithPort:
    // directly when the user taps "Generate".
    // LanPortDetector.setManualPort: then posts a notification that fires this callback too,
    // so the share code was generated twice (PortForwarder starting is idempotent, but the display flickered).
    // This callback therefore only logs and no longer calls generateShareCodeWithPort: again.
    NSLog(@"[MultiplayerVC] lanPortDidDetect: received port %@ notification (manual input flow already generated share code, skipping duplicate)", port);
}

/// Generate and show the share code from the LAN port the user entered
///
/// This method is reused in the following cases:
///   1. from lanPortDidDetect: when a LanPortDetector notification arrives (kept for compatibility, normally never fired)
///   2. from showManualPortInputAlert once the user enters a port by hand (the main case)
///   3. from the hostButtonTapped idempotency check (indirectly, through showManualPortInputAlert)
///
/// Key change (port detection replaced by manual entry):
/// It used to be triggered by automatic port detection after hostButtonTapped connected,
/// and is now triggered once the user enters the port, so it is always the real LAN port of the current session.
- (void)generateShareCodeWithPort:(NSString *)port {
    MultiplayerRoom *room = self.hostRoom;
    if (!room) {
        return;
    }

    // Update the room port and this device IP
    room.hostPort = port;
    NSString *localIP = [[MultiplayerManager sharedManager] currentLocalIP];

    // Key fix (multi-guest improvement): guard against an empty hostIP
    // If currentLocalIP is empty (an unusual case), do not generate an invalid share code
    if (!localIP.length) {
        NSLog(@"[MultiplayerVC] Warning: currentLocalIP is nil, cannot generate valid share code");
        [self showSimpleAlertWithTitle:MPLocalized(@"mp.host.share_code_failed", @"Failed to generate the share code")
                                  message:MPLocalized(@"mp.host.no_local_ip", @"Could not read this device's ZeroTier IP. Check your network connection and try again")];
        return;
    }

    // Key fix (multi-guest improvement): detect a change in the host IP
    // If room.hostIP is already set and differs from the current localIP, the host ZeroTier IP has changed,
    // the old share code is stale, and the host has to be told to share again
    BOOL ipChanged = (room.hostIP.length > 0 && ![room.hostIP isEqualToString:localIP]);
    if (ipChanged) {
        NSLog(@"[MultiplayerVC] Host IP changed: %@ -> %@, old share code is invalid", room.hostIP, localIP);
    }

    room.hostIP = localIP;
    [[MultiplayerManager sharedManager] updateRoom:room];

    // Generate the share code
    self.lastShareCode = [[MultiplayerManager sharedManager] generateShareCodeForRoom:room];
    // Key fix (P1-4): an IPv6 address must be wrapped in square brackets, or its colons are confused with the port separator
    if ([room.hostIP containsString:@":"]) {
        self.lastServerAddress = [NSString stringWithFormat:@"[%@]:%@", room.hostIP, room.hostPort];
    } else {
        self.lastServerAddress = [NSString stringWithFormat:@"%@:%@", room.hostIP, room.hostPort];
    }

    // Refresh the table so section 1 shows the latest share code
    [self.tableView reloadData];

    // Tell the user the share code has been generated
    [self showHostShareCodeAlert];

    // If the IP changed, also tell the host that the old code is stale
    if (ipChanged) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [self showSimpleAlertWithTitle:MPLocalized(@"mp.host.ip_changed_title", @"The host's IP has changed")
                                      message:MPLocalized(@"mp.host.ip_changed_msg", @"Your ZeroTier IP has changed, so the code you shared earlier no longer works. Send your guests the new share code.")];
        });
    }
}

/// Show the host share code alert
///
/// It offers:
///   - copy the share code to the clipboard
///   - share it through the system share sheet
- (void)showHostShareCodeAlert {
    NSString *shareCode = self.lastShareCode ?: @"";
    NSString *serverAddr = self.lastServerAddress ?: @"-";

    NSString *message = [NSString stringWithFormat:@"%@\n\n%@\n\n%@\n%@\n\n%@",
                         MPLocalized(@"mp.host.share_code_ready", @"Share code generated! Send the code below to your guests:"),
                         shareCode,
                         MPLocalized(@"mp.host.tip.wait_guest", @"Guests join your multiplayer network by entering this code"),
                         [NSString stringWithFormat:@"%@: %@", MPLocalized(@"mp.host.server_address", @"Server address"), serverAddr],
                         MPLocalized(@"mp.host.tip.copy_or_share", @"Use the buttons below to copy or share the code")];

    UIAlertController *alert = [UIAlertController alertControllerWithTitle:MPLocalized(@"mp.host.share_code_title", @"Share code generated")
                                                                   message:message
                                                            preferredStyle:UIAlertControllerStyleAlert];

    // Copy button
    [alert addAction:[UIAlertAction actionWithTitle:MPLocalized(@"mp.host.copy_code", @"Copy code")
                                              style:UIAlertActionStyleDefault
                                            handler:^(UIAlertAction *action) {
        UIPasteboard *pasteboard = [UIPasteboard generalPasteboard];
        pasteboard.string = shareCode;
    }]];

    // Share button
    __weak typeof(self) weakSelf = self;
    [alert addAction:[UIAlertAction actionWithTitle:MPLocalized(@"mp.host.share_button", @"Share...")
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

    // Close button
    [alert addAction:[UIAlertAction actionWithTitle:MPLocalized(@"common.ok", @"OK")
                                              style:UIAlertActionStyleCancel
                                            handler:nil]];

    [self presentViewController:alert animated:YES completion:nil];
}

#pragma mark - In-game mode: the guest flow

/// Tapping "Guest": start the guest flow
///
/// Matching the FCL guest flow:
///   1. show an input dialog (a UIAlertController with a text field)
///   2. the user enters the share code
///   3. parse the code (parseShareCode:)
///   4. connect to the room (connectToRoom:completion:)
///   5. confirm on success and show the server address
- (void)guestButtonTapped {
    [self.view endEditing:YES];

    // Check that the ZeroTier framework is available
    if (![[MultiplayerManager sharedManager] isFrameworkAvailable]) {
        [self showSimpleAlertWithTitle:MPLocalized(@"mp.core.unavailable_title", @"Multiplayer core unavailable")
                                message:MPLocalized(@"mp.core.unavailable_msg", @"The ZeroTier multiplayer core is not loaded, so you cannot join as a guest. Please use a build that includes the real zt.framework.")];
        return;
    }

    UIAlertController *alert = [UIAlertController alertControllerWithTitle:MPLocalized(@"mp.guest.input_title", @"Enter share code")
                                                                   message:MPLocalized(@"mp.guest.input_msg", @"Enter the share code the host gave you")
                                                            preferredStyle:UIAlertControllerStyleAlert];

    [alert addTextFieldWithConfigurationHandler:^(UITextField *textField) {
        textField.placeholder = MPLocalized(@"mp.guest.code_placeholder", @"Paste the share code here");
        textField.autocapitalizationType = UITextAutocapitalizationTypeNone;
        textField.autocorrectionType = UITextAutocorrectionTypeNo;
        textField.keyboardType = UIKeyboardTypeASCIICapable;
        textField.clearButtonMode = UITextFieldViewModeWhileEditing;
    }];

    [alert addAction:[UIAlertAction actionWithTitle:MPLocalized(@"common.cancel", @"Cancel")
                                              style:UIAlertActionStyleCancel
                                            handler:nil]];

    __weak typeof(self) weakSelf = self;
    [alert addAction:[UIAlertAction actionWithTitle:MPLocalized(@"mp.guest.join_button", @"Join")
                                              style:UIAlertActionStyleDefault
                                            handler:^(UIAlertAction *action) {
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf) return;

        UITextField *field = alert.textFields.firstObject;
        NSString *code = [field.text stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];

        // Check: the code is not empty
        if (code.length == 0) {
            [strongSelf showSimpleAlertWithTitle:MPLocalized(@"mp.guest.error_title", @"Input is empty")
                                          message:MPLocalized(@"mp.guest.error.empty", @"Enter the share code the host gave you")];
            return;
        }

        // Parse the share code
        MultiplayerRoom *parsedRoom = [[MultiplayerManager sharedManager] parseShareCode:code];
        if (!parsedRoom) {
            [strongSelf showSimpleAlertWithTitle:MPLocalized(@"mp.guest.error_title", @"Invalid code")
                                          message:MPLocalized(@"mp.guest.error.invalid_code", @"Could not read the share code — check that it is complete and correct")];
            return;
        }

        // Validate the parsed network ID
        if (!parsedRoom.networkId.length || ![[MultiplayerManager sharedManager] isValidNetworkId:parsedRoom.networkId]) {
            [strongSelf showSimpleAlertWithTitle:MPLocalized(@"mp.guest.error_title", @"Invalid code")
                                          message:MPLocalized(@"mp.guest.error.invalid_network_id", @"The network ID in the share code is invalid")];
            return;
        }

        // Key fix (P0-6): check that the hostIP in the share code is not empty
        // A guest needs the host IP for port forwarding, so a share code with an empty hostIP is unusable
        if (!parsedRoom.hostIP.length) {
            [strongSelf showSimpleAlertWithTitle:MPLocalized(@"mp.sharecode.invalid", @"Invalid share code")
                                          message:MPLocalized(@"mp.sharecode.missing_host", @"The share code is missing the host IP — check that the code is complete")];
            return;
        }

        [strongSelf performGuestJoinWithRoom:parsedRoom shareCode:code];
    }]];

    [self presentViewController:alert animated:YES completion:nil];
}

/// The guest flow: join the room
///
/// @param parsedRoom The room object parsed out of the share code
/// @param shareCode The original share code (for display)
- (void)performGuestJoinWithRoom:(MultiplayerRoom *)parsedRoom shareCode:(NSString *)shareCode {
    // Mark the guest flow as active
    self.isGuestFlowActive = YES;
    self.lastShareCode = shareCode;
    // Set the host address temporarily; once connected, showGuestConnectedAlert updates it to the port-forwarded address
    self.lastServerAddress = [NSString stringWithFormat:@"%@:%@", parsedRoom.hostIP, parsedRoom.hostPort];

    // Set the guest room object (kept so the state can be shown)
    self.guestRoom = parsedRoom;

    // If another room is connected, disconnect first
    MultiplayerRoom *currentRoom = [[MultiplayerManager sharedManager] currentRoom];
    if (currentRoom && ![currentRoom.networkId isEqualToString:parsedRoom.networkId]) {
        [[MultiplayerManager sharedManager] disconnectCurrentRoom];
    }

    // Show the "connecting" progress message (whose text updates live)
    //
    // Key fix (no feedback in the foreground):
    // As in hostButtonTapped, an alert whose progress can be updated replaces the static message.
    [self showConnectionProgressWithTitle:MPLocalized(@"mp.guest.connecting_title", @"Joining multiplayer")
                                   message:MPLocalized(@"mp.guest.connecting_msg", @"Connecting to the host's ZeroTier network, please wait...")];

    // Connect to the room
    __weak typeof(self) weakSelf = self;
    [self connectToRoom:parsedRoom completion:^(BOOL success, NSError *error) {
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf) return;

        // Dismiss the progress alert first, then show the result
        [strongSelf dismissConnectionProgressAlertWithCompletion:^{
            if (success) {
                // Connected successfully: show the guest joined message
                [strongSelf showGuestConnectedAlert];
            } else {
                // Connection failed
                strongSelf.isGuestFlowActive = NO;
                [strongSelf showSimpleAlertWithTitle:MPLocalized(@"mp.connect.failed", @"Connection failed")
                                              message:error.localizedDescription ?: MPLocalized(@"mp.connect.failed_msg", @"Could not connect to the host's network. Check that the share code is correct and that your connection is working.")];
            }
        }];
        [strongSelf.tableView reloadData];
    }];

    [self.tableView reloadData];
}

/// Show the message after a guest connects
///
/// Matching the FCL guidance after a guest joins:
///   - "Connected to the host's multiplayer network"
///   - write the server address into the current profile automatically (so Minecraft connects on the next launch)
///   - copy the server address to the clipboard automatically (so it can be pasted into Minecraft)
///   - show the instructions and the server address
///
/// Because libzt runs in-process (creating no system network interface), the Minecraft UDP LAN broadcast
/// cannot travel over the ZeroTier network, so "discover rooms automatically" is not possible. Instead:
///   1. write the profile serverIp automatically (so Minecraft connects on the next launch)
///   2. copy the server address to the clipboard automatically (ready to paste into "Add Server" in Minecraft)
///   3. show clear instructions
- (void)showGuestConnectedAlert {
    MultiplayerRoom *room = self.guestRoom;
    // Key fix (P1-5): show "unknown" when hostIP is empty, rather than misleading the user with currentLocalIP
    NSString *hostIP = room.hostIP.length ? room.hostIP : MPLocalized(@"mp.unknown", @"Unknown");
    NSString *hostPort = room.hostPort.length ? room.hostPort : @"25565";

    // Key fix: Minecraft uses the Netty NioSocketChannel and does not go through the Java SOCKS5 proxy.
    // A guest cannot enter the host ZeroTier IP directly (the system cannot route to it) and must go through the local port forwarder.
    // PortForwarder listens on 127.0.0.1:25565 (or the next free port) and forwards to the host ZeroTier IP:port.
    // The guest enters 127.0.0.1:<forwarded port> in Minecraft to connect.
    uint16_t forwardPort = [[MultiplayerManager sharedManager] currentForwardingPort];
    NSString *serverAddress;
    if (forwardPort > 0) {
        // The port forwarder is running, so use the local address
        serverAddress = [NSString stringWithFormat:@"127.0.0.1:%u", forwardPort];
        NSLog(@"[MultiplayerVC] Guest using port forwarding address: %@ (forwarding to %@:%@)",
              serverAddress, hostIP, hostPort);
        self.lastServerAddress = serverAddress;

        // Write the server address into the current profile automatically (so Minecraft connects to it on the next launch)
        NSString *profileName = [PLProfiles current].selectedProfileName;
        if (profileName && profileName.length > 0) {
            [[PLProfiles current] setServerIp:serverAddress forProfile:profileName];
            NSLog(@"[Multiplayer] Auto-wrote server address %@ to profile %@", serverAddress, profileName);
        }
    } else {
        // Key fix (P0-5): with the port forwarder not running, do not write the profile
        // A guest cannot reach the ZeroTier IP directly (the system cannot route to it), so writing it would make the next Minecraft launch fail to connect
        serverAddress = [NSString stringWithFormat:@"%@:%@", hostIP, hostPort];
        NSLog(@"[MultiplayerVC] Warning: port forwarder not started, not writing profile serverIp");
        // Show a warning rather than a success message
        [self showSimpleAlertWithTitle:MPLocalized(@"mp.connect.failed", @"Connection failed")
                               message:MPLocalized(@"mp.connect.port_forward_failed_msg", @"The port forwarder failed to start, so the host cannot be reached. Try disconnecting and reconnecting.")];
        return;
    }

    // Copy the server address to the clipboard automatically (ready to paste into "Add Server" in Minecraft)
    UIPasteboard *pasteboard = [UIPasteboard generalPasteboard];
    pasteboard.string = serverAddress;

    // Build the message
    NSString *message = [NSString stringWithFormat:@"%@\n\n%@\n%@\n\n%@: %@\n\n%@",
                         MPLocalized(@"mp.guest.connected_msg", @"Connected to the host's multiplayer network"),
                         MPLocalized(@"mp.guest.tip.add_server", @"On Minecraft's multiplayer screen tap \"Add Server\" and paste the address below to join"),
                         MPLocalized(@"mp.guest.tip.address_copied", @"The server address was copied to your clipboard — just paste it"),
                         MPLocalized(@"mp.guest.server_address", @"Server address"),
                         serverAddress,
                         MPLocalized(@"mp.guest.tip.auto_saved", @"The address was saved to the current profile, so the game will connect automatically next time")];

    [self showSimpleAlertWithTitle:MPLocalized(@"mp.guest.connected_title", @"Joined multiplayer")
                           message:message];
}

#pragma mark - MultiplayerManagerDelegate

/// The ZeroTier node came online: refresh the room list and state
- (void)multiplayerNodeOnline {
    [self refreshRooms];
    [self.tableView reloadData];
}

/// The ZeroTier node went offline: refresh the room list and state
- (void)multiplayerNodeOffline {
    [self refreshRooms];
    [self.tableView reloadData];
}

/// The given room connected: refresh the room list and state
- (void)multiplayerRoomConnected:(MultiplayerRoom *)room {
    [self refreshRooms];
    [self.tableView reloadData];
}

/// The given room failed to connect: refresh the room list and state
- (void)multiplayerRoom:(MultiplayerRoom *)room didFailWithError:(NSError *)error {
    [self refreshRooms];
    [self.tableView reloadData];
}

/// The ZeroTier framework availability result: refresh the room list
- (void)multiplayerFrameworkAvailabilityChecked:(BOOL)available {
    [self refreshRooms];
    [self.tableView reloadData];
}

/// Connection flow progress update
///
/// Called on the main thread by notifyConnectionProgress: on MultiplayerManager.
/// It updates the message of connectionProgressAlert, so the user sees the current connection step live.
///
/// Key fix (no feedback in the foreground):
/// the connection flow used to show a static "Connecting to the ZeroTier network" message,
/// leaving the user unaware of the progress (starting the node, waiting for it to come online, joining the network, waiting for it to be ready, starting the proxy...).
/// This callback now updates the progress text live, so the user sees the detailed steps.
///
/// @param message The progress text (such as "Step 2/6: waiting for the node to come online...")
- (void)multiplayerConnectionProgress:(NSString *)message {
    // This method is already on the main thread (guaranteed by MultiplayerManager.notifyConnectionProgress:)
    if (self.connectionProgressAlert) {
        // Update the message of the progress alert already on screen
        // The message property of a UIAlertController can be updated after presenting,
        // and the system refreshes the UI itself, so it does not have to be presented again.
        self.connectionProgressAlert.message = message;
    }
    NSLog(@"[MultiplayerVC] Connection progress: %@", message);
}

#pragma mark - Utility methods

/// Refresh the room list (main thread)
- (void)refreshRooms {
    dispatch_async(dispatch_get_main_queue(), ^{
        self.rooms = [[MultiplayerManager sharedManager] savedRooms] ?: @[];
        [self.tableView reloadData];
    });
}

/// Show a simple alert
- (void)showSimpleAlertWithTitle:(NSString *)title message:(NSString *)message {
    dispatch_async(dispatch_get_main_queue(), ^{
        // Key fix: clear the progress alert reference (if any) before showing a new alert
        self.connectionProgressAlert = nil;
        UIAlertController *alert = [UIAlertController alertControllerWithTitle:title message:message preferredStyle:UIAlertControllerStyleAlert];
        [alert addAction:[UIAlertAction actionWithTitle:MPLocalized(@"common.ok", @"OK") style:UIAlertActionStyleDefault handler:nil]];
        // so nothing is presented twice
        if (self.presentedViewController) {
            [self.presentedViewController dismissViewControllerAnimated:NO completion:^{
                [self presentViewController:alert animated:YES completion:nil];
            }];
        } else {
            [self presentViewController:alert animated:YES completion:nil];
        }
    });
}

/// Show the connection progress alert (whose message can be updated live)
///
/// This alert has a "Cancel" button, so the user can cancel while connecting.
/// Cancelling calls disconnectCurrentRoom to abort the connection flow.
///
/// Once shown, the multiplayerConnectionProgress: callback updates self.connectionProgressAlert.message
/// to change the progress text live, with no need to present it again.
///
/// @param title   The alert title (such as "Starting multiplayer")
/// @param message The initial progress text (such as "Connecting to the ZeroTier network, please wait...")
- (void)showConnectionProgressWithTitle:(NSString *)title message:(NSString *)message {
    dispatch_async(dispatch_get_main_queue(), ^{
        // If a progress alert is already on screen, dismiss it first
        if (self.connectionProgressAlert && self.presentedViewController == self.connectionProgressAlert) {
            [self dismissViewControllerAnimated:NO completion:^{
                [self presentNewConnectionProgressAlertWithTitle:title message:message];
            }];
        } else if (self.presentedViewController) {
            // Another VC is showing (such as an earlier simple alert), so dismiss it first
            [self.presentedViewController dismissViewControllerAnimated:NO completion:^{
                [self presentNewConnectionProgressAlertWithTitle:title message:message];
            }];
        } else {
            [self presentNewConnectionProgressAlertWithTitle:title message:message];
        }
    });
}

/// Internal: create and present a new connection progress alert
- (void)presentNewConnectionProgressAlertWithTitle:(NSString *)title message:(NSString *)message {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:title
                                                                    message:message
                                                             preferredStyle:UIAlertControllerStyleAlert];

    // Add a "Cancel" button, so the user can cancel while connecting
    __weak typeof(self) weakSelf = self;
    [alert addAction:[UIAlertAction actionWithTitle:MPLocalized(@"common.cancel", @"Cancel")
                                              style:UIAlertActionStyleCancel
                                            handler:^(UIAlertAction *action) {
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf) return;

        // The user cancelled: abort the connection flow in progress
        NSLog(@"[MultiplayerVC] User cancelled the connection flow");
        strongSelf.isHostFlowActive = NO;
        strongSelf.isGuestFlowActive = NO;
        [[MultiplayerManager sharedManager] disconnectCurrentRoom];
        strongSelf.connectionProgressAlert = nil;
        [strongSelf.tableView reloadData];
    }]];

    self.connectionProgressAlert = alert;
    [self presentViewController:alert animated:YES completion:nil];
}

/// Dismiss the connection progress alert
///
/// Called once the connection finishes (successfully or not) to dismiss the progress alert,
/// after which completion shows the result alert (a success message or an error).
///
/// @param completion Called once the alert is dismissed
- (void)dismissConnectionProgressAlertWithCompletion:(void (^)(void))completion {
    dispatch_async(dispatch_get_main_queue(), ^{
        if (self.connectionProgressAlert && self.presentedViewController == self.connectionProgressAlert) {
            // The progress alert is on screen: dismiss it and continue in completion
            self.connectionProgressAlert = nil;
            [self dismissViewControllerAnimated:YES completion:^{
                if (completion) completion();
            }];
        } else {
            // The progress alert is not on screen (the user may have cancelled it, or it was never created):
            // clear the reference and run completion straight away
            self.connectionProgressAlert = nil;
            if (completion) completion();
        }
    });
}

/// Build a small solid circular icon (used as a status dot)
/// @param color The circle color
/// @param size The circle diameter (in points)
/// @return The circular UIImage
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

/// Get the color for a room status
/// @param status The room status
/// @return The status color (connecting=orange, connected=green, disconnected=gray, error=red)
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

/// Get the localized text for a room status
/// @param status The room status
/// @return The status text ("Not connected" / "Connecting" / "Connected" / "Error")
- (NSString *)textForRoomStatus:(MultiplayerRoomStatus)status {
    switch (status) {
        case MultiplayerRoomStatusDisconnected:
            return MPLocalized(@"mp.room.status.disconnected", @"Not connected");
        case MultiplayerRoomStatusConnecting:
            return MPLocalized(@"mp.room.status.connecting", @"Connecting");
        case MultiplayerRoomStatusConnected:
            return MPLocalized(@"mp.room.status.connected", @"Connected");
        case MultiplayerRoomStatusError:
            return MPLocalized(@"mp.room.status.error", @"Error");
    }
    return @"";
}

/// Build the connect/disconnect button for a room row
///
/// Button style: a rounded rectangle, 64pt wide and 32pt tall
/// - connected: reads "Disconnect", with a red background
/// - connecting: reads "Connecting", with a gray background, and is disabled
/// - otherwise: reads "Connect", with a blue background
///
/// @param room The room object
/// @return The configured button
- (UIButton *)makeActionButtonForRoom:(MultiplayerRoom *)room {
    UIButton *button = [UIButton buttonWithType:UIButtonTypeSystem];
    button.frame = CGRectMake(0, 0, 64, 32);
    button.titleLabel.font = [UIFont systemFontOfSize:14 weight:UIFontWeightMedium];
    button.layer.cornerRadius = 8;
    button.layer.masksToBounds = YES;

    NSString *title;
    UIColor *bgColor;

    if (room.status == MultiplayerRoomStatusConnected) {
        title = MPLocalized(@"mp.room.button.disconnect", @"Disconnect");
        bgColor = [UIColor systemRedColor];
        button.enabled = YES;
    } else if (room.status == MultiplayerRoomStatusConnecting) {
        title = MPLocalized(@"mp.room.button.connecting", @"Connecting");
        bgColor = [UIColor systemGrayColor];
        button.enabled = NO;
    } else {
        title = MPLocalized(@"mp.room.button.connect", @"Connect");
        bgColor = FluxTheme.accent;
        button.enabled = YES;
    }

    [button setTitle:title forState:UIControlStateNormal];
    [button setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    button.backgroundColor = bgColor;

    return button;
}

#pragma mark - UITextFieldDelegate

/// Dismiss the keyboard when Return is pressed
- (BOOL)textFieldShouldReturn:(UITextField *)textField {
    if (textField == self.directIPField) {
        // Pressing Return in the IP field moves to the port field
        [self.directPortField becomeFirstResponder];
    } else {
        [textField resignFirstResponder];
    }
    return YES;
}

#pragma mark - UITableViewDataSource

/// Number of sections: depends on the mode
- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView {
    if (self.mode == MultiplayerVCModeInGame) {
        // In-game mode: choose a role + multiplayer status
        return 2;
    }
    // Launcher mode: multiplayer settings + my rooms + direct connect
    return 3;
}

/// Rows per section: depends on the mode and the section
- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    if (self.mode == MultiplayerVCModeInGame) {
        switch (section) {
            case 0:
                // Choose a role: Host + Guest
                return 2;
            case 1:
                // Multiplayer status: one combined status row
                return 1;
            default:
                return 0;
        }
    }
    // Launcher mode
    switch (section) {
        case 0:
            // Multiplayer settings: the enable switch + network ID + the ZeroTier setup guide
            return 3;
        case 1:
            // My rooms: at least 1 row (the empty state message)
            return MAX(1, (NSInteger)self.rooms.count);
        case 2:
            // Direct connect: IP+port input + the join button
            return 2;
        default:
            return 0;
    }
}

/// Section title: depends on the mode
- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section {
    if (self.mode == MultiplayerVCModeInGame) {
        switch (section) {
            case 0:
                return MPLocalized(@"mp.ingame.section.role", @"Choose a role");
            case 1:
                return MPLocalized(@"mp.ingame.section.status", @"Multiplayer status");
            default:
                return nil;
        }
    }
    switch (section) {
        case 0:
            return MPLocalized(@"mp.section.settings", @"Multiplayer settings");
        case 1:
            return MPLocalized(@"mp.section.rooms", @"My rooms");
        case 2:
            return MPLocalized(@"mp.section.direct", @"Direct connect");
        default:
            return nil;
    }
}

/// Section footer: depends on the mode
- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section {
    if (self.mode == MultiplayerVCModeInGame) {
        switch (section) {
            case 0:
                return MPLocalized(@"mp.ingame.section.role_footer", @"The host opens the world to LAN in Minecraft, then guests join by entering the share code");
            case 1:
                return MPLocalized(@"mp.ingame.section.status_footer", @"Shows status information for the current multiplayer network");
            default:
                return nil;
        }
    }
    switch (section) {
        case 0:
            return MPLocalized(@"mp.section.settings_footer", @"Once multiplayer is enabled you can set a network ID, which is used automatically when hosting");
        case 2:
            return MPLocalized(@"mp.section.direct_footer", @"Enter a server IP and port to save into the current profile and join automatically when the game starts");
        default:
            return nil;
    }
}

/// Configure the cell for the given index path
- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    if (self.mode == MultiplayerVCModeInGame) {
        return [self cellForInGameSection:indexPath];
    }
    return [self cellForLauncherSection:indexPath];
}

#pragma mark - Launcher mode cell configuration

/// Launcher mode cell configuration dispatch
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

/// Cell configuration for section 0, "Multiplayer settings"
/// @param row The row number (0=the enable switch, 1=the preset network ID, 2=the ZeroTier setup guide)
- (UITableViewCell *)cellForSettingsSectionAtRow:(NSInteger)row {
    if (row == 2) {
        // The ZeroTier network setup guide entry
        return [self cellForGuideSection];
    }
    if (row == 0) {
        // The enable multiplayer row
        UITableViewCell *cell = [self.tableView dequeueReusableCellWithIdentifier:@"SwitchCell"];
        cell.selectionStyle = UITableViewCellSelectionStyleNone;
        cell.textLabel.text = MPLocalized(@"mp.settings.enable_multiplayer", @"Enable multiplayer");
        cell.textLabel.font = [UIFont systemFontOfSize:16];

        // Lazily initialize the UISwitch
        if (!self.enableSwitch) {
            self.enableSwitch = [[UISwitch alloc] init];
            [self.enableSwitch addTarget:self action:@selector(enableSwitchChanged:) forControlEvents:UIControlEventValueChanged];
        }
        // Initial state: set from the persisted user intent (matching viewWillAppear:)
        BOOL enabled = [[MultiplayerManager sharedManager] isMultiplayerEnabled];
        [self.enableSwitch setOn:enabled animated:NO];
        cell.accessoryView = self.enableSwitch;

        // Detail text: shows the real node state (rather than the user intent)
        BOOL started = [[MultiplayerManager sharedManager] isNodeStarted];
        if (started) {
            if ([[MultiplayerManager sharedManager] isNodeOnline]) {
                cell.detailTextLabel.text = MPLocalized(@"mp.settings.node_online", @"Node online");
            } else {
                cell.detailTextLabel.text = MPLocalized(@"mp.settings.node_starting", @"Node starting...");
            }
        } else {
            // The node has not started: if the user has enabled it (waiting for the automatic restart), show "Starting"
            if (enabled) {
                cell.detailTextLabel.text = MPLocalized(@"mp.settings.node_starting", @"Node starting...");
            } else {
                cell.detailTextLabel.text = MPLocalized(@"mp.settings.node_offline", @"Node not started");
            }
        }
        cell.detailTextLabel.font = [UIFont systemFontOfSize:12];

        // Adapt to the custom background
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
        // The preset network ID row
        UITableViewCell *cell = [self.tableView dequeueReusableCellWithIdentifier:@"NetworkIdCell"];
        cell.selectionStyle = UITableViewCellSelectionStyleDefault;
        cell.textLabel.text = MPLocalized(@"mp.settings.preset_network_id", @"Preset network ID");
        cell.textLabel.font = [UIFont systemFontOfSize:16];

        // Show the current preset network ID (masked: the first 4 + ... + the last 4)
        NSString *presetNetId = [[MultiplayerManager sharedManager] presetNetworkId];
        NSString *displayValue;
        if (presetNetId.length >= 16) {
            displayValue = [NSString stringWithFormat:@"%@...%@",
                            [presetNetId substringToIndex:4],
                            [presetNetId substringFromIndex:presetNetId.length - 4]];
        } else if (presetNetId.length > 0) {
            displayValue = presetNetId;
        } else {
            displayValue = MPLocalized(@"mp.settings.not_set", @"Not set");
        }

        // Use detailTextLabel for the value
        cell.detailTextLabel.text = displayValue;
        cell.detailTextLabel.font = [UIFont systemFontOfSize:14];
        cell.detailTextLabel.numberOfLines = 1;
        cell.detailTextLabel.adjustsFontSizeToFitWidth = YES;
        cell.detailTextLabel.minimumScaleFactor = 0.7;

        // Show the edit icon on the right
        cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;

        // Adapt to the custom background
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

/// The guide entry cell in section 0, "Multiplayer settings" (row == 2)
///
/// Equivalent to the FCL "multiplayer help" entry: it walks the host through creating and configuring a ZeroTier network.
/// Tapping it shows a detailed illustrated guide covering registering an account, creating a network, getting the network ID
/// and setting the network visibility, with a shortcut button for "Open central.zerotier.com".
- (UITableViewCell *)cellForGuideSection {
    UITableViewCell *cell = [self.tableView dequeueReusableCellWithIdentifier:@"DefaultCell"];
    cell.selectionStyle = UITableViewCellSelectionStyleDefault;
    cell.textLabel.text = MPLocalized(@"mp.settings.zt_guide", @"How to create a ZeroTier network");
    cell.textLabel.font = [UIFont systemFontOfSize:16];

    // Icon on the left: a question mark in a circle
    cell.imageView.image = [UIImage systemImageNamed:@"questionmark.circle"];
    cell.imageView.tintColor = FluxTheme.accent;

    // Chevron on the right
    cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;

    // Detail text: a short explanation
    cell.detailTextLabel.text = MPLocalized(@"mp.settings.zt_guide_desc", @"Not sure how to create a network? Tap here");
    cell.detailTextLabel.font = [UIFont systemFontOfSize:12];

    // Adapt to the custom background
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

/// Cell configuration for section 1, "My rooms"
/// @param row The row number
- (UITableViewCell *)cellForRoomsSectionAtRow:(NSInteger)row {
    // Empty state: show the message
    if (self.rooms.count == 0) {
        UITableViewCell *cell = [self.tableView dequeueReusableCellWithIdentifier:@"EmptyCell"];
        cell.selectionStyle = UITableViewCellSelectionStyleNone;
        cell.textLabel.text = MPLocalized(@"mp.rooms.empty", @"No rooms (rooms are only kept for this session)");
        cell.textLabel.textAlignment = NSTextAlignmentCenter;
        cell.textLabel.font = [UIFont systemFontOfSize:14];
        // Adapt to the custom background
        if ([[BackgroundManager sharedManager] hasBackground]) {
            cell.textLabel.textColor = [UIColor whiteColor];
        } else {
            cell.textLabel.textColor = [UIColor secondaryLabelColor];
        }
        [[BackgroundManager sharedManager] applyEffectToCell:cell];
        return cell;
    }

    // With rooms: use a standard subtitle-style UITableViewCell
    MultiplayerRoom *room = self.rooms[row];
    // RoomCell is not registered; a subtitle-style cell is built by hand with dequeueReusableCellWithIdentifier:
    UITableViewCell *cell = [self.tableView dequeueReusableCellWithIdentifier:@"RoomCell"];
    if (!cell) {
        cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:@"RoomCell"];
    }
    cell.selectionStyle = UITableViewCellSelectionStyleDefault;

    // Room name
    cell.textLabel.text = room.name.length ? room.name : MPLocalized(@"mp.room.unnamed", @"Untitled room");
    cell.textLabel.font = [UIFont systemFontOfSize:16 weight:UIFontWeightMedium];

    // Detail: network ID + status + server address (the full address is shown when connected, for easy sharing)
    NSString *statusText = [self textForRoomStatus:room.status];
    NSMutableString *detail = [NSMutableString string];
    [detail appendFormat:@"%@: %@",
        MPLocalized(@"mp.room.network_id", @"Network ID"),
        room.networkId ?: @"-"];
    [detail appendFormat:@"\n%@", statusText];
    if (room.status == MultiplayerRoomStatusConnected) {
        // Show the full server address when connected
        NSString *hostIP = room.hostIP.length ? room.hostIP : [[MultiplayerManager sharedManager] currentLocalIP];
        NSString *hostPort = room.hostPort.length ? room.hostPort : @"25565";
        if (hostIP.length) {
            [detail appendFormat:@"\n%@: %@:%@",
                MPLocalized(@"mp.room.server_address", @"Server address"),
                hostIP, hostPort];
        }
    }
    cell.detailTextLabel.text = detail;
    cell.detailTextLabel.font = [UIFont systemFontOfSize:12];
    cell.detailTextLabel.numberOfLines = 0;

    // Status dot (imageView shows a small colored circle)
    UIColor *statusColor = [self colorForRoomStatus:room.status];
    UIImage *dotImage = [self circleImageWithColor:statusColor size:10];
    cell.imageView.image = dotImage;

    // The connect/disconnect button (accessoryView)
    UIButton *actionButton = [self makeActionButtonForRoom:room];
    [actionButton addTarget:self action:@selector(roomButtonTapped:) forControlEvents:UIControlEventTouchUpInside];
    actionButton.tag = row;
    cell.accessoryView = actionButton;

    // Adapt to the custom background
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

/// Cell configuration for section 2, "Direct connect"
/// @param row The row number (0=IP+port input, 1=the join button)
- (UITableViewCell *)cellForDirectSectionAtRow:(NSInteger)row {
    if (row == 0) {
        // The IP + port input row
        UITableViewCell *cell = [self.tableView dequeueReusableCellWithIdentifier:@"DirectInputCell"];
        cell.selectionStyle = UITableViewCellSelectionStyleNone;

        // Lazily initialize the IP field
        if (!self.directIPField) {
            self.directIPField = [[UITextField alloc] init];
            self.directIPField.placeholder = MPLocalized(@"mp.direct.ip_placeholder", @"Server IP");
            self.directIPField.font = [UIFont systemFontOfSize:15];
            self.directIPField.autocapitalizationType = UITextAutocapitalizationTypeNone;
            self.directIPField.autocorrectionType = UITextAutocorrectionTypeNo;
            self.directIPField.keyboardType = UIKeyboardTypeNumbersAndPunctuation;
            self.directIPField.clearButtonMode = UITextFieldViewModeWhileEditing;
            self.directIPField.returnKeyType = UIReturnKeyNext;
            self.directIPField.delegate = self;
            self.directIPField.translatesAutoresizingMaskIntoConstraints = NO;
        }

        // Lazily initialize the port field
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

        // Lazily initialize the colon separator label
        UILabel *colonLabel = (UILabel *)[cell.contentView viewWithTag:9528];
        if (!colonLabel) {
            colonLabel = [[UILabel alloc] init];
            colonLabel.tag = 9528;
            colonLabel.text = @":";
            colonLabel.font = [UIFont systemFontOfSize:15];
            colonLabel.translatesAutoresizingMaskIntoConstraints = NO;
            [cell.contentView addSubview:colonLabel];
        }

        // If the textField is already on another cell (the cell reuse case), remove it first
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

        // Only set the constraints the first time the textField is added to a cell (activating them twice would conflict)
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

        // Adapt to the custom background
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
        // The join game button row
        UITableViewCell *cell = [self.tableView dequeueReusableCellWithIdentifier:@"ButtonCell"];
        cell.selectionStyle = UITableViewCellSelectionStyleNone;
        cell.textLabel.text = MPLocalized(@"mp.direct.join_button", @"Join game");
        cell.textLabel.textAlignment = NSTextAlignmentCenter;
        cell.textLabel.font = [UIFont systemFontOfSize:16 weight:UIFontWeightSemibold];
        // Adapt to the custom background
        if ([[BackgroundManager sharedManager] hasBackground]) {
            cell.textLabel.textColor = [UIColor whiteColor];
        } else {
            cell.textLabel.textColor = FluxTheme.accent;
        }
        [[BackgroundManager sharedManager] applyEffectToCell:cell];
        return cell;
    }
}

#pragma mark - In-game mode cell configuration

/// In-game mode cell configuration dispatch
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

/// Cell configuration for section 0, "Choose a role"
/// @param row The row number (0=Host, 1=Guest)
- (UITableViewCell *)cellForRoleSectionAtRow:(NSInteger)row {
    UITableViewCell *cell = [self.tableView dequeueReusableCellWithIdentifier:@"RoleCardCell"];
    cell.selectionStyle = UITableViewCellSelectionStyleNone;

    // A custom card layout: a large icon on the left with the title and description on the right
    if (row == 0) {
        // Host
        cell.imageView.image = [UIImage systemImageNamed:@"crown"];
        cell.imageView.tintColor = [UIColor systemOrangeColor];
        cell.textLabel.text = MPLocalized(@"mp.ingame.host_title", @"Host");
        cell.textLabel.font = [UIFont systemFontOfSize:18 weight:UIFontWeightSemibold];
        cell.detailTextLabel.text = MPLocalized(@"mp.ingame.host_desc", @"Create a multiplayer room, then generate a share code once you open the world to LAN");
        cell.detailTextLabel.font = [UIFont systemFontOfSize:13];
        cell.detailTextLabel.numberOfLines = 0;

        // Show a status indicator while the host flow is active
        if (self.isHostFlowActive) {
            cell.accessoryType = UITableViewCellAccessoryCheckmark;
        } else {
            cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
        }
    } else {
        // Guest
        cell.imageView.image = [UIImage systemImageNamed:@"person.2"];
        cell.imageView.tintColor = FluxTheme.accent;
        cell.textLabel.text = MPLocalized(@"mp.ingame.guest_title", @"Guest");
        cell.textLabel.font = [UIFont systemFontOfSize:18 weight:UIFontWeightSemibold];
        cell.detailTextLabel.text = MPLocalized(@"mp.ingame.guest_desc", @"Enter a share code to join the host's multiplayer network");
        cell.detailTextLabel.font = [UIFont systemFontOfSize:13];
        cell.detailTextLabel.numberOfLines = 0;

        // Show a status indicator while the guest flow is active
        if (self.isGuestFlowActive) {
            cell.accessoryType = UITableViewCellAccessoryCheckmark;
        } else {
            cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
        }
    }

    // Adapt to the custom background
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

/// Cell configuration for section 1, "Multiplayer status"
///
/// Shows everything together:
///   - the current multiplayer status (connected/not connected)
///   - Network ID
///   - the local IP
///   - the host flow: the share code
///   - the guest flow: the server address
- (UITableViewCell *)cellForInGameStatusSection {
    UITableViewCell *cell = [self.tableView dequeueReusableCellWithIdentifier:@"StatusCell"];
    cell.selectionStyle = UITableViewCellSelectionStyleNone;

    MultiplayerManager *manager = [MultiplayerManager sharedManager];
    MultiplayerRoom *currentRoom = manager.currentRoom;
    BOOL connected = (currentRoom != nil) && (currentRoom.status == MultiplayerRoomStatusConnected);

    // Title: multiplayer status
    cell.textLabel.text = connected ? MPLocalized(@"mp.ingame.status.connected", @"Connected") : MPLocalized(@"mp.ingame.status.disconnected", @"Not connected");
    cell.textLabel.font = [UIFont systemFontOfSize:16 weight:UIFontWeightMedium];

    // Detail: network ID + local IP + (host) the share code / (guest) the server address
    NSMutableString *detail = [NSMutableString string];

    // Status indicator
    if (self.isHostFlowActive) {
        [detail appendString:MPLocalized(@"mp.ingame.status.host_mode", @"Host mode")];
    } else if (self.isGuestFlowActive) {
        [detail appendString:MPLocalized(@"mp.ingame.status.guest_mode", @"Guest mode")];
    } else {
        [detail appendString:MPLocalized(@"mp.ingame.status.idle", @"Not started")];
    }

    // Network ID
    NSString *networkId = currentRoom.networkId.length ? currentRoom.networkId : [manager presetNetworkId];
    if (networkId.length) {
        [detail appendFormat:@"\n%@: %@", MPLocalized(@"mp.ingame.status.network_id", @"Network ID"), networkId];
    } else {
        [detail appendFormat:@"\n%@: %@", MPLocalized(@"mp.ingame.status.network_id", @"Network ID"), MPLocalized(@"mp.settings.not_set", @"Not set")];
    }

    // Local IP
    NSString *localIP = manager.currentLocalIP;
    if (localIP.length) {
        [detail appendFormat:@"\n%@: %@", MPLocalized(@"mp.ingame.status.local_ip", @"Local IP"), localIP];
    }

    // Host flow: show the share code
    if (self.isHostFlowActive && self.lastShareCode.length) {
        [detail appendFormat:@"\n%@: %@",
            MPLocalized(@"mp.ingame.status.share_code", @"Share code"),
            self.lastShareCode];
    }

    // Guest flow: show the server address
    if (self.isGuestFlowActive && self.lastServerAddress.length) {
        [detail appendFormat:@"\n%@: %@",
            MPLocalized(@"mp.ingame.status.server_address", @"Server address"),
            self.lastServerAddress];
    }

    cell.detailTextLabel.text = detail;
    cell.detailTextLabel.font = [UIFont systemFontOfSize:13];
    cell.detailTextLabel.numberOfLines = 0;

    // Status dot
    UIColor *statusColor = connected ? [UIColor systemGreenColor] : [UIColor systemGrayColor];
    UIImage *dotImage = [self circleImageWithColor:statusColor size:10];
    cell.imageView.image = dotImage;

    // Adapt to the custom background
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

/// Row tap handler: dispatched by mode and section
- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];

    if (self.mode == MultiplayerVCModeInGame) {
        [self handleInGameSelectionAtIndexPath:indexPath];
        return;
    }
    [self handleLauncherSelectionAtIndexPath:indexPath];
}

/// Launcher mode tap handling
- (void)handleLauncherSelectionAtIndexPath:(NSIndexPath *)indexPath {
    switch (indexPath.section) {
        case 0:
            if (indexPath.row == 0) {
                // Tapping the switch row: give the switch focus (toggling it)
                // Nothing to do; the switch responds itself
            } else if (indexPath.row == 1) {
                // Tapping the network ID row: show the edit dialog
                [self networkIdCellTapped];
            } else if (indexPath.row == 2) {
                // Tapping the guide entry: show the ZeroTier network setup guide
                [self showZeroTierGuide];
            }
            break;
        case 1:
            if (self.rooms.count == 0) {
                // Empty state: tell the user to set a network ID first, or to join a room directly
                [self showSimpleAlertWithTitle:MPLocalized(@"mp.rooms.empty_title", @"No rooms")
                                         message:MPLocalized(@"mp.rooms.empty_msg", @"Set a network ID in Section 0 first, then choose Host or Guest in the in-game mode")];
            } else {
                // Tapping a room row: show the action sheet
                MultiplayerRoom *room = self.rooms[indexPath.row];
                [self showRoomActionsForRoom:room];
            }
            break;
        case 2:
            if (indexPath.row == 0) {
                // Tapping the direct connect input row: give the IP field focus
                [self.directIPField becomeFirstResponder];
            } else if (indexPath.row == 1) {
                // Tapping the join game button
                [self joinDirectConnect];
            }
            break;
        default:
            break;
    }
}

/// In-game mode tap handling
- (void)handleInGameSelectionAtIndexPath:(NSIndexPath *)indexPath {
    switch (indexPath.section) {
        case 0:
            if (indexPath.row == 0) {
                // Host
                [self hostButtonTapped];
            } else if (indexPath.row == 1) {
                // Guest
                [self guestButtonTapped];
            }
            break;
        case 1:
            // The multiplayer status row: no action (it only shows information)
            // While the host flow is active, tapping it shows the share code again
            if (self.isHostFlowActive && self.lastShareCode.length) {
                [self showHostShareCodeAlert];
            }
            break;
        default:
            break;
    }
}

/// Row height: depends on the mode and the index path
- (CGFloat)tableView:(UITableView *)tableView heightForRowAtIndexPath:(NSIndexPath *)indexPath {
    if (self.mode == MultiplayerVCModeInGame) {
        if (indexPath.section == 0) {
            // The role card rows: a large card style, so they are taller
            return 76;
        }
        if (indexPath.section == 1) {
            // The multiplayer status row: a dynamic height (multi-line detail)
            return UITableViewAutomaticDimension;
        }
        return 56;
    }
    // Launcher mode
    if (indexPath.section == 0) {
        // The multiplayer settings rows
        return 56;
    }
    if (indexPath.section == 1) {
        if (self.rooms.count == 0) {
            // The empty state row
            return 60;
        }
        // Room rows: the subtitle takes 2-3 lines and needs more space
        return 76;
    }
    if (indexPath.section == 2) {
        // The IP+port input row / the join button row
        return 48;
    }
    return UITableViewAutomaticDimension;
}

@end
