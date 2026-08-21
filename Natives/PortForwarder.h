//
//  PortForwarder.h
//  Flux
//
//  TCP port forwarder (supporting both host and guest modes)
//
//  ============================================================================
//  Design notes
//  ============================================================================
//
//  This file implements a TCP port forwarder with two modes, so iOS can play with
//  PC/Mac/Android:
//
//  1. Guest mode:
//     a local BSD socket listens -> traffic is forwarded through a libzt socket to the remote ZeroTier IP
//     Used when an iOS guest connects to a host (PC/Mac/Android/iOS).
//     The guest enters 127.0.0.1:localPort in Minecraft to reach the host.
//
//  2. Host mode (reverse forwarding):
//     a libzt socket listens on the ZeroTier network -> traffic is forwarded to the local MC LAN port (a BSD socket)
//     Used when an iOS host accepts connections from PC/Mac/Android/iOS guests.
//     A guest joins by connecting straight to the host ZeroTier IP:listenPort in Minecraft.
//
//  Why port forwarding rather than a SOCKS5 proxy?
//
//  Minecraft has used Netty as its networking library since 1.7.2. The Netty NioSocketChannel
//  is built on java.nio.channels.SocketChannel, and SocketChannel does not consult the Java
//  ProxySelector. That means the JVM arguments -DsocksProxyHost/-DsocksProxyPort do nothing for
//  Minecraft multiplayer connections (they only affect java.net.Socket, as used for login authentication).
//
//  So when a guest enters the host ZeroTier IP (such as 10.147.17.1:54321) in Minecraft:
//    1. Minecraft Netty creates an NioSocketChannel
//    2. NioSocketChannel creates a SocketChannel directly
//    3. SocketChannel tries to connect straight to 10.147.17.1:54321
//    4. the system has no ZeroTier network interface (we use in-process libzt)
//    5. the system cannot route to 10.147.17.1
//    6. the connection fails with "could not connect"
//
//  The guest-mode port forwarding approach:
//    1. listen on a local TCP port (such as 127.0.0.1:25565)
//    2. when Minecraft connects to 127.0.0.1:25565, connect through the libzt socket API to
//       the host ZeroTier IP:port
//    3. forward data in both directions
//    4. the guest enters 127.0.0.1:25565 in Minecraft to connect
//
//  The host-mode reverse forwarding approach:
//    1. listen on a port within the ZeroTier network through the libzt socket API (such as 0.0.0.0:25565)
//    2. accept the connection when a guest reaches the host IP:25565 over the ZeroTier network
//    3. create a local BSD socket connected to 127.0.0.1:localHostPort (the MC LAN port)
//    4. forward data in both directions (libzt socket <-> local BSD socket)
//    5. the guest connects straight to the host ZeroTier IP:25565 in Minecraft
//
//  The architecture:
//    Guest mode:
//      - listening socket: a system POSIX socket (socket/bind/listen/accept)
//      - client socket: a system POSIX socket (the fd accept returns)
//      - remote socket: a libzt socket (created through ZeroTierBridge)
//    Host mode:
//      - listening socket: a libzt socket (created through ZeroTierBridge)
//      - client socket: a libzt socket (the fd acceptOnSocket: returns)
//      - local socket: a system POSIX socket (connected to 127.0.0.1:localHostPort)
//    - forwarding uses a concurrent GCD queue, with both directions running at once
//
//  The relationship with ZeroTierBridge:
//    PortForwarder relies on the socket methods ZeroTierBridge provides to talk to the ZeroTier virtual network.
//    ZeroTierBridge must have started the node and joined the network before PortForwarder can work.
//
//  Notes:
//    - PortForwarder is a singleton (sharedForwarder)
//    - only one mode can run at a time (host or guest), so stop the old one before starting a new one
//    - the accept loop runs on a background thread, so the main thread is not blocked
//    - the forwarding threads use an autorelease pool and atomic operations for thread safety
//
//  =============================================================================

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// The default local listening port of the port forwarder (the default Minecraft server port)
extern const uint16_t PortForwarderDefaultLocalPort;

