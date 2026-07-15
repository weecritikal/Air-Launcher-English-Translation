//
//  PortForwarder.m
//  Angel Aura Amethyst
//
//  本地 TCP 端口转发器实现
//
//  ============================================================================
//  实现说明
//  ============================================================================
//
//  本文件实现 PortForwarder.h 中定义的本地 TCP 端口转发器。
//
//  关键实现点：
//    1. 监听 socket 使用系统 POSIX socket（socket/bind/listen/accept）
//    2. 客户端连接后，在新线程中处理连接和数据转发
//    3. 远程连接通过 ZeroTierBridge 的 libzt socket API 建立
//    4. 双向转发使用 GCD 并发队列，两个方向同时转发
//    5. 使用 atomic_bool 标志确保跨线程内存可见性
//    6. 端口冲突处理：尝试 localPort 到 localPort+9，最后回退 port=0
//
//  线程模型：
//    - 主线程：startWithLocalPort:remoteHost:remotePort:error: / stop
//    - Accept 线程：NSThread，循环 accept 新连接
//    - 客户端处理线程：NSThread，每个客户端一个
//    - 转发任务：GCD 并发队列，每个连接两个任务（client→remote、remote→client）
//
//  与 SOCKS5Proxy 的区别：
//    - SOCKS5Proxy 需要 SOCKS5 协议握手，适用于支持 SOCKS5 的客户端
//    - PortForwarder 不需要任何协议握手，直接转发 TCP 流量
//    - PortForwarder 适用于 Minecraft 的 Netty 连接（不走 SOCKS5 代理）
//
//  ============================================================================

#import "PortForwarder.h"
#import "ZeroTierBridge.h"
#import "utils.h"

// POSIX socket 头文件
#include <sys/socket.h>
#include <netinet/in.h>
#include <netinet/tcp.h>  // TCP_NODELAY（禁用 Nagle 算法，降低延迟）
#include <arpa/inet.h>
#include <unistd.h>
#include <string.h>
#include <errno.h>
#include <sys/select.h>
#include <sys/time.h>
#include <stdatomic.h>  // C11 原子操作，用于双向转发的标志变量

#pragma mark - 常量定义

/// 端口转发器默认本地监听端口（Minecraft 默认服务器端口）
const uint16_t PortForwarderDefaultLocalPort = 25565;

/// 错误域名
static NSString * const kPortForwarderErrorDomain = @"PortForwarderErrorDomain";

/// 错误码
typedef NS_ENUM(NSInteger, PortForwarderErrorCode) {
    PortForwarderErrorCodeAlreadyRunning       = 1,  // 转发器已在运行
    PortForwarderErrorCodeSocketCreateFailed   = 2,  // 创建 socket 失败
    PortForwarderErrorCodeBindFailed           = 3,  // 绑定端口失败
    PortForwarderErrorCodeListenFailed         = 4,  // 监听失败
    PortForwarderErrorCodeFrameworkUnavailable = 5,  // ZeroTier framework 不可用
    PortForwarderErrorCodeInvalidRemoteHost    = 6,  // 远程主机地址无效
    PortForwarderErrorCodeInvalidRemotePort    = 7,  // 远程端口无效
};

/// 数据转发缓冲区大小（64KB）
#define PORT_FORWARDER_BUFFER_SIZE 65536

/// 远程连接超时时间（10 秒）
#define PORT_FORWARDER_CONNECT_TIMEOUT 10.0

/// 监听队列最大长度
#define PORT_FORWARDER_BACKLOG 16

/// 端口冲突最大重试次数
#define PORT_FORWARDER_MAX_PORT_RETRIES 10

#pragma mark - 辅助函数

/// 将所有数据写入 fd（循环 write 直到所有数据写完或出错）
/// @param fd 文件描述符
/// @param buffer 数据缓冲区
/// @param length 数据长度
/// @return 实际写入的字节数，-1 表示错误
static ssize_t writeAll(int fd, const uint8_t *buffer, size_t length) {
    size_t totalWritten = 0;
    while (totalWritten < length) {
        ssize_t n = write(fd, buffer + totalWritten, length - totalWritten);
        if (n < 0) {
            if (errno == EINTR) {
                // 被信号中断，重试
                continue;
            }
            // 关键修复（P1-4）：处理 SO_SNDTIMEO 超时
            // EAGAIN/EWOULDBLOCK 表示发送缓冲区暂时不可用（达到 SO_SNDTIMEO 超时）。
            // 之前直接返回 -1 视为错误，导致转发线程退出，连接断开。
            // 实际上对于实时游戏流量，超时通常意味着对端处理不过来，应该断开连接让 MC 自动重连，
            // 而不是无限阻塞。这里直接返回 -1 让上层关闭连接。
            if (errno == EAGAIN || errno == EWOULDBLOCK) {
                NSLog(@"[PortForwarder] writeAll 超时（fd=%d），关闭连接", fd);
            }
            // 真正的错误
            return -1;
        }
        if (n == 0) {
            // 不应该发生
            break;
        }
        totalWritten += (size_t)n;
    }
    return (ssize_t)totalWritten;
}

