//
//  WorldItem.m
//  Amethyst
//
//  World save data model implementation
//

#import "WorldItem.h"

@implementation WorldItem

- (instancetype)initWithFilePath:(NSString *)path {
    if (self = [super init]) {
        _filePath = [path copy];
        _worldName = [[path lastPathComponent] copy];
        _displayName = [_worldName copy];

        // Check whether level.dat exists
        NSString *levelDat = [path stringByAppendingPathComponent:@"level.dat"];
        NSFileManager *fm = [NSFileManager defaultManager];
        if ([fm fileExistsAtPath:levelDat]) {
            _levelDatPath = [levelDat copy];
            // Read the level.dat modification time as lastPlayed
            NSError *err = nil;
            NSDictionary *attrs = [fm attributesOfItemAtPath:levelDat error:&err];
            if (!err && attrs[NSFileModificationDate]) {
                NSDate *modDate = attrs[NSFileModificationDate];
                NSDateFormatter *fmt = [[NSDateFormatter alloc] init];
                fmt.dateStyle = NSDateFormatterShortStyle;
                fmt.timeStyle = NSDateFormatterShortStyle;
                _lastPlayed = [fmt stringFromDate:modDate];
            }
        }

        // Compute the world directory size
        _worldSize = [self directorySizeAtPath:path];
    }
    return self;
}

- (instancetype)initWithOnlineData:(NSDictionary *)data {
    if (self = [super init]) {
        // From Modrinth/CurseForge search results
        _onlineID = data[@"id"] ? [data[@"id"] description] : nil;
        _displayName = data[@"title"] ?: @"";
        _worldDescription = data[@"description"] ?: @"";
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
        _worldName = nil;
        _levelDatPath = nil;
    }
    return self;
}

- (NSString *)basename {
    return _worldName ?: _displayName ?: @"";
}

// Compute the directory size recursively
- (NSNumber *)directorySizeAtPath:(NSString *)path {
    if (!path) return @0;
    NSFileManager *fm = [NSFileManager defaultManager];
    BOOL isDir = NO;
    if (![fm fileExistsAtPath:path isDirectory:&isDir] || !isDir) return @0;

    unsigned long long size = 0;
    NSDirectoryEnumerator *enumerator = [fm enumeratorAtPath:path];
    NSString *fileName;
    while ((fileName = [enumerator nextObject])) {
        NSDictionary *attrs = [enumerator fileAttributes];
        if (attrs[NSFileSize]) {
            size += [attrs[NSFileSize] unsignedLongLongValue];
        }
    }
    return @(size);
}

@end
