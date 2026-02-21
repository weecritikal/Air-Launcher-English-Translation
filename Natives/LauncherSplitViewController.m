#import "LauncherSplitViewController.h"
#import "LauncherMenuViewController.h"
#import "LauncherNewsViewController.h"
#import "LauncherProfilesViewController.h"
#import "LauncherNavigationController.h"
#import "LauncherPreferences.h"
#import "utils.h"
#import "BackgroundManager.h"

extern NSMutableDictionary *prefDict;

@interface LauncherSplitViewController ()<UISplitViewControllerDelegate>
@end

@implementation LauncherSplitViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    
    // Set transparent background to show global background
    self.view.backgroundColor = [UIColor clearColor];
    
    if ([getPrefObject(@"control.control_safe_area") length] == 0) {
        setPrefObject(@"control.control_safe_area", NSStringFromUIEdgeInsets(getDefaultSafeArea()));
    }

    self.delegate = self;

    UINavigationController *masterVc = [[UINavigationController alloc] initWithRootViewController:[[LauncherMenuViewController alloc] init]];
    LauncherNavigationController *detailVc = [[LauncherNavigationController alloc] initWithRootViewController:[[LauncherNewsViewController alloc] init]];
    detailVc.toolbarHidden = NO;

    self.viewControllers = @[masterVc, detailVc];
    [self changeDisplayModeForSize:self.view.frame.size];
    
    self.maximumPrimaryColumnWidth = self.view.bounds.size.width * 0.95;
    
    // Apply global background to this split view controller
    [[BackgroundManager sharedManager] applyBackgroundToSplitViewController:self];
    
    // Listen for background change notifications
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(backgroundChanged:)
                                                 name:@"BackgroundChanged"
                                               object:nil];
                                             
    // Listen for navigation changes to ensure transparency
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(navigationControllerDidShow:)
                                                 name:@"UINavigationControllerDidShowViewControllerNotification"
                                               object:nil];
}

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

- (void)navigationControllerDidShow:(NSNotification *)notification {
    // Ensure transparency is maintained when navigating
    if ([[BackgroundManager sharedManager] hasBackground]) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [[BackgroundManager sharedManager] makeSplitViewControllerTransparent:self];
        });
    }
}

- (void)applyBackground {
    [[BackgroundManager sharedManager] applyBackgroundToSplitViewController:self];
}

- (void)backgroundChanged:(NSNotification *)notification {
    // Reapply background when changed
    [[BackgroundManager sharedManager] applyBackgroundToSplitViewController:self];
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    
    // Resume video background
    [[BackgroundManager sharedManager] resumeVideo];
    
    // Ensure transparency
    if ([[BackgroundManager sharedManager] hasBackground]) {
        [[BackgroundManager sharedManager] makeSplitViewControllerTransparent:self];
    }
}

- (void)viewWillDisappear:(BOOL)animated {
    [super viewWillDisappear:animated];
    // Pause video to save resources
    [[BackgroundManager sharedManager] pauseVideo];
}

- (void)viewWillTransitionToSize:(CGSize)size withTransitionCoordinator:(id<UIViewControllerTransitionCoordinator>)coordinator {
    [super viewWillTransitionToSize:size withTransitionCoordinator:coordinator];
    [self changeDisplayModeForSize:size];
    
    // Update background frame on rotation
    [coordinator animateAlongsideTransition:^(id<UIViewControllerTransitionCoordinatorContext> context) {
        [[BackgroundManager sharedManager] updateBackgroundFrame];
    } completion:nil];
}

- (void)splitViewController:(UISplitViewController *)svc willChangeToDisplayMode:(UISplitViewControllerDisplayMode)displayMode {
    if (self.preferredDisplayMode != displayMode && self.displayMode != UISplitViewControllerDisplayModeSecondaryOnly) {
        dispatch_async(dispatch_get_main_queue(), ^{
            self.preferredDisplayMode = UISplitViewControllerDisplayModeSecondaryOnly;
        });
    }
}

- (void)changeDisplayModeForSize:(CGSize)size {
    BOOL isPortrait = size.height > size.width;
    if (self.preferredDisplayMode == 0 || self.displayMode != UISplitViewControllerDisplayModeSecondaryOnly) {
        if(!getPrefBool(@"general.hidden_sidebar")) {
            self.preferredDisplayMode = isPortrait ?
                UISplitViewControllerDisplayModeOneOverSecondary :
                UISplitViewControllerDisplayModeOneBesideSecondary;
        } else {
            self.preferredDisplayMode = UISplitViewControllerDisplayModeSecondaryOnly;
        }
    }
    self.preferredSplitBehavior = isPortrait ?
        UISplitViewControllerSplitBehaviorOverlay :
        UISplitViewControllerSplitBehaviorTile;
}

- (void)dismissViewController {
    [self dismissViewControllerAnimated:YES completion:nil];
}

@end
