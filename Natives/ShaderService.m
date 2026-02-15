//
//  ShaderService.m
//  Amethyst
//
//  Shader service implementation
//

#import "ShaderService.h"
#import <CommonCrypto/CommonCrypto.h>
#import <UIKit/UIKit.h>
#import "PLProfiles.h"
#import "ShaderItem.h"

@interface ShaderService () <NSURLSessionDownloadDelegate>
@property (nonatomic, strong) NSURLSession *downloadSession;
@property (nonatomic, strong) NSMutableDictionary<NSURLSessionTask *, ShaderDownloadHandler> *downloadCompletionHandlers;
@property (nonatomic, strong) NSMutableDictionary<NSURLSessionTask *, NSString *> *downloadDestinationPaths;
@end

@implementation ShaderService

+ (instancetype)sharedService {
    static ShaderService *s;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        s = [[ShaderService alloc] init];
    });
    return s;
}

- (instancetype)init {
    if (self = [super init]) {
        _onlineSearchEnabled = NO;
        NSURLSessionConfiguration *config = [NSURLSessionConfiguration backgroundSessionConfigurationWithIdentifier:@"com.amethyst.shaderdownloader"];
        _downloadSession = [NSURLSession sessionWithConfiguration:config delegate:self delegateQueue:nil];
        _downloadCompletionHandlers = [NSMutableDictionary dictionary];
        _downloadDestinationPaths = [NSMutableDictionary dictionary];
    }
    return self;
}

#pragma mark - Helpers

- (nullable NSString *)sha1ForFileAtPath:(NSString *)path {
    NSData *d = [NSData dataWithContentsOfFile:path];
    if (!d) return nil;
    unsigned char digest[CC_SHA1_DIGEST_LENGTH];
    CC_SHA1(d.bytes, (CC_LONG)d.length, digest);
    NSMutableString *hex = [NSMutableString stringWithCapacity:CC_SHA1_DIGEST_LENGTH * 2];
    for (int i = 0; i < CC_SHA1_DIGEST_LENGTH; i++) {
        [hex appendFormat:@"%02x", digest[i]];
    }
    return [hex copy];
}

- (NSString *)iconCachePathForURL:(NSString *)urlString {
    if (!urlString) return nil;
    NSString *cacheDir = [NSSearchPathForDirectoriesInDomains(NSCachesDirectory, NSUserDomainMask, YES) firstObject];
    NSString *folder = [cacheDir stringByAppendingPathComponent:@"shader_icons"];
    if (![[NSFileManager defaultManager] fileExistsAtPath:folder]) {
        [[NSFileManager defaultManager] createDirectoryAtPath:folder withIntermediateDirectories:YES attributes:nil error:nil];
    }
    const char *cstr = [urlString UTF8String];
    unsigned char digest[CC_SHA1_DIGEST_LENGTH];
    CC_SHA1(cstr, (CC_LONG)strlen(cstr), digest);
    NSMutableString *hex = [NSMutableString stringWithCapacity:CC_SHA1_DIGEST_LENGTH * 2];
    for (int i = 0; i < CC_SHA1_DIGEST_LENGTH; i++) {
        [hex appendFormat:@"%02x", digest[i]];
    }
    return [folder stringByAppendingPathComponent:hex];
}

#pragma mark - Shaders folder detection & scan

- (nullable NSString *)existingShadersFolderForProfile:(NSString *)profileName {
    NSString *profile = profileName.length ? profileName : @"default";
    NSFileManager *fm = [NSFileManager defaultManager];

    @try {
        NSDictionary *profiles = PLProfiles.current.profiles;
        NSDictionary *prof = profiles[profile];
        if ([prof isKindOfClass:[NSDictionary class]]) {
            NSString *gameDir = prof[@"gameDir"];
            if ([gameDir isKindOfClass:[NSString class]] && gameDir.length > 0) {
                // Check for shaderpacks folder (standard location)
                NSString *shadersPath = [gameDir stringByAppendingPathComponent:@"shaderpacks"];
                BOOL isDir = NO;
                if ([fm fileExistsAtPath:shadersPath isDirectory:&isDir] && isDir) {
                    return shadersPath;
                }
            }
        }
    } @catch (NSException *ex) { }

    const char *gameDirC = getenv("POJAV_GAME_DIR");
    if (gameDirC) {
        NSString *gameDir = [NSString stringWithUTF8String:gameDirC];
        NSString *shadersPath = [gameDir stringByAppendingPathComponent:@"shaderpacks"];
        BOOL isDir = NO;
        if ([fm fileExistsAtPath:shadersPath isDirectory:&isDir] && isDir) {
            return shadersPath;
        }
    }
    return nil;
}

