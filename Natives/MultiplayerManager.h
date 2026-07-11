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

/// ZeroTier 联机管理器
///
/// 参照 FCL 的 MultiplayerManager 和 ZL2 的 LanServerManager 设计：
/// 1. 管理本地联机房间列表（增删改查）
/// 2. 通过 URL Scheme 唤起 ZeroTier One app 加入/离开网络
/// 3. 检测 ZeroTier One app 是否已安装
/// 4. 管理当前连接状态
/// 5. 生成分享信息（房间名 + Network ID + IP + 端口）
@interface MultiplayerManager : NSObject

+ (instancetype)sharedManager;

/// 当前连接的房间（nil 表示未连接任何房间）
@property (nonatomic, strong, readonly, nullable) MultiplayerRoom *currentRoom;

/// 所有已保存的房间列表
@property (nonatomic, strong, readonly) NSArray<MultiplayerRoom *> *savedRooms;

/// ZeroTier One app 是否已安装
- (BOOL)isZeroTierAppInstalled;

/// 设置 ZeroTier 安装状态覆盖（用户手动指定，用于 canOpenURL 检测失败时）
/// @param installed YES 表示用户确认已安装 ZeroTier One
- (void)setZeroTierInstalledOverride:(BOOL)installed;

/// 用户是否已手动覆盖 ZeroTier 安装状态
- (BOOL)isZeroTierInstallOverridden;

/// 打开 ZeroTier One app
- (void)openZeroTierApp;

/// 通过 Network ID 加入 ZeroTier 网络（唤起 ZeroTier One app）
/// @param networkId ZeroTier Network ID（16位十六进制）
- (void)joinNetwork:(NSString *)networkId;

/// 离开 ZeroTier 网络（唤起 ZeroTier One app）
/// @param networkId ZeroTier Network ID
- (void)leaveNetwork:(NSString *)networkId;

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

/// 连接到房间（设置 currentRoom + 唤起 ZeroTier）
/// @param room 房间对象
/// @param completion 完成回调
- (void)connectToRoom:(MultiplayerRoom *)room completion:(void (^)(BOOL success, NSError * _Nullable error))completion;

/// 断开当前房间连接
- (void)disconnectCurrentRoom;

/// 生成房间的分享文本
/// @param room 房间对象
/// @return 分享文本（如 "来联机！房间名：xxx\nZeroTier网络ID：xxx\n服务器IP：xxx:xxx"）
- (NSString *)shareTextForRoom:(MultiplayerRoom *)room;

/// 从分享文本解析房间信息
/// @param text 分享文本
/// @return 解析出的房间对象（解析失败返回 nil）
- (nullable MultiplayerRoom *)parseRoomFromShareText:(NSString *)text;

/// 生成新的 ZeroTier 风格房间 ID（UUID）
- (NSString *)generateRoomId;

@end

NS_ASSUME_NONNULL_END
