//
//  SOCKS5Proxy.m
//  Angel Aura Amethyst
//
//  本地 SOCKS5 代理服务器实现
//
//  ============================================================================
//  实现说明
//  ============================================================================
//
//  本文件实现 SOCKS5Proxy.h 中定义的本地 SOCKS5 代理服务器。
//
//  关键实现点：
//    1. 监听 socket 使用系统 POSIX socket（socket/bind/listen/accept）
//    2. 客户端连接后，在新线程中处理 SOCKS5 握手和数据转发
//    3. SOCKS5 协议实现遵循 RFC 1928，支持无认证方式和 CONNECT 命令
//    4. 目标地址支持 IPv4、IPv6 和域名三种类型
//    5. 远程连接通过 ZeroTierBridge 的 libzt socket API 建立
//    6. 双向转发使用 GCD 并发队列，两个方向同时转发
//    7. 所有在 block 内赋值的局部变量使用 __block 修饰符
//
//  线程模型：
//    - 主线程：startWithPort:error: / stop
//    - Accept 线程：NSThread，循环 accept 新连接
//    - 客户端处理线程：NSThread，每个客户端一个
//    - 转发任务：GCD 并发队列，每个连接两个任务（client→remote、remote→client）
//
//  SOCKS5 协议常量（RFC 1928）：
//    VER = 0x05（SOCKS 版本 5）
//    METHOD_NO_AUTH = 0x00（无认证）
//    METHOD_NO_ACCEPTABLE = 0xFF（无可接受的认证方法）
//    CMD_CONNECT = 0x01（CONNECT 命令）
//    ATYP_IPV4 = 0x01（IPv4 地址）
//    ATYP_DOMAIN = 0x03（域名）
//    ATYP_IPV6 = 0x04（IPv6 地址）
//
//  ============================================================================

#import "SOCKS5Proxy.h"
#import "ZeroTierBridge.h"
#import "utils.h"

// POSIX socket 头文件
#include <sys/socket.h>
#include <netinet/in.h>
#include <arpa/inet.h>
#include <unistd.h>
#include <string.h>
#include <errno.h>

#pragma mark - 常量定义

/// SOCKS5 代理默认监听端口
const uint16_t SOCKS5ProxyDefaultPort = 1080;

/// 客户端连接通知名
NSNotificationName const SOCKS5ProxyClientConnectedNotification = @"SOCKS5ProxyClientConnectedNotification";

/// 客户端断开通知名
NSNotificationName const SOCKS5ProxyClientDisconnectedNotification = @"SOCKS5ProxyClientDisconnectedNotification";

/// 错误域名
static NSString * const kSOCKS5ProxyErrorDomain = @"SOCKS5ProxyErrorDomain";

/// 错误码
typedef NS_ENUM(NSInteger, SOCKS5ProxyErrorCode) {
    SOCKS5ProxyErrorCodeAlreadyRunning        = 1, // 代理已在运行
    SOCKS5ProxyErrorCodeSocketCreateFailed    = 2, // 创建 socket 失败
    SOCKS5ProxyErrorCodeBindFailed            = 3, // 绑定端口失败
    SOCKS5ProxyErrorCodeListenFailed          = 4, // 监听失败
    SOCKS5ProxyErrorCodeFrameworkUnavailable  = 5, // ZeroTier framework 不可用
};

/// SOCKS5 协议常量（RFC 1928）
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

/// SOCKS5 回复码（RFC 1928 第 6 节）
#define SOCKS5_REP_SUCCESS                    0x00
#define SOCKS5_REP_GENERAL_FAILURE            0x01
#define SOCKS5_REP_NOT_ALLOWED                0x02
#define SOCKS5_REP_NETWORK_UNREACHABLE        0x03
#define SOCKS5_REP_HOST_UNREACHABLE           0x04
#define SOCKS5_REP_CONNECTION_REFUSED         0x05
#define SOCKS5_REP_TTL_EXPIRED                0x06
#define SOCKS5_REP_COMMAND_NOT_SUPPORTED      0x07
#define SOCKS5_REP_ADDRESS_TYPE_NOT_SUPPORTED 0x08

/// 数据转发缓冲区大小（64KB）
#define SOCKS5_BUFFER_SIZE 65536

/// 连接远程主机的超时时间（秒）
#define SOCKS5_CONNECT_TIMEOUT 30.0

#pragma mark - 辅助函数

