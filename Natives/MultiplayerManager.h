#import <Foundation/Foundation.h>
#import "ZeroTierBridge.h"

NS_ASSUME_NONNULL_BEGIN

/// Multiplayer room status
typedef NS_ENUM(NSInteger, MultiplayerRoomStatus) {
    MultiplayerRoomStatusDisconnected = 0, // Not connected
    MultiplayerRoomStatusConnecting   = 1, // Connecting
    MultiplayerRoomStatusConnected    = 2, // Connected
    MultiplayerRoomStatusError        = 3  // Error
};

/// Multiplayer room role
///
/// Key fix (replacing the IP heuristic):
/// Guest identity used to be inferred from `hostIP != localIP`, which had these problems:
///   - the hostIP in the host's share code and the localIP assigned to the guest could, rarely, be the same
///     (almost never with adhoc IPv6, but possible on a standard network with a small IPv4 pool or an unusual configuration)
///   - a guest was then wrongly identified as the host, PortForwarder never started, and MC could not connect with no error shown
/// The role is now declared explicitly: the host sets Host when creating a room, and the guest sets Guest in parseShareCode.
/// It is serialized, so it survives across processes and sessions.
typedef NS_ENUM(NSInteger, MultiplayerRoomRole) {
    MultiplayerRoomRoleUnknown = 0, // Unknown (for compatibility with old data)
    MultiplayerRoomRoleHost    = 1, // Host
    MultiplayerRoomRoleGuest   = 2, // Guest
};

/// Multiplayer room model
@interface MultiplayerRoom : NSObject <NSCoding, NSSecureCoding>
@property (nonatomic, copy) NSString *roomId;          // Unique identifier (a UUID)
@property (nonatomic, copy) NSString *name;            // Room name
@property (nonatomic, copy) NSString *networkId;       // The ZeroTier network ID (16 hexadecimal digits)
/// The host IP on the ZeroTier network (such as 10.147.17.1, or an IPv6 address in ad-hoc mode).
///
/// Key fix (M13): hostIP is now atomic, matching status (the H12 fix).
/// hostIP is written in connectToRoomFlow: (a background utility queue, inside _stateLock) and
/// zeroTierNetworkReady: (the main thread, inside _stateLock), but read without a lock on the main thread
/// in UI cells, shareTextForRoom:, lanPortDidDetect: and elsewhere.
/// atomic makes each getter/setter call atomic, so no intermediate state can be read.
@property (atomic, copy) NSString *hostIP;          // The host IP on the ZeroTier network (such as 10.147.17.1)
/// The MC server port (25565 by default).
///
/// Key fix: hostPort is now atomic. It is modified on the main thread (in generateShareCodeWithPort:
/// and similar) and read on a background thread (connectToRoomFlow reads it to decide whether this is guest mode).
/// A nonatomic property can be read mid-write across threads, while atomic makes each getter/setter atomic.
@property (atomic, copy) NSString *hostPort;        // The MC server port (25565 by default)
@property (nonatomic, copy) NSString *roomDescription; // Room description
/// Connection status.
///
/// Key fix (H12): status is now atomic, guaranteeing memory consistency across threads.
/// It was previously nonatomic assign, which had these problems:
///   - the background connection thread (MultiplayerManager.connectToRoomFlow) writes status
///   - the main thread (MultiplayerViewController) reads status for the UI
///   - the main thread also writes status (such as when the disconnect button is tapped)
///   - reading and writing a nonatomic property from several threads can read a partially written or stale value
///
/// An atomic property uses an underlying lock to make each getter/setter call atomic,
/// so no intermediate state can be read. For a single-value property like a state machine, atomic is enough.
///
/// Note: atomic does not make compound operations (such as read-modify-write) atomic,
/// so complex state transitions must still be protected by the caller with a lock (such as MultiplayerManager._stateLock).
@property (atomic, assign) MultiplayerRoomStatus status; // Connection status
/// The room role (host/guest).
///
/// Key fix: replaces the fragile heuristic that inferred identity by comparing IPs.
/// atomic guarantees memory consistency across threads (as it does for status).
/// When old data is deserialized without this field it defaults to Unknown and falls back to the IP heuristic for compatibility.
@property (atomic, assign) MultiplayerRoomRole role;   // Room role
@property (nonatomic, copy) NSString *ownerName;       // Host name
@property (nonatomic, strong) NSDate *createdAt;       // Creation time
@property (nonatomic, strong) NSDate *lastConnectedAt; // Last connection time
@end

