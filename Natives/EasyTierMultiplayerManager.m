//
//  EasyTierMultiplayerManager.m
//  Amethyst
//
//  基于 Terracotta（陶瓦联机）Scaffolding-MC 协议的 MC 联机功能管理器
//
//  ============================================================================
//  邀请码格式：U/XXXX-XXXX-XXXX-XXXX
//  ============================================================================
//
//  参照 Terracotta 源码（src/controller/rooms/scaffolding/room.rs）实现，
//  与 HMCL、FCL、ZL2、PCL2 的陶瓦联机完全互通。
//
//  邀请码结构：
//  - U/         固定前缀（2 字符）
//  - XXXX       第 1 组（4 字符）
//  - -          分隔符
//  - XXXX       第 2 组（4 字符）
//  - -          分隔符
//  - XXXX       第 3 组（4 字符）
//  - -          分隔符
//  - XXXX       第 4 组（4 字符）
//  总计：2 + 4*4 + 3 = 21 字符
//
//  字符表（Base-34，排除 I 和 O 避免与 1 和 0 混淆）：
//  0123456789ABCDEFGHJKLMNPQRSTUVWXYZ
//
//  编码算法：
//  1. 生成 128 位随机数 value
//  2. value = value % 34^16（确保能用 16 个 base-34 字符表示）
//  3. value = value - (value % 7)（使 value 能被 7 整除，作为校验和）
//  4. 循环 16 次，每次取 value % 34 作为一位（小端序：第 0 位是最低有效位）
//  5. 在第 4、8、12 位后插入 `-` 分隔符
//  6. 前面加上 `U/` 前缀
//
//  与 EasyTier 参数的对应：
//  - network-name  = "scaffolding-mc-" + 前 8 字符（第 4 位后插 `-`）
//    例如：scaffolding-mc-AABB-CCDD
//  - network-secret = 后 8 字符（第 4 位后插 `-`）
//    例如：EEFF-GGHH
//  - 公共服务器使用硬编码默认值（不在邀请码中编码）
//
//  校验和原理：
//  由于 34 ≡ -1 (mod 7)，所以 34^k ≡ (-1)^k (mod 7)
//  因此 value mod 7 = (d0 - d1 + d2 - d3 + d4 - d5 + ...) mod 7
//  这是一个交替和，可以方便地计算和验证
//
//  系统要求：
//  - EasyTier iOS app 需要 iOS 16.0 及以上系统
//  - ZeroTier iOS app 支持 iOS 13.0 及以上系统
//  - 本启动器最低支持 iOS 14.0
//  - iOS 14-15 用户只能使用 ZeroTier 联机
//  - iOS 16+ 用户可以同时使用 EasyTier 和 ZeroTier 联机
//

#import "EasyTierMultiplayerManager.h"
#import <UIKit/UIKit.h>
#import <Security/Security.h>

/// NSUserDefaults 存储 EasyTier 房间列表的 key
static NSString *const kEasyTierSavedRoomsKey = @"easytier_multiplayer_saved_rooms_v2";

/// MC 默认服务器端口
static NSString *const kDefaultMCPort = @"25565";

/// EasyTier iOS app 的 URL Scheme
static NSString *const kEasyTierURLScheme = @"easytier";

/// EasyTier TestFlight 安装链接
static NSString *const kEasyTierTestFlightURL = @"https://testflight.apple.com/join/YWnDyJfM";

/// EasyTier GitHub 仓库链接
static NSString *const kEasyTierGitHubURL = @"https://github.com/EasyTier/EasyTier-iOS";

/// 房主在 EasyTier 网络中的固定虚拟 IP
static NSString *const kEasyTierHostVirtualIP = @"10.144.144.1";

/// Scaffolding-MC 网络名前缀
static NSString *const kScaffoldingNetworkNamePrefix = @"scaffolding-mc-";

/// Base-34 字符表（排除 I 和 O，避免与 1 和 0 混淆）
/// 索引 0-33 对应字符 '0'-'9', 'A'-'H', 'J'-'N', 'P'-'Z'
static NSString *const kBase34Charset = @"0123456789ABCDEFGHJKLMNPQRSTUVWXYZ";

