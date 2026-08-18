#import <UIKit/UIKit.h>

// FCL-style rework: PLCrashView is now a UIViewController subclass (no longer a UIView).
// The class name is kept as PLCrashView for backward compatibility (the PLLogOutputView call sites are unchanged).
// It uses a two-column layout inside (the log on the left, the buttons on the right) with Auto Layout and UIStackView,
// following the crash screen design of FCL.
//   1. the OOM card height was overridden by a hardcoded 140 in layoutSubviews
//   2. the two columns were squeezed on a narrow screen (the right column was too narrow on iPhone)
//   3. repeated recalculation in layoutSubviews misplaced the buttons
@interface PLCrashView : UIViewController

/// Show the crash screen and handle the exit code
/// @param exitCode The game exit code
/// @param customTitle A custom error title (optional)
/// @param customReason A custom error reason (optional)
+ (void)showWithExitCode:(int)exitCode customTitle:(NSString *)customTitle customReason:(NSString *)customReason;

/// Show the crash screen (with only an exit code)
/// @param exitCode The game exit code
+ (void)showWithExitCode:(int)exitCode;

/// Hide the crash screen and return to the launcher
- (void)dismissAndReturnToLauncher;

/// Restart the launcher (a class method, safe to call from another VC)
/// It tears down the current crash screen and restarts the app process
+ (void)restartLauncher;

/// Hide the crash screen and return to the launcher (a class method, safe to call from another VC)
+ (void)dismissAndReturnToLauncher;

@end
