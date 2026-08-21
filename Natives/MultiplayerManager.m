//
//  MultiplayerManager.m
//  Flux
//
//  Implementation of the Minecraft multiplayer manager built on the ZeroTier Apple Framework
//
//  ============================================================================
//  Design rationale and references
//  ============================================================================
//
//  This file follows the multiplayer manager designs of these open-source projects:
//
//  1. FCL (FoldCraftLauncher) - an MC launcher for Android
//     - its MultiplayerManager calls libzt through JNI to build the ZeroTier virtual network
//       in-process, with no external app needed. This implementation takes the same in-process approach.
//     - FCL starts a local SOCKS5 proxy (on libzt sockets) that forwards Minecraft traffic
//       onto the ZeroTier network. This implementation reproduces that design exactly.
//
//  2. ZL2 (ZalithLauncher) - an MC launcher for Android (a PojavLauncher fork)
//     - its LanServerManager is also built on ZeroTier and provides room cards,
//       share code import, and integration with the built-in "Add Server" feature of Minecraft.
//
//  3. ShardLauncher-iOS - an MC launcher for iOS
//     - brings in zerotier-sockets-apple-framework (zt.framework) as a git submodule
//     - wraps the libzt C API in a ZeroTierBridge singleton
//     - shortcoming: creating a room sends the user to my.zerotier.com. This implementation fixes that
//       and keeps the whole flow inside the app (entering a network ID is enough to join, with no detour).
//
//  The iOS strategy:
//    1. link zt.framework (zerotier-sockets-apple-framework) directly and run the ZeroTier node
//       in-process. No NetworkExtension entitlement is needed; it runs purely in user space.
//    2. start a local SOCKS5 proxy (127.0.0.1:1080) that forwards traffic onto the ZeroTier
//       virtual network through the libzt BSD socket API.
//    3. Minecraft goes through the SOCKS5 proxy via the JVM arguments -DsocksProxyHost=127.0.0.1 -DsocksProxyPort=1080,
//       so all its traffic reaches the host server over the ZeroTier network.
//    4. the launcher keeps a local "multiplayer room" list (room name + network ID + host IP + port),
//       persisted with NSUserDefaults + NSKeyedArchiver (NSSecureCoding).
//    5. the launcher offers a "share text" feature that packs the room information into formatted text,
//       easy to send to friends over WeChat/QQ/iMessage and other channels.
//
//  About ZeroTier network IDs:
//    - a 16-digit hexadecimal string (a 64-bit unsigned integer)
//    - obtained after the user creates a network at https://my.zerotier.com
//    - the host either sets the network to "Private" and authorizes members, or to "Public" so anyone can join
//    - once joined, ZeroTier assigns each node a virtual IP (such as 10.147.17.x)
//
//  ZeroTier framework integration:
//    Following ShardLauncher-iOS, zerotier-sockets-apple-framework comes in as a git submodule
//    (Natives/external/ZeroTierFramework) and is checked out/updated with the repository, so it cannot go stale
//    the way a manual copy would. The build links the prebuilt zt.framework inside the submodule directly.
//    If the submodule is not initialized, CMake errors out and tells you to run git submodule update --init.
//
//  ============================================================================

#import "MultiplayerManager.h"
#import "ZeroTierBridge.h"
#import "SOCKS5Proxy.h"
#import "PortForwarder.h"
#import "LauncherPreferences.h"
#import "PLProfiles.h"
#import <UIKit/UIKit.h>  // For UIApplicationDidEnterBackgroundNotification and friends (the P0-B lifecycle observers)
#import "utils.h"

#pragma mark - Constant definitions

/// The NSUserDefaults key that stored the room list
///
/// Key fix (removing saved room history): this key is now only used for a one-off migration cleanup
/// and no longer persists the room list. The user made clear they do not want saved room history
/// (FCL does not have it either), so the room list should be empty on every launcher start.
/// Any old data found at startup is cleared.
static NSString * const kMultiplayerSavedRoomsKey = @"multiplayer_saved_rooms";

/// The NSUserDefaults key that stores the multiplayer enabled state
/// It persists the user's intent to enable multiplayer, independent of whether the node has actually started.
static NSString * const kMultiplayerEnabledKey = @"multiplayer.enabled";

/// The default Minecraft server port
static NSString * const kDefaultMCPort = @"25565";

/// The prefixes used in the share text (for both generating and parsing it)
static NSString * const kShareHeaderLine = @"🎮 Let's play together!";
static NSString * const kShareRoomNamePrefix = @"Room name: ";
static NSString * const kShareNetworkIdPrefix = @"ZeroTier Network ID: ";
static NSString * const kShareServerAddressPrefix = @"Server address: ";

/// The default SOCKS5 proxy port (matching SOCKS5ProxyDefaultPort in SOCKS5Proxy.h)
static uint16_t const kMultiplayerDefaultSOCKS5Port = 1080;

/// The environment variable name passed to JavaLauncher, whose value is "127.0.0.1:port"
/// On seeing it, JavaLauncher injects the -DsocksProxyHost/-DsocksProxyPort arguments
static NSString * const kAMETHYSTSOCKS5ProxyEnvVar = @"AMETHYST_SOCKS5_PROXY";

/// Timeout for waiting for the ZeroTier node to come online (seconds)
static NSTimeInterval const kNodeOnlineTimeout = 30.0;

/// Timeout for waiting for the ZeroTier network to be ready (seconds)
static NSTimeInterval const kNetworkReadyTimeout = 30.0;

/// Name of the folder holding the ZeroTier node identity files (inside the app Documents folder)
static NSString * const kZeroTierHomeDirName = @"zerotier_home";

/// Error domain
static NSString * const kMultiplayerErrorDomain = @"MultiplayerManagerErrorDomain";

/// Error codes
typedef NS_ENUM(NSInteger, MultiplayerErrorCode) {
    MultiplayerErrorCodeRoomNotFound         = 1001, // Room not found
    MultiplayerErrorCodeRoomAlreadyExist     = 1002, // The room already exists (a duplicate roomId)
    MultiplayerErrorCodeInvalidNetworkId     = 1003, // Invalid network ID format
    MultiplayerErrorCodeInvalidRoom          = 1004, // Invalid room object
    MultiplayerErrorCodeParseShareTextFailed = 1005, // Failed to parse the share text
    MultiplayerErrorCodeFrameworkUnavailable = 1006, // zt.framework unavailable (stub mode)
    MultiplayerErrorCodeNodeStartFailed      = 1007, // The ZeroTier node failed to start
    MultiplayerErrorCodeNodeOnlineTimeout    = 1008, // Timed out waiting for the node to come online
    MultiplayerErrorCodeJoinNetworkFailed    = 1009, // Failed to join the network
    MultiplayerErrorCodeNetworkReadyTimeout  = 1010, // Timed out waiting for the network to be ready
    MultiplayerErrorCodeSOCKS5ProxyStartFailed = 1011, // The SOCKS5 proxy failed to start
};

#pragma mark - MultiplayerRoom implementation

@implementation MultiplayerRoom

/// Required by NSSecureCoding: declare that this class supports secure coding
+ (BOOL)supportsSecureCoding {
    return YES;
}

/// Convenience initializer
- (instancetype)initWithId:(NSString *)roomId
                      name:(NSString *)name
                 networkId:(NSString *)networkId
                    hostIP:(NSString *)hostIP
                  hostPort:(NSString *)hostPort {
    self = [super init];
    if (self) {
        _roomId = roomId ?: [[NSUUID UUID] UUIDString];
        _name = [name copy] ?: @"";
        _networkId = [networkId copy] ?: @"";
        _hostIP = [hostIP copy] ?: @"";
        _hostPort = [hostPort copy] ?: kDefaultMCPort;
        _roomDescription = @"";
        _status = MultiplayerRoomStatusDisconnected;
        _role = MultiplayerRoomRoleUnknown;
        _ownerName = @"";
        _createdAt = [NSDate date];
        _lastConnectedAt = nil;
    }
    return self;
}

#pragma mark - NSSecureCoding / NSCoding

- (instancetype)initWithCoder:(NSCoder *)coder {
    self = [super init];
    if (self) {
        _roomId = [coder decodeObjectOfClass:[NSString class] forKey:@"roomId"] ?: @"";
        _name = [coder decodeObjectOfClass:[NSString class] forKey:@"name"] ?: @"";
        _networkId = [coder decodeObjectOfClass:[NSString class] forKey:@"networkId"] ?: @"";
        _hostIP = [coder decodeObjectOfClass:[NSString class] forKey:@"hostIP"] ?: @"";
        _hostPort = [coder decodeObjectOfClass:[NSString class] forKey:@"hostPort"] ?: kDefaultMCPort;
        _roomDescription = [coder decodeObjectOfClass:[NSString class] forKey:@"description"] ?: @"";
        _ownerName = [coder decodeObjectOfClass:[NSString class] forKey:@"ownerName"] ?: @"";

        _createdAt = [coder decodeObjectOfClass:[NSDate class] forKey:@"createdAt"];
        _lastConnectedAt = [coder decodeObjectOfClass:[NSDate class] forKey:@"lastConnectedAt"];

        NSInteger statusValue = [coder decodeIntegerForKey:@"status"];
        if (statusValue < MultiplayerRoomStatusDisconnected ||
            statusValue > MultiplayerRoomStatusError) {
            statusValue = MultiplayerRoomStatusDisconnected;
        }
        _status = (MultiplayerRoomStatus)statusValue;

        // Key fix: the role field. Old data may not contain this key, and decodeObjectForKey: returns 0
        // (NSKeyedArchiver returns 0 from decodeIntegerForKey for a key that was never encoded),
        // which is MultiplayerRoomRoleUnknown, so the caller falls back to the IP heuristic for compatibility.
        NSInteger roleValue = [coder decodeIntegerForKey:@"role"];
        if (roleValue < MultiplayerRoomRoleUnknown ||
            roleValue > MultiplayerRoomRoleGuest) {
            roleValue = MultiplayerRoomRoleUnknown;
        }
        _role = (MultiplayerRoomRole)roleValue;
    }
    return self;
}

- (void)encodeWithCoder:(NSCoder *)coder {
    [coder encodeObject:self.roomId forKey:@"roomId"];
    [coder encodeObject:self.name forKey:@"name"];
    [coder encodeObject:self.networkId forKey:@"networkId"];
    [coder encodeObject:self.hostIP forKey:@"hostIP"];
    [coder encodeObject:self.hostPort forKey:@"hostPort"];
    [coder encodeObject:self.roomDescription forKey:@"description"];
    [coder encodeObject:self.ownerName forKey:@"ownerName"];
    [coder encodeObject:self.createdAt forKey:@"createdAt"];
    [coder encodeObject:self.lastConnectedAt forKey:@"lastConnectedAt"];
    [coder encodeInteger:(NSInteger)self.status forKey:@"status"];
    [coder encodeInteger:(NSInteger)self.role forKey:@"role"];
}

#pragma mark - Description methods (to make debugging easier)

- (NSString *)description {
    return [NSString stringWithFormat:@"<MultiplayerRoom: %p roomId=%@ name=%@ networkId=%@ host=%@:%@ status=%ld>",
            self,
            self.roomId,
            self.name,
            self.networkId,
            self.hostIP,
            self.hostPort,
            (long)self.status];
}

#pragma mark - Copying and equality (to make deduplication and comparison easy)

- (id)copyWithZone:(NSZone *)zone {
    MultiplayerRoom *copy = [[MultiplayerRoom alloc] init];
    copy.roomId = [self.roomId copy];
    copy.name = [self.name copy];
    copy.networkId = [self.networkId copy];
    copy.hostIP = [self.hostIP copy];
    copy.hostPort = [self.hostPort copy];
    copy.roomDescription = [self.roomDescription copy];
    copy.status = self.status;
    copy.role = self.role;
    copy.ownerName = [self.ownerName copy];
    copy.createdAt = [self.createdAt copy];
    copy.lastConnectedAt = [self.lastConnectedAt copy];
    return copy;
}

- (BOOL)isEqual:(id)object {
    if (self == object) return YES;
    if (![object isKindOfClass:[MultiplayerRoom class]]) return NO;
    MultiplayerRoom *other = (MultiplayerRoom *)object;
    return [self.roomId isEqualToString:other.roomId];
}

- (NSUInteger)hash {
    return self.roomId.hash;
}

@end

#pragma mark - MultiplayerManager implementation

@interface MultiplayerManager () <ZeroTierBridgeDelegate>
{
    /// The lock guarding reads and writes of the room list
    dispatch_queue_t _serializationQueue;

    /// The lock guarding the connection state (_currentRoom / _currentLocalIP / _nodeStarted and so on)
    NSLock *_stateLock;
}

/// The writable room list (declared readonly in the header)
@property (nonatomic, strong, readwrite) NSMutableArray<MultiplayerRoom *> *internalRooms;

/// The writable current room (declared readonly in the header)
/// Key fix (M1): now atomic, so the setter is atomic and no intermediate state can be read across threads.
@property (atomic, strong, readwrite, nullable) MultiplayerRoom *currentRoom;

/// The writable SOCKS5 port
/// Key fix (M1): now atomic, matching the header declaration
@property (atomic, assign, readwrite) uint16_t currentSOCKS5Port;

/// The writable local IP
/// Key fix (M1): now atomic, matching the header declaration
@property (atomic, copy, readwrite, nullable) NSString *currentLocalIP;

/// The writable port forwarder local port
@property (atomic, assign, readwrite) uint16_t currentForwardingPort;

/// Whether the ZeroTier node has started (which does not mean it is online)
@property (nonatomic, assign, readwrite) BOOL nodeStarted;

/// The network ID currently connecting (as a uint64_t, used to query state through ZeroTierBridge)
/// 0 means no network is currently connecting
@property (nonatomic, assign) uint64_t currentNetworkID;

/// The connection flow cancellation flag (SubTask 4.2: an explicit cancellation mechanism)
///
/// Set to YES by disconnectCurrentRoom and checked by connectToRoomFlow before each step.
/// This differs from the M5 "check whether currentRoom changed":
///   - M5 checked whether the room object had been replaced (over-defensive, and removed)
///   - this flag is only set on an explicit disconnect, making it a legitimate cancellation mechanism
@property (atomic, assign, readwrite) BOOL connectionCancelled;
@end

@implementation MultiplayerManager

#pragma mark - Singleton

+ (instancetype)sharedManager {
    static MultiplayerManager *shared = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        shared = [[self alloc] init];
    });
    return shared;
}

