//
//  ZeroTierBridge.m
//  Angel Aura Amethyst
//
//  Implementation of the Objective-C wrapper layer for the ZeroTier libzt C API (slimmed-down version)
//
//  Implementation highlights: a singleton with state protected by NSLock; static C functions extract data synchronously on the callback thread
//  into an NSDictionary, which is forwarded to the main thread with dispatch_async; framework detection is done via
//  the zts_node_start() return value; waiting operations use dispatch_semaphore_t.
//

#import "ZeroTierBridge.h"
#import "utils.h"

#include <string.h>
#include <stdlib.h>
#include <arpa/inet.h>

static NSString * const kZeroTierErrorDomain = @"ZeroTierBridgeErrorDomain";

typedef NS_ENUM(NSInteger, ZeroTierErrorCode) {
    ZeroTierErrorCodeFrameworkUnavailable = 1, ZeroTierErrorCodeNodeNotStarted = 2,
    ZeroTierErrorCodeNodeStartFailed = 3, ZeroTierErrorCodeNetworkJoinFailed = 4,
    ZeroTierErrorCodeTimeout = 5, ZeroTierErrorCodeInvalidArgument = 6, ZeroTierErrorCodeSocketError = 7,
};

@interface ZeroTierBridge () {
    ZeroTierNodeStatus _nodeStatus;
    NSMutableDictionary<NSNumber *, NSNumber *> *_networkStatuses;
    NSMutableDictionary<NSNumber *, NSString *> *_ipv4Addresses;
    NSMutableDictionary<NSNumber *, NSString *> *_ipv6Addresses;
    BOOL _isStarted;
    BOOL _frameworkAvailable;
    BOOL _frameworkChecked;
    uint64_t _nodeID;
    NSString *_homeDirectory;
    dispatch_semaphore_t _nodeOnlineSemaphore;
    dispatch_semaphore_t _networkEventSemaphore;
    NSLock *_lock;
}
- (void)handleEventData:(NSDictionary *)eventData;
- (BOOL)isNetworkReady:(uint64_t)networkID;
@end

#pragma mark - Event callbacks (static C functions)

/// libzt event callback entry point: extracts data synchronously on the callback thread, wraps it in an NSDictionary and forwards it to the main thread
static void zeroTierEventCallback(void *msgPtr) {
    zts_event_msg_t *msg = (zts_event_msg_t *)msgPtr;
    if (!msg) return;

    NSMutableDictionary *eventData = [NSMutableDictionary dictionary];
    eventData[@"eventCode"] = @(msg->event_code);
    if (msg->node) eventData[@"nodeID"] = @(msg->node->node_id);
    if (msg->network) eventData[@"netID"] = @(msg->network->net_id);

    if (msg->addr) {
        eventData[@"addrNetID"] = @(msg->addr->net_id);
        char ipBuf[ZTS_IP_MAX_STR_LEN] = {0};
        struct zts_sockaddr_storage *ss = &msg->addr->addr;
        int family = ss->ss_family;
        void *srcAddr = (family == ZTS_AF_INET)
            ? (void *)&((struct zts_sockaddr_in *)ss)->sin_addr
            : (void *)&((struct zts_sockaddr_in6 *)ss)->sin6_addr;
        if (zts_inet_ntop(family, srcAddr, ipBuf, sizeof(ipBuf))) {
            eventData[@"addrStr"] = [NSString stringWithUTF8String:ipBuf];
            eventData[@"addrFamily"] = @(family);
        }
    }

    NSDictionary *immutableData = [eventData copy];
    dispatch_async(dispatch_get_main_queue(), ^{
        [[ZeroTierBridge sharedInstance] handleEventData:immutableData];
    });
}

#pragma mark - ZeroTierBridge implementation

@implementation ZeroTierBridge

