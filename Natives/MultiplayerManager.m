//
//  MultiplayerManager.m
//  Amethyst
//
//  基于 ZeroTier Apple Framework 的 Minecraft 联机功能管理器实现
//
//  ============================================================================
//  设计理念与参照来源
//  ============================================================================
//
//  本文件参照了以下开源项目的联机管理器设计思路：
//
//  1. FCL (FoldCraftLauncher) - Android 平台的 MC 启动器
//     - 其 MultiplayerManager 通过 JNI 调用 libzt 直接在进程内建立 ZeroTier
//       虚拟网络，无需依赖外部 app。本实现采用相同的进程内运行思路。
//     - FCL 启动一个本地 SOCKS5 代理（基于 libzt socket），将 Minecraft 流量
//       转发到 ZeroTier 网络。本实现完全复刻此设计。
//
//  2. ZL2 (ZalithLauncher) - Android 平台的 MC 启动器（PojavLauncher 分支）
//     - 其 LanServerManager 同样基于 ZeroTier，提供了房间卡片 UI、
//       分享码导入、以及与 MC 内置"添加服务器"功能的联动。
//
//  3. ShardLauncher-iOS - iOS 平台的 MC 启动器
//     - 通过 git submodule 引入 zerotier-sockets-apple-framework (zt.framework)
//     - 使用 ZeroTierBridge 单例封装 libzt C API
//     - 缺陷：创建房间时跳转到 my.zerotier.com 官网，本实现修复此问题，
//       在 App 内完成全流程（输入 Network ID 即可加入，无需跳转）。
//
//  iOS 实现策略：
//    1. 直接链接 zt.framework（zerotier-sockets-apple-framework），在进程内运行
//       ZeroTier 节点。无需 NetworkExtension 权限，纯用户态运行。
//    2. 启动本地 SOCKS5 代理（127.0.0.1:1080），通过 libzt 的 BSD socket API
//       将流量转发到 ZeroTier 虚拟网络。
//    3. Minecraft 通过 JVM 参数 -DsocksProxyHost=127.0.0.1 -DsocksProxyPort=1080
//       走 SOCKS5 代理，所有 Minecraft 流量经 ZeroTier 网络到达房主服务器。
//    4. 启动器本地维护"联机房间"列表（房间名 + Network ID + 房主 IP + 端口），
//       使用 NSUserDefaults + NSKeyedArchiver（NSSecureCoding）持久化。
//    5. 启动器提供"分享文本"功能，将房间信息打包成一段带格式的文本，
//       方便通过微信/QQ/iMessage 等社交渠道发送给好友。
//
//  ZeroTier 网络 ID 说明：
//    - 16 位十六进制字符串（64 位无符号整数）
//    - 由用户在 https://my.zerotier.com 后台创建网络后获得
//    - 房主需在后台将网络设为"Private"并授权成员，或设为"Public"让任何人可加入
//    - 加入网络后，ZeroTier 会为每个节点分配一个虚拟 IP（如 10.147.17.x）
//
//  stub 模式：
//    如果 zt.framework 不可用（如 CI 构建环境链接了 zt_stub.c），所有 ZeroTier
//    API 返回 ZTS_ERR_SERVICE (-2)，isFrameworkAvailable 返回 NO，联机功能不可用。
//    UI 层应检测此情况并提示用户。
//
//  ============================================================================

#import "MultiplayerManager.h"
#import "ZeroTierBridge.h"
#import "SOCKS5Proxy.h"
#import "LauncherPreferences.h"

#pragma mark - 常量定义

/// NSUserDefaults 中存储房间列表的 key
static NSString * const kMultiplayerSavedRoomsKey = @"multiplayer_saved_rooms";

/// MC 默认服务器端口
static NSString * const kDefaultMCPort = @"25565";

/// 分享文本中的各种前缀标记（用于生成和解析）
static NSString * const kShareHeaderLine = @"🎮 来联机吧！";
static NSString * const kShareRoomNamePrefix = @"房间名称：";
static NSString * const kShareNetworkIdPrefix = @"ZeroTier网络ID：";
static NSString * const kShareServerAddressPrefix = @"服务器地址：";

/// SOCKS5 代理默认端口（与 SOCKS5Proxy.h 中的 SOCKS5ProxyDefaultPort 一致）
static uint16_t const kMultiplayerDefaultSOCKS5Port = 1080;

/// 传递给 JavaLauncher 的环境变量名，值为 "127.0.0.1:port"
/// JavaLauncher 检测到此环境变量后会注入 -DsocksProxyHost/-DsocksProxyPort 参数
static NSString * const kAMETHYSTSOCKS5ProxyEnvVar = @"AMETHYST_SOCKS5_PROXY";

/// 等待 ZeroTier 节点上线的超时时间（秒）
static NSTimeInterval const kNodeOnlineTimeout = 30.0;

/// 等待 ZeroTier 网络就绪的超时时间（秒）
static NSTimeInterval const kNetworkReadyTimeout = 30.0;

/// ZeroTier 节点身份文件存储目录名（位于 app Documents 目录下）
static NSString * const kZeroTierHomeDirName = @"zerotier_home";

/// 错误域名
static NSString * const kMultiplayerErrorDomain = @"MultiplayerManagerErrorDomain";

/// 错误码
typedef NS_ENUM(NSInteger, MultiplayerErrorCode) {
    MultiplayerErrorCodeRoomNotFound         = 1001, // 房间未找到
    MultiplayerErrorCodeRoomAlreadyExist     = 1002, // 房间已存在（roomId 重复）
    MultiplayerErrorCodeInvalidNetworkId     = 1003, // Network ID 格式无效
    MultiplayerErrorCodeInvalidRoom          = 1004, // 房间对象无效
    MultiplayerErrorCodeParseShareTextFailed = 1005, // 解析分享文本失败
    MultiplayerErrorCodeFrameworkUnavailable = 1006, // zt.framework 不可用（stub 模式）
    MultiplayerErrorCodeNodeStartFailed      = 1007, // ZeroTier 节点启动失败
    MultiplayerErrorCodeNodeOnlineTimeout    = 1008, // 等待节点上线超时
    MultiplayerErrorCodeJoinNetworkFailed    = 1009, // 加入网络失败
    MultiplayerErrorCodeNetworkReadyTimeout  = 1010, // 等待网络就绪超时
    MultiplayerErrorCodeSOCKS5ProxyStartFailed = 1011, // SOCKS5 代理启动失败
};

