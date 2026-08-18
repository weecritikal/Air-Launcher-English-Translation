//
//  ModpackImportService.h
//  Amethyst
//
//  Modpack import service - supports the .zip and .mrpack formats
//
//  Supported formats:
//    1. Modrinth (.mrpack)       - modrinth.index.json
//    2. CurseForge (.zip)         - manifest.json
//    3. MMC (.zip)                - mmc-pack.json + instance.cfg
//    4. Plain ZIP (.zip)          - containing the .minecraft folder structure directly (the HMCL/FCL export format)
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Modpack format (for import)
typedef NS_ENUM(NSInteger, ModpackImportFormat) {
    ModpackImportFormatUnknown = 0,
    ModpackImportFormatModrinth,   // .mrpack
    ModpackImportFormatCurseForge, // .zip + manifest.json
    ModpackImportFormatMMC,        // .zip + mmc-pack.json + instance.cfg
    ModpackImportFormatPlainZip,   // .zip with a direct .minecraft folder
};

@interface ModpackImportService : NSObject

/// Cancellation signal: once set to YES from outside, an importModpack in progress stops at the next checkpoint
@property (nonatomic, assign, getter=isCancelled) BOOL cancelled;

/// Phase 5 fix (following FCL DownloadList): the files that failed to download during the last import
/// Each record has the shape @{@"fileName":NSString, @"url":NSString, @"reason":NSString}
/// Even when importModpack: returns YES some files may have failed, so the caller can read this property and show it to the user.
@property (nonatomic, copy, readonly) NSArray<NSDictionary *> *failedFiles;

/// Parse a modpack file and return its information dictionary
- (nullable NSDictionary *)parseModpackAtURL:(NSURL *)fileURL error:(NSError **)error;

/// Import a modpack into the game directory
- (BOOL)importModpack:(NSDictionary *)modpackInfo error:(NSError **)error;

/// Import a modpack into the game directory (with progress callbacks)
/// progress: 0.0 ~ 1.0, with stageMessage describing the current stage
- (BOOL)importModpack:(NSDictionary *)modpackInfo
             progress:(void (^_Nullable)(double progress, NSString *stageMessage))progress
                error:(NSError **)error;

/// Get the list of imported modpacks
- (NSArray<NSDictionary *> *)getImportedModpacks;

/// Delete an imported modpack
- (BOOL)deleteModpack:(NSDictionary *)modpackInfo error:(NSError **)error;

/// Reset the cancellation state (called before starting a new import)
- (void)resetCancelState;

@end

NS_ASSUME_NONNULL_END