/// Terracotta 默认公共服务器列表（硬编码，不在邀请码中编码）
static NSArray<NSString *> *kDefaultPublicServers = nil;

#pragma mark - EasyTierRoom 实现

@implementation EasyTierRoom

/// 房主模式便捷初始化：生成新的邀请码
- (instancetype)initAsHostWithName:(NSString *)name
                          hostPort:(NSString *)hostPort {
    self = [super init];
    if (self) {
        _roomId = [[NSUUID UUID] UUIDString];
        _name = [name copy] ?: @"联机房间";
        _hostPort = [hostPort copy] ?: kDefaultMCPort;
        _role = EasyTierRoomRoleHost;
        _hostIP = kEasyTierHostVirtualIP;
        _status = EasyTierRoomStatusDisconnected;
        _ownerName = @"";
        _createdAt = [NSDate date];
        _lastConnectedAt = nil;

        // 生成邀请码并解析出 network-name 和 network-secret
        EasyTierMultiplayerManager *mgr = [EasyTierMultiplayerManager sharedManager];
        _invitationCode = [mgr generateInvitationCode];
        NSDictionary *parsed = [mgr parseInvitationCode:_invitationCode];
        if (parsed) {
            _networkName = parsed[@"networkName"];
            _networkSecret = parsed[@"networkSecret"];
        } else {
            _networkName = @"";
            _networkSecret = @"";
        }
    }
    return self;
}

/// 房客模式便捷初始化：从邀请码解析
- (instancetype)initAsGuestWithName:(NSString *)name
                      invitationCode:(NSString *)invitationCode {
    self = [super init];
    if (self) {
        EasyTierMultiplayerManager *mgr = [EasyTierMultiplayerManager sharedManager];

        // 验证邀请码
        if (![mgr isValidInvitationCode:invitationCode]) {
            NSLog(@"[EasyTierRoom] 邀请码无效：%@", invitationCode);
            return nil;
        }

        _roomId = [[NSUUID UUID] UUIDString];
        _name = [name copy] ?: @"加入的房间";
        _invitationCode = [invitationCode copy];
        _role = EasyTierRoomRoleGuest;
        _hostIP = kEasyTierHostVirtualIP; // 房主的 IP 固定
        _hostPort = kDefaultMCPort;
        _status = EasyTierRoomStatusDisconnected;
        _ownerName = @"";
        _createdAt = [NSDate date];
        _lastConnectedAt = nil;

        // 从邀请码解析 network-name 和 network-secret
        NSDictionary *parsed = [mgr parseInvitationCode:invitationCode];
        if (parsed) {
            _networkName = parsed[@"networkName"];
            _networkSecret = parsed[@"networkSecret"];
        } else {
            NSLog(@"[EasyTierRoom] 邀请码解析失败：%@", invitationCode);
            return nil;
        }
    }
    return self;
}

#pragma mark - NSSecureCoding / NSCoding

- (instancetype)initWithCoder:(NSCoder *)coder {
    self = [super init];
    if (self) {
        _roomId = [coder decodeObjectOfClass:[NSString class] forKey:@"roomId"] ?: @"";
        _name = [coder decodeObjectOfClass:[NSString class] forKey:@"name"] ?: @"";
        _invitationCode = [coder decodeObjectOfClass:[NSString class] forKey:@"invitationCode"] ?: @"";
        _networkName = [coder decodeObjectOfClass:[NSString class] forKey:@"networkName"] ?: @"";
        _networkSecret = [coder decodeObjectOfClass:[NSString class] forKey:@"networkSecret"] ?: @"";
        _hostIP = [coder decodeObjectOfClass:[NSString class] forKey:@"hostIP"] ?: @"";
        _hostPort = [coder decodeObjectOfClass:[NSString class] forKey:@"hostPort"] ?: kDefaultMCPort;
        _ownerName = [coder decodeObjectOfClass:[NSString class] forKey:@"ownerName"] ?: @"";
        _createdAt = [coder decodeObjectOfClass:[NSDate class] forKey:@"createdAt"];
        _lastConnectedAt = [coder decodeObjectOfClass:[NSDate class] forKey:@"lastConnectedAt"];

        NSInteger roleValue = [coder decodeIntegerForKey:@"role"];
        if (roleValue < EasyTierRoomRoleHost || roleValue > EasyTierRoomRoleGuest) {
            roleValue = EasyTierRoomRoleGuest;
        }
        _role = (EasyTierRoomRole)roleValue;

        NSInteger statusValue = [coder decodeIntegerForKey:@"status"];
        if (statusValue < EasyTierRoomStatusDisconnected || statusValue > EasyTierRoomStatusError) {
            statusValue = EasyTierRoomStatusDisconnected;
        }
        _status = (EasyTierRoomStatus)statusValue;
    }
    return self;
}

