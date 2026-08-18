#import "CustomControlsViewController.h"
#import "LauncherPreferences.h"
#import "LauncherPreferencesViewController.h"
#import "PLProfiles.h"
#import "SurfaceViewController.h"
#import "GameMenuOverlayView.h"
#import "TrackedTextField.h"
#import "utils.h"
#import "ScreenUtils.h"
// ZeroTier/Terracotta multiplayer temporarily removed (while a startup crash is investigated)
// #import "MultiplayerViewController.h"
// #import "MultiplayerManager.h"
// #import "TerracottaViewController.h"
#import <objc/runtime.h>

// Expose the private properties from the class extension for use by the category
@interface SurfaceViewController()
@property(nonatomic) TrackedTextField *inputTextField;
@property(nonatomic) BOOL toggleHidden;
- (void)updateControlHiddenState:(BOOL)hide;
@end

// A category cannot store ivars, so menuDimView is implemented with an associated object
static const void *kMenuDimViewKey = &kMenuDimViewKey;

@interface SurfaceViewController(Navigation)
// Background dimming layer for the FCL-style menu (translucent black, tap to close the menu)
@property(nonatomic) UIView *menuDimView;
@end

@implementation SurfaceViewController(Navigation)

- (void)setMenuDimView:(UIView *)menuDimView {
    objc_setAssociatedObject(self, kMenuDimViewKey, menuDimView, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

- (UIView *)menuDimView {
    return objc_getAssociatedObject(self, kMenuDimViewKey);
}

- (void)initCategory_Navigation {
    // FCL Android style: the menu pops up from the bottom and the game view is not scaled down
    // Modeled on the bottom pop-up menu style of FCL GameMenu.java / GameMenuView.kt
    self.menuArray = @[
        @"game.menu.force_close",          // Force close
        @"game.menu.log_output",            // Log output
        @"game.menu.custom_controls",       // Control layout editor
        @"game.menu.multiplayer",           // Multiplayer (Terracotta; switchable to ZeroTier from the top-right corner)
        @"game.menu.toggle_stats",          // FPS/memory display toggle
        @"game.menu.toggle_controls",       // Hide/show control buttons
        @"game.menu.toggle_virtual_mouse",  // Virtual mouse toggle
        @"game.menu.toggle_keyboard",       // In-game keyboard
        @"game.menu.resolution",            // Resolution adjustment
        @"Settings"                         // Settings
    ];

    // FCL style: the menu pops up from the bottom, its width is 70% of the screen width (centered), and its maximum height is 60% of the screen height
    CGFloat screenWidth = [ScreenUtils screenSize].width;
    CGFloat screenHeight = [ScreenUtils screenSize].height;
    CGFloat menuWidth = MIN(screenWidth * 0.7, 400);
    CGFloat menuMaxHeight = screenHeight * 0.6;
    CGFloat menuEstimatedHeight = self.menuArray.count * 48 + 16;
    CGFloat menuHeight = MIN(menuEstimatedHeight, menuMaxHeight);

    self.menuView = [[UITableView alloc] initWithFrame:CGRectMake(
        (screenWidth - menuWidth) / 2.0,
        screenHeight,  // Initially placed off the bottom of the screen (slides up during the animation)
        menuWidth,
        menuHeight
    ) style:UITableViewStylePlain];

    self.menuView.dataSource = self;
    self.menuView.delegate = self;
    self.menuView.hidden = YES;
    self.menuView.layer.cornerRadius = 16;
    self.menuView.clipsToBounds = YES;
    self.menuView.scrollEnabled = YES;
    self.menuView.separatorInset = UIEdgeInsetsMake(0, 16, 0, 16);
    // FCL style: translucent dark background
    self.menuView.backgroundColor = [UIColor colorWithDynamicProvider:^UIColor * _Nonnull(UITraitCollection * _Nonnull traitCollection) {
        return [UIColor colorWithRed:28.0/255.0 green:28.0/255.0 blue:30.0/255.0 alpha:0.95];
    }];
    // Add a shadow
    self.menuView.layer.shadowColor = [UIColor blackColor].CGColor;
    self.menuView.layer.shadowOffset = CGSizeMake(0, -2);
    self.menuView.layer.shadowRadius = 12;
    self.menuView.layer.shadowOpacity = 0.4;
    [self.view addSubview:self.menuView];

    // FCL style: translucent background dimming layer (tap to close the menu)
    self.menuDimView = [[UIView alloc] initWithFrame:self.view.bounds];
    self.menuDimView.backgroundColor = [UIColor colorWithRed:0 green:0 blue:0 alpha:0.4];
    self.menuDimView.alpha = 0;
    self.menuDimView.hidden = YES;
    UITapGestureRecognizer *dimTap = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(dismissMenu)];
    dimTap.cancelsTouchesInView = YES;
    [self.menuDimView addGestureRecognizer:dimTap];
    [self.view addSubview:self.menuDimView];
    // Make sure the menu sits above the dimming layer
    [self.view bringSubviewToFront:self.menuView];

    // FCL/ZL2 style floating button + FPS/memory display
    GameMenuOverlayView *overlay = [[GameMenuOverlayView alloc] initWithParentView:self.view];
    __weak typeof(self) weakSelf = self;
    overlay.onMenuButtonTapped = ^{
        [weakSelf toggleMenu];
    };
    self.gameMenuOverlay = overlay;
}

/// Toggle the menu visibility (triggered by tapping the floating button)
- (void)toggleMenu {
    if (self.menuView.hidden) {
        [self showMenu];
    } else {
        [self dismissMenu];
    }
}

/// FCL style: pop the menu up from the bottom (the game view is not scaled down)
- (void)showMenu {
    self.menuView.hidden = NO;
    self.menuDimView.hidden = NO;

    // Prepare the animation start state: the menu sits off the bottom of the screen
    CGFloat screenHeight = [ScreenUtils screenSize].height;
    CGFloat menuHeight = self.menuView.frame.size.height;
    self.menuView.transform = CGAffineTransformIdentity;
    self.menuView.frame = CGRectMake(
        self.menuView.frame.origin.x,
        screenHeight,  // Off the bottom of the screen
        self.menuView.frame.size.width,
        menuHeight
    );

    // Compute the target position: pops up from the bottom, leaving room for the safe area
    CGFloat safeBottom = [ScreenUtils safeAreaBottom];
    CGFloat targetY = screenHeight - menuHeight - safeBottom - 16;

    [UIView animateWithDuration:0.3
                          delay:0
         usingSpringWithDamping:0.85
          initialSpringVelocity:0.5
                        options:UIViewAnimationOptionCurveEaseOut
                     animations:^{
        // Slide the menu up to its target position
        self.menuView.frame = CGRectMake(
            self.menuView.frame.origin.x,
            targetY,
            self.menuView.frame.size.width,
            menuHeight
        );
        // Fade in the background dimming layer
        self.menuDimView.alpha = 1.0;
    } completion:^(BOOL finished) {
        [self setNeedsUpdateOfHomeIndicatorAutoHidden];
        [self setNeedsUpdateOfScreenEdgesDeferringSystemGestures];
        [self setNeedsStatusBarAppearanceUpdate];
    }];
}

/// FCL style: the menu slides down and disappears (the game view is not scaled down)
- (void)dismissMenu {
    CGFloat screenHeight = [ScreenUtils screenSize].height;

    [UIView animateWithDuration:0.25
                          delay:0
                        options:UIViewAnimationOptionCurveEaseIn
                     animations:^{
        // Slide the menu down to off the bottom of the screen
        self.menuView.frame = CGRectMake(
            self.menuView.frame.origin.x,
            screenHeight,
            self.menuView.frame.size.width,
            self.menuView.frame.size.height
        );
        // Fade out the background dimming layer
        self.menuDimView.alpha = 0.0;
    } completion:^(BOOL finished) {
        self.menuView.hidden = YES;
        self.menuDimView.hidden = YES;
        [self setNeedsUpdateOfHomeIndicatorAutoHidden];
        [self setNeedsUpdateOfScreenEdgesDeferringSystemGestures];
        [self setNeedsStatusBarAppearanceUpdate];
    }];
}

- (void)setupCategory_Navigation {
    // FCL style: the old right-edge swipe gesture for opening the menu has been removed entirely
    // UIScreenEdgePanGestureRecognizer is no longer registered; the menu is triggered by the floating button
    // The empty method body is kept because SurfaceViewController.m calls it via performSelector
}

- (void)actionForceClose {
    UIAlertController* alert = [UIAlertController alertControllerWithTitle:nil
        message:localize(@"game.menu.confirm.force_close", nil)
        preferredStyle:UIAlertControllerStyleAlert];

    UIAlertAction* cancelAction = [UIAlertAction actionWithTitle:localize(@"Cancel", nil) style:UIAlertActionStyleDefault handler:nil];
    [alert addAction:cancelAction];

    UIAlertAction* okAction = [UIAlertAction actionWithTitle:localize(@"OK", nil) style:UIAlertActionStyleDestructive handler:^(UIAlertAction * action) {
        // ZeroTier/Terracotta multiplayer temporarily removed: the original stopAllMultiplayerServices call is commented out
        // @try {
        //     [[MultiplayerManager sharedManager] stopAllMultiplayerServices];
        //     NSLog(@"[ForceClose] Multiplayer resources cleaned up");
        // } @catch (NSException *e) {
        //     NSLog(@"[ForceClose] Exception while cleaning up multiplayer resources: %@", e);
        // }

        // FCL style: exit directly, no more shrink animation
        if (fatalExitGroup == nil) {
            exit(0);
        } else {
            dispatch_group_leave(fatalExitGroup);
        }
    }];
    [alert addAction:okAction];

    [self presentViewController:alert animated:YES completion:nil];
}

- (void)actionOpenCustomControls {
    [self dismissMenu];
    [self.ctrlView removeAllButtons];
    CustomControlsViewController *vc = [[CustomControlsViewController alloc] init];
    vc.modalPresentationStyle = UIModalPresentationOverFullScreen;
    vc.setDefaultCtrl = ^(NSString *name){
        if (PLProfiles.current.selectedProfile[@"defaultTouchCtrl"]) {
            // Save default to current profile
            PLProfiles.current.selectedProfile[@"defaultTouchCtrl"] = name;
        } else {
            // Save default to preferences
            setPrefObject(@"control.default_ctrl", name);
        }
    };
    vc.getDefaultCtrl = ^{
        return [PLProfiles resolveKeyForCurrentProfile:@"defaultTouchCtrl"];
    };
    [self presentViewController:vc animated:NO completion:nil];
}

- (void)actionOpenPreferences {
    [self dismissMenu];
    LauncherPreferencesViewController *vc = [[LauncherPreferencesViewController alloc] init];
    [self presentViewController:vc animated:YES completion:nil];
}

/// Open the in-game multiplayer screen (Terracotta multiplayer, interoperable with HMCL/FCL/ZL2)
///
/// Matches the FCL flow: after launching the game, enter the multiplayer screen through the floating ball menu,
/// then either host (create a world → open to LAN → enter the port → generate an invite code)
/// or join (enter the invite code → join the network → connect directly to 127.0.0.1:25565 in MC multiplayer).
- (void)actionOpenMultiplayer {
    // ZeroTier/Terracotta multiplayer temporarily removed (while a startup crash is investigated)
    [self dismissMenu];
    UIAlertController *alert = [UIAlertController
        alertControllerWithTitle:@"Multiplayer is temporarily unavailable"
                          message:@"The multiplayer module (ZeroTier/Terracotta) is disabled for now while a startup crash is being investigated. Please wait for a future release."
                   preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
}

/// FCL style: hide/show the control buttons (matches the FCL hide_all toggle)
- (void)actionToggleControls {
    self.toggleHidden = !self.toggleHidden;
    [self updateControlHiddenState:self.toggleHidden];
}

/// FCL style: toggle the virtual mouse (matches the FCL mouse group / ZL2 ControlMouse)
- (void)actionToggleVirtualMouse {
    if (!isGrabbing) {
        virtualMouseEnabled = !virtualMouseEnabled;
        self.mousePointerView.hidden = !virtualMouseEnabled;
        setPrefBool(@"control.virtmouse_enable", virtualMouseEnabled);
        [self setNeedsUpdateOfPrefersPointerLocked];
    }
}

/// FCL style: open/close the in-game keyboard (matches FCL open_quick_input / ZL2 input_method)
- (void)actionToggleKeyboard {
    if (self.inputTextField.isFirstResponder) {
        [self.inputTextField resignFirstResponder];
        self.inputTextField.alpha = 1.0f;
    } else {
        [self.inputTextField becomeFirstResponder];
        self.inputTextField.text = @" ";
    }
}

/// FCL/ZL2 style: adjust the game resolution (matches FCL window_scale / ZL2 resolutionRatio)
- (void)actionAdjustResolution {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:localize(@"game.menu.resolution", nil)
                                                                   message:localize(@"game.menu.resolution.message", nil)
                                                            preferredStyle:UIAlertControllerStyleActionSheet];

    NSArray *options = @[@25, @50, @75, @100, @125, @150];
    NSInteger currentValue = (NSInteger)getPrefFloat(@"video.resolution");
    for (NSNumber *value in options) {
        NSString *title = [NSString stringWithFormat:@"%ld%%", (long)value.intValue];
        if (value.intValue == currentValue) {
            title = [NSString stringWithFormat:@"✓ %@", title];
        }
        [alert addAction:[UIAlertAction actionWithTitle:title style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
            setPrefFloat(@"video.resolution", value.floatValue);
            [self updateSavedResolution];
        }]];
    }
    [alert addAction:[UIAlertAction actionWithTitle:localize(@"Cancel", nil) style:UIAlertActionStyleCancel handler:nil]];

    // iPad adaptation
    alert.popoverPresentationController.sourceView = self.view;
    alert.popoverPresentationController.sourceRect = CGRectMake(self.view.bounds.size.width / 2, self.view.bounds.size.height / 2, 1, 1);

    [self presentViewController:alert animated:YES completion:nil];
}