+ (instancetype)sharedInstance {
    static ZeroTierBridge *shared = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{ shared = [[self alloc] init]; });
    return shared;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _nodeStatus = ZeroTierNodeStatusStopped;
        _networkStatuses = [[NSMutableDictionary alloc] init];
        _ipv4Addresses = [[NSMutableDictionary alloc] init];
        _ipv6Addresses = [[NSMutableDictionary alloc] init];
        _nodeOnlineSemaphore = dispatch_semaphore_create(0);
        _networkEventSemaphore = dispatch_semaphore_create(0);
        _lock = [[NSLock alloc] init];
    }
    return self;
}

#pragma mark - Framework detection

/// The first call detects it from the zts_node_start() return value: ZTS_ERR_OK means the real framework,
/// ZTS_ERR_SERVICE means a stub. After detection the state is cleaned up and the result cached.
- (BOOL)isFrameworkAvailable {
    [_lock lock];
    BOOL cached = _frameworkChecked;
    BOOL available = _frameworkAvailable;
    [_lock unlock];
    if (cached) return available;

    int result = zts_node_start();
    BOOL frameworkAvailable = (result == ZTS_ERR_OK);
    if (frameworkAvailable) {
        // The real framework, so clean up the node that was started
        zts_node_stop();
        NSTimeInterval deadline = [NSDate timeIntervalSinceReferenceDate] + 2.0;
        while (zts_node_is_online() == 1 && [NSDate timeIntervalSinceReferenceDate] < deadline) {
            [NSThread sleepForTimeInterval:0.05];
        }
    }
    NSLog(@"[ZeroTierBridge] framework check: zts_node_start()=%d, available=%@", result, frameworkAvailable ? @"YES" : @"NO");

    [_lock lock];
    _frameworkAvailable = frameworkAvailable;
    _frameworkChecked = YES;
    [_lock unlock];
    return frameworkAvailable;
}

#pragma mark - Node management

- (BOOL)startNodeWithHomeDirectory:(NSString *)homeDir error:(NSError **)error {
    if (!homeDir.length) {
        if (error) *error = [NSError errorWithDomain:kZeroTierErrorDomain code:ZeroTierErrorCodeInvalidArgument userInfo:@{NSLocalizedDescriptionKey: @"The home directory path is invalid"}];
        return NO;
    }
    if (![self isFrameworkAvailable]) {
        if (error) *error = [NSError errorWithDomain:kZeroTierErrorDomain code:ZeroTierErrorCodeFrameworkUnavailable userInfo:@{NSLocalizedDescriptionKey: @"The ZeroTier framework is unavailable (stub mode)"}];
        return NO;
    }
    // Return YES immediately if it is already started
    [_lock lock];
    if (_isStarted) { [_lock unlock]; return YES; }
    [_lock unlock];

    // Key fix (defensive state synchronization for stopNode):
    // If stopNode still has not fully shut the node down after its 2 second timeout (zts_node_is_online still returns 1),
    // wait here for up to 3 more seconds to make sure the old node has fully stopped, avoiding a conflict between zts_init_from_storage and the old node.
    if (zts_node_is_online() == 1) {
        NSLog(@"[ZeroTierBridge] startNode: detected node still online (stop not fully completed), waiting for shutdown...");
        NSTimeInterval deadline = [NSDate timeIntervalSinceReferenceDate] + 3.0;
        while (zts_node_is_online() == 1 && [NSDate timeIntervalSinceReferenceDate] < deadline) {
            [NSThread sleepForTimeInterval:0.05];
        }
        if (zts_node_is_online() == 1) {
            NSLog(@"[ZeroTierBridge] startNode: node still not shut down, forcing continue (may cause state conflict)");
        }
    }

    int result = zts_init_from_storage([homeDir UTF8String]);
    if (result != ZTS_ERR_OK) {
        if (error) *error = [NSError errorWithDomain:kZeroTierErrorDomain code:ZeroTierErrorCodeNodeStartFailed userInfo:@{NSLocalizedDescriptionKey: [NSString stringWithFormat:@"Failed to initialize the storage directory (code=%d)", result]}];
        zts_node_stop();
        return NO;
    }
    result = zts_init_set_event_handler(zeroTierEventCallback);
    if (result != ZTS_ERR_OK) {
        if (error) *error = [NSError errorWithDomain:kZeroTierErrorDomain code:ZeroTierErrorCodeNodeStartFailed userInfo:@{NSLocalizedDescriptionKey: [NSString stringWithFormat:@"Failed to set the event callback (code=%d)", result]}];
        zts_node_stop();
        return NO;
    }
    result = zts_node_start();
    if (result != ZTS_ERR_OK) {
        if (error) *error = [NSError errorWithDomain:kZeroTierErrorDomain code:ZeroTierErrorCodeNodeStartFailed userInfo:@{NSLocalizedDescriptionKey: [NSString stringWithFormat:@"The node failed to start (code=%d)", result]}];
        zts_node_stop();
        return NO;
    }

    [_lock lock];
    _isStarted = YES;
    _nodeStatus = ZeroTierNodeStatusStarting;
    _homeDirectory = [homeDir copy];
    [_lock unlock];

    NSLog(@"[ZeroTierBridge] node start request submitted, homeDir = %@", homeDir);
    return YES;
}

