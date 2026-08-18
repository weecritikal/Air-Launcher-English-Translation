//
//  PortForwarder.m
//  Angel Aura Amethyst
//
//  TCP port forwarder implementation (supporting both host and guest modes)
//
//  ============================================================================
//  Implementation notes
//  ============================================================================
//
//  This file implements the TCP port forwarder declared in PortForwarder.h, in two modes:
//
//  Guest mode:
//    1. the listening socket is a system POSIX socket (socket/bind/listen/accept)
//    2. once a client connects, a libzt socket is created through ZeroTierBridge to reach the remote host
//    3. bidirectional forwarding uses a concurrent GCD queue, with both directions running at once
//    4. an atomic_bool flag guarantees memory visibility across threads
//    5. port conflict handling: localPort through localPort+9 are tried, finally falling back to port=0
//
//  Host mode (reverse forwarding):
//    1. the listening socket is a libzt socket (through createListenSocket/bind/listen on ZeroTierBridge)
//    2. zts_bsd_select detects new connections (like the POSIX select of guest mode)
//    3. once a client connects (acceptOnSocket:), a local BSD socket is created connecting to 127.0.0.1:localHostPort
//    4. forward data in both directions (libzt socket <-> local BSD socket)
//    5. a generation counter stops an old thread accepting again after a quick stop->start
//
//  The threading model:
//    - main thread: startGuestMode / startHostMode / stop
//    - accept thread: an NSThread looping over new connections (POSIX select in guest mode, zts_bsd_select in host mode)
//    - client handling threads: an NSThread per client
//    - forwarding tasks: a concurrent GCD queue with two tasks per connection (posix->zt and zt->posix)
//
//  Stability mechanisms (shared by both modes):
//    - a generation counter: stops an old accept thread accepting again after a quick stop->start
//    - TCP_NODELAY: disables the Nagle algorithm, lowering latency for a real-time game
//    - SO_KEEPALIVE + aggressive keepalive parameters: detects half-dead connections promptly
//    - SO_SNDTIMEO / SO_RCVTIMEO: stops a forwarding thread blocking forever
//    - SO_NOSIGPIPE: prevents a SIGPIPE crash
//    - atomic_bool: memory visibility across threads
//    - an active fd list: stop shuts them down to wake blocked read/recv calls
//
//  =============================================================================

#import "PortForwarder.h"
#import "ZeroTierBridge.h"
#import "utils.h"

// POSIX socket headers
#include <sys/socket.h>
#include <netinet/in.h>
#include <netinet/tcp.h>  // TCP_NODELAY (disabling the Nagle algorithm to lower latency)
#include <arpa/inet.h>
#include <unistd.h>
#include <string.h>
#include <errno.h>
#include <sys/select.h>
#include <sys/time.h>
#include <fcntl.h>      // fcntl (F_GETFL/F_SETFL/O_NONBLOCK, used by the non-blocking connect)
#include <stdatomic.h>  // C11 atomics, used for the bidirectional forwarding flags

#pragma mark - Constant definitions

/// The default local listening port of the port forwarder (the default Minecraft server port)
const uint16_t PortForwarderDefaultLocalPort = 25565;

/// Error domain
static NSString * const kPortForwarderErrorDomain = @"PortForwarderErrorDomain";

/// The data forwarding buffer size (64KB)
#define PORT_FORWARDER_BUFFER_SIZE 65536

/// The remote connection timeout (10 seconds)
#define PORT_FORWARDER_CONNECT_TIMEOUT 10.0

/// The maximum listen backlog
#define PORT_FORWARDER_BACKLOG 16

/// The maximum number of port conflict retries
#define PORT_FORWARDER_MAX_PORT_RETRIES 10

#pragma mark - Helper functions

/// Write every byte to an fd (looping over write until everything is written or it errors)
/// @param fd The file descriptor
/// @param buffer The data buffer
/// @param length The data length
/// @return The number of bytes actually written, or -1 on error
static ssize_t writeAll(int fd, const uint8_t *buffer, size_t length) {
    size_t totalWritten = 0;
    while (totalWritten < length) {
        ssize_t n = write(fd, buffer + totalWritten, length - totalWritten);
        if (n < 0) {
            if (errno == EINTR) {
                // Interrupted by a signal, so retry
                continue;
            }
            // Key fix (P1-4): handle the SO_SNDTIMEO timeout
            // EAGAIN/EWOULDBLOCK means the send buffer is temporarily unavailable (the SO_SNDTIMEO timeout was reached).
            // Returning -1 straight away treated it as an error, so the forwarding thread exited and the connection dropped.
            // For real-time game traffic a timeout usually means the peer cannot keep up, so the connection should be dropped and let Minecraft reconnect
            // rather than blocking forever. Returning -1 here lets the caller close the connection.
            if (errno == EAGAIN || errno == EWOULDBLOCK) {
                NSLog(@"[PortForwarder] writeAll timeout (fd=%d), closing connection", fd);
            }
            // A real error
            return -1;
        }
        if (n == 0) {
            // This should not happen
            break;
        }
        totalWritten += (size_t)n;
    }
    return (ssize_t)totalWritten;
}

#pragma mark - PortForwarder class extension

@interface PortForwarder () {
    /// The listening socket file descriptor (-1 when none has been created)
    /// Guest mode: a POSIX socket fd
    /// Host mode: a libzt socket fd
    int _listenFD;

    /// The accept thread
    NSThread *_acceptThread;

    /// The lock guarding the internal state
    NSLock *_lock;

    /// Whether a stop is in progress (used to tell the accept thread to exit)
    BOOL _stopping;

    /// Key fix (P1-8): the accept thread generation counter
    /// It increments on every start, and acceptLoop captures the current generation when it begins
    /// and checks it still matches on every iteration. If it does not (meaning a stop->start happened in between),
    /// the old thread exits immediately, so it does not accept on the same listenFD as the accept thread started by the new run.
    int _acceptGeneration;

    /// The set of active POSIX socket fds (shut down by stop to wake blocked reads)
    /// Guest mode: the client fds accept returned
    /// Host mode: the fds connected to the local MC LAN port
    NSMutableArray<NSNumber *> *_activePosixFDs;

    /// The set of active libzt socket fds (shut down by stop to wake blocked recvData calls)
    /// Guest mode: the libzt fds connected to the remote host
    /// Host mode: the libzt client fds acceptOnSocket: returned
    NSMutableArray<NSNumber *> *_activeZtFDs;
}

