//
//  NeoForgeDirectInstaller.m
//  Amethyst
//
//  Direct NeoForge installer (new format only, NeoForge 1.20.1+).
//
//  This direct installer downloads the pre-patched PATCHED artifact instead of running the processors from install_profile.json.
//  Reason: the iOS sandbox forbids fork/exec, so a child JVM cannot be spawned to run the processor tools (binarypatcher,
//  jarsplitter, SpecialSource and so on). The common approach for community launchers on restricted platforms is to download
//  the pre-patched client jar NeoForge already publishes (such as neoforge-{loader}-client.jar),
//  which is equivalent to the processors' output and usable as is at runtime.
//
//  The JarJar (JarInJar) mechanism is handled at runtime by modlauncher's JarInJarDependencyLocator,
//  so no processor is needed at install time.
//

#import "ArchiveIntegrity.h"
#import "NeoForgeDirectInstaller.h"
#import "PLProfiles.h"
#import "utils.h"
#import "LauncherPreferences.h"
#import "MinecraftResourceUtils.h"
#import "external/UnzipKit/UZKArchive.h"

NSString *const NeoForgeDirectInstallerErrorDomain = @"NeoForgeDirectInstallerErrorDomain";

@implementation NeoForgeDirectInstaller

#pragma mark - Public

+ (BOOL)installNeoForgeFromInstaller:(NSString *)installerPath
                           versionId:(NSString *)versionId
                               error:(NSError **)error {
    return [self installNeoForgeFromInstaller:installerPath versionId:versionId progress:nil error:error];
}

+ (BOOL)installNeoForgeFromInstaller:(NSString *)installerPath
                           versionId:(NSString *)versionId
                            progress:(void (^)(double progress, NSString *stageMessage))progress
                               error:(NSError **)error {
    return [self installNeoForgeFromInstaller:installerPath
                                    versionId:versionId
                                customGameDir:nil
                          skipRegisterVersion:NO
                                     progress:progress
                                       error:error];
}

+ (BOOL)installNeoForgeFromInstaller:(NSString *)installerPath
                           versionId:(NSString *)versionId
                       customGameDir:(nullable NSString *)customGameDir
                 skipRegisterVersion:(BOOL)skipRegisterVersion
                            progress:(void (^)(double progress, NSString *stageMessage))progress
                               error:(NSError **)error {
    void (^reportProgress)(double, NSString *) = ^(double p, NSString *msg) {
        NSLog(@"[NeoForgeDirect] Progress: %.2f - %@", p, msg);
        if (progress) {
            progress(p, msg);
        }
    };

    @try {
        NSLog(@"[NeoForgeDirect] Starting installation: %@", versionId);
        reportProgress(0.0, @"Starting installation");
        if (error) {
            *error = nil;
        }

        // Step 1: Read install_profile.json
        NSLog(@"[NeoForgeDirect] Reading install_profile.json");
        reportProgress(0.05, @"Reading install_profile.json");
        NSData *profileData = [self dataFromZip:installerPath entry:@"install_profile.json" error:error];
        if (!profileData) {
            NSLog(@"[NeoForgeDirect] Failed to read install_profile.json");
            if (error && !*error) {
                *error = [NSError errorWithDomain:NeoForgeDirectInstallerErrorDomain
                                             code:NeoForgeDirectInstallerErrorMissingProfile
                                         userInfo:@{NSLocalizedDescriptionKey: @"Missing install_profile.json in installer"}];
            }
            return NO;
        }
        NSLog(@"[NeoForgeDirect] Successfully read install_profile.json (%lu bytes)", (unsigned long)profileData.length);

        // Step 2: Parse install_profile.json
        NSLog(@"[NeoForgeDirect] Parsing install_profile.json");
        reportProgress(0.1, @"Parsing JSON");
        NSError *jsonError = nil;
        NSMutableDictionary *installProfile = [NSJSONSerialization JSONObjectWithData:profileData
                                                                              options:NSJSONReadingMutableContainers
                                                                                error:&jsonError];
        NSLog(@"[NeoForgeDirect] JSON parsing completed, error=%@", jsonError ?: @"none");
        if (![installProfile isKindOfClass:[NSDictionary class]] || jsonError) {
            if (error) {
                *error = [NSError errorWithDomain:NeoForgeDirectInstallerErrorDomain
                                             code:NeoForgeDirectInstallerErrorInvalidProfile
                                         userInfo:@{NSLocalizedDescriptionKey: @"Failed to parse install_profile.json"}];
            }
            return NO;
        }

        // NeoForge only uses new format (spec field)
        BOOL isNewFormat = (installProfile[@"spec"] != nil);
        NSLog(@"[NeoForgeDirect] Format detection: new=%d", isNewFormat);
        if (!isNewFormat) {
            if (error) {
                *error = [NSError errorWithDomain:NeoForgeDirectInstallerErrorDomain
                                             code:NeoForgeDirectInstallerErrorInvalidProfile
                                         userInfo:@{NSLocalizedDescriptionKey: @"NeoForge installer uses unknown format (expected new format with spec)"}];
            }
            return NO;
        }

        // Use the custom gameDir when importing a modpack; otherwise use the default POJAV_GAME_DIR
        // Note: gameDir (user.dir, the isolated directory for mods/saves/configs) uses customGameDir,
        // but versionDir and librariesDir must always use POJAV_GAME_DIR (the main directory).
        // Reason: the Java side of the Minecraft launcher always loads from POJAV_GAME_DIR/versions and /libraries,
        // Putting versionDir/librariesDir under customGameDir used to cause "version information not found" at launch.
        NSString *gameDir = customGameDir.length > 0 ? customGameDir : [self gameDirectory];
        NSString *mainGameDir = [self gameDirectory];  // Always use the main directory to store versions and libraries
        NSString *librariesDir = [mainGameDir stringByAppendingPathComponent:@"libraries"];
        NSLog(@"[NeoForgeDirect] Game directory (user.dir): %@", gameDir);
        NSLog(@"[NeoForgeDirect] Main game directory (versions/libraries): %@", mainGameDir);
        NSLog(@"[NeoForgeDirect] Libraries directory: %@", librariesDir);
        reportProgress(0.15, @"Preparing the version folder");

        // Create the libraries directory up front, so later downloads/extractions do not fail
        [[NSFileManager defaultManager] createDirectoryAtPath:librariesDir
                                  withIntermediateDirectories:YES
                                                   attributes:nil
                                                        error:nil];

        BOOL success = [self installNewFormat:installProfile
                               installerPath:installerPath
                                   versionId:versionId
                                     gameDir:gameDir
                               librariesDir:librariesDir
                                    progress:progress
                                      error:error];
        if (!success) {
            NSLog(@"[NeoForgeDirect] Installation failed");
            return NO;
        }

        // Step: Register version in launcher_profiles.json (must run on main thread)
        // Skipped when importing a modpack (ModpackImportService.createProfileForModpack registers it centrally)
        if (!skipRegisterVersion) {
            NSLog(@"[NeoForgeDirect] Registering version on main thread");
            reportProgress(0.95, @"Registering version");
            if ([NSThread isMainThread]) {
                [self registerVersion:versionId];
            } else {
                dispatch_sync(dispatch_get_main_queue(), ^{
                    [self registerVersion:versionId];
                });
            }
            NSLog(@"[NeoForgeDirect] Version registered successfully");
        }

        NSLog(@"[NeoForgeDirect] Installation completed successfully");
        reportProgress(1.0, @"Installation complete");
        return YES;
    }
    @catch (NSException *exception) {
        NSString *stack = [exception.callStackSymbols componentsJoinedByString:@"\n"];
        NSLog(@"[NeoForgeDirect] EXCEPTION: name=%@, reason=%@, callStack=%@", exception.name, exception.reason, stack);
        if (error) {
            *error = [NSError errorWithDomain:NeoForgeDirectInstallerErrorDomain
                                          code:NeoForgeDirectInstallerErrorException
                                      userInfo:@{
                                          NSLocalizedDescriptionKey: [NSString stringWithFormat:@"Installation exception: %@", exception.reason ?: @"Unknown reason"],
                                          NSLocalizedFailureReasonErrorKey: exception.name ?: @"UnknownException"
                                      }];
        }
        return NO;
    }
}

+ (BOOL)isNewFormatInstaller:(NSString *)installerPath {
    NSData *profileData = [self dataFromZip:installerPath entry:@"install_profile.json" error:nil];
    if (!profileData) {
        return NO;
    }

    NSDictionary *dict = [NSJSONSerialization JSONObjectWithData:profileData options:0 error:nil];
    if (![dict isKindOfClass:[NSDictionary class]]) {
        return NO;
    }

    return dict[@"spec"] != nil;
}

