#import "LauncherPreferences.h"
#import "PLPreferences.h"
#import "UIKit+hook.h"
#import "config.h"
#import "utils.h"

NSString *const PREF_DOWNLOAD_SOURCE_MOD = @"general.download_source_mod";
NSString *const PREF_DOWNLOAD_SOURCE_SHADER = @"general.download_source_shader";
NSString *const PREF_DOWNLOAD_SOURCE_RESOURCEPACK = @"general.download_source_resourcepack";
NSString *const PREF_DOWNLOAD_SOURCE_DATAPACK = @"general.download_source_datapack";
NSString *const PREF_DOWNLOAD_SOURCE_MODPACK = @"general.download_source_modpack";
NSString *const PREF_DOWNLOAD_SOURCE_WORLD = @"general.download_source_world";
NSString *const PREF_DOWNLOAD_SOURCE_SERVER = @"general.download_source_server";
NSString *const PREF_CURSEFORGE_API_KEY = @"general.curseforge_api_key";
NSString *const PREF_MOD_UPDATE_KEEP_OLD = @"general.mod_update_keep_old";
NSString *const PREF_MOD_MIRROR = @"general.mod_mirror";

@interface PLPreferences()
@end

@implementation PLPreferences

+ (id)defaultPrefForGlobal:(BOOL)global {
    // Preferences that can be isolated
    NSMutableDictionary<NSString *, NSMutableDictionary *> *defaults = @{
        @"general": @{
            @"check_sha": @YES,
            @"cosmetica": @YES,
            @"debug_logging": @(!CONFIG_RELEASE),
            @"news_url": @"https://air-api.vercel.app/api/announcements.php",
            @"download_source": @"bmclapi",
            // A separate download source per asset type (falling back to modrinth when unset)
            @"download_source_mod": @"modrinth",
            @"download_source_shader": @"modrinth",
            @"download_source_resourcepack": @"modrinth",
            @"download_source_datapack": @"modrinth",
            @"download_source_modpack": @"modrinth",
            @"download_source_world": @"modrinth",
            @"download_source_server": @"modrinth",
            // The CurseForge API key: an empty string means the compile-time default key is used
            @"curseforge_api_key": @"",
            // Whether to keep the old file when updating a mod (YES by default)
            @"mod_update_keep_old": @YES,
            // The mod mirror source: official (the official source) / mcim (the MCIM mirror, faster from mainland China)
            @"mod_mirror": @"official",
            // The forced memory allocation written into the profile; 0 = use the java.allocated_memory/auto_ram logic
            @"ram_allocation": @(0),
            // The preview level of the home announcement tile: full (title + date + summary) / summary (title + summary) / title_only
            @"announcement_preview_level": @"summary",
        }.mutableCopy,
        @"video": @{ // Video & Audio
            @"renderer": @"auto",
            @"resolution": @(100),
            // The max_framerate option has been removed: CADisplayLink always uses the adaptive 30-120Hz range,
            // and the screen hardware decides the real frame rate. disable_game_vsync is kept as the only frame rate unlock switch.
            // Unlock the frame rate (disable vertical sync): on by default.
            // Minecraft defaults to enableVsync=true, which locks the frame rate to the refresh rate (60 on 60Hz, 120 on 120Hz ProMotion).
            // When on, the launcher disables VSync at three layers: forcing enableVsync=false in options.txt,
            // forcing interval=0 in pojavSwapInterval, and triple-buffering the CAMetalLayer. See the comments at each site.
            @"disable_game_vsync": @YES,
            @"performance_hud": @NO,
            @"fullscreen_airplay": @YES,
            @"silence_other_audio": @NO,
            @"silence_with_switch": @NO,
            @"fix_simple_voice_chat_mod": @NO,
            @"allow_microphone": @NO,
            // In-game OpenGL/Vulkan switching on MC 26.2+; an empty string = default (handled by JavaLauncher)
            @"graphics_api": @""
        }.mutableCopy,
        @"control": @{
            @"default_ctrl": @"default.json",
            @"control_safe_area": UIApplication.sharedApplication ? NSStringFromUIEdgeInsets(getDefaultSafeArea()) : @"",
            @"default_gamepad_ctrl": @"default.json",
            @"controller_type": @"xbox",
            @"hardware_hide": @YES,
            @"recording_hide": @YES,
            @"gesture_mouse": @YES,
            @"gesture_hotbar": @YES,
            @"disable_haptics": @NO,
            @"slideable_hotbar": @NO,
            @"press_duration": @(400),
            @"button_scale": @(100),
            @"mouse_scale": @(100),
            @"mouse_speed": @(100),
            @"virtmouse_enable": @NO,
            @"gyroscope_enable": @NO,
            @"gyroscope_invert_x_axis": @NO,
            @"gyroscope_sensitivity": @(100),
            @"mod_touch_enable": @NO,
            @"mod_touch_mode": @0,
            @"mod_touch_vibrate_enable": @YES,
            @"mod_touch_vibrate_intensity": @2,
            @"mod_touch_moveview_enable": @YES,
            // A placeholder key for a UI sub-panel (the getPreference callback of LauncherPreferencesViewController
            // queries every setting by "section.key", including the button/childPane types).
            // An empty-string default avoids the "Getter could not find preference control.custom_controls" log line.
            @"custom_controls": @""
        }.mutableCopy,
        @"java": @{
            @"java_homes": @{
                @"0": @{
                    @"1_16_5_older": @"8",
                    @"1_17_newer": @"17",
                    @"execute_jar": @"8"
                }.mutableCopy,
                @"8": @"internal",
                @"17": @"internal",
                @"21": @"internal",
                @"25": @"internal"
            }.mutableCopy,
            @"java_args": @"",
            @"env_variables": @"",
            @"auto_ram": @(!getEntitlementValue(@"com.apple.private.memorystatus")),
            @"allocated_memory": [NSNumber numberWithFloat:roundf((NSProcessInfo.processInfo.physicalMemory / 1048576) * 0.25)],
            // The forced Java version written into the profile; auto = chosen from the game version
            @"java_version": @"auto"
        }.mutableCopy,
        // MobileGlues renderer preferences
        // When the renderer is MobileGlues or Vulkan, init_loadMobileGluesConfig() writes
        // <POJAV_HOME>/MG/config.json, controlling the GL version, the ANGLE backend, FSR and so on.
        // The OpenGL fallback of the Vulkan renderer is MobileGlues (aligned with the Ynnyny repo), so these settings apply.
        // The Auto renderer really uses ANGLE and never loads MobileGlues, so these settings do not apply.
        @"mobileglues": @{
            @"enable_angle": @NO,
            @"enable_no_error": @(0),
            @"enable_ext_timer_query": @YES,
            @"enable_ext_compute_shader": @NO,
            @"enable_ext_direct_state_access": @NO,
            @"max_glsl_cache_size": @(32),
            @"multidraw_mode": @(0),
            @"angle_depth_clear_fix_mode": @(0),
            @"custom_gl_version": @(0),
            @"fsr1_setting": @(0)
        }.mutableCopy,
        // Position persistence and the switch for the in-game overlay (GameMenuOverlayView)
        // The position is stored as a percentage of the screen width/height (0.0~1.0), with the sentinel -1 meaning unset,
        // in which case restorePositions in GameMenuOverlayView falls back to the hardcoded default position.
        @"game": @{
            @"menu_button_x": @(-1.0),
            @"menu_button_y": @(-1.0),
            @"stats_label_x": @(-1.0),
            @"stats_label_y": @(-1.0),
            @"stats_label_visible": @YES
        }.mutableCopy,
        @"internal": @{
            @"isolated": @NO,
            @"latest_version": [NSDictionary new]
        }.mutableCopy
    }.mutableCopy;

    if (global) {
        // Preferences that cannot be isolated
        NSDictionary *general = @{
            @"game_directory": @"default",
            @"hidden_sidebar": @(realUIIdiom == UIUserInterfaceIdiomPhone),
            @"appicon": @"AppIcon-Light",
            @"ui_layout": @"vs",
            @"ui_theme": @"dark",
            @"multi_threaded": @NO,
            // The custom appearance colors (hex strings; an empty string = the default dark frosted glass / white text)
            @"text_color": @"",
            @"card_color": @"",
            // The theme accent color (a hex string; an empty string = the default blue #429CF5, see accentColor() in LauncherPreferences.m)
            // A default is provided so accessing it does not log "Getter could not find preference general.accent_color" every time
            @"accent_color": @""
        };
        [defaults[@"general"] addEntriesFromDictionary:general];

        defaults[@"java"][@"manage_runtime"] = @""; // stub
        defaults[@"debug"] = @{
            @"debug_universal_script_jit": @NO,
            @"debug_always_attached_jit": @NO,
            @"debug_skip_wait_jit": @NO,
            @"debug_hide_home_indicator": @NO,
            @"debug_ipad_ui": @(realUIIdiom == UIUserInterfaceIdiomPad),
            @"debug_auto_correction": @YES,
            @"debug_show_layout_bounds": @NO,
            @"debug_show_layout_overlap": @NO
        }.mutableCopy;
        defaults[@"warnings"] = @{
            @"local_warn": @YES,
            @"mem_warn": @YES,
            @"auto_ram_warn": @YES,
            @"limited_ram_warn": @YES
        }.mutableCopy;
        // TODO: isolate this or add account picker into profile editor(?)
        defaults[@"internal"][@"selected_account"] = @"";
    }

    return defaults;
}