/// The actual listening port
@property (nonatomic, assign, readwrite) uint16_t listeningPort;

/// Whether it is running
@property (nonatomic, assign, readwrite, getter=isRunning) BOOL running;

/// The current mode
@property (nonatomic, assign, readwrite) PortForwarderMode mode;

/// Guest mode: the remote host address (the host ZeroTier IP)
@property (nonatomic, copy, readwrite, nullable) NSString *hostIP;

/// Guest mode: the remote port (the host MC LAN port)
@property (nonatomic, assign, readwrite) uint16_t hostPort;

/// Host mode: the local MC LAN port
@property (nonatomic, assign, readwrite) uint16_t localHostPort;

#pragma mark - Guest mode private methods

/// The main loop of the guest-mode accept thread
/// @param myGen The generation captured at startup
- (void)guestAcceptLoopWithGeneration:(int)myGen;

/// Guest mode: handle a client connection
/// @param clientFD The client socket file descriptor (a POSIX socket)
- (void)handleGuestClient:(int)clientFD;

#pragma mark - Host mode private methods

/// The main loop of the host-mode accept thread
/// @param myGen The generation captured at startup
- (void)hostAcceptLoopWithGeneration:(int)myGen;

/// Host mode: handle a connection accepted over ZeroTier
/// @param ztClientFD The libzt client socket file descriptor
- (void)handleHostConnection:(int)ztClientFD;

#pragma mark - Shared private methods

/// Forward data in both directions
/// @param posixFD The POSIX socket (the client in guest mode, the local connection in host mode)
/// @param ztFD The libzt socket (the remote in guest mode, the client in host mode)
- (void)forwardDataBetweenPosixFD:(int)posixFD
                             ztFD:(int)ztFD;

@end

#pragma mark - PortForwarder implementation

@implementation PortForwarder

#pragma mark - Singleton

/// Get the shared PortForwarder singleton
/// dispatch_once guarantees thread-safe one-time initialization
+ (instancetype)sharedForwarder {
    static PortForwarder *shared = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        shared = [[self alloc] init];
    });
    return shared;
}

/// allocWithZone: is overridden so alloc/init cannot create a second instance
+ (instancetype)allocWithZone:(struct _NSZone *)zone {
    static PortForwarder *shared = nil;
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
        _acceptThread = nil;
        _stopping = NO;
        _running = NO;
        _mode = PortForwarderModeNone;
        _listeningPort = 0;
        _hostIP = nil;
        _hostPort = 0;
        _localHostPort = 0;
        _lock = [[NSLock alloc] init];
        _activePosixFDs = [[NSMutableArray alloc] init];
        _activeZtFDs = [[NSMutableArray alloc] init];
        _acceptGeneration = 0;
        NSLog(@"[PortForwarder] Singleton initialized");
    }
    return self;
}

#pragma mark - Starting guest mode

/// Start guest mode
///
/// The full flow:
///   1. validate the parameters
///   2. check whether it is already running
///   3. check that the ZeroTier framework is available
///   4. create the listening socket (trying ports localPort through localPort+9)
///   5. bind + listen
///   6. start the accept thread
- (BOOL)startGuestModeWithLocalPort:(uint16_t)localPort
                              hostIP:(NSString *)hostIP
                            hostPort:(uint16_t)hostPort {
    // ============================================================
    // Step 1: validate the parameters
    // ============================================================
    if (!hostIP || hostIP.length == 0) {
        NSLog(@"[PortForwarder] Guest mode start failed: hostIP is empty");
        return NO;
    }

    if (hostPort == 0) {
        NSLog(@"[PortForwarder] Guest mode start failed: hostPort is 0");
        return NO;
    }

    // ============================================================
    // Step 2: check whether it is already running
    // ============================================================
    [_lock lock];
    if (_running) {
        [_lock unlock];
        NSLog(@"[PortForwarder] Guest mode start failed: forwarder already running (mode=%ld, port %u)",
              (long)_mode, _listeningPort);
        return NO;
    }
    [_lock unlock];

    // ============================================================
    // Step 3: check that the ZeroTier framework is available
    // ============================================================
    if (![[ZeroTierBridge sharedInstance] isFrameworkAvailable]) {
        NSLog(@"[PortForwarder] Guest mode start failed: ZeroTier framework unavailable");
        return NO;
    }

    // ============================================================
    // Step 4: create the listening socket (trying ports localPort through localPort+9)
    // ============================================================
    NSLog(@"[PortForwarder] Starting guest mode: local %u (or +1~+9) → %@:%u",
          localPort, hostIP, hostPort);

    int listenFD = -1;
    uint16_t actualPort = 0;

    for (int retry = 0; retry < PORT_FORWARDER_MAX_PORT_RETRIES; retry++) {
        uint16_t tryPort = localPort + retry;

        // Create the TCP socket
        listenFD = socket(AF_INET, SOCK_STREAM, 0);
        if (listenFD < 0) {
            NSLog(@"[PortForwarder] socket() failed: errno=%d (%s)", errno, strerror(errno));
            continue;
        }

        // Set SO_REUSEADDR, so bind does not fail while the port is in TIME_WAIT
        int reuseAddr = 1;
        setsockopt(listenFD, SOL_SOCKET, SO_REUSEADDR, &reuseAddr, sizeof(reuseAddr));

        // Bind to 127.0.0.1:tryPort (loopback only, not exposed externally)
        struct sockaddr_in bindAddr;
        memset(&bindAddr, 0, sizeof(bindAddr));
        bindAddr.sin_family = AF_INET;
        bindAddr.sin_addr.s_addr = htonl(INADDR_LOOPBACK);  // 127.0.0.1
        bindAddr.sin_port = htons(tryPort);

        int bindResult = bind(listenFD, (struct sockaddr *)&bindAddr, sizeof(bindAddr));
        if (bindResult < 0) {
            NSLog(@"[PortForwarder] bind(%u) failed: errno=%d (%s), trying next port",
                  tryPort, errno, strerror(errno));
            close(listenFD);
            listenFD = -1;
            continue;
        }

        // bind succeeded
        actualPort = tryPort;
        NSLog(@"[PortForwarder] bind succeeded: port %u", actualPort);
        break;
    }

    // If every port fails to bind, finally try port=0 (letting the system choose)
    if (listenFD < 0) {
        NSLog(@"[PortForwarder] All specified ports failed to bind, trying system auto-assigned port...");
        listenFD = socket(AF_INET, SOCK_STREAM, 0);
        if (listenFD < 0) {
            NSLog(@"[PortForwarder] socket() failed: errno=%d (%s)", errno, strerror(errno));
            return NO;
        }

        int reuseAddr = 1;
        setsockopt(listenFD, SOL_SOCKET, SO_REUSEADDR, &reuseAddr, sizeof(reuseAddr));

        struct sockaddr_in bindAddr;
        memset(&bindAddr, 0, sizeof(bindAddr));
        bindAddr.sin_family = AF_INET;
        bindAddr.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
        bindAddr.sin_port = htons(0);  // Let the system pick the port

        int bindResult = bind(listenFD, (struct sockaddr *)&bindAddr, sizeof(bindAddr));
        if (bindResult < 0) {
            NSLog(@"[PortForwarder] bind(0) failed: errno=%d (%s)", errno, strerror(errno));
            close(listenFD);
            return NO;
        }

        // Read back the port the system assigned
        struct sockaddr_in actualAddr;
        socklen_t addrLen = sizeof(actualAddr);
        if (getsockname(listenFD, (struct sockaddr *)&actualAddr, &addrLen) == 0) {
            actualPort = ntohs(actualAddr.sin_port);
        }
        NSLog(@"[PortForwarder] System auto-assigned port: %u", actualPort);
    }

    // ============================================================
    // Step 5: listen
    // ============================================================
    int listenResult = listen(listenFD, PORT_FORWARDER_BACKLOG);
    if (listenResult < 0) {
        NSLog(@"[PortForwarder] listen() failed: errno=%d (%s)", errno, strerror(errno));
        close(listenFD);
        return NO;
    }

    // ============================================================
    // Step 6: update the state and start the accept thread
    // ============================================================
    [_lock lock];
    _listenFD = listenFD;
    _listeningPort = actualPort;
    _hostIP = [hostIP copy];
    _hostPort = hostPort;
    _localHostPort = 0;
    _mode = PortForwarderModeGuest;
    _running = YES;
    _stopping = NO;
    // Key fix (P1-8): increment the generation to mark this start cycle
    // This solves the case where a quick stop->start leaves the old accept thread running and both threads
    // accept on the same listenFD (the fd number can be reused), causing duplicate accepts
    _acceptGeneration++;
    int myGen = _acceptGeneration;
    [_lock unlock];

    // Start the accept thread with the current generation
    __weak typeof(self) weakSelf = self;
    _acceptThread = [[NSThread alloc] initWithBlock:^{
        [weakSelf guestAcceptLoopWithGeneration:myGen];
    }];
    _acceptThread.name = @"PortForwarder-GuestAccept";
    [_acceptThread start];

    NSLog(@"[PortForwarder] Guest mode started: 127.0.0.1:%u → %@:%u",
          actualPort, hostIP, hostPort);

    return YES;
}

