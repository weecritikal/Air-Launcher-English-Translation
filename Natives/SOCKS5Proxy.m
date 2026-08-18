//
//  SOCKS5Proxy.m
//  Angel Aura Amethyst
//
//  Local SOCKS5 proxy server implementation
//
//  ============================================================================
//  Implementation notes
//  ============================================================================
//
//  This file implements the local SOCKS5 proxy server declared in SOCKS5Proxy.h.
//
//  Key implementation points:
//    1. the listening socket is a system POSIX socket (socket/bind/listen/accept)
//    2. once a client connects, the SOCKS5 handshake and data forwarding run on a new thread
//    3. the SOCKS5 implementation follows RFC 1928, supporting the no-auth method and the CONNECT command
//    4. the destination address can be IPv4, IPv6 or a domain name
//    5. the remote connection is made through the libzt socket API of ZeroTierBridge
//    6. bidirectional forwarding uses a concurrent GCD queue, with both directions running at once
//    7. every local variable assigned inside a block carries the __block qualifier
//
//  The threading model:
//    - main thread: startWithPort:error: / stop
//    - accept thread: an NSThread looping over new connections
//    - client handling threads: an NSThread per client
//    - forwarding tasks: a concurrent GCD queue with two tasks per connection (client->remote and remote->client)
//
//  The SOCKS5 protocol constants (RFC 1928):
//    VER = 0x05 (SOCKS version 5)
//    METHOD_NO_AUTH = 0x00 (no authentication)
//    METHOD_NO_ACCEPTABLE = 0xFF (no acceptable authentication method)
//    CMD_CONNECT = 0x01 (the CONNECT command)
//    ATYP_IPV4 = 0x01 (an IPv4 address)
//    ATYP_DOMAIN = 0x03 (a domain name)
//    ATYP_IPV6 = 0x04 (an IPv6 address)
//
//  ============================================================================

#import "SOCKS5Proxy.h"
#import "ZeroTierBridge.h"
#import "utils.h"

// POSIX socket headers
#include <sys/socket.h>
#include <netinet/in.h>
#include <netinet/tcp.h>  // TCP_NODELAY
#include <arpa/inet.h>
#include <unistd.h>
#include <string.h>
#include <errno.h>
#include <sys/select.h>
#include <sys/time.h>
#include <stdatomic.h>  // C11 atomics
#include <netdb.h>      // getaddrinfo (domain name resolution, used by P0-2)

#pragma mark - Constant definitions

/// The default SOCKS5 proxy listening port
const uint16_t SOCKS5ProxyDefaultPort = 1080;

/// The client connected notification name
NSNotificationName const SOCKS5ProxyClientConnectedNotification = @"SOCKS5ProxyClientConnectedNotification";

/// The client disconnected notification name
NSNotificationName const SOCKS5ProxyClientDisconnectedNotification = @"SOCKS5ProxyClientDisconnectedNotification";

/// Error domain
static NSString * const kSOCKS5ProxyErrorDomain = @"SOCKS5ProxyErrorDomain";

/// Error codes
typedef NS_ENUM(NSInteger, SOCKS5ProxyErrorCode) {
    SOCKS5ProxyErrorCodeAlreadyRunning        = 1, // The proxy is already running
    SOCKS5ProxyErrorCodeSocketCreateFailed    = 2, // Creating the socket failed
    SOCKS5ProxyErrorCodeBindFailed            = 3, // Binding the port failed
    SOCKS5ProxyErrorCodeListenFailed          = 4, // Listening failed
    SOCKS5ProxyErrorCodeFrameworkUnavailable  = 5, // The ZeroTier framework is unavailable
};

/// The SOCKS5 protocol constants (RFC 1928)
#define SOCKS5_VERSION                 0x05
#define SOCKS5_METHOD_NO_AUTH          0x00
#define SOCKS5_METHOD_USER_PASS        0x02
#define SOCKS5_METHOD_NO_ACCEPTABLE    0xFF
#define SOCKS5_CMD_CONNECT             0x01
#define SOCKS5_CMD_BIND                0x02
#define SOCKS5_CMD_UDP_ASSOCIATE       0x03
#define SOCKS5_ATYP_IPV4               0x01
#define SOCKS5_ATYP_DOMAIN             0x03
#define SOCKS5_ATYP_IPV6               0x04

/// The SOCKS5 reply codes (RFC 1928 section 6)
#define SOCKS5_REP_SUCCESS                    0x00
#define SOCKS5_REP_GENERAL_FAILURE            0x01
#define SOCKS5_REP_NOT_ALLOWED                0x02
#define SOCKS5_REP_NETWORK_UNREACHABLE        0x03
#define SOCKS5_REP_HOST_UNREACHABLE           0x04
#define SOCKS5_REP_CONNECTION_REFUSED         0x05
#define SOCKS5_REP_TTL_EXPIRED                0x06
#define SOCKS5_REP_COMMAND_NOT_SUPPORTED      0x07
#define SOCKS5_REP_ADDRESS_TYPE_NOT_SUPPORTED 0x08

/// The data forwarding buffer size (64KB)
#define SOCKS5_BUFFER_SIZE 65536

/// The timeout for connecting to a remote host (seconds)
#define SOCKS5_CONNECT_TIMEOUT 30.0

/// The client socket read/write timeout (seconds)
/// Stops a malicious client sending part of the data and then holding the connection open, blocking a server thread forever
#define SOCKS5_CLIENT_IO_TIMEOUT 30

/// The client handshake read/write timeout (seconds)
#define SOCKS5_HANDSHAKE_TIMEOUT 15

#pragma mark - Helper functions

/// Read exactly the given number of bytes (with a timeout)
///
/// The read() system call may not return every requested byte at once, so it has to loop.
/// This function blocks until it has read the requested length or the connection closes.
///
/// Key fix (H9): select provides the timeout, so a malicious client cannot send part of the data
/// and then hold the connection open without sending more, blocking a server thread forever.
///
/// @param fd The socket file descriptor
/// @param buf The receive buffer
/// @param len The number of bytes to read
/// @param timeoutSec The timeout in seconds (<=0 means blocking mode with no timeout)
/// @return The number of bytes actually read (< len means the connection closed or errored, and -1 means an error or a timeout)
static ssize_t readAllWithTimeout(int fd, void *buf, size_t len, int timeoutSec) {
    size_t totalRead = 0;
    uint8_t *p = (uint8_t *)buf;

    while (totalRead < len) {
        // Use select to check whether the socket is readable, with a timeout
        if (timeoutSec > 0) {
            fd_set readFds;
            FD_ZERO(&readFds);
            FD_SET(fd, &readFds);

            struct timeval tv;
            tv.tv_sec = timeoutSec;
            tv.tv_usec = 0;

            int selectResult = select(fd + 1, &readFds, NULL, NULL, &tv);
            if (selectResult < 0) {
                if (errno == EINTR) {
                    continue;
                }
                NSLog(@"[SOCKS5Proxy] readAll select error: errno = %d, fd = %d", errno, fd);
                return -1;
            }
            if (selectResult == 0) {
                // Timed out
                NSLog(@"[SOCKS5Proxy] readAll timeout (%d sec), fd = %d, read %zu/%zu bytes",
                      timeoutSec, fd, totalRead, len);
                return totalRead > 0 ? (ssize_t)totalRead : -1;
            }
        }

        ssize_t n = read(fd, p + totalRead, len - totalRead);
        if (n < 0) {
            // Interrupted by a signal, so retry
            if (errno == EINTR) {
                continue;
            }
            // Another error
            NSLog(@"[SOCKS5Proxy] readAll error: errno = %d, fd = %d", errno, fd);
            return -1;
        }
        if (n == 0) {
            // The connection has closed
            return (ssize_t)totalRead;
        }
        totalRead += (size_t)n;
    }

    return (ssize_t)totalRead;
}

/// Compatibility with older callers: readAll with no timeout (for a socket that already has SO_RCVTIMEO set)
static ssize_t readAll(int fd, void *buf, size_t len) {
    return readAllWithTimeout(fd, buf, len, 0);
}