/// 完整读取指定长度的数据
///
/// read() 系统调用可能不会一次性返回所有请求的字节，需要循环读取。
/// 本函数会阻塞直到读取到指定长度或连接关闭。
///
/// @param fd socket 文件描述符
/// @param buf 接收缓冲区
/// @param len 需要读取的长度
/// @return 实际读取的字节数（< len 表示连接已关闭或出错）
static ssize_t readAll(int fd, void *buf, size_t len) {
    size_t totalRead = 0;
    uint8_t *p = (uint8_t *)buf;

    while (totalRead < len) {
        ssize_t n = read(fd, p + totalRead, len - totalRead);
        if (n < 0) {
            // 被信号中断，重试
            if (errno == EINTR) {
                continue;
            }
            // 其他错误
            NSLog(@"[SOCKS5Proxy] readAll 错误：errno = %d, fd = %d", errno, fd);
            return -1;
        }
        if (n == 0) {
            // 连接已关闭
            return (ssize_t)totalRead;
        }
        totalRead += (size_t)n;
    }

    return (ssize_t)totalRead;
}

/// 完整写入指定长度的数据
///
/// write() 系统调用可能不会一次性写入所有字节，需要循环写入。
///
/// @param fd socket 文件描述符
/// @param buf 写入缓冲区
/// @param len 需要写入的长度
/// @return 实际写入的字节数（< len 表示出错）
static ssize_t writeAll(int fd, const void *buf, size_t len) {
    size_t totalWritten = 0;
    const uint8_t *p = (const uint8_t *)buf;

    while (totalWritten < len) {
        ssize_t n = write(fd, p + totalWritten, len - totalWritten);
        if (n < 0) {
            if (errno == EINTR) {
                continue;
            }
            NSLog(@"[SOCKS5Proxy] writeAll 错误：errno = %d, fd = %d", errno, fd);
            return -1;
        }
        if (n == 0) {
            return (ssize_t)totalWritten;
        }
        totalWritten += (size_t)n;
    }

    return (ssize_t)totalWritten;
}

#pragma mark - SOCKS5Proxy 类扩展

@interface SOCKS5Proxy () {
    /// 监听 socket 文件描述符（受 _lock 保护）
    int _listenFD;

    /// 实际监听端口（受 _lock 保护）
    uint16_t _listeningPort;

    /// 是否正在运行（受 _lock 保护）
    BOOL _running;

    /// Accept 线程（接受新客户端连接）
    NSThread *_acceptThread;

    /// 线程锁，保护所有内部状态变量
    NSLock *_lock;

    /// 活跃的客户端处理线程列表（受 _lock 保护）
    NSMutableArray<NSThread *> *_clientThreads;
}
@end

#pragma mark - SOCKS5Proxy 实现

@implementation SOCKS5Proxy

#pragma mark - 单例模式

/// 获取共享的 SOCKS5Proxy 单例实例
/// 使用 dispatch_once 保证线程安全的单次初始化
+ (instancetype)sharedProxy {
    static SOCKS5Proxy *shared = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        shared = [[self alloc] init];
    });
    return shared;
}

/// 重写 allocWithZone: 防止通过 alloc/init 创建第二个实例
+ (instancetype)allocWithZone:(struct _NSZone *)zone {
    static SOCKS5Proxy *shared = nil;
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
        _listeningPort = 0;
        _running = NO;
        _acceptThread = nil;
        _lock = [[NSLock alloc] init];
        _clientThreads = [[NSMutableArray alloc] init];

        NSLog(@"[SOCKS5Proxy] 单例已初始化");
    }
    return self;
}

#pragma mark - 启动与停止

