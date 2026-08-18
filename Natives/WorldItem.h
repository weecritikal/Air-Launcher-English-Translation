//
//  WorldItem.h
//  Amethyst
//
//  World save data model, modeled on ShaderItem, with world-specific properties such as worldName and levelDatPath added
//  Locally scans the subdirectories of saves/ (each subdirectory containing a level.dat is one world)
//

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

@interface WorldItem : NSObject

// --- Local world properties ---
// World directory name (the subdirectory name under saves/)
@property (nonatomic, copy, nullable) NSString *worldName;
// Full path of the world directory (saves/<worldName>)
@property (nonatomic, copy, nullable) NSString *filePath;
// Path of the level.dat file
@property (nonatomic, copy, nullable) NSString *levelDatPath;
// Last modification time of level.dat (used to display "Last played")
@property (nonatomic, copy, nullable) NSString *lastPlayed;
// World size (in bytes, computed by recursing over the directory)
@property (nonatomic, strong, nullable) NSNumber *worldSize;

// --- Online world properties (used for online downloads) ---
@property (nonatomic, copy, nullable) NSString *onlineID;
@property (nonatomic, copy, nullable) NSString *author;
@property (nonatomic, strong, nullable) NSNumber *downloads;
@property (nonatomic, strong, nullable) NSNumber *likes;
@property (nonatomic, copy, nullable) NSString *lastUpdated;
@property (nonatomic, strong, nullable) NSArray<NSString *> *categories;
@property (nonatomic, copy, nullable) NSString *selectedVersionDownloadURL;

// --- Shared/metadata properties ---
@property (nonatomic, copy, nullable) NSString *displayName;
@property (nonatomic, copy, nullable) NSString *worldDescription;
@property (nonatomic, copy, nullable) NSString *iconURL;
@property (nonatomic, strong, nullable) UIImage *icon;
@property (nonatomic, copy, nullable) NSString *fileSHA1;
@property (nonatomic, copy, nullable) NSString *version;
@property (nonatomic, copy, nullable) NSString *gameVersion;
@property (nonatomic, copy, nullable) NSString *homepage;
@property (nonatomic, copy, nullable) NSString *sources;

// --- Initializers ---
// Initialize from a local world directory path (path points at saves/<worldName>)
- (instancetype)initWithFilePath:(NSString *)path;
// Initialize from an online search result
- (instancetype)initWithOnlineData:(NSDictionary *)data;

// --- Helpers ---
- (NSString *)basename;

@end

NS_ASSUME_NONNULL_END