/// Write exactly the given number of bytes (with a timeout)
///
/// The write() system call may not write every byte at once, so it has to loop.
///
/// Key fix (M9): a write returning 0 counts as an error (the peer may have closed).
///
/// @param fd The socket file descriptor
/// @param buf The write buffer
/// @param len The number of bytes to write
/// @param timeoutSec The timeout in seconds (<=0 means blocking mode with no timeout)
/// @return The number of bytes actually written (< len means an error, and -1 means an error or a timeout)
static ssize_t writeAllWithTimeout(int fd, const void *buf, size_t len, int timeoutSec) {
    size_t totalWritten = 0;
    const uint8_t *p = (const uint8_t *)buf;

    while (totalWritten < len) {
        // Use select to check whether the socket is writable, with a timeout
        if (timeoutSec > 0) {
            fd_set writeFds;
            FD_ZERO(&writeFds);
            FD_SET(fd, &writeFds);

            struct timeval tv;
            tv.tv_sec = timeoutSec;
            tv.tv_usec = 0;

            int selectResult = select(fd + 1, NULL, &writeFds, NULL, &tv);
            if (selectResult < 0) {
                if (errno == EINTR) {
                    continue;
                }
                NSLog(@"[SOCKS5Proxy] writeAll select error: errno = %d, fd = %d", errno, fd);
                return -1;
            }
            if (selectResult == 0) {
                // Timed out
                NSLog(@"[SOCKS5Proxy] writeAll timeout (%d sec), fd = %d, wrote %zu/%zu bytes",
                      timeoutSec, fd, totalWritten, len);
                return totalWritten > 0 ? (ssize_t)totalWritten : -1;
            }
        }

        ssize_t n = write(fd, p + totalWritten, len - totalWritten);
        if (n < 0) {
            if (errno == EINTR) {
                continue;
            }
            NSLog(@"[SOCKS5Proxy] writeAll error: errno = %d, fd = %d", errno, fd);
            return -1;
        }
        if (n == 0) {
            // Key fix (M9): a write returning 0 usually means an error (the peer has closed, or the buffer is full)
            NSLog(@"[SOCKS5Proxy] writeAll returned 0, peer may have closed: fd = %d", fd);
            return -1;
        }
        totalWritten += (size_t)n;
    }

    return (ssize_t)totalWritten;
}

/// Compatibility with older callers: writeAll with no timeout
static ssize_t writeAll(int fd, const void *buf, size_t len) {
    return writeAllWithTimeout(fd, buf, len, 0);
}

#pragma mark - SOCKS5Proxy class extension

@interface SOCKS5Proxy () {
    /// The listening socket file descriptor (guarded by _lock)
    int _listenFD;

    /// The actual listening port (guarded by _lock)
    uint16_t _listeningPort;

    /// Whether it is running (guarded by _lock)
    BOOL _running;

    /// The accept thread (accepting new client connections)
    NSThread *_acceptThread;

    /// The lock guarding every internal state variable
    NSLock *_lock;

    /// The list of active client handling threads (guarded by _lock)
    NSMutableArray<NSThread *> *_clientThreads;

    /// Key fix (C1): the list of active client socket fds (guarded by _lock)
    /// Used by stop to shut every client connection down, forcing read/write to return,
    /// so a client thread blocked on IO cannot hang around and leak.
    NSMutableArray<NSNumber *> *_clientFDs;

    /// Key fix (M12): the list of active remote (libzt) socket fds (guarded by _lock)
    /// Used by stop to shut every remote connection down, forcing recv/send to return,
    /// so a client thread inside forwardDataBetweenClientFD: does not sit blocked in recvData:remoteFD:
    /// for up to 30 seconds (the SO_RCVTIMEO set by SOCKS5_CONNECT_TIMEOUT).
    ///
    /// stop used to shut down only the client fds and ignore the remote ones:
    ///   1. the client->remote task exited because read(clientFD) returned 0
    ///   2. the remote->client task stayed blocked in recvData:remoteFD:
    ///      (shutdown(clientFD, SHUT_WR) only closes the write side of the client fd and does not affect the read side of the remote fd)
    ///   3. dispatch_group_wait(group, DISPATCH_TIME_FOREVER) waited for both directions to finish
    ///   4. so the client thread lived on for up to 30 seconds after stop returned, temporarily leaking a thread and an fd
    ///
    /// The fix: track every remote fd and call shutdown(SHUT_RDWR) on each of them in stop,
    /// forcing recvData: to return immediately so the client thread exits quickly.
    NSMutableArray<NSNumber *> *_remoteFDs;
}
@end

#pragma mark - SOCKS5Proxy implementation

@implementation SOCKS5Proxy

#pragma mark - Singleton

/// Get the shared SOCKS5Proxy singleton
/// dispatch_once guarantees thread-safe one-time initialization
+ (instancetype)sharedProxy {
    static SOCKS5Proxy *shared = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        shared = [[self alloc] init];
    });
    return shared;
}

/// allocWithZone: is overridden so alloc/init cannot create a second instance
+ (instancetype)allocWithZone:(struct _NSZone *)zone {
    static SOCKS5Proxy *shared = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        shared = [super allocWithZone:zone];
    });
    return shared;
}

/// The private initializer
- (instancetype)init {
    self = [super init];
    if (self) {
        _listenFD = -1;
        _listeningPort = 0;
        _running = NO;
        _acceptThread = nil;
        _lock = [[NSLock alloc] init];
        _clientThreads = [[NSMutableArray alloc] init];
        _clientFDs = [[NSMutableArray alloc] init];
        _remoteFDs = [[NSMutableArray alloc] init];

        NSLog(@"[SOCKS5Proxy] Singleton initialized");
    }
    return self;
}

#pragma mark - Starting and stopping