- (void)stopNode {
    [_lock lock];
    if (!_isStarted) { [_lock unlock]; return; }
    [_lock unlock];

    zts_node_stop();
    // Key fix (stopNode state synchronization):
    // Previously, when called on the main thread, waitBlock was dispatched to run asynchronously in the background while the state cleanup completed immediately on the main thread.
    // A caller that saw _isStarted = NO would immediately call startNode, potentially running concurrently with stop logic that had not finished in the background,
    // making zts_init_from_storage / zts_node_start conflict with the state of the old node that was still stopping.
    //
    // The fix: the main thread also waits synchronously for the node to go offline, but the maximum wait is shortened to 2 seconds so the UI does not freeze for long.
    // 2 seconds is usually enough for libzt to finish shutting the node down; beyond that we stop waiting, and libzt finishes its own cleanup eventually anyway.
    // Callers (such as disconnectCurrentRoom) that call from the main thread face at most a 2 second synchronous wait, which is acceptable -
    // disconnectCurrentRoom is normally triggered explicitly by the user (tapping the disconnect button), and a brief wait is preferable to inconsistent state.
    NSTimeInterval deadline = [NSDate timeIntervalSinceReferenceDate] + 2.0;
    while (zts_node_is_online() == 1 && [NSDate timeIntervalSinceReferenceDate] < deadline) {
        [NSThread sleepForTimeInterval:0.05];
    }

    [_lock lock];
    _isStarted = NO;
    _nodeStatus = ZeroTierNodeStatusStopped;
    _nodeID = 0;
    _homeDirectory = nil;
    [_networkStatuses removeAllObjects];
    [_ipv4Addresses removeAllObjects];
    [_ipv6Addresses removeAllObjects];
    [_lock unlock];
    NSLog(@"[ZeroTierBridge] node stopped");
}

- (BOOL)isNodeOnline {
    [_lock lock];
    BOOL started = _isStarted;
    [_lock unlock];
    return started && zts_node_is_online() == 1;
}

- (uint64_t)nodeID {
    [_lock lock];
    uint64_t id = _nodeID;
    [_lock unlock];
    if (id != 0) return id;
    if (zts_node_is_online()) {
        id = zts_node_get_id();
        if (id != 0) {
            [_lock lock]; _nodeID = id; [_lock unlock];
        }
    }
    return id;
}

- (ZeroTierNodeStatus)nodeStatus {
    [_lock lock];
    ZeroTierNodeStatus status = _nodeStatus;
    [_lock unlock];
    return status;
}

#pragma mark - Network management

