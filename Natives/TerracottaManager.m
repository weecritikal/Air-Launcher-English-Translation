#import "TerracottaManager.h"
#import "TerracottaBridge.h"
#import "SilentAudioPlayer.h"

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
        /* 单例触发 init 时自动初始化 Terracotta（若库可用） */
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

    /* 用独立的 terracotta/ 子目录存放工作数据 */
    NSString *workDir = [docsDir stringByAppendingPathComponent:@"terracotta"];
    [[NSFileManager defaultManager] createDirectoryAtPath:workDir
                              withIntermediateDirectories:YES
                                               attributes:nil error:nil];
    NSString *logPath = [workDir stringByAppendingPathComponent:@"terracotta.log"];

    BOOL ok = [TerracottaBridge startWithWorkingDirectory:workDir loggingPath:logPath];
    if (!ok) {
        NSLog(@"[TerracottaManager] terracotta_ios_start failed");
        self.lastError = @"Terracotta 初始化失败";
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
    self.stageDescription = @"正在创建房间…";
    self.lastError = nil;

    [[SilentAudioPlayer shared] startKeepingAlive];

    BOOL ok = [TerracottaBridge startHostWithRoom:inviteCode
                                              port:port
                                        playerName:playerName];
    if (!ok) {
        self.status = TerracottaStatusError;
        self.lastError = @"无法启动房主（请确认当前无活动会话）";
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
        self.lastError = @"邀请码格式不正确";
        return NO;
    }
    [self resetSessionState];
    self.role = TerracottaRoleClient;
    self.currentInviteCode = inviteCode;
    self.status = TerracottaStatusConnecting;
    self.stageDescription = @"正在加入房间…";
    self.lastError = nil;

    [[SilentAudioPlayer shared] startKeepingAlive];

    BOOL ok = [TerracottaBridge setGuestingWithRoom:inviteCode playerName:playerName];
    if (!ok) {
        self.status = TerracottaStatusError;
        self.lastError = @"无法加入（邀请码无效或当前已有会话）";
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
    /* lastError 不在此清除，让 UI 能在 stopSession 后仍看到上次错误（如果有） */
    _lastStateKind = -1;
    _lastStateIndex = -1;
}

#pragma mark - Polling

- (void)startPolling {
    [self stopPolling];
    /* dispatch_source_t 定时器，0.5s 间隔，QOS_CLASS_UTILITY 队列避免阻塞主线程 */
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

/// 把 Rust 侧 8 个底层状态映射到 4 个高层状态，更新所有 @property。
/// 状态去重：state.kind 和 state.index 都没变时跳过通知。
- (void)applyState:(TerracottaState *)state {
    if (state.kind == _lastStateKind && state.index == _lastStateIndex) {
        /* 状态没变，但玩家列表可能变化（新玩家加入），仍更新 */
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
            self.stageDescription = @"正在扫描 MC 局域网端口…";
            break;
        case TerracottaStateKindHostStarting:
            self.status = TerracottaStatusConnecting;
            self.stageDescription = @"正在启动 EasyTier 网络…";
            break;
        case TerracottaStateKindHostOk:
            self.status = TerracottaStatusConnected;
            self.stageDescription = @"房间已创建，等待玩家加入";
            break;
        case TerracottaStateKindGuestConnecting:
            self.status = TerracottaStatusConnecting;
            self.stageDescription = @"正在连接房主…";
            break;
        case TerracottaStateKindGuestStarting:
            self.status = TerracottaStatusConnecting;
            self.stageDescription = @"正在启动 EasyTier 网络…";
            break;
        case TerracottaStateKindGuestOk:
            self.status = TerracottaStatusConnected;
            self.stageDescription = @"已加入房间";
            break;
        case TerracottaStateKindException:
            self.status = TerracottaStatusError;
            self.lastError = [TerracottaBridge describeException:state.exceptionType];
            self.stageDescription = self.lastError;
            /* 异常时停止轮询和保活 */
            [self stopPolling];
            [[SilentAudioPlayer shared] stopKeepingAlive];
            break;
    }

    /* 更新邀请码和直连地址（仅 Rust 侧有值时覆盖） */
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