#pragma mark - New format (NeoForge 1.20.1+)

+ (BOOL)installNewFormat:(NSDictionary *)installProfile
           installerPath:(NSString *)installerPath
               versionId:(NSString *)versionId
                 gameDir:(NSString *)gameDir
            librariesDir:(NSString *)librariesDir
                progress:(void (^)(double, NSString *))progress
                  error:(NSError **)error {
    NSLog(@"[NeoForgeDirect] installNewFormat started");
    void (^reportProgress)(double, NSString *) = ^(double p, NSString *msg) {
        NSLog(@"[NeoForgeDirect] Progress: %.2f - %@", p, msg);
        if (progress) {
            progress(p, msg);
        }
    };

    // Read version.json
    NSLog(@"[NeoForgeDirect] Reading version.json");
    NSString *versionJsonEntry = installProfile[@"json"];
    if (!versionJsonEntry || ![versionJsonEntry isKindOfClass:[NSString class]]) {
        versionJsonEntry = @"version.json";
    }
    // The version.json path may start with "/", which is stripped uniformly
    if ([versionJsonEntry hasPrefix:@"/"]) {
        versionJsonEntry = [versionJsonEntry substringFromIndex:1];
    }
    NSLog(@"[NeoForgeDirect] version.json entry: %@", versionJsonEntry);

    NSData *versionData = [self dataFromZip:installerPath entry:versionJsonEntry error:error];
    if (!versionData) {
        if (error && !*error) {
            *error = [NSError errorWithDomain:NeoForgeDirectInstallerErrorDomain
                                         code:NeoForgeDirectInstallerErrorMissingProfile
                                     userInfo:@{NSLocalizedDescriptionKey: @"Missing version.json in installer"}];
        }
        return NO;
    }
    NSLog(@"[NeoForgeDirect] Successfully read version.json (%lu bytes)", (unsigned long)versionData.length);

    NSLog(@"[NeoForgeDirect] Parsing version.json");
    NSMutableDictionary *versionJson = [NSJSONSerialization JSONObjectWithData:versionData
                                                                       options:NSJSONReadingMutableContainers
                                                                         error:nil];
    if (![versionJson isKindOfClass:[NSDictionary class]]) {
        if (error) {
            *error = [NSError errorWithDomain:NeoForgeDirectInstallerErrorDomain
                                         code:NeoForgeDirectInstallerErrorInvalidProfile
                                     userInfo:@{NSLocalizedDescriptionKey: @"Failed to parse version.json"}];
        }
        return NO;
    }
    NSLog(@"[NeoForgeDirect] version.json parsed successfully");

    versionJson[@"id"] = versionId;

    // The install_profile libraries are Forge's own installer tooling - ForgeAutoRenamingTool,
    // installertools, jarsplitter, binarypatcher and friends - which exist only to run the
    // processors at install time. iOS cannot run those processors at all, so none of it is
    // needed to play.
    //
    // They used to be merged into the version JSON, whose libraries become the game's classpath
    // AND its module path. ForgeAutoRenamingTool shades ASM, so it landed beside the real
    // org.objectweb.asm and the module system refused to resolve:
    //
    //   ResolutionException: Modules ForgeAutoRenamingTool and org.objectweb.asm
    //   export package org.objectweb.asm to module org.apache.httpcomponents.httpclient
    //
    // The merged list is still used to decide what to fetch - having the jars on disk costs
    // nothing - but the version JSON keeps only the libraries the game actually launches with.
    NSArray *librariesToFetch = versionJson[@"libraries"];
    // Merge the install_profile libraries in, for download purposes only (dedup by name)
    NSLog(@"[NeoForgeDirect] Merging libraries");
    NSArray *profileLibraries = installProfile[@"libraries"];
    if ([profileLibraries isKindOfClass:[NSArray class]] && profileLibraries.count > 0) {
        NSMutableArray *mergedLibraries = [NSMutableArray array];
        NSMutableArray *existingNames = [NSMutableArray array];

        NSArray *versionLibraries = versionJson[@"libraries"];
        if ([versionLibraries isKindOfClass:[NSArray class]]) {
            for (NSDictionary *lib in versionLibraries) {
                [mergedLibraries addObject:lib];
                if ([lib isKindOfClass:[NSDictionary class]]) {
                    NSString *name = lib[@"name"];
                    if ([name isKindOfClass:[NSString class]]) {
                        [existingNames addObject:name];
                    }
                }
            }
        }

        NSUInteger addedCount = 0;
        NSUInteger skippedCount = 0;
        for (NSDictionary *library in installProfile[@"libraries"]) {
            if (![library isKindOfClass:[NSDictionary class]]) continue;
            NSString *name = library[@"name"];
            if (![name isKindOfClass:[NSString class]]) continue;
            if ([existingNames containsObject:name]) {
                skippedCount++;
                continue;
            }
            [mergedLibraries addObject:library];
            [existingNames addObject:name];
            addedCount++;
        }
        NSLog(@"[NeoForgeDirect] Merged libraries: added %lu, skipped %lu duplicates", (unsigned long)addedCount, (unsigned long)skippedCount);
        librariesToFetch = mergedLibraries;
    }

    // Prepare version directory
    // The version JSON must be written into POJAV_GAME_DIR/versions/ (the main directory) rather than the profile gameDir.
    // The Java side of the Minecraft launcher always loads version JSONs from POJAV_GAME_DIR/versions.
    NSString *versionDir = [[self gameDirectory] stringByAppendingPathComponent:[NSString stringWithFormat:@"versions/%@", versionId]];
    NSString *versionJsonPath = [versionDir stringByAppendingPathComponent:[NSString stringWithFormat:@"%@.json", versionId]];
    NSLog(@"[NeoForgeDirect] Version directory: %@", versionDir);
    [[NSFileManager defaultManager] createDirectoryAtPath:versionDir
                              withIntermediateDirectories:YES
                                               attributes:nil
                                                    error:nil];

    // Step A: extract every dependency under maven/ inside installer.jar into the libraries directory
    NSLog(@"[NeoForgeDirect] Extracting all maven entries from installer jar");
    reportProgress(0.2, @"Extracting the embedded maven dependencies");
    NSUInteger extractedCount = [self extractAllMavenEntries:installerPath toLibrariesDir:librariesDir];
    NSLog(@"[NeoForgeDirect] Extracted %lu maven entries", (unsigned long)extractedCount);

    // Step B: download the libraries from versionJson.libraries that are not inside installer.jar
    NSLog(@"[NeoForgeDirect] Downloading missing libraries from maven");
    reportProgress(0.3, @"Downloading missing libraries");
    NSArray *allLibraries = librariesToFetch;
    if ([allLibraries isKindOfClass:[NSArray class]]) {
        [self downloadMissingLibraries:allLibraries librariesDir:librariesDir progress:progress baseProgress:0.3 progressSpan:0.4];
    }

    // Step C: the key step - download the pre-patched PATCHED artifact
    // The processors in install_profile.json would produce the :client jar, but iOS cannot run processors.
    // NeoForge already publishes that pre-patched jar to maven, so it can simply be downloaded.
    NSLog(@"[NeoForgeDirect] Downloading pre-patched client artifact");
    reportProgress(0.75, @"Downloading the pre-patched core jar");
    NSString *mainPath = installProfile[@"path"];

    // Current NeoForge leaves the top-level path null and records the patched artefact under
    // data.PATCHED instead, as a maven coordinate in square brackets. That entry is
    // authoritative - it already names the right artifactId for the version's era - so it is
    // read before anything is derived.
    if (![mainPath isKindOfClass:[NSString class]] || mainPath.length == 0) {
        id patched = installProfile[@"data"][@"PATCHED"];
        NSString *coordinate = nil;
        if ([patched isKindOfClass:[NSDictionary class]]) {
            id client = patched[@"client"] ?: patched[@"server"];
            if ([client isKindOfClass:[NSString class]]) coordinate = client;
        }
        NSCharacterSet *brackets = [NSCharacterSet characterSetWithCharactersInString:@"[] "];
        coordinate = [coordinate stringByTrimmingCharactersInSet:brackets];
        if (coordinate.length > 0) {
            mainPath = coordinate;
            NSLog(@"[NeoForgeDirect] path field absent, using data.PATCHED: %@", mainPath);
        }
    }

    // Last resort: assemble it from the version field (NeoForge 1.20.1 uses the forge artifactId, 1.20.2+ the neoforge artifactId)
    if (![mainPath isKindOfClass:[NSString class]] || mainPath.length == 0) {
        NSString *versionField = installProfile[@"version"];
        if ([versionField isKindOfClass:[NSString class]] && versionField.length > 0) {
            // The NeoForge 1.20.1 path looks like "net.neoforged:forge:1.20.1-47.1.0" (versionField contains "1.20.1-")
            // Other versions have a path like "net.neoforged:neoforge:20.6.119-beta"
            // Note: NeoForge loader version 47.x corresponds to MC 1.20.1, but versionField may just be "47.1.0"
            // without the "1.20.1" substring, so a two-part check is needed (consistent with NeoForgeVersionFetcher.m:54).
            // When versionField starts with "47." but has no MC version prefix, the "1.20.1-" prefix must be added,
            // otherwise the maven coordinates net/neoforged/forge/47.1.0/forge-47.1.0-client.jar would 404.
            if ([versionField containsString:@"1.20.1"] || [versionField hasPrefix:@"47."]) {
                NSString *resolvedVersion = versionField;
                if ([versionField hasPrefix:@"47."] && ![versionField containsString:@"1.20.1"]) {
                    resolvedVersion = [NSString stringWithFormat:@"1.20.1-%@", versionField];
                }
                mainPath = [NSString stringWithFormat:@"net.neoforged:forge:%@", resolvedVersion];
            } else {
                mainPath = [NSString stringWithFormat:@"net.neoforged:neoforge:%@", versionField];
            }
            NSLog(@"[NeoForgeDirect] path field missing, falling back to version field: %@", mainPath);
        }
    }
    if ([mainPath isKindOfClass:[NSString class]] && mainPath.length > 0) {
        if (![self downloadPatchedArtifact:mainPath librariesDir:librariesDir error:error]) {
            NSLog(@"[NeoForgeDirect] Failed to download patched artifact");
            return NO;
        }
    } else {
        // path is a core NeoForge runtime dependency, and its absence causes a ClassNotFoundException at launch
        NSLog(@"[NeoForgeDirect] install_profile.json missing path/version fields, cannot download patched client jar");
        if (error) {
            *error = [NSError errorWithDomain:NeoForgeDirectInstallerErrorDomain
                                         code:NeoForgeDirectInstallerErrorInvalidProfile
                                     userInfo:@{NSLocalizedDescriptionKey: @"install_profile.json is missing the path and version fields, so the pre-patched core jar cannot be located"}];
        }
        return NO;
    }

    // Write version JSON
    NSLog(@"[NeoForgeDirect] Writing version JSON to: %@", versionJsonPath);
    reportProgress(0.9, @"Writing version JSON");
    NSError *writeError = saveJSONToFile(versionJson, versionJsonPath);
    if (writeError) {
        if (error) {
            *error = [NSError errorWithDomain:NeoForgeDirectInstallerErrorDomain
                                         code:NeoForgeDirectInstallerErrorWriteFailed
                                     userInfo:@{NSLocalizedDescriptionKey: [NSString stringWithFormat:@"Failed to write version JSON: %@", writeError.localizedDescription]}];
        }
        return NO;
    }
    NSLog(@"[NeoForgeDirect] Version JSON written successfully");

    // Modeled on FCL/HMCL: make sure the version JSON of the parent version (vanilla MC) exists.
    // The version.json of NeoForge contains fields such as "inheritsFrom": "1.20.1", and at launch the Java side
    // reads versions/{inheritsFrom}/{inheritsFrom}.json and merges it with the NeoForge version.
    // If the user has not installed the vanilla version yet, the launch crashes with a FileNotFoundException.
    NSString *inheritsFrom = [versionJson[@"inheritsFrom"] isKindOfClass:[NSString class]] ? versionJson[@"inheritsFrom"] : nil;
    if (inheritsFrom.length > 0 && ![inheritsFrom isEqualToString:versionId]) {
        NSLog(@"[NeoForgeDirect] Checking parent vanilla version: %@", inheritsFrom);
        NSError *parentError = nil;
        if (![self ensureParentVersionExists:inheritsFrom error:&parentError]) {
            NSLog(@"[NeoForgeDirect] Warning: parent version %@ auto-completion failed: %@", inheritsFrom, parentError.localizedDescription ?: @"Unknown error");
        } else {
            NSLog(@"[NeoForgeDirect] Parent vanilla version ensured: %@", inheritsFrom);
        }
    }

    NSLog(@"[NeoForgeDirect] installNewFormat completed");
    return YES;
}

