//
//  ZeroTierBridge.m
//  Angel Aura Amethyst
//
//  ZeroTier libzt C API 的 Objective-C 封装层实现
//
//  ============================================================================
//  实现说明
//  ============================================================================
//
//  本文件实现 ZeroTierBridge.h 中定义的接口，封装 libzt 的 C API。
//
//  关键实现点：
//    1. 单例模式：使用 dispatch_once 保证线程安全的单次初始化
//    2. 事件回调：使用静态 C 函数作为 libzt 的回调入口，通过 dispatch_async
//       转发到主线程的 Objective-C 方法 handleEventData: 处理
//    3. 框架检测：信任编译时链接结果，不调用有副作用的 API
//       （避免 zts_node_start/zts_node_stop 导致节点状态混乱）
//    4. 状态管理：使用 NSLock 保护内部状态（节点状态、网络状态、IP 地址缓存）
//    5. Socket 操作：直接转发到 zts_bsd_* API，connectSocket 支持超时设置
//    6. 自动重连：节点离线后以指数退避方式自动重连，最多 10 次后重置节点
//    7. Keychain 备份：自动备份/恢复身份文件，防止重装后节点身份变化
//
//  事件处理映射表（ZeroTierSockets.h 中的事件码）：
//    ZTS_EVENT_NODE_ONLINE          (201) → delegate zeroTierNodeOnlineWithID:
//    ZTS_EVENT_NODE_OFFLINE         (202) → delegate zeroTierNodeOffline
//    ZTS_EVENT_NETWORK_OK           (213) → 更新网络状态 + delegate zeroTierNetworkReady:
//    ZTS_EVENT_NETWORK_ACCESS_DENIED(214) → delegate zeroTierNetworkJoinFailed:error:
//    ZTS_EVENT_NETWORK_NOT_FOUND    (210) → delegate zeroTierNetworkJoinFailed:error:
//    ZTS_EVENT_ADDR_ADDED_IP4       (260) → delegate zeroTierAddressAssigned:family:address:
//    ZTS_EVENT_ADDR_ADDED_IP6       (262) → delegate zeroTierAddressAssigned:family:address:
//    ZTS_EVENT_PEER_DIRECT          (230) → delegate zeroTierPeerConnectionModeChanged:
//    ZTS_EVENT_PEER_RELAY           (231) → delegate zeroTierPeerConnectionModeChanged:
//    ZTS_EVENT_PEER_UNREACHABLE     (232) → delegate zeroTierPeerConnectionModeChanged:
//
//  关键修复（自原始版本新增）：
//    - 自动重连定时器（指数退避，2s→4s→8s→16s→30s，最多 10 次后重置节点）
//    - stopNode 后台同步等待节点真正下线（避免残留节点干扰后续启动）
//    - startNode 检测残留节点并等待清理（防止 stopNode 主线程不等待导致竞争）
//    - resetNode 完整重置逻辑（停止并重新启动节点）
//    - 更细粒度的状态锁保护
//    - 应用前后台切换时的重连优化
//    - 非阻塞 connect + select 实现真正的超时控制
//    - 完整的 Keychain 备份与恢复（identity.secret + identity.public）
//    - 对端连接模式缓存与查询
//  ============================================================================

#import "ZeroTierBridge.h"
#import "utils.h"

// 标准 C 头文件
#include <string.h>
#include <stdlib.h>
#include <arpa/inet.h>
#include <sys/socket.h>
#include <netinet/in.h>
#include <unistd.h>
#include <errno.h>
#include <fcntl.h>
#include <sys/time.h>

// Security.framework（用于 Keychain 备份/恢复 ZeroTier 身份文件）
#import <Security/Security.h>

#pragma mark - 常量定义

/// 错误域名
static NSString * const kZeroTierErrorDomain = @"ZeroTierBridgeErrorDomain";

/// 错误码
typedef NS_ENUM(NSInteger, ZeroTierErrorCode) {
    ZeroTierErrorCodeFrameworkUnavailable = 1,  // zt.framework 不可用（stub 模式）
    ZeroTierErrorCodeNodeNotStarted       = 2,  // 节点未启动
    ZeroTierErrorCodeNodeStartFailed      = 3,  // 节点启动失败
    ZeroTierErrorCodeNetworkJoinFailed    = 4,  // 加入网络失败
    ZeroTierErrorCodeTimeout              = 5,  // 等待超时
    ZeroTierErrorCodeInvalidArgument      = 6,  // 参数无效
    ZeroTierErrorCodeSocketError          = 7,  // socket 操作失败
};

/// Keychain 服务名
static NSString * const kKeychainService = @"com.angelauramc.zerotier";

/// Keychain 中存储身份密钥的 key
static NSString * const kKeychainSecretKey = @"identity.secret";

/// Keychain 中存储身份公钥的 key
static NSString * const kKeychainPublicKey = @"identity.public";

/// 重连最大尝试次数（超过后重置节点）
static const NSInteger kMaxReconnectAttempts = 10;

/// 重连最大延迟（秒）
static const NSTimeInterval kMaxReconnectDelay = 30.0;

/// 节点下线等待超时（秒）
static const NSTimeInterval kNodeOfflineWaitTimeout = 5.0;

/// 应用进入后台后重连延迟加倍因子
static const NSTimeInterval kBackgroundReconnectMultiplier = 2.0;

#pragma mark - ZeroTierBridge 类扩展

@interface ZeroTierBridge () {
    /// 节点状态（受 _lock 保护）
    ZeroTierNodeStatus _nodeStatus;

    /// 网络状态缓存：networkID → ZeroTierNetworkStatus（受 _lock 保护）
    NSMutableDictionary<NSNumber *, NSNumber *> *_networkStatuses;

    /// IPv4 地址缓存：networkID → IPv4 字符串（受 _lock 保护）
    NSMutableDictionary<NSNumber *, NSString *> *_ipv4Addresses;

    /// IPv6 地址缓存：networkID → IPv6 字符串（受 _lock 保护）
    NSMutableDictionary<NSNumber *, NSString *> *_ipv6Addresses;

    /// 节点是否已启动（受 _lock 保护）
    BOOL _isStarted;

    /// framework 是否可用（受 _lock 保护）
    BOOL _frameworkAvailable;

    /// framework 检测是否已完成（受 _lock 保护）
    BOOL _frameworkChecked;

    /// 节点 ID 缓存（受 _lock 保护）
    uint64_t _nodeID;

    /// 节点是否曾经上线过（受 _lock 保护）
    /// 用于 waitForNodeOnlineWithTimeout: 的容错逻辑：
    /// 节点掉线后 libzt 会自动重连，如果曾上线过则视为可用
    BOOL _hasBeenOnline;

    /// 主页目录路径（受 _lock 保护）
    NSString *_homeDirectory;

    /// 对端节点连接模式缓存：peerID → ZeroTierPeerConnectionMode（受 _lock 保护）
    NSMutableDictionary<NSNumber *, NSNumber *> *_peerConnectionModes;

    /// 对端节点路径地址缓存：peerID → address string（受 _lock 保护）
    NSMutableDictionary<NSNumber *, NSString *> *_peerAddresses;

    /// 当前节点 ID 字符串（受 _lock 保护）
    NSString *_ownNodeIdString;

    /// TCP/IP 协议栈是否已启动（受 _lock 保护）
    BOOL _isStackUp;

    /// 节点上线/离线事件信号量，用于 waitForNodeOnlineWithTimeout:
    dispatch_semaphore_t _nodeOnlineSemaphore;

    /// 网络事件信号量，用于 waitForNetworkReady:timeout:
    dispatch_semaphore_t _networkEventSemaphore;

    /// 线程锁，保护所有内部状态变量
    NSLock *_lock;

    // ========== 自动重连相关 ==========

    /// 重连定时器（主线程运行）
    NSTimer *_reconnectTimer;

    /// 当前重连尝试次数
    NSInteger _reconnectAttempts;

    /// 是否正在重连中
    BOOL _isReconnecting;

    /// 应用是否在后台
    BOOL _applicationInBackground;
}

/// 处理 ZeroTier 事件回调（由 zeroTierEventCallback 在主线程调用）
/// @param eventData 从事件消息中提取的数据（eventCode/nodeID/netID/addrStr 等）
- (void)handleEventData:(NSDictionary *)eventData;

/// 启动重连定时器
- (void)startReconnectTimer;

/// 停止重连定时器
- (void)stopReconnectTimer;

/// 重连超时处理
- (void)handleReconnectTimeout;

/// 重置节点（停止并重新启动）
- (void)resetNode;

/// 备份身份文件到 Keychain
- (void)backupIdentityToKeychain;

/// 从 Keychain 恢复身份文件到 homeDir
- (void)restoreIdentityFromKeychainToHomeDir:(NSString *)homeDir;

/// 从 Keychain 加载数据
- (NSData *)loadKeychainDataForKey:(NSString *)key;

/// 向 Keychain 写入数据
- (void)setKeychainData:(NSData *)data forKey:(NSString *)key;

/// 保存 identity.secret 到 Keychain
- (void)saveIdentitySecretToKeychain:(NSString *)secret;

/// 保存 identity.public 到 Keychain
- (void)saveIdentityPublicToKeychain:(NSString *)publicKey;

/// 检查指定网络是否已就绪（传输层就绪且地址已分配）
- (BOOL)isNetworkReady:(uint64_t)networkID;

/// 更新对端节点地址并通知代理
- (void)updatePeerAddress:(uint64_t)peerId address:(NSString *)address;

/// 设置对端节点连接模式并通知代理
- (void)setConnectionMode:(ZeroTierPeerConnectionMode)mode forPeer:(uint64_t)peerID;

/// 应用进入后台通知
- (void)applicationDidEnterBackground:(NSNotification *)notification;

/// 应用进入前台通知
- (void)applicationWillEnterForeground:(NSNotification *)notification;

@end

#pragma mark - 事件回调（静态 C 函数）

/// ZeroTier 事件回调入口（C 函数）
///
/// libzt 的事件回调是在后台线程调用的。
///
/// 关键修复（SIGSEGV 崩溃）：
///   之前的实现将 msg 指针通过 dispatch_async 传递到主线程，但 msg 指针
///   在回调返回后会被 libzt 释放/重用，导致主线程访问已释放的内存，引发
///   objc_retain_x8 处的 SIGSEGV 崩溃。
///
///   修复方案：在回调线程（即 libzt 线程）同步提取所有需要的数据，
///   封装成不可变的 NSDictionary，再 dispatch_async 到主线程处理。
///   NSDictionary 会被 block retain，安全传递到主线程。
///
/// @param msgPtr 指向 zts_event_msg_t 的指针
static void zeroTierEventCallback(void *msgPtr) {
    zts_event_msg_t *msg = (zts_event_msg_t *)msgPtr;
    if (!msg) {
        NSLog(@"[ZeroTierBridge] 事件回调收到空消息指针");
        return;
    }

    int eventCode = msg->event_code;
    NSLog(@"[ZeroTierBridge] 收到事件回调：event_code = %d", eventCode);

    // 在回调线程同步提取所有需要的数据（msg 指针此时有效）
    NSMutableDictionary *eventData = [NSMutableDictionary dictionary];
    eventData[@"eventCode"] = @(eventCode);

    // 提取节点信息
    if (msg->node) {
        eventData[@"nodeID"] = @(msg->node->node_id);
    }

    // 提取网络信息
    if (msg->network) {
        eventData[@"netID"] = @(msg->network->net_id);
    }

    // 提取地址信息
    if (msg->addr) {
        eventData[@"addrNetID"] = @(msg->addr->net_id);
        char ipBuf[ZTS_IP_MAX_STR_LEN] = {0};
        struct zts_sockaddr_storage *ss = &msg->addr->addr;
        if (ss->ss_family == ZTS_AF_INET) {
            struct zts_sockaddr_in *sin = (struct zts_sockaddr_in *)ss;
            if (zts_inet_ntop(ZTS_AF_INET, &sin->sin_addr, ipBuf, sizeof(ipBuf))) {
                eventData[@"addrStr"] = [NSString stringWithUTF8String:ipBuf];
                eventData[@"addrFamily"] = @(ZTS_AF_INET);
            }
        } else if (ss->ss_family == ZTS_AF_INET6) {
            struct zts_sockaddr_in6 *sin6 = (struct zts_sockaddr_in6 *)ss;
            if (zts_inet_ntop(ZTS_AF_INET6, &sin6->sin6_addr, ipBuf, sizeof(ipBuf))) {
                eventData[@"addrStr"] = [NSString stringWithUTF8String:ipBuf];
                eventData[@"addrFamily"] = @(ZTS_AF_INET6);
            }
        }
    }

    // 提取对端节点信息
    if (msg->peer) {
        eventData[@"peerID"] = @(msg->peer->peer_id);
        if (msg->peer->path_count > 0) {
            struct zts_sockaddr_storage *pss = &msg->peer->paths[0].address;
            char pathBuf[ZTS_IP_MAX_STR_LEN] = {0};
            if (pss->ss_family == ZTS_AF_INET) {
                struct zts_sockaddr_in *psin = (struct zts_sockaddr_in *)pss;
                if (zts_inet_ntop(ZTS_AF_INET, &psin->sin_addr, pathBuf, sizeof(pathBuf))) {
                    eventData[@"peerPathAddress"] = [NSString stringWithUTF8String:pathBuf];
                }
            } else if (pss->ss_family == ZTS_AF_INET6) {
                struct zts_sockaddr_in6 *psin6 = (struct zts_sockaddr_in6 *)pss;
                if (zts_inet_ntop(ZTS_AF_INET6, &psin6->sin6_addr, pathBuf, sizeof(pathBuf))) {
                    eventData[@"peerPathAddress"] = [NSString stringWithUTF8String:pathBuf];
                }
            }
        }
    }

    // 将不可变副本传递到主线程处理（block 会 retain eventData）
    NSDictionary *immutableData = [eventData copy];
    dispatch_async(dispatch_get_main_queue(), ^{
        [[ZeroTierBridge sharedInstance] handleEventData:immutableData];
    });
}