- (void)scanShadersForProfile:(NSString *)profileName completion:(ShaderListHandler)completion {
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSString *shadersFolder = [self existingShadersFolderForProfile:profileName];
        NSMutableArray<ShaderItem *> *items = [NSMutableArray array];

        if (!shadersFolder) {
            if (completion) {
                completion(items);
            }
            return;
        }

        NSArray<NSString *> *contents = [[NSFileManager defaultManager] contentsOfDirectoryAtPath:shadersFolder error:nil];
        dispatch_group_t group = dispatch_group_create();

        for (NSString *fileName in contents) {
            if ([fileName.lowercaseString hasSuffix:@".zip"] || [fileName.lowercaseString hasSuffix:@".zip.disabled"]) {
                NSString *fullPath = [shadersFolder stringByAppendingPathComponent:fileName];
                ShaderItem *shader = [[ShaderItem alloc] initWithFilePath:fullPath];
                [items addObject:shader];

                dispatch_group_enter(group);
                [self fetchMetadataForShader:shader completion:^(ShaderItem *populatedShader, NSError * _Nullable error) {
                    dispatch_group_leave(group);
                }];
            }
        }

        dispatch_group_notify(group, dispatch_get_main_queue(), ^{
            // Sort after all metadata has been fetched
            [items sortUsingComparator:^NSComparisonResult(ShaderItem *obj1, ShaderItem *obj2) {
                NSString *name1 = obj1.displayName ?: obj1.fileName;
                NSString *name2 = obj2.displayName ?: obj2.fileName;
                return [name1 localizedCaseInsensitiveCompare:name2];
            }];

            if (completion) {
                completion(items);
            }
        });
    });
}

#pragma mark - Metadata fetch

- (void)fetchMetadataForShader:(ShaderItem *)shader completion:(ShaderMetadataHandler)completion {
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        // For shaders, we don't have embedded metadata like mods do
        // We can try to parse from filename or use cached data
        // For now, just return the shader as-is
        
        if (completion) completion(shader, nil);
    });
}

#pragma mark - File operations

- (BOOL)toggleEnableForShader:(ShaderItem *)shader error:(NSError **)error {
    NSFileManager *fileManager = [NSFileManager defaultManager];
    NSString *currentPath = shader.filePath;
    NSString *newPath;

    if (shader.disabled) {
        // Enable the shader: remove .disabled suffix
        if ([currentPath.lowercaseString hasSuffix:@".zip.disabled"]) {
            newPath = [currentPath substringToIndex:currentPath.length - [@".disabled" length]];
        } else {
            if (error) *error = [NSError errorWithDomain:@"ShaderServiceError" code:101 userInfo:@{NSLocalizedDescriptionKey:@"File state inconsistent, cannot enable."}];
            return NO;
        }
    } else {
        // Disable the shader: add .disabled suffix
        newPath = [currentPath stringByAppendingString:@".disabled"];
    }

    BOOL success = [fileManager moveItemAtPath:currentPath toPath:newPath error:error];
    if (success) {
        // IMPORTANT: Update the model object to reflect the change
        shader.filePath = newPath;
        shader.fileName = [newPath lastPathComponent];
        [shader refreshDisabledFlag]; // This will set `disabled` property correctly
    }

    return success;
}

- (BOOL)deleteShader:(ShaderItem *)shader error:(NSError **)error {
    return [[NSFileManager defaultManager] removeItemAtPath:shader.filePath error:error];
}

#pragma mark - Online Shader Downloading

