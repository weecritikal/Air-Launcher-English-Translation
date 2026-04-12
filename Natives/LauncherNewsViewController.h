#import <UIKit/UIKit.h>

// MARK: - Tile Type & Size Enums

typedef NS_ENUM(NSInteger, HomeTileType) {
    HomeTileTypeProfile = 0,
    HomeTileTypeAnnouncement,
    HomeTileTypeVersionRelease,
    HomeTileTypeVersionSnapshot,
    HomeTileTypeNews,
    HomeTileTypeShortcut,
};

typedef NS_ENUM(NSInteger, HomeTileSize) {
    HomeTileSizeCompact = 0,  // Half width (two per row)
    HomeTileSizeFull,         // Full width
};

// MARK: - HomeTileConfig

@interface HomeTileConfig : NSObject <NSSecureCoding>

@property (nonatomic, copy) NSString *tileId;
@property (nonatomic, assign) HomeTileType tileType;
@property (nonatomic, assign) HomeTileSize tileSize;
@property (nonatomic, assign) BOOL visible;
@property (nonatomic, copy) NSString *customTitle;
@property (nonatomic, copy) NSString *iconName;
@property (nonatomic, copy) NSString *accentColorHex;
@property (nonatomic, copy) NSString *shortcutAction;  // For HomeTileTypeShortcut

+ (NSArray<HomeTileConfig *> *)defaultTileConfigs;
+ (NSArray<HomeTileConfig *> *)loadSavedConfigs;
+ (void)saveConfigs:(NSArray<HomeTileConfig *> *)configs;
- (UIColor *)accentColor;
- (NSDictionary *)toDictionary;
+ (instancetype)fromDictionary:(NSDictionary *)dict;

@end

// MARK: - Shortcut Action Constants

extern NSString * const kShortcutActionMods;
extern NSString * const kShortcutActionShaders;
extern NSString * const kShortcutActionModpack;
extern NSString * const kShortcutActionBackground;
extern NSString * const kShortcutActionVersions;

// MARK: - LauncherNewsViewController

@interface LauncherNewsViewController : UIViewController

@end