/// Start the proxy server
///
/// The flow:
///   1. check whether it is already running
///   2. check that the ZeroTier framework is available
///   3. create the POSIX socket
///   4. set SO_REUSEADDR
///   5. bind to 127.0.0.1:port
///   6. read back the port actually bound
///   7. start listening
///   8. start the accept thread
- (BOOL)startWithPort:(uint16_t)port
                error:(NSError **)error {
    // Key fix (H8): the whole startup runs under the lock, so concurrent calls cannot confuse the state
    [_lock lock];

    // Key fix (C1/H8): a bind failure (errno=48 EADDRINUSE) is caused by the socket not being closed properly on the last disconnect,
    // or by _running being out of step with the real socket state after the app crashed (SIGSEGV).
    // The fix: force a stop before starting, making sure the old listening socket is closed and the port is free.
    if (_running) {
        NSLog(@"[SOCKS5Proxy] Detected proxy still running before startup, stopping old proxy to release port");
        // Release the lock temporarily to call stop (which takes the lock itself)
        [_lock unlock];
        [self stop];
        // Give the system a moment to release the port (the TIME_WAIT state)
        [NSThread sleepForTimeInterval:0.1];
        [_lock lock];
    } else if (_listenFD >= 0) {
        // _running is NO but _listenFD is still valid (an inconsistent state), so force it closed
        NSLog(@"[SOCKS5Proxy] Detected zombie listen socket (fd=%d), forcefully closing", _listenFD);
        close(_listenFD);
        _listenFD = -1;
        [NSThread sleepForTimeInterval:0.1];
    }

    // Check whether it is running (checked again after stopping)
    if (_running) {
        [_lock unlock];
        NSLog(@"[SOCKS5Proxy] Proxy already running, port = %u", _listeningPort);
        if (error) {
            *error = [NSError errorWithDomain:kSOCKS5ProxyErrorDomain
                                          code:SOCKS5ProxyErrorCodeAlreadyRunning
                                      userInfo:@{NSLocalizedDescriptionKey: @"The SOCKS5 proxy is already running"}];
        }
        return NO;
    }
    [_lock unlock];

    // Check whether the ZeroTier framework is available
    // With no framework the proxy cannot reach the ZeroTier network, so starting it is pointless
    if (![[ZeroTierBridge sharedInstance] isFrameworkAvailable]) {
        NSLog(@"[SOCKS5Proxy] Startup failed: ZeroTier framework unavailable");
        if (error) {
            *error = [NSError errorWithDomain:kSOCKS5ProxyErrorDomain
                                          code:SOCKS5ProxyErrorCodeFrameworkUnavailable
                                      userInfo:@{NSLocalizedDescriptionKey: @"The ZeroTier framework is unavailable, so the SOCKS5 proxy cannot start"}];
        }
        return NO;
    }

    NSLog(@"[SOCKS5Proxy] Starting proxy server, requested port = %u", port);

    // Step 1: create the listening socket (a system POSIX socket, not a libzt one)
    int fd = socket(AF_INET, SOCK_STREAM, 0);
    if (fd < 0) {
        NSLog(@"[SOCKS5Proxy] Failed to create socket: errno = %d", errno);
        if (error) {
            *error = [NSError errorWithDomain:kSOCKS5ProxyErrorDomain
                                          code:SOCKS5ProxyErrorCodeSocketCreateFailed
                                      userInfo:@{NSLocalizedDescriptionKey: [NSString stringWithFormat:@"Failed to create a socket (errno=%d)", errno]}];
        }
        return NO;
    }

    // Step 2: set SO_REUSEADDR to allow the port to be reused
    // This avoids the "Address already in use" error (from the previous run's socket sitting in TIME_WAIT)
    int opt = 1;
    if (setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &opt, sizeof(opt)) < 0) {
        NSLog(@"[SOCKS5Proxy] Failed to set SO_REUSEADDR: errno = %d (ignoring, continuing)", errno);
    }

    // Step 3: bind to 127.0.0.1:port
    // Only the loopback address is listened on, so nothing is exposed to the outside network
    //
    // Key fix (port conflict handling): try the next port when bind fails.
    //
    // errno=48 (EADDRINUSE) means the port is taken, which can happen because:
    //   1. the socket of the previous launcher process is in TIME_WAIT (SO_REUSEADDR behaves inconsistently
    //      for a 127.0.0.1 bind on iOS in some cases and can still refuse the bind)
    //   2. another process on a jailbroken iOS device holds the port (VPN tools and
    //      SSH dynamic forwarding on jailbroken setups often use port 1080)
    //   3. the previous SOCKS5 proxy in this process was not closed properly (startWithPort:
    //      does check and stop at its entry point, but something can still linger in an edge case)
    //
    // The fix:
    //   - try the port the user asked for first (usually 1080)
    //   - if bind fails, try port+1, port+2, ..., port+9 in turn (10 ports in all)
    //   - if all 10 fail, use port=0 and let the system pick a free one
    //   - the port actually used is exposed to JavaLauncher through the listeningPort property and currentSOCKS5Port,
    //     so the JVM argument -DsocksProxyPort gets the right port
    //
    // This keeps a fixed port where possible (which helps with debugging and firewall rules) while stopping a port
    // conflict from breaking multiplayer entirely.

    uint16_t actualPort = 0;
    BOOL bindSuccess = NO;
    int lastBindErrno = 0;

    for (int attempt = 0; attempt < 11; attempt++) {
        // The first 10 attempts use port+0 through port+9, and the 11th uses port=0 (letting the system choose)
        uint16_t tryPort = (attempt < 10) ? (port + attempt) : 0;

        struct sockaddr_in addr;
        memset(&addr, 0, sizeof(addr));
        addr.sin_family = AF_INET;
        addr.sin_port = htons(tryPort);
        addr.sin_addr.s_addr = inet_addr("127.0.0.1");

        if (bind(fd, (struct sockaddr *)&addr, sizeof(addr)) == 0) {
            // bind succeeded
            bindSuccess = YES;

            if (tryPort == 0) {
                // With a system-assigned port, getsockname reports the real one
                socklen_t addrLen = sizeof(addr);
                if (getsockname(fd, (struct sockaddr *)&addr, &addrLen) < 0) {
                    NSLog(@"[SOCKS5Proxy] getsockname failed: errno = %d", errno);
                    close(fd);
                    if (error) {
                        *error = [NSError errorWithDomain:kSOCKS5ProxyErrorDomain
                                                      code:SOCKS5ProxyErrorCodeSocketCreateFailed
                                                  userInfo:@{NSLocalizedDescriptionKey: @"Could not read the actual listening port"}];
                    }
                    return NO;
                }
                actualPort = ntohs(addr.sin_port);
            } else {
                actualPort = tryPort;
            }

            if (tryPort != port) {
                NSLog(@"[SOCKS5Proxy] Requested port %u is in use, using port %u instead", port, actualPort);
            }
            break;
        }

        // bind failed
        lastBindErrno = errno;
        NSLog(@"[SOCKS5Proxy] bind port %u failed: errno = %d (trying next port)", tryPort, errno);

        // After a failed bind the old socket has to be closed and a new one created
        // (the socket state is unpredictable after a failed bind, so it cannot be reused)
        close(fd);
        fd = socket(AF_INET, SOCK_STREAM, 0);
        if (fd < 0) {
            NSLog(@"[SOCKS5Proxy] Failed to recreate socket: errno = %d", errno);
            if (error) {
                *error = [NSError errorWithDomain:kSOCKS5ProxyErrorDomain
                                              code:SOCKS5ProxyErrorCodeSocketCreateFailed
                                          userInfo:@{NSLocalizedDescriptionKey: [NSString stringWithFormat:@"Failed to create a socket (errno=%d)", errno]}];
            }
            return NO;
        }

        // Set SO_REUSEADDR again (a new socket needs it set again)
        int reuseOpt = 1;
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &reuseOpt, sizeof(reuseOpt));
    }

    if (!bindSuccess) {
        NSLog(@"[SOCKS5Proxy] All port attempts failed (last errno = %d)", lastBindErrno);
        close(fd);
        if (error) {
            *error = [NSError errorWithDomain:kSOCKS5ProxyErrorDomain
                                          code:SOCKS5ProxyErrorCodeBindFailed
                                      userInfo:@{NSLocalizedDescriptionKey: [NSString stringWithFormat:@"Failed to bind port %u (errno=%d), and no fallback port was available", port, lastBindErrno]}];
        }
        return NO;
    }

    // Step 5: start listening
    // backlog = 16, allowing up to 16 pending connections
    if (listen(fd, 16) < 0) {
        NSLog(@"[SOCKS5Proxy] listen failed: errno = %d", errno);
        close(fd);
        if (error) {
            *error = [NSError errorWithDomain:kSOCKS5ProxyErrorDomain
                                          code:SOCKS5ProxyErrorCodeListenFailed
                                      userInfo:@{NSLocalizedDescriptionKey: [NSString stringWithFormat:@"Failed to listen (errno=%d)", errno]}];
        }
        return NO;
    }

    // Update the internal state
    [_lock lock];
    _listenFD = fd;
    _listeningPort = actualPort;
    _running = YES;
    [_clientFDs removeAllObjects];
    [_clientThreads removeAllObjects];
    // Key fix (P1-9): start did not clear _remoteFDs, so an old remoteFD left over from a restart
    // would be shutdownSocket:-ed by the next stop(), possibly closing a new fd the system had reused.
    // It is cleared alongside _clientFDs / _clientThreads, keeping the fd lists consistent.
    [_remoteFDs removeAllObjects];
    [_lock unlock];

    NSLog(@"[SOCKS5Proxy] Proxy server started, listening on 127.0.0.1:%u", actualPort);

    // Step 6: start the accept thread
    __weak typeof(self) weakSelf = self;
    _acceptThread = [[NSThread alloc] initWithBlock:^{
        [weakSelf acceptLoop];
    }];
    [_acceptThread setName:@"SOCKS5Proxy-Accept"];
    [_acceptThread start];

    return YES;
}

