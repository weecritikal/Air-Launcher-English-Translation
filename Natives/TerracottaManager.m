#import "TerracottaManager.h"
#import "TerracottaBridge.h"
#import "SilentAudioPlayer.h"
#import "utils.h"

NSNotificationName TerracottaManagerStateDidChangeNotification = @"TerracottaManagerStateDidChange";

@interface TerracottaManager ()
@property(nonatomic, assign) TerracottaStatus status;
@property(nonatomic, assign) TerracottaRole role;
@property(nonatomic, copy, nullable) NSString *currentInviteCode;
@property(nonatomic, assign) uint16_t currentPort;
@property(nonatomic, copy, nullable) NSString *stageDescription;
@property(nonatomic, copy, nullable) NSArray<TerracottaPlayerProfile *> *players;
@property(nonatomic, copy, nullable) NSString *directConnectURL;
@property(nonatomic, copy, nullable) NSString *lastError;
@property(nonatomic, assign) BOOL initialized;
@end

@implementation TerracottaManager {
    dispatch_source_t _pollTimer;
    NSInteger _lastStateKind;
    NSInteger _lastStateIndex;
    dispatch_queue_t _pollQueue;
}

#pragma mark - Singleton

+ (instancetype)shared {
    static TerracottaManager *instance;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        instance = [[TerracottaManager alloc] init];
    });
    return instance;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _status = TerracottaStatusDisconnected;
        _role = TerracottaRoleNone;
        _pollQueue = dispatch_queue_create("terracotta.poll", dispatch_queue_attr_make_with_qos_class(
            DISPATCH_QUEUE_SERIAL, QOS_CLASS_UTILITY, 0));
        /* Terracotta is initialized automatically when the singleton triggers init (if the library is available) */
        [self initializeTerracotta];
    }
    return self;
}

#pragma mark - Initialization

- (void)initializeTerracotta {
    if (self.initialized) return;
    if (![TerracottaBridge isAvailable]) {
        NSLog(@"[TerracottaManager] libterracotta not linked, multiplayer disabled");
        return;
    }

    NSString *docsDir = NSSearchPathForDirectoriesInDomains(
        NSDocumentDirectory, NSUserDomainMask, YES).firstObject;
    if (docsDir == nil) docsDir = NSTemporaryDirectory();

    /* Use a separate terracotta/ subdirectory to hold working data */
    NSString *workDir = [docsDir stringByAppendingPathComponent:@"terracotta"];
    [[NSFileManager defaultManager] createDirectoryAtPath:workDir
                              withIntermediateDirectories:YES
                                               attributes:nil error:nil];
    NSString *logPath = [workDir stringByAppendingPathComponent:@"terracotta.log"];

    BOOL ok = [TerracottaBridge startWithWorkingDirectory:workDir loggingPath:logPath];
    if (!ok) {
        NSLog(@"[TerracottaManager] terracotta_ios_start failed");
        self.lastError = @"Terracotta failed to initialize";
        self.status = TerracottaStatusError;
        return;
    }
    NSLog(@"[TerracottaManager] Terracotta initialized at %@", workDir);
    self.initialized = YES;
}

#pragma mark - Session Control

- (void)createRoomWithPort:(uint16_t)port
                inviteCode:(NSString *)inviteCode
                playerName:(NSString *)playerName {
    [self resetSessionState];
    self.role = TerracottaRoleHost;
    self.currentPort = port;
    self.currentInviteCode = inviteCode;
    self.status = TerracottaStatusConnecting;
    self.stageDescription = @"Creating the room…";
    self.lastError = nil;

    [[SilentAudioPlayer shared] startKeepingAlive];

    BOOL ok = [TerracottaBridge startHostWithRoom:inviteCode
                                              port:port
                                        playerName:playerName];
    if (!ok) {
        self.status = TerracottaStatusError;
        self.lastError = @"Could not start hosting (make sure no session is already active)";
        [[SilentAudioPlayer shared] stopKeepingAlive];
        [self notifyStateChanged];
        return;
    }
    [self startPolling];
    [self notifyStateChanged];
}

- (BOOL)joinRoomWithInviteCode:(NSString *)inviteCode
                    playerName:(NSString *)playerName {
    if (![TerracottaBridge verifyRoomCode:inviteCode]) {
        self.lastError = @"Invalid invite code format";
        return NO;
    }
    [self resetSessionState];
    self.role = TerracottaRoleClient;
    self.currentInviteCode = inviteCode;
    self.status = TerracottaStatusConnecting;
    self.stageDescription = @"Joining the room…";
    self.lastError = nil;

    [[SilentAudioPlayer shared] startKeepingAlive];

    BOOL ok = [TerracottaBridge setGuestingWithRoom:inviteCode playerName:playerName];
    if (!ok) {
        self.status = TerracottaStatusError;
        self.lastError = @"Could not join (the invite code is invalid, or a session is already active)";
        [[SilentAudioPlayer shared] stopKeepingAlive];
        [self notifyStateChanged];
        return NO;
    }
    [self startPolling];
    [self notifyStateChanged];
    return YES;
}

