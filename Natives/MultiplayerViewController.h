#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

/// Multiplayer screen modes (following the FCL multiplayer flow)
typedef NS_ENUM(NSInteger, MultiplayerVCMode) {
    /// Launcher mode (before the game starts):
    /// shows the multiplayer switch + the preset network ID setting + the room list
    /// The user enables multiplayer and sets their own ZeroTier network ID on this page
    MultiplayerVCModeLauncher = 0,

    /// In-game mode (after the game starts, reached from the floating button menu):
    /// shows the "Host" and "Guest" options
    /// Host: detect the LAN port automatically -> generate a share code
    /// Guest: enter a share code -> join the network -> set up the SOCKS5 proxy
    MultiplayerVCModeInGame = 1,
};

/// The Minecraft multiplayer screen (rebuilt after the FCL multiplayer flow)
///
/// Matching the multiplayer experience of FCL (FoldCraftLauncher):
/// - before launching: turn on the switch on the multiplayer screen to enable multiplayer
/// - after launching: open the multiplayer screen from the floating button menu and choose host or guest
/// - host: create a world -> open it to LAN -> read the port automatically -> generate a share code
/// - guest: enter the share code -> see the room on the Minecraft multiplayer screen
///
/// The network ID is preset: the host sets it once (after creating it at my.zerotier.com),
/// after which it is used automatically every time they host, and the share code carries it.
@interface MultiplayerViewController : UIViewController

/// Initialize the multiplayer screen
/// @param mode The screen mode (launcher / in-game)
- (instancetype)initWithMode:(MultiplayerVCMode)mode;

@end

NS_ASSUME_NONNULL_END