#pragma mark - MultiplayerRoom 实现

@implementation MultiplayerRoom

/// NSSecureCoding 要求：声明该类支持安全编码
+ (BOOL)supportsSecureCoding {
    return YES;
}

/// 便捷初始化方法
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
}

#pragma mark - 描述方法（便于调试）

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

#pragma mark - 复制与相等性（便于去重和比较）

- (id)copyWithZone:(NSZone *)zone {
    MultiplayerRoom *copy = [[MultiplayerRoom alloc] init];
    copy.roomId = [self.roomId copy];
    copy.name = [self.name copy];
    copy.networkId = [self.networkId copy];
    copy.hostIP = [self.hostIP copy];
    copy.hostPort = [self.hostPort copy];
    copy.roomDescription = [self.roomDescription copy];
    copy.status = self.status;
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

#pragma mark - MultiplayerManager 实现

@interface MultiplayerManager () <ZeroTierBridgeDelegate>
{
    /// 用于保护房间列表读写操作的锁
    dispatch_queue_t _serializationQueue;

    /// 保护 _currentRoom / _currentLocalIP / _nodeStarted 等连接状态的锁
    NSLock *_stateLock;
}

/// 可读写的房间列表（头文件中声明为 readonly）
@property (nonatomic, strong, readwrite) NSMutableArray<MultiplayerRoom *> *internalRooms;

/// 可读写的当前房间（头文件中声明为 readonly）
@property (nonatomic, strong, readwrite, nullable) MultiplayerRoom *currentRoom;

/// 可读写的 SOCKS5 端口
@property (nonatomic, assign, readwrite) uint16_t currentSOCKS5Port;

/// 可读写的本地 IP
@property (nonatomic, copy, readwrite, nullable) NSString *currentLocalIP;

/// ZeroTier 节点是否已启动（不代表已上线）
@property (nonatomic, assign, readwrite) BOOL nodeStarted;

/// 当前正在连接的 Network ID（uint64_t 形式，用于 ZeroTierBridge 查询状态）
/// 0 表示当前没有正在连接的网络
@property (nonatomic, assign) uint64_t currentNetworkID;
@end

@implementation MultiplayerManager

#pragma mark - 单例模式

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

        [self loadRooms];

        // 设置 ZeroTierBridge 代理，接收节点/网络状态回调
        [[ZeroTierBridge sharedInstance] setDelegate:self];

        NSLog(@"[MultiplayerManager] 初始化完成，已加载 %lu 个房间", (unsigned long)_internalRooms.count);
    }
    return self;
}

#pragma mark - 对外暴露的只读属性

- (NSArray<MultiplayerRoom *> *)savedRooms {
    if ([NSThread isMainThread]) {
        return [_internalRooms copy];
    } else {
        __block NSArray *result = nil;
        dispatch_sync(dispatch_get_main_queue(), ^{
            result = [self.internalRooms copy];
        });
        return result;
    }
}

- (BOOL)isSOCKS5ProxyRunning {
    return [[SOCKS5Proxy sharedProxy] isRunning];
}

- (BOOL)isNodeOnline {
    return [[ZeroTierBridge sharedInstance] isNodeOnline];
}

#pragma mark - 数据持久化

- (void)loadRooms {
    @synchronized(self) {
        NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
        NSData *data = [defaults dataForKey:kMultiplayerSavedRoomsKey];

        if (!data || data.length == 0) {
            self.internalRooms = [[NSMutableArray alloc] init];
            return;
        }

        NSError *error = nil;
        NSSet *allowedClasses = [NSSet setWithObjects:[NSArray class], [MultiplayerRoom class], nil];
        NSArray *rooms = [NSKeyedUnarchiver unarchivedObjectOfClasses:allowedClasses
                                                           fromData:data
                                                              error:&error];
        if (error || !rooms) {
            NSLog(@"[MultiplayerManager] 加载房间列表失败：%@", error.localizedDescription);
            NSKeyedUnarchiver *unarchiver = [[NSKeyedUnarchiver alloc] initForReadingFromData:data error:&error];
            unarchiver.requiresSecureCoding = NO;
            @try {
                NSArray *legacyRooms = [unarchiver decodeObjectForKey:NSKeyedArchiveRootObjectKey];
                if ([legacyRooms isKindOfClass:[NSArray class]]) {
                    self.internalRooms = [NSMutableArray arrayWithArray:legacyRooms];
                    NSLog(@"[MultiplayerManager] 使用兼容模式加载了 %lu 个房间", (unsigned long)self.internalRooms.count);
                    [unarchiver finishDecoding];
                    return;
                }
            } @catch (NSException *exception) {
                NSLog(@"[MultiplayerManager] 兼容模式解档异常：%@", exception);
            }
            [unarchiver finishDecoding];
            self.internalRooms = [[NSMutableArray alloc] init];
            return;
        }

        NSMutableArray *validRooms = [[NSMutableArray alloc] init];
        for (id obj in rooms) {
            if ([obj isKindOfClass:[MultiplayerRoom class]]) {
                [validRooms addObject:obj];
            }
        }

        self.internalRooms = validRooms;
        NSLog(@"[MultiplayerManager] 成功加载 %lu 个房间", (unsigned long)self.internalRooms.count);
    }
}

- (void)saveRooms {
    NSArray *roomsToSave = [self.internalRooms copy];

    dispatch_async(_serializationQueue, ^{
        NSError *error = nil;
        NSData *data = [NSKeyedArchiver archivedDataWithRootObject:roomsToSave
                                             requiringSecureCoding:YES
                                                             error:&error];
        if (error || !data) {
            NSLog(@"[MultiplayerManager] 序列化房间列表失败：%@", error.localizedDescription);
            return;
        }

        NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
        [defaults setObject:data forKey:kMultiplayerSavedRoomsKey];
        BOOL synced = [defaults synchronize];
        NSLog(@"[MultiplayerManager] 房间列表已保存（%lu 个，synchronize=%d）",
              (unsigned long)roomsToSave.count, synced);
    });
}

#pragma mark - 框架检测与节点管理

- (BOOL)isFrameworkAvailable {
    return [[ZeroTierBridge sharedInstance] isFrameworkAvailable];
}

- (BOOL)isNodeStarted {
    [_stateLock lock];
    BOOL started = _nodeStarted;
    [_stateLock unlock];
    return started;
}