/// 启动代理服务器
///
/// 流程：
///   1. 检查是否已运行
///   2. 检查 ZeroTier framework 可用性
///   3. 创建 POSIX socket
///   4. 设置 SO_REUSEADDR
///   5. 绑定到 127.0.0.1:port
///   6. 获取实际绑定端口
///   7. 开始监听
///   8. 启动 Accept 线程
- (BOOL)startWithPort:(uint16_t)port
                error:(NSError **)error {
    // 检查是否已运行
    [_lock lock];
    if (_running) {
        [_lock unlock];
        NSLog(@"[SOCKS5Proxy] 代理已在运行，端口 = %u", _listeningPort);
        if (error) {
            *error = [NSError errorWithDomain:kSOCKS5ProxyErrorDomain
                                          code:SOCKS5ProxyErrorCodeAlreadyRunning
                                      userInfo:@{NSLocalizedDescriptionKey: @"SOCKS5 代理已在运行"}];
        }
        return NO;
    }
    [_lock unlock];

    // 检查 ZeroTier framework 是否可用
    // 如果 framework 不可用，代理无法连接到 ZeroTier 网络，启动没有意义
    if (![[ZeroTierBridge sharedInstance] isFrameworkAvailable]) {
        NSLog(@"[SOCKS5Proxy] 启动失败：ZeroTier framework 不可用");
        if (error) {
            *error = [NSError errorWithDomain:kSOCKS5ProxyErrorDomain
                                          code:SOCKS5ProxyErrorCodeFrameworkUnavailable
                                      userInfo:@{NSLocalizedDescriptionKey: @"ZeroTier framework 不可用，无法启动 SOCKS5 代理"}];
        }
        return NO;
    }

    NSLog(@"[SOCKS5Proxy] 启动代理服务器，请求端口 = %u", port);

    // 步骤 1：创建监听 socket（系统 POSIX socket，不是 libzt socket）
    int fd = socket(AF_INET, SOCK_STREAM, 0);
    if (fd < 0) {
        NSLog(@"[SOCKS5Proxy] 创建 socket 失败：errno = %d", errno);
        if (error) {
            *error = [NSError errorWithDomain:kSOCKS5ProxyErrorDomain
                                          code:SOCKS5ProxyErrorCodeSocketCreateFailed
                                      userInfo:@{NSLocalizedDescriptionKey: [NSString stringWithFormat:@"创建 socket 失败 (errno=%d)", errno]}];
        }
        return NO;
    }

    // 步骤 2：设置 SO_REUSEADDR，允许端口重用
    // 避免"Address already in use"错误（前一次运行的 socket 处于 TIME_WAIT 状态）
    int opt = 1;
    if (setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &opt, sizeof(opt)) < 0) {
        NSLog(@"[SOCKS5Proxy] 设置 SO_REUSEADDR 失败：errno = %d（忽略，继续）", errno);
    }

    // 步骤 3：绑定到 127.0.0.1:port
    // 只监听本地回环地址，避免暴露到外部网络
    struct sockaddr_in addr;
    memset(&addr, 0, sizeof(addr));
    addr.sin_family = AF_INET;
    addr.sin_port = htons(port);
    addr.sin_addr.s_addr = inet_addr("127.0.0.1");

    if (bind(fd, (struct sockaddr *)&addr, sizeof(addr)) < 0) {
        NSLog(@"[SOCKS5Proxy] bind 失败：errno = %d, port = %u", errno, port);
        close(fd);
        if (error) {
            *error = [NSError errorWithDomain:kSOCKS5ProxyErrorDomain
                                          code:SOCKS5ProxyErrorCodeBindFailed
                                      userInfo:@{NSLocalizedDescriptionKey: [NSString stringWithFormat:@"绑定端口 %u 失败 (errno=%d)", port, errno]}];
        }
        return NO;
    }

    // 步骤 4：获取实际绑定的端口
    // 如果 port=0，系统会自动分配一个可用端口，需要通过 getsockname 查询
    socklen_t addrLen = sizeof(addr);
    if (getsockname(fd, (struct sockaddr *)&addr, &addrLen) < 0) {
        NSLog(@"[SOCKS5Proxy] getsockname 失败：errno = %d", errno);
        close(fd);
        if (error) {
            *error = [NSError errorWithDomain:kSOCKS5ProxyErrorDomain
                                          code:SOCKS5ProxyErrorCodeSocketCreateFailed
                                      userInfo:@{NSLocalizedDescriptionKey: @"获取实际监听端口失败"}];
        }
        return NO;
    }
    uint16_t actualPort = ntohs(addr.sin_port);

    // 步骤 5：开始监听
    // backlog = 16，允许最多 16 个等待接受的连接
    if (listen(fd, 16) < 0) {
        NSLog(@"[SOCKS5Proxy] listen 失败：errno = %d", errno);
        close(fd);
        if (error) {
            *error = [NSError errorWithDomain:kSOCKS5ProxyErrorDomain
                                          code:SOCKS5ProxyErrorCodeListenFailed
                                      userInfo:@{NSLocalizedDescriptionKey: [NSString stringWithFormat:@"监听失败 (errno=%d)", errno]}];
        }
        return NO;
    }

    // 更新内部状态
    [_lock lock];
    _listenFD = fd;
    _listeningPort = actualPort;
    _running = YES;
    [_lock unlock];

    NSLog(@"[SOCKS5Proxy] 代理服务器已启动，监听 127.0.0.1:%u", actualPort);

    // 步骤 6：启动 Accept 线程
    __weak typeof(self) weakSelf = self;
    _acceptThread = [[NSThread alloc] initWithBlock:^{
        [weakSelf acceptLoop];
    }];
    [_acceptThread setName:@"SOCKS5Proxy-Accept"];
    [_acceptThread start];

    return YES;
}

