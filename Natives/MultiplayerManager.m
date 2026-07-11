//
//  MultiplayerManager.m
//  Amethyst
//
//  基于 ZeroTier 的 Minecraft 联机功能管理器实现
//
//  ============================================================================
//  设计理念与参照来源
//  ============================================================================
//
//  本文件参照了以下两个开源项目的联机管理器设计思路：
//
//  1. FCL (FoldCraftLauncher) - Android 平台的 MC 启动器
//     - 其 MultiplayerManager 负责 ZeroTier 网络的加入/离开、
//       联机房间的本地化管理、以及分享信息的生成与解析。
//     - FCL 通过 JNI 调用 ZeroTier 的 native 库（libzt）直接在进程内
//       建立 ZeroTier 虚拟网络，无需依赖外部 app。
//
//  2. ZL2 (ZalithLauncher) - Android 平台的 MC 启动器（PojavLauncher 分支）
//     - 其 LanServerManager 同样基于 ZeroTier，但提供了更友好的
//       房间卡片 UI、分享码导入、以及与 MC 内置"添加服务器"功能的联动。
//
//  在 iOS 平台上，由于以下限制，无法完全照搬 Android 的实现：
//    a. iOS 不允许 App 在后台长期运行 VPN / 虚拟网卡（ZeroTier 官方 app
//       使用 NetworkExtension.framework 的 NEPacketTunnelProvider，需要
//       Apple 颁发的 Network Extension 权限，普通开发者账号无法获取）。
//    b. iOS 沙盒机制禁止第三方 App 直接操作 utun 设备。
//
//  因此，iOS 上的联机策略调整为：
//    1. 启动器不直接集成 ZeroTier SDK，而是通过 URL Scheme 唤起
//       ZeroTier 官方 app（ZeroTier One）进行网络的加入/离开。
//    2. 启动器本地维护"联机房间"列表（房间名 + Network ID + 房主 IP + 端口），
//       使用 NSUserDefaults + NSKeyedArchiver（NSSecureCoding）持久化。
//    3. 启动器提供"分享文本"功能，将房间信息打包成一段带格式的文本，
//       方便通过微信/QQ/iMessage 等社交渠道发送给好友。
//    4. 好友收到分享文本后，可在启动器内"导入房间"，自动解析并添加到列表。
//    5. 连接房间时，启动器先唤起 ZeroTier One 加入网络，再引导用户在 MC 内
//       通过"多人游戏 → 直接连接 / 添加服务器"输入 房主IP:端口 加入。
//
//  ZeroTier URL Scheme 说明（逆向自 ZeroTier One iOS app）：
//    - zerotier://                         打开 app 主界面
//    - zerotier://network?n=<networkId>    加入指定网络
//    - zerotier://network?n=<networkId>&leave=1  离开指定网络
//
//  注意：iOS 9+ 要求在 Info.plist 的 LSApplicationQueriesSchemes 中声明
//  要查询的 URL Scheme。使用 isZeroTierAppInstalled 前必须将 "zerotier"
//  添加到 LSApplicationQueriesSchemes 数组中，否则 canOpenURL: 始终返回 NO
//  （控制台会打印 "This app is not allowed to query for scheme zerotier"）。
//
//  ZeroTier One app App Store 地址：
//    https://apps.apple.com/app/zerotier-one/id1083244434
//
//  ============================================================================
//

#import "MultiplayerManager.h"
#import "LauncherPreferences.h"
#import <UIKit/UIKit.h>

#pragma mark - 常量定义

/// NSUserDefaults 中存储房间列表的 key
static NSString * const kMultiplayerSavedRoomsKey = @"multiplayer_saved_rooms";

/// ZeroTier app 的 URL Scheme
static NSString * const kZeroTierURLScheme = @"zerotier";

/// ZeroTier One app 在 App Store 的下载地址
static NSString * const kZeroTierAppStoreURL = @"https://apps.apple.com/app/zerotier-one/id1083244434";

/// MC 默认服务器端口
static NSString * const kDefaultMCPort = @"25565";

/// 分享文本中的各种前缀标记（用于生成和解析）
static NSString * const kShareHeaderLine = @"🎮 来联机吧！";
static NSString * const kShareRoomNamePrefix = @"房间名称：";
static NSString * const kShareNetworkIdPrefix = @"ZeroTier网络ID：";
static NSString * const kShareServerAddressPrefix = @"服务器地址：";

/// 错误域名
static NSString * const kMultiplayerErrorDomain = @"MultiplayerManagerErrorDomain";

/// 错误码
typedef NS_ENUM(NSInteger, MultiplayerErrorCode) {
    MultiplayerErrorCodeRoomNotFound    = 1001, // 房间未找到
    MultiplayerErrorCodeRoomAlreadyExist = 1002, // 房间已存在（roomId 重复）
    MultiplayerErrorCodeInvalidNetworkId = 1003, // Network ID 格式无效
    MultiplayerErrorCodeInvalidRoom      = 1004, // 房间对象无效
    MultiplayerErrorCodeZeroTierNotInstalled = 1005, // ZeroTier app 未安装
    MultiplayerErrorCodeParseShareTextFailed = 1006  // 解析分享文本失败
};

#pragma mark - MultiplayerRoom 实现

@implementation MultiplayerRoom

/// NSSecureCoding 要求：声明该类支持安全编码
/// 当使用 NSKeyedArchiver/NSKeyedUnarchiver 的 requireSecureCoding:YES 时，
/// 必须实现此方法并返回 YES，否则解档时会抛出异常。
+ (BOOL)supportsSecureCoding {
    return YES;
}

/// 便捷初始化方法
/// 使用指定的房间信息创建一个新房间对象，自动生成 roomId（UUID）、
/// 设置默认端口 25565、默认状态为 Disconnected、createdAt 为当前时间。
///
/// @param roomId     房间唯一标识（可为 nil，nil 时自动生成）
/// @param name       房间名称
/// @param networkId  ZeroTier Network ID（16位十六进制）
/// @param hostIP     房主在 ZeroTier 网络中的 IP
/// @param hostPort   MC 服务器端口（可为 nil，nil 时使用 25565）
- (instancetype)initWithId:(NSString *)roomId
                      name:(NSString *)name
                 networkId:(NSString *)networkId
                    hostIP:(NSString *)hostIP
                  hostPort:(NSString *)hostPort {
    self = [super init];
    if (self) {
        _roomId = roomId ?: [[NSUUID UUID] UUIDString];
        _name = [name copy] ?: @"";
        _networkId = [networkId copy] ?: @"";
        _hostIP = [hostIP copy] ?: @"";
        _hostPort = [hostPort copy] ?: kDefaultMCPort;
        _roomDescription = @"";
        _status = MultiplayerRoomStatusDisconnected;
        _ownerName = @"";
        _createdAt = [NSDate date];
        _lastConnectedAt = nil;
    }
    return self;
}

