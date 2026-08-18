#import <UIKit/UIKit.h>

#define TYPE_INSTALLED 0
#define TYPE_RELEASE 1
#define TYPE_SNAPSHOT 2
#define TYPE_OLDBETA 3
#define TYPE_OLDALPHA 4

@interface MinecraftResourceUtils : NSObject

+ (void)processVersion:(NSMutableDictionary *)json inheritsFrom:(NSMutableDictionary *)inheritsFrom;
+ (void)tweakVersionJson:(NSMutableDictionary *)json;

+ (NSObject *)findVersion:(NSString *)version inList:(NSArray *)list;
+ (NSObject *)findNearestVersion:(NSObject *)version expectedType:(int)type;

// Evaluate the OS rules in the Mojang version JSON (iOS is treated as osx)
+ (BOOL)evaluateRules:(NSArray *)rules;
// Expand the rule-based JVM argument entries into an array of strings
+ (NSArray<NSString *> *)flattenJvmArg:(id)arg;

@end
