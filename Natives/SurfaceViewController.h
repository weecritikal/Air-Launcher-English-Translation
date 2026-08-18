#import <UIKit/UIKit.h>
#import "UIKit+hook.h"

#import "customcontrols/ControlLayout.h"
#import "GameSurfaceView.h"
#import "PLLogOutputView.h"

BOOL canAppendToLog;
dispatch_group_t fatalExitGroup;

CGRect virtualMouseFrame;
CGPoint lastVirtualMousePoint;

@interface SurfaceViewController : UIViewController

@property(nonatomic) ControlLayout *ctrlView;
@property(nonatomic) GameSurfaceView* surfaceView;
@property(nonatomic) UIView *touchView;
@property UIImageView* mousePointerView;
@property(nonatomic) UIPanGestureRecognizer* scrollPanGesture;

@property(nonatomic) UIView* rootView;

- (instancetype)initWithMetadata:(NSDictionary *)metadata;
- (void)sendTouchPoint:(CGPoint)location withEvent:(int)event;
- (void)updateSavedResolution;
- (void)updateGrabState;

+ (GameSurfaceView *)surface;
+ (BOOL)isRunning;
// Get the currently displayed SurfaceViewController instance
// Supports both being the rootViewController and being presented modally
+ (instancetype)currentInstance;

// LogView category
@property(nonatomic) PLLogOutputView* logOutputView;

// Navigation category
@property(nonatomic) NSArray *menuArray;
@property(nonatomic) UITableView *menuView;
@property(nonatomic) UIScreenEdgePanGestureRecognizer* edgeGesture;
@property(nonatomic) UIView *gameMenuOverlay; // FCL style floating button + FPS/memory display

@end

@interface SurfaceViewController(ExternalDisplay)

- (void)switchToExternalDisplay;
- (void)switchToInternalDisplay;

@end

@interface SurfaceViewController(LogView)

- (void)viewWillTransitionToSize_LogView:(CGRect)frame;

@end

@interface SurfaceViewController(Navigation)<UIGestureRecognizerDelegate, UITableViewDataSource, UITableViewDelegate>

- (void)actionOpenNavigationMenu;
- (void)didSelectMenuItem:(int)item;
- (void)viewWillTransitionToSize_Navigation:(CGRect)frame;
// FCL style in-game menu actions
- (void)actionToggleControls;        // Hide/show control buttons
- (void)actionToggleVirtualMouse;    // Virtual mouse toggle
- (void)actionToggleKeyboard;        // In-game keyboard toggle
- (void)actionAdjustResolution;      // Resolution adjustment
- (void)actionOpenMultiplayer;       // Multiplayer (ZeroTier)

@end
