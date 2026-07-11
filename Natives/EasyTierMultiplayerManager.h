#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// EasyTier 联机房间状态
typedef NS_ENUM(NSInteger, EasyTierRoomStatus) {
    EasyTierRoomStatusDisconnected = 0, // 未连接
    EasyTierRoomStatusConnecting   = 1, // 连接中
    EasyTierRoomStatusConnected    = 2, // 已连接
    EasyTierRoomStatusError        = 3  // 错误
};

/// EasyTier 联机房间模型
///
/// EasyTier 与 ZeroTier 的区别：
/// - ZeroTier 使用 16 位十六进制的 Network ID 标识网络
/// - EasyTier 使用「网络名称(network-name) + 网络密码(network-secret)」标识网络
/// - EasyTier 支持指定公共/自建中继服务器(serverUrl)来辅助 NAT 穿透
/// - EasyTier 的网络名和密码是跨平台通用的，可以和 FCL/ZL2/HMCL 的「陶瓦联机」互通
///
/// 兼容性说明：
/// - EasyTier iOS 客户端需要 iOS 16.0 及以上系统（使用 NetworkExtension 框架）
/// - ZeroTier iOS 客户端支持 iOS 13.0 及以上系统
/// - 本启动器最低支持 iOS 14.0，因此：
///   * iOS 14-15 用户只能使用 ZeroTier 联机
///   * iOS 16+ 用户可以同时使用 EasyTier 和 ZeroTier 联机
///   * EasyTier 联机可以与 FCL/ZL2/HMCL 的陶瓦联机互通
@interface EasyTierRoom : NSObject <NSCoding, NSSecureCoding>

/// 唯一标识（UUID）
@property (nonatomic, copy) NSString *roomId;

/// 房间显示名称（用户自定义，如"和小明联机"）
@property (nonatomic, copy) NSString *name;

/// EasyTier 网络名称（network-name 参数，跨平台通用的网络标识）
/// 与 FCL/ZL2/HMCL 使用相同的 network-name 即可加入同一网络
@property (nonatomic, copy) NSString *networkName;

/// EasyTier 网络密码（network-secret 参数，加入网络需要提供相同的密码）
@property (nonatomic, copy) NSString *networkSecret;

/// EasyTier 中继服务器 URL（可选，如 "tcp://public.easytier.cn:11010"）
/// 指定公共共享节点或自建中继服务器，用于辅助 NAT 穿透
/// 为空时使用 EasyTier 默认的公共节点
@property (nonatomic, copy) NSString *serverUrl;

/// 房主在 EasyTier 网络中的虚拟 IP（如 10.144.144.1）
@property (nonatomic, copy) NSString *hostIP;

/// MC 服务器端口（默认 25565）
@property (nonatomic, copy) NSString *hostPort;

/// 房间描述
@property (nonatomic, copy) NSString *roomDescription;

/// 连接状态
@property (nonatomic, assign) EasyTierRoomStatus status;

/// 房主名称
@property (nonatomic, copy) NSString *ownerName;

/// 创建时间
@property (nonatomic, strong) NSDate *createdAt;

/// 上次连接时间
@property (nonatomic, strong) NSDate *lastConnectedAt;

/// 便捷初始化方法
/// @param roomId       房间 ID（传 nil 时自动生成 UUID）
/// @param name         房间显示名称
/// @param networkName  EasyTier 网络名称
/// @param networkSecret EasyTier 网络密码
/// @param serverUrl    中继服务器 URL（可选）
/// @param hostIP       房主虚拟 IP
/// @param hostPort     MC 服务器端口
- (instancetype)initWithId:(NSString *)roomId
                      name:(NSString *)name
               networkName:(NSString *)networkName
             networkSecret:(NSString *)networkSecret
                 serverUrl:(NSString *)serverUrl
                    hostIP:(NSString *)hostIP
                  hostPort:(NSString *)hostPort;

@end