#pragma mark - Starting host mode

/// Start host mode
///
/// The full flow:
///   1. validate the parameters
///   2. check whether it is already running
///   3. check that the ZeroTier framework is available
///   4. create the libzt listening socket through ZeroTierBridge
///   5. bind + listen (within the ZeroTier virtual network)
///   6. start the accept thread
- (BOOL)startHostModeWithListenPort:(uint16_t)listenPort
                       localHostPort:(uint16_t)localHostPort {
    // ============================================================
    // Step 1: validate the parameters
    // ============================================================
    if (listenPort == 0) {
        NSLog(@"[PortForwarder] Host mode start failed: listenPort is 0");
        return NO;
    }

    if (localHostPort == 0) {
        NSLog(@"[PortForwarder] Host mode start failed: localHostPort is 0");
        return NO;
    }

    // ============================================================
    // Step 2: check whether it is already running
    // ============================================================
    [_lock lock];
    if (_running) {
        [_lock unlock];
        NSLog(@"[PortForwarder] Host mode start failed: forwarder already running (mode=%ld, port %u)",
              (long)_mode, _listeningPort);
        return NO;
    }
    [_lock unlock];

    // ============================================================
    // Step 3: check that the ZeroTier framework is available
    // ============================================================
    if (![[ZeroTierBridge sharedInstance] isFrameworkAvailable]) {
        NSLog(@"[PortForwarder] Host mode start failed: ZeroTier framework unavailable");
        return NO;
    }

    // ============================================================
    // Step 4: create the libzt listening socket
    // ============================================================
    NSLog(@"[PortForwarder] Starting host mode: ZeroTier listening %u → local 127.0.0.1:%u",
          listenPort, localHostPort);

    int ztListenFD = [[ZeroTierBridge sharedInstance] createListenSocket];
    if (ztListenFD < 0) {
        NSLog(@"[PortForwarder] createListenSocket failed: fd=%d", ztListenFD);
        return NO;
    }

    // ============================================================
    // Step 5: bind + listen (within the ZeroTier virtual network)
    // ============================================================
    int bindResult = [[ZeroTierBridge sharedInstance] bindSocket:ztListenFD toPort:listenPort];
    if (bindResult != 0) {
        NSLog(@"[PortForwarder] bindSocket(%u) failed: result=%d", listenPort, bindResult);
        [[ZeroTierBridge sharedInstance] closeSocket:ztListenFD];
        return NO;
    }

    int listenResult = [[ZeroTierBridge sharedInstance] listenOnSocket:ztListenFD];
    if (listenResult != 0) {
        NSLog(@"[PortForwarder] listenOnSocket failed: result=%d", listenResult);
        [[ZeroTierBridge sharedInstance] closeSocket:ztListenFD];
        return NO;
    }

    NSLog(@"[PortForwarder] libzt listening succeeded: ZeroTier network port %u (fd=%d)", listenPort, ztListenFD);

    // ============================================================
    // Step 6: update the state and start the accept thread
    // ============================================================
    [_lock lock];
    _listenFD = ztListenFD;
    _listeningPort = listenPort;
    _hostIP = nil;
    _hostPort = 0;
    _localHostPort = localHostPort;
    _mode = PortForwarderModeHost;
    _running = YES;
    _stopping = NO;
    // Increment the generation to mark this start cycle (the same stability mechanism as guest mode)
    _acceptGeneration++;
    int myGen = _acceptGeneration;
    [_lock unlock];

    // Start the accept thread with the current generation
    __weak typeof(self) weakSelf = self;
    _acceptThread = [[NSThread alloc] initWithBlock:^{
        [weakSelf hostAcceptLoopWithGeneration:myGen];
    }];
    _acceptThread.name = @"PortForwarder-HostAccept";
    [_acceptThread start];

    NSLog(@"[PortForwarder] Host mode started: ZeroTier :%u → local 127.0.0.1:%u",
          listenPort, localHostPort);

    return YES;
}