- (void)encodeWithCoder:(NSCoder *)coder {
    [coder encodeObject:self.roomId forKey:@"roomId"];
    [coder encodeObject:self.name forKey:@"name"];
    [coder encodeObject:self.invitationCode forKey:@"invitationCode"];
    [coder encodeObject:self.networkName forKey:@"networkName"];
    [coder encodeObject:self.networkSecret forKey:@"networkSecret"];
    [coder encodeObject:self.hostIP forKey:@"hostIP"];
    [coder encodeObject:self.hostPort forKey:@"hostPort"];
    [coder encodeObject:self.ownerName forKey:@"ownerName"];
    [coder encodeObject:self.createdAt forKey:@"createdAt"];
    [coder encodeObject:self.lastConnectedAt forKey:@"lastConnectedAt"];
    [coder encodeInteger:(NSInteger)self.role forKey:@"role"];
    [coder encodeInteger:(NSInteger)self.status forKey:@"status"];
}

+ (BOOL)supportsSecureCoding {
    return YES;
}

- (id)copyWithZone:(NSZone *)zone {
    EasyTierRoom *copy = [[[self class] allocWithZone:zone] init];
    if (copy) {
        copy.roomId = [self.roomId copy];
        copy.name = [self.name copy];
        copy.invitationCode = [self.invitationCode copy];
        copy.networkName = [self.networkName copy];
        copy.networkSecret = [self.networkSecret copy];
        copy.hostIP = [self.hostIP copy];
        copy.hostPort = [self.hostPort copy];
        copy.role = self.role;
        copy.status = self.status;
        copy.ownerName = [self.ownerName copy];
        copy.createdAt = [self.createdAt copy];
        copy.lastConnectedAt = [self.lastConnectedAt copy];
    }
    return copy;
}

- (NSString *)description {
    return [NSString stringWithFormat:@"<EasyTierRoom: %@ name=%@ code=%@ role=%ld status=%ld>",
            self.roomId, self.name, self.invitationCode, (long)self.role, (long)self.status];
}

- (BOOL)isEqual:(id)object {
    if (self == object) return YES;
    if (![object isKindOfClass:[EasyTierRoom class]]) return NO;
    EasyTierRoom *other = (EasyTierRoom *)object;
    return [self.roomId isEqualToString:other.roomId];
}

- (NSUInteger)hash {
    return [self.roomId hash];
}

@end

#pragma mark - EasyTierMultiplayerManager 实现

@interface EasyTierMultiplayerManager ()

@property (nonatomic, strong) NSMutableArray<EasyTierRoom *> *internalRooms;
@property (nonatomic, strong) dispatch_queue_t serializationQueue;

// 在 class extension 中将 currentRoom 重新声明为 readwrite，
// 以便在实现内部赋值（头文件中对外暴露为 readonly）
@property (nonatomic, strong, readwrite, nullable) EasyTierRoom *currentRoom;

@end

@implementation EasyTierMultiplayerManager

#pragma mark - 单例实现

+ (instancetype)sharedManager {
    static EasyTierMultiplayerManager *shared = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        shared = [[self alloc] init];
    });
    return shared;
}