/// Stop the proxy server
///
/// Key fix (C1): after closing the listening socket, shut down every active client connection,
/// forcing the client threads blocked on read/recv to return, so no thread leaks.
///
/// Key fix (M4): wait briefly after stopping, so the client threads have a chance to clean up
/// before the caller leaves the ZeroTier network.
- (void)stop {
    // Key fix (N1): calling stop on the main thread blocked the UI for up to 2 seconds.
    //
    // The chain: the user taps "Disconnect" -> MultiplayerManager.disconnectCurrentRoom
    // (main thread) -> SOCKS5Proxy.stop (main thread) -> waiting for the client threads to exit (2 seconds) -> a frozen UI.
    //
    // The fix:
    //   1. every immediate cleanup step (closing the listening socket, shutting down the client/remote fds, clearing the lists,
    //      setting _running=NO) runs synchronously on the current thread, so once stop returns the proxy accepts
    //      no new connections and forwards nothing, and the state is immediately visible to the caller
    //   2. the slow part, "wait for the client threads to exit", now runs asynchronously on a background queue when called
    //      from the main thread, so the UI is not blocked; on a background thread it still waits synchronously
    //      (disconnectCurrentRoom is usually on the main thread, and waiting synchronously off it is harmless)
    //
    // So stop returns almost immediately on the main thread (costing only the shutdown syscalls) and the UI does not stall,
    // while the client threads are still waited on in the background and their resources are cleaned up correctly.
    BOOL isMainThread = [NSThread isMainThread];

    [_lock lock];
    if (!_running) {
        [_lock unlock];
        NSLog(@"[SOCKS5Proxy] Proxy is not running, no need to stop");
        return;
    }

    NSLog(@"[SOCKS5Proxy] Stopping proxy server (isMainThread=%d)...", isMainThread);
    _running = NO;

    // Close the listening socket, which makes accept() return an error and the accept thread exit
    if (_listenFD >= 0) {
        close(_listenFD);
        _listenFD = -1;
    }

    // Save the current port for the log, then clear it
    uint16_t savedPort = _listeningPort;
    _listeningPort = 0;

    // Copy the client thread and fd lists (so the lock is not held for long)
    NSArray<NSThread *> *threads = [_clientThreads copy];
    NSArray<NSNumber *> *clientFDs = [_clientFDs copy];
    NSArray<NSNumber *> *remoteFDs = [_remoteFDs copy];
    [_clientThreads removeAllObjects];
    [_clientFDs removeAllObjects];
    [_remoteFDs removeAllObjects];
    [_lock unlock];

    NSLog(@"[SOCKS5Proxy] Listen socket closed (port %u), shutting down %lu client connections and %lu remote connections...",
          savedPort, (unsigned long)clientFDs.count, (unsigned long)remoteFDs.count);

    // Key fix (C1): shut down every active client fd
    // shutdown(SHUT_RDWR) forces read/recv to return 0 or an error, waking the blocked client threads
    // This is the core of the thread leak fix: only waking a blocked read lets a client thread exit
    for (NSNumber *fdNum in clientFDs) {
        int clientFD = [fdNum intValue];
        if (clientFD >= 0) {
            // shutdown rather than close: close only decrements the reference count and does not wake a blocked read
            // shutdown(SHUT_RDWR) makes every read/write blocked on that fd return immediately
            int rc = shutdown(clientFD, SHUT_RDWR);
            NSLog(@"[SOCKS5Proxy] shutdown client fd=%d, result=%d (errno=%d)", clientFD, rc, errno);
        }
    }

    // Key fix (M12): shut down every active remote fd (a libzt socket)
    // Without shutting them down, a client thread inside forwardDataBetweenClientFD:
    // sat blocked in recvData:remoteFD: for up to 30 seconds (the SO_RCVTIMEO timeout).
    // A SHUT_RDWR on the remote fd makes recv return immediately, so the client thread exits quickly.
    for (NSNumber *fdNum in remoteFDs) {
        int remoteFD = [fdNum intValue];
        if (remoteFD >= 0) {
            int rc = [[ZeroTierBridge sharedInstance] shutdownSocket:remoteFD how:2 /* SHUT_RDWR */];
            NSLog(@"[SOCKS5Proxy] shutdown remote fd=%d, result=%d", remoteFD, rc);
        }
    }

    NSLog(@"[SOCKS5Proxy] Shut down all client connections, waiting for %lu client threads to exit...",
          (unsigned long)threads.count);

    // Key fix (N1): wait for the client threads to exit (with a timeout, so it cannot wait forever)
    // - on a background thread: wait synchronously, since the caller is off the main thread and blocking does not affect the UI
    // - on the main thread: dispatch the wait to a background queue, so the UI does not freeze
    //   The client threads exit quickly once woken by the shutdown, so waiting asynchronously does not delay
    //   the next startWithPort: (which checks the _running flag and _listenFD itself,
    //   and only waits 0.1 seconds when force-stopping an old proxy, so it cannot clash with the asynchronous wait)
    if (threads.count == 0) {
        NSLog(@"[SOCKS5Proxy] Proxy stopped (no active client threads)");
        return;
    }

    if (isMainThread) {
        // Main thread: dispatch the wait to a background queue, so the UI is not blocked
        NSArray<NSThread *> *threadsToWait = [threads copy];
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
            NSTimeInterval waitDeadline = [NSDate timeIntervalSinceReferenceDate] + 2.0;
            for (NSThread *thread in threadsToWait) {
                while (![thread isFinished] && [NSDate timeIntervalSinceReferenceDate] < waitDeadline) {
                    [NSThread sleepForTimeInterval:0.05];
                }
                if (![thread isFinished]) {
                    NSLog(@"[SOCKS5Proxy] Warning: client thread %@ did not exit within 2 seconds", thread.name);
                }
            }
            NSLog(@"[SOCKS5Proxy] Proxy stopped, all client connections cleaned up (background wait completed)");
        });
        NSLog(@"[SOCKS5Proxy] stop called on main thread, dispatched waiting for %lu client threads to background queue",
              (unsigned long)threads.count);
    } else {
        // Background thread: wait synchronously
        NSTimeInterval waitDeadline = [NSDate timeIntervalSinceReferenceDate] + 2.0;
        for (NSThread *thread in threads) {
            while (![thread isFinished] && [NSDate timeIntervalSinceReferenceDate] < waitDeadline) {
                [NSThread sleepForTimeInterval:0.05];
            }
            if (![thread isFinished]) {
                NSLog(@"[SOCKS5Proxy] Warning: client thread %@ did not exit within 2 seconds", thread.name);
            }
        }
        NSLog(@"[SOCKS5Proxy] Proxy stopped, all client connections cleaned up");
    }
}

/// Whether the proxy server is running
/// @return YES when it is running
- (BOOL)isRunning {
    [_lock lock];
    BOOL running = _running;
    [_lock unlock];
    return running;
}

/// The current listening port
/// @return The listening port (0 when it is not running)
- (uint16_t)listeningPort {
    [_lock lock];
    uint16_t port = _listeningPort;
    [_lock unlock];
    return port;
}

#pragma mark - Accept loop

