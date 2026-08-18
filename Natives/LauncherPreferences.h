#import <UIKit/UIKit.h>

void loadPreferences(BOOL reset);
void toggleIsolatedPref(BOOL forceEnable);

id getPrefObject(NSString *key);
BOOL getPrefBool(NSString *key);
float getPrefFloat(NSString *key);
NSInteger getPrefInt(NSString *key);

void setPrefObject(NSString *key, id value);
void setPrefBool(NSString *key, BOOL value);
void setPrefFloat(NSString *key, float value);
void setPrefInt(NSString *key, NSInteger value);
void setPrefString(NSString *key, NSString *value);  // Newly added

void resetWarnings();

/// Get the user-defined theme accent color (preference key general.accent_color).
/// When unset it returns the launcher default blue, RGB(0.26, 0.63, 0.96) = #429CF5.
/// Refreshes are driven by the "LauncherAppearanceChanged" notification, so callers should re-read it in that callback.
/// Following the FCL theme color mechanism: the user can pick any accent color in settings, such as the FCL periwinkle #7797CF,
/// affecting every "primary blue" element: the play button, the selected menu state, the add-account button and so on.
UIColor *accentColor(void);

/// The default value of accentColor (the current blue #429CF5), for cases that need to tell "default" from "custom" apart
#define ACCENT_COLOR_DEFAULT_HEX @"429CF5"

BOOL getEntitlementValue(NSString *key);

UIEdgeInsets getDefaultSafeArea();
CGRect getSafeArea(CGRect screenBounds);
void setSafeArea(CGSize screenSize, CGRect safeArea);

NSString* getSelectedJavaHome(NSString* defaultJRETag, int minVersion);

NSArray* getRendererKeys(BOOL containsDefault);
NSArray* getRendererNames(BOOL containsDefault);