- (void)actionOpenNavigationMenu {
    // FCL style: the in-game custom control SPECIALBTN_MENU also triggers the bottom pop-up menu
    [self toggleMenu];
}

- (UIRectEdge)preferredScreenEdgesDeferringSystemGestures {
    if (!self.menuView.hidden) {
        return 0;
    }
    return UIRectEdgeBottom | UIRectEdgeRight;
}

- (BOOL)prefersHomeIndicatorAutoHidden {
    return self.menuView.hidden &&
        getPrefBool(@"debug.debug_hide_home_indicator");
}

- (BOOL)prefersStatusBarHidden {
    return self.menuView.hidden;
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    return self.menuArray.count;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"FCLMenuCell"];

    if (cell == nil) {
        cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:@"FCLMenuCell"];
        cell.backgroundColor = [UIColor clearColor];
        cell.textLabel.textColor = [UIColor whiteColor];
        // Fix: the in-game menu font should not use sp scaling; a fixed 16pt keeps it consistent across all devices
        // The original [ScreenUtils sp:16] scaled up to 32pt on iPad, making the menu font too large
        cell.textLabel.font = [UIFont systemFontOfSize:16];
        cell.textLabel.textAlignment = NSTextAlignmentLeft;
        // FCL style: leave room for the icon on the left, cell height 48
        cell.separatorInset = UIEdgeInsetsMake(0, 16, 0, 16);
        cell.selectionStyle = UITableViewCellSelectionStyleDefault;
        // Selected state background
        UIView *selectedBg = [[UIView alloc] init];
        selectedBg.backgroundColor = [UIColor colorWithRed:80.0/255.0 green:80.0/255.0 blue:90.0/255.0 alpha:0.6];
        cell.selectedBackgroundView = selectedBg;
    }

    cell.textLabel.text = localize(self.menuArray[indexPath.row], nil);
    return cell;
}

