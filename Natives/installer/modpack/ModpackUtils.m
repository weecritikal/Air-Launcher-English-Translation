#import "installer/FabricUtils.h"
#import "ModpackUtils.h"
#import "LauncherPreferences.h"
#import "PLPreferences.h"

@implementation ModpackUtils

+ (void)archive:(UZKArchive *)archive extractDirectory:(NSString *)dir toPath:(NSString *)path error:(NSError *__autoreleasing*)error {
    [archive performOnFilesInArchive:^(UZKFileInfo *fileInfo, BOOL *stop) {
        if (![fileInfo.filename hasPrefix:dir] ||
            fileInfo.filename.length <= dir.length) {
            return;
        }
        NSString *fileName = [fileInfo.filename substringFromIndex:dir.length+1];
        NSString *destItemPath = [path stringByAppendingPathComponent:fileName];
        NSString *destDirPath = fileInfo.isDirectory ? destItemPath : destItemPath.stringByDeletingLastPathComponent;
        BOOL createdDir = [NSFileManager.defaultManager createDirectoryAtPath:destDirPath
            withIntermediateDirectories:YES
            attributes:nil error:error];
        if (!createdDir) {
            *stop = YES;
            return;
        } else if (fileInfo.isDirectory) {
            return;
        }

        NSData *data = [archive extractData:fileInfo error:error];
        BOOL written = [data writeToFile:destItemPath options:NSDataWritingAtomic error:error];
        *stop = !data || !written;
        if (!*stop) {
            NSLog(@"[ModpackDL] Extracted %@", fileInfo.filename);
        }
    } error:error];
}

/// Strip a leading "<minecraft version>-" from a loader version.
///
/// Modpack manifests are inconsistent about this: most declare a Forge loader as "forge-47.4.0",
/// but some spell it out as "forge-1.20.1-47.4.0". Both have to end up as the bare loader version,
/// because the Minecraft prefix is added back when the maven coordinate is built - left alone, the
/// spelled-out form produced "1.20.1-1.20.1-47.4.0" and a 404 that looked like the modpack was
/// asking for a Forge build that does not exist.
+ (NSString *)loaderVersionWithoutMinecraftPrefix:(NSString *)loaderVersion
                                 minecraftVersion:(NSString *)minecraftVersion {
    if (loaderVersion.length == 0 || minecraftVersion.length == 0) return loaderVersion;
    NSString *prefix = [minecraftVersion stringByAppendingString:@"-"];
    return [loaderVersion hasPrefix:prefix] ? [loaderVersion substringFromIndex:prefix.length] : loaderVersion;
}

+ (NSDictionary *)infoForDependencies:(NSDictionary *)dependency {
    NSMutableDictionary *info = [NSMutableDictionary new];
    NSString *minecraftVersion = dependency[@"minecraft"];
    if (dependency[@"forge"]) {
        // Forge has no separate version JSON download URL; the version JSON is embedded in installer.jar.
        // The installer URL and the loader type are set so that ModrinthAPI/CurseForgeAPI, during modpack installation,
        // download installer.jar and call ForgeDirectInstaller to write the full version.json and download the Forge libraries.
        // Setting no fields used to mean that after a modpack install only the profile was set and no version JSON was downloaded,
        // so launching reported "version information not found".
        NSString *forgeVer = [self loaderVersionWithoutMinecraftPrefix:dependency[@"forge"]
                                                     minecraftVersion:minecraftVersion];
        info[@"id"] = [NSString stringWithFormat:@"%@-forge-%@", minecraftVersion, forgeVer];
        info[@"loader"] = @"Forge";
        info[@"loaderVersion"] = forgeVer;
        info[@"installer"] = [self installerURLForLoader:@"Forge"
                                          loaderVersion:forgeVer
                                       minecraftVersion:minecraftVersion] ?: @"";
    } else if (dependency[@"fabric-loader"]) {
        info[@"id"] = [NSString stringWithFormat:@"fabric-loader-%@-%@", dependency[@"fabric-loader"], minecraftVersion];
        info[@"json"] = [NSString stringWithFormat:FabricUtils.endpoints[@"Fabric"][@"json"], minecraftVersion, dependency[@"fabric-loader"]];
    } else if (dependency[@"quilt-loader"]) {
        info[@"id"] = [NSString stringWithFormat:@"quilt-loader-%@-%@", dependency[@"quilt-loader"], minecraftVersion];
        info[@"json"] = [NSString stringWithFormat:FabricUtils.endpoints[@"Quilt"][@"json"], minecraftVersion, dependency[@"quilt-loader"]];
    } else if (dependency[@"neoforge"]) {
        // NeoForge is like Forge: the version JSON is embedded in installer.jar.
        // The installer URL and the loader type are set so NeoForgeDirectInstaller is called during modpack installation.
        NSString *neoforgeVer = [self loaderVersionWithoutMinecraftPrefix:dependency[@"neoforge"]
                                                         minecraftVersion:minecraftVersion];
        info[@"id"] = [NSString stringWithFormat:@"%@-neoforge-%@", minecraftVersion, neoforgeVer];
        info[@"loader"] = @"NeoForge";
        info[@"loaderVersion"] = neoforgeVer;
        info[@"installer"] = [self installerURLForLoader:@"NeoForge"
                                          loaderVersion:neoforgeVer
                                       minecraftVersion:minecraftVersion] ?: @"";
    }
    info[@"minecraftVersion"] = minecraftVersion ?: @"";
    return info;
}