- (BOOL)joinNetwork:(uint64_t)networkID error:(NSError **)error {
    [_lock lock];
    BOOL started = _isStarted;
    [_lock unlock];
    if (!started) {
        if (error) *error = [NSError errorWithDomain:kZeroTierErrorDomain code:ZeroTierErrorCodeNodeNotStarted userInfo:@{NSLocalizedDescriptionKey: @"The ZeroTier node is not running"}];
        return NO;
    }
    int result = zts_net_join(networkID);
    if (result != ZTS_ERR_OK) {
        if (error) *error = [NSError errorWithDomain:kZeroTierErrorDomain code:ZeroTierErrorCodeNetworkJoinFailed userInfo:@{NSLocalizedDescriptionKey: [NSString stringWithFormat:@"Failed to join the network (code=%d)", result]}];
        return NO;
    }
    [_lock lock];
    _networkStatuses[@(networkID)] = @(ZeroTierNetworkStatusRequestingConfig);
    [_lock unlock];
    return YES;
}

- (BOOL)leaveNetwork:(uint64_t)networkID {
    int result = zts_net_leave(networkID);
    if (result != ZTS_ERR_OK) return NO;
    [_lock lock];
    [_networkStatuses removeObjectForKey:@(networkID)];
    [_ipv4Addresses removeObjectForKey:@(networkID)];
    [_ipv6Addresses removeObjectForKey:@(networkID)];
    [_lock unlock];
    return YES;
}

- (ZeroTierNetworkStatus)networkStatus:(uint64_t)networkID {
    [_lock lock];
    NSNumber *statusNum = _networkStatuses[@(networkID)];
    [_lock unlock];
    return statusNum ? (ZeroTierNetworkStatus)[statusNum integerValue] : ZeroTierNetworkStatusUnknown;
}

- (nullable NSString *)ipv4AddressForNetwork:(uint64_t)networkID {
    [_lock lock];
    NSString *addr = _ipv4Addresses[@(networkID)];
    [_lock unlock];
    if (addr) return addr;
    char ipBuf[ZTS_IP_MAX_STR_LEN] = {0};
    if (zts_addr_get_str(networkID, ZTS_AF_INET, ipBuf, sizeof(ipBuf)) == ZTS_ERR_OK) {
        NSString *ipStr = [NSString stringWithUTF8String:ipBuf];
        [_lock lock]; _ipv4Addresses[@(networkID)] = ipStr; [_lock unlock];
        return ipStr;
    }
    return nil;
}

- (nullable NSString *)ipv6AddressForNetwork:(uint64_t)networkID {
    [_lock lock];
    NSString *addr = _ipv6Addresses[@(networkID)];
    [_lock unlock];
    if (addr) return addr;
    char ipBuf[ZTS_IP_MAX_STR_LEN] = {0};
    if (zts_addr_get_str(networkID, ZTS_AF_INET6, ipBuf, sizeof(ipBuf)) == ZTS_ERR_OK) {
        NSString *ipStr = [NSString stringWithUTF8String:ipBuf];
        [_lock lock]; _ipv6Addresses[@(networkID)] = ipStr; [_lock unlock];
        return ipStr;
    }
    return nil;
}

#pragma mark - Wait operations

- (BOOL)waitForNodeOnlineWithTimeout:(NSTimeInterval)timeout {
    if ([self isNodeOnline]) return YES;
    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:timeout];
    while ([[NSDate date] compare:deadline] == NSOrderedAscending) {
        if ([self nodeStatus] == ZeroTierNodeStatusStopped) return NO;
        NSTimeInterval remaining = [deadline timeIntervalSinceNow];
        if (remaining <= 0) break;
        dispatch_semaphore_wait(_nodeOnlineSemaphore, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(remaining * NSEC_PER_SEC)));
        if ([self isNodeOnline]) return YES;
    }
    return NO;
}

