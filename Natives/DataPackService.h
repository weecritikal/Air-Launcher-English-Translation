//
//  DataPackService.h
//  Flux
//
//  Local management and download service for data packs, structured like ShaderService/ModService
//  The API consistently takes NSString *profileName (matching ModService)
//  Adds pack.mcmeta parsing (pack_format / description)
//  Adds a worldName parameter so packs can be downloaded into a specific world (saves/<worldName>/datapacks/)
//

#import <Foundation/Foundation.h>
#import "DataPackItem.h"

NS_ASSUME_NONNULL_BEGIN

// Data pack list callback
typedef void(^DataPackListHandler)(NSArray<DataPackItem *> *items);
// Data pack metadata callback
typedef void(^DataPackMetadataHandler)(DataPackItem *item, NSError * _Nullable error);
// Download completion callback (success indicates whether it worked)
typedef void(^DataPackDownloadCompletionHandler)(BOOL success, NSError * _Nullable error);
// Download progress callback (runs on the main thread, so UI updates are safe)
typedef void(^DataPackDownloadProgressHandler)(NSProgress * _Nullable downloadProgress);

@interface DataPackService : NSObject

@property (nonatomic, assign) BOOL onlineSearchEnabled;

+ (instancetype)sharedService;

// --- Local data pack management ---
// Scan the datapacks folder of the given profile and return the .zip and .zip.disabled files
- (void)scanDataPacksForProfile:(NSString *)profileName completion:(DataPackListHandler)completion;
// Read data pack metadata (parsing pack.mcmeta inside the zip for pack_format and description)
- (void)fetchMetadataForDataPack:(DataPackItem *)item completion:(DataPackMetadataHandler)completion;
// Enable/disable a data pack (adding or removing the .disabled suffix)
- (BOOL)toggleEnableForDataPack:(DataPackItem *)item error:(NSError **)error;
// Delete a data pack file
- (BOOL)deleteDataPack:(DataPackItem *)item error:(NSError **)error;

// --- Online data pack downloads ---
// Download a data pack into the datapacks folder of the given profile (<gameDir>/datapacks/), with live progress callbacks
// Note: Minecraft requires data packs in <gameDir>/saves/<world name>/datapacks/, but a world cannot be picked on iOS,
// so packs go to <gameDir>/datapacks/ by default and the user has to move them into the right world folder.
- (void)downloadDataPack:(DataPackItem *)item
               toProfile:(NSString *)profileName
                progress:(DataPackDownloadProgressHandler _Nullable)progress
              completion:(DataPackDownloadCompletionHandler _Nullable)completion;

// Download a data pack into a specific world's datapacks folder (<gameDir>/saves/<worldName>/datapacks/)
// Falls back to <gameDir>/datapacks/ when worldName is nil
- (void)downloadDataPack:(DataPackItem *)item
               toProfile:(NSString *)profileName
               worldName:(nullable NSString *)worldName
                progress:(DataPackDownloadProgressHandler _Nullable)progress
              completion:(DataPackDownloadCompletionHandler _Nullable)completion;

// --- Helpers ---
- (NSString *)iconCachePathForURL:(NSString *)urlString;

/// Return the datapacks folder of the current profile, creating it if it does not exist
- (nullable NSString *)ensureDataPacksFolderForProfile:(NSString *)profileName error:(NSError **)error;

@end

NS_ASSUME_NONNULL_END
