#import "ScreenUtils.h"

@implementation ScreenUtils

// Fast caching: nativeBounds/nativeScale are fixed values read once with dispatch_once
// UIScreen.main.bounds/nativeBounds are O(1), but dispatch_once still avoids the cost of repeated calls
// Note: CGSizeZero expands to the compound literal (CGSize){0,0} in the iOS SDK, which is not a compile-time constant
// and cannot initialize a global. A plain struct initializer {0,0} is used instead.
static CGSize _cachedNativeBounds = {0, 0};
static CGFloat _cachedNativeScale = 0;
static CGFloat _cachedScale = 0;
static dispatch_once_t _nativeOnceToken;

+ (void)initializeNativeBounds {
    dispatch_once(&_nativeOnceToken, ^{
        UIScreen *screen = [UIScreen mainScreen];
        _cachedNativeBounds = screen.nativeBounds.size;
        _cachedNativeScale = screen.nativeScale;
        _cachedScale = screen.scale;
    });
}

+ (CGSize)screenSize {
    // UIScreen.main.bounds changes with the orientation on iOS 13+, so it is read live
    return [UIScreen mainScreen].bounds.size;
}

+ (CGSize)screenSizePortrait {
    [self initializeNativeBounds];
    // nativeBounds is a fixed value where width < height in portrait
    CGSize native = _cachedNativeBounds;
    if (native.width <= native.height) {
        // The native orientation is already portrait
        return CGSizeMake(native.width / _cachedNativeScale, native.height / _cachedNativeScale);
    }
    // The native orientation is landscape, so swap them
    return CGSizeMake(native.height / _cachedNativeScale, native.width / _cachedNativeScale);
}

+ (CGSize)screenSizeLandscape {
    [self initializeNativeBounds];
    CGSize native = _cachedNativeBounds;
    if (native.width >= native.height) {
        // The native orientation is already landscape
        return CGSizeMake(native.width / _cachedNativeScale, native.height / _cachedNativeScale);
    }
    // The native orientation is portrait, so swap them
    return CGSizeMake(native.height / _cachedNativeScale, native.width / _cachedNativeScale);
}

+ (CGSize)nativeScreenSize {
    [self initializeNativeBounds];
    return _cachedNativeBounds;
}

+ (CGFloat)screenScale {
    [self initializeNativeBounds];
    return _cachedScale;
}

+ (CGFloat)nativeScale {
    [self initializeNativeBounds];
    return _cachedNativeScale;
}

+ (BOOL)isPad {
    // Prefer traitCollection.userInterfaceIdiom (which _setUserInterfaceIdiom in UIKit+hook affects)
    // but use the real idiom when the user has not forced Phone mode
    // Note: UIKit+hook.m forces the idiom to Phone (unless debug.debug_ipad_ui is set),
    // so [UIDevice currentDevice].userInterfaceIdiom here would be affected by the hook.
    // To detect a real iPad, mainScreen.traitCollection.userInterfaceIdiom is used.
    UIUserInterfaceIdiom idiom = [UIScreen mainScreen].traitCollection.userInterfaceIdiom;
    if (idiom == UIUserInterfaceIdiomPad) return YES;
    // Fallback: detect from the model name (which the hook does not affect)
    NSString *model = [[UIDevice currentDevice].model lowercaseString];
    return [model containsString:@"ipad"];
}

+ (BOOL)isPhone {
    return ![self isPad];
}

+ (BOOL)isLandscape {
    // statusBarOrientation is more reliable than UIDevice.orientation (which can be unknown early in startup)
    UIInterfaceOrientation orientation = [[UIApplication sharedApplication] statusBarOrientation];
    return UIInterfaceOrientationIsLandscape(orientation);
}

+ (BOOL)isPortrait {
    UIInterfaceOrientation orientation = [[UIApplication sharedApplication] statusBarOrientation];
    return UIInterfaceOrientationIsPortrait(orientation);
}

+ (UIEdgeInsets)safeAreaInsets {
    UIWindow *window = [self keyWindow];
    if (@available(iOS 11.0, *)) {
        return window.safeAreaInsets;
    }
    return UIEdgeInsetsZero;
}

+ (CGFloat)statusBarHeight {
    UIWindow *window = [self keyWindow];
    if (@available(iOS 13.0, *)) {
        if (window.windowScene && window.windowScene.statusBarManager) {
            return window.windowScene.statusBarManager.statusBarFrame.size.height;
        }
    }
    return [UIApplication sharedApplication].statusBarFrame.size.height;
}

+ (CGFloat)navigationBarHeight {
    // 44 as standard, which may differ on an iPhone in landscape
    return 44.0;
}

+ (CGFloat)tabBarHeight {
    return 49.0 + [self safeAreaBottom];
}

+ (CGFloat)safeAreaBottom {
    return [self safeAreaInsets].bottom;
}

+ (CGFloat)safeAreaTop {
    return [self safeAreaInsets].top;
}

+ (BOOL)hasNotch {
    return [self safeAreaTop] > 20.0;
}

+ (CGFloat)cornerRadius {
    // Approximate: about 39pt on iPhone X and later, about 18pt on iPad
    return [self isPad] ? 18.0 : 39.0;
}

+ (CGFloat)sp:(CGFloat)sp {
    // Following the sp() function of FCL: scaled from the screen width
    // FCL uses baseWidth = 360 (the Android reference phone width)
    // but iOS uses points rather than pixels, so baseWidth = 375 here (the iPhone X width)
    CGFloat baseWidth = 375.0;
    CGFloat screenWidth = [self screenSize].width;
    CGFloat scale = screenWidth / baseWidth;
    // Clamp the scale, so extreme sizes are avoided
    // Fix: the old max=2.0 doubled the font on iPad (16pt->32pt),
    // making the text in the menu and version manager far too large. On an iPad 1024+ wide the scale of 2.73 was clamped to 2.0,
    // well beyond anything sensible. The cap is now 1.15, so iPad text is only slightly larger than the iPhone baseline,
    // matching the system dynamic type style.
    if (scale < 0.85) scale = 0.85;
    if (scale > 1.15) scale = 1.15;
    return sp * scale;
}

+ (CGFloat)dp:(CGFloat)dp {
    // As with sp, scaled from the screen width
    CGFloat baseWidth = 375.0;
    CGFloat screenWidth = [self screenSize].width;
    CGFloat scale = screenWidth / baseWidth;
    // dp is used for dimensions (icon sizes, spacing and so on), so it allows a slightly wider scale range than sp,
    // while still being clamped so elements are not oversized on iPad
    if (scale < 0.85) scale = 0.85;
    if (scale > 1.3) scale = 1.3;
    return dp * scale;
}

+ (UIWindow *)keyWindow {
    // Works on iOS 13+ and older versions
    if (@available(iOS 13.0, *)) {
        for (UIWindowScene *scene in [UIApplication sharedApplication].connectedScenes) {
            if (scene.activationState == UISceneActivationStateForegroundActive) {
                for (UIWindow *window in scene.windows) {
                    if (window.isKeyWindow) {
                        return window;
                    }
                }
                // With no keyWindow, return the first window
                if (scene.windows.count > 0) {
                    return scene.windows.firstObject;
                }
            }
        }
    }
    return [UIApplication sharedApplication].keyWindow;
}

@end