#pragma mark - PortForwarder 类扩展

@interface PortForwarder () {
    /// 监听 socket 文件描述符（-1 表示未创建）
    int _listenFD;

    /// Accept 线程
    NSThread *_acceptThread;

    /// 线程锁，保护内部状态
    NSLock *_lock;

    /// 是否正在停止（用于通知 accept 线程退出）
    BOOL _stopping;

    /// 关键修复（P1-8）：accept 线程代际计数器
    /// 每次 start 自增，acceptLoop 启动时捕获当前代际值，
    /// 循环中检查代际是否仍匹配。若不匹配（说明期间发生过 stop→start），
    /// 旧线程立即退出，避免与新一轮 start 启动的 accept 线程重复 accept 同一 listenFD。
    int _acceptGeneration;

    /// 活跃客户端 socket fd 集合（用于 stop 时 shutdown 唤醒阻塞的 read）
    /// 关键稳定性优化：stop 时如果不 shutdown 这些 fd，客户端线程会一直阻塞在
    /// read/recvData 上，导致线程泄漏。shutdown(SHUT_RDWR) 会立即唤醒它们。
    NSMutableArray<NSNumber *> *_activeClientFDs;

    /// 活跃 libzt 远程 socket fd 集合（用于 stop 时 shutdown 唤醒阻塞的 recvData）
    NSMutableArray<NSNumber *> *_activeRemoteFDs;
}

/// 实际监听端口
@property (nonatomic, assign, readwrite) uint16_t listeningPort;

/// 是否正在运行
@property (nonatomic, assign, readwrite, getter=isRunning) BOOL running;

/// 远程主机地址
@property (nonatomic, copy, readwrite, nullable) NSString *remoteHost;

/// 远程端口
@property (nonatomic, assign, readwrite) uint16_t remotePort;

/// 在 accept 线程中处理新连接
/// @param clientFD 客户端 socket 文件描述符
- (void)handleClient:(int)clientFD;

/// 双向转发数据
/// @param clientFD 客户端 socket（系统 POSIX socket）
/// @param remoteFD 远程 socket（libzt socket）
- (void)forwardDataBetweenClientFD:(int)clientFD
                          remoteFD:(int)remoteFD;

@end

#pragma mark - PortForwarder 实现

@implementation PortForwarder

#pragma mark - 单例模式

/// 获取共享的 PortForwarder 单例实例
/// 使用 dispatch_once 保证线程安全的单次初始化
+ (instancetype)sharedForwarder {
    static PortForwarder *shared = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        shared = [[self alloc] init];
    });
    return shared;
}

/// 重写 allocWithZone: 防止通过 alloc/init 创建第二个实例
+ (instancetype)allocWithZone:(struct _NSZone *)zone {
    static PortForwarder *shared = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        shared = [super allocWithZone:zone];
    });
    return shared;
}

/// 私有初始化方法
- (instancetype)init {
    self = [super init];
    if (self) {
        _listenFD = -1;
        _acceptThread = nil;
        _stopping = NO;
        _running = NO;
        _listeningPort = 0;
        _remoteHost = nil;
        _remotePort = 0;
        _lock = [[NSLock alloc] init];
        _activeClientFDs = [[NSMutableArray alloc] init];
        _activeRemoteFDs = [[NSMutableArray alloc] init];
        _acceptGeneration = 0;
        NSLog(@"[PortForwarder] 单例已初始化");
    }
    return self;
}

#pragma mark - 启动端口转发