/// EasyTier 联机管理器
///
/// 参照 FCL 的 MultiplayerManager 和 ZL2 的 LanServerManager 设计，
/// 针对 EasyTier（陶瓦联机）的 iOS 集成实现。
///
/// 与 ZeroTier 的集成方式不同：
/// - ZeroTier iOS app 注册了 zerotier:// URL Scheme，可以通过 URL 自动加入网络
/// - EasyTier iOS app（https://github.com/EasyTier/EasyTier-iOS）目前未注册 URL Scheme，
///   因此无法通过 URL 自动传参加入网络，需要用户手动在 EasyTier app 中操作
/// - 本管理器尝试使用 easytier:// scheme 唤起 app（未来兼容），
///   失败时引导用户打开 App Store / TestFlight 安装 EasyTier
///
/// 功能列表：
/// 1. 管理本地 EasyTier 房间列表（增删改查）
/// 2. 检测 EasyTier app 是否已安装（通过 canOpenURL:）
/// 3. 尝试通过 URL Scheme 唤起 EasyTier app（未来兼容）
/// 4. 生成 EasyTier 房间的分享信息（网络名 + 密码 + 服务器IP + 端口）
/// 5. 从分享文本解析 EasyTier 房间信息
/// 6. 管理当前连接状态
@interface EasyTierMultiplayerManager : NSObject

/// 单例访问
+ (instancetype)sharedManager;

/// 当前连接的房间（nil 表示未连接任何房间）
@property (nonatomic, strong, readonly, nullable) EasyTierRoom *currentRoom;

/// 所有已保存的房间列表
@property (nonatomic, strong, readonly) NSArray<EasyTierRoom *> *savedRooms;

/// EasyTier app 是否已安装
/// 通过 canOpenURL: 检测 easytier:// scheme
/// 注意：Info.plist 中需要将 easytier 添加到 LSApplicationQueriesSchemes
- (BOOL)isEasyTierAppInstalled;

/// 尝试打开 EasyTier app
/// 如果已安装则通过 URL Scheme 唤起，否则打开 TestFlight 安装页面
- (void)openEasyTierApp;

/// 尝试通过 URL Scheme 加入 EasyTier 网络
/// @param networkName 网络名称
/// @param networkSecret 网络密码
/// @param serverUrl 中继服务器 URL（可选）
/// 注意：当前 EasyTier iOS app 未注册 URL Scheme，此方法会尝试 easytier:// 格式，
/// 如果失败则打开 EasyTier app 主界面
- (void)joinNetwork:(NSString *)networkName
       networkSecret:(NSString *)networkSecret
           serverUrl:(NSString *)serverUrl;

/// 添加房间到本地列表
/// @param room 房间对象
- (void)addRoom:(EasyTierRoom *)room;

/// 删除房间
/// @param roomId 房间 ID
- (void)removeRoom:(NSString *)roomId;

/// 更新房间信息
/// @param room 更新后的房间对象
- (void)updateRoom:(EasyTierRoom *)room;

/// 获取指定房间
/// @param roomId 房间 ID
- (nullable EasyTierRoom *)roomWithId:(NSString *)roomId;

/// 连接到房间（设置 currentRoom + 尝试唤起 EasyTier）
/// @param room 房间对象
/// @param completion 完成回调
- (void)connectToRoom:(EasyTierRoom *)room
           completion:(void (^)(BOOL success, NSError * _Nullable error))completion;

/// 断开当前房间连接
- (void)disconnectCurrentRoom;

/// 生成房间的分享文本
/// @param room 房间对象
/// @return 分享文本（包含网络名、密码、服务器IP、端口等信息）
- (NSString *)shareTextForRoom:(EasyTierRoom *)room;

/// 从分享文本解析 EasyTier 房间信息
/// @param text 分享文本
/// @return 解析出的房间对象（解析失败返回 nil）
- (nullable EasyTierRoom *)parseRoomFromShareText:(NSString *)text;

/// 生成新的房间 ID（UUID）
- (NSString *)generateRoomId;

/// 获取 EasyTier 默认公共中继服务器 URL
- (NSString *)defaultPublicServerUrl;

/// 获取 EasyTier TestFlight 链接
- (NSString *)easyTierTestFlightUrl;

/// 获取 EasyTier GitHub 仓库链接
- (NSString *)easyTierGitHubUrl;

@end

NS_ASSUME_NONNULL_END
