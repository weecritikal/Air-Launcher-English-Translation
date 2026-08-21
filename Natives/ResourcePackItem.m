//
//  ResourcePackItem.m
//  Flux
//
//  Resource pack model implementation
//

#import "ResourcePackItem.h"

@implementation ResourcePackItem

- (instancetype)initWithFilePath:(NSString *)path {
    if (self = [super init]) {
        _filePath = [path copy];
        _fileName = [[path lastPathComponent] copy];
        [self refreshDisabledFlag];
        NSString *name = [_fileName copy];

        if ([name hasSuffix:@".disabled"]) {
            name = [name substringToIndex:name.length - [@".disabled" length]];
        }
        if ([name hasSuffix:@".zip"]) {
            name = [name stringByDeletingPathExtension];
        }
        _displayName = name.length ? name : _fileName;
    }
    return self;
}

- (instancetype)initWithOnlineData:(NSDictionary *)data {
    if (self = [super init]) {
        // From the Modrinth search results
        _onlineID = data[@"id"] ? [data[@"id"] description] : nil;
        _displayName = data[@"title"] ?: @"";
        _resourcePackDescription = data[@"description"] ?: @"";
        _iconURL = data[@"imageUrl"] ?: @"";
        _author = data[@"author"] ?: @"";

        // Handle numeric types
        id downloadsValue = data[@"downloads"];
        if ([downloadsValue isKindOfClass:[NSNumber class]]) {
            _downloads = downloadsValue;
        } else if ([downloadsValue respondsToSelector:@selector(longLongValue)]) {
            _downloads = @([downloadsValue longLongValue]);
        }

        id likesValue = data[@"likes"];
        if ([likesValue isKindOfClass:[NSNumber class]]) {
            _likes = likesValue;
        } else if ([likesValue respondsToSelector:@selector(longLongValue)]) {
            _likes = @([likesValue longLongValue]);
        }

        // Date and categories
        _lastUpdated = data[@"lastUpdated"] ?: @"";
        _categories = data[@"categories"] ?: @[];

        // These properties are nil until a download version is chosen
        _filePath = nil;
        _fileName = nil;
    }
    return self;
}

- (void)refreshDisabledFlag {
    _disabled = [_fileName.lowercaseString hasSuffix:@".disabled"];
}

- (NSString *)basename {
    NSString *name = _fileName ?: @"";
    if ([name hasSuffix:@".disabled"]) {
        name = [name substringToIndex:name.length - [@".disabled" length]];
    }
    if ([name hasSuffix:@".zip"]) name = [name stringByDeletingPathExtension];
    return name;
}

@end
