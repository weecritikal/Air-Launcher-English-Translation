#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// 联机房间状态
typedef NS_ENUM(NSInteger, MultiplayerRoomStatus) {
    MultiplayerRoomStatusDisconnected = 0, // 未连接
    MultiplayerRoomStatusConnecting   = 1, // 连接中
    MultiplayerRoomStatusConnected    = 2, // 已连接
    MultiplayerRoomStatusError        = 3  // 错误
};

/// 联机房间模型
@interface MultiplayerRoom : NSObject <NSCoding, NSSecureCoding>
@property (nonatomic, copy) NSString *roomId;          // 唯一标识（UUID）
@property (nonatomic, copy) NSString *name;            // 房间名称
@property (nonatomic, copy) NSString *networkId;       // ZeroTier Network ID（16位十六进制）
@property (nonatomic, copy) NSString *hostIP;          // 房主在 ZeroTier 网络中的 IP（如 10.147.17.1）
@property (nonatomic, copy) NSString *hostPort;        // MC 服务器端口（默认 25565）
@property (nonatomic, copy) NSString *roomDescription; // 房间描述
@property (nonatomic, assign) MultiplayerRoomStatus status; // 连接状态
@property (nonatomic, copy) NSString *ownerName;       // 房主名称
@property (nonatomic, strong) NSDate *createdAt;       // 创建时间
@property (nonatomic, strong) NSDate *lastConnectedAt; // 上次连接时间
@end

/// 联机状态变化通知代理
///
/// 当 ZeroTier 节点状态、网络状态发生变化时，会通过代理回调通知上层。
/// 所有回调方法都在主线程调用。
@protocol MultiplayerManagerDelegate <NSObject>
@optional

/// ZeroTier 节点已上线
- (void)multiplayerNodeOnline;

/// ZeroTier 节点已离线
- (void)multiplayerNodeOffline;

/// 指定房间已连接成功（网络已就绪且 SOCKS5 代理已启动）
/// @param room 连接成功的房间
- (void)multiplayerRoomConnected:(MultiplayerRoom *)room;

/// 指定房间连接失败
/// @param room 连接失败的房间
/// @param error 错误信息
- (void)multiplayerRoom:(MultiplayerRoom *)room
   didFailWithError:(NSError *)error;

/// ZeroTier 框架可用性检测结果
/// @param available YES 表示 zt.framework 已加载（非 stub）
- (void)multiplayerFrameworkAvailabilityChecked:(BOOL)available;

@end

/// ZeroTier 联机管理器
///
/// 参照 FCL 的 MultiplayerManager 和 ZL2 的 LanServerManager 设计：
/// 1. 管理本地联机房间列表（增删改查）
/// 2. 通过 ZeroTier Apple Framework (zt.framework) 在进程内加入/离开 ZeroTier 网络
/// 3. 启动本地 SOCKS5 代理，将 Minecraft 流量转发到 ZeroTier 虚拟网络
/// 4. 检测 zt.framework 是否可用（非 stub）
/// 5. 管理当前连接状态
/// 6. 生成分享信息（房间名 + Network ID + IP + 端口）
///
/// 与旧的基于 URL Scheme 的实现不同，本版本完全在 App 进程内运行 ZeroTier 节点，
/// 无需依赖外部的 ZeroTier One app，也不需要 NetworkExtension 权限。
/// 流量通过本地 SOCKS5 代理（127.0.0.1:1080）转发，Minecraft 通过 JVM 的
/// -DsocksProxyHost/-DsocksProxyPort 参数走代理。
@interface MultiplayerManager : NSObject

+ (instancetype)sharedManager;

/// 代理对象（弱引用）
@property (nonatomic, weak, nullable) id<MultiplayerManagerDelegate> delegate;

/// 当前连接的房间（nil 表示未连接任何房间）
@property (nonatomic, strong, readonly, nullable) MultiplayerRoom *currentRoom;

/// 所有已保存的房间列表
@property (nonatomic, strong, readonly) NSArray<MultiplayerRoom *> *savedRooms;

/// 当前 SOCKS5 代理监听端口（代理未运行时返回 0）
@property (nonatomic, assign, readonly) uint16_t currentSOCKS5Port;

/// 当前 SOCKS5 代理是否正在运行
@property (nonatomic, assign, readonly) BOOL isSOCKS5ProxyRunning;

/// ZeroTier 节点是否已上线
@property (nonatomic, assign, readonly) BOOL isNodeOnline;