#pragma mark - Helpers

// Game directory: consistent with the [launchTarget isKindOfClass:NSDictionary.class] branch in JavaLauncher.m
// i.e. $POJAV_HOME/instances/<general.game_directory>/<profile.gameDir>
// But there is no profile yet during a direct install, so gameDir cannot be read and the default "." is used
+ (NSString *)gameDirectory {
    const char *env = getenv("POJAV_GAME_DIR");
    if (env) {
        return [@(env) stringByStandardizingPath];
    }
    return NSHomeDirectory();
}

/// Phase 6 fix (modeled on FCL): use NSURLSession instead of the deprecated NSURLConnection sendSynchronousRequest:
/// for synchronous HTTP downloads. NSURLConnection has been deprecated since iOS 13, and mirrors such as BMCLAPI behaved
/// unreliably on some iOS versions (TLS negotiation failures, timeouts having no effect, 302 redirects not being followed),
/// Failing to fetch the parent version JSON → the NeoForge version cannot find the vanilla version named in inheritsFrom → the launch crashes.
+ (NSData *)downloadDataForRequest:(NSURLRequest *)request error:(NSError **)error {
    if (!request) {
        if (error) {
            *error = [NSError errorWithDomain:NeoForgeDirectInstallerErrorDomain
                                         code:NeoForgeDirectInstallerErrorWriteFailed
                                     userInfo:@{NSLocalizedDescriptionKey: @"nil request"}];
        }
        return nil;
    }
    __block NSData *resultData = nil;
    __block NSError *resultError = nil;
    dispatch_semaphore_t sem = dispatch_semaphore_create(0);
    NSURLSessionDataTask *task = [[NSURLSession sharedSession] dataTaskWithRequest:request
                                                                   completionHandler:^(NSData *data, NSURLResponse *response, NSError *taskError) {
        if (taskError) {
            resultError = taskError;
        } else if ([response isKindOfClass:[NSHTTPURLResponse class]]) {
            NSInteger statusCode = [(NSHTTPURLResponse *)response statusCode];
            if (statusCode >= 400) {
                resultError = [NSError errorWithDomain:NeoForgeDirectInstallerErrorDomain
                                                   code:statusCode
                                               userInfo:@{NSLocalizedDescriptionKey: [NSString stringWithFormat:@"HTTP %ld for %@", (long)statusCode, request.URL.absoluteString]}];
            } else {
                resultData = data;
            }
        } else {
            resultData = data;
        }
        dispatch_semaphore_signal(sem);
    }];
    [task resume];
    long waitResult = dispatch_semaphore_wait(sem, dispatch_time(DISPATCH_TIME_NOW, 60 * NSEC_PER_SEC));
    if (waitResult != 0) {
        [task cancel];
        if (error) {
            *error = [NSError errorWithDomain:NeoForgeDirectInstallerErrorDomain
                                         code:NSURLErrorTimedOut
                                     userInfo:@{NSLocalizedDescriptionKey: [NSString stringWithFormat:@"Request timed out (60s): %@", request.URL.absoluteString]}];
        }
        return nil;
    }
    if (error) *error = resultError;
    return resultData;
}