+ (instancetype)allocWithZone:(struct _NSZone *)zone {
    static EasyTierMultiplayerManager *shared = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        shared = [super allocWithZone:zone];
    });
    return shared;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _serializationQueue = dispatch_queue_create("com.angelaura.easytier.multiplayer.serialization", DISPATCH_QUEUE_SERIAL);
        _internalRooms = [[NSMutableArray alloc] init];
        _currentRoom = nil;

        // 初始化默认公共服务器列表
        kDefaultPublicServers = @[
            @"tcp://public.easytier.top:11010",
            @"tcp://public2.easytier.cn:54321",
            @"https://etnode.zkitefly.eu.org/node1",
            @"https://etnode.zkitefly.eu.org/node2"
        ];

        [self loadRooms];
        NSLog(@"[EasyTierMultiplayerManager] 初始化完成，已加载 %lu 个房间", (unsigned long)_internalRooms.count);
    }
    return self;
}

#pragma mark - 对外暴露的只读属性

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

#pragma mark - 邀请码生成与解析

/// Base-34 字符转数值
/// 字符表：0123456789ABCDEFGHJKLMNPQRSTUVWXYZ
/// 容错：I→1, O→0
- (NSInteger)charToDigit:(unichar)c {
    // 容错处理：I→1, O→0
    if (c == 'I' || c == 'i') c = '1';
    if (c == 'O' || c == 'o') c = '0';

    // 转大写
    if (c >= 'a' && c <= 'z') c = c - 'a' + 'A';

    if (c >= '0' && c <= '9') return c - '0';
    if (c >= 'A' && c <= 'H') return c - 'A' + 10;  // A-H → 10-17
    if (c >= 'J' && c <= 'N') return c - 'J' + 18;  // J-N → 18-22 (跳过 I)
    if (c >= 'P' && c <= 'Z') return c - 'P' + 23;  // P-Z → 23-33 (跳过 O)

    return -1; // 非法字符
}

/// 数值转 Base-34 字符
- (unichar)digitToChar:(NSInteger)digit {
    if (digit < 0 || digit >= 34) return '?';
    return [kBase34Charset characterAtIndex:digit];
}

/// 生成新的邀请码（U/XXXX-XXXX-XXXX-XXXX 格式）
///
/// 算法参照 Terracotta 源码 room.rs 的 create_room() 和 from_value()：
/// 1. 生成 16 个随机 base-34 数字
/// 2. 计算当前值的 mod 7（使用交替和：d0 - d1 + d2 - d3 + ...）
/// 3. 调整最后一个数字使总和能被 7 整除
/// 4. 编码为字符串
- (NSString *)generateInvitationCode {
    // 生成 16 个随机 base-34 数字（0-33）
    NSInteger digits[16];
    for (int i = 0; i < 16; i++) {
        digits[i] = arc4random_uniform(34);
    }

    // 计算交替和 mod 7
    // 由于 34 ≡ -1 (mod 7)，所以 34^k ≡ (-1)^k (mod 7)
    // value mod 7 = (d0 * 1 + d1 * (-1) + d2 * 1 + d3 * (-1) + ...) mod 7
    //             = (d0 - d1 + d2 - d3 + d4 - d5 + ...) mod 7
    NSInteger mod7 = 0;
    for (int i = 0; i < 16; i++) {
        if (i % 2 == 0) {
            mod7 = (mod7 + digits[i]) % 7;
        } else {
            mod7 = (mod7 - digits[i] % 7 + 7) % 7;
        }
    }

    // 调整最后一个数字（d15）使 value mod 7 == 0
    // d15 对 mod 7 的贡献是 -d15（因为位置 15 是奇数，符号为负）
    // 需要 (mod7 - d15) ≡ 0 (mod 7)
    // 即 d15 ≡ mod7 (mod 7)
    // 保持 d15 在 [0, 33] 范围内，选择最接近原值的合法值
    NSInteger neededMod7 = mod7;
    NSInteger currentMod7 = digits[15] % 7;
    NSInteger diff = (neededMod7 - currentMod7 + 7) % 7;
    digits[15] = digits[15] + diff;
    if (digits[15] >= 34) {
        digits[15] -= 7;
    }

    // 构建邀请码字符串
    // 格式：U/v0v1v2v3-v4v5v6v7-v8v9v10v11-v12v13v14v15
    NSMutableString *code = [NSMutableString stringWithString:@"U/"];
    for (int i = 0; i < 16; i++) {
        if (i == 4 || i == 8 || i == 12) {
            [code appendString:@"-"];
        }
        [code appendFormat:@"%C", (unsigned short)[self digitToChar:digits[i]]];
    }

    return code;
}

