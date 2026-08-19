#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>
#import "authenticator/BaseAuthenticator.h"
#import "AFNetworking.h"
#import "ALTServerConnection.h"
#import "CustomControlsViewController.h"
#import "DownloadProgressViewController.h"
#import "DownloadTasksViewController.h"
#import "DownloadTaskManager.h"
#import "DownloadTaskItem.h"
#import "JavaGUIViewController.h"
#import "LauncherMenuViewController.h"
#import "LauncherNavigationController.h"
#import "LauncherPreferences.h"
#import "MinecraftResourceDownloadTask.h"
#import "MinecraftResourceUtils.h"
#import "PickTextField.h"
#import "PLPickerView.h"
#import "PLProfiles.h"
#import "UIKit+AFNetworking.h"
#import "UIKit+hook.h"
#import "ios_uikit_bridge.h"
#import "utils.h"
#import "installer/modpack/ModrinthAPI.h"

#include <sys/time.h>

#define AUTORESIZE_MASKS UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleLeftMargin | UIViewAutoresizingFlexibleRightMargin

static void *ProgressObserverContext = &ProgressObserverContext;

@interface LauncherNavigationController () <UIDocumentPickerDelegate, UIPickerViewDataSource, PLPickerViewDelegate, UIPopoverPresentationControllerDelegate> {
}

@property(nonatomic) MinecraftResourceDownloadTask* task;
@property(nonatomic) DownloadProgressViewController* progressVC;
@property(nonatomic) PLPickerView* versionPickerView;
@property(nonatomic) UITextField* versionTextField;
@property(nonatomic) int profileSelectedAt;

// ===== Download center entry point (modelled on the download progress modals of FCL/ZL2/HMCL) =====
// Adds a "Download center" button to the toolbar which opens DownloadTasksViewController,
// showing the progress of every download in one place (the MC client/mods/shaders/resource packs/data packs/world saves/modpacks).
// Every download registered with DownloadTaskManager reports its progress through this modal.
@property(nonatomic, strong) UIButton *downloadCenterButton;
@property(nonatomic, strong) UIActivityIndicatorView *downloadCenterActivityIndicator;
@property(nonatomic, strong) UILabel *downloadCenterProgressLabel;
@property(nonatomic, weak) DownloadTasksViewController *presentedDownloadCenterVC;
// Tracks whether the user closed the download center by hand (so it does not keep reopening on every download update)
@property(nonatomic, assign) BOOL userDismissedDownloadCenter;

@end

@implementation LauncherNavigationController

