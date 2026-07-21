#import "TerracottaBridge.h"
#import "terracotta.h"
#import <fcntl.h>
#import <unistd.h>

@implementation TerracottaPlayerProfile
@end

@implementation TerracottaState
@end

/* 私有 JSON 解码辅助 —— 对应 Rust 侧 terracotta_ios_get_state 的输出 schema */
@interface TerracottaStatePayload : NSObject
@property(nonatomic, copy) NSString *state;
@property(nonatomic, assign) NSInteger index;
@property(nonatomic, copy, nullable) NSString *room;
@property(nonatomic, copy, nullable) NSString *url;
@property(nonatomic, assign) NSInteger profileIndex;
@property(nonatomic, copy, nullable) NSArray<NSDictionary *> *profiles;
@property(nonatomic, copy, nullable) NSString *difficulty;
@property(nonatomic, assign) NSInteger type;
@end
@implementation TerracottaStatePayload
@end

@implementation TerracottaBridge

/* 把可选 NSString 当作 const char * 传给 C 函数。nil 转 NULL。 */
static void terracottaCallWithOptionalCString(NSString *s, void (^body)(const char *)) {
    if (s != nil) {
        const char *cstr = [s UTF8String];
        body(cstr);
    } else {
        body(NULL);
    }
}

#pragma mark - Availability

+ (BOOL)isAvailable {
    /* terracotta_ios_start 是 weak 符号；libterracotta.a 未链接时为 NULL。
     * 用宏 terracotta_ios_available() 检查（避免每次调用都写 NULL 比较）。 */
    return terracotta_ios_available() ? YES : NO;
}

#pragma mark - Public API

+ (BOOL)startWithWorkingDirectory:(NSString *)workingDirectory
                       loggingPath:(NSString *)loggingPath {
    if (!terracotta_ios_available()) {
        NSLog(@"[TerracottaBridge] libterracotta not linked, start ignored");
        return NO;
    }
    int fd = -1;
    if (loggingPath != nil) {
        /* O_WRONLY=1, O_CREAT=0o100, O_TRUNC=0o1000, O_APPEND=0o2000, mode=0o644 */
        fd = open([loggingPath UTF8String], 0o2000 | 0o100 | 0o1000, 0o644);
    }
    @try {
        return terracotta_ios_start([workingDirectory UTF8String], fd) == 0 ? YES : NO;
    } @finally {
        if (fd >= 0) close(fd);
    }
}

+ (void)setWaiting {
    if (!terracotta_ios_available()) return;
    terracotta_ios_set_waiting();
}

+ (void)setScanningWithRoom:(NSString *)room
                 playerName:(NSString *)playerName {
    if (!terracotta_ios_available()) return;
    terracottaCallWithOptionalCString(room, ^(const char *roomCStr) {
        terracottaCallWithOptionalCString(playerName, ^(const char *playerCStr) {
            terracotta_ios_set_scanning(roomCStr, playerCStr);
        });
    });
}

+ (BOOL)startHostWithRoom:(NSString *)room
                     port:(uint16_t)port
               playerName:(NSString *)playerName {
    if (!terracotta_ios_available()) return NO;
    __block BOOL result = NO;
    terracottaCallWithOptionalCString(room, ^(const char *roomCStr) {
        terracottaCallWithOptionalCString(playerName, ^(const char *playerCStr) {
            result = (terracotta_ios_start_host_with_port(roomCStr, port, playerCStr) == 1) ? YES : NO;
        });
    });
    return result;
}

+ (BOOL)setGuestingWithRoom:(NSString *)room
                 playerName:(NSString *)playerName {
    if (!terracotta_ios_available()) return NO;
    __block BOOL result = NO;
    terracottaCallWithOptionalCString(room, ^(const char *roomCStr) {
        terracottaCallWithOptionalCString(playerName, ^(const char *playerCStr) {
            result = (terracotta_ios_set_guesting(roomCStr, playerCStr) == 1) ? YES : NO;
        });
    });
    return result;
}

+ (BOOL)verifyRoomCode:(NSString *)code {
    if (!terracotta_ios_available()) return NO;
    if (code == nil || code.length == 0) return NO;
    return terracotta_ios_verify_room_code([code UTF8String]) == 3 ? YES : NO;
}

+ (TerracottaState *)pollState {
    if (!terracotta_ios_available()) return nil;
    char *raw = terracotta_ios_get_state();
    if (raw == NULL) return nil;
    @try {
        NSString *jsonStr = [NSString stringWithUTF8String:raw];
        if (jsonStr == nil) return nil;
        NSData *data = [jsonStr dataUsingEncoding:NSUTF8StringEncoding];
        if (data == nil) return nil;
        NSDictionary *json = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
        if (json == nil || ![json isKindOfClass:[NSDictionary class]]) return nil;
        return [self parseStateFromJSON:json];
    } @catch (NSException *e) {
        NSLog(@"[TerracottaBridge] pollState parse exception: %@", e);
        return nil;
    } @finally {
        terracotta_ios_free_string(raw);
    }
}