/// 获取 ZeroTier 节点身份文件存储目录
/// 位于 app Documents 目录下的 zerotier_home 子目录
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
    // 如果节点已启动，直接回调成功
    if ([self isNodeStarted]) {
        NSLog(@"[MultiplayerManager] ZeroTier 节点已启动，跳过重复启动");
        if (completion) {
            dispatch_async(dispatch_get_main_queue(), ^{
                completion(YES, nil);
            });
        }
        return;
    }

    // 检测 framework 是否可用
    if (![[ZeroTierBridge sharedInstance] isFrameworkAvailable]) {
        NSLog(@"[MultiplayerManager] zt.framework 不可用，无法启动 ZeroTier 节点");
        if (completion) {
            NSError *error = [NSError errorWithDomain:kMultiplayerErrorDomain
                                                  code:MultiplayerErrorCodeFrameworkUnavailable
                                              userInfo:@{NSLocalizedDescriptionKey: @"ZeroTier 框架不可用，无法启动联机功能"}];
            dispatch_async(dispatch_get_main_queue(), ^{
                completion(NO, error);
            });
        }
        return;
    }

    NSLog(@"[MultiplayerManager] 启动 ZeroTier 节点...");

    // 在后台线程启动节点，避免阻塞主线程
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        NSString *homeDir = [self zeroTierHomeDirectory];
        NSError *startError = nil;
        BOOL success = [[ZeroTierBridge sharedInstance] startNodeWithHomeDirectory:homeDir
                                                                            error:&startError];
        if (success) {
            [self->_stateLock lock];
            self->_nodeStarted = YES;
            [self->_stateLock unlock];
            NSLog(@"[MultiplayerManager] ZeroTier 节点启动请求已提交，等待上线...");
        } else {
            NSLog(@"[MultiplayerManager] ZeroTier 节点启动失败：%@", startError.localizedDescription);
        }

        if (completion) {
            NSError *cbError = success ? nil : [NSError errorWithDomain:kMultiplayerErrorDomain
                                                                     code:MultiplayerErrorCodeNodeStartFailed
                                                                 userInfo:@{NSLocalizedDescriptionKey: startError.localizedDescription ?: @"节点启动失败"}];
            dispatch_async(dispatch_get_main_queue(), ^{
                completion(success, cbError);
            });
        }
    });
}

#pragma mark - 兼容旧 API（已废弃）

- (BOOL)isZeroTierAppInstalled {
    // 旧 API：检测外部 ZeroTier One app 是否安装
    // 新版本：检测 zt.framework 是否可用
    return [self isFrameworkAvailable];
}

- (void)setZeroTierInstalledOverride:(BOOL)installed {
    // 旧 API：用户手动覆盖 ZeroTier 安装状态
    // 新版本：进程内框架无需此机制，空操作
    NSLog(@"[MultiplayerManager] setZeroTierInstalledOverride:%d 已废弃，新版本无需此操作", installed);
}

- (BOOL)isZeroTierInstallOverridden {
    // 旧 API：用户是否已手动覆盖
    // 新版本：始终返回 NO
    return NO;
}

- (void)openZeroTierApp {
    // 旧 API：打开外部 ZeroTier One app
    // 新版本：进程内框架，无需打开外部 app，空操作
    NSLog(@"[MultiplayerManager] openZeroTierApp 已废弃，新版本使用进程内框架");
}

#pragma mark - 网络加入与离开

- (void)joinNetwork:(NSString *)networkId
         completion:(void (^)(BOOL, NSError * _Nullable))completion {
    if (!networkId || networkId.length == 0) {
        if (completion) {
            NSError *error = [NSError errorWithDomain:kMultiplayerErrorDomain
                                                  code:MultiplayerErrorCodeInvalidNetworkId
                                              userInfo:@{NSLocalizedDescriptionKey: @"Network ID 为空"}];
            dispatch_async(dispatch_get_main_queue(), ^{
                completion(NO, error);
            });
        }
        return;
    }

    NSString *trimmedNetworkId = [networkId stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];

    if (![self isValidNetworkId:trimmedNetworkId]) {
        NSLog(@"[MultiplayerManager] joinNetwork: Network ID 格式无效：%@", trimmedNetworkId);
        if (completion) {
            NSError *error = [NSError errorWithDomain:kMultiplayerErrorDomain
                                                  code:MultiplayerErrorCodeInvalidNetworkId
                                              userInfo:@{NSLocalizedDescriptionKey: [NSString stringWithFormat:@"Network ID 格式无效：%@", trimmedNetworkId]}];
            dispatch_async(dispatch_get_main_queue(), ^{
                completion(NO, error);
            });
        }
        return;
    }

    // 确保节点已启动后再加入网络
    [self ensureNodeStartedWithCompletion:^(BOOL nodeStarted, NSError * _Nullable nodeError) {
        if (!nodeStarted) {
            if (completion) {
                dispatch_async(dispatch_get_main_queue(), ^{
                    completion(NO, nodeError);
                });
            }
            return;
        }

        // 在后台线程执行 joinNetwork（ZeroTierBridge 是同步调用，但内部只是提交请求）
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
            uint64_t netID = [ZeroTierBridge parseNetworkIDFromString:trimmedNetworkId];
            if (netID == 0) {
                if (completion) {
                    NSError *error = [NSError errorWithDomain:kMultiplayerErrorDomain
                                                          code:MultiplayerErrorCodeInvalidNetworkId
                                                      userInfo:@{NSLocalizedDescriptionKey: @"Network ID 解析失败"}];
                    dispatch_async(dispatch_get_main_queue(), ^{
                        completion(NO, error);
                    });
                }
                return;
            }

            NSError *joinError = nil;
            BOOL success = [[ZeroTierBridge sharedInstance] joinNetwork:netID error:&joinError];
            if (success) {
                NSLog(@"[MultiplayerManager] 已加入 ZeroTier 网络 %@，等待网络就绪...", trimmedNetworkId);
            } else {
                NSLog(@"[MultiplayerManager] 加入 ZeroTier 网络失败：%@", joinError.localizedDescription);
            }

            if (completion) {
                NSError *cbError = success ? nil : [NSError errorWithDomain:kMultiplayerErrorDomain
                                                                          code:MultiplayerErrorCodeJoinNetworkFailed
                                                                      userInfo:@{NSLocalizedDescriptionKey: joinError.localizedDescription ?: @"加入网络失败"}];
                dispatch_async(dispatch_get_main_queue(), ^{
                    completion(success, cbError);
                });
            }
        });
    }];
}