/// 启动端口转发
///
/// 完整流程：
///   1. 参数校验
///   2. 检查是否已在运行
///   3. 检查 ZeroTier framework 是否可用
///   4. 创建监听 socket（尝试端口 localPort 到 localPort+9）
///   5. bind + listen
///   6. 启动 accept 线程
- (uint16_t)startWithLocalPort:(uint16_t)localPort
                    remoteHost:(NSString *)remoteHost
                    remotePort:(uint16_t)remotePort
                         error:(NSError **)error {
    // ============================================================
    // 步骤 1：参数校验
    // ============================================================
    if (!remoteHost || remoteHost.length == 0) {
        NSLog(@"[PortForwarder] start 失败：remoteHost 为空");
        if (error) {
            *error = [NSError errorWithDomain:kPortForwarderErrorDomain
                                          code:PortForwarderErrorCodeInvalidRemoteHost
                                      userInfo:@{NSLocalizedDescriptionKey: @"远程主机地址无效"}];
        }
        return 0;
    }
    
    if (remotePort == 0) {
        NSLog(@"[PortForwarder] start 失败：remotePort 为 0");
        if (error) {
            *error = [NSError errorWithDomain:kPortForwarderErrorDomain
                                          code:PortForwarderErrorCodeInvalidRemotePort
                                      userInfo:@{NSLocalizedDescriptionKey: @"远程端口无效"}];
        }
        return 0;
    }
    
    // ============================================================
    // 步骤 2：检查是否已在运行
    // ============================================================
    [_lock lock];
    if (_running) {
        [_lock unlock];
        NSLog(@"[PortForwarder] start 失败：转发器已在运行（端口 %u → %@:%u）",
              _listeningPort, _remoteHost, _remotePort);
        if (error) {
            *error = [NSError errorWithDomain:kPortForwarderErrorDomain
                                          code:PortForwarderErrorCodeAlreadyRunning
                                      userInfo:@{NSLocalizedDescriptionKey: @"端口转发器已在运行，请先停止"}];
        }
        return 0;
    }
    [_lock unlock];
    
    // ============================================================
    // 步骤 3：检查 ZeroTier framework 是否可用
    // ============================================================
    if (![[ZeroTierBridge sharedInstance] isFrameworkAvailable]) {
        NSLog(@"[PortForwarder] start 失败：ZeroTier framework 不可用");
        if (error) {
            *error = [NSError errorWithDomain:kPortForwarderErrorDomain
                                          code:PortForwarderErrorCodeFrameworkUnavailable
                                      userInfo:@{NSLocalizedDescriptionKey: @"ZeroTier framework 不可用，无法转发到远程主机"}];
        }
        return 0;
    }
    
    // ============================================================
    // 步骤 4：创建监听 socket（尝试端口 localPort 到 localPort+9）
    // ============================================================
    NSLog(@"[PortForwarder] 启动端口转发：本地 %u（或 +1~+9）→ %@:%u",
          localPort, remoteHost, remotePort);
    
    int listenFD = -1;
    uint16_t actualPort = 0;
    
    for (int retry = 0; retry < PORT_FORWARDER_MAX_PORT_RETRIES; retry++) {
        uint16_t tryPort = localPort + retry;
        
        // 创建 TCP socket
        listenFD = socket(AF_INET, SOCK_STREAM, 0);
        if (listenFD < 0) {
            NSLog(@"[PortForwarder] socket() 失败：errno=%d (%s)", errno, strerror(errno));
            continue;
        }
        
        // 设置 SO_REUSEADDR，避免端口处于 TIME_WAIT 状态时 bind 失败
        int reuseAddr = 1;
        setsockopt(listenFD, SOL_SOCKET, SO_REUSEADDR, &reuseAddr, sizeof(reuseAddr));
        
        // 绑定到 127.0.0.1:tryPort（仅本地回环，不对外暴露）
        struct sockaddr_in bindAddr;
        memset(&bindAddr, 0, sizeof(bindAddr));
        bindAddr.sin_family = AF_INET;
        bindAddr.sin_addr.s_addr = htonl(INADDR_LOOPBACK);  // 127.0.0.1
        bindAddr.sin_port = htons(tryPort);
        
        int bindResult = bind(listenFD, (struct sockaddr *)&bindAddr, sizeof(bindAddr));
        if (bindResult < 0) {
            NSLog(@"[PortForwarder] bind(%u) 失败：errno=%d (%s)，尝试下一个端口",
                  tryPort, errno, strerror(errno));
            close(listenFD);
            listenFD = -1;
            continue;
        }
        
        // bind 成功
        actualPort = tryPort;
        NSLog(@"[PortForwarder] bind 成功：端口 %u", actualPort);
        break;
    }
    
    // 如果所有端口都绑定失败，最后尝试 port=0（系统自动分配）
    if (listenFD < 0) {
        NSLog(@"[PortForwarder] 所有指定端口都绑定失败，尝试系统自动分配端口...");
        listenFD = socket(AF_INET, SOCK_STREAM, 0);
        if (listenFD < 0) {
            NSLog(@"[PortForwarder] socket() 失败：errno=%d (%s)", errno, strerror(errno));
            if (error) {
                *error = [NSError errorWithDomain:kPortForwarderErrorDomain
                                              code:PortForwarderErrorCodeSocketCreateFailed
                                          userInfo:@{NSLocalizedDescriptionKey: [NSString stringWithFormat:@"创建 socket 失败：%s", strerror(errno)]}];
            }
            return 0;
        }
        
        int reuseAddr = 1;
        setsockopt(listenFD, SOL_SOCKET, SO_REUSEADDR, &reuseAddr, sizeof(reuseAddr));
        
        struct sockaddr_in bindAddr;
        memset(&bindAddr, 0, sizeof(bindAddr));
        bindAddr.sin_family = AF_INET;
        bindAddr.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
        bindAddr.sin_port = htons(0);  // 系统自动分配端口
        
        int bindResult = bind(listenFD, (struct sockaddr *)&bindAddr, sizeof(bindAddr));
        if (bindResult < 0) {
            NSLog(@"[PortForwarder] bind(0) 失败：errno=%d (%s)", errno, strerror(errno));
            close(listenFD);
            if (error) {
                *error = [NSError errorWithDomain:kPortForwarderErrorDomain
                                              code:PortForwarderErrorCodeBindFailed
                                          userInfo:@{NSLocalizedDescriptionKey: [NSString stringWithFormat:@"绑定端口失败：%s", strerror(errno)]}];
            }
            return 0;
        }
        
        // 获取系统分配的实际端口
        struct sockaddr_in actualAddr;
        socklen_t addrLen = sizeof(actualAddr);
        if (getsockname(listenFD, (struct sockaddr *)&actualAddr, &addrLen) == 0) {
            actualPort = ntohs(actualAddr.sin_port);
        }
        NSLog(@"[PortForwarder] 系统自动分配端口：%u", actualPort);
    }
    
    // ============================================================
    // 步骤 5：listen
    // ============================================================
    int listenResult = listen(listenFD, PORT_FORWARDER_BACKLOG);
    if (listenResult < 0) {
        NSLog(@"[PortForwarder] listen() 失败：errno=%d (%s)", errno, strerror(errno));
        close(listenFD);
        if (error) {
            *error = [NSError errorWithDomain:kPortForwarderErrorDomain
                                          code:PortForwarderErrorCodeListenFailed
                                          userInfo:@{NSLocalizedDescriptionKey: [NSString stringWithFormat:@"监听失败：%s", strerror(errno)]}];
        }
        return 0;
    }
    
    // ============================================================
    // 步骤 6：更新状态并启动 accept 线程
    // ============================================================
    [_lock lock];
    _listenFD = listenFD;
    _listeningPort = actualPort;
    _remoteHost = [remoteHost copy];
    _remotePort = remotePort;
    _running = YES;
    _stopping = NO;
    // 关键修复（P1-8）：代际自增，标识本次 start 周期
    // 用于解决快速 stop→start 时旧 accept 线程未及时退出、与新 accept 线程
    // 同时 accept 同一 listenFD（fd 数字可能被复用）导致重复 accept 的问题
    _acceptGeneration++;
    int myGen = _acceptGeneration;
    [_lock unlock];

    // 启动 accept 线程，传入当前代际值
    __weak typeof(self) weakSelf = self;
    _acceptThread = [[NSThread alloc] initWithBlock:^{
        [weakSelf acceptLoopWithGeneration:myGen];
    }];
    _acceptThread.name = @"PortForwarder-Accept";
    [_acceptThread start];
    
    NSLog(@"[PortForwarder] 端口转发已启动：127.0.0.1:%u → %@:%u",
          actualPort, remoteHost, remotePort);
    
    return actualPort;
}

