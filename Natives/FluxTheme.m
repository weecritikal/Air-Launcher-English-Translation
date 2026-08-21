#import "FluxTheme.h"

@implementation FluxTheme

/// Both stops are taken from the app icon's own palette, so the accent and the icon
/// are the same colour rather than two greens that nearly match.
static UIColor *FluxDynamic(UIColor *light, UIColor *dark) {
    return [UIColor colorWithDynamicProvider:^UIColor *(UITraitCollection *traits) {
        return traits.userInterfaceStyle == UIUserInterfaceStyleDark ? dark : light;
    }];
}

+ (UIColor *)accent {
    static UIColor *c;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        // Both stops are contrast-checked, because the accent is used as a filled
        // background with text on it, not only as a tint:
        //   light  #07856B - white text on it 4.59:1, against white bg 4.59:1
        //   dark   #66E6CA - dark text on it 12.06:1, against systemBackground 11.13:1
        // The dark stop on a white background is 1.53:1, which is why light mode needs
        // its own value rather than one shared colour.
        c = FluxDynamic([UIColor colorWithRed:0.027 green:0.522 blue:0.420 alpha:1.0],
                        [UIColor colorWithRed:0.400 green:0.902 blue:0.792 alpha:1.0]);
    });
    return c;
}

+ (UIColor *)accentSubtle {
    static UIColor *c;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        c = FluxDynamic([UIColor colorWithRed:0.027 green:0.522 blue:0.420 alpha:0.14],
                        [UIColor colorWithRed:0.400 green:0.902 blue:0.792 alpha:0.18]);
    });
    return c;
}

+ (UIColor *)onAccent {
    static UIColor *c;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        // Dark text on the light-mode accent would be unreadable, and white on the
        // bright dark-mode mint likewise - so this inverts with the accent, not with
        // the interface style in the usual direction.
        c = FluxDynamic(UIColor.whiteColor,
                        [UIColor colorWithRed:0.02 green:0.09 blue:0.08 alpha:1.0]);
    });
    return c;
}

@end
