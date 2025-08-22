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
        if ([name hasSuffix:@".disabled"]) {
            // remove the ".disabled" suffix (stringByDeletingPathExtension removes only last extension)
            name = [name substringToIndex:name.length - [@".disabled" length]];
        }
        if ([name hasSuffix:@".jar"]) {
            name = [name stringByDeletingPathExtension];
        }
        _displayName = name;
    }
    return self;
}

- (void)refreshDisabledFlag {
    _disabled = [_fileName hasSuffix:@".disabled"];
}

- (NSString *)basename {
    NSString *name = _fileName;
    if ([name hasSuffix:@".disabled"]) {
        name = [name substringToIndex:name.length - [@".disabled" length]];
    }
    return name;
}

@end