#pragma mark - ZeroTierBridge 实现

@implementation ZeroTierBridge

#pragma mark - 单例模式

/// 获取共享的 ZeroTierBridge 单例实例
/// 使用 dispatch_once 保证线程安全的单次初始化
+ (instancetype)sharedInstance {
    static ZeroTierBridge *shared = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        shared = [[self alloc] init];
    });
    return shared;
}

/// 重写 allocWithZone: 防止通过 alloc/init 创建第二个实例
/// 这是一种更严格的单例保护，确保即使外部调用 [[ZeroTierBridge alloc] init]
/// 也能拿到同一个实例
+ (instancetype)allocWithZone:(struct _NSZone *)zone {
    static ZeroTierBridge *shared = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        shared = [super allocWithZone:zone];
    });
    return shared;
}

/// 私有初始化方法
/// 创建内部状态变量和线程锁
- (instancetype)init {
    self = [super init];
    if (self) {
        // 初始化锁
        _lock = [[NSLock alloc] init];

        // 初始化状态字典
        _networkStatuses = [[NSMutableDictionary alloc] init];
        _ipv4Addresses = [[NSMutableDictionary alloc] init];
        _ipv6Addresses = [[NSMutableDictionary alloc] init];
        _peerConnectionModes = [[NSMutableDictionary alloc] init];
        _peerAddresses = [[NSMutableDictionary alloc] init];

        // 初始化状态变量
        _nodeStatus = ZeroTierNodeStatusStopped;
        _isStarted = NO;
        _frameworkAvailable = NO;
        _frameworkChecked = NO;
        _nodeID = 0;
        _hasBeenOnline = NO;
        _homeDirectory = nil;
        _ownNodeIdString = nil;
        _isStackUp = NO;

        // 初始化信号量
        _nodeOnlineSemaphore = dispatch_semaphore_create(0);
        _networkEventSemaphore = dispatch_semaphore_create(0);

        // 初始化重连相关
        _reconnectTimer = nil;
        _reconnectAttempts = 0;
        _isReconnecting = NO;
        _applicationInBackground = NO;

        // 注册应用生命周期通知
        [[NSNotificationCenter defaultCenter] addObserver:self
                                                 selector:@selector(applicationDidEnterBackground:)
                                                     name:UIApplicationDidEnterBackgroundNotification
                                                   object:nil];
        [[NSNotificationCenter defaultCenter] addObserver:self
                                                 selector:@selector(applicationWillEnterForeground:)
                                                     name:UIApplicationWillEnterForegroundNotification
                                                   object:nil];

        NSLog(@"[ZeroTierBridge] 单例已初始化");
    }
    return self;
}

/// 析构：移除通知观察者
- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
    [self stopReconnectTimer];
}

#pragma mark - 应用生命周期

/// 应用进入后台通知
- (void)applicationDidEnterBackground:(NSNotification *)notification {
    NSLog(@"[ZeroTierBridge] 应用进入后台");
    _applicationInBackground = YES;
    // 后台时重连定时器会继续工作，但延迟加倍（由 startReconnectTimer 处理）
}

/// 应用进入前台通知
- (void)applicationWillEnterForeground:(NSNotification *)notification {
    NSLog(@"[ZeroTierBridge] 应用进入前台");
    _applicationInBackground = NO;
    // 如果节点离线且未在重连中，立即启动重连
    if (_isStarted && ![self isNodeOnline] && !_isReconnecting) {
        NSLog(@"[ZeroTierBridge] 应用回到前台，节点离线，启动重连");
        [self startReconnectTimer];
    }
}

#pragma mark - 框架检测

/// 检测 zt.framework 是否可用
///
/// 检测原理：
///   - ZeroTier Apple Framework 通过 git submodule 引入（external/ZeroTierFramework），
///     构建时直接链接 submodule 中的预编译 zt.framework。
///   - 若 zts_node_start() 返回 ZTS_ERR_OK (0)，说明 framework 已正确加载并启动节点。
///
/// 注意：此方法在检测过程中如果发现 framework 可用，会顺带启动节点
/// （因为 zts_node_start() 有副作用）。这种设计是有意为之，因为：
///   1. 没有其他无副作用的 API 可以检测 framework 可用性
///   2. 如果 framework 可用，用户大概率需要启动节点
///   3. 后续调用 startNodeWithHomeDirectory: 会检测 _isStarted 标志，
///      如果已启动则跳过重复启动
///
/// @return YES 如果 framework 可用
- (BOOL)isFrameworkAvailable {
    // 先检查缓存
    [_lock lock];
    BOOL cached = _frameworkChecked;
    BOOL available = _frameworkAvailable;
    [_lock unlock];

    if (cached) {
        return available;
    }

    NSLog(@"[ZeroTierBridge] 开始检测 framework 可用性...");

    // 信任编译时链接结果，直接返回 YES
    BOOL frameworkAvailable = YES;

    [_lock lock];
    _frameworkAvailable = frameworkAvailable;
    _frameworkChecked = YES;
    [_lock unlock];

    NSLog(@"[ZeroTierBridge] framework 检测完成：available = %@（信任编译时链接）",
          frameworkAvailable ? @"YES" : @"NO");

    return frameworkAvailable;
}

#pragma mark - 节点管理

/// 启动 ZeroTier 节点
///
/// 流程：
///   1. 校验 homeDir 参数
///   2. 检测 framework 可用性
///   3. 检查是否已启动（避免重复启动）
///   4. 等待残留节点下线（关键修复：避免 stopNode 主线程不等待导致的竞争）
///   5. 从 Keychain 恢复身份文件
///   6. 调用 zts_init_from_storage 设置存储目录
///   7. 调用 zts_init_set_event_handler 设置事件回调
///   8. 调用 zts_node_start 启动节点
///
/// @param homeDir 主页目录路径
/// @param error 错误输出
/// @return YES 如果启动成功
- (BOOL)startNodeWithHomeDirectory:(NSString *)homeDir
                             error:(NSError **)error {
    // ============================================================
    // 步骤 1：参数校验
    // ============================================================
    if (!homeDir || homeDir.length == 0) {
        NSLog(@"[ZeroTierBridge] startNode 失败：homeDir 为空");
        if (error) {
            *error = [NSError errorWithDomain:kZeroTierErrorDomain
                                          code:ZeroTierErrorCodeInvalidArgument
                                      userInfo:@{NSLocalizedDescriptionKey: @"主页目录路径无效"}];
        }
        return NO;
    }

    // ============================================================
    // 步骤 2：检测 framework 可用性
    // ============================================================
    if (![self isFrameworkAvailable]) {
        NSLog(@"[ZeroTierBridge] startNode 失败：framework 不可用");
        if (error) {
            *error = [NSError errorWithDomain:kZeroTierErrorDomain
                                          code:ZeroTierErrorCodeFrameworkUnavailable
                                      userInfo:@{NSLocalizedDescriptionKey: @"ZeroTier framework 不可用"}];
        }
        return NO;
    }

    // ============================================================
    // 步骤 3：检查是否已启动
    // ============================================================
    [_lock lock];
    if (_isStarted) {
        [_lock unlock];
        NSLog(@"[ZeroTierBridge] 节点已启动，跳过重复启动");
        return YES;
    }
    [_lock unlock];

    // ============================================================
    // 步骤 4：关键修复：等待残留节点下线
    //   当 stopNode 在主线程调用时，由于不等待节点真正下线，
    //   可能导致 zts_node_is_online() 仍返回 1，但 _isStarted 已为 NO。
    //   此时再次调用 startNode 会与残留节点冲突，导致启动失败。
    // ============================================================
    if (zts_node_is_online() == 1) {
        BOOL isMainThread = [NSThread isMainThread];
        NSTimeInterval maxWait = isMainThread ? 2.0 : 5.0;
        NSLog(@"[ZeroTierBridge] startNode：检测到 libzt 内部仍有残留节点在线，"
              @"等待其下线（最多 %.0f 秒，isMainThread=%d）", maxWait, isMainThread);
        NSTimeInterval deadline = [NSDate timeIntervalSinceReferenceDate] + maxWait;
        int pollCount = 0;
        while (zts_node_is_online() == 1 && [NSDate timeIntervalSinceReferenceDate] < deadline) {
            [NSThread sleepForTimeInterval:0.1];
            pollCount++;
        }
        if (zts_node_is_online() == 1) {
            NSLog(@"[ZeroTierBridge] startNode 警告：残留节点在线等待超时（%.0f 秒），"
                  @"继续尝试初始化（可能失败）", maxWait);
        } else {
            NSLog(@"[ZeroTierBridge] startNode：残留节点已下线（polling %d 次，约 %.1f 秒）",
                  pollCount, pollCount * 0.1);
        }
    }

    // ============================================================
    // 步骤 5：从 Keychain 恢复 ZeroTier 身份文件
    // ============================================================
    [self restoreIdentityFromKeychainToHomeDir:homeDir];

    // ============================================================
    // 步骤 6：初始化存储路径
    // ============================================================
    int result = zts_init_from_storage([homeDir UTF8String]);
    if (result != ZTS_ERR_OK) {
        NSLog(@"[ZeroTierBridge] zts_init_from_storage 失败：result = %d", result);
        if (error) {
            *error = [NSError errorWithDomain:kZeroTierErrorDomain
                                          code:ZeroTierErrorCodeNodeStartFailed
                                      userInfo:@{NSLocalizedDescriptionKey: [NSString stringWithFormat:@"初始化存储目录失败 (code=%d)", result]}];
        }
        // 关键修复：zts_init_from_storage 失败，调用 zts_node_stop 清理
        zts_node_stop();
        return NO;
    }
    NSLog(@"[ZeroTierBridge] zts_init_from_storage 成功");

    // ============================================================
    // 步骤 7：设置事件回调
    // ============================================================
    result = zts_init_set_event_handler(zeroTierEventCallback);
    if (result != ZTS_ERR_OK) {
        NSLog(@"[ZeroTierBridge] zts_init_set_event_handler 失败：result = %d", result);
        if (error) {
            *error = [NSError errorWithDomain:kZeroTierErrorDomain
                                          code:ZeroTierErrorCodeNodeStartFailed
                                      userInfo:@{NSLocalizedDescriptionKey: [NSString stringWithFormat:@"设置事件回调失败 (code=%d)", result]}];
        }
        zts_node_stop();
        return NO;
    }
    NSLog(@"[ZeroTierBridge] zts_init_set_event_handler 成功");

    // ============================================================
    // 步骤 8：启动节点
    // ============================================================
    result = zts_node_start();
    if (result != ZTS_ERR_OK) {
        NSLog(@"[ZeroTierBridge] zts_node_start 失败：result = %d", result);
        if (error) {
            *error = [NSError errorWithDomain:kZeroTierErrorDomain
                                          code:ZeroTierErrorCodeNodeStartFailed
                                      userInfo:@{NSLocalizedDescriptionKey: [NSString stringWithFormat:@"节点启动失败 (code=%d)", result]}];
        }
        zts_node_stop();
        return NO;
    }

    // ============================================================
    // 步骤 9：更新内部状态
    // ============================================================
    [_lock lock];
    _isStarted = YES;
    _nodeStatus = ZeroTierNodeStatusStarting;
    _homeDirectory = [homeDir copy];
    _reconnectAttempts = 0;
    _isReconnecting = NO;
    // 清空旧缓存
    [_networkStatuses removeAllObjects];
    [_ipv4Addresses removeAllObjects];
    [_ipv6Addresses removeAllObjects];
    [_peerConnectionModes removeAllObjects];
    [_peerAddresses removeAllObjects];
    [_lock unlock];

    NSLog(@"[ZeroTierBridge] 节点启动请求已提交，等待上线事件...");
    return YES;
}