/// 停止代理服务器
///
/// 关闭监听 socket，停止接受新连接。
/// 已建立的客户端连接会继续处理直到完成。
- (void)stop {
    [_lock lock];
    if (!_running) {
        [_lock unlock];
        NSLog(@"[SOCKS5Proxy] 代理未运行，无需停止");
        return;
    }

    NSLog(@"[SOCKS5Proxy] 停止代理服务器...");
    _running = NO;

    // 关闭监听 socket，这会导致 accept() 返回错误，accept 线程退出
    if (_listenFD >= 0) {
        close(_listenFD);
        _listenFD = -1;
    }

    // 保存当前端口用于日志，然后清除
    uint16_t savedPort = _listeningPort;
    _listeningPort = 0;

    // 复制客户端线程列表（不阻塞太久）
    NSArray<NSThread *> *threads = [_clientThreads copy];
    [_clientThreads removeAllObjects];
    [_lock unlock];

    NSLog(@"[SOCKS5Proxy] 监听已关闭（端口 %u），等待 %lu 个客户端线程完成...",
          savedPort, (unsigned long)threads.count);

    // 注意：不强制终止客户端线程，让它们自然完成
    // 客户端线程会在数据转发完成后自动退出
}

/// 代理服务器是否正在运行
/// @return YES 如果正在运行
- (BOOL)isRunning {
    [_lock lock];
    BOOL running = _running;
    [_lock unlock];
    return running;
}

/// 当前监听端口
/// @return 监听端口（未运行时返回 0）
- (uint16_t)listeningPort {
    [_lock lock];
    uint16_t port = _listeningPort;
    [_lock unlock];
    return port;
}

#pragma mark - Accept 循环

/// Accept 循环（在 _acceptThread 线程中运行）
///
/// 循环接受新客户端连接，为每个客户端启动一个处理线程。
- (void)acceptLoop {
    NSLog(@"[SOCKS5Proxy] Accept 线程已启动");

    while (YES) {
        // 检查运行状态
        [_lock lock];
        BOOL running = _running;
        int listenFD = _listenFD;
        [_lock unlock];

        if (!running || listenFD < 0) {
            NSLog(@"[SOCKS5Proxy] Accept 线程退出（代理已停止）");
            break;
        }

        // 接受新连接
        struct sockaddr_in clientAddr;
        socklen_t clientLen = sizeof(clientAddr);
        int clientFD = accept(listenFD, (struct sockaddr *)&clientAddr, &clientLen);

        if (clientFD < 0) {
            // 检查是否是因为代理已停止
            [_lock lock];
            BOOL stillRunning = _running;
            [_lock unlock];

            if (!stillRunning) {
                NSLog(@"[SOCKS5Proxy] Accept 返回 -1，代理已停止，退出循环");
                break;
            }

            // 其他错误，记录日志并继续
            NSLog(@"[SOCKS5Proxy] accept 失败：errno = %d", errno);
            continue;
        }

        // 获取客户端 IP 和端口
        char clientIP[INET_ADDRSTRLEN] = {0};
        inet_ntop(AF_INET, &clientAddr.sin_addr, clientIP, sizeof(clientIP));
        uint16_t clientPort = ntohs(clientAddr.sin_port);
        NSLog(@"[SOCKS5Proxy] 新客户端连接：%s:%u (fd=%d)", clientIP, clientPort, clientFD);

        // 发送客户端连接通知
        [[NSNotificationCenter defaultCenter] postNotificationName:SOCKS5ProxyClientConnectedNotification
                                                            object:self
                                                          userInfo:@{
                                                              @"clientIP": [NSString stringWithUTF8String:clientIP],
                                                              @"clientPort": @(clientPort)
                                                          }];

        // 启动客户端处理线程
        __weak typeof(self) weakSelf = self;
        NSThread *clientThread = [[NSThread alloc] initWithBlock:^{
            [weakSelf handleClient:clientFD];
        }];
        [clientThread setName:[NSString stringWithFormat:@"SOCKS5Proxy-Client-%d", clientFD]];

        [_lock lock];
        if (_running) {
            [_clientThreads addObject:clientThread];
            [clientThread start];
        } else {
            // 代理已停止，直接关闭客户端连接
            NSLog(@"[SOCKS5Proxy] 代理已停止，拒绝新连接 fd=%d", clientFD);
            close(clientFD);
        }
        [_lock unlock];
    }

    NSLog(@"[SOCKS5Proxy] Accept 线程已退出");
}