#pragma mark - Accept 线程

/// Accept 线程主循环
///
/// 使用 select 检测监听 socket 是否可读（有新连接），
/// 这样可以在 stop 时通过关闭监听 socket 来唤醒 select，优雅退出。
///
/// 关键修复（P1-8）：接受代际参数。
/// 当快速 stop→start 时，旧 accept 线程可能未及时退出。由于 fd 数字可能被
/// 系统复用（旧 listenFD 关闭后，新 socket 可能拿到相同数字），旧线程会
/// 错误地接受新 listenFD 上的连接，造成重复 accept 与状态混乱。
/// 通过代际计数器识别旧线程并使其主动退出。
- (void)acceptLoopWithGeneration:(int)myGen {
    NSLog(@"[PortForwarder] Accept 线程已启动（代际=%d）", myGen);

    while (YES) {
        @autoreleasepool {
            [_lock lock];
            int listenFD = _listenFD;
            BOOL stopping = _stopping;
            int currentGen = _acceptGeneration;
            [_lock unlock];

            // 关键修复（P1-8）：代际不匹配说明期间发生过 stop→start，
            // 当前 accept 线程属于上一周期，应立即退出，把 listenFD 让给新线程
            if (currentGen != myGen) {
                NSLog(@"[PortForwarder] Accept 线程：代际不匹配（my=%d, current=%d），退出循环",
                      myGen, currentGen);
                break;
            }

            if (stopping || listenFD < 0) {
                NSLog(@"[PortForwarder] Accept 线程：收到停止信号，退出循环");
                break;
            }
            
            // 使用 select 等待监听 socket 可读（有新连接）
            // select 超时设为 1 秒，定期检查 _stopping 标志
            fd_set readSet;
            FD_ZERO(&readSet);
            FD_SET(listenFD, &readSet);
            
            struct timeval timeout;
            timeout.tv_sec = 1;
            timeout.tv_usec = 0;
            
            int selectResult = select(listenFD + 1, &readSet, NULL, NULL, &timeout);
            if (selectResult < 0) {
                if (errno == EINTR) {
                    // 被信号中断，重试
                    continue;
                }
                NSLog(@"[PortForwarder] select() 失败：errno=%d (%s)", errno, strerror(errno));
                break;
            }
            
            if (selectResult == 0) {
                // 超时，没有新连接，继续循环
                continue;
            }
            
            // 有新连接
            if (FD_ISSET(listenFD, &readSet)) {
                struct sockaddr_in clientAddr;
                socklen_t clientAddrLen = sizeof(clientAddr);
                int clientFD = accept(listenFD, (struct sockaddr *)&clientAddr, &clientAddrLen);
                
                if (clientFD < 0) {
                    if (errno == EINTR || errno == EAGAIN || errno == EWOULDBLOCK) {
                        continue;
                    }
                    NSLog(@"[PortForwarder] accept() 失败：errno=%d (%s)", errno, strerror(errno));
                    
                    // 如果是 EBADF，说明监听 socket 已被关闭（stop 被调用）
                    if (errno == EBADF) {
                        break;
                    }
                    continue;
                }
                
                // 获取客户端 IP 和端口（用于日志）
                char clientIP[INET_ADDRSTRLEN] = {0};
                inet_ntop(AF_INET, &clientAddr.sin_addr, clientIP, sizeof(clientIP));
                uint16_t clientPort = ntohs(clientAddr.sin_port);
                NSLog(@"[PortForwarder] 新客户端连接：%s:%u (fd=%d)", clientIP, clientPort, clientFD);
                
                // 在新线程中处理客户端连接
                __weak typeof(self) weakSelf = self;
                NSThread *clientThread = [[NSThread alloc] initWithBlock:^{
                    [weakSelf handleClient:clientFD];
                }];
                clientThread.name = [NSString stringWithFormat:@"PortForwarder-Client-%d", clientFD];
                [clientThread start];
            }
        }
    }
    
    NSLog(@"[PortForwarder] Accept 线程已退出");
}