/// 停止 ZeroTier 节点
///
/// 调用 zts_node_stop 停止节点，并清理所有内部状态缓存。
///
/// 关键修复（H14）：同步等待节点真正下线，避免后续 startNode 失败。
/// 之前的实现仅调用 zts_node_stop() 后立即设置 _isStarted = NO，
/// 但 zts_node_stop() 是异步的——它只是发出停止请求，节点实际关闭需要时间。
/// 如果在 stopNode 后立即调用 startNode，会出现：
///   - libzt 内部节点可能还在关闭中，zts_node_start 会失败或行为未定义
///   - 即使 _isStarted = NO 让 startNode 进入启动流程，启动也可能失败
///   - 多次快速 stop/start 会导致状态混乱
///
/// 修复方案：
///   - 调用 zts_node_stop() 后，使用 polling + sleep 等待 zts_node_is_online() 返回 0
///   - 设置 5 秒超时，避免无限等待
///   - 如果在主线程调用，则不等待（避免阻塞 UI），改为依靠 NODE_DOWN 事件清理
- (void)stopNode {
    // ============================================================
    // 步骤 1：检查是否已启动
    // ============================================================
    [_lock lock];
    if (!_isStarted) {
        [_lock unlock];
        NSLog(@"[ZeroTierBridge] stopNode：节点未启动，跳过");
        return;
    }
    [_lock unlock];

    NSLog(@"[ZeroTierBridge] 停止节点...");

    // ============================================================
    // 步骤 2：停止重连定时器
    // ============================================================
    [self stopReconnectTimer];

    // ============================================================
    // 步骤 3：离开所有网络
    // ============================================================
    zts_net_leave_all();
    NSLog(@"[ZeroTierBridge] 已请求离开所有网络");

    // ============================================================
    // 步骤 4：停止节点
    // ============================================================
    int result = zts_node_stop();
    if (result != ZTS_ERR_OK) {
        NSLog(@"[ZeroTierBridge] zts_node_stop 失败：result = %d", result);
    } else {
        NSLog(@"[ZeroTierBridge] zts_node_stop 成功");
    }

    // ============================================================
    // 步骤 5：关键修复：后台线程同步等待节点真正下线
    // ============================================================
    BOOL isMainThread = [NSThread isMainThread];
    if (isMainThread) {
        NSLog(@"[ZeroTierBridge] stopNode 在主线程调用，跳过同步等待（依靠 NODE_DOWN 事件清理状态）");
    } else {
        NSTimeInterval deadline = [NSDate timeIntervalSinceReferenceDate] + kNodeOfflineWaitTimeout;
        int pollCount = 0;
        while (zts_node_is_online() == 1 && [NSDate timeIntervalSinceReferenceDate] < deadline) {
            [NSThread sleepForTimeInterval:0.1];
            pollCount++;
        }
        if (zts_node_is_online() == 0) {
            NSLog(@"[ZeroTierBridge] 节点已确认下线（polling %d 次，约 %.1f 秒）",
                  pollCount, pollCount * 0.1);
        } else {
            NSLog(@"[ZeroTierBridge] 节点下线等待超时（%.0f 秒），继续清理状态",
                  kNodeOfflineWaitTimeout);
        }
    }

    // ============================================================
    // 步骤 6：清理所有内部状态
    // ============================================================
    [_lock lock];
    _isStarted = NO;
    _nodeStatus = ZeroTierNodeStatusStopped;
    _nodeID = 0;
    _hasBeenOnline = NO;
    _homeDirectory = nil;
    _ownNodeIdString = nil;
    _isStackUp = NO;
    [_networkStatuses removeAllObjects];
    [_ipv4Addresses removeAllObjects];
    [_ipv6Addresses removeAllObjects];
    [_peerConnectionModes removeAllObjects];
    [_peerAddresses removeAllObjects];
    _reconnectAttempts = 0;
    _isReconnecting = NO;
    [_lock unlock];

    NSLog(@"[ZeroTierBridge] 节点已停止，内部状态已清理");
}

/// 节点是否在线
/// @return YES 如果节点已上线
- (BOOL)isNodeOnline {
    int online = zts_node_is_online();
    if (online == 1) {
        [_lock lock];
        if (_isStarted && !_hasBeenOnline) {
            _hasBeenOnline = YES;
            NSLog(@"[ZeroTierBridge] isNodeOnline 检测到节点上线，同步设置 _hasBeenOnline = YES");
        }
        BOOL started = _isStarted;
        [_lock unlock];
        // 只有 _isStarted 为 YES 时才认为在线，避免 stopNode 后残留报告在线
        if (!started) {
            NSLog(@"[ZeroTierBridge] isNodeOnline：zts_node_is_online()=1 但 _isStarted=NO，返回 NO");
            return NO;
        }
        return YES;
    }
    return NO;
}

/// 获取节点 ID
///
/// 优先返回缓存值，如果未缓存且节点已上线，则调用 zts_node_get_id 查询。
///
/// @return 节点 ID（如果节点未上线则返回 0）
- (uint64_t)nodeID {
    [_lock lock];
    uint64_t id = _nodeID;
    [_lock unlock];

    if (id != 0) {
        return id;
    }

    // 如果未缓存，调用 API 查询
    if ([self isNodeOnline]) {
        id = zts_node_get_id();
        if (id != 0) {
            [_lock lock];
            _nodeID = id;
            [_lock unlock];
            NSLog(@"[ZeroTierBridge] 从 API 获取 nodeID = %016llx", id);
        }
    }
    return id;
}

/// 获取节点状态
/// @return 当前节点状态枚举值
- (ZeroTierNodeStatus)nodeStatus {
    [_lock lock];
    ZeroTierNodeStatus status = _nodeStatus;
    [_lock unlock];
    return status;
}

/// 获取节点 ID 字符串
- (NSString *)nodeIdString {
    [_lock lock];
    NSString *s = _ownNodeIdString;
    [_lock unlock];
    if (s) {
        return s;
    }
    uint64_t nid = [self nodeID];
    if (nid != 0) {
        s = [ZeroTierBridge formatNetworkID:nid];
        [_lock lock];
        _ownNodeIdString = s;
        [_lock unlock];
    }
    return s;
}

#pragma mark - 网络管理

/// 加入 ZeroTier 网络
///
/// 调用 zts_net_join 加入网络。加入后节点会向网络控制器请求配置，
/// 配置成功后会触发 ZTS_EVENT_NETWORK_OK 事件。
///
/// @param networkID 网络 ID（64 位无符号整数）
/// @param error 错误输出
/// @return YES 如果加入请求已成功提交
- (BOOL)joinNetwork:(uint64_t)networkID
              error:(NSError **)error {
    // 检查节点是否已启动
    [_lock lock];
    if (!_isStarted) {
        [_lock unlock];
        NSLog(@"[ZeroTierBridge] joinNetwork 失败：节点未启动");
        if (error) {
            *error = [NSError errorWithDomain:kZeroTierErrorDomain
                                          code:ZeroTierErrorCodeNodeNotStarted
                                      userInfo:@{NSLocalizedDescriptionKey: @"ZeroTier 节点未启动"}];
        }
        return NO;
    }
    [_lock unlock];

    NSLog(@"[ZeroTierBridge] 加入网络：networkID = %016llx", networkID);

    int result = zts_net_join(networkID);
    if (result != ZTS_ERR_OK) {
        NSLog(@"[ZeroTierBridge] zts_net_join 失败：result = %d, networkID = %016llx", result, networkID);
        if (error) {
            *error = [NSError errorWithDomain:kZeroTierErrorDomain
                                          code:ZeroTierErrorCodeNetworkJoinFailed
                                      userInfo:@{NSLocalizedDescriptionKey: [NSString stringWithFormat:@"加入网络失败 (code=%d)", result]}];
        }
        return NO;
    }

    // 更新网络状态为"请求中"
    [_lock lock];
    _networkStatuses[@(networkID)] = @(ZeroTierNetworkStatusRequesting);
    [_lock unlock];

    NSLog(@"[ZeroTierBridge] 加入网络请求已提交，等待网络配置...");
    return YES;
}

/// 离开 ZeroTier 网络
/// @param networkID 网络 ID
/// @return YES 如果成功离开
- (BOOL)leaveNetwork:(uint64_t)networkID {
    NSLog(@"[ZeroTierBridge] 离开网络：networkID = %016llx", networkID);

    int result = zts_net_leave(networkID);
    if (result != ZTS_ERR_OK) {
        NSLog(@"[ZeroTierBridge] zts_net_leave 失败：result = %d, networkID = %016llx", result, networkID);
        return NO;
    }

    // 清理该网络的所有缓存
    [_lock lock];
    [_networkStatuses removeObjectForKey:@(networkID)];
    [_ipv4Addresses removeObjectForKey:@(networkID)];
    [_ipv6Addresses removeObjectForKey:@(networkID)];
    // 不清理对端缓存（可能仍需要），但清理网络相关的
    [_lock unlock];

    NSLog(@"[ZeroTierBridge] 已离开网络并清理缓存");
    return YES;
}

/// 获取网络状态
///
/// 优先返回事件回调更新的缓存状态。如果节点在线，还会查询实时状态作为补充。
///
/// @param networkID 网络 ID
/// @return 网络状态枚举值
- (ZeroTierNetworkStatus)networkStatus:(uint64_t)networkID {
    // 先读取缓存状态
    [_lock lock];
    ZeroTierNetworkStatus status = ZeroTierNetworkStatusNotJoined;
    NSNumber *cached = _networkStatuses[@(networkID)];
    if (cached) {
        status = (ZeroTierNetworkStatus)[cached integerValue];
    }
    [_lock unlock];

    // 如果节点在线，查询实时状态作为补充
    if ([self isNodeOnline]) {
        int apiStatus = zts_net_get_status(networkID);
        // ZTS_NETWORK_STATUS_REQUESTING_CONFIGURATION = 0
        // ZTS_NETWORK_STATUS_OK = 1
        // ZTS_NETWORK_STATUS_ACCESS_DENIED = 2
        // ZTS_NETWORK_STATUS_NOT_FOUND = 3
        // ZTS_NETWORK_STATUS_PORT_ERROR = 4
        // ZTS_NETWORK_STATUS_CLIENT_TOO_OLD = 5
        switch (apiStatus) {
            case 0:
                status = ZeroTierNetworkStatusRequesting;
                break;
            case 1:
                status = ZeroTierNetworkStatusJoined;
                break;
            case 2:
                status = ZeroTierNetworkStatusDenied;
                break;
            case 3:
                status = ZeroTierNetworkStatusNotFound;
                break;
            case 4:
            case 5:
                status = ZeroTierNetworkStatusError;
                break;
            default:
                if (apiStatus < 0 && status == ZeroTierNetworkStatusNotJoined) {
                    status = ZeroTierNetworkStatusError;
                }
                break;
        }
    }

    return status;
}