/// Delegate for multiplayer state changes
///
/// When the ZeroTier node or network state changes, the delegate is notified.
/// Every callback runs on the main thread.
@protocol MultiplayerManagerDelegate <NSObject>
@optional

/// The ZeroTier node came online
- (void)multiplayerNodeOnline;

/// The ZeroTier node went offline
- (void)multiplayerNodeOffline;

/// The given room connected successfully (the network is ready and the SOCKS5 proxy has started)
/// @param room The room that connected
- (void)multiplayerRoomConnected:(MultiplayerRoom *)room;

/// The given room failed to connect
/// @param room The room that failed to connect
/// @param error Error information
- (void)multiplayerRoom:(MultiplayerRoom *)room
   didFailWithError:(NSError *)error;

/// The result of the ZeroTier framework availability check
/// @param available YES means zt.framework is loaded (and not a stub)
- (void)multiplayerFrameworkAvailabilityChecked:(BOOL)available;

/// Connection flow progress update
///
/// Called at each step of connectToRoomFlow: to report progress to the UI.
/// It lets the user see detailed progress such as "starting the node" and "joining the network",
/// rather than a static "Connecting..." message.
///
/// @param message The progress text (such as "Step 2: waiting for the node to come online...")
- (void)multiplayerConnectionProgress:(NSString *)message;

@end

/// ZeroTier multiplayer manager
///
/// Modelled on the MultiplayerManager of FCL and the LanServerManager of ZL2:
/// 1. manages the local room list (create/read/update/delete)
/// 2. joins/leaves a ZeroTier network in-process through the ZeroTier Apple Framework (zt.framework)
/// 3. starts a local SOCKS5 proxy that forwards Minecraft traffic onto the ZeroTier virtual network
/// 4. detects whether zt.framework is available (and not a stub)
/// 5. manages the current connection state
/// 6. generates the share information (room name + network ID + IP + port)
///
/// Unlike the older URL-scheme-based implementation, this version runs the ZeroTier node entirely inside the app process,
/// so it needs neither the external ZeroTier One app nor NetworkExtension entitlements.
/// Traffic is forwarded through the local SOCKS5 proxy (127.0.0.1:1080), with Minecraft using the proxy via the JVM
/// -DsocksProxyHost/-DsocksProxyPort arguments.
@interface MultiplayerManager : NSObject

+ (instancetype)sharedManager;

/// The delegate (a weak reference)
@property (nonatomic, weak, nullable) id<MultiplayerManagerDelegate> delegate;

/// The room currently connected (nil means nothing is connected)
///
/// Key fix (M1): now atomic, guaranteeing memory consistency across threads.
/// currentRoom is accessed in connectToRoom (the main thread), connectToRoomFlow (a background utility queue),
/// and disconnectCurrentRoom (any thread), and read from the UI, the delegate callbacks and elsewhere.
/// atomic makes each getter/setter call atomic, so no intermediate state can be read.
@property (atomic, strong, readonly, nullable) MultiplayerRoom *currentRoom;

/// Every saved room
@property (nonatomic, strong, readonly) NSArray<MultiplayerRoom *> *savedRooms;

/// The port the SOCKS5 proxy is listening on (0 when the proxy is not running)
///
/// Key fix (M1): now atomic, matching currentRoom.
@property (atomic, assign, readonly) uint16_t currentSOCKS5Port;

/// Whether the SOCKS5 proxy is running
@property (nonatomic, assign, readonly) BOOL isSOCKS5ProxyRunning;

/// The local port the port forwarder is listening on (0 when it is not running)
///
/// Once a guest connects, PortForwarder listens on a local port (such as 25565)
/// and forwards to the host ZeroTier IP and MC LAN port. The guest can then enter
/// 127.0.0.1:<that port> in Minecraft to join the host's game.
@property (atomic, assign, readonly) uint16_t currentForwardingPort;