#pragma mark - 客户端处理

/// 处理单个客户端连接（在客户端处理线程中运行）
///
/// 流程：
///   1. SOCKS5 握手（认证协商 + 请求解析）
///   2. 通过 ZeroTierBridge 连接目标主机
///   3. 双向转发数据
///   4. 清理资源
///
/// @param clientFD 客户端 socket 文件描述符
- (void)handleClient:(int)clientFD {
    @autoreleasepool {
        NSLog(@"[SOCKS5Proxy] 开始处理客户端 fd=%d", clientFD);

        // 用于保存握手结果
        NSString *targetHost = nil;
        uint16_t targetPort = 0;
        int remoteFD = -1;

        // 步骤 1：SOCKS5 握手
        BOOL handshakeOK = [self socks5Handshake:clientFD
                                      targetHost:&targetHost
                                      targetPort:&targetPort
                                        remoteFD:&remoteFD];

        if (!handshakeOK) {
            NSLog(@"[SOCKS5Proxy] SOCKS5 握手失败，关闭客户端 fd=%d", clientFD);
            close(clientFD);
            if (remoteFD >= 0) {
                [[ZeroTierBridge sharedInstance] closeSocket:remoteFD];
            }

            // 发送客户端断开通知
            [[NSNotificationCenter defaultCenter] postNotificationName:SOCKS5ProxyClientDisconnectedNotification
                                                                object:self
                                                              userInfo:@{@"reason": @"handshake_failed"}];

            // 从线程列表移除自己
            [self removeCurrentThread];
            return;
        }

        NSLog(@"[SOCKS5Proxy] SOCKS5 握手成功，目标 %@:%u，开始转发 (clientFD=%d, remoteFD=%d)",
              targetHost, targetPort, clientFD, remoteFD);

        // 步骤 2：双向转发数据
        [self forwardDataBetweenClientFD:clientFD remoteFD:remoteFD];

        // 步骤 3：清理资源
        // 关闭客户端 socket（系统 POSIX socket）
        close(clientFD);
        // 关闭远程 socket（libzt socket，通过 ZeroTierBridge 关闭）
        [[ZeroTierBridge sharedInstance] closeSocket:remoteFD];

        NSLog(@"[SOCKS5Proxy] 客户端处理完成 fd=%d", clientFD);

        // 发送客户端断开通知
        [[NSNotificationCenter defaultCenter] postNotificationName:SOCKS5ProxyClientDisconnectedNotification
                                                            object:self
                                                          userInfo:@{@"reason": @"closed"}];

        // 从线程列表移除自己
        [self removeCurrentThread];
    }
}

#pragma mark - SOCKS5 协议实现