#pragma mark - Guest mode accept thread

/// The main loop of the guest-mode accept thread
///
/// POSIX select detects whether the listening socket is readable (a new connection),
/// so stop can wake select by closing the listening socket and exit cleanly.
///
/// Key fix (P1-8): it takes a generation parameter.
/// After a quick stop->start the old accept thread may not have exited yet. Because the fd number can be
/// reused by the system (a new socket can get the same number after the old listenFD closes), the old thread would
/// wrongly accept connections on the new listenFD, causing duplicate accepts and confused state.
/// The generation counter identifies the old thread and makes it exit on its own.
- (void)guestAcceptLoopWithGeneration:(int)myGen {
    NSLog(@"[PortForwarder] Guest mode Accept thread started (generation=%d)", myGen);

    while (YES) {
        @autoreleasepool {
            [_lock lock];
            int listenFD = _listenFD;
            BOOL stopping = _stopping;
            int currentGen = _acceptGeneration;
            [_lock unlock];

            // Key fix (P1-8): a generation mismatch means a stop->start happened in between,
            // so this accept thread belongs to the previous cycle and must exit immediately, leaving listenFD to the new thread
            if (currentGen != myGen) {
                NSLog(@"[PortForwarder] Guest Accept thread: generation mismatch (my=%d, current=%d), exiting loop",
                      myGen, currentGen);
                break;
            }

            if (stopping || listenFD < 0) {
                NSLog(@"[PortForwarder] Guest Accept thread: received stop signal, exiting loop");
                break;
            }

            // Use select to wait for the listening socket to become readable (a new connection)
            // The select timeout is 1 second, so the _stopping flag is checked regularly
            fd_set readSet;
            FD_ZERO(&readSet);
            FD_SET(listenFD, &readSet);

            struct timeval timeout;
            timeout.tv_sec = 1;
            timeout.tv_usec = 0;

            int selectResult = select(listenFD + 1, &readSet, NULL, NULL, &timeout);
            if (selectResult < 0) {
                if (errno == EINTR) {
                    // Interrupted by a signal, so retry
                    continue;
                }
                NSLog(@"[PortForwarder] select() failed: errno=%d (%s)", errno, strerror(errno));
                break;
            }

            if (selectResult == 0) {
                // Timed out with no new connection, so keep looping
                continue;
            }

            // There is a new connection
            if (FD_ISSET(listenFD, &readSet)) {
                struct sockaddr_in clientAddr;
                socklen_t clientAddrLen = sizeof(clientAddr);
                int clientFD = accept(listenFD, (struct sockaddr *)&clientAddr, &clientAddrLen);

                if (clientFD < 0) {
                    if (errno == EINTR || errno == EAGAIN || errno == EWOULDBLOCK) {
                        continue;
                    }
                    NSLog(@"[PortForwarder] accept() failed: errno=%d (%s)", errno, strerror(errno));

                    // EBADF means the listening socket has been closed (stop was called)
                    if (errno == EBADF) {
                        break;
                    }
                    continue;
                }

                // Get the client IP and port (for the log)
                char clientIP[INET_ADDRSTRLEN] = {0};
                inet_ntop(AF_INET, &clientAddr.sin_addr, clientIP, sizeof(clientIP));
                uint16_t clientPort = ntohs(clientAddr.sin_port);
                NSLog(@"[PortForwarder] Guest mode new client connection: %s:%u (fd=%d)", clientIP, clientPort, clientFD);

                // Handle the client connection on a new thread
                __weak typeof(self) weakSelf = self;
                NSThread *clientThread = [[NSThread alloc] initWithBlock:^{
                    [weakSelf handleGuestClient:clientFD];
                }];
                clientThread.name = [NSString stringWithFormat:@"PortForwarder-GuestClient-%d", clientFD];
                [clientThread start];
            }
        }
    }

    NSLog(@"[PortForwarder] Guest mode Accept thread exited");
}

#pragma mark - Host mode accept thread

/// The main loop of the host-mode accept thread
///
/// zts_bsd_select detects whether the libzt listening socket is readable (a new connection),
/// so stop can wake select by closing the listening socket and exit cleanly.
///
/// with the same generation counter mechanism as guest mode, stopping an old thread accepting again after a quick stop->start.
- (void)hostAcceptLoopWithGeneration:(int)myGen {
    NSLog(@"[PortForwarder] Host mode Accept thread started (generation=%d)", myGen);

    while (YES) {
        @autoreleasepool {
            [_lock lock];
            int listenFD = _listenFD;
            BOOL stopping = _stopping;
            int currentGen = _acceptGeneration;
            [_lock unlock];

            // A generation mismatch means a stop->start happened in between, so this thread belongs to the previous cycle and must exit
            if (currentGen != myGen) {
                NSLog(@"[PortForwarder] Host Accept thread: generation mismatch (my=%d, current=%d), exiting loop",
                      myGen, currentGen);
                break;
            }

            if (stopping || listenFD < 0) {
                NSLog(@"[PortForwarder] Host Accept thread: received stop signal, exiting loop");
                break;
            }

            // Use zts_bsd_select to wait for the libzt listening socket to become readable (a new connection)
            // The select timeout is 1 second, so the _stopping flag is checked regularly
            zts_fd_set readSet;
            ZTS_FD_ZERO(&readSet);
            ZTS_FD_SET(listenFD, &readSet);

            struct zts_timeval timeout;
            timeout.tv_sec = 1;
            timeout.tv_usec = 0;

            int selectResult = zts_bsd_select(listenFD + 1, &readSet, NULL, NULL, &timeout);
            if (selectResult < 0) {
                NSLog(@"[PortForwarder] zts_bsd_select() failed: result=%d", selectResult);
                // EBADF or a service error means the listening socket has been closed (stop was called)
                break;
            }

            if (selectResult == 0) {
                // Timed out with no new connection, so keep looping
                continue;
            }

            // There is a new connection
            if (ZTS_FD_ISSET(listenFD, &readSet)) {
                int ztClientFD = [[ZeroTierBridge sharedInstance] acceptOnSocket:listenFD];

                if (ztClientFD < 0) {
                    // accept failed, either transiently or because the listening socket has closed
                    NSLog(@"[PortForwarder] acceptOnSocket failed: fd=%d", ztClientFD);
                    continue;
                }

                NSLog(@"[PortForwarder] Host mode new connection via ZeroTier (ztClientFD=%d)", ztClientFD);

                // Handle the connection on a new thread
                __weak typeof(self) weakSelf = self;
                NSThread *connThread = [[NSThread alloc] initWithBlock:^{
                    [weakSelf handleHostConnection:ztClientFD];
                }];
                connThread.name = [NSString stringWithFormat:@"PortForwarder-HostConn-%d", ztClientFD];
                [connThread start];
            }
        }
    }

    NSLog(@"[PortForwarder] Host mode Accept thread exited");
}