/// The accept loop (running on the _acceptThread)
///
/// Accepts new client connections in a loop, starting a handling thread for each one.
- (void)acceptLoop {
    NSLog(@"[SOCKS5Proxy] Accept thread started");

    // Key fix (M10): a consecutive accept error counter, so a runaway loop cannot burn CPU
    int consecutiveErrors = 0;
    static const int kMaxConsecutiveErrors = 20;

    while (YES) {
        // Check the running state
        [_lock lock];
        BOOL running = _running;
        int listenFD = _listenFD;
        [_lock unlock];

        if (!running || listenFD < 0) {
            NSLog(@"[SOCKS5Proxy] Accept thread exiting (proxy has stopped)");
            break;
        }

        // Accept a new connection
        struct sockaddr_in clientAddr;
        socklen_t clientLen = sizeof(clientAddr);
        int clientFD = accept(listenFD, (struct sockaddr *)&clientAddr, &clientLen);

        if (clientFD < 0) {
            // Check whether it is because the proxy has stopped
            [_lock lock];
            BOOL stillRunning = _running;
            [_lock unlock];

            if (!stillRunning) {
                NSLog(@"[SOCKS5Proxy] accept returned -1, proxy has stopped, exiting loop");
                break;
            }

            // Key fix (M10): EBADF means listenFD is invalid, so exit outright
            // EMFILE/ENFILE mean file descriptors are exhausted, so back off and continue
            if (errno == EBADF) {
                NSLog(@"[SOCKS5Proxy] accept returned EBADF (listenFD invalid), exiting loop");
                // Key fix (M11): the _running state must be cleared on an abnormal exit,
                // otherwise isRunning still returns YES and the caller believes the proxy is fine while it has stopped accepting.
                [_lock lock];
                _running = NO;
                if (_listenFD >= 0) {
                    close(_listenFD);
                    _listenFD = -1;
                }
                _listeningPort = 0;
                [_lock unlock];
                break;
            }

            consecutiveErrors++;
            NSLog(@"[SOCKS5Proxy] accept failed: errno = %d (consecutive %d times)", errno, consecutiveErrors);

            // Key fix (M10): too many consecutive errors, so exit rather than loop forever
            if (consecutiveErrors >= kMaxConsecutiveErrors) {
                NSLog(@"[SOCKS5Proxy] %d consecutive accept errors, exiting loop", consecutiveErrors);
                // Key fix (M11): clear the _running state and _listenFD on an abnormal exit,
                // so isRunning returns NO and the caller (MultiplayerManager) can tell the proxy has stopped.
                // Not clearing them meant:
                //   - isRunning still returned YES
                //   - MultiplayerManager.isSOCKS5ProxyRunning reported the proxy as running
                //   - while it no longer accepted connections, so Minecraft SOCKS5 requests were silently dropped
                //   - leaving the system in an inconsistent state
                [_lock lock];
                _running = NO;
                if (_listenFD >= 0) {
                    close(_listenFD);
                    _listenFD = -1;
                }
                _listeningPort = 0;
                [_lock unlock];
                break;
            }

            // Back off, so the CPU does not spin
            [NSThread sleepForTimeInterval:0.1];
            continue;
        }

        // Reset the error counter
        consecutiveErrors = 0;

        // Get the client IP and port
        char clientIP[INET_ADDRSTRLEN] = {0};
        inet_ntop(AF_INET, &clientAddr.sin_addr, clientIP, sizeof(clientIP));
        uint16_t clientPort = ntohs(clientAddr.sin_port);
        NSLog(@"[SOCKS5Proxy] New client connection: %s:%u (fd=%d)", clientIP, clientPort, clientFD);

        // Key fix (H9/C1): set SO_RCVTIMEO on the client socket
        // So a malicious client cannot send part of the data and then hold the connection open, blocking a server thread forever.
        // After the timeout read returns -1 with errno=EAGAIN/EWOULDBLOCK and the client thread can exit.
        struct timeval rcvTimeout;
        rcvTimeout.tv_sec = SOCKS5_CLIENT_IO_TIMEOUT;
        rcvTimeout.tv_usec = 0;
        if (setsockopt(clientFD, SOL_SOCKET, SO_RCVTIMEO, &rcvTimeout, sizeof(rcvTimeout)) < 0) {
            NSLog(@"[SOCKS5Proxy] Failed to set SO_RCVTIMEO: errno = %d (ignoring, continuing)", errno);
        }

        // Key fix (M14): set SO_KEEPALIVE
        // If the peer disappears abruptly (a network drop, a crashed process), this end notices promptly
        // instead of sitting blocked on read unaware the connection is gone.
        int keepalive = 1;
        if (setsockopt(clientFD, SOL_SOCKET, SO_KEEPALIVE, &keepalive, sizeof(keepalive)) < 0) {
            NSLog(@"[SOCKS5Proxy] Failed to set SO_KEEPALIVE: errno = %d (ignoring, continuing)", errno);
        }

        // Key fix (P1-5): set SO_SNDTIMEO / SO_NOSIGPIPE on the client socket
        //
        // The problem is the same as in PortForwarder: writeAll calls writeAllWithTimeout(fd, buf, len, 0),
        // and timeoutSec=0 means no timeout. When the Minecraft receive buffer fills, write blocks forever and the forwarding thread leaks.
        //
        // The fix: a 30-second send timeout, after which write returns -1 with errno=EAGAIN and the forwarding loop exits.
        // SO_NOSIGPIPE stops a write to a closed connection raising SIGPIPE and crashing.
        struct timeval sndTimeout;
        sndTimeout.tv_sec = SOCKS5_CLIENT_IO_TIMEOUT;
        sndTimeout.tv_usec = 0;
        if (setsockopt(clientFD, SOL_SOCKET, SO_SNDTIMEO, &sndTimeout, sizeof(sndTimeout)) < 0) {
            NSLog(@"[SOCKS5Proxy] Failed to set SO_SNDTIMEO: errno = %d (ignoring, continuing)", errno);
        }
        int nosigpipe = 1;
        if (setsockopt(clientFD, SOL_SOCKET, SO_NOSIGPIPE, &nosigpipe, sizeof(nosigpipe)) < 0) {
            NSLog(@"[SOCKS5Proxy] Failed to set SO_NOSIGPIPE: errno = %d (ignoring, continuing)", errno);
        }

        // Key fix (P2-11): the iOS default keepalive interval is about 2 hours, too slow to detect a half-dead connection.
        // Made more aggressive: probing after 30s idle, every 10s, with 3 failures meaning it is dead.
        int keepIdle = 30;
        setsockopt(clientFD, IPPROTO_TCP, TCP_KEEPALIVE, &keepIdle, sizeof(keepIdle));
        int keepIntvl = 10;
        setsockopt(clientFD, IPPROTO_TCP, TCP_KEEPINTVL, &keepIntvl, sizeof(keepIntvl));
        int keepCnt = 3;
        setsockopt(clientFD, IPPROTO_TCP, TCP_KEEPCNT, &keepCnt, sizeof(keepCnt));

        // Post the client connected notification
        [[NSNotificationCenter defaultCenter] postNotificationName:SOCKS5ProxyClientConnectedNotification
                                                            object:self
                                                          userInfo:@{
                                                              @"clientIP": [NSString stringWithUTF8String:clientIP],
                                                              @"clientPort": @(clientPort)
                                                          }];

        // Start the client handling thread
        __weak typeof(self) weakSelf = self;
        NSThread *clientThread = [[NSThread alloc] initWithBlock:^{
            [weakSelf handleClient:clientFD];
        }];
        [clientThread setName:[NSString stringWithFormat:@"SOCKS5Proxy-Client-%d", clientFD]];

        [_lock lock];
        if (_running) {
            [_clientThreads addObject:clientThread];
            // Key fix (C1): add the client fd to the array, so stop can shut it down
            [_clientFDs addObject:@(clientFD)];
            [clientThread start];
        } else {
            // The proxy has stopped, so close the client connection straight away
            NSLog(@"[SOCKS5Proxy] Proxy has stopped, rejecting new connection fd=%d", clientFD);
            close(clientFD);
        }
        [_lock unlock];
    }

    NSLog(@"[SOCKS5Proxy] Accept thread exited");
}

#pragma mark - Client handling

