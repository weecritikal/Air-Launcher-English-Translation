#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Update information data model
@interface UpdateInfo : NSObject
@property(nonatomic, copy, nullable) NSString *latestVersion;    /* Latest version number (with the v prefix stripped) */
@property(nonatomic, copy, nullable) NSString *currentVersion;   /* Current app version number */
@property(nonatomic, assign) BOOL hasUpdate;                     /* Whether a new version is available */
@property(nonatomic, copy, nullable) NSString *releaseName;      /* Release title */
@property(nonatomic, copy, nullable) NSString *releaseNotes;     /* Changelog (markdown) */
@property(nonatomic, copy, nullable) NSString *htmlURL;          /* Link to the release page */
@property(nonatomic, copy, nullable) NSString *publishedAt;      /* Publication time (ISO8601) */
@property(nonatomic, copy, nullable) NSArray<NSDictionary *> *assets; /* List of downloadable assets */
@end

/// Update checker (modeled on FCL/ZL2, using the GitHub Releases API)
///
/// Stable release check: calls the /releases/latest endpoint, and GitHub automatically returns the newest non-pre-release.
/// Project URL: https://github.com/weecritikal/Air-Launcher-English-Translation
@interface UpdateChecker : NSObject

/// Repository owner
@property(nonatomic, class, readonly) NSString *repoOwner;
/// Repository name
@property(nonatomic, class, readonly) NSString *repoName;
/// Stable releases API URL
@property(nonatomic, class, readonly) NSString *latestReleaseURL;

/// Check for updates (stable releases). The network request runs on a background thread and the callback on the main thread.
/// @param completion callback; info is nil when the request failed (error is non-nil) or parsing failed
+ (void)checkForUpdateWithCompletion:(void(^)(UpdateInfo *_Nullable info, NSError *_Nullable error))completion;

/// Open the release page (in Safari)
+ (void)openReleasePage;

/// Version comparison: returns NSOrderedAscending when v1 < v2
+ (NSComparisonResult)compareVersion:(NSString *)v1 withVersion:(NSString *)v2;

/// Get the current app version number (CFBundleShortVersionString)
+ (NSString *)currentVersion;

@end

NS_ASSUME_NONNULL_END