/// Modeled on FCL/HMCL: make sure the version JSON of the parent version (vanilla MC) exists.
/// The version.json of NeoForge contains fields such as "inheritsFrom": "1.20.1", and at launch the Java side
/// Tools.getVersionInfo() on the Java side reads versions/{inheritsFrom}/{inheritsFrom}.json and merges it with the current version.
/// If the user has not installed the vanilla version yet, the launch crashes with a FileNotFoundException.
/// This method only downloads the parent version's version JSON (not the vanilla client.jar, because the iOS launcher uses
/// its own rendering pipeline and does not need the vanilla client.jar; the JSON is needed for metadata such as mainClass, arguments,
/// assetIndex and the vanilla libraries).
+ (BOOL)ensureParentVersionExists:(NSString *)parentVersionId error:(NSError **)error {
    if (parentVersionId.length == 0) return YES;

    NSString *mainGameDir = [self gameDirectory];
    NSString *parentVersionDir = [mainGameDir stringByAppendingPathComponent:
                                  [NSString stringWithFormat:@"versions/%@", parentVersionId]];
    NSString *parentJsonPath = [parentVersionDir stringByAppendingPathComponent:
                                [NSString stringWithFormat:@"%@.json", parentVersionId]];

    // 1. The parent version JSON already exists, so there is nothing to download
    if ([NSFileManager.defaultManager fileExistsAtPath:parentJsonPath]) {
        NSLog(@"[NeoForgeDirect] Parent version JSON already exists: %@", parentJsonPath);
        return YES;
    }

    NSLog(@"[NeoForgeDirect] Parent version JSON missing, downloading: %@", parentVersionId);

    // 2. Fetch the Mojang version manifest
    NSString *downloadSource = getPrefObject(@"general.download_source");
    BOOL useBMCLAPI = [downloadSource isEqualToString:@"bmclapi"];
    NSString *manifestURL = useBMCLAPI
        ? @"https://bmclapi2.bangbang93.com/mc/game/version_manifest_v2.json"
        : @"https://piston-meta.mojang.com/mc/game/version_manifest_v2.json";

    NSURL *url = [NSURL URLWithString:manifestURL];
    if (!url) {
        if (error) {
            *error = [NSError errorWithDomain:NeoForgeDirectInstallerErrorDomain
                                         code:NeoForgeDirectInstallerErrorWriteFailed
                                     userInfo:@{NSLocalizedDescriptionKey: @"Invalid manifest URL"}];
        }
        return NO;
    }

    NSMutableURLRequest *manifestRequest = [NSMutableURLRequest requestWithURL:url];
    manifestRequest.timeoutInterval = 30.0;
    manifestRequest.cachePolicy = NSURLRequestReloadIgnoringLocalCacheData;
    [manifestRequest setValue:@"Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15" forHTTPHeaderField:@"User-Agent"];

    NSData *manifestData = [self downloadDataForRequest:manifestRequest error:error];
    if (!manifestData) {
        NSLog(@"[NeoForgeDirect] Failed to download version manifest: %@", error ? [*error localizedDescription] : @"unknown");
        return NO;
    }

    NSDictionary *manifest = [NSJSONSerialization JSONObjectWithData:manifestData options:0 error:nil];
    NSArray *versions = [manifest isKindOfClass:[NSDictionary class]] ? manifest[@"versions"] : nil;
    if (![versions isKindOfClass:[NSArray class]]) {
        if (error) {
            *error = [NSError errorWithDomain:NeoForgeDirectInstallerErrorDomain
                                         code:NeoForgeDirectInstallerErrorInvalidProfile
                                     userInfo:@{NSLocalizedDescriptionKey: @"Invalid version manifest format"}];
        }
        return NO;
    }

    // 3. Find the matching version entry and get its version JSON URL
    NSString *versionJSONURL = nil;
    for (NSDictionary *v in versions) {
        if ([v isKindOfClass:[NSDictionary class]] && [v[@"id"] isEqualToString:parentVersionId]) {
            versionJSONURL = [v[@"url"] isKindOfClass:[NSString class]] ? v[@"url"] : nil;
            break;
        }
    }
    if (!versionJSONURL) {
        if (error) {
            *error = [NSError errorWithDomain:NeoForgeDirectInstallerErrorDomain
                                         code:NeoForgeDirectInstallerErrorInvalidProfile
                                     userInfo:@{NSLocalizedDescriptionKey: [NSString stringWithFormat:@"Version %@ not found in manifest", parentVersionId]}];
        }
        return NO;
    }

    // BMCLAPI mirror: replace the official Mojang domain with the BMCLAPI domain
    if (useBMCLAPI) {
        versionJSONURL = [versionJSONURL stringByReplacingOccurrencesOfString:@"piston-meta.mojang.com"
                                                                    withString:@"bmclapi2.bangbang93.com"];
        versionJSONURL = [versionJSONURL stringByReplacingOccurrencesOfString:@"launchermeta.mojang.com"
                                                                    withString:@"bmclapi2.bangbang93.com"];
    }

    NSLog(@"[NeoForgeDirect] Downloading parent version JSON from: %@", versionJSONURL);

    // 4. Download the version JSON
    NSURL *jsonURL = [NSURL URLWithString:versionJSONURL];
    if (!jsonURL) {
        if (error) {
            *error = [NSError errorWithDomain:NeoForgeDirectInstallerErrorDomain
                                         code:NeoForgeDirectInstallerErrorWriteFailed
                                     userInfo:@{NSLocalizedDescriptionKey: @"Invalid version JSON URL"}];
        }
        return NO;
    }

    NSMutableURLRequest *jsonRequest = [NSMutableURLRequest requestWithURL:jsonURL];
    jsonRequest.timeoutInterval = 30.0;
    jsonRequest.cachePolicy = NSURLRequestReloadIgnoringLocalCacheData;
    [jsonRequest setValue:@"Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15" forHTTPHeaderField:@"User-Agent"];

    NSData *jsonData = [self downloadDataForRequest:jsonRequest error:error];
    if (!jsonData) {
        NSLog(@"[NeoForgeDirect] Failed to download parent version JSON: %@", error ? [*error localizedDescription] : @"unknown");
        return NO;
    }

    // 5. Create the parent version directory and write the JSON
    NSError *dirError = nil;
    [NSFileManager.defaultManager createDirectoryAtPath:parentVersionDir
                            withIntermediateDirectories:YES
                                             attributes:nil
                                                  error:&dirError];
    if (dirError) {
        NSLog(@"[NeoForgeDirect] Failed to create parent version dir: %@", dirError.localizedDescription);
        if (error) *error = dirError;
        return NO;
    }

    NSError *writeErr = nil;
    if (![jsonData writeToFile:parentJsonPath options:NSDataWritingAtomic error:&writeErr]) {
        NSLog(@"[NeoForgeDirect] Failed to write parent version JSON: %@", writeErr.localizedDescription);
        if (error) *error = writeErr;
        return NO;
    }

    NSLog(@"[NeoForgeDirect] Parent version JSON saved: %@ (%lu bytes)", parentJsonPath, (unsigned long)jsonData.length);
    return YES;
}

+ (void)registerVersion:(NSString *)versionId {
    NSLog(@"[NeoForgeDirect] registerVersion called: %@", versionId);
    PLProfiles *profiles = [PLProfiles current];
    NSLog(@"[NeoForgeDirect] PLProfiles current: %@", profiles ? @"ok" : @"nil");
    NSMutableDictionary *profileDict = [NSMutableDictionary dictionary];
    profileDict[@"name"] = versionId;
    profileDict[@"lastVersionId"] = versionId;
    // Back to the original "switch game directory" model: every version shares the root directory (gameDir=".")
    // The user switches between game directories manually with the "Switch game directory" feature in settings
    profileDict[@"gameDir"] = @".";
    profileDict[@"type"] = @"custom";
    profileDict[@"created"] = [NSDate date].description;
    // Infer the Java version: NeoForge 1.20.5+ needs Java 21, 1.18+ needs Java 17, 1.17 needs Java 16
    NSInteger javaMajor = [self inferJavaMajorVersionFromVersionId:versionId];
    // Write an NSString rather than an NSDictionary, consistent with every reader such as ProfileSettingsViewController
    // JavaLauncher reads it with .intValue, and "17".intValue = 17
    profileDict[@"javaVersion"] = [NSString stringWithFormat:@"%ld", (long)javaMajor];
    [profiles saveProfile:profileDict withName:versionId];
    // Consistent with the Fabric / Vanilla installation paths: select the newly created profile automatically, so the user does not return to the main screen and still launch the old version
    profiles.selectedProfileName = versionId;
    NSLog(@"[NeoForgeDirect] Profile saved and selected (javaVersion=%ld, gameDir=%@)", (long)javaMajor, profileDict[@"gameDir"]);
}