/// 获取网络分配的 IPv4 地址
///
/// 优先返回缓存值（由 ADDR_ADDED_IP4 事件更新），
/// 如果缓存中没有，则调用 zts_addr_get_str 查询。
///
/// @param networkID 网络 ID
/// @return IPv4 地址字符串（如 "10.147.17.1"），如果未分配则返回 nil
- (nullable NSString *)ipv4AddressForNetwork:(uint64_t)networkID {
    // 先查缓存
    [_lock lock];
    NSString *cached = _ipv4Addresses[@(networkID)];
    [_lock unlock];
    if (cached) {
        return cached;
    }

    // 调用 API 查询
    char ipStr[ZTS_IP_MAX_STR_LEN] = {0};
    int result = zts_addr_get_str(networkID, ZTS_AF_INET, ipStr, sizeof(ipStr));
    if (result == ZTS_ERR_OK && ipStr[0] != '\0') {
        NSString *addr = [NSString stringWithUTF8String:ipStr];
        [_lock lock];
        _ipv4Addresses[@(networkID)] = addr;
        [_lock unlock];
        return addr;
    }

    return nil;
}

/// 获取网络分配的 IPv6 地址
///
/// 优先返回缓存值（由 ADDR_ADDED_IP6 事件更新），
/// 如果缓存中没有，则调用 zts_addr_get_str 查询。
///
/// @param networkID 网络 ID
/// @return IPv6 地址字符串，如果未分配则返回 nil
- (nullable NSString *)ipv6AddressForNetwork:(uint64_t)networkID {
    // 先查缓存
    [_lock lock];
    NSString *cached = _ipv6Addresses[@(networkID)];
    [_lock unlock];
    if (cached) {
        return cached;
    }

    // 调用 API 查询
    char ipStr[ZTS_IP_MAX_STR_LEN] = {0};
    int result = zts_addr_get_str(networkID, ZTS_AF_INET6, ipStr, sizeof(ipStr));
    if (result == ZTS_ERR_OK && ipStr[0] != '\0') {
        NSString *addr = [NSString stringWithUTF8String:ipStr];
        [_lock lock];
        _ipv6Addresses[@(networkID)] = addr;
        [_lock unlock];
        return addr;
    }

    return nil;
}

/// 检查指定网络是否已就绪（内部方法）
///
/// 按网络类型区分地址族要求：
///   - 标准网络（networkID 高字节不是 0xff）：要求 IPv4 地址已分配
///   - Ad-hoc 网络（networkID 高字节是 0xff，即以 "ff" 开头）：要求 IPv6 地址已分配
/// 两者都要求 zts_net_transport_is_ready(networkID) == 1。
///
/// @param networkID 网络 ID
/// @return YES 如果网络传输就绪且对应地址族已分配
- (BOOL)isNetworkReady:(uint64_t)networkID {
    if (zts_net_transport_is_ready(networkID) != 1) {
        return NO;
    }

    // Ad-hoc 网络 ID 以 "ff" 开头（高字节为 0xff），只有 IPv6 地址
    uint8_t highByte = (uint8_t)((networkID >> 56) & 0xFF);
    BOOL isAdhoc = (highByte == 0xFF);

    if (isAdhoc) {
        return zts_addr_is_assigned(networkID, ZTS_AF_INET6) == 1;
    }

    // 标准网络通常只分配 IPv4
    return zts_addr_is_assigned(networkID, ZTS_AF_INET) == 1;
}

#pragma mark - 等待操作

/// 等待节点上线
///
/// 优先检查当前状态；若未上线则通过信号量等待 ZTS_EVENT_NODE_ONLINE /
/// ZTS_EVENT_NODE_OFFLINE 事件，避免忙等。事件会在主线程触发信号量，
/// 等待线程在后台被唤醒后重新评估状态。
///
/// 状态机：
///   - 节点从未上线（!_hasBeenOnline）：严格等待 zts_node_is_online() == 1
///   - 节点曾上线但当前离线（_hasBeenOnline && Offline）：最多等待 10 秒恢复
///   - 节点正在启动（Starting）：继续等待直到 Online 或原始超时
///
/// @param timeout 超时时间（秒）
/// @return YES 如果节点在超时前上线
- (BOOL)waitForNodeOnlineWithTimeout:(NSTimeInterval)timeout {
    NSLog(@"[ZeroTierBridge] 等待节点上线，超时 = %.1f 秒", timeout);

    if ([self isNodeOnline]) {
        NSLog(@"[ZeroTierBridge] 节点已在线，立即返回 YES");
        return YES;
    }

    // 检查节点是否处于不可恢复状态
    [_lock lock];
    ZeroTierNodeStatus status = _nodeStatus;
    BOOL hasBeenOnline = _hasBeenOnline;
    [_lock unlock];
    if (status == ZeroTierNodeStatusStopped || status == ZeroTierNodeStatusError) {
        NSLog(@"[ZeroTierBridge] 节点已停止或发生错误，结束等待");
        return NO;
    }

    // 根据节点是否曾上线决定有效超时
    NSTimeInterval effectiveTimeout = timeout;
    if (hasBeenOnline) {
        effectiveTimeout = MIN(timeout, 10.0);
        NSLog(@"[ZeroTierBridge] 节点曾上线但当前离线，使用 %.1f 秒恢复等待窗口", effectiveTimeout);
    }

    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:effectiveTimeout];

    while ([[NSDate date] compare:deadline] == NSOrderedAscending) {
        // 检查当前状态
        if ([self isNodeOnline]) {
            NSLog(@"[ZeroTierBridge] 节点已上线（等待成功）");
            return YES;
        }

        // 检查是否进入错误状态
        [_lock lock];
        ZeroTierNodeStatus currentStatus = _nodeStatus;
        [_lock unlock];
        if (currentStatus == ZeroTierNodeStatusStopped || currentStatus == ZeroTierNodeStatusError) {
            NSLog(@"[ZeroTierBridge] 节点进入停止或错误状态，结束等待");
            return NO;
        }

        // 使用信号量等待下一次节点上下线事件
        NSTimeInterval remaining = [deadline timeIntervalSinceNow];
        if (remaining <= 0) {
            break;
        }
        dispatch_semaphore_wait(_nodeOnlineSemaphore, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(remaining * NSEC_PER_SEC)));

        // 兜底：短睡眠防止极端情况下事件丢失导致 CPU 空转
        [NSThread sleepForTimeInterval:0.05];
    }

    NSLog(@"[ZeroTierBridge] 等待节点上线超时（%.1f 秒）", effectiveTimeout);
    return NO;
}

/// 等待网络就绪
///
/// 优先检查当前状态；若未就绪则通过信号量等待网络相关事件（NETWORK_OK、
/// NETWORK_READY_IP4 / IP6、ADDR_ADDED_* 等），避免忙等。
///
/// 网络就绪判定：传输层就绪且至少有一个地址族已分配。
/// 公共网络优先 IPv4，但也接受 IPv6（如 Ad-hoc）。
///
/// @param networkID 网络 ID
/// @param timeout 超时时间（秒）
/// @return YES 如果网络在超时前就绪
- (BOOL)waitForNetworkReady:(uint64_t)networkID
                    timeout:(NSTimeInterval)timeout {
    NSLog(@"[ZeroTierBridge] 等待网络就绪：networkID = %016llx，超时 = %.1f 秒", networkID, timeout);

    if ([self isNetworkReady:networkID]) {
        NSLog(@"[ZeroTierBridge] 网络已就绪，立即返回 YES");
        return YES;
    }

    // 检查是否已被拒绝或不存在
    ZeroTierNetworkStatus cachedStatus = [self networkStatus:networkID];
    if (cachedStatus == ZeroTierNetworkStatusDenied) {
        NSLog(@"[ZeroTierBridge] 网络访问被拒绝（networkID = %016llx），立即返回失败", networkID);
        return NO;
    }
    if (cachedStatus == ZeroTierNetworkStatusNotFound) {
        NSLog(@"[ZeroTierBridge] 网络不存在（networkID = %016llx），立即返回失败", networkID);
        return NO;
    }

    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:timeout];

    while ([[NSDate date] compare:deadline] == NSOrderedAscending) {
        if ([self isNetworkReady:networkID]) {
            NSLog(@"[ZeroTierBridge] 网络已就绪（事件唤醒）");
            return YES;
        }

        // 再次检查状态
        ZeroTierNetworkStatus currentStatus = [self networkStatus:networkID];
        if (currentStatus == ZeroTierNetworkStatusDenied) {
            NSLog(@"[ZeroTierBridge] 网络访问被拒绝，立即返回失败");
            return NO;
        }
        if (currentStatus == ZeroTierNetworkStatusNotFound) {
            NSLog(@"[ZeroTierBridge] 网络不存在，立即返回失败");
            return NO;
        }

        NSTimeInterval remaining = [deadline timeIntervalSinceNow];
        if (remaining <= 0) {
            break;
        }
        dispatch_semaphore_wait(_networkEventSemaphore, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(remaining * NSEC_PER_SEC)));

        // 兜底：短睡眠防止极端情况下事件丢失导致 CPU 空转
        [NSThread sleepForTimeInterval:0.05];
    }

    NSLog(@"[ZeroTierBridge] 等待网络就绪超时（%.1f 秒）", timeout);
    return NO;
}

#pragma mark - 事件处理

