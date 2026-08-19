#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Structural validation for downloaded ZIP-based archives (.jar, .zip).
///
/// A jar that is truncated mid-transfer, or an HTML error page a CDN served with a
/// 200 status, is still a non-empty file on disk. Nothing downstream noticed that,
/// so the file was accepted, written into mods/, and only surfaced later as
/// `java.util.zip.ZipException: zip END header not found` while Forge scanned the
/// mods directory — with no indication of which file was at fault. The only way out
/// was deleting the instance and reinstalling everything.
///
/// These checks read a few kilobytes from the head and the tail of a file, never the
/// whole thing, so they are cheap enough to run over an entire mods folder.
@interface ArchiveIntegrity : NSObject

/// YES when the path looks like an archive the launcher should validate (.jar/.zip).
+ (BOOL)isArchivePath:(NSString *)path;

/// Validate a ZIP archive's structure: the local file header magic at the start and a
/// reachable, in-bounds End Of Central Directory record at the end.
/// Returns nil when the archive is intact, or a short human-readable reason when it is not.
+ (nullable NSString *)validationFailureForArchiveAtPath:(NSString *)path;

/// Convenience wrapper around -validationFailureForArchiveAtPath:.
+ (BOOL)isValidArchiveAtPath:(NSString *)path;

/// Validate a file a download task just produced, before it is treated as installed:
/// the HTTP status first (a download task reports no error for a 403 or 404 — the error page is
/// simply delivered as the body), then the archive structure.
/// Returns nil when the file is good, or a short reason to report and retry on.
+ (nullable NSString *)rejectionReasonForDownloadedFile:(NSString *)path
                                               response:(nullable NSURLResponse *)response;

/// Scan a directory (non-recursively) for corrupt .jar files.
/// Returns an array of @{@"name": ..., @"reason": ...} for each bad file.
+ (NSArray<NSDictionary<NSString *, NSString *> *> *)findCorruptArchivesInDirectory:(NSString *)directory;

/// Scan a directory for corrupt .jar files and move each one into a `.air_corrupt`
/// subfolder, so the game can start instead of crashing on it. The subfolder is dot-prefixed
/// and therefore ignored by Forge/Fabric mod discovery, and the files are kept rather than
/// deleted so a bad download can still be inspected.
/// Returns an array of @{@"name": ..., @"reason": ...} for each file moved.
+ (NSArray<NSDictionary<NSString *, NSString *> *> *)quarantineCorruptArchivesInDirectory:(NSString *)directory;

/// Resolve the mods folder of a profile, or nil when it does not exist.
/// Mirrors -[ModService existingModsFolderForProfile:].
+ (nullable NSString *)modsFolderForProfile:(nullable NSString *)profileName;

@end

NS_ASSUME_NONNULL_END