- (void)viewDidLoad
{
    [super viewDidLoad];

    if ([self respondsToSelector:@selector(setNeedsUpdateOfScreenEdgesDeferringSystemGestures)]) {
        [self setNeedsUpdateOfScreenEdgesDeferringSystemGestures];
    }

    self.versionTextField = [[PickTextField alloc] initWithFrame:CGRectMake(4, 4, self.toolbar.frame.size.width * 0.8 - 8, self.toolbar.frame.size.height - 8)];
    [self.versionTextField addTarget:self.versionTextField action:@selector(resignFirstResponder) forControlEvents:UIControlEventEditingDidEndOnExit];
    self.versionTextField.autoresizingMask = AUTORESIZE_MASKS;
    self.versionTextField.placeholder = @"Specify version...";
    self.versionTextField.leftView = [[UIImageView alloc] initWithFrame:CGRectMake(0, 0, 40, 40)];
    self.versionTextField.rightView = [[UIImageView alloc] initWithImage:[[UIImage imageNamed:@"SpinnerArrow"] _imageWithSize:CGSizeMake(30, 30)]];
    self.versionTextField.rightView.frame = CGRectMake(0, 0, self.versionTextField.frame.size.height * 0.9, self.versionTextField.frame.size.height * 0.9);
    self.versionTextField.leftViewMode = UITextFieldViewModeAlways;
    self.versionTextField.rightViewMode = UITextFieldViewModeAlways;
    self.versionTextField.textAlignment = NSTextAlignmentCenter;

    self.versionPickerView = [[PLPickerView alloc] init];
    self.versionPickerView.delegate = self;
    self.versionPickerView.dataSource = self;
    UIToolbar *versionPickToolbar = [[UIToolbar alloc] initWithFrame:CGRectMake(0.0, 0.0, self.view.frame.size.width, 44.0)];

    [self reloadProfileList];

    // Listen for the profile list refresh notification
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(reloadProfileList)
                                                 name:@"ReloadProfileList"
                                               object:nil];

    UIBarButtonItem *versionFlexibleSpace = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemFlexibleSpace target:self action:nil];
    UIBarButtonItem *versionDoneButton = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemDone target:self action:@selector(versionClosePicker)];
    versionPickToolbar.items = @[versionFlexibleSpace, versionDoneButton];
    self.versionTextField.inputAccessoryView = versionPickToolbar;
    self.versionTextField.inputView = self.versionPickerView;

    UIView *targetToolbar = self.toolbar;
    [targetToolbar addSubview:self.versionTextField];

    self.progressViewMain = [[UIProgressView alloc] initWithFrame:CGRectMake(0, 0, self.toolbar.frame.size.width, 4)];
    self.progressViewMain.autoresizingMask = AUTORESIZE_MASKS;
    self.progressViewMain.hidden = YES;
    [targetToolbar addSubview:self.progressViewMain];

    self.buttonInstall = [UIButton buttonWithType:UIButtonTypeSystem];
    setButtonPointerInteraction(self.buttonInstall);
    [self.buttonInstall setTitle:localize(@"Play", nil) forState:UIControlStateNormal];
    self.buttonInstall.autoresizingMask = AUTORESIZE_MASKS;
    self.buttonInstall.backgroundColor = [UIColor colorWithRed:121/255.0 green:56/255.0 blue:162/255.0 alpha:1.0];
    self.buttonInstall.layer.cornerRadius = 5;
    self.buttonInstall.frame = CGRectMake(self.toolbar.frame.size.width * 0.8, 4, self.toolbar.frame.size.width * 0.2, self.toolbar.frame.size.height - 8);
    self.buttonInstall.tintColor = UIColor.whiteColor;
    self.buttonInstall.enabled = NO;
    [self.buttonInstall addTarget:self action:@selector(performInstallOrShowDetails:) forControlEvents:UIControlEventPrimaryActionTriggered];
    [targetToolbar addSubview:self.buttonInstall];

    self.progressText = [[UILabel alloc] initWithFrame:self.versionTextField.frame];
    self.progressText.adjustsFontSizeToFitWidth = YES;
    self.progressText.autoresizingMask = AUTORESIZE_MASKS;
    self.progressText.font = [self.progressText.font fontWithSize:16];
    self.progressText.textAlignment = NSTextAlignmentCenter;
    self.progressText.userInteractionEnabled = NO;
    [targetToolbar addSubview:self.progressText];

    // ===== Download center entry button (modelled on the download progress modals of FCL/ZL2/HMCL) =====
    // Add a "Download center" button on the left of the toolbar, shown whenever there are downloads;
    // tapping it presents DownloadTasksViewController (as a FormSheet) with the progress of every download.
    // Button layout: [icon] [progress percentage] [activity indicator]
    CGFloat dcBtnWidth = 72.0;
    CGFloat dcBtnHeight = self.toolbar.frame.size.height - 8;
    self.downloadCenterButton = [UIButton buttonWithType:UIButtonTypeSystem];
    // The button title is not used for the text; a separate progressLabel avoids clashing with the icon layout
    self.downloadCenterButton.tintColor = [UIColor whiteColor];
    self.downloadCenterButton.backgroundColor = [UIColor colorWithRed:121/255.0 green:56/255.0 blue:162/255.0 alpha:0.85];
    self.downloadCenterButton.layer.cornerRadius = 5;
    self.downloadCenterButton.frame = CGRectMake(4, 4, dcBtnWidth, dcBtnHeight);
    self.downloadCenterButton.autoresizingMask = UIViewAutoresizingFlexibleRightMargin;
    [self.downloadCenterButton setImage:[UIImage systemImageNamed:@"arrow.down.circle"] forState:UIControlStateNormal];
    // The icon is pinned to the left of the button
    CGFloat iconSize = 22.0;
    [self.downloadCenterButton setImageEdgeInsets:UIEdgeInsetsMake(0, 4, 0, dcBtnWidth - iconSize - 4)];
    [self.downloadCenterButton addTarget:self action:@selector(openDownloadCenter) forControlEvents:UIControlEventTouchUpInside];
    self.downloadCenterButton.hidden = YES;
    [targetToolbar addSubview:self.downloadCenterButton];

    // Activity indicator (on the right of the button, spinning while downloading)
    self.downloadCenterActivityIndicator = [[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleMedium];
    self.downloadCenterActivityIndicator.color = [UIColor whiteColor];
    self.downloadCenterActivityIndicator.hidesWhenStopped = YES;
    CGFloat indicatorSize = 20.0;
    self.downloadCenterActivityIndicator.frame = CGRectMake(dcBtnWidth - indicatorSize - 4, (dcBtnHeight - indicatorSize) / 2.0, indicatorSize, indicatorSize);
    self.downloadCenterActivityIndicator.autoresizingMask = UIViewAutoresizingFlexibleLeftMargin;
    [self.downloadCenterButton addSubview:self.downloadCenterActivityIndicator];

    // Progress percentage label (in the middle of the button, showing the aggregate progress)
    self.downloadCenterProgressLabel = [[UILabel alloc] init];
    self.downloadCenterProgressLabel.font = [UIFont monospacedDigitSystemFontOfSize:11 weight:UIFontWeightBold];
    self.downloadCenterProgressLabel.textColor = [UIColor whiteColor];
    self.downloadCenterProgressLabel.textAlignment = NSTextAlignmentCenter;
    self.downloadCenterProgressLabel.text = @"";
    self.downloadCenterProgressLabel.frame = CGRectMake(iconSize + 6, 0, dcBtnWidth - iconSize - indicatorSize - 12, dcBtnHeight);
    self.downloadCenterProgressLabel.autoresizingMask = UIViewAutoresizingFlexibleWidth;
    [self.downloadCenterButton addSubview:self.downloadCenterProgressLabel];

    [self fetchRemoteVersionList];
    [NSNotificationCenter.defaultCenter addObserver:self
        selector:@selector(receiveNotification:)
        name:@"InstallModpack"
        object:nil];

    // ===== Download center notification observers =====
    // Listen for DownloadTaskManager notifications, so that when a new download registers or progress updates:
    // 1. the download center button state and progress percentage are updated
    // 2. the download center is presented automatically (unless the user closed it by hand or another modal is showing)
    // This makes sure mods, shaders, resource packs and every other download report progress through the download center.
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(handleDownloadTaskUpdate:)
                                                 name:DownloadTaskManagerDidUpdateTaskNotification
                                               object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(handleDownloadTaskCompleted:)
                                                 name:DownloadTaskManagerTaskCompletedNotification
                                               object:nil];
    // Listen for the download center being closed by hand, and set the flag so it does not keep reopening
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(handleDownloadCenterDismissed)
                                                 name:@"DownloadCenterDidDismiss"
                                               object:nil];

    if ([BaseAuthenticator.current isKindOfClass:MicrosoftAuthenticator.class]) {
        // Perform token refreshment on startup
        [self setInteractionEnabled:NO forDownloading:NO];
        id callback = ^(id status, BOOL success) {
            status = [status description];
            self.progressText.text = status;
            if (status == nil) {
                [self setInteractionEnabled:YES forDownloading:NO];
            } else if (!success) {
                showDialog(localize(@"Error", nil), status);
            }
        };
        [BaseAuthenticator.current refreshTokenWithCallback:callback];
    }
}

