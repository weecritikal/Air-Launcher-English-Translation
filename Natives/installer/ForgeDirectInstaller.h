//
//  ForgeDirectInstaller.h
//  Amethyst
//
//  Direct Forge installer (old + new format) based on FCL logic.
//

#import <Foundation/Foundation.h>

extern NSString *const ForgeDirectInstallerErrorDomain;

typedef NS_ENUM(NSInteger, ForgeDirectInstallerErrorCode) {
    ForgeDirectInstallerErrorInvalidArchive   = 1,
    ForgeDirectInstallerErrorMissingProfile   = 2,
    ForgeDirectInstallerErrorInvalidProfile   = 3,
    ForgeDirectInstallerErrorExtractionFailed = 4,
    ForgeDirectInstallerErrorWriteFailed      = 5,
    ForgeDirectInstallerErrorException        = 6
};

@interface ForgeDirectInstaller : NSObject

+ (BOOL)installForgeFromInstaller:(NSString *)installerPath
                        versionId:(NSString *)versionId
                            error:(NSError **)error;

+ (BOOL)installForgeFromInstaller:(NSString *)installerPath
                        versionId:(NSString *)versionId
                          progress:(void (^)(double progress, NSString *stageMessage))progress
                            error:(NSError **)error;

+ (BOOL)isNewFormatInstaller:(NSString *)installerPath;

@end