#pragma mark - 客户端处理

/// 处理客户端连接
///
/// 流程：
///   1. 通过 ZeroTierBridge 创建 libzt socket
///   2. 连接到远程主机 remoteHost:remotePort
///   3. 双向转发数据
///   4. 关闭连接
- (void)handleClient:(int)clientFD {
    @autoreleasepool {
        [_lock lock];
        NSString *remoteHost = [_remoteHost copy];
        uint16_t remotePort = _remotePort;
        [_lock unlock];
        
        if (!remoteHost.length) {
            NSLog(@"[PortForwarder] handleClient：remoteHost 为空，关闭客户端连接");
            close(clientFD);
            return;
        }
        
        NSLog(@"[PortForwarder] 处理客户端连接 fd=%d，转发到 %@:%u", clientFD, remoteHost, remotePort);

        // 对客户端 socket 设置 TCP_NODELAY（禁用 Nagle 算法）
        //
        // 关键性能优化：Minecraft 是实时交互游戏，玩家操作需要立即发送到服务器。
        // Nagle 算法会将小数据包合并发送以减少网络开销，但会增加延迟。
        // 对于 MC 这种实时游戏，延迟比带宽更重要，因此必须禁用 Nagle。
        int clientNoDelay = 1;
        setsockopt(clientFD, IPPROTO_TCP, TCP_NODELAY, &clientNoDelay, sizeof(clientNoDelay));

        // 对客户端 socket 设置 SO_KEEPALIVE（连接保活）
        //
        // 关键稳定性优化：MC 的 TCP 连接可能长时间无数据传输（如玩家挂机），
        // 中间的 NAT/防火墙可能会因超时而丢弃连接表项，导致连接"假死"。
        // SO_KEEPALIVE 让系统定期发送 keepalive 探测包，保持连接活跃。
        int clientKeepAlive = 1;
        setsockopt(clientFD, SOL_SOCKET, SO_KEEPALIVE, &clientKeepAlive, sizeof(clientKeepAlive));

        // 关键修复（P1-4）：客户端 socket 设置 SO_SNDTIMEO / SO_RCVTIMEO / SO_NOSIGPIPE
        //
        // 问题：原 writeAll 仅处理 EINTR 重试，无超时。当 MC 客户端接收缓冲区满
        // （主线程卡顿、大区块加载）时，write 会无限阻塞，导致转发线程泄漏。
        // 即使 stop() 调用 shutdown(clientFD, SHUT_RDWR)，由于线程卡在 write 而非 read，
        // shutdown 不一定能立即唤醒已阻塞的 write（取决于内核实现）。
        //
        // 修复：设置 30 秒发送/接收超时 + SO_NOSIGPIPE 防止 SIGPIPE 崩溃。
        // 超时后 writeAll 会返回 EAGAIN/EWOULDBLOCK，转发循环可主动退出。
        struct timeval ioTimeout;
        ioTimeout.tv_sec = 30;
        ioTimeout.tv_usec = 0;
        setsockopt(clientFD, SOL_SOCKET, SO_SNDTIMEO, &ioTimeout, sizeof(ioTimeout));
        setsockopt(clientFD, SOL_SOCKET, SO_RCVTIMEO, &ioTimeout, sizeof(ioTimeout));
        int clientNoSigPipe = 1;
        setsockopt(clientFD, SOL_SOCKET, SO_NOSIGPIPE, &clientNoSigPipe, sizeof(clientNoSigPipe));

        // 关键修复（P2-11）：iOS 默认 keepalive 间隔 ~2 小时，无法及时检测半死连接。
        // 改为更激进的参数：空闲 30s 开始探测，每 10s 探测一次，3 次失败判定死亡。
        // TCP_KEEPALIVE 是 iOS 上 keep-alive 间隔的对应选项（macOS 用 TCP_KEEPALIVE，
        // Linux 用 TCP_KEEPIDLE，这里只编译 iOS，用 TCP_KEEPALIVE）。
        int keepIdle = 30;
        setsockopt(clientFD, IPPROTO_TCP, TCP_KEEPALIVE, &keepIdle, sizeof(keepIdle));
        int keepIntvl = 10;
        setsockopt(clientFD, IPPROTO_TCP, TCP_KEEPINTVL, &keepIntvl, sizeof(keepIntvl));
        int keepCnt = 3;
        setsockopt(clientFD, IPPROTO_TCP, TCP_KEEPCNT, &keepCnt, sizeof(keepCnt));

        // ============================================================
        // 步骤 1：创建 libzt socket
        // ============================================================
        // 使用 inet_pton 严格校验地址类型，避免误判
        BOOL isIPv6Target = (zts_inet_pton(ZTS_AF_INET6, [remoteHost UTF8String], NULL) == 1);
        int socketFamily = isIPv6Target ? ZTS_AF_INET6 : ZTS_AF_INET;

        int ztFD = [[ZeroTierBridge sharedInstance] createTCPSocketForFamily:socketFamily];
        if (ztFD < 0) {
            NSLog(@"[PortForwarder] 创建 ZeroTier socket(family=%d) 失败：ztFD=%d", socketFamily, ztFD);
            close(clientFD);
            return;
        }

        // 对 libzt socket 也设置 TCP_NODELAY（降低 ZeroTier 虚拟网络的延迟）
        int ztNoDelay = 1;
        zts_bsd_setsockopt(ztFD, ZTS_IPPROTO_TCP, ZTS_TCP_NODELAY, &ztNoDelay, sizeof(ztNoDelay));

        // ============================================================
        // 步骤 2：连接到远程主机
        // ============================================================
        int connectResult = [[ZeroTierBridge sharedInstance] connectSocket:ztFD
                                                                    toHost:remoteHost
                                                                      port:remotePort
                                                                   timeout:PORT_FORWARDER_CONNECT_TIMEOUT];
        if (connectResult != 0) {
            NSLog(@"[PortForwarder] 通过 ZeroTier 连接目标失败：result=%d, target=%@:%u",
                  connectResult, remoteHost, remotePort);
            [[ZeroTierBridge sharedInstance] closeSocket:ztFD];
            close(clientFD);
            return;
        }

        NSLog(@"[PortForwarder] 通过 ZeroTier 连接目标成功：target=%@:%u, ztFD=%d",
              remoteHost, remotePort, ztFD);

        // 将 fd 加入活跃列表（用于 stop 时 shutdown 唤醒阻塞的 read/recv）
        // 关键修复（P1-7）：connect 期间 stop 可能已被调用，stop 复制活跃列表时
        // 此连接尚未加入，导致 fd 漏网，stop 后仍继续转发，且永不清理。
        // 修复：加入活跃列表前检查 _running，若已停止则立即关闭 fd 并返回。
        [_lock lock];
        BOOL stillRunning = _running;
        if (stillRunning) {
            [_activeClientFDs addObject:@(clientFD)];
            [_activeRemoteFDs addObject:@(ztFD)];
        }
        [_lock unlock];

        if (!stillRunning) {
            NSLog(@"[PortForwarder] handleClient：转发器已停止，关闭新连接 clientFD=%d ztFD=%d",
                  clientFD, ztFD);
            [[ZeroTierBridge sharedInstance] closeSocket:ztFD];
            close(clientFD);
            return;
        }

        // ============================================================
        // 步骤 3：双向转发数据
        // ============================================================
        [self forwardDataBetweenClientFD:clientFD remoteFD:ztFD];

        // 从活跃列表中移除（转发已结束，fd 即将被关闭）
        [_lock lock];
        [_activeClientFDs removeObject:@(clientFD)];
        [_activeRemoteFDs removeObject:@(ztFD)];
        [_lock unlock];

        // ============================================================
        // 步骤 4：关闭连接
        // ============================================================
        NSLog(@"[PortForwarder] 转发结束，关闭连接：clientFD=%d, ztFD=%d", clientFD, ztFD);
        [[ZeroTierBridge sharedInstance] closeSocket:ztFD];
        close(clientFD);
    }
}

