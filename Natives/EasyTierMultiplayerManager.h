#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// EasyTier 联机房间状态
typedef NS_ENUM(NSInteger, EasyTierRoomStatus) {
    EasyTierRoomStatusDisconnected = 0, // 未激活
    EasyTierRoomStatusConnecting   = 1, // 准备配置中
    EasyTierRoomStatusConnected    = 2, // 配置已就绪（可查看并使用）
    EasyTierRoomStatusError        = 3  // 错误
};

/// EasyTier 联机房间角色
typedef NS_ENUM(NSInteger, EasyTierRoomRole) {
    EasyTierRoomRoleHost  = 0, // 房主（开房）
    EasyTierRoomRoleGuest = 1  // 房客（加入）
};

/// EasyTier 联机房间模型
///
/// 基于 Terracotta（陶瓦联机）的 Scaffolding-MC 协议实现，
/// 使用 `U/XXXX-XXXX-XXXX-XXXX` 格式的邀请码，与 HMCL/FCL/ZL2/PCL2 完全互通。
///
/// 邀请码格式说明：
/// - `U/` 固定前缀
/// - 16 个 base-34 字符（字符表：0123456789ABCDEFGHJKLMNPQRSTUVWXYZ，排除 I 和 O）
/// - 分为 4 组，每组 4 字符，用 `-` 分隔
/// - 包含模 7 校验和（用于检测输入错误）
/// - 前 8 字符 → EasyTier network-name（加 `scaffolding-mc-` 前缀）
/// - 后 8 字符 → EasyTier network-secret
///
/// 协议兼容性：
/// - 邀请码生成与解析算法完全遵循 Terracotta 源码（src/controller/rooms/scaffolding/room.rs）
/// - 生成的邀请码可在 HMCL、FCL、ZL2、PCL2 中直接导入使用
/// - 接收来自上述任一启动器的邀请码也可正确解析
///
/// 关于嵌入式集成：
/// - iOS 平台由于沙盒限制，无法像 Android（FCL/ZL2）那样以子进程方式运行 EasyTier 核心
/// - 完整的嵌入式集成需要 NetworkExtension（NEPacketTunnelProvider）+ Rust 静态库
/// - 当前版本采用"配置信息透明展示"模式：生成完整的 EasyTier 配置（邀请码、网络名、
///   密码、公共服务器、TOML 配置），用户可在任意 EasyTier 客户端中使用
/// - 协议层完全兼容，确保与 FCL/ZL2/HMCL 完美互通
@interface EasyTierRoom : NSObject <NSCoding, NSSecureCoding>

/// 唯一标识（UUID）
@property (nonatomic, copy) NSString *roomId;

/// 房间显示名称（用户自定义，如"和小明联机"）
@property (nonatomic, copy) NSString *name;

/// 邀请码（格式：U/XXXX-XXXX-XXXX-XXXX）
/// 这是与 HMCL/FCL/ZL2/PCL2 互通的核心标识
@property (nonatomic, copy) NSString *invitationCode;

/// EasyTier 网络名称（从邀请码解析，格式：scaffolding-mc-XXXX-XXXX）
@property (nonatomic, copy) NSString *networkName;

/// EasyTier 网络密码（从邀请码解析，格式：XXXX-XXXX）
@property (nonatomic, copy) NSString *networkSecret;

/// 房主在 EasyTier 网络中的虚拟 IP（房主固定为 10.144.144.1）
@property (nonatomic, copy) NSString *hostIP;

/// MC 服务器端口（房主开放局域网时的端口，默认 25565）
@property (nonatomic, copy) NSString *hostPort;

/// 房间角色（房主/房客）
@property (nonatomic, assign) EasyTierRoomRole role;

/// 连接状态
@property (nonatomic, assign) EasyTierRoomStatus status;

/// 房主名称
@property (nonatomic, copy) NSString *ownerName;

/// 创建时间
@property (nonatomic, strong) NSDate *createdAt;

/// 上次连接时间
@property (nonatomic, strong) NSDate *lastConnectedAt;

/// 便捷初始化方法（房主模式：生成邀请码）
/// @param name     房间显示名称
/// @param hostPort MC 服务器端口
- (instancetype)initAsHostWithName:(NSString *)name
                          hostPort:(NSString *)hostPort;

/// 便捷初始化方法（房客模式：从邀请码解析）
/// @param name           房间显示名称
/// @param invitationCode 邀请码（U/XXXX-XXXX-XXXX-XXXX）
- (nullable instancetype)initAsGuestWithName:(NSString *)name
                              invitationCode:(NSString *)invitationCode;

@end