- (BOOL)waitForNetworkReady:(uint64_t)networkID timeout:(NSTimeInterval)timeout {
    if ([self isNetworkReady:networkID]) return YES;
    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:timeout];
    while ([[NSDate date] compare:deadline] == NSOrderedAscending) {
        ZeroTierNetworkStatus cachedStatus = [self networkStatus:networkID];
        if (cachedStatus == ZeroTierNetworkStatusAccessDenied ||
            cachedStatus == ZeroTierNetworkStatusNotFound ||
            cachedStatus == ZeroTierNetworkStatusClientTooOld) {
            return NO;
        }
        if ([self isNetworkReady:networkID]) return YES;
        NSTimeInterval remaining = [deadline timeIntervalSinceNow];
        if (remaining <= 0) break;
        dispatch_semaphore_wait(_networkEventSemaphore, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(remaining * NSEC_PER_SEC)));
    }
    return NO;
}

/// Network readiness test: the transport layer is ready and an address of the matching family has been assigned (ad-hoc networks use IPv6)
- (BOOL)isNetworkReady:(uint64_t)networkID {
    if (zts_net_transport_is_ready(networkID) != 1) return NO;
    uint8_t highByte = (uint8_t)((networkID >> 56) & 0xFF);
    if (highByte == 0xFF) {
        return zts_addr_is_assigned(networkID, ZTS_AF_INET6) == 1;
    }
    return zts_addr_is_assigned(networkID, ZTS_AF_INET) == 1;
}

#pragma mark - Event handling (main thread)