#pragma mark - 双向数据转发

/// 双向转发数据
///
/// 在客户端 socket（系统 POSIX）和远程 socket（libzt）之间双向转发数据。
/// 使用 GCD 并发队列，两个方向同时转发。
/// 使用 atomic_bool 标志确保跨线程内存可见性。
///
/// @param clientFD 客户端 socket（系统 POSIX socket）
/// @param remoteFD 远程 socket（libzt socket）
- (void)forwardDataBetweenClientFD:(int)clientFD
                          remoteFD:(int)remoteFD {
    // 使用 atomic_bool 替代 __block BOOL，确保跨线程内存可见性
    // （参考 SOCKS5Proxy 的实现，ARM64 弱内存模型需要原子操作提供内存屏障）
    // 关键修复：使用 atomic_bool 替代 atomic_bool，确保跨平台兼容性
    // atomic_bool 在 Objective-C 中可能不被支持（BOOL 是 signed char 的 typedef）
    __block atomic_bool clientClosed = ATOMIC_VAR_INIT(false);
    __block atomic_bool remoteClosed = ATOMIC_VAR_INIT(false);
    
    // 创建并发队列用于双向转发
    dispatch_queue_t forwardQueue = dispatch_queue_create("com.angelaura.portforwarder.forward", DISPATCH_QUEUE_CONCURRENT);
    dispatch_group_t group = dispatch_group_create();
    
    // ============================================================
    // 方向 1：client → remote
    // 从客户端（POSIX socket）读取数据，通过 ZeroTier（libzt socket）发送
    // ============================================================
    dispatch_group_async(group, forwardQueue, ^{
        uint8_t buffer[PORT_FORWARDER_BUFFER_SIZE];
        
        while (YES) {
            @autoreleasepool {
                // 检查远程是否已关闭（原子读，自带内存屏障）
                if (atomic_load(&remoteClosed)) {
                    NSLog(@"[PortForwarder] client→remote：远程已关闭，退出转发");
                    break;
                }
                
                // 从客户端读取数据（系统 read）
                ssize_t n = read(clientFD, buffer, sizeof(buffer));
                if (n <= 0) {
                    // n == 0：客户端关闭连接
                    // n < 0：读取错误
                    NSLog(@"[PortForwarder] client→remote 结束：n=%zd, errno=%d", n, errno);
                    
                    // 标记客户端已关闭（原子写，自带内存屏障）
                    atomic_store(&clientClosed, true);
                    
                    // 关闭远程的写端，通知 remote→client 方向退出
                    // shutdown 会导致另一端的 recv 返回 0
                    [[ZeroTierBridge sharedInstance] shutdownSocket:remoteFD how:SHUT_WR];
                    break;
                }
                
                // 通过 ZeroTier 发送数据（libzt send）
                ssize_t sent = [[ZeroTierBridge sharedInstance] sendData:remoteFD
                                                                  buffer:buffer
                                                                  length:(size_t)n];
                if (sent <= 0) {
                    NSLog(@"[PortForwarder] 发送到远程失败：sent=%zd", sent);
                    
                    // 标记远程已关闭（原子写）
                    atomic_store(&remoteClosed, true);
                    
                    // 关闭客户端的写端
                    shutdown(clientFD, SHUT_WR);
                    break;
                }
            }
        }
    });
    
    // ============================================================
    // 方向 2：remote → client
    // 从 ZeroTier（libzt socket）接收数据，发送给客户端（POSIX socket）
    // ============================================================
    dispatch_group_async(group, forwardQueue, ^{
        uint8_t buffer[PORT_FORWARDER_BUFFER_SIZE];
        
        while (YES) {
            @autoreleasepool {
                // 检查客户端是否已关闭（原子读，自带内存屏障）
                if (atomic_load(&clientClosed)) {
                    NSLog(@"[PortForwarder] remote→client：客户端已关闭，退出转发");
                    break;
                }
                
                // 通过 ZeroTier 接收数据（libzt recv）
                ssize_t n = [[ZeroTierBridge sharedInstance] recvData:remoteFD
                                                                buffer:buffer
                                                                length:sizeof(buffer)];
                if (n <= 0) {
                    // n == 0：远程关闭连接
                    // n < 0：接收错误
                    NSLog(@"[PortForwarder] remote→client 结束：n=%zd", n);
                    
                    // 标记远程已关闭（原子写）
                    atomic_store(&remoteClosed, true);
                    
                    // 关闭客户端的写端，通知 client→remote 方向退出
                    shutdown(clientFD, SHUT_WR);
                    break;
                }
                
                // 发送数据给客户端（系统 write）
                ssize_t sent = writeAll(clientFD, buffer, (size_t)n);
                if (sent <= 0) {
                    NSLog(@"[PortForwarder] 发送到客户端失败：sent=%zd", sent);
                    
                    // 标记客户端已关闭（原子写）
                    atomic_store(&clientClosed, true);
                    
                    // 关闭远程的写端
                    [[ZeroTierBridge sharedInstance] shutdownSocket:remoteFD how:SHUT_WR];
                    break;
                }
            }
        }
    });
    
    // 等待两个方向的转发都结束
    dispatch_group_wait(group, DISPATCH_TIME_FOREVER);
    
    NSLog(@"[PortForwarder] 双向转发已结束：clientFD=%d, remoteFD=%d", clientFD, remoteFD);
}

