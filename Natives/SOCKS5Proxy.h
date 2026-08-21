//
//  SOCKS5Proxy.h
//  Flux
//
//  A local SOCKS5 proxy server
//
//  ============================================================================
//  Design notes
//  ============================================================================
//
//  This file implements a local SOCKS5 proxy server that forwards Minecraft client traffic
//  to the host game server over the ZeroTier virtual network.
//
//  How it works:
//    1. the proxy listens on 127.0.0.1:port (1080 by default)
//    2. the Minecraft client is configured with a SOCKS5 proxy pointing at 127.0.0.1:port
//    3. once the client connects, it performs the SOCKS5 handshake (RFC 1928)
//    4. the proxy parses the destination the client asked for (the host ZeroTier IP + port)
//    5. the proxy creates a libzt socket through ZeroTierBridge to reach that destination
//    6. the proxy forwards data in both directions between the client socket and the ZeroTier socket
//
//  The architecture:
//    - listening socket: a system POSIX socket (socket/bind/listen/accept)
//    - client socket: a system POSIX socket (the fd accept returns)
//    - remote socket: a libzt socket (created through ZeroTierBridge)
//    - it is designed this way because the ZeroTier libzt socket is for virtual network traffic,
//      while listening locally only needs a system socket
//
//  The SOCKS5 protocol (RFC 1928):
//    1. handshake stage:
//       client -> proxy: VER(1) NMETHODS(1) METHODS(NMETHODS)
//       proxy -> client: VER(1) METHOD(1)
//    2. request stage:
//       client -> proxy: VER(1) CMD(1) RSV(1) ATYP(1) DST.ADDR(?) DST.PORT(2)
//       proxy -> client: VER(1) REP(1) RSV(1) ATYP(1) BND.ADDR(?) BND.PORT(2)
//    3. forwarding stage: data flows in both directions
//
//  The relationship with ZeroTierBridge:
//    SOCKS5Proxy relies on the socket methods ZeroTierBridge provides (createTCPSocket,
//    connectSocket:toHost:port:timeout:、sendData:buffer:length:、
//    recvData:buffer:length:, closeSocket:) to talk to the ZeroTier virtual network.
//    ZeroTierBridge must have started the node and joined the network before SOCKS5Proxy can work.
//
//  ============================================================================

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// The default SOCKS5 proxy listening port
extern const uint16_t SOCKS5ProxyDefaultPort;

/// The client connected notification
/// userInfo: { @"clientIP": NSString, @"clientPort": NSNumber }
extern NSNotificationName const SOCKS5ProxyClientConnectedNotification;

/// The client disconnected notification
/// userInfo: { @"reason": NSString }
extern NSNotificationName const SOCKS5ProxyClientDisconnectedNotification;

/// A local SOCKS5 proxy server
///
/// A singleton, reached through +sharedProxy.
/// The proxy listens on 127.0.0.1 and forwards client traffic to the destination over the ZeroTier virtual network.
@interface SOCKS5Proxy : NSObject

/// Singleton accessor
+ (instancetype)sharedProxy;

/// Start the proxy server
///
/// Creates a POSIX socket listening on 127.0.0.1:port and accepts client connections on a background thread.
/// When port is 0, the system picks a free port (which listeningPort then reports).
///
/// It checks whether the ZeroTier framework is available before starting, and refuses to start when it is not
/// (stub mode).
///
/// @param port The listening port (0 for automatic)
/// @param error Error output (on failure)
/// @return YES when it started successfully
- (BOOL)startWithPort:(uint16_t)port
                error:(NSError **)error;

/// Stop the proxy server
///
/// Closes the listening socket, so no new connections are accepted.
/// Existing client connections keep running until they finish and are then cleaned up.
- (void)stop;

/// Whether the proxy server is running
/// @return YES when it is running
- (BOOL)isRunning;

/// The current listening port
/// @return The listening port (0 when it is not running)
- (uint16_t)listeningPort;

@end

NS_ASSUME_NONNULL_END