/// Infer the required Java major version from the versionId
/// versionId may take one of two forms:
///   - Modpack path: "{mc}-neoforge-{loader}", such as "1.20.1-neoforge-47.1.0" or "1.21.5-neoforge-21.5.75"
///   - UI path: "NeoForge-{loader}", such as "NeoForge-47.1.0" or "NeoForge-21.5.75"
/// Both must be handled: try matching the MC version directly first, and on failure derive the MC version from the NeoForge loader version number
+ (NSInteger)inferJavaMajorVersionFromVersionId:(NSString *)versionId {
    // 1. First try to match an MC version in the "1.x.x" form (covering the modpack path, and the edge case where the UI path contains a 1.x.x)
    //    Anchoring at the start (^|[-_]) avoids matching a "1.x" substring inside the loader version number
    NSRegularExpression *regex = [NSRegularExpression regularExpressionWithPattern:@"(?:^|[-_])1\\.(\\d+)(?:\\.(\\d+))?"
                                                                           options:0
                                                                             error:nil];
    NSTextCheckingResult *match = [regex firstMatchInString:versionId options:0 range:NSMakeRange(0, versionId.length)];
    if (match && match.numberOfRanges >= 2) {
        NSString *minorStr = [versionId substringWithRange:[match rangeAtIndex:1]];
        NSInteger minor = [minorStr integerValue];
        NSString *patchStr = (match.numberOfRanges >= 3 && [match rangeAtIndex:2].location != NSNotFound)
                            ? [versionId substringWithRange:[match rangeAtIndex:2]]
                            : @"0";
        NSInteger patch = [patchStr integerValue];
        if (minor >= 21) return 21;                  // 1.21+
        if (minor >= 20 && patch >= 5) return 21;    // 1.20.5+
        if (minor >= 18) return 17;                  // 1.18 - 1.20.4
        if (minor >= 17) return 17;                  // 1.17 (NeoForge requires at least 17, and Java 17 can run 1.17 in a backward-compatible way)
        return 17;                                    // 1.16 and below (unsupported by NeoForge, but 17 is returned conservatively)
    }

    // 2. When the match fails (the UI path where versionId = "NeoForge-{loader}"), derive the MC version from the NeoForge loader version number
    //    NeoForge version number conventions:
    //      - 47.x.y         → MC 1.20.1（legacy forge artifactId）→ Java 17
    //      - 20.2.x - 20.4.x → MC 1.20.2-1.20.4                     → Java 17
    //      - 20.5.x - 20.6.x → MC 1.20.5-1.20.6                     → Java 21
    //      - 21.x.x          → MC 1.21.x                            → Java 21
    //      - 26.x.x+         → MC 1.26.x+ (future versions)               → Java 21
    NSString *loaderVersion = [self extractNeoForgeLoaderVersionFromVersionId:versionId];
    if (loaderVersion.length > 0) {
        NSArray *parts = [loaderVersion componentsSeparatedByString:@"."];
        if (parts.count >= 2) {
            NSInteger major = [parts[0] integerValue];
            NSInteger minor = (parts.count >= 2) ? [parts[1] integerValue] : 0;
            // 47.x（1.20.1 legacy）→ Java 17
            if (major == 47) return 17;
            // The 20.x series: 20.5+ → Java 21, 20.2-20.4 → Java 17
            if (major == 20) {
                return (minor >= 5) ? 21 : 17;
            }
            // 21.x and above (1.21+) → Java 21
            if (major >= 21) return 21;
        }
    }

    return 17; // NeoForge requires at least Java 17
}

/// Extract the NeoForge loader version number from the versionId
/// "NeoForge-21.5.75" → "21.5.75"
/// "1.20.1-neoforge-47.1.0" → "47.1.0"
/// "1.21.5-neoforge-21.5.75-beta" → "21.5.75-beta"
+ (NSString *)extractNeoForgeLoaderVersionFromVersionId:(NSString *)versionId {
    if (!versionId.length) return @"";
    // Modpack path format: "{mc}-neoforge-{loader}"
    NSString *marker = @"-neoforge-";
    NSRange markerRange = [versionId rangeOfString:marker options:NSCaseInsensitiveSearch];
    if (markerRange.location != NSNotFound) {
        return [versionId substringFromIndex:markerRange.location + markerRange.length];
    }
    // UI path format: "NeoForge-{loader}"
    NSRange dashRange = [versionId rangeOfString:@"-"];
    if (dashRange.location != NSNotFound) {
        return [versionId substringFromIndex:dashRange.location + dashRange.length];
    }
    return versionId;
}

#pragma mark - Maven entry Extraction

// Extract every file under the maven/ directory inside installer.jar into the libraries directory
// Returns the number of files extracted successfully
+ (NSUInteger)extractAllMavenEntries:(NSString *)installerPath toLibrariesDir:(NSString *)librariesDir {
    NSError *openError = nil;
    UZKArchive *archive = [[UZKArchive alloc] initWithPath:installerPath error:&openError];
    if (!archive || openError) {
        NSLog(@"[NeoForgeDirect] extractAllMavenEntries: failed to open archive: %@", openError.localizedDescription ?: @"unknown");
        return 0;
    }

    NSError *listError = nil;
    NSArray<NSString *> *filenames = [archive listFilenames:&listError];
    if (!filenames || listError) {
        NSLog(@"[NeoForgeDirect] extractAllMavenEntries: failed to list filenames: %@", listError.localizedDescription ?: @"unknown");
        return 0;
    }

    NSUInteger count = 0;
    NSFileManager *fm = [NSFileManager defaultManager];
    for (NSString *name in filenames) {
        if (![name hasPrefix:@"maven/"]) continue;
        // Skip directory entries (those ending in /), so extractDataFromFile returning empty data does not produce misleading log lines
        if ([name hasSuffix:@"/"]) continue;

        NSString *relativePath = [name substringFromIndex:@"maven/".length];
        if (relativePath.length == 0) continue;

        NSString *destPath = [librariesDir stringByAppendingPathComponent:relativePath];
        // Skip files that already exist, to avoid extracting them twice (in the reinstall case)
        if ([fm fileExistsAtPath:destPath]) {
            count++;
            continue;
        }

        // Extract using the already opened archive instance, instead of reopening the zip for every file (a performance optimization)
        NSError *extractError = nil;
        NSData *data = [archive extractDataFromFile:name error:&extractError];
        if (!data || extractError) {
            NSLog(@"[NeoForgeDirect] extractAllMavenEntries: failed to extract %@: %@", name, extractError.localizedDescription ?: @"unknown");
            continue;
        }

        // Create the target directory
        NSString *destDir = [destPath stringByDeletingLastPathComponent];
        [fm createDirectoryAtPath:destDir withIntermediateDirectories:YES attributes:nil error:nil];

        // Write the file
        NSError *writeError = nil;
        if (![data writeToFile:destPath options:NSDataWritingAtomic error:&writeError]) {
            NSLog(@"[NeoForgeDirect] extractAllMavenEntries: failed to write %@: %@", destPath, writeError.localizedDescription ?: @"unknown");
            continue;
        }
        count++;
    }
    return count;
}

#pragma mark - Library Download