+ (instancetype)allocWithZone:(struct _NSZone *)zone {
    static MultiplayerManager *shared = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        shared = [super allocWithZone:zone];
    });
    return shared;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _serializationQueue = dispatch_queue_create("com.angelaura.multiplayer.serialization", DISPATCH_QUEUE_SERIAL);
        _stateLock = [[NSLock alloc] init];
        _internalRooms = [[NSMutableArray alloc] init];
        _currentRoom = nil;
        _currentSOCKS5Port = 0;
        _currentLocalIP = nil;
        _nodeStarted = NO;
        _currentNetworkID = 0;

        // Key fix (removing saved room history):
        // the room list is no longer loaded from NSUserDefaults, so it starts empty on every launch.
        // Any old data is cleared at the same time (a one-off migration), leaving nothing behind.
        [self cleanupLegacySavedRooms];

        // Set the ZeroTierBridge delegate, to receive node/network state callbacks
        [[ZeroTierBridge sharedInstance] setDelegate:self];

        // Key fix (P0-B): observe the iOS app lifecycle notifications
        // iOS background restrictions suspend/reclaim ZeroTier connections, so the node drops out often.
        // When the app goes to the background: record the current state, let libzt heal itself, and do not stop the node
        // When the app returns to the foreground: check the node state and, if it dropped, reconnect and restore the data plane
        // Note: the node is deliberately not stopped on backgrounding — the iOS background RunLoop still processes libzt events,
        // and the libzt NAT keepalive holds the connection for a while, so stopping it would only make reconnecting more expensive.
        [[NSNotificationCenter defaultCenter] addObserver:self
                                                 selector:@selector(applicationDidEnterBackground)
                                                     name:UIApplicationDidEnterBackgroundNotification
                                                   object:nil];
        [[NSNotificationCenter defaultCenter] addObserver:self
                                                 selector:@selector(applicationWillEnterForeground)
                                                     name:UIApplicationWillEnterForegroundNotification
                                                   object:nil];

        NSLog(@"[MultiplayerManager] Initialization complete (no legacy rooms loaded, room list empty, lifecycle listeners registered)");
    }
    return self;
}

#pragma mark - iOS app lifecycle handling

/// The app entered the background
/// The iOS backgrounding strategy:
///   - do not stop the ZeroTier node (libzt has its own NAT keepalive and survives a short spell in the background)
///   - record whether a multiplayer room is active, to decide whether to restore it on returning to the foreground
///   - NSTimer is suspended in the background, so the keepalive timer stops temporarily and resumes on return
- (void)applicationDidEnterBackground {
    [_stateLock lock];
    MultiplayerRoom *room = self.currentRoom;
    BOOL hasActiveRoom = (room != nil && self.currentNetworkID != 0);
    [_stateLock unlock];

    if (hasActiveRoom) {
        NSLog(@"[MultiplayerManager] App entered background: active multiplayer room exists (%@), "
              @"relying on libzt self-healing, will verify on foreground", room.name);
    } else {
        NSLog(@"[MultiplayerManager] App entered background: no active multiplayer rooms");
    }
}

/// The app returned to the foreground
///
/// The simplified strategy (following the spec):
///   - check the node state, and if it is still online check whether the data plane needs restoring
///   - if it dropped, do a single stopNode + startNodeWithHomeDirectory: + rejoin the network,
///     with no exponential backoff (the old automatic reconnect logic has been removed)
- (void)applicationWillEnterForeground {
    [_stateLock lock];
    MultiplayerRoom *room = self.currentRoom;
    uint64_t netID = _currentNetworkID;
    BOOL hasActiveRoom = (room != nil && netID != 0);
    [_stateLock unlock];

    if (!hasActiveRoom) {
        NSLog(@"[MultiplayerManager] App returned to foreground: no active multiplayer rooms, no recovery needed");
        return;
    }

    NSLog(@"[MultiplayerManager] App returned to foreground: active multiplayer room detected (%@), checking ZeroTier node status", room.name);

    // Check the node state asynchronously, so the main thread is not blocked
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        BOOL nodeOnline = [[ZeroTierBridge sharedInstance] isNodeOnline];
        if (nodeOnline) {
            // The node is still online, so check whether the data plane needs restoring
            NSLog(@"[MultiplayerManager] App returned to foreground: ZeroTier node still online, checking data plane");
            [self ensureDataPlaneRunningForCurrentRoom];
            return;
        }

        // The node dropped (iOS killed the connection in the background), so do a single stopNode + startNode + rejoin
        NSLog(@"[MultiplayerManager] App returned to foreground: ZeroTier node went offline (iOS background limit), restarting node");
        [[ZeroTierBridge sharedInstance] stopNode];

        // Reset the node-started flag, so ensureNodeStartedWithCompletion can start it again
        [self->_stateLock lock];
        self->_nodeStarted = NO;
        [self->_stateLock unlock];

        NSString *homeDir = [self zeroTierHomeDirectory];
        NSError *startError = nil;
        BOOL started = [[ZeroTierBridge sharedInstance] startNodeWithHomeDirectory:homeDir
                                                                             error:&startError];
        if (!started) {
            NSLog(@"[MultiplayerManager] App returned to foreground: node restart failed: %@",
                  startError.localizedDescription ?: @"Unknown error");
            return;
        }

        [self->_stateLock lock];
        self->_nodeStarted = YES;
        [self->_stateLock unlock];

        // Wait for the node to come online
        BOOL online = [[ZeroTierBridge sharedInstance] waitForNodeOnlineWithTimeout:kNodeOnlineTimeout];
        if (!online) {
            NSLog(@"[MultiplayerManager] App returned to foreground: node online timeout (%.0fs)", kNodeOnlineTimeout);
            return;
        }

        // Rejoin the network
        NSError *joinError = nil;
        if (![[ZeroTierBridge sharedInstance] joinNetwork:netID error:&joinError]) {
            NSLog(@"[MultiplayerManager] App returned to foreground: re-join network failed: %@",
                  joinError.localizedDescription ?: @"Unknown error");
            return;
        }

        // Wait for the network to be ready
        BOOL ready = [[ZeroTierBridge sharedInstance] waitForNetworkReady:netID
                                                                  timeout:kNetworkReadyTimeout];
        if (!ready) {
            NSLog(@"[MultiplayerManager] App returned to foreground: network ready wait failed (%.0fs)", kNetworkReadyTimeout);
            return;
        }

        // Update the local IP (the network-ready callback may update it too, but updating it here keeps the state correct)
        NSString *localIP = nil;
        if ([self isAdhocNetworkId:room.networkId]) {
            localIP = [[ZeroTierBridge sharedInstance] ipv6AddressForNetwork:netID];
        } else {
            localIP = [[ZeroTierBridge sharedInstance] ipv4AddressForNetwork:netID];
        }
        if (localIP.length > 0) {
            [self->_stateLock lock];
            self.currentLocalIP = localIP;
            [self->_stateLock unlock];
        }

        // Restore the data plane (SOCKS5 + PortForwarder)
        NSLog(@"[MultiplayerManager] App returned to foreground: node re-online, restoring data plane");
        [self ensureDataPlaneRunningForCurrentRoom];
    });
}

#pragma mark - Publicly exposed read-only properties

- (NSArray<MultiplayerRoom *> *)savedRooms {
    // Key fix (C2): remove dispatch_sync(dispatch_get_main_queue()),
    // because a dispatch_sync from a background thread to the main thread mixes two locking schemes with @synchronized(self)
    // and risks a deadlock (the main thread waiting for @synchronized while the background thread waits for the main thread).
    // The fix: guard reads and writes of _internalRooms with @synchronized alone and
    // return an immutable copy, so changes by the caller do not affect the internal state.
    @synchronized(self) {
        return [_internalRooms copy];
    }
}

- (BOOL)isSOCKS5ProxyRunning {
    return [[SOCKS5Proxy sharedProxy] isRunning];
}

- (BOOL)isPortForwarderRunning {
    return [[PortForwarder sharedForwarder] isRunning];
}

- (BOOL)isNodeOnline {
    return [[ZeroTierBridge sharedInstance] isNodeOnline];
}

#pragma mark - Multiplayer enable state management

/// Whether the user has enabled multiplayer (read from NSUserDefaults)
///
/// This is independent of isNodeStarted and reflects the user's intent rather than the actual node state.
/// It is used to restore the multiplayer switch when the view controller reloads.
- (BOOL)isMultiplayerEnabled {
    return [[NSUserDefaults standardUserDefaults] boolForKey:kMultiplayerEnabledKey];
}

/// Set the multiplayer enabled state (persisted to NSUserDefaults)
- (void)setMultiplayerEnabled:(BOOL)enabled {
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    if (enabled) {
        [defaults setBool:YES forKey:kMultiplayerEnabledKey];
    } else {
        [defaults setBool:NO forKey:kMultiplayerEnabledKey];
    }
    [defaults synchronize];
    NSLog(@"[MultiplayerManager] Multiplayer enabled state set to %d", enabled);
}

#pragma mark - Data persistence (disabled)

/// Clear the old saved room data (a one-off migration)
///
/// Key fix (removing saved room history):
/// the user made clear they do not want saved room history (FCL does not have it either).
/// This is called from init and clears any old room data left in NSUserDefaults.
/// Afterwards the room list lives purely in memory and is never persisted.
- (void)cleanupLegacySavedRooms {
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    NSData *legacyData = [defaults dataForKey:kMultiplayerSavedRoomsKey];
    if (legacyData && legacyData.length > 0) {
        NSLog(@"[MultiplayerManager] Detected legacy saved room data (%lu bytes), cleaning up...",
              (unsigned long)legacyData.length);
        [defaults removeObjectForKey:kMultiplayerSavedRoomsKey];
        [defaults synchronize];
        NSLog(@"[MultiplayerManager] Legacy room data cleared (room list no longer persisted)");
    }
}

/// loadRooms is deprecated (a no-op)
///
/// Key fix (removing saved room history): the room list is no longer loaded from NSUserDefaults.
/// It starts empty on every launcher start, and rooms only exist for the current session (in memory).
/// This is kept as a no-op for compatibility with any remaining callers (though init no longer calls it).
- (void)loadRooms {
    // No-op: the room list is no longer loaded from persistent storage
    @synchronized(self) {
        self.internalRooms = [[NSMutableArray alloc] init];
    }
}

/// saveRooms is deprecated (a no-op)
///
/// Key fix (removing saved room history): the room list is no longer persisted to NSUserDefaults.
/// This is kept as a no-op for compatibility with the many existing [self saveRooms] calls,
/// so none of them have to be changed. The room list lives purely in memory and is cleared when the launcher closes.
- (void)saveRooms {
    // No-op: the room list is no longer persisted to NSUserDefaults
    // The room list lives purely in memory and is cleared when the launcher closes
}

#pragma mark - Framework detection and node management

- (BOOL)isFrameworkAvailable {
    return [[ZeroTierBridge sharedInstance] isFrameworkAvailable];
}

- (BOOL)isNodeStarted {
    [_stateLock lock];
    BOOL started = _nodeStarted;
    [_stateLock unlock];
    return started;
}

/// Get the folder holding the ZeroTier node identity files
/// The zerotier_home subfolder inside the app Documents folder
- (NSString *)zeroTierHomeDirectory {
    NSArray *paths = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES);
    NSString *documentsDir = paths.firstObject ?: NSTemporaryDirectory();
    NSString *homeDir = [documentsDir stringByAppendingPathComponent:kZeroTierHomeDirName];

    NSFileManager *fm = [NSFileManager defaultManager];
    if (![fm fileExistsAtPath:homeDir]) {
        [fm createDirectoryAtPath:homeDir
      withIntermediateDirectories:YES
                       attributes:nil
                            error:nil];
    }
    return homeDir;
}

- (void)ensureNodeStartedWithCompletion:(void (^)(BOOL success, NSError * _Nullable error))completion {
    // If the node has already started, report success straight away
    if ([self isNodeStarted]) {
        NSLog(@"[MultiplayerManager] ZeroTier node already started, skipping duplicate start");
        if (completion) {
            dispatch_async(dispatch_get_main_queue(), ^{
                completion(YES, nil);
            });
        }
        return;
    }

    // Check whether the framework is available
    if (![[ZeroTierBridge sharedInstance] isFrameworkAvailable]) {
        NSLog(@"[MultiplayerManager] zt.framework unavailable, cannot start ZeroTier node");
        if (completion) {
            NSError *error = [NSError errorWithDomain:kMultiplayerErrorDomain
                                                  code:MultiplayerErrorCodeFrameworkUnavailable
                                              userInfo:@{NSLocalizedDescriptionKey: @"The ZeroTier framework is unavailable, so multiplayer cannot start"}];
            dispatch_async(dispatch_get_main_queue(), ^{
                completion(NO, error);
            });
        }
        return;
    }

    NSLog(@"[MultiplayerManager] Starting ZeroTier node...");

    // Start the node on a background thread, so the main thread is not blocked
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        NSString *homeDir = [self zeroTierHomeDirectory];
        NSError *startError = nil;
        BOOL success = [[ZeroTierBridge sharedInstance] startNodeWithHomeDirectory:homeDir
                                                                            error:&startError];
        if (success) {
            [self->_stateLock lock];
            self->_nodeStarted = YES;
            [self->_stateLock unlock];
            NSLog(@"[MultiplayerManager] ZeroTier node start request submitted, waiting for online...");
        } else {
            NSLog(@"[MultiplayerManager] ZeroTier node start failed: %@", startError.localizedDescription);
        }

        if (completion) {
            NSError *cbError = success ? nil : [NSError errorWithDomain:kMultiplayerErrorDomain
                                                                     code:MultiplayerErrorCodeNodeStartFailed
                                                                 userInfo:@{NSLocalizedDescriptionKey: startError.localizedDescription ?: @"The node failed to start"}];
            dispatch_async(dispatch_get_main_queue(), ^{
                completion(success, cbError);
            });
        }
    });
}

#pragma mark - Legacy API compatibility (deprecated)

- (BOOL)isZeroTierAppInstalled {
    // The old API: detect whether the external ZeroTier One app is installed
    // The new version: detect whether zt.framework is available
    return [self isFrameworkAvailable];
}

- (void)setZeroTierInstalledOverride:(BOOL)installed {
    // The old API: let the user override the ZeroTier install state
    // The new version: the in-process framework needs no such mechanism, so this is a no-op
    NSLog(@"[MultiplayerManager] setZeroTierInstalledOverride:%d is deprecated, no longer needed in new version", installed);
}

- (BOOL)isZeroTierInstallOverridden {
    // The old API: whether the user has overridden it
    // The new version: always NO
    return NO;
}

- (void)openZeroTierApp {
    // The old API: open the external ZeroTier One app
    // The new version: the framework is in-process, so there is no app to open and this is a no-op
    NSLog(@"[MultiplayerManager] openZeroTierApp is deprecated, new version uses in-process framework");
}

#pragma mark - Joining and leaving networks