- (BOOL)isVersionInstalled:(NSString *)versionId {
    NSString *localPath = [NSString stringWithFormat:@"%s/versions/%@", getenv("POJAV_GAME_DIR"), versionId];
    BOOL isDirectory;
    [NSFileManager.defaultManager fileExistsAtPath:localPath isDirectory:&isDirectory];
    return isDirectory;
}

- (void)fetchLocalVersionList {
    if (!localVersionList) {
        localVersionList = [NSMutableArray new];
    }
    [localVersionList removeAllObjects];

    NSFileManager *fileManager = [NSFileManager defaultManager];
    NSString *versionPath = [NSString stringWithFormat:@"%s/versions/", getenv("POJAV_GAME_DIR")];
    NSArray *list = [fileManager contentsOfDirectoryAtPath:versionPath error:Nil];
    for (NSString *versionId in list) {
        if (![self isVersionInstalled:versionId]) continue;
        [localVersionList addObject:@{
            @"id": versionId,
            @"type": @"custom"
        }];
    }
}

- (void)fetchRemoteVersionList {
    self.buttonInstall.enabled = NO;
    remoteVersionList = @[
        @{@"id": @"latest-release", @"type": @"release"},
        @{@"id": @"latest-snapshot", @"type": @"snapshot"}
    ].mutableCopy;

    AFHTTPSessionManager *manager = [AFHTTPSessionManager manager];
    // Configure the response serializer to accept application/octet-stream
    AFJSONResponseSerializer *serializer = [AFJSONResponseSerializer serializer];
    [serializer setAcceptableContentTypes:[NSSet setWithObjects:@"application/json", @"text/json", @"text/javascript", @"application/octet-stream", nil]];
    manager.responseSerializer = serializer;
    NSString *downloadSource = getPrefObject(@"general.download_source");
    NSString *versionManifestURL;
    
    if ([downloadSource isEqualToString:@"bmclapi"]) {
        versionManifestURL = @"https://bmclapi2.bangbang93.com/mc/game/version_manifest_v2.json";
    } else {
        versionManifestURL = @"https://piston-meta.mojang.com/mc/game/version_manifest_v2.json";
    }
    
    [manager GET:versionManifestURL parameters:nil headers:nil progress:^(NSProgress * _Nonnull progress) {
        // The AFNetworking progress callback runs on a background thread, so UI updates must be dispatched to the main thread,
        // otherwise it triggers the "modifying the autolayout engine from a background thread" crash
        dispatch_async(dispatch_get_main_queue(), ^{
            self.progressViewMain.progress = progress.fractionCompleted;
        });
    } success:^(NSURLSessionTask *task, NSDictionary *responseObject) {
        [remoteVersionList addObjectsFromArray:responseObject[@"versions"]];
        NSDebugLog(@"[VersionList] Got %d versions", remoteVersionList.count);
        setPrefObject(@"internal.latest_version", responseObject[@"latest"]);
        self.buttonInstall.enabled = YES;
    } failure:^(NSURLSessionTask *operation, NSError *error) {
        NSDebugLog(@"[VersionList] Warning: Unable to fetch version list: %@", error.localizedDescription);
        self.buttonInstall.enabled = YES;
    }];
}

