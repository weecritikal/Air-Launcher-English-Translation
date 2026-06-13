//
//  ForgeDirectInstaller.m
//  Amethyst
//
//  Direct Forge installer (old + new format) based on FCL logic.
//

#import "ForgeDirectInstaller.h"
#import "PLProfiles.h"
#import "utils.h"

#import "SSZipArchive.h"
#include "minizip/mz_compat.h"
#include "minizip/mz_zip.h"
#include "minizip/mz_os.h"

NSString *const ForgeDirectInstallerErrorDomain = @"ForgeDirectInstallerErrorDomain";

@implementation ForgeDirectInstaller

#pragma mark - Public

+ (BOOL)installForgeFromInstaller:(NSString *)installerPath
                        versionId:(NSString *)versionId
                            error:(NSError **)error {
    if (error) {
        *error = nil;
    }

    // Step 1 & 2: Open jar as ZIP and read install_profile.json
    NSData *profileData = [self dataFromZip:installerPath entry:@"install_profile.json" error:error];
    if (!profileData) {
        if (error && !*error) {
            *error = [NSError errorWithDomain:ForgeDirectInstallerErrorDomain
                                         code:ForgeDirectInstallerErrorMissingProfile
                                     userInfo:@{NSLocalizedDescriptionKey: @"Missing install_profile.json in installer"}];
        }
        return NO;
    }

    // Step 3: Parse install_profile.json
    NSError *jsonError = nil;
    NSMutableDictionary *installProfile = [NSJSONSerialization JSONObjectWithData:profileData
                                                                          options:NSJSONReadingMutableContainers
                                                                            error:&jsonError];
    if (![installProfile isKindOfClass:[NSDictionary class]] || jsonError) {
        if (error) {
            *error = [NSError errorWithDomain:ForgeDirectInstallerErrorDomain
                                         code:ForgeDirectInstallerErrorInvalidProfile
                                     userInfo:@{NSLocalizedDescriptionKey: @"Failed to parse install_profile.json"}];
        }
        return NO;
    }

    // Step 4: Determine format
    BOOL isNewFormat = (installProfile[@"spec"] != nil);
    BOOL isOldFormat = (installProfile[@"install"] != nil && installProfile[@"versionInfo"] != nil);

    if (!isNewFormat && !isOldFormat) {
        if (error) {
            *error = [NSError errorWithDomain:ForgeDirectInstallerErrorDomain
                                         code:ForgeDirectInstallerErrorInvalidProfile
                                     userInfo:@{NSLocalizedDescriptionKey: @"Unknown install_profile format"}];
        }
        return NO;
    }

    NSString *gameDir = [self gameDirectory];

    BOOL success = NO;
    if (isOldFormat) {
        success = [self installOldFormat:installProfile
                           installerPath:installerPath
                               versionId:versionId
                                gameDir:gameDir
                                  error:error];
    } else {
        success = [self installNewFormat:installProfile
                           installerPath:installerPath
                               versionId:versionId
                                gameDir:gameDir
                                  error:error];
    }

    if (!success) {
        return NO;
    }

    // Step 7: Register version in launcher_profiles.json
    [self registerVersion:versionId];

    return YES;
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

+ (NSString *)gameDirectory {
    const char *env = getenv("POJAV_GAME_DIR");
    if (env) {
        return [@(env) stringByStandardizingPath];
    }
    return NSHomeDirectory();
}

+ (void)registerVersion:(NSString *)versionId {
    PLProfiles *profiles = [PLProfiles current];
    NSMutableDictionary *profileDict = [NSMutableDictionary dictionary];
    profileDict[@"name"] = versionId;
    profileDict[@"lastVersionId"] = versionId;
    profileDict[@"gameDir"] = @".";
    [profiles saveProfile:profileDict withName:versionId];
}

#pragma mark - Old format (Forge 1.12.2-)

+ (BOOL)installOldFormat:(NSDictionary *)installProfile
           installerPath:(NSString *)installerPath
               versionId:(NSString *)versionId
                gameDir:(NSString *)gameDir
                  error:(NSError **)error {
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

    // Write version JSON
    NSString *versionDir = [gameDir stringByAppendingPathComponent:[NSString stringWithFormat:@"versions/%@", versionId]];
    NSString *versionJsonPath = [versionDir stringByAppendingPathComponent:[NSString stringWithFormat:@"%@.json", versionId]];

    [[NSFileManager defaultManager] createDirectoryAtPath:versionDir
                              withIntermediateDirectories:YES
                                               attributes:nil
                                                    error:nil];

    NSError *writeError = saveJSONToFile(mutableVersionInfo, versionJsonPath);
    if (writeError) {
        if (error) {
            *error = [NSError errorWithDomain:ForgeDirectInstallerErrorDomain
                                         code:ForgeDirectInstallerErrorWriteFailed
                                     userInfo:@{NSLocalizedDescriptionKey: [NSString stringWithFormat:@"Failed to write version JSON: %@", writeError.localizedDescription]}];
        }
        return NO;
    }

    // Extract universal jar
    NSDictionary *installDict = installProfile[@"install"];
    id filePathObj = installDict[@"filePath"];
    id mavenPathObj = installDict[@"path"];
    NSString *filePath = [filePathObj isKindOfClass:[NSString class]] ? filePathObj : nil;
    NSString *mavenPath = [mavenPathObj isKindOfClass:[NSString class]] ? mavenPathObj : nil;

    if (filePath.length > 0) {
        NSString *destPath;
        if (mavenPath.length > 0) {
            destPath = [gameDir stringByAppendingPathComponent:[NSString stringWithFormat:@"libraries/%@", [self mavenPathToRelativePath:mavenPath]]];
        } else {
            destPath = [versionDir stringByAppendingPathComponent:[filePath lastPathComponent]];
        }

        if (![self extractFile:installerPath entry:filePath to:destPath error:error]) {
            return NO;
        }
    }

    return YES;
}

#pragma mark - New format (Forge 1.13+)

+ (BOOL)installNewFormat:(NSDictionary *)installProfile
           installerPath:(NSString *)installerPath
               versionId:(NSString *)versionId
                gameDir:(NSString *)gameDir
                  error:(NSError **)error {
    // Read version.json
    NSString *versionJsonEntry = installProfile[@"json"];
    if (!versionJsonEntry || ![versionJsonEntry isKindOfClass:[NSString class]]) {
        versionJsonEntry = @"version.json";
    }

    NSData *versionData = [self dataFromZip:installerPath entry:versionJsonEntry error:error];
    if (!versionData) {
        if (error && !*error) {
            *error = [NSError errorWithDomain:ForgeDirectInstallerErrorDomain
                                         code:ForgeDirectInstallerErrorMissingProfile
                                     userInfo:@{NSLocalizedDescriptionKey: @"Missing version.json in installer"}];
        }
        return NO;
    }

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

    versionJson[@"id"] = versionId;

    // Merge libraries from install_profile into versionJson
    NSArray *profileLibraries = installProfile[@"libraries"];
    if ([profileLibraries isKindOfClass:[NSArray class]] && profileLibraries.count > 0) {
        NSMutableArray *mergedLibraries = [NSMutableArray array];

        NSArray *versionLibraries = versionJson[@"libraries"];
        if ([versionLibraries isKindOfClass:[NSArray class]]) {
            [mergedLibraries addObjectsFromArray:versionLibraries];
        }

        [mergedLibraries addObjectsFromArray:profileLibraries];
        versionJson[@"libraries"] = mergedLibraries;
    }

    // Write version JSON
    NSString *versionDir = [gameDir stringByAppendingPathComponent:[NSString stringWithFormat:@"versions/%@", versionId]];
    NSString *versionJsonPath = [versionDir stringByAppendingPathComponent:[NSString stringWithFormat:@"%@.json", versionId]];

    [[NSFileManager defaultManager] createDirectoryAtPath:versionDir
                              withIntermediateDirectories:YES
                                               attributes:nil
                                                    error:nil];

    NSError *writeError = saveJSONToFile(versionJson, versionJsonPath);
    if (writeError) {
        if (error) {
            *error = [NSError errorWithDomain:ForgeDirectInstallerErrorDomain
                                         code:ForgeDirectInstallerErrorWriteFailed
                                     userInfo:@{NSLocalizedDescriptionKey: [NSString stringWithFormat:@"Failed to write version JSON: %@", writeError.localizedDescription]}];
        }
        return NO;
    }

    // Extract libraries
    NSArray *libraries = installProfile[@"libraries"];
    if ([libraries isKindOfClass:[NSArray class]]) {
        for (NSDictionary *library in libraries) {
            if (![library isKindOfClass:[NSDictionary class]]) {
                continue;
            }

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
                NSString *name = [nameObj isKindOfClass:[NSString class]] ? nameObj : nil;
                if (name.length > 0) {
                    relativePath = [self mavenNameToPath:name];
                }
            }

            if (relativePath.length > 0) {
                NSString *sourcePath = [NSString stringWithFormat:@"maven/%@", relativePath];
                NSString *destPath = [gameDir stringByAppendingPathComponent:[NSString stringWithFormat:@"libraries/%@", relativePath]];

                // Only extract if the entry exists in the jar
                if ([self entryExists:installerPath entry:sourcePath]) {
                    if (![self extractFile:installerPath entry:sourcePath to:destPath error:error]) {
                        return NO;
                    }
                }
            }
        }
    }

    // Extract main path jar if present
    NSString *mainPath = installProfile[@"path"];
    if ([mainPath isKindOfClass:[NSString class]] && mainPath.length > 0) {
        NSString *relativePath = [self mavenPathToRelativePath:mainPath];
        NSString *sourcePath = [NSString stringWithFormat:@"maven/%@", relativePath];
        NSString *destPath = [gameDir stringByAppendingPathComponent:[NSString stringWithFormat:@"libraries/%@", relativePath]];

        if ([self entryExists:installerPath entry:sourcePath]) {
            if (![self extractFile:installerPath entry:sourcePath to:destPath error:error]) {
                return NO;
            }
        }
    }

    return YES;
}

