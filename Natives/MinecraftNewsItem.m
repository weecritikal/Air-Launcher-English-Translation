//
//  MinecraftNewsItem.m
//  Flux
//

#import "MinecraftNewsItem.h"

@implementation MinecraftNewsItem

/// Unescape HTML entities (handling &amp; &lt; &gt; &quot; &#39; &apos; and so on)
/// See WebUtility.HtmlDecode(item.Description) in the PCL-CE NewsViewModel
static NSString *MCNews_HTMLEntityDecode(NSString *input) {
    if (input.length == 0) return @"";
    NSMutableString *result = [input mutableCopy];
    [result replaceOccurrencesOfString:@"&amp;" withString:@"&"
                               options:NSLiteralSearch range:NSMakeRange(0, result.length)];
    [result replaceOccurrencesOfString:@"&lt;" withString:@"<"
                               options:NSLiteralSearch range:NSMakeRange(0, result.length)];
    [result replaceOccurrencesOfString:@"&gt;" withString:@">"
                               options:NSLiteralSearch range:NSMakeRange(0, result.length)];
    [result replaceOccurrencesOfString:@"&quot;" withString:@"\""
                               options:NSLiteralSearch range:NSMakeRange(0, result.length)];
    [result replaceOccurrencesOfString:@"&#39;" withString:@"'"
                               options:NSLiteralSearch range:NSMakeRange(0, result.length)];
    [result replaceOccurrencesOfString:@"&apos;" withString:@"'"
                               options:NSLiteralSearch range:NSMakeRange(0, result.length)];
    return [result copy];
}

+ (instancetype)itemFromDictionary:(NSDictionary *)dict {
    if (![dict isKindOfClass:[NSDictionary class]]) return nil;
    MinecraftNewsItem *item = [[MinecraftNewsItem alloc] init];
    item.title = dict[@"title"] ?: @"";
    item.articleURL = dict[@"url"] ?: @"";
    // Unescape the HTML entities in the description field
    NSString *desc = dict[@"description"] ?: @"";
    item.summary = MCNews_HTMLEntityDecode(desc);
    item.author = dict[@"author"];
    item.imageURL = dict[@"image"] ?: @"";
    item.imageAltText = dict[@"imageAltText"];
    // The time field is a Unix timestamp in seconds (a numeric type)
    id timeValue = dict[@"time"];
    if ([timeValue isKindOfClass:[NSNumber class]]) {
        item.publishDate = [(NSNumber *)timeValue doubleValue];
    } else if ([timeValue isKindOfClass:[NSString class]]) {
        item.publishDate = [(NSString *)timeValue doubleValue];
    }
    item.newsType = dict[@"type"];
    item.locale = dict[@"locale"];
    return item;
}

- (NSString *)formattedDateString {
    if (self.publishDate <= 0) return @"";
    NSDate *date = [NSDate dateWithTimeIntervalSince1970:self.publishDate];
    NSDateFormatter *fmt = [[NSDateFormatter alloc] init];
    fmt.locale = NSLocale.autoupdatingCurrentLocale;
    fmt.dateStyle = NSDateFormatterMediumStyle;
    fmt.timeStyle = NSDateFormatterNoStyle;
    return [fmt stringFromDate:date];
}

@end
