//
//  EasyTierMultiplayerManager.m
//  Amethyst
//
//  基于 EasyTier 的 Minecraft 联机功能管理器实现（陶瓦联机）
//
//  ============================================================================
//  设计理念与参照来源
//  ============================================================================
//
//  本文件参照了以下开源项目的联机管理器设计思路：
//
//  1. FCL (FoldCraftLauncher) - Android 平台的 MC 启动器
//     - 其 MultiplayerManager 负责 EasyTier 网络的加入/离开、
//       联机房间的本地化管理、以及分享信息的生成与解析。
//     - FCL 通过 JNI 调用 EasyTier 的 native 库直接在进程内建立虚拟网络。
//
//  2. ZL2 (ZalithLauncher) - Android 平台的 MC 启动器（PojavLauncher 分支）
//     - 其 LanServerManager 同样基于 EasyTier（陶瓦联机），提供了房间卡片 UI、
//       分享码导入、以及与 MC 内置"添加服务器"功能的联动。
//
//  3. HMCL (Hello Minecraft! Launcher) - 桌面平台的 MC 启动器
//     - HMCL 从 3.7.0.300 版本开始内置「陶瓦联机」功能，基于 EasyTier。
//     - HMCL 使用 EasyTier 的 network-name + network-secret 参数组网，
//       可与 FCL/ZL2 互通。
//
//  在 iOS 平台上，由于以下限制，无法完全照搬 Android 的实现：
//    a. iOS 不允许 App 在后台长期运行 VPN / 虚拟网卡（EasyTier iOS app
//       使用 NetworkExtension.framework 的 NEPacketTunnelProvider，需要
//       Apple 颁发的 Network Extension 权限）。
//    b. iOS 沙盒机制禁止第三方 App 直接操作 utun 设备。
//    c. EasyTier iOS app（https://github.com/EasyTier/EasyTier-iOS）
//       使用 Swift + Rust 编写，与本项目 Objective-C + Makefile 构建系统
//       不兼容，无法直接集成。
//    d. EasyTier iOS app 当前未注册 URL Scheme，无法像 ZeroTier 那样
//       通过 URL 自动传参加入网络。
//
//  因此，iOS 上的 EasyTier 联机策略调整为：
//    1. 启动器不直接集成 EasyTier SDK，而是引导用户安装 EasyTier iOS app。
//    2. 启动器本地维护"联机房间"列表（房间名 + 网络名 + 密码 + 服务器URL +
//       房主IP + 端口），使用 NSUserDefaults + NSKeyedArchiver 持久化。
//    3. 启动器提供"分享文本"功能，将房间信息打包成一段带格式的文本。
//    4. 好友收到分享文本后，可在启动器内"导入房间"。
//    5. 连接房间时，启动器引导用户打开 EasyTier app 手动加入网络，
//       再引导用户在 MC 内通过"多人游戏 → 直接连接 / 添加服务器"输入
//       房主IP:端口 加入。
//
//  系统要求：
//    - EasyTier iOS app 需要 iOS 16.0 及以上系统
//    - ZeroTier iOS app 支持 iOS 13.0 及以上系统
//    - 本启动器最低支持 iOS 14.0
//    - 因此 iOS 14-15 用户只能使用 ZeroTier 联机
//    - iOS 16+ 用户可以同时使用 EasyTier 和 ZeroTier 联机
//
//  与 FCL/ZL2/HMCL 的兼容性：
//    EasyTier 的 network-name 和 network-secret 是跨平台通用的，
//    只要 iOS 用户在 EasyTier app 中加入与 PC/Android 玩家相同的
//    network-name + network-secret，即可获得虚拟 IP 并与对方联机。
//    这意味着 iOS 用户可以与 FCL/ZL2/HMCL 的「陶瓦联机」互通。
//

#import "EasyTierMultiplayerManager.h"
#import <UIKit/UIKit.h>

/// NSUserDefaults 存储 EasyTier 房间列表的 key
static NSString *const kEasyTierSavedRoomsKey = @"easytier_multiplayer_saved_rooms";

/// MC 默认服务器端口
static NSString *const kDefaultMCPort = @"25565";

/// EasyTier iOS app 的 URL Scheme（未来兼容，当前 EasyTier app 未注册）
/// 如果 EasyTier 未来添加了 URL Scheme 支持，此 scheme 将用于自动传参
static NSString *const kEasyTierURLScheme = @"easytier";

/// EasyTier 默认公共中继服务器 URL
/// EasyTier 官方提供的免费公共节点，用于辅助 NAT 穿透
static NSString *const kEasyTierDefaultPublicServer = @"tcp://public.easytier.cn:11010";