/// 从邀请码解析出网络名和网络密码
/// @param invitationCode 邀请码（U/XXXX-XXXX-XXXX-XXXX）
/// @return 包含 networkName 和 networkSecret 的字典（解析失败返回 nil）
- (NSDictionary<NSString *, NSString *> *)parseInvitationCode:(NSString *)invitationCode {
    if (!invitationCode || invitationCode.length == 0) return nil;

    // 转大写
    NSString *upperCode = [invitationCode uppercaseString];

    // 邀请码格式：U/XXXX-XXXX-XXXX-XXXX
    // 总长度 21 字符
    NSString *prefix = @"U/";
    NSString *bodyPattern = @"XXXX-XXXX-XXXX-XXXX"; // 19 字符

    // 滑动窗口搜索 U/ 前缀
    NSUInteger prefixLen = prefix.length;
    NSUInteger bodyLen = bodyPattern.length; // 19

    for (NSUInteger start = 0; start + prefixLen + bodyLen <= upperCode.length; start++) {
        // 检查前缀
        NSString *checkPrefix = [upperCode substringWithRange:NSMakeRange(start, prefixLen)];
        if (![checkPrefix isEqualToString:prefix]) continue;

        // 提取 body（19 字符）
        NSString *body = [upperCode substringWithRange:NSMakeRange(start + prefixLen, bodyLen)];

        // 验证格式：第 4、9、14 位为 `-`，其余为 base-34 字符
        NSMutableArray *digits = [NSMutableArray arrayWithCapacity:16];
        BOOL formatValid = YES;

        for (NSUInteger i = 0; i < bodyLen; i++) {
            unichar c = [body characterAtIndex:i];
            if (i == 4 || i == 9 || i == 14) {
                // 分隔符位置
                if (c != '-') {
                    formatValid = NO;
                    break;
                }
            } else {
                // 数据字符位置
                NSInteger digit = [self charToDigit:c];
                if (digit < 0) {
                    formatValid = NO;
                    break;
                }
                [digits addObject:@(digit)];
            }
        }

        if (!formatValid || digits.count != 16) continue;

        // 验证校验和：value mod 7 == 0
        // 使用交替和：d0 - d1 + d2 - d3 + ...
        NSInteger mod7 = 0;
        for (int i = 0; i < 16; i++) {
            NSInteger d = [digits[i] integerValue];
            if (i % 2 == 0) {
                mod7 = (mod7 + d % 7) % 7;
            } else {
                mod7 = (mod7 - d % 7 + 7) % 7;
            }
        }

        if (mod7 != 0) continue; // 校验和失败

        // 解析成功，构建 network-name 和 network-secret
        // 前 8 字符 → network-name（加 scaffolding-mc- 前缀，第 4 位后插 `-`）
        // 后 8 字符 → network-secret（第 4 位后插 `-`）
        NSMutableString *networkName = [NSMutableString stringWithString:kScaffoldingNetworkNamePrefix];
        NSMutableString *networkSecret = [NSMutableString string];

        for (int i = 0; i < 16; i++) {
            unichar c = [self digitToChar:[digits[i] integerValue]];
            if (i < 8) {
                // network-name 部分
                if (i == 4) {
                    [networkName appendString:@"-"];
                }
                [networkName appendFormat:@"%C", (unsigned short)c];
            } else {
                // network-secret 部分
                if (i == 12) {
                    [networkSecret appendString:@"-"];
                }
                [networkSecret appendFormat:@"%C", (unsigned short)c];
            }
        }

        return @{
            @"networkName": [networkName copy],
            @"networkSecret": [networkSecret copy]
        };
    }

    return nil; // 未找到合法邀请码
}