#pragma mark - NSSecureCoding / NSCoding

/// 从 NSCoder（通常是 NSKeyedUnarchiver）中解码恢复房间对象
/// 所有属性都通过 decodeObjectOfClass:forKey: 安全解码，符合 NSSecureCoding 规范
- (instancetype)initWithCoder:(NSCoder *)coder {
    self = [super init];
    if (self) {
        // 字符串属性使用 NSString 类安全解码
        _roomId = [coder decodeObjectOfClass:[NSString class] forKey:@"roomId"] ?: @"";
        _name = [coder decodeObjectOfClass:[NSString class] forKey:@"name"] ?: @"";
        _networkId = [coder decodeObjectOfClass:[NSString class] forKey:@"networkId"] ?: @"";
        _hostIP = [coder decodeObjectOfClass:[NSString class] forKey:@"hostIP"] ?: @"";
        _hostPort = [coder decodeObjectOfClass:[NSString class] forKey:@"hostPort"] ?: kDefaultMCPort;
        _roomDescription = [coder decodeObjectOfClass:[NSString class] forKey:@"description"] ?: @"";
        _ownerName = [coder decodeObjectOfClass:[NSString class] forKey:@"ownerName"] ?: @"";

        // 日期属性使用 NSDate 类安全解码
        _createdAt = [coder decodeObjectOfClass:[NSDate class] forKey:@"createdAt"];
        _lastConnectedAt = [coder decodeObjectOfClass:[NSDate class] forKey:@"lastConnectedAt"];

        // 枚举状态使用 decodeIntegerForKey 解码
        NSInteger statusValue = [coder decodeIntegerForKey:@"status"];
        // 边界保护：防止存储的状态值超出枚举范围（如旧版本数据迁移）
        if (statusValue < MultiplayerRoomStatusDisconnected ||
            statusValue > MultiplayerRoomStatusError) {
            statusValue = MultiplayerRoomStatusDisconnected;
        }
        _status = (MultiplayerRoomStatus)statusValue;
    }
    return self;
}

/// 将房间对象编码到 NSCoder（通常是 NSKeyedArchiver）中进行持久化
/// 所有属性都使用 encodeObject:forKey: 或 encodeInteger:forKey: 编码
- (void)encodeWithCoder:(NSCoder *)coder {
    [coder encodeObject:self.roomId forKey:@"roomId"];
    [coder encodeObject:self.name forKey:@"name"];
    [coder encodeObject:self.networkId forKey:@"networkId"];
    [coder encodeObject:self.hostIP forKey:@"hostIP"];
    [coder encodeObject:self.hostPort forKey:@"hostPort"];
    [coder encodeObject:self.roomDescription forKey:@"description"];
    [coder encodeObject:self.ownerName forKey:@"ownerName"];
    [coder encodeObject:self.createdAt forKey:@"createdAt"];
    [coder encodeObject:self.lastConnectedAt forKey:@"lastConnectedAt"];
    [coder encodeInteger:(NSInteger)self.status forKey:@"status"];
}

#pragma mark - 描述方法（便于调试）

/// 返回房间的描述信息，便于在 NSLog / LLDB 中查看
- (NSString *)description {
    return [NSString stringWithFormat:@"<MultiplayerRoom: %p roomId=%@ name=%@ networkId=%@ host=%@:%@ status=%ld>",
            self,
            self.roomId,
            self.name,
            self.networkId,
            self.hostIP,
            self.hostPort,
            (long)self.status];
}

#pragma mark - 复制与相等性（便于去重和比较）

/// 实现 copyWithZone: 以支持便捷复制（虽然未在头文件声明 <NSCopying>，
/// 但内部实现有助于在 updateRoom 等场景中保留旧数据快照）
- (id)copyWithZone:(NSZone *)zone {
    MultiplayerRoom *copy = [[MultiplayerRoom alloc] init];
    copy.roomId = [self.roomId copy];
    copy.name = [self.name copy];
    copy.networkId = [self.networkId copy];
    copy.hostIP = [self.hostIP copy];
    copy.hostPort = [self.hostPort copy];
    copy.roomDescription = [self.roomDescription copy];
    copy.status = self.status;
    copy.ownerName = [self.ownerName copy];
    copy.createdAt = [self.createdAt copy];
    copy.lastConnectedAt = [self.lastConnectedAt copy];
    return copy;
}

/// 基于 roomId 判断两个房间是否相等
- (BOOL)isEqual:(id)object {
    if (self == object) return YES;
    if (![object isKindOfClass:[MultiplayerRoom class]]) return NO;
    MultiplayerRoom *other = (MultiplayerRoom *)object;
    return [self.roomId isEqualToString:other.roomId];
}

/// 与 isEqual: 配套的 hash 实现
- (NSUInteger)hash {
    return self.roomId.hash;
}

@end

#pragma mark - MultiplayerManager 实现

@interface MultiplayerManager ()
{
    /// 用于保护房间列表读写操作的锁
    /// 虽然公开方法约定在主线程调用，但内部异步操作（如 saveRooms）
    /// 可能会与主线程并发，使用锁确保线程安全
    dispatch_queue_t _serializationQueue;
}

/// 可读写的房间列表（头文件中声明为 readonly）
@property (nonatomic, strong, readwrite) NSMutableArray<MultiplayerRoom *> *internalRooms;

/// 可读写的当前房间（头文件中声明为 readonly）
@property (nonatomic, strong, readwrite, nullable) MultiplayerRoom *currentRoom;
@end

@implementation MultiplayerManager

#pragma mark - 单例模式

/// 获取共享的 MultiplayerManager 单例实例
/// 使用 dispatch_once 保证线程安全的单次初始化
+ (instancetype)sharedManager {
    static MultiplayerManager *shared = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        shared = [[self alloc] init];
    });
    return shared;
}

/// 重写 allocWithZone: 防止通过 alloc/init 创建第二个实例
/// 这是一种更严格的单例保护，确保即使外部调用 [[MultiplayerManager alloc] init]
/// 也能拿到同一个实例
+ (instancetype)allocWithZone:(struct _NSZone *)zone {
    static MultiplayerManager *shared = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        shared = [super allocWithZone:zone];
    });
    return shared;
}

/// 私有初始化方法
/// 创建一个串行队列用于持久化操作，并从 NSUserDefaults 加载已保存的房间列表
- (instancetype)init {
    self = [super init];
    if (self) {
        // 创建串行队列，用于串行化房间列表的读写操作
        _serializationQueue = dispatch_queue_create("com.angelaura.multiplayer.serialization", DISPATCH_QUEUE_SERIAL);
        _internalRooms = [[NSMutableArray alloc] init];
        _currentRoom = nil;

        // 从本地存储加载房间列表
        [self loadRooms];

        NSLog(@"[MultiplayerManager] 初始化完成，已加载 %lu 个房间", (unsigned long)_internalRooms.count);
    }
    return self;
}