- (void)fetchRemoteVersionListForce:(BOOL)force {
    // Call fetchRemoteVersionList directly, ignoring the force parameter
    [self fetchRemoteVersionList];
}

// Invoked by: startup, instance change event
- (void)reloadProfileList {
    // Reload local version list
    [self fetchLocalVersionList];
    // Reload launcher_profiles.json
    [PLProfiles updateCurrent];
    [self.versionPickerView reloadAllComponents];
    // Reload selected profile info
    self.profileSelectedAt = [PLProfiles.current.profiles.allKeys indexOfObject:PLProfiles.current.selectedProfileName];
    if (self.profileSelectedAt == -1) {
        // This instance has no profiles?
        return;
    }
    [self.versionPickerView selectRow:self.profileSelectedAt inComponent:0 animated:NO];
    [self pickerView:self.versionPickerView didSelectRow:self.profileSelectedAt inComponent:0];
}

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
    // Key fix (KVO leak): remove the KVO observer as a safety net.
    // In the normal flow it is removed when the download completes or errors, but if the VC is released mid-download (e.g. leaving the launcher),
    // the KVO observer points at a freed object and crashes on a dangling pointer.
    if (self.task && self.task.progress) {
        @try {
            [self.task.progress removeObserver:self
                                    forKeyPath:@"fractionCompleted"
                                       context:ProgressObserverContext];
        } @catch (NSException *e) {}
    }
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
///   while the launcher itself presented DownloadProgressViewController in launchMinecraft:
///   (the FCL/ZL2-style single-task progress), so both appeared at once.
///   It now follows FCL/ZL2/HMCL: DownloadProgressViewController appears automatically when a version download starts,
///   and DownloadTasksViewController is only opened manually (via the download center button).
- (void)handleDownloadTaskUpdate:(NSNotification *)notification {
    dispatch_async(dispatch_get_main_queue(), ^{
        [self updateDownloadCenterButton];
    });
}