/// Port forwarding modes
typedef NS_ENUM(NSInteger, PortForwarderMode) {
    PortForwarderModeNone = 0,   ///< Not running
    PortForwarderModeGuest,      ///< Guest mode: listen locally -> forward to the remote ZeroTier IP
    PortForwarderModeHost,       ///< Host mode: listen on the ZeroTier network -> forward to the local MC LAN port
};

/// TCP port forwarder (supporting both host and guest modes)
///
/// A singleton, reached through +sharedForwarder.
/// Only one mode can run at a time, so stop the old one before starting a new one.
@interface PortForwarder : NSObject

/// Singleton accessor
+ (instancetype)sharedForwarder;

#pragma mark - Guest mode

/// Start guest mode: listen locally -> forward to the remote ZeroTier IP
///
/// Creates a POSIX socket listening on 127.0.0.1:localPort and accepts client connections on a background thread.
/// For each client, a libzt socket is created through ZeroTierBridge to connect to
/// hostIP:hostPort, and data is forwarded in both directions.
///
/// When localPort is 0, the system picks a free port.
/// When localPort is taken, localPort+1 through localPort+9 are tried.
///
/// @param localPort The local listening port (0 for automatic)
/// @param hostIP The remote host address (the host ZeroTier IP)
/// @param hostPort The remote port (the host MC LAN port)
/// @return YES when it started successfully, NO on failure
- (BOOL)startGuestModeWithLocalPort:(uint16_t)localPort
                              hostIP:(NSString *)hostIP
                            hostPort:(uint16_t)hostPort;

#pragma mark - Host mode

/// Start host mode: listen on the ZeroTier network -> forward to the local MC LAN port
///
/// Creates a libzt socket through ZeroTierBridge that listens on 0.0.0.0:listenPort within the
/// ZeroTier network, and accepts client connections on a background thread.
/// For each client, a local BSD socket is created connecting to 127.0.0.1:localHostPort,
/// and data is forwarded in both directions.
///
/// A guest (PC/Mac/Android/iOS) joins by connecting straight to the host ZeroTier IP:listenPort
/// in Minecraft.
///
/// @param listenPort The port to listen on within the ZeroTier network (usually 25565)
/// @param localHostPort The local MC LAN port (the one Minecraft shows in the chat box after "Open to LAN")
/// @return YES when it started successfully, NO on failure
- (BOOL)startHostModeWithListenPort:(uint16_t)listenPort
                       localHostPort:(uint16_t)localHostPort;

#pragma mark - Stopping

/// Stop port forwarding (stopping host and guest mode alike)
///
/// Closes the listening socket, so no new connections are accepted.
/// Existing client connections keep running until they finish and are then cleaned up.
- (void)stop;

#pragma mark - State queries

/// Whether the port forwarder is running
@property (nonatomic, readonly, getter=isRunning) BOOL running;

/// The current mode
@property (nonatomic, readonly) PortForwarderMode mode;

/// The current listening port
///
/// Guest mode: the local BSD socket listening port
/// Host mode: the libzt socket listening port within the ZeroTier network
@property (nonatomic, readonly) uint16_t listeningPort;

#pragma mark - Guest mode properties

/// Guest mode: the remote host currently forwarded to (the host ZeroTier IP)
@property (nonatomic, readonly, copy, nullable) NSString *hostIP;

/// Guest mode: the remote port currently forwarded to (the host MC LAN port)
@property (nonatomic, readonly) uint16_t hostPort;

#pragma mark - Host mode properties

/// Host mode: the local MC LAN port (the one Minecraft shows in the chat box after "Open to LAN")
@property (nonatomic, readonly) uint16_t localHostPort;

@end

NS_ASSUME_NONNULL_END
