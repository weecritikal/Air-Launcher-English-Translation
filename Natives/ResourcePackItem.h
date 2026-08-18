//
//  ResourcePackItem.h
//  Amethyst
//
//  Resource pack model, modelled on ShaderItem with packFormat added (parsed from pack.mcmeta)
//

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

@interface ResourcePackItem : NSObject

// --- Local resource pack properties ---
@property (nonatomic, copy, nullable) NSString *fileName;
@property (nonatomic, copy, nullable) NSString *filePath;
@property (nonatomic, assign) BOOL disabled;

// --- Online resource pack properties ---
@property (nonatomic, copy, nullable) NSString *onlineID;
@property (nonatomic, copy, nullable) NSString *author;
@property (nonatomic, strong, nullable) NSNumber *downloads;
@property (nonatomic, strong, nullable) NSNumber *likes;
@property (nonatomic, copy, nullable) NSString *lastUpdated;
@property (nonatomic, strong, nullable) NSArray<NSString *> *categories;
@property (nonatomic, copy, nullable) NSString *selectedVersionDownloadURL;

// --- Shared/metadata properties ---
@property (nonatomic, copy, nullable) NSString *displayName;
@property (nonatomic, copy, nullable) NSString *resourcePackDescription;
@property (nonatomic, copy, nullable) NSString *iconURL;
@property (nonatomic, strong, nullable) UIImage *icon;
@property (nonatomic, copy, nullable) NSString *fileSHA1;
@property (nonatomic, copy, nullable) NSString *version;
@property (nonatomic, copy, nullable) NSString *gameVersion;
@property (nonatomic, copy, nullable) NSString *homepage;
@property (nonatomic, copy, nullable) NSString *sources;
// The pack_format field from pack.mcmeta
@property (nonatomic, strong, nullable) NSNumber *packFormat;

// --- Initializers ---
- (instancetype)initWithFilePath:(NSString *)path;
- (instancetype)initWithOnlineData:(NSDictionary *)data;

// --- Helpers ---
- (NSString *)basename;
- (void)refreshDisabledFlag;

@end

NS_ASSUME_NONNULL_END