#pragma mark - 对外暴露的只读属性

/// 返回房间列表的不可变副本，防止外部直接修改内部数组
- (NSArray<MultiplayerRoom *> *)savedRooms {
    // 在主线程读取，返回数组的 copy（不可变）
    if ([NSThread isMainThread]) {
        return [_internalRooms copy];
    } else {
        // 如果在非主线程调用，派发到主线程同步读取
        // 但由于头文件约定公开方法在主线程执行，这里仅做保护
        __block NSArray *result = nil;
        dispatch_sync(dispatch_get_main_queue(), ^{
            result = [self.internalRooms copy];
        });
        return result;
    }
}

#pragma mark - 数据持久化

/// 从 NSUserDefaults 加载已保存的房间列表
/// 使用 NSKeyedUnarchiver + NSSecureCoding 解码
- (void)loadRooms {
    @synchronized(self) {
        NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
        NSData *data = [defaults dataForKey:kMultiplayerSavedRoomsKey];

        if (!data || data.length == 0) {
            // 没有存储数据，保持空数组
            self.internalRooms = [[NSMutableArray alloc] init];
            return;
        }

        NSError *error = nil;
        // 使用 NSSecureCoding 安全解档
        // allowedClasses 限定为 NSArray 和 MultiplayerRoom，防止恶意数据注入
        NSSet *allowedClasses = [NSSet setWithObjects:[NSArray class], [MultiplayerRoom class], nil];
        NSArray *rooms = [NSKeyedUnarchiver unarchivedObjectOfClasses:allowedClasses
                                                           fromData:data
                                                              error:&error];
        if (error || !rooms) {
            NSLog(@"[MultiplayerManager] 加载房间列表失败：%@", error.localizedDescription);
            // 解档失败时，使用旧的兼容方式尝试一次（NSKeyedUnarchiver 旧 API）
            // 这是为了兼容可能存在的旧版本数据格式
            NSKeyedUnarchiver *unarchiver = [[NSKeyedUnarchiver alloc] initForReadingFromData:data error:&error];
            unarchiver.requiresSecureCoding = NO;
            @try {
                NSArray *legacyRooms = [unarchiver decodeObjectForKey:NSKeyedArchiveRootObjectKey];
                if ([legacyRooms isKindOfClass:[NSArray class]]) {
                    self.internalRooms = [NSMutableArray arrayWithArray:legacyRooms];
                    NSLog(@"[MultiplayerManager] 使用兼容模式加载了 %lu 个房间", (unsigned long)self.internalRooms.count);
                    [unarchiver finishDecoding];
                    return;
                }
            } @catch (NSException *exception) {
                NSLog(@"[MultiplayerManager] 兼容模式解档异常：%@", exception);
            }
            [unarchiver finishDecoding];
            self.internalRooms = [[NSMutableArray alloc] init];
            return;
        }

        // 过滤掉无效的房间对象（防御性编程）
        NSMutableArray *validRooms = [[NSMutableArray alloc] init];
        for (id obj in rooms) {
            if ([obj isKindOfClass:[MultiplayerRoom class]]) {
                [validRooms addObject:obj];
            }
        }

        self.internalRooms = validRooms;
        NSLog(@"[MultiplayerManager] 成功加载 %lu 个房间", (unsigned long)self.internalRooms.count);
    }
}

/// 将当前房间列表保存到 NSUserDefaults
/// 使用 NSKeyedArchiver + NSSecureCoding 编码
/// 该方法在每次 addRoom/removeRoom/updateRoom 后自动调用
- (void)saveRooms {
    // 在串行队列中执行持久化，避免阻塞主线程
    // 但为了保证调用方看到的 savedRooms 立即反映最新状态，
    // _internalRooms 的内存修改在主线程同步完成，磁盘写入异步进行
    NSArray *roomsToSave = [self.internalRooms copy];

    dispatch_async(_serializationQueue, ^{
        NSError *error = nil;
        // 使用 NSKeyedArchiver 的安全编码 API（requiresSecureCoding = YES）
        NSData *data = [NSKeyedArchiver archivedDataWithRootObject:roomsToSave
                                             requiringSecureCoding:YES
                                                             error:&error];
        if (error || !data) {
            NSLog(@"[MultiplayerManager] 序列化房间列表失败：%@", error.localizedDescription);
            return;
        }

        NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
        [defaults setObject:data forKey:kMultiplayerSavedRoomsKey];
        // synchronize 在现代 iOS 上已非必需，但为了确保数据及时落盘（尤其在用户即将退出 app 时），仍保留调用
        BOOL synced = [defaults synchronize];
        NSLog(@"[MultiplayerManager] 房间列表已保存（%lu 个，synchronize=%d）",
              (unsigned long)roomsToSave.count, synced);
    });
}

#pragma mark - ZeroTier App 检测与跳转

