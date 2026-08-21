//
//  LanPortDetector.h
//  Flux
//
//  Minecraft "Open to LAN" port detector (manual entry version)
//
//  Note: automatic detection (parsing latestlog.txt) has been removed, because the log format varies
//  widely between MC versions and an old log could cause a false detection. Only the manual port entry API remains.
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Notification name: posted when the port is set manually
/// userInfo: @{ @"port": @(port number) }
extern NSString *const LanPortDetectorDidDetectPortNotification;

/// Minecraft "Open to LAN" port detector (manual entry version)
@interface LanPortDetector : NSObject

/// Singleton accessor
+ (instancetype)sharedInstance;

/// Set the Minecraft LAN port manually
/// @param port The port number Minecraft shows in the chat box after "Open to LAN"
- (void)setManualPort:(uint16_t)port;

@end

NS_ASSUME_NONNULL_END