/// Handle one client connection (running on a client handling thread)
///
/// The flow:
///   1. the SOCKS5 handshake (method negotiation + request parsing)
///   2. connect to the destination host through ZeroTierBridge
///   3. forward data in both directions
///   4. clean up
///
/// Key fix (H10): @try @finally makes sure the fds are closed on every path,
/// so nothing leaks even if the handshake or forwarding throws.
///
/// @param clientFD The client socket file descriptor
- (void)handleClient:(int)clientFD {
    @autoreleasepool {
        NSLog(@"[SOCKS5Proxy] Starting to handle client fd=%d", clientFD);

        // Holds the handshake result
        NSString *targetHost = nil;
        uint16_t targetPort = 0;
        int remoteFD = -1;

        @try {
            // Step 1: the SOCKS5 handshake
            BOOL handshakeOK = [self socks5Handshake:clientFD
                                          targetHost:&targetHost
                                          targetPort:&targetPort
                                            remoteFD:&remoteFD];

            if (!handshakeOK) {
                NSLog(@"[SOCKS5Proxy] SOCKS5 handshake failed, closing client fd=%d", clientFD);

                // Post the client disconnected notification
                [[NSNotificationCenter defaultCenter] postNotificationName:SOCKS5ProxyClientDisconnectedNotification
                                                                    object:self
                                                                  userInfo:@{@"reason": @"handshake_failed"}];
                return;
            }

            NSLog(@"[SOCKS5Proxy] SOCKS5 handshake succeeded, target %@:%u, starting forwarding (clientFD=%d, remoteFD=%d)",
                  targetHost, targetPort, clientFD, remoteFD);

            // Key fix (M12): add the remote fd to _remoteFDs, so stop can shut it down.
            // Otherwise stop only shuts down the client fd, the remote fd stays blocked in recv, and the client thread cannot exit.
            [_lock lock];
            [_remoteFDs addObject:@(remoteFD)];
            [_lock unlock];

            // Key fix: set TCP_NODELAY on the client socket (disabling the Nagle algorithm)
            // Minecraft is a real-time game, where latency matters more than bandwidth
            int clientNoDelay = 1;
            setsockopt(clientFD, IPPROTO_TCP, TCP_NODELAY, &clientNoDelay, sizeof(clientNoDelay));

            // Key fix: set TCP_NODELAY on the libzt socket (lowering ZeroTier virtual network latency)
            int ztNoDelay = 1;
            zts_bsd_setsockopt(remoteFD, ZTS_IPPROTO_TCP, ZTS_TCP_NODELAY, &ztNoDelay, sizeof(ztNoDelay));

            // Step 2: forward data in both directions
            [self forwardDataBetweenClientFD:clientFD remoteFD:remoteFD];

            // Post the client disconnected notification
            [[NSNotificationCenter defaultCenter] postNotificationName:SOCKS5ProxyClientDisconnectedNotification
                                                                object:self
                                                              userInfo:@{@"reason": @"closed"}];

            NSLog(@"[SOCKS5Proxy] Client handling completed fd=%d", clientFD);
        } @finally {
            // Key fix (H10): close the fds whether or not something threw, so nothing leaks
            //
            // Key fix (M10): remove the fd from _clientFDs before calling close(fd).
            // Calling close(clientFD) before removeCurrentThreadAndFD: raced with fd reuse:
            //   1. after close(clientFD) the fd number can be reused by a new accept
            //   2. if a new start cycle began between the close and removeCurrentThreadAndFD: and
            //      accept returned the same fd number
            //   3. the indexOfObject:@(clientFD) inside removeCurrentThreadAndFD: would match
            //      the new connection's entry and remove it by mistake
            //   4. so a later stop would not shut down that new connection's fd, leaking the thread
            // The fix: remove the fd from _clientFDs inside _lock first, then close(fd) outside the lock.
            // The fd number is then out of the list before it can be reused, so no new entry is removed by mistake.
            //
            // Key fix (M12): remove remoteFD from _remoteFDs at the same time, so stop cannot
            // shut down an already-closed remoteFD.
            [self removeCurrentThreadAndClientFD:clientFD remoteFD:remoteFD];

            // Close the client socket (a system POSIX socket)
            if (clientFD >= 0) {
                close(clientFD);
            }
            // Close the remote socket (a libzt socket, closed through ZeroTierBridge)
            if (remoteFD >= 0) {
                [[ZeroTierBridge sharedInstance] closeSocket:remoteFD];
            }
        }
    }
}

#pragma mark - SOCKS5 protocol implementation

