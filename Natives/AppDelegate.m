#import "AppDelegate.h"
#import "SceneDelegate.h"
#import "ios_uikit_bridge.h"
#import "utils.h"
#import "AFNetworking.h"
#import "MinecraftResourceDownloadTask.h"

// SurfaceViewController
extern dispatch_group_t fatalExitGroup;

@interface AppDelegate ()
@property (nonatomic, copy) void (^backgroundURLSessionCompletionHandler)(void);
@end

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

#pragma mark - Background URL Session

- (void)application:(UIApplication *)application handleEventsForBackgroundURLSession:(NSString *)identifier completionHandler:(void (^)(void))completionHandler {
    if (![identifier isEqualToString:kMinecraftResourceDownloadBackgroundSessionIdentifier]) {
        if (completionHandler) {
            completionHandler();
        }
        return;
    }

    self.backgroundURLSessionCompletionHandler = completionHandler;

    AFURLSessionManager *manager = [MinecraftResourceDownloadTask sharedBackgroundSessionManager];
    __weak typeof(self) weakSelf = self;
    [manager setDidFinishEventsForBackgroundURLSessionBlock:^(NSURLSession *session) {
        if (weakSelf.backgroundURLSessionCompletionHandler) {
            weakSelf.backgroundURLSessionCompletionHandler();
            weakSelf.backgroundURLSessionCompletionHandler = nil;
        }
    }];
}

#pragma mark - Orientation Support

- (UIInterfaceOrientationMask)application:(UIApplication *)application supportedInterfaceOrientationsForWindow:(UIWindow *)window {
    // Force landscape only
    return UIInterfaceOrientationMaskLandscape;
}

@end
