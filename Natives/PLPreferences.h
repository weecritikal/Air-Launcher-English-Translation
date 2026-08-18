#import <Foundation/Foundation.h>

// Download source preference keys (one per asset type)
extern NSString *const PREF_DOWNLOAD_SOURCE_MOD;
extern NSString *const PREF_DOWNLOAD_SOURCE_SHADER;
extern NSString *const PREF_DOWNLOAD_SOURCE_RESOURCEPACK;
extern NSString *const PREF_DOWNLOAD_SOURCE_DATAPACK;
extern NSString *const PREF_DOWNLOAD_SOURCE_MODPACK;
extern NSString *const PREF_DOWNLOAD_SOURCE_WORLD;
extern NSString *const PREF_DOWNLOAD_SOURCE_SERVER;
// The CurseForge API key preference key
extern NSString *const PREF_CURSEFORGE_API_KEY;
// Whether to keep the old file when updating a mod
extern NSString *const PREF_MOD_UPDATE_KEEP_OLD;
// The mod mirror source (official / mcim)
extern NSString *const PREF_MOD_MIRROR;

@interface PLPreferences : NSObject

@property(nonatomic) NSString *globalPath, *instancePath;
@property(nonatomic) NSMutableDictionary<NSString *, NSMutableDictionary *> *globalPref, *instancePref;

- (id)initWithGlobalPath:(NSString *)path;
- (id)initWithAutomaticMigrator;

- (void)toggleIsolationForced:(BOOL)forced;
- (id)getObject:(NSString *)key;
- (BOOL)setObject:(NSString *)key value:(id)value;
- (void)reset;

// Download source management (per type)
+ (NSString *)currentDownloadSourceForType:(NSString *)type;
+ (void)setDownloadSource:(NSString *)source forType:(NSString *)type;
// CurseForge API Key
+ (NSString *)curseForgeAPIKey;
+ (void)setCurseForgeAPIKey:(NSString *)key;
// Keeping the old file on a mod update
+ (BOOL)modUpdateKeepOld;
+ (void)setModUpdateKeepOld:(BOOL)keepOld;

@end