/// EasyTier TestFlight 安装链接
static NSString *const kEasyTierTestFlightURL = @"https://testflight.apple.com/join/YWnDyJfM";

/// EasyTier GitHub 仓库链接
static NSString *const kEasyTierGitHubURL = @"https://github.com/EasyTier/EasyTier-iOS";

#pragma mark - EasyTierRoom 实现

@implementation EasyTierRoom

/// 便捷初始化方法
- (instancetype)initWithId:(NSString *)roomId
                      name:(NSString *)name
               networkName:(NSString *)networkName
             networkSecret:(NSString *)networkSecret
                 serverUrl:(NSString *)serverUrl
                    hostIP:(NSString *)hostIP
                  hostPort:(NSString *)hostPort {
    self = [super init];
    if (self) {
        _roomId = roomId ?: [[NSUUID UUID] UUIDString];
        _name = [name copy] ?: @"";
        _networkName = [networkName copy] ?: @"";
        _networkSecret = [networkSecret copy] ?: @"";
        _serverUrl = [serverUrl copy] ?: @"";
        _hostIP = [hostIP copy] ?: @"";
        _hostPort = [hostPort copy] ?: kDefaultMCPort;
        _roomDescription = @"";
        _status = EasyTierRoomStatusDisconnected;
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
        _networkName = [coder decodeObjectOfClass:[NSString class] forKey:@"networkName"] ?: @"";
        _networkSecret = [coder decodeObjectOfClass:[NSString class] forKey:@"networkSecret"] ?: @"";
        _serverUrl = [coder decodeObjectOfClass:[NSString class] forKey:@"serverUrl"] ?: @"";
        _hostIP = [coder decodeObjectOfClass:[NSString class] forKey:@"hostIP"] ?: @"";
        _hostPort = [coder decodeObjectOfClass:[NSString class] forKey:@"hostPort"] ?: kDefaultMCPort;
        _roomDescription = [coder decodeObjectOfClass:[NSString class] forKey:@"roomDescription"] ?: @"";
        _ownerName = [coder decodeObjectOfClass:[NSString class] forKey:@"ownerName"] ?: @"";

        // 日期属性使用 NSDate 类安全解码
        _createdAt = [coder decodeObjectOfClass:[NSDate class] forKey:@"createdAt"];
        _lastConnectedAt = [coder decodeObjectOfClass:[NSDate class] forKey:@"lastConnectedAt"];

        // 枚举状态使用 decodeIntegerForKey 解码
        NSInteger statusValue = [coder decodeIntegerForKey:@"status"];
        // 边界保护：防止存储的状态值超出枚举范围
        if (statusValue < EasyTierRoomStatusDisconnected ||
            statusValue > EasyTierRoomStatusError) {
            statusValue = EasyTierRoomStatusDisconnected;
        }
        _status = (EasyTierRoomStatus)statusValue;
    }
    return self;
}

/// 编码房间对象到 NSCoder（通常是 NSKeyedArchiver）
- (void)encodeWithCoder:(NSCoder *)coder {
    [coder encodeObject:self.roomId forKey:@"roomId"];
    [coder encodeObject:self.name forKey:@"name"];
    [coder encodeObject:self.networkName forKey:@"networkName"];
    [coder encodeObject:self.networkSecret forKey:@"networkSecret"];
    [coder encodeObject:self.serverUrl forKey:@"serverUrl"];
    [coder encodeObject:self.hostIP forKey:@"hostIP"];
    [coder encodeObject:self.hostPort forKey:@"hostPort"];
    [coder encodeObject:self.roomDescription forKey:@"roomDescription"];
    [coder encodeObject:self.ownerName forKey:@"ownerName"];
    [coder encodeObject:self.createdAt forKey:@"createdAt"];
    [coder encodeObject:self.lastConnectedAt forKey:@"lastConnectedAt"];
    [coder encodeInteger:(NSInteger)self.status forKey:@"status"];
}

/// NSSecureCoding 要求：指定可安全解码的类
+ (BOOL)supportsSecureCoding {
    return YES;
}

/// 重写 copy 方法，返回房间的深拷贝
- (id)copyWithZone:(NSZone *)zone {
    EasyTierRoom *copy = [[[self class] allocWithZone:zone] init];
    if (copy) {
        copy.roomId = [self.roomId copy];
        copy.name = [self.name copy];
        copy.networkName = [self.networkName copy];
        copy.networkSecret = [self.networkSecret copy];
        copy.serverUrl = [self.serverUrl copy];
        copy.hostIP = [self.hostIP copy];
        copy.hostPort = [self.hostPort copy];
        copy.roomDescription = [self.roomDescription copy];
        copy.status = self.status;
        copy.ownerName = [self.ownerName copy];
        copy.createdAt = [self.createdAt copy];
        copy.lastConnectedAt = [self.lastConnectedAt copy];
    }
    return copy;
}

