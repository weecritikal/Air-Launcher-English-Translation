//
//  GameMenuOverlayView.h
//  Flux
//
//  Modelled on the floating button design of FCL MenuView and ZL2 GameScreen:
//  - a draggable round settings button (with its position persisted), replacing the old right-swipe strip
//  - a draggable FPS/memory label (with its position persisted), toggleable from the menu
//  - tapping the settings button fires a callback (opening the menu)
//  - hitTest pass-through: only the button/label areas capture touches, and everything else passes through to the game
//

#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

/// In-game floating overlay: settings button + FPS/memory display
/// Modelled on the floating button design of FCL MenuView.java and ZL2 GameScreen.kt
@interface GameMenuOverlayView : UIView

/// Settings button tap callback (opens the menu)
@property (nonatomic, copy, nullable) void (^onMenuButtonTapped)(void);

/// Show/hide the whole overlay (the hideMenuView concept from FCL)
@property (nonatomic, assign) BOOL overlayHidden;

/// Whether the FPS/memory stats label is shown (toggleable from the menu, as in FCL)
@property (nonatomic, assign) BOOL statsLabelVisible;

/// Initialize and add to the given parent view
- (instancetype)initWithParentView:(UIView *)parentView;

/// Update the FPS and memory display (driven by the game loop; every 500ms~1s is recommended)
/// Must be called on the main thread
- (void)updateFPS:(NSInteger)fps memoryUsageMB:(double)memoryMB;

/// Load the persisted position from the preferences
- (void)restorePositions;

/// Save the current position to the preferences
- (void)savePositions;

/// Toggle the FPS/memory display on or off
- (void)toggleStatsLabel;

@end

NS_ASSUME_NONNULL_END