- (void)handleEventData:(NSDictionary *)eventData {
    int eventCode = [eventData[@"eventCode"] intValue];
    id<ZeroTierBridgeDelegate> delegate = self.delegate;
    uint64_t netID = [eventData[@"netID"] unsignedLongLongValue];

    switch (eventCode) {
        case ZTS_EVENT_NODE_ONLINE: {
            uint64_t nodeID = [eventData[@"nodeID"] unsignedLongLongValue];
            [_lock lock]; _nodeID = nodeID; _nodeStatus = ZeroTierNodeStatusOnline; [_lock unlock];
            dispatch_semaphore_signal(_nodeOnlineSemaphore);
            if ([delegate respondsToSelector:@selector(zeroTierNodeOnlineWithID:)]) [delegate zeroTierNodeOnlineWithID:nodeID];
            break;
        }
        case ZTS_EVENT_NODE_OFFLINE: {
            [_lock lock]; _nodeStatus = ZeroTierNodeStatusOffline; [_lock unlock];
            dispatch_semaphore_signal(_nodeOnlineSemaphore);
            if ([delegate respondsToSelector:@selector(zeroTierNodeOffline)]) [delegate zeroTierNodeOffline];
            break;
        }
        case ZTS_EVENT_NODE_DOWN: {
            [_lock lock]; _nodeStatus = ZeroTierNodeStatusStopped; _isStarted = NO; [_lock unlock];
            if ([delegate respondsToSelector:@selector(zeroTierNodeDown)]) [delegate zeroTierNodeDown];
            break;
        }
        case ZTS_EVENT_NETWORK_OK: {
            // Key fix (mitigating iOS background event pile-up):
            // After the app enters the background on iOS the main RunLoop is suspended and all libzt events pile up on the main queue.
            // They all run at once when returning to the foreground, which can fire the NETWORK_OK event for the same network several times.
            // State deduplication is used here: if the network is already in the OK state, the semaphore and the delegate callback are skipped,
            // which avoids spuriously triggering waitForNetworkReady higher up and repeated UI refresh flicker.
            // The first OK event (no record in _networkStatuses, or a different status) is handled normally.
            [_lock lock];
            NSNumber *existingStatus = _networkStatuses[@(netID)];
            BOOL isDuplicate = (existingStatus != nil &&
                                existingStatus.integerValue == ZeroTierNetworkStatusOk);
            _networkStatuses[@(netID)] = @(ZeroTierNetworkStatusOk);
            [_lock unlock];
            if (isDuplicate) {
                NSLog(@"[ZeroTierBridge] received duplicate NETWORK_OK event (netID=%llu), skipping signal and callback", netID);
                break;
            }
            dispatch_semaphore_signal(_networkEventSemaphore);
            if ([delegate respondsToSelector:@selector(zeroTierNetworkReady:ipv4:ipv6:)]) {
                [delegate zeroTierNetworkReady:netID ipv4:[self ipv4AddressForNetwork:netID] ipv6:[self ipv6AddressForNetwork:netID]];
            }
            break;
        }
        case ZTS_EVENT_NETWORK_REQ_CONFIG: {
            [_lock lock]; _networkStatuses[@(netID)] = @(ZeroTierNetworkStatusRequestingConfig); [_lock unlock];
            dispatch_semaphore_signal(_networkEventSemaphore);
            break;
        }
        // Unified handling of network failure events: update the status + signal the semaphore + invoke the matching callback
        case ZTS_EVENT_NETWORK_ACCESS_DENIED:
        case ZTS_EVENT_NETWORK_NOT_FOUND:
        case ZTS_EVENT_NETWORK_CLIENT_TOO_OLD:
        case ZTS_EVENT_NETWORK_DOWN: {
            ZeroTierNetworkStatus status = ZeroTierNetworkStatusUnknown;
            SEL callback = NULL;
            switch (eventCode) {
                case ZTS_EVENT_NETWORK_ACCESS_DENIED: status = ZeroTierNetworkStatusAccessDenied; callback = @selector(zeroTierNetworkAccessDenied:); break;
                case ZTS_EVENT_NETWORK_NOT_FOUND: status = ZeroTierNetworkStatusNotFound; callback = @selector(zeroTierNetworkNotFound:); break;
                case ZTS_EVENT_NETWORK_CLIENT_TOO_OLD: status = ZeroTierNetworkStatusClientTooOld; callback = @selector(zeroTierNetworkClientTooOld:); break;
                case ZTS_EVENT_NETWORK_DOWN: status = ZeroTierNetworkStatusDown; callback = @selector(zeroTierNetworkDown:); break;
            }
            // State deduplication: as with NETWORK_OK, this avoids a batch of identical failure events piling up in the background from all firing
            [_lock lock];
            NSNumber *existingStatus = _networkStatuses[@(netID)];
            BOOL isDuplicate = (existingStatus != nil &&
                                existingStatus.integerValue == (NSInteger)status);
            _networkStatuses[@(netID)] = @(status);
            [_lock unlock];
            if (isDuplicate) {
                NSLog(@"[ZeroTierBridge] received duplicate network failure event (code=%d, netID=%llu), skipping signal and callback",
                      eventCode, netID);
                break;
            }
            dispatch_semaphore_signal(_networkEventSemaphore);
            if (callback && [delegate respondsToSelector:callback]) {
                NSInvocation *inv = [NSInvocation invocationWithMethodSignature:[(id)delegate methodSignatureForSelector:callback]];
                [inv setTarget:(id)delegate];
                [inv setSelector:callback];
                [inv setArgument:&netID atIndex:2];
                [inv invoke];
            }
            break;
        }
        case ZTS_EVENT_ADDR_ADDED_IP4:
        case ZTS_EVENT_ADDR_ADDED_IP6: {
            uint64_t addrNetID = [eventData[@"addrNetID"] unsignedLongLongValue];
            NSString *addr = eventData[@"addrStr"];
            int family = [eventData[@"addrFamily"] intValue];
            BOOL addrChanged = NO;
            if (addr) {
                [_lock lock];
                if (family == ZTS_AF_INET) {
                    NSString *old = _ipv4Addresses[@(addrNetID)];
                    addrChanged = ![addr isEqualToString:old];
                    _ipv4Addresses[@(addrNetID)] = addr;
                } else if (family == ZTS_AF_INET6) {
                    NSString *old = _ipv6Addresses[@(addrNetID)];
                    addrChanged = ![addr isEqualToString:old];
                    _ipv6Addresses[@(addrNetID)] = addr;
                }
                [_lock unlock];
            }
            // Key fix (mitigating iOS background event pile-up):
            // If the address has not changed (a repeated ADDR_ADDED event), skip the semaphore and the delegate callback,
            // so that a batch of same-address events piled up in the background does not fire zeroTierNetworkReady: repeatedly and make the UI flicker.
            // On the first address assignment there is no record in _ipv4Addresses/_ipv6Addresses, so addrChanged=YES and it is handled normally.
            if (!addrChanged) {
                NSLog(@"[ZeroTierBridge] received duplicate ADDR_ADDED event (netID=%llu), skipping signal and callback", addrNetID);
                break;
            }
            dispatch_semaphore_signal(_networkEventSemaphore);
            if ([delegate respondsToSelector:@selector(zeroTierNetworkReady:ipv4:ipv6:)] && [self isNetworkReady:addrNetID]) {
                [delegate zeroTierNetworkReady:addrNetID ipv4:[self ipv4AddressForNetwork:addrNetID] ipv6:[self ipv6AddressForNetwork:addrNetID]];
            }
            break;
        }
        default:
            break;
    }
}