#pragma mark - Guest mode client handling

/// Guest mode: handle a client connection
///
/// The flow:
///   1. create a libzt socket through ZeroTierBridge
///   2. connect to the remote host hostIP:hostPort
///   3. forward data in both directions
///   4. close the connection
- (void)handleGuestClient:(int)clientFD {
    @autoreleasepool {
        [_lock lock];
        NSString *hostIP = [_hostIP copy];
        uint16_t hostPort = _hostPort;
        [_lock unlock];

        if (!hostIP.length) {
            NSLog(@"[PortForwarder] handleGuestClient: hostIP is empty, closing client connection");
            close(clientFD);
            return;
        }

        NSLog(@"[PortForwarder] Handling guest client connection fd=%d, forwarding to %@:%u", clientFD, hostIP, hostPort);

        // Set TCP_NODELAY on the client socket (disabling the Nagle algorithm)
        //
        // A key performance win: Minecraft is a real-time game, so player input must reach the server immediately.
        // The Nagle algorithm coalesces small packets to reduce overhead, at the cost of latency.
        // For a real-time game like Minecraft latency matters more than bandwidth, so Nagle must be off.
        int clientNoDelay = 1;
        setsockopt(clientFD, IPPROTO_TCP, TCP_NODELAY, &clientNoDelay, sizeof(clientNoDelay));

        // Set SO_KEEPALIVE on the client socket (connection keepalive)
        //
        // A key stability win: a Minecraft TCP connection can go a long time with no traffic (an idle player),
        // and an intermediate NAT/firewall may drop the connection table entry on a timeout, leaving the connection half-dead.
        // SO_KEEPALIVE makes the system send keepalive probes regularly, keeping the connection alive.
        int clientKeepAlive = 1;
        setsockopt(clientFD, SOL_SOCKET, SO_KEEPALIVE, &clientKeepAlive, sizeof(clientKeepAlive));

        // Key fix (P1-4): set SO_SNDTIMEO / SO_RCVTIMEO / SO_NOSIGPIPE on the client socket
        //
        // The problem: writeAll only retried on EINTR and had no timeout. When the Minecraft client receive buffer filled up
        // (a stalled main thread, a large chunk load), write blocked forever and leaked the forwarding thread.
        // Even with stop() calling shutdown(clientFD, SHUT_RDWR), a thread stuck in write rather than read
        // is not necessarily woken by shutdown (it depends on the kernel).
        //
        // The fix: a 30-second send/receive timeout plus SO_NOSIGPIPE to prevent a SIGPIPE crash.
        // After the timeout writeAll returns EAGAIN/EWOULDBLOCK and the forwarding loop can exit on its own.
        struct timeval ioTimeout;
        ioTimeout.tv_sec = 30;
        ioTimeout.tv_usec = 0;
        setsockopt(clientFD, SOL_SOCKET, SO_SNDTIMEO, &ioTimeout, sizeof(ioTimeout));
        setsockopt(clientFD, SOL_SOCKET, SO_RCVTIMEO, &ioTimeout, sizeof(ioTimeout));
        int clientNoSigPipe = 1;
        setsockopt(clientFD, SOL_SOCKET, SO_NOSIGPIPE, &clientNoSigPipe, sizeof(clientNoSigPipe));

        // Key fix (P2-11): the iOS default keepalive interval is about 2 hours, too slow to detect a half-dead connection.
        // The parameters are now more aggressive: probing starts after 30s idle, every 10s, and 3 failures mean it is dead.
        // TCP_KEEPALIVE is the iOS option for the keep-alive interval (macOS uses TCP_KEEPALIVE and
        // Linux uses TCP_KEEPIDLE; only iOS is compiled here, so TCP_KEEPALIVE is used).
        int keepIdle = 30;
        setsockopt(clientFD, IPPROTO_TCP, TCP_KEEPALIVE, &keepIdle, sizeof(keepIdle));
        int keepIntvl = 10;
        setsockopt(clientFD, IPPROTO_TCP, TCP_KEEPINTVL, &keepIntvl, sizeof(keepIntvl));
        int keepCnt = 3;
        setsockopt(clientFD, IPPROTO_TCP, TCP_KEEPCNT, &keepCnt, sizeof(keepCnt));

        // ============================================================
        // Step 1: create the libzt socket
        // ============================================================
        // inet_pton validates the address type strictly, so it cannot be misjudged
        BOOL isIPv6Target = (zts_inet_pton(ZTS_AF_INET6, [hostIP UTF8String], NULL) == 1);
        int socketFamily = isIPv6Target ? ZTS_AF_INET6 : ZTS_AF_INET;

        int ztFD = [[ZeroTierBridge sharedInstance] createTCPSocketForFamily:socketFamily];
        if (ztFD < 0) {
            NSLog(@"[PortForwarder] Creating ZeroTier socket(family=%d) failed: ztFD=%d", socketFamily, ztFD);
            close(clientFD);
            return;
        }

        // Set TCP_NODELAY on the libzt socket too (lowering latency on the ZeroTier virtual network)
        int ztNoDelay = 1;
        zts_bsd_setsockopt(ztFD, ZTS_IPPROTO_TCP, ZTS_TCP_NODELAY, &ztNoDelay, sizeof(ztNoDelay));

        // ============================================================
        // Step 2: connect to the remote host
        // ============================================================
        int connectResult = [[ZeroTierBridge sharedInstance] connectSocket:ztFD
                                                                    toHost:hostIP
                                                                      port:hostPort
                                                                   timeout:PORT_FORWARDER_CONNECT_TIMEOUT];
        if (connectResult != 0) {
            NSLog(@"[PortForwarder] Connecting to target via ZeroTier failed: result=%d, target=%@:%u",
                  connectResult, hostIP, hostPort);
            [[ZeroTierBridge sharedInstance] closeSocket:ztFD];
            close(clientFD);
            return;
        }

        NSLog(@"[PortForwarder] Connected to target via ZeroTier successfully: target=%@:%u, ztFD=%d",
              hostIP, hostPort, ztFD);

        // Add the fd to the active list (so stop can shut it down and wake a blocked read/recv)
        // Key fix (P1-7): stop may have been called during connect, and when stop copied the active list
        // this connection was not in it yet, so the fd slipped through, kept forwarding after the stop and was never cleaned up.
        // The fix: check _running before adding it to the active list, and close the fd and return if it has stopped.
        [_lock lock];
        BOOL stillRunning = _running;
        if (stillRunning) {
            [_activePosixFDs addObject:@(clientFD)];
            [_activeZtFDs addObject:@(ztFD)];
        }
        [_lock unlock];

        if (!stillRunning) {
            NSLog(@"[PortForwarder] handleGuestClient: forwarder stopped, closing new connection clientFD=%d ztFD=%d",
                  clientFD, ztFD);
            [[ZeroTierBridge sharedInstance] closeSocket:ztFD];
            close(clientFD);
            return;
        }

        // ============================================================
        // Step 3: forward data in both directions
        // ============================================================
        [self forwardDataBetweenPosixFD:clientFD ztFD:ztFD];

        // Remove it from the active list (forwarding is over and the fd is about to close)
        [_lock lock];
        [_activePosixFDs removeObject:@(clientFD)];
        [_activeZtFDs removeObject:@(ztFD)];
        [_lock unlock];

        // ============================================================
        // Step 4: close the connection
        // ============================================================
        NSLog(@"[PortForwarder] Guest forwarding ended, closing connection: clientFD=%d, ztFD=%d", clientFD, ztFD);
        [[ZeroTierBridge sharedInstance] closeSocket:ztFD];
        close(clientFD);
    }
}

