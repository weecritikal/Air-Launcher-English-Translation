//
//  MinecraftNewsItem.h
//  Amethyst
//
//  Official Minecraft news data model
//  Field definitions taken from PCL-CE (PCL.Core/Model/Homepage/News/NewsItem.cs)
//
//  Data source: net-secondary.web.minecraft-services.net/api/v1.0/{locale}/search
//  Field mapping:
//    title          -> title
//    url            -> articleURL (an absolute address, no joining needed)
//    description    -> summary (HTML entities need unescaping)
//    author         -> author
//    image          -> imageURL (an absolute address)
//    imageAltText   -> imageAltText
//    time           -> publishDate (a Unix timestamp in seconds)
//    type           -> newsType
//    locale         -> locale
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface MinecraftNewsItem : NSObject

/// Article title
@property (nonatomic, copy) NSString *title;
/// URL of the article detail page (an absolute address)
@property (nonatomic, copy) NSString *articleURL;
/// Summary (the API returns HTML-entity-encoded text, which is unescaped here)
@property (nonatomic, copy) NSString *summary;
/// Author
@property (nonatomic, copy, nullable) NSString *author;
/// Cover image URL (an absolute address)
@property (nonatomic, copy) NSString *imageURL;
/// Alt text of the cover image
@property (nonatomic, copy, nullable) NSString *imageAltText;
/// Publication time (a Unix timestamp in seconds)
@property (nonatomic, assign) NSTimeInterval publishDate;
/// Type (such as "News")
@property (nonatomic, copy, nullable) NSString *newsType;
/// Locale (such as "zh-cn")
@property (nonatomic, copy, nullable) NSString *locale;

/// Build from the dictionary the API returns (missing fields fall back to an empty string)
+ (instancetype)itemFromDictionary:(NSDictionary *)dict;

/// Format as a local date string (such as "2026-07-16")
- (NSString *)formattedDateString;

@end

NS_ASSUME_NONNULL_END
