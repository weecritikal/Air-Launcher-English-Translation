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

// 评估 Mojang 版本 JSON 中的 OS 规则（iOS 视作 osx）
+ (BOOL)evaluateRules:(NSArray *)rules;
// 将规则化的 JVM 参数项展开为字符串数组
+ (NSArray<NSString *> *)flattenJvmArg:(id)arg;

@end
