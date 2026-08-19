#import "LauncherRightPanelViewController.h"
#import "authenticator/BaseAuthenticator.h"
#import "LauncherProfilesViewController.h"
#import "AccountListViewController.h"
#import "SurfaceViewController.h"
#import "JavaGUIViewController.h"
#import "PLProfiles.h"
#import "LauncherPreferences.h"
#import "MinecraftResourceUtils.h"
#import "MinecraftResourceDownloadTask.h"
#import "DownloadProgressViewController.h"
#import "DownloadTaskManager.h"
#import "DownloadTasksViewController.h"
#import "DownloadTaskItem.h"
#import "ALTServerConnection.h"
#import "BackgroundManager.h"
#import "ios_uikit_bridge.h"
#import "utils.h"
#import "AvatarManager.h"
#import "ImageCropperViewController.h"
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>

#include <sys/time.h>

// C function declarations - these are defined in LauncherPreferences.m or elsewhere
extern void setPrefString(NSString *key, NSString *value);
extern void setPrefInt(NSString *key, NSInteger value);

static void *ProgressObserverContext = &ProgressObserverContext;

@interface LauncherRightPanelViewController () <UIDocumentPickerDelegate, UIImagePickerControllerDelegate, UINavigationControllerDelegate>

@property(nonatomic, strong) UIImageView *avatarImageView;
@property(nonatomic, strong) UILabel *usernameLabel;
@property(nonatomic, strong) UILabel *versionLabel;
@property(nonatomic, strong) UIButton *launchButton;
@property(nonatomic, strong) UIButton *manageVersionBtn;
@property(nonatomic, strong) UIButton *executeJarBtn;
// JIT status label (above the play button)
@property(nonatomic, strong) UILabel *jitStatusLabel;

// Download-related properties
@property(nonatomic, strong) MinecraftResourceDownloadTask *task;
@property(nonatomic, strong) DownloadProgressViewController *progressVC;
@property(nonatomic, strong) UIProgressView *progressView;
@property(nonatomic, strong) UILabel *progressLabel;

// ===== Download center entry point (modelled on the unified download progress modal of FCL/ZL2/HMCL) =====
// FCL, ZL2 and HMCL all put a "download manager/download center" button on the launcher main screen,
// which opens a progress dialog showing live progress for every download (the MC client/mods/shaders/resource packs and so on).
// This button is that entry point: it appears whenever DownloadTaskManager has any download,
// and presents DownloadTasksViewController (the full task list plus progress details) as a FormSheet.
@property(nonatomic, strong) UIButton *downloadCenterButton;
// Activity indicator on the button (spinning while a download runs, to show there is something active)
@property(nonatomic, strong) UIActivityIndicatorView *downloadCenterActivityIndicator;
// Progress percentage label on the button (showing the live aggregate progress of every active task)
@property(nonatomic, strong) UILabel *downloadCenterProgressLabel;
// The download center VC currently presented (weak, to avoid a retain cycle)
@property(nonatomic, weak) DownloadTasksViewController *presentedDownloadCenterVC;
// Tracks whether the user closed the download center by hand (so it does not keep reopening on every download update)
@property(nonatomic, assign) BOOL userDismissedDownloadCenter;

// FCL style: with no account, tapping play opens the add-account screen and the launch continues automatically after signing in.
// pendingLaunchAfterLogin=YES means the user reached account sign-in from the play button, so launchGame should fire once sign-in succeeds.
@property(nonatomic, assign) BOOL pendingLaunchAfterLogin;

@end

@implementation LauncherRightPanelViewController

#pragma mark - Lifecycle

- (void)viewDidLoad {
    [super viewDidLoad];
    
    self.view.backgroundColor = [UIColor clearColor];

    // Adapt to the custom launcher background: make this view controller transparent so the global background (image/video) shows through.
    // Even though this controller is added as a child VC of LauncherRootViewController, this still has to be called from its own viewDidLoad.
    [[BackgroundManager sharedManager] makeViewControllerTransparent:self];

    [self setupUI];
    [self updateAccountInfo];
    [self updateVersionInfo];
    
    // Listen for account information updates
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(updateAccountInfo)
                                                 name:@"UpdateAccountInfo"
                                               object:nil];
    // Listen for version/profile switches
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(updateVersionInfo)
                                                 name:@"SelectedProfileChanged"
                                               object:nil];

    // Listen for changes to the aggregate download state, so the play button can be updated
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(updateLaunchButtonState)
                                                 name:DownloadTaskManagerAggregateStateDidChangeNotification
                                               object:nil];

    // ===== Download center notification observers =====
    // Listen for download task updates (progress changes, new registrations and so on) to keep the download center button state and percentage live.
    // This makes sure every download registered with DownloadTaskManager — mods, shaders, resource packs, data packs, world saves —
    // is reflected on the download center button, where the user can tap for details (as in the download progress modals of FCL/ZL2/HMCL).
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(handleDownloadTaskUpdate:)
                                                 name:DownloadTaskManagerDidUpdateTaskNotification
                                               object:nil];
    // Listen for task completion, to update the button state and hide the activity indicator once everything is done
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(handleDownloadTaskCompleted:)
                                                 name:DownloadTaskManagerTaskCompletedNotification
                                               object:nil];
    // Listen for the download center being closed by hand, and set the flag so it does not keep reopening
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(handleDownloadCenterDismissed)
                                                 name:@"DownloadCenterDidDismiss"
                                               object:nil];

    // Listen for launcher appearance changes (custom font/card color) and refresh the text colors
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(applyCustomAppearance)
                                                 name:@"LauncherAppearanceChanged"
                                               object:nil];

    // Listen for background UI effect changes: when the user switches between frosted glass and translucent, or adjusts the opacity,
    // call makeViewControllerTransparent again to apply the latest look and keep the background showing correctly.
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(reapplyBackgroundEffect)
                                                 name:@"BackgroundUIEffectChanged"
                                               object:nil];
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    [self updateAccountInfo];
    [self updateVersionInfo];
    [self updateLaunchButtonState];
    [self updateJITStatus];
    [self applyCustomAppearance];
    [self updateDownloadCenterButton];
}

/// Re-apply the background effect: called when the BackgroundUIEffectChanged notification arrives.
/// Re-applies the opacity/frosted-glass effect to this view controller via BackgroundManager,
/// so the global background shows through correctly.
- (void)reapplyBackgroundEffect {
    [[BackgroundManager sharedManager] makeViewControllerTransparent:self];
}

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
    // Key fix (cumulative UI glitch): remove the KVO observer as a safety net, so a VC released mid-task cannot leave a dangling pointer.
    if (self.task && self.task.progress) {
        @try {
            [self.task.progress removeObserver:self
                                    forKeyPath:@"fractionCompleted"
                                       context:ProgressObserverContext];
        } @catch (NSException *e) {}
    }
}

#pragma mark - UI Setup