- (void)leaveNetwork:(NSString *)networkId {
    if (!networkId || networkId.length == 0) {
        NSLog(@"[MultiplayerManager] leaveNetwork: networkId 为空");
        return;
    }

    NSString *trimmedNetworkId = [networkId stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    uint64_t netID = [ZeroTierBridge parseNetworkIDFromString:trimmedNetworkId];
    if (netID == 0) {
        NSLog(@"[MultiplayerManager] leaveNetwork: Network ID 解析失败：%@", trimmedNetworkId);
        return;
    }

    BOOL success = [[ZeroTierBridge sharedInstance] leaveNetwork:netID];
    if (success) {
        NSLog(@"[MultiplayerManager] 已离开 ZeroTier 网络 %@", trimmedNetworkId);
    } else {
        NSLog(@"[MultiplayerManager] 离开 ZeroTier 网络失败：%@", trimmedNetworkId);
    }

    // 清理当前网络 ID 跟踪
    [_stateLock lock];
    if (_currentNetworkID == netID) {
        _currentNetworkID = 0;
    }
    [_stateLock unlock];
}

#pragma mark - 房间管理（增删改查）

- (void)addRoom:(MultiplayerRoom *)room {
    if (!room) {
        NSLog(@"[MultiplayerManager] addRoom: room 为空");
        return;
    }

    if (!room.roomId || room.roomId.length == 0) {
        NSLog(@"[MultiplayerManager] addRoom: roomId 为空，自动生成");
        room.roomId = [[NSUUID UUID] UUIDString];
    }

    if (!room.name || room.name.length == 0) {
        room.name = @"未命名房间";
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
                NSLog(@"[MultiplayerManager] addRoom: roomId 已存在：%@", room.roomId);
                return;
            }
        }

        [self.internalRooms addObject:room];
        [self sortRoomsByCreatedAt];
    }

    NSLog(@"[MultiplayerManager] 已添加房间：%@（%@）", room.name, room.roomId);
    [self saveRooms];
}

- (void)removeRoom:(NSString *)roomId {
    if (!roomId || roomId.length == 0) {
        NSLog(@"[MultiplayerManager] removeRoom: roomId 为空");
        return;
    }

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
            NSLog(@"[MultiplayerManager] removeRoom: 未找到 roomId：%@", roomId);
            return;
        }

        self.internalRooms = roomsToKeep;

        // 如果要删除的房间是当前连接的房间，先断开
        if (self.currentRoom && [self.currentRoom.roomId isEqualToString:roomId]) {
            NSLog(@"[MultiplayerManager] 删除的房间是当前连接的房间，先断开连接");
            // 这里调用 disconnectCurrentRoom 会修改 self.currentRoom，需要先保存引用
            MultiplayerRoom *roomToDisconnect = self.currentRoom;
            [self disconnectCurrentRoom];
            roomToDisconnect.status = MultiplayerRoomStatusDisconnected;
            self.currentRoom = nil;
        }
    }

    NSLog(@"[MultiplayerManager] 已删除房间：%@", roomId);
    [self saveRooms];
}

- (void)updateRoom:(MultiplayerRoom *)room {
    if (!room || !room.roomId || room.roomId.length == 0) {
        NSLog(@"[MultiplayerManager] updateRoom: room 或 roomId 为空");
        return;
    }

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
            NSLog(@"[MultiplayerManager] updateRoom: 未找到 roomId：%@", room.roomId);
            return;
        }

        self.internalRooms = updatedRooms;
        [self sortRoomsByCreatedAt];

        // 如果更新的是当前连接的房间，同步更新 currentRoom 引用
        if (self.currentRoom && [self.currentRoom.roomId isEqualToString:room.roomId]) {
            self.currentRoom = room;
        }
    }

    NSLog(@"[MultiplayerManager] 已更新房间：%@（%@）", room.name, room.roomId);
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

#pragma mark - 连接管理