- (void)stopSession {
    [TerracottaBridge setWaiting];
    [self stopPolling];
    [[SilentAudioPlayer shared] stopKeepingAlive];
    [self resetSessionState];
    [self notifyStateChanged];
}

#pragma mark - State Reset

- (void)resetSessionState {
    self.role = TerracottaRoleNone;
    self.status = TerracottaStatusDisconnected;
    self.currentInviteCode = nil;
    self.currentPort = 0;
    self.stageDescription = nil;
    self.players = nil;
    self.directConnectURL = nil;
    /* lastError is not cleared here, so the UI can still see the previous error (if any) after stopSession */
    _lastStateKind = -1;
    _lastStateIndex = -1;
}

#pragma mark - Polling

- (void)startPolling {
    [self stopPolling];
    /* dispatch_source_t timer, 0.5s interval, on a QOS_CLASS_UTILITY queue to avoid blocking the main thread */
    _pollTimer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, _pollQueue);
    dispatch_time_t start = dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC));
    dispatch_source_set_timer(_pollTimer, start,
                              (uint64_t)(0.5 * NSEC_PER_SEC),
                              (uint64_t)(0.1 * NSEC_PER_SEC));
    __weak typeof(self) weakSelf = self;
    dispatch_source_set_event_handler(_pollTimer, ^{
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (strongSelf == nil) return;
        TerracottaState *state = [TerracottaBridge pollState];
        if (state != nil) {
            [strongSelf applyState:state];
        }
    });
    dispatch_resume(_pollTimer);
}

- (void)stopPolling {
    if (_pollTimer != nil) {
        dispatch_source_cancel(_pollTimer);
        _pollTimer = nil;
    }
}

#pragma mark - State Mapping

/// Map the 8 low-level states on the Rust side to the 4 high-level states and update every @property.
/// State deduplication: skip the notification when neither state.kind nor state.index changed.
- (void)applyState:(TerracottaState *)state {
    if (state.kind == _lastStateKind && state.index == _lastStateIndex) {
        /* The state did not change, but the player list may have (a new player joined), so still update */
        if (state.profiles != nil) self.players = state.profiles;
        return;
    }
    _lastStateKind = state.kind;
    _lastStateIndex = state.index;

    switch (state.kind) {
        case TerracottaStateKindWaiting:
            self.status = TerracottaStatusDisconnected;
            self.stageDescription = nil;
            break;
        case TerracottaStateKindHostScanning:
            self.status = TerracottaStatusConnecting;
            self.stageDescription = @"Scanning for the Minecraft LAN port…";
            break;
        case TerracottaStateKindHostStarting:
            self.status = TerracottaStatusConnecting;
            self.stageDescription = @"Starting the EasyTier network…";
            break;
        case TerracottaStateKindHostOk:
            self.status = TerracottaStatusConnected;
            self.stageDescription = @"Room created, waiting for players to join";
            break;
        case TerracottaStateKindGuestConnecting:
            self.status = TerracottaStatusConnecting;
            self.stageDescription = @"Connecting to the host…";
            break;
        case TerracottaStateKindGuestStarting:
            self.status = TerracottaStatusConnecting;
            self.stageDescription = @"Starting the EasyTier network…";
            break;
        case TerracottaStateKindGuestOk:
            self.status = TerracottaStatusConnected;
            self.stageDescription = @"Joined the room";
            break;
        case TerracottaStateKindException:
            self.status = TerracottaStatusError;
            self.lastError = [TerracottaBridge describeException:state.exceptionType];
            self.stageDescription = self.lastError;
            /* Stop polling and keep-alive on an exception */
            [self stopPolling];
            [[SilentAudioPlayer shared] stopKeepingAlive];
            break;
    }

    /* Update the invite code and direct connect address (only overwrite when the Rust side has a value) */
    if (state.room.length > 0) self.currentInviteCode = state.room;
    if (state.directConnectURL.length > 0) self.directConnectURL = state.directConnectURL;
    if (state.profiles != nil) self.players = state.profiles;

    [self notifyStateChanged];
}

#pragma mark - Notification

- (void)notifyStateChanged {
    dispatch_async(dispatch_get_main_queue(), ^{
        [[NSNotificationCenter defaultCenter]
            postNotificationName:TerracottaManagerStateDidChangeNotification object:self];
    });
}

@end