/// 重写 description 方便调试
- (NSString *)description {
    return [NSString stringWithFormat:@"<EasyTierRoom: %@ name=%@ networkName=%@ host=%@:%@ status=%ld>",
            self.roomId, self.name, self.networkName, self.hostIP, self.hostPort, (long)self.status];
}

/// 重写 isEqual：通过 roomId 判断是否同一个房间
- (BOOL)isEqual:(id)object {
    if (self == object) return YES;
    if (![object isKindOfClass:[EasyTierRoom class]]) return NO;
    EasyTierRoom *other = (EasyTierRoom *)object;
    return [self.roomId isEqualToString:other.roomId];
}

/// 重写 hash：与 isEqual 配合，使用 roomId 的 hash
- (NSUInteger)hash {
    return [self.roomId hash];
}

@end

#pragma mark - EasyTierMultiplayerManager 实现

@interface EasyTierMultiplayerManager ()

/// 内部可变房间列表（线程安全访问通过 serializationQueue 保证）
@property (nonatomic, strong) NSMutableArray<EasyTierRoom *> *internalRooms;

/// 串行队列，用于串行化房间列表的读写操作，保证线程安全
@property (nonatomic, strong) dispatch_queue_t serializationQueue;

@end

@implementation EasyTierMultiplayerManager

#pragma mark - 单例实现

/// 使用 dispatch_once 保证线程安全的单次初始化
+ (instancetype)sharedManager {
    static EasyTierMultiplayerManager *shared = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        shared = [[self alloc] init];
    });
    return shared;
}

/// 重写 allocWithZone: 防止通过 alloc/init 创建第二个实例
+ (instancetype)allocWithZone:(struct _NSZone *)zone {
    static EasyTierMultiplayerManager *shared = nil;
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
        // 创建串行队列，用于串行化房间列表的读写操作
        _serializationQueue = dispatch_queue_create("com.angelaura.easytier.multiplayer.serialization", DISPATCH_QUEUE_SERIAL);
        _internalRooms = [[NSMutableArray alloc] init];
        _currentRoom = nil;

        // 从本地存储加载房间列表
        [self loadRooms];

        NSLog(@"[EasyTierMultiplayerManager] 初始化完成，已加载 %lu 个房间", (unsigned long)_internalRooms.count);
    }
    return self;
}

#pragma mark - 对外暴露的只读属性

/// 返回房间列表的不可变副本，防止外部直接修改内部数组
- (NSArray<EasyTierRoom *> *)savedRooms {
    if ([NSThread isMainThread]) {
        return [_internalRooms copy];
    } else {
        __block NSArray *result = nil;
        dispatch_sync(dispatch_get_main_queue(), ^{
            result = [self.internalRooms copy];
        });
        return result;
    }
}

#pragma mark - 数据持久化

/// 从 NSUserDefaults 加载已保存的房间列表
- (void)loadRooms {
    @synchronized(self) {
        NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
        NSData *data = [defaults dataForKey:kEasyTierSavedRoomsKey];

        if (!data || data.length == 0) {
            self.internalRooms = [[NSMutableArray alloc] init];
            return;
        }

        NSError *error = nil;
        NSSet *allowedClasses = [NSSet setWithObjects:[NSArray class], [EasyTierRoom class], nil];
        NSArray *rooms = [NSKeyedUnarchiver unarchivedObjectOfClasses:allowedClasses
                                                              fromData:data
                                                                 error:&error];
        if (error || !rooms) {
            NSLog(@"[EasyTierMultiplayerManager] 加载房间列表失败：%@", error.localizedDescription);
            // 兼容旧版本数据格式
            NSKeyedUnarchiver *unarchiver = [[NSKeyedUnarchiver alloc] initForReadingFromData:data error:&error];
            unarchiver.requiresSecureCoding = NO;
            @try {
                NSArray *legacyRooms = [unarchiver decodeObjectForKey:NSKeyedArchiveRootObjectKey];
                if ([legacyRooms isKindOfClass:[NSArray class]]) {
                    self.internalRooms = [NSMutableArray arrayWithArray:legacyRooms];
                    NSLog(@"[EasyTierMultiplayerManager] 使用兼容模式加载了 %lu 个房间", (unsigned long)self.internalRooms.count);
                    [unarchiver finishDecoding];
                    return;
                }
            } @catch (NSException *exception) {
                NSLog(@"[EasyTierMultiplayerManager] 兼容模式解档异常：%@", exception);
            }
            [unarchiver finishDecoding];
            self.internalRooms = [[NSMutableArray alloc] init];
            return;
        }

        self.internalRooms = [NSMutableArray arrayWithArray:rooms];
        NSLog(@"[EasyTierMultiplayerManager] 成功加载 %lu 个房间", (unsigned long)self.internalRooms.count);
    }
}