/// Whether the port forwarder is running
@property (nonatomic, assign, readonly) BOOL isPortForwarderRunning;

/// Whether the ZeroTier node is online
@property (nonatomic, assign, readonly) BOOL isNodeOnline;

/// The local IP assigned to the current room on the ZeroTier network (which can be shown to the user)
/// Only valid once the room is connected and ZeroTier has assigned an IP
///
/// Key fix (M1): now atomic, matching currentRoom.
@property (atomic, copy, readonly, nullable) NSString *currentLocalIP;

#pragma mark - 框架检测

/// Detect whether zt.framework is available (and not a stub implementation)
///
/// This delegates to isFrameworkAvailable on ZeroTierBridge, and the result is cached.
/// The ZeroTier Apple Framework comes in as a git submodule, and the build links the prebuilt
/// zt.framework inside it. If the submodule is not initialized, the build fails.
///
/// @return YES when the framework is available
- (BOOL)isFrameworkAvailable;

/// Whether the user has enabled multiplayer (persisted to NSUserDefaults)
///
/// This is independent of isNodeStarted and reflects the user's intent rather than the actual node state.
/// It is used to restore the multiplayer switch when the view controller reloads.
///
/// The scenario: the user turns the multiplayer switch ON -> the ZeroTier node starts in the background (taking several seconds) ->
/// the user closes the multiplayer view controller -> the user reopens it ->
/// the node may still be starting (isNodeStarted=NO), but the user has already expressed the intent
/// (isMultiplayerEnabled=YES), so the switch should read ON.
///
/// Once the node starts successfully the switch stays ON while isMultiplayerEnabled=YES;
/// if the node fails to start, the caller should set isMultiplayerEnabled to NO and revert the switch.
///
/// This property is persisted to NSUserDefaults, so the multiplayer setting survives closing the launcher (killing the process)
/// and reopening it (though the node does not start automatically; the user has to use the switch again).
///
/// @return YES when the user has enabled multiplayer
- (BOOL)isMultiplayerEnabled;

/// Set the multiplayer enabled state (persisted to NSUserDefaults)
/// @param enabled YES means the user has enabled multiplayer
- (void)setMultiplayerEnabled:(BOOL)enabled;

/// Whether the ZeroTier node has started
/// @return YES when the node has started (it need not be online yet)
- (BOOL)isNodeStarted;

/// Start the ZeroTier node
///
/// If the node has not started yet, it is started on a background thread.
/// Once started, it fires the ZTS_EVENT_NODE_ONLINE event asynchronously.
///
/// @param completion Completion callback (main thread; YES means the start request was submitted successfully)
- (void)ensureNodeStartedWithCompletion:(void (^)(BOOL success, NSError * _Nullable error))completion;

#pragma mark - 兼容旧 API（已废弃，仅用于平滑过渡）

/// Detect whether the ZeroTier One app is installed (deprecated)
///
/// The old URL-scheme-based implementation had to detect whether the external ZeroTier One app was installed.
/// Newer versions use the in-process zt.framework and no longer depend on an external app.
/// This method now returns the result of isFrameworkAvailable, keeping the API compatible.
///
/// @return YES when zt.framework is available
- (BOOL)isZeroTierAppInstalled __attribute__((deprecated("Use isFrameworkAvailable instead")));

/// Override the ZeroTier install state (deprecated; a no-op in newer versions)
/// @param installed A deprecated parameter with no effect
- (void)setZeroTierInstalledOverride:(BOOL)installed __attribute__((deprecated("Newer versions do not need the install state overridden manually")));

/// Whether the user has overridden the ZeroTier install state by hand (deprecated)
/// @return Always NO
- (BOOL)isZeroTierInstallOverridden __attribute__((deprecated("Newer versions always return NO")));

/// Open the ZeroTier One app (deprecated; a no-op in newer versions)
- (void)openZeroTierApp __attribute__((deprecated("Newer versions use an in-process framework, so there is no external app to open")));