- (void)joinNetwork:(NSString *)networkId
         completion:(void (^)(BOOL, NSError * _Nullable))completion {
    if (!networkId || networkId.length == 0) {
        if (completion) {
            NSError *error = [NSError errorWithDomain:kMultiplayerErrorDomain
                                                  code:MultiplayerErrorCodeInvalidNetworkId
                                              userInfo:@{NSLocalizedDescriptionKey: @"The network ID is empty"}];
            dispatch_async(dispatch_get_main_queue(), ^{
                completion(NO, error);
            });
        }
        return;
    }

    NSString *trimmedNetworkId = [networkId stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];

    if (![self isValidNetworkId:trimmedNetworkId]) {
        NSLog(@"[MultiplayerManager] joinNetwork: Invalid Network ID format: %@", trimmedNetworkId);
        if (completion) {
            NSError *error = [NSError errorWithDomain:kMultiplayerErrorDomain
                                                  code:MultiplayerErrorCodeInvalidNetworkId
                                              userInfo:@{NSLocalizedDescriptionKey: [NSString stringWithFormat:@"Invalid network ID format: %@", trimmedNetworkId]}];
            dispatch_async(dispatch_get_main_queue(), ^{
                completion(NO, error);
            });
        }
        return;
    }

    // Make sure the node has started before joining a network
    [self ensureNodeStartedWithCompletion:^(BOOL nodeStarted, NSError * _Nullable nodeError) {
        if (!nodeStarted) {
            if (completion) {
                dispatch_async(dispatch_get_main_queue(), ^{
                    completion(NO, nodeError);
                });
            }
            return;
        }

        // Run joinNetwork on a background thread (ZeroTierBridge is synchronous, but internally it only submits the request)
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
            uint64_t netID = [ZeroTierBridge parseNetworkIDFromString:trimmedNetworkId];
            if (netID == 0) {
                if (completion) {
                    NSError *error = [NSError errorWithDomain:kMultiplayerErrorDomain
                                                          code:MultiplayerErrorCodeInvalidNetworkId
                                                      userInfo:@{NSLocalizedDescriptionKey: @"Could not parse the network ID"}];
                    dispatch_async(dispatch_get_main_queue(), ^{
                        completion(NO, error);
                    });
                }
                return;
            }

            NSError *joinError = nil;
            BOOL success = [[ZeroTierBridge sharedInstance] joinNetwork:netID error:&joinError];
            if (success) {
                NSLog(@"[MultiplayerManager] Joined ZeroTier network %@, waiting for network ready...", trimmedNetworkId);
            } else {
                NSLog(@"[MultiplayerManager] Join ZeroTier network failed: %@", joinError.localizedDescription);
            }

            if (completion) {
                NSError *cbError = success ? nil : [NSError errorWithDomain:kMultiplayerErrorDomain
                                                                          code:MultiplayerErrorCodeJoinNetworkFailed
                                                                      userInfo:@{NSLocalizedDescriptionKey: joinError.localizedDescription ?: @"Failed to join the network"}];
                dispatch_async(dispatch_get_main_queue(), ^{
                    completion(success, cbError);
                });
            }
        });
    }];
}

- (BOOL)leaveNetwork:(NSString *)networkId {
    if (!networkId || networkId.length == 0) {
        NSLog(@"[MultiplayerManager] leaveNetwork: networkId is nil");
        return NO;
    }

    NSString *trimmedNetworkId = [networkId stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    uint64_t netID = [ZeroTierBridge parseNetworkIDFromString:trimmedNetworkId];
    if (netID == 0) {
        NSLog(@"[MultiplayerManager] leaveNetwork: Network ID parse failed: %@", trimmedNetworkId);
        return NO;
    }

    BOOL success = [[ZeroTierBridge sharedInstance] leaveNetwork:netID];
    if (success) {
        NSLog(@"[MultiplayerManager] Left ZeroTier network %@", trimmedNetworkId);
    } else {
        NSLog(@"[MultiplayerManager] Leave ZeroTier network failed: %@", trimmedNetworkId);
    }

    // Clear the current network ID tracking
    [_stateLock lock];
    if (_currentNetworkID == netID) {
        _currentNetworkID = 0;
    }
    [_stateLock unlock];
    return success;
}

#pragma mark - Room management (create/read/update/delete)

- (void)addRoom:(MultiplayerRoom *)room {
    if (!room) {
        NSLog(@"[MultiplayerManager] addRoom: room is nil");
        return;
    }

    if (!room.roomId || room.roomId.length == 0) {
        NSLog(@"[MultiplayerManager] addRoom: roomId is nil, auto-generating");
        room.roomId = [[NSUUID UUID] UUIDString];
    }

    if (!room.name || room.name.length == 0) {
        room.name = @"Untitled room";
    }

    if (!room.hostPort || room.hostPort.length == 0) {
        room.hostPort = kDefaultMCPort;
    }

    if (!room.createdAt) {
        room.createdAt = [NSDate date];
    }

    @synchronized(self) {
        for (MultiplayerRoom *existing in self.internalRooms) {
            if ([existing.roomId isEqualToString:room.roomId]) {
                NSLog(@"[MultiplayerManager] addRoom: roomId already exists: %@", room.roomId);
                return;
            }
        }

        [self.internalRooms addObject:room];
        [self sortRoomsByCreatedAt];
    }

    NSLog(@"[MultiplayerManager] Room added: %@ (%@)", room.name, room.roomId);
    [self saveRooms];
}

- (void)removeRoom:(NSString *)roomId {
    if (!roomId || roomId.length == 0) {
        NSLog(@"[MultiplayerManager] removeRoom: roomId is nil");
        return;
    }

    // Key fix (M6): do not call disconnectCurrentRoom inside @synchronized.
    // It used to be called inside @synchronized, and it calls
    // [[SOCKS5Proxy sharedProxy] stop], which waits for the client threads to exit (up to 2 seconds).
    // @synchronized(self) is held throughout, blocking every room list operation
    // (savedRooms, addRoom:, updateRoom:, roomWithId: and so on) and potentially stalling the main thread UI.
    //
    // The fix:
    //   1. only modify the room list and decide whether a disconnect is needed inside @synchronized
    //   2. move the disconnectCurrentRoom call outside @synchronized
    //
    // Key fix (M2): remove the redundant self.currentRoom = nil and roomToDisconnect.status = ...
    // disconnectCurrentRoom already clears currentRoom and updates room.status inside _stateLock,
    // so setting them again is unnecessary (and writing currentRoom without _stateLock is a data race).

    BOOL needsDisconnect = NO;
    @synchronized(self) {
        NSMutableArray *roomsToKeep = [[NSMutableArray alloc] init];
        MultiplayerRoom *roomToRemove = nil;

        for (MultiplayerRoom *room in self.internalRooms) {
            if ([room.roomId isEqualToString:roomId]) {
                roomToRemove = room;
            } else {
                [roomsToKeep addObject:room];
            }
        }

        if (!roomToRemove) {
            NSLog(@"[MultiplayerManager] removeRoom: roomId not found: %@", roomId);
            return;
        }

        self.internalRooms = roomsToKeep;

        // Check whether the current connection needs closing (reading currentRoom inside _stateLock)
        [_stateLock lock];
        needsDisconnect = (self.currentRoom != nil &&
                           [self.currentRoom.roomId isEqualToString:roomId]);
        [_stateLock unlock];
    }

    // Disconnect outside the lock (so it is not held for long)
    if (needsDisconnect) {
        NSLog(@"[MultiplayerManager] Removing currently connected room, disconnecting first");
        [self disconnectCurrentRoom];
    }

    NSLog(@"[MultiplayerManager] Room deleted: %@", roomId);
    [self saveRooms];
}

- (void)updateRoom:(MultiplayerRoom *)room {
    if (!room || !room.roomId || room.roomId.length == 0) {
        NSLog(@"[MultiplayerManager] updateRoom: room or roomId is nil");
        return;
    }

    // Key fix (M3): currentRoom must be read and written under _stateLock
    // and must not be mixed with @synchronized(self).
    // self.currentRoom used to be read and written directly inside @synchronized(self), while currentRoom
    // is protected by _stateLock everywhere else (connectToRoom, disconnectCurrentRoom, connectToRoomFlow and so on).
    // Mixing the two locking schemes meant:
    //   - a background thread writing currentRoom under @synchronized
    //   - the main thread reading currentRoom under _stateLock
    //   - with no shared memory barrier, so the main thread could read a stale value
    //
    // The fix: only internalRooms is updated inside @synchronized,
    // and currentRoom is read and written under _stateLock separately.

    @synchronized(self) {
        BOOL found = NO;
        NSMutableArray *updatedRooms = [[NSMutableArray alloc] init];

        for (MultiplayerRoom *existing in self.internalRooms) {
            if ([existing.roomId isEqualToString:room.roomId]) {
                [updatedRooms addObject:room];
                found = YES;
            } else {
                [updatedRooms addObject:existing];
            }
        }

        if (!found) {
            NSLog(@"[MultiplayerManager] updateRoom: roomId not found: %@", room.roomId);
            return;
        }

        self.internalRooms = updatedRooms;
        [self sortRoomsByCreatedAt];
    }

    // Update the currentRoom reference inside _stateLock
    [_stateLock lock];
    if (self.currentRoom && [self.currentRoom.roomId isEqualToString:room.roomId]) {
        self.currentRoom = room;
    }
    [_stateLock unlock];

    NSLog(@"[MultiplayerManager] Room updated: %@ (%@)", room.name, room.roomId);
    [self saveRooms];
}

- (nullable MultiplayerRoom *)roomWithId:(NSString *)roomId {
    if (!roomId || roomId.length == 0) {
        return nil;
    }

    @synchronized(self) {
        for (MultiplayerRoom *room in self.internalRooms) {
            if ([room.roomId isEqualToString:roomId]) {
                return room;
            }
        }
    }
    return nil;
}

- (void)sortRoomsByCreatedAt {
    [self.internalRooms sortUsingComparator:^NSComparisonResult(MultiplayerRoom *room1, MultiplayerRoom *room2) {
        NSDate *date1 = room1.createdAt;
        NSDate *date2 = room2.createdAt;

        if (!date1 && !date2) return NSOrderedSame;
        if (!date1) return NSOrderedAscending;
        if (!date2) return NSOrderedDescending;

        NSComparisonResult result = [date2 compare:date1];
        if (result == NSOrderedSame) {
            return [room1.roomId compare:room2.roomId];
        }
        return result;
    }];
}

#pragma mark - Connection management

- (void)connectToRoom:(MultiplayerRoom *)room
           completion:(void (^)(BOOL success, NSError * _Nullable error))completion {
    if (!room) {
        if (completion) {
            NSError *error = [NSError errorWithDomain:kMultiplayerErrorDomain
                                                  code:MultiplayerErrorCodeInvalidRoom
                                              userInfo:@{NSLocalizedDescriptionKey: @"The room object is empty"}];
            dispatch_async(dispatch_get_main_queue(), ^{
                completion(NO, error);
            });
        }
        return;
    }

    if (!room.networkId || room.networkId.length == 0) {
        if (completion) {
            NSError *error = [NSError errorWithDomain:kMultiplayerErrorDomain
                                                  code:MultiplayerErrorCodeInvalidNetworkId
                                              userInfo:@{NSLocalizedDescriptionKey: @"The room's network ID is empty"}];
            dispatch_async(dispatch_get_main_queue(), ^{
                completion(NO, error);
            });
        }
        return;
    }

    // Check that the framework is available
    if (![[ZeroTierBridge sharedInstance] isFrameworkAvailable]) {
        NSLog(@"[MultiplayerManager] zt.framework unavailable, cannot connect to room");
        room.status = MultiplayerRoomStatusError;
        [self updateRoom:room];
        if (completion) {
            NSError *error = [NSError errorWithDomain:kMultiplayerErrorDomain
                                                  code:MultiplayerErrorCodeFrameworkUnavailable
                                              userInfo:@{NSLocalizedDescriptionKey: @"The ZeroTier framework is unavailable. Make sure zt.framework is integrated correctly"}];
            dispatch_async(dispatch_get_main_queue(), ^{
                completion(NO, error);
            });
        }
        return;
    }

    NSLog(@"[MultiplayerManager] Starting connection to room: %@ (Network ID: %@)", room.name, room.networkId);

    // 1. Set the current room and mark it as connecting
    //
    // Key fix (critical 1): room.status must be modified inside _stateLock,
    // atomically with the currentRoom assignment. It used to be modified outside the lock,
    // so a concurrent disconnectCurrentRoom could produce:
    //   - connectToRoom sets currentRoom = room (holding the lock)
    //   - disconnectCurrentRoom reads currentRoom = room (holding the lock)
    //   - connectToRoom writes room.status = Connecting (lock released)
    //   - disconnectCurrentRoom writes room.status = Disconnected (lock released, overwriting)
    //   - leaving status out of step with reality
    [_stateLock lock];
    // Key fix (the connectionCancelled reset race):
    // connectionCancelled is reset to NO while _stateLock is held.
    // currentRoom is not set yet at that point (it is set on the next line), so even if disconnectCurrentRoom takes the lock
    // it returns early because currentRoom == nil and never sets YES.
    // This makes "reset the cancellation flag" and "set currentRoom" atomic under the lock,
    // removing the race where resetting on the connectToRoomFlow background thread overwrote a cancellation signal.
    self.connectionCancelled = NO;
    self.currentRoom = room;
    self.currentNetworkID = [ZeroTierBridge parseNetworkIDFromString:room.networkId];
    room.status = MultiplayerRoomStatusConnecting;
    room.lastConnectedAt = [NSDate date];
    [_stateLock unlock];

    // Key fix: if the room is not in the list, add it first, otherwise every later updateRoom fails to find the roomId
    if (![self roomWithId:room.roomId]) {
        NSLog(@"[MultiplayerManager] Room not in list, adding first: %@", room.roomId);
        [self addRoom:room];
    }
    [self updateRoom:room];

    // 2. The full connection flow (run on a background thread, so the main thread is not blocked)
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        [self connectToRoomFlow:room completion:^(BOOL success, NSError * _Nullable error) {
            if (success) {
                NSLog(@"[MultiplayerManager] Room connection succeeded: %@", room.name);
                room.status = MultiplayerRoomStatusConnected;
            } else {
                NSLog(@"[MultiplayerManager] Room connection failed: %@ - %@", room.name, error.localizedDescription);
                room.status = MultiplayerRoomStatusError;

                // Key fix (M4): clear currentRoom/currentNetworkID and the other state references when the connection fails.
                // Only room.status used to be updated, without clearing the currentRoom reference the manager holds,
                // which meant:
                //   - self.currentRoom still pointed at the failed room, so the UI showed the wrong "current connection"
                //   - _currentNetworkID still matched that network, so later zeroTierNetworkReady: callbacks
                //     still matched and updated the state of a connection that had been abandoned
                //   - the state was inconsistent when retrying the same room
                //
                // The fix: inside _stateLock, check that currentRoom is still the same room and only clear it
                // when it is (so a new room the user has switched to is not cleared).
                [self->_stateLock lock];
                if (self.currentRoom && [self.currentRoom.roomId isEqualToString:room.roomId]) {
                    self.currentRoom = nil;
                    self.currentNetworkID = 0;
                    self.currentLocalIP = nil;
                    self.currentSOCKS5Port = 0;
                    self.currentForwardingPort = 0;
                    NSLog(@"[MultiplayerManager] Connection failed, cleared currentRoom state reference");
                } else {
                    NSLog(@"[MultiplayerManager] Connection failed but currentRoom changed (user may have switched rooms), not clearing state");
                }
                [self->_stateLock unlock];
            }
            [self updateRoom:room];

            if (completion) {
                dispatch_async(dispatch_get_main_queue(), ^{
                    completion(success, error);
                });
            }
        }];
    });
}