#pragma mark - ZIP / minizip helpers

+ (NSData *)dataFromZip:(NSString *)zipPath entry:(NSString *)entryPath error:(NSError **)error {
    if (error) {
        *error = nil;
    }

    zipFile zip = unzOpen(zipPath.fileSystemRepresentation);
    if (zip == NULL) {
        if (error) {
            *error = [NSError errorWithDomain:ForgeDirectInstallerErrorDomain
                                         code:ForgeDirectInstallerErrorInvalidArchive
                                     userInfo:@{NSLocalizedDescriptionKey: @"Failed to open installer archive"}];
        }
        return nil;
    }

    int ret = unzGoToFirstFile(zip);
    NSData *result = nil;

    while (ret == UNZ_OK) {
        unz_file_info fileInfo = {};
        char fileName[PATH_MAX];
        ret = unzGetCurrentFileInfo(zip, &fileInfo, fileName, sizeof(fileName), NULL, 0, NULL, 0);
        if (ret != UNZ_OK) {
            break;
        }

        NSString *currentName = @(fileName);
        if ([currentName isEqualToString:entryPath]) {
            ret = unzOpenCurrentFile(zip);
            if (ret != UNZ_OK) {
                break;
            }

            NSMutableData *data = [NSMutableData dataWithLength:(NSUInteger)fileInfo.uncompressed_size];
            int read = unzReadCurrentFile(zip, data.mutableBytes, (unsigned int)fileInfo.uncompressed_size);
            unzCloseCurrentFile(zip);

            if (read == fileInfo.uncompressed_size) {
                result = data;
            }
            break;
        }

        ret = unzGoToNextFile(zip);
    }

    unzClose(zip);
    return result;
}

