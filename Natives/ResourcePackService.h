//
//  ResourcePackService.h
//  Flux
//
//  Local management and download service for resource packs, structured like ShaderService/ModService
//  The API consistently takes NSString *profileName (matching ModService)
//  Adds pack.mcmeta parsing (pack_format / description)
//

#import <Foundation/Foundation.h>
#import "ResourcePackItem.h"

NS_ASSUME_NONNULL_BEGIN

// Resource pack list callback
typedef void(^ResourcePackListHandler)(NSArray<ResourcePackItem *> *items);
// Resource pack metadata callback
typedef void(^ResourcePackMetadataHandler)(ResourcePackItem *item, NSError * _Nullable error);
// Download completion callback (success indicates whether it worked)
typedef void(^ResourcePackDownloadCompletionHandler)(BOOL success, NSError * _Nullable error);
// Download progress callback (runs on the main thread, so UI updates are safe)
typedef void(^ResourcePackDownloadProgressHandler)(NSProgress * _Nullable downloadProgress);

@interface ResourcePackService : NSObject

@property (nonatomic, assign) BOOL onlineSearchEnabled;

+ (instancetype)sharedService;

// --- Local resource pack management ---
// Scan the resourcepacks folder of the given profile and return the .zip and .zip.disabled files
- (void)scanResourcePacksForProfile:(NSString *)profileName completion:(ResourcePackListHandler)completion;
// Read resource pack metadata (parsing pack.mcmeta inside the zip for pack_format and description)
- (void)fetchMetadataForResourcePack:(ResourcePackItem *)item completion:(ResourcePackMetadataHandler)completion;
// Enable/disable a resource pack (adding or removing the .disabled suffix)
- (BOOL)toggleEnableForResourcePack:(ResourcePackItem *)item error:(NSError **)error;
// Delete a resource pack file
- (BOOL)deleteResourcePack:(ResourcePackItem *)item error:(NSError **)error;

// --- Online resource pack downloads ---
// Download a resource pack into the resourcepacks folder of the given profile, with live progress callbacks
- (void)downloadResourcePack:(ResourcePackItem *)item
                   toProfile:(NSString *)profileName
                    progress:(ResourcePackDownloadProgressHandler _Nullable)progress
                  completion:(ResourcePackDownloadCompletionHandler _Nullable)completion;

// --- Helpers ---
- (NSString *)iconCachePathForURL:(NSString *)urlString;

/// Return the resourcepacks folder of the current profile, creating it if it does not exist
- (nullable NSString *)ensureResourcePacksFolderForProfile:(NSString *)profileName error:(NSError **)error;

@end

NS_ASSUME_NONNULL_END