- (CGFloat)tableView:(UITableView *)tableView heightForRowAtIndexPath:(NSIndexPath *)indexPath {
    // Fix: use a fixed row height of 48pt that does not scale with the screen
    // The original [ScreenUtils sp:48] scaled up to 96pt on iPad, making the menu items too tall
    return 48;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:NO];
    [self didSelectMenuItem:indexPath.row];
}

- (void)didSelectMenuItem:(int)item {
    switch (item) {
        case 0: // Force close
            [self actionForceClose];
            break;
        case 1: // Log output
            [self.logOutputView actionToggleLogOutput];
            break;
        case 2: // Control layout editor
            [self actionOpenCustomControls];
            break;
        case 3: // Multiplayer (Terracotta, interoperable with HMCL/FCL/ZL2; switchable to ZeroTier from the top-right corner)
            [self actionOpenMultiplayer];
            break;
        case 4: // FPS/memory display toggle
            if ([self.gameMenuOverlay isKindOfClass:[GameMenuOverlayView class]]) {
                [(GameMenuOverlayView *)self.gameMenuOverlay toggleStatsLabel];
            }
            break;
        case 5: // Hide/show control buttons
            [self actionToggleControls];
            break;
        case 6: // Virtual mouse toggle
            [self actionToggleVirtualMouse];
            break;
        case 7: // In-game keyboard
            [self actionToggleKeyboard];
            break;
        case 8: // Resolution adjustment
            [self actionAdjustResolution];
            break;
        case 9: // Settings
            [self actionOpenPreferences];
            break;
    }
}

