//
//  PLProfiles.m
//  Amethyst
//
//  Profile manager with JSON-safe save
//

#import "LauncherPreferences.h"
#import "PLProfiles.h"
#import "utils.h"

static PLProfiles* current;

@interface PLProfiles()
@end

@implementation PLProfiles

+ (id)defaultProfiles {
    return @{
        @"profiles": @{
            @"(Default)": @{
                @"name": @"(Default)",
                @"lastVersionId": @"latest-release"
            }
        },
        @"selectedProfile": @"(Default)"
    }.mutableCopy;
}

+ (PLProfiles *)current {
    if (!current) {
        [self updateCurrent];
    }
    return current;
}

+ (void)updateCurrent {
    current = [[PLProfiles alloc] initWithCurrentInstance];
}

+ (id)profile:(NSMutableDictionary *)profile resolveKey:(id)key {
    id rawValue = profile[key];
    // Handling the javaVersion field: the Mojang spec makes it an NSDictionary ({component, majorVersion}),
    // and some code (such as ForgeDirectInstaller) writes an NSDictionary too, while PLProfiles expects an NSString.
    if ([rawValue isKindOfClass:[NSDictionary class]]) {
        // javaVersion: return majorVersion as a string; when it is missing, fall through to valueDefaults below
        id major = rawValue[@"majorVersion"];
        if (major) return [major description];
        // Fall through to the valueDefaults logic below, so nil is never returned to break the caller
    } else if ([rawValue isKindOfClass:[NSString class]] && [(NSString *)rawValue length] > 0) {
        return rawValue;
    }

    NSDictionary *valueDefaults = @{
        @"javaVersion": @"0",
        @"gameDir": @"."
    };
    if (valueDefaults[key]) {
        return valueDefaults[key];
    }

    NSDictionary *prefDefaults = @{
        @"defaultTouchCtrl": @"control.default_ctrl",
        @"defaultGamepadCtrl": @"control.default_gamepad_ctrl",
        @"javaArgs": @"java.java_args",
        @"renderer": @"video.renderer",
        // The MC 26.2+ graphics API (in-game OpenGL/Vulkan switching), defaulting to "default"
        // This field only applies on MC 26.2+; older versions ignore it, with no side effects.
        @"graphicsApi": @"video.graphics_api"
    };
    return getPrefObject(prefDefaults[key]);
}

+ (id)resolveKeyForCurrentProfile:(id)key {
    return [self profile:self.current.selectedProfile resolveKey:key];
}

- (id)initWithCurrentInstance {
    self = [super init];
    self.profilePath = [@(getenv("POJAV_GAME_DIR")) stringByAppendingPathComponent:@"launcher_profiles.json"];
    self.profileDict = parseJSONFromFile(self.profilePath);
    if (self.profileDict[@"NSErrorObject"]) {
        self.profileDict = PLProfiles.defaultProfiles;
        [self save];
    }

    return self;
}

- (id)profiles {
    id profiles = self.profileDict[@"profiles"];
    if (![profiles isKindOfClass:[NSDictionary class]]) {
        profiles = [NSMutableDictionary dictionary];
        self.profileDict[@"profiles"] = profiles;
    } else if (![profiles isKindOfClass:[NSMutableDictionary class]]) {
        profiles = [profiles mutableCopy];
        self.profileDict[@"profiles"] = profiles;
    }
    return profiles;
}

- (id)selectedProfile {
    return self.profiles[self.selectedProfileName];
}

- (NSString *)selectedProfileName {
    return (id)self.profileDict[@"selectedProfile"];
}

- (void)setSelectedProfileName:(NSString *)name {
    self.profileDict[@"selectedProfile"] = (id)name;
    [self save];
    
    [[NSNotificationCenter defaultCenter] postNotificationName:@"SelectedProfileChanged" object:name];
}

/// Recursively strip NSDate and other JSON-invalid types, so saving cannot crash
- (id)jsonSanitizedObject:(id)obj {
    if ([obj isKindOfClass:[NSDate class]]) {
        static NSDateFormatter *formatter = nil;
        static dispatch_once_t onceToken;
        dispatch_once(&onceToken, ^{
            formatter = [[NSDateFormatter alloc] init];
            formatter.locale = [NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"];
            formatter.timeZone = [NSTimeZone timeZoneWithAbbreviation:@"UTC"];
            formatter.dateFormat = @"yyyy-MM-dd'T'HH:mm:ss'Z'";
        });
        return [formatter stringFromDate:obj];
    } else if ([obj isKindOfClass:[NSDictionary class]]) {
        NSMutableDictionary *clean = [NSMutableDictionary dictionaryWithCapacity:[obj count]];
        [obj enumerateKeysAndObjectsUsingBlock:^(id key, id val, BOOL *stop) {
            id safeKey = [key isKindOfClass:[NSDate class]] ? [self jsonSanitizedObject:key] : key;
            clean[safeKey] = [self jsonSanitizedObject:val];
        }];
        return clean;
    } else if ([obj isKindOfClass:[NSArray class]]) {
        NSMutableArray *clean = [NSMutableArray arrayWithCapacity:[obj count]];
        for (id item in obj) {
            [clean addObject:[self jsonSanitizedObject:item]];
        }
        return clean;
    }
    return obj;
}

- (void)save {
    id sanitized = [self jsonSanitizedObject:self.profileDict];
    if ([NSJSONSerialization isValidJSONObject:sanitized]) {
        saveJSONToFile(sanitized, self.profilePath);
    } else {
        NSLog(@"[PLProfiles] save failed: profileDict still contains invalid JSON types after sanitization");
    }
}

- (void)saveProfile:(NSMutableDictionary<NSString *, NSString *> *)profile withName:(NSString *)name {
    if (!self.profileDict[@"profiles"]) {
        self.profileDict[@"profiles"] = [NSMutableDictionary dictionary];
    }
    self.profileDict[@"profiles"][name] = profile;
    [self save];
}

#pragma mark - Server address (FCL style: join a server automatically after launch)

// Get the server address of the selected profile, returning @"" when empty
- (NSString *)serverIpForCurrentProfile {
    return [self serverIpForProfile:self.selectedProfileName];
}

// Get the server address of the given profile, returning @"" when missing or empty
- (NSString *)serverIpForProfile:(NSString *)profileName {
    NSString *ip = self.profiles[profileName][@"serverIp"];
    return ip ?: @"";
}

// Set the server address of the given profile, turning nil into @""
- (void)setServerIp:(NSString *)serverIp forProfile:(NSString *)profileName {
    NSMutableDictionary *profile = [self.profiles[profileName] mutableCopy];
    if (!profile) {
        profile = [NSMutableDictionary dictionary];
    }
    profile[@"serverIp"] = serverIp ?: @"";
    self.profiles[profileName] = profile;
    [self save];
}

@end