+ (BOOL)entryExists:(NSString *)zipPath entry:(NSString *)entryPath {
    zipFile zip = unzOpen(zipPath.fileSystemRepresentation);
    if (zip == NULL) {
        return NO;
    }

    int ret = unzGoToFirstFile(zip);
    BOOL found = NO;

    while (ret == UNZ_OK) {
        char fileName[PATH_MAX];
        ret = unzGetCurrentFileInfo(zip, NULL, fileName, sizeof(fileName), NULL, 0, NULL, 0);
        if (ret != UNZ_OK) {
            break;
        }

        if ([@(fileName) isEqualToString:entryPath]) {
            found = YES;
            break;
        }

        ret = unzGoToNextFile(zip);
    }

    unzClose(zip);
    return found;
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
    [[NSFileManager defaultManager] createDirectoryAtPath:destDir
                              withIntermediateDirectories:YES
                                               attributes:nil
                                                    error:nil];

    BOOL written = [data writeToFile:destPath options:NSDataWritingAtomic error:error];
    if (!written) {
        if (error && !*error) {
            *error = [NSError errorWithDomain:ForgeDirectInstallerErrorDomain
                                         code:ForgeDirectInstallerErrorWriteFailed
                                     userInfo:@{NSLocalizedDescriptionKey: [NSString stringWithFormat:@"Failed to write %@", destPath]}];
        }
        return NO;
    }

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