/// 处理 ZeroTier 事件（在主线程调用）
///
/// 根据 zts_event_msg_t 的 event_code 字段分发到对应的处理逻辑。
///
/// @param eventData 事件数据字典
- (void)handleEventData:(NSDictionary *)eventData {
    if (!eventData) {
        NSLog(@"[ZeroTierBridge] handleEventData 收到空数据");
        return;
    }

    int eventCode = [eventData[@"eventCode"] intValue];
    NSLog(@"[ZeroTierBridge] 处理事件：event_code = %d", eventCode);

    switch (eventCode) {
        // ===== 节点事件 =====

        case ZTS_EVENT_NODE_UP: {
            // 节点已初始化（200）
            NSLog(@"[ZeroTierBridge] 事件：节点已初始化 (NODE_UP)");
            [_lock lock];
            _nodeStatus = ZeroTierNodeStatusStarting;
            [_lock unlock];
            break;
        }

        case ZTS_EVENT_NODE_ONLINE: {
            // 节点已上线（201）
            uint64_t nodeID = [eventData[@"nodeID"] unsignedLongLongValue];
            NSString *nodeIdString = [ZeroTierBridge formatNetworkID:nodeID];
            NSLog(@"[ZeroTierBridge] 事件：节点已上线 (NODE_ONLINE)，nodeID = %@", nodeIdString);

            [_lock lock];
            _nodeStatus = ZeroTierNodeStatusOnline;
            _nodeID = nodeID;
            _hasBeenOnline = YES;
            _ownNodeIdString = nodeIdString;
            [_lock unlock];

            // 备份身份文件到 Keychain
            [self backupIdentityToKeychain];

            // 停止重连定时器
            [self stopReconnectTimer];
            _reconnectAttempts = 0;
            _isReconnecting = NO;

            // 唤醒等待节点上线的线程
            dispatch_semaphore_signal(_nodeOnlineSemaphore);

            // 通知代理
            dispatch_async(dispatch_get_main_queue(), ^{
                if ([self.delegate respondsToSelector:@selector(zeroTierBridgeDidGoOnline:)]) {
                    [self.delegate zeroTierBridgeDidGoOnline:nodeIdString];
                }
                if ([self.delegate respondsToSelector:@selector(zeroTierNodeOnlineWithID:)]) {
                    [self.delegate zeroTierNodeOnlineWithID:nodeID];
                }
            });
            break;
        }

        case ZTS_EVENT_NODE_OFFLINE: {
            // 节点已离线（202）
            NSLog(@"[ZeroTierBridge] 事件：节点已离线 (NODE_OFFLINE)");
            [_lock lock];
            _nodeStatus = ZeroTierNodeStatusOffline;
            [_lock unlock];

            // 唤醒等待节点上线的线程
            dispatch_semaphore_signal(_nodeOnlineSemaphore);

            // 通知代理
            dispatch_async(dispatch_get_main_queue(), ^{
                if ([self.delegate respondsToSelector:@selector(zeroTierBridgeDidGoOffline)]) {
                    [self.delegate zeroTierBridgeDidGoOffline];
                }
                if ([self.delegate respondsToSelector:@selector(zeroTierNodeOffline)]) {
                    [self.delegate zeroTierNodeOffline];
                }
            });

            // 启动自动重连（如果节点仍处于启动状态且不在后台重连中）
            if (_isStarted && !_isReconnecting) {
                [self startReconnectTimer];
            }
            break;
        }

        case ZTS_EVENT_NODE_DOWN: {
            // 节点正在关闭（203）
            NSLog(@"[ZeroTierBridge] 事件：节点正在关闭 (NODE_DOWN)");
            [_lock lock];
            _isStarted = NO;
            _nodeStatus = ZeroTierNodeStatusStopped;
            _nodeID = 0;
            _hasBeenOnline = NO;
            _homeDirectory = nil;
            _ownNodeIdString = nil;
            _isStackUp = NO;
            [_networkStatuses removeAllObjects];
            [_ipv4Addresses removeAllObjects];
            [_ipv6Addresses removeAllObjects];
            [_peerConnectionModes removeAllObjects];
            [_peerAddresses removeAllObjects];
            [_lock unlock];

            // 唤醒可能在等待节点上线的线程
            dispatch_semaphore_signal(_nodeOnlineSemaphore);
            break;
        }

        case ZTS_EVENT_NODE_FATAL_ERROR: {
            // 节点发生致命错误（204）
            NSLog(@"[ZeroTierBridge] 事件：节点发生致命错误 (NODE_FATAL_ERROR)");
            [_lock lock];
            _isStarted = NO;
            _nodeStatus = ZeroTierNodeStatusError;
            _nodeID = 0;
            _hasBeenOnline = NO;
            _ownNodeIdString = nil;
            _isStackUp = NO;
            [_networkStatuses removeAllObjects];
            [_ipv4Addresses removeAllObjects];
            [_ipv6Addresses removeAllObjects];
            [_peerConnectionModes removeAllObjects];
            [_peerAddresses removeAllObjects];
            [_lock unlock];

            // 通知代理
            dispatch_async(dispatch_get_main_queue(), ^{
                if ([self.delegate respondsToSelector:@selector(zeroTierNodeFatalError)]) {
                    [self.delegate zeroTierNodeFatalError];
                }
            });

            // 唤醒等待线程
            dispatch_semaphore_signal(_nodeOnlineSemaphore);
            break;
        }

        // ===== 网络事件 =====

        case ZTS_EVENT_NETWORK_OK: {
            // 网络加入成功（213）
            uint64_t netID = [eventData[@"netID"] unsignedLongLongValue];
            NSLog(@"[ZeroTierBridge] 事件：网络加入成功 (NETWORK_OK)，netID = %016llx", netID);

            [_lock lock];
            _networkStatuses[@(netID)] = @(ZeroTierNetworkStatusJoined);
            [_lock unlock];

            // 通知代理网络已就绪
            dispatch_async(dispatch_get_main_queue(), ^{
                if ([self.delegate respondsToSelector:@selector(zeroTierNetworkReady:ipv4:ipv6:)]) {
                    NSString *ipv4 = [self ipv4AddressForNetwork:netID];
                    NSString *ipv6 = [self ipv6AddressForNetwork:netID];
                    [self.delegate zeroTierNetworkReady:netID ipv4:ipv4 ipv6:ipv6];
                }
            });

            dispatch_semaphore_signal(_networkEventSemaphore);
            break;
        }

        case ZTS_EVENT_NETWORK_ACCESS_DENIED: {
            // 网络访问被拒绝（214）
            uint64_t netID = [eventData[@"netID"] unsignedLongLongValue];
            NSLog(@"[ZeroTierBridge] 事件：网络访问被拒绝 (NETWORK_ACCESS_DENIED)，netID = %016llx", netID);

            [_lock lock];
            _networkStatuses[@(netID)] = @(ZeroTierNetworkStatusDenied);
            [_lock unlock];

            // 通知代理加入失败
            dispatch_async(dispatch_get_main_queue(), ^{
                if ([self.delegate respondsToSelector:@selector(zeroTierNetworkJoinFailed:error:)]) {
                    [self.delegate zeroTierNetworkJoinFailed:netID
                                                       error:@"网络访问被拒绝，请联系网络管理员授权此节点"];
                }
            });

            dispatch_semaphore_signal(_networkEventSemaphore);
            break;
        }

        case ZTS_EVENT_NETWORK_NOT_FOUND: {
            // 网络不存在（210）
            uint64_t netID = [eventData[@"netID"] unsignedLongLongValue];
            NSLog(@"[ZeroTierBridge] 事件：网络不存在 (NETWORK_NOT_FOUND)，netID = %016llx", netID);

            [_lock lock];
            _networkStatuses[@(netID)] = @(ZeroTierNetworkStatusNotFound);
            [_lock unlock];

            dispatch_async(dispatch_get_main_queue(), ^{
                if ([self.delegate respondsToSelector:@selector(zeroTierNetworkJoinFailed:error:)]) {
                    [self.delegate zeroTierNetworkJoinFailed:netID
                                                       error:@"网络不存在，请检查 Network ID 是否正确"];
                }
            });

            dispatch_semaphore_signal(_networkEventSemaphore);
            break;
        }

        case ZTS_EVENT_NETWORK_UPDATE: {
            // 网络配置已更新（219）
            uint64_t netID = [eventData[@"netID"] unsignedLongLongValue];
            NSLog(@"[ZeroTierBridge] 事件：网络配置已更新 (NETWORK_UPDATE)，netID = %016llx", netID);

            // 清除地址缓存，强制重新查询
            [_lock lock];
            [_ipv4Addresses removeObjectForKey:@(netID)];
            [_ipv6Addresses removeObjectForKey:@(netID)];
            [_lock unlock];

            dispatch_semaphore_signal(_networkEventSemaphore);
            break;
        }

        case ZTS_EVENT_NETWORK_READY_IP4: {
            // IPv4 网络就绪（215）
            uint64_t netID = [eventData[@"netID"] unsignedLongLongValue];
            NSLog(@"[ZeroTierBridge] 事件：IPv4 网络就绪 (NETWORK_READY_IP4)，netID = %016llx", netID);

            [_lock lock];
            [_ipv4Addresses removeObjectForKey:@(netID)];
            [_lock unlock];

            dispatch_async(dispatch_get_main_queue(), ^{
                if ([self.delegate respondsToSelector:@selector(zeroTierNetworkReady:ipv4:ipv6:)]) {
                    NSString *ipv4 = [self ipv4AddressForNetwork:netID];
                    NSString *ipv6 = [self ipv6AddressForNetwork:netID];
                    [self.delegate zeroTierNetworkReady:netID ipv4:ipv4 ipv6:ipv6];
                }
            });

            dispatch_semaphore_signal(_networkEventSemaphore);
            break;
        }

        case ZTS_EVENT_NETWORK_READY_IP6: {
            // IPv6 网络就绪（216）
            uint64_t netID = [eventData[@"netID"] unsignedLongLongValue];
            NSLog(@"[ZeroTierBridge] 事件：IPv6 网络就绪 (NETWORK_READY_IP6)，netID = %016llx", netID);

            [_lock lock];
            [_ipv6Addresses removeObjectForKey:@(netID)];
            [_lock unlock];

            dispatch_async(dispatch_get_main_queue(), ^{
                if ([self.delegate respondsToSelector:@selector(zeroTierNetworkReady:ipv4:ipv6:)]) {
                    NSString *ipv4 = [self ipv4AddressForNetwork:netID];
                    NSString *ipv6 = [self ipv6AddressForNetwork:netID];
                    [self.delegate zeroTierNetworkReady:netID ipv4:ipv4 ipv6:ipv6];
                }
            });

            dispatch_semaphore_signal(_networkEventSemaphore);
            break;
        }

        case ZTS_EVENT_NETWORK_DOWN: {
            // 网络控制器不可达（218）
            uint64_t netID = [eventData[@"netID"] unsignedLongLongValue];
            NSLog(@"[ZeroTierBridge] 事件：网络控制器不可达 (NETWORK_DOWN)，netID = %016llx", netID);

            [_lock lock];
            _networkStatuses[@(netID)] = @(ZeroTierNetworkStatusError);
            [_lock unlock];

            dispatch_semaphore_signal(_networkEventSemaphore);
            break;
        }

        case ZTS_EVENT_NETWORK_REQ_CONFIG: {
            // 网络配置请求中（212）
            uint64_t netID = [eventData[@"netID"] unsignedLongLongValue];
            NSLog(@"[ZeroTierBridge] 事件：网络配置请求中 (NETWORK_REQ_CONFIG)，netID = %016llx", netID);

            [_lock lock];
            _networkStatuses[@(netID)] = @(ZeroTierNetworkStatusRequesting);
            [_lock unlock];

            dispatch_semaphore_signal(_networkEventSemaphore);
            break;
        }

        case ZTS_EVENT_NETWORK_CLIENT_TOO_OLD: {
            // ZeroTier 客户端版本过旧（211）
            uint64_t netID = [eventData[@"netID"] unsignedLongLongValue];
            NSLog(@"[ZeroTierBridge] 事件：客户端版本过旧 (NETWORK_CLIENT_TOO_OLD)，netID = %016llx", netID);

            [_lock lock];
            _networkStatuses[@(netID)] = @(ZeroTierNetworkStatusError);
            [_lock unlock];

            dispatch_async(dispatch_get_main_queue(), ^{
                if ([self.delegate respondsToSelector:@selector(zeroTierNetworkJoinFailed:error:)]) {
                    [self.delegate zeroTierNetworkJoinFailed:netID
                                                       error:@"ZeroTier 版本过旧，请更新 zt.framework"];
                }
                if ([self.delegate respondsToSelector:@selector(zeroTierBridge:clientTooOldWithNetworkId:)]) {
                    [self.delegate zeroTierBridge:self clientTooOldWithNetworkId:netID];
                }
            });

            dispatch_semaphore_signal(_networkEventSemaphore);
            break;
        }

        // ===== 地址事件 =====

        case ZTS_EVENT_ADDR_ADDED_IP4: {
            // IPv4 地址已分配（260）
            uint64_t netID = [eventData[@"addrNetID"] unsignedLongLongValue];
            NSString *addrStr = eventData[@"addrStr"];
            int family = ZTS_AF_INET;

            if (addrStr) {
                NSLog(@"[ZeroTierBridge] 事件：IPv4 地址已分配 (ADDR_ADDED_IP4)，netID = %016llx，addr = %@", netID, addrStr);

                [_lock lock];
                _ipv4Addresses[@(netID)] = addrStr;
                [_lock unlock];

                dispatch_async(dispatch_get_main_queue(), ^{
                    if ([self.delegate respondsToSelector:@selector(zeroTierAddressAssigned:family:address:)]) {
                        [self.delegate zeroTierAddressAssigned:netID family:family address:addrStr];
                    }
                });

                dispatch_semaphore_signal(_networkEventSemaphore);
            }
            break;
        }

        case ZTS_EVENT_ADDR_ADDED_IP6: {
            // IPv6 地址已分配（262）
            uint64_t netID = [eventData[@"addrNetID"] unsignedLongLongValue];
            NSString *addrStr = eventData[@"addrStr"];
            int family = ZTS_AF_INET6;

            if (addrStr) {
                NSLog(@"[ZeroTierBridge] 事件：IPv6 地址已分配 (ADDR_ADDED_IP6)，netID = %016llx，addr = %@", netID, addrStr);

                [_lock lock];
                _ipv6Addresses[@(netID)] = addrStr;
                [_lock unlock];

                dispatch_async(dispatch_get_main_queue(), ^{
                    if ([self.delegate respondsToSelector:@selector(zeroTierAddressAssigned:family:address:)]) {
                        [self.delegate zeroTierAddressAssigned:netID family:family address:addrStr];
                    }
                });

                dispatch_semaphore_signal(_networkEventSemaphore);
            }
            break;
        }

        case ZTS_EVENT_ADDR_REMOVED_IP4: {
            // IPv4 地址已移除（261）
            uint64_t netID = [eventData[@"addrNetID"] unsignedLongLongValue];
            NSLog(@"[ZeroTierBridge] 事件：IPv4 地址已移除 (ADDR_REMOVED_IP4)，netID = %016llx", netID);
            [_lock lock];
            [_ipv4Addresses removeObjectForKey:@(netID)];
            [_lock unlock];
            dispatch_semaphore_signal(_networkEventSemaphore);
            break;
        }

        case ZTS_EVENT_ADDR_REMOVED_IP6: {
            // IPv6 地址已移除（263）
            uint64_t netID = [eventData[@"addrNetID"] unsignedLongLongValue];
            NSLog(@"[ZeroTierBridge] 事件：IPv6 地址已移除 (ADDR_REMOVED_IP6)，netID = %016llx", netID);
            [_lock lock];
            [_ipv6Addresses removeObjectForKey:@(netID)];
            [_lock unlock];
            dispatch_semaphore_signal(_networkEventSemaphore);
            break;
        }

        // ===== 对端节点事件 =====

        case ZTS_EVENT_PEER_DIRECT: {
            uint64_t peerID = [eventData[@"peerID"] unsignedLongLongValue];
            NSString *pathAddr = eventData[@"peerPathAddress"];
            NSLog(@"[ZeroTierBridge] 事件：对端直连 (PEER_DIRECT)，peerID = %016llx，path = %@",
                  peerID, pathAddr ?: @"(unknown)");

            [self setConnectionMode:ZeroTierPeerConnectionModeDirect forPeer:peerID];
            [self updatePeerAddress:peerID address:pathAddr];
            break;
        }

        case ZTS_EVENT_PEER_RELAY: {
            uint64_t peerID = [eventData[@"peerID"] unsignedLongLongValue];
            NSLog(@"[ZeroTierBridge] 事件：对端中继 (PEER_RELAY)，peerID = %016llx", peerID);
            [self setConnectionMode:ZeroTierPeerConnectionModeRelay forPeer:peerID];
            break;
        }

        case ZTS_EVENT_PEER_UNREACHABLE: {
            uint64_t peerID = [eventData[@"peerID"] unsignedLongLongValue];
            NSLog(@"[ZeroTierBridge] 事件：对端不可达 (PEER_UNREACHABLE)，peerID = %016llx", peerID);
            [self setConnectionMode:ZeroTierPeerConnectionModeUnreachable forPeer:peerID];
            break;
        }

        case ZTS_EVENT_PEER_PATH_DISCOVERED: {
            uint64_t peerID = [eventData[@"peerID"] unsignedLongLongValue];
            NSString *pathAddr = eventData[@"peerPathAddress"];
            NSLog(@"[ZeroTierBridge] 事件：对端路径发现 (PEER_PATH_DISCOVERED)，peerID = %016llx，path = %@",
                  peerID, pathAddr ?: @"(unknown)");
            [self updatePeerAddress:peerID address:pathAddr];
            break;
        }

        case ZTS_EVENT_PEER_PATH_DEAD: {
            uint64_t peerID = [eventData[@"peerID"] unsignedLongLongValue];
            NSLog(@"[ZeroTierBridge] 事件：对端路径失效 (PEER_PATH_DEAD)，peerID = %016llx", peerID);
            // 清除缓存地址
            [_lock lock];
            [_peerAddresses removeObjectForKey:@(peerID)];
            [_lock unlock];
            break;
        }

        // ===== 其他事件 =====

        case ZTS_EVENT_STACK_UP: {
            NSLog(@"[ZeroTierBridge] 事件：TCP/IP 栈已启动 (STACK_UP)");
            [_lock lock];
            _isStackUp = YES;
            [_lock unlock];
            dispatch_async(dispatch_get_main_queue(), ^{
                if ([self.delegate respondsToSelector:@selector(zeroTierBridge:stackDidGoUp:)]) {
                    [self.delegate zeroTierBridge:self stackDidGoUp:YES];
                }
            });
            break;
        }

        case ZTS_EVENT_STACK_DOWN: {
            NSLog(@"[ZeroTierBridge] 事件：TCP/IP 栈已停止 (STACK_DOWN)");
            [_lock lock];
            _isStackUp = NO;
            [_lock unlock];
            dispatch_async(dispatch_get_main_queue(), ^{
                if ([self.delegate respondsToSelector:@selector(zeroTierBridge:stackDidGoUp:)]) {
                    [self.delegate zeroTierBridge:self stackDidGoUp:NO];
                }
            });
            break;
        }

        case ZTS_EVENT_NETIF_UP:
            NSLog(@"[ZeroTierBridge] 事件：网络接口已启用 (NETIF_UP)");
            break;

        case ZTS_EVENT_NETIF_DOWN:
            NSLog(@"[ZeroTierBridge] 事件：网络接口已禁用 (NETIF_DOWN)");
            break;

        case ZTS_EVENT_NETIF_REMOVED:
            NSLog(@"[ZeroTierBridge] 事件：网络接口已移除 (NETIF_REMOVED)");
            break;

        case ZTS_EVENT_NETIF_LINK_UP:
            NSLog(@"[ZeroTierBridge] 事件：网络接口链路已启用 (NETIF_LINK_UP)");
            break;

        case ZTS_EVENT_NETIF_LINK_DOWN:
            NSLog(@"[ZeroTierBridge] 事件：网络接口链路已禁用 (NETIF_LINK_DOWN)");
            break;

        case ZTS_EVENT_ROUTE_ADDED:
            NSLog(@"[ZeroTierBridge] 事件：路由已添加 (ROUTE_ADDED)");
            break;

        case ZTS_EVENT_ROUTE_REMOVED:
            NSLog(@"[ZeroTierBridge] 事件：路由已移除 (ROUTE_REMOVED)");
            break;

        case ZTS_EVENT_STORE_IDENTITY_SECRET:
            NSLog(@"[ZeroTierBridge] 事件：节点私钥已生成/更新 (STORE_IDENTITY_SECRET)");
            break;

        case ZTS_EVENT_STORE_IDENTITY_PUBLIC:
            NSLog(@"[ZeroTierBridge] 事件：节点公钥已生成/更新 (STORE_IDENTITY_PUBLIC)");
            break;

        case ZTS_EVENT_STORE_PLANET:
            NSLog(@"[ZeroTierBridge] 事件：Planet 配置已更新 (STORE_PLANET)");
            break;

        case ZTS_EVENT_STORE_PEER:
            NSLog(@"[ZeroTierBridge] 事件：Peer 配置已更新 (STORE_PEER)");
            break;

        case ZTS_EVENT_STORE_NETWORK:
            NSLog(@"[ZeroTierBridge] 事件：Network 配置已更新 (STORE_NETWORK)");
            break;

        default:
            NSLog(@"[ZeroTierBridge] 未处理的事件：event_code = %d", eventCode);
            break;
    }
}