- (void)connectToRoom:(MultiplayerRoom *)room
           completion:(void (^)(BOOL success, NSError * _Nullable error))completion {
    if (!room) {
        if (completion) {
            NSError *error = [NSError errorWithDomain:kMultiplayerErrorDomain
                                                  code:MultiplayerErrorCodeInvalidRoom
                                              userInfo:@{NSLocalizedDescriptionKey: @"房间对象为空"}];
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
                                              userInfo:@{NSLocalizedDescriptionKey: @"房间的 Network ID 为空"}];
            dispatch_async(dispatch_get_main_queue(), ^{
                completion(NO, error);
            });
        }
        return;
    }

    // 检测 framework 可用性
    if (![[ZeroTierBridge sharedInstance] isFrameworkAvailable]) {
        NSLog(@"[MultiplayerManager] zt.framework 不可用，无法连接房间");
        room.status = MultiplayerRoomStatusError;
        [self updateRoom:room];
        if (completion) {
            NSError *error = [NSError errorWithDomain:kMultiplayerErrorDomain
                                                  code:MultiplayerErrorCodeFrameworkUnavailable
                                              userInfo:@{NSLocalizedDescriptionKey: @"ZeroTier 框架不可用，请确保 zt.framework 已正确集成"}];
            dispatch_async(dispatch_get_main_queue(), ^{
                completion(NO, error);
            });
        }
        return;
    }

    NSLog(@"[MultiplayerManager] 开始连接房间：%@（Network ID: %@）", room.name, room.networkId);

    // 1. 设置当前房间并更新状态为连接中
    [_stateLock lock];
    self.currentRoom = room;
    self.currentNetworkID = [ZeroTierBridge parseNetworkIDFromString:room.networkId];
    [_stateLock unlock];

    room.status = MultiplayerRoomStatusConnecting;
    room.lastConnectedAt = [NSDate date];

    // 关键修复：如果房间不在列表中，先添加到列表，否则后续 updateRoom 都会因找不到 roomId 而失败
    if (![self roomWithId:room.roomId]) {
        NSLog(@"[MultiplayerManager] 房间不在列表中，先添加：%@", room.roomId);
        [self addRoom:room];
    }
    [self updateRoom:room];

    // 2. 完整连接流程（在后台线程执行，避免阻塞主线程）
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        [self connectToRoomFlow:room completion:^(BOOL success, NSError * _Nullable error) {
            if (success) {
                NSLog(@"[MultiplayerManager] 房间连接成功：%@", room.name);
                room.status = MultiplayerRoomStatusConnected;
            } else {
                NSLog(@"[MultiplayerManager] 房间连接失败：%@ - %@", room.name, error.localizedDescription);
                room.status = MultiplayerRoomStatusError;
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

/// 房间连接的完整流程（在后台线程执行）
///
/// 步骤：
///   1. 启动 ZeroTier 节点（如果尚未启动）
///   2. 等待节点上线
///   3. 加入 ZeroTier 网络
///   4. 等待网络就绪（IPv4 地址已分配）
///   5. 启动本地 SOCKS5 代理
///   6. 设置 AMETHYST_SOCKS5_PROXY 环境变量
- (void)connectToRoomFlow:(MultiplayerRoom *)room
               completion:(void (^)(BOOL success, NSError * _Nullable error))completion {
    // 步骤 1：启动节点
    if (![self isNodeStarted]) {
        NSLog(@"[MultiplayerManager] [连接流程] 步骤 1：启动 ZeroTier 节点");
        __block BOOL nodeStartSuccess = NO;
        __block NSError *nodeStartError = nil;
        // 使用 dispatch_sync_wait 模式同步等待节点启动完成
        dispatch_semaphore_t sem = dispatch_semaphore_create(0);
        [self ensureNodeStartedWithCompletion:^(BOOL success, NSError * _Nullable error) {
            nodeStartSuccess = success;
            nodeStartError = error;
            dispatch_semaphore_signal(sem);
        }];
        dispatch_semaphore_wait(sem, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(kNodeOnlineTimeout * NSEC_PER_SEC)));

        if (!nodeStartSuccess) {
            if (completion) {
                completion(NO, nodeStartError ?: [NSError errorWithDomain:kMultiplayerErrorDomain
                                                                       code:MultiplayerErrorCodeNodeStartFailed
                                                                   userInfo:@{NSLocalizedDescriptionKey: @"节点启动失败"}]);
            }
            return;
        }
    } else {
        NSLog(@"[MultiplayerManager] [连接流程] 步骤 1：节点已启动，跳过");
    }

    // 步骤 2：等待节点上线
    NSLog(@"[MultiplayerManager] [连接流程] 步骤 2：等待节点上线（超时 %.0fs）", kNodeOnlineTimeout);
    if (![[ZeroTierBridge sharedInstance] isNodeOnline]) {
        BOOL online = [[ZeroTierBridge sharedInstance] waitForNodeOnlineWithTimeout:kNodeOnlineTimeout];
        if (!online) {
            if (completion) {
                completion(NO, [NSError errorWithDomain:kMultiplayerErrorDomain
                                                    code:MultiplayerErrorCodeNodeOnlineTimeout
                                                userInfo:@{NSLocalizedDescriptionKey: [NSString stringWithFormat:@"等待 ZeroTier 节点上线超时（%.0fs）", kNodeOnlineTimeout]}]);
            }
            return;
        }
    }
    NSLog(@"[MultiplayerManager] [连接流程] 节点已上线");

    // 步骤 3：加入网络
    NSLog(@"[MultiplayerManager] [连接流程] 步骤 3：加入 ZeroTier 网络 %@", room.networkId);
    uint64_t netID = [ZeroTierBridge parseNetworkIDFromString:room.networkId];
    if (netID == 0) {
        if (completion) {
            completion(NO, [NSError errorWithDomain:kMultiplayerErrorDomain
                                                code:MultiplayerErrorCodeInvalidNetworkId
                                            userInfo:@{NSLocalizedDescriptionKey: @"Network ID 解析失败"}]);
        }
        return;
    }

    NSError *joinError = nil;
    if (![[ZeroTierBridge sharedInstance] joinNetwork:netID error:&joinError]) {
        if (completion) {
            completion(NO, [NSError errorWithDomain:kMultiplayerErrorDomain
                                                code:MultiplayerErrorCodeJoinNetworkFailed
                                            userInfo:@{NSLocalizedDescriptionKey: joinError.localizedDescription ?: @"加入网络失败"}]);
        }
        return;
    }

    // 步骤 4：等待网络就绪
    NSLog(@"[MultiplayerManager] [连接流程] 步骤 4：等待网络就绪（超时 %.0fs）", kNetworkReadyTimeout);
    BOOL ready = [[ZeroTierBridge sharedInstance] waitForNetworkReady:netID
                                                              timeout:kNetworkReadyTimeout];
    if (!ready) {
        if (completion) {
            completion(NO, [NSError errorWithDomain:kMultiplayerErrorDomain
                                                code:MultiplayerErrorCodeNetworkReadyTimeout
                                            userInfo:@{NSLocalizedDescriptionKey: [NSString stringWithFormat:@"等待 ZeroTier 网络就绪超时（%.0fs）。请确认网络 ID 正确且节点已在 my.zerotier.com 后台授权。", kNetworkReadyTimeout]}]);
        }
        return;
    }

    // 获取分配的 IP 地址
    // 标准模式：获取 IPv4 地址
    // Ad-hoc 模式（快速模式）：只有 IPv6 地址，需要特殊处理
    NSString *localIP = nil;
    BOOL isAdhoc = [self isAdhocNetworkId:room.networkId];
    if (isAdhoc) {
        // Ad-hoc 网络只有 IPv6 地址
        localIP = [[ZeroTierBridge sharedInstance] ipv6AddressForNetwork:netID];
        NSLog(@"[MultiplayerManager] [连接流程] Ad-hoc 模式，本机 ZeroTier IPv6：%@", localIP ?: @"（未分配）");
    } else {
        // 标准模式：获取 IPv4 地址
        localIP = [[ZeroTierBridge sharedInstance] ipv4AddressForNetwork:netID];
        NSLog(@"[MultiplayerManager] [连接流程] 标准模式，本机 ZeroTier IPv4：%@", localIP ?: @"（未分配）");
    }

    [_stateLock lock];
    self.currentLocalIP = localIP;
    // 关键修复（对标 FCL/HMCL）：将本机 ZeroTier IP 同步到 room.hostIP，
    // 使 shareTextForRoom: 能正确输出房主的服务器地址，而不显示「未知」。
    // 之前缺失此同步导致分享文本中服务器地址为空，加入者无法直接获取连接地址。
    if (localIP && localIP.length > 0 && self.currentRoom) {
        self.currentRoom.hostIP = localIP;
        NSLog(@"[MultiplayerManager] [连接流程] 已同步房主 ZeroTier IP 到房间 %@：%@", self.currentRoom.name, localIP);
    }
    MultiplayerRoom *roomForIPUpdate = self.currentRoom;
    [_stateLock unlock];

    // 持久化房主 IP 到房间列表（后台异步写入，避免阻塞连接流程）
    if (roomForIPUpdate && localIP && localIP.length > 0) {
        [self updateRoom:roomForIPUpdate];
    }

    // 步骤 5：启动 SOCKS5 代理
    NSLog(@"[MultiplayerManager] [连接流程] 步骤 5：启动 SOCKS5 代理");
    NSError *proxyError = nil;
    BOOL proxyStarted = [[SOCKS5Proxy sharedProxy] startWithPort:kMultiplayerDefaultSOCKS5Port
                                                            error:&proxyError];
    if (!proxyStarted) {
        NSLog(@"[MultiplayerManager] [连接流程] SOCKS5 代理启动失败：%@", proxyError.localizedDescription);
        if (completion) {
            completion(NO, [NSError errorWithDomain:kMultiplayerErrorDomain
                                                code:MultiplayerErrorCodeSOCKS5ProxyStartFailed
                                            userInfo:@{NSLocalizedDescriptionKey: proxyError.localizedDescription ?: @"SOCKS5 代理启动失败"}]);
        }
        return;
    }

    uint16_t actualPort = [[SOCKS5Proxy sharedProxy] listeningPort];
    [_stateLock lock];
    self.currentSOCKS5Port = actualPort;
    [_stateLock unlock];

    NSLog(@"[MultiplayerManager] [连接流程] SOCKS5 代理已启动，监听 127.0.0.1:%u", actualPort);

    // 步骤 6：设置环境变量，供 JavaLauncher 读取
    NSString *proxyValue = [NSString stringWithFormat:@"127.0.0.1:%u", actualPort];
    setenv([kAMETHYSTSOCKS5ProxyEnvVar UTF8String], [proxyValue UTF8String], 1);
    NSLog(@"[MultiplayerManager] [连接流程] 已设置环境变量 %@=%@", kAMETHYSTSOCKS5ProxyEnvVar, proxyValue);

    if (completion) {
        completion(YES, nil);
    }
}

- (void)disconnectCurrentRoom {
    [_stateLock lock];
    MultiplayerRoom *room = self.currentRoom;
    NSString *networkId = room.networkId;
    [_stateLock unlock];

    if (!room) {
        NSLog(@"[MultiplayerManager] disconnectCurrentRoom: 当前没有连接的房间");
        return;
    }

    NSLog(@"[MultiplayerManager] 断开房间连接：%@（Network ID: %@）", room.name, networkId);

    // 1. 停止 SOCKS5 代理
    if ([[SOCKS5Proxy sharedProxy] isRunning]) {
        NSLog(@"[MultiplayerManager] 停止 SOCKS5 代理");
        [[SOCKS5Proxy sharedProxy] stop];
    }

    [_stateLock lock];
    self.currentSOCKS5Port = 0;
    self.currentLocalIP = nil;
    [_stateLock unlock];

    // 2. 清除环境变量
    unsetenv([kAMETHYSTSOCKS5ProxyEnvVar UTF8String]);
    NSLog(@"[MultiplayerManager] 已清除环境变量 %@", kAMETHYSTSOCKS5ProxyEnvVar);

    // 3. 离开 ZeroTier 网络
    if (networkId && networkId.length > 0) {
        [self leaveNetwork:networkId];
    }

    // 4. 更新房间状态为已断开
    room.status = MultiplayerRoomStatusDisconnected;

    @synchronized(self) {
        for (MultiplayerRoom *existing in self.internalRooms) {
            if ([existing.roomId isEqualToString:room.roomId]) {
                existing.status = MultiplayerRoomStatusDisconnected;
                break;
            }
        }
    }

    // 5. 清空当前房间引用
    [_stateLock lock];
    self.currentRoom = nil;
    self.currentNetworkID = 0;
    [_stateLock unlock];

    // 6. 持久化
    [self saveRooms];

    NSLog(@"[MultiplayerManager] 已断开房间连接");
}

#pragma mark - ZeroTierBridgeDelegate

- (void)zeroTierNodeOnlineWithID:(uint64_t)nodeID {
    NSLog(@"[MultiplayerManager] ZeroTier 节点已上线，nodeID = %llu", nodeID);
    if ([self.delegate respondsToSelector:@selector(multiplayerNodeOnline)]) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [self.delegate multiplayerNodeOnline];
        });
    }
}