/// EasyTier 联机管理器
///
/// 基于 Terracotta（陶瓦联机）的 Scaffolding-MC 协议实现，
/// 使用 `U/XXXX-XXXX-XXXX-XXXX` 格式的邀请码，与 HMCL/FCL/ZL2/PCL2 完全互通。
///
/// 邀请码编码规则（参照 Terracotta 源码 src/controller/rooms/scaffolding/room.rs）：
/// 1. 生成 128 位随机数
/// 2. 对 34^16 取模
/// 3. 减去 value % 7 使其能被 7 整除（校验和）
/// 4. 循环 16 次，每次取 value % 34 作为一位（小端序），value /= 34
/// 5. 在第 4、8、12 位后插入 `-` 分隔符
/// 6. 字符表：0123456789ABCDEFGHJKLMNPQRSTUVWXYZ（排除 I 和 O）
///
/// 解析规则：
/// 1. 转大写，容错 I→1, O→0
/// 2. 滑动搜索 `U/` 前缀
/// 3. 验证第 4、9、14 位为 `-`
/// 4. 从后往前重建 value: value = value * 34 + digit
/// 5. 校验 value % 7 == 0
///
/// 与 EasyTier 参数的对应：
/// - network-name = `scaffolding-mc-` + 前 8 字符（第 4 位后插 `-`）
/// - network-secret = 后 8 字符（第 12 位后插 `-`）
/// - 公共服务器使用硬编码默认值（不在邀请码中）
///
/// 关于 iOS 集成方式：
/// - Android 平台（FCL/ZL2）通过子进程 + VpnService 运行 EasyTier 核心
/// - iOS 沙盒禁止子进程和直接操作 utun 设备
/// - 完整嵌入式集成需要 NetworkExtension + Rust 静态库（工程复杂度极高）
/// - 当前版本采用"配置信息透明展示"模式：生成完整配置供用户使用
/// - 协议层完全兼容，确保与 FCL/ZL2/HMCL 完美互通
@interface EasyTierMultiplayerManager : NSObject

/// 单例访问
+ (instancetype)sharedManager;

/// 当前激活的房间（nil 表示未激活任何房间）
@property (nonatomic, strong, readonly, nullable) EasyTierRoom *currentRoom;

/// 所有已保存的房间列表
@property (nonatomic, strong, readonly) NSArray<EasyTierRoom *> *savedRooms;

/// 房主在 EasyTier 网络中的固定虚拟 IP
@property (nonatomic, copy, readonly) NSString *hostVirtualIP;

#pragma mark - 邀请码生成与解析

/// 生成新的邀请码（U/XXXX-XXXX-XXXX-XXXX 格式）
/// @return 邀请码字符串
- (NSString *)generateInvitationCode;

/// 从邀请码解析出网络名和网络密码
/// @param invitationCode 邀请码（U/XXXX-XXXX-XXXX-XXXX）
/// @return 包含 networkName 和 networkSecret 的字典（解析失败返回 nil）
- (nullable NSDictionary<NSString *, NSString *> *)parseInvitationCode:(NSString *)invitationCode;

/// 验证邀请码是否合法
/// @param invitationCode 邀请码字符串
/// @return YES 如果合法
- (BOOL)isValidInvitationCode:(NSString *)invitationCode;

/// 从邀请码提取 EasyTier network-name
/// @param invitationCode 邀请码
/// @return network-name（如 scaffolding-mc-AABB-CCDD），失败返回 nil
- (nullable NSString *)networkNameFromInvitationCode:(NSString *)invitationCode;

/// 从邀请码提取 EasyTier network-secret
/// @param invitationCode 邀请码
/// @return network-secret（如 EEFF-GGHH），失败返回 nil
- (nullable NSString *)networkSecretFromInvitationCode:(NSString *)invitationCode;

#pragma mark - 配置生成

/// 生成房间的 EasyTier TOML 配置字符串
///
/// 该配置可直接用于 EasyTier 命令行或图形客户端导入。
/// 配置包含：
/// - ipv4：虚拟 IP（房主为 10.144.144.1，房客由 EasyTier 自动分配）
/// - network_identity：network_name + network_secret（从邀请码解析）
/// - peer：公共服务器列表
/// - listeners：本地监听端口
///
/// @param room 房间对象
/// @return TOML 格式的配置字符串
- (NSString *)generateTOMLConfigForRoom:(EasyTierRoom *)room;

/// 生成房间的人类可读配置摘要
///
/// 用于在 UI 中展示和分享，包含：
/// - 邀请码
/// - 网络名
/// - 网络密码
/// - 公共服务器
/// - 房主 IP
/// - MC 服务器地址
///
/// @param room 房间对象
/// @return 配置摘要字符串
- (NSString *)generateConfigSummaryForRoom:(EasyTierRoom *)room;

/// 获取 EasyTier 默认公共服务器列表
- (NSArray<NSString *> *)defaultPublicServers;

#pragma mark - 房间管理

/// 添加房间到本地列表
- (void)addRoom:(EasyTierRoom *)room;

/// 删除房间
- (void)removeRoom:(NSString *)roomId;

/// 更新房间信息
- (void)updateRoom:(EasyTierRoom *)room;

/// 获取指定房间
- (nullable EasyTierRoom *)roomWithId:(NSString *)roomId;

/// 激活房间（设置 currentRoom + 准备配置）
///
/// 注意：当前版本不会真正建立 EasyTier 虚拟网络（需要 NetworkExtension）。
/// 此方法仅标记房间为"配置已就绪"状态，用户可在详情中查看并复制配置。
///
/// @param room       房间对象
/// @param completion 完成回调（主线程）
- (void)connectToRoom:(EasyTierRoom *)room
           completion:(void (^)(BOOL success, NSError * _Nullable error))completion;

/// 取消激活当前房间
- (void)disconnectCurrentRoom;

#pragma mark - 分享与辅助

/// 生成房间的分享文本（用于社交渠道分享）
- (NSString *)shareTextForRoom:(EasyTierRoom *)room;

/// 生成新的房间 ID（UUID）
- (NSString *)generateRoomId;

@end

NS_ASSUME_NONNULL_END