#pragma mark - 内部辅助方法

/// 更新指定 peer 的连接模式并通知 delegate
/// @param mode 新的连接模式
/// @param peerID 对端节点 ID
- (void)setConnectionMode:(ZeroTierPeerConnectionMode)mode forPeer:(uint64_t)peerID {
    NSNumber *key = @(peerID);
    ZeroTierPeerConnectionMode oldMode = ZeroTierPeerConnectionModeUnknown;

    [_lock lock];
    NSNumber *old = _peerConnectionModes[key];
    if (old) {
        oldMode = (ZeroTierPeerConnectionMode)[old integerValue];
    }
    if (oldMode != mode) {
        _peerConnectionModes[key] = @(mode);
        [_lock unlock];

        dispatch_async(dispatch_get_main_queue(), ^{
            if ([self.delegate respondsToSelector:@selector(zeroTierPeerConnectionModeChanged:forPeer:)]) {
                [self.delegate zeroTierPeerConnectionModeChanged:mode forPeer:peerID];
            }
        });
    } else {
        [_lock unlock];
    }
}

/// 更新指定 peer 的路径地址并通知 delegate
/// @param peerId 对端节点 ID
/// @param address 路径地址字符串（可能为 nil）
- (void)updatePeerAddress:(uint64_t)peerId address:(nullable NSString *)address {
    NSNumber *key = @(peerId);

    if (!address || address.length == 0) {
        [_lock lock];
        [_peerAddresses removeObjectForKey:key];
        [_lock unlock];
        return;
    }

    [_lock lock];
    NSString *old = _peerAddresses[key];
    if (![old isEqualToString:address]) {
        _peerAddresses[key] = address;
        [_lock unlock];

        dispatch_async(dispatch_get_main_queue(), ^{
            if ([self.delegate respondsToSelector:@selector(zeroTierBridge:peer:didUpdateAddress:)]) {
                [self.delegate zeroTierBridge:self peer:peerId didUpdateAddress:address];
            }
        });
    } else {
        [_lock unlock];
    }
}

#pragma mark - 重连逻辑

/// 启动重连定时器
///
/// 使用指数退避策略：2s、4s、8s、16s、30s（之后保持30s）
/// 若应用在后台，延迟加倍
- (void)startReconnectTimer {
    // 先停止旧定时器
    [self stopReconnectTimer];

    // 检查条件
    if (!_isStarted || _isReconnecting) {
        return;
    }

    // 计算延迟
    NSInteger delay = MIN(kMaxReconnectDelay, 2 * (NSInteger)pow(2, _reconnectAttempts));
    if (_applicationInBackground) {
        delay = (NSInteger)(delay * kBackgroundReconnectMultiplier);
    }
    _reconnectAttempts++;
    _isReconnecting = YES;

    NSLog(@"[ZeroTierBridge] 启动重连定时器，延迟 %.1f 秒（尝试 %ld 次）",
          (double)delay, (long)_reconnectAttempts);

    dispatch_async(dispatch_get_main_queue(), ^{
        _reconnectTimer = [NSTimer scheduledTimerWithTimeInterval:delay
                                                           target:self
                                                         selector:@selector(handleReconnectTimeout)
                                                         userInfo:nil
                                                          repeats:NO];
    });
}

/// 停止重连定时器
- (void)stopReconnectTimer {
    dispatch_async(dispatch_get_main_queue(), ^{
        if (_reconnectTimer) {
            [_reconnectTimer invalidate];
            _reconnectTimer = nil;
            NSLog(@"[ZeroTierBridge] 重连定时器已停止");
        }
    });
    _isReconnecting = NO;
}

/// 重连超时处理
- (void)handleReconnectTimeout {
    // 检查节点是否已恢复
    if (!_isStarted || [self isNodeOnline]) {
        _isReconnecting = NO;
        NSLog(@"[ZeroTierBridge] 重连成功：节点已在线");
        return;
    }

    // 检查 libzt 内部状态（可能 _isStarted 为 NO 但 zts_node_is_online 为 1）
    if (zts_node_is_online()) {
        NSLog(@"[ZeroTierBridge] 重连检测到 zts_node_is_online=1，尝试恢复状态");
        [_lock lock];
        _nodeStatus = ZeroTierNodeStatusOnline;
        _hasBeenOnline = YES;
        [_lock unlock];
        _isReconnecting = NO;
        _reconnectAttempts = 0;
        [self stopReconnectTimer];

        dispatch_async(dispatch_get_main_queue(), ^{
            if ([self.delegate respondsToSelector:@selector(zeroTierBridgeDidGoOnline:)]) {
                [self.delegate zeroTierBridgeDidGoOnline:_ownNodeIdString];
            }
        });
        return;
    }

    // 检查重连次数
    if (_reconnectAttempts > kMaxReconnectAttempts) {
        NSLog(@"[ZeroTierBridge] 重连尝试次数过多（%ld），重置节点", (long)_reconnectAttempts);
        [self resetNode];
        return;
    }

    // 继续尝试
    [self startReconnectTimer];
}