/// Report connection flow progress to the delegate
///
/// Called at each step of connectToRoomFlow: so the UI can show live progress.
/// It dispatches to the main thread for thread safety.
///
/// @param message The progress text
- (void)notifyConnectionProgress:(NSString *)message {
    if ([self.delegate respondsToSelector:@selector(multiplayerConnectionProgress:)]) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [self.delegate multiplayerConnectionProgress:message];
        });
    }
}

/// The full room connection flow (run on a background thread)
///
/// The 6 steps (following the spec):
///   1. start the ZeroTier node (if it has not started)
///   2. wait for the node to come online
///   3. join the ZeroTier network
///   4. wait for the network to be ready (an IPv4 or ad-hoc IPv6 address assigned)
///   5. start the local SOCKS5 proxy
///   6. set the AMETHYST_SOCKS5_PROXY environment variable and the port forwarder (started in guest mode only)
///
/// Simplifications (following the spec):
///   - the over-defensive M5 logic that checked whether currentRoom had changed between steps has been removed,
///     since disconnectCurrentRoom cancels the flow explicitly.
///   - host mode does not start PortForwarder; it waits for the UI to call
///     startHostPortForwarderWithListenPort:localHostPort:.
- (void)connectToRoomFlow:(MultiplayerRoom *)room
               completion:(void (^)(BOOL success, NSError * _Nullable error))completion {
    // Performance diagnostics: record the total connection time and the time per step, to help with tuning and debugging
    CFAbsoluteTime flowStartTime = CFAbsoluteTimeGetCurrent();
    CFAbsoluteTime stepStartTime = flowStartTime;
#define MP_LOG_STEP_TIME(stepName) do { \
    CFAbsoluteTime _now = CFAbsoluteTimeGetCurrent(); \
    NSLog(@"[MultiplayerManager] [ConnectFlow] [Timing] %@ took %.2fs (cumulative %.2fs)", \
          (stepName), _now - stepStartTime, _now - flowStartTime); \
    stepStartTime = _now; \
} while(0)

    // SubTask 4.2: the cancellation flag is already reset in connectToRoom: while the main thread holds the lock (see connectToRoom: below).
    // It is deliberately not reset here, to avoid racing with disconnectCurrentRoom setting YES:
    //   - resetting here meant that if disconnectCurrentRoom set YES during the window where dispatch_async scheduled onto the background thread,
    //     this line would immediately overwrite it with NO and the cancellation signal would be lost.
    //   - the reset now happens in connectToRoom: before currentRoom is set (while the main thread holds _stateLock),
    //     and disconnectCurrentRoom must take _stateLock before it can read currentRoom and trigger a cancellation,
    //     so the reset and a possible cancellation cannot overlap.

    // A cancellation check has been added before step 1 (matching steps 2/3/4/5),
    // so the node is not started when the user has already cancelled explicitly during the dispatch_async
    if (self.connectionCancelled) {
        NSLog(@"[MultiplayerManager] [ConnectFlow] Cancelled before step 1, exiting");
        if (completion) {
            completion(NO, [NSError errorWithDomain:kMultiplayerErrorDomain
                                                code:MultiplayerErrorCodeRoomNotFound
                                            userInfo:@{NSLocalizedDescriptionKey: @"Connection cancelled"}]);
        }
        return;
    }

    // Step 1: start the node
    //
    // Call the synchronous startNodeWithHomeDirectory:error: API of ZeroTierBridge directly,
    // avoiding a hop through main_queue (connectToRoomFlow already runs on a background utility queue).
    // The framework availability check happens at the connectToRoom entry point, so it is not repeated here.
    if (![self isNodeStarted]) {
        NSLog(@"[MultiplayerManager] [ConnectFlow] Step 1: Starting ZeroTier node");
        [self notifyConnectionProgress:@"Step 1/6: starting the ZeroTier node..."];
        NSString *homeDir = [self zeroTierHomeDirectory];
        NSError *startError = nil;
        BOOL nodeStartSuccess = [[ZeroTierBridge sharedInstance] startNodeWithHomeDirectory:homeDir
                                                                                     error:&startError];
        if (nodeStartSuccess) {
            [_stateLock lock];
            _nodeStarted = YES;
            [_stateLock unlock];
            NSLog(@"[MultiplayerManager] [ConnectFlow] ZeroTier node start request submitted, waiting for online...");
        } else {
            NSLog(@"[MultiplayerManager] [ConnectFlow] ZeroTier node start failed: %@", startError.localizedDescription);
            if (completion) {
                completion(NO, startError ?: [NSError errorWithDomain:kMultiplayerErrorDomain
                                                                   code:MultiplayerErrorCodeNodeStartFailed
                                                               userInfo:@{NSLocalizedDescriptionKey: @"The node failed to start"}]);
            }
            return;
        }
    } else {
        NSLog(@"[MultiplayerManager] [ConnectFlow] Step 1: Node already started, skipping");
    }
    MP_LOG_STEP_TIME(@"Step 1: Start node");

    // Step 2: wait for the node to come online
    // SubTask 4.2: check the cancellation flag
    if (self.connectionCancelled) {
        NSLog(@"[MultiplayerManager] [ConnectFlow] Cancelled before step 2, exiting");
        if (completion) {
            completion(NO, [NSError errorWithDomain:kMultiplayerErrorDomain
                                                code:MultiplayerErrorCodeRoomNotFound
                                            userInfo:@{NSLocalizedDescriptionKey: @"Connection cancelled"}]);
        }
        return;
    }
    NSLog(@"[MultiplayerManager] [ConnectFlow] Step 2: Waiting for node online (timeout %.0fs)", kNodeOnlineTimeout);
    [self notifyConnectionProgress:@"Step 2/6: waiting for the node to come online..."];
    if (![[ZeroTierBridge sharedInstance] isNodeOnline]) {
        BOOL online = [[ZeroTierBridge sharedInstance] waitForNodeOnlineWithTimeout:kNodeOnlineTimeout];
        if (!online) {
            if (completion) {
                completion(NO, [NSError errorWithDomain:kMultiplayerErrorDomain
                                                    code:MultiplayerErrorCodeNodeOnlineTimeout
                                                userInfo:@{NSLocalizedDescriptionKey: [NSString stringWithFormat:@"Timed out waiting for the ZeroTier node to come online (%.0fs)", kNodeOnlineTimeout]}]);
            }
            return;
        }
    }
    NSLog(@"[MultiplayerManager] [ConnectFlow] Node is online");
    MP_LOG_STEP_TIME(@"Step 2: Wait for node online");

    // Step 3: join the network
    // SubTask 4.2: check the cancellation flag
    if (self.connectionCancelled) {
        NSLog(@"[MultiplayerManager] [ConnectFlow] Cancelled before step 3, exiting");
        if (completion) {
            completion(NO, [NSError errorWithDomain:kMultiplayerErrorDomain
                                                code:MultiplayerErrorCodeRoomNotFound
                                            userInfo:@{NSLocalizedDescriptionKey: @"Connection cancelled"}]);
        }
        return;
    }
    NSLog(@"[MultiplayerManager] [ConnectFlow] Step 3: Joining ZeroTier network %@", room.networkId);
    [self notifyConnectionProgress:[NSString stringWithFormat:@"Step 3/6: joining ZeroTier network %@...", room.networkId]];
    uint64_t netID = [ZeroTierBridge parseNetworkIDFromString:room.networkId];
    if (netID == 0) {
        if (completion) {
            completion(NO, [NSError errorWithDomain:kMultiplayerErrorDomain
                                                code:MultiplayerErrorCodeInvalidNetworkId
                                            userInfo:@{NSLocalizedDescriptionKey: @"Could not parse the network ID"}]);
        }
        return;
    }

    NSError *joinError = nil;
    if (![[ZeroTierBridge sharedInstance] joinNetwork:netID error:&joinError]) {
        if (completion) {
            completion(NO, [NSError errorWithDomain:kMultiplayerErrorDomain
                                                code:MultiplayerErrorCodeJoinNetworkFailed
                                            userInfo:@{NSLocalizedDescriptionKey: joinError.localizedDescription ?: @"Failed to join the network"}]);
        }
        return;
    }
    MP_LOG_STEP_TIME(@"Step 3: Join network");

    // Step 4: wait for the network to be ready
    //
    // When an unauthorized node joins a private network, the ZeroTier controller ignores it (assigning no IP)
    // and may not send an ACCESS_DENIED event straight away. A background timer fires after 8 seconds
    // to check the network state: if it is OK but there is no IP, the node is unauthorized and a hint is reported.
    // SubTask 4.2: check the cancellation flag
    if (self.connectionCancelled) {
        NSLog(@"[MultiplayerManager] [ConnectFlow] Cancelled before step 4, exiting");
        if (completion) {
            completion(NO, [NSError errorWithDomain:kMultiplayerErrorDomain
                                                code:MultiplayerErrorCodeRoomNotFound
                                            userInfo:@{NSLocalizedDescriptionKey: @"Connection cancelled"}]);
        }
        return;
    }
    NSLog(@"[MultiplayerManager] [ConnectFlow] Step 4: Waiting for network ready (timeout %.0fs)", kNetworkReadyTimeout);
    [self notifyConnectionProgress:@"Step 4/6: waiting for the network to be ready..."];

    // After 8 seconds, check whether an authorization hint is needed
    // SubTask 5.7: if no IP has been assigned within 8 seconds, show the guest their own ZeroTier node ID so the host can find them
    __block BOOL step4Done = NO;
    __weak typeof(self) weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(8.0 * NSEC_PER_SEC)),
                   dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        if (step4Done) return;
        // Key fix: the 8-second check block must honor cancellation, otherwise a user who has already disconnected
        // still receives misleading progress messages such as "your node may not be authorized"
        if (weakSelf.connectionCancelled) {
            NSLog(@"[MultiplayerManager] [ConnectFlow] 8s check: cancellation detected, skipping");
            return;
        }
        ZeroTierNetworkStatus status = [[ZeroTierBridge sharedInstance] networkStatus:netID];
        NSString *ipv4 = [[ZeroTierBridge sharedInstance] ipv4AddressForNetwork:netID];
        NSString *ipv6 = [[ZeroTierBridge sharedInstance] ipv6AddressForNetwork:netID];
        NSLog(@"[MultiplayerManager] [ConnectFlow] 8s check: status=%ld, ipv4=%@, ipv6=%@",
              (long)status, ipv4, ipv6);
        if (status == ZeroTierNetworkStatusOk && !ipv4.length && !ipv6.length) {
            // Joined the network but with no IP = unauthorized on a private network
            // Show the guest their own ZeroTier node ID, so the host can find and authorize them at central.zerotier.com
            uint64_t myNodeID = [[ZeroTierBridge sharedInstance] nodeID];
            NSString *nodeIDStr = (myNodeID != 0) ? [ZeroTierBridge formatNetworkID:myNodeID] : @"(unknown)";
            [weakSelf notifyConnectionProgress:[NSString stringWithFormat:@"Still waiting for the network to be ready... your node may not be authorized. Your ZeroTier node ID is %@ — send it to the host and ask them to tick the Auth checkbox under Member Devices at central.zerotier.com", nodeIDStr]];
        } else if (status == ZeroTierNetworkStatusUnknown || status == ZeroTierNetworkStatusRequestingConfig) {
            // Still requesting to join the network
            [weakSelf notifyConnectionProgress:@"Still requesting to join the network, please wait..."];
        }
    });

    BOOL ready = [[ZeroTierBridge sharedInstance] waitForNetworkReady:netID
                                                              timeout:kNetworkReadyTimeout];
    step4Done = YES;

    if (!ready) {
        // When waiting for the network fails, leave the network that was joined, to avoid leaking resources.
        NSLog(@"[MultiplayerManager] [ConnectFlow] Network ready wait failed, cleaning up joined network %@", room.networkId);
        [[ZeroTierBridge sharedInstance] leaveNetwork:netID];

        // Check the network state, to give a more precise error message
        // SubTask 5.6 + 5.7: refine the guest flow errors, showing the guest their own ZeroTier node ID in the unauthorized case so the host can find them
        ZeroTierNetworkStatus failStatus = [[ZeroTierBridge sharedInstance] networkStatus:netID];
        // Get the guest's own ZeroTier node ID (used to tell the host who to look for in the unauthorized case)
        uint64_t myNodeID = [[ZeroTierBridge sharedInstance] nodeID];
        NSString *myNodeIDStr = (myNodeID != 0) ? [ZeroTierBridge formatNetworkID:myNodeID] : nil;
        NSString *failDesc = nil;
        if (failStatus == ZeroTierNetworkStatusAccessDenied) {
            failDesc = myNodeIDStr
                ? [NSString stringWithFormat:@"Network access was denied. Your ZeroTier node ID is %@ — send it to the host and ask them to tick the Auth checkbox for your device under Member Devices at central.zerotier.com.", myNodeIDStr]
                : @"Network access was denied. Ask the host to authorize your device at central.zerotier.com.";
        } else if (failStatus == ZeroTierNetworkStatusNotFound) {
            failDesc = @"The network does not exist. Check that the share code is complete, or ask the host to confirm the network ID.";
        } else if (failStatus == ZeroTierNetworkStatusClientTooOld) {
            failDesc = @"The ZeroTier client is too old to join the network. Update zt.framework and try again.";
        } else if (failStatus == ZeroTierNetworkStatusDown) {
            failDesc = @"The network controller is unreachable. Try again later or ask the host to check the network status.";
        } else if (failStatus == ZeroTierNetworkStatusOk) {
            failDesc = myNodeIDStr
                ? [NSString stringWithFormat:@"Joined the network but no IP address was assigned. Your ZeroTier node ID is %@ — send it to the host and ask them to tick the Auth checkbox for your device under Member Devices at central.zerotier.com.", myNodeIDStr]
                : @"Joined the network but no IP address was assigned. Your node may not be authorized — ask the host to authorize your device under Member Devices at central.zerotier.com (tick the Auth checkbox).";
        } else {
            failDesc = [NSString stringWithFormat:@"Timed out waiting for the ZeroTier network to be ready (%.0fs). Check that the network ID is correct and that your node is authorized at central.zerotier.com.", kNetworkReadyTimeout];
        }

        if (completion) {
            completion(NO, [NSError errorWithDomain:kMultiplayerErrorDomain
                                                code:MultiplayerErrorCodeNetworkReadyTimeout
                                            userInfo:@{NSLocalizedDescriptionKey: failDesc}]);
        }
        return;
    }

    // Get the assigned IP address
    // Standard mode: get the IPv4 address
    // Ad-hoc mode (quick mode): IPv6 only, which needs special handling
    NSString *localIP = nil;
    BOOL isAdhoc = [self isAdhocNetworkId:room.networkId];
    if (isAdhoc) {
        // An ad-hoc network only has IPv6 addresses
        localIP = [[ZeroTierBridge sharedInstance] ipv6AddressForNetwork:netID];
        NSLog(@"[MultiplayerManager] [ConnectFlow] Ad-hoc mode, local ZeroTier IPv6: %@", localIP ?: @"(not assigned)");
    } else {
        // Standard mode: get the IPv4 address
        localIP = [[ZeroTierBridge sharedInstance] ipv4AddressForNetwork:netID];
        NSLog(@"[MultiplayerManager] [ConnectFlow] Standard mode, local ZeroTier IPv4: %@", localIP ?: @"(not assigned)");
    }

    // If no local IP can be read, the network is ready but the IP assignment went wrong,
    // so the joined network should be cleaned up here too, to avoid a confused state on the next reconnect.
    if (!localIP || localIP.length == 0) {
        NSLog(@"[MultiplayerManager] [ConnectFlow] Cannot obtain local ZeroTier IP, cleaning up joined network %@", room.networkId);
        [[ZeroTierBridge sharedInstance] leaveNetwork:netID];

        if (completion) {
            completion(NO, [NSError errorWithDomain:kMultiplayerErrorDomain
                                                code:MultiplayerErrorCodeNetworkReadyTimeout
                                            userInfo:@{NSLocalizedDescriptionKey: @"Joined the ZeroTier network but no local IP was assigned — the network may not have authorized you, or its addresses are exhausted"}]);
        }
        return;
    }
    MP_LOG_STEP_TIME(@"Step 4: Wait for network ready");

    // Copy this device's ZeroTier IP into currentLocalIP, and into room.hostIP when hosting
    //
    // Telling host and guest apart (the key fix replacing the IP heuristic):
    //   - prefer room.role: role == Host means this is the host
    //   - when role == Unknown, fall back to the IP heuristic for compatibility:
    //     - the host connecting for the first time: room.hostIP is empty -> fill in this device IP for sharing
    //     - the host reconnecting (with an unchanged IP): room.hostIP == this device IP -> unchanged, so copying is fine
    //     - a guest connecting: room.hostIP == the host IP (from the share code) != this device IP -> do not overwrite
    [_stateLock lock];
    self.currentLocalIP = localIP;
    if (localIP.length > 0 && self.currentRoom) {
        NSString *existingHostIP = self.currentRoom.hostIP;
        MultiplayerRoomRole currentRole = self.currentRoom.role;
        BOOL isHostByRole = (currentRole == MultiplayerRoomRoleHost);
        BOOL isHostByIPFallback = (currentRole == MultiplayerRoomRoleUnknown &&
                                   (existingHostIP.length == 0 || [existingHostIP isEqualToString:localIP]));
        BOOL isHost = isHostByRole || isHostByIPFallback;
        if (isHost) {
            self.currentRoom.hostIP = localIP;
            // When the host sets it for the first time, make sure role is marked as Host (for the old path)
            if (currentRole == MultiplayerRoomRoleUnknown) {
                self.currentRoom.role = MultiplayerRoomRoleHost;
            }
            NSLog(@"[MultiplayerManager] [ConnectFlow] Synced host ZeroTier IP to room %@ (role=%ld): %@",
                  self.currentRoom.name, (long)self.currentRoom.role, localIP);
        } else {
            // Guest: keep the host IP from the share code and do not overwrite it
            NSLog(@"[MultiplayerManager] [ConnectFlow] Guest mode (role=%ld): keeping host IP %@, not using local IP %@",
                  (long)currentRole, existingHostIP, localIP);
        }
    }
    MultiplayerRoom *roomForIPUpdate = self.currentRoom;
    [_stateLock unlock];

    // Copy the host IP into the room list
    if (roomForIPUpdate && localIP.length > 0) {
        [self updateRoom:roomForIPUpdate];
    }

    // Step 5: start the SOCKS5 proxy
    // SubTask 4.2: check the cancellation flag
    if (self.connectionCancelled) {
        NSLog(@"[MultiplayerManager] [ConnectFlow] Cancelled before step 5, exiting");
        if (completion) {
            completion(NO, [NSError errorWithDomain:kMultiplayerErrorDomain
                                                code:MultiplayerErrorCodeRoomNotFound
                                            userInfo:@{NSLocalizedDescriptionKey: @"Connection cancelled"}]);
        }
        return;
    }
    NSLog(@"[MultiplayerManager] [ConnectFlow] Step 5: Starting SOCKS5 proxy");
    [self notifyConnectionProgress:@"Step 5/6: starting the SOCKS5 proxy..."];
    NSError *proxyError = nil;
    BOOL proxyStarted = [[SOCKS5Proxy sharedProxy] startWithPort:kMultiplayerDefaultSOCKS5Port
                                                            error:&proxyError];
    if (!proxyStarted) {
        NSLog(@"[MultiplayerManager] [ConnectFlow] SOCKS5 proxy start failed: %@", proxyError.localizedDescription);
        // When the SOCKS5 proxy fails to start, the joined network must be left too,
        // otherwise the next connection attempt hits an inconsistent state because the node is already in the network.
        NSLog(@"[MultiplayerManager] [ConnectFlow] Cleaning up joined network %@", room.networkId);
        [[ZeroTierBridge sharedInstance] leaveNetwork:netID];

        if (completion) {
            completion(NO, [NSError errorWithDomain:kMultiplayerErrorDomain
                                                code:MultiplayerErrorCodeSOCKS5ProxyStartFailed
                                            userInfo:@{NSLocalizedDescriptionKey: proxyError.localizedDescription ?: @"Failed to start the SOCKS5 proxy"}]);
        }
        return;
    }

    uint16_t actualPort = [[SOCKS5Proxy sharedProxy] listeningPort];

    [_stateLock lock];
    self.currentSOCKS5Port = actualPort;
    [_stateLock unlock];

    NSLog(@"[MultiplayerManager] [ConnectFlow] SOCKS5 proxy started, listening on 127.0.0.1:%u", actualPort);
    MP_LOG_STEP_TIME(@"Step 5: Start SOCKS5 proxy");

    // Step 6: set the environment variable and start the port forwarder (guest mode only)
    //
    // About the port forwarder:
    //   the SOCKS5 proxy only covers java.net.Socket (login authentication and so on), while the Minecraft multiplayer connection
    //   uses the Netty NioSocketChannel (built on java.nio.channels.SocketChannel),
    //   which does not go through the Java SOCKS5 proxy. A local port forwarder is therefore needed as well:
    //     - guest mode: listen for TCP on 127.0.0.1:25565 (or the next free port)
    //       and forward through a libzt socket to the host ZeroTier IP:MC LAN port.
    //       The guest enters 127.0.0.1:25565 in Minecraft to connect.
    //     - host mode: not started here; it waits for the UI to call
    //       startHostPortForwarderWithListenPort:localHostPort: to start host mode
    //       (listening on 25565 on the ZeroTier network -> forwarding to the local MC LAN port).
    [self notifyConnectionProgress:@"Step 6/6: setting up the proxy and port forwarding..."];
    NSString *proxyValue = [NSString stringWithFormat:@"127.0.0.1:%u", actualPort];
    setenv([kAMETHYSTSOCKS5ProxyEnvVar UTF8String], [proxyValue UTF8String], 1);
    NSLog(@"[MultiplayerManager] [ConnectFlow] Set environment variable %@=%@", kAMETHYSTSOCKS5ProxyEnvVar, proxyValue);

    // The guest-mode port forwarder only starts when the room has both a hostIP and a hostPort
    // Host mode (hostIP empty or equal to this device IP) does not start it and waits for the UI to call the host-mode API
    //
    // Key fix (replacing the IP heuristic):
    // prefer room.role to decide guest identity; when role == Unknown (old data or an unusual path),
    // fall back to the IP heuristic for compatibility. This removes the fragile case where "hostIP happens to equal localIP"
    // made a guest look like the host, left PortForwarder unstarted and stopped Minecraft connecting.
    NSString *hostIP = room.hostIP;
    NSString *hostPortStr = room.hostPort;
    MultiplayerRoomRole role = room.role;
    BOOL isGuestByRole = (role == MultiplayerRoomRoleGuest);
    BOOL isGuestByIPFallback = (role == MultiplayerRoomRoleUnknown &&
                                hostIP.length > 0 &&
                                hostPortStr.length > 0 &&
                                localIP.length > 0 &&
                                ![hostIP isEqualToString:localIP]);
    BOOL isGuestMode = isGuestByRole || isGuestByIPFallback;
    if (isGuestMode && hostIP.length > 0 && hostPortStr.length > 0) {
        uint16_t hostPort = (uint16_t)[hostPortStr integerValue];
        if (hostPort > 0) {
            NSLog(@"[MultiplayerManager] [ConnectFlow] Guest mode (role=%ld): starting port forwarder 127.0.0.1:%u -> %@:%u",
                  (long)role, PortForwarderDefaultLocalPort, hostIP, hostPort);

            BOOL forwardStarted = [[PortForwarder sharedForwarder] startGuestModeWithLocalPort:PortForwarderDefaultLocalPort
                                                                                         hostIP:hostIP
                                                                                       hostPort:hostPort];
            if (forwardStarted) {
                uint16_t forwardPort = [[PortForwarder sharedForwarder] listeningPort];
                NSLog(@"[MultiplayerManager] [ConnectFlow] Port forwarder started: 127.0.0.1:%u -> %@:%u",
                      forwardPort, hostIP, hostPort);

                [_stateLock lock];
                self.currentForwardingPort = forwardPort;
                [_stateLock unlock];
            } else {
                NSLog(@"[MultiplayerManager] [ConnectFlow] Port forwarder start failed (SOCKS5 proxy unaffected)");
                // A port forwarder failure does not abort the whole connection (the SOCKS5 proxy still works)
            }
        } else {
            NSLog(@"[MultiplayerManager] [ConnectFlow] Host port invalid: %@, skipping port forward", hostPortStr);
        }
    } else {
        NSLog(@"[MultiplayerManager] [ConnectFlow] Host mode (role=%ld): skipping guest port forward, waiting for UI to call startHostPortForwarderWithListenPort:localHostPort:",
              (long)role);
    }
    MP_LOG_STEP_TIME(@"Step 6: Env vars + port forward");
    NSLog(@"[MultiplayerManager] [ConnectFlow] Connect flow completed, total time %.2fs", CFAbsoluteTimeGetCurrent() - flowStartTime);

    if (completion) {
        completion(YES, nil);
    }
