#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/* Terracotta 状态枚举（对应 Rust 侧 terracotta_ios_get_state 返回的 JSON "state" 字段） */
typedef NS_ENUM(NSInteger, TerracottaStateKind) {
    TerracottaStateWaiting          = 0,  /* 空闲 */
    TerracottaStateHostScanning     = 1,  /* 房主：扫描本地 MC LAN 广播 */
    TerracottaStateHostStarting     = 2,  /* 房主：已发现 MC 端口，启动 EasyTier */
    TerracottaStateHostOk           = 3,  /* 房主：房间已就绪，可被加入 */
    TerracottaStateGuestConnecting  = 4,  /* 访客：协商 EasyTier + Scaffolding */
    TerracottaStateGuestStarting    = 5,  /* 访客：建立 port_forward */
    TerracottaStateGuestOk          = 6,  /* 访客：port_forward 已建立 */
    TerracottaStateException        = 7,  /* 异常 */
};

/* 房间内玩家档案（Scaffolding 协议 c:player_profiles_list 响应） */
@interface TerracottaPlayerProfile : NSObject
@property(nonatomic, copy)   NSString *name;
@property(nonatomic, copy)   NSString *machineId;
@property(nonatomic, copy, nullable) NSString *easytierId;
@property(nonatomic, copy)   NSString *vendor;
@property(nonatomic, copy)   NSString *kind;  /* "HOST" / "LOCAL" / "GUEST" */
@end

/* Terracotta 当前状态快照（解析自 terracotta_ios_get_state） */
@interface TerracottaState : NSObject
@property(nonatomic, assign) TerracottaStateKind kind;
@property(nonatomic, assign) NSInteger index;       /* 房间会话索引 */
@property(nonatomic, copy, nullable)   NSString *room;          /* 邀请码 */
@property(nonatomic, copy, nullable)   NSString *url;           /* 访客直连地址 */
@property(nonatomic, assign) NSInteger profileIndex;
@property(nonatomic, copy, nullable)   NSArray<TerracottaPlayerProfile *> *profiles;
@property(nonatomic, copy, nullable)   NSString *difficulty;    /* guest-starting 阶段的连接难度 */
@property(nonatomic, assign) NSInteger exceptionType;           /* exception 状态的类型 (0-5) */
@end

/* ObjC 封装的 Terracotta C ABI。所有方法线程安全。 */
@interface TerracottaBridge : NSObject

/* 运行时检查 libterracotta 是否链接。libterracotta.a 未链接时返回 NO，
 * 所有调用会安全降级（返回 NO/nil，状态保持 Waiting）。 */
+ (BOOL)isAvailable;

/* 初始化 Terracotta。App 启动时调用一次。
 *   workingDirectory  Terracotta 工作目录（machine-id 会写在这里）
 *   loggingPath       日志文件路径；nil 表示不写文件
 * 返回 YES 表示成功。 */
+ (BOOL)startWithWorkingDirectory:(NSString *)workingDirectory
                       loggingPath:(nullable NSString *)loggingPath;

/* 回到 Waiting 状态（终止当前会话）。Idempotent。 */
+ (void)setWaiting;

/* 房主：开始扫描本地 MC LAN 广播。 */
+ (void)setScanningWithRoom:(nullable NSString *)room
                 playerName:(nullable NSString *)playerName;

/* 房主（手动端口模式）：用用户输入的 MC LAN 端口直接启动 host。
 * 返回 YES 表示已开始启动；NO 表示当前不在 Waiting 状态。 */
+ (BOOL)startHostWithRoom:(nullable NSString *)room
                     port:(uint16_t)port
               playerName:(nullable NSString *)playerName;

/* 访客：加入房间。
 * 返回 YES 表示已开始加入；NO 表示邀请码无效或当前不在 Waiting 状态。 */
+ (BOOL)setGuestingWithRoom:(NSString *)room
                 playerName:(nullable NSString *)playerName;

/* 仅校验邀请码格式。返回 YES 表示是合法的 Scaffolding 邀请码。 */
+ (BOOL)verifyRoomCode:(NSString *)code;

/* 读取当前状态。返回 nil 表示 JSON 解析失败。 */
+ (nullable TerracottaState *)pollState;

/* 元数据：(version, compileTimestampMs, easytierVersion)。返回 nil 表示失败。 */
+ (nullable NSDictionary<NSString *, id> *)metadata;

/* 把 ExceptionType 翻译成中文描述。 */
+ (NSString *)describeException:(NSInteger)type;

@end

NS_ASSUME_NONNULL_END
