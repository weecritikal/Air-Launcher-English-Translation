//
//  MinecraftNewsService.h
//  Flux
//
//  Official Minecraft news fetch service
//  Modelled on PCL-CE (PCL.Core/ViewModel/Homepage/NewsViewModel.cs):
//    - data source: https://net-secondary.web.minecraft-services.net/api/v1.0/{locale}/search
//    - parameters: pageSize=24&sortType=Recent&category=News&newsOnly=true&page=N
//    - no authentication needed, only a User-Agent header
//    - image and link URLs are absolute, so no prefix has to be joined on
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@class MinecraftNewsItem;

/// Error domain
extern NSString * const MCNewsErrorDomain;

typedef NS_ENUM(NSInteger, MCNewsErrorCode) {
    MCNewsErrorCodeNetwork = 1,
    MCNewsErrorCodeParsing,
    MCNewsErrorCodeEmpty,
};

/// Completion callback for fetching one news item
typedef void(^MCNewsFetchHandler)(NSArray<MinecraftNewsItem *> *items,
                                  NSInteger totalCount,
                                  NSError * _Nullable error);

@interface MinecraftNewsService : NSObject

+ (instancetype)sharedService;

/// The locale used for requests (zh-cn by default, following the system language and changeable in settings)
@property (nonatomic, copy) NSString *locale;

/// Fetch the news list
/// @param page Page number (starting at 1)
/// @param pageSize Items per page (PCL-CE uses 24)
/// @param completion Main-thread callback; items is this page of news and totalCount the total number
- (void)fetchNewsWithPage:(NSInteger)page
                 pageSize:(NSInteger)pageSize
               completion:(MCNewsFetchHandler)completion;

/// Convenience method for fetching the first page (page=1, pageSize=24)
- (void)fetchLatestNewsWithCompletion:(MCNewsFetchHandler)completion;

/// Link safety check (see IsSafeNewsLink in PCL-CE)
/// Only minecraft.net / minecraft-services.net / microsoft.com and their subdomains are allowed
+ (BOOL)isSafeNewsLink:(NSString *)urlString;

@end

NS_ASSUME_NONNULL_END