/// 检测 ZeroTier One app 是否已安装
///
/// 检测策略（多重 fallback，确保各种安装方式都能正确识别）：
///
/// 1. canOpenURL:（首选）
///    iOS 9+ 要求在 Info.plist 的 LSApplicationQueriesSchemes 中声明 "zerotier"。
///    适用于 App Store 安装的 ZeroTier One。
///    局限：某些非 App Store 安装方式（TrollStore、越狱 ipa）可能返回 NO。
///
/// 2. LSApplicationWorkspace 检查（fallback 1）
///    私有 API，枚举已安装 app 的 bundle id。
///    适用于越狱/TrollStore 设备上通过非 App Store 方式安装的 ZeroTier One。
///    ZeroTier One 的 bundle id 为 com.zerotier.one。
///
/// 3. 用户偏好覆盖（fallback 2）
///    如果用户通过设置手动指定"已安装 ZeroTier"，则跳过自动检测。
///    pref key: multiplayer.zerotier.installed_override (BOOL)
///
/// 关于 canOpenURL: 在某些情况下返回 NO 的原因：
/// - iOS 限制最多查询 50 个 scheme，超过后所有查询返回 NO
/// - 某些 iOS 版本上 TrollStore 安装的 app 不注册 URL Scheme
/// - 越狱设备上某些注入工具可能破坏 URL Scheme 注册
///
/// @return YES 如果 ZeroTier One app 已安装
- (BOOL)isZeroTierAppInstalled {
    // 策略 0：用户偏好覆盖（最高优先级）
    // 用户明确知道装了，但自动检测失败时可手动覆盖
    if (getPrefBool(@"multiplayer.zerotier.installed_override")) {
        return YES;
    }

    // 策略 1：canOpenURL:（App Store 安装的标准方式）
    NSURL *url = [NSURL URLWithString:[NSString stringWithFormat:@"%@://", kZeroTierURLScheme]];
    if (url) {
        __block BOOL canOpen = NO;
        if ([NSThread isMainThread]) {
            canOpen = [[UIApplication sharedApplication] canOpenURL:url];
        } else {
            dispatch_sync(dispatch_get_main_queue(), ^{
                canOpen = [[UIApplication sharedApplication] canOpenURL:url];
            });
        }
        if (canOpen) {
            return YES;
        }
    }

    // 策略 2：LSApplicationWorkspace 私有 API（TrollStore/越狱安装）
    // 检查 com.zerotier.one bundle id 是否存在于已安装 app 列表
    Class LSApplicationWorkspaceClass = NSClassFromString(@"LSApplicationWorkspace");
    if (LSApplicationWorkspaceClass) {
        SEL defaultWorkspaceSel = NSSelectorFromString(@"defaultWorkspace");
        SEL installedAppsSel = NSSelectorFromString(@"allInstalledApplications");
        if ([LSApplicationWorkspaceClass respondsToSelector:defaultWorkspaceSel] &&
            [LSApplicationWorkspaceClass respondsToSelector:installedAppsSel]) {
            id workspace = [LSApplicationWorkspaceClass performSelector:defaultWorkspaceSel];
            if (workspace && [workspace respondsToSelector:installedAppsSel]) {
                NSArray *installedApps = [workspace performSelector:installedAppsSel];
                for (id app in installedApps) {
                    NSString *bundleID = nil;
                    if ([app respondsToSelector:@selector(applicationIdentifier)]) {
                        bundleID = [app performSelector:@selector(applicationIdentifier)];
                    } else if ([app respondsToSelector:NSSelectorFromString(@"bundleIdentifier")]) {
                        bundleID = [app performSelector:NSSelectorFromString(@"bundleIdentifier")];
                    }
                    if ([bundleID isEqualToString:@"com.zerotier.one"]) {
                        return YES;
                    }
                }
            }
        }
    }

    // 策略 3：检查 /var/containers/Bundle 下的 ZeroTier app 目录（越狱/TrollStore）
    // 这是最底层的检测方式，不依赖任何框架
    NSFileManager *fm = [NSFileManager defaultManager];
    NSArray *searchPaths = @[
        @"/var/containers/Bundle/Application",
        @"/var/jb/containers/Bundle/Application",
        @"/Applications",
        @"/var/containers/Bundle/ Applications",
    ];
    for (NSString *searchPath in searchPaths) {
        if (![fm fileExistsAtPath:searchPath]) continue;
        NSDirectoryEnumerator *enumerator = [fm enumeratorAtPath:searchPath];
        NSString *subpath;
        while ((subpath = [enumerator nextObject])) {
            // 查找 ZeroTier.app 或包含 com.zerotier.one 的目录
            if ([subpath hasSuffix:@"ZeroTier.app"] ||
                [subpath hasSuffix:@"ZeroTier One.app"] ||
                [subpath.pathExtension isEqualToString:@"app"] && [subpath containsString:@"ZeroTier"]) {
                return YES;
            }
        }
    }

    return NO;
}

/// 设置 ZeroTier 安装状态覆盖（用户手动指定）
/// @param installed YES 表示用户确认已安装 ZeroTier One
- (void)setZeroTierInstalledOverride:(BOOL)installed {
    setPrefBool(@"multiplayer.zerotier.installed_override", installed);
}

/// 用户是否已手动覆盖 ZeroTier 安装状态
- (BOOL)isZeroTierInstallOverridden {
    return getPrefBool(@"multiplayer.zerotier.installed_override");
}

/// 打开 ZeroTier One app
/// 如果 app 未安装，则打开 App Store 下载页面
- (void)openZeroTierApp {
    // 确保在主线程执行 UI 相关操作
    void (^openBlock)(void) = ^{
        NSURL *url = [NSURL URLWithString:[NSString stringWithFormat:@"%@://", kZeroTierURLScheme]];

        if ([[UIApplication sharedApplication] canOpenURL:url]) {
            // ZeroTier app 已安装，直接打开
            [[UIApplication sharedApplication] openURL:url
                                               options:@{}
                                     completionHandler:^(BOOL success) {
                if (!success) {
                    NSLog(@"[MultiplayerManager] 打开 ZeroTier app 失败");
                    // 打开失败，回退到 App Store
                    [self openZeroTierAppStorePage];
                }
            }];
        } else {
            // ZeroTier app 未安装，打开 App Store 下载页
            NSLog(@"[MultiplayerManager] ZeroTier app 未安装，跳转 App Store");
            [self openZeroTierAppStorePage];
        }
    };

    if ([NSThread isMainThread]) {
        openBlock();
    } else {
        dispatch_async(dispatch_get_main_queue(), openBlock);
    }
}

/// 打开 ZeroTier One 在 App Store 的下载页面
- (void)openZeroTierAppStorePage {
    NSURL *appStoreURL = [NSURL URLWithString:kZeroTierAppStoreURL];
    if (!appStoreURL) return;

    [[UIApplication sharedApplication] openURL:appStoreURL
                                       options:@{}
                             completionHandler:^(BOOL success) {
        if (!success) {
            NSLog(@"[MultiplayerManager] 打开 App Store 失败");
        }
    }];
}

/// 通过 Network ID 加入 ZeroTier 网络
///
/// 通过 URL Scheme "zerotier://network?n=<networkId>" 唤起 ZeroTier One app，
/// app 会自动尝试加入指定的网络（用户仍需在 ZeroTier app 内确认加入，
/// 且网络管理员需要在 my.zerotier.com 后台授权该设备）。
///
/// 如果 ZeroTier app 未安装，则跳转到 App Store 下载页面。
///
/// @param networkId ZeroTier Network ID（16位十六进制字符串）
- (void)joinNetwork:(NSString *)networkId {
    if (!networkId || networkId.length == 0) {
        NSLog(@"[MultiplayerManager] joinNetwork: networkId 为空");
        return;
    }

    // 去除前后空白字符
    NSString *trimmedNetworkId = [networkId stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];

    // 验证 Network ID 格式（16位十六进制）
    if (![self isValidNetworkId:trimmedNetworkId]) {
        NSLog(@"[MultiplayerManager] joinNetwork: Network ID 格式无效：%@", trimmedNetworkId);
        return;
    }

    void (^joinBlock)(void) = ^{
        // 构造 ZeroTier URL Scheme：zerotier://network?n=<networkId>
        NSString *urlString = [NSString stringWithFormat:@"%@://network?n=%@",
                               kZeroTierURLScheme, trimmedNetworkId];
        NSURL *url = [NSURL URLWithString:urlString];

        if (!url) {
            NSLog(@"[MultiplayerManager] 构造 ZeroTier join URL 失败：%@", urlString);
            return;
        }

        if ([[UIApplication sharedApplication] canOpenURL:url]) {
            [[UIApplication sharedApplication] openURL:url
                                               options:@{}
                                     completionHandler:^(BOOL success) {
                if (success) {
                    NSLog(@"[MultiplayerManager] 已唤起 ZeroTier 加入网络：%@", trimmedNetworkId);
                } else {
                    NSLog(@"[MultiplayerManager] 唤起 ZeroTier 加入网络失败，尝试打开 App Store");
                    [self openZeroTierAppStorePage];
                }
            }];
        } else {
            NSLog(@"[MultiplayerManager] ZeroTier app 未安装，跳转 App Store");
            [self openZeroTierAppStorePage];
        }
    };

    if ([NSThread isMainThread]) {
        joinBlock();
    } else {
        dispatch_async(dispatch_get_main_queue(), joinBlock);
    }
}