- (void)downloadShader:(ShaderItem *)shader toProfile:(NSString *)profileName completion:(ShaderDownloadHandler)completion {
    NSString *shadersFolder = [self existingShadersFolderForProfile:profileName];
    if (!shadersFolder) {
        // Try to create shaderpacks folder
        NSString *profile = profileName.length ? profileName : @"default";
        NSString *gameDir = nil;
        
        @try {
            NSDictionary *profiles = PLProfiles.current.profiles;
            NSDictionary *prof = profiles[profile];
            if ([prof isKindOfClass:[NSDictionary class]]) {
                gameDir = prof[@"gameDir"];
            }
        } @catch (NSException *ex) { }
        
        if (!gameDir) {
            const char *gameDirC = getenv("POJAV_GAME_DIR");
            if (gameDirC) {
                gameDir = [NSString stringWithUTF8String:gameDirC];
            }
        }
        
        if (gameDir) {
            shadersFolder = [gameDir stringByAppendingPathComponent:@"shaderpacks"];
            NSError *dirError = nil;
            [[NSFileManager defaultManager] createDirectoryAtPath:shadersFolder withIntermediateDirectories:YES attributes:nil error:&dirError];
            if (dirError) {
                if (completion) {
                    NSError *error = [NSError errorWithDomain:@"ShaderServiceError" code:1 userInfo:@{NSLocalizedDescriptionKey:@"Cannot create shaderpacks folder."}];
                    completion(error);
                }
                return;
            }
        } else {
            if (completion) {
                NSError *error = [NSError errorWithDomain:@"ShaderServiceError" code:1 userInfo:@{NSLocalizedDescriptionKey:@"Cannot find shaderpacks folder."}];
                completion(error);
            }
            return;
        }
    }

    NSURL *url = [NSURL URLWithString:shader.selectedVersionDownloadURL];
    if (!url) {
        if (completion) {
            NSError *error = [NSError errorWithDomain:@"ShaderServiceError" code:2 userInfo:@{NSLocalizedDescriptionKey:@"Invalid download URL."}];
            completion(error);
        }
        return;
    }

    NSString *destinationPath = [shadersFolder stringByAppendingPathComponent:shader.fileName];

    NSURLSessionDownloadTask *task = [self.downloadSession downloadTaskWithURL:url];
    self.downloadCompletionHandlers[task] = completion;
    self.downloadDestinationPaths[task] = destinationPath;

    [task resume];
}

#pragma mark - NSURLSessionDownloadDelegate

- (void)URLSession:(NSURLSession *)session downloadTask:(NSURLSessionDownloadTask *)downloadTask didFinishDownloadingToURL:(NSURL *)location {
    ShaderDownloadHandler handler = self.downloadCompletionHandlers[downloadTask];
    NSString *destinationPath = self.downloadDestinationPaths[downloadTask];

    [self.downloadCompletionHandlers removeObjectForKey:downloadTask];
    [self.downloadDestinationPaths removeObjectForKey:downloadTask];

    if (!handler || !destinationPath) {
        return;
    }

    NSFileManager *fm = [NSFileManager defaultManager];
    NSError *moveError = nil;

    // Ensure the destination directory exists
    NSString *dir = [destinationPath stringByDeletingLastPathComponent];
    if (![fm fileExistsAtPath:dir]) {
        [fm createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:nil];
    }

    // If a file already exists, remove it
    if ([fm fileExistsAtPath:destinationPath]) {
        [fm removeItemAtPath:destinationPath error:nil];
    }

    if (![fm moveItemAtURL:location toURL:[NSURL fileURLWithPath:destinationPath] error:&moveError]) {
        handler(moveError);
    } else {
        handler(nil); // Success
    }
}

- (void)URLSession:(NSURLSession *)session task:(NSURLSessionTask *)task didCompleteWithError:(NSError *)error {
    if (error) {
        ShaderDownloadHandler handler = self.downloadCompletionHandlers[task];
        if (handler) {
            handler(error);
            [self.downloadCompletionHandlers removeObjectForKey:task];
            [self.downloadDestinationPaths removeObjectForKey:task];
        }
    }
}

@end
