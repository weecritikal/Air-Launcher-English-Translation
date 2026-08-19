//
//  AnnouncementItem.m
//  Amethyst
//

#import "AnnouncementItem.h"

@implementation AnnouncementItem

+ (instancetype)itemFromDictionary:(NSDictionary *)dict {
    if (![dict isKindOfClass:[NSDictionary class]]) return nil;
    AnnouncementItem *item = [[AnnouncementItem alloc] init];
    item.announcementId = dict[@"id"] ?: @"";
    item.title = dict[@"title"] ?: @"";
    item.date = dict[@"date"] ?: @"";
    item.summary = dict[@"summary"] ?: @"";
    item.content = dict[@"content"] ?: @"";
    item.priority = dict[@"priority"] ?: @"normal";
    item.actionURL = dict[@"action_url"] ?: @"";
    item.actionTitle = dict[@"action_title"] ?: @"";
    item.imageURL = dict[@"image_url"] ?: @"";
    return item;
}

- (NSString *)formattedDateString {
    if (self.date.length == 0) return @"";
    // Parse the ISO date "2026-07-23"
    NSDateFormatter *fmt = [[NSDateFormatter alloc] init];
    // A fixed input format has to be parsed against en_US_POSIX; a real locale can apply
    // its own calendar or numerals and fail to read an ISO date.
    fmt.locale = [NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"];
    fmt.dateFormat = @"yyyy-MM-dd";
    NSDate *date = [fmt dateFromString:self.date];
    if (!date) return self.date;

    NSDateFormatter *displayFmt = [[NSDateFormatter alloc] init];
    displayFmt.locale = NSLocale.autoupdatingCurrentLocale;
    displayFmt.dateStyle = NSDateFormatterLongStyle;
    displayFmt.timeStyle = NSDateFormatterNoStyle;
    return [displayFmt stringFromDate:date];
}

@end
