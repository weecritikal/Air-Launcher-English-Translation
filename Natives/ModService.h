//
//  ModService.h
//  AmethystMods
//
//  Created by Copilot on 2025-08-22.
//

#import <Foundation/Foundation.h>
#import "ModItem.h"

NS_ASSUME_NONNULL_BEGIN

typedef void(^ModListHandler)(NSArray<ModItem *> *mods);
typedef void(^ModMetadataHandler)(ModItem *item, NSError * _Nullable error);

@interface ModService : NSObject

+ (instancetype)sharedService;

- (void)scanModsForProfile:(NSString *)profileName completion:(ModListHandler)completion;
- (void)fetchMetadataForMod:(ModItem *)mod completion:(ModMetadataHandler)completion;
- (NSString *)iconCachePathForURL:(NSString *)urlString;
- (BOOL)toggleEnableForMod:(ModItem *)mod error:(NSError **)error;
- (BOOL)deleteMod:(ModItem *)mod error:(NSError **)error;

@end

NS_ASSUME_NONNULL_END