/// Handle a download task completion notification
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
- (void)updateDownloadCenterButton {
    DownloadTaskManager *manager = [DownloadTaskManager sharedManager];
    NSArray<DownloadTaskItem *> *allTasks = [manager allTasks];

    if (allTasks.count == 0) {
        self.downloadCenterButton.hidden = YES;
        [self.downloadCenterActivityIndicator stopAnimating];
        return;
    }

    self.downloadCenterButton.hidden = NO;

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
        double avgProgress = activeCount > 0 ? totalProgress / activeCount : 0.0;
        NSInteger percent = (NSInteger)(avgProgress * 100.0 + 0.5);
        percent = MAX(0, MIN(100, percent));
        self.downloadCenterProgressLabel.text = [NSString stringWithFormat:@"%ld%%", (long)percent];
        [self.downloadCenterActivityIndicator startAnimating];
    } else if (allCompleted) {
        self.downloadCenterProgressLabel.text = @"Done";
        [self.downloadCenterActivityIndicator stopAnimating];
    } else {
        self.downloadCenterProgressLabel.text = @"Pause";
        [self.downloadCenterActivityIndicator stopAnimating];
    }
}

#pragma mark - Options
- (void)enterCustomControls {
    CustomControlsViewController *vc = [[CustomControlsViewController alloc] init];
    vc.modalPresentationStyle = UIModalPresentationOverFullScreen;
    vc.setDefaultCtrl = ^(NSString *name){
        setPrefObject(@"control.default_ctrl", name);
    };
    vc.getDefaultCtrl = ^{
        return getPrefObject(@"control.default_ctrl");
    };
    [self presentViewController:vc animated:YES completion:nil];
}

- (void)enterModInstaller {
    // typeWithMIMEType: can return nil, and a nil inside an array literal throws at
    // runtime. Build the list defensively and always include a catch-all, so JARs that
    // report as public.data (common for files from Safari or third-party providers)
    // are still tappable instead of silently doing nothing.
    NSMutableArray<UTType *> *jarTypes = [NSMutableArray new];
    UTType *jarMIME = [UTType typeWithMIMEType:@"application/java-archive"];
    if (jarMIME) [jarTypes addObject:jarMIME];
    UTType *jarExt = [UTType typeWithFilenameExtension:@"jar"];
    if (jarExt) [jarTypes addObject:jarExt];
    [jarTypes addObjectsFromArray:@[UTTypeArchive, UTTypeData, UTTypeItem]];
    UIDocumentPickerViewController *documentPicker = [[UIDocumentPickerViewController alloc]
        initForOpeningContentTypes:jarTypes
        asCopy:YES];
    documentPicker.shouldShowFileExtensions = YES;
    documentPicker.delegate = self;
    documentPicker.modalPresentationStyle = UIModalPresentationFormSheet;
    [self presentViewController:documentPicker animated:YES completion:nil];
}