+ (id)getPreference:(NSString *)key from:(NSDictionary *)pref {
    for (NSDictionary *section in pref.allValues) {
        if ([section isKindOfClass:NSDictionary.class] && section[key]) {
            return section[key];
        }
    }
    return nil;
}

+ (id)getOldLayoutPreference:(NSString *)key from:(NSDictionary *)pref {
    // Find preference in the root dictionary first
    if (pref[key]) {
        return pref[key];
    }
    // Find preference in subdictionaries
    id value = [self getPreference:key from:pref];
    if (!value) {
        NSLog(@"[PLPreferences] Migrator could not find preference %@", key);
    }
    return value;
}

- (id)initWithGlobalPath:(NSString *)path {
    self = [super init];
    self.globalPath = path;
    self.globalPref = [NSMutableDictionary dictionaryWithContentsOfFile:path];
    [self saveGlobalPref];
    return self;
}

- (id)initWithAutomaticMigrator {
    self = [super init];
    self.globalPath = [@(getenv("POJAV_HOME")) stringByAppendingPathComponent:@"launcher_preferences_v2.plist"];
    NSMutableDictionary *pref = [NSMutableDictionary dictionaryWithContentsOfFile:self.globalPath];

    NSString *oldPath = [@(getenv("POJAV_HOME")) stringByAppendingPathComponent:@"launcher_preferences.plist"];
    NSMutableDictionary *oldPref = [NSMutableDictionary dictionaryWithContentsOfFile:oldPath];

    if (pref || !oldPref[@"env_vars"]) {
        // Initialize or load existing v2 layout
        self.globalPref = pref;
    } else {
        NSDebugLog(@"[PLPreferences] Migrating to %@", self.globalPath.lastPathComponent);
        // Perform migration from v1 layout
        self.globalPref = [NSMutableDictionary new];
        for (NSString *section in self.globalPref.allKeys) {
            for (NSString *key in self.globalPref[section].allKeys) {
                id value = [PLPreferences getOldLayoutPreference:key from:oldPref];
                if (value) {
                    self.globalPref[section][key] = value;
                }
            }
        }
    }

    [self saveGlobalPref];
    return self;
}

