#import <UIKit/UIKit.h>

/// Screen size helper (following the ScreenUtils design of FCL)
/// Very fast lookups: nativeBounds/nativeScale are cached with dispatch_once (fixed values, O(1));
/// screenSize/safeAreaInsets are read live (since they change with the orientation and safe area).
/// Supports iPhone and iPad, adapting to the orientation automatically.
@interface ScreenUtils : NSObject

/// The current screen size (in points, for the current orientation)
+ (CGSize)screenSize;

/// The portrait screen size (in points, a fixed value)
+ (CGSize)screenSizePortrait;

/// The landscape screen size (in points, a fixed value)
+ (CGSize)screenSizeLandscape;

/// The native screen size (in pixels, a fixed value that does not change with orientation)
+ (CGSize)nativeScreenSize;

/// The screen scale factor (such as 2.0 or 3.0)
+ (CGFloat)screenScale;

/// The native scale factor (such as 2.0 or 3.0)
+ (CGFloat)nativeScale;

/// Whether this is an iPad
+ (BOOL)isPad;

/// Whether this is an iPhone
+ (BOOL)isPhone;

/// Whether this is landscape (based on statusBarOrientation, which is more reliable than UIDevice.orientation)
+ (BOOL)isLandscape;

/// Whether this is portrait
+ (BOOL)isPortrait;

/// The safe area insets (of the current keyWindow)
+ (UIEdgeInsets)safeAreaInsets;

/// The status bar height (statusBarManager on iOS 13+, statusBarFrame on older versions)
+ (CGFloat)statusBarHeight;

/// The navigation bar height (44, which may differ on an iPhone in landscape)
+ (CGFloat)navigationBarHeight;

/// The tab bar height (49 + safeAreaBottom)
+ (CGFloat)tabBarHeight;

/// The bottom safe area height (34 on iPhone X and later, 0 otherwise)
+ (CGFloat)safeAreaBottom;

/// The top safe area height (47/44 on iPhone X and later, 20 otherwise)
+ (CGFloat)safeAreaTop;

/// Whether there is a notch or Dynamic Island (safeAreaTop > 20)
+ (BOOL)hasNotch;

/// The screen corner radius (approximate, as a design reference)
+ (CGFloat)cornerRadius;

/// A scaled font size (scaled from the screen width, following the sp() function of FCL)
+ (CGFloat)sp:(CGFloat)sp;

/// A scaled dimension (scaled from the screen width, following the dp() function of FCL)
+ (CGFloat)dp:(CGFloat)dp;

/// The current keyWindow (working on iOS 13+ and older versions)
+ (UIWindow *)keyWindow;

@end
