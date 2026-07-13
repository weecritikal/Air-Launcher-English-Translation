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
//
//  事件处理映射表（ZeroTierSockets.h 中的事件码）：
//    ZTS_EVENT_NODE_ONLINE          (201) → delegate zeroTierNodeOnlineWithID:
//    ZTS_EVENT_NODE_OFFLINE         (202) → delegate zeroTierNodeOffline
//    ZTS_EVENT_NETWORK_OK           (213) → 更新网络状态 + delegate zeroTierNetworkReady:
//    ZTS_EVENT_NETWORK_ACCESS_DENIED(214) → delegate zeroTierNetworkJoinFailed:error:
//    ZTS_EVENT_NETWORK_NOT_FOUND    (210) → delegate zeroTierNetworkJoinFailed:error:
//    ZTS_EVENT_ADDR_ADDED_IP4       (260) → delegate zeroTierAddressAssigned:family:address:
//    ZTS_EVENT_ADDR_ADDED_IP6       (262) → delegate zeroTierAddressAssigned:family:address:
//
//  ============================================================================

#import "ZeroTierBridge.h"
#import "utils.h"

// 标准 C 头文件
#include <string.h>
#include <stdlib.h>
#include <arpa/inet.h>

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

    /// 线程锁，保护所有内部状态变量
    NSLock *_lock;
}

/// 处理 ZeroTier 事件回调（由 zeroTierEventCallback 在主线程调用）
/// @param eventData 从事件消息中提取的数据（eventCode/nodeID/netID/addrStr 等）
- (void)handleEventData:(NSDictionary *)eventData;

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
        _nodeStatus = ZeroTierNodeStatusStopped;
        _networkStatuses = [[NSMutableDictionary alloc] init];
        _ipv4Addresses = [[NSMutableDictionary alloc] init];
        _ipv6Addresses = [[NSMutableDictionary alloc] init];
        _isStarted = NO;
        _frameworkAvailable = NO;
        _frameworkChecked = NO;
        _nodeID = 0;
        _hasBeenOnline = NO;
        _homeDirectory = nil;
        _lock = [[NSLock alloc] init];

        NSLog(@"[ZeroTierBridge] 单例已初始化");
    }
    return self;
}

#pragma mark - 框架检测

