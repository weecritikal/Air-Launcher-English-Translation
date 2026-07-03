//
//  NeoForgeDirectInstaller.m
//  Amethyst
//
//  Direct NeoForge installer (new format only, NeoForge 1.20.1+).
//

#import "NeoForgeDirectInstaller.h"
#import "PLProfiles.h"
#import "utils.h"
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
    void (^reportProgress)(double, NSString *) = ^(double p, NSString *msg) {
        NSLog(@"[NeoForgeDirect] Progress: %.2f - %@", p, msg);
        if (progress) {
            progress(p, msg);
        }
    };

    @try {
        NSLog(@"[NeoForgeDirect] Starting installation: %@", versionId);
        reportProgress(0.0, @"开始安装");
        if (error) {
            *error = nil;
        }

        // Step 1: Read install_profile.json
        NSLog(@"[NeoForgeDirect] Reading install_profile.json");
        reportProgress(0.1, @"正在读取 install_profile.json");
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
        reportProgress(0.2, @"正在解析 JSON");
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

        NSString *gameDir = [self gameDirectory];
        NSLog(@"[NeoForgeDirect] Game directory: %@", gameDir);
        reportProgress(0.3, @"正在准备版本目录");

        BOOL success = [self installNewFormat:installProfile
                               installerPath:installerPath
                                   versionId:versionId
                                     gameDir:gameDir
                                    progress:progress
                                      error:error];
        if (!success) {
            NSLog(@"[NeoForgeDirect] Installation failed");
            return NO;
        }

        // Step: Register version in launcher_profiles.json (must run on main thread)
        NSLog(@"[NeoForgeDirect] Registering version on main thread");
        reportProgress(0.9, @"正在注册版本");
        if ([NSThread isMainThread]) {
            [self registerVersion:versionId];
        } else {
            dispatch_sync(dispatch_get_main_queue(), ^{
                [self registerVersion:versionId];
            });
        }
        NSLog(@"[NeoForgeDirect] Version registered successfully");

        NSLog(@"[NeoForgeDirect] Installation completed successfully");
        reportProgress(1.0, @"安装完成");
        return YES;
    }
    @catch (NSException *exception) {
        NSString *stack = [exception.callStackSymbols componentsJoinedByString:@"\n"];
        NSLog(@"[NeoForgeDirect] EXCEPTION: name=%@, reason=%@, callStack=%@", exception.name, exception.reason, stack);
        if (error) {
            *error = [NSError errorWithDomain:NeoForgeDirectInstallerErrorDomain
                                          code:NeoForgeDirectInstallerErrorException
                                      userInfo:@{
                                          NSLocalizedDescriptionKey: [NSString stringWithFormat:@"安装异常: %@", exception.reason ?: @"未知原因"],
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

    // Merge libraries from install_profile into versionJson (dedup by name)
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
        versionJson[@"libraries"] = mergedLibraries;
    }

    // Prepare version directory
    NSString *versionDir = [gameDir stringByAppendingPathComponent:[NSString stringWithFormat:@"versions/%@", versionId]];
    NSString *versionJsonPath = [versionDir stringByAppendingPathComponent:[NSString stringWithFormat:@"%@.json", versionId]];
    NSLog(@"[NeoForgeDirect] Version directory: %@", versionDir);
    [[NSFileManager defaultManager] createDirectoryAtPath:versionDir
                              withIntermediateDirectories:YES
                                               attributes:nil
                                                    error:nil];

    // Extract libraries
    NSLog(@"[NeoForgeDirect] Extracting libraries");
    NSArray *libraries = installProfile[@"libraries"];
    if ([libraries isKindOfClass:[NSArray class]]) {
        NSUInteger total = libraries.count;
        NSLog(@"[NeoForgeDirect] Extracting libraries, count: %lu", (unsigned long)total);
        NSUInteger i = 0;
        for (NSDictionary *library in libraries) {
            if (![library isKindOfClass:[NSDictionary class]]) {
                i++;
                continue;
            }

            NSString *name = [library[@"name"] isKindOfClass:[NSString class]] ? library[@"name"] : @"<unknown>";
            NSLog(@"[NeoForgeDirect] Extracting library %lu/%lu: %@", (unsigned long)(i + 1), (unsigned long)total, name);
            reportProgress(0.4 + 0.3 * ((double)i / (double)(total > 0 ? total : 1)),
                           [NSString stringWithFormat:@"正在提取 libraries (%lu/%lu)", (unsigned long)(i + 1), (unsigned long)total]);

            NSString *relativePath = nil;

            NSDictionary *downloads = library[@"downloads"];
            if ([downloads isKindOfClass:[NSDictionary class]]) {
                NSDictionary *artifact = downloads[@"artifact"];
                if ([artifact isKindOfClass:[NSDictionary class]]) {
                    id artifactPathObj = artifact[@"path"];
                    NSString *artifactPath = [artifactPathObj isKindOfClass:[NSString class]] ? artifactPathObj : nil;
                    if (artifactPath.length > 0) {
                        relativePath = artifactPath;
                    }
                }
            }

            if (!relativePath) {
                id nameObj = library[@"name"];
                NSString *libName = [nameObj isKindOfClass:[NSString class]] ? nameObj : nil;
                if (libName.length > 0) {
                    relativePath = [self mavenNameToPath:libName];
                }
            }

            if (relativePath.length > 0) {
                NSString *sourcePath = [NSString stringWithFormat:@"maven/%@", relativePath];
                NSString *destPath = [gameDir stringByAppendingPathComponent:[NSString stringWithFormat:@"libraries/%@", relativePath]];

                if ([self entryExists:installerPath entry:sourcePath]) {
                    if (![self extractFile:installerPath entry:sourcePath to:destPath error:error]) {
                        return NO;
                    }
                    NSLog(@"[NeoForgeDirect] Extracted library %lu/%lu: %@", (unsigned long)(i + 1), (unsigned long)total, name);
                } else {
                    NSLog(@"[NeoForgeDirect] Library entry not found in jar, skipped: %@", sourcePath);
                }
            }
            i++;
        }
    }

    // Extract main path jar if present
    NSLog(@"[NeoForgeDirect] Extracting main path jar");
    NSString *mainPath = installProfile[@"path"];
    if ([mainPath isKindOfClass:[NSString class]] && mainPath.length > 0) {
        NSString *relativePath = [self mavenPathToRelativePath:mainPath];
        NSString *sourcePath = [NSString stringWithFormat:@"maven/%@", relativePath];
        NSString *destPath = [gameDir stringByAppendingPathComponent:[NSString stringWithFormat:@"libraries/%@", relativePath]];

        if ([self entryExists:installerPath entry:sourcePath]) {
            if (![self extractFile:installerPath entry:sourcePath to:destPath error:error]) {
                return NO;
            }
            NSLog(@"[NeoForgeDirect] Main path jar extracted: %@", sourcePath);
        } else {
            NSLog(@"[NeoForgeDirect] Main path jar not found in jar, skipped: %@", sourcePath);
        }
    }

    // Write version JSON
    NSLog(@"[NeoForgeDirect] Writing version JSON to: %@", versionJsonPath);
    reportProgress(0.8, @"正在写入版本 JSON");
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

    NSLog(@"[NeoForgeDirect] installNewFormat completed");
    return YES;
}

#pragma mark - Helpers

+ (NSString *)gameDirectory {
    const char *env = getenv("POJAV_GAME_DIR");
    if (env) {
        return [@(env) stringByStandardizingPath];
    }
    return NSHomeDirectory();
}

+ (void)registerVersion:(NSString *)versionId {
    NSLog(@"[NeoForgeDirect] registerVersion called: %@", versionId);
    PLProfiles *profiles = [PLProfiles current];
    NSLog(@"[NeoForgeDirect] PLProfiles current: %@", profiles ? @"ok" : @"nil");
    NSMutableDictionary *profileDict = [NSMutableDictionary dictionary];
    profileDict[@"name"] = versionId;
    profileDict[@"lastVersionId"] = versionId;
    profileDict[@"gameDir"] = @".";
    profileDict[@"type"] = @"custom";
    profileDict[@"created"] = [NSDate date].description;
    [profiles saveProfile:profileDict withName:versionId];
    // 与 Fabric / Vanilla 安装路径保持一致：自动选中新建的 profile，避免用户回到主界面仍启动旧版本
    profiles.selectedProfileName = versionId;
    NSLog(@"[NeoForgeDirect] Profile saved and selected");
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
