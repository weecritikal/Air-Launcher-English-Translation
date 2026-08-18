#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// The 8 low-level state enums on the Rust side (corresponding to the "state" field of the JSON returned by terracotta_ios_get_state)
typedef NS_ENUM(NSInteger, TerracottaStateKind) {
    TerracottaStateKindWaiting          = 0,  /* Idle, multiplayer not started */
    TerracottaStateKindHostScanning     = 1,  /* Host: scanning for MC LAN multicast */
    TerracottaStateKindHostStarting     = 2,  /* Host: EasyTier starting */
    TerracottaStateKindHostOk           = 3,  /* Host: connection established, waiting for guests */
    TerracottaStateKindGuestConnecting  = 4,  /* Guest: connecting to the host */
    TerracottaStateKindGuestStarting    = 5,  /* Guest: EasyTier starting */
    TerracottaStateKindGuestOk          = 6,  /* Guest: connection established, ready to enter MC */
    TerracottaStateKindException        = 7,  /* Exception (see the type field) */
};

/// Player profile (host + joined guests)
@interface TerracottaPlayerProfile : NSObject
@property(nonatomic, copy, nullable) NSString *name;
@property(nonatomic, copy, nullable) NSString *machineId;
@property(nonatomic, copy, nullable) NSString *easytierId;
@property(nonatomic, copy, nullable) NSString *vendor;
@property(nonatomic, copy, nullable) NSString *kind;
@end

/// State snapshot from the Rust side
@interface TerracottaState : NSObject
@property(nonatomic, assign) TerracottaStateKind kind;
@property(nonatomic, assign) NSInteger index;
@property(nonatomic, copy, nullable) NSString *room;
@property(nonatomic, copy, nullable) NSString *directConnectURL;
@property(nonatomic, copy, nullable) NSArray<TerracottaPlayerProfile *> *profiles;
@property(nonatomic, assign) NSInteger profileIndex;
@property(nonatomic, assign) NSInteger exceptionType;  /* Only valid when kind==Exception */
@end

/// C ABI wrapper layer. All methods are thread safe.
@interface TerracottaBridge : NSObject

/// Checks at runtime whether libterracotta is linked. When it is not, all calls degrade safely.
+ (BOOL)isAvailable;

/// Initialize Terracotta. Called once at app launch.
+ (BOOL)startWithWorkingDirectory:(NSString *)workingDirectory
                       loggingPath:(nullable NSString *)loggingPath;

/// Return to the Waiting state (terminating the current session). Idempotent.
+ (void)setWaiting;

/// Host: start scanning for MC LAN multicast.
+ (void)setScanningWithRoom:(nullable NSString *)room
                 playerName:(nullable NSString *)playerName;

/// Host (manual port mode): start the host using the MC LAN port entered by the user.
+ (BOOL)startHostWithRoom:(nullable NSString *)room
                     port:(uint16_t)port
               playerName:(nullable NSString *)playerName;

/// Guest: join a room.
+ (BOOL)setGuestingWithRoom:(NSString *)room
                 playerName:(nullable NSString *)playerName;

/// Validate the invite code format. Returns YES for a valid Scaffolding invite code.
+ (BOOL)verifyRoomCode:(NSString *)code;

/// Poll the current state. Returns nil if parsing failed or the library is unavailable.
+ (nullable TerracottaState *)pollState;

/// Metadata: version / compileTimestamp / easytierVersion.
+ (nullable NSDictionary<NSString *, id> *)metadata;

/// Exception type description (for UI display).
+ (NSString *)describeException:(NSInteger)type;

@end

NS_ASSUME_NONNULL_END