/// 检测 zt.framework 是否可用（非 stub）
///
/// 检测原理：
///   - stub 实现（zt_stub.c）中，zts_node_start() 固定返回 ZTS_ERR_SERVICE (-2)
///   - 真实 framework 中，zts_node_start() 会返回 ZTS_ERR_OK (0) 并启动节点
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

    // 检测原理：
    //   - stub 实现（zt_stub.c）中，zts_node_start() 固定返回 ZTS_ERR_SERVICE (-2)
    //   - 真实 framework 中，zts_node_start() 会返回 ZTS_ERR_OK (0) 并启动节点
    //
    // 重要修复（闪退问题）：
    //   之前的实现调用 zts_node_start() 检测后立即调用 zts_node_stop() 停止节点。
    //   但 zts_node_stop() 是异步的，会立即返回 ZTS_ERR_SERVICE(-2) 但节点并未真正停止，
    //   导致后续 zts_init_from_storage 失败（返回 -2），节点启动失败，打开联机开关闪退。
    //
    // 新方案：不调用任何有副作用的 API（zts_node_start/zts_node_stop），
    //   只调用无副作用的 zts_node_is_online() 验证符号存在：
    //   - stub 返回 0
    //   - 真实库（节点未启动）也返回 0
    //   - 真实库（节点已启动）返回 1
    //   这个调用本身不会崩溃，仅用于验证符号存在。
    //
    //   然后直接信任编译时链接结果：如果 zt.framework 二进制存在，
    //   CMakeLists.txt 的 if(EXISTS) 检测通过，链接真实库；否则链接 stub。
    //   如果链接的是 stub，startNodeWithHomeDirectory: 会在 zts_init_from_storage
    //   时返回错误，由调用方处理。这样避免了"启动后停止"导致的节点状态混乱和闪退。
    int onlineCheck = zts_node_is_online();
    NSLog(@"[ZeroTierBridge] 检测：zts_node_is_online() = %d（无副作用调用，仅验证符号）", onlineCheck);

    // 信任编译时链接结果，直接返回 YES
    BOOL frameworkAvailable = YES;

    [_lock lock];
    _frameworkAvailable = frameworkAvailable;
    _frameworkChecked = YES;
    // 不在此处设置 _isStarted=YES，让 startNodeWithHomeDirectory: 完整初始化
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
///   4. 调用 zts_init_from_storage 设置存储目录
///   5. 调用 zts_init_set_event_handler 设置事件回调
///   6. 调用 zts_node_start 启动节点
- (BOOL)startNodeWithHomeDirectory:(NSString *)homeDir
                             error:(NSError **)error {
    // 参数校验
    if (!homeDir || homeDir.length == 0) {
        NSLog(@"[ZeroTierBridge] startNode 失败：homeDir 为空");
        if (error) {
            *error = [NSError errorWithDomain:kZeroTierErrorDomain
                                          code:ZeroTierErrorCodeInvalidArgument
                                      userInfo:@{NSLocalizedDescriptionKey: @"主页目录路径无效"}];
        }
        return NO;
    }

    // 检测 framework 是否可用
    if (![self isFrameworkAvailable]) {
        NSLog(@"[ZeroTierBridge] startNode 失败：framework 不可用（stub 模式）");
        if (error) {
            *error = [NSError errorWithDomain:kZeroTierErrorDomain
                                          code:ZeroTierErrorCodeFrameworkUnavailable
                                      userInfo:@{NSLocalizedDescriptionKey: @"ZeroTier framework 不可用（stub 模式），请集成真实的 zt.framework"}];
        }
        return NO;
    }

    // 检查是否已启动
    [_lock lock];
    if (_isStarted) {
        [_lock unlock];
        NSLog(@"[ZeroTierBridge] 节点已启动，跳过重复启动");
        return YES;
    }
    [_lock unlock];

    NSLog(@"[ZeroTierBridge] 启动节点，homeDir = %@", homeDir);

    // 步骤 1：初始化存储路径
    // zts_init_from_storage 指定身份文件的存储目录，
    // 节点会在此目录下读写 authtoken.secret、identity.public、identity.secret 等文件
    int result = zts_init_from_storage([homeDir UTF8String]);
    if (result != ZTS_ERR_OK) {
        NSLog(@"[ZeroTierBridge] zts_init_from_storage 失败：result = %d", result);
        if (error) {
            *error = [NSError errorWithDomain:kZeroTierErrorDomain
                                          code:ZeroTierErrorCodeNodeStartFailed
                                      userInfo:@{NSLocalizedDescriptionKey: [NSString stringWithFormat:@"初始化存储目录失败 (code=%d)", result]}];
        }
        return NO;
    }
    NSLog(@"[ZeroTierBridge] zts_init_from_storage 成功");

    // 步骤 2：设置事件回调
    // 事件回调会在 libzt 的后台线程中被调用，我们通过 zeroTierEventCallback
    // 转发到主线程处理
    result = zts_init_set_event_handler(zeroTierEventCallback);
    if (result != ZTS_ERR_OK) {
        NSLog(@"[ZeroTierBridge] zts_init_set_event_handler 失败：result = %d", result);
        if (error) {
            *error = [NSError errorWithDomain:kZeroTierErrorDomain
                                          code:ZeroTierErrorCodeNodeStartFailed
                                      userInfo:@{NSLocalizedDescriptionKey: [NSString stringWithFormat:@"设置事件回调失败 (code=%d)", result]}];
        }
        return NO;
    }
    NSLog(@"[ZeroTierBridge] zts_init_set_event_handler 成功");

    // 步骤 3：启动节点
    // zts_node_start 是异步的，调用后立即返回，节点会在后台初始化。
    // 当节点成功上线后，会触发 ZTS_EVENT_NODE_ONLINE 事件。
    result = zts_node_start();
    if (result != ZTS_ERR_OK) {
        NSLog(@"[ZeroTierBridge] zts_node_start 失败：result = %d", result);
        if (error) {
            *error = [NSError errorWithDomain:kZeroTierErrorDomain
                                          code:ZeroTierErrorCodeNodeStartFailed
                                      userInfo:@{NSLocalizedDescriptionKey: [NSString stringWithFormat:@"节点启动失败 (code=%d)", result]}];
        }
        return NO;
    }

    // 更新内部状态
    [_lock lock];
    _isStarted = YES;
    _nodeStatus = ZeroTierNodeStatusStarting;
    _homeDirectory = [homeDir copy];
    [_lock unlock];

    NSLog(@"[ZeroTierBridge] 节点启动请求已提交，等待上线事件...");
    return YES;
}