- (void)zeroTierNodeOffline {
    NSLog(@"[MultiplayerManager] ZeroTier 节点已离线");
    if ([self.delegate respondsToSelector:@selector(multiplayerNodeOffline)]) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [self.delegate multiplayerNodeOffline];
        });
    }
}

- (void)zeroTierNetworkReady:(uint64_t)networkID
                        ipv4:(NSString *)ipv4
                        ipv6:(NSString *)ipv6 {
    NSLog(@"[MultiplayerManager] ZeroTier 网络就绪：networkID=%llu ipv4=%@ ipv6=%@",
          networkID, ipv4 ?: @"(nil)", ipv6 ?: @"(nil)");

    // 判断当前网络是否为 Ad-hoc 网络
    // Ad-hoc 网络只有 IPv6 地址，需要使用 ipv6 而非 ipv4
    MultiplayerRoom *currentRoom = self.currentRoom;
    BOOL isAdhoc = currentRoom && [self isAdhocNetworkId:currentRoom.networkId];
    NSString *effectiveIP = isAdhoc ? ipv6 : ipv4;

    // 更新当前房间的本地 IP
    [_stateLock lock];
    if (_currentNetworkID == networkID) {
        self.currentLocalIP = effectiveIP;
        // 关键修复（对标 FCL/HMCL）：ZeroTier 网络就绪回调可能晚于 connectToRoomFlow 完成，
        // 此处也需将 IP 同步到 room.hostIP，确保分享文本能输出正确的服务器地址。
        // Ad-hoc 模式下使用 IPv6，标准模式下使用 IPv4。
    }
    MultiplayerRoom *room = self.currentRoom;
    BOOL needsUpdate = NO;
    if (room && effectiveIP && effectiveIP.length > 0) {
        // 仅当 IP 变化时才更新，避免重复写入
        if (![room.hostIP isEqualToString:effectiveIP]) {
            room.hostIP = effectiveIP;
            needsUpdate = YES;
        }
        NSLog(@"[MultiplayerManager] 已更新房间 %@ 的本地 IP（%@）：%@",
              room.name, isAdhoc ? @"IPv6" : @"IPv4", effectiveIP);
    }
    [_stateLock unlock];

    // 持久化到房间列表（后台异步写入）
    if (needsUpdate && room) {
        [self updateRoom:room];
    }

    // 通知 delegate 刷新 UI（IP 显示可能需要更新）
    if (room && [self.delegate respondsToSelector:@selector(multiplayerRoomConnected:)]) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [self.delegate multiplayerRoomConnected:room];
        });
    }
}