// Download the libraries from version.json.libraries that do not exist yet
+ (void)downloadMissingLibraries:(NSArray *)libraries
                   librariesDir:(NSString *)librariesDir
                       progress:(void (^)(double, NSString *))progress
                   baseProgress:(double)base
                  progressSpan:(double)span {
    NSUInteger total = libraries.count;
    if (total == 0) return;

    NSFileManager *fm = [NSFileManager defaultManager];
    NSUInteger downloaded = 0;
    NSUInteger skipped = 0;
    NSUInteger failed = 0;
    NSUInteger processed = 0;  // Number processed (used for the progress calculation, counting successes/skips/failures)
    NSMutableArray<NSString *> *criticalFailures = [NSMutableArray array];  // List of failed critical libraries

    for (NSDictionary *library in libraries) {
        if (![library isKindOfClass:[NSDictionary class]]) continue;

        NSString *name = [library[@"name"] isKindOfClass:[NSString class]] ? library[@"name"] : nil;
        if (!name) continue;

        // Modeled on FCL/HMCL: evaluate the library's OS rules, treating iOS as osx.
        // Skip libraries enabled only on Windows/Linux (such as natives-windows and Twitch platform libraries),
        // to avoid downloading useless native binaries and running into 404s.
        id rulesObj = library[@"rules"];
        if ([rulesObj isKindOfClass:[NSArray class]] && [(NSArray *)rulesObj count] > 0) {
            if (![MinecraftResourceUtils evaluateRules:(NSArray *)rulesObj]) {
                NSLog(@"[NeoForgeDirect] Skipping library %@ (OS rules disallow osx/iOS)", name);
                skipped++;
                processed++;
                continue;
            }
        }

        // Resolve the target path
        NSString *relativePath = nil;
        NSDictionary *downloads = library[@"downloads"];
        if ([downloads isKindOfClass:[NSDictionary class]]) {
            NSDictionary *artifact = downloads[@"artifact"];
            if ([artifact isKindOfClass:[NSDictionary class]]) {
                id artifactPathObj = artifact[@"path"];
                if ([artifactPathObj isKindOfClass:[NSString class]] && [(NSString *)artifactPathObj length] > 0) {
                    relativePath = (NSString *)artifactPathObj;
                }
            }
        }
        if (!relativePath) {
            relativePath = [self mavenPathToRelativePath:name];
        }
        if (relativePath.length == 0) continue;

        NSString *destPath = [librariesDir stringByAppendingPathComponent:relativePath];

        // Skip it if it already exists — but only when it is actually intact. A library left
        // behind by an earlier failed download used to be skipped forever on this check alone,
        // so no amount of reinstalling could ever replace it.
        if ([fm fileExistsAtPath:destPath]) {
            NSString *corruption = [ArchiveIntegrity isArchivePath:destPath]
                ? [ArchiveIntegrity validationFailureForArchiveAtPath:destPath] : nil;
            if (!corruption) {
                skipped++;
                processed++;
                continue;
            }
            NSLog(@"[NeoForgeDirect] Existing library %@ is corrupt (%@), downloading it again", name, corruption);
            [fm removeItemAtPath:destPath error:nil];
        }

        // Assemble the URL
        NSString *url = nil;
        if ([downloads isKindOfClass:[NSDictionary class]]) {
            NSDictionary *artifact = downloads[@"artifact"];
            if ([artifact isKindOfClass:[NSDictionary class]]) {
                id urlObj = artifact[@"url"];
                if ([urlObj isKindOfClass:[NSString class]] && [(NSString *)urlObj length] > 0) {
                    url = (NSString *)urlObj;
                }
            }
        }
        if (!url) {
            url = [self buildMavenURLForLibrary:name relativePath:relativePath];
        }

        if (!url) {
            NSLog(@"[NeoForgeDirect] Cannot build URL for library %@, skipping", name);
            failed++;
            processed++;
            continue;
        }

        // Compute progress from processed (so progress does not stall on failures)
        if (progress) {
            double p = base + span * ((double)processed / (double)total);
            progress(p, [NSString stringWithFormat:@"Downloading libraries (%lu/%lu): %@", (unsigned long)(processed + 1), (unsigned long)total, name]);
        }

        NSError *downloadError = nil;
        if ([self downloadFileFromURL:url toPath:destPath error:&downloadError]) {
            downloaded++;
            NSLog(@"[NeoForgeDirect] Downloaded library: %@", name);
        } else {
            // The primary source failed: try the fallback source
            NSLog(@"[NeoForgeDirect] Primary source failed for %@, trying fallback: %@", name, downloadError.localizedDescription ?: @"unknown");
            NSString *fallbackURL = [self buildFallbackURLForLibrary:name relativePath:relativePath];
            if (fallbackURL && ![fallbackURL isEqualToString:url]) {
                NSError *fallbackError = nil;
                if ([self downloadFileFromURL:fallbackURL toPath:destPath error:&fallbackError]) {
                    downloaded++;
                    NSLog(@"[NeoForgeDirect] Downloaded library via fallback: %@", name);
                    processed++;
                    continue;
                }
                NSLog(@"[NeoForgeDirect] Fallback also failed for %@: %@", name, fallbackError.localizedDescription ?: @"unknown");
            }
            failed++;
            // A failed critical library crashes the launch, so log a warning
            if ([self isCriticalLibrary:name]) {
                [criticalFailures addObject:name];
                NSLog(@"[NeoForgeDirect] Warning: critical library download failed (app will crash on launch): %@", name);
            } else {
                NSLog(@"[NeoForgeDirect] Failed to download library %@ (both sources failed)", name);
            }
        }
        processed++;
    }

    NSLog(@"[NeoForgeDirect] Library download summary: downloaded=%lu, skipped=%lu, failed=%lu, total=%lu, criticalFailures=%lu",
          (unsigned long)downloaded, (unsigned long)skipped, (unsigned long)failed, (unsigned long)total, (unsigned long)criticalFailures.count);
    if (criticalFailures.count > 0) {
        NSLog(@"[NeoForgeDirect] Warning: critical library download failures: %@", criticalFailures);
    }
}

/// Determine whether this is a critical library (one whose absence crashes the launch)
+ (BOOL)isCriticalLibrary:(NSString *)name {
    if (!name.length) return NO;
    NSArray<NSString *> *criticalPrefixes = @[
        @"cpw.mods:modlauncher",
        @"net.minecraftforge.bootstraplauncher",
        @"net.minecraftforge:forge",
        @"net.neoforged:forge",
        @"net.neoforged:neoforge",
        @"net.neoforged.fancymodloader",
        @"org.spongepowered:mixin",
        @"org.ow2.asm:asm",
        @"com.google.guava:guava",
        @"com.google.code.gson:gson",
        @"org.lwjgl:lwjgl",
        @"com.mojang:authlib",
        @"com.mojang:brigadier",
        @"com.mojang:datafixerupper",
        @"com.mojang:minecraft"
    ];
    for (NSString *prefix in criticalPrefixes) {
        if ([name hasPrefix:prefix]) return YES;
    }
    return NO;
}

// Build the maven URL for a library
// Optimized routing: match the groupId precisely to the correct maven repository, to avoid 404s
+ (NSString *)buildMavenURLForLibrary:(NSString *)name relativePath:(NSString *)relativePath {
    NSString *downloadSource = getPrefObject(@"general.download_source");
    BOOL useBMCLAPI = [downloadSource isEqualToString:@"bmclapi"];

    // NeoForge's own libraries come from maven.neoforged.net/releases
    if ([name hasPrefix:@"net.neoforged:"] || [name hasPrefix:@"net.neoforged."] || [name hasPrefix:@"cpw.mods:"]) {
        if (useBMCLAPI) {
            return [NSString stringWithFormat:@"https://bmclapi2.bangbang93.com/maven/%@", relativePath];
        }
        return [NSString stringWithFormat:@"https://maven.neoforged.net/releases/%@", relativePath];
    }

    // Forge's own libraries come from maven.minecraftforge.net
    if ([name hasPrefix:@"net.minecraftforge:"]) {
        if (useBMCLAPI) {
            return [NSString stringWithFormat:@"https://bmclapi2.bangbang93.com/maven/%@", relativePath];
        }
        return [NSString stringWithFormat:@"https://maven.minecraftforge.net/%@", relativePath];
    }

    // SpongePowered (mixin and the like) comes from repo.spongepowered.org
    if ([name hasPrefix:@"org.spongepowered:"]) {
        if (useBMCLAPI) {
            return [NSString stringWithFormat:@"https://bmclapi2.bangbang93.com/maven/%@", relativePath];
        }
        return [NSString stringWithFormat:@"https://repo.spongepowered.org/repository/maven-public/%@", relativePath];
    }

    // oceanlabs and asm come from maven.minecraftforge.net
    if ([name hasPrefix:@"de.oceanlabs.mcp:"] || [name hasPrefix:@"org.ow2.asm:"]) {
        if (useBMCLAPI) {
            return [NSString stringWithFormat:@"https://bmclapi2.bangbang93.com/maven/%@", relativePath];
        }
        return [NSString stringWithFormat:@"https://maven.minecraftforge.net/%@", relativePath];
    }

    // Other libraries (Mojang, lwjgl and so on) come from libraries.minecraft.net (the BMCLAPI mirror)
    if (useBMCLAPI) {
        return [NSString stringWithFormat:@"https://bmclapi2.bangbang93.com/maven/%@", relativePath];
    }
    return [NSString stringWithFormat:@"https://libraries.minecraft.net/%@", relativePath];
}

/// Build the fallback URL (switching to the BMCLAPI mirror when the primary source fails, or vice versa)
+ (NSString *)buildFallbackURLForLibrary:(NSString *)name relativePath:(NSString *)relativePath {
    NSString *downloadSource = getPrefObject(@"general.download_source");
    BOOL useBMCLAPI = [downloadSource isEqualToString:@"bmclapi"];

    if (useBMCLAPI) {
        // BMCLAPI failed, so try the official source
        if ([name hasPrefix:@"net.neoforged:"] || [name hasPrefix:@"net.neoforged."] || [name hasPrefix:@"cpw.mods:"]) {
            return [NSString stringWithFormat:@"https://maven.neoforged.net/releases/%@", relativePath];
        }
        if ([name hasPrefix:@"net.minecraftforge:"] || [name hasPrefix:@"de.oceanlabs.mcp:"] || [name hasPrefix:@"org.ow2.asm:"]) {
            return [NSString stringWithFormat:@"https://maven.minecraftforge.net/%@", relativePath];
        }
        if ([name hasPrefix:@"org.spongepowered:"]) {
            return [NSString stringWithFormat:@"https://repo.spongepowered.org/repository/maven-public/%@", relativePath];
        }
        return [NSString stringWithFormat:@"https://libraries.minecraft.net/%@", relativePath];
    }
    // The official source failed, so try the BMCLAPI mirror
    return [NSString stringWithFormat:@"https://bmclapi2.bangbang93.com/maven/%@", relativePath];
}

