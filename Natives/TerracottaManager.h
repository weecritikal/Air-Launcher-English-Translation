#import <Foundation/Foundation.h>
#import "TerracottaBridge.h"

NS_ASSUME_NONNULL_BEGIN

/// Multiplayer session status (high-level state machine: 8 low-level Rust states → 4 UI states)
typedef NS_ENUM(NSInteger, TerracottaStatus) {
    TerracottaStatusDisconnected = 0,  /* Not connected */
    TerracottaStatusConnecting   = 1,  /* Connecting (host-scanning/starting, guest-connecting/starting) */
    TerracottaStatusConnected    = 2,  /* Connected (host-ok, guest-ok) */
    TerracottaStatusError        = 3,  /* Error (exception) */
};

/// Current role
typedef NS_ENUM(NSInteger, TerracottaRole) {
    TerracottaRoleNone   = 0,
    TerracottaRoleHost   = 1,  /* Host */
    TerracottaRoleClient = 2,  /* Guest */
};

/// State change notification name. userInfo is nil; callers read the latest state through [TerracottaManager shared].
extern NSNotificationName TerracottaManagerStateDidChangeNotification;

/// Multiplayer manager singleton
///
/// Wraps TerracottaBridge state polling, state machine mapping and SilentAudioPlayer background keep-alive.
/// The UI observes state changes via KVO or TerracottaManagerStateDidChangeNotification.
@interface TerracottaManager : NSObject

+ (instancetype)shared;

@property(nonatomic, readonly) TerracottaStatus status;
@property(nonatomic, readonly) TerracottaRole role;
@property(nonatomic, readonly, nullable) NSString *currentInviteCode;  /* The host's invite code */
@property(nonatomic, readonly) uint16_t currentPort;                   /* The host's MC LAN port */
@property(nonatomic, readonly, nullable) NSString *stageDescription;   /* Stage text shown in the UI */
@property(nonatomic, readonly, nullable) NSArray<TerracottaPlayerProfile *> *players;
@property(nonatomic, readonly, nullable) NSString *directConnectURL;   /* Direct connect address for guests entering MC */
@property(nonatomic, readonly, nullable) NSString *lastError;
@property(nonatomic, readonly) BOOL initialized;

/// Called once at app launch (triggered by SceneDelegate). A no-op when libterracotta is not linked.
- (void)initializeTerracotta;

/// Host: create a room (manual port mode).
/// Flow: reset → setConnecting → startKeepingAlive → startHostWithPort → startPolling
- (void)createRoomWithPort:(uint16_t)port
                inviteCode:(nullable NSString *)inviteCode
                playerName:(nullable NSString *)playerName;

/// Guest: join a room.
/// Flow: verifyRoomCode → reset → setConnecting → startKeepingAlive → setGuesting → startPolling
/// Returns NO if the invite code format is invalid (no join is attempted).
- (BOOL)joinRoomWithInviteCode:(NSString *)inviteCode
                    playerName:(nullable NSString *)playerName;

/// Terminate the current session and return to the Disconnected state.
- (void)stopSession;

@end

NS_ASSUME_NONNULL_END