#pragma mark - 停止端口转发

/// 停止端口转发
///
/// 流程：
///   1. 设置停止标志
///   2. 关闭监听 socket（唤醒 accept 线程的 select）
///   3. shutdown 所有活跃的客户端/远程 fd（唤醒阻塞的 read/recv）
///   4. 异步等待客户端线程退出（主线程不阻塞）
///   5. 清理状态
///
/// 关键稳定性优化：shutdown 活跃连接
///   如果不 shutdown，正在 forwardDataBetweenClientFD: 中阻塞的 read/recvData
///   不会返回，客户端线程会一直存在（线程泄漏）。shutdown(SHUT_RDWR) 会立即
///   唤醒所有阻塞在该 fd 上的 read/write，让客户端线程正常退出。
- (void)stop {
    BOOL isMainThread = [NSThread isMainThread];

    [_lock lock];
    if (!_running) {
        [_lock unlock];
        NSLog(@"[PortForwarder] stop：转发器未在运行，跳过");
        return;
    }

    NSLog(@"[PortForwarder] 停止端口转发（端口 %u → %@:%u，isMainThread=%d）",
          _listeningPort, _remoteHost, _remotePort, isMainThread);

    _stopping = YES;
    _running = NO;
    int listenFD = _listenFD;
    _listenFD = -1;
    NSThread *acceptThread = _acceptThread;

    // 复制活跃 fd 列表（不阻塞太久）
    NSArray<NSNumber *> *clientFDs = [_activeClientFDs copy];
    NSArray<NSNumber *> *remoteFDs = [_activeRemoteFDs copy];
    [_activeClientFDs removeAllObjects];
    [_activeRemoteFDs removeAllObjects];
    [_lock unlock];

    // 1. 关闭监听 socket，唤醒 accept 线程的 select
    if (listenFD >= 0) {
        close(listenFD);
    }

    // 2. shutdown 所有活跃的客户端/远程 fd（唤醒阻塞的 read/recv）
    NSLog(@"[PortForwarder] shutdown %lu 个客户端连接和 %lu 个远程连接...",
          (unsigned long)clientFDs.count, (unsigned long)remoteFDs.count);

    for (NSNumber *fdNum in clientFDs) {
        int fd = [fdNum intValue];
        if (fd >= 0) {
            shutdown(fd, SHUT_RDWR);
        }
    }

    for (NSNumber *fdNum in remoteFDs) {
        int fd = [fdNum intValue];
        if (fd >= 0) {
            [[ZeroTierBridge sharedInstance] shutdownSocket:fd how:SHUT_RDWR];
        }
    }

    // 3. 清理状态（主线程立即返回，客户端线程在后台自行退出）
    [_lock lock];
    _acceptThread = nil;
    _listeningPort = 0;
    _remoteHost = nil;
    _remotePort = 0;
    _stopping = NO;
    [_lock unlock];

    NSLog(@"[PortForwarder] 端口转发已停止");
}

@end