/// 验证邀请码是否合法
- (BOOL)isValidInvitationCode:(NSString *)invitationCode {
    return [self parseInvitationCode:invitationCode] != nil;
}

/// 从邀请码提取 EasyTier network-name
- (NSString *)networkNameFromInvitationCode:(NSString *)invitationCode {
    NSDictionary *parsed = [self parseInvitationCode:invitationCode];
    return parsed[@"networkName"];
}

/// 从邀请码提取 EasyTier network-secret
- (NSString *)networkSecretFromInvitationCode:(NSString *)invitationCode {
    NSDictionary *parsed = [self parseInvitationCode:invitationCode];
    return parsed[@"networkSecret"];
}

#pragma mark - EasyTier App 检测与唤起

- (BOOL)isEasyTierAppInstalled {
    NSString *urlString = [NSString stringWithFormat:@"%@://", kEasyTierURLScheme];
    NSURL *url = [NSURL URLWithString:urlString];
    if (!url) return NO;

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

- (void)openEasyTierApp {
    dispatch_async(dispatch_get_main_queue(), ^{
        if ([self isEasyTierAppInstalled]) {
            NSString *urlString = [NSString stringWithFormat:@"%@://", kEasyTierURLScheme];
            NSURL *url = [NSURL URLWithString:urlString];
            [[UIApplication sharedApplication] openURL:url options:@{} completionHandler:nil];
            NSLog(@"[EasyTierMultiplayerManager] 已唤起 EasyTier app");
        } else {
            NSURL *testFlightUrl = [NSURL URLWithString:kEasyTierTestFlightURL];
            [[UIApplication sharedApplication] openURL:testFlightUrl options:@{} completionHandler:nil];
            NSLog(@"[EasyTierMultiplayerManager] EasyTier app 未安装，已打开 TestFlight 安装页面");
        }
    });
}

- (void)joinNetwork:(NSString *)networkName
       networkSecret:(NSString *)networkSecret {
    if (!networkName || networkName.length == 0) {
        NSLog(@"[EasyTierMultiplayerManager] joinNetwork 失败：networkName 为空");
        return;
    }

    dispatch_async(dispatch_get_main_queue(), ^{
        if ([self isEasyTierAppInstalled]) {
            // 当前 EasyTier iOS app 未注册 URL Scheme，直接打开 app 主界面
            // 未来如果 EasyTier 支持 URL Scheme，可以在这里传参
            NSURL *url = [NSURL URLWithString:[NSString stringWithFormat:@"%@://", kEasyTierURLScheme]];
            [[UIApplication sharedApplication] openURL:url options:@{} completionHandler:nil];
            NSLog(@"[EasyTierMultiplayerManager] 已打开 EasyTier app（需手动加入网络：%@）", networkName);
        } else {
            NSURL *testFlightUrl = [NSURL URLWithString:kEasyTierTestFlightURL];
            [[UIApplication sharedApplication] openURL:testFlightUrl options:@{} completionHandler:nil];
            NSLog(@"[EasyTierMultiplayerManager] EasyTier app 未安装，已打开 TestFlight 安装页面");
        }
    });
}

#pragma mark - 数据持久化

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
            self.internalRooms = [[NSMutableArray alloc] init];
            return;
        }

        self.internalRooms = [NSMutableArray arrayWithArray:rooms];
        NSLog(@"[EasyTierMultiplayerManager] 成功加载 %lu 个房间", (unsigned long)self.internalRooms.count);
    }
}

- (void)saveRooms {
    NSArray *roomsCopy;
    @synchronized(self) {
        roomsCopy = [self.internalRooms copy];
    }

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
    });
}

#pragma mark - 房间管理