/// 重置节点（停止并重新启动）
- (void)resetNode {
    NSLog(@"[ZeroTierBridge] 重置节点...");
    [self stopNode];
    if (_homeDirectory) {
        NSLog(@"[ZeroTierBridge] 重新启动节点");
        [self startNodeWithHomeDirectory:_homeDirectory error:nil];
    } else {
        NSLog(@"[ZeroTierBridge] homeDirectory 为空，无法重启节点");
    }
}

#pragma mark - Keychain 备份与恢复

/// 备份 ZeroTier 身份文件到 Keychain
///
/// 在节点上线后（NODE_ONLINE 事件）调用。此时 libzt 已经在 homeDir 中
/// 生成了 identity.secret 和 identity.public 文件。
/// 将这些文件的内容读取并存储到 Keychain，以便删除应用后恢复。
- (void)backupIdentityToKeychain {
    NSString *homeDir = nil;
    [_lock lock];
    homeDir = [_homeDirectory copy];
    [_lock unlock];

    if (!homeDir.length) {
        NSLog(@"[ZeroTierBridge] backupIdentityToKeychain：homeDir 为空，跳过备份");
        return;
    }

    NSFileManager *fm = [NSFileManager defaultManager];
    NSArray<NSString *> *identityFiles = @[@"identity.secret", @"identity.public"];

    for (NSString *fileName in identityFiles) {
        NSString *filePath = [homeDir stringByAppendingPathComponent:fileName];
        if ([fm fileExistsAtPath:filePath]) {
            NSData *data = [NSData dataWithContentsOfFile:filePath];
            if (data && data.length > 0) {
                [self setKeychainData:data forKey:fileName];
                NSLog(@"[ZeroTierBridge] 身份文件 %@ 已备份到 Keychain（%lu 字节）",
                      fileName, (unsigned long)data.length);
            }
        }
    }
}

/// 从 Keychain 恢复 ZeroTier 身份文件到 homeDir
///
/// 在 startNodeWithHomeDirectory: 中、zts_init_from_storage 调用前执行。
/// 检查 homeDir 中是否已有身份文件，如果没有则从 Keychain 恢复。
/// 这样删除应用重新安装后，仍能使用原来的节点身份。
- (void)restoreIdentityFromKeychainToHomeDir:(NSString *)homeDir {
    if (!homeDir || homeDir.length == 0) return;

    NSFileManager *fm = [NSFileManager defaultManager];

    // 确保 homeDir 存在
    if (![fm fileExistsAtPath:homeDir]) {
        [fm createDirectoryAtPath:homeDir withIntermediateDirectories:YES attributes:nil error:nil];
        NSLog(@"[ZeroTierBridge] 创建 homeDir：%@", homeDir);
    }

    // 检查 identity.secret 是否已存在
    NSString *secretPath = [homeDir stringByAppendingPathComponent:@"identity.secret"];
    if ([fm fileExistsAtPath:secretPath]) {
        NSLog(@"[ZeroTierBridge] identity.secret 已存在，无需恢复");
        return;
    }

    // 从 Keychain 恢复身份文件
    NSLog(@"[ZeroTierBridge] zerotier_home 中未找到身份文件，尝试从 Keychain 恢复...");
    BOOL restored = NO;

    NSData *secretData = [self loadKeychainDataForKey:kKeychainSecretKey];
    if (secretData) {
        [secretData writeToFile:secretPath atomically:YES];
        NSLog(@"[ZeroTierBridge] 身份文件 identity.secret 已从 Keychain 恢复（%lu 字节）",
              (unsigned long)secretData.length);
        restored = YES;
    } else {
        NSLog(@"[ZeroTierBridge] Keychain 中未找到 identity.secret");
    }

    NSString *publicPath = [homeDir stringByAppendingPathComponent:@"identity.public"];
    NSData *publicData = [self loadKeychainDataForKey:kKeychainPublicKey];
    if (publicData) {
        [publicData writeToFile:publicPath atomically:YES];
        NSLog(@"[ZeroTierBridge] 身份文件 identity.public 已从 Keychain 恢复（%lu 字节）",
              (unsigned long)publicData.length);
        restored = YES;
    } else {
        NSLog(@"[ZeroTierBridge] Keychain 中未找到 identity.public");
    }

    if (restored) {
        NSLog(@"[ZeroTierBridge] 身份文件恢复完成，节点将使用原有身份（无需重新授权）");
    } else {
        NSLog(@"[ZeroTierBridge] Keychain 中未找到备份的身份文件，将生成新身份");
    }
}

/// 从 Keychain 读取数据
+ (nullable NSData *)keychainDataForKey:(NSString *)key {
    NSDictionary *query = @{
        (__bridge id)kSecClass: (__bridge id)kSecClassGenericPassword,
        (__bridge id)kSecAttrService: kKeychainService,
        (__bridge id)kSecAttrAccount: key,
        (__bridge id)kSecReturnData: @YES,
        (__bridge id)kSecMatchLimit: (__bridge id)kSecMatchLimitOne,
    };
    CFTypeRef result = NULL;
    OSStatus status = SecItemCopyMatching((__bridge CFDictionaryRef)query, &result);
    if (status == errSecSuccess && result) {
        return (__bridge_transfer NSData *)result;
    }
    return nil;
}

/// 向 Keychain 写入数据
+ (void)setKeychainData:(NSData *)data forKey:(NSString *)key {
    // 先删除旧数据
    NSDictionary *deleteQuery = @{
        (__bridge id)kSecClass: (__bridge id)kSecClassGenericPassword,
        (__bridge id)kSecAttrService: kKeychainService,
        (__bridge id)kSecAttrAccount: key,
    };
    SecItemDelete((__bridge CFDictionaryRef)deleteQuery);

    // 写入新数据
    NSDictionary *addQuery = @{
        (__bridge id)kSecClass: (__bridge id)kSecClassGenericPassword,
        (__bridge id)kSecAttrService: kKeychainService,
        (__bridge id)kSecAttrAccount: key,
        (__bridge id)kSecValueData: data,
        (__bridge id)kSecAttrAccessible: (__bridge id)kSecAttrAccessibleAfterFirstUnlock,
    };
    OSStatus status = SecItemAdd((__bridge CFDictionaryRef)addQuery, NULL);
    if (status != errSecSuccess) {
        NSLog(@"[ZeroTierBridge] Keychain 写入失败：key=%@, status=%d", key, (int)status);
    }
}

/// 保存 identity.secret 到 Keychain
- (void)saveIdentitySecretToKeychain:(NSString *)secret {
    if (secret.length == 0) return;
    NSData *data = [secret dataUsingEncoding:NSUTF8StringEncoding];
    [self setKeychainData:data forKey:kKeychainSecretKey];
}

/// 保存 identity.public 到 Keychain
- (void)saveIdentityPublicToKeychain:(NSString *)publicKey {
    if (publicKey.length == 0) return;
    NSData *data = [publicKey dataUsingEncoding:NSUTF8StringEncoding];
    [self setKeychainData:data forKey:kKeychainPublicKey];
}

#pragma mark - 对端信息查询

/// 查询指定 peer 当前的连接模式
/// @param peerID 对端节点 ID
/// @return 连接模式枚举值（无信息时返回 Unknown）
- (ZeroTierPeerConnectionMode)peerConnectionModeForPeer:(uint64_t)peerID {
    [_lock lock];
    NSNumber *mode = _peerConnectionModes[@(peerID)];
    [_lock unlock];
    return mode ? (ZeroTierPeerConnectionMode)[mode integerValue] : ZeroTierPeerConnectionModeUnknown;
}

/// 查询指定 peer 的路径地址
/// @param peerID 对端节点 ID
/// @return 路径地址字符串（无信息时返回 nil）
- (nullable NSString *)peerAddressForPeer:(uint64_t)peerID {
    [_lock lock];
    NSString *addr = _peerAddresses[@(peerID)];
    [_lock unlock];
    return addr;
}

#pragma mark - 网络详情查询

/// 获取网络名称
/// @param networkID ZeroTier Network ID（64 位无符号整数）
/// @return 网络名称（不可用返回 nil）
- (nullable NSString *)networkNameForNetwork:(uint64_t)networkID {
    char nameBuf[ZTS_MAX_NETWORK_SHORT_NAME_LENGTH + 1] = {0};
    int result = zts_net_get_name(networkID, nameBuf, sizeof(nameBuf));
    if (result == ZTS_ERR_OK && nameBuf[0] != '\0') {
        return [NSString stringWithUTF8String:nameBuf];
    }
    return nil;
}

/// 获取网络 MTU
/// @param networkID ZeroTier Network ID（64 位无符号整数）
/// @return MTU 值（不可用返回 0）
- (int)networkMTUForNetwork:(uint64_t)networkID {
    int mtu = zts_net_get_mtu(networkID);
    if (mtu > 0) {
        return mtu;
    }
    return 0;
}

/// 获取网络类型
/// @param networkID ZeroTier Network ID（64 位无符号整数）
/// @return 网络类型（0=private，1=public；未知时返回 0）
- (int)networkTypeForNetwork:(uint64_t)networkID {
    int type = zts_net_get_type(networkID);
    if (type == ZTS_NETWORK_TYPE_PUBLIC) {
        return 1;
    }
    if (type == ZTS_NETWORK_TYPE_PRIVATE) {
        return 0;
    }
    return 0;
}

/// 获取本节点在该网络中的 MAC 地址
/// @param networkID ZeroTier Network ID（64 位无符号整数）
/// @return MAC 地址（不可用返回 0）
- (uint64_t)macAddressForNetwork:(uint64_t)networkID {
    uint64_t mac = zts_net_get_mac(networkID);
    if (mac != 0) {
        return mac;
    }
    return 0;
}

#pragma mark - 工具方法

/// 从十六进制字符串解析网络 ID
///
/// ZeroTier 网络 ID 通常以 16 位十六进制字符串表示（如 "a84ac5c10a1b2c3d"），
/// 本方法使用 strtoull 将其转换为 uint64_t。
///
/// @param networkIDStr 十六进制字符串
/// @return 网络 ID（解析失败返回 0）
+ (uint64_t)parseNetworkIDFromString:(NSString *)networkIDStr {
    if (!networkIDStr || networkIDStr.length == 0) {
        NSLog(@"[ZeroTierBridge] parseNetworkIDFromString 错误：输入字符串为空");
        return 0;
    }

    uint64_t networkID = strtoull([networkIDStr UTF8String], NULL, 16);
    NSLog(@"[ZeroTierBridge] 解析网络 ID：'%@' → %016llx", networkIDStr, networkID);
    return networkID;
}

/// 将网络 ID 格式化为十六进制字符串
///
/// 使用 %016llx 格式化为 16 位小写十六进制字符串，不足位补零。
///
/// @param networkID 网络 ID
/// @return 16 位十六进制字符串（如 "a84ac5c10a1b2c3d"）
+ (NSString *)formatNetworkID:(uint64_t)networkID {
    return [NSString stringWithFormat:@"%016llx", networkID];
}

#pragma mark - Socket 操作

/// 创建 TCP socket（封装 zts_bsd_socket）
///
/// 创建一个基于 ZeroTier 虚拟网络的 IPv4 TCP socket。
///
/// @return socket 文件描述符（≥ 0 表示成功，< 0 表示失败）
- (int)createTCPSocket {
    return [self createTCPSocketForFamily:ZTS_AF_INET];
}

