//
//  ServerItem.h
//  Amethyst
//
//  The server project model, following the design of ModItem:
//  it can carry either Modrinth server projects (project_type=server)
//  or the server pack information of a CurseForge modpack.
//  When the Modrinth server projects API is unavailable, it falls back to modpack search results.
//

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

/// The source API of a server project
typedef NS_ENUM(NSInteger, ServerAPISource) {
    ServerAPISourceModrinth = 1, // Modrinth (project_type=server or modpack)
    ServerAPISourceCurseForge = 2, // CurseForge (the server pack of a modpack)
};

@interface ServerItem : NSObject

/// The server project ID (a Modrinth project_id or a CurseForge project id as a string)
@property (nonatomic, copy, nullable) NSString *serverID;
/// The display name
@property (nonatomic, copy, nullable) NSString *title;
/// The summary/description
@property (nonatomic, copy, nullable) NSString *serverDescription;
/// The icon URL
@property (nonatomic, copy, nullable) NSString *iconURL;
/// The icon (the cached UIImage)
@property (nonatomic, strong, nullable) UIImage *icon;
/// The download count
@property (nonatomic, strong, nullable) NSNumber *downloads;
/// The follow/like count
@property (nonatomic, strong, nullable) NSNumber *likes;
/// The last updated time
@property (nonatomic, copy, nullable) NSString *lastUpdated;
/// The project type ("server" or "modpack")
@property (nonatomic, copy, nullable) NSString *projectType;
/// The source API
@property (nonatomic, assign) ServerAPISource apiSource;
/// Author
@property (nonatomic, copy, nullable) NSString *author;
/// The category tags
@property (nonatomic, strong, nullable) NSArray<NSString *> *categories;

/// The server address (IP/domain:port), parsed from the project details or description; it may be empty
@property (nonatomic, copy, nullable) NSString *serverAddress;
/// The linked modpack ID (the project ID, when the server is linked to a modpack)
@property (nonatomic, copy, nullable) NSString *associatedModpackID;
/// The source API of the linked modpack (paired with associatedModpackID; 1=Modrinth, 2=CurseForge)
@property (nonatomic, assign) ServerAPISource associatedModpackSource;

/// For the detail page: the download URL of the server's linked modpack (when a server modpack file can be downloaded directly)
@property (nonatomic, copy, nullable) NSString *serverPackDownloadURL;
/// For the detail page: the server modpack file name
@property (nonatomic, copy, nullable) NSString *serverPackFileName;
/// For the detail page: the server modpack file size (bytes)
@property (nonatomic, strong, nullable) NSNumber *serverPackFileSize;

/// The project home page URL
@property (nonatomic, copy, nullable) NSString *homepage;

/// Build from the dictionary the API returns (handling both the Modrinth and CurseForge fields)
- (instancetype)initWithSearchData:(NSDictionary *)data;

/// Fill in the extra fields from the detail API response (the address, the linked modpack and so on)
- (void)applyDetailData:(NSDictionary *)data;

/// The formatted download count (such as 1.2k)
- (NSString *)formattedDownloads;

/// The formatted like count
- (NSString *)formattedLikes;

@end

NS_ASSUME_NONNULL_END
