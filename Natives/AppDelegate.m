#import "AppDelegate.h"
#import "SceneDelegate.h"
#import "ios_uikit_bridge.h"
#import "utils.h"

// SurfaceViewController
extern dispatch_group_t fatalExitGroup;

@implementation AppDelegate

#pragma mark - UISceneSession lifecycle

- (UISceneConfiguration *)application:(UIApplication *)application configurationForConnectingSceneSession:(UISceneSession *)connectingSceneSession options:(UISceneConnectionOptions *)options {
    // Called when a new scene session is being created.
    return [[UISceneConfiguration alloc] initWithName:@"Default Configuration" sessionRole:connectingSceneSession.role];
}

- (void)application:(UIApplication *)application didDiscardSceneSessions:(NSSet<UISceneSession *> *)sceneSessions {
    // Called when the user discards a scene session.
}

- (void)applicationWillTerminate:(UIApplication *)application {
    if (fatalExitGroup != nil) {
        dispatch_group_leave(fatalExitGroup);
        fatalExitGroup = nil;
    }
}

#pragma mark - Orientation Support (iOS 15 and earlier)

- (UIInterfaceOrientationMask)application:(UIApplication *)application supportedInterfaceOrientationsForWindow:(UIWindow *)window {
    // Force landscape only
    return UIInterfaceOrientationMaskLandscape;
}

@end
ly
    return UIInterfaceOrientationMaskLandscape;
}

@end