+ (nullable NSString *)installerURLForLoader:(NSString *)loader
                               loaderVersion:(NSString *)loaderVersion
                            minecraftVersion:(NSString *)minecraftVersion {
    NSString *downloadSource = [PLPreferences currentDownloadSourceForType:@"forge"];
    BOOL useBMCLAPI = [downloadSource isEqualToString:@"bmclapi"];

    // Some manifests already spell the Minecraft version into the loader version, so strip it
    // before adding it back - otherwise the coordinate reads "1.20.1-1.20.1-47.4.0" and 404s.
    loaderVersion = [self loaderVersionWithoutMinecraftPrefix:loaderVersion minecraftVersion:minecraftVersion];

    if ([loader isEqualToString:@"Forge"]) {
        // The Forge versionString is "<mc>-<loaderVersion>", for example "1.20.1-47.3.0"
        NSString *versionString = [NSString stringWithFormat:@"%@-%@", minecraftVersion, loaderVersion];
        if (useBMCLAPI) {
            return [NSString stringWithFormat:@"https://bmclapi2.bangbang93.com/maven/net/minecraftforge/forge/%@/forge-%@-installer.jar", versionString, versionString];
        }
        return [NSString stringWithFormat:@"https://maven.minecraftforge.net/net/minecraftforge/forge/%@/forge-%@-installer.jar", versionString, versionString];
    }

    if ([loader isEqualToString:@"NeoForge"]) {
        // Early NeoForge 1.20.1 versions use the artifactId net.neoforged:forge, and later ones net.neoforged:neoforge
        // loaderVersion is for example "47.1.0" (1.20.1) or "20.6.119-beta" (1.20.6+)
        BOOL isLegacyForgeArtifact = [minecraftVersion isEqualToString:@"1.20.1"];
        if (isLegacyForgeArtifact) {
            if (useBMCLAPI) {
                return [NSString stringWithFormat:@"https://bmclapi2.bangbang93.com/maven/net/neoforged/forge/%@/forge-%@-installer.jar", loaderVersion, loaderVersion];
            }
            return [NSString stringWithFormat:@"https://maven.neoforged.net/releases/net/neoforged/forge/%@/forge-%@-installer.jar", loaderVersion, loaderVersion];
        }
        if (useBMCLAPI) {
            return [NSString stringWithFormat:@"https://bmclapi2.bangbang93.com/maven/net/neoforged/neoforge/%@/neoforge-%@-installer.jar", loaderVersion, loaderVersion];
        }
        return [NSString stringWithFormat:@"https://maven.neoforged.net/releases/net/neoforged/neoforge/%@/neoforge-%@-installer.jar", loaderVersion, loaderVersion];
    }

    return nil;
}

+ (NSInteger)javaMajorVersionForMC:(NSString *)mcVersion {
    NSArray *parts = [mcVersion componentsSeparatedByString:@"."];
    if (parts.count < 2) return 8;
    NSInteger major = [parts[1] integerValue];
    if (major >= 21) return 21;       // 1.21+
    if (major >= 20 && parts.count >= 3 && [parts[2] integerValue] >= 5) return 21; // 1.20.5+
    if (major >= 18) return 17;       // 1.18+
    if (major >= 17) return 17;       // 1.17 (Java 16 is not bundled, and Java 17 runs 1.17 fine)
    return 8;                          // 1.16.5 and earlier
}

+ (void)writePlaceholderVersionJSONForVersionId:(NSString *)versionId
                               minecraftVersion:(NSString *)minecraftVersion
                                         loader:(NSString *)loader
                                 loaderVersion:(NSString *)loaderVersion
                                          error:(NSError *)error {
    // Placeholder JSON: mainClass points at a nonexistent class, so launching reports an error explicitly
    // This keeps a failed Forge/NeoForge direct install from being mistaken for vanilla MC and making the user believe their mods are active
    NSInteger javaMajor = [self javaMajorVersionForMC:minecraftVersion];
    NSString *comment = error.localizedDescription.length > 0
        ? [NSString stringWithFormat:@"This modpack needs the %@ %@ loader and the automatic install failed: %@. Please install it manually from the download screen.", loader, loaderVersion, error.localizedDescription]
        : [NSString stringWithFormat:@"This modpack needs the %@ %@ loader and the automatic install failed. Please install it manually from the download screen.", loader, loaderVersion];
    NSDictionary *placeholderJSON = @{
        @"_comment_": comment,
        @"id": versionId ?: @"",
        @"inheritsFrom": minecraftVersion ?: @"",
        @"type": @"release",
        @"mainClass": @"net.angelaura.installer.MissingLoader",
        @"javaVersion": @{@"component": @"java-runtime", @"majorVersion": @(javaMajor)}
    };
    NSData *jsonData = [NSJSONSerialization dataWithJSONObject:placeholderJSON options:NSJSONWritingPrettyPrinted error:nil];
    if (!jsonData) return;

    // The placeholder JSON is written to POJAV_GAME_DIR/versions/{versionId}/{versionId}.json
    // Reason: the Java side always loads version JSONs from POJAV_GAME_DIR/versions
    NSString *versionDir = [NSString stringWithFormat:@"%s/versions/%@", getenv("POJAV_GAME_DIR"), versionId];
    [NSFileManager.defaultManager createDirectoryAtPath:versionDir withIntermediateDirectories:YES attributes:nil error:nil];
    NSString *versionJsonPath = [versionDir stringByAppendingPathComponent:[NSString stringWithFormat:@"%@.json", versionId]];
    [jsonData writeToFile:versionJsonPath options:NSDataWritingAtomic error:nil];
    NSLog(@"[ModpackUtils] Placeholder version JSON written: %@", versionJsonPath);
}

@end
