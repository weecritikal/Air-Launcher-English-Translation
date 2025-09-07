//
//  ModItem.h
//  AmethystMods
//
//  Created by Copilot on 2025-08-22.
//

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

@interface ModItem : NSObject

@property (nonatomic, copy) NSString *fileName;
@property (nonatomic, copy) NSString *filePath;
@property (nonatomic, assign) BOOL disabled;
@property (nonatomic, copy, nullable) NSString *displayName;
@property (nonatomic, copy, nullable) NSString *modDescription;
@property (nonatomic, copy, nullable) NSString *iconURL;
@property (nonatomic, copy, nullable) NSString *fileSHA1;

// Additional metadata fields used by ModService
@property (nonatomic, copy, nullable) NSString *version;
@property (nonatomic, copy, nullable) NSString *homepage;
@property (nonatomic, copy, nullable) NSString *sources;
@property (nonatomic, assign) BOOL isFabric;
@property (nonatomic, assign) BOOL isForge;
@property (nonatomic, assign) BOOL isNeoForge;

- (instancetype)initWithFilePath:(NSString *)path;
- (NSString *)basename;
- (void)refreshDisabledFlag;

@end

NS_ASSUME_NONNULL_END