- (void)enterModInstallerWithPath:(NSString *)path hitEnterAfterWindowShown:(BOOL)hitEnter {
    JavaGUIViewController *vc = [[JavaGUIViewController alloc] init];
    vc.filepath = path;
    vc.hitEnterAfterWindowShown = hitEnter;
    if (!vc.requiredJavaVersion) {
        // Report parse failures (a missing manifest or an invalid main class) explicitly, instead of returning silently and letting the user think the installer started
        showDialog(localize(@"Error", nil),
            [NSString stringWithFormat:@"Could not determine the installer main class or Java version: %@", path.lastPathComponent]);
        return;
    }
    // The execute_jar path: the Caciocavallo17 jar is now consistently compiled for Java 17,
    // so both Java 17 and 21 can load it and requiredJavaVersion no longer has to be forced up to 25.
    // - Java 8 JARs (such as the OptiFine installer) take the Caciocavallo (non-17) path and use Java 8
    // - Java 17+ JARs take the Caciocavallo17 path and can use Java 17 or 21
    // This matches the launchJar branch in JavaLauncher.m.
    int requiredJavaVersion = vc.requiredJavaVersion;
    // Check up front whether a JRE is configured for the execute_jar tag, so a missing JRE is not discovered after presenting and left as a black screen
    // This matches the behavior of LauncherRightPanelViewController.enterModInstallerWithPath:
    NSString *javaHome = getSelectedJavaHome(@"execute_jar", requiredJavaVersion);
    if (!javaHome) {
        showDialog(localize(@"Error", nil),
            [NSString stringWithFormat:@"Running this JAR requires Java %d or later, but no matching runtime is configured.\n\nGo to Settings → Manage runtimes and assign a Java %d+ runtime to the \"Execute Jar\" tag.", requiredJavaVersion, requiredJavaVersion]);
        return;
    }
    [self invokeAfterJITEnabled:^{
        vc.modalPresentationStyle = UIModalPresentationFullScreen;
        NSLog(@"[ModInstaller] launching %@", vc.filepath);
        [self presentViewController:vc animated:YES completion:nil];
    }];
}

- (void)documentPicker:(UIDocumentPickerViewController *)controller didPickDocumentAtURL:(NSURL *)url {
    // Handle normal jar file import
    [self enterModInstallerWithPath:url.path hitEnterAfterWindowShown:NO];
}

- (void)setInteractionEnabled:(BOOL)enabled forDownloading:(BOOL)downloading {
    for (UIControl *view in self.toolbar.subviews) {
        if ([view isKindOfClass:UIControl.class]) {
            view.alpha = enabled ? 1 : 0.2;
            view.enabled = enabled;
        }
    }
    // The integrity check/download before launching always shows progress (an HMCL-style progress bar plus text),
    // and is no longer hidden by the floating button setting, so the user sees the whole integrity check before launch.
    BOOL showProgressUI = YES;
    self.progressViewMain.hidden = enabled || !showProgressUI;
    if (!showProgressUI) {
        self.progressText.text = nil;
    }
    if (downloading) {
        [self.buttonInstall setTitle:localize(enabled ? @"Play" : @"Details", nil) forState:UIControlStateNormal];
        self.buttonInstall.alpha = 1;
        self.buttonInstall.enabled = YES;
    }
    UIApplication.sharedApplication.idleTimerDisabled = !enabled;
}