// Download the pre-patched PATCHED artifact
// mainPath format: "net.neoforged:forge:1.20.1-47.3.0" (older NeoForge) or "net.neoforged:neoforge:21.5.75" (newer NeoForge)
// which maps to the :client classifier jar on maven:
//   Official source: https://maven.neoforged.net/releases/net/neoforged/{forge|neoforge}/{ver}/{forge|neoforge}-{ver}-client.jar
//   BMCLAPI: https://bmclapi2.bangbang93.com/maven/net/neoforged/{forge|neoforge}/{ver}/{forge|neoforge}-{ver}-client.jar
+ (BOOL)downloadPatchedArtifact:(NSString *)mainPath librariesDir:(NSString *)librariesDir error:(NSError **)error {
    NSArray *parts = [mainPath componentsSeparatedByString:@":"];
    if (parts.count < 3) {
        if (error) {
            *error = [NSError errorWithDomain:NeoForgeDirectInstallerErrorDomain
                                         code:NeoForgeDirectInstallerErrorInvalidProfile
                                     userInfo:@{NSLocalizedDescriptionKey: [NSString stringWithFormat:@"Invalid main path: %@", mainPath]}];
        }
        return NO;
    }

    NSString *groupId = parts[0];
    NSString *artifactId = parts[1];
    NSString *version = parts[2];

    NSString *groupPath = [groupId stringByReplacingOccurrencesOfString:@"." withString:@"/"];

    // Modeled on FCL/HMCL: in practice the NeoForge maven (for example 21.1.77) publishes only -universal (HTTP 200),
    // while -client and the classifier-less form both 404. The order was therefore changed to universal -> client -> no classifier,
    // trying the most likely universal first.
    NSArray *classifiers = @[@"universal", @"client", @""];
    NSString *downloadSource = getPrefObject(@"general.download_source");
    BOOL useBMCLAPI = [downloadSource isEqualToString:@"bmclapi"];

    // Source URL construction: the official source + BMCLAPI + the HMCL mirror
    // mirror.hua-u.me was listed here as a last resort. Its hostname no longer resolves, so
    // every attempt ended on a DNS failure that masked the real error.
    NSMutableArray *baseURLs = [NSMutableArray array];
    if ([groupId hasPrefix:@"net.neoforged"]) {
        if (useBMCLAPI) {
            [baseURLs addObject:@"https://bmclapi2.bangbang93.com/maven"];
            [baseURLs addObject:@"https://maven.neoforged.net/releases"];
        } else {
            [baseURLs addObject:@"https://maven.neoforged.net/releases"];
            [baseURLs addObject:@"https://bmclapi2.bangbang93.com/maven"];
        }
    } else {
        // Fallback: treat it as Forge
        if (useBMCLAPI) {
            [baseURLs addObject:@"https://bmclapi2.bangbang93.com/maven"];
            [baseURLs addObject:@"https://maven.minecraftforge.net"];
        } else {
            [baseURLs addObject:@"https://maven.minecraftforge.net"];
            [baseURLs addObject:@"https://bmclapi2.bangbang93.com/maven"];
        }
    }

    NSError *lastError = nil;
    NSString *firstTriedURL = nil;
    for (NSString *classifier in classifiers) {
        NSString *jarName;
        if (classifier.length > 0) {
            jarName = [NSString stringWithFormat:@"%@-%@-%@.jar", artifactId, version, classifier];
        } else {
            jarName = [NSString stringWithFormat:@"%@-%@.jar", artifactId, version];
        }
        NSString *relativePath = [NSString stringWithFormat:@"%@/%@/%@/%@", groupPath, artifactId, version, jarName];
        NSString *destPath = [librariesDir stringByAppendingPathComponent:relativePath];

        // Skip it if it already exists, provided it can actually be opened
        if ([NSFileManager.defaultManager fileExistsAtPath:destPath]) {
            NSString *corruption = [ArchiveIntegrity validationFailureForArchiveAtPath:destPath];
            if (!corruption) {
                NSLog(@"[NeoForgeDirect] Patched artifact already exists: %@", destPath);
                return YES;
            }
            NSLog(@"[NeoForgeDirect] Existing patched artifact is corrupt (%@), downloading it again", corruption);
            [NSFileManager.defaultManager removeItemAtPath:destPath error:nil];
        }

        for (NSString *baseURL in baseURLs) {
            NSString *url = [NSString stringWithFormat:@"%@/%@", baseURL, relativePath];
            if (firstTriedURL == nil) firstTriedURL = url;
            NSLog(@"[NeoForgeDirect] Trying classifier=%@ source=%@", classifier, url);
            NSError *downloadError = nil;
            if ([self downloadFileFromURL:url toPath:destPath error:&downloadError]) {
                NSLog(@"[NeoForgeDirect] Patched artifact downloaded: %@ (classifier=%@)", destPath, classifier);
                return YES;
            }
            // Download failed: clean up any partial file
            [NSFileManager.defaultManager removeItemAtPath:destPath error:nil];
            lastError = downloadError;
            NSLog(@"[NeoForgeDirect] Failed: %@ (%@)", url, downloadError.localizedDescription ?: @"Unknown error");
        }
    }

    if (error) {
        *error = [NSError errorWithDomain:NeoForgeDirectInstallerErrorDomain
                                     code:NeoForgeDirectInstallerErrorExtractionFailed
                                 userInfo:@{
                                     NSLocalizedDescriptionKey: [NSString stringWithFormat:@"Failed to download the pre-patched core jar\nPrimary URL: %@\nClassifiers tried: client/universal/none\nSources tried: official/BMCLAPI/HMCL mirror\nLast error: %@",
                                         firstTriedURL ?: @"Unknown",
                                         lastError.localizedDescription ?: @"Unknown error"]
                                 }];
    }
    return NO;
}