#undef MP_LOG_STEP_TIME
}

- (void)disconnectCurrentRoom {
    // SubTask 4.2: set the cancellation flag, telling a running connectToRoomFlow to stop at the next step
    // This differs from the M5 "check whether currentRoom changed" — this flag is only set on an explicit disconnect
    self.connectionCancelled = YES;

    [_stateLock lock];
    MultiplayerRoom *room = self.currentRoom;
    NSString *networkId = room.networkId;
    [_stateLock unlock];

    if (!room) {
        NSLog(@"[MultiplayerManager] disconnectCurrentRoom: No current room connected");
        return;
    }

    NSLog(@"[MultiplayerManager] Disconnecting room: %@ (Network ID: %@)", room.name, networkId);

    // 1. Stop the SOCKS5 proxy
    if ([[SOCKS5Proxy sharedProxy] isRunning]) {
        NSLog(@"[MultiplayerManager] Stopping SOCKS5 proxy");
        [[SOCKS5Proxy sharedProxy] stop];
    }

    // 1.5 Stop the port forwarder (in host or guest mode)
    if ([[PortForwarder sharedForwarder] isRunning]) {
        NSLog(@"[MultiplayerManager] Stopping port forwarder (mode=%ld)", (long)[[PortForwarder sharedForwarder] mode]);
        [[PortForwarder sharedForwarder] stop];
    }

    [_stateLock lock];
    self.currentSOCKS5Port = 0;
    self.currentForwardingPort = 0;
    self.currentLocalIP = nil;
    [_stateLock unlock];

    // 2. Clear the environment variable
    unsetenv([kAMETHYSTSOCKS5ProxyEnvVar UTF8String]);
    NSLog(@"[MultiplayerManager] Cleared environment variable %@", kAMETHYSTSOCKS5ProxyEnvVar);

    // 3. Leave the ZeroTier network
    // Key fix: check the leaveNetwork return value and force a stopNode cleanup on failure.
    // The return value used to be ignored, so if leaveNetwork failed (a libzt error, a node fault and so on)
    // the node was really still in the network while the manager state was cleared, leaving the next reconnect to the same network inconsistent.
    // A failure now forces stopNode to reset the whole node state, so the next connection starts clean.
    if (networkId && networkId.length > 0) {
        BOOL leaveSuccess = [self leaveNetwork:networkId];
        if (!leaveSuccess) {
            NSLog(@"[MultiplayerManager] disconnectCurrentRoom: leaveNetwork failed, forcing stopNode for full cleanup");
            [[ZeroTierBridge sharedInstance] stopNode];
            [_stateLock lock];
            _nodeStarted = NO;
            [_stateLock unlock];
        }
    }

    // 4. Set the room status to disconnected
    room.status = MultiplayerRoomStatusDisconnected;

    @synchronized(self) {
        for (MultiplayerRoom *existing in self.internalRooms) {
            if ([existing.roomId isEqualToString:room.roomId]) {
                existing.status = MultiplayerRoomStatusDisconnected;
                break;
            }
        }
    }

    // 5. Clear the current room reference
    [_stateLock lock];
    self.currentRoom = nil;
    self.currentNetworkID = 0;
    [_stateLock unlock];

    // 6. Persist
    [self saveRooms];

    // 7. Key fix (P0-A): clear any leftover serverIp in PLProfiles
    // The problem: on a successful connection, connectToRoomFlow writes the host IP:port into the profile serverIp
    // field (so Minecraft connects automatically next launch). Without clearing it on disconnect, the next launch still
    // tries to reach the old server — with no SOCKS5 proxy running and no ZeroTier network joined the connection fails,
    // yet Minecraft still shows the "connecting to server" screen, which is the "it always shows connecting to a server" bug.
    // The fix: clear the serverIp of the current profile when disconnecting.
    @try {
        NSString *currentProfile = [[PLProfiles current] selectedProfileName];
        if (currentProfile.length > 0) {
            [[PLProfiles current] setServerIp:@"" forProfile:currentProfile];
            NSLog(@"[MultiplayerManager] Cleared serverIp for profile '%@'", currentProfile);
        }
    } @catch (NSException *e) {
        NSLog(@"[MultiplayerManager] Failed to clear serverIp: %@", e);
    }

    NSLog(@"[MultiplayerManager] Room disconnected");
}

