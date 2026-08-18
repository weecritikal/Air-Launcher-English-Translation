#import "config.h"
#import "utils.h"
#import "LauncherPreferences.h"
#import "PLPreferences.h"
#import "UIKit+hook.h"
#import <CoreFoundation/CoreFoundation.h>

static PLPreferences* pref;

void loadPreferences(BOOL reset) {
    assert(getenv("POJAV_HOME"));
    if (reset) {
        [pref reset];
    } else {
        pref = [[PLPreferences alloc] initWithAutomaticMigrator];
    }
}

void toggleIsolatedPref(BOOL forceEnable) {
    // Always recompute instancePath from the current POJAV_GAME_DIR.
    // POJAV_GAME_DIR is a symbolic link (pointing at $POJAV_HOME/instances/<current>),
    // and changeSelectionTo updates that link when the game directory is switched.
    // `if (!pref.instancePath)` used to cache the path from the first time it was set,
    // so after switching directories the launcher_preferences.plist of the old instance was still read
    // and the user had to restart the launcher for instancePath to be recomputed. It now refreshes every time.
    pref.instancePath = [NSString stringWithFormat:@"%s/launcher_preferences.plist", getenv("POJAV_GAME_DIR")];
    [pref toggleIsolationForced:forceEnable];
}

id getPrefObject(NSString *key) {
    return [pref getObject:key];
}
BOOL getPrefBool(NSString *key) {
    return [getPrefObject(key) boolValue];
}
float getPrefFloat(NSString *key) {
    return [getPrefObject(key) floatValue];
}
NSInteger getPrefInt(NSString *key) {
    return [getPrefObject(key) intValue];
}

void setPrefObject(NSString *key, id value) {
    [pref setObject:key value:value];
}
void setPrefBool(NSString *key, BOOL value) {
    setPrefObject(key, @(value));
}
void setPrefFloat(NSString *key, float value) {
    setPrefObject(key, @(value));
}
void setPrefInt(NSString *key, NSInteger value) {
    setPrefObject(key, @(value));
}
void setPrefString(NSString *key, NSString *value) {  // Newly added
    setPrefObject(key, value);
}

void resetWarnings() {
    for (int i = 0; i < pref.globalPref[@"warnings"].count; i++) {
        NSString *key = pref.globalPref[@"warnings"].allKeys[i];
        pref.globalPref[@"warnings"][key] = @YES;
    }
}

#pragma mark Accent Color

/// Parse a hex string (such as "429CF5" or "#429CF5") into a UIColor, returning nil on failure
static UIColor *colorFromHex(NSString *hex) {
    if (![hex isKindOfClass:[NSString class]] || hex.length == 0) return nil;
    NSString *clean = [hex stringByReplacingOccurrencesOfString:@"#" withString:@""];
    unsigned int rgb = 0;
    NSScanner *scanner = [NSScanner scannerWithString:clean];
    if (![scanner scanHexInt:&rgb]) return nil;
    return [UIColor colorWithRed:((rgb >> 16) & 0xFF) / 255.0
                           green:((rgb >> 8) & 0xFF) / 255.0
                            blue:(rgb & 0xFF) / 255.0
                           alpha:1.0];
}

UIColor *accentColor(void) {
    // Prefer the user-defined theme accent color, falling back to the default blue #429CF5 when unset
    NSString *hex = getPrefObject(@"general.accent_color");
    UIColor *custom = colorFromHex(hex);
    if (custom) return custom;
    // The default blue, RGB(0.26, 0.63, 0.96) = #429CF5
    return [UIColor colorWithRed:0.26 green:0.63 blue:0.96 alpha:1.0];
}

#pragma mark Safe area

CGRect getSafeArea(CGRect screenBounds) {
    UIEdgeInsets safeArea = UIEdgeInsetsFromString(getPrefObject(@"control.control_safe_area"));
    if (screenBounds.size.width < screenBounds.size.height) {
        safeArea = UIEdgeInsetsMake(safeArea.right, safeArea.top, safeArea.left, safeArea.bottom);
    }
    return UIEdgeInsetsInsetRect(screenBounds, safeArea);
}