- (void)addRoom:(EasyTierRoom *)room {
    if (!room) return;

    if (!room.roomId || room.roomId.length == 0) {
        room.roomId = [self generateRoomId];
    }

    @synchronized(self) {
        for (int i = 0; i < self.internalRooms.count; i++) {
            if ([self.internalRooms[i].roomId isEqualToString:room.roomId]) {
                [self.internalRooms removeObjectAtIndex:i];
                break;
            }
        }
        [self.internalRooms addObject:room];
        [self.internalRooms sortUsingComparator:^NSComparisonResult(EasyTierRoom *a, EasyTierRoom *b) {
            return [b.createdAt compare:a.createdAt];
        }];
    }

    [self saveRooms];
    NSLog(@"[EasyTierMultiplayerManager] 已添加房间：%@ (%@)", room.name, room.roomId);
}

- (void)removeRoom:(NSString *)roomId {
    if (!roomId || roomId.length == 0) return;

    @synchronized(self) {
        for (int i = 0; i < self.internalRooms.count; i++) {
            if ([self.internalRooms[i].roomId isEqualToString:roomId]) {
                EasyTierRoom *removed = self.internalRooms[i];
                [self.internalRooms removeObjectAtIndex:i];

                if (self.currentRoom && [self.currentRoom.roomId isEqualToString:roomId]) {
                    self.currentRoom = nil;
                }

                NSLog(@"[EasyTierMultiplayerManager] 已删除房间：%@", removed.name);
                break;
            }
        }
    }

    [self saveRooms];
}

- (void)updateRoom:(EasyTierRoom *)room {
    if (!room || !room.roomId) return;

    @synchronized(self) {
        for (int i = 0; i < self.internalRooms.count; i++) {
            if ([self.internalRooms[i].roomId isEqualToString:room.roomId]) {
                self.internalRooms[i] = room;
                break;
            }
        }
        [self.internalRooms sortUsingComparator:^NSComparisonResult(EasyTierRoom *a, EasyTierRoom *b) {
            return [b.createdAt compare:a.createdAt];
        }];
    }

    [self saveRooms];
}

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

    room.status = EasyTierRoomStatusConnecting;
    [self updateRoom:room];

    self.currentRoom = room;

    [self joinNetwork:room.networkName
       networkSecret:room.networkSecret];

    room.status = EasyTierRoomStatusConnected;
    room.lastConnectedAt = [NSDate date];
    [self updateRoom:room];

    if (completion) {
        completion(YES, nil);
    }

    NSLog(@"[EasyTierMultiplayerManager] 已发起连接：%@ (code=%@)", room.name, room.invitationCode);
}

- (void)disconnectCurrentRoom {
    if (!self.currentRoom) return;

    EasyTierRoom *room = self.currentRoom;
    room.status = EasyTierRoomStatusDisconnected;
    [self updateRoom:room];

    NSLog(@"[EasyTierMultiplayerManager] 已断开房间连接：%@", room.name);
    self.currentRoom = nil;
}

#pragma mark - 分享与辅助

- (NSString *)shareTextForRoom:(EasyTierRoom *)room {
    if (!room) return @"";

    NSMutableString *text = [NSMutableString string];
    [text appendFormat:@"来联机！房间名：%@\n", room.name];
    [text appendFormat:@"邀请码：%@\n", room.invitationCode];

    if (room.hostIP && room.hostIP.length > 0) {
        [text appendFormat:@"服务器IP：%@:%@\n", room.hostIP, room.hostPort];
    }

    if (room.ownerName && room.ownerName.length > 0) {
        [text appendFormat:@"房主：%@\n", room.ownerName];
    }

    [text appendString:@"\n使用方法：\n"];
    [text appendString:@"1. 在启动器的 EasyTier 联机界面输入邀请码\n"];
    [text appendString:@"2. 打开 EasyTier app 加入网络\n"];
    [text appendString:@"3. 在 MC 中添加服务器 IP 即可联机\n"];
    [text appendString:@"（兼容 HMCL/FCL/ZL2/PCL2 陶瓦联机）"];

    return text;
}

- (NSString *)generateRoomId {
    return [[NSUUID UUID] UUIDString];
}

- (NSArray<NSString *> *)defaultPublicServers {
    return kDefaultPublicServers ?: @[];
}

- (NSString *)easyTierTestFlightUrl {
    return kEasyTierTestFlightURL;
}

- (NSString *)easyTierGitHubUrl {
    return kEasyTierGitHubURL;
}

@end