- (void)zeroTierNetworkJoinFailed:(uint64_t)networkID
                            error:(NSString *)errorDescription {
    NSLog(@"[MultiplayerManager] ZeroTier 网络加入失败：networkID=%llu error=%@", networkID, errorDescription);

    [_stateLock lock];
    MultiplayerRoom *room = (_currentNetworkID == networkID) ? self.currentRoom : nil;
    [_stateLock unlock];

    if (room) {
        room.status = MultiplayerRoomStatusError;
        [self updateRoom:room];

        if ([self.delegate respondsToSelector:@selector(multiplayerRoom:didFailWithError:)]) {
            NSError *error = [NSError errorWithDomain:kMultiplayerErrorDomain
                                                  code:MultiplayerErrorCodeJoinNetworkFailed
                                              userInfo:@{NSLocalizedDescriptionKey: errorDescription}];
            dispatch_async(dispatch_get_main_queue(), ^{
                [self.delegate multiplayerRoom:room didFailWithError:error];
            });
        }
    }
}

- (void)zeroTierAddressAssigned:(uint64_t)networkID
                         family:(int)family
                        address:(NSString *)address {
    NSLog(@"[MultiplayerManager] ZeroTier 地址分配：networkID=%llu family=%d address=%@",
          networkID, family, address);

    // 仅 IPv4 地址更新到 currentLocalIP
    if (family == 2 /* AF_INET */) {
        [_stateLock lock];
        if (_currentNetworkID == networkID) {
            self.currentLocalIP = address;
        }
        [_stateLock unlock];
    }
}

#pragma mark - 分享功能