#pragma mark - Host mode connection handling

/// Host mode: handle a connection accepted over ZeroTier
///
/// The flow:
///   1. set TCP_NODELAY on the libzt client fd
///   2. create a local BSD socket
///   3. connect to 127.0.0.1:localHostPort (the MC LAN port)
///   4. forward data in both directions (libzt socket <-> local BSD socket)
///   5. close the connection
- (void)handleHostConnection:(int)ztClientFD {
    @autoreleasepool {
        [_lock lock];
        uint16_t localHostPort = _localHostPort;
        [_lock unlock];

        if (localHostPort == 0) {
            NSLog(@"[PortForwarder] handleHostConnection: localHostPort is 0, closing connection");
            [[ZeroTierBridge sharedInstance] closeSocket:ztClientFD];
            return;
        }

        NSLog(@"[PortForwarder] Handling host connection ztClientFD=%d, forwarding to local 127.0.0.1:%u",
              ztClientFD, localHostPort);

        // Set TCP_NODELAY on the libzt client fd (lowering latency on the ZeroTier virtual network)
        int ztNoDelay = 1;
        zts_bsd_setsockopt(ztClientFD, ZTS_IPPROTO_TCP, ZTS_TCP_NODELAY, &ztNoDelay, sizeof(ztNoDelay));

        // ============================================================
        // Step 1: create the local BSD socket
        // ============================================================
        int localFD = socket(AF_INET, SOCK_STREAM, 0);
        if (localFD < 0) {
            NSLog(@"[PortForwarder] Creating local socket failed: errno=%d (%s)", errno, strerror(errno));
            [[ZeroTierBridge sharedInstance] closeSocket:ztClientFD];
            return;
        }

        // Set TCP_NODELAY on the local socket (disabling the Nagle algorithm to lower latency)
        int localNoDelay = 1;
        setsockopt(localFD, IPPROTO_TCP, TCP_NODELAY, &localNoDelay, sizeof(localNoDelay));

        // Set SO_KEEPALIVE on the local socket (connection keepalive)
        int localKeepAlive = 1;
        setsockopt(localFD, SOL_SOCKET, SO_KEEPALIVE, &localKeepAlive, sizeof(localKeepAlive));

        // Set SO_SNDTIMEO / SO_RCVTIMEO / SO_NOSIGPIPE (the same stability mechanisms as guest mode)
        struct timeval ioTimeout;
        ioTimeout.tv_sec = 30;
        ioTimeout.tv_usec = 0;
        setsockopt(localFD, SOL_SOCKET, SO_SNDTIMEO, &ioTimeout, sizeof(ioTimeout));
        setsockopt(localFD, SOL_SOCKET, SO_RCVTIMEO, &ioTimeout, sizeof(ioTimeout));
        int localNoSigPipe = 1;
        setsockopt(localFD, SOL_SOCKET, SO_NOSIGPIPE, &localNoSigPipe, sizeof(localNoSigPipe));

        // Aggressive keepalive parameters (the same as guest mode)
        int keepIdle = 30;
        setsockopt(localFD, IPPROTO_TCP, TCP_KEEPALIVE, &keepIdle, sizeof(keepIdle));
        int keepIntvl = 10;
        setsockopt(localFD, IPPROTO_TCP, TCP_KEEPINTVL, &keepIntvl, sizeof(keepIntvl));
        int keepCnt = 3;
        setsockopt(localFD, IPPROTO_TCP, TCP_KEEPCNT, &keepCnt, sizeof(keepCnt));

        // ============================================================
        // Step 2: connect to the local MC LAN port (a non-blocking connect with a select timeout)
        // ============================================================
        // Key fix: a blocking connect() was used before, and SO_SNDTIMEO/SO_RCVTIMEO do not affect connect(),
        // so if the SYN was dropped because of something unusual (a firewall, an odd system state) it blocked forever,
        // and the shutdown in stop() does not wake a socket mid-connect, leaking the connection handling thread.
        // It now uses a non-blocking connect with a 5-second select timeout, closing the fd and freeing the thread on a timeout.
        struct sockaddr_in localAddr;
        memset(&localAddr, 0, sizeof(localAddr));
        localAddr.sin_family = AF_INET;
        localAddr.sin_addr.s_addr = htonl(INADDR_LOOPBACK);  // 127.0.0.1
        localAddr.sin_port = htons(localHostPort);

        // Put the socket into non-blocking mode
        int flags = fcntl(localFD, F_GETFL, 0);
        if (flags < 0 || fcntl(localFD, F_SETFL, flags | O_NONBLOCK) < 0) {
            NSLog(@"[PortForwarder] Setting non-blocking failed: errno=%d (%s), falling back to blocking connect", errno, strerror(errno));
            // Fall back to a blocking connect (loopback usually returns immediately, so the impact is small)
            int connectResult = connect(localFD, (struct sockaddr *)&localAddr, sizeof(localAddr));
            if (connectResult < 0) {
                NSLog(@"[PortForwarder] Connecting to local MC LAN port failed: 127.0.0.1:%u, errno=%d (%s)",
                      localHostPort, errno, strerror(errno));
                close(localFD);
                [[ZeroTierBridge sharedInstance] closeSocket:ztClientFD];
                return;
            }
        } else {
            // A non-blocking connect: usually returns -1 (EINPROGRESS) straight away, or 0 when the loopback port is open
            int connectResult = connect(localFD, (struct sockaddr *)&localAddr, sizeof(localAddr));
            if (connectResult < 0) {
                if (errno != EINPROGRESS) {
                    // Failed immediately (ECONNREFUSED means the port is not open)
                    NSLog(@"[PortForwarder] Connecting to local MC LAN port failed: 127.0.0.1:%u, errno=%d (%s)",
                          localHostPort, errno, strerror(errno));
                    close(localFD);
                    [[ZeroTierBridge sharedInstance] closeSocket:ztClientFD];
                    return;
                }
                // EINPROGRESS: wait for it to become writable (the connection completing), with a 5-second select timeout
                fd_set writeSet;
                FD_ZERO(&writeSet);
                FD_SET(localFD, &writeSet);
                struct timeval connTimeout;
                connTimeout.tv_sec = 5;
                connTimeout.tv_usec = 0;
                int selRet = select(localFD + 1, NULL, &writeSet, NULL, &connTimeout);
                if (selRet <= 0) {
                    // selRet == 0 means a timeout; selRet < 0 means an error
                    NSLog(@"[PortForwarder] Connecting to local MC LAN port timeout/failed: 127.0.0.1:%u, selRet=%d, errno=%d (%s)",
                          localHostPort, selRet, errno, strerror(errno));
                    close(localFD);
                    [[ZeroTierBridge sharedInstance] closeSocket:ztClientFD];
                    return;
                }
                // Check SO_ERROR to confirm the connection really succeeded
                int sockErr = 0;
                socklen_t errLen = sizeof(sockErr);
                if (getsockopt(localFD, SOL_SOCKET, SO_ERROR, &sockErr, &errLen) < 0 || sockErr != 0) {
                    NSLog(@"[PortForwarder] Connecting to local MC LAN port failed (SO_ERROR=%d): 127.0.0.1:%u",
                          sockErr, localHostPort);
                    close(localFD);
                    [[ZeroTierBridge sharedInstance] closeSocket:ztClientFD];
                    return;
                }
            }
            // Restore blocking mode (forwardDataBetweenPosixFD relies on blocking read/write together with SO_RCVTIMEO)
            (void)fcntl(localFD, F_SETFL, flags);
        }

        NSLog(@"[PortForwarder] Connected to local MC LAN port successfully: 127.0.0.1:%u, localFD=%d",
              localHostPort, localFD);

        // Add the fd to the active list (so stop can shut it down and wake a blocked read/recv)
        // The same P1-7 fix as guest mode: check _running so nothing slips through after a stop
        [_lock lock];
        BOOL stillRunning = _running;
        if (stillRunning) {
            [_activePosixFDs addObject:@(localFD)];
            [_activeZtFDs addObject:@(ztClientFD)];
        }
        [_lock unlock];

        if (!stillRunning) {
            NSLog(@"[PortForwarder] handleHostConnection: forwarder stopped, closing new connection localFD=%d ztClientFD=%d",
                  localFD, ztClientFD);
            close(localFD);
            [[ZeroTierBridge sharedInstance] closeSocket:ztClientFD];
            return;
        }

        // ============================================================
        // Step 3: forward data in both directions
        // ============================================================
        [self forwardDataBetweenPosixFD:localFD ztFD:ztClientFD];

        // Remove it from the active list (forwarding is over and the fd is about to close)
        [_lock lock];
        [_activePosixFDs removeObject:@(localFD)];
        [_activeZtFDs removeObject:@(ztClientFD)];
        [_lock unlock];

        // ============================================================
        // Step 4: close the connection
        // ============================================================
        NSLog(@"[PortForwarder] Host forwarding ended, closing connection: localFD=%d, ztClientFD=%d",
              localFD, ztClientFD);
        [[ZeroTierBridge sharedInstance] closeSocket:ztClientFD];
        close(localFD);
    }
}