- (id)setDefaultsForPref:(NSMutableDictionary *)pref global:(BOOL)global {
    NSMutableDictionary<NSString *, NSMutableDictionary *> *defaults = [PLPreferences defaultPrefForGlobal:global];
    if (!pref) {
        NSLog(@"[PLPreferences] Initializing default values for %@ preferences", global ? @"global" : @"isolated");
        return defaults;
    }

    for (NSString *section in defaults.allKeys) {
        if (!pref[section]) {
            NSDebugLog(@"[PLPreferences] Set default values for section %@", section);
            pref[section] = defaults[section];
            continue;
        }
        // Key fix: nested dictionaries loaded from a plist are immutable NSDictionary objects (NSMutableDictionary
        // dictionaryWithContentsOfFile: only guarantees the top level is mutable, and nested dictionaries stay NSDictionary).
        // Without converting them to NSMutableDictionary, a later setValue:forKeyPath: throws,
        // so the user's settings cannot be saved (affecting every section, including mobileglues and video).
        if (![pref[section] isKindOfClass:[NSMutableDictionary class]]) {
            pref[section] = [pref[section] mutableCopy];
        }
        for (NSString *key in defaults[section].allKeys) {
            if (pref[section][key]) continue;
            id value = defaults[section][key];
            NSDebugLog(@"[PLPreferences] Set default vaule: %@", key, value);
            pref[section][key] = value;
        }
    }
    return pref;
}

- (void)setGlobalPref:(NSMutableDictionary *)pref {
    _globalPref = [self setDefaultsForPref:pref global:YES];
}

- (void)setInstancePref:(NSMutableDictionary *)pref {
    _instancePref = [self setDefaultsForPref:pref global:NO];
}

