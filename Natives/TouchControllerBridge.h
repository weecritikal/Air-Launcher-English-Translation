//
//  TouchControllerBridge.h
//  Angel Aura Amethyst
//
//  TouchController JNI bridge header
//  Provides the communication interface between the Minecraft TouchController mod and the iOS launcher
//

#ifndef TouchControllerBridge_h
#define TouchControllerBridge_h

#import <Foundation/Foundation.h>

#ifdef __cplusplus
extern "C" {
#endif

/**
 * TouchController bridge class
 * Responsible for managing initialization of and communication with the TouchController static library
 */
@interface TouchControllerBridge : NSObject

/**
 * Initialize the TouchController bridge
 * @return whether initialization succeeded
 */
+ (BOOL)initializeTouchController;

/**
 * Create a new TouchController transport object
 * @param name the transport object name (Unix domain socket path)
 * @return the transport object handle (-1 on failure)
 */
+ (long long)createTransportWithName:(NSString *)name;

/**
 * Receive data from TouchController
 * @param handle the transport object handle
 * @param buffer the receive buffer
 * @return the number of bytes received (0 if there is no data, -1 on failure)
 */
+ (int)receiveFromTransport:(long long)handle buffer:(NSMutableData *)buffer;

/**
 * Send data to TouchController
 * @param handle the transport object handle
 * @param data the data to send
 * @return whether sending succeeded
 */
+ (BOOL)sendToTransport:(long long)handle data:(NSData *)data;

/**
 * Destroy the TouchController transport object
 * @param handle the transport object handle
 */
+ (void)destroyTransport:(long long)handle;

/**
 * Check whether TouchController is available
 * @return whether TouchController has been initialized correctly
 */
+ (BOOL)isTouchControllerAvailable;

@end

#ifdef __cplusplus
}
#endif

#endif /* TouchControllerBridge_h */