/// 离开 ZeroTier 网络
///
/// 通过 URL Scheme "zerotier://network?n=<networkId>&leave=1" 唤起 ZeroTier One app，
/// app 会自动尝试离开指定的网络。
///
/// @param networkId ZeroTier Network ID
- (void)leaveNetwork:(NSString *)networkId {
    if (!networkId || networkId.length == 0) {
        NSLog(@"[MultiplayerManager] leaveNetwork: networkId 为空");
        return;
    }

    NSString *trimmedNetworkId = [networkId stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];

    void (^leaveBlock)(void) = ^{
        // 构造 ZeroTier URL Scheme：zerotier://network?n=<networkId>&leave=1
        NSString *urlString = [NSString stringWithFormat:@"%@://network?n=%@&leave=1",
                               kZeroTierURLScheme, trimmedNetworkId];
        NSURL *url = [NSURL URLWithString:urlString];

        if (!url) {
            NSLog(@"[MultiplayerManager] 构造 ZeroTier leave URL 失败：%@", urlString);
            return;
        }

        if ([[UIApplication sharedApplication] canOpenURL:url]) {
            [[UIApplication sharedApplication] openURL:url
                                               options:@{}
                                     completionHandler:^(BOOL success) {
                if (success) {
                    NSLog(@"[MultiplayerManager] 已唤起 ZeroTier 离开网络：%@", trimmedNetworkId);
                } else {
                    NSLog(@"[MultiplayerManager] 唤起 ZeroTier 离开网络失败");
                }
            }];
        } else {
            NSLog(@"[MultiplayerManager] ZeroTier app 未安装，无法离开网络");
            // 离开网络时如果 app 未安装，不需要跳转 App Store
            // 因为用户可能已经卸载了 app，此时离开网络已无意义
        }
    };

    if ([NSThread isMainThread]) {
        leaveBlock();
    } else {
        dispatch_async(dispatch_get_main_queue(), leaveBlock);
    }
}

#pragma mark - 房间管理（增删改查）

/// 添加房间到本地列表
///
/// 流程：
/// 1. 校验 room 非空且 roomId 非空
/// 2. 检查 roomId 唯一性（若已存在同 roomId 的房间，拒绝添加）
/// 3. 添加到 _internalRooms
/// 4. 按 createdAt 降序排序（最新创建的房间在前）
/// 5. 调用 saveRooms 持久化
///
/// @param room 房间对象
- (void)addRoom:(MultiplayerRoom *)room {
    if (!room) {
        NSLog(@"[MultiplayerManager] addRoom: room 为空");
        return;
    }

    if (!room.roomId || room.roomId.length == 0) {
        NSLog(@"[MultiplayerManager] addRoom: roomId 为空，自动生成");
        room.roomId = [[NSUUID UUID] UUIDString];
    }

    if (!room.name || room.name.length == 0) {
        room.name = @"未命名房间";
    }

    if (!room.hostPort || room.hostPort.length == 0) {
        room.hostPort = kDefaultMCPort;
    }

    if (!room.createdAt) {
        room.createdAt = [NSDate date];
    }

    @synchronized(self) {
        // 检查 roomId 唯一性
        for (MultiplayerRoom *existing in self.internalRooms) {
            if ([existing.roomId isEqualToString:room.roomId]) {
                NSLog(@"[MultiplayerManager] addRoom: roomId 已存在：%@", room.roomId);
                return;
            }
        }

        [self.internalRooms addObject:room];

        // 按 createdAt 降序排序（最新创建的房间排在最前）
        [self sortRoomsByCreatedAt];
    }

    NSLog(@"[MultiplayerManager] 已添加房间：%@（%@）", room.name, room.roomId);
    [self saveRooms];
}

/// 删除房间
///
/// 从 _internalRooms 中过滤掉指定 roomId 的房间，然后持久化。
/// 如果要删除的房间正好是当前连接的房间（currentRoom），则先断开连接。
///
/// @param roomId 房间 ID
- (void)removeRoom:(NSString *)roomId {
    if (!roomId || roomId.length == 0) {
        NSLog(@"[MultiplayerManager] removeRoom: roomId 为空");
        return;
    }

    @synchronized(self) {
        NSMutableArray *roomsToKeep = [[NSMutableArray alloc] init];
        MultiplayerRoom *roomToRemove = nil;

        for (MultiplayerRoom *room in self.internalRooms) {
            if ([room.roomId isEqualToString:roomId]) {
                roomToRemove = room;
            } else {
                [roomsToKeep addObject:room];
            }
        }

        if (!roomToRemove) {
            NSLog(@"[MultiplayerManager] removeRoom: 未找到 roomId：%@", roomId);
            return;
        }

        self.internalRooms = roomsToKeep;

        // 如果要删除的房间是当前连接的房间，先断开
        if (self.currentRoom && [self.currentRoom.roomId isEqualToString:roomId]) {
            NSLog(@"[MultiplayerManager] 删除的房间是当前连接的房间，先断开连接");
            // 注意：这里不调用 disconnectCurrentRoom，因为它会唤起 ZeroTier 离开网络，
            // 而删除房间时用户可能只是想清理列表，不一定想离开网络。
            // 这里仅清空 currentRoom 引用并重置状态。
            self.currentRoom.status = MultiplayerRoomStatusDisconnected;
            self.currentRoom = nil;
        }
    }

    NSLog(@"[MultiplayerManager] 已删除房间：%@", roomId);
    [self saveRooms];
}