#pragma mark - 网络加入与离开

/// Join a ZeroTier network by network ID
///
/// This calls zts_net_join in-process to join the given network.
/// If the node has not started, it is started first.
///
/// @param networkId The ZeroTier network ID (16 hexadecimal digits)
/// @param completion Completion callback (main thread; YES means the join request was submitted, not that the network is ready)
- (void)joinNetwork:(NSString *)networkId
         completion:(nullable void (^)(BOOL success, NSError * _Nullable error))completion;

/// Leave a ZeroTier network
///
/// This calls zts_net_leave in-process to leave the given network.
///
/// @param networkId ZeroTier Network ID
/// @return YES when leaving succeeded; NO when it failed (an invalid parameter or a failing underlying call).
///         The caller can use the return value to decide whether to force a stopNode cleanup.
- (BOOL)leaveNetwork:(NSString *)networkId;

#pragma mark - 房间管理（增删改查）

/// Add a room to the local list
/// @param room The room object
- (void)addRoom:(MultiplayerRoom *)room;

/// Delete a room
/// @param roomId The room ID
- (void)removeRoom:(NSString *)roomId;

/// Update a room
/// @param room The updated room object
- (void)updateRoom:(MultiplayerRoom *)room;

/// Get a room
/// @param roomId The room ID
- (nullable MultiplayerRoom *)roomWithId:(NSString *)roomId;

#pragma mark - 连接管理

/// Connect to a room
///
/// The full flow (6 steps):
///   1. check that the framework is available (failing immediately if it is not)
///   2. start the ZeroTier node (if it has not started)
///   3. wait for the node to come online (30 second timeout)
///   4. join the ZeroTier network
///   5. wait for the network to be ready (an IPv4 or ad-hoc IPv6 address assigned, 30 second timeout)
///   6. start the local SOCKS5 proxy (port 1080) and the port forwarder:
///      - guest mode: PortForwarder in guest mode (local 25565 -> the host ZeroTier IP:port)
///      - host mode: PortForwarder is not started immediately; once the user enters the MC LAN port,
///        startHostPortForwarderWithListenPort:localHostPort: starts host mode
///
/// Telling host and guest apart:
///   - the host connecting for the first time: room.hostIP is empty -> this device's ZeroTier IP is copied into room.hostIP at the end of the flow
///   - a guest connecting: room.hostIP is already the host IP (from the share code) -> it is left untouched
///
/// A failure at any step sets the room status to Error and calls completion(NO, error).
///
/// @param room       The room object
/// @param completion Completion callback (main thread)
- (void)connectToRoom:(MultiplayerRoom *)room
           completion:(void (^)(BOOL success, NSError * _Nullable error))completion;

/// Disconnect from the current room
///
/// The flow:
///   1. stop the local SOCKS5 proxy
///   2. clear the AMETHYST_SOCKS5_PROXY environment variable
///   3. leave the ZeroTier network
///   4. set the room status to Disconnected
///   5. clear currentRoom
- (void)disconnectCurrentRoom;

/// Start PortForwarder in host mode (reverse forwarding)
///
/// The host calls this after opening the world to LAN in Minecraft and entering the MC LAN port.
/// PortForwarder listens on listenPort on the ZeroTier network and forwards connections to
/// the local 127.0.0.1:localHostPort (the MC LAN port), so PC/Mac/Android/iOS guests
/// can join the game directly through the host ZeroTier IP:listenPort.
///
/// Precondition: the current room is connected (self.currentRoom is non-nil and status == Connected).
///
/// @param listenPort The port to listen on within the ZeroTier network (usually 25565)
/// @param localHostPort The local MC LAN port (the one Minecraft shows in the chat box after "Open to LAN")
/// @return YES when it started successfully, NO on failure (such as no connected room, or PortForwarder failing to start)
- (BOOL)startHostPortForwarderWithListenPort:(uint16_t)listenPort
                               localHostPort:(uint16_t)localHostPort;