- (void)launchMinecraft:(UIButton *)sender {
    if (!self.versionTextField.hasText) {
        [self.versionTextField becomeFirstResponder];
        return;
    }

    if (BaseAuthenticator.current == nil) {
        // Present the account selector if none selected
        UIViewController *view = [(UINavigationController *)self.splitViewController.viewControllers[0]
        viewControllers][0];
        [view performSelector:@selector(selectAccount:) withObject:sender];
        return;
    }

    [self setInteractionEnabled:NO forDownloading:YES];

    NSString *versionId = PLProfiles.current.profiles[self.versionTextField.text][@"lastVersionId"];
    NSDictionary *object = [remoteVersionList filteredArrayUsingPredicate:[NSPredicate predicateWithFormat:@"(id == %@)", versionId]].firstObject;
    if (!object) {
        object = @{
            @"id": versionId,
            @"type": @"custom"
        };
    }

    self.task = [MinecraftResourceDownloadTask new];
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        __weak LauncherNavigationController *weakSelf = self;
        self.task.handleError = ^{
            dispatch_async(dispatch_get_main_queue(), ^{
                [weakSelf setInteractionEnabled:YES forDownloading:YES];
                // Key fix (KVO leak): on error the KVO observer must be removed before the task is set to nil,
                // otherwise task.progress still holds a KVO observer on self and the next download adds a duplicate.
                @try {
                    [weakSelf.task.progress removeObserver:weakSelf
                                                forKeyPath:@"fractionCompleted"
                                                   context:ProgressObserverContext];
                } @catch (NSException *e) {}
                weakSelf.task = nil;
                weakSelf.progressVC = nil;
            });
        };
        [self.task downloadVersion:object];
        dispatch_async(dispatch_get_main_queue(), ^{
            self.progressViewMain.observedProgress = self.task.progress;
            [self.task.progress addObserver:self
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

- (void)performInstallOrShowDetails:(UIButton *)sender {
    if (self.task) {
        // Show the download progress details (the floating button is gone)
        if (!self.progressVC) {
            self.progressVC = [[DownloadProgressViewController alloc] initWithTask:self.task];
        }
        UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:self.progressVC];
        nav.modalPresentationStyle = UIModalPresentationPopover;
        nav.popoverPresentationController.sourceView = sender;
        [self presentViewController:nav animated:YES completion:nil];
    } else {
        [self launchMinecraft:sender];
    }
}

- (void)observeValueForKeyPath:(NSString *)keyPath ofObject:(id)object change:(NSDictionary *)change context:(void *)context {
    if (context != ProgressObserverContext) {
        [super observeValueForKeyPath:keyPath ofObject:object change:change context:context];
        return;
    }

    // Calculate download speed and ETA
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
        // The integrity check/download before launching always shows progress (an HMCL-style progress bar plus text)
        BOOL showProgressUI = YES;
        if (showProgressUI) {
            self.progressText.text = progress.localizedAdditionalDescription;
        }

        if (!progress.finished) return;
        [self.progressVC dismissViewControllerAnimated:NO completion:nil];

        self.progressViewMain.observedProgress = nil;
        // Key fix (KVO leak): remove the KVO observer when the download completes.
        // It was not removed before, so every download piled another observer onto self.task.progress,
        // and after several downloads a progress change fired observeValueForKeyPath repeatedly and the UI misbehaved.
        @try {
            [self.task.progress removeObserver:self
                                    forKeyPath:@"fractionCompleted"
                                       context:ProgressObserverContext];
        } @catch (NSException *e) {}
        if (self.task.metadata) {
            [self invokeAfterJITEnabled:^{
                if (!UIKit_launchMinecraftSurfaceVC(self.view.window, self.task.metadata)) {
                    // Refused before starting, with the reason already shown. Put the launcher back
                    // the way it was rather than leaving the buttons disabled behind a dialog.
                    self.task = nil;
                    [self setInteractionEnabled:YES forDownloading:YES];
                    [self reloadProfileList];
                }
            }];
        } else {
            self.task = nil;
            [self setInteractionEnabled:YES forDownloading:YES];
            [self reloadProfileList];
        }
    });
}

- (void)receiveNotification:(NSNotification *)notification {
    if (![notification.name isEqualToString:@"InstallModpack"]) {
        return;
    }
    [self setInteractionEnabled:NO forDownloading:YES];
    self.task = [MinecraftResourceDownloadTask new];
    NSDictionary *userInfo = notification.userInfo;
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        __weak LauncherNavigationController *weakSelf = self;
        self.task.handleError = ^{
            dispatch_async(dispatch_get_main_queue(), ^{
                [weakSelf setInteractionEnabled:YES forDownloading:YES];
                // Key fix (KVO leak): remove the KVO observer on error too, matching the launchMinecraft flow
                @try {
                    [weakSelf.task.progress removeObserver:weakSelf
                                                forKeyPath:@"fractionCompleted"
                                                   context:ProgressObserverContext];
                } @catch (NSException *e) {}
                weakSelf.task = nil;
                weakSelf.progressVC = nil;
            });
        };
        [self.task downloadModpackFromAPI:notification.object detail:userInfo[@"detail"] atIndex:[userInfo[@"index"] unsignedLongValue]];
        dispatch_async(dispatch_get_main_queue(), ^{
            self.progressViewMain.observedProgress = self.task.progress;
            [self.task.progress addObserver:self
                forKeyPath:@"fractionCompleted"
                options:NSKeyValueObservingOptionInitial
                context:ProgressObserverContext];
        });
    });
}

