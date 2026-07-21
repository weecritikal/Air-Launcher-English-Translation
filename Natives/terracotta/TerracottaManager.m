#import "TerracottaManager.h"
#import "TerracottaBridge.h"
#import "SilentAudioPlayer.h"

NSNotificationName TerracottaManagerStateDidChangeNotification = @"TerracottaManagerStateDidChange";

@interface TerracottaManager ()
@property(nonatomic, assign, readwrite) TerracottaStatus status;
@property(nonatomic, assign, readwrite) TerracottaRole role;
@property(nonatomic, copy,   readwrite, nullable) NSString *currentInviteCode;
@property(nonatomic, copy,   readwrite, nullable) NSString *currentPort;
@property(nonatomic, copy,   readwrite) NSString *stageDescription;
@property(nonatomic, copy,   readwrite, nullable) NSArray<TerracottaPlayerProfile *> *players;
@property(nonatomic, copy,   readwrite, nullable) NSString *directConnectURL;
@property(nonatomic, copy,   readwrite, nullable) NSString *lastError;
@property(nonatomic, assign, readwrite) BOOL initialized;
@end

@implementation TerracottaManager {
    BOOL _sessionActive;
    TerracottaStateKind _lastStateKind;
    NSInteger _lastStateIndex;
    dispatch_source_t _pollTimer;
}

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
        _stageDescription = @"";
        _sessionActive = NO;
        _lastStateKind = TerracottaStateWaiting;
        _lastStateIndex = -1;
        [self initializeTerracotta];
    }
    return self;
}

#pragma mark - Initialization

- (void)initializeTerracotta {
    if (self.initialized) return;

    NSString *docsDir = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject;
    if (docsDir == nil) docsDir = NSTemporaryDirectory();

    /* 用独立的 terracotta/ 子目录存放工作数据（machine-id、日志等），
     * 避免污染 Documents 根目录，且方便用户清理重置。 */
    NSString *workDir = [docsDir stringByAppendingPathComponent:@"terracotta"];
    [[NSFileManager defaultManager] createDirectoryAtPath:workDir
                              withIntermediateDirectories:YES attributes:nil error:nil];

    NSString *logPath = [workDir stringByAppendingPathComponent:@"terracotta.log"];

    BOOL ok = [TerracottaBridge startWithWorkingDirectory:workDir loggingPath:logPath];
    if (!ok) {
        NSLog(@"[TerracottaManager] terracotta_ios_start failed");
        self.lastError = @"Terracotta 初始化失败";
        self.status = TerracottaStatusError;
        return;
    }

    NSLog(@"[TerracottaManager] Terracotta initialized, workDir=%@", workDir);
    self.initialized = YES;
}

#pragma mark - Public API

- (BOOL)createRoomWithInviteCode:(NSString *)inviteCode
                            port:(NSString *)port
                       playerName:(NSString *)playerName {
    if (!self.initialized) {
        self.lastError = @"Terracotta 未初始化";
        return NO;
    }

    [self resetSessionState];

    self.role = TerracottaRoleHost;
    self.currentInviteCode = inviteCode;
    self.currentPort = port;
    self.status = TerracottaStatusConnecting;
    self.stageDescription = @"正在扫描本地 Minecraft 服务器...";
    _sessionActive = YES;

    [[SilentAudioPlayer shared] startKeepingAlive];
    [TerracottaBridge setScanningWithRoom:inviteCode playerName:playerName];
    [self startPolling];
    [self notifyStateChanged];
    return YES;
}

- (BOOL)createRoomWithPort:(uint16_t)port
                inviteCode:(NSString *)inviteCode
                playerName:(NSString *)playerName {
    if (!self.initialized) {
        self.lastError = @"Terracotta 未初始化";
        return NO;
    }

    [self resetSessionState];

    self.role = TerracottaRoleHost;
    self.currentInviteCode = inviteCode;
    self.currentPort = [NSString stringWithFormat:@"%u", port];
    self.status = TerracottaStatusConnecting;
    self.stageDescription = @"正在生成邀请码并启动虚拟网络...";
    _sessionActive = YES;

    [[SilentAudioPlayer shared] startKeepingAlive];

    BOOL ok = [TerracottaBridge startHostWithRoom:inviteCode port:port playerName:playerName];
    if (!ok) {
        self.lastError = @"启动失败：Terracotta 不在 Waiting 状态";
        self.status = TerracottaStatusError;
        _sessionActive = NO;
        [[SilentAudioPlayer shared] stopKeepingAlive];
        [self notifyStateChanged];
        return NO;
    }

    [self startPolling];
    [self notifyStateChanged];
    return YES;
}

- (BOOL)joinRoomWithInviteCode:(NSString *)inviteCode
                    playerName:(NSString *)playerName {
    if (!self.initialized) {
        self.lastError = @"Terracotta 未初始化";
        return NO;
    }

    if (![TerracottaBridge verifyRoomCode:inviteCode]) {
        self.lastError = @"邀请码格式错误（应为 U/NNNN-NNNN-SSSS-SSSS）";
        [self notifyStateChanged];
        return NO;
    }

    [self resetSessionState];

    self.role = TerracottaRoleClient;
    self.currentInviteCode = inviteCode;
    self.status = TerracottaStatusConnecting;
    self.stageDescription = @"正在连接房主...";
    _sessionActive = YES;

    [[SilentAudioPlayer shared] startKeepingAlive];

    BOOL ok = [TerracottaBridge setGuestingWithRoom:inviteCode playerName:playerName];
    if (!ok) {
        self.lastError = @"加入失败：邀请码无效或 Terracotta 不在 Waiting 状态";
        self.status = TerracottaStatusError;
        _sessionActive = NO;
        [[SilentAudioPlayer shared] stopKeepingAlive];
        [self notifyStateChanged];
        return NO;
    }

    [self startPolling];
    [self notifyStateChanged];
    return YES;
}

