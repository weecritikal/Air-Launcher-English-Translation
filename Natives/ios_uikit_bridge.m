#import "ArchiveIntegrity.h"
#import "installer/ForgeDirectInstaller.h"
#import "authenticator/BaseAuthenticator.h"
#import "AppDelegate.h"
#import "SceneDelegate.h"
#import "LauncherNavigationController.h"
#import "LauncherPreferences.h"
#import "LauncherSplitViewController.h"
#import "PLLogOutputView.h"
#import "SurfaceViewController.h"

#include <objc/runtime.h>
#include "ios_uikit_bridge.h"
#include "utils.h"

void internal_showDialog(NSString* title, NSString* message) {
    NSLog(@"[UI] Dialog shown: %@: %@", title, message);

    UIAlertController* alert = [UIAlertController alertControllerWithTitle:title
        message:message
        preferredStyle:UIAlertControllerStyleAlert];
    //text.dataDetectorTypes = UIDataDetectorTypeLink;
    UIAlertAction* okAction = [UIAlertAction actionWithTitle:localize(@"OK", nil) style:UIAlertActionStyleDefault handler:nil];
    [alert addAction:okAction];

    UIWindow *alertWindow = [[UIWindow alloc] initWithWindowScene:UIWindow.mainWindow.windowScene];
    alertWindow.frame = UIScreen.mainScreen.bounds;
    alertWindow.rootViewController = [UIViewController new];
    alertWindow.windowLevel = 1000;
    [alertWindow makeKeyAndVisible];
    objc_setAssociatedObject(alert, @selector(alertWindow), alertWindow, OBJC_ASSOCIATION_RETAIN_NONATOMIC);

    [alertWindow.rootViewController presentViewController:alert animated:YES completion:nil];
}

void showDialog(NSString* title, NSString* message) {
    dispatch_async(dispatch_get_main_queue(), ^{
        internal_showDialog(title, message);
    });
}

JNIEXPORT void JNICALL Java_net_kdt_pojavlaunch_uikit_UIKit_showError(JNIEnv* env, jclass clazz, jstring title, jstring message, jboolean exitIfOk) {
    const char *title_c = (*env)->GetStringUTFChars(env, title, 0);
    const char *message_c = (*env)->GetStringUTFChars(env, message, 0);
    NSString *title_o = @(title_c);
    NSString *message_o = @(message_c);
    (*env)->ReleaseStringUTFChars(env, title, title_c);
    (*env)->ReleaseStringUTFChars(env, message, message_c);

    if (SurfaceViewController.isRunning) {
        NSLog(@"%@\n%@", title_o, message_o);
        [PLLogOutputView handleExitCode:1];
        return;
    }

dispatch_async(dispatch_get_main_queue(), ^{

    UIAlertController* alert = [UIAlertController
        alertControllerWithTitle:title_o message:message_o
        preferredStyle:UIAlertControllerStyleAlert];
    NSMutableParagraphStyle *style = [[NSMutableParagraphStyle alloc] init];
    style.alignment = NSTextAlignmentLeft;

    NSMutableAttributedString *atrStr = [[NSMutableAttributedString alloc] initWithString:message_o attributes:@{NSParagraphStyleAttributeName:style,NSFontAttributeName:[UIFont systemFontOfSize:13.0]}];

    [alert setValue:atrStr forKey:@"attributedMessage"];

    UIAlertAction* okAction = [UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault
        handler:^(UIAlertAction * action) {
            if (exitIfOk == JNI_TRUE) {
                exit(-1);
            }
        }];
    [alert addAction:okAction];
    
    UIAlertAction* copyAction = [UIAlertAction actionWithTitle:@"Copy" style:UIAlertActionStyleDefault
        handler:^(UIAlertAction * action) {
            UIPasteboard.generalPasteboard.string = message_o;
            if (exitIfOk == JNI_TRUE) {
                exit(-1);
            }
        }];
    [alert addAction:copyAction];
    
    [currentVC() presentViewController:alert animated:YES completion:nil];
});
}

jstring UIKit_accessClipboard(JNIEnv* env, jint action, jbyteArray copySrc) {
    if (action == CLIPBOARD_PASTE) {
        // paste request
        if (UIPasteboard.generalPasteboard.hasStrings) {
            return (*env)->NewStringUTF(env, [UIPasteboard.generalPasteboard.string UTF8String]);
        } else {
            return (*env)->NewStringUTF(env, "");
        }
    } else if (action == CLIPBOARD_COPY) {
        // copy request
        const char* copySrcC = (*env)->GetByteArrayElements(env, copySrc, 0);
        if (copySrcC) {
            UIPasteboard.generalPasteboard.string = @(copySrcC);
            (*env)->ReleaseByteArrayElements(env, copySrc, copySrcC, 0);
        }
        return NULL;
    } else {
        // unknown request
        NSLog(@"Warning: unknown clipboard action: %x", action);
        return NULL;
    }
}