/// Stop every multiplayer service (a full cleanup)
///
/// Called when the world closes, the game quits, or the app goes to the background or is terminated, so every resource is released:
///   1. stop the SOCKS5 proxy
///   2. stop the port forwarder
///   3. clear the AMETHYST_SOCKS5_PROXY environment variable
///   4. leave every ZeroTier network
///   5. stop the ZeroTier node
///   6. reset every piece of state
///   7. clear any leftover serverIp in PLProfiles
- (void)stopAllMultiplayerServices;

#pragma mark - 分享与导入

/// Generate the share text for a room
/// @param room The room object
/// @return The share text
- (NSString *)shareTextForRoom:(MultiplayerRoom *)room;

/// Parse room information out of share text
/// @param text The share text
/// @return The parsed room object (nil when parsing fails)
- (nullable MultiplayerRoom *)parseRoomFromShareText:(NSString *)text;

/// Generate a new ZeroTier-style room ID (a UUID)
- (NSString *)generateRoomId;

#pragma mark - 分享代码（FCL 风格 Base64 编码）

/// Generate the share code for a room (base64-encoded JSON)
///
/// Equivalent to the FCL multiplayer share code: the host opens the world to LAN, a code is generated automatically,
/// and a guest joins the room by entering it.
///
/// Code format: Base64(JSON), where the JSON holds:
///   - networkId: ZeroTier Network ID
///   - hostIP: the host IP on the ZeroTier network
///   - hostPort: the MC server port (the LAN port or 25565)
///   - roomName: the room name
///
/// @param room The room object
/// @return The base64-encoded share code
- (NSString *)generateShareCodeForRoom:(MultiplayerRoom *)room;

/// Parse room information out of a share code (base64-encoded JSON)
///
/// @param code The base64-encoded share code
/// @return The parsed room object (nil when parsing fails)
- (nullable MultiplayerRoom *)parseShareCode:(NSString *)code;

#pragma mark - 预设 Network ID 管理（FCL 风格）

/// Get the ZeroTier network ID the user preset
///
/// Equivalent to FCL: the host sets a network ID once (after creating it at my.zerotier.com)
/// and it is reused automatically every time they host, with no re-entering.
///
/// @return The preset network ID (nil when unset)
- (nullable NSString *)presetNetworkId;

/// Set the preset ZeroTier network ID
/// @param networkId The network ID (passing nil or an empty string clears it)
- (void)setPresetNetworkId:(nullable NSString *)networkId;

#pragma mark - Ad-hoc 网络（快速模式，无需注册账号）

/// Generate an ad-hoc network ID (quick mode)
///
/// Equivalent to the FCL "play together with no registration" experience:
///   - zts_net_compute_adhoc_id generates a public network ID that needs no network controller
///   - the host and guests join the same network simply by using the same port range
///   - there is no need to register at my.zerotier.com, create a network or authorize members
///
/// Notes:
///   1. an ad-hoc network only has IPv6 addresses (no IPv4)
///   2. the network is public and anyone can join (so it is less secure)
///   3. the IP is assigned automatically from the node ID and may change (less stable than standard mode)
///   4. the port range is limited: the MC server port and LAN port must fall inside it
///
/// To cover every port Minecraft may use (25565 and the random LAN ports 49152-65535),
/// this method uses the full 0-65535 range.
///
/// @return The ad-hoc network ID as a 16-digit hexadecimal string
- (NSString *)generateAdhocNetworkId;

/// Whether a network ID belongs to an ad-hoc network
///
/// Ad-hoc network IDs start with "ff" (such as ff0000ffff000000).
/// Used to tell standard mode from quick mode during the connection flow.
///
/// @param networkId The network ID to test
/// @return YES when it is an ad-hoc network
- (BOOL)isAdhocNetworkId:(NSString *)networkId;

#pragma mark - 校验工具

/// Validate the format of a ZeroTier network ID
/// @param networkId The network ID string to check
/// @return YES when the format is valid
- (BOOL)isValidNetworkId:(NSString *)networkId;

/// Validate the format of an IP address
/// @param ipAddress The IP address string to check
/// @return YES when the format is valid
- (BOOL)isValidIPAddress:(NSString *)ipAddress;

@end

NS_ASSUME_NONNULL_END
