//
//  ForgeDirectInstaller.m
//  Amethyst
//
//  Direct Forge installer (old + new format) based on FCL logic.
//
//  This direct installer downloads the pre-patched PATCHED artifact instead of running the processors from install_profile.json.
//  Reason: the iOS sandbox forbids fork/exec, so a child JVM cannot be spawned to run the processor tools (binarypatcher,
//  jarsplitter, SpecialSource and so on). The common approach for community launchers on restricted platforms is to download
//  the pre-patched client jar Forge/NeoForge already publish to maven (such as forge-{mc}-{loader}-client.jar),
//  which is equivalent to the processors' output and usable as is at runtime.
//
//  The JarJar (JarInJar) mechanism is handled at runtime by modlauncher's JarInJarDependencyLocator,
//  so no processor is needed at install time.
//
//  Forge in the old format (1.12.2 and earlier) has no processors, so a direct install just drops in the universal jar + version.json.
//

#import "ForgeDirectInstaller.h"
#import "PLProfiles.h"
#import "utils.h"
#import "LauncherPreferences.h"
#import "MinecraftResourceUtils.h"
#import "external/UnzipKit/UZKArchive.h"

NSString *const ForgeDirectInstallerErrorDomain = @"ForgeDirectInstallerErrorDomain";

@implementation ForgeDirectInstaller

#pragma mark - Public

+ (BOOL)installForgeFromInstaller:(NSString *)installerPath
                        versionId:(NSString *)versionId
                            error:(NSError **)error {
    return [self installForgeFromInstaller:installerPath versionId:versionId progress:nil error:error];
}

+ (BOOL)installForgeFromInstaller:(NSString *)installerPath
                        versionId:(NSString *)versionId
                          progress:(void (^)(double progress, NSString *stageMessage))progress
                            error:(NSError **)error {
    return [self installForgeFromInstaller:installerPath
                                  versionId:versionId
                              customGameDir:nil
                        skipRegisterVersion:NO
                                   progress:progress
                                     error:error];
}