+ (NSDictionary<NSString *, id> *)metadata {
    if (!terracotta_ios_available()) return nil;
    char *raw = terracotta_ios_get_metadata();
    if (raw == NULL) return nil;
    @try {
        /* Rust 侧返回 NUL 分隔的 UTF-8："<version>\0<ts_ms>\0<et_version>\0"
         * strlen 不能用（内部有 NUL），手动扫描 3 个 NUL 计算总长度 */
        size_t totalLen = 0;
        char *cursor = raw;
        int nulCount = 0;
        while (nulCount < 3) {
            char ch = *cursor;
            totalLen += 1;
            if (ch == 0) nulCount += 1;
            cursor += 1;
        }
        NSData *buffer = [NSData dataWithBytes:raw length:totalLen];
        /* 按 \0 切分（末尾的 NUL 会产出空段，过滤掉） */
        NSMutableArray<NSString *> *segments = [NSMutableArray array];
        const uint8_t *bytes = buffer.bytes;
        size_t segStart = 0;
        for (size_t i = 0; i < totalLen; i++) {
            if (bytes[i] == 0) {
                if (i > segStart) {
                    NSString *seg = [[NSString alloc] initWithBytes:bytes + segStart
                                                             length:i - segStart
                                                           encoding:NSUTF8StringEncoding];
                    if (seg != nil) [segments addObject:seg];
                }
                segStart = i + 1;
            }
        }
        if (segments.count != 3) return nil;
        long long ts = [segments[1] longLongValue];
        return @{
            @"version":           segments[0],
            @"compileTimestamp":  @(ts),
            @"easytierVersion":   segments[2]
        };
    } @catch (NSException *e) {
        NSLog(@"[TerracottaBridge] metadata parse exception: %@", e);
        return nil;
    } @finally {
        terracotta_ios_free_string(raw);
    }
}

+ (NSString *)describeException:(NSInteger)type {
    switch (type) {
        case 0: return @"无法连接到房主（PingHostFail）";
        case 1: return @"房主拒绝连接（PingHostRst）";
        case 2: return @"访客端 EasyTier 崩溃（GuestEasytierCrash）";
        case 3: return @"房主端 EasyTier 崩溃（HostEasytierCrash）";
        case 4: return @"MC 服务器拒绝连接（PingServerRst）";
        case 5: return @"Scaffolding 协议返回非法数据";
        default: return [NSString stringWithFormat:@"未知错误（type=%ld）", (long)type];
    }
}

#pragma mark - JSON Parsing

+ (TerracottaState *)parseStateFromJSON:(NSDictionary *)json {
    TerracottaState *state = [[TerracottaState alloc] init];
    NSString *stateStr = json[@"state"];
    state.index = [json[@"index"] integerValue];
    state.room = json[@"room"];
    state.url = json[@"url"];
    state.profileIndex = [json[@"profile_index"] integerValue];
    state.difficulty = json[@"difficulty"];
    state.exceptionType = [json[@"type"] integerValue];

    if ([stateStr isEqualToString:@"waiting"]) {
        state.kind = TerracottaStateWaiting;
    } else if ([stateStr isEqualToString:@"host-scanning"]) {
        state.kind = TerracottaStateHostScanning;
    } else if ([stateStr isEqualToString:@"host-starting"]) {
        state.kind = TerracottaStateHostStarting;
    } else if ([stateStr isEqualToString:@"host-ok"]) {
        state.kind = TerracottaStateHostOk;
    } else if ([stateStr isEqualToString:@"guest-connecting"]) {
        state.kind = TerracottaStateGuestConnecting;
    } else if ([stateStr isEqualToString:@"guest-starting"]) {
        state.kind = TerracottaStateGuestStarting;
    } else if ([stateStr isEqualToString:@"guest-ok"]) {
        state.kind = TerracottaStateGuestOk;
    } else if ([stateStr isEqualToString:@"exception"]) {
        state.kind = TerracottaStateException;
    } else {
        NSLog(@"[TerracottaBridge] unknown state: %@", stateStr);
        return nil;
    }

    /* 解析玩家列表 */
    NSArray *profilesArray = json[@"profiles"];
    if (profilesArray != nil && [profilesArray isKindOfClass:[NSArray class]]) {
        NSMutableArray<TerracottaPlayerProfile *> *profiles = [NSMutableArray array];
        for (NSDictionary *p in profilesArray) {
            if (![p isKindOfClass:[NSDictionary class]]) continue;
            TerracottaPlayerProfile *profile = [[TerracottaPlayerProfile alloc] init];
            profile.name = p[@"name"] ?: @"";
            profile.machineId = p[@"machine_id"] ?: @"";
            profile.easytierId = p[@"easytier_id"];
            profile.vendor = p[@"vendor"] ?: @"";
            profile.kind = p[@"kind"] ?: @"";
            [profiles addObject:profile];
        }
        state.profiles = profiles;
    }

    return state;
}

@end