- (void)invokeAfterJITEnabled:(void(^)(void))handler {
    // Note: do not clear localVersionList/remoteVersionList here.
    // This method is called both by JAR execution and by a normal game launch; clearing them would leave the user with an empty version list
    // and briefly disable buttonInstall after returning. The lifetime of the version list belongs to reloadProfileList.
    BOOL hasTrollStoreJIT = getEntitlementValue(@"jb.pmap_cs.custom_trust");

    if (isJITEnabled(false)) {
        [ALTServerManager.sharedManager stopDiscovering];
        handler();
        return;
    } else if (hasTrollStoreJIT) {
        NSURL *jitURL = [NSURL URLWithString:[NSString stringWithFormat:@"apple-magnifier://enable-jit?bundle-id=%@", NSBundle.mainBundle.bundleIdentifier]];
        [UIApplication.sharedApplication openURL:jitURL options:@{} completionHandler:nil];
        // Do not return, wait for TrollStore to enable JIT and jump back
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

    self.progressText.text = localize(@"launcher.wait_jit.title", nil);

    UIAlertController* alert = [UIAlertController alertControllerWithTitle:localize(@"launcher.wait_jit.title", nil)
        message:hasTrollStoreJIT ? localize(@"launcher.wait_jit_trollstore.message", nil) : localize(@"launcher.wait_jit.message", nil)
        preferredStyle:UIAlertControllerStyleAlert];
/* TODO:
    UIAlertAction *cancel = [UIAlertAction actionWithTitle:localize(@"Cancel", nil) style:UIAlertActionStyleCancel handler:^{
        
    }];
    [alert addAction:cancel];
*/
    [self presentViewController:alert animated:YES completion:nil];

    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        while (!isJITEnabled(false)) {
            // Perform check for every 200ms
            usleep(1000*200);
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            [alert dismissViewControllerAnimated:YES completion:handler];
        });
    });
}

#pragma mark - UIPopoverPresentationControllerDelegate
- (UIModalPresentationStyle)adaptivePresentationStyleForPresentationController:(UIPresentationController *)controller traitCollection:(UITraitCollection *)traitCollection {
    return UIModalPresentationNone;
}

#pragma mark - UIPickerView stuff
- (void)pickerView:(PLPickerView *)pickerView didSelectRow:(NSInteger)row inComponent:(NSInteger)component {
    self.profileSelectedAt = row;
    //((UIImageView *)self.versionTextField.leftView).image = [pickerView imageAtRow:row column:component];
    ((UIImageView *)self.versionTextField.leftView).image = [pickerView imageAtRow:row column:component];
    self.versionTextField.text = [self pickerView:pickerView titleForRow:row forComponent:component];
    PLProfiles.current.selectedProfileName = self.versionTextField.text;
}

- (NSInteger)numberOfComponentsInPickerView:(UIPickerView *)pickerView {
    return 1;
}

- (NSInteger)pickerView:(UIPickerView *)pickerView numberOfRowsInComponent:(NSInteger)component {
    return PLProfiles.current.profiles.count;
}

- (NSString *)pickerView:(UIPickerView *)pickerView titleForRow:(NSInteger)row forComponent:(NSInteger)component {
    return PLProfiles.current.profiles.allValues[row][@"name"];
}

- (void)pickerView:(UIPickerView *)pickerView enumerateImageView:(UIImageView *)imageView forRow:(NSInteger)row forComponent:(NSInteger)component {
    UIImage *fallbackImage = [[UIImage imageNamed:@"DefaultProfile"] _imageWithSize:CGSizeMake(40, 40)];
    NSString *urlString = PLProfiles.current.profiles.allValues[row][@"icon"];
    [imageView setImageWithURL:[NSURL URLWithString:urlString] placeholderImage:fallbackImage];
}

- (void)versionClosePicker {
    [self.versionTextField endEditing:YES];
    [self pickerView:self.versionPickerView didSelectRow:[self.versionPickerView selectedRowInComponent:0] inComponent:0];
}

#pragma mark - View controller UI mode

- (BOOL)prefersHomeIndicatorAutoHidden {
    return YES;
}

- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    // Post a notification to update the account information
    [[NSNotificationCenter defaultCenter] postNotificationName:@"UpdateAccountInfo" object:nil];
}

@end