/// The SOCKS5 handshake
///
/// Completes the method negotiation and request parsing, then connects to the destination through ZeroTierBridge.
///
/// @param clientFD The client socket file descriptor
/// @param targetHost Output: the destination host address
/// @param targetPort Output: the destination port
/// @param remoteFD Output: the remote socket file descriptor (a libzt socket)
/// @return YES when the handshake succeeded
- (BOOL)socks5Handshake:(int)clientFD
             targetHost:(NSString **)targetHost
             targetPort:(uint16_t *)targetPort
               remoteFD:(int *)remoteFD {
    // ============================================================
    // Step 1: negotiate the authentication method
    // ============================================================

    // Read the client greeting header: VER(1) NMETHODS(1)
    uint8_t greeting[2] = {0};
    ssize_t n = readAll(clientFD, greeting, 2);
    if (n != 2) {
        NSLog(@"[SOCKS5Proxy] Failed to read greeting header: n=%zd", n);
        return NO;
    }

    // Validate the SOCKS version
    if (greeting[0] != SOCKS5_VERSION) {
        NSLog(@"[SOCKS5Proxy] Unsupported SOCKS version: %d", greeting[0]);
        return NO;
    }

    uint8_t nMethods = greeting[1];
    if (nMethods == 0) {
        NSLog(@"[SOCKS5Proxy] Client did not provide any authentication methods");
        return NO;
    }

    // Read the method list: METHODS(NMETHODS)
    uint8_t methods[256] = {0};
    n = readAll(clientFD, methods, nMethods);
    if (n != nMethods) {
        NSLog(@"[SOCKS5Proxy] Failed to read methods list: n=%zd, expected=%d", n, nMethods);
        return NO;
    }

    // Check whether the no-auth method is supported (METHOD_NO_AUTH = 0x00)
    // This proxy does not support username/password authentication
    BOOL noAuthSupported = NO;
    for (int i = 0; i < nMethods; i++) {
        if (methods[i] == SOCKS5_METHOD_NO_AUTH) {
            noAuthSupported = YES;
            break;
        }
    }

    if (!noAuthSupported) {
        NSLog(@"[SOCKS5Proxy] Client does not support no-auth method, rejecting connection");
        // Reply that no method is acceptable
        uint8_t reply[2] = {SOCKS5_VERSION, SOCKS5_METHOD_NO_ACCEPTABLE};
        writeAll(clientFD, reply, 2);
        return NO;
    }

    // Reply selecting the no-auth method: VER(1) METHOD(1)
    uint8_t methodReply[2] = {SOCKS5_VERSION, SOCKS5_METHOD_NO_AUTH};
    n = writeAll(clientFD, methodReply, 2);
    if (n != 2) {
        NSLog(@"[SOCKS5Proxy] Failed to send method reply: n=%zd", n);
        return NO;
    }

    NSLog(@"[SOCKS5Proxy] SOCKS5 authentication method negotiation completed (no-auth)");

    // ============================================================
    // Step 2: read the client request
    // ============================================================

    // Read the request header: VER(1) CMD(1) RSV(1) ATYP(1)
    uint8_t requestHeader[4] = {0};
    n = readAll(clientFD, requestHeader, 4);
    if (n != 4) {
        NSLog(@"[SOCKS5Proxy] Failed to read request header: n=%zd", n);
        return NO;
    }

    // Validate the SOCKS version
    if (requestHeader[0] != SOCKS5_VERSION) {
        NSLog(@"[SOCKS5Proxy] SOCKS version error in request: %d", requestHeader[0]);
        return NO;
    }

    // Check the command (only CONNECT is supported)
    uint8_t cmd = requestHeader[1];
    if (cmd != SOCKS5_CMD_CONNECT) {
        NSLog(@"[SOCKS5Proxy] Unsupported CMD: %d (only CONNECT=1 supported)", cmd);
        [self sendSocks5Reply:clientFD
                          rep:SOCKS5_REP_COMMAND_NOT_SUPPORTED
                     bindAddr:@"0.0.0.0"
                     bindPort:0
                         atyp:SOCKS5_ATYP_IPV4];
        return NO;
    }

    // Parse the destination address
    uint8_t atyp = requestHeader[3];
    NSString *destHost = nil;

    switch (atyp) {
        case SOCKS5_ATYP_IPV4: {
            // An IPv4 address: 4 bytes
            uint8_t ipv4[4] = {0};
            n = readAll(clientFD, ipv4, 4);
            if (n != 4) {
                NSLog(@"[SOCKS5Proxy] Failed to read IPv4 address: n=%zd", n);
                return NO;
            }
            destHost = [NSString stringWithFormat:@"%d.%d.%d.%d",
                        ipv4[0], ipv4[1], ipv4[2], ipv4[3]];
            break;
        }

        case SOCKS5_ATYP_DOMAIN: {
            // A domain name: a 1-byte length plus the name
            uint8_t domainLen = 0;
            n = readAll(clientFD, &domainLen, 1);
            if (n != 1) {
                NSLog(@"[SOCKS5Proxy] Failed to read domain name length: n=%zd", n);
                return NO;
            }
            char domain[256] = {0};
            n = readAll(clientFD, domain, domainLen);
            if (n != domainLen) {
                NSLog(@"[SOCKS5Proxy] Failed to read domain name: n=%zd, expected=%d", n, domainLen);
                return NO;
            }
            NSString *domainStr = [NSString stringWithUTF8String:domain];

            // Key fix (P0-2): zts_bsd_connect in libzt cannot resolve domain names
            // (zts_inet_pton returns 0 for anything that is not a numeric IP), so the system
            // getaddrinfo has to resolve the name into an IP before passing it to ZeroTierBridge.connectSocket.
            // Otherwise entering a domain name in Minecraft made multiplayer fail outright.
            // On a resolution failure it falls back to the original domain, matching the old behavior (with the caller reporting the error).
            struct addrinfo hints, *res = NULL;
            memset(&hints, 0, sizeof(hints));
            hints.ai_family = AF_UNSPEC;       // Accept both IPv4 and IPv6
            hints.ai_socktype = SOCK_STREAM;
            int gaiResult = getaddrinfo(domain, NULL, &hints, &res);
            if (gaiResult == 0 && res != NULL) {
                char resolvedIP[INET6_ADDRSTRLEN] = {0};
                if (res->ai_family == AF_INET) {
                    struct sockaddr_in *sin = (struct sockaddr_in *)res->ai_addr;
                    inet_ntop(AF_INET, &sin->sin_addr, resolvedIP, sizeof(resolvedIP));
                } else if (res->ai_family == AF_INET6) {
                    struct sockaddr_in6 *sin6 = (struct sockaddr_in6 *)res->ai_addr;
                    inet_ntop(AF_INET6, &sin6->sin6_addr, resolvedIP, sizeof(resolvedIP));
                }
                if (resolvedIP[0] != '\0') {
                    destHost = [NSString stringWithUTF8String:resolvedIP];
                    NSLog(@"[SOCKS5Proxy] Domain %@ resolved to %@", domainStr, destHost);
                } else {
                    destHost = domainStr;
                    NSLog(@"[SOCKS5Proxy] Domain %@ resolved to empty result, falling back to original domain", domainStr);
                }
                freeaddrinfo(res);
            } else {
                destHost = domainStr;
                NSLog(@"[SOCKS5Proxy] Domain %@ resolution failed (gaiResult=%d: %s), using original domain",
                      domainStr, gaiResult, gai_strerror(gaiResult));
            }
            break;
        }

        case SOCKS5_ATYP_IPV6: {
            // An IPv6 address: 16 bytes
            uint8_t ipv6[16] = {0};
            n = readAll(clientFD, ipv6, 16);
            if (n != 16) {
                NSLog(@"[SOCKS5Proxy] Failed to read IPv6 address: n=%zd", n);
                return NO;
            }
            char ipv6Str[INET6_ADDRSTRLEN] = {0};
            inet_ntop(AF_INET6, ipv6, ipv6Str, sizeof(ipv6Str));
            destHost = [NSString stringWithUTF8String:ipv6Str];
            break;
        }

        default:
            NSLog(@"[SOCKS5Proxy] Unsupported ATYP: %d", atyp);
            [self sendSocks5Reply:clientFD
                              rep:SOCKS5_REP_ADDRESS_TYPE_NOT_SUPPORTED
                         bindAddr:@"0.0.0.0"
                         bindPort:0
                             atyp:SOCKS5_ATYP_IPV4];
            return NO;
    }

    // Read the destination port: 2 bytes in network byte order (big endian)
    uint8_t portBytes[2] = {0};
    n = readAll(clientFD, portBytes, 2);
    if (n != 2) {
        NSLog(@"[SOCKS5Proxy] Failed to read port: n=%zd", n);
        return NO;
    }
    uint16_t destPort = (uint16_t)((portBytes[0] << 8) | portBytes[1]);

    NSLog(@"[SOCKS5Proxy] Client requested connection to %@:%u", destHost, destPort);

    // ============================================================
    // Step 3: connect to the destination over the ZeroTier virtual network
    // ============================================================

    // Detect the address type: an IPv6 address contains ':' and an IPv4 address contains '.'
    BOOL isIPv6Target = ([destHost rangeOfString:@":"].location != NSNotFound);
    int socketFamily = isIPv6Target ? ZTS_AF_INET6 : ZTS_AF_INET;

    // Create the libzt socket (choosing IPv4 or IPv6 from the destination address type)
    // An ad-hoc network is IPv6-only, so the socket must be created with ZTS_AF_INET6
    int ztFD = [[ZeroTierBridge sharedInstance] createTCPSocketForFamily:socketFamily];
    if (ztFD < 0) {
        NSLog(@"[SOCKS5Proxy] Failed to create ZeroTier socket(family=%d): ztFD=%d", socketFamily, ztFD);
        [self sendSocks5Reply:clientFD
                          rep:SOCKS5_REP_GENERAL_FAILURE
                     bindAddr:@"0.0.0.0"
                     bindPort:0
                         atyp:SOCKS5_ATYP_IPV4];
        return NO;
    }

    // Connect to the destination host
    int connectResult = [[ZeroTierBridge sharedInstance] connectSocket:ztFD
                                                                toHost:destHost
                                                                  port:destPort
                                                               timeout:SOCKS5_CONNECT_TIMEOUT];
    if (connectResult != 0) {
        NSLog(@"[SOCKS5Proxy] Failed to connect to target via ZeroTier: result=%d, target=%@:%u",
              connectResult, destHost, destPort);
        [[ZeroTierBridge sharedInstance] closeSocket:ztFD];

        // Choose the right reply code for the error
        // Since the libzt error codes do not map onto the SOCKS5 reply codes, CONNECTION_REFUSED is used throughout
        [self sendSocks5Reply:clientFD
                          rep:SOCKS5_REP_CONNECTION_REFUSED
                     bindAddr:@"0.0.0.0"
                     bindPort:0
                         atyp:SOCKS5_ATYP_IPV4];
        return NO;
    }

    NSLog(@"[SOCKS5Proxy] Connected to target via ZeroTier successfully: target=%@:%u, ztFD=%d",
          destHost, destPort, ztFD);

    // ============================================================
    // Step 4: send the success reply
    // ============================================================

    [self sendSocks5Reply:clientFD
                      rep:SOCKS5_REP_SUCCESS
                 bindAddr:@"0.0.0.0"
                 bindPort:0
                     atyp:SOCKS5_ATYP_IPV4];

    // Return the handshake result
    if (targetHost) {
        *targetHost = destHost;
    }
    if (targetPort) {
        *targetPort = destPort;
    }
    if (remoteFD) {
        *remoteFD = ztFD;
    }

    return YES;
}

/// Send a SOCKS5 reply
///
/// The reply format: VER(1) REP(1) RSV(1) ATYP(1) BND.ADDR(?) BND.PORT(2)
///
/// @param clientFD The client socket file descriptor
/// @param rep The reply code (SOCKS5_REP_*)
/// @param bindAddr The bound address (BND.ADDR)
/// @param bindPort The bound port (BND.PORT)
/// @param atyp The address type (SOCKS5_ATYP_*)
- (void)sendSocks5Reply:(int)clientFD
                    rep:(uint8_t)rep
              bindAddr:(NSString *)bindAddr
              bindPort:(uint16_t)bindPort
                  atyp:(uint8_t)atyp {
    // Build the reply data
    NSMutableData *reply = [NSMutableData data];

    // VER(1) REP(1) RSV(1) ATYP(1)
    uint8_t header[4] = {SOCKS5_VERSION, rep, 0x00, atyp};
    [reply appendBytes:header length:4];

    // BND.ADDR (whose length depends on ATYP)
    if (atyp == SOCKS5_ATYP_IPV4) {
        uint8_t ipv4[4] = {0, 0, 0, 0};
        if (bindAddr && bindAddr.length > 0) {
            inet_pton(AF_INET, [bindAddr UTF8String], ipv4);
        }
        [reply appendBytes:ipv4 length:4];
    } else if (atyp == SOCKS5_ATYP_IPV6) {
        uint8_t ipv6[16] = {0};
        if (bindAddr && bindAddr.length > 0) {
            inet_pton(AF_INET6, [bindAddr UTF8String], ipv6);
        }
        [reply appendBytes:ipv6 length:16];
    }

    // BND.PORT (2 bytes, in network byte order)
    uint8_t portBytes[2] = {
        (uint8_t)((bindPort >> 8) & 0xFF),
        (uint8_t)(bindPort & 0xFF)
    };
    [reply appendBytes:portBytes length:2];

    // Send the reply
    // Key fix (L2): check the writeAll return value and log a failure
    ssize_t writeResult = writeAll(clientFD, reply.bytes, reply.length);
    if (writeResult < 0 || (size_t)writeResult != reply.length) {
        NSLog(@"[SOCKS5Proxy] Failed to send SOCKS5 reply: writeResult=%zd, expected=%lu",
              writeResult, (unsigned long)reply.length);
    }

    NSLog(@"[SOCKS5Proxy] Sent SOCKS5 reply: rep=%d, addr=%@:%u, atyp=%d",
          rep, bindAddr, bindPort, atyp);
}