- (void)viewWillTransitionToSize_Navigation:(CGRect)frame {
    // FCL style: the menu pops up from the bottom, so recompute the frame on rotation
    CGFloat screenWidth = frame.size.width;
    CGFloat screenHeight = frame.size.height;
    CGFloat menuWidth = MIN(screenWidth * 0.7, 400);
    CGFloat menuMaxHeight = screenHeight * 0.6;
    CGFloat menuEstimatedHeight = self.menuArray.count * 48 + 16;
    CGFloat menuHeight = MIN(menuEstimatedHeight, menuMaxHeight);

    if (!self.menuView.hidden) {
        // When the menu is visible, update it to the new target position
        CGFloat safeBottom = [ScreenUtils safeAreaBottom];
        CGFloat targetY = screenHeight - menuHeight - safeBottom - 16;
        self.menuView.frame = CGRectMake(
            (screenWidth - menuWidth) / 2.0,
            targetY,
            menuWidth,
            menuHeight
        );
    } else {
        // When the menu is not visible, keep it off the bottom of the screen
        self.menuView.frame = CGRectMake(
            (screenWidth - menuWidth) / 2.0,
            screenHeight,
            menuWidth,
            menuHeight
        );
    }
    // Update the dimming layer frame
    self.menuDimView.frame = CGRectMake(0, 0, screenWidth, screenHeight);
}

@end