- (void)toggleIsolationForced:(BOOL)force {
    NSMutableDictionary *instancePref = [NSMutableDictionary dictionaryWithContentsOfFile:self.instancePath];
    if (force || [instancePref[@"internal"][@"isolated"] boolValue]) {
        NSLog(@"[PLPreferences] Using isolated preferences from %@", self.instancePath.stringByResolvingSymlinksInPath);
        self.instancePref = instancePref;
        if (!instancePref) {
            // Copy preferences from the global one
            for (NSString *section in self.instancePref) {
                for (NSString *key in self.instancePref[section].allKeys) {
                    self.instancePref[section][key] = self.globalPref[section][key];
                }
            }
        }

        // Declare that itself is isolated
        self.instancePref[@"internal"][@"isolated"] = @YES;

        [self saveInstancePref];
    } else if (self.instancePref) {
        NSLog(@"[PLPreferences] Using global preferences");
        _instancePref = nil;
    }
}

- (id)getObject:(NSString *)key {
    id value = [self.instancePref valueForKeyPath:key];
    if (!value) {
        value = [self.globalPref valueForKeyPath:key];
    }
    if (!value) {
        NSLog(@"[PLPreferences] Getter could not find preference %@", key);
    }
    return value;
}

- (BOOL)setObject:(NSString *)key value:(id)value {
    if ([self.instancePref valueForKeyPath:key]) {
        [self.instancePref setValue:value forKeyPath:key];
        [self saveInstancePref];
        return YES;
    } else if ([self.globalPref valueForKeyPath:key]) {
        [self.globalPref setValue:value forKeyPath:key];
        [self saveGlobalPref];
        return YES;
    }
    NSLog(@"[PLPreferences] Setter could not find preference %@", key);
    return NO;
}

- (void)reset {
    if (self.instancePref) {
        [NSFileManager.defaultManager removeItemAtPath:self.instancePath error:nil];
        [self toggleIsolationForced:YES];
        // Only reset isolated values
        return;
    }

    self.globalPref = nil;
    [self saveGlobalPref];
}

- (void)saveGlobalPref {
    [self.globalPref writeToFile:self.globalPath atomically:YES];
}

- (void)saveInstancePref {
    [self.instancePref writeToFile:self.instancePath atomically:YES];
}

// Download source management (persisted per type)
+ (NSString *)currentDownloadSourceForType:(NSString *)type {
    NSString *key = [self downloadSourceKeyForType:type];
    NSString *source = getPrefObject(key);
    return source ?: @"modrinth";
}

+ (void)setDownloadSource:(NSString *)source forType:(NSString *)type {
    NSString *key = [self downloadSourceKeyForType:type];
    setPrefObject(key, source);
}

+ (NSString *)downloadSourceKeyForType:(NSString *)type {
    if ([type isEqualToString:@"mod"]) return PREF_DOWNLOAD_SOURCE_MOD;
    if ([type isEqualToString:@"shader"]) return PREF_DOWNLOAD_SOURCE_SHADER;
    if ([type isEqualToString:@"resourcepack"]) return PREF_DOWNLOAD_SOURCE_RESOURCEPACK;
    if ([type isEqualToString:@"datapack"]) return PREF_DOWNLOAD_SOURCE_DATAPACK;
    if ([type isEqualToString:@"modpack"]) return PREF_DOWNLOAD_SOURCE_MODPACK;
    if ([type isEqualToString:@"world"]) return PREF_DOWNLOAD_SOURCE_WORLD;
    if ([type isEqualToString:@"server"]) return PREF_DOWNLOAD_SOURCE_SERVER;
    return PREF_DOWNLOAD_SOURCE_MOD;
}

// The CurseForge API key (set at runtime, overriding the compile-time default)
+ (NSString *)curseForgeAPIKey {
    return getPrefObject(PREF_CURSEFORGE_API_KEY);
}

+ (void)setCurseForgeAPIKey:(NSString *)key {
    if (key && key.length > 0) {
        setPrefObject(PREF_CURSEFORGE_API_KEY, key);
    } else {
        // Note: passing nil makes setValue:forKeyPath: remove the key, so the next write with
        // setObject:value: fails silently because the key does not exist. An empty string is written instead, keeping the key.
        setPrefObject(PREF_CURSEFORGE_API_KEY, @"");
    }
}

// Keeping the old file on a mod update (YES by default)
+ (BOOL)modUpdateKeepOld {
    NSNumber *value = getPrefObject(PREF_MOD_UPDATE_KEEP_OLD);
    return value ? value.boolValue : YES;
}

+ (void)setModUpdateKeepOld:(BOOL)keepOld {
    setPrefObject(PREF_MOD_UPDATE_KEEP_OLD, @(keepOld));
}

@end