/// 创建 TCP socket（指定地址族）
///
/// 用于 Ad-hoc 网络等只有 IPv6 的场景。
/// - ZTS_AF_INET（IPv4）：标准 ZeroTier 网络
/// - ZTS_AF_INET6（IPv6）：Ad-hoc 网络（只有 IPv6 地址）
///
/// @param family 地址族（ZTS_AF_INET 或 ZTS_AF_INET6）
/// @return socket 文件描述符（≥ 0 表示成功，< 0 表示失败）
- (int)createTCPSocketForFamily:(int)family {
    int fd = zts_bsd_socket(family, ZTS_SOCK_STREAM, ZTS_IPPROTO_TCP);
    if (fd < 0) {
        NSLog(@"[ZeroTierBridge] 创建 ZeroTier socket(family=%d) 失败：fd=%d, zts_errno=%d",
              family, fd, zts_errno);
    } else {
        NSLog(@"[ZeroTierBridge] 创建 ZeroTier socket(family=%d) 成功：fd=%d", family, fd);

        // 设置 TCP_NODELAY（禁用 Nagle 算法，降低延迟）
        int nodelay = 1;
        zts_bsd_setsockopt(fd, ZTS_IPPROTO_TCP, ZTS_TCP_NODELAY, &nodelay, sizeof(nodelay));

        // 设置 SO_KEEPALIVE（保持连接活跃）
        int keepalive = 1;
        zts_bsd_setsockopt(fd, ZTS_SOL_SOCKET, ZTS_SO_KEEPALIVE, &keepalive, sizeof(keepalive));
    }
    return fd;
}

/// 连接 socket 到目标主机
///
/// 封装 zts_bsd_connect，支持 IPv4 和 IPv6。
///
/// 关键修复（C3）：使用非阻塞 socket + select 实现真正的 connect 超时。
///
/// @param fd socket 文件描述符
/// @param host 目标主机 IP 地址字符串
/// @param port 目标端口
/// @param timeout 连接超时时间（秒）
/// @return 0 表示成功，< 0 表示失败
- (int)connectSocket:(int)fd
              toHost:(NSString *)host
                port:(uint16_t)port
             timeout:(NSTimeInterval)timeout {
    // ============================================================
    // 1. 参数校验
    // ============================================================
    if (!host || host.length == 0 || fd < 0) {
        NSLog(@"[ZeroTierBridge] connectSocket 参数无效：fd=%d, host=%@", fd, host);
        return ZTS_ERR_ARG;
    }
    NSLog(@"[ZeroTierBridge] 连接 socket：fd=%d, host=%@, port=%u, timeout=%.1f",
          fd, host, port, timeout);

    const char *hostCStr = [host UTF8String];

    // ============================================================
    // 2. 设置 recv/send 超时（影响后续的数据传输，不影响 connect）
    // ============================================================
    if (timeout > 0) {
        struct zts_timeval tv;
        tv.tv_sec = (long)timeout;
        tv.tv_usec = (long)((timeout - (NSTimeInterval)tv.tv_sec) * 1000000);
        if (tv.tv_usec < 0) {
            tv.tv_usec = 0;
        }

        int rc = zts_bsd_setsockopt(fd, ZTS_SOL_SOCKET, ZTS_SO_RCVTIMEO, &tv, sizeof(tv));
        if (rc != ZTS_ERR_OK) {
            NSLog(@"[ZeroTierBridge] 设置 SO_RCVTIMEO 失败：%d", rc);
        }
        rc = zts_bsd_setsockopt(fd, ZTS_SOL_SOCKET, ZTS_SO_SNDTIMEO, &tv, sizeof(tv));
        if (rc != ZTS_ERR_OK) {
            NSLog(@"[ZeroTierBridge] 设置 SO_SNDTIMEO 失败：%d", rc);
        }
    }

    // ============================================================
    // 3. 检测目标地址类型
    // ============================================================
    BOOL isIPv6 = (zts_inet_pton(ZTS_AF_INET6, hostCStr, NULL) == 1);
    NSLog(@"[ZeroTierBridge] 地址类型：%@", isIPv6 ? @"IPv6" : @"IPv4");

    // ============================================================
    // 4. 准备目标地址结构
    // ============================================================
    struct zts_sockaddr_storage addrStorage;
    memset(&addrStorage, 0, sizeof(addrStorage));
    socklen_t addrLen = 0;

    if (isIPv6) {
        struct zts_sockaddr_in6 *addr6 = (struct zts_sockaddr_in6 *)&addrStorage;
        addr6->sin6_len = sizeof(struct zts_sockaddr_in6);
        addr6->sin6_family = ZTS_AF_INET6;
        addr6->sin6_port = htons(port);

        int ptonResult = zts_inet_pton(ZTS_AF_INET6, hostCStr, &addr6->sin6_addr);
        if (ptonResult != 1) {
            NSLog(@"[ZeroTierBridge] zts_inet_pton(IPv6) 失败：result=%d, host=%@", ptonResult, host);
            return ZTS_ERR_ARG;
        }
        addrLen = sizeof(struct zts_sockaddr_in6);
    } else {
        struct zts_sockaddr_in *addr = (struct zts_sockaddr_in *)&addrStorage;
        addr->sin_len = sizeof(struct zts_sockaddr_in);
        addr->sin_family = ZTS_AF_INET;
        addr->sin_port = htons(port);

        int ptonResult = zts_inet_pton(ZTS_AF_INET, hostCStr, &addr->sin_addr);
        if (ptonResult != 1) {
            NSLog(@"[ZeroTierBridge] zts_inet_pton(IPv4) 失败：result=%d, host=%@", ptonResult, host);
            return ZTS_ERR_ARG;
        }
        addrLen = sizeof(struct zts_sockaddr_in);
    }

    // ============================================================
    // 5. 非阻塞 connect + select 实现超时
    // ============================================================
    int origFlags = zts_bsd_fcntl(fd, ZTS_F_GETFL, 0);
    if (origFlags < 0) {
        NSLog(@"[ZeroTierBridge] zts_bsd_fcntl(F_GETFL) 失败，回退到阻塞模式");
        int result = zts_bsd_connect(fd, (const struct zts_sockaddr *)&addrStorage, addrLen);
        if (result != ZTS_ERR_OK) {
            NSLog(@"[ZeroTierBridge] 阻塞模式连接失败：%d", result);
        } else {
            NSLog(@"[ZeroTierBridge] 阻塞模式连接成功");
        }
        return result;
    }

    // 设置为非阻塞
    zts_bsd_fcntl(fd, ZTS_F_SETFL, origFlags | ZTS_O_NONBLOCK);

    int connectResult = zts_bsd_connect(fd, (const struct zts_sockaddr *)&addrStorage, addrLen);
    if (connectResult == ZTS_ERR_OK) {
        NSLog(@"[ZeroTierBridge] 连接立即成功");
        zts_bsd_fcntl(fd, ZTS_F_SETFL, origFlags);
        return ZTS_ERR_OK;
    }

    // 检查是否是 EINPROGRESS（非阻塞 connect 的预期返回）
    if (zts_errno != ZTS_EINPROGRESS) {
        NSLog(@"[ZeroTierBridge] 非阻塞连接失败：zts_errno=%d", zts_errno);
        zts_bsd_fcntl(fd, ZTS_F_SETFL, origFlags);
        return connectResult;
    }

    // 使用 select 等待连接完成
    zts_fd_set writeFds;
    ZTS_FD_ZERO(&writeFds);
    ZTS_FD_SET(fd, &writeFds);

    struct zts_timeval selectTimeout;
    selectTimeout.tv_sec = (long)timeout;
    selectTimeout.tv_usec = (long)((timeout - (NSTimeInterval)selectTimeout.tv_sec) * 1000000);
    if (selectTimeout.tv_usec < 0) {
        selectTimeout.tv_usec = 0;
    }

    int selectResult = zts_bsd_select(fd + 1, NULL, &writeFds, NULL, &selectTimeout);

    // 恢复原始阻塞模式
    zts_bsd_fcntl(fd, ZTS_F_SETFL, origFlags);

    if (selectResult < 0) {
        NSLog(@"[ZeroTierBridge] select 错误：zts_errno=%d", zts_errno);
        return ZTS_ERR_SOCKET;
    }

    if (selectResult == 0) {
        NSLog(@"[ZeroTierBridge] 连接超时（%.1f 秒）：%@:%u", timeout, host, port);
        return ZTS_ERR_SOCKET;
    }

    // 检查连接结果（通过 SO_ERROR）
    int socketError = 0;
    socklen_t errorLen = sizeof(socketError);
    int sockoptResult = zts_bsd_getsockopt(fd, ZTS_SOL_SOCKET, ZTS_SO_ERROR, &socketError, &errorLen);
    if (sockoptResult != ZTS_ERR_OK) {
        NSLog(@"[ZeroTierBridge] getsockopt(SO_ERROR) 失败：%d", zts_errno);
        return ZTS_ERR_SOCKET;
    }

    if (socketError != 0) {
        NSLog(@"[ZeroTierBridge] 连接失败：SO_ERROR=%d, host=%@, port=%u", socketError, host, port);
        return ZTS_ERR_SOCKET;
    }

    NSLog(@"[ZeroTierBridge] 连接成功（非阻塞+select）");
    return ZTS_ERR_OK;
}

/// 关闭 socket（封装 zts_bsd_close）
/// @param fd socket 文件描述符
/// @return 0 表示成功，< 0 表示失败
- (int)closeSocket:(int)fd {
    if (fd < 0) return ZTS_ERR_ARG;
    int result = zts_bsd_close(fd);
    if (result != ZTS_ERR_OK) {
        NSLog(@"[ZeroTierBridge] zts_bsd_close 失败：result=%d, zts_errno=%d", result, zts_errno);
    } else {
        NSLog(@"[ZeroTierBridge] 关闭 socket：fd=%d", fd);
    }
    return result;
}

/// 关闭 socket 的读/写端（封装 zts_bsd_shutdown）
///
/// 关键修复（M12）：SOCKS5Proxy.stop 调用此方法 shutdown 远程 fd，
/// 强制阻塞在 recvData: 上的客户端线程立即返回，避免线程泄漏。
- (int)shutdownSocket:(int)fd how:(int)how {
    if (fd < 0) return ZTS_ERR_ARG;
    int result = zts_bsd_shutdown(fd, how);
    if (result != ZTS_ERR_OK) {
        NSLog(@"[ZeroTierBridge] zts_bsd_shutdown 失败：result=%d, zts_errno=%d", result, zts_errno);
    } else {
        NSLog(@"[ZeroTierBridge] shutdown socket：fd=%d, how=%d", fd, how);
    }
    return result;
}

/// 发送数据（封装 zts_bsd_send）
/// @param fd socket 文件描述符
/// @param buf 发送缓冲区
/// @param len 缓冲区长度
/// @return 实际发送的字节数（< 0 表示失败）
- (ssize_t)sendData:(int)fd
             buffer:(const void *)buf
              length:(size_t)len {
    if (fd < 0 || !buf || len == 0) return ZTS_ERR_ARG;
    ssize_t sent = zts_bsd_send(fd, buf, len, 0);
    if (sent < 0) {
        NSLog(@"[ZeroTierBridge] zts_bsd_send 失败：sent=%zd, zts_errno=%d", sent, zts_errno);
    }
    return sent;
}

/// 接收数据（封装 zts_bsd_recv）
/// @param fd socket 文件描述符
/// @param buf 接收缓冲区
/// @param len 缓冲区长度
/// @return 实际接收的字节数（< 0 表示失败，0 表示连接已关闭）
- (ssize_t)recvData:(int)fd
             buffer:(void *)buf
              length:(size_t)len {
    if (fd < 0 || !buf || len == 0) return ZTS_ERR_ARG;
    ssize_t received = zts_bsd_recv(fd, buf, len, 0);
    if (received < 0) {
        NSLog(@"[ZeroTierBridge] zts_bsd_recv 失败：received=%zd, zts_errno=%d", received, zts_errno);
    }
    return received;
}

@end