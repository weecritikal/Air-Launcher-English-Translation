//
//  ZeroTierBridge.h
//  Angel Aura Amethyst
//
//  Objective-C wrapper layer for the ZeroTier libzt C API (slimmed-down version)
//
//  Design notes:
//    This file is the Objective-C wrapper for ZeroTier's official Apple framework (zt.framework),
//    modeled on the concise implementation of ShardLauncher-iOS plus the official libzt samples, keeping only the essentials:
//      - Node start/stop
//      - Joining/leaving a network
//      - Address lookup
//      - Client/server socket operations (used by SOCKS5Proxy and PortForwarder)
//      - Forwarding events to the main thread
//
//  Complex logic that was removed:
//    - Keychain identity backup/restore (replaced by re-authorizing a new node on my.zerotier.com)
//    - Automatic reconnect with exponential backoff (replaced by a single retry when returning to the foreground)
//    - Keep-alive timer (libzt has its own NAT keepalive)
//    - Redundant query interfaces such as peer connection mode and network details
//

#import <Foundation/Foundation.h>
#import "external/ZeroTierFramework/ios-example-app/zt.framework/Headers/ZeroTierSockets.h"

NS_ASSUME_NONNULL_BEGIN

// Forward declaration: the delegate protocol methods need to reference the ZeroTierBridge type
@class ZeroTierBridge;

/// ZeroTier node status
typedef NS_ENUM(NSInteger, ZeroTierNodeStatus) {
    ZeroTierNodeStatusStopped = 0,  // The node has stopped (not started or shut down)
    ZeroTierNodeStatusStarting,     // The node is starting (zts_node_start has been called, waiting for the ONLINE event)
    ZeroTierNodeStatusOnline,       // The node is online (at least one upstream node is reachable)
    ZeroTierNodeStatusOffline,      // The node is offline (the network is unreachable)
};

/// ZeroTier network status
typedef NS_ENUM(NSInteger, ZeroTierNetworkStatus) {
    ZeroTierNetworkStatusUnknown = 0,           // Status unknown (not joined, or no event received yet)
    ZeroTierNetworkStatusRequestingConfig,      // Requesting the network configuration
    ZeroTierNetworkStatusOk,                    // Successfully joined the network (the configuration is ready)
    ZeroTierNetworkStatusAccessDenied,          // Join was denied (the node is not authorized)
    ZeroTierNetworkStatusNotFound,              // The network does not exist
    ZeroTierNetworkStatusClientTooOld,          // The ZeroTier client version is too old
    ZeroTierNetworkStatusDown,                  // The network controller is unreachable
};

/// ZeroTierBridge delegate protocol
///
/// Every method is @optional, and every callback is invoked on the main thread.
@protocol ZeroTierBridgeDelegate <NSObject>
@optional

/// The node is online
- (void)zeroTierNodeOnlineWithID:(uint64_t)nodeID;

/// The node is offline (the network is unreachable)
- (void)zeroTierNodeOffline;

/// The node has shut down (zts_node_stop completed)
- (void)zeroTierNodeDown;

/// The network is ready (an IP address assignment has been received)
- (void)zeroTierNetworkReady:(uint64_t)networkID
                        ipv4:(nullable NSString *)ipv4
                        ipv6:(nullable NSString *)ipv6;

/// The network does not exist
- (void)zeroTierNetworkNotFound:(uint64_t)networkID;

/// Network access denied (the node is not authorized)
- (void)zeroTierNetworkAccessDenied:(uint64_t)networkID;

/// The ZeroTier client version is too old
- (void)zeroTierNetworkClientTooOld:(uint64_t)networkID;

/// The network controller is unreachable
- (void)zeroTierNetworkDown:(uint64_t)networkID;

@end

/// ZeroTier bridge class (an Objective-C wrapper for the libzt C API)
///
/// A singleton; obtain the single global instance through +sharedInstance.
@interface ZeroTierBridge : NSObject

/// Singleton accessor
+ (instancetype)sharedInstance;

