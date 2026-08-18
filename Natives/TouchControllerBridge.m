//
//  TouchControllerBridge.m
//  Angel Aura Amethyst
//
//  TouchController JNI bridge implementation
//  Implements the communication between the Minecraft TouchController mod and the iOS launcher
//

#import "TouchControllerBridge.h"
#import <dlfcn.h>
#import <os/log.h>

// C API function pointer type declarations for the TouchController static library
// These types match the touchcontroller_ios_* family of function signatures (with no JNIEnv*/jclass parameters),
// and dlsym looks up the C API symbol names (rather than the JNI-mangled ones), avoiding crashes caused by mismatched calling conventions
typedef void (*JNI_Init_Func)(void);              // touchcontroller_ios_init
typedef long long (*JNI_New_Func)(const char *name);  // touchcontroller_ios_new
typedef int (*JNI_Receive_Func)(long long handle, void *buffer, int length);  // touchcontroller_ios_receive
typedef void (*JNI_Send_Func)(long long handle, const void *buffer, int offset, int length);  // touchcontroller_ios_send
typedef void (*JNI_Destroy_Func)(long long handle);  // touchcontroller_ios_destroy

// Function pointers
static JNI_Init_Func g_TouchController_Init = NULL;
static JNI_New_Func g_TouchController_New = NULL;
static JNI_Receive_Func g_TouchController_Receive = NULL;
static JNI_Send_Func g_TouchController_Send = NULL;
static JNI_Destroy_Func g_TouchController_Destroy = NULL;

// Whether it has been initialized
static BOOL g_Initialized = NO;
static void *g_LibraryHandle = NULL;

// Logging
static os_log_t touchControllerLog = NULL;

@implementation TouchControllerBridge

+ (void)load {
    touchControllerLog = os_log_create("com.air-devs.air", "TouchController");
    [self initializeTouchController];
}

+ (BOOL)initializeTouchController {
    if (g_Initialized) {
        return YES;
    }

    os_log_info(touchControllerLog, "Initializing TouchController bridge...");

    // Try to load the TouchController static library
    // Since it is statically linked, we simply check whether the symbols exist
    // If the static library has been linked into the executable, dlsym(RTLD_DEFAULT) should find the symbols
    
    g_TouchController_Init = (JNI_Init_Func)dlsym(RTLD_DEFAULT, "touchcontroller_ios_init");
    g_TouchController_New = (JNI_New_Func)dlsym(RTLD_DEFAULT, "touchcontroller_ios_new");
    g_TouchController_Receive = (JNI_Receive_Func)dlsym(RTLD_DEFAULT, "touchcontroller_ios_receive");
    g_TouchController_Send = (JNI_Send_Func)dlsym(RTLD_DEFAULT, "touchcontroller_ios_send");
    g_TouchController_Destroy = (JNI_Destroy_Func)dlsym(RTLD_DEFAULT, "touchcontroller_ios_destroy");

    // Check whether every function was found
    if (!g_TouchController_Init || !g_TouchController_New || !g_TouchController_Receive || 
        !g_TouchController_Send || !g_TouchController_Destroy) {
        const char *error = dlerror();
        os_log_error(touchControllerLog, "Failed to load TouchController symbols: %s", error ? error : "unknown error");
        g_Initialized = NO;
        return NO;
    }

    // Call the initialization function
    if (g_TouchController_Init) {
        g_TouchController_Init();
    }

    g_Initialized = YES;
    os_log_info(touchControllerLog, "TouchController bridge initialized successfully");
    return YES;
}

+ (BOOL)isTouchControllerAvailable {
    return g_Initialized;
}

+ (long long)createTransportWithName:(NSString *)name {
    if (!g_Initialized || !g_TouchController_New) {
        os_log_error(touchControllerLog, "TouchController not initialized");
        return -1;
    }

    const char *cName = [name UTF8String];
    long long handle = g_TouchController_New(cName);

    if (handle < 0) {
        os_log_error(touchControllerLog, "Failed to create transport with name: %s", cName);
    } else {
        os_log_debug(touchControllerLog, "Created transport with handle: %lld", handle);
    }

    return handle;
}

+ (int)receiveFromTransport:(long long)handle buffer:(NSMutableData *)buffer {
    if (!g_Initialized || !g_TouchController_Receive) {
        os_log_error(touchControllerLog, "TouchController not initialized");
        return -1;
    }

    if (handle < 0) {
        os_log_error(touchControllerLog, "Invalid transport handle: %lld", handle);
        return -1;
    }

    // Allocate the buffer
    static const int BUFFER_SIZE = 4096;
    uint8_t tempBuffer[BUFFER_SIZE];

    // Call the JNI receive function
    int result = g_TouchController_Receive(handle, tempBuffer, BUFFER_SIZE);

    if (result > 0) {
        // Data received successfully
        [buffer appendBytes:tempBuffer length:result];
        os_log_debug(touchControllerLog, "Received %d bytes from transport %lld", result, handle);
    } else if (result == 0) {
        // No data available
        os_log_debug(touchControllerLog, "No data available from transport %lld", handle);
    } else {
        // Receive failed
        os_log_error(touchControllerLog, "Failed to receive from transport %lld", handle);
    }

    return result;
}

+ (BOOL)sendToTransport:(long long)handle data:(NSData *)data {
    if (!g_Initialized || !g_TouchController_Send) {
        os_log_error(touchControllerLog, "TouchController not initialized");
        return NO;
    }

    if (handle < 0) {
        os_log_error(touchControllerLog, "Invalid transport handle: %lld", handle);
        return NO;
    }

    if (!data || data.length == 0) {
        os_log_error(touchControllerLog, "No data to send");
        return NO;
    }

    // Call the JNI send function
    g_TouchController_Send(handle, [data bytes], 0, (int)[data length]);

    os_log_debug(touchControllerLog, "Sent %lu bytes to transport %lld", (unsigned long)[data length], handle);
    return YES;
}

+ (void)destroyTransport:(long long)handle {
    if (!g_Initialized || !g_TouchController_Destroy) {
        os_log_error(touchControllerLog, "TouchController not initialized");
        return;
    }

    if (handle < 0) {
        os_log_error(touchControllerLog, "Invalid transport handle: %lld", handle);
        return;
    }

    g_TouchController_Destroy(handle);
    os_log_debug(touchControllerLog, "Destroyed transport %lld", handle);
}

@end