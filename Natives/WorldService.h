//
//  WorldService.h
//  Amethyst
//
//  World save management and download service, structured after ResourcePackService/DataPackService
//  The API consistently takes NSString *profileName
//  Scans the saves/ directory and robustly extracts downloaded world zips (detecting a top-level directory)
//  Uses defaultSessionConfiguration + NSURLSessionDownloadTask for better download throughput
//

#import <Foundation/Foundation.h>
#import "WorldItem.h"

NS_ASSUME_NONNULL_BEGIN

// World list callback
typedef void(^WorldListHandler)(NSArray<WorldItem *> *items);
// Download completion callback (success indicates whether it succeeded, error carries the failure reason)
typedef void(^WorldDownloadCompletionHandler)(BOOL success, NSError * _Nullable error);
// Download progress callback (runs on the main thread, so UI updates are safe)
typedef void(^WorldDownloadProgressHandler)(NSProgress * _Nullable downloadProgress);

@interface WorldService : NSObject

+ (instancetype)sharedService;

// --- Local world management ---
// Scan the saves directory of the given profile and return each subdirectory containing a level.dat as a WorldItem
- (void)scanWorldsForProfile:(NSString *)profileName completion:(WorldListHandler)completion;
// Delete a world directory (recursively)
- (BOOL)deleteWorld:(WorldItem *)item error:(NSError **)error;

// --- Online world downloads ---
// Download a world zip into the saves directory of the given profile and extract it automatically once downloaded (robust extraction logic)
// The progress callback reports download progress in real time (not covering the extraction phase)
// completion is invoked on the main thread; success indicates whether downloading and extracting succeeded
- (void)downloadWorld:(WorldItem *)item
            toProfile:(NSString *)profileName
             progress:(WorldDownloadProgressHandler _Nullable)progress
           completion:(WorldDownloadCompletionHandler _Nullable)completion;

// Import a world zip from a local file URL (such as a file chosen with UIDocumentPicker)
// Robust extraction is used here too, and the temporary zip can be deleted once the import completes
- (void)importWorldFromURL:(NSURL *)sourceURL
                toProfile:(NSString *)profileName
                 progress:(WorldDownloadProgressHandler _Nullable)progress
               completion:(WorldDownloadCompletionHandler _Nullable)completion;

// --- Helpers ---

/// 获取当前 profile 的 saves 目录，不存在时自动创建
- (nullable NSString *)ensureWorldsFolderForProfile:(NSString *)profileName error:(NSError **)error;

/// 查找当前 profile 的 saves 目录（已存在时返回路径，否则返回 nil）
- (nullable NSString *)existingWorldsFolderForProfile:(NSString *)profileName;

@end

NS_ASSUME_NONNULL_END