void setSafeArea(CGSize screenSize, CGRect frame) {
    UIEdgeInsets safeArea;
    // TODO: make safe area consistent across opposite orientations?
    if (screenSize.width < screenSize.height) {
        safeArea = UIEdgeInsetsMake(
            frame.origin.x,
            screenSize.height - CGRectGetMaxY(frame),
            screenSize.width - CGRectGetMaxX(frame),
            frame.origin.y);
    } else {
        safeArea = UIEdgeInsetsMake(
            frame.origin.y,
            frame.origin.x,
            screenSize.height - CGRectGetMaxY(frame),
            screenSize.width - CGRectGetMaxX(frame));
    }
    setPrefObject(@"control.control_safe_area", NSStringFromUIEdgeInsets(safeArea));
}

UIEdgeInsets getDefaultSafeArea() {
    UIEdgeInsets safeArea = UIApplication.sharedApplication.windows.firstObject.safeAreaInsets;
    CGSize screenSize = UIScreen.mainScreen.bounds.size;
    if (screenSize.width < screenSize.height) {
        safeArea.left = safeArea.top;
        safeArea.right = safeArea.bottom;
    }
    safeArea.top = safeArea.bottom = 0;
    return safeArea;
}

#pragma mark Java runtime

NSString* getSelectedJavaHome(NSString* defaultJRETag, int minVersion) {
    NSDictionary *pref = getPrefObject(@"java.java_homes");
    NSDictionary<NSString *, NSString *> *selected = pref[@"0"];
    NSString *selectedVer = selected[defaultJRETag];
    if (minVersion > selectedVer.intValue) {
        NSArray *sortedVersions = [pref.allKeys valueForKeyPath:@"self.integerValue"];
        sortedVersions = [sortedVersions sortedArrayUsingSelector:@selector(compare:)];
        BOOL found = NO;
        for (NSNumber *version in sortedVersions) {
            if (version.intValue >= minVersion) {
                selectedVer = version.stringValue;
                found = YES;
                break;
            }
        }
        // Fix: the original code left selectedVer at its initial value (such as "17") when no runtime satisfied minVersion,
        // so if (!selectedVer) was never true and it silently fell back to Java 17, which always crashes on 26.x and later.
        if (!found) {
            NSLog(@"Error: requested Java >= %d was not installed! (available: %@)", minVersion, sortedVersions);
            return nil;
        }
    }

    id selectedDir = pref[selectedVer];
    if ([selectedDir isEqualToString:@"internal"]) {
        selectedDir = [NSString stringWithFormat:@"%@/java_runtimes/java-%@-openjdk", NSBundle.mainBundle.bundlePath, selectedVer];
    } else {
        selectedDir = [NSString stringWithFormat:@"%s/java_runtimes/%@", getenv("POJAV_HOME"), selectedDir];
    }

    if ([NSFileManager.defaultManager fileExistsAtPath:selectedDir]) {
        return selectedDir;
    } else {
        NSLog(@"Error: selected runtime for %@ does not exist: %@", defaultJRETag, selectedDir);
        return nil;
    }
}

#pragma mark Renderer
NSArray* getRendererKeys(BOOL containsDefault) {
    NSMutableArray *array = @[
        @"auto",
        @ RENDERER_NAME_GL4ES,
        @ RENDERER_NAME_MTL_ANGLE,
        @ RENDERER_NAME_MOBILEGLUES,
        @ RENDERER_NAME_VK_ZINK,
        @ RENDERER_NAME_LTW,
        @ RENDERER_NAME_VULKAN
    ].mutableCopy;

    if (containsDefault) {
        [array insertObject:@"(default)" atIndex:0];
    }
    
    return array;
}

NSArray* getRendererNames(BOOL containsDefault) {
    NSMutableArray *array;

    array = @[
        localize(@"preference.title.renderer.debug.auto", nil),
        localize(@"preference.title.renderer.debug.gl4es", nil),
        localize(@"preference.title.renderer.debug.angle", nil),
        localize(@"preference.title.renderer.debug.mg", nil),
        localize(@"preference.title.renderer.debug.zink", nil),
        localize(@"preference.title.renderer.debug.ltw", nil),
        localize(@"preference.title.renderer.debug.vulkan", nil)
    ].mutableCopy;

    if (containsDefault) {
        [array insertObject:@"(default)" atIndex:0];
    }

    return array;
}