- (NSString *)shareTextForRoom:(MultiplayerRoom *)room {
    if (!room) {
        return @"";
    }

    NSString *name = room.name ?: @"未命名房间";
    NSString *networkId = room.networkId ?: @"";
    // hostIP 可能为空字符串（房主尚未连接房间时），此时显示提示
    NSString *hostIP = (room.hostIP && room.hostIP.length > 0) ? room.hostIP : @"（房主连接房间后自动显示）";
    NSString *hostPort = (room.hostPort && room.hostPort.length > 0) ? room.hostPort : kDefaultMCPort;

    NSString *serverAddress = [NSString stringWithFormat:@"%@:%@", hostIP, hostPort];

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
    [text appendString:@"加入步骤：\n"];
    [text appendString:@"1. 在启动器联机页面输入上方的 ZeroTier 网络 ID\n"];
    [text appendString:@"2. 点击「加入房间」，启动器会自动启动联机核心并连接\n"];
    [text appendFormat:@"3. 连接成功后启动游戏，在 MC 中添加服务器：%@", serverAddress];
    [text appendString:@"\n\n"];
    [text appendString:@"提示：房主需先在启动器内连接房间并启动游戏（或开放局域网），加入者才能连入。"];

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

    // ========== 1. 逐行匹配带前缀的字段 ==========

    NSRegularExpression *nameRegex = [NSRegularExpression
        regularExpressionWithPattern:@"房间名称[：:]?\\s*(.+)"
                             options:NSRegularExpressionCaseInsensitive
                               error:nil];

    NSRegularExpression *networkIdRegex = [NSRegularExpression
        regularExpressionWithPattern:@"(?:ZeroTier网络ID|网络ID|Network\\s*ID)[：:]?\\s*([0-9a-fA-F]{16})"
                             options:NSRegularExpressionCaseInsensitive
                               error:nil];

    NSRegularExpression *addressRegex = [NSRegularExpression
        regularExpressionWithPattern:@"服务器地址[：:]?\\s*([0-9]{1,3}\\.[0-9]{1,3}\\.[0-9]{1,3}\\.[0-9]{1,3})(?::([0-9]{1,5}))?"
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

    // ========== 2. 兜底：未匹配到 Network ID 时，在整个文本中搜索 ==========

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

    // ========== 3. 兜底：未匹配到服务器地址时，在整个文本中搜索 ==========

    if (!hostIP) {
        NSRegularExpression *rawAddressRegex = [NSRegularExpression
            regularExpressionWithPattern:@"([0-9]{1,3}\\.[0-9]{1,3}\\.[0-9]{1,3}\\.[0-9]{1,3})(?::([0-9]{1,5}))?"
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

    // ========== 4. 校验解析结果 ==========

    if (!networkId || networkId.length != 16) {
        NSLog(@"[MultiplayerManager] 解析分享文本失败：Network ID 无效或缺失");
        return nil;
    }

    if (![self isValidNetworkId:networkId]) {
        NSLog(@"[MultiplayerManager] 解析分享文本失败：Network ID 格式校验未通过：%@", networkId);
        return nil;
    }

    if (!roomName || roomName.length == 0) {
        roomName = @"导入的房间";
    }

    if (!hostPort || hostPort.length == 0) {
        hostPort = kDefaultMCPort;
    }

    if (!hostIP) {
        hostIP = @"";
        NSLog(@"[MultiplayerManager] 解析分享文本：未找到服务器 IP，用户需后续手动补充");
    }

    // ========== 5. 构造房间对象 ==========

    MultiplayerRoom *room = [[MultiplayerRoom alloc] initWithId:nil
                                                            name:roomName
                                                       networkId:networkId
                                                          hostIP:hostIP
                                                        hostPort:hostPort];
    room.roomDescription = @"从分享文本导入";
    room.status = MultiplayerRoomStatusDisconnected;

    NSLog(@"[MultiplayerManager] 成功解析分享文本：name=%@, networkId=%@, host=%@:%@",
          roomName, networkId, hostIP, hostPort);

    return room;
}

#pragma mark - 辅助方法

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

#pragma mark - 分享代码（FCL 风格 Base64 编码）

/// 分享代码的 JSON key 常量
static NSString * const kShareCodeKeyNetworkId = @"n";
static NSString * const kShareCodeKeyHostIP = @"h";
static NSString * const kShareCodeKeyHostPort = @"p";
static NSString * const kShareCodeKeyRoomName = @"r";

/// 预设 Network ID 的偏好键
static NSString * const kPresetNetworkIdPrefKey = @"multiplayer.preset_network_id";

- (NSString *)generateShareCodeForRoom:(MultiplayerRoom *)room {
    if (!room || !room.networkId) {
        return @"";
    }

    // 构建 JSON 字典
    NSMutableDictionary *jsonDict = [NSMutableDictionary dictionary];
    jsonDict[kShareCodeKeyNetworkId] = room.networkId;
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

    // 序列化为 JSON Data
    NSError *jsonError = nil;
    NSData *jsonData = [NSJSONSerialization dataWithJSONObject:jsonDict
                                                       options:NSJSONWritingSortedKeys
                                                         error:&jsonError];
    if (jsonError || !jsonData) {
        NSLog(@"[MultiplayerManager] 生成分享代码失败：JSON 序列化失败 - %@", jsonError);
        return @"";
    }

    // Base64 编码（URL 安全：去掉换行符）
    NSString *base64String = [jsonData base64EncodedStringWithOptions:0];
    // 去除可能的换行符和空格
    base64String = [base64String stringByReplacingOccurrencesOfString:@"\n" withString:@""];
    base64String = [base64String stringByReplacingOccurrencesOfString:@"\r" withString:@""];
    base64String = [base64String stringByReplacingOccurrencesOfString:@" " withString:@""];

    NSLog(@"[MultiplayerManager] 已生成分享代码（长度=%lu）：%@...",
          (unsigned long)base64String.length,
          base64String.length > 20 ? [base64String substringToIndex:20] : base64String);

    return base64String;
}

- (nullable MultiplayerRoom *)parseShareCode:(NSString *)code {
    if (!code || code.length == 0) {
        return nil;
    }

    // 清理输入：去除首尾空白和换行符
    NSString *cleanCode = [code stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (cleanCode.length == 0) {
        return nil;
    }

    // Base64 解码
    NSData *jsonData = [[NSData alloc] initWithBase64EncodedString:cleanCode
                                                            options:NSDataBase64DecodingIgnoreUnknownCharacters];
    if (!jsonData || jsonData.length == 0) {
        NSLog(@"[MultiplayerManager] 解析分享代码失败：Base64 解码失败");
        return nil;
    }

    // JSON 反序列化
    NSError *jsonError = nil;
    NSDictionary *jsonDict = [NSJSONSerialization JSONObjectWithData:jsonData
                                                            options:0
                                                              error:&jsonError];
    if (jsonError || !jsonDict || ![jsonDict isKindOfClass:[NSDictionary class]]) {
        NSLog(@"[MultiplayerManager] 解析分享代码失败：JSON 反序列化失败 - %@", jsonError);
        return nil;
    }

    // 提取字段
    NSString *networkId = jsonDict[kShareCodeKeyNetworkId];
    NSString *hostIP = jsonDict[kShareCodeKeyHostIP];
    NSString *hostPort = jsonDict[kShareCodeKeyHostPort];
    NSString *roomName = jsonDict[kShareCodeKeyRoomName];

    // 校验 Network ID
    if (!networkId || ![self isValidNetworkId:networkId]) {
        NSLog(@"[MultiplayerManager] 解析分享代码失败：Network ID 无效 - %@", networkId);
        return nil;
    }

    // 构建房间对象
    MultiplayerRoom *room = [[MultiplayerRoom alloc] init];
    room.roomId = [self generateRoomId];
    room.networkId = networkId;
    room.hostIP = hostIP ?: @"";
    room.hostPort = hostPort ?: kDefaultMCPort;
    room.name = roomName ?: [NSString stringWithFormat:@"%@...", [networkId substringToIndex:8]];
    room.roomDescription = @"";
    room.ownerName = @"";
    room.status = MultiplayerRoomStatusDisconnected;
    room.createdAt = [NSDate date];

    NSLog(@"[MultiplayerManager] 已解析分享代码：roomName=%@ networkId=%@ hostIP=%@ hostPort=%@",
          room.name, room.networkId, room.hostIP, room.hostPort);

    return room;
}

#pragma mark - 预设 Network ID 管理（FCL 风格）

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
        NSLog(@"[MultiplayerManager] 已清除预设 Network ID");
        return;
    }

    // 校验格式
    if (![self isValidNetworkId:networkId]) {
        NSLog(@"[MultiplayerManager] 预设 Network ID 格式无效，未保存：%@", networkId);
        return;
    }

    [[NSUserDefaults standardUserDefaults] setObject:networkId forKey:kPresetNetworkIdPrefKey];
    [[NSUserDefaults standardUserDefaults] synchronize];
    NSLog(@"[MultiplayerManager] 已保存预设 Network ID：%@", networkId);
}

#pragma mark - Ad-hoc 网络（快速模式，无需注册账号）

- (NSString *)generateAdhocNetworkId {
    // 使用 zts_net_compute_adhoc_id 生成 Ad-hoc 网络 ID
    // 参数：端口范围 0-65535（兼容 MC 所有端口，包括 25565 和 LAN 随机端口）
    // 返回值：uint64_t 类型的网络 ID，需要转换为 16 位十六进制字符串
    uint64_t adhocNetId = zts_net_compute_adhoc_id(0, 65535);

    // 转换为 16 位十六进制字符串（与标准 Network ID 格式一致）
    NSString *adhocNetIdStr = [NSString stringWithFormat:@"%016llx", adhocNetId];

    NSLog(@"[MultiplayerManager] 已生成 Ad-hoc 网络 ID：%@ (raw=%llu)", adhocNetIdStr, adhocNetId);
    return adhocNetIdStr;
}

- (BOOL)isAdhocNetworkId:(NSString *)networkId {
    // Ad-hoc 网络 ID 以 "ff" 开头（如 ff0000ffff000000）
    // 标准网络 ID 以其他字符开头（如 1a2b3c4d5e6f7g8h）
    if (!networkId || networkId.length < 2) {
        return NO;
    }
    NSString *prefix = [[networkId substringToIndex:2] lowercaseString];
    return [prefix isEqualToString:@"ff"];
}

@end
