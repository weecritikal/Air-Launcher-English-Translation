//
//  ModItem.m
//  AmethystMods
//
//  Created by Copilot on 2025-08-22.
//

#import "ModItem.h"

@implementation ModItem

- (instancetype)initWithFilePath:(NSString *)path {
    if (self = [super init]) {
        _filePath = [path copy];
        _fileName = [[path lastPathComponent] copy];
        [self refreshDisabledFlag];
        NSString *name = [_fileName copy];

        // handle ".disabled" suffix (may be ".jar.disabled" or ".disabled")
        if ([name hasSuffix:@".disabled"]) {
            name = [name substringToIndex:name.length - [@".disabled" length]];
        }
        // remove .jar extension if present
        if ([name hasSuffix:@".jar"]) {
            name = [name stringByDeletingPathExtension];
        }
        // fallback displayName
        _displayName = name.length ? name : _fileName;
        // ensure defaults for metadata
        _modDescription = _modDescription ?: @"";
        _iconURL = _iconURL ?: @"";
        _fileSHA1 = _fileSHA1 ?: nil;
        _version = _version ?: nil;
        _homepage = _homepage ?: nil;
        _sources = _sources ?: nil;
        _isFabric = NO;
        _isForge = NO;
        _isNeoForge = NO;
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
    // strip .jar if still present
    if ([name hasSuffix:@".jar"]) name = [name stringByDeletingPathExtension];
    return name;
}

@end