#pragma mark - ZeroTierBridgeDelegate

- (void)zeroTierNodeOnlineWithID:(uint64_t)nodeID {
    NSLog(@"[MultiplayerManager] ZeroTier node went online, nodeID = %llu", nodeID);
    if ([self.delegate respondsToSelector:@selector(multiplayerNodeOnline)]) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [self.delegate multiplayerNodeOnline];
        });
    }
}

/// Fix for the data plane (SOCKS5Proxy + PortForwarder) not restarting after the node recovers.
///
/// Background: zeroTierNodeOffline stops SOCKS5/PortForwarder to free resources,
/// but when the node came back online the original implementation only updated currentLocalIP without restarting the data plane, so:
///   - the UI still said "connected"
///   - but Minecraft traffic had no proxy and the connection dropped immediately
///   - the user had to disconnect and reconnect by hand
///
/// This method is called from zeroTierNetworkReady: and applicationWillEnterForeground,
/// and only restarts things when there is a currentRoom and the proxy is not running.
/// On the first connection the data plane is already started by connectToRoomFlow, so this does not start it twice (avoiding a port clash).
///
/// The host-mode PortForwarder is not restored here (it needs the MC LAN port, so the UI calls
/// startHostPortForwarderWithListenPort:localHostPort: to restart it).
- (void)ensureDataPlaneRunningForCurrentRoom {
    [_stateLock lock];
    MultiplayerRoom *room = self.currentRoom;
    NSString *hostIP = room.hostIP;
    NSString *hostPortStr = room.hostPort;
    NSString *localIP = self.currentLocalIP;
    uint16_t savedSocksPort = _currentSOCKS5Port;
    uint16_t savedForwardPort = _currentForwardingPort;
    uint64_t currentNetID = _currentNetworkID;
    [_stateLock unlock];

    // With no current room or no connecting network, the data plane does not need restarting
    if (!room || currentNetID == 0) {
        return;
    }

    // Restart the SOCKS5 proxy (only when it is not running)
    if (![[SOCKS5Proxy sharedProxy] isRunning] || savedSocksPort == 0) {
        NSLog(@"[MultiplayerManager] [Data plane recovery] Restarting SOCKS5 proxy (room: %@)", room.name);
        NSError *proxyError = nil;
        BOOL proxyStarted = [[SOCKS5Proxy sharedProxy] startWithPort:kMultiplayerDefaultSOCKS5Port
                                                                error:&proxyError];
        if (proxyStarted) {
            uint16_t actualPort = [[SOCKS5Proxy sharedProxy] listeningPort];
            [_stateLock lock];
            self.currentSOCKS5Port = actualPort;
            [_stateLock unlock];
            NSString *proxyValue = [NSString stringWithFormat:@"127.0.0.1:%u", actualPort];
            setenv([kAMETHYSTSOCKS5ProxyEnvVar UTF8String], [proxyValue UTF8String], 1);
            NSLog(@"[MultiplayerManager] [Data plane recovery] SOCKS5 proxy restarted, listening on 127.0.0.1:%u", actualPort);
        } else {
            NSLog(@"[MultiplayerManager] [Data plane recovery] SOCKS5 proxy restart failed: %@",
                  proxyError.localizedDescription ?: @"Unknown error");
        }
    }

    // Restart the guest-mode PortForwarder (only when it is not running and this is guest mode)
    // Deciding guest mode:
    //   - prefer room.role == Guest
    //   - when role == Unknown, fall back to the IP heuristic (a non-empty hostIP, a valid hostPort, and hostIP different from this device IP)
    // The host-mode PortForwarder is not restored automatically (it needs the MC LAN port, so the UI restarts it)
    MultiplayerRoomRole role = room.role;
    BOOL isGuestByRole = (role == MultiplayerRoomRoleGuest);
    BOOL isGuestByIPFallback = (role == MultiplayerRoomRoleUnknown &&
                                hostIP.length > 0 &&
                                hostPortStr.length > 0 &&
                                localIP.length > 0 &&
                                ![hostIP isEqualToString:localIP]);
    BOOL isGuestMode = isGuestByRole || isGuestByIPFallback;
    if (isGuestMode &&
        (![[PortForwarder sharedForwarder] isRunning] || savedForwardPort == 0)) {
        uint16_t hostPort = (uint16_t)[hostPortStr integerValue];
        if (hostPort > 0) {
            NSLog(@"[MultiplayerManager] [Data plane recovery] Restarting port forwarder (guest mode): 127.0.0.1:%u → %@:%u",
                  PortForwarderDefaultLocalPort, hostIP, hostPort);
            BOOL forwardStarted = [[PortForwarder sharedForwarder] startGuestModeWithLocalPort:PortForwarderDefaultLocalPort
                                                                                         hostIP:hostIP
                                                                                       hostPort:hostPort];
            if (forwardStarted) {
                uint16_t forwardPort = [[PortForwarder sharedForwarder] listeningPort];
                [_stateLock lock];
                self.currentForwardingPort = forwardPort;
                [_stateLock unlock];
                NSLog(@"[MultiplayerManager] [Data plane recovery] Port forwarder restarted: 127.0.0.1:%u → %@:%u",
                      forwardPort, hostIP, hostPort);
            } else {
                NSLog(@"[MultiplayerManager] [Data plane recovery] Port forwarder restart failed");
            }
        }
    }
}

- (void)zeroTierNodeOffline {
    NSLog(@"[MultiplayerManager] ZeroTier node went offline");

    // Key stability improvement: while the node is offline, PortForwarder and SOCKS5Proxy cannot forward anything,
    // so they are stopped immediately, sparing the guest a long "connecting" hang in Minecraft.
    // disconnectCurrentRoom is not called (it would clear currentRoom); only the proxy and forwarder are stopped.
    if ([[PortForwarder sharedForwarder] isRunning]) {
        NSLog(@"[MultiplayerManager] Node offline, stopping port forwarder");
        [[PortForwarder sharedForwarder] stop];
    }
    if ([[SOCKS5Proxy sharedProxy] isRunning]) {
        NSLog(@"[MultiplayerManager] Node offline, stopping SOCKS5 proxy");
        [[SOCKS5Proxy sharedProxy] stop];
    }

    [_stateLock lock];
    self.currentSOCKS5Port = 0;
    self.currentForwardingPort = 0;
    [_stateLock unlock];

    if ([self.delegate respondsToSelector:@selector(multiplayerNodeOffline)]) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [self.delegate multiplayerNodeOffline];
        });
    }
}

- (void)zeroTierNodeDown {
    NSLog(@"[MultiplayerManager] ZeroTier node shut down (zts_node_stop complete)");

    [_stateLock lock];
    self.currentSOCKS5Port = 0;
    self.currentForwardingPort = 0;
    self.currentLocalIP = nil;
    _nodeStarted = NO;
    [_stateLock unlock];

    // The node is down, so stop the data plane
    if ([[PortForwarder sharedForwarder] isRunning]) {
        NSLog(@"[MultiplayerManager] Node shut down, stopping port forwarder");
        [[PortForwarder sharedForwarder] stop];
    }
    if ([[SOCKS5Proxy sharedProxy] isRunning]) {
        NSLog(@"[MultiplayerManager] Node shut down, stopping SOCKS5 proxy");
        [[SOCKS5Proxy sharedProxy] stop];
    }
    unsetenv([kAMETHYSTSOCKS5ProxyEnvVar UTF8String]);
}

- (void)zeroTierNetworkReady:(uint64_t)networkID
                        ipv4:(NSString *)ipv4
                        ipv6:(NSString *)ipv6 {
    NSLog(@"[MultiplayerManager] ZeroTier network ready: networkID=%llu ipv4=%@ ipv6=%@",
          networkID, ipv4 ?: @"(nil)", ipv6 ?: @"(nil)");

    // Key fix (N8): the currentRoom read, the isAdhoc test and the effectiveIP computation all moved inside _stateLock.
    //
    // The problem: self.currentRoom used to be read outside the lock, isAdhoc and effectiveIP computed,
    // and only then _currentNetworkID checked inside the lock. Between the unlocked read and the locked check there was a window
    // in which disconnectCurrentRoom could clear currentRoom and currentNetworkID.
    // The practical impact was limited (effectiveIP was computed but never written, because _currentNetworkID had been cleared),
    // but the risks remained:
    //   - the currentRoom read outside the lock may have been replaced by another room by the time the lock was taken (the room-switch case)
    //   - so effectiveIP, derived from the old room isAdhoc test, would be written into the currentLocalIP of the new room
    //
    // The fix: every related read and test happens inside _stateLock, keeping the state consistent.
    [_stateLock lock];

    // Work out whether the current network is an ad-hoc network
    // An ad-hoc network only has IPv6 addresses, so ipv6 must be used instead of ipv4
    MultiplayerRoom *currentRoom = self.currentRoom;
    BOOL isAdhoc = currentRoom && [self isAdhocNetworkId:currentRoom.networkId];
    NSString *effectiveIP = isAdhoc ? ipv6 : ipv4;

    // Update the local IP of the current room
    if (_currentNetworkID == networkID) {
        self.currentLocalIP = effectiveIP;
        // Key fix (matching FCL/HMCL): the ZeroTier network-ready callback can arrive after connectToRoomFlow finishes,
        // so the IP has to be copied into room.hostIP here too, making sure the share text carries the right server address.
        // IPv6 is used in ad-hoc mode and IPv4 in standard mode.

        // Key fix (P0-1): fix for the data plane (SOCKS5/PortForwarder) not restarting after the node recovers.
        // zeroTierNodeOffline has stopped the proxy, so ensureDataPlaneRunningForCurrentRoom is called here once the network is ready
        // to restart the data plane. On the first connection the proxy is already running and the internal isRunning check skips it, with no side effects.
        // Note: calling it inside _stateLock would risk a deadlock (ensureDataPlaneRunningForCurrentRoom takes _stateLock itself),
        // so it is called after unlocking.
    }
    MultiplayerRoom *room = currentRoom;
    BOOL needsUpdate = NO;
    BOOL needsDataPlaneRestore = (_currentNetworkID == networkID);
    if (room && effectiveIP && effectiveIP.length > 0) {
        // Key fix (the root cause of guest connection failures): only the host should copy this device's ZeroTier IP into room.hostIP.
        // Copying it unconditionally overwrote the guest hostIP with their own IP, so PortForwarder forwarded to the guest themselves.
        // The guest hostIP comes from the share code (the host IP) and must be preserved.
        //
        // Key fix (replacing the IP heuristic):
        // prefer room.role; when role == Unknown, fall back to the IP heuristic for compatibility.
        NSString *existingHostIP = room.hostIP;
        BOOL isHostByRole = (room.role == MultiplayerRoomRoleHost);
        BOOL isHostByIPFallback = (room.role == MultiplayerRoomRoleUnknown &&
                                   (existingHostIP.length == 0 || [existingHostIP isEqualToString:effectiveIP]));
        BOOL isHost = isHostByRole || isHostByIPFallback;
        if (isHost) {
            // Host: copy this device IP into hostIP (for sharing with guests)
            if (![existingHostIP isEqualToString:effectiveIP]) {
                room.hostIP = effectiveIP;
                needsUpdate = YES;
            }
            NSLog(@"[MultiplayerManager] Updated local IP for room %@ (%@, role=%ld): %@",
                  room.name, isAdhoc ? @"IPv6" : @"IPv4", (long)room.role, effectiveIP);
        } else {
            // Guest: keep the host IP and only update currentLocalIP (already updated above)
            NSLog(@"[MultiplayerManager] Guest mode (role=%ld): keeping host IP %@, local IP %@ (not overwriting hostIP)",
                  (long)room.role, existingHostIP, effectiveIP);
        }
    }
    [_stateLock unlock];

    // Key fix (P0-1): call ensureDataPlaneRunningForCurrentRoom outside the lock,
    // so _stateLock is not acquired recursively and cannot deadlock.
    if (needsDataPlaneRestore) {
        [self ensureDataPlaneRunningForCurrentRoom];
    }

    // Persist to the room list (written asynchronously in the background)
    if (needsUpdate && room) {
        [self updateRoom:room];
    }

    // Tell the delegate to refresh the UI (the IP display may need updating)
    //
    // Key fix (H6): inside dispatch_async, check again that currentRoom is still the same room.
    // Capturing the outer room variable and using it inside the dispatch_async block carried these risks:
    //   - the network-ready event may only reach the main thread after the user has switched rooms
    //   - self.currentRoom is then a different room, while the callback still reports the old one
    //   - so the UI shows a connected state that does not match the new room
    // The fix: re-read self.currentRoom inside dispatch_async, compare it with room,
    // and only notify the delegate while currentRoom is still room.
    if (room && [self.delegate respondsToSelector:@selector(multiplayerRoomConnected:)]) {
        dispatch_async(dispatch_get_main_queue(), ^{
            MultiplayerRoom *currentNow = self.currentRoom;
            if (currentNow && [currentNow.roomId isEqualToString:room.roomId]) {
                [self.delegate multiplayerRoomConnected:room];
            } else {
                NSLog(@"[MultiplayerManager] Network ready callback arrived on main thread but current room changed, skipping notification (roomId=%@)",
                      room.roomId);
            }
        });
    }
}