#pragma mark - Bidirectional data forwarding

/// Forward data in both directions
///
/// Forward data in both directions between a POSIX socket and a libzt socket.
/// A concurrent GCD queue runs both directions at once.
/// An atomic_bool flag guarantees memory visibility across threads.
///
/// The data flow in each mode:
///   guest mode: posixFD = the client (Minecraft), ztFD = the remote (the host over ZeroTier)
///   host mode: posixFD = local (the MC LAN port), ztFD = the client (the guest over ZeroTier)
///
/// @param posixFD The POSIX socket (system read/write)
/// @param ztFD libzt socket（ZeroTierBridge recvData/sendData）
- (void)forwardDataBetweenPosixFD:(int)posixFD
                             ztFD:(int)ztFD {
    // atomic_bool replaces __block BOOL, guaranteeing memory visibility across threads
    // (as in SOCKS5Proxy; the weak ARM64 memory model needs atomics to provide the memory barriers)
    __block atomic_bool posixClosed = ATOMIC_VAR_INIT(false);
    __block atomic_bool ztClosed = ATOMIC_VAR_INIT(false);

    // Create the concurrent queue used for bidirectional forwarding
    dispatch_queue_t forwardQueue = dispatch_queue_create("com.angelaura.portforwarder.forward", DISPATCH_QUEUE_CONCURRENT);
    dispatch_group_t group = dispatch_group_create();

    // ============================================================
    // Direction 1: posix -> zt
    // Read from the POSIX socket (read) and send through the libzt socket (sendData)
    // ============================================================
    dispatch_group_async(group, forwardQueue, ^{
        uint8_t buffer[PORT_FORWARDER_BUFFER_SIZE];

        while (YES) {
            @autoreleasepool {
                // Check whether the peer has closed (an atomic read, which carries a memory barrier)
                if (atomic_load(&ztClosed)) {
                    NSLog(@"[PortForwarder] posix→zt: peer closed, exiting forwarding");
                    break;
                }

                // Read from the POSIX socket (system read)
                ssize_t n = read(posixFD, buffer, sizeof(buffer));
                if (n <= 0) {
                    // n == 0: the POSIX side closed the connection
                    // n < 0: a read error
                    NSLog(@"[PortForwarder] posix→zt ended: n=%zd, errno=%d", n, errno);

                    // Mark the POSIX side as closed (an atomic write, which carries a memory barrier)
                    atomic_store(&posixClosed, true);

                    // Shut down the write side of zt, telling the zt->posix direction to exit
                    // The shutdown makes recv on the other side return 0
                    [[ZeroTierBridge sharedInstance] shutdownSocket:ztFD how:SHUT_WR];
                    break;
                }

                // Send the data through the libzt socket
                ssize_t sent = [[ZeroTierBridge sharedInstance] sendData:ztFD
                                                                  buffer:buffer
                                                                  length:(size_t)n];
                if (sent <= 0) {
                    NSLog(@"[PortForwarder] Sending to zt side failed: sent=%zd", sent);

                    // Mark the zt side as closed (an atomic write)
                    atomic_store(&ztClosed, true);

                    // Shut down the write side of POSIX
                    shutdown(posixFD, SHUT_WR);
                    break;
                }
            }
        }
    });

    // ============================================================
    // Direction 2: zt -> posix
    // Receive from the libzt socket (recvData) and send to the POSIX socket (writeAll)
    // ============================================================
    dispatch_group_async(group, forwardQueue, ^{
        uint8_t buffer[PORT_FORWARDER_BUFFER_SIZE];

        while (YES) {
            @autoreleasepool {
                // Check whether the POSIX side has closed (an atomic read, which carries a memory barrier)
                if (atomic_load(&posixClosed)) {
                    NSLog(@"[PortForwarder] zt→posix: peer closed, exiting forwarding");
                    break;
                }

                // Receive through the libzt socket
                ssize_t n = [[ZeroTierBridge sharedInstance] recvData:ztFD
                                                                buffer:buffer
                                                                length:sizeof(buffer)];
                if (n <= 0) {
                    // n == 0: the zt side closed the connection
                    // n < 0: a receive error
                    NSLog(@"[PortForwarder] zt→posix ended: n=%zd", n);

                    // Mark the zt side as closed (an atomic write)
                    atomic_store(&ztClosed, true);

                    // Shut down the write side of POSIX, telling the posix->zt direction to exit
                    shutdown(posixFD, SHUT_WR);
                    break;
                }

                // Send the data to the POSIX socket (system write)
                ssize_t sent = writeAll(posixFD, buffer, (size_t)n);
                if (sent <= 0) {
                    NSLog(@"[PortForwarder] Sending to POSIX side failed: sent=%zd", sent);

                    // Mark the POSIX side as closed (an atomic write)
                    atomic_store(&posixClosed, true);

                    // Shut down the write side of zt
                    [[ZeroTierBridge sharedInstance] shutdownSocket:ztFD how:SHUT_WR];
                    break;
                }
            }
        }
    });

    // Wait for both directions to finish forwarding
    dispatch_group_wait(group, DISPATCH_TIME_FOREVER);

    NSLog(@"[PortForwarder] Bidirectional forwarding ended: posixFD=%d, ztFD=%d", posixFD, ztFD);
}