/// 当前房间在 ZeroTier 网络中分配到的本地 IP（可用于显示给用户）
/// 仅在房间已连接且 ZeroTier 分配了 IP 后才有效
@property (nonatomic, copy, readonly, nullable) NSString *currentLocalIP;

#pragma mark - 框架检测

/// 检测 zt.framework 是否可用（非 stub 实现）
///
/// 本方法委托给 ZeroTierBridge 的 isFrameworkAvailable，结果会被缓存。
/// 当 framework 不可用时（如 CI 构建环境链接了 zt_stub.c），所有联机功能将不可用。
///
/// @return YES 如果 framework 可用
- (BOOL)isFrameworkAvailable;

/// ZeroTier 节点是否已启动
/// @return YES 如果节点已启动（不要求已上线）
- (BOOL)isNodeStarted;

/// 启动 ZeroTier 节点
///
/// 如果节点尚未启动，则在后台线程启动节点。
/// 节点启动后会异步触发 ZTS_EVENT_NODE_ONLINE 事件。
///
/// @param completion 完成回调（主线程，YES 表示启动请求已成功提交）
- (void)ensureNodeStartedWithCompletion:(void (^)(BOOL success, NSError * _Nullable error))completion;

#pragma mark - 兼容旧 API（已废弃，仅用于平滑过渡）

/// 检测 ZeroTier One app 是否已安装（已废弃）
///
/// 旧的基于 URL Scheme 的实现需要检测外部 ZeroTier One app 是否安装。
/// 新版本使用进程内 zt.framework，不再依赖外部 app。
/// 本方法现在返回 isFrameworkAvailable 的结果，保持 API 兼容性。
///
/// @return YES 如果 zt.framework 可用
- (BOOL)isZeroTierAppInstalled __attribute__((deprecated("使用 isFrameworkAvailable 代替")));

/// 设置 ZeroTier 安装状态覆盖（已废弃，新版本为空操作）
/// @param installed 已废弃参数，无实际效果
- (void)setZeroTierInstalledOverride:(BOOL)installed __attribute__((deprecated("新版本无需手动覆盖安装状态")));

/// 用户是否已手动覆盖 ZeroTier 安装状态（已废弃）
/// @return 始终返回 NO
- (BOOL)isZeroTierInstallOverridden __attribute__((deprecated("新版本始终返回 NO")));

/// 打开 ZeroTier One app（已废弃，新版本为空操作）
- (void)openZeroTierApp __attribute__((deprecated("新版本使用进程内框架，无需打开外部 app")));

#pragma mark - 网络加入与离开

/// 通过 Network ID 加入 ZeroTier 网络
///
/// 本方法直接在进程内调用 zts_net_join 加入指定网络。
/// 如果节点尚未启动，会先启动节点。
///
/// @param networkId ZeroTier Network ID（16位十六进制）
/// @param completion 完成回调（主线程，YES 表示加入请求已成功提交，不代表网络已就绪）
- (void)joinNetwork:(NSString *)networkId
         completion:(nullable void (^)(BOOL success, NSError * _Nullable error))completion;

/// 离开 ZeroTier 网络
///
/// 本方法直接在进程内调用 zts_net_leave 离开指定网络。
///
/// @param networkId ZeroTier Network ID
- (void)leaveNetwork:(NSString *)networkId;

#pragma mark - 房间管理（增删改查）

/// 添加房间到本地列表
/// @param room 房间对象
- (void)addRoom:(MultiplayerRoom *)room;

/// 删除房间
/// @param roomId 房间 ID
- (void)removeRoom:(NSString *)roomId;

/// 更新房间信息
/// @param room 更新后的房间对象
- (void)updateRoom:(MultiplayerRoom *)room;

/// 获取指定房间
/// @param roomId 房间 ID
- (nullable MultiplayerRoom *)roomWithId:(NSString *)roomId;

#pragma mark - 连接管理

/// 连接到房间
///
/// 完整流程：
///   1. 校验 room 非空且 networkId 有效
///   2. 设置 currentRoom 并更新状态为 Connecting
///   3. 启动 ZeroTier 节点（如果尚未启动）
///   4. 加入 ZeroTier 网络
///   5. 等待网络就绪（IPv4 地址已分配）
///   6. 启动本地 SOCKS5 代理（端口 1080）
///   7. 设置 AMETHYST_SOCKS5_PROXY 环境变量（供 JavaLauncher 读取）
///   8. 更新房间状态为 Connected，回调 completion
///
/// 任何一步失败都会更新房间状态为 Error 并回调 completion(NO, error)。
///
/// @param room       房间对象
/// @param completion 完成回调（主线程）
- (void)connectToRoom:(MultiplayerRoom *)room
           completion:(void (^)(BOOL success, NSError * _Nullable error))completion;

