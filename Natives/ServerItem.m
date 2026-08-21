//
//  ServerItem.m
//  Flux
//

#import "ServerItem.h"

@implementation ServerItem

- (instancetype)initWithSearchData:(NSDictionary *)data {
    if (self = [super init]) {
        if (![data isKindOfClass:[NSDictionary class]]) {
            return self;
        }

        // The source API: 1=Modrinth, 2=CurseForge (the default is inferred from the field naming style)
        id apiSrc = data[@"apiSource"];
        if ([apiSrc respondsToSelector:@selector(integerValue)]) {
            _apiSource = [apiSrc integerValue];
        } else if (data[@"project_id"] || data[@"slug"]) {
            _apiSource = ServerAPISourceModrinth;
        } else if (data[@"id"] && data[@"logo"]) {
            _apiSource = ServerAPISourceCurseForge;
        }

        // The server project ID
        id sid = data[@"serverID"] ?: data[@"project_id"] ?: data[@"id"] ?: data[@"slug"];
        _serverID = [sid isKindOfClass:[NSString class]] ? sid : [sid description];

        // The title: Modrinth uses title and CurseForge uses name
        id title = data[@"title"] ?: data[@"name"];
        _title = [title isKindOfClass:[NSString class]] ? title : [title description];

        // The description: Modrinth uses description and CurseForge uses summary
        id desc = data[@"description"] ?: data[@"summary"];
        _serverDescription = [desc isKindOfClass:[NSString class]] ? desc : @"";

        // The icon URL: Modrinth uses icon_url / imageUrl and CurseForge uses logo.thumbnailUrl / logo.url
        NSString *icon = data[@"iconURL"] ?: data[@"icon_url"] ?: data[@"imageUrl"];
        if (![icon isKindOfClass:[NSString class]] || icon.length == 0) {
            NSDictionary *logo = [data[@"logo"] isKindOfClass:[NSDictionary class]] ? data[@"logo"] : nil;
            icon = logo[@"thumbnailUrl"] ?: logo[@"url"];
        }
        _iconURL = [icon isKindOfClass:[NSString class]] ? icon : @"";

        // The author
        id author = data[@"author"];
        _author = [author isKindOfClass:[NSString class]] ? author : @"";

        // The download count
        id dl = data[@"downloads"];
        if ([dl isKindOfClass:[NSNumber class]]) {
            _downloads = dl;
        } else if ([dl respondsToSelector:@selector(longLongValue)]) {
            _downloads = @([dl longLongValue]);
        }

        // The like count: Modrinth uses follows and CurseForge uses thumbsUpCount
        id likes = data[@"likes"] ?: data[@"follows"] ?: data[@"thumbsUpCount"];
        if ([likes isKindOfClass:[NSNumber class]]) {
            _likes = likes;
        } else if ([likes respondsToSelector:@selector(longLongValue)]) {
            _likes = @([likes longLongValue]);
        }

        // The last updated time
        id updated = data[@"lastUpdated"] ?: data[@"date_modified"] ?: data[@"dateReleased"];
        _lastUpdated = [updated isKindOfClass:[NSString class]] ? updated : @"";

        // The project type: Modrinth returns project_type and CurseForge is inferred from classId
        NSString *ptype = data[@"projectType"] ?: data[@"project_type"];
        if ([ptype isKindOfClass:[NSString class]] && ptype.length > 0) {
            _projectType = ptype;
        } else {
            // Default: server/modpack for Modrinth and modpack for CurseForge
            _projectType = (_apiSource == ServerAPISourceCurseForge) ? @"modpack" : @"server";
        }

        // Categories
        id cats = data[@"categories"];
        _categories = [cats isKindOfClass:[NSArray class]] ? cats : @[];

        // The home page: Modrinth uses page_url and CurseForge uses websiteUrl
        NSString *home = data[@"homepage"] ?: data[@"page_url"];
        if (![home isKindOfClass:[NSString class]] || home.length == 0) {
            NSDictionary *links = [data[@"links"] isKindOfClass:[NSDictionary class]] ? data[@"links"] : nil;
            home = links[@"websiteUrl"];
        }
        _homepage = [home isKindOfClass:[NSString class]] ? home : @"";
    }
    return self;
}

- (void)applyDetailData:(NSDictionary *)data {
    if (![data isKindOfClass:[NSDictionary class]]) return;

    // The server address: prefer the server_address / serverAddress / ip / address fields
    NSString *addr = data[@"server_address"] ?: data[@"serverAddress"] ?: data[@"ip"] ?: data[@"address"];
    if ([addr isKindOfClass:[NSString class]] && addr.length > 0) {
        self.serverAddress = addr;
    } else if (self.serverDescription.length > 0) {
        // Fallback: parse a possible address out of the description (IP:port or domain:port)
        NSString *parsed = [self extractAddressFromText:self.serverDescription];
        if (parsed) self.serverAddress = parsed;
    }

    // The linked modpack ID: Modrinth uses modpack_project_id and CurseForge uses modpackId
    NSString *mpID = data[@"modpack_project_id"] ?: data[@"modpackId"] ?: data[@"associatedModpackId"];
    if ([mpID isKindOfClass:[NSString class]] && mpID.length > 0) {
        self.associatedModpackID = mpID;
    } else if ([mpID respondsToSelector:@selector(integerValue)]) {
        self.associatedModpackID = [mpID description];
    }

    // The server modpack file information (when there is any)
    NSString *spURL = data[@"serverPackDownloadURL"] ?: data[@"downloadUrl"];
    if ([spURL isKindOfClass:[NSString class]] && spURL.length > 0) {
        self.serverPackDownloadURL = spURL;
    }
    NSString *spName = data[@"serverPackFileName"] ?: data[@"fileName"];
    if ([spName isKindOfClass:[NSString class]] && spName.length > 0) {
        self.serverPackFileName = spName;
    }
    id spSize = data[@"serverPackFileSize"] ?: data[@"fileLength"];
    if ([spSize isKindOfClass:[NSNumber class]]) {
        self.serverPackFileSize = spSize;
    } else if ([spSize respondsToSelector:@selector(unsignedLongLongValue)]) {
        self.serverPackFileSize = @([spSize unsignedLongLongValue]);
    }
}

/// Extract a possible server address from text (in the IP:port or domain:port form)
- (nullable NSString *)extractAddressFromText:(NSString *)text {
    if (!text.length) return nil;
    NSError *error = nil;
    // Matches xxx.xxx.xxx.xxx:port or domain.example.com:port
    NSRegularExpression *regex = [NSRegularExpression
        regularExpressionWithPattern:@"\\b((?:[a-zA-Z0-9-]+\\.)+[a-zA-Z]{2,}|(?:\\d{1,3}\\.){3}\\d{1,3}):\\d{1,5}\\b"
                             options:0
                               error:&error];
    if (error || !regex) return nil;
    NSTextCheckingResult *match = [regex firstMatchInString:text options:0 range:NSMakeRange(0, text.length)];
    if (match) {
        return [text substringWithRange:match.range];
    }
    return nil;
}

- (NSString *)formattedDownloads {
    return [self formatCount:self.downloads];
}

- (NSString *)formattedLikes {
    return [self formatCount:self.likes];
}

- (NSString *)formatCount:(NSNumber *)count {
    if (!count) return @"0";
    long long value = [count longLongValue];
    if (value < 1000) return [NSString stringWithFormat:@"%lld", value];
    if (value < 1000000) return [NSString stringWithFormat:@"%.1fk", value / 1000.0];
    return [NSString stringWithFormat:@"%.1fM", value / 1000000.0];
}

@end
