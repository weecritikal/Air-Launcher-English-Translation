//
//  LanPortDetector.m
//  Amethyst
//
//  Implementation of the Minecraft "Open to LAN" port detector (manual entry version)
//

#import "LanPortDetector.h"
#import "utils.h"

/// Notification name: posted when the port is set manually
NSString *const LanPortDetectorDidDetectPortNotification = @"LanPortDetectorDidDetectPort";

@interface LanPortDetector ()
/// The port currently set (0 means unset)
@property (nonatomic, assign, readwrite) uint16_t detectedPort;
@end

@implementation LanPortDetector

#pragma mark - Singleton

+ (instancetype)sharedInstance {
    static LanPortDetector *shared = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        shared = [[self alloc] init];
    });
    return shared;
}

#pragma mark - Setting the port manually

/// Set the Minecraft LAN port manually
- (void)setManualPort:(uint16_t)port {
    self.detectedPort = port;

    NSLog(@"[LanPortDetector] Manually set LAN port: %u", port);

    // Post the notification, with the port number in userInfo
    dispatch_async(dispatch_get_main_queue(), ^{
        [[NSNotificationCenter defaultCenter] postNotificationName:LanPortDetectorDidDetectPortNotification
                                                            object:self
                                                          userInfo:@{ @"port": @(port) }];
    });
}

@end
