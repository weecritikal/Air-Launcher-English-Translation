#import <Foundation/Foundation.h>
#import "TerracottaBridge.h"

NS_ASSUME_NONNULL_BEGIN

/* 给 UI 显示的高层连接状态 */
typedef NS_ENUM(NSInteger, TerracottaStatus) {
    TerracottaStatusDisconnected = 0,  /* 未连接 */
    TerracottaStatusConnecting   = 1,  /* 连接中 */
    TerracottaStatusConnected    = 2,  /* 已连接 */
    TerracottaStatusError        = 3,  /* 出错 */
};

/* 玩家角色（房主 / 加入者） */
typedef NS_ENUM(NSInteger, TerracottaRole) {
    TerracottaRoleNone   = 0,
    TerracottaRoleHost   = 1,
    TerracottaRoleClient = 2,
};

/* 状态变化通知 —— UI 监听此通知后读取 manager 属性刷新 */
extern NSNotificationName TerracottaManagerStateDidChangeNotification;

/* Terracotta 联机管理器（替代旧版 ZeroTier 联机方案）
 *
 * - 不使用 NETunnelProviderManager / NEPacketTunnelProvider → 不需要 NE 权限
 * - 通过 TerracottaBridge 调用 terracotta_ios_* C ABI（与 HMCL/FCL/ZL2 同源）
 * - 0.5 秒一次轮询 terracotta_ios_get_state，驱动 UI 状态
 * - 用 SilentAudioPlayer 在房间运行期间提供后台保活
 * - 单例，App 启动时初始化一次 */
@interface TerracottaManager : NSObject

+ (instancetype)shared;

/* 给 UI 的高层状态（KVO 兼容） */
@property(nonatomic, assign, readonly) TerracottaStatus status;
/* 当前角色（房主 / 加入者 / nil） */
@property(nonatomic, assign, readonly) TerracottaRole role;
/* 当前邀请码（房主 hostOk 后才有；访客 joinRoom 后立即写入） */
@property(nonatomic, copy, readonly, nullable) NSString *currentInviteCode;
/* 当前 MC 端口（房主 createRoom 时用户输入；访客 guestOk 后从 url 解析） */
@property(nonatomic, copy, readonly, nullable) NSString *currentPort;
/* 当前阶段中文描述（来自 TerracottaState） */
@property(nonatomic, copy, readonly) NSString *stageDescription;
/* 房间内玩家列表（hostOk/guestOk 时由 Rust 侧 profiles 填充） */
@property(nonatomic, copy, readonly, nullable) NSArray<TerracottaPlayerProfile *> *players;
/* 访客在 MC 直连用的 host:port 字符串（如 "127.0.0.1:25565"） */
@property(nonatomic, copy, readonly, nullable) NSString *directConnectURL;
/* 最近一次错误信息（status=Error 时显示） */
@property(nonatomic, copy, readonly, nullable) NSString *lastError;
/* Terracotta 是否已初始化成功 */
@property(nonatomic, assign, readonly) BOOL initialized;

/* 房主：创建房间（自动扫描 MC LAN 广播模式，iOS 多播不可靠故不推荐）
 *   inviteCode  可选，复用已有邀请码；nil 让 Rust 侧生成
 *   port        仅用于 UI 显示和历史记录，不传给 Terracotta
 *   playerName  可选，玩家昵称；nil 用设备名 */
- (BOOL)createRoomWithInviteCode:(nullable NSString *)inviteCode
                            port:(nullable NSString *)port
                       playerName:(nullable NSString *)playerName;

/* 房主（手动端口模式，iOS 推荐使用）
 *   inviteCode  可选，复用已有邀请码；nil 让 Rust 侧生成
 *   port        MC LAN 端口（如 25565）
 *   playerName  可选，玩家昵称；nil 用设备名 */
- (BOOL)createRoomWithPort:(uint16_t)port
                inviteCode:(nullable NSString *)inviteCode
                playerName:(nullable NSString *)playerName;

/* 访客：加入房间
 *   inviteCode  必填，房主分享的 Scaffolding 邀请码
 *   playerName  可选，玩家昵称；nil 用设备名
 * 返回 NO 表示邀请码非法或当前不在 Waiting 状态。 */
- (BOOL)joinRoomWithInviteCode:(NSString *)inviteCode
                    playerName:(nullable NSString *)playerName;

/* 关闭当前会话（房主关房 / 访客断开）。Idempotent。 */
- (void)stopSession;

/* 仅校验邀请码格式 */
- (BOOL)verifyRoomCode:(NSString *)code;

@end

NS_ASSUME_NONNULL_END