/// 更新房间信息
///
/// 查找同 roomId 的房间并替换为新数据，然后持久化。
/// 如果未找到对应 roomId 的房间，则不做任何操作（不会新增）。
///
/// @param room 更新后的房间对象（roomId 必须与已存在的房间匹配）
- (void)updateRoom:(MultiplayerRoom *)room {
    if (!room || !room.roomId || room.roomId.length == 0) {
        NSLog(@"[MultiplayerManager] updateRoom: room 或 roomId 为空");
        return;
    }

    @synchronized(self) {
        BOOL found = NO;
        NSMutableArray *updatedRooms = [[NSMutableArray alloc] init];

        for (MultiplayerRoom *existing in self.internalRooms) {
            if ([existing.roomId isEqualToString:room.roomId]) {
                // 替换为新数据
                [updatedRooms addObject:room];
                found = YES;
            } else {
                [updatedRooms addObject:existing];
            }
        }

        if (!found) {
            NSLog(@"[MultiplayerManager] updateRoom: 未找到 roomId：%@", room.roomId);
            return;
        }

        self.internalRooms = updatedRooms;

        // 按 createdAt 降序排序
        [self sortRoomsByCreatedAt];

        // 如果更新的是当前连接的房间，同步更新 currentRoom 引用
        if (self.currentRoom && [self.currentRoom.roomId isEqualToString:room.roomId]) {
            self.currentRoom = room;
        }
    }

    NSLog(@"[MultiplayerManager] 已更新房间：%@（%@）", room.name, room.roomId);
    [self saveRooms];
}

/// 获取指定 roomId 的房间
///
/// 线性查找（房间数量通常很少，无需哈希索引）。
///
/// @param roomId 房间 ID
/// @return 房间对象，未找到返回 nil
- (nullable MultiplayerRoom *)roomWithId:(NSString *)roomId {
    if (!roomId || roomId.length == 0) {
        return nil;
    }

    @synchronized(self) {
        for (MultiplayerRoom *room in self.internalRooms) {
            if ([room.roomId isEqualToString:roomId]) {
                return room;
            }
        }
    }
    return nil;
}

/// 按 createdAt 降序排序房间列表（最新创建的在前）
/// 如果 createdAt 相同，则按 roomId 字典序排列作为稳定排序的辅助
- (void)sortRoomsByCreatedAt {
    [self.internalRooms sortUsingComparator:^NSComparisonResult(MultiplayerRoom *room1, MultiplayerRoom *room2) {
        NSDate *date1 = room1.createdAt;
        NSDate *date2 = room2.createdAt;

        if (!date1 && !date2) return NSOrderedSame;
        if (!date1) return NSOrderedAscending;  // 无日期的排后面
        if (!date2) return NSOrderedDescending;

        NSComparisonResult result = [date2 compare:date1]; // 降序
        if (result == NSOrderedSame) {
            // createdAt 相同时，按 roomId 字典序，保证稳定排序
            return [room1.roomId compare:room2.roomId];
        }
        return result;
    }];
}

#pragma mark - 连接管理

/// 连接到房间
///
/// 流程：
/// 1. 校验 room 非空
/// 2. 设置 _currentRoom
/// 3. 调用 joinNetwork: 唤起 ZeroTier 加入网络
/// 4. 更新房间状态为 Connecting
/// 5. 更新 lastConnectedAt 为当前时间
/// 6. 同步更新 savedRooms 中对应房间的状态
/// 7. completion 回调 YES（实际的 ZeroTier 网络连接状态由 ZeroTier app 管理，
///    启动器无法实时获知，因此这里总是回调成功）
///
/// @param room       房间对象
/// @param completion 完成回调（主线程）
- (void)connectToRoom:(MultiplayerRoom *)room
           completion:(void (^)(BOOL success, NSError * _Nullable error))completion {
    if (!room) {
        if (completion) {
            NSError *error = [NSError errorWithDomain:kMultiplayerErrorDomain
                                                 code:MultiplayerErrorCodeInvalidRoom
                                             userInfo:@{NSLocalizedDescriptionKey: @"房间对象为空"}];
            dispatch_async(dispatch_get_main_queue(), ^{
                completion(NO, error);
            });
        }
        return;
    }

    if (!room.networkId || room.networkId.length == 0) {
        if (completion) {
            NSError *error = [NSError errorWithDomain:kMultiplayerErrorDomain
                                                 code:MultiplayerErrorCodeInvalidNetworkId
                                             userInfo:@{NSLocalizedDescriptionKey: @"房间的 Network ID 为空"}];
            dispatch_async(dispatch_get_main_queue(), ^{
                completion(NO, error);
            });
        }
        return;
    }

    NSLog(@"[MultiplayerManager] 开始连接房间：%@（Network ID: %@）", room.name, room.networkId);

    // 1. 设置当前房间
    self.currentRoom = room;

    // 2. 更新房间状态为连接中
    room.status = MultiplayerRoomStatusConnecting;

    // 3. 更新上次连接时间
    room.lastConnectedAt = [NSDate date];

    // 4. 同步更新 savedRooms 中对应房间的状态和时间
    @synchronized(self) {
        for (NSUInteger i = 0; i < self.internalRooms.count; i++) {
            MultiplayerRoom *existing = self.internalRooms[i];
            if ([existing.roomId isEqualToString:room.roomId]) {
                existing.status = room.status;
                existing.lastConnectedAt = room.lastConnectedAt;
                break;
            }
        }
    }

    // 5. 唤起 ZeroTier 加入网络
    [self joinNetwork:room.networkId];

    // 6. 持久化（保存状态更新）
    [self saveRooms];

    // 7. 回调成功
    // 注意：实际的 ZeroTier 网络连接状态由 ZeroTier app 管理，启动器无法实时获知。
    // 这里回调 YES 仅表示"已成功唤起 ZeroTier app 并发起加入网络请求"。
    NSLog(@"[MultiplayerManager] 已发起连接请求，ZeroTier app 连接状态需用户在 ZeroTier app 内确认");
    if (completion) {
        dispatch_async(dispatch_get_main_queue(), ^{
            completion(YES, nil);
        });
    }
}

/// 断开当前房间连接
///
/// 流程：
/// 1. 如果 currentRoom 为空，直接返回
/// 2. 调用 leaveNetwork: 唤起 ZeroTier 离开网络
/// 3. 更新房间状态为 Disconnected
/// 4. 同步更新 savedRooms 中对应房间的状态
/// 5. 清空 _currentRoom
/// 6. 持久化
- (void)disconnectCurrentRoom {
    if (!self.currentRoom) {
        NSLog(@"[MultiplayerManager] disconnectCurrentRoom: 当前没有连接的房间");
        return;
    }

    MultiplayerRoom *room = self.currentRoom;
    NSString *networkId = room.networkId;

    NSLog(@"[MultiplayerManager] 断开房间连接：%@（Network ID: %@）", room.name, networkId);

    // 1. 唤起 ZeroTier 离开网络
    if (networkId && networkId.length > 0) {
        [self leaveNetwork:networkId];
    }

    // 2. 更新房间状态为已断开
    room.status = MultiplayerRoomStatusDisconnected;

    // 3. 同步更新 savedRooms 中对应房间的状态
    @synchronized(self) {
        for (MultiplayerRoom *existing in self.internalRooms) {
            if ([existing.roomId isEqualToString:room.roomId]) {
                existing.status = MultiplayerRoomStatusDisconnected;
                break;
            }
        }
    }

    // 4. 清空当前房间引用
    self.currentRoom = nil;

    // 5. 持久化
    [self saveRooms];

    NSLog(@"[MultiplayerManager] 已断开房间连接");
}