/// Delegate object (a weak reference, to avoid a retain cycle)
@property (nonatomic, weak, nullable) id<ZeroTierBridgeDelegate> delegate;

#pragma mark - 节点管理

/// Start the ZeroTier node
/// @param homeDir the directory where identity files are stored
/// @param error Error output (on failure)
/// @return YES if the start request was submitted successfully (which does not mean the node is online)
- (BOOL)startNodeWithHomeDirectory:(NSString *)homeDir
                             error:(NSError **)error;

/// Stop the ZeroTier node and clear the internal state caches
- (void)stopNode;

/// Whether the node is online
- (BOOL)isNodeOnline;

/// Get the node ID (returns 0 when the node is not online)
- (uint64_t)nodeID;

/// Get the node status
- (ZeroTierNodeStatus)nodeStatus;

#pragma mark - 网络管理

/// Join a ZeroTier network
- (BOOL)joinNetwork:(uint64_t)networkID error:(NSError **)error;

/// Leave a ZeroTier network
- (BOOL)leaveNetwork:(uint64_t)networkID;

/// Get the network status
- (ZeroTierNetworkStatus)networkStatus:(uint64_t)networkID;

/// Get the IPv4 address assigned by the network (nil if none was assigned)
- (nullable NSString *)ipv4AddressForNetwork:(uint64_t)networkID;

/// Get the IPv6 address assigned by the network (nil if none was assigned)
- (nullable NSString *)ipv6AddressForNetwork:(uint64_t)networkID;

#pragma mark - 框架检测与等待

/// Detect whether zt.framework is available (i.e. not a stub)
///
/// The first call detects it from the zts_node_start() return value, and the result is cached.
- (BOOL)isFrameworkAvailable;

/// Wait for the node to come online (waits on a semaphore for the event, returning NO on timeout)
- (BOOL)waitForNodeOnlineWithTimeout:(NSTimeInterval)timeout;

/// Wait for the network to become ready (waits on a semaphore for the event, returning NO on timeout)
- (BOOL)waitForNetworkReady:(uint64_t)networkID timeout:(NSTimeInterval)timeout;

#pragma mark - Socket 客户端操作（供 SOCKS5Proxy 和 PortForwarder 房客模式使用）

/// Create a TCP socket (wraps zts_bsd_socket, IPv4)
- (int)createTCPSocket;

/// Create a TCP socket (with an explicit address family)
- (int)createTCPSocketForFamily:(int)family;

/// Connect a socket to the target host
- (int)connectSocket:(int)fd
              toHost:(NSString *)host
                port:(uint16_t)port
             timeout:(NSTimeInterval)timeout;

/// Close a socket
- (int)closeSocket:(int)fd;

/// Shut down the read/write side of a socket
- (int)shutdownSocket:(int)fd how:(int)how;

/// Send data
- (ssize_t)sendData:(int)fd
             buffer:(const void *)buf
              length:(size_t)len;

/// Receive data
- (ssize_t)recvData:(int)fd
             buffer:(void *)buf
              length:(size_t)len;

#pragma mark - Socket 服务端 API（供 PortForwarder 房主模式使用）

/// Create a libzt TCP socket and return the fd (< 0 means failure)
- (int)createListenSocket;

/// Bind to 0.0.0.0:port; a return value of 0 means success
- (int)bindSocket:(int)fd toPort:(uint16_t)port;

/// Listen (backlog=128); a return value of 0 means success
- (int)listenOnSocket:(int)fd;

/// Accept a connection and return the client fd (< 0 means failure)
- (int)acceptOnSocket:(int)fd;

#pragma mark - 工具方法

/// Parse a network ID from a hexadecimal string (returns 0 if parsing fails)
+ (uint64_t)parseNetworkIDFromString:(NSString *)networkIDStr;

/// Format a network ID as a 16-digit lowercase hexadecimal string
+ (NSString *)formatNetworkID:(uint64_t)networkID;

@end

NS_ASSUME_NONNULL_END