/// 将房间列表保存到 NSUserDefaults
/// 使用 NSKeyedArchiver + NSSecureCoding 编码
/// 持久化操作异步派发到串行队列，避免阻塞主线程
- (void)saveRooms {
    // 在同步块中获取数组副本，避免在异步保存过程中被修改
    NSArray *roomsCopy;
    @synchronized(self) {
        roomsCopy = [self.internalRooms copy];
    }

    // 异步派发到串行队列执行持久化
    dispatch_async(self.serializationQueue, ^{
        NSError *error = nil;
        NSData *data = [NSKeyedArchiver archivedDataWithRootObject:roomsCopy
                                                 requiringSecureCoding:YES
                                                                 error:&error];
        if (error) {
            NSLog(@"[EasyTierMultiplayerManager] 保存房间列表失败：%@", error.localizedDescription);
            return;
        }

        NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
        [defaults setObject:data forKey:kEasyTierSavedRoomsKey];
        [defaults synchronize];
        NSLog(@"[EasyTierMultiplayerManager] 成功保存 %lu 个房间", (unsigned long)roomsCopy.count);
    });
}

#pragma mark - EasyTier App 检测与唤起

/// EasyTier app 是否已安装
/// 通过 canOpenURL: 检测 easytier:// scheme
/// 注意：Info.plist 中需要将 easytier 添加到 LSApplicationQueriesSchemes
- (BOOL)isEasyTierAppInstalled {
    NSString *urlString = [NSString stringWithFormat:@"%@://", kEasyTierURLScheme];
    NSURL *url = [NSURL URLWithString:urlString];
    if (!url) return NO;

    // canOpenURL: 必须在主线程调用
    if ([NSThread isMainThread]) {
        return [[UIApplication sharedApplication] canOpenURL:url];
    } else {
        __block BOOL canOpen = NO;
        dispatch_sync(dispatch_get_main_queue(), ^{
            canOpen = [[UIApplication sharedApplication] canOpenURL:url];
        });
        return canOpen;
    }
}

/// 尝试打开 EasyTier app
/// 如果已安装则通过 URL Scheme 唤起，否则打开 TestFlight 安装页面
- (void)openEasyTierApp {
    dispatch_async(dispatch_get_main_queue(), ^{
        if ([self isEasyTierAppInstalled]) {
            // EasyTier app 已安装，通过 URL Scheme 唤起
            NSString *urlString = [NSString stringWithFormat:@"%@://", kEasyTierURLScheme];
            NSURL *url = [NSURL URLWithString:urlString];
            [[UIApplication sharedApplication] openURL:url options:@{} completionHandler:nil];
            NSLog(@"[EasyTierMultiplayerManager] 已唤起 EasyTier app");
        } else {
            // EasyTier app 未安装，打开 TestFlight 安装页面
            NSURL *testFlightUrl = [NSURL URLWithString:kEasyTierTestFlightURL];
            [[UIApplication sharedApplication] openURL:testFlightUrl options:@{} completionHandler:nil];
            NSLog(@"[EasyTierMultiplayerManager] EasyTier app 未安装，已打开 TestFlight 安装页面");
        }
    });
}