/// Move any unreadable jar out of the mods folder before the JVM ever sees it.
///
/// A mod that downloaded truncated used to take the whole game down at startup with
/// java.util.zip.ZipException: zip END header not found, thrown from Forge's mod scanner.
/// The stack trace named no file, so there was nothing to act on except deleting the instance
/// and reinstalling the version, the modloader and the modpack from scratch. Now the bad file is
/// set aside, the game starts, and the message says exactly which mod to fetch again.
static void UIKit_quarantineCorruptModsBeforeLaunch(void) {
    NSString *modsFolder = [ArchiveIntegrity modsFolderForProfile:nil];
    if (modsFolder.length == 0) return;

    NSArray<NSDictionary<NSString *, NSString *> *> *quarantined =
        [ArchiveIntegrity quarantineCorruptArchivesInDirectory:modsFolder];
    if (quarantined.count == 0) return;

    NSMutableString *message = [NSMutableString stringWithFormat:
        @"%lu mod%@ did not download correctly and would have stopped the game from starting. "
         "%@ been moved into mods/.air_corrupt so the game can launch.\n",
        (unsigned long)quarantined.count,
        quarantined.count == 1 ? @"" : @"s",
        quarantined.count == 1 ? @"It has" : @"They have"];
    NSUInteger shown = MIN(quarantined.count, (NSUInteger)8);
    for (NSUInteger i = 0; i < shown; i++) {
        [message appendFormat:@"\n  • %@ — %@", quarantined[i][@"name"], quarantined[i][@"reason"]];
    }
    if (quarantined.count > shown) {
        [message appendFormat:@"\n  ...and %lu more", (unsigned long)(quarantined.count - shown)];
    }
    [message appendString:@"\n\nReinstall the modpack to download just these again — the rest of the "
                           "files are kept, so it will not start over."];

    NSLog(@"[Launch] %@", message);
    showDialog(@"Damaged mods were set aside", message);
}

/// Refuse to start a Forge version whose runtime was never fully built, or was built badly.
///
/// Forge 1.13+ boots through three files its installer's processors produce on the device. Absent,
/// the JVM dies with "Invalid paths argument, contained no existing paths"; present but damaged -
/// an install that was interrupted partway through writing one - it dies with "zip END header not
/// found". Neither message names a file or suggests a next step, and both arrive a good half minute
/// into loading. Checking first turns that into a sentence naming the file and the fix.
/// Returns YES when the launch may proceed.
static BOOL UIKit_verifyForgeRuntimeBeforeLaunch(NSDictionary *metadata) {
    if (![metadata isKindOfClass:NSDictionary.class]) return YES;

    const char *gameDirC = getenv("POJAV_GAME_DIR");
    if (!gameDirC) return YES;
    NSString *librariesDir = [@(gameDirC) stringByAppendingPathComponent:@"libraries"];

    NSArray<NSDictionary<NSString *, NSString *> *> *unusable =
        [ForgeDirectInstaller unusableRuntimeArtifactsForVersionJSON:metadata librariesDir:librariesDir];
    if (unusable.count == 0) return YES;

    NSMutableString *message = [NSMutableString stringWithString:
        @"This Forge version did not finish installing, so the game cannot start. "
         "Forge builds these files on your device while it installs:\n"];
    for (NSDictionary *entry in unusable) {
        [message appendFormat:@"\n  - %@ (%@)", [entry[@"path"] lastPathComponent], entry[@"reason"]];
    }
    [message appendString:@"\n\nInstall this Forge version again and pick \"Run the Forge installer\" - "
                           "only Forge's own installer can build them. Let it finish before leaving the "
                           "screen. Your mods and worlds are kept."];

    NSLog(@"[Launch] Refusing to start: %lu unusable Forge runtime artifact(s): %@",
          (unsigned long)unusable.count, unusable);
    showDialog(@"Forge is not fully installed", message);
    return NO;
}

BOOL UIKit_launchMinecraftSurfaceVC(UIWindow* window, NSDictionary* metadata) {
    // Leave this pref, might be useful later for launching with Quick Actions/Shortcuts/URL Scheme
    //setPreference(@"internal_launch_on_boot", getPreference(@"restart_before_launch"));
    BaseAuthenticator *currentAuth = BaseAuthenticator.current;
    // selected_account stores the accountId (the unique identifier), so the login state can be restored by accountId after a restart
    setPrefObject(@"internal.selected_account", currentAuth.authData[@"accountId"]);
    if (!UIKit_verifyForgeRuntimeBeforeLaunch(metadata)) {
        return NO;
    }
    UIKit_quarantineCorruptModsBeforeLaunch();
    dispatch_async(dispatch_get_main_queue(), ^{
        tmpRootVC = window.rootViewController;
        [UIView animateWithDuration:0.2 animations:^{
            window.alpha = 0;
        } completion:^(BOOL b){
            [window resignKeyWindow];
            window.alpha = 1;
            window.rootViewController = [[SurfaceViewController alloc] initWithMetadata:metadata];
            [window makeKeyAndVisible];
        }];
    });
    return YES;
}

void UIKit_returnToSplitView() {
    // Researching memory-safe ways to return from SurfaceViewController to the split view
    // so that the app doesn't close when quitting the game (similar behaviour to Android)
    dispatch_async(dispatch_get_main_queue(), ^{
        UIWindow *window = UIWindow.mainWindow;

        // Return from JavaGUIViewController
        if ([window.rootViewController isKindOfClass:LauncherSplitViewController.class]) {
            [currentVC() dismissViewControllerAnimated:YES completion:nil];
            return;
        }

        // Return from SurfaceViewController
        [UIView animateWithDuration:0.2 animations:^{
            window.alpha = 0;
        } completion:^(BOOL b){
            [window resignKeyWindow];
            window.alpha = 1;
            if (tmpRootVC) {
                window.rootViewController = tmpRootVC;
                tmpRootVC = nil;
            } else {
                window.rootViewController = [[LauncherSplitViewController alloc] initWithStyle:UISplitViewControllerStyleDoubleColumn];
            }
            [window makeKeyAndVisible];
        }];
    });
}

void launchInitialViewController(UIWindow *window) {
    window.rootViewController = [[LauncherSplitViewController alloc] initWithStyle:UISplitViewControllerStyleDoubleColumn];
#if 0
    if (getPrefBool(@"internal.internal_launch_on_boot")) {
        window.rootViewController = [[SurfaceViewController alloc] init];
    } else {
        window.rootViewController = [[LauncherSplitViewController alloc] initWithStyle:UISplitViewControllerStyleDoubleColumn];
    }
#endif
}