#pragma mark - Bidirectional data forwarding

/// Forward data in both directions between the client and the remote host
///
/// A concurrent GCD queue runs two tasks, one per direction:
///   - client -> remote: read from the client and send to the remote over ZeroTier
///   - remote -> client: receive from ZeroTier and send to the client
///
/// When either direction ends, shutdown() tells the other end, so its read/recv returns 0 and it exits.
///
/// @param clientFD The client socket file descriptor (a system POSIX socket)
/// @param remoteFD The remote socket file descriptor (a libzt socket)
- (void)forwardDataBetweenClientFD:(int)clientFD
                          remoteFD:(int)remoteFD {
    // Key fix (N2): atomic_bool replaces __block BOOL, guaranteeing memory visibility across threads.
    //
    // The problem: the __block qualifier only lets a variable be modified inside a block; it provides no memory barrier.
    // On a weak memory model such as ARM64 (iPhone), a write to a __block variable by one thread
    // may not be seen promptly by another, so:
    //   - one direction closes, but the loop in the other does not notice the flag change in time
    //   - it stays blocked on read/recvData until the peer FIN arrives or the IO times out
    //   - the forwarding task exits late (in the worst case only after the peer closes or the IO times out)
    //
    // The fix: use a C11 atomic_bool, whose atomic operations carry the right memory barriers
    // (memory_order_seq_cst), so one thread's write is immediately visible to the other.
    //
    // Key fix (found while verifying N2): both __block and atomic are required.
    // - __block: makes the block capture the variable by reference (so both blocks share one variable) rather than by value
    //   (capturing by value would give each block its own copy, so the atomic operations would act on separate copies and do nothing)
    // - atomic_bool: provides the memory barrier that makes it visible across threads
    // Neither alone is enough: __block without atomics has no barrier, and atomics alone would be captured by value.
    // Key fix: atomic_bool replaces _Atomic(BOOL) for portability
    // _Atomic(BOOL) may not be supported in Objective-C (BOOL is a typedef for signed char)
    __block atomic_bool clientClosed = ATOMIC_VAR_INIT(false);
    __block atomic_bool remoteClosed = ATOMIC_VAR_INIT(false);

    // Create the concurrent queue used for bidirectional forwarding
    dispatch_queue_t forwardQueue = dispatch_queue_create("com.angelaura.socks5.forward", DISPATCH_QUEUE_CONCURRENT);
    dispatch_group_t group = dispatch_group_create();

    // ============================================================
    // Direction 1: client -> remote
    // Read from the client (a POSIX socket) and send over ZeroTier (a libzt socket)
    // ============================================================
    dispatch_group_async(group, forwardQueue, ^{
        uint8_t buffer[SOCKS5_BUFFER_SIZE];

        while (YES) {
            @autoreleasepool {
                // Check whether the remote has closed (an atomic read, which carries a memory barrier)
                if (atomic_load(&remoteClosed)) {
                    NSLog(@"[SOCKS5Proxy] client→remote: remote already closed, exiting forwarding");
                    break;
                }

                // Read from the client (system read)
                ssize_t n = read(clientFD, buffer, sizeof(buffer));
                if (n <= 0) {
                    // n == 0: the client closed the connection
                    // n < 0: a read error
                    NSLog(@"[SOCKS5Proxy] client→remote ended: n=%zd, errno=%d", n, errno);

                    // Mark the client as closed (an atomic write, which carries a memory barrier)
                    atomic_store(&clientClosed, true);

                    // Shut down the write side of the remote, telling the remote->client direction to exit
                    // The shutdown makes recv on the other side return 0
                    // Key fix: remoteFD is a libzt socket, so zts_bsd_shutdown must be used
                    [[ZeroTierBridge sharedInstance] shutdownSocket:remoteFD how:SHUT_WR];
                    break;
                }

                // Send the data over ZeroTier (a libzt send)
                ssize_t sent = [[ZeroTierBridge sharedInstance] sendData:remoteFD
                                                                  buffer:buffer
                                                                  length:(size_t)n];
                if (sent <= 0) {
                    NSLog(@"[SOCKS5Proxy] Failed to send to remote: sent=%zd", sent);

                    // Mark the remote as closed (an atomic write)
                    atomic_store(&remoteClosed, true);

                    // Shut down the write side of the client
                    shutdown(clientFD, SHUT_WR);
                    break;
                }
            }
        }
    });

    // ============================================================
    // Direction 2: remote -> client
    // Receive from ZeroTier (a libzt socket) and send to the client (a POSIX socket)
    // ============================================================
    dispatch_group_async(group, forwardQueue, ^{
        uint8_t buffer[SOCKS5_BUFFER_SIZE];

        while (YES) {
            @autoreleasepool {
                // Check whether the client has closed (an atomic read, which carries a memory barrier)
                if (atomic_load(&clientClosed)) {
                    NSLog(@"[SOCKS5Proxy] remote→client: client already closed, exiting forwarding");
                    break;
                }

                // Receive over ZeroTier (a libzt recv)
                ssize_t n = [[ZeroTierBridge sharedInstance] recvData:remoteFD
                                                                buffer:buffer
                                                                length:sizeof(buffer)];
                if (n <= 0) {
                    // n == 0: the remote closed the connection
                    // n < 0: a receive error
                    NSLog(@"[SOCKS5Proxy] remote→client ended: n=%zd", n);

                    // Mark the remote as closed (an atomic write)
                    atomic_store(&remoteClosed, true);

                    // Shut down the write side of the client, telling the client->remote direction to exit
                    shutdown(clientFD, SHUT_WR);
                    break;
                }

                // Send the data to the client (system write)
                ssize_t sent = writeAll(clientFD, buffer, (size_t)n);
                if (sent <= 0) {
                    NSLog(@"[SOCKS5Proxy] Failed to send to client: sent=%zd", sent);

                    // Mark the client as closed (an atomic write)
                    atomic_store(&clientClosed, true);

                    // Shut down the write side of the remote
                    // Key fix: remoteFD is a libzt socket, so zts_bsd_shutdown must be used
                    [[ZeroTierBridge sharedInstance] shutdownSocket:remoteFD how:SHUT_WR];
                    break;
                }
            }
        }
    });

    // Wait for both directions to finish forwarding
    dispatch_group_wait(group, DISPATCH_TIME_FOREVER);

    NSLog(@"[SOCKS5Proxy] Bidirectional forwarding ended (clientFD=%d, remoteFD=%d)", clientFD, remoteFD);
}

#pragma mark - Helper methods

/// Remove the current thread and its fds from the client thread list, the client fd list and the remote fd list
///
/// Key fix (C1): the client fd is removed too, so stop cannot shut down an already-closed fd
/// Key fix (M12): the remote fd is removed too, so stop cannot shut down an already-closed remoteFD
- (void)removeCurrentThreadAndClientFD:(int)clientFD remoteFD:(int)remoteFD {
    NSThread *current = [NSThread currentThread];
    [_lock lock];
    [_clientThreads removeObject:current];

    // Remove the client fd (found with indexOfObject: on the matching NSNumber)
    if (clientFD >= 0) {
        NSNumber *clientFDNum = @(clientFD);
        NSUInteger clientIndex = [_clientFDs indexOfObject:clientFDNum];
        if (clientIndex != NSNotFound) {
            [_clientFDs removeObjectAtIndex:clientIndex];
        }
    }

    // Key fix (M12): remove the remote fd
    if (remoteFD >= 0) {
        NSNumber *remoteFDNum = @(remoteFD);
        NSUInteger remoteIndex = [_remoteFDs indexOfObject:remoteFDNum];
        if (remoteIndex != NSNotFound) {
            [_remoteFDs removeObjectAtIndex:remoteIndex];
        }
    }

    [_lock unlock];
}

@end