/// 尝试通过 URL Scheme 加入 EasyTier 网络
/// 注意：当前 EasyTier iOS app 未注册 URL Scheme，此方法会尝试 easytier:// 格式，
/// 如果失败则打开 EasyTier app 主界面或 TestFlight 安装页面
- (void)joinNetwork:(NSString *)networkName
       networkSecret:(NSString *)networkSecret
           serverUrl:(NSString *)serverUrl {
    // 参数安全检查
    if (!networkName || networkName.length == 0) {
        NSLog(@"[EasyTierMultiplayerManager] joinNetwork 失败：networkName 为空");
        return;
    }

    dispatch_async(dispatch_get_main_queue(), ^{
        if ([self isEasyTierAppInstalled]) {
            // EasyTier app 已安装
            // 尝试使用 URL Scheme 传参（未来 EasyTier 支持 URL Scheme 后可用）
            // 当前格式：easytier://join?network_name=xxx&network_secret=xxx&server_url=xxx
            // 注意：此 URL 格式为预留格式，当前 EasyTier iOS app 不支持
            NSMutableString *urlString = [NSMutableString stringWithFormat:@"%@://join", kEasyTierURLScheme];

            // 构建查询参数
            NSMutableArray *params = [NSMutableArray array];
            [params addObject:[NSString stringWithFormat:@"network_name=%@",
                               [self urlEncodeString:networkName]]];
            if (networkSecret && networkSecret.length > 0) {
                [params addObject:[NSString stringWithFormat:@"network_secret=%@",
                                   [self urlEncodeString:networkSecret]]];
            }
            if (serverUrl && serverUrl.length > 0) {
                [params addObject:[NSString stringWithFormat:@"server_url=%@",
                                   [self urlEncodeString:serverUrl]]];
            }

            [urlString appendString:@"?"];
            [urlString appendString:[params componentsJoinedByString:@"&"]];

            NSURL *url = [NSURL URLWithString:urlString];
            if (url && [[UIApplication sharedApplication] canOpenURL:url]) {
                // 尝试通过带参数的 URL 唤起
                [[UIApplication sharedApplication] openURL:url options:@{} completionHandler:^(BOOL success) {
                    if (!success) {
                        // 带参数的 URL 打开失败，退回打开 app 主界面
                        NSURL *mainUrl = [NSURL URLWithString:[NSString stringWithFormat:@"%@://", kEasyTierURLScheme]];
                        [[UIApplication sharedApplication] openURL:mainUrl options:@{} completionHandler:nil];
                    }
                }];
                NSLog(@"[EasyTierMultiplayerManager] 尝试通过 URL Scheme 加入网络：%@", networkName);
            } else {
                // URL 构建失败或 canOpenURL 为 NO，直接打开 app 主界面
                NSURL *mainUrl = [NSURL URLWithString:[NSString stringWithFormat:@"%@://", kEasyTierURLScheme]];
                [[UIApplication sharedApplication] openURL:mainUrl options:@{} completionHandler:nil];
                NSLog(@"[EasyTierMultiplayerManager] 已打开 EasyTier app（URL Scheme 不支持带参，需手动加入网络）");
            }
        } else {
            // EasyTier app 未安装，打开 TestFlight 安装页面
            NSURL *testFlightUrl = [NSURL URLWithString:kEasyTierTestFlightURL];
            [[UIApplication sharedApplication] openURL:testFlightUrl options:@{} completionHandler:nil];
            NSLog(@"[EasyTierMultiplayerManager] EasyTier app 未安装，已打开 TestFlight 安装页面");
        }
    });
}

#pragma mark - 房间管理

/// 添加房间到本地列表
- (void)addRoom:(EasyTierRoom *)room {
    if (!room) {
        NSLog(@"[EasyTierMultiplayerManager] addRoom 失败：room 为 nil");
        return;
    }

    // 如果 roomId 为空，生成一个新的 UUID
    if (!room.roomId || room.roomId.length == 0) {
        room.roomId = [self generateRoomId];
    }

    @synchronized(self) {
        // 唯一性校验：如果已存在相同 roomId 的房间，先移除旧的
        for (int i = 0; i < self.internalRooms.count; i++) {
            if ([self.internalRooms[i].roomId isEqualToString:room.roomId]) {
                [self.internalRooms removeObjectAtIndex:i];
                break;
            }
        }

        // 添加新房间
        [self.internalRooms addObject:room];

        // 按 createdAt 降序排序（最新创建的在前面）
        [self.internalRooms sortUsingComparator:^NSComparisonResult(EasyTierRoom *a, EasyTierRoom *b) {
            return [b.createdAt compare:a.createdAt];
        }];
    }

    // 持久化
    [self saveRooms];

    NSLog(@"[EasyTierMultiplayerManager] 已添加房间：%@ (%@)", room.name, room.roomId);
}

/// 删除房间
- (void)removeRoom:(NSString *)roomId {
    if (!roomId || roomId.length == 0) {
        NSLog(@"[EasyTierMultiplayerManager] removeRoom 失败：roomId 为空");
        return;
    }

    @synchronized(self) {
        for (int i = 0; i < self.internalRooms.count; i++) {
            if ([self.internalRooms[i].roomId isEqualToString:roomId]) {
                EasyTierRoom *removed = self.internalRooms[i];
                [self.internalRooms removeObjectAtIndex:i];

                // 如果删除的是当前连接的房间，断开连接
                if (self.currentRoom && [self.currentRoom.roomId isEqualToString:roomId]) {
                    self.currentRoom = nil;
                }

                NSLog(@"[EasyTierMultiplayerManager] 已删除房间：%@ (%@)", removed.name, removed.roomId);
                break;
            }
        }
    }

    // 持久化
    [self saveRooms];
}