- (void)stopSession {
    if (!_sessionActive) return;
    _sessionActive = NO;

    [TerracottaBridge setWaiting];
    [self stopPolling];
    [[SilentAudioPlayer shared] stopKeepingAlive];

    dispatch_async(dispatch_get_main_queue(), ^{
        self.status = TerracottaStatusDisconnected;
        self.role = TerracottaRoleNone;
        self.currentInviteCode = nil;
        self.currentPort = nil;
        self.stageDescription = @"";
        self.players = nil;
        self.directConnectURL = nil;
        self.lastError = nil;
        _lastStateKind = TerracottaStateWaiting;
        _lastStateIndex = -1;
        [self notifyStateChanged];
    });
}

- (BOOL)verifyRoomCode:(NSString *)code {
    return [TerracottaBridge verifyRoomCode:code];
}

#pragma mark - Polling

- (void)startPolling {
    [self stopPolling];
    /* 用 dispatch_source_t 创建 0.5s 重复定时器，比 NSTimer 在后台模式下更可靠 */
    dispatch_source_t timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0,
                                                      dispatch_get_global_queue(QOS_CLASS_UTILITY, 0));
    dispatch_source_set_timer(timer, dispatch_time(DISPATCH_TIME_NOW, 0),
                              500 * NSEC_PER_MSEC,  /* 0.5s */
                              100 * NSEC_PER_MSEC);
    dispatch_source_set_event_handler(timer, ^{
        [self pollOnce];
    });
    dispatch_resume(timer);
    _pollTimer = timer;
}

- (void)stopPolling {
    if (_pollTimer != nil) {
        dispatch_source_cancel(_pollTimer);
        _pollTimer = nil;
    }
}

- (void)pollOnce {
    TerracottaState *state = [TerracottaBridge pollState];
    if (state == nil) return;

    /* 跳过未变化的状态（避免无谓的通知触发） */
    if (state.kind == _lastStateKind && state.index == _lastStateIndex) return;
    _lastStateKind = state.kind;
    _lastStateIndex = state.index;

    dispatch_async(dispatch_get_main_queue(), ^{
        [self applyState:state];
    });
}

- (void)applyState:(TerracottaState *)state {
    self.stageDescription = [self localizedStageForState:state];

    switch (state.kind) {
        case TerracottaStateWaiting:
            if (_sessionActive) {
                self.status = TerracottaStatusDisconnected;
                _sessionActive = NO;
                [[SilentAudioPlayer shared] stopKeepingAlive];
                [self stopPolling];
            }
            break;

        case TerracottaStateHostScanning:
            self.status = TerracottaStatusConnecting;
            self.players = nil;
            break;

        case TerracottaStateHostStarting:
            self.status = TerracottaStatusConnecting;
            if (self.currentInviteCode == nil && state.room != nil) {
                self.currentInviteCode = state.room;
            }
            break;

        case TerracottaStateHostOk:
            self.status = TerracottaStatusConnected;
            if (self.currentInviteCode == nil && state.room != nil) {
                self.currentInviteCode = state.room;
            }
            self.players = state.profiles;
            self.lastError = nil;
            break;

        case TerracottaStateGuestConnecting:
            self.status = TerracottaStatusConnecting;
            self.players = nil;
            break;

        case TerracottaStateGuestStarting:
            self.status = TerracottaStatusConnecting;
            break;

        case TerracottaStateGuestOk:
            self.status = TerracottaStatusConnected;
            self.directConnectURL = state.url;
            if (state.url != nil) {
                NSRange colonRange = [state.url rangeOfString:@":" options:NSBackwardsSearch];
                if (colonRange.location != NSNotFound && colonRange.location + 1 < state.url.length) {
                    self.currentPort = [state.url substringFromIndex:colonRange.location + 1];
                }
            }
            self.players = state.profiles;
            self.lastError = nil;
            break;

        case TerracottaStateException:
            self.status = TerracottaStatusError;
            self.lastError = [TerracottaBridge describeException:state.exceptionType];
            /* 异常后保持轮询，让 Rust 侧可能的自愈（set_waiting）能反映到 UI */
            break;
    }

    [self notifyStateChanged];
}

- (NSString *)localizedStageForState:(TerracottaState *)state {
    switch (state.kind) {
        case TerracottaStateWaiting:         return @"空闲";
        case TerracottaStateHostScanning:    return @"正在扫描本地 Minecraft 服务器...";
        case TerracottaStateHostStarting:    return @"正在生成邀请码并启动虚拟网络...";
        case TerracottaStateHostOk:          return @"房间已就绪，可被加入";
        case TerracottaStateGuestConnecting: return @"正在连接房主...";
        case TerracottaStateGuestStarting:
            return [NSString stringWithFormat:@"正在建立联机隧道（难度: %@）...",
                    state.difficulty ?: @"UNKNOWN"];
        case TerracottaStateGuestOk:
            return [NSString stringWithFormat:@"已连接，在 MC 直接连 %@", state.url ?: @""];
        case TerracottaStateException:
            return [TerracottaBridge describeException:state.exceptionType];
    }
    return @"";
}

#pragma mark - Helpers

- (void)resetSessionState {
    self.lastError = nil;
    self.stageDescription = @"";
    self.players = nil;
    self.directConnectURL = nil;
    _lastStateKind = TerracottaStateWaiting;
    _lastStateIndex = -1;
    if (_sessionActive) {
        [TerracottaBridge setWaiting];
    }
}

- (void)notifyStateChanged {
    [[NSNotificationCenter defaultCenter] postNotificationName:TerracottaManagerStateDidChangeNotification
                                                        object:self];
}

@end