+ (BOOL)installForgeFromInstaller:(NSString *)installerPath
                        versionId:(NSString *)versionId
                    customGameDir:(nullable NSString *)customGameDir
              skipRegisterVersion:(BOOL)skipRegisterVersion
                         progress:(void (^)(double progress, NSString *stageMessage))progress
                            error:(NSError **)error {
    void (^reportProgress)(double, NSString *) = ^(double p, NSString *msg) {
        NSLog(@"[ForgeDirect] Progress: %.2f - %@", p, msg);
        if (progress) {
            progress(p, msg);
        }
    };

    @try {
        NSLog(@"[ForgeDirect] Starting installation: %@", versionId);
        reportProgress(0.0, @"Starting installation");
        if (error) {
            *error = nil;
        }

        // Step 1 & 2: Open jar as ZIP and read install_profile.json
        NSLog(@"[ForgeDirect] Reading install_profile.json");
        reportProgress(0.05, @"Reading install_profile.json");
        NSData *profileData = [self dataFromZip:installerPath entry:@"install_profile.json" error:error];
        if (!profileData) {
            NSLog(@"[ForgeDirect] Failed to read install_profile.json");
            if (error && !*error) {
                *error = [NSError errorWithDomain:ForgeDirectInstallerErrorDomain
                                             code:ForgeDirectInstallerErrorMissingProfile
                                         userInfo:@{NSLocalizedDescriptionKey: @"Missing install_profile.json in installer"}];
            }
            return NO;
        }
        NSLog(@"[ForgeDirect] Successfully read install_profile.json (%lu bytes)", (unsigned long)profileData.length);

        // Step 3: Parse install_profile.json
        NSLog(@"[ForgeDirect] Parsing install_profile.json");
        reportProgress(0.1, @"Parsing JSON and detecting the format");
        NSError *jsonError = nil;
        NSMutableDictionary *installProfile = [NSJSONSerialization JSONObjectWithData:profileData
                                                                              options:NSJSONReadingMutableContainers
                                                                                error:&jsonError];
        NSLog(@"[ForgeDirect] JSON parsing completed, error=%@", jsonError ?: @"none");
        if (![installProfile isKindOfClass:[NSDictionary class]] || jsonError) {
            if (error) {
                *error = [NSError errorWithDomain:ForgeDirectInstallerErrorDomain
                                             code:ForgeDirectInstallerErrorInvalidProfile
                                         userInfo:@{NSLocalizedDescriptionKey: @"Failed to parse install_profile.json"}];
            }
            return NO;
        }

        // Step 4: Determine format
        NSLog(@"[ForgeDirect] Detecting installer format");
        BOOL isNewFormat = (installProfile[@"spec"] != nil);
        BOOL isOldFormat = (installProfile[@"install"] != nil && installProfile[@"versionInfo"] != nil);
        NSLog(@"[ForgeDirect] Format detection: new=%d, old=%d", isNewFormat, isOldFormat);

        if (!isNewFormat && !isOldFormat) {
            if (error) {
                *error = [NSError errorWithDomain:ForgeDirectInstallerErrorDomain
                                             code:ForgeDirectInstallerErrorInvalidProfile
                                         userInfo:@{NSLocalizedDescriptionKey: @"Unknown install_profile format"}];
            }
            return NO;
        }

        // Use the custom gameDir when importing a modpack; otherwise use the default POJAV_GAME_DIR
        // Note: gameDir (user.dir, the isolated directory for mods/saves/configs) uses customGameDir,
        // but versionDir and librariesDir must always use POJAV_GAME_DIR (the main directory).
        // Reason: DIR_HOME_VERSION and DIR_HOME_LIBRARY in the Minecraft launcher (Tools.java on the Java side)
        // always point at POJAV_GAME_DIR/versions and POJAV_GAME_DIR/libraries and are not read from the profile gameDir.
        // Putting versionDir/librariesDir under customGameDir used to cause "version information not found" at launch.
        NSString *gameDir = customGameDir.length > 0 ? customGameDir : [self gameDirectory];
        NSString *mainGameDir = [self gameDirectory];  // Always use the main directory to store versions and libraries
        NSString *librariesDir = [mainGameDir stringByAppendingPathComponent:@"libraries"];
        NSLog(@"[ForgeDirect] Game directory (user.dir): %@", gameDir);
        NSLog(@"[ForgeDirect] Main game directory (versions/libraries): %@", mainGameDir);
        NSLog(@"[ForgeDirect] Libraries directory: %@", librariesDir);
        reportProgress(0.15, @"Preparing the version folder");

        // Create the libraries directory up front, so later downloads/extractions do not fail
        [[NSFileManager defaultManager] createDirectoryAtPath:librariesDir
                                  withIntermediateDirectories:YES
                                                   attributes:nil
                                                        error:nil];

        BOOL success = NO;
        if (isOldFormat) {
            NSLog(@"[ForgeDirect] Using old format installer");
            success = [self installOldFormat:installProfile
                               installerPath:installerPath
                                   versionId:versionId
                                    gameDir:gameDir
                               librariesDir:librariesDir
                                    progress:progress
                                      error:error];
        } else {
            NSLog(@"[ForgeDirect] Using new format installer");
            success = [self installNewFormat:installProfile
                               installerPath:installerPath
                                   versionId:versionId
                                    gameDir:gameDir
                               librariesDir:librariesDir
                                    progress:progress
                                      error:error];
        }

        if (!success) {
            NSLog(@"[ForgeDirect] Installation failed");
            return NO;
        }

        // Step 7: Register version in launcher_profiles.json (must run on main thread)
        // Skipped when importing a modpack (ModpackImportService.createProfileForModpack registers it centrally)
        if (!skipRegisterVersion) {
            NSLog(@"[ForgeDirect] Registering version on main thread");
            reportProgress(0.95, @"Registering version");
            if ([NSThread isMainThread]) {
                [self registerVersion:versionId];
            } else {
                dispatch_sync(dispatch_get_main_queue(), ^{
                    [self registerVersion:versionId];
                });
            }
            NSLog(@"[ForgeDirect] Version registered successfully");
        }

        NSLog(@"[ForgeDirect] Installation completed successfully");
        reportProgress(1.0, @"Installation complete");
        return YES;
    }
    @catch (NSException *exception) {
        NSString *stack = [exception.callStackSymbols componentsJoinedByString:@"\n"];
        NSLog(@"[ForgeDirect] EXCEPTION: name=%@, reason=%@, callStack=%@", exception.name, exception.reason, stack);
        if (error) {
            *error = [NSError errorWithDomain:ForgeDirectInstallerErrorDomain
                                          code:ForgeDirectInstallerErrorException
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
/// making ensureParentVersionExists: fail to fetch the parent version JSON → the Forge/NeoForge version could not find the vanilla version named in inheritsFrom → the launch crashed.
/// This reuses the NSURLSession + semaphore pattern already proven in downloadFileFromURL:.
+ (NSData *)downloadDataForRequest:(NSURLRequest *)request error:(NSError **)error {
    if (!request) {
        if (error) {
            *error = [NSError errorWithDomain:ForgeDirectInstallerErrorDomain
                                         code:ForgeDirectInstallerErrorWriteFailed
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
                resultError = [NSError errorWithDomain:ForgeDirectInstallerErrorDomain
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
            *error = [NSError errorWithDomain:ForgeDirectInstallerErrorDomain
                                         code:NSURLErrorTimedOut
                                     userInfo:@{NSLocalizedDescriptionKey: [NSString stringWithFormat:@"Request timed out (60s): %@", request.URL.absoluteString]}];
        }
        return nil;
    }
    if (error) *error = resultError;
    return resultData;
}

/// Modeled on FCL/HMCL: make sure the version JSON of the parent version (vanilla MC) exists.
/// The version.json of Forge/NeoForge contains fields such as "inheritsFrom": "1.20.1", and at launch
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
        NSLog(@"[ForgeDirect] Parent version JSON already exists: %@", parentJsonPath);
        return YES;
    }

    NSLog(@"[ForgeDirect] Parent version JSON missing, downloading: %@", parentVersionId);

    // 2. Fetch the Mojang version manifest
    NSString *downloadSource = getPrefObject(@"general.download_source");
    BOOL useBMCLAPI = [downloadSource isEqualToString:@"bmclapi"];
    NSString *manifestURL = useBMCLAPI
        ? @"https://bmclapi2.bangbang93.com/mc/game/version_manifest_v2.json"
        : @"https://piston-meta.mojang.com/mc/game/version_manifest_v2.json";

    NSURL *url = [NSURL URLWithString:manifestURL];
    if (!url) {
        if (error) {
            *error = [NSError errorWithDomain:ForgeDirectInstallerErrorDomain
                                         code:ForgeDirectInstallerErrorWriteFailed
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
        NSLog(@"[ForgeDirect] Failed to download version manifest: %@", error ? [*error localizedDescription] : @"unknown");
        return NO;
    }

    NSDictionary *manifest = [NSJSONSerialization JSONObjectWithData:manifestData options:0 error:nil];
    NSArray *versions = [manifest isKindOfClass:[NSDictionary class]] ? manifest[@"versions"] : nil;
    if (![versions isKindOfClass:[NSArray class]]) {
        if (error) {
            *error = [NSError errorWithDomain:ForgeDirectInstallerErrorDomain
                                         code:ForgeDirectInstallerErrorInvalidProfile
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
            *error = [NSError errorWithDomain:ForgeDirectInstallerErrorDomain
                                         code:ForgeDirectInstallerErrorInvalidProfile
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

    NSLog(@"[ForgeDirect] Downloading parent version JSON from: %@", versionJSONURL);

    // 4. Download the version JSON
    NSURL *jsonURL = [NSURL URLWithString:versionJSONURL];
    if (!jsonURL) {
        if (error) {
            *error = [NSError errorWithDomain:ForgeDirectInstallerErrorDomain
                                         code:ForgeDirectInstallerErrorWriteFailed
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
        NSLog(@"[ForgeDirect] Failed to download parent version JSON: %@", error ? [*error localizedDescription] : @"unknown");
        return NO;
    }

    // 5. Create the parent version directory and write the JSON
    NSError *dirError = nil;
    [NSFileManager.defaultManager createDirectoryAtPath:parentVersionDir
                            withIntermediateDirectories:YES
                                             attributes:nil
                                                  error:&dirError];
    if (dirError) {
        NSLog(@"[ForgeDirect] Failed to create parent version dir: %@", dirError.localizedDescription);
        if (error) *error = dirError;
        return NO;
    }

    NSError *writeErr = nil;
    if (![jsonData writeToFile:parentJsonPath options:NSDataWritingAtomic error:&writeErr]) {
        NSLog(@"[ForgeDirect] Failed to write parent version JSON: %@", writeErr.localizedDescription);
        if (error) *error = writeErr;
        return NO;
    }

    NSLog(@"[ForgeDirect] Parent version JSON saved: %@ (%lu bytes)", parentJsonPath, (unsigned long)jsonData.length);
    return YES;
}

+ (void)registerVersion:(NSString *)versionId {
    NSLog(@"[ForgeDirect] registerVersion called: %@", versionId);
    PLProfiles *profiles = [PLProfiles current];
    NSLog(@"[ForgeDirect] PLProfiles current: %@", profiles ? @"ok" : @"nil");
    NSMutableDictionary *profileDict = [NSMutableDictionary dictionary];
    profileDict[@"name"] = versionId;
    profileDict[@"lastVersionId"] = versionId;
    // Back to the original "switch game directory" model: every version shares the root directory (gameDir=".")
    // The user switches between game directories manually with the "Switch game directory" feature in settings
    profileDict[@"gameDir"] = @".";
    profileDict[@"type"] = @"custom";
    profileDict[@"created"] = [NSDate date].description;
    // Infer the Java version: Forge 1.20.5+ needs Java 21, 1.18+ needs Java 17, 1.17 needs Java 16, everything else Java 8
    // versionId looks like "1.20.1-forge-47.3.0" or "Forge-1.20.1-47.3.0", so extract the MC version
    NSInteger javaMajor = [self inferJavaMajorVersionFromVersionId:versionId];
    // Write an NSString rather than an NSDictionary, consistent with every reader such as ProfileSettingsViewController
    // JavaLauncher reads it with .intValue, and "17".intValue = 17
    profileDict[@"javaVersion"] = [NSString stringWithFormat:@"%ld", (long)javaMajor];
    [profiles saveProfile:profileDict withName:versionId];
    // Consistent with the Fabric / Vanilla installation paths: select the newly created profile automatically, so the user does not return to the main screen and still launch the old version
    profiles.selectedProfileName = versionId;
    NSLog(@"[ForgeDirect] Profile saved and selected (javaVersion=%ld, gameDir=%@)", (long)javaMajor, profileDict[@"gameDir"]);
}

/// Infer the required Java major version from the versionId
/// versionId looks like "1.20.1-forge-47.3.0", "Forge-1.20.1-47.3.0" or "1.18.2-forge-40.2.0"
+ (NSInteger)inferJavaMajorVersionFromVersionId:(NSString *)versionId {
    // Extract the MC version in 1.x.x form (anchored at the start or at a separator, to avoid matching a "1.x" inside the loader version)
    NSRegularExpression *regex = [NSRegularExpression regularExpressionWithPattern:@"(?:^|[-_])1\\.(\\d+)(?:\\.(\\d+))?"
                                                                           options:0
                                                                             error:nil];
    NSTextCheckingResult *match = [regex firstMatchInString:versionId options:0 range:NSMakeRange(0, versionId.length)];
    if (!match || match.numberOfRanges < 2) return 8;
    NSString *minorStr = [versionId substringWithRange:[match rangeAtIndex:1]];
    NSInteger minor = [minorStr integerValue];
    NSString *patchStr = match.numberOfRanges >= 3 && [match rangeAtIndex:2].location != NSNotFound
                        ? [versionId substringWithRange:[match rangeAtIndex:2]]
                        : @"0";
    NSInteger patch = [patchStr integerValue];
    if (minor >= 21) return 21;                  // 1.21+
    if (minor >= 20 && patch >= 5) return 21;    // 1.20.5+
    if (minor >= 18) return 17;                  // 1.18+
    if (minor >= 17) return 17;                  // 1.17 (the project does not bundle Java 16, and Java 17 can run 1.17 in a backward-compatible way)
    return 8;                                     // 1.16.5 and below
}

#pragma mark - Old format (Forge 1.12.2-)

+ (BOOL)installOldFormat:(NSDictionary *)installProfile
           installerPath:(NSString *)installerPath
               versionId:(NSString *)versionId
                gameDir:(NSString *)gameDir
            librariesDir:(NSString *)librariesDir
                progress:(void (^)(double, NSString *))progress
                  error:(NSError **)error {
    NSLog(@"[ForgeDirect] installOldFormat started");
    void (^reportProgress)(double, NSString *) = ^(double p, NSString *msg) {
        NSLog(@"[ForgeDirect] Progress: %.2f - %@", p, msg);
        if (progress) {
            progress(p, msg);
        }
    };

    NSDictionary *versionInfo = installProfile[@"versionInfo"];
    if (![versionInfo isKindOfClass:[NSDictionary class]]) {
        if (error) {
            *error = [NSError errorWithDomain:ForgeDirectInstallerErrorDomain
                                         code:ForgeDirectInstallerErrorInvalidProfile
                                     userInfo:@{NSLocalizedDescriptionKey: @"Missing versionInfo in install_profile.json"}];
        }
        return NO;
    }

    NSMutableDictionary *mutableVersionInfo = [versionInfo mutableCopy];
    mutableVersionInfo[@"id"] = versionId;

    // Prepare version directory
    // The version JSON must be written into POJAV_GAME_DIR/versions/ (the main directory) rather than the profile gameDir.
    // The Java side of the Minecraft launcher always loads version JSONs from POJAV_GAME_DIR/versions.
    NSString *versionDir = [[self gameDirectory] stringByAppendingPathComponent:[NSString stringWithFormat:@"versions/%@", versionId]];
    NSString *versionJsonPath = [versionDir stringByAppendingPathComponent:[NSString stringWithFormat:@"%@.json", versionId]];
    NSLog(@"[ForgeDirect] Version directory: %@", versionDir);
    [[NSFileManager defaultManager] createDirectoryAtPath:versionDir
                              withIntermediateDirectories:YES
                                               attributes:nil
                                                    error:nil];

    // Extract universal jar
    NSLog(@"[ForgeDirect] Extracting universal jar");
    reportProgress(0.4, @"Extracting libraries (1/1)");
    NSDictionary *installDict = installProfile[@"install"];
    id filePathObj = installDict[@"filePath"];
    id mavenPathObj = installDict[@"path"];
    NSString *filePath = [filePathObj isKindOfClass:[NSString class]] ? filePathObj : nil;
    NSString *mavenPath = [mavenPathObj isKindOfClass:[NSString class]] ? mavenPathObj : nil;

    if (filePath.length > 0) {
        NSString *destPath;
        if (mavenPath.length > 0) {
            destPath = [librariesDir stringByAppendingPathComponent:[self mavenPathToRelativePath:mavenPath]];
        } else {
            destPath = [versionDir stringByAppendingPathComponent:[filePath lastPathComponent]];
        }
        NSLog(@"[ForgeDirect] Extracting universal jar to: %@", destPath);

        if (![self extractFile:installerPath entry:filePath to:destPath error:error]) {
            return NO;
        }
        NSLog(@"[ForgeDirect] Universal jar extracted successfully");
    } else {
        // filePath missing: the universal jar is the core runtime dependency of older Forge versions
        // If mavenPath exists, extractAllMavenEntries later may still extract it (from the maven/ path inside the zip)
        // If mavenPath is missing too, launching may fail with NoClassDefFoundError
        NSLog(@"[ForgeDirect] Warning: install.filePath missing, universal jar will rely on extractAllMavenEntries or subsequent downloadMissingLibraries");
    }
    reportProgress(0.7, @"Extracting libraries (1/1)");

    // The old format also needs every dependency under maven/ inside installer.jar to be extracted
    // Older Forge versions usually download libraries from Maven at runtime, but installer.jar may ship some of them too
    reportProgress(0.75, @"Extracting the embedded maven dependencies");
    [self extractAllMavenEntries:installerPath toLibrariesDir:librariesDir];

    // Download the libraries missing from versionInfo.libraries (the old format may have a libraries array as well)
    NSArray *libs = mutableVersionInfo[@"libraries"];
    if ([libs isKindOfClass:[NSArray class]] && libs.count > 0) {
        reportProgress(0.8, @"Downloading missing libraries");
        [self downloadMissingLibraries:libs librariesDir:librariesDir progress:progress baseProgress:0.8 progressSpan:0.1];
    }

    // Write version JSON
    NSLog(@"[ForgeDirect] Writing version JSON to: %@", versionJsonPath);
    reportProgress(0.9, @"Writing version JSON");
    NSError *writeError = saveJSONToFile(mutableVersionInfo, versionJsonPath);
    if (writeError) {
        if (error) {
            *error = [NSError errorWithDomain:ForgeDirectInstallerErrorDomain
                                         code:ForgeDirectInstallerErrorWriteFailed
                                     userInfo:@{NSLocalizedDescriptionKey: [NSString stringWithFormat:@"Failed to write version JSON: %@", writeError.localizedDescription]}];
        }
        return NO;
    }
    NSLog(@"[ForgeDirect] Version JSON written successfully");

    // Modeled on FCL/HMCL: the versionInfo of old-format Forge 1.12- may also contain inheritsFrom,
    // so make sure the version JSON of the parent version (vanilla MC) exists.
    NSString *oldInheritsFrom = [mutableVersionInfo[@"inheritsFrom"] isKindOfClass:[NSString class]] ? mutableVersionInfo[@"inheritsFrom"] : nil;
    if (oldInheritsFrom.length > 0 && ![oldInheritsFrom isEqualToString:versionId]) {
        NSLog(@"[ForgeDirect] Checking parent vanilla version (old format): %@", oldInheritsFrom);
        NSError *parentError = nil;
        if (![self ensureParentVersionExists:oldInheritsFrom error:&parentError]) {
            NSLog(@"[ForgeDirect] Warning: parent version %@ auto-completion failed: %@", oldInheritsFrom, parentError.localizedDescription ?: @"Unknown error");
        } else {
            NSLog(@"[ForgeDirect] Parent vanilla version ensured: %@", oldInheritsFrom);
        }
    }

    NSLog(@"[ForgeDirect] installOldFormat completed");
    return YES;
}

#pragma mark - New format (Forge 1.13+)

+ (BOOL)installNewFormat:(NSDictionary *)installProfile
           installerPath:(NSString *)installerPath
               versionId:(NSString *)versionId
                gameDir:(NSString *)gameDir
            librariesDir:(NSString *)librariesDir
                progress:(void (^)(double, NSString *))progress
                  error:(NSError **)error {
    NSLog(@"[ForgeDirect] installNewFormat started");
    void (^reportProgress)(double, NSString *) = ^(double p, NSString *msg) {
        NSLog(@"[ForgeDirect] Progress: %.2f - %@", p, msg);
        if (progress) {
            progress(p, msg);
        }
    };

    // Read version.json
    NSLog(@"[ForgeDirect] Reading version.json");
    NSString *versionJsonEntry = installProfile[@"json"];
    if (!versionJsonEntry || ![versionJsonEntry isKindOfClass:[NSString class]]) {
        versionJsonEntry = @"version.json";
    }
    // The version.json path may start with "/", which is stripped uniformly
    if ([versionJsonEntry hasPrefix:@"/"]) {
        versionJsonEntry = [versionJsonEntry substringFromIndex:1];
    }
    NSLog(@"[ForgeDirect] version.json entry: %@", versionJsonEntry);

    NSData *versionData = [self dataFromZip:installerPath entry:versionJsonEntry error:error];
    if (!versionData) {
        if (error && !*error) {
            *error = [NSError errorWithDomain:ForgeDirectInstallerErrorDomain
                                         code:ForgeDirectInstallerErrorMissingProfile
                                     userInfo:@{NSLocalizedDescriptionKey: @"Missing version.json in installer"}];
        }
        return NO;
    }
    NSLog(@"[ForgeDirect] Successfully read version.json (%lu bytes)", (unsigned long)versionData.length);

    NSLog(@"[ForgeDirect] Parsing version.json");
    NSMutableDictionary *versionJson = [NSJSONSerialization JSONObjectWithData:versionData
                                                                       options:NSJSONReadingMutableContainers
                                                                         error:nil];
    if (![versionJson isKindOfClass:[NSDictionary class]]) {
        if (error) {
            *error = [NSError errorWithDomain:ForgeDirectInstallerErrorDomain
                                         code:ForgeDirectInstallerErrorInvalidProfile
                                     userInfo:@{NSLocalizedDescriptionKey: @"Failed to parse version.json"}];
        }
        return NO;
    }
    NSLog(@"[ForgeDirect] version.json parsed successfully");

    versionJson[@"id"] = versionId;

    // Merge libraries from install_profile into versionJson (dedup by name)
    NSLog(@"[ForgeDirect] Merging libraries");
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
        NSLog(@"[ForgeDirect] Merged libraries: added %lu, skipped %lu duplicates", (unsigned long)addedCount, (unsigned long)skippedCount);
        versionJson[@"libraries"] = mergedLibraries;
    }

    // Prepare version directory
    // The version JSON must be written into POJAV_GAME_DIR/versions/ (the main directory) rather than the profile gameDir.
    // The Java side of the Minecraft launcher always loads version JSONs from POJAV_GAME_DIR/versions.
    NSString *versionDir = [[self gameDirectory] stringByAppendingPathComponent:[NSString stringWithFormat:@"versions/%@", versionId]];
    NSString *versionJsonPath = [versionDir stringByAppendingPathComponent:[NSString stringWithFormat:@"%@.json", versionId]];
    NSLog(@"[ForgeDirect] Version directory: %@", versionDir);
    [[NSFileManager defaultManager] createDirectoryAtPath:versionDir
                              withIntermediateDirectories:YES
                                               attributes:nil
                                                    error:nil];

    // Step A: extract every dependency under maven/ inside installer.jar into the libraries directory
    // These are the dependencies the installer ships and they must be installed
    NSLog(@"[ForgeDirect] Extracting all maven entries from installer jar");
    reportProgress(0.2, @"Extracting the embedded maven dependencies");
    NSUInteger extractedCount = [self extractAllMavenEntries:installerPath toLibrariesDir:librariesDir];
    NSLog(@"[ForgeDirect] Extracted %lu maven entries", (unsigned long)extractedCount);

    // Step B: download the libraries from versionJson.libraries that are not inside installer.jar
    // The libraries in version.json include vanilla mc, modlauncher, bootstraplauncher and so on
    // Those are not inside installer.jar and must be downloaded from maven
    NSLog(@"[ForgeDirect] Downloading missing libraries from maven");
    reportProgress(0.3, @"Downloading missing libraries");
    NSArray *allLibraries = versionJson[@"libraries"];
    if ([allLibraries isKindOfClass:[NSArray class]]) {
        [self downloadMissingLibraries:allLibraries librariesDir:librariesDir progress:progress baseProgress:0.3 progressSpan:0.4];
    }

    // Step C: the key step - download the pre-patched PATCHED artifact
    // The processors in install_profile.json would produce the :client jar, but iOS cannot run processors.
    // Forge/NeoForge already publish that pre-patched jar to maven, so it can simply be downloaded.
    NSLog(@"[ForgeDirect] Downloading pre-patched client artifact");
    reportProgress(0.75, @"Downloading the pre-patched core jar");
    NSString *mainPath = installProfile[@"path"];
    // Fallback: build the standard Forge coordinates from the version field when the path field is missing
    if (![mainPath isKindOfClass:[NSString class]] || mainPath.length == 0) {
        NSString *versionField = installProfile[@"version"];
        if ([versionField isKindOfClass:[NSString class]] && versionField.length > 0) {
            mainPath = [NSString stringWithFormat:@"net.minecraftforge:forge:%@", versionField];
            NSLog(@"[ForgeDirect] path field missing, falling back to version field: %@", mainPath);
        }
    }
    if ([mainPath isKindOfClass:[NSString class]] && mainPath.length > 0) {
        if (![self downloadPatchedArtifact:mainPath librariesDir:librariesDir error:error]) {
            NSLog(@"[ForgeDirect] Failed to download patched artifact");
            return NO;
        }
    } else {
        // path is a core runtime dependency of Forge 1.13+, and its absence causes a ClassNotFoundException at launch
        NSLog(@"[ForgeDirect] install_profile.json missing path/version fields, cannot download patched client jar");
        if (error) {
            *error = [NSError errorWithDomain:ForgeDirectInstallerErrorDomain
                                         code:ForgeDirectInstallerErrorInvalidProfile
                                     userInfo:@{NSLocalizedDescriptionKey: @"install_profile.json is missing the path and version fields, so the pre-patched core jar cannot be located"}];
        }
        return NO;
    }

    // Write version JSON
    NSLog(@"[ForgeDirect] Writing version JSON to: %@", versionJsonPath);
    reportProgress(0.9, @"Writing version JSON");
    NSError *writeError = saveJSONToFile(versionJson, versionJsonPath);
    if (writeError) {
        if (error) {
            *error = [NSError errorWithDomain:ForgeDirectInstallerErrorDomain
                                         code:ForgeDirectInstallerErrorWriteFailed
                                     userInfo:@{NSLocalizedDescriptionKey: [NSString stringWithFormat:@"Failed to write version JSON: %@", writeError.localizedDescription]}];
        }
        return NO;
    }
    NSLog(@"[ForgeDirect] Version JSON written successfully");

    // Modeled on FCL/HMCL: make sure the version JSON of the parent version (vanilla MC) exists.
    // The version.json of Forge 1.13+ contains fields such as "inheritsFrom": "1.20.1", and at launch the Java side
    // reads versions/{inheritsFrom}/{inheritsFrom}.json and merges it with the Forge version.
    // If the user has not installed the vanilla version yet, the launch crashes with a FileNotFoundException.
    // The missing parent version JSON is therefore filled in automatically after the direct install (only the JSON is downloaded, not the vanilla client jar,
    // because the iOS launcher uses its own rendering pipeline and does not need the vanilla client.jar).
    NSString *inheritsFrom = [versionJson[@"inheritsFrom"] isKindOfClass:[NSString class]] ? versionJson[@"inheritsFrom"] : nil;
    if (inheritsFrom.length > 0 && ![inheritsFrom isEqualToString:versionId]) {
        NSLog(@"[ForgeDirect] Checking parent vanilla version: %@", inheritsFrom);
        NSError *parentError = nil;
        if (![self ensureParentVersionExists:inheritsFrom error:&parentError]) {
            // A missing parent version only produces a warning and does not block the installation (the user may install the vanilla version manually later)
            NSLog(@"[ForgeDirect] Warning: parent version %@ auto-completion failed: %@", inheritsFrom, parentError.localizedDescription ?: @"Unknown error");
        } else {
            NSLog(@"[ForgeDirect] Parent vanilla version ensured: %@", inheritsFrom);
        }
    }

    NSLog(@"[ForgeDirect] installNewFormat completed");
    return YES;
}

#pragma mark - Maven entry Extraction

// Extract every file under the maven/ directory inside installer.jar into the libraries directory
// Returns the number of files extracted successfully
+ (NSUInteger)extractAllMavenEntries:(NSString *)installerPath toLibrariesDir:(NSString *)librariesDir {
    NSError *openError = nil;
    UZKArchive *archive = [[UZKArchive alloc] initWithPath:installerPath error:&openError];
    if (!archive || openError) {
        NSLog(@"[ForgeDirect] extractAllMavenEntries: failed to open archive: %@", openError.localizedDescription ?: @"unknown");
        return 0;
    }

    NSError *listError = nil;
    NSArray<NSString *> *filenames = [archive listFilenames:&listError];
    if (!filenames || listError) {
        NSLog(@"[ForgeDirect] extractAllMavenEntries: failed to list filenames: %@", listError.localizedDescription ?: @"unknown");
        return 0;
    }

    NSUInteger count = 0;
    NSFileManager *fm = [NSFileManager defaultManager];
    for (NSString *name in filenames) {
        // Only handle files with the maven/ prefix
        if (![name hasPrefix:@"maven/"]) continue;
        // Skip directory entries (those ending in /), so extractDataFromFile returning empty data does not produce misleading log lines
        if ([name hasSuffix:@"/"]) continue;

        // Convert to a relative path by stripping the "maven/" prefix
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
            NSLog(@"[ForgeDirect] extractAllMavenEntries: failed to extract %@: %@", name, extractError.localizedDescription ?: @"unknown");
            continue;
        }

        // Create the target directory (handling collisions with a file of the same name)
        NSString *destDir = [destPath stringByDeletingLastPathComponent];
        [self ensureDirectoryExists:destDir error:nil];

        // Write the file
        NSError *writeError = nil;
        if (![data writeToFile:destPath options:NSDataWritingAtomic error:&writeError]) {
            NSLog(@"[ForgeDirect] extractAllMavenEntries: failed to write %@: %@", destPath, writeError.localizedDescription ?: @"unknown");
            continue;
        }
        count++;
    }
    return count;
}

#pragma mark - Library Download

// Download the libraries from version.json.libraries that do not exist yet
// library.downloads.artifact.url is preferred; if it is absent the maven repository URL is assembled instead
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
                NSLog(@"[ForgeDirect] Skipping library %@ (OS rules disallow osx/iOS)", name);
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

        // Skip it if it already exists
        if ([fm fileExistsAtPath:destPath]) {
            skipped++;
            processed++;
            continue;
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
            // Assemble it from the maven repository (Forge libraries come from maven.minecraftforge.net, everything else from libraries.minecraft.net)
            url = [self buildMavenURLForLibrary:name relativePath:relativePath];
        }

        if (!url) {
            NSLog(@"[ForgeDirect] Cannot build URL for library %@, skipping", name);
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
            NSLog(@"[ForgeDirect] Downloaded library: %@", name);
        } else {
            // The primary source failed: try the fallback source (BMCLAPI ↔ the official source)
            NSLog(@"[ForgeDirect] Primary source failed for %@, trying fallback: %@", name, downloadError.localizedDescription ?: @"unknown");
            NSString *fallbackURL = [self buildFallbackURLForLibrary:name relativePath:relativePath];
            if (fallbackURL && ![fallbackURL isEqualToString:url]) {
                NSError *fallbackError = nil;
                if ([self downloadFileFromURL:fallbackURL toPath:destPath error:&fallbackError]) {
                    downloaded++;
                    NSLog(@"[ForgeDirect] Downloaded library via fallback: %@", name);
                    processed++;
                    continue;
                }
                NSLog(@"[ForgeDirect] Fallback also failed for %@: %@", name, fallbackError.localizedDescription ?: @"unknown");
            }
            failed++;
            // A failed critical library (modlauncher, bootstraplauncher, mixin, asm, or Forge/NeoForge's own libraries) crashes the launch, so log a warning
            if ([self isCriticalLibrary:name]) {
                [criticalFailures addObject:name];
                NSLog(@"[ForgeDirect] Warning: critical library download failed (app will crash on launch): %@", name);
            } else {
                NSLog(@"[ForgeDirect] Failed to download library %@ (both sources failed)", name);
            }
            // Do not abort the flow; some libraries may be unimportant or may be downloaded again when the game launches
        }
        processed++;
    }

    NSLog(@"[ForgeDirect] Library download summary: downloaded=%lu, skipped=%lu, failed=%lu, total=%lu, criticalFailures=%lu",
          (unsigned long)downloaded, (unsigned long)skipped, (unsigned long)failed, (unsigned long)total, (unsigned long)criticalFailures.count);
    if (criticalFailures.count > 0) {
        NSLog(@"[ForgeDirect] Warning: critical library download failures: %@", criticalFailures);
    }
}

/// Determine whether this is a critical library (one whose absence crashes the launch)
+ (BOOL)isCriticalLibrary:(NSString *)name {
    if (!name.length) return NO;
    // Core runtime dependencies such as modlauncher, bootstraplauncher, mixin, asm, Forge/NeoForge's own libraries and jimfs
    NSArray<NSString *> *criticalPrefixes = @[
        @"cpw.mods:modlauncher",
        @"net.minecraftforge.bootstraplauncher",
        @"net.minecraftforge:forge",
        @"net.minecraftforge:fmlloader",
        @"net.minecraftforge:javafmllanguage",
        @"net.minecraftforge:lowcodelanguage",
        @"net.minecraftforge:mclanguage",
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

    // Forge's own libraries come from maven.minecraftforge.net
    if ([name hasPrefix:@"net.minecraftforge:"]) {
        if (useBMCLAPI) {
            return [NSString stringWithFormat:@"https://bmclapi2.bangbang93.com/maven/%@", relativePath];
        }
        return [NSString stringWithFormat:@"https://maven.minecraftforge.net/%@", relativePath];
    }

    // NeoForge's own libraries come from maven.neoforged.net
    if ([name hasPrefix:@"net.neoforged:"] || [name hasPrefix:@"net.neoforged."]) {
        if (useBMCLAPI) {
            return [NSString stringWithFormat:@"https://bmclapi2.bangbang93.com/maven/%@", relativePath];
        }
        return [NSString stringWithFormat:@"https://maven.neoforged.net/releases/%@", relativePath];
    }

    // cpw.mods:modlauncher is a core dependency of Forge 1.13+, and its primary source is the Forge maven
    if ([name hasPrefix:@"cpw.mods:"]) {
        if (useBMCLAPI) {
            return [NSString stringWithFormat:@"https://bmclapi2.bangbang93.com/maven/%@", relativePath];
        }
        return [NSString stringWithFormat:@"https://maven.minecraftforge.net/%@", relativePath];
    }

    // SpongePowered (mixin, asm and so on) comes from repo.spongepowered.org
    if ([name hasPrefix:@"org.spongepowered:"]) {
        if (useBMCLAPI) {
            return [NSString stringWithFormat:@"https://bmclapi2.bangbang93.com/maven/%@", relativePath];
        }
        return [NSString stringWithFormat:@"https://repo.spongepowered.org/repository/maven-public/%@", relativePath];
    }

    // oceanlabs (mcp_config, mcp_mappings and so on) comes from maven.minecraftforge.net (Forge mirrors these)
    if ([name hasPrefix:@"de.oceanlabs.mcp:"]) {
        if (useBMCLAPI) {
            return [NSString stringWithFormat:@"https://bmclapi2.bangbang93.com/maven/%@", relativePath];
        }
        return [NSString stringWithFormat:@"https://maven.minecraftforge.net/%@", relativePath];
    }

    // asm (ow2 asm) comes from maven.minecraftforge.net (Forge mirrors asm)
    if ([name hasPrefix:@"org.ow2.asm:"]) {
        if (useBMCLAPI) {
            return [NSString stringWithFormat:@"https://bmclapi2.bangbang93.com/maven/%@", relativePath];
        }
        return [NSString stringWithFormat:@"https://maven.minecraftforge.net/%@", relativePath];
    }

    // MojoHaus (bootstraplauncher, installertools and so on) comes from maven.minecraftforge.net first
    if ([name hasPrefix:@"net.minecraftforge.installertools:"] ||
        [name hasPrefix:@"net.minecraftforge.bootstraplauncher:"]) {
        if (useBMCLAPI) {
            return [NSString stringWithFormat:@"https://bmclapi2.bangbang93.com/maven/%@", relativePath];
        }
        return [NSString stringWithFormat:@"https://maven.minecraftforge.net/%@", relativePath];
    }

    // JitPack (some modlauncher dependencies)
    if ([name hasPrefix:@"com.machinezoo.noexception:"] ||
        [name hasPrefix:@"org.codehaus.mojo:"]) {
        if (useBMCLAPI) {
            return [NSString stringWithFormat:@"https://bmclapi2.bangbang93.com/maven/%@", relativePath];
        }
        return [NSString stringWithFormat:@"https://maven.minecraftforge.net/%@", relativePath];
    }

    // Other libraries (Mojang, lwjgl, gson and so on) come from libraries.minecraft.net (the BMCLAPI mirror)
    if (useBMCLAPI) {
        return [NSString stringWithFormat:@"https://bmclapi2.bangbang93.com/maven/%@", relativePath];
    }
    return [NSString stringWithFormat:@"https://libraries.minecraft.net/%@", relativePath];
}

/// Build the fallback URL (switching to the BMCLAPI mirror when the primary source fails, or vice versa)
+ (NSString *)buildFallbackURLForLibrary:(NSString *)name relativePath:(NSString *)relativePath {
    NSString *downloadSource = getPrefObject(@"general.download_source");
    BOOL useBMCLAPI = [downloadSource isEqualToString:@"bmclapi"];

    // When the primary source is BMCLAPI, fall back to the official source; when it is the official source, fall back to BMCLAPI
    if (useBMCLAPI) {
        // BMCLAPI failed, so try the official source
        if ([name hasPrefix:@"net.minecraftforge:"] || [name hasPrefix:@"de.oceanlabs.mcp:"] || [name hasPrefix:@"org.ow2.asm:"] || [name hasPrefix:@"cpw.mods:"]) {
            return [NSString stringWithFormat:@"https://maven.minecraftforge.net/%@", relativePath];
        }
        if ([name hasPrefix:@"net.neoforged:"] || [name hasPrefix:@"net.neoforged."]) {
            return [NSString stringWithFormat:@"https://maven.neoforged.net/releases/%@", relativePath];
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
// mainPath format: "net.minecraftforge:forge:1.20.1-47.3.0"
// which maps to the :client classifier jar on maven:
//   Official source: https://maven.minecraftforge.net/net/minecraftforge/forge/1.20.1-47.3.0/forge-1.20.1-47.3.0-client.jar
//   BMCLAPI: https://bmclapi2.bangbang93.com/maven/net/minecraftforge/forge/1.20.1-47.3.0/forge-1.20.1-47.3.0-client.jar
+ (BOOL)downloadPatchedArtifact:(NSString *)mainPath librariesDir:(NSString *)librariesDir error:(NSError **)error {
    // Split the maven coordinates
    NSArray *parts = [mainPath componentsSeparatedByString:@":"];
    if (parts.count < 3) {
        if (error) {
            *error = [NSError errorWithDomain:ForgeDirectInstallerErrorDomain
                                         code:ForgeDirectInstallerErrorInvalidProfile
                                     userInfo:@{NSLocalizedDescriptionKey: [NSString stringWithFormat:@"Invalid main path: %@", mainPath]}];
        }
        return NO;
    }

    NSString *groupId = parts[0];
    NSString *artifactId = parts[1];
    NSString *version = parts[2];

    NSString *groupPath = [groupId stringByReplacingOccurrencesOfString:@"." withString:@"/"];

    // Modeled on FCL/HMCL: try several classifiers.
    // In practice the Forge maven (for example 1.21.11-61.0.x) usually publishes only -universal (HTTP 200),
    // while -client and the classifier-less form both 404. Early Forge (1.7-1.12) also mostly used -universal.
    // The order was therefore changed to universal -> client -> no classifier, trying the most likely universal first
    // instead of wasting time on the client form that is bound to 404 (every 404 still costs a round trip).
    NSArray *classifiers = @[@"universal", @"client", @""];
    NSString *downloadSource = getPrefObject(@"general.download_source");
    BOOL useBMCLAPI = [downloadSource isEqualToString:@"bmclapi"];

    // Source URL construction: the official source + BMCLAPI + the HMCL mirror
    // Note: the Tencent Cloud mirror (mirrors.cloud.tencent.com/maven) does not mirror the Forge/NeoForge maven,
    // so using it as a fallback was a misconfiguration; it has been replaced with the HMCL mirror (mirror.hua-u.me).
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
        if (useBMCLAPI) {
            [baseURLs addObject:@"https://bmclapi2.bangbang93.com/maven"];
            [baseURLs addObject:@"https://maven.minecraftforge.net"];
        } else {
            [baseURLs addObject:@"https://maven.minecraftforge.net"];
            [baseURLs addObject:@"https://bmclapi2.bangbang93.com/maven"];
        }
    }
    // The HMCL mirror is the last resort (it is reasonably available in mainland China and mirrors the Forge maven)
    if ([groupId hasPrefix:@"net.neoforged"]) {
        [baseURLs addObject:@"https://mirror.hua-u.me/neoforge"];
    } else {
        [baseURLs addObject:@"https://mirror.hua-u.me/forge"];
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

        // Skip it if it already exists
        if ([NSFileManager.defaultManager fileExistsAtPath:destPath]) {
            NSLog(@"[ForgeDirect] Patched artifact already exists: %@", destPath);
            return YES;
        }

        for (NSString *baseURL in baseURLs) {
            NSString *url = [NSString stringWithFormat:@"%@/%@", baseURL, relativePath];
            if (firstTriedURL == nil) firstTriedURL = url;
            NSLog(@"[ForgeDirect] Trying classifier=%@ source=%@", classifier, url);
            NSError *downloadError = nil;
            if ([self downloadFileFromURL:url toPath:destPath error:&downloadError]) {
                NSLog(@"[ForgeDirect] Patched artifact downloaded: %@ (classifier=%@)", destPath, classifier);
                return YES;
            }
            // Download failed: clean up any partial file, so it is not mistaken for an existing one next time
            [NSFileManager.defaultManager removeItemAtPath:destPath error:nil];
            lastError = downloadError;
            NSLog(@"[ForgeDirect] Failed: %@ (%@)", url, downloadError.localizedDescription ?: @"Unknown error");
        }
    }

    if (error) {
        *error = [NSError errorWithDomain:ForgeDirectInstallerErrorDomain
                                     code:ForgeDirectInstallerErrorExtractionFailed
                                 userInfo:@{
                                     NSLocalizedDescriptionKey: [NSString stringWithFormat:@"Failed to download the pre-patched core jar\nPrimary URL: %@\nClassifiers tried: client/universal/none\nSources tried: official/BMCLAPI/HMCL mirror\nLast error: %@",
                                         firstTriedURL ?: @"Unknown",
                                         lastError.localizedDescription ?: @"Unknown error"]
                                 }];
    }
    return NO;
}

// Create a directory safely: if a regular file of the same name exists on the path (left over from a failed install), delete it first.
// APFS does not allow a file and a directory with the same name to coexist, so createDirectoryAtPath would fail outright.
+ (BOOL)ensureDirectoryExists:(NSString *)path error:(NSError **)error {
    NSFileManager *fm = NSFileManager.defaultManager;
    BOOL isDir = NO;
    if ([fm fileExistsAtPath:path isDirectory:&isDir]) {
        if (isDir) return YES; // The directory already exists
        // A regular file of the same name exists, so delete it
        NSError *removeError = nil;
        if (![fm removeItemAtPath:path error:&removeError]) {
            if (error) {
                *error = [NSError errorWithDomain:ForgeDirectInstallerErrorDomain
                                             code:ForgeDirectInstallerErrorWriteFailed
                                         userInfo:@{NSLocalizedDescriptionKey: [NSString stringWithFormat:@"Could not delete conflicting file %@: %@", path, removeError.localizedDescription]}];
            }
            return NO;
        }
    }
    NSError *createError = nil;
    [fm createDirectoryAtPath:path withIntermediateDirectories:YES attributes:nil error:&createError];
    if (createError) {
        if (error) *error = createError;
        return NO;
    }
    return YES;
}

// Download a file synchronously to the given path (with a 60 second timeout)
+ (BOOL)downloadFileFromURL:(NSString *)urlString toPath:(NSString *)destPath error:(NSError **)error {
    if (error) *error = nil;

    NSURL *url = [NSURL URLWithString:urlString];
    if (!url) {
        if (error) {
            *error = [NSError errorWithDomain:ForgeDirectInstallerErrorDomain
                                         code:ForgeDirectInstallerErrorWriteFailed
                                     userInfo:@{NSLocalizedDescriptionKey: [NSString stringWithFormat:@"Invalid URL: %@", urlString]}];
        }
        return NO;
    }

    // Create the target directory (handling collisions with a file of the same name)
    NSString *destDir = [destPath stringByDeletingLastPathComponent];
    NSError *dirError = nil;
    if (![self ensureDirectoryExists:destDir error:&dirError]) {
        if (error) {
            *error = dirError ?: [NSError errorWithDomain:ForgeDirectInstallerErrorDomain
                                                   code:ForgeDirectInstallerErrorWriteFailed
                                               userInfo:@{NSLocalizedDescriptionKey: [NSString stringWithFormat:@"Failed to create directory %@: %@", destDir, dirError.localizedDescription]}];
        }
        return NO;
    }

    // Download synchronously with NSURLSession and a 60 second timeout (so dataWithContentsOfURL does not hang on a weak connection)
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:url];
    request.timeoutInterval = 60.0;
    request.cachePolicy = NSURLRequestReloadIgnoringLocalCacheData;
    // Add a User-Agent: some maven repositories (BMCLAPI and Cloudflare-protected sources) reject non-browser user agents (403/WAF).
    // Modeled on FCL, a browser-style user agent is used to improve compatibility.
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
                resultError = [NSError errorWithDomain:ForgeDirectInstallerErrorDomain
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
            *error = [NSError errorWithDomain:ForgeDirectInstallerErrorDomain
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
            *error = [NSError errorWithDomain:ForgeDirectInstallerErrorDomain
                                         code:ForgeDirectInstallerErrorWriteFailed
                                     userInfo:@{NSLocalizedDescriptionKey: [NSString stringWithFormat:@"Empty response: %@", urlString]}];
        }
        return NO;
    }

    BOOL written = [resultData writeToFile:destPath options:NSDataWritingAtomic error:error];
    if (!written) {
        return NO;
    }

    NSLog(@"[ForgeDirect] Downloaded %@ (%lu bytes) -> %@", urlString.lastPathComponent ?: urlString, (unsigned long)resultData.length, destPath);
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
        NSLog(@"[ForgeDirect] Failed to open archive: %@", openError.localizedDescription ?: @"unknown");
        if (error) {
            *error = [NSError errorWithDomain:ForgeDirectInstallerErrorDomain
                                         code:ForgeDirectInstallerErrorInvalidArchive
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
        NSLog(@"[ForgeDirect] Failed to extract entry '%@': %@", entryPath, extractError.localizedDescription ?: @"unknown");
        if (error) {
            *error = [NSError errorWithDomain:ForgeDirectInstallerErrorDomain
                                         code:ForgeDirectInstallerErrorExtractionFailed
                                     userInfo:@{NSLocalizedDescriptionKey: [NSString stringWithFormat:@"Failed to extract %@: %@", entryPath, extractError.localizedDescription ?: @"not found"]}];
        }
        return nil;
    }

    NSLog(@"[ForgeDirect] Extracted entry '%@' (%lu bytes)", entryPath, (unsigned long)result.length);
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
            *error = [NSError errorWithDomain:ForgeDirectInstallerErrorDomain
                                         code:ForgeDirectInstallerErrorExtractionFailed
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
        NSLog(@"[ForgeDirect] Failed to create directory '%@': %@", destDir, dirError.localizedDescription);
        if (error) {
            *error = [NSError errorWithDomain:ForgeDirectInstallerErrorDomain
                                         code:ForgeDirectInstallerErrorWriteFailed
                                     userInfo:@{NSLocalizedDescriptionKey: [NSString stringWithFormat:@"Failed to create directory %@: %@", destDir, dirError.localizedDescription]}];
        }
        return NO;
    }

    BOOL written = [data writeToFile:destPath options:NSDataWritingAtomic error:error];
    if (!written) {
        NSLog(@"[ForgeDirect] Failed to write file '%@'", destPath);
        if (error && !*error) {
            *error = [NSError errorWithDomain:ForgeDirectInstallerErrorDomain
                                         code:ForgeDirectInstallerErrorWriteFailed
                                     userInfo:@{NSLocalizedDescriptionKey: [NSString stringWithFormat:@"Failed to write %@", destPath]}];
        }
        return NO;
    }

    NSLog(@"[ForgeDirect] Written file '%@' (%lu bytes)", destPath, (unsigned long)data.length);
    return YES;
}

#pragma mark - Maven path utilities

+ (NSString *)mavenPathToRelativePath:(NSString *)mavenPath {
    // Format: groupId:artifactId:version[:classifier]
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
    // Same format as mavenPathToRelativePath
    return [self mavenPathToRelativePath:name];
}

@end