/// Shared network failure handling: turn a network failure event into a delegate notification
///
/// @param networkID The ID of the network that failed
/// @param errorDescription The localized failure description
- (void)handleNetworkFailure:(uint64_t)networkID
              errorDescription:(NSString *)errorDescription {
    NSLog(@"[MultiplayerManager] ZeroTier network failure: networkID=%llu desc=%@", networkID, errorDescription);

    [_stateLock lock];
    MultiplayerRoom *room = (_currentNetworkID == networkID) ? self.currentRoom : nil;
    [_stateLock unlock];

    if (!room) {
        return;
    }

    room.status = MultiplayerRoomStatusError;
    [self updateRoom:room];

    if (![self.delegate respondsToSelector:@selector(multiplayerRoom:didFailWithError:)]) {
        return;
    }

    NSError *error = [NSError errorWithDomain:kMultiplayerErrorDomain
                                          code:MultiplayerErrorCodeJoinNetworkFailed
                                      userInfo:@{NSLocalizedDescriptionKey: errorDescription}];

    // The user may have switched rooms while dispatch_async reached the main thread, so it is checked again
    // currentRoom is still the same room, so the delegate is not told about a stale room state.
    dispatch_async(dispatch_get_main_queue(), ^{
        MultiplayerRoom *currentNow = self.currentRoom;
        if (currentNow && [currentNow.roomId isEqualToString:room.roomId]) {
            [self.delegate multiplayerRoom:room didFailWithError:error];
        } else {
            NSLog(@"[MultiplayerManager] Network failure callback arrived on main thread but current room changed, skipping notification (roomId=%@)",
                  room.roomId);
        }
    });
}

- (void)zeroTierNetworkNotFound:(uint64_t)networkID {
    NSLog(@"[MultiplayerManager] ZeroTier network not found: networkID=%llu", networkID);
    [self handleNetworkFailure:networkID
              errorDescription:@"The network does not exist. Check that the network ID is correct."];
}

- (void)zeroTierNetworkAccessDenied:(uint64_t)networkID {
    NSLog(@"[MultiplayerManager] ZeroTier network access denied: networkID=%llu", networkID);
    [self handleNetworkFailure:networkID
              errorDescription:@"Network access was denied. Ask the host to authorize your device at central.zerotier.com."];
}

- (void)zeroTierNetworkClientTooOld:(uint64_t)networkID {
    NSLog(@"[MultiplayerManager] ZeroTier client too old: networkID=%llu", networkID);
    [self handleNetworkFailure:networkID
              errorDescription:@"The ZeroTier client is too old to join the network. Update zt.framework and try again."];
}

- (void)zeroTierNetworkDown:(uint64_t)networkID {
    NSLog(@"[MultiplayerManager] ZeroTier network controller unreachable: networkID=%llu", networkID);
    [self handleNetworkFailure:networkID
              errorDescription:@"The network controller is unreachable. Try again later or ask the host to check the network status."];
}

#pragma mark - Sharing

- (NSString *)shareTextForRoom:(MultiplayerRoom *)room {
    if (!room) {
        return @"";
    }

    NSString *name = room.name ?: @"Untitled room";
    NSString *networkId = room.networkId ?: @"";
    // hostIP may be an empty string (when the host has not connected to the room yet), in which case a hint is shown
    NSString *hostIP = (room.hostIP && room.hostIP.length > 0) ? room.hostIP : @"(shown automatically once the host connects to the room)";
    NSString *hostPort = (room.hostPort && room.hostPort.length > 0) ? room.hostPort : kDefaultMCPort;

    // Key fix (M7): an IPv6 address must be wrapped in square brackets in the host:port format.
    // Joining them as host:port turned an IPv6 address such as 2001:db8::1 into 2001:db8::1:25565,
    // where the port cannot be told apart from the colons in the address and the Minecraft client cannot parse it.
    // RFC 3986 requires an IPv6 address in a URI to be wrapped in [ and ], for example [2001:db8::1]:25565.
    // The test: a hostIP containing a colon is treated as IPv6.
    NSString *serverAddress;
    BOOL isIPv6 = ([hostIP rangeOfString:@":"].location != NSNotFound);
    if (isIPv6) {
        serverAddress = [NSString stringWithFormat:@"[%@]:%@", hostIP, hostPort];
    } else {
        serverAddress = [NSString stringWithFormat:@"%@:%@", hostIP, hostPort];
    }

    NSMutableString *text = [NSMutableString string];

    [text appendString:kShareHeaderLine];
    [text appendString:@"\n"];

    [text appendString:kShareRoomNamePrefix];
    [text appendString:name];
    [text appendString:@"\n"];

    [text appendString:kShareNetworkIdPrefix];
    [text appendString:networkId];
    [text appendString:@"\n"];

    [text appendString:kShareServerAddressPrefix];
    [text appendString:serverAddress];
    [text appendString:@"\n"];

    [text appendString:@"\n"];
    [text appendString:@"How to join:\n"];
    [text appendString:@"1. Enter the ZeroTier network ID above on the launcher's multiplayer page\n"];
    [text appendString:@"2. Tap \"Join room\" and the launcher will start the multiplayer core and connect automatically\n"];
    [text appendFormat:@"3. Once connected, start the game and add this server in Minecraft: %@", serverAddress];
    [text appendString:@"\n\n"];
    [text appendString:@"Tip: the host must connect to the room in the launcher and start the game (or open it to LAN) before anyone else can join."];

    return [text copy];
}