// Download a file synchronously to the given path (with a 60 second timeout)
+ (BOOL)downloadFileFromURL:(NSString *)urlString toPath:(NSString *)destPath error:(NSError **)error {
    if (error) *error = nil;

    NSURL *url = [NSURL URLWithString:urlString];
    if (!url) {
        if (error) {
            *error = [NSError errorWithDomain:NeoForgeDirectInstallerErrorDomain
                                         code:NeoForgeDirectInstallerErrorWriteFailed
                                     userInfo:@{NSLocalizedDescriptionKey: [NSString stringWithFormat:@"Invalid URL: %@", urlString]}];
        }
        return NO;
    }

    NSString *destDir = [destPath stringByDeletingLastPathComponent];
    NSError *dirError = nil;
    [NSFileManager.defaultManager createDirectoryAtPath:destDir
                            withIntermediateDirectories:YES
                                             attributes:nil
                                                  error:&dirError];
    if (dirError) {
        if (error) {
            *error = [NSError errorWithDomain:NeoForgeDirectInstallerErrorDomain
                                         code:NeoForgeDirectInstallerErrorWriteFailed
                                     userInfo:@{NSLocalizedDescriptionKey: [NSString stringWithFormat:@"Failed to create directory %@: %@", destDir, dirError.localizedDescription]}];
        }
        return NO;
    }

    // Download synchronously with NSURLSession and a 60 second timeout (so dataWithContentsOfURL does not hang on a weak connection)
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:url];
    request.timeoutInterval = 60.0;
    request.cachePolicy = NSURLRequestReloadIgnoringLocalCacheData;
    // Add a User-Agent: modeled on FCL, a browser-style user agent improves compatibility with BMCLAPI/Cloudflare sources.
    [request setValue:@"Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15" forHTTPHeaderField:@"User-Agent"];
    [request setValue:@"application/java-archive,*/*;q=0.9" forHTTPHeaderField:@"Accept"];

    __block NSData *resultData = nil;
    __block NSError *resultError = nil;
    dispatch_semaphore_t semaphore = dispatch_semaphore_create(0);

    NSURLSessionDataTask *task = [[NSURLSession sharedSession] dataTaskWithRequest:request
                                                                     completionHandler:^(NSData *data, NSURLResponse *response, NSError *taskError) {
        if (taskError) {
            resultError = taskError;
        } else if ([response isKindOfClass:[NSHTTPURLResponse class]]) {
            NSInteger statusCode = [(NSHTTPURLResponse *)response statusCode];
            if (statusCode >= 400) {
                resultError = [NSError errorWithDomain:NeoForgeDirectInstallerErrorDomain
                                                   code:statusCode
                                               userInfo:@{NSLocalizedDescriptionKey: [NSString stringWithFormat:@"HTTP %ld: %@", (long)statusCode, urlString]}];
            } else {
                resultData = data;
            }
        } else {
            resultData = data;
        }
        dispatch_semaphore_signal(semaphore);
    }];
    [task resume];
    long waitResult = dispatch_semaphore_wait(semaphore, dispatch_time(DISPATCH_TIME_NOW, 70 * NSEC_PER_SEC));
    if (waitResult != 0) {
        // Semaphore timeout: cancel the task to release network resources, so a background task does not keep running and leak memory temporarily
        [task cancel];
        if (error) {
            *error = [NSError errorWithDomain:NeoForgeDirectInstallerErrorDomain
                                         code:NSURLErrorTimedOut
                                     userInfo:@{NSLocalizedDescriptionKey: [NSString stringWithFormat:@"Download timed out (70s): %@", urlString]}];
        }
        return NO;
    }

    if (resultError) {
        if (error) *error = resultError;
        return NO;
    }
    if (!resultData || resultData.length == 0) {
        if (error) {
            *error = [NSError errorWithDomain:NeoForgeDirectInstallerErrorDomain
                                         code:NeoForgeDirectInstallerErrorWriteFailed
                                     userInfo:@{NSLocalizedDescriptionKey: [NSString stringWithFormat:@"Empty response: %@", urlString]}];
        }
        return NO;
    }

    BOOL written = [resultData writeToFile:destPath options:NSDataWritingAtomic error:error];
    if (!written) {
        return NO;
    }

    // A 200 response is not proof the body was complete. Reject a jar that will not open, so
    // the caller moves on to the next mirror instead of installing a library that brings the
    // game down at launch with "zip END header not found".
    if ([ArchiveIntegrity isArchivePath:destPath]) {
        NSString *corruption = [ArchiveIntegrity validationFailureForArchiveAtPath:destPath];
        if (corruption) {
            [[NSFileManager defaultManager] removeItemAtPath:destPath error:nil];
            if (error) {
                *error = [NSError errorWithDomain:NeoForgeDirectInstallerErrorDomain
                                             code:NeoForgeDirectInstallerErrorWriteFailed
                                         userInfo:@{NSLocalizedDescriptionKey: [NSString stringWithFormat:@"Damaged download from %@: %@", urlString, corruption]}];
            }
            NSLog(@"[NeoForgeDirect] Discarded damaged download of %@ (%@)", urlString.lastPathComponent ?: urlString, corruption);
            return NO;
        }
    }

    NSLog(@"[NeoForgeDirect] Downloaded %@ (%lu bytes) -> %@", urlString.lastPathComponent ?: urlString, (unsigned long)resultData.length, destPath);
    return YES;
}

#pragma mark - ZIP / UnzipKit helpers

+ (NSData *)dataFromZip:(NSString *)zipPath entry:(NSString *)entryPath error:(NSError **)error {
    if (error) {
        *error = nil;
    }

    NSError *openError = nil;
    UZKArchive *archive = [[UZKArchive alloc] initWithPath:zipPath error:&openError];
    if (!archive || openError) {
        NSLog(@"[NeoForgeDirect] Failed to open archive: %@", openError.localizedDescription ?: @"unknown");
        if (error) {
            *error = [NSError errorWithDomain:NeoForgeDirectInstallerErrorDomain
                                         code:NeoForgeDirectInstallerErrorInvalidArchive
                                     userInfo:@{NSLocalizedDescriptionKey: [NSString stringWithFormat:@"Failed to open installer archive: %@", openError.localizedDescription ?: @"unknown"]}];
        }
        return nil;
    }

    NSError *extractError = nil;
    NSData *result = [archive extractDataFromFile:entryPath error:&extractError];
    if (!result) {
        // Some version entry paths have a leading "/", which is handled for compatibility
        if ([entryPath hasPrefix:@"/"]) {
            NSString *altPath = [entryPath substringFromIndex:1];
            result = [archive extractDataFromFile:altPath error:&extractError];
        }
    }
    if (!result) {
        NSLog(@"[NeoForgeDirect] Failed to extract entry '%@': %@", entryPath, extractError.localizedDescription ?: @"unknown");
        if (error) {
            *error = [NSError errorWithDomain:NeoForgeDirectInstallerErrorDomain
                                         code:NeoForgeDirectInstallerErrorExtractionFailed
                                     userInfo:@{NSLocalizedDescriptionKey: [NSString stringWithFormat:@"Failed to extract %@: %@", entryPath, extractError.localizedDescription ?: @"not found"]}];
        }
        return nil;
    }

    NSLog(@"[NeoForgeDirect] Extracted entry '%@' (%lu bytes)", entryPath, (unsigned long)result.length);
    return result;
}

+ (BOOL)entryExists:(NSString *)zipPath entry:(NSString *)entryPath {
    NSError *openError = nil;
    UZKArchive *archive = [[UZKArchive alloc] initWithPath:zipPath error:&openError];
    if (!archive || openError) {
        return NO;
    }

    NSError *listError = nil;
    NSArray<NSString *> *filenames = [archive listFilenames:&listError];
    if (!filenames || listError) {
        return NO;
    }

    for (NSString *name in filenames) {
        if ([name isEqualToString:entryPath]) {
            return YES;
        }
    }
    return NO;
}

+ (BOOL)extractFile:(NSString *)zipPath entry:(NSString *)entryPath to:(NSString *)destPath error:(NSError **)error {
    if (error) {
        *error = nil;
    }

    NSData *data = [self dataFromZip:zipPath entry:entryPath error:error];
    if (!data) {
        if (error && !*error) {
            *error = [NSError errorWithDomain:NeoForgeDirectInstallerErrorDomain
                                         code:NeoForgeDirectInstallerErrorExtractionFailed
                                     userInfo:@{NSLocalizedDescriptionKey: [NSString stringWithFormat:@"Failed to extract %@ from installer", entryPath]}];
        }
        return NO;
    }

    NSString *destDir = [destPath stringByDeletingLastPathComponent];
    NSError *dirError = nil;
    [[NSFileManager defaultManager] createDirectoryAtPath:destDir
                              withIntermediateDirectories:YES
                                               attributes:nil
                                                    error:&dirError];
    if (dirError) {
        NSLog(@"[NeoForgeDirect] Failed to create directory '%@': %@", destDir, dirError.localizedDescription);
        if (error) {
            *error = [NSError errorWithDomain:NeoForgeDirectInstallerErrorDomain
                                         code:NeoForgeDirectInstallerErrorWriteFailed
                                     userInfo:@{NSLocalizedDescriptionKey: [NSString stringWithFormat:@"Failed to create directory %@: %@", destDir, dirError.localizedDescription]}];
        }
        return NO;
    }

    BOOL written = [data writeToFile:destPath options:NSDataWritingAtomic error:error];
    if (!written) {
        NSLog(@"[NeoForgeDirect] Failed to write file '%@'", destPath);
        if (error && !*error) {
            *error = [NSError errorWithDomain:NeoForgeDirectInstallerErrorDomain
                                         code:NeoForgeDirectInstallerErrorWriteFailed
                                     userInfo:@{NSLocalizedDescriptionKey: [NSString stringWithFormat:@"Failed to write %@", destPath]}];
        }
        return NO;
    }

    NSLog(@"[NeoForgeDirect] Written file '%@' (%lu bytes)", destPath, (unsigned long)data.length);
    return YES;
}

#pragma mark - Maven path utilities

+ (NSString *)mavenPathToRelativePath:(NSString *)mavenPath {
    NSArray *parts = [mavenPath componentsSeparatedByString:@":"];
    if (parts.count < 3) {
        return mavenPath;
    }

    NSString *groupId = parts[0];
    NSString *artifactId = parts[1];
    NSString *version = parts[2];
    NSString *classifier = (parts.count > 3) ? parts[3] : nil;

    NSString *groupPath = [groupId stringByReplacingOccurrencesOfString:@"." withString:@"/"];
    NSString *jarName;
    if (classifier.length > 0) {
        jarName = [NSString stringWithFormat:@"%@-%@-%@.jar", artifactId, version, classifier];
    } else {
        jarName = [NSString stringWithFormat:@"%@-%@.jar", artifactId, version];
    }

    return [NSString stringWithFormat:@"%@/%@/%@/%@", groupPath, artifactId, version, jarName];
}

+ (NSString *)mavenNameToPath:(NSString *)name {
    return [self mavenPathToRelativePath:name];
}

@end