#pragma mark - 分享功能

/// 生成房间的分享文本
///
/// 生成格式化的分享文本，包含房间名称、ZeroTier Network ID、服务器地址，
/// 以及简要的联机步骤说明。用户可将此文本通过微信/QQ/iMessage 等渠道发送给好友。
///
/// 格式示例：
///   🎮 来联机吧！
///   房间名称：xxx 的世界
///   ZeroTier网络ID：1a2b3c4d5e6f7788
///   服务器地址：10.147.17.1:25565
///
///   1. 安装 ZeroTier One app
///   2. 加入网络ID：1a2b3c4d5e6f7788
///   3. 在MC中添加服务器：10.147.17.1:25565
///
/// @param room 房间对象
/// @return 分享文本
- (NSString *)shareTextForRoom:(MultiplayerRoom *)room {
    if (!room) {
        return @"";
    }

    NSString *name = room.name ?: @"未命名房间";
    NSString *networkId = room.networkId ?: @"";
    NSString *hostIP = room.hostIP ?: @"未知";
    NSString *hostPort = room.hostPort ?: kDefaultMCPort;

    // 构造服务器地址（IP:端口）
    NSString *serverAddress = [NSString stringWithFormat:@"%@:%@", hostIP, hostPort];

    // 使用 stringWithFormat 拼接分享文本
    // 注意换行符使用 \n，在大部分聊天软件中都能正确显示
    NSMutableString *text = [NSMutableString string];

    [text appendString:kShareHeaderLine];
    [text appendString:@"\n"];

    [text appendString:kShareRoomNamePrefix];
    [text appendString:name];
    [text appendString:@"\n"];

    [text appendString:kShareNetworkIdPrefix];
    [text appendString:networkId];
    [text appendString:@"\n"];

    [text appendString:kShareServerAddressPrefix];
    [text appendString:serverAddress];
    [text appendString:@"\n"];

    [text appendString:@"\n"];
    [text appendString:@"1. 安装 ZeroTier One app\n"];
    [text appendFormat:@"2. 加入网络ID：%@\n", networkId];
    [text appendFormat:@"3. 在MC中添加服务器：%@", serverAddress];

    return [text copy];
}