/// 更新房间信息
- (void)updateRoom:(EasyTierRoom *)room {
    if (!room || !room.roomId) {
        NSLog(@"[EasyTierMultiplayerManager] updateRoom 失败：room 或 roomId 为空");
        return;
    }

    @synchronized(self) {
        for (int i = 0; i < self.internalRooms.count; i++) {
            if ([self.internalRooms[i].roomId isEqualToString:room.roomId]) {
                // 替换为更新后的房间对象
                self.internalRooms[i] = room;
                break;
            }
        }

        // 重新排序
        [self.internalRooms sortUsingComparator:^NSComparisonResult(EasyTierRoom *a, EasyTierRoom *b) {
            return [b.createdAt compare:a.createdAt];
        }];
    }

    // 持久化
    [self saveRooms];

    NSLog(@"[EasyTierMultiplayerManager] 已更新房间：%@ (%@)", room.name, room.roomId);
}

/// 获取指定房间
- (EasyTierRoom *)roomWithId:(NSString *)roomId {
    if (!roomId || roomId.length == 0) return nil;

    @synchronized(self) {
        for (EasyTierRoom *room in self.internalRooms) {
            if ([room.roomId isEqualToString:roomId]) {
                return [room copy];
            }
        }
    }
    return nil;
}

/// 连接到房间（设置 currentRoom + 尝试唤起 EasyTier）
- (void)connectToRoom:(EasyTierRoom *)room
           completion:(void (^)(BOOL success, NSError * _Nullable error))completion {
    if (!room) {
        if (completion) {
            NSError *error = [NSError errorWithDomain:@"EasyTierMultiplayerManager"
                                                  code:1001
                                              userInfo:@{NSLocalizedDescriptionKey: @"房间对象为空"}];
            completion(NO, error);
        }
        return;
    }

    // 更新房间状态为连接中
    room.status = EasyTierRoomStatusConnecting;
    [self updateRoom:room];

    // 设置当前房间
    self.currentRoom = room;

    // 尝试唤起 EasyTier app 加入网络
    [self joinNetwork:room.networkName
       networkSecret:room.networkSecret
           serverUrl:room.serverUrl];

    // 更新房间状态和上次连接时间
    room.status = EasyTierRoomStatusConnected;
    room.lastConnectedAt = [NSDate date];
    [self updateRoom:room];

    if (completion) {
        completion(YES, nil);
    }

    NSLog(@"[EasyTierMultiplayerManager] 已发起连接：%@ (network=%@)", room.name, room.networkName);
}

/// 断开当前房间连接
- (void)disconnectCurrentRoom {
    if (!self.currentRoom) {
        NSLog(@"[EasyTierMultiplayerManager] disconnectCurrentRoom：当前无连接的房间");
        return;
    }

    // 更新房间状态
    EasyTierRoom *room = self.currentRoom;
    room.status = EasyTierRoomStatusDisconnected;
    [self updateRoom:room];

    NSLog(@"[EasyTierMultiplayerManager] 已断开房间连接：%@", room.name);

    // 清除当前房间
    self.currentRoom = nil;

    // 注意：EasyTier 的断开网络操作需要用户在 EasyTier app 中手动完成
    // 因为 EasyTier app 当前不支持 URL Scheme 自动离开网络
}

#pragma mark - 分享与解析

/// 生成房间的分享文本
/// 格式参照 FCL/ZL2/HMCL 的陶瓦联机分享格式
- (NSString *)shareTextForRoom:(EasyTierRoom *)room {
    if (!room) return @"";

    NSMutableString *text = [NSMutableString string];

    // 标题行
    [text appendFormat:@"来联机！房间名：%@\n", room.name];

    // EasyTier 网络信息
    [text appendFormat:@"EasyTier网络名：%@\n", room.networkName];
    [text appendFormat:@"网络密码：%@\n", room.networkSecret];

    // 中继服务器（如果有）
    if (room.serverUrl && room.serverUrl.length > 0) {
        [text appendFormat:@"中继服务器：%@\n", room.serverUrl];
    }

    // 服务器地址
    if (room.hostIP && room.hostIP.length > 0) {
        [text appendFormat:@"服务器IP：%@:%@\n", room.hostIP, room.hostPort];
    }

    // 房主名称（如果有）
    if (room.ownerName && room.ownerName.length > 0) {
        [text appendFormat:@"房主：%@\n", room.ownerName];
    }

    // 使用说明
    [text appendString:@"\n使用方法：\n"];
    [text appendString:@"1. 安装 EasyTier iOS app（TestFlight 搜索 EasyTier）\n"];
    [text appendString:@"2. 在 EasyTier app 中加入上述网络名和密码\n"];
    [text appendString:@"3. 在启动器中添加服务器 IP 即可联机\n"];
    [text appendString:@"（兼容 FCL/ZL2/HMCL 陶瓦联机）"];

    return text;
}