- (nullable MultiplayerRoom *)parseRoomFromShareText:(NSString *)text {
    if (!text || text.length == 0) {
        return nil;
    }

    NSString *roomName = nil;
    NSString *networkId = nil;
    NSString *hostIP = nil;
    NSString *hostPort = nil;

    NSArray<NSString *> *lines = [text componentsSeparatedByString:@"\n"];

    // ========== 1. Match the prefixed fields line by line ==========

    NSRegularExpression *nameRegex = [NSRegularExpression
        regularExpressionWithPattern:@"Room\\s*name:?\\s*(.+)"
                             options:NSRegularExpressionCaseInsensitive
                               error:nil];

    NSRegularExpression *networkIdRegex = [NSRegularExpression
        regularExpressionWithPattern:@"(?:ZeroTier\\s*)?Network\\s*ID:?\\s*([0-9a-fA-F]{16})"
                             options:NSRegularExpressionCaseInsensitive
                               error:nil];

    // Key fix (M8): addressRegex now matches both IPv4 and IPv6 addresses.
    // It used to match only the IPv4 form ([0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}),
    // so an IPv6 server address in ad-hoc share text (such as [2001:db8::1]:25565)
    // could not be parsed at all and hostIP was always empty when importing an ad-hoc room from share text.
    //
    // The fix: add an IPv6 branch to the regex, matching a bracketed IPv6 address (\[[0-9a-fA-F:]+\]).
    // Note: shareTextForRoom always emits IPv6 addresses in the [IPv6]:port form (the M7 fix),
    // so only the bracketed form needs matching here.
    // The brackets are kept in hostIP, which makes the address type easy to recognize later.
    NSRegularExpression *addressRegex = [NSRegularExpression
        regularExpressionWithPattern:@"Server\\s*address:?\\s*((?:[0-9]{1,3}\\.[0-9]{1,3}\\.[0-9]{1,3}\\.[0-9]{1,3}|\\[[0-9a-fA-F:]+\\]))(?::([0-9]{1,5}))?"
                             options:0
                               error:nil];

    for (NSString *line in lines) {
        NSString *trimmedLine = [line stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
        if (trimmedLine.length == 0) continue;

        if (!roomName) {
            NSTextCheckingResult *nameMatch = [nameRegex firstMatchInString:trimmedLine
                                                                   options:0
                                                                     range:NSMakeRange(0, trimmedLine.length)];
            if (nameMatch && nameMatch.numberOfRanges >= 2) {
                roomName = [trimmedLine substringWithRange:[nameMatch rangeAtIndex:1]];
                roomName = [roomName stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
            }
        }

        if (!networkId) {
            NSTextCheckingResult *networkMatch = [networkIdRegex firstMatchInString:trimmedLine
                                                                            options:0
                                                                              range:NSMakeRange(0, trimmedLine.length)];
            if (networkMatch && networkMatch.numberOfRanges >= 2) {
                networkId = [trimmedLine substringWithRange:[networkMatch rangeAtIndex:1]];
                networkId = [networkId lowercaseString];
            }
        }

        if (!hostIP) {
            NSTextCheckingResult *addressMatch = [addressRegex firstMatchInString:trimmedLine
                                                                          options:0
                                                                            range:NSMakeRange(0, trimmedLine.length)];
            if (addressMatch && addressMatch.numberOfRanges >= 2) {
                hostIP = [trimmedLine substringWithRange:[addressMatch rangeAtIndex:1]];
                if (addressMatch.numberOfRanges >= 3) {
                    NSRange portRange = [addressMatch rangeAtIndex:2];
                    if (portRange.location != NSNotFound && portRange.length > 0) {
                        hostPort = [trimmedLine substringWithRange:portRange];
                    }
                }
            }
        }
    }

    // ========== 2. Fallback: search the whole text when no network ID matched ==========

    if (!networkId) {
        NSRegularExpression *rawHexRegex = [NSRegularExpression
            regularExpressionWithPattern:@"\\b([0-9a-fA-F]{16})\\b"
                                 options:0
                                   error:nil];
        NSTextCheckingResult *rawHexMatch = [rawHexRegex firstMatchInString:text
                                                                   options:0
                                                                     range:NSMakeRange(0, text.length)];
        if (rawHexMatch && rawHexMatch.numberOfRanges >= 2) {
            networkId = [[text substringWithRange:[rawHexMatch rangeAtIndex:1]] lowercaseString];
        }
    }

    // ========== 3. Fallback: search the whole text when no server address matched ==========

    if (!hostIP) {
        // Key fix (M8): rawAddressRegex supports IPv6 addresses (in the bracketed form) too.
        NSRegularExpression *rawAddressRegex = [NSRegularExpression
            regularExpressionWithPattern:@"((?:[0-9]{1,3}\\.[0-9]{1,3}\\.[0-9]{1,3}\\.[0-9]{1,3}|\\[[0-9a-fA-F:]+\\]))(?::([0-9]{1,5}))?"
                                 options:0
                                   error:nil];
        NSTextCheckingResult *rawAddressMatch = [rawAddressRegex firstMatchInString:text
                                                                           options:0
                                                                             range:NSMakeRange(0, text.length)];
        if (rawAddressMatch && rawAddressMatch.numberOfRanges >= 2) {
            hostIP = [text substringWithRange:[rawAddressMatch rangeAtIndex:1]];
            if (rawAddressMatch.numberOfRanges >= 3) {
                NSRange portRange = [rawAddressMatch rangeAtIndex:2];
                if (portRange.location != NSNotFound && portRange.length > 0) {
                    hostPort = [text substringWithRange:portRange];
                }
            }
        }
    }

    // ========== 4. Validate the parsed result ==========

    if (!networkId || networkId.length != 16) {
        NSLog(@"[MultiplayerManager] Parsing share text failed: Network ID invalid or missing");
        return nil;
    }

    if (![self isValidNetworkId:networkId]) {
        NSLog(@"[MultiplayerManager] Parsing share text failed: Network ID format validation failed: %@", networkId);
        return nil;
    }

    if (!roomName || roomName.length == 0) {
        roomName = @"Imported room";
    }

    if (!hostPort || hostPort.length == 0) {
        hostPort = kDefaultMCPort;
    }

    if (!hostIP) {
        hostIP = @"";
        NSLog(@"[MultiplayerManager] Parsing share text: server IP not found, user may need to manually add it later");
    }

    // ========== 5. Build the room object ==========

    MultiplayerRoom *room = [[MultiplayerRoom alloc] initWithId:nil
                                                            name:roomName
                                                       networkId:networkId
                                                          hostIP:hostIP
                                                        hostPort:hostPort];
    room.roomDescription = @"Imported from shared text";
    room.status = MultiplayerRoomStatusDisconnected;

    NSLog(@"[MultiplayerManager] Successfully parsed share text: name=%@, networkId=%@, host=%@:%@",
          roomName, networkId, hostIP, hostPort);

    return room;
}

#pragma mark - Helper methods

- (NSString *)generateRoomId {
    return [[NSUUID UUID] UUIDString];
}

- (BOOL)isValidNetworkId:(NSString *)networkId {
    if (!networkId || networkId.length != 16) {
        return NO;
    }

    NSCharacterSet *hexCharset = [NSCharacterSet characterSetWithCharactersInString:@"0123456789abcdefABCDEF"];
    for (NSUInteger i = 0; i < networkId.length; i++) {
        unichar ch = [networkId characterAtIndex:i];
        if (![hexCharset characterIsMember:ch]) {
            return NO;
        }
    }

    NSString *lowercase = [networkId lowercaseString];
    if ([lowercase isEqualToString:@"0000000000000000"]) {
        return NO;
    }

    return YES;
}

- (BOOL)isValidIPAddress:(NSString *)ipAddress {
    if (!ipAddress || ipAddress.length == 0) {
        return NO;
    }

    NSArray *components = [ipAddress componentsSeparatedByString:@"."];
    if (components.count != 4) {
        return NO;
    }

    for (NSString *component in components) {
        if (component.length == 0 || component.length > 3) {
            return NO;
        }

        NSCharacterSet *digitCharset = [NSCharacterSet decimalDigitCharacterSet];
        for (NSUInteger i = 0; i < component.length; i++) {
            unichar ch = [component characterAtIndex:i];
            if (![digitCharset characterIsMember:ch]) {
                return NO;
            }
        }

        NSInteger value = [component integerValue];
        if (value < 0 || value > 255) {
            return NO;
        }

        if (component.length > 1 && [component hasPrefix:@"0"]) {
            return NO;
        }
    }

    return YES;
}

#pragma mark - Share codes (FCL style base64 encoding)

/// The JSON key constants of the share code
static NSString * const kShareCodeKeyNetworkId = @"n";
static NSString * const kShareCodeKeyHostIP = @"h";
static NSString * const kShareCodeKeyHostPort = @"p";
static NSString * const kShareCodeKeyRoomName = @"r";

/// The preference key for the preset network ID
static NSString * const kPresetNetworkIdPrefKey = @"multiplayer.preset_network_id";

- (NSString *)generateShareCodeForRoom:(MultiplayerRoom *)room {
    if (!room || !room.networkId) {
        return @"";
    }

    // Build the JSON dictionary
    NSMutableDictionary *jsonDict = [NSMutableDictionary dictionary];
    // Normalize the network ID case: always lowercase, so an inconsistent case cannot produce two different share codes for one room
    jsonDict[kShareCodeKeyNetworkId] = [room.networkId lowercaseString];
    if (room.hostIP && room.hostIP.length > 0) {
        jsonDict[kShareCodeKeyHostIP] = room.hostIP;
    }
    if (room.hostPort && room.hostPort.length > 0) {
        jsonDict[kShareCodeKeyHostPort] = room.hostPort;
    } else {
        jsonDict[kShareCodeKeyHostPort] = kDefaultMCPort;
    }
    if (room.name && room.name.length > 0) {
        jsonDict[kShareCodeKeyRoomName] = room.name;
    }

    // Serialize to JSON data
    NSError *jsonError = nil;
    NSData *jsonData = [NSJSONSerialization dataWithJSONObject:jsonDict
                                                       options:NSJSONWritingSortedKeys
                                                         error:&jsonError];
    if (jsonError || !jsonData) {
        NSLog(@"[MultiplayerManager] Generating share code failed: JSON serialization failed - %@", jsonError);
        return @"";
    }

    // Base64 encoding: the Base64EncodingOptions of NSData on iOS have no URL-safe option (Swift 6.2+ does),
    // so standard base64 is used first and + is replaced with - and / with _ by hand, giving the URL-safe form.
    // This stops a share code failing to parse after an IM/URL/email turns + into a space or / into _.
    NSString *base64String = [jsonData base64EncodedStringWithOptions:0];
    base64String = [base64String stringByReplacingOccurrencesOfString:@"+" withString:@"-"];
    base64String = [base64String stringByReplacingOccurrencesOfString:@"/" withString:@"_"];
    // The standard encoding produces no line breaks, but whitespace is stripped anyway just in case
    base64String = [base64String stringByReplacingOccurrencesOfString:@" " withString:@""];

    NSLog(@"[MultiplayerManager] Share code generated (length=%lu): %@...",
          (unsigned long)base64String.length,
          base64String.length > 20 ? [base64String substringToIndex:20] : base64String);

    return base64String;
}

- (nullable MultiplayerRoom *)parseShareCode:(NSString *)code {
    if (!code || code.length == 0) {
        return nil;
    }

    // Clean the input: strip surrounding whitespace and newlines
    NSString *cleanCode = [code stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (cleanCode.length == 0) {
        return nil;
    }

    // Compatibility with older share codes and ones mangled by an IM client:
    // - newer generators use URL-safe base64 (- and _)
    // - older generators use standard base64 (+ and /)
    // - some IM/URL handling turns + into a space, / into _ and so on
    // The strategy: turn spaces back into +, turn the URL-safe characters (- _) back into the standard ones (+ /),
    // then decode as standard base64. That handles both formats and mangled codes.
    NSMutableString *normalized = [cleanCode mutableCopy];
    [normalized replaceOccurrencesOfString:@" " withString:@"+" options:0 range:NSMakeRange(0, normalized.length)];
    [normalized replaceOccurrencesOfString:@"-" withString:@"+" options:0 range:NSMakeRange(0, normalized.length)];
    [normalized replaceOccurrencesOfString:@"_" withString:@"/" options:0 range:NSMakeRange(0, normalized.length)];

    // Base64 decoding (still with IgnoreUnknownCharacters as a fallback, ignoring any other stray characters)
    NSData *jsonData = [[NSData alloc] initWithBase64EncodedString:normalized
                                                            options:NSDataBase64DecodingIgnoreUnknownCharacters];
    if (!jsonData || jsonData.length == 0) {
        NSLog(@"[MultiplayerManager] Parsing share code failed: Base64 decoding failed");
        return nil;
    }

    // JSON deserialization
    NSError *jsonError = nil;
    NSDictionary *jsonDict = [NSJSONSerialization JSONObjectWithData:jsonData
                                                            options:0
                                                              error:&jsonError];
    if (jsonError || !jsonDict || ![jsonDict isKindOfClass:[NSDictionary class]]) {
        NSLog(@"[MultiplayerManager] Parsing share code failed: JSON deserialization failed - %@", jsonError);
        return nil;
    }

    // Extract the fields
    NSString *networkId = jsonDict[kShareCodeKeyNetworkId];
    NSString *hostIP = jsonDict[kShareCodeKeyHostIP];
    NSString *hostPort = jsonDict[kShareCodeKeyHostPort];
    NSString *roomName = jsonDict[kShareCodeKeyRoomName];

    // Normalize the network ID case: always lowercase, so an inconsistent case cannot break joining the ZeroTier network
    if (networkId) {
        networkId = [networkId lowercaseString];
    }

    // Validate the network ID
    if (!networkId || ![self isValidNetworkId:networkId]) {
        NSLog(@"[MultiplayerManager] Parsing share code failed: Invalid Network ID - %@", networkId);
        return nil;
    }

    // Build the room object
    MultiplayerRoom *room = [[MultiplayerRoom alloc] init];
    room.roomId = [self generateRoomId];
    room.networkId = networkId;
    room.hostIP = hostIP ?: @"";
    room.hostPort = hostPort ?: kDefaultMCPort;
    room.name = roomName ?: [NSString stringWithFormat:@"%@...", [networkId substringToIndex:8]];
    room.roomDescription = @"";
    room.ownerName = @"";
    room.status = MultiplayerRoomStatusDisconnected;
    // Key fix: a room parsed from a share code is always in the guest role
    room.role = MultiplayerRoomRoleGuest;
    room.createdAt = [NSDate date];

    NSLog(@"[MultiplayerManager] Share code parsed: roomName=%@ networkId=%@ hostIP=%@ hostPort=%@",
          room.name, room.networkId, room.hostIP, room.hostPort);

    return room;
}

#pragma mark - Preset network ID management (FCL style)

- (nullable NSString *)presetNetworkId {
    NSString *networkId = [[NSUserDefaults standardUserDefaults] stringForKey:kPresetNetworkIdPrefKey];
    if (networkId && networkId.length > 0 && [self isValidNetworkId:networkId]) {
        return networkId;
    }
    return nil;
}

- (void)setPresetNetworkId:(nullable NSString *)networkId {
    if (!networkId || networkId.length == 0) {
        [[NSUserDefaults standardUserDefaults] removeObjectForKey:kPresetNetworkIdPrefKey];
        NSLog(@"[MultiplayerManager] Cleared preset Network ID");
        return;
    }

    // Validate the format
    if (![self isValidNetworkId:networkId]) {
        NSLog(@"[MultiplayerManager] Preset Network ID format invalid, not saved: %@", networkId);
        return;
    }

    [[NSUserDefaults standardUserDefaults] setObject:networkId forKey:kPresetNetworkIdPrefKey];
    [[NSUserDefaults standardUserDefaults] synchronize];
    NSLog(@"[MultiplayerManager] Saved preset Network ID: %@", networkId);
}

#pragma mark - Ad-hoc networks (quick mode, no account registration needed)

- (NSString *)generateAdhocNetworkId {
    // Generate the ad-hoc network ID with zts_net_compute_adhoc_id
    // Parameters: the port range 0-65535 (covering every Minecraft port, including 25565 and the random LAN ports)
    // Return value: the network ID as a uint64_t, which has to be turned into a 16-digit hexadecimal string
    uint64_t adhocNetId = zts_net_compute_adhoc_id(0, 65535);

    // Key fix (H11): validate the value zts_net_compute_adhoc_id returns.
    // The return value used to be formatted into a string unchecked, which meant:
    //   - in stub mode (with zt.framework unavailable) zts_net_compute_adhoc_id returns 0,
    //     which formats to "0000000000000000", and the caller then tries to join a
    //     network that does not exist, causing all kinds of unpredictable errors.
    //   - even with the framework available, an invalid port range or an internal libzt fault
    //     can return 0 or an invalid value, which also makes joining the network fail later.
    //
    // The fix:
    //   1. check whether adhocNetId is 0 (the most obvious failure marker)
    //   2. check whether the high byte of adhocNetId is 0xff (the ad-hoc network ID spec requires
    //      the high byte to be 0xff; see the zts_net_compute_adhoc_id documentation
    //      in ZeroTierSockets.h, for example ff0000ffff000000)
    //   3. return nil if the checks fail, leaving it to the caller (the UI already checks for nil/empty)
    if (adhocNetId == 0) {
        NSLog(@"[MultiplayerManager] generateAdhocNetworkId failed: zts_net_compute_adhoc_id returned 0 (possibly stub mode or libzt error)");
        return nil;
    }

    // The high byte of an ad-hoc network ID must be 0xff (see the example on lines 1559-1560 of ZeroTierSockets.h:
    // ff00160016000000、ff0000ffff000000）
    uint8_t highByte = (uint8_t)((adhocNetId >> 56) & 0xFF);
    if (highByte != 0xFF) {
        NSLog(@"[MultiplayerManager] generateAdhocNetworkId failed: high byte of return value 0x%016llx is not 0xff (does not conform to Ad-hoc network ID spec)",
              adhocNetId);
        return nil;
    }

    // Convert it into a 16-digit hexadecimal string (matching the standard network ID format)
    NSString *adhocNetIdStr = [NSString stringWithFormat:@"%016llx", adhocNetId];

    NSLog(@"[MultiplayerManager] Ad-hoc network ID generated: %@ (raw=%llu)", adhocNetIdStr, adhocNetId);
    return adhocNetIdStr;
}

- (BOOL)isAdhocNetworkId:(NSString *)networkId {
    // Ad-hoc network IDs start with "ff" (such as ff0000ffff000000)
    // Standard network IDs start with something else (such as 1a2b3c4d5e6f7g8h)
    if (!networkId || networkId.length < 2) {
        return NO;
    }
    NSString *prefix = [[networkId substringToIndex:2] lowercaseString];
    return [prefix isEqualToString:@"ff"];
}


#pragma mark - Full cleanup when the world is closed

/// Stop every multiplayer service
/// Called when the world closes, the app quits or the connection drops, so every resource is released
- (void)stopAllMultiplayerServices {
    NSLog(@"[MultiplayerManager] Stopping all multiplayer services...");

    // 1. Stop the SOCKS5 proxy
    if ([[SOCKS5Proxy sharedProxy] isRunning]) {
        NSLog(@"[MultiplayerManager] Stopping SOCKS5 proxy");
        [[SOCKS5Proxy sharedProxy] stop];
    }

    // 2. Stop the port forwarder
    if ([[PortForwarder sharedForwarder] isRunning]) {
        NSLog(@"[MultiplayerManager] Stopping port forwarder");
        [[PortForwarder sharedForwarder] stop];
    }

    // 3. Clear the environment variable (so no old multiplayer code lingers)
    unsetenv([kAMETHYSTSOCKS5ProxyEnvVar UTF8String]);
    NSLog(@"[MultiplayerManager] Cleared SOCKS5 environment variable");

    // 4. Leave every ZeroTier network
    // Key fix (P1-6): the original code guarded the internalRooms read with _stateLock,
    // while every other read and write of internalRooms (addRoom/removeRoom/updateRoom/the savedRooms getter)
    // uses @synchronized(self). _stateLock and @synchronized(self) are two unrelated locks,
    // and reading and writing a mutable array at once is undefined behavior that can crash with EXC_BAD_ACCESS.
    // The fix: read internalRooms under @synchronized(self) too, matching the rest of the project.
    NSArray *rooms;
    @synchronized(self) {
        rooms = [self.internalRooms copy];
    }

    for (MultiplayerRoom *room in rooms) {
        if (room.networkId && room.networkId.length > 0) {
            // networkId is a 16-digit hexadecimal string and must be parsed with parseNetworkIDFromString,
            // not unsignedLongLongValue (NSString has no such method, and it would parse as decimal anyway)
            uint64_t networkID = [ZeroTierBridge parseNetworkIDFromString:room.networkId];
            if (networkID == 0) {
                NSLog(@"[MultiplayerManager] Skipping invalid Network ID: %@", room.networkId);
                continue;
            }
            NSLog(@"[MultiplayerManager] Leaving network: %@", room.networkId);
            [[ZeroTierBridge sharedInstance] leaveNetwork:networkID];
        }
    }

    // 5. Stop the ZeroTier node
    NSLog(@"[MultiplayerManager] Stopping ZeroTier node");
    [[ZeroTierBridge sharedInstance] stopNode];

    // 6. Reset every piece of state (so hosting next time generates a fresh multiplayer code)
    [_stateLock lock];
    self.currentRoom = nil;
    self.currentNetworkID = 0;
    self.currentLocalIP = nil;
    self.currentSOCKS5Port = 0;
    self.currentForwardingPort = 0;
    _nodeStarted = NO;
    [_stateLock unlock];

    // 7. Key fix (P0-A): clear any leftover serverIp in PLProfiles
    // Same reasoning as disconnectCurrentRoom: stop a leftover serverIp triggering
    // the "it always shows connecting to a server" bug on the next Minecraft launch. stopAllMultiplayerServices runs when the game quits,
    // when the app goes to the background and when it is terminated, so it must clean up completely.
    @try {
        NSString *currentProfile = [[PLProfiles current] selectedProfileName];
        if (currentProfile.length > 0) {
            [[PLProfiles current] setServerIp:@"" forProfile:currentProfile];
            NSLog(@"[MultiplayerManager] Cleared serverIp for profile '%@'", currentProfile);
        }
    } @catch (NSException *e) {
        NSLog(@"[MultiplayerManager] Failed to clear serverIp: %@", e);
    }

    NSLog(@"[MultiplayerManager] All multiplayer services stopped, state reset");
}

#pragma mark - Starting the PortForwarder in host mode

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
                               localHostPort:(uint16_t)localHostPort {
    // Check the currently connected room
    [_stateLock lock];
    MultiplayerRoom *room = self.currentRoom;
    MultiplayerRoomStatus status = room.status;
    [_stateLock unlock];

    if (!room || status != MultiplayerRoomStatusConnected) {
        NSLog(@"[MultiplayerManager] startHostPortForwarder failed: no room connected (room=%@ status=%ld)",
              room ? room.name : @"nil", (long)status);
        return NO;
    }

    // If PortForwarder is already running, stop the old mode first
    if ([[PortForwarder sharedForwarder] isRunning]) {
        NSLog(@"[MultiplayerManager] startHostPortForwarder: PortForwarder already running (mode=%ld), stopping first",
              (long)[[PortForwarder sharedForwarder] mode]);
        [[PortForwarder sharedForwarder] stop];

        [_stateLock lock];
        self.currentForwardingPort = 0;
        [_stateLock unlock];
    }

    NSLog(@"[MultiplayerManager] Starting PortForwarder host mode: ZeroTier listening %u → local 127.0.0.1:%u",
          listenPort, localHostPort);

    BOOL started = [[PortForwarder sharedForwarder] startHostModeWithListenPort:listenPort
                                                                  localHostPort:localHostPort];
    if (!started) {
        NSLog(@"[MultiplayerManager] PortForwarder host mode start failed");
        return NO;
    }

    uint16_t actualPort = [[PortForwarder sharedForwarder] listeningPort];
    [_stateLock lock];
    self.currentForwardingPort = actualPort;
    [_stateLock unlock];

    NSLog(@"[MultiplayerManager] PortForwarder host mode started: ZeroTier listening %u → local 127.0.0.1:%u",
          actualPort, localHostPort);
    return YES;
}

@end