- (void)setupUI {
    // Avatar
    self.avatarImageView = [[UIImageView alloc] init];
    self.avatarImageView.translatesAutoresizingMaskIntoConstraints = NO;
    self.avatarImageView.contentMode = UIViewContentModeScaleAspectFit;
    self.avatarImageView.layer.cornerRadius = 36;
    self.avatarImageView.layer.masksToBounds = YES;
    self.avatarImageView.backgroundColor = [UIColor colorWithWhite:0.2 alpha:1.0];
    self.avatarImageView.image = [UIImage systemImageNamed:@"person.circle.fill"];
    self.avatarImageView.tintColor = [UIColor systemGrayColor];
    self.avatarImageView.userInteractionEnabled = YES;
    [self.avatarImageView addGestureRecognizer:[[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(selectAccount:)]];
    // Long-press the avatar: show the import/clear custom avatar menu
    UILongPressGestureRecognizer *longPress = [[UILongPressGestureRecognizer alloc] initWithTarget:self action:@selector(showAvatarMenu:)];
    longPress.minimumPressDuration = 0.5;
    [self.avatarImageView addGestureRecognizer:longPress];
    [self.view addSubview:self.avatarImageView];
    
    // Username label
    self.usernameLabel = [[UILabel alloc] init];
    self.usernameLabel.translatesAutoresizingMaskIntoConstraints = NO;
    self.usernameLabel.font = [UIFont boldSystemFontOfSize:16];
    self.usernameLabel.textColor = [UIColor labelColor];
    self.usernameLabel.textAlignment = NSTextAlignmentCenter;
    // The sidebar is narrower on iPhone, so automatic font scaling stops a long username being truncated
    self.usernameLabel.adjustsFontSizeToFitWidth = YES;
    self.usernameLabel.minimumScaleFactor = 0.7;
    self.usernameLabel.lineBreakMode = NSLineBreakByTruncatingTail;
    self.usernameLabel.text = @"Not signed in";
    [self.view addSubview:self.usernameLabel];

    // Version label
    self.versionLabel = [[UILabel alloc] init];
    self.versionLabel.translatesAutoresizingMaskIntoConstraints = NO;
    self.versionLabel.font = [UIFont systemFontOfSize:13];
    self.versionLabel.textColor = [UIColor secondaryLabelColor];
    self.versionLabel.textAlignment = NSTextAlignmentCenter;
    self.versionLabel.adjustsFontSizeToFitWidth = YES;
    self.versionLabel.minimumScaleFactor = 0.7;
    self.versionLabel.lineBreakMode = NSLineBreakByTruncatingTail;
    self.versionLabel.text = @"No version selected";
    // FCL style: tapping the version label also opens the picker
    self.versionLabel.userInteractionEnabled = YES;
    [self.versionLabel addGestureRecognizer:[[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(showVersionPicker)]];
    [self.view addSubview:self.versionLabel];
    
    // Progress label
    self.progressLabel = [[UILabel alloc] init];
    self.progressLabel.translatesAutoresizingMaskIntoConstraints = NO;
    self.progressLabel.font = [UIFont systemFontOfSize:12];
    self.progressLabel.textColor = [UIColor secondaryLabelColor];
    self.progressLabel.textAlignment = NSTextAlignmentCenter;
    self.progressLabel.text = @"";
    self.progressLabel.hidden = YES;
    [self.view addSubview:self.progressLabel];
    
    // Progress bar
    self.progressView = [[UIProgressView alloc] initWithProgressViewStyle:UIProgressViewStyleDefault];
    self.progressView.translatesAutoresizingMaskIntoConstraints = NO;
    self.progressView.hidden = YES;
    [self.view addSubview:self.progressView];

    // ===== Download center entry button (modelled on the download progress modals of FCL/ZL2/HMCL) =====
    // Design rationale: FCL and ZL2 put a "download manager" button on the launcher main screen that opens a progress dialog,
    // while HMCL shows the progress of every download on the download page. This button combines all three:
    // - button style: a rounded card, matching the other launcher buttons
    // - left: the download icon + an activity indicator (spinning while downloading)
    // - middle: the "Download center" text + the progress percentage
    // - right: a chevron (showing it can be tapped for details)
    // - shown whenever DownloadTaskManager has any download, hidden when there are none
    self.downloadCenterButton = [UIButton buttonWithType:UIButtonTypeSystem];
    self.downloadCenterButton.translatesAutoresizingMaskIntoConstraints = NO;
    [self.downloadCenterButton setTitle:@"Download center" forState:UIControlStateNormal];
    [self.downloadCenterButton setTitleColor:[UIColor labelColor] forState:UIControlStateNormal];
    self.downloadCenterButton.titleLabel.font = [UIFont systemFontOfSize:13 weight:UIFontWeightMedium];
    self.downloadCenterButton.titleLabel.adjustsFontSizeToFitWidth = YES;
    self.downloadCenterButton.titleLabel.minimumScaleFactor = 0.7;
    self.downloadCenterButton.titleLabel.lineBreakMode = NSLineBreakByTruncatingTail;
    self.downloadCenterButton.backgroundColor = [UIColor colorWithWhite:0.2 alpha:1.0];
    self.downloadCenterButton.layer.cornerRadius = 10;
    self.downloadCenterButton.layer.masksToBounds = YES;
    // Download icon on the left
    UIImage *downloadIcon = [UIImage systemImageNamed:@"arrow.down.circle"];
    [self.downloadCenterButton setImage:downloadIcon forState:UIControlStateNormal];
    self.downloadCenterButton.tintColor = accentColor();
    self.downloadCenterButton.imageEdgeInsets = UIEdgeInsetsMake(0, -4, 0, 4);
    self.downloadCenterButton.titleEdgeInsets = UIEdgeInsetsMake(0, 4, 0, -4);
    self.downloadCenterButton.contentHorizontalAlignment = UIControlContentHorizontalAlignmentLeft;
    self.downloadCenterButton.contentEdgeInsets = UIEdgeInsetsMake(0, 12, 0, 12);
    [self.downloadCenterButton addTarget:self action:@selector(openDownloadCenter) forControlEvents:UIControlEventTouchUpInside];
    self.downloadCenterButton.hidden = YES; // Hidden by default, shown when there are downloads
    [self.view addSubview:self.downloadCenterButton];

    // Activity indicator (spinning while downloading, overlaid on the right of the button)
    self.downloadCenterActivityIndicator = [[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleMedium];
    self.downloadCenterActivityIndicator.translatesAutoresizingMaskIntoConstraints = NO;
    self.downloadCenterActivityIndicator.color = accentColor();
    self.downloadCenterActivityIndicator.hidesWhenStopped = YES;
    [self.downloadCenterButton addSubview:self.downloadCenterActivityIndicator];

    // Progress percentage label (overlaid on the right of the button, showing the aggregate progress)
    self.downloadCenterProgressLabel = [[UILabel alloc] init];
    self.downloadCenterProgressLabel.translatesAutoresizingMaskIntoConstraints = NO;
    self.downloadCenterProgressLabel.font = [UIFont monospacedDigitSystemFontOfSize:12 weight:UIFontWeightMedium];
    self.downloadCenterProgressLabel.textColor = accentColor();
    self.downloadCenterProgressLabel.textAlignment = NSTextAlignmentRight;
    self.downloadCenterProgressLabel.text = @"0%";
    [self.downloadCenterButton addSubview:self.downloadCenterProgressLabel];
    
    // Play button (an FCL composite layout with the ZL2 press animation)
    self.launchButton = [UIButton buttonWithType:UIButtonTypeSystem];
    self.launchButton.translatesAutoresizingMaskIntoConstraints = NO;
    [self.launchButton setTitle:@"Play" forState:UIControlStateNormal];
    [self.launchButton setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    self.launchButton.titleLabel.font = [UIFont boldSystemFontOfSize:18];
    // The right panel is narrower on iPhone: the title font scales so long text such as "Downloading..." is not truncated
    self.launchButton.titleLabel.adjustsFontSizeToFitWidth = YES;
    self.launchButton.titleLabel.minimumScaleFactor = 0.6;
    self.launchButton.titleLabel.lineBreakMode = NSLineBreakByTruncatingTail;
    self.launchButton.backgroundColor = accentColor();
    self.launchButton.layer.cornerRadius = 10;
    self.launchButton.layer.masksToBounds = YES;
    // FCL style: a button shadow (an elevation effect) to add depth
    self.launchButton.layer.shadowColor = [UIColor blackColor].CGColor;
    self.launchButton.layer.shadowOffset = CGSizeMake(0, 2);
    self.launchButton.layer.shadowRadius = 4;
    self.launchButton.layer.shadowOpacity = 0.3;
    // masksToBounds clips the shadow, so backgroundColor + cornerRadius is used instead, which does not clip
    // but masksToBounds=YES is what makes the rounded background color work, so the shadow would need its own container view
    // Trade-off: keep masksToBounds=YES (the rounded corners matter more) and drop the shadow (UIButton has its own highlight on iOS)
    self.launchButton.layer.masksToBounds = YES;

    [self.launchButton addTarget:self action:@selector(launchButtonTapped) forControlEvents:UIControlEventTouchUpInside];
    // ZL2-style press animation: scale to 0.95 on press and back on release
    [self.launchButton addTarget:self action:@selector(launchButtonTouchDown) forControlEvents:UIControlEventTouchDown];
    [self.launchButton addTarget:self action:@selector(launchButtonTouchUp) forControlEvents:UIControlEventTouchUpOutside | UIControlEventTouchCancel];
    [self.view addSubview:self.launchButton];

    // JIT status label (above the play button)
    self.jitStatusLabel = [[UILabel alloc] init];
    self.jitStatusLabel.translatesAutoresizingMaskIntoConstraints = NO;
    self.jitStatusLabel.font = [UIFont systemFontOfSize:11 weight:UIFontWeightMedium];
    self.jitStatusLabel.textAlignment = NSTextAlignmentCenter;
    self.jitStatusLabel.layer.cornerRadius = 8;
    self.jitStatusLabel.layer.masksToBounds = YES;
    self.jitStatusLabel.text = @"JIT: checking...";
    [self.view addSubview:self.jitStatusLabel];

    // Version picker button (FCL style: the version picker lives on the right; control settings moved to the left menu, case 3)
    self.manageVersionBtn = [UIButton buttonWithType:UIButtonTypeSystem];
    self.manageVersionBtn.translatesAutoresizingMaskIntoConstraints = NO;
    [self.manageVersionBtn setTitle:@"Select version" forState:UIControlStateNormal];
    [self.manageVersionBtn setTitleColor:[UIColor labelColor] forState:UIControlStateNormal];
    [self.manageVersionBtn.titleLabel setFont:[UIFont systemFontOfSize:14 weight:UIFontWeightMedium]];
    self.manageVersionBtn.titleLabel.adjustsFontSizeToFitWidth = YES;
    self.manageVersionBtn.titleLabel.minimumScaleFactor = 0.7;
    self.manageVersionBtn.titleLabel.lineBreakMode = NSLineBreakByTruncatingTail;
    self.manageVersionBtn.backgroundColor = [UIColor colorWithWhite:0.2 alpha:1.0];
    self.manageVersionBtn.layer.cornerRadius = 10;
    [self.manageVersionBtn addTarget:self action:@selector(showVersionPicker) forControlEvents:UIControlEventTouchUpInside];
    [self.view addSubview:self.manageVersionBtn];

    // Execute JAR button
    self.executeJarBtn = [UIButton buttonWithType:UIButtonTypeSystem];
    self.executeJarBtn.translatesAutoresizingMaskIntoConstraints = NO;
    [self.executeJarBtn setTitle:@"Execute Jar" forState:UIControlStateNormal];
    [self.executeJarBtn setTitleColor:[UIColor labelColor] forState:UIControlStateNormal];
    self.executeJarBtn.titleLabel.adjustsFontSizeToFitWidth = YES;
    self.executeJarBtn.titleLabel.minimumScaleFactor = 0.7;
    self.executeJarBtn.titleLabel.lineBreakMode = NSLineBreakByTruncatingTail;
    self.executeJarBtn.backgroundColor = [UIColor colorWithWhite:0.2 alpha:1.0];
    self.executeJarBtn.layer.cornerRadius = 10;
    [self.executeJarBtn addTarget:self action:@selector(executeJar) forControlEvents:UIControlEventTouchUpInside];
    [self.view addSubview:self.executeJarBtn];
    
    // Constraint layout:
    // - the upper half (avatar/username/version/progress) is anchored downwards from the top
    // - the lower half (Execute Jar/version picker/JIT/play button) is anchored upwards from the bottom
    // so the JIT display and the play button sit at the bottom of the right panel, away from the avatar area and not crowded.
    [NSLayoutConstraint activateConstraints:@[
        // Avatar (top)
        [self.avatarImageView.topAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.topAnchor constant:16],
        [self.avatarImageView.centerXAnchor constraintEqualToAnchor:self.view.centerXAnchor],
        [self.avatarImageView.widthAnchor constraintEqualToConstant:72],
        [self.avatarImageView.heightAnchor constraintEqualToConstant:72],

        // Username
        [self.usernameLabel.topAnchor constraintEqualToAnchor:self.avatarImageView.bottomAnchor constant:8],
        [self.usernameLabel.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor constant:12],
        [self.usernameLabel.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor constant:-12],

        // Version
        [self.versionLabel.topAnchor constraintEqualToAnchor:self.usernameLabel.bottomAnchor constant:4],
        [self.versionLabel.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor constant:12],
        [self.versionLabel.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor constant:-12],

        // Progress label
        [self.progressLabel.topAnchor constraintEqualToAnchor:self.versionLabel.bottomAnchor constant:8],
        [self.progressLabel.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor constant:12],
        [self.progressLabel.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor constant:-12],

        // Progress bar
        [self.progressView.topAnchor constraintEqualToAnchor:self.progressLabel.bottomAnchor constant:4],
        [self.progressView.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor constant:12],
        [self.progressView.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor constant:-12],

        // ===== Download center entry button (below the progress bar) =====
        // Shown when there are downloads; tapping it presents DownloadTasksViewController (as in the download progress modals of FCL/ZL2/HMCL)
        [self.downloadCenterButton.topAnchor constraintEqualToAnchor:self.progressView.bottomAnchor constant:8],
        [self.downloadCenterButton.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor constant:12],
        [self.downloadCenterButton.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor constant:-12],
        [self.downloadCenterButton.heightAnchor constraintEqualToConstant:36],

        // Activity indicator (on the right of the button, vertically centered)
        [self.downloadCenterActivityIndicator.trailingAnchor constraintEqualToAnchor:self.downloadCenterButton.trailingAnchor constant:-12],
        [self.downloadCenterActivityIndicator.centerYAnchor constraintEqualToAnchor:self.downloadCenterButton.centerYAnchor],

        // Progress percentage label (to the left of the indicator, vertically centered)
        [self.downloadCenterProgressLabel.trailingAnchor constraintEqualToAnchor:self.downloadCenterActivityIndicator.leadingAnchor constant:-6],
        [self.downloadCenterProgressLabel.centerYAnchor constraintEqualToAnchor:self.downloadCenterButton.centerYAnchor],

        // ===== Lower button area (anchored upwards from the bottom of the safe area, as in the two-button row of FCL) =====
        // Execute Jar button (bottom row, left half)
        [self.executeJarBtn.bottomAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.bottomAnchor constant:-12],
        [self.executeJarBtn.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor constant:12],
        [self.executeJarBtn.heightAnchor constraintEqualToConstant:38],

        // Manage versions button (bottom row, right half, on the same row as Execute Jar)
        [self.manageVersionBtn.bottomAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.bottomAnchor constant:-12],
        [self.manageVersionBtn.leadingAnchor constraintEqualToAnchor:self.executeJarBtn.trailingAnchor constant:8],
        [self.manageVersionBtn.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor constant:-12],
        [self.manageVersionBtn.heightAnchor constraintEqualToConstant:38],

        // The two buttons are equally wide (half each, minus the 8pt gap between them)
        [self.executeJarBtn.widthAnchor constraintEqualToAnchor:self.manageVersionBtn.widthAnchor],

        // Play button (full width, above the two buttons)
        [self.launchButton.bottomAnchor constraintEqualToAnchor:self.executeJarBtn.topAnchor constant:-8],
        [self.launchButton.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor constant:12],
        [self.launchButton.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor constant:-12],
        [self.launchButton.heightAnchor constraintEqualToConstant:46],

        // JIT status label (above the play button)
        [self.jitStatusLabel.bottomAnchor constraintEqualToAnchor:self.launchButton.topAnchor constant:-8],
        [self.jitStatusLabel.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor constant:12],
        [self.jitStatusLabel.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor constant:-12],
        [self.jitStatusLabel.heightAnchor constraintEqualToConstant:20],
    ]];

    // Leave room below the progress bar so it does not overlap the JIT label underneath (a weak constraint, so a gap is allowed)
    [NSLayoutConstraint constraintWithItem:self.jitStatusLabel
                                attribute:NSLayoutAttributeTop
                                relatedBy:NSLayoutRelationGreaterThanOrEqual
                                   toItem:self.progressView
                                attribute:NSLayoutAttributeBottom
                               multiplier:1.0
                                 constant:12].active = YES;
}

#pragma mark - Actions

- (void)selectAccount:(UITapGestureRecognizer *)gesture {
    // The user is managing accounts deliberately (not coming from the play button), so any "pending launch" intent is cancelled,
    // to avoid unexpectedly launching the game after signing in.
    self.pendingLaunchAfterLogin = NO;
    // FCL style: account management is shown in the middle content area, so a notification tells LauncherRootViewController to switch content
    [[NSNotificationCenter defaultCenter] postNotificationName:@"ShowAccountManager" object:nil];
}

#pragma mark - Download center (modeled on the download progress dialogs of FCL/ZL2/HMCL)

/// Open the download center modal
/// Following how FCL/ZL2/HMCL show download progress: present DownloadTasksViewController as a FormSheet,
/// showing live progress for every download (the MC client/mods/shaders/resource packs/data packs/world saves/modpacks).
/// Everything registered with DownloadTaskManager appears here, giving one place to manage download progress.
- (void)openDownloadCenter {
    // If the download center is already up, return so it is not presented twice
    if (self.presentedDownloadCenterVC) {
        return;
    }

    // The user opened the download center deliberately, so reset the "user closed it" flag
    self.userDismissedDownloadCenter = NO;

    DownloadTasksViewController *downloadCenterVC = [[DownloadTasksViewController alloc] init];
    downloadCenterVC.modalPresentationStyle = UIModalPresentationFormSheet;
    // Do not cover the whole screen when presenting; a FormSheet is centered on iPad and near full-screen on iPhone
    downloadCenterVC.preferredContentSize = CGSizeMake(500, 600);

    // Held weakly, to avoid a retain cycle
    self.presentedDownloadCenterVC = downloadCenterVC;

    // Get the topmost view controller to present from
    UIViewController *topVC = self;
    while (topVC.presentedViewController) {
        topVC = topVC.presentedViewController;
    }

    [topVC presentViewController:downloadCenterVC animated:YES completion:nil];
}

/// Handle a download task update notification (a progress change, a new task registering, and so on)
/// On receiving one, only the download center button state is updated; the download center is no longer presented automatically.
///
/// Why this changed (fixing two progress displays appearing during a version download):
///   this method used to present DownloadTasksViewController (the download center) as soon as an active download was detected,
///   while the launcher itself presented DownloadProgressViewController from startDownloadWithVersion:
///   (the FCL/ZL2-style single-task progress), so both appeared at once.
///   It now follows FCL/ZL2/HMCL: DownloadProgressViewController appears automatically when a version download starts,
///   and DownloadTasksViewController is only opened manually (via the download center button).
- (void)handleDownloadTaskUpdate:(NSNotification *)notification {
    dispatch_async(dispatch_get_main_queue(), ^{
        [self updateDownloadCenterButton];
    });
}

/// Handle a download task completion notification
/// Update the button state when a task completes; once every task is done, hide the download center button after a delay
- (void)handleDownloadTaskCompleted:(NSNotification *)notification {
    dispatch_async(dispatch_get_main_queue(), ^{
        [self updateDownloadCenterButton];
    });
}

/// Handle the download center being closed by the user
/// Sets userDismissedDownloadCenter=YES, so later download updates do not keep reopening it.
/// The user can reopen it with the "Download center" button in the launcher (which resets the flag).
- (void)handleDownloadCenterDismissed {
    self.userDismissedDownloadCenter = YES;
    self.presentedDownloadCenterVC = nil;
}

/// Update the download center button state and progress percentage
/// Based on the current state of DownloadTaskManager:
/// - no tasks: hide the button
/// - active tasks (downloading/pending): show the button + spin the activity indicator + show the aggregate percentage
/// - all complete: show the button + stop the activity indicator + show "Completed"
- (void)updateDownloadCenterButton {
    DownloadTaskManager *manager = [DownloadTaskManager sharedManager];
    NSArray<DownloadTaskItem *> *allTasks = [manager allTasks];

    if (allTasks.count == 0) {
        // No downloads at all, so hide the download center button
        self.downloadCenterButton.hidden = YES;
        [self.downloadCenterActivityIndicator stopAnimating];
        return;
    }

    // There are downloads, so show the button
    self.downloadCenterButton.hidden = NO;

    // Compute the aggregate progress (the average across every active task)
    BOOL hasActive = NO;
    BOOL allCompleted = YES;
    double totalProgress = 0.0;
    NSInteger activeCount = 0;

    for (DownloadTaskItem *task in allTasks) {
        if (task.state == DownloadTaskStateDownloading || task.state == DownloadTaskStatePending) {
            hasActive = YES;
            allCompleted = NO;
            totalProgress += task.progress;
            activeCount++;
        } else if (task.state != DownloadTaskStateCompleted) {
            allCompleted = NO;
        }
    }

    if (hasActive) {
        // There are active downloads
        double avgProgress = activeCount > 0 ? totalProgress / activeCount : 0.0;
        NSInteger percent = (NSInteger)(avgProgress * 100.0 + 0.5);
        percent = MAX(0, MIN(100, percent));
        self.downloadCenterProgressLabel.text = [NSString stringWithFormat:@"%ld%%", (long)percent];
        [self.downloadCenterActivityIndicator startAnimating];
    } else if (allCompleted) {
        // All complete
        self.downloadCenterProgressLabel.text = @"Completed";
        [self.downloadCenterActivityIndicator stopAnimating];
    } else {
        // There are paused/failed/cancelled tasks but nothing active
        self.downloadCenterProgressLabel.text = @"Paused";
        [self.downloadCenterActivityIndicator stopAnimating];
    }
}

#pragma mark - Custom avatar import

- (void)showAvatarMenu:(UILongPressGestureRecognizer *)gesture {
    if (gesture.state != UIGestureRecognizerStateBegan) return;

    BaseAuthenticator *currentAuth = BaseAuthenticator.current;
    NSString *accountId = currentAuth.authData[@"accountId"];
    if (!accountId || accountId.length == 0) {
        [self showAlert:@"Not signed in" message:@"Sign in to an account before setting a custom avatar"];
        return;
    }

    BOOL hasCustom = [[AvatarManager sharedManager] hasCustomAvatarForAccount:accountId];

    UIAlertController *sheet = [UIAlertController alertControllerWithTitle:@"Custom avatar"
                                                                   message:nil
                                                            preferredStyle:UIAlertControllerStyleActionSheet];
    [sheet addAction:[UIAlertAction actionWithTitle:@"Import image from photo library" style:UIAlertActionStyleDefault handler:^(UIAlertAction * _Nonnull action) {
        [self openAvatarImagePicker];
    }]];
    if (hasCustom) {
        [sheet addAction:[UIAlertAction actionWithTitle:@"Clear custom avatar" style:UIAlertActionStyleDestructive handler:^(UIAlertAction * _Nonnull action) {
            [[AvatarManager sharedManager] removeAvatarForAccount:accountId];
            [self updateAccountInfo];
        }]];
    }
    [sheet addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];

    // iPad support: anchor the popover to the avatar
    if (sheet.popoverPresentationController) {
        sheet.popoverPresentationController.sourceView = self.avatarImageView;
        sheet.popoverPresentationController.sourceRect = self.avatarImageView.bounds;
    }
    [self presentViewController:sheet animated:YES completion:nil];
}

- (void)openAvatarImagePicker {
    // Prevent it being presented twice
    for (UIWindow *window in UIApplication.sharedApplication.windows) {
        for (UIView *view in window.subviews) {
            if ([view isKindOfClass:[UIImagePickerController class]]) return;
        }
    }
    UIImagePickerController *picker = [[UIImagePickerController alloc] init];
    picker.sourceType = UIImagePickerControllerSourceTypePhotoLibrary;
    picker.delegate = self;
    [self presentViewController:picker animated:YES completion:nil];
}

- (void)imagePickerController:(UIImagePickerController *)picker didFinishPickingMediaWithInfo:(NSDictionary<UIImagePickerControllerInfoKey,id> *)info {
    [picker dismissViewControllerAnimated:YES completion:^{
        dispatch_async(dispatch_get_main_queue(), ^{
            UIImage *selectedImage = info[UIImagePickerControllerOriginalImage];
            if (!selectedImage) {
                [self showAlert:@"Error" message:@"Could not read the selected image"];
                return;
            }
            // The avatar has to be square, so a non-square image is cropped
            if (selectedImage.size.width != selectedImage.size.height) {
                ImageCropperViewController *cropperVC = [[ImageCropperViewController alloc] initWithImage:selectedImage];
                __weak typeof(self) weakSelf = self;
                cropperVC.completionHandler = ^(UIImage * _Nullable croppedImage) {
                    [weakSelf dismissViewControllerAnimated:YES completion:^{
                        if (croppedImage) {
                            [weakSelf saveAvatarImage:croppedImage];
                        }
                    }];
                };
                // This VC is a child view controller, so self.navigationController may be nil,
                // and the cropper is therefore presented (wrapped in a NavigationController to keep its navigation bar style)
                UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:cropperVC];
                nav.modalPresentationStyle = UIModalPresentationFullScreen;
                [self presentViewController:nav animated:YES completion:nil];
            } else {
                [self saveAvatarImage:selectedImage];
            }
        });
    }];
}

- (void)imagePickerControllerDidCancel:(UIImagePickerController *)picker {
    [picker dismissViewControllerAnimated:YES completion:nil];
}

- (void)saveAvatarImage:(UIImage *)image {
    BaseAuthenticator *currentAuth = BaseAuthenticator.current;
    NSString *accountId = currentAuth.authData[@"accountId"];
    if (!accountId || accountId.length == 0) {
        [self showAlert:@"Error" message:@"No account is signed in, so the avatar cannot be saved"];
        return;
    }
    __weak typeof(self) weakSelf = self;
    [[AvatarManager sharedManager] saveAvatarForAccount:accountId image:image withCompletion:^(BOOL success, NSError * _Nullable error) {
        dispatch_async(dispatch_get_main_queue(), ^{
            if (success) {
                [weakSelf updateAccountInfo];
            } else {
                NSString *msg = error.localizedDescription ?: @"Failed to save the avatar";
                [weakSelf showAlert:@"Error" message:msg];
            }
        });
    }];
}

#pragma mark - JIT status display

- (void)updateJITStatus {
    if (!self.jitStatusLabel) return;
    BOOL enabled = isJITEnabled(NO);
    if (enabled) {
        self.jitStatusLabel.text = @"JIT: on";
        self.jitStatusLabel.textColor = [UIColor colorWithRed:0.2 green:0.7 blue:0.3 alpha:1.0];
        self.jitStatusLabel.backgroundColor = [[UIColor colorWithRed:0.2 green:0.7 blue:0.3 alpha:1.0] colorWithAlphaComponent:0.15];
    } else {
        self.jitStatusLabel.text = @"JIT: off";
        self.jitStatusLabel.textColor = [UIColor colorWithRed:0.9 green:0.4 blue:0.3 alpha:1.0];
        self.jitStatusLabel.backgroundColor = [[UIColor colorWithRed:0.9 green:0.4 blue:0.3 alpha:1.0] colorWithAlphaComponent:0.15];
    }
}

#pragma mark - Custom appearance (font color)

/// Read the general.text_color preference and apply it to the main text of the right panel.
/// The card background is always dark (BackgroundManager), so a user who sets a light card_color should set text_color too.
/// general.accent_color is also read here to refresh the play button theme color (the FCL-style theme accent).
- (void)applyCustomAppearance {
    // Theme accent color: refresh the play button background so the user's chosen color applies immediately
    self.launchButton.backgroundColor = accentColor();

    NSString *hex = getPrefObject(@"general.text_color");
    UIColor *customColor = [self colorFromHexString:hex];
    if (customColor) {
        self.usernameLabel.textColor = customColor;
        self.versionLabel.textColor = [customColor colorWithAlphaComponent:0.75];
        self.progressLabel.textColor = [customColor colorWithAlphaComponent:0.75];
        self.jitStatusLabel.textColor = customColor;
        [self.manageVersionBtn setTitleColor:customColor forState:UIControlStateNormal];
        [self.executeJarBtn setTitleColor:customColor forState:UIControlStateNormal];
    } else {
        // With no custom text color set, restore the system adaptive color
        self.usernameLabel.textColor = [UIColor labelColor];
        self.versionLabel.textColor = [UIColor secondaryLabelColor];
        self.progressLabel.textColor = [UIColor secondaryLabelColor];
        [self.manageVersionBtn setTitleColor:[UIColor labelColor] forState:UIControlStateNormal];
        [self.executeJarBtn setTitleColor:[UIColor labelColor] forState:UIControlStateNormal];
        // The JIT status color is managed separately by updateJITStatus and is not reset here
    }
}

- (nullable UIColor *)colorFromHexString:(id)hex {
    if (![hex isKindOfClass:[NSString class]] || [(NSString *)hex length] == 0) return nil;
    NSString *clean = [(NSString *)hex stringByReplacingOccurrencesOfString:@"#" withString:@""];
    if (clean.length != 6 && clean.length != 8) return nil;
    unsigned int rgb = 0;
    NSScanner *scanner = [NSScanner scannerWithString:clean];
    if (![scanner scanHexInt:&rgb]) return nil;
    unsigned int r, g, b, a;
    if (clean.length == 6) {
        // RRGGBB
        r = (rgb >> 16) & 0xFF;
        g = (rgb >> 8) & 0xFF;
        b = rgb & 0xFF;
        a = 255;
    } else {
        // AARRGGBB
        a = (rgb >> 24) & 0xFF;
        r = (rgb >> 16) & 0xFF;
        g = (rgb >> 8) & 0xFF;
        b = rgb & 0xFF;
    }
    return [UIColor colorWithRed:r / 255.0 green:g / 255.0 blue:b / 255.0 alpha:a / 255.0];
}

- (void)showVersionPicker {
    // FCL style: show an ActionSheet in the right panel so the user can pick an installed version
    NSDictionary *profiles = PLProfiles.current.profiles;
    NSArray *sortedNames = [[profiles allKeys] sortedArrayUsingSelector:@selector(localizedCaseInsensitiveCompare:)];
    NSString *currentSelected = PLProfiles.current.selectedProfileName;
    
    if (sortedNames.count == 0) {
        [self showAlert:@"No versions installed" message:@"Install a version from the download page first"];
        return;
    }
    
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Select version"
                                                                   message:nil
                                                            preferredStyle:UIAlertControllerStyleActionSheet];
    
    for (NSString *profileName in sortedNames) {
        NSDictionary *profile = profiles[profileName];
        NSString *versionId = profile[@"lastVersionId"] ?: @"";
        // Detect whether version isolation is enabled (gameDir != ".")
        NSString *gameDir = profile[@"gameDir"] ?: @".";
        BOOL isolated = ![gameDir isEqualToString:@"."];
        NSMutableString *title = [NSMutableString string];
        if ([profileName isEqualToString:currentSelected]) {
            [title appendString:@"✓ "];
        }
        [title appendString:profileName];
        [title appendFormat:@"  (%@)", versionId];
        if (isolated) {
            [title appendString:@"  · Isolated"];
        }
        [alert addAction:[UIAlertAction actionWithTitle:title
                                                  style:UIAlertActionStyleDefault
                                                handler:^(UIAlertAction * _Nonnull action) {
            [self selectProfile:profileName];
        }]];
    }
    
    [alert addAction:[UIAlertAction actionWithTitle:@"Manage versions" style:UIAlertActionStyleDefault handler:^(UIAlertAction * _Nonnull action) {
        // Go to the version manager page
        [[NSNotificationCenter defaultCenter] postNotificationName:@"ShowVersionManager" object:nil];
    }]];
    
    [alert addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    
    // On iPad an ActionSheet must be given a popoverPresentationController
    alert.popoverPresentationController.sourceView = self.manageVersionBtn;
    alert.popoverPresentationController.sourceRect = self.manageVersionBtn.bounds;
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)selectProfile:(NSString *)profileName {
    PLProfiles.current.selectedProfileName = profileName;
    [PLProfiles.current save];
    // The SelectedProfileChanged notification is already posted inside setSelectedProfileName
    [self updateVersionInfo];
}

- (void)showVersionManager {
    // Compatibility with older callers: go to the version manager page
    [[NSNotificationCenter defaultCenter] postNotificationName:@"ShowVersionManager" object:nil];
}

- (void)executeJar {
    // Execute JAR: open the file picker to choose a JAR file
    // asCopy:YES makes sure the file is copied into the app sandbox, so a security-scoped URL cannot make UZKArchive fail to read it
    // typeWithMIMEType: can return nil, and a nil inside an array literal throws at
    // runtime. Build the list defensively and always include a catch-all, so JARs that
    // report as public.data are still tappable instead of silently doing nothing.
    NSMutableArray<UTType *> *jarTypes = [NSMutableArray new];
    UTType *jarMIME = [UTType typeWithMIMEType:@"application/java-archive"];
    if (jarMIME) [jarTypes addObject:jarMIME];
    UTType *jarExt = [UTType typeWithFilenameExtension:@"jar"];
    if (jarExt) [jarTypes addObject:jarExt];
    [jarTypes addObjectsFromArray:@[UTTypeArchive, UTTypeData, UTTypeItem]];
    UIDocumentPickerViewController *picker = [[UIDocumentPickerViewController alloc]
        initForOpeningContentTypes:jarTypes
        asCopy:YES];
    picker.shouldShowFileExtensions = YES;
    picker.delegate = self;
    picker.allowsMultipleSelection = NO;
    [self presentViewController:picker animated:YES completion:nil];
}

#pragma mark - UIDocumentPickerDelegate

- (void)documentPicker:(UIDocumentPickerViewController *)controller didPickDocumentsAtURLs:(NSArray<NSURL *> *)urls {
    if (urls.count == 0) return;
    NSURL *jarURL = urls[0];
    [self enterModInstallerWithPath:jarURL.path hitEnterAfterWindowShown:NO];
}

- (void)documentPickerWasCancelled:(UIDocumentPickerViewController *)controller {
}

- (void)enterModInstallerWithPath:(NSString *)path hitEnterAfterWindowShown:(BOOL)hitEnter {
    JavaGUIViewController *vc = [[JavaGUIViewController alloc] init];
    vc.filepath = path;
    vc.hitEnterAfterWindowShown = hitEnter;
    // requiredJavaVersion reads the MANIFEST.MF of the JAR to resolve the main class
    int javaVersion = vc.requiredJavaVersion;
    if (!javaVersion) {
        // JAR parsing failed: vc has not been presented yet so showDialog would not appear, hence an explicit alert on self here
        [self showAlert:@"Cannot execute the JAR"
                  message:[NSString stringWithFormat:@"Could not parse the JAR file: %@\n\nPossible causes:\n• The file is not a valid Java archive\n• META-INF/MANIFEST.MF is missing\n• The Main-Class attribute is missing\n• The file is corrupted", path.lastPathComponent ?: @""]];
        return;
    }

    // The execute_jar path: the Caciocavallo17 jar is now consistently compiled for Java 17,
    // so both Java 17 and 21 can load it and requiredJavaVersion no longer has to be forced up to 25.
    // - Java 8 JARs (such as the OptiFine installer) take the Caciocavallo (non-17) path and use Java 8
    // - Java 17+ JARs take the Caciocavallo17 path and can use Java 17 or 21
    // This matches the launchJar branch in JavaLauncher.m.
    int requiredJavaVersion = javaVersion;

    // Check up front whether a JRE is configured for the execute_jar tag, so a missing JRE is not discovered after presenting and left as a black screen
    NSString *javaHome = getSelectedJavaHome(@"execute_jar", requiredJavaVersion);
    if (!javaHome) {
        [self showAlert:@"Missing Java runtime"
                  message:[NSString stringWithFormat:@"Running this JAR requires Java %d or later, but no matching runtime is configured.\n\nGo to Settings → Manage runtimes and assign a Java %d+ runtime to the \"Execute Jar\" tag.", requiredJavaVersion, requiredJavaVersion]];
        return;
    }

    [self invokeAfterJITEnabled:^{
        vc.modalPresentationStyle = UIModalPresentationFullScreen;
        NSLog(@"[ModInstaller] launching %@ (Java %d, home=%@)", vc.filepath, requiredJavaVersion, javaHome);
        [self presentViewController:vc animated:YES completion:nil];
    }];
}

/// Show a simple alert
- (void)showAlert:(NSString *)title message:(NSString *)message {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:title
                                                                    message:message
                                                             preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
}

#pragma mark - Launch Game

/// ZL2-style press animation: scale to 0.95 on press
- (void)launchButtonTouchDown {
    [UIView animateWithDuration:0.1
                          delay:0
                        options:UIViewAnimationOptionCurveEaseIn
                     animations:^{
        self.launchButton.transform = CGAffineTransformMakeScale(0.95, 0.95);
    } completion:nil];
}

/// ZL2-style press animation: back to 1.0 on release
- (void)launchButtonTouchUp {
    [UIView animateWithDuration:0.1
                          delay:0
                        options:UIViewAnimationOptionCurveEaseOut
                     animations:^{
        self.launchButton.transform = CGAffineTransformIdentity;
    } completion:nil];
}

- (void)launchButtonTapped {
    // Restore the press animation (TouchUpInside does not fire launchButtonTouchUp)
    [UIView animateWithDuration:0.1
                          delay:0
                        options:UIViewAnimationOptionCurveEaseOut
                     animations:^{
        self.launchButton.transform = CGAffineTransformIdentity;
    } completion:nil];

    if (self.task) {
        // A download is running, so show the details (the floating button is gone)
        if (!self.progressVC) {
            self.progressVC = [[DownloadProgressViewController alloc] initWithTask:self.task];
        }
        UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:self.progressVC];
        nav.modalPresentationStyle = UIModalPresentationFormSheet;
        [self presentViewController:nav animated:YES completion:nil];
    } else if ([[DownloadTaskManager sharedManager] hasActiveTasks]) {
        // Launching is still allowed during a download (no hard block), the user is just told a download is in progress.
        // The original implementation returned here, so "once the download ball was enabled, any unfinished download blocked launching forever",
        // and a stuck download state machine could make launching impossible permanently.
        [self showAlert:@"Notice" message:@"A download is in progress, which may affect launching the game."];
        [self launchGame];
    } else {
        [self launchGame];
    }
}

- (void)launchGame {
    // Downloads no longer block launching. Some downloads (mods, shaders) have nothing to do with starting the game itself,
    // so forcing the user to wait made launching feel slow or impossible.
    BaseAuthenticator *currentAuth = BaseAuthenticator.current;
    if (!currentAuth) {
        // FCL style: with no account, go to the account management screen and continue launching once sign-in finishes.
        // The old behavior was an alert saying "Please sign in first" followed by a return, so the user had to sign in and come back,
        // which was unfriendly. It now sets the pendingLaunchAfterLogin flag and posts a ShowAccountManager notification,
        // so when the UpdateAccountInfo notification comes back here after a successful sign-in, launchGame fires automatically.
        self.pendingLaunchAfterLogin = YES;
        [[NSNotificationCenter defaultCenter] postNotificationName:@"ShowAccountManager" object:nil];
        return;
    }

    // A normal launch, so clear the pending-launch flag
    self.pendingLaunchAfterLogin = NO;

    NSString *selectedProfile = PLProfiles.current.selectedProfileName;
    if (!selectedProfile) {
        [self showAlert:@"Select a version first"];
        return;
    }

    NSString *versionId = PLProfiles.current.profiles[selectedProfile][@"lastVersionId"];
    if (!versionId) {
        [self showAlert:@"Could not fetch version information"];
        return;
    }

    // FCL style: record the last-played timestamp in the profile, for the version manager page to show
    NSMutableDictionary *profiles = PLProfiles.current.profiles;
    NSMutableDictionary *profile = [profiles[selectedProfile] mutableCopy];
    if (profile) {
        profile[@"lastPlayed"] = @([[NSDate date] timeIntervalSince1970]);
        profiles[selectedProfile] = profile;
        [PLProfiles.current save];
    }

    // Put the UI into the downloading state
    [self setInteractionEnabled:NO];
    
    // Find the version object
    NSDictionary *versionObject = nil;
    
    // Look in the remote version list (through remoteVersionList on LauncherRootViewController)
    // Since remoteVersionList lives on LauncherRootViewController, it has to be reached another way
    // A notification is used here to request the version information
    NSMutableDictionary *userInfo = [NSMutableDictionary dictionary];
    userInfo[@"versionId"] = versionId;
    userInfo[@"callback"] = ^(NSDictionary *version) {
        if (version) {
            [self startDownloadWithVersion:version profileName:selectedProfile];
        } else {
            // If it is not in the remote list, it may be a local version
            dispatch_async(dispatch_get_main_queue(), ^{
                [self setInteractionEnabled:YES];
                [self showAlert:@"Version information not found. Check that the version is correct"];
            });
        }
    };
    
    [[NSNotificationCenter defaultCenter] postNotificationName:@"FindVersionInRemoteList" object:nil userInfo:userInfo];
}

- (void)startDownloadWithVersion:(NSDictionary *)versionObject profileName:(NSString *)profileName {
    self.task = [MinecraftResourceDownloadTask new];

    __weak LauncherRightPanelViewController *weakSelf = self;

    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        weakSelf.task.handleError = ^{
            dispatch_async(dispatch_get_main_queue(), ^{
                [weakSelf setInteractionEnabled:YES];
                // Key fix (cumulative UI glitch): handleError did not remove the KVO observer,
                // so after task.progress was freed the KVO still pointed at a dead object and repeated launches crashed on a dangling pointer.
                // The KVO is now removed before task = nil.
                @try {
                    [weakSelf.task.progress removeObserver:weakSelf
                                                forKeyPath:@"fractionCompleted"
                                                   context:ProgressObserverContext];
                } @catch (NSException *e) {}
                weakSelf.progressView.observedProgress = nil;
                weakSelf.task = nil;
                weakSelf.progressVC = nil;
            });
        };

        [weakSelf.task downloadVersion:versionObject];

        dispatch_async(dispatch_get_main_queue(), ^{
            weakSelf.progressView.observedProgress = weakSelf.task.progress;
            [weakSelf.task.progress addObserver:weakSelf
                                    forKeyPath:@"fractionCompleted"
                                       options:NSKeyValueObservingOptionInitial
                                       context:ProgressObserverContext];

            // Present the FCL/ZL2-style single-task progress dialog automatically (as FCL does when a download starts)
            // DownloadTasksViewController (the download center) used to be presented automatically from a DownloadTaskManager notification,
            // so two progress displays appeared at once. DownloadProgressViewController is now used consistently.
            if (!weakSelf.progressVC) {
                weakSelf.progressVC = [[DownloadProgressViewController alloc] initWithTask:weakSelf.task];
            }
            UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:weakSelf.progressVC];
            nav.modalPresentationStyle = UIModalPresentationFormSheet;
            // Check whether a modal is already up, so an important one (such as account sign-in) is not covered
            UIViewController *topVC = weakSelf;
            while (topVC.presentedViewController) {
                topVC = topVC.presentedViewController;
            }
            if (!topVC.presentedViewController) {
                [topVC presentViewController:nav animated:YES completion:nil];
            }
        });
    });
}

- (void)setInteractionEnabled:(BOOL)enabled {
    self.manageVersionBtn.enabled = enabled;
    self.executeJarBtn.enabled = enabled;

    // The integrity check/download before launching always shows progress (an HMCL-style progress bar plus text),
    // It is no longer hidden by the floating button setting. The floating button (the percentage in its center) and this progress bar complement each other,
    // so the user sees exactly the same integrity check progress before launching.
    BOOL showProgressUI = YES;
    if (enabled) {
        self.progressView.hidden = YES;
        self.progressLabel.hidden = YES;
        self.progressLabel.text = @"";
    } else {
        self.progressView.hidden = !showProgressUI;
        self.progressLabel.hidden = !showProgressUI;
        self.progressLabel.text = showProgressUI ? @"Preparing..." : @"";
    }

    UIApplication.sharedApplication.idleTimerDisabled = !enabled;
    [self updateLaunchButtonState];
}

- (void)updateLaunchButtonState {
    BOOL hasActiveTasks = [[DownloadTaskManager sharedManager] hasActiveTasks];
    BOOL hasAccount = (BaseAuthenticator.current != nil);
    NSString *selectedProfile = PLProfiles.current.selectedProfileName;
    BOOL hasVersion = selectedProfile && PLProfiles.current.profiles[selectedProfile][@"lastVersionId"] != nil;
    // FCL style: the button stays tappable with no account, and tapping it opens account management (the launch continues automatically after signing in).
    // hasAccount used to take part in the disabled check, so with no account the button was completely untappable and "tapping play did nothing at all".
    // The button is now tappable with no account and its title changes to "Sign in and play", telling the user they will sign in first.
    BOOL enabled = hasVersion && !self.task;

    self.launchButton.enabled = enabled;
    NSString *title;
    if (hasActiveTasks) {
        title = @"Play (downloading)";
    } else if (!hasAccount) {
        title = @"Sign in and play";
    } else {
        title = @"Play";
    }
    [self.launchButton setTitle:title forState:UIControlStateNormal];
}

