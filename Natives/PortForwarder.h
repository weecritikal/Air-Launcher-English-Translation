//
//  PortForwarder.h
//  Angel Aura Amethyst
//
//  本地 TCP 端口转发器
//
//  ============================================================================
//  设计说明
//  ============================================================================
//
//  本文件实现一个本地 TCP 端口转发器，将 Minecraft 客户端的流量通过
//  ZeroTier 虚拟网络转发到房主的游戏服务器。
//
//  为什么需要端口转发而不是 SOCKS5 代理？
//
//  Minecraft 从 1.7.2 开始使用 Netty 作为网络库。Netty 的 NioSocketChannel
//  底层使用 java.nio.channels.SocketChannel，而 SocketChannel 不检查 Java 的
//  ProxySelector。这意味着 JVM 参数 -DsocksProxyHost/-DsocksProxyPort 对
//  Minecraft 的多人游戏连接无效（只对 java.net.Socket 有效，如登录认证等）。
//
//  因此，当房客在 MC 中输入房主的 ZeroTier IP（如 10.147.17.1:54321）时：
//    1. MC 的 Netty 创建 NioSocketChannel
//    2. NioSocketChannel 直接创建 SocketChannel
//    3. SocketChannel 尝试直接连接 10.147.17.1:54321
//    4. 系统没有 ZeroTier 网络接口（我们用的是进程内 libzt）
//    5. 系统无法路由到 10.147.17.1
//    6. 连接失败，显示"无法连接"
//
//  端口转发方案：
//    1. 在本地监听一个 TCP 端口（如 127.0.0.1:25565）
//    2. 当 MC 连接到 127.0.0.1:25565 时，通过 libzt 的 socket API 连接到
//       房主的 ZeroTier IP:端口
//    3. 双向转发数据
//    4. 房客在 MC 中输入 127.0.0.1:25565 即可连接
//
//  这样，MC 的 Netty 连接到 127.0.0.1:25565（本地地址，系统可以路由），
//  由 PortForwarder 通过 libzt 转发到房主的 ZeroTier 网络。
//
//  工作流程：
//    1. PortForwarder 监听 127.0.0.1:localPort（系统 POSIX socket）
//    2. Minecraft 客户端连接到 127.0.0.1:localPort
//    3. PortForwarder 通过 ZeroTierBridge 创建 libzt socket
//    4. PortForwarder 通过 libzt socket 连接到 remoteHost:remotePort
//    5. PortForwarder 在客户端 socket 和 libzt socket 之间双向转发数据
//
//  架构说明：
//    - 监听 socket：使用系统 POSIX socket（socket/bind/listen/accept）
//    - 客户端 socket：系统 POSIX socket（accept 返回的 fd）
//    - 远程 socket：libzt socket（通过 ZeroTierBridge 创建）
//    - 转发使用 GCD 并发队列，两个方向同时转发
//
//  与 ZeroTierBridge 的关系：
//    PortForwarder 依赖 ZeroTierBridge 提供的 socket 方法与 ZeroTier 虚拟网络通信。
//    ZeroTierBridge 必须已启动节点并加入网络后，PortForwarder 才能正常工作。
//
//  ============================================================================

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// 端口转发器默认本地监听端口（Minecraft 默认服务器端口）
extern const uint16_t PortForwarderDefaultLocalPort;

/// 本地 TCP 端口转发器
///
/// 单例模式，通过 +sharedForwarder 获取全局唯一实例。
/// 在本地监听 TCP 端口，将流量通过 ZeroTier 虚拟网络转发到远程主机。
@interface PortForwarder : NSObject

/// 单例访问
+ (instancetype)sharedForwarder;

/// 启动端口转发
///
/// 创建 POSIX socket 监听 127.0.0.1:localPort，并在后台线程接受客户端连接。
/// 每个客户端连接后，通过 ZeroTierBridge 创建 libzt socket 连接到
/// remoteHost:remotePort，然后双向转发数据。
///
/// 如果 localPort 为 0，则由系统自动分配可用端口。
/// 如果 localPort 被占用，会尝试 localPort+1 到 localPort+9。
///
/// @param localPort 本地监听端口（0 表示自动分配）
/// @param remoteHost 远程主机地址（房主的 ZeroTier IP）
/// @param remotePort 远程端口（房主的 MC LAN 端口）
/// @param error 错误输出（如果失败）
/// @return 成功返回实际监听端口，失败返回 0
- (uint16_t)startWithLocalPort:(uint16_t)localPort
                    remoteHost:(NSString *)remoteHost
                    remotePort:(uint16_t)remotePort
                         error:(NSError **)error;

/// 停止端口转发
///
/// 关闭监听 socket，停止接受新连接。
/// 已建立的客户端连接会继续处理直到完成，然后自动清理。
- (void)stop;

/// 端口转发器是否正在运行
@property (nonatomic, readonly, getter=isRunning) BOOL running;

/// 当前监听端口
@property (nonatomic, readonly) uint16_t listeningPort;

/// 当前转发的远程主机
@property (nonatomic, readonly, copy, nullable) NSString *remoteHost;

/// 当前转发的远程端口
@property (nonatomic, readonly) uint16_t remotePort;

@end

NS_ASSUME_NONNULL_END