#pragma mark - Socket client operations

- (int)createTCPSocket {
    return zts_bsd_socket(ZTS_AF_INET, ZTS_SOCK_STREAM, ZTS_IPPROTO_TCP);
}

- (int)createTCPSocketForFamily:(int)family {
    return zts_bsd_socket(family, ZTS_SOCK_STREAM, ZTS_IPPROTO_TCP);
}

- (int)connectSocket:(int)fd toHost:(NSString *)host port:(uint16_t)port timeout:(NSTimeInterval)timeout {
    if (!host.length || fd < 0) return ZTS_ERR_ARG;

    // Set the recv/send timeouts
    if (timeout > 0) {
        struct zts_timeval tv;
        tv.tv_sec = (long)timeout;
        tv.tv_usec = (long)((timeout - (NSTimeInterval)tv.tv_sec) * 1000000);
        if (tv.tv_usec < 0) tv.tv_usec = 0;
        zts_bsd_setsockopt(fd, ZTS_SOL_SOCKET, ZTS_SO_RCVTIMEO, &tv, sizeof(tv));
        zts_bsd_setsockopt(fd, ZTS_SOL_SOCKET, ZTS_SO_SNDTIMEO, &tv, sizeof(tv));
    }

    // Prepare the target address
    const char *hostCStr = [host UTF8String];
    struct zts_sockaddr_storage addrStorage;
    memset(&addrStorage, 0, sizeof(addrStorage));
    socklen_t addrLen = 0;

    BOOL isIPv6 = (zts_inet_pton(ZTS_AF_INET6, hostCStr, NULL) == 1);
    if (isIPv6) {
        struct zts_sockaddr_in6 *addr6 = (struct zts_sockaddr_in6 *)&addrStorage;
        addr6->sin6_len = sizeof(struct zts_sockaddr_in6);
        addr6->sin6_family = ZTS_AF_INET6;
        addr6->sin6_port = htons(port);
        if (zts_inet_pton(ZTS_AF_INET6, hostCStr, &addr6->sin6_addr) != 1) return ZTS_ERR_ARG;
        addrLen = sizeof(struct zts_sockaddr_in6);
    } else {
        struct zts_sockaddr_in *addr = (struct zts_sockaddr_in *)&addrStorage;
        addr->sin_len = sizeof(struct zts_sockaddr_in);
        addr->sin_family = ZTS_AF_INET;
        addr->sin_port = htons(port);
        if (zts_inet_pton(ZTS_AF_INET, hostCStr, &addr->sin_addr) != 1) return ZTS_ERR_ARG;
        addrLen = sizeof(struct zts_sockaddr_in);
    }

    // Non-blocking connect + select to implement the timeout
    int origFlags = zts_bsd_fcntl(fd, ZTS_F_GETFL, 0);
    if (origFlags < 0) {
        return zts_bsd_connect(fd, (const struct zts_sockaddr *)&addrStorage, addrLen);
    }
    zts_bsd_fcntl(fd, ZTS_F_SETFL, origFlags | ZTS_O_NONBLOCK);

    int connectResult = zts_bsd_connect(fd, (const struct zts_sockaddr *)&addrStorage, addrLen);
    if (connectResult == ZTS_ERR_OK) {
        zts_bsd_fcntl(fd, ZTS_F_SETFL, origFlags);
        return ZTS_ERR_OK;
    }
    if (zts_errno != ZTS_EINPROGRESS) {
        zts_bsd_fcntl(fd, ZTS_F_SETFL, origFlags);
        return connectResult;
    }

    zts_fd_set writeFds;
    ZTS_FD_ZERO(&writeFds);
    ZTS_FD_SET(fd, &writeFds);
    struct zts_timeval selectTimeout;
    selectTimeout.tv_sec = (long)timeout;
    selectTimeout.tv_usec = (long)((timeout - (NSTimeInterval)selectTimeout.tv_sec) * 1000000);
    if (selectTimeout.tv_usec < 0) selectTimeout.tv_usec = 0;

    int selectResult = zts_bsd_select(fd + 1, NULL, &writeFds, NULL, &selectTimeout);
    zts_bsd_fcntl(fd, ZTS_F_SETFL, origFlags);
    if (selectResult <= 0) return ZTS_ERR_SOCKET;

    int socketError = 0;
    socklen_t errorLen = sizeof(socketError);
    if (zts_bsd_getsockopt(fd, ZTS_SOL_SOCKET, ZTS_SO_ERROR, &socketError, &errorLen) != ZTS_ERR_OK) return ZTS_ERR_SOCKET;
    if (socketError != 0) return ZTS_ERR_SOCKET;

    // Set TCP_NODELAY to lower interactive latency
    int noDelay = 1;
    zts_bsd_setsockopt(fd, ZTS_IPPROTO_TCP, ZTS_TCP_NODELAY, &noDelay, sizeof(noDelay));
    return ZTS_ERR_OK;
}