/// 断开当前房间连接
///
/// 流程：
///   1. 停止本地 SOCKS5 代理
///   2. 清除 AMETHYST_SOCKS5_PROXY 环境变量
///   3. 离开 ZeroTier 网络
///   4. 更新房间状态为 Disconnected
///   5. 清空 currentRoom
- (void)disconnectCurrentRoom;

#pragma mark - 分享与导入

/// 生成房间的分享文本
/// @param room 房间对象
/// @return 分享文本
- (NSString *)shareTextForRoom:(MultiplayerRoom *)room;

/// 从分享文本解析房间信息
/// @param text 分享文本
/// @return 解析出的房间对象（解析失败返回 nil）
- (nullable MultiplayerRoom *)parseRoomFromShareText:(NSString *)text;

/// 生成新的 ZeroTier 风格房间 ID（UUID）
- (NSString *)generateRoomId;

#pragma mark - 分享代码（FCL 风格 Base64 编码）

/// 生成房间的分享代码（Base64 编码的 JSON）
///
/// 对标 FCL 的联机分享码：房主开放局域网后自动生成一段代码，
/// 房客输入代码即可加入房间。
///
/// 代码格式：Base64(JSON)，JSON 包含：
///   - networkId: ZeroTier Network ID
///   - hostIP: 房主在 ZeroTier 网络中的 IP
///   - hostPort: MC 服务器端口（LAN 端口或 25565）
///   - roomName: 房间名称
///
/// @param room 房间对象
/// @return Base64 编码的分享代码
- (NSString *)generateShareCodeForRoom:(MultiplayerRoom *)room;

/// 从分享代码解析房间信息（Base64 编码的 JSON）
///
/// @param code Base64 编码的分享代码
/// @return 解析出的房间对象（解析失败返回 nil）
- (nullable MultiplayerRoom *)parseShareCode:(NSString *)code;

#pragma mark - 预设 Network ID 管理（FCL 风格）

/// 获取用户预设的 ZeroTier Network ID
///
/// 对标 FCL：房主首次设置一次 Network ID（在 my.zerotier.com 创建后填入），
/// 之后每次开房自动使用这个 Network ID，无需重复输入。
///
/// @return 预设的 Network ID（未设置时返回 nil）
- (nullable NSString *)presetNetworkId;

/// 设置预设的 ZeroTier Network ID
/// @param networkId Network ID（传入 nil 或空字符串则清除）
- (void)setPresetNetworkId:(nullable NSString *)networkId;

#pragma mark - Ad-hoc 网络（快速模式，无需注册账号）

/// 生成 Ad-hoc 网络 ID（快速模式）
///
/// 对标 FCL 的"无需注册直接联机"体验：
///   - 调用 zts_net_compute_adhoc_id 生成一个无需网络控制器的公开网络 ID
///   - 房主和房客使用相同的端口范围即可加入同一网络
///   - 无需在 my.zerotier.com 注册账号、创建网络、授权成员
///
/// 注意：
///   1. Ad-hoc 网络只有 IPv6 地址（无 IPv4）
///   2. 网络是公开的，任何人都能加入（安全性弱）
///   3. IP 基于节点 ID 自动分配，可能变化（稳定性不如标准模式）
///   4. 端口范围限制：MC 服务器端口和 LAN 端口需在范围内
///
/// 为兼容 MC 的所有端口（25565 和 LAN 随机端口 49152-65535），
/// 本方法使用 0-65535 的全端口范围。
///
/// @return 16 位十六进制的 Ad-hoc 网络 ID 字符串
- (NSString *)generateAdhocNetworkId;

/// 判断 Network ID 是否为 Ad-hoc 网络
///
/// Ad-hoc 网络 ID 以 "ff" 开头（如 ff0000ffff000000）。
/// 用于在连接流程中区分标准模式和快速模式。
///
/// @param networkId 待判断的 Network ID
/// @return YES 如果是 Ad-hoc 网络
- (BOOL)isAdhocNetworkId:(NSString *)networkId;

#pragma mark - 校验工具

/// 验证 ZeroTier Network ID 格式
/// @param networkId 待校验的 Network ID 字符串
/// @return YES 如果格式有效
- (BOOL)isValidNetworkId:(NSString *)networkId;

/// 验证 IP 地址格式
/// @param ipAddress 待校验的 IP 地址字符串
/// @return YES 如果格式有效
- (BOOL)isValidIPAddress:(NSString *)ipAddress;

@end

NS_ASSUME_NONNULL_END