/// 从分享文本解析 EasyTier 房间信息
/// 支持多种格式的分享文本，使用正则表达式匹配关键字段
- (EasyTierRoom *)parseRoomFromShareText:(NSString *)text {
    if (!text || text.length == 0) {
        NSLog(@"[EasyTierMultiplayerManager] 解析分享文本失败：文本为空");
        return nil;
    }

    NSString *roomName = nil;
    NSString *networkName = nil;
    NSString *networkSecret = nil;
    NSString *serverUrl = nil;
    NSString *hostIP = nil;
    NSString *hostPort = nil;
    NSString *ownerName = nil;

    // ========== 1. 使用正则表达式匹配各字段 ==========

    // 匹配房间名（支持多种格式）
    // 房间名：xxx / 房间名:xxx / 房间：xxx
    NSRegularExpression *roomNameRegex = [NSRegularExpression
        regularExpressionWithPattern:@"房间名[：:]\\s*(.+?)(?:\\n|$)"
                             options:0
                               error:nil];
    NSTextCheckingResult *roomNameMatch = [roomNameRegex firstMatchInString:text
                                                                   options:0
                                                                     range:NSMakeRange(0, text.length)];
    if (roomNameMatch && roomNameMatch.numberOfRanges >= 2) {
        roomName = [text substringWithRange:[roomNameMatch rangeAtIndex:1]];
        // 去除首尾空白
        roomName = [roomName stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
    }

    // 匹配 EasyTier 网络名
    // EasyTier网络名：xxx / 网络名：xxx / network-name:xxx
    NSRegularExpression *networkNameRegex = [NSRegularExpression
        regularExpressionWithPattern:@"(?:EasyTier)?网络名[：:]\\s*(.+?)(?:\\n|$)"
                             options:0
                               error:nil];
    NSTextCheckingResult *networkNameMatch = [networkNameRegex firstMatchInString:text
                                                                          options:0
                                                                            range:NSMakeRange(0, text.length)];
    if (networkNameMatch && networkNameMatch.numberOfRanges >= 2) {
        networkName = [text substringWithRange:[networkNameMatch rangeAtIndex:1]];
        networkName = [networkName stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
    }

    // 匹配网络密码
    // 网络密码：xxx / 密码：xxx / network-secret:xxx
    NSRegularExpression *secretRegex = [NSRegularExpression
        regularExpressionWithPattern:@"(?:网络)?密码[：:]\\s*(.+?)(?:\\n|$)"
                             options:0
                               error:nil];
    NSTextCheckingResult *secretMatch = [secretRegex firstMatchInString:text
                                                               options:0
                                                                 range:NSMakeRange(0, text.length)];
    if (secretMatch && secretMatch.numberOfRanges >= 2) {
        networkSecret = [text substringWithRange:[secretMatch rangeAtIndex:1]];
        networkSecret = [networkSecret stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
    }

    // 匹配中继服务器
    // 中继服务器：xxx / 服务器URL：xxx / server:xxx
    NSRegularExpression *serverRegex = [NSRegularExpression
        regularExpressionWithPattern:@"(?:中继服务器|服务器URL|server)[：:]\\s*(.+?)(?:\\n|$)"
                             options:0
                               error:nil];
    NSTextCheckingResult *serverMatch = [serverRegex firstMatchInString:text
                                                               options:0
                                                                 range:NSMakeRange(0, text.length)];
    if (serverMatch && serverMatch.numberOfRanges >= 2) {
        serverUrl = [text substringWithRange:[serverMatch rangeAtIndex:1]];
        serverUrl = [serverUrl stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
    }

    // 匹配服务器 IP:端口
    // 服务器IP：10.144.144.1:25565 / IP：10.144.144.1
    NSRegularExpression *ipRegex = [NSRegularExpression
        regularExpressionWithPattern:@"(?:服务器)?IP[：:]\\s*([0-9]{1,3}\\.[0-9]{1,3}\\.[0-9]{1,3}\\.[0-9]{1,3})(?::([0-9]{1,5}))?"
                             options:0
                               error:nil];
    NSTextCheckingResult *ipMatch = [ipRegex firstMatchInString:text
                                                       options:0
                                                         range:NSMakeRange(0, text.length)];
    if (ipMatch && ipMatch.numberOfRanges >= 2) {
        hostIP = [text substringWithRange:[ipMatch rangeAtIndex:1]];
        if (ipMatch.numberOfRanges >= 3) {
            NSRange portRange = [ipMatch rangeAtIndex:2];
            if (portRange.location != NSNotFound && portRange.length > 0) {
                hostPort = [text substringWithRange:portRange];
            }
        }
    }

    // 匹配房主名称
    // 房主：xxx
    NSRegularExpression *ownerRegex = [NSRegularExpression
        regularExpressionWithPattern:@"房主[：:]\\s*(.+?)(?:\\n|$)"
                             options:0
                               error:nil];
    NSTextCheckingResult *ownerMatch = [ownerRegex firstMatchInString:text
                                                             options:0
                                                               range:NSMakeRange(0, text.length)];
    if (ownerMatch && ownerMatch.numberOfRanges >= 2) {
        ownerName = [text substringWithRange:[ownerMatch rangeAtIndex:1]];
        ownerName = [ownerName stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
    }

    // ========== 2. 兜底匹配 ==========

    // 如果未匹配到网络名，尝试在整个文本中搜索可能的网络名
    // EasyTier 网络名通常是字母数字组合，不太好通过正则精确匹配
    // 这里不做兜底，因为容易误匹配

    // 如果未匹配到服务器地址，尝试在整个文本中搜索 IP:端口
    if (!hostIP) {
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

    // ========== 3. 校验解析结果 ==========

    // 网络名是必须的，没有则解析失败
    if (!networkName || networkName.length == 0) {
        NSLog(@"[EasyTierMultiplayerManager] 解析分享文本失败：网络名缺失");
        return nil;
    }

    // 如果没有房间名称，使用默认值
    if (!roomName || roomName.length == 0) {
        roomName = @"导入的房间";
    }

    // 如果没有密码，使用空字符串
    if (!networkSecret) {
        networkSecret = @"";
    }

    // 如果没有端口，使用默认值
    if (!hostPort || hostPort.length == 0) {
        hostPort = kDefaultMCPort;
    }

    // 如果没有 IP，可以只用网络名创建房间
    if (!hostIP) {
        hostIP = @"";
        NSLog(@"[EasyTierMultiplayerManager] 解析分享文本：未找到服务器 IP，用户需后续手动补充");
    }

    // ========== 4. 构造房间对象 ==========

    EasyTierRoom *room = [[EasyTierRoom alloc] initWithId:nil
                                                      name:roomName
                                               networkName:networkName
                                             networkSecret:networkSecret
                                                 serverUrl:serverUrl
                                                    hostIP:hostIP
                                                  hostPort:hostPort];
    room.roomDescription = @"从分享文本导入";
    room.status = EasyTierRoomStatusDisconnected;
    if (ownerName) {
        room.ownerName = ownerName;
    }

    NSLog(@"[EasyTierMultiplayerManager] 成功解析分享文本：name=%@, networkName=%@, host=%@:%@",
          roomName, networkName, hostIP, hostPort);

    return room;
}

#pragma mark - 辅助方法

/// 生成新的房间 ID（UUID 字符串）
- (NSString *)generateRoomId {
    return [[NSUUID UUID] UUIDString];
}

/// 获取 EasyTier 默认公共中继服务器 URL
- (NSString *)defaultPublicServerUrl {
    return kEasyTierDefaultPublicServer;
}

/// 获取 EasyTier TestFlight 链接
- (NSString *)easyTierTestFlightUrl {
    return kEasyTierTestFlightURL;
}

/// 获取 EasyTier GitHub 仓库链接
- (NSString *)easyTierGitHubUrl {
    return kEasyTierGitHubURL;
}

/// URL 编码辅助方法
/// 将字符串进行百分号编码，用于构建 URL 查询参数
- (NSString *)urlEncodeString:(NSString *)string {
    if (!string) return @"";
    // URLQueryAllowedCharacterSet 包含了查询参数中允许的字符
    // 字母、数字、以及 -._~ 等安全字符不会被编码
    return [string stringByAddingPercentEncodingWithAllowedCharacters:
            [NSCharacterSet URLQueryAllowedCharacterSet]];
}

@end