/// SOCKS5 握手
///
/// 完成认证协商和请求解析，并通过 ZeroTierBridge 连接目标主机。
///
/// @param clientFD 客户端 socket 文件描述符
/// @param targetHost 输出：目标主机地址
/// @param targetPort 输出：目标端口
/// @param remoteFD 输出：远程 socket 文件描述符（libzt socket）
/// @return YES 如果握手成功
- (BOOL)socks5Handshake:(int)clientFD
             targetHost:(NSString **)targetHost
             targetPort:(uint16_t *)targetPort
               remoteFD:(int *)remoteFD {
    // ============================================================
    // 步骤 1：认证方法协商
    // ============================================================

    // 读取客户端 greeting 头：VER(1) NMETHODS(1)
    uint8_t greeting[2] = {0};
    ssize_t n = readAll(clientFD, greeting, 2);
    if (n != 2) {
        NSLog(@"[SOCKS5Proxy] 读取 greeting 头失败：n=%zd", n);
        return NO;
    }

    // 验证 SOCKS 版本
    if (greeting[0] != SOCKS5_VERSION) {
        NSLog(@"[SOCKS5Proxy] 不支持的 SOCKS 版本：%d", greeting[0]);
        return NO;
    }

    uint8_t nMethods = greeting[1];
    if (nMethods == 0) {
        NSLog(@"[SOCKS5Proxy] 客户端未提供任何认证方法");
        return NO;
    }

    // 读取方法列表：METHODS(NMETHODS)
    uint8_t methods[256] = {0};
    n = readAll(clientFD, methods, nMethods);
    if (n != nMethods) {
        NSLog(@"[SOCKS5Proxy] 读取方法列表失败：n=%zd, expected=%d", n, nMethods);
        return NO;
    }

    // 检查是否支持无认证方式（METHOD_NO_AUTH = 0x00）
    // 本代理不支持用户名/密码认证
    BOOL noAuthSupported = NO;
    for (int i = 0; i < nMethods; i++) {
        if (methods[i] == SOCKS5_METHOD_NO_AUTH) {
            noAuthSupported = YES;
            break;
        }
    }

    if (!noAuthSupported) {
        NSLog(@"[SOCKS5Proxy] 客户端不支持无认证方式，拒绝连接");
        // 回复无可接受的方法
        uint8_t reply[2] = {SOCKS5_VERSION, SOCKS5_METHOD_NO_ACCEPTABLE};
        writeAll(clientFD, reply, 2);
        return NO;
    }

    // 回复选择无认证方式：VER(1) METHOD(1)
    uint8_t methodReply[2] = {SOCKS5_VERSION, SOCKS5_METHOD_NO_AUTH};
    n = writeAll(clientFD, methodReply, 2);
    if (n != 2) {
        NSLog(@"[SOCKS5Proxy] 发送 method 回复失败：n=%zd", n);
        return NO;
    }

    NSLog(@"[SOCKS5Proxy] SOCKS5 认证方法协商完成（无认证）");

    // ============================================================
    // 步骤 2：读取客户端请求
    // ============================================================

    // 读取请求头：VER(1) CMD(1) RSV(1) ATYP(1)
    uint8_t requestHeader[4] = {0};
    n = readAll(clientFD, requestHeader, 4);
    if (n != 4) {
        NSLog(@"[SOCKS5Proxy] 读取请求头失败：n=%zd", n);
        return NO;
    }

    // 验证 SOCKS 版本
    if (requestHeader[0] != SOCKS5_VERSION) {
        NSLog(@"[SOCKS5Proxy] 请求中的 SOCKS 版本错误：%d", requestHeader[0]);
        return NO;
    }

    // 检查命令类型（只支持 CONNECT）
    uint8_t cmd = requestHeader[1];
    if (cmd != SOCKS5_CMD_CONNECT) {
        NSLog(@"[SOCKS5Proxy] 不支持的 CMD：%d（仅支持 CONNECT=1）", cmd);
        [self sendSocks5Reply:clientFD
                          rep:SOCKS5_REP_COMMAND_NOT_SUPPORTED
                     bindAddr:@"0.0.0.0"
                     bindPort:0
                         atyp:SOCKS5_ATYP_IPV4];
        return NO;
    }

    // 解析目标地址
    uint8_t atyp = requestHeader[3];
    NSString *destHost = nil;

    switch (atyp) {
        case SOCKS5_ATYP_IPV4: {
            // IPv4 地址：4 字节
            uint8_t ipv4[4] = {0};
            n = readAll(clientFD, ipv4, 4);
            if (n != 4) {
                NSLog(@"[SOCKS5Proxy] 读取 IPv4 地址失败：n=%zd", n);
                return NO;
            }
            destHost = [NSString stringWithFormat:@"%d.%d.%d.%d",
                        ipv4[0], ipv4[1], ipv4[2], ipv4[3]];
            break;
        }

        case SOCKS5_ATYP_DOMAIN: {
            // 域名：1 字节长度 + 域名字符串
            uint8_t domainLen = 0;
            n = readAll(clientFD, &domainLen, 1);
            if (n != 1) {
                NSLog(@"[SOCKS5Proxy] 读取域名长度失败：n=%zd", n);
                return NO;
            }
            char domain[256] = {0};
            n = readAll(clientFD, domain, domainLen);
            if (n != domainLen) {
                NSLog(@"[SOCKS5Proxy] 读取域名失败：n=%zd, expected=%d", n, domainLen);
                return NO;
            }
            destHost = [NSString stringWithUTF8String:domain];
            break;
        }

        case SOCKS5_ATYP_IPV6: {
            // IPv6 地址：16 字节
            uint8_t ipv6[16] = {0};
            n = readAll(clientFD, ipv6, 16);
            if (n != 16) {
                NSLog(@"[SOCKS5Proxy] 读取 IPv6 地址失败：n=%zd", n);
                return NO;
            }
            char ipv6Str[INET6_ADDRSTRLEN] = {0};
            inet_ntop(AF_INET6, ipv6, ipv6Str, sizeof(ipv6Str));
            destHost = [NSString stringWithUTF8String:ipv6Str];
            break;
        }

        default:
            NSLog(@"[SOCKS5Proxy] 不支持的 ATYP：%d", atyp);
            [self sendSocks5Reply:clientFD
                              rep:SOCKS5_REP_ADDRESS_TYPE_NOT_SUPPORTED
                         bindAddr:@"0.0.0.0"
                         bindPort:0
                             atyp:SOCKS5_ATYP_IPV4];
            return NO;
    }

    // 读取目标端口：2 字节，网络字节序（大端）
    uint8_t portBytes[2] = {0};
    n = readAll(clientFD, portBytes, 2);
    if (n != 2) {
        NSLog(@"[SOCKS5Proxy] 读取端口失败：n=%zd", n);
        return NO;
    }
    uint16_t destPort = (uint16_t)((portBytes[0] << 8) | portBytes[1]);

    NSLog(@"[SOCKS5Proxy] 客户端请求连接到 %@:%u", destHost, destPort);

    // ============================================================
    // 步骤 3：通过 ZeroTier 虚拟网络连接目标
    // ============================================================

    // 创建 libzt socket（ZeroTier 虚拟网络 socket）
    int ztFD = [[ZeroTierBridge sharedInstance] createTCPSocket];
    if (ztFD < 0) {
        NSLog(@"[SOCKS5Proxy] 创建 ZeroTier socket 失败：ztFD=%d", ztFD);
        [self sendSocks5Reply:clientFD
                          rep:SOCKS5_REP_GENERAL_FAILURE
                     bindAddr:@"0.0.0.0"
                     bindPort:0
                         atyp:SOCKS5_ATYP_IPV4];
        return NO;
    }

    // 连接目标主机
    int connectResult = [[ZeroTierBridge sharedInstance] connectSocket:ztFD
                                                                toHost:destHost
                                                                  port:destPort
                                                               timeout:SOCKS5_CONNECT_TIMEOUT];
    if (connectResult != 0) {
        NSLog(@"[SOCKS5Proxy] 通过 ZeroTier 连接目标失败：result=%d, target=%@:%u",
              connectResult, destHost, destPort);
        [[ZeroTierBridge sharedInstance] closeSocket:ztFD];

        // 根据错误类型选择合适的回复码
        // 由于 libzt 的错误码与 SOCKS5 回复码不直接对应，这里统一使用 CONNECTION_REFUSED
        [self sendSocks5Reply:clientFD
                          rep:SOCKS5_REP_CONNECTION_REFUSED
                     bindAddr:@"0.0.0.0"
                     bindPort:0
                         atyp:SOCKS5_ATYP_IPV4];
        return NO;
    }

    NSLog(@"[SOCKS5Proxy] 通过 ZeroTier 连接目标成功：target=%@:%u, ztFD=%d",
          destHost, destPort, ztFD);

    // ============================================================
    // 步骤 4：发送成功回复
    // ============================================================

    [self sendSocks5Reply:clientFD
                      rep:SOCKS5_REP_SUCCESS
                 bindAddr:@"0.0.0.0"
                 bindPort:0
                     atyp:SOCKS5_ATYP_IPV4];

    // 输出握手结果
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

/// 发送 SOCKS5 回复
///
/// 回复格式：VER(1) REP(1) RSV(1) ATYP(1) BND.ADDR(?) BND.PORT(2)
///
/// @param clientFD 客户端 socket 文件描述符
/// @param rep 回复码（SOCKS5_REP_*）
/// @param bindAddr 绑定地址（BND.ADDR）
/// @param bindPort 绑定端口（BND.PORT）
/// @param atyp 地址类型（SOCKS5_ATYP_*）
- (void)sendSocks5Reply:(int)clientFD
                    rep:(uint8_t)rep
              bindAddr:(NSString *)bindAddr
              bindPort:(uint16_t)bindPort
                  atyp:(uint8_t)atyp {
    // 构建回复数据
    NSMutableData *reply = [NSMutableData data];

    // VER(1) REP(1) RSV(1) ATYP(1)
    uint8_t header[4] = {SOCKS5_VERSION, rep, 0x00, atyp};
    [reply appendBytes:header length:4];

    // BND.ADDR（根据 ATYP 不同长度不同）
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

    // BND.PORT（2 字节，网络字节序）
    uint8_t portBytes[2] = {
        (uint8_t)((bindPort >> 8) & 0xFF),
        (uint8_t)(bindPort & 0xFF)
    };
    [reply appendBytes:portBytes length:2];

    // 发送回复
    writeAll(clientFD, reply.bytes, reply.length);

    NSLog(@"[SOCKS5Proxy] 已发送 SOCKS5 回复：rep=%d, addr=%@:%u, atyp=%d",
          rep, bindAddr, bindPort, atyp);
}

#pragma mark - 双向数据转发

/// 在客户端和远程主机之间双向转发数据
///
/// 使用 GCD 并发队列，启动两个任务分别处理两个方向的数据转发：
///   - client → remote：从客户端读取数据，通过 ZeroTier 发送到远程
///   - remote → client：从 ZeroTier 接收数据，发送给客户端
///
/// 当任一方向结束时，通过 shutdown() 通知另一端，使其 read/recv 返回 0 并退出。
///
/// @param clientFD 客户端 socket 文件描述符（系统 POSIX socket）
/// @param remoteFD 远程 socket 文件描述符（libzt socket）
- (void)forwardDataBetweenClientFD:(int)clientFD
                          remoteFD:(int)remoteFD {
    // 使用 __block 修饰的标志变量，用于在 block 之间通信
    // 当一个方向结束时，设置标志通知另一个方向退出
    __block BOOL clientClosed = NO;
    __block BOOL remoteClosed = NO;

    // 创建并发队列用于双向转发
    dispatch_queue_t forwardQueue = dispatch_queue_create("com.angelaura.socks5.forward", DISPATCH_QUEUE_CONCURRENT);
    dispatch_group_t group = dispatch_group_create();

    // ============================================================
    // 方向 1：client → remote
    // 从客户端（POSIX socket）读取数据，通过 ZeroTier（libzt socket）发送
    // ============================================================
    dispatch_group_async(group, forwardQueue, ^{
        uint8_t buffer[SOCKS5_BUFFER_SIZE];

        while (YES) {
            @autoreleasepool {
                // 检查远程是否已关闭
                // 使用 __block 变量在两个 block 之间共享状态
                if (remoteClosed) {
                    NSLog(@"[SOCKS5Proxy] client→remote：远程已关闭，退出转发");
                    break;
                }

                // 从客户端读取数据（系统 read）
                ssize_t n = read(clientFD, buffer, sizeof(buffer));
                if (n <= 0) {
                    // n == 0：客户端关闭连接
                    // n < 0：读取错误
                    NSLog(@"[SOCKS5Proxy] client→remote 结束：n=%zd, errno=%d", n, errno);

                    // 标记客户端已关闭
                    clientClosed = YES;

                    // 关闭远程的写端，通知 remote→client 方向退出
                    // shutdown 会导致另一端的 recv 返回 0
                    shutdown(remoteFD, SHUT_WR);
                    break;
                }

                // 通过 ZeroTier 发送数据（libzt send）
                ssize_t sent = [[ZeroTierBridge sharedInstance] sendData:remoteFD
                                                                  buffer:buffer
                                                                  length:(size_t)n];
                if (sent <= 0) {
                    NSLog(@"[SOCKS5Proxy] 发送到远程失败：sent=%zd", sent);

                    // 标记远程已关闭
                    remoteClosed = YES;

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
        uint8_t buffer[SOCKS5_BUFFER_SIZE];

        while (YES) {
            @autoreleasepool {
                // 检查客户端是否已关闭
                if (clientClosed) {
                    NSLog(@"[SOCKS5Proxy] remote→client：客户端已关闭，退出转发");
                    break;
                }

                // 通过 ZeroTier 接收数据（libzt recv）
                ssize_t n = [[ZeroTierBridge sharedInstance] recvData:remoteFD
                                                                buffer:buffer
                                                                length:sizeof(buffer)];
                if (n <= 0) {
                    // n == 0：远程关闭连接
                    // n < 0：接收错误
                    NSLog(@"[SOCKS5Proxy] remote→client 结束：n=%zd", n);

                    // 标记远程已关闭
                    remoteClosed = YES;

                    // 关闭客户端的写端，通知 client→remote 方向退出
                    shutdown(clientFD, SHUT_WR);
                    break;
                }

                // 发送数据给客户端（系统 write）
                ssize_t sent = writeAll(clientFD, buffer, (size_t)n);
                if (sent <= 0) {
                    NSLog(@"[SOCKS5Proxy] 发送到客户端失败：sent=%zd", sent);

                    // 标记客户端已关闭
                    clientClosed = YES;

                    // 关闭远程的写端
                    shutdown(remoteFD, SHUT_WR);
                    break;
                }
            }
        }
    });

    // 等待两个方向的转发都完成
    dispatch_group_wait(group, DISPATCH_TIME_FOREVER);

    NSLog(@"[SOCKS5Proxy] 双向转发结束 (clientFD=%d, remoteFD=%d)", clientFD, remoteFD);
}

#pragma mark - 辅助方法

/// 从客户端线程列表中移除当前线程
- (void)removeCurrentThread {
    NSThread *current = [NSThread currentThread];
    [_lock lock];
    [_clientThreads removeObject:current];
    [_lock unlock];
}

@end