/// 停止 ZeroTier 节点
///
/// 调用 zts_node_stop 停止节点，并清理所有内部状态缓存。
- (void)stopNode {
    [_lock lock];
    if (!_isStarted) {
        [_lock unlock];
        NSLog(@"[ZeroTierBridge] 节点未启动，无需停止");
        return;
    }
    [_lock unlock];

    NSLog(@"[ZeroTierBridge] 停止节点...");

    int result = zts_node_stop();
    if (result != ZTS_ERR_OK) {
        NSLog(@"[ZeroTierBridge] zts_node_stop 失败：result = %d", result);
    } else {
        NSLog(@"[ZeroTierBridge] zts_node_stop 成功");
    }

    // 清理内部状态
    [_lock lock];
    _isStarted = NO;
    _nodeStatus = ZeroTierNodeStatusStopped;
    _nodeID = 0;
    _hasBeenOnline = NO;
    _homeDirectory = nil;
    [_networkStatuses removeAllObjects];
    [_ipv4Addresses removeAllObjects];
    [_ipv6Addresses removeAllObjects];
    [_lock unlock];

    NSLog(@"[ZeroTierBridge] 节点已停止，内部状态已清理");
}

/// 节点是否在线
/// @return YES 如果节点已上线
- (BOOL)isNodeOnline {
    int online = zts_node_is_online();
    // 关键修复：如果 zts_node_is_online() 返回 1 但 _hasBeenOnline 还未被事件回调设置，
    // 在这里同步设置（事件回调可能因主线程阻塞而延迟，但 API 查询是实时的）
    if (online == 1) {
        [_lock lock];
        if (!_hasBeenOnline) {
            _hasBeenOnline = YES;
            NSLog(@"[ZeroTierBridge] isNodeOnline 检测到节点上线，同步设置 _hasBeenOnline = YES");
        }
        [_lock unlock];
    }
    return online == 1;
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
    if (zts_node_is_online()) {
        id = zts_node_get_id();
        if (id != 0) {
            [_lock lock];
            _nodeID = id;
            [_lock unlock];
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
    // zts_net_get_status 返回 ZTS_NETWORK_STATUS_* 枚举值
    if (zts_node_is_online()) {
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
                // 如果 API 返回负值（错误），保留缓存状态
                if (apiStatus < 0 && status == ZeroTierNetworkStatusNotJoined) {
                    // 缓存中也没有，标记为错误
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

#pragma mark - 等待操作

/// 等待节点上线
///
/// 以 200ms 为间隔轮询 zts_node_is_online()，直到节点上线或超时。
///
/// @param timeout 超时时间（秒）
/// @return YES 如果节点在超时前上线
- (BOOL)waitForNodeOnlineWithTimeout:(NSTimeInterval)timeout {
    NSLog(@"[ZeroTierBridge] 等待节点上线，超时 = %.1f 秒", timeout);

    // 关键修复：ZeroTier 节点在网络波动时会短暂掉线再重连（典型表现：NODE_ONLINE → NODE_OFFLINE → NODE_ONLINE）。
    // 如果等待窗口正好处于离线期，会导致连接流程失败。
    // 修复策略：
    //   1. 优先检查 zts_node_is_online()（libzt 实时查询，最准确）
    //   2. 如果实时查询返回 0，但 _nodeStatus 曾经为 Online（_hasBeenOnline 标记），也认为节点可用
    //      —— 因为节点会自动重连，掉线只是暂时的，网络加入请求仍会被处理
    //   3. 如果节点从未上线过（_hasBeenOnline == NO），则严格等待实时查询返回 1
    //   4. 关键修复：如果等待过半仍未上线，尝试重新调用 zts_node_start() 唤醒节点
    //      （libzt 在某些情况下需要外部触发才能重连）

    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:timeout];
    BOOL hasTriggeredRestart = NO;
    NSTimeInterval halfTimeout = timeout * 0.5;

    while ([[NSDate date] compare:deadline] == NSOrderedAscending) {
        int online = zts_node_is_online();
        if (online == 1) {
            NSLog(@"[ZeroTierBridge] 节点已上线（zts_node_is_online = 1）");
            return YES;
        }

        // 检查是否曾经上线过：如果曾经上线，说明节点已配置完成，只是暂时掉线
        // 此时可以继续后续流程（加入网络），libzt 会在重连后自动恢复
        [_lock lock];
        BOOL hasBeenOnline = _hasBeenOnline;
        ZeroTierNodeStatus status = _nodeStatus;
        BOOL isStarted = _isStarted;
        [_lock unlock];
        if (hasBeenOnline && status != ZeroTierNodeStatusStopped && status != ZeroTierNodeStatusError) {
            NSLog(@"[ZeroTierBridge] 节点曾上线过，当前状态=%d，视为可用（容错）", (int)status);
            return YES;
        }

        // 关键修复：如果等待过半仍未上线，且节点已启动但从未上线（或掉线后未重连），
        // 尝试重新调用 zts_node_start() 唤醒节点
        NSTimeInterval elapsed = timeout - [deadline timeIntervalSinceNow];
        if (!hasTriggeredRestart && elapsed > halfTimeout && isStarted) {
            NSLog(@"[ZeroTierBridge] 等待过半（%.1fs）节点仍未上线，尝试重新调用 zts_node_start() 唤醒", elapsed);
            int restartResult = zts_node_start();
            NSLog(@"[ZeroTierBridge] zts_node_start() 重新调用结果 = %d", restartResult);
            hasTriggeredRestart = YES;
            // 重新调用后给节点 2 秒恢复时间
            [NSThread sleepForTimeInterval:2.0];
            continue;
        }

        // 每 200ms 检查一次
        [NSThread sleepForTimeInterval:0.2];
    }

    NSLog(@"[ZeroTierBridge] 等待节点上线超时（%.1f 秒）", timeout);
    return NO;
}

/// 等待网络就绪
///
/// 以 200ms 为间隔轮询 zts_net_transport_is_ready() 和 zts_addr_is_assigned()，
/// 直到网络就绪且 IPv4 地址已分配，或超时。
///
/// @param networkID 网络 ID
/// @param timeout 超时时间（秒）
/// @return YES 如果网络在超时前就绪
- (BOOL)waitForNetworkReady:(uint64_t)networkID
                    timeout:(NSTimeInterval)timeout {
    NSLog(@"[ZeroTierBridge] 等待网络就绪：networkID = %016llx，超时 = %.1f 秒", networkID, timeout);

    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:timeout];
    while ([[NSDate date] compare:deadline] == NSOrderedAscending) {
        // 检查传输层是否就绪
        int transportReady = zts_net_transport_is_ready(networkID);
        // 检查 IPv4 或 IPv6 地址是否已分配
        // 标准网络会分配 IPv4 地址，Ad-hoc 网络只有 IPv6 地址
        int ipv4Assigned = zts_addr_is_assigned(networkID, ZTS_AF_INET);
        int ipv6Assigned = zts_addr_is_assigned(networkID, ZTS_AF_INET6);

        if (transportReady == 1 && (ipv4Assigned == 1 || ipv6Assigned == 1)) {
            NSLog(@"[ZeroTierBridge] 网络已就绪：transportReady=%d, ipv4=%d, ipv6=%d",
                  transportReady, ipv4Assigned, ipv6Assigned);
            return YES;
        }

        // 每 200ms 检查一次
        [NSThread sleepForTimeInterval:0.2];
    }

    NSLog(@"[ZeroTierBridge] 等待网络就绪超时（%.1f 秒）", timeout);
    return NO;
}

#pragma mark - 事件处理

/// 处理 ZeroTier 事件（在主线程调用）
///
/// 根据 zts_event_msg_t 的 event_code 字段分发到对应的处理逻辑。
///
/// @param msg 事件消息指针
- (void)handleEventData:(NSDictionary *)eventData {
    if (!eventData) {
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
            NSLog(@"[ZeroTierBridge] 事件：节点已上线 (NODE_ONLINE)，nodeID = %016llx", nodeID);

            [_lock lock];
            _nodeStatus = ZeroTierNodeStatusOnline;
            _nodeID = nodeID;
            _hasBeenOnline = YES; // 标记节点曾经上线，用于 waitForNodeOnlineWithTimeout: 容错
            [_lock unlock];

            // 通知 delegate
            if ([self.delegate respondsToSelector:@selector(zeroTierNodeOnlineWithID:)]) {
                [self.delegate zeroTierNodeOnlineWithID:nodeID];
            }
            break;
        }

        case ZTS_EVENT_NODE_OFFLINE: {
            // 节点已离线（202）
            NSLog(@"[ZeroTierBridge] 事件：节点已离线 (NODE_OFFLINE)");
            [_lock lock];
            _nodeStatus = ZeroTierNodeStatusOffline;
            [_lock unlock];

            // 通知 delegate
            if ([self.delegate respondsToSelector:@selector(zeroTierNodeOffline)]) {
                [self.delegate zeroTierNodeOffline];
            }
            break;
        }

        case ZTS_EVENT_NODE_DOWN: {
            // 节点正在关闭（203）
            NSLog(@"[ZeroTierBridge] 事件：节点正在关闭 (NODE_DOWN)");
            [_lock lock];
            _nodeStatus = ZeroTierNodeStatusStopped;
            [_lock unlock];
            break;
        }

        case ZTS_EVENT_NODE_FATAL_ERROR: {
            // 节点发生致命错误（204）
            // 可能原因：身份冲突（两个节点的公钥哈希到同一个 40 位地址）
            NSLog(@"[ZeroTierBridge] 事件：节点发生致命错误 (NODE_FATAL_ERROR)");
            [_lock lock];
            _nodeStatus = ZeroTierNodeStatusError;
            [_lock unlock];
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

            // 通知 delegate 网络已就绪
            NSString *ipv4 = [self ipv4AddressForNetwork:netID];
            NSString *ipv6 = [self ipv6AddressForNetwork:netID];
            if ([self.delegate respondsToSelector:@selector(zeroTierNetworkReady:ipv4:ipv6:)]) {
                [self.delegate zeroTierNetworkReady:netID ipv4:ipv4 ipv6:ipv6];
            }
            break;
        }

        case ZTS_EVENT_NETWORK_ACCESS_DENIED: {
            // 网络访问被拒绝（214）
            uint64_t netID = [eventData[@"netID"] unsignedLongLongValue];
            NSLog(@"[ZeroTierBridge] 事件：网络访问被拒绝 (NETWORK_ACCESS_DENIED)，netID = %016llx", netID);

            [_lock lock];
            _networkStatuses[@(netID)] = @(ZeroTierNetworkStatusDenied);
            [_lock unlock];

            // 通知 delegate 加入失败
            if ([self.delegate respondsToSelector:@selector(zeroTierNetworkJoinFailed:error:)]) {
                [self.delegate zeroTierNetworkJoinFailed:netID
                                                   error:@"网络访问被拒绝，请联系网络管理员授权此节点"];
            }
            break;
        }

        case ZTS_EVENT_NETWORK_NOT_FOUND: {
            // 网络不存在（210）
            uint64_t netID = [eventData[@"netID"] unsignedLongLongValue];
            NSLog(@"[ZeroTierBridge] 事件：网络不存在 (NETWORK_NOT_FOUND)，netID = %016llx", netID);

            [_lock lock];
            _networkStatuses[@(netID)] = @(ZeroTierNetworkStatusNotFound);
            [_lock unlock];

            // 通知 delegate 加入失败
            if ([self.delegate respondsToSelector:@selector(zeroTierNetworkJoinFailed:error:)]) {
                [self.delegate zeroTierNetworkJoinFailed:netID
                                                   error:@"网络不存在，请检查 Network ID 是否正确"];
            }
            break;
        }

        case ZTS_EVENT_NETWORK_READY_IP4: {
            // IPv4 网络就绪（215）
            uint64_t netID = [eventData[@"netID"] unsignedLongLongValue];
            NSLog(@"[ZeroTierBridge] 事件：IPv4 网络就绪 (NETWORK_READY_IP4)，netID = %016llx", netID);

            // 清除 IPv4 缓存，强制下次查询时刷新
            [_lock lock];
            [_ipv4Addresses removeObjectForKey:@(netID)];
            [_lock unlock];

            // 通知 delegate 网络已就绪
            NSString *ipv4 = [self ipv4AddressForNetwork:netID];
            NSString *ipv6 = [self ipv6AddressForNetwork:netID];
            if ([self.delegate respondsToSelector:@selector(zeroTierNetworkReady:ipv4:ipv6:)]) {
                [self.delegate zeroTierNetworkReady:netID ipv4:ipv4 ipv6:ipv6];
            }
            break;
        }

        case ZTS_EVENT_NETWORK_READY_IP6: {
            // IPv6 网络就绪（216）
            uint64_t netID = [eventData[@"netID"] unsignedLongLongValue];
            NSLog(@"[ZeroTierBridge] 事件：IPv6 网络就绪 (NETWORK_READY_IP6)，netID = %016llx", netID);

            // 清除 IPv6 缓存，强制下次查询时刷新
            [_lock lock];
            [_ipv6Addresses removeObjectForKey:@(netID)];
            [_lock unlock];

            // 通知 delegate 网络已就绪
            NSString *ipv4 = [self ipv4AddressForNetwork:netID];
            NSString *ipv6 = [self ipv6AddressForNetwork:netID];
            if ([self.delegate respondsToSelector:@selector(zeroTierNetworkReady:ipv4:ipv6:)]) {
                [self.delegate zeroTierNetworkReady:netID ipv4:ipv4 ipv6:ipv6];
            }
            break;
        }

        case ZTS_EVENT_NETWORK_DOWN: {
            // 网络控制器不可达（218）
            uint64_t netID = [eventData[@"netID"] unsignedLongLongValue];
            NSLog(@"[ZeroTierBridge] 事件：网络控制器不可达 (NETWORK_DOWN)，netID = %016llx", netID);
            break;
        }

        case ZTS_EVENT_NETWORK_REQ_CONFIG: {
            // 网络配置请求中（212）
            uint64_t netID = [eventData[@"netID"] unsignedLongLongValue];
            NSLog(@"[ZeroTierBridge] 事件：网络配置请求中 (NETWORK_REQ_CONFIG)，netID = %016llx", netID);
            [_lock lock];
            _networkStatuses[@(netID)] = @(ZeroTierNetworkStatusRequesting);
            [_lock unlock];
            break;
        }

        // ===== 地址事件 =====

        case ZTS_EVENT_ADDR_ADDED_IP4: {
            // IPv4 地址已分配（260）
            uint64_t netID = [eventData[@"addrNetID"] unsignedLongLongValue];
            NSString *addrStr = eventData[@"addrStr"];
            int family = ZTS_AF_INET;

            NSLog(@"[ZeroTierBridge] 事件：IPv4 地址已分配 (ADDR_ADDED_IP4)，netID = %016llx，addr = %@", netID, addrStr);

            // 更新缓存
            if (addrStr) {
                [_lock lock];
                _ipv4Addresses[@(netID)] = addrStr;
                [_lock unlock];
            }

            // 通知 delegate
            if ([self.delegate respondsToSelector:@selector(zeroTierAddressAssigned:family:address:)]) {
                [self.delegate zeroTierAddressAssigned:netID family:family address:addrStr ?: @""];
            }
            break;
        }

        case ZTS_EVENT_ADDR_ADDED_IP6: {
            // IPv6 地址已分配（262）
            uint64_t netID = [eventData[@"addrNetID"] unsignedLongLongValue];
            NSString *addrStr = eventData[@"addrStr"];
            int family = ZTS_AF_INET6;

            NSLog(@"[ZeroTierBridge] 事件：IPv6 地址已分配 (ADDR_ADDED_IP6)，netID = %016llx，addr = %@", netID, addrStr);

            // 更新缓存
            if (addrStr) {
                [_lock lock];
                _ipv6Addresses[@(netID)] = addrStr;
                [_lock unlock];
            }

            // 通知 delegate
            if ([self.delegate respondsToSelector:@selector(zeroTierAddressAssigned:family:address:)]) {
                [self.delegate zeroTierAddressAssigned:netID family:family address:addrStr ?: @""];
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
            break;
        }

        case ZTS_EVENT_ADDR_REMOVED_IP6: {
            // IPv6 地址已移除（263）
            uint64_t netID = [eventData[@"addrNetID"] unsignedLongLongValue];
            NSLog(@"[ZeroTierBridge] 事件：IPv6 地址已移除 (ADDR_REMOVED_IP6)，netID = %016llx", netID);
            [_lock lock];
            [_ipv6Addresses removeObjectForKey:@(netID)];
            [_lock unlock];
            break;
        }

        // ===== 其他事件（仅记录日志） =====

        case ZTS_EVENT_STACK_UP:
            NSLog(@"[ZeroTierBridge] 事件：TCP/IP 栈已启动 (STACK_UP)");
            break;

        case ZTS_EVENT_STACK_DOWN:
            NSLog(@"[ZeroTierBridge] 事件：TCP/IP 栈已停止 (STACK_DOWN)");
            break;

        case ZTS_EVENT_NETIF_UP:
            NSLog(@"[ZeroTierBridge] 事件：网络接口已启用 (NETIF_UP)");
            break;

        case ZTS_EVENT_NETIF_DOWN:
            NSLog(@"[ZeroTierBridge] 事件：网络接口已禁用 (NETIF_DOWN)");
            break;

        case ZTS_EVENT_ROUTE_ADDED:
            NSLog(@"[ZeroTierBridge] 事件：路由已添加 (ROUTE_ADDED)");
            break;

        case ZTS_EVENT_ROUTE_REMOVED:
            NSLog(@"[ZeroTierBridge] 事件：路由已移除 (ROUTE_REMOVED)");
            break;

        default:
            NSLog(@"[ZeroTierBridge] 未处理的事件：event_code = %d", eventCode);
            break;
    }
}

#pragma mark - Socket 操作（供 SOCKS5Proxy 使用）

/// 创建 TCP socket（封装 zts_bsd_socket）
///
/// 创建一个基于 ZeroTier 虚拟网络的 IPv4 TCP socket。
///
/// @return socket 文件描述符（≥ 0 表示成功，< 0 表示失败）
- (int)createTCPSocket {
    // 参数：AF_INET（IPv4）、SOCK_STREAM（TCP）、IPPROTO_TCP
    int fd = zts_bsd_socket(ZTS_AF_INET, ZTS_SOCK_STREAM, ZTS_IPPROTO_TCP);
    if (fd < 0) {
        NSLog(@"[ZeroTierBridge] 创建 TCP socket 失败：fd = %d, zts_errno = %d", fd, zts_errno);
    } else {
        NSLog(@"[ZeroTierBridge] 创建 TCP socket 成功：fd = %d", fd);
    }
    return fd;
}

- (int)createTCPSocketForFamily:(int)family {
    // 根据指定的地址族创建 TCP socket
    // 用于 Ad-hoc 网络等只有 IPv6 的场景
    int fd = zts_bsd_socket(family, ZTS_SOCK_STREAM, ZTS_IPPROTO_TCP);
    if (fd < 0) {
        NSLog(@"[ZeroTierBridge] 创建 TCP socket(family=%d) 失败：fd = %d, zts_errno = %d", family, fd, zts_errno);
    } else {
        NSLog(@"[ZeroTierBridge] 创建 TCP socket(family=%d) 成功：fd = %d", family, fd);
    }
    return fd;
}

/// 连接 socket 到目标主机
///
/// 封装 zts_bsd_connect，支持 IPv4 和 IPv6。
/// 超时通过 zts_bsd_setsockopt 设置 SO_RCVTIMEO 和 SO_SNDTIMEO 实现。
///
/// 注意：zts_sockaddr_in 的字段名与系统 sockaddr_in 不同：
///   - zts_sockaddr_in 使用 sin_len、sin_family、sin_port、sin_addr、sin_zero
///   - 端口需要转换为网络字节序（htons）
///   - 地址使用 zts_inet_pton 从字符串转换
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
    // 参数校验
    if (!host || host.length == 0) {
        NSLog(@"[ZeroTierBridge] connectSocket 错误：host 为空");
        return ZTS_ERR_ARG;
    }

    if (fd < 0) {
        NSLog(@"[ZeroTierBridge] connectSocket 错误：fd 无效 (fd=%d)", fd);
        return ZTS_ERR_ARG;
    }

    NSLog(@"[ZeroTierBridge] 连接 socket：fd = %d, host = %@, port = %u, timeout = %.1f",
          fd, host, port, timeout);

    const char *hostCStr = [host UTF8String];

    // 设置超时（通过 SO_RCVTIMEO 和 SO_SNDTIMEO）
    // 这会影响后续的 send/recv 操作超时
    if (timeout > 0) {
        struct zts_timeval tv;
        tv.tv_sec = (long)timeout;
        tv.tv_usec = (long)((timeout - (NSTimeInterval)tv.tv_sec) * 1000000);
        if (tv.tv_usec < 0) {
            tv.tv_usec = 0;
        }

        // 设置接收超时
        int rc = zts_bsd_setsockopt(fd, ZTS_SOL_SOCKET, ZTS_SO_RCVTIMEO, &tv, sizeof(tv));
        if (rc != ZTS_ERR_OK) {
            NSLog(@"[ZeroTierBridge] 设置 SO_RCVTIMEO 失败：rc = %d, zts_errno = %d", rc, zts_errno);
        }

        // 设置发送超时
        rc = zts_bsd_setsockopt(fd, ZTS_SOL_SOCKET, ZTS_SO_SNDTIMEO, &tv, sizeof(tv));
        if (rc != ZTS_ERR_OK) {
            NSLog(@"[ZeroTierBridge] 设置 SO_SNDTIMEO 失败：rc = %d, zts_errno = %d", rc, zts_errno);
        }
    }

    // 检测 IP 地址类型（IPv4 或 IPv6）
    // 通过检查字符串中是否包含 ':' 来判断（IPv6 地址包含冒号）
    BOOL isIPv6 = ([host rangeOfString:@":"].location != NSNotFound);
    NSLog(@"[ZeroTierBridge] 地址类型：%@", isIPv6 ? @"IPv6" : @"IPv4");

    if (isIPv6) {
        // IPv6 连接
        struct zts_sockaddr_in6 addr6;
        memset(&addr6, 0, sizeof(addr6));
        addr6.sin6_len = sizeof(addr6);
        addr6.sin6_family = ZTS_AF_INET6;
        addr6.sin6_port = htons(port);

        // 使用 zts_inet_pton 将 IPv6 字符串转换为二进制地址
        int ptonResult = zts_inet_pton(ZTS_AF_INET6, hostCStr, &addr6.sin6_addr);
        if (ptonResult != 1) {
            NSLog(@"[ZeroTierBridge] zts_inet_pton(IPv6) 失败：result = %d, host = %@", ptonResult, host);
            return ZTS_ERR_ARG;
        }

        // 调用 zts_bsd_connect 连接
        int result = zts_bsd_connect(fd, (const struct zts_sockaddr *)&addr6, sizeof(addr6));
        if (result != ZTS_ERR_OK) {
            NSLog(@"[ZeroTierBridge] zts_bsd_connect(IPv6) 失败：result = %d, zts_errno = %d", result, zts_errno);
        } else {
            NSLog(@"[ZeroTierBridge] IPv6 连接成功");
        }
        return result;
    } else {
        // IPv4 连接
        struct zts_sockaddr_in addr;
        memset(&addr, 0, sizeof(addr));
        addr.sin_len = sizeof(addr);
        addr.sin_family = ZTS_AF_INET;
        addr.sin_port = htons(port);

        // 使用 zts_inet_pton 将 IPv4 字符串转换为二进制地址
        int ptonResult = zts_inet_pton(ZTS_AF_INET, hostCStr, &addr.sin_addr);
        if (ptonResult != 1) {
            NSLog(@"[ZeroTierBridge] zts_inet_pton(IPv4) 失败：result = %d, host = %@", ptonResult, host);
            return ZTS_ERR_ARG;
        }

        // 调用 zts_bsd_connect 连接
        int result = zts_bsd_connect(fd, (const struct zts_sockaddr *)&addr, sizeof(addr));
        if (result != ZTS_ERR_OK) {
            NSLog(@"[ZeroTierBridge] zts_bsd_connect(IPv4) 失败：result = %d, zts_errno = %d", result, zts_errno);
        } else {
            NSLog(@"[ZeroTierBridge] IPv4 连接成功");
        }
        return result;
    }
}

/// 关闭 socket（封装 zts_bsd_close）
/// @param fd socket 文件描述符
/// @return 0 表示成功，< 0 表示失败
- (int)closeSocket:(int)fd {
    NSLog(@"[ZeroTierBridge] 关闭 socket：fd = %d", fd);
    int result = zts_bsd_close(fd);
    if (result != ZTS_ERR_OK) {
        NSLog(@"[ZeroTierBridge] zts_bsd_close 失败：result = %d, zts_errno = %d", result, zts_errno);
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
    // 参数：fd、buf、len、flags=0（无特殊标志）
    ssize_t sent = zts_bsd_send(fd, buf, len, 0);
    if (sent < 0) {
        NSLog(@"[ZeroTierBridge] zts_bsd_send 失败：sent = %zd, zts_errno = %d, fd = %d", sent, zts_errno, fd);
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
    // 参数：fd、buf、len、flags=0（无特殊标志）
    ssize_t received = zts_bsd_recv(fd, buf, len, 0);
    if (received < 0) {
        NSLog(@"[ZeroTierBridge] zts_bsd_recv 失败：received = %zd, zts_errno = %d, fd = %d", received, zts_errno, fd);
    }
    return received;
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

    // strtoull 参数：
    //   - str：要解析的字符串
    //   - endptr：解析结束位置（NULL 表示不关心）
    //   - base：进制（16 表示十六进制）
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

@end
