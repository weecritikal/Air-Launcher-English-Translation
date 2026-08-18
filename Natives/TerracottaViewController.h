#import <UIKit/UIKit.h>

/// Terracotta multiplayer screen (modeled on the FCL style)
///
/// Inside the launcher it is presented by LauncherRootViewController/LauncherCardLayoutViewController via
/// the ShowMultiplayer notification; in game it is presented by SurfaceViewController+Navigation via
/// the floating ball menu. Both entry points show the same controller (modally).
@interface TerracottaViewController : UIViewController

@end
