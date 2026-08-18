#import "SceneDelegate.h"
#import "ios_uikit_bridge.h"
#import "utils.h"
#import "LauncherRootViewController.h"
#import "LauncherCardLayoutViewController.h"
#import "LauncherPreferences.h"
#import "BackgroundManager.h"
// Terracotta temporarily removed (while a startup crash is investigated)
// #import "TerracottaManager.h"
// #import "TerracottaBridge.h"

extern UIWindow *mainWindow;

@interface SceneDelegate ()
@end

@implementation SceneDelegate

- (void)scene:(UIScene *)scene willConnectToSession:(UISceneSession *)session options:(UISceneConnectionOptions *)connectionOptions {
    UIWindowScene *windowScene = (UIWindowScene *)scene;
    
    // Force landscape (iOS 16+)
    if (@available(iOS 16.0, *)) {
        UIWindowSceneGeometryPreferencesIOS *geometryPreferences = [[UIWindowSceneGeometryPreferencesIOS alloc] init];
        geometryPreferences.interfaceOrientations = UIInterfaceOrientationMaskLandscape;
        [windowScene requestGeometryUpdateWithPreferences:geometryPreferences errorHandler:^(NSError *error) {
            NSLog(@"[SceneDelegate] Failed to update geometry: %@", error);
        }];
    }
    
    self.window = [[UIWindow alloc] initWithWindowScene:windowScene];
    self.window.frame = windowScene.coordinateSpace.bounds;
    // Fix: use systemBackgroundColor so it adapts to light/dark mode.
    // The previously hardcoded dark gray (0.08) made the middle "a block of black" in light mode.
    // systemBackgroundColor is white in light mode and black in dark mode, adapting automatically.
    // BackgroundManager.applyBackgroundToWindow overrides this color when the user has set a custom wallpaper.
    if (@available(iOS 13.0, *)) {
        self.window.backgroundColor = [UIColor systemBackgroundColor];
    } else {
        self.window.backgroundColor = [UIColor colorWithWhite:0.08 alpha:1.0];
    }
    mainWindow = self.window;

    // Choose the layout from the settings: the VS three-column layout by default, switchable to the bento card layout
    NSString *layout = getPrefObject(@"general.ui_layout");
    UIViewController *rootVC;
    if ([layout isEqualToString:@"card"]) {
        rootVC = [[LauncherCardLayoutViewController alloc] init];
    } else {
        rootVC = [[LauncherRootViewController alloc] init];
    }
    self.window.rootViewController = rootVC;

    // Appearance (light/dark/match system): read from the general.ui_theme preference.
    //   light  -> UIUserInterfaceStyleLight
    //   dark   -> UIUserInterfaceStyleDark (the default, matching the original behavior)
    //   auto   -> UIUserInterfaceStyleUnspecified (matching the system)
    // overrideUserInterfaceStyle is available on iOS 13+. Only the window level is set; accounts and preferences are untouched.
    if (@available(iOS 13.0, *)) {
        NSString *theme = getPrefObject(@"general.ui_theme");
        if ([theme isEqualToString:@"light"]) {
            self.window.overrideUserInterfaceStyle = UIUserInterfaceStyleLight;
        } else if ([theme isEqualToString:@"auto"]) {
            self.window.overrideUserInterfaceStyle = UIUserInterfaceStyleUnspecified;
        } else {
            self.window.overrideUserInterfaceStyle = UIUserInterfaceStyleDark;
        }
    }

    [self.window makeKeyAndVisible];

    // Apply the background immediately (the old 0.1s delay has been removed):
    // the delay exposed the window base color at startup as a "black band" or a flash. BackgroundManager already calls
    // loadSavedBackground/loadUISettings in its init, so the singleton is fully initialized on first access and no delay is needed.
    [[BackgroundManager sharedManager] applyBackgroundToWindow:self.window];

    // Terracotta temporarily removed (while a startup crash is investigated)
    // if ([TerracottaBridge isAvailable]) {
    //     TerracottaManager *mgr = [TerracottaManager shared];
    //     NSLog(@"[SceneDelegate] Terracotta manager initialized: %d", mgr.initialized);
    // } else {
    //     NSLog(@"[SceneDelegate] libterracotta not linked, multiplayer disabled");
    // }
    NSLog(@"[SceneDelegate] Terracotta temporarily disabled for crash investigation");

    // Listen for the theme change notification (so switching "Appearance" in settings applies live, with no restart)
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(applyUITheme:)
                                                 name:@"UIThemeChanged"
                                               object:nil];
}

- (void)applyUITheme:(NSNotification *)notification {
    // Switch the appearance live. Only window.overrideUserInterfaceStyle is changed;
    // the PLPreferences reset logic is untouched and no account data is read or written, so switching theme cannot sign the user out.
    NSString *theme = notification.object ?: getPrefObject(@"general.ui_theme");
    if (@available(iOS 13.0, *)) {
        if ([theme isEqualToString:@"light"]) {
            self.window.overrideUserInterfaceStyle = UIUserInterfaceStyleLight;
        } else if ([theme isEqualToString:@"auto"]) {
            self.window.overrideUserInterfaceStyle = UIUserInterfaceStyleUnspecified;
        } else {
            self.window.overrideUserInterfaceStyle = UIUserInterfaceStyleDark;
        }
    }
}

- (void)sceneDidDisconnect:(UIScene *)scene {
    [[NSNotificationCenter defaultCenter] removeObserver:self name:@"UIThemeChanged" object:nil];
}

- (void)sceneDidBecomeActive:(UIScene *)scene {
}

- (void)sceneWillResignActive:(UIScene *)scene {
}

- (void)sceneWillEnterForeground:(UIScene *)scene {
}

- (void)sceneDidEnterBackground:(UIScene *)scene {
    CallbackBridge_pauseGameIfNeed();
}

#pragma mark - Orientation Support (iOS 16+)

- (UIInterfaceOrientationMask)scene:(UIScene *)scene supportedInterfaceOrientationsForWindowScene:(UIWindowScene *)windowScene API_AVAILABLE(ios(16.0)) {
    return UIInterfaceOrientationMaskLandscape;
}

@end