- (int)closeSocket:(int)fd { return zts_bsd_close(fd); }
- (int)shutdownSocket:(int)fd how:(int)how { return zts_bsd_shutdown(fd, how); }
- (ssize_t)sendData:(int)fd buffer:(const void *)buf length:(size_t)len { return zts_bsd_send(fd, buf, len, 0); }
- (ssize_t)recvData:(int)fd buffer:(void *)buf length:(size_t)len { return zts_bsd_recv(fd, buf, len, 0); }

#pragma mark - Socket server API (used by PortForwarder host mode)

- (int)createListenSocket {
    return zts_bsd_socket(ZTS_AF_INET, ZTS_SOCK_STREAM, ZTS_IPPROTO_TCP);
}

- (int)bindSocket:(int)fd toPort:(uint16_t)port {
    if (fd < 0) return ZTS_ERR_ARG;
    int reuse = 1;
    zts_bsd_setsockopt(fd, ZTS_SOL_SOCKET, ZTS_SO_REUSEADDR, &reuse, sizeof(reuse));
    struct zts_sockaddr_in addr;
    memset(&addr, 0, sizeof(addr));
    addr.sin_len = sizeof(struct zts_sockaddr_in);
    addr.sin_family = ZTS_AF_INET;
    addr.sin_port = htons(port);
    addr.sin_addr.s_addr = ZTS_INADDR_ANY;
    return zts_bsd_bind(fd, (const struct zts_sockaddr *)&addr, sizeof(addr));
}

- (int)listenOnSocket:(int)fd {
    if (fd < 0) return ZTS_ERR_ARG;
    return zts_bsd_listen(fd, 128);
}

- (int)acceptOnSocket:(int)fd {
    if (fd < 0) return ZTS_ERR_ARG;
    return zts_bsd_accept(fd, NULL, NULL);
}

#pragma mark - Utility methods

+ (uint64_t)parseNetworkIDFromString:(NSString *)networkIDStr {
    if (!networkIDStr.length) return 0;
    return strtoull([networkIDStr UTF8String], NULL, 16);
}

+ (NSString *)formatNetworkID:(uint64_t)networkID {
    return [NSString stringWithFormat:@"%016llx", networkID];
}

@end