/// 从分享文本解析房间信息
///
/// 使用正则表达式从分享文本中提取：
/// - 房间名称（"房间名称：" 后的内容）
/// - ZeroTier Network ID（"ZeroTier网络ID：" 后的 16 位十六进制）
/// - 服务器地址（"服务器地址：" 后的 IP:端口）
///
/// 为了提高兼容性，解析逻辑做了以下增强：
/// 1. 支持中英文冒号（：和 :）
/// 2. Network ID 容忍大小写
/// 3. 服务器地址支持只写 IP（端口默认 25565）
/// 4. 如果文本中没有明确的标记前缀，尝试直接匹配 16 位十六进制作为 Network ID
///
/// @param text 分享文本
/// @return 解析出的房间对象（解析失败返回 nil）
- (nullable MultiplayerRoom *)parseRoomFromShareText:(NSString *)text {
    if (!text || text.length == 0) {
        return nil;
    }

    NSString *roomName = nil;
    NSString *networkId = nil;
    NSString *hostIP = nil;
    NSString *hostPort = nil;

    // 按行分割文本，逐行解析
    NSArray<NSString *> *lines = [text componentsSeparatedByString:@"\n"];

    // ========== 1. 逐行匹配带前缀的字段 ==========

    // 房间名称正则：匹配 "房间名称" 后跟可选的冒号（中英文）和空白，然后捕获后面的内容
    // 支持：房间名称：xxx / 房间名称: xxx / 房间名称xxx
    NSRegularExpression *nameRegex = [NSRegularExpression
        regularExpressionWithPattern:@"房间名称[：:]?\\s*(.+)"
                             options:NSRegularExpressionCaseInsensitive
                               error:nil];

    // Network ID 正则：匹配 "ZeroTier网络ID" 后跟可选的冒号和空白，然后捕获 16 位十六进制
    // 支持：ZeroTier网络ID：1a2b3c4d5e6f7788 / ZeroTier网络ID: 1a2b3c4d5e6f7788
    // 也兼容 "网络ID"、"Network ID" 等变体
    NSRegularExpression *networkIdRegex = [NSRegularExpression
        regularExpressionWithPattern:@"(?:ZeroTier网络ID|网络ID|Network\\s*ID)[：:]?\\s*([0-9a-fA-F]{16})"
                             options:NSRegularExpressionCaseInsensitive
                               error:nil];

    // 服务器地址正则：匹配 "服务器地址" 后跟可选的冒号和空白，然后捕获 IP:端口 或 IP
    // 支持：服务器地址：10.147.17.1:25565 / 服务器地址: 10.147.17.1
    NSRegularExpression *addressRegex = [NSRegularExpression
        regularExpressionWithPattern:@"服务器地址[：:]?\\s*([0-9]{1,3}\\.[0-9]{1,3}\\.[0-9]{1,3}\\.[0-9]{1,3})(?::([0-9]{1,5}))?"
                             options:0
                               error:nil];

    for (NSString *line in lines) {
        NSString *trimmedLine = [line stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
        if (trimmedLine.length == 0) continue;

        // 尝试匹配房间名称
        if (!roomName) {
            NSTextCheckingResult *nameMatch = [nameRegex firstMatchInString:trimmedLine
                                                                   options:0
                                                                     range:NSMakeRange(0, trimmedLine.length)];
            if (nameMatch && nameMatch.numberOfRanges >= 2) {
                roomName = [trimmedLine substringWithRange:[nameMatch rangeAtIndex:1]];
                roomName = [roomName stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
            }
        }

        // 尝试匹配 Network ID
        if (!networkId) {
            NSTextCheckingResult *networkMatch = [networkIdRegex firstMatchInString:trimmedLine
                                                                            options:0
                                                                              range:NSMakeRange(0, trimmedLine.length)];
            if (networkMatch && networkMatch.numberOfRanges >= 2) {
                networkId = [trimmedLine substringWithRange:[networkMatch rangeAtIndex:1]];
                // 统一转为小写
                networkId = [networkId lowercaseString];
            }
        }

        // 尝试匹配服务器地址
        if (!hostIP) {
            NSTextCheckingResult *addressMatch = [addressRegex firstMatchInString:trimmedLine
                                                                          options:0
                                                                            range:NSMakeRange(0, trimmedLine.length)];
            if (addressMatch && addressMatch.numberOfRanges >= 2) {
                hostIP = [trimmedLine substringWithRange:[addressMatch rangeAtIndex:1]];
                // 如果有端口号（第 3 个捕获组）
                if (addressMatch.numberOfRanges >= 3) {
                    NSRange portRange = [addressMatch rangeAtIndex:2];
                    if (portRange.location != NSNotFound && portRange.length > 0) {
                        hostPort = [trimmedLine substringWithRange:portRange];
                    }
                }
            }
        }
    }

    // ========== 2. 兜底：如果未匹配到 Network ID，尝试在整个文本中直接搜索 16 位十六进制 ==========

    if (!networkId) {
        // 直接匹配独立的 16 位十六进制字符串
        NSRegularExpression *rawHexRegex = [NSRegularExpression
            regularExpressionWithPattern:@"\\b([0-9a-fA-F]{16})\\b"
                                 options:0
                                   error:nil];
        NSTextCheckingResult *rawHexMatch = [rawHexRegex firstMatchInString:text
                                                                   options:0
                                                                     range:NSMakeRange(0, text.length)];
        if (rawHexMatch && rawHexMatch.numberOfRanges >= 2) {
            networkId = [[text substringWithRange:[rawHexMatch rangeAtIndex:1]] lowercaseString];
        }
    }

    // ========== 3. 兜底：如果未匹配到服务器地址，尝试在整个文本中搜索 IP:端口 ==========

    if (!hostIP) {
        // 直接匹配 IP:端口
        NSRegularExpression *rawAddressRegex = [NSRegularExpression
            regularExpressionWithPattern:@"([0-9]{1,3}\\.[0-9]{1,3}\\.[0-9]{1,3}\\.[0-9]{1,3})(?::([0-9]{1,5}))?"
                                 options:0
                                   error:nil];
        NSTextCheckingResult *rawAddressMatch = [rawAddressRegex firstMatchInString:text
                                                                           options:0
                                                                             range:NSMakeRange(0, text.length)];
        if (rawAddressMatch && rawAddressMatch.numberOfRanges >= 2) {
            hostIP = [text substringWithRange:[rawAddressMatch rangeAtIndex:1]];
            if (rawAddressMatch.numberOfRanges >= 3) {
                NSRange portRange = [rawAddressMatch rangeAtIndex:2];
                if (portRange.location != NSNotFound && portRange.length > 0) {
                    hostPort = [text substringWithRange:portRange];
                }
            }
        }
    }

    // ========== 4. 校验解析结果 ==========

    // Network ID 是必须的，没有则解析失败
    if (!networkId || networkId.length != 16) {
        NSLog(@"[MultiplayerManager] 解析分享文本失败：Network ID 无效或缺失");
        return nil;
    }

    // 进一步校验 Network ID 格式
    if (![self isValidNetworkId:networkId]) {
        NSLog(@"[MultiplayerManager] 解析分享文本失败：Network ID 格式校验未通过：%@", networkId);
        return nil;
    }

    // 如果没有房间名称，使用默认值
    if (!roomName || roomName.length == 0) {
        roomName = @"导入的房间";
    }

    // 如果没有端口，使用默认值
    if (!hostPort || hostPort.length == 0) {
        hostPort = kDefaultMCPort;
    }

    // 如果没有 IP，可以只用 Network ID 创建房间（用户后续可手动补充）
    if (!hostIP) {
        hostIP = @"";
        NSLog(@"[MultiplayerManager] 解析分享文本：未找到服务器 IP，用户需后续手动补充");
    }

    // ========== 5. 构造房间对象 ==========

    MultiplayerRoom *room = [[MultiplayerRoom alloc] initWithId:nil
                                                            name:roomName
                                                       networkId:networkId
                                                          hostIP:hostIP
                                                        hostPort:hostPort];
    room.roomDescription = @"从分享文本导入";
    room.status = MultiplayerRoomStatusDisconnected;

    NSLog(@"[MultiplayerManager] 成功解析分享文本：name=%@, networkId=%@, host=%@:%@",
          roomName, networkId, hostIP, hostPort);

    return room;
}

#pragma mark - 辅助方法

/// 生成新的房间 ID（UUID 字符串）
/// 使用 NSUUID 生成大写的 UUID 字符串，如 "E621E1F8-C36C-495A-93BC-8C9C2E1F1B66"
/// @return UUID 字符串
- (NSString *)generateRoomId {
    return [[NSUUID UUID] UUIDString];
}

/// 验证 ZeroTier Network ID 格式
///
/// ZeroTier Network ID 是一个 16 位十六进制字符串（64 位整数），
/// 由 ZeroTier 官方在创建网络时分配。有效的 Network ID 满足：
/// 1. 长度恰好为 16 个字符
/// 2. 每个字符都是 0-9 或 a-f（不区分大小写）
/// 3. 不能全为 0（0x0000000000000000 不是有效网络 ID）
///
/// @param networkId 待校验的 Network ID 字符串
/// @return YES 如果格式有效
- (BOOL)isValidNetworkId:(NSString *)networkId {
    if (!networkId || networkId.length != 16) {
        return NO;
    }

    // 检查每个字符是否为十六进制
    NSCharacterSet *hexCharset = [NSCharacterSet characterSetWithCharactersInString:@"0123456789abcdefABCDEF"];
    for (NSUInteger i = 0; i < networkId.length; i++) {
        unichar ch = [networkId characterAtIndex:i];
        if (![hexCharset characterIsMember:ch]) {
            return NO;
        }
    }

    // 检查是否全为 0（不是有效网络 ID）
    NSString *lowercase = [networkId lowercaseString];
    if ([lowercase isEqualToString:@"0000000000000000"]) {
        return NO;
    }

    return YES;
}

/// 验证 IP 地址格式
///
/// 支持 IPv4 地址格式校验（如 10.147.17.1）。
/// 每段数字范围应在 0-255 之间。
///
/// @param ipAddress 待校验的 IP 地址字符串
/// @return YES 如果格式有效
- (BOOL)isValidIPAddress:(NSString *)ipAddress {
    if (!ipAddress || ipAddress.length == 0) {
        return NO;
    }

    NSArray *components = [ipAddress componentsSeparatedByString:@"."];
    if (components.count != 4) {
        return NO;
    }

    for (NSString *component in components) {
        if (component.length == 0 || component.length > 3) {
            return NO;
        }

        // 检查是否为纯数字
        NSCharacterSet *digitCharset = [NSCharacterSet decimalDigitCharacterSet];
        for (NSUInteger i = 0; i < component.length; i++) {
            unichar ch = [component characterAtIndex:i];
            if (![digitCharset characterIsMember:ch]) {
                return NO;
            }
        }

        // 检查数字范围 0-255
        NSInteger value = [component integerValue];
        if (value < 0 || value > 255) {
            return NO;
        }

        // 检查前导零（如 "01" 是无效的）
        if (component.length > 1 && [component hasPrefix:@"0"]) {
            return NO;
        }
    }

    return YES;
}

@end