#pragma mark - Stopping port forwarding

/// Stop port forwarding (stopping host and guest mode alike)
///
/// The flow:
///   1. set the stop flag
///   2. close the listening socket (waking the select in the accept thread)
///      - guest mode: a POSIX close()
///      - host mode: ZeroTierBridge closeSocket:
///   3. shut down every active POSIX/libzt fd (waking blocked read/recv calls)
///   4. clean up the state
///
/// A key stability improvement: shutting down the active connections
///   Without the shutdown, a read/recvData blocked inside forwardDataBetweenPosixFD:ztFD:
///   never returns and the client thread lives on (a thread leak). shutdown(SHUT_RDWR) immediately
///   wakes every read/write blocked on that fd, so the client thread exits cleanly.
- (void)stop {
    BOOL isMainThread = [NSThread isMainThread];

    [_lock lock];
    if (!_running) {
        [_lock unlock];
        NSLog(@"[PortForwarder] stop: forwarder not running, skipping");
        return;
    }

    PortForwarderMode mode = _mode;
    uint16_t listeningPort = _listeningPort;

    NSLog(@"[PortForwarder] Stopping port forwarding (mode=%ld, port %u, isMainThread=%d)",
          (long)mode, listeningPort, isMainThread);

    _stopping = YES;
    _running = NO;
    int listenFD = _listenFD;
    _listenFD = -1;
    NSThread *acceptThread = _acceptThread;

    // Copy the active fd list (so the lock is not held for long)
    NSArray<NSNumber *> *posixFDs = [_activePosixFDs copy];
    NSArray<NSNumber *> *ztFDs = [_activeZtFDs copy];
    [_activePosixFDs removeAllObjects];
    [_activeZtFDs removeAllObjects];
    [_lock unlock];

    // 1. Close the listening socket, waking the select in the accept thread
    if (listenFD >= 0) {
        if (mode == PortForwarderModeHost) {
            // Host mode: a libzt listening socket, closed through ZeroTierBridge
            [[ZeroTierBridge sharedInstance] closeSocket:listenFD];
        } else {
            // Guest mode: a POSIX listening socket, closed with the system close
            close(listenFD);
        }
    }

    // 2. Shut down every active POSIX/libzt fd (waking blocked read/recv calls)
    NSLog(@"[PortForwarder] Shutting down %lu POSIX connections and %lu libzt connections...",
          (unsigned long)posixFDs.count, (unsigned long)ztFDs.count);

    for (NSNumber *fdNum in posixFDs) {
        int fd = [fdNum intValue];
        if (fd >= 0) {
            // A POSIX socket uses the system shutdown
            shutdown(fd, SHUT_RDWR);
        }
    }

    for (NSNumber *fdNum in ztFDs) {
        int fd = [fdNum intValue];
        if (fd >= 0) {
            // A libzt socket uses the ZeroTierBridge shutdown
            [[ZeroTierBridge sharedInstance] shutdownSocket:fd how:SHUT_RDWR];
        }
    }

    // 3. Clean up the state (the main thread returns at once and the client threads exit in the background)
    [_lock lock];
    _acceptThread = nil;
    _listeningPort = 0;
    _hostIP = nil;
    _hostPort = 0;
    _localHostPort = 0;
    _mode = PortForwarderModeNone;
    _stopping = NO;
    [_lock unlock];

    NSLog(@"[PortForwarder] Port forwarding stopped");
}

@end
