#import "TerracottaBridge.h"
#import "terracotta.h"
#import <fcntl.h>
#import <unistd.h>
#import "utils.h"

#pragma mark - Data Models

@implementation TerracottaPlayerProfile
@end

@implementation TerracottaState
@end

#pragma mark - Bridge Implementation

@implementation TerracottaBridge

/* Pass an optional NSString to a C function as a const char *. nil becomes NULL. */
static void terracottaCallWithOptionalCString(NSString *s, void (^body)(const char *)) {
    if (s != nil) {
        body([s UTF8String]);
    } else {
        body(NULL);
    }
}

#pragma mark - Availability

+ (BOOL)isAvailable {
    return terracotta_ios_available() ? YES : NO;
}

#pragma mark - Lifecycle

+ (BOOL)startWithWorkingDirectory:(NSString *)workingDirectory
                       loggingPath:(NSString *)loggingPath {
    if (!terracotta_ios_available()) {
        NSLog(@"[TerracottaBridge] libterracotta not linked, start ignored");
        return NO;
    }
    int fd = -1;
    if (loggingPath != nil) {
        /* Standard C octal: O_WRONLY=01, O_CREAT=0100, O_TRUNC=01000, O_APPEND=02000, mode=0644
         * Note: the C++14 0o prefix cannot be used (C does not support it and AppleClang reports an invalid suffix) */
        fd = open([loggingPath UTF8String], 02000 | 0100 | 01000, 0644);
    }
    @try {
        return terracotta_ios_start([workingDirectory UTF8String], fd) == 0 ? YES : NO;
    } @finally {
        if (fd >= 0) close(fd);
    }
}

+ (void)setWaiting {
    if (terracotta_ios_available()) terracotta_ios_set_waiting();
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
    if (room == nil || room.length == 0) return NO;
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

#pragma mark - State Polling

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

+ (TerracottaState *)parseStateFromJSON:(NSDictionary *)json {
    TerracottaState *state = [[TerracottaState alloc] init];
    NSString *stateStr = json[@"state"];
    state.kind = [self stateKindFromString:stateStr];
    state.index = [json[@"index"] integerValue];
    state.room = json[@"room"];
    state.directConnectURL = json[@"url"];
    state.profileIndex = [json[@"profile_index"] integerValue];
    state.exceptionType = [json[@"type"] integerValue];

    /* Parse the player list */
    NSArray *profilesArray = json[@"profiles"];
    if ([profilesArray isKindOfClass:[NSArray class]]) {
        NSMutableArray<TerracottaPlayerProfile *> *profiles = [NSMutableArray array];
        for (NSDictionary *p in profilesArray) {
            if (![p isKindOfClass:[NSDictionary class]]) continue;
            TerracottaPlayerProfile *profile = [[TerracottaPlayerProfile alloc] init];
            profile.name = p[@"name"];
            profile.machineId = p[@"machine_id"];
            profile.easytierId = p[@"easytier_id"];
            profile.vendor = p[@"vendor"];
            profile.kind = p[@"kind"];
            [profiles addObject:profile];
        }
        state.profiles = profiles;
    }
    return state;
}

+ (TerracottaStateKind)stateKindFromString:(NSString *)s {
    if (s == nil) return TerracottaStateKindWaiting;
    static NSDictionary<NSString *, NSNumber *> *mapping;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        mapping = @{
            @"waiting":           @(TerracottaStateKindWaiting),
            @"host-scanning":     @(TerracottaStateKindHostScanning),
            @"host-starting":     @(TerracottaStateKindHostStarting),
            @"host-ok":           @(TerracottaStateKindHostOk),
            @"guest-connecting":  @(TerracottaStateKindGuestConnecting),
            @"guest-starting":    @(TerracottaStateKindGuestStarting),
            @"guest-ok":          @(TerracottaStateKindGuestOk),
            @"exception":         @(TerracottaStateKindException),
        };
    });
    NSNumber *num = mapping[s];
    if (num == nil) return TerracottaStateKindWaiting;
    return (TerracottaStateKind)[num integerValue];
}

#pragma mark - Metadata

+ (NSDictionary<NSString *, id> *)metadata {
    if (!terracotta_ios_available()) return nil;
    char *raw = terracotta_ios_get_metadata();
    if (raw == NULL) return nil;
    @try {
        /* The Rust side returns NUL-separated UTF-8: "<version>\0<ts_ms>\0<et_version>\0"
         * strlen cannot be used (there are NULs inside), so scan manually for 3 NULs to compute the total length */
        size_t totalLen = 0;
        char *cursor = raw;
        int nulCount = 0;
        while (nulCount < 3) {
            char ch = *cursor;
            totalLen += 1;
            if (ch == 0) nulCount += 1;
            cursor += 1;
        }
        /* Split on \0 */
        NSMutableArray<NSString *> *segments = [NSMutableArray array];
        const uint8_t *bytes = (const uint8_t *)raw;
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

#pragma mark - Exception Description

+ (NSString *)describeException:(NSInteger)type {
    switch (type) {
        case 0: return @"Could not connect to the host (PingHostFail)";
        case 1: return @"The host refused the connection (PingHostRst)";
        case 2: return @"EasyTier crashed on the guest (GuestEasytierCrash)";
        case 3: return @"EasyTier crashed on the host (HostEasytierCrash)";
        case 4: return @"The Minecraft server refused the connection (PingServerRst)";
        case 5: return @"The Scaffolding protocol returned invalid data";
        default: return [NSString stringWithFormat:@"Unknown error (type=%ld)", (long)type];
    }
}

@end