- (void)observeValueForKeyPath:(NSString *)keyPath ofObject:(id)object change:(NSDictionary *)change context:(void *)context {
    if (context != ProgressObserverContext) {
        [super observeValueForKeyPath:keyPath ofObject:object change:change context:context];
        return;
    }
    
    // Compute the download speed and time remaining
    static CGFloat lastMsTime;
    static NSUInteger lastSecTime, lastCompletedUnitCount;
    NSProgress *progress = self.task.textProgress;
    struct timeval tv;
    gettimeofday(&tv, NULL);
    NSInteger completedUnitCount = self.task.progress.totalUnitCount * self.task.progress.fractionCompleted;
    progress.completedUnitCount = completedUnitCount;
    if (lastSecTime < tv.tv_sec) {
        CGFloat currentTime = tv.tv_sec + tv.tv_usec / 1000000.0;
        NSInteger throughput = (completedUnitCount - lastCompletedUnitCount) / (currentTime - lastMsTime);
        progress.throughput = @(throughput);
        progress.estimatedTimeRemaining = @((progress.totalUnitCount - completedUnitCount) / throughput);
        lastCompletedUnitCount = completedUnitCount;
        lastSecTime = tv.tv_sec;
        lastMsTime = currentTime;
    }
    
    dispatch_async(dispatch_get_main_queue(), ^{
        // The integrity check/download before launching always shows progress (an HMCL-style progress bar plus text),
        // and is no longer hidden by the floating button setting. The floating button (the percentage in its center) and this progress bar complement each other,
        // so the user sees exactly the same integrity check progress before launching.
        BOOL showProgressUI = YES;
        if (showProgressUI) {
            self.progressLabel.text = progress.localizedAdditionalDescription;
        }

        if (!progress.finished) return;

        // Key fix (cumulative UI glitch): the KVO observer was not removed when the progress finished,
        // so after each download it stayed attached to a freed task.progress and repeated launches eventually crashed.
        // The KVO is now removed as soon as the task finishes (whether or not the game launches).
        @try {
            [self.task.progress removeObserver:self
                                    forKeyPath:@"fractionCompleted"
                                       context:ProgressObserverContext];
        } @catch (NSException *e) {}

        [self.progressVC dismissViewControllerAnimated:NO completion:nil];

        self.progressView.observedProgress = nil;
        
        if (self.task.metadata) {
            // Apply the profile-specific settings
            NSString *profileName = PLProfiles.current.selectedProfileName;
            NSDictionary *profile = PLProfiles.current.profiles[profileName];
            
            if (profile) {
                // Apply the renderer setting
                NSString *renderer = profile[@"renderer"] ?: @"auto";
                if (![renderer isEqualToString:@"auto"]) {
                    setPrefString(@"video.renderer", renderer);
                }

                // Apply the graphics API setting (in-game OpenGL/Vulkan switching on MC 26.2+)
                // JavaLauncher.m reads it and sets the AMETHYST_GRAPHICS_API environment variable,
                // and PojavLauncher.java writes the graphicsApi field into options.txt
                NSString *graphicsApi = profile[@"graphicsApi"];
                if (graphicsApi.length > 0) {
                    setPrefString(@"video.graphics_api", graphicsApi);
                }

                // Apply the Java version setting (handling the NSDictionary format written by older direct installers)
                id javaVerRaw = profile[@"javaVersion"];
                NSString *javaVer = nil;
                if ([javaVerRaw isKindOfClass:[NSDictionary class]]) {
                    id major = javaVerRaw[@"majorVersion"];
                    javaVer = major ? [major description] : @"auto";
                } else if ([javaVerRaw isKindOfClass:[NSString class]]) {
                    javaVer = javaVerRaw;
                } else {
                    javaVer = @"auto";
                }
                if (![javaVer isEqualToString:@"auto"]) {
                    setPrefString(@"java.java_version", javaVer);
                }
                
                // Apply the memory setting
                NSInteger allocatedMemory = [profile[@"allocatedMemory"] integerValue];
                if (allocatedMemory > 0) {
                    setPrefInt(@"general.ram_allocation", (int)allocatedMemory);
                }
            }
            
            [self invokeAfterJITEnabled:^{
                if (!UIKit_launchMinecraftSurfaceVC(self.view.window, self.task.metadata)) {
                    // Refused before starting, with the reason already shown. Put the launcher back
                    // the way it was rather than leaving the buttons disabled behind a dialog.
                    self.task = nil;
                    [self setInteractionEnabled:YES];
                    [[NSNotificationCenter defaultCenter] postNotificationName:@"ReloadProfileList" object:nil];
                }
            }];
        } else {
            self.task = nil;
            [self setInteractionEnabled:YES];
            // Notify listeners to refresh the version list
            [[NSNotificationCenter defaultCenter] postNotificationName:@"ReloadProfileList" object:nil];
        }
    });
}

