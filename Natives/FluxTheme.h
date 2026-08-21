#import <UIKit/UIKit.h>

/// The one place Flux's brand colours are defined.
///
/// Before this, the launcher had no accent identity: interactive elements used
/// UIKit's default blue, which reads as "a generic iOS app" rather than as this one,
/// and the accent was spelled out at 76 separate call sites.
///
/// Only brand colours belong here. UIKit's semantic colours - labelColor,
/// systemBackground, secondaryLabel and the rest - already adapt correctly to light
/// and dark mode and to accessibility settings, and are used in 268 places. Wrapping
/// those would gain nothing and lose the system behaviour. The colours the launcher
/// uses to *categorise* things (purple for shaders, orange for resource packs, and so
/// on) are a deliberate code and are also left alone: they carry meaning, not brand.
@interface FluxTheme : NSObject

/// The brand accent - tints, chips, progress, primary buttons, selection.
/// Mint in dark mode, a deeper teal in light mode, so it holds contrast against both.
@property (class, nonatomic, readonly) UIColor *accent;

/// The accent at low opacity, for chip and badge backgrounds that sit behind text.
@property (class, nonatomic, readonly) UIColor *accentSubtle;

/// Foreground to place *on top of* an accent-filled surface.
@property (class, nonatomic, readonly) UIColor *onAccent;

@end
