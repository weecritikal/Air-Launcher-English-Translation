//
//  ServerService.h
//  Amethyst
//
//  The server project service layer, following the pattern of ModService/ShaderService:
//  - wraps the Modrinth and CurseForge source switch
//  - search/details/join a server/download the server modpack
//

#import <Foundation/Foundation.h>
#import "ServerItem.h"

NS_ASSUME_NONNULL_BEGIN

/// The server search source (matching PLPreferences.currentDownloadSourceForType:@"server")
typedef NS_ENUM(NSInteger, ServerDownloadAPI) {
    ServerDownloadAPIModrinth = 1,
    ServerDownloadAPICurseForge = 2,
};

typedef void(^ServerListHandler)(NSArray<ServerItem *> *servers, NSError * _Nullable error);
typedef void(^ServerDetailHandler)(ServerItem * _Nullable server, NSError * _Nullable error);
typedef void(^ServerDownloadHandler)(NSError * _Nullable error);
typedef void(^ServerProgressHandler)(NSProgress *progress);

@interface ServerService : NSObject

+ (instancetype)sharedService;

/// Return the API matching the current preference (Modrinth or CurseForge)
+ (ServerDownloadAPI)currentAPI;

/// Search server projects (using the currently preferred source)
/// @param api The API to use (Modrinth/CurseForge)
/// @param filters The search filters (query/limit/offset/mcVersion/loader and so on)
- (void)searchServersWithAPI:(ServerDownloadAPI)api
                     filters:(NSDictionary *)filters
                  completion:(ServerListHandler)completion;

/// Get the server details (filling in the server address, the linked modpack and so on)
/// @param api The same API used for the search
- (void)getServerDetailsWithAPI:(ServerDownloadAPI)api
                       serverID:(NSString *)serverID
                      completion:(ServerDetailHandler)completion;

/// Join a server: save the address into the current profile (writing the serverIp field)
/// @param address The server address (IP:port or domain:port)
/// @param profileName The target profile name; nil means the current profile
- (BOOL)joinServer:(NSString *)address
        forProfile:(nullable NSString *)profileName
             error:(NSError **)error;

/// Download the server modpack into the given profile folder
/// @param serverItem A server project with serverPackDownloadURL/serverPackFileName filled in
/// @param profileName The target profile name
/// @param progress The download progress callback (main thread)
/// @param completion The download completion callback (main thread)
- (void)downloadServerPack:(ServerItem *)serverItem
                 toProfile:(NSString *)profileName
                  progress:(nullable ServerProgressHandler)progress
                completion:(ServerDownloadHandler)completion;

/// The icon cache path (the same strategy as ModService)
- (NSString *)iconCachePathForURL:(NSString *)urlString;

@end

NS_ASSUME_NONNULL_END