- (void)invokeAfterJITEnabled:(void(^)(void))handler {
    BOOL hasTrollStoreJIT = getEntitlementValue(@"jb.pmap_cs.custom_trust");
    
    if (isJITEnabled(false)) {
        [ALTServerManager.sharedManager stopDiscovering];
        handler();
        return;
    } else if (hasTrollStoreJIT) {
        NSURL *jitURL = [NSURL URLWithString:[NSString stringWithFormat:@"apple-magnifier://enable-jit?bundle-id=%@", NSBundle.mainBundle.bundleIdentifier]];
        [UIApplication.sharedApplication openURL:jitURL options:@{} completionHandler:nil];
    } else if (getPrefBool(@"debug.debug_skip_wait_jit")) {
        NSLog(@"Debug option skipped waiting for JIT. Java might not work.");
        handler();
        return;
    } else if (@available(iOS 17.4, *)) {
        NSString *scriptDataString = @"";
        if (DeviceNeedsDebugJITMapping()) {
            NSData *scriptData = [NSData dataWithContentsOfFile:[NSBundle.mainBundle.bundlePath stringByAppendingPathComponent:@"UniversalJIT26.js"]];
            scriptDataString = [@"&script-data=" stringByAppendingString:[scriptData base64EncodedStringWithOptions:0]];
        }
        [UIApplication.sharedApplication openURL:[NSURL URLWithString:[NSString stringWithFormat:@"stikjit://enable-jit?bundle-id=%@&pid=%d%@", NSBundle.mainBundle.bundleIdentifier, getpid(), scriptDataString]] options:@{} completionHandler:nil];
    } else {
        // Assuming 16.7-17.3.1. SideStore still lacks this URL scheme at the time of writing, so it only jumps to SideStore.
        [UIApplication.sharedApplication openURL:[NSURL URLWithString:[NSString stringWithFormat:@"sidestore://sidejit-enable?pid=%d", getpid()]] options:@{} completionHandler:nil];
    }
    
    self.progressLabel.text = @"Waiting for JIT...";
    
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Waiting for JIT"
                                                                   message:hasTrollStoreJIT ? @"Enabling JIT through TrollStore..." : @"Please enable JIT"
                                                            preferredStyle:UIAlertControllerStyleAlert];
    [self presentViewController:alert animated:YES completion:nil];
    
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        while (!isJITEnabled(false)) {
            usleep(1000 * 200);
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            [alert dismissViewControllerAnimated:YES completion:handler];
        });
    });
}

