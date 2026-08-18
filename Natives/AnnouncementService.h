//
//  AnnouncementService.h
//  Amethyst
//
//  Announcement fetch service
//  Fetches the announcement list from the JSON API pointed at by general.news_url, with a 30-minute local cache.
//  Caches the raw NSData in NSUserDefaults and falls back to it when the network fails.
//

#import <Foundation/Foundation.h>

@class AnnouncementItem;

NS_ASSUME_NONNULL_BEGIN

/// Announcement fetch completion callback
typedef void(^AnnouncementFetchHandler)(NSArray<AnnouncementItem *> * _Nullable items,
                                        NSError * _Nullable error);

@interface AnnouncementService : NSObject

+ (instancetype)sharedService;

/// Fetch the announcement list from the server (with a 30-minute local cache)
/// @param completion Called on the main thread
- (void)fetchAnnouncementsWithCompletion:(AnnouncementFetchHandler)completion;

/// Force a refresh (ignoring the cache)
- (void)forceRefreshWithCompletion:(AnnouncementFetchHandler)completion;

/// Read the cached announcements (no network request)
- (NSArray<AnnouncementItem *> *)cachedAnnouncements;

@end

NS_ASSUME_NONNULL_END