- (void)showAlert:(NSString *)message {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Notice"
                                                                   message:message
                                                            preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
}

#pragma mark - Data Updates

- (void)updateAccountInfo {
    BaseAuthenticator *currentAuth = BaseAuthenticator.current;
    if (currentAuth && currentAuth.authData) {
        NSString *username = currentAuth.authData[@"username"];
        if (username) {
            if ([username hasPrefix:@"Demo."]) {
                username = [username substringFromIndex:5];
            }
            self.usernameLabel.text = username;
        }

        // Load the avatar: a local custom avatar wins, falling back to the online URL
        // The avatar file name uses accountId (a unique identifier), so accounts with the same name no longer clash
        UIImage *localAvatar = [[AvatarManager sharedManager] avatarForAccount:currentAuth.authData[@"accountId"]];
        if (localAvatar) {
            self.avatarImageView.image = localAvatar;
        } else {
            NSString *avatarURL = currentAuth.authData[@"profilePicURL"];
            if (avatarURL) {
                avatarURL = [avatarURL stringByReplacingOccurrencesOfString:@"\\/" withString:@"/"];
                dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
                    NSData *imageData = [NSData dataWithContentsOfURL:[NSURL URLWithString:avatarURL]];
                    if (imageData) {
                        UIImage *image = [UIImage imageWithData:imageData];
                        dispatch_async(dispatch_get_main_queue(), ^{
                            self.avatarImageView.image = image;
                        });
                    }
                });
            }
        }
    } else {
        self.usernameLabel.text = @"Not signed in";
        self.avatarImageView.image = [UIImage systemImageNamed:@"person.circle.fill"];
    }

    [self updateLaunchButtonState];

    // FCL style: if the user reached sign-in from "Play" (pendingLaunchAfterLogin=YES)
    // and the account is ready, continue launching automatically.
    if (self.pendingLaunchAfterLogin && BaseAuthenticator.current != nil) {
        self.pendingLaunchAfterLogin = NO;
        [self launchGame];
    }
}

- (void)updateVersionInfo {
    NSString *selectedProfile = PLProfiles.current.selectedProfileName;
    if (selectedProfile) {
        NSDictionary *profile = PLProfiles.current.profiles[selectedProfile];
        if (profile) {
            NSString *versionId = profile[@"lastVersionId"] ?: @"unknown";
            // Show the version isolation state: gameDir != "." means it is isolated
            NSString *gameDir = profile[@"gameDir"] ?: @".";
            BOOL isolated = ![gameDir isEqualToString:@"."];
            if (isolated) {
                self.versionLabel.text = [NSString stringWithFormat:@"%@  · Isolated", versionId];
            } else {
                self.versionLabel.text = versionId;
            }
        }
    } else {
        self.versionLabel.text = @"No version selected";
    }

    [self updateLaunchButtonState];
}

#pragma mark - Orientation

- (BOOL)shouldAutorotate {
    return YES;
}

- (UIInterfaceOrientationMask)supportedInterfaceOrientations {
    return UIInterfaceOrientationMaskLandscape;
}

@end