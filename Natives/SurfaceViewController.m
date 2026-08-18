#import <AVFoundation/AVFoundation.h>
#import <GameController/GameController.h>
#import <objc/runtime.h>
#import "authenticator/BaseAuthenticator.h"
#import "customcontrols/ControlButton.h"
#import "customcontrols/ControlDrawer.h"
#import "customcontrols/ControlSubButton.h"
#import "customcontrols/CustomControlsUtils.h"

#import "input/ControllerInput.h"
#import "input/GyroInput.h"
#import "input/KeyboardInput.h"

#import "JavaLauncher.h"
#import "LauncherPreferences.h"
#import "MinecraftResourceUtils.h"
#import "PLProfiles.h"
#import "SurfaceViewController.h"
#import "utils.h"
#import "GameMenuOverlayView.h"
#import "TrackedTextField.h"
#import "TouchControllerBridge.h"
#import "UIKit+hook.h"
#import "ios_uikit_bridge.h"
#import "LanPortDetector.h"
#import "BackgroundManager.h"
// ZeroTier/Terracotta multiplayer temporarily removed (while a startup crash is investigated)
// #import "MultiplayerManager.h"

#include "glfw_keycodes.h"
#include "utils.h"

#include <dlfcn.h>
#include <mach/mach.h>
#include <mach/task_info.h>

// --- [START] TouchController Mod Support ---
#include <arpa/inet.h>
#include <netinet/in.h>
#include <sys/socket.h>
#include <fcntl.h>
#include <errno.h>
#include <string.h>

#define TC_MOD_PORT 12450

@interface TouchSender : NSObject {
    int _sock;
    struct sockaddr_in6 _target;
}
- (void)sendType:(int32_t)type id:(int32_t)fingerId x:(float)x y:(float)y;
@end

@implementation TouchSender

- (instancetype)init {
    self = [super init];
    if (self) {
        _sock = socket(AF_INET6, SOCK_DGRAM, 0);
        if (_sock < 0) {
            NSLog(@"[TouchController] Error: Failed to create socket");
        } else {
            // Increase send buffer size to reduce packet loss
            int sendBufSize = 256 * 1024; // 256KB
            if (setsockopt(_sock, SOL_SOCKET, SO_SNDBUF, &sendBufSize, sizeof(sendBufSize)) < 0) {
                NSLog(@"[TouchController] Warning: Failed to set send buffer size: %s", strerror(errno));
            }

            // Non-blocking mode
            int flags = fcntl(_sock, F_GETFL, 0);
            fcntl(_sock, F_SETFL, flags | O_NONBLOCK);

            memset(&_target, 0, sizeof(_target));
            _target.sin6_family = AF_INET6;
            _target.sin6_port = htons(TC_MOD_PORT);
            // Connect to localhost IPv6 ::1
            if (inet_pton(AF_INET6, "::1", &_target.sin6_addr) <= 0) {
                NSLog(@"[TouchController] Error: Invalid IPv6 address");
            } else {
                NSLog(@"[TouchController] Sender ready on port %d", TC_MOD_PORT);
            }
        }
    }
    return self;
}

- (void)dealloc {
    if (_sock >= 0) close(_sock);
}

- (void)sendType:(int32_t)type id:(int32_t)fingerId x:(float)x y:(float)y {
    if (_sock < 0) return;

    struct {
        int32_t type;
        int32_t id;
        int32_t x;
        int32_t y;
    } packet;

    packet.type = htonl(type);
    packet.id = htonl(fingerId);

    // Float to Int bits (Big Endian)
    union { float f; int32_t i; } ux, uy;
    ux.f = x;
    uy.f = y;
    packet.x = htonl(ux.i);
    packet.y = htonl(uy.i);

    
    size_t length = (type == 2) ? 8 : 16;

    // ä¼åéè¯æºå¶ï¼åå°éè¯æ¬¡æ°ï¼é¿åä¸å¿è¦çå»¶è¿
    int maxRetries = (type == 2) ? 2 : 1;
    int retry;
    ssize_t sent = -1;

    for (retry = 0; retry < maxRetries; retry++) {
        sent = sendto(_sock, &packet, length, 0, (struct sockaddr *)&_target, sizeof(_target));
        if (sent == length) {
            // åéæå
            break;
        } else if (sent < 0) {
            int err = errno;
            if (err == EAGAIN || err == EWOULDBLOCK) {
                // ç¼å²åºæ»¡ï¼ç­æä¼ç åéè¯
                usleep(500); // åå°ä¼ç æ¶é´å°0.5æ¯«ç§
                continue;
            } else {
                // å¶ä»éè¯¯ï¼è®°å½å¹¶éåºéè¯
                NSLog(@"[TouchController] Error: sendto failed: %s (type=%d, id=%d)", strerror(err), type, fingerId);
                break;
            }
        } else {
            // é¨ååéï¼çè®ºä¸ä¸ä¼åçï¼ï¼è®°å½å¹¶éè¯
            NSLog(@"[TouchController] Warning: partial send: %zd of %zu bytes", sent, length);
            usleep(500); // åå°ä¼ç æ¶é´å°0.5æ¯«ç§
        }
    }

    if (sent != length) {
        NSLog(@"[TouchController] Error: failed to send packet after %d retries (type=%d, id=%d)", maxRetries, type, fingerId);
    }
}
@end

#pragma mark - PLDisplayLinkTarget
// CADisplayLink callback target class
//
// Key fix (Vulkan FPS display not working):
// Previously [CADisplayLink displayLinkWithTarget:block selector:@selector(invoke)] was used
// to pass a block, but the block's invoke method signature -(void)invoke does not match the
// -(void)selector:(CADisplayLink*)link signature CADisplayLink expects, so the callback never fired.
// This class provides a displayLinkTick: method with the correct signature, ensuring the CADisplayLink callback fires properly.
@interface PLDisplayLinkTarget : NSObject
@property(nonatomic, assign) BOOL isVulkanMode;  // The configured expected Vulkan path (for diagnostic logs only; the real decision is made at runtime by pojavIsActualVulkanPath())
@property(nonatomic, assign) NSUInteger tickCount;  // Diagnostics: cumulative tick count
@end

@implementation PLDisplayLinkTarget

- (instancetype)initWithVulkanMode:(BOOL)isVulkanMode {
    self = [super init];
    if (self) {
        _isVulkanMode = isVulkanMode;
        _tickCount = 0;
    }
    return self;
}

// CADisplayLink callback method (correct signature: takes a CADisplayLink* parameter)
//
// Key fix (incorrect FPS display for Vulkan/MoltenVK+OpenGL):
// Previously the static string inferred at viewDidLoad time (isVulkanMode) decided whether to increment the FPS counter,
// but graphicsApi=default is decided internally by MC and cannot be predicted; moreover MC's actual choice may differ from the configuration.
// Now pojavIsActualVulkanPath() is queried dynamically every frame (reading clientAPI == GLFW_NO_API),
// which matches MC's real rendering path and avoids:
//   - Double counting: with a Vulkan renderer but MC choosing the GL path, both pojavSwapBuffers and displayLink would count
//   - Missed counting: with graphicsApi=prefer_opengl but MC taking the Vulkan path, the displayLink fallback would not be enabled
- (void)displayLinkTick:(CADisplayLink *)link {
    [GyroInput tick];
    [ControllerInput tick];
    // Dynamic decision: only increment the FPS counter when MC is really taking the Vulkan path
    BOOL actualVulkanPath = pojavIsActualVulkanPath();
    if (actualVulkanPath) {
        pojavIncrementFpsCounter();
    }
    _tickCount++;
    // Diagnostic log: emitted for the first 5 callbacks and on state changes, to make clientAPI changes easy to trace
    static BOOL s_lastActualVulkanPath = NO;
    BOOL stateChanged = (s_lastActualVulkanPath != actualVulkanPath);
    if (_tickCount <= 5 || stateChanged) {
        NSLog(@"[PLDisplayLinkTarget] displayLinkTick #%lu (configuredVulkan=%d, actualVulkanPath=%d, stateChanged=%d)",
              (unsigned long)_tickCount, _isVulkanMode, actualVulkanPath, stateChanged);
        s_lastActualVulkanPath = actualVulkanPath;
    }
}

@end

// --- [START] TouchController Static Library Support ---
// ProxyMessage ç±»åå®ä¹ (åè TouchController-iOSTest)
#define PROXY_MESSAGE_TYPE_ADD_POINTER 1
#define PROXY_MESSAGE_TYPE_REMOVE_POINTER 2
#define PROXY_MESSAGE_TYPE_VIBRATE 4
#define PROXY_MESSAGE_TYPE_INPUT_STATUS 7
#define PROXY_MESSAGE_TYPE_INPUT_CURSOR 9
#define PROXY_MESSAGE_TYPE_INPUT_AREA 11
#define PROXY_MESSAGE_TYPE_MOVE_VIEW 12
#define PROXY_MESSAGE_TYPE_CAPABILITY 5
#define PROXY_MESSAGE_TYPE_KEYBOARD_SHOW 8
#define PROXY_MESSAGE_TYPE_INITIALIZE 10

// Vibrate ç±»å
#define VIBRATE_KIND_BLOCK_BROKEN 0

// --- [END] TouchController Static Library Support ---

int memorystatus_control(uint32_t command, int32_t pid, uint32_t flags, void *buffer, size_t buffersize);
#define MEMORYSTATUS_CMD_SET_JETSAM_TASK_LIMIT        6

static int currentHotbarSlot = -1;
static GameSurfaceView* pojavWindow;

@interface SurfaceViewController ()<UITextFieldDelegate, UIGestureRecognizerDelegate> {
}

// FPS/memory monitoring (FPS is counted in the native pojavSwapBuffers, modeled on FCL/ZL2)
@property(nonatomic) NSTimer *statsTimer;                 // Low-frequency timer, once per second
@property(nonatomic) CADisplayLink *statsDisplayLink;     // Render loop reference (used for Gyro/Controller ticks and invalidation)
@property(nonatomic, strong) id statsDisplayLinkTarget;   // The CADisplayLink target (strong reference to prevent deallocation)

@property(nonatomic) NSDictionary* metadata;
@property(nonatomic) TrackedTextField *inputTextField;
@property(nonatomic) NSMutableArray* swipeableButtons;
@property(nonatomic) ControlButton* swipingButton;
@property(nonatomic) UITouch *primaryTouch, *hotbarTouch;

@property(nonatomic) UILongPressGestureRecognizer* longPressGesture, *longPressTwoGesture;
@property(nonatomic) UITapGestureRecognizer *tapGesture, *doubleTapGesture;
// TouchController look-around gesture: single-finger swipe on the right half
@property(nonatomic) UIPanGestureRecognizer *moveViewPanGesture;

@property(nonatomic) id mouseConnectCallback, mouseDisconnectCallback;
@property(nonatomic) id controllerConnectCallback, controllerDisconnectCallback;
// Key fix (accumulating UI anomaly): the MousePointerUpdated block observer was previously not stored,
// so it could not be removed in dealloc, leaking one observer plus a strong reference to self every time the game was entered and exited.
// It is now stored as a property and removed in dealloc.
@property(nonatomic) id mousePointerUpdatedCallback;

@property(nonatomic) CGFloat screenScale;
@property(nonatomic) CGFloat mouseSpeed;
@property(nonatomic) CGRect clickRange;
@property(nonatomic) BOOL isMacCatalystApp, shouldHideControlsFromRecording,
    shouldTriggerClick, shouldTriggerHaptic, slideableHotbar, toggleHidden;

@property(nonatomic) BOOL enableMouseGestures, enableHotbarGestures;

@property(nonatomic) UIImpactFeedbackGenerator *lightHaptic;
@property(nonatomic) UIImpactFeedbackGenerator *mediumHaptic;

@property(nonatomic, strong) TouchSender *touchSender;
@property(nonatomic) long long touchControllerTransportHandle;

// TouchController Text Input Support
@property(nonatomic, strong) UITextField *touchControllerTextField;
@property(nonatomic) BOOL touchControllerTextInputEnabled;

// Phase 13/16: launch overlay layer (modeled on the FCL/ZL2 launch progress display, shown from JVM startup until the first frame is rendered)
//
// Important design notes (modeled on FCL/ZL2):
//   launchOverlayView.userInteractionEnabled must be NO so that it does not intercept touch events.
//   That way the gameMenuOverlay below it in the view hierarchy (floating ball + FPS display) can still be
//   dragged and tapped by the user during launch. This is how FCL/ZL2 do it - the launch overlay is a purely
//   visual layer that takes no part in interaction. All its subviews (icon, progress bar, text) are presentational and need no touches.
//
//   View hierarchy (bottom to top):
//     rootView (game rendering surface)
//       → menuView (bottom pop-up menu)
//         → menuDimView (menu background dimming layer)
//           → gameMenuOverlay (floating ball + FPS display) ← must stay interactive
//             → launchOverlayView (launch overlay layer) ← userInteractionEnabled = NO
//
//   Touch event flow:
//     1. The user touches the screen → UIKit starts hitTest from the topmost view
//     2. launchOverlayView.userInteractionEnabled = NO → hitTest returns nil
//     3. The touch passes through to gameMenuOverlay
//     4. gameMenuOverlay.hitTest checks whether menuButton/statsLabel was hit
//        - Hit → returns that control, and the user can drag/tap it
//        - Not hit → returns nil and the touch keeps passing through to the game view
@property(nonatomic, strong) UIView *launchOverlayView;
@property(nonatomic, strong) CAGradientLayer *launchGradientLayer;
@property(nonatomic, strong) UIActivityIndicatorView *launchSpinner;
@property(nonatomic, strong) UILabel *launchTitleLabel;
@property(nonatomic, assign) NSTimeInterval launchStartTime;
@property(nonatomic, assign) BOOL launchOverlayDismissed;
@property(nonatomic, strong) UIButton *launchCancelButton;     // Cancel launch button

@end

@implementation SurfaceViewController

#pragma mark - TouchController Static Library Support

// å¯å¨ TouchController æ¶æ¯æ¥æ¶å¾ªç¯
- (void)startTouchControllerMessageLoop {
    __weak typeof(self) weakSelf = self;
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        while (weakSelf.touchControllerTransportHandle >= 0 && ![weakSelf isViewDismissed]) {
            @autoreleasepool {
                NSMutableData *buffer = [NSMutableData dataWithLength:256];
                int result = [TouchControllerBridge receiveFromTransport:weakSelf.touchControllerTransportHandle buffer:buffer];

                if (result > 0) {
                    [buffer setLength:result];
                    [weakSelf processTouchControllerMessage:buffer];
                }

                // ä¼ç  16ms
                usleep(16000);
            }
        }
    });
}

// æ£æ¥è§å¾æ¯å¦å·²å³é­
- (BOOL)isViewDismissed {
    return !self.view.window || self.isBeingDismissed;
}

// ç¼ç  ProxyMessage: AddPointerMessage (type=1, index=int32, x=float, y=float)
- (NSData *)encodeAddPointerMessage:(int32_t)index x:(float)x y:(float)y {
    NSMutableData *data = [NSMutableData dataWithCapacity:16];
    int32_t type = htonl(PROXY_MESSAGE_TYPE_ADD_POINTER);
    int32_t indexBE = htonl(index);

    // å° float è½¬æ¢ä¸ºç½ç»å­èåº
    union { float f; uint32_t i; } ux, uy;
    ux.f = x;
    uy.f = y;
    uint32_t xBE = htonl(ux.i);
    uint32_t yBE = htonl(uy.i);

    [data appendBytes:&type length:4];
    [data appendBytes:&indexBE length:4];
    [data appendBytes:&xBE length:4];
    [data appendBytes:&yBE length:4];

    return data;
}

// ç¼ç  ProxyMessage: RemovePointerMessage (type=2, index=int32)
- (NSData *)encodeRemovePointerMessage:(int32_t)index {
    NSMutableData *data = [NSMutableData dataWithCapacity:8];
    int32_t type = htonl(PROXY_MESSAGE_TYPE_REMOVE_POINTER);
    int32_t indexBE = htonl(index);

    [data appendBytes:&type length:4];
    [data appendBytes:&indexBE length:4];

    return data;
}

// åé ProxyMessage å° TouchController éæåº
- (void)sendTouchControllerProxyMessage:(int32_t)index x:(float)x y:(float)y isRemove:(BOOL)isRemove {
    NSData *messageData;

    if (isRemove) {
        messageData = [self encodeRemovePointerMessage:index];
    } else {
        messageData = [self encodeAddPointerMessage:index x:x y:y];
    }

    if (self.touchControllerTransportHandle >= 0 && messageData) {
        [TouchControllerBridge sendToTransport:self.touchControllerTransportHandle data:messageData];
    }
}

#pragma mark - TouchController Text Input Support

// ç¼ç  InputStatusMessage (type=7)
- (NSData *)encodeInputStatusMessageWithText:(NSString *)text
                              compositionStart:(int)compositionStart
                              compositionLength:(int)compositionLength
                              selectionStart:(int)selectionStart
                              selectionLength:(int)selectionLength
                              selectionLeft:(BOOL)selectionLeft {
    if (!text) {
        // æ æ°æ®ï¼åªåé type + 0
        int32_t type = htonl(7);
        NSMutableData *data = [NSMutableData dataWithCapacity:1];
        [data appendBytes:&type length:4];
        uint8_t hasData = 0;
        [data appendBytes:&hasData length:1];
        return data;
    }

    // å° UTF-16 è½¬æ¢ä¸º UTF-8
    NSData *textData = [text dataUsingEncoding:NSUTF8StringEncoding];
    const char *textBytes = (const char *)[textData bytes];
    int textLength = (int)[textData length];

    // è®¡ç® UTF-8 ä½ç½®
    NSString *prefix = [text substringToIndex:compositionStart];
    NSData *prefixData = [prefix dataUsingEncoding:NSUTF8StringEncoding];
    int compositionStartUtf8 = (int)[prefixData length];

    NSString *compSegment = [text substringWithRange:NSMakeRange(compositionStart, compositionLength)];
    NSData *compData = [compSegment dataUsingEncoding:NSUTF8StringEncoding];
    int compositionLengthUtf8 = (int)[compData length];

    NSString *selPrefix = [text substringToIndex:selectionStart];
    NSData *selPrefixData = [selPrefix dataUsingEncoding:NSUTF8StringEncoding];
    int selectionStartUtf8 = (int)[selPrefixData length];

    NSString *selSegment = [text substringWithRange:NSMakeRange(selectionStart, selectionLength)];
    NSData *selData = [selSegment dataUsingEncoding:NSUTF8StringEncoding];
    int selectionLengthUtf8 = (int)[selData length];

    // ç¼ç æ¶æ¯
    NSMutableData *data = [NSMutableData dataWithCapacity:5 + textLength + 17];
    int32_t type = htonl(7);
    [data appendBytes:&type length:4];

    uint8_t hasDataFlag = 1;
    [data appendBytes:&hasDataFlag length:1];

    int32_t textLengthBE = htonl(textLength);
    [data appendBytes:&textLengthBE length:4];
    [data appendBytes:textBytes length:textLength];

    int32_t compStartBE = htonl(compositionStartUtf8);
    int32_t compLenBE = htonl(compositionLengthUtf8);
    [data appendBytes:&compStartBE length:4];
    [data appendBytes:&compLenBE length:4];

    int32_t selStartBE = htonl(selectionStartUtf8);
    int32_t selLenBE = htonl(selectionLengthUtf8);
    [data appendBytes:&selStartBE length:4];
    [data appendBytes:&selLenBE length:4];

    uint8_t selectionLeftFlag = selectionLeft ? 1 : 0;
    [data appendBytes:&selectionLeftFlag length:1];

    return data;
}

// ç¼ç  InputCursorMessage (type=9)
- (NSData *)encodeInputCursorMessageWithRect:(CGRect)rect {
    NSMutableData *data = [NSMutableData dataWithCapacity:17];
    int32_t type = htonl(9);
    [data appendBytes:&type length:4];

    uint8_t hasData = 1;
    [data appendBytes:&hasData length:1];

    union { float f; uint32_t i; } left, top, width, height;
    left.f = rect.origin.x;
    top.f = rect.origin.y;
    width.f = rect.size.width;
    height.f = rect.size.height;

    uint32_t leftBE = htonl(left.i);
    uint32_t topBE = htonl(top.i);
    uint32_t widthBE = htonl(width.i);
    uint32_t heightBE = htonl(height.i);

    [data appendBytes:&leftBE length:4];
    [data appendBytes:&topBE length:4];
    [data appendBytes:&widthBE length:4];
    [data appendBytes:&heightBE length:4];

    return data;
}

// ç¼ç  InputAreaMessage (type=11)
- (NSData *)encodeInputAreaMessageWithRect:(CGRect)rect {
    NSMutableData *data = [NSMutableData dataWithCapacity:17];
    int32_t type = htonl(11);
    [data appendBytes:&type length:4];

    uint8_t hasData = 1;
    [data appendBytes:&hasData length:1];

    union { float f; uint32_t i; } left, top, width, height;
    left.f = rect.origin.x;
    top.f = rect.origin.y;
    width.f = rect.size.width;
    height.f = rect.size.height;

    uint32_t leftBE = htonl(left.i);
    uint32_t topBE = htonl(top.i);
    uint32_t widthBE = htonl(width.i);
    uint32_t heightBE = htonl(height.i);

    [data appendBytes:&leftBE length:4];
    [data appendBytes:&topBE length:4];
    [data appendBytes:&widthBE length:4];
    [data appendBytes:&heightBE length:4];

    return data;
}

// åéææ¬è¾å¥ç¶æå° TouchController
- (void)sendTextInputStatus {
    if (self.touchControllerTransportHandle < 0) return;

    NSString *text = self.touchControllerTextField.text ?: @"";
    UITextRange *selectedRange = self.touchControllerTextField.selectedTextRange;
    NSInteger selectionStart = [self.touchControllerTextField offsetFromPosition:self.touchControllerTextField.beginningOfDocument
                                                                  toPosition:selectedRange.start];
    NSInteger selectionLength = [self.touchControllerTextField offsetFromPosition:selectedRange.start
                                                                    toPosition:selectedRange.end];

    NSData *messageData = [self encodeInputStatusMessageWithText:text
                                              compositionStart:0
                                              compositionLength:0
                                              selectionStart:(int)selectionStart
                                              selectionLength:(int)selectionLength
                                              selectionLeft:NO];

    [TouchControllerBridge sendToTransport:self.touchControllerTransportHandle data:messageData];
}

// åéåæ ä½ç½®ä¿¡æ¯
- (void)sendInputCursorWithRect:(CGRect)rect {
    if (self.touchControllerTransportHandle < 0) return;

    NSData *messageData = [self encodeInputCursorMessageWithRect:rect];
    [TouchControllerBridge sendToTransport:self.touchControllerTransportHandle data:messageData];
}

// åéè¾å¥åºåä¿¡æ¯
- (void)sendInputAreaWithRect:(CGRect)rect {
    if (self.touchControllerTransportHandle < 0) return;

    NSData *messageData = [self encodeInputAreaMessageWithRect:rect];
    [TouchControllerBridge sendToTransport:self.touchControllerTransportHandle data:messageData];
}

#pragma mark - TouchController Vibration Support

// ç¼ç  VibrateMessage (type=4)
- (NSData *)encodeVibrateMessageWithKind:(int32_t)kind {
    NSMutableData *data = [NSMutableData dataWithCapacity:8];
    int32_t type = htonl(PROXY_MESSAGE_TYPE_VIBRATE);
    int32_t kindBE = htonl(kind);

    [data appendBytes:&type length:4];
    [data appendBytes:&kindBE length:4];

    return data;
}

// è§¦åéå¨åé¦
- (void)triggerVibrationWithKind:(int32_t)kind {
    // æ£æ¥éå¨æ¯å¦å¯ç¨
    if (!getPrefBool(@"control.mod_touch_vibrate_enable")) {
        return;
    }

    // è·åéå¨å¼ºåº¦è®¾ç½®
    NSInteger intensity = [getPrefObject(@"control.mod_touch_vibrate_intensity") integerValue];
    if (intensity < 1) intensity = 1;
    if (intensity > 3) intensity = 3;

    // ä½¿ç¨ UIImpactFeedbackGenerator è§¦åéå¨
    UIImpactFeedbackGenerator *feedbackGenerator;
    switch (intensity) {
        case 1: // è½»åº¦éå¨
            feedbackGenerator = [[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleLight];
            break;
        case 2: // ä¸­åº¦éå¨
            feedbackGenerator = [[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleMedium];
            break;
        case 3: // éåº¦éå¨
            feedbackGenerator = [[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleHeavy];
            break;
        default:
            feedbackGenerator = [[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleMedium];
            break;
    }

    [feedbackGenerator impactOccurred];

    // åæ¶åé VibrateMessage å° TouchController
    if (self.touchControllerTransportHandle >= 0) {
        NSData *messageData = [self encodeVibrateMessageWithKind:kind];
        [TouchControllerBridge sendToTransport:self.touchControllerTransportHandle data:messageData];
    }
}

#pragma mark - TouchController Capability

// Encode CapabilityMessage (type=5)
// Format: 4B type (big endian) + 1B name_len + N B name (UTF-8) + 1B enabled (0/1)
- (NSData *)encodeCapabilityMessageWithName:(NSString *)name enabled:(BOOL)enabled {
    NSData *nameData = [name dataUsingEncoding:NSUTF8StringEncoding];
    if (!nameData) {
        NSLog(@"[TouchController] Failed to encode capability name as UTF-8: %@", name);
        return nil;
    }

    uint8_t nameLen = (uint8_t)[nameData length];
    int32_t type = htonl(PROXY_MESSAGE_TYPE_CAPABILITY);
    uint8_t enabledByte = enabled ? 1 : 0;

    NSMutableData *data = [NSMutableData dataWithCapacity:4 + 1 + nameLen + 1];
    [data appendBytes:&type length:4];
    [data appendBytes:&nameLen length:1];
    [data appendBytes:[nameData bytes] length:nameLen];
    [data appendBytes:&enabledByte length:1];

    return data;
}

// Encode InitializeMessage (type=10)
// Reserved for the launcher to initialize proactively in the future; currently not called
- (NSData *)encodeInitializeMessage {
    int32_t type = htonl(PROXY_MESSAGE_TYPE_INITIALIZE);
    return [NSData dataWithBytes:&type length:4];
}

// Called after receiving an InitializeMessage, to declare the launcher's capabilities to the mod
- (void)sendCapabilities {
    if (self.touchControllerTransportHandle < 0) {
        NSLog(@"[TouchController] Cannot send capabilities: transport not initialized");
        return;
    }

    // Send the text_status capability: declares that the launcher will report text editing state via InputStatusMessage
    NSData *textStatusCap = [self encodeCapabilityMessageWithName:@"text_status" enabled:YES];
    [TouchControllerBridge sendToTransport:self.touchControllerTransportHandle data:textStatusCap];

    // Send the keyboard_show capability: declares that the launcher will respond to KeyboardShowMessage to show/hide the keyboard
    NSData *keyboardShowCap = [self encodeCapabilityMessageWithName:@"keyboard_show" enabled:YES];
    [TouchControllerBridge sendToTransport:self.touchControllerTransportHandle data:keyboardShowCap];

    NSLog(@"[TouchController] Sent capabilities: text_status, keyboard_show");
}

#pragma mark - TouchController MoveView Support

// ç¼ç  MoveViewMessage (type=12)
- (NSData *)encodeMoveViewMessageWithScreenBased:(BOOL)screenBased
                                     deltaPitch:(float)deltaPitch
                                      deltaYaw:(float)deltaYaw {
    NSMutableData *data = [NSMutableData dataWithCapacity:13];
    int32_t type = htonl(PROXY_MESSAGE_TYPE_MOVE_VIEW);
    uint8_t screenBasedByte = screenBased ? 1 : 0;

    // å° float è½¬æ¢ä¸ºç½ç»å­èåº
    union { float f; uint32_t i; } up, uy;
    up.f = deltaPitch;
    uy.f = deltaYaw;
    uint32_t pitchBE = htonl(up.i);
    uint32_t yawBE = htonl(uy.i);

    [data appendBytes:&type length:4];
    [data appendBytes:&screenBasedByte length:1];
    [data appendBytes:&pitchBE length:4];
    [data appendBytes:&yawBE length:4];

    return data;
}

// åéç§»å¨è§è§æ¶æ¯
- (void)sendMoveViewWithDeltaPitch:(float)deltaPitch deltaYaw:(float)deltaYaw {
    if (self.touchControllerTransportHandle >= 0) {
        NSData *messageData = [self encodeMoveViewMessageWithScreenBased:YES
                                                              deltaPitch:deltaPitch
                                                               deltaYaw:deltaYaw];
        [TouchControllerBridge sendToTransport:self.touchControllerTransportHandle data:messageData];
    }
}

#pragma mark - TouchController Message Receiver

// å¤çä» TouchController æ¥æ¶å°çæ¶æ¯
- (void)processTouchControllerMessage:(NSData *)messageData {
    if (messageData.length < 4) {
        NSLog(@"[TouchController] Message too short: %lu bytes", (unsigned long)messageData.length);
        return;
    }

    int32_t type;
    [messageData getBytes:&type length:4];
    type = ntohl(type);

    switch (type) {
        case PROXY_MESSAGE_TYPE_VIBRATE: {
            if (messageData.length >= 8) {
                int32_t kind;
                [messageData getBytes:&kind range:NSMakeRange(4, 4)];
                kind = ntohl(kind);
                
                // ä½¿ç¨ dispatch_async ç¡®ä¿å¨ä¸»çº¿ç¨ä¸­è°ç¨
                dispatch_async(dispatch_get_main_queue(), ^{
                    if (self.view && !self.isBeingDismissed) {
                        [self triggerVibrationWithKind:kind];
                    }
                });
            }
            break;
        }
        case PROXY_MESSAGE_TYPE_MOVE_VIEW: {
            if (messageData.length >= 13) {
                uint8_t screenBasedByte;
                int32_t pitchBE, yawBE;
                [messageData getBytes:&screenBasedByte range:NSMakeRange(4, 1)];
                [messageData getBytes:&pitchBE range:NSMakeRange(5, 4)];
                [messageData getBytes:&yawBE range:NSMakeRange(9, 4)];

                BOOL screenBased = (screenBasedByte != 0);
                union { uint32_t i; float f; } up, uy;
                up.i = ntohl(pitchBE);
                uy.i = ntohl(yawBE);

                // MoveView æ¶æ¯éå¸¸æ¯ä»å®¢æ·ç«¯åéå°æå¡ç«¯ç
                // è¿éæä»¬è®°å½æ¥å¿ï¼å®éåºç¨å¯è½éè¦ç¹æ®å¤ç
                NSLog(@"[TouchController] Received MoveView: screenBased=%d, pitch=%.2f, yaw=%.2f",
                      screenBased, up.f, uy.f);
            }
            break;
        }
        case PROXY_MESSAGE_TYPE_INITIALIZE: {
            NSLog(@"[TouchController] Received InitializeMessage, sending capabilities");
            dispatch_async(dispatch_get_main_queue(), ^{
                if (self.view && !self.isBeingDismissed) {
                    [self sendCapabilities];
                }
            });
            break;
        }
        case PROXY_MESSAGE_TYPE_KEYBOARD_SHOW: {
            if (messageData.length >= 5) {
                uint8_t showByte;
                [messageData getBytes:&showByte range:NSMakeRange(4, 1)];
                BOOL show = (showByte != 0);
                NSLog(@"[TouchController] Received KeyboardShow: show=%d", show);
                dispatch_async(dispatch_get_main_queue(), ^{
                    if (self.view && !self.isBeingDismissed) {
                        if (show) {
                            [self.touchControllerTextField becomeFirstResponder];
                        } else {
                            [self.touchControllerTextField resignFirstResponder];
                        }
                    }
                });
            } else {
                NSLog(@"[TouchController] KeyboardShowMessage too short: %lu bytes", (unsigned long)messageData.length);
            }
            break;
        }
        case PROXY_MESSAGE_TYPE_CAPABILITY: {
            // Capability negotiation in the mod → launcher direction (future extension point)
            // The launcher currently does not handle capabilities declared by the mod, it only logs them
            if (messageData.length >= 6) {
                uint8_t nameLen;
                [messageData getBytes:&nameLen range:NSMakeRange(4, 1)];
                if (messageData.length >= (NSUInteger)(5 + nameLen + 1)) {
                    NSRange nameRange = NSMakeRange(5, nameLen);
                    NSString *capabilityName = [[NSString alloc] initWithData:[messageData subdataWithRange:nameRange] encoding:NSUTF8StringEncoding];
                    uint8_t enabledByte;
                    [messageData getBytes:&enabledByte range:NSMakeRange(5 + nameLen, 1)];
                    NSLog(@"[TouchController] Received Capability: name=%@, enabled=%d", capabilityName, enabledByte != 0);
                } else {
                    NSLog(@"[TouchController] CapabilityMessage too short for declared name length");
                }
            }
            break;
        }
        default: {
            NSUInteger dumpLen = MIN(messageData.length, (NSUInteger)32);
            NSMutableString *hexDump = [NSMutableString string];
            const uint8_t *bytes = (const uint8_t *)[messageData bytes];
            for (NSUInteger i = 0; i < dumpLen; i++) {
                [hexDump appendFormat:@"%02x ", bytes[i]];
            }
            NSLog(@"[TouchController] Unknown message type: %d, length: %lu, hex: %@",
                  type, (unsigned long)messageData.length, hexDump);
            break;
        }
    }
}

// åå§åææ¬è¾å¥å­æ®µ
#pragma mark - GestureRecognizer Delegate

// Only moveViewPanGesture needs special handling; other gestures keep the default behavior
- (BOOL)gestureRecognizerShouldBegin:(UIGestureRecognizer *)gestureRecognizer {
    if (gestureRecognizer == self.moveViewPanGesture) {
        // Condition 1: TouchController must be enabled
        if (!getPrefBool(@"control.mod_touch_enable")) return NO;
        // Condition 2: must be in static library mode (mode == 2)
        NSInteger mode = [getPrefObject(@"control.mod_touch_mode") integerValue];
        if (mode != 2) return NO;
        // Condition 3: the look-around toggle must be on
        if (!getPrefBool(@"control.mod_touch_moveview_enable")) return NO;
        // Condition 4: must be in game (isGrabbing is true)
        if (isGrabbing != JNI_TRUE) return NO;
        // Condition 5: the touch must start in the right half of touchView
        CGPoint location = [gestureRecognizer locationInView:self.touchView];
        if (location.x < self.touchView.bounds.size.width / 2.0) return NO;
        return YES;
    }
    return YES;
}

#pragma mark - TouchController MoveView Gesture

// Handle the right-half swipe gesture and send a MoveViewMessage to TouchController
- (void)handleMoveViewPanGesture:(UIPanGestureRecognizer *)gesture {
    // Double check (defensive programming: verify again even though gestureRecognizerShouldBegin returned YES)
    if (!getPrefBool(@"control.mod_touch_enable")) return;
    if (!getPrefBool(@"control.mod_touch_moveview_enable")) return;
    if (isGrabbing != JNI_TRUE) return;

    UIPanGestureRecognizer *panGesture = (UIPanGestureRecognizer *)gesture;
    CGPoint translation = [panGesture translationInView:self.touchView];

    switch (panGesture.state) {
        case UIGestureRecognizerStateBegan:
            // The start position needs no special handling; translation is already relative to the start point
            break;
        case UIGestureRecognizerStateChanged: {
            // Compute the incremental view angle change
            // Note: deltaPitch corresponds to the Y axis (up/down) and deltaYaw to the X axis (left/right)
            // Sensitivity factor: converts screen pixels into a reasonable view angle change
            // 1.0 means a 1:1 mapping (when screenBased=true the mod side multiplies by sensitivity)
            float deltaPitch = (float)translation.y;
            float deltaYaw = (float)translation.x;
            [self sendMoveViewWithDeltaPitch:deltaPitch deltaYaw:deltaYaw];
            // Reset translation to zero so the next frame's delta is incremental rather than cumulative
            [panGesture setTranslation:CGPointZero inView:self.touchView];
            break;
        }
        case UIGestureRecognizerStateEnded:
        case UIGestureRecognizerStateCancelled:
        case UIGestureRecognizerStateFailed:
            // Clean up state (nothing special needed; translation has been reset or the gesture has ended)
            break;
        default:
            break;
    }
}

- (void)setupTouchControllerTextInput {
    if (!self.touchControllerTextField) {
        self.touchControllerTextField = [[UITextField alloc] initWithFrame:CGRectZero];
        self.touchControllerTextField.hidden = YES;
        self.touchControllerTextField.autocapitalizationType = UITextAutocapitalizationTypeNone;
        self.touchControllerTextField.autocorrectionType = UITextAutocorrectionTypeNo;
        self.touchControllerTextField.keyboardType = UIKeyboardTypeDefault;
        [self.view addSubview:self.touchControllerTextField];

        // æ·»å ææ¬ååçå¬
        [self.touchControllerTextField addTarget:self
                                          action:@selector(textFieldDidChange:)
                                forControlEvents:UIControlEventEditingChanged];
    }
}

// å¤çææ¬åå
- (void)textFieldDidChange:(UITextField *)textField {
    [self sendTextInputStatus];
}

// æ¾ç¤ºææ¬è¾å¥çé¢
- (void)showTouchControllerTextInput {
    if (!self.touchControllerTextInputEnabled) return;

    [self setupTouchControllerTextInput];
    self.touchControllerTextField.hidden = NO;
    [self.touchControllerTextField becomeFirstResponder];

    // åéè¾å¥åºåä¿¡æ¯
    [self sendInputAreaWithRect:self.touchControllerTextField.frame];

    // åéåå§ææ¬ç¶æ
    [self sendTextInputStatus];
}

// éèææ¬è¾å¥çé¢
- (void)hideTouchControllerTextInput {
    [self.touchControllerTextField resignFirstResponder];
    self.touchControllerTextField.hidden = YES;

    // åéç©ºç¶æä»¥å³é­è¾å¥
    NSData *messageData = [self encodeInputStatusMessageWithText:nil
                                              compositionStart:0
                                              compositionLength:0
                                              selectionStart:0
                                              selectionLength:0
                                              selectionLeft:NO];
    [TouchControllerBridge sendToTransport:self.touchControllerTransportHandle data:messageData];
}

#pragma mark - Initialization

- (instancetype)initWithMetadata:(NSDictionary *)metadata {
    self = [super init];
    if (self) {
        self.metadata = metadata;
    }
    return self;
}

- (void)viewDidLoad
{
    [super viewDidLoad];
    isControlModifiable = NO;
    self.isMacCatalystApp = NSProcessInfo.processInfo.isMacCatalystApp;
    // Load MetalHUD library
    dlopen("/usr/lib/libMTLHud.dylib", 0);

    self.lightHaptic = [[UIImpactFeedbackGenerator alloc] initWithStyle:(UIImpactFeedbackStyleLight)];
    self.mediumHaptic = [[UIImpactFeedbackGenerator alloc] initWithStyle:(UIImpactFeedbackStyleMedium)];
    
    UIApplication.sharedApplication.idleTimerDisabled = YES;
    BOOL isTVOS = realUIIdiom == UIUserInterfaceIdiomTV;
    if (!isTVOS) {
        [self setNeedsUpdateOfScreenEdgesDeferringSystemGestures];
        [self setNeedsUpdateOfHomeIndicatorAutoHidden];
    }

    // Render loop tick: Gyro/Controller input sampling (FPS counting has moved into the native pojavSwapBuffers)
    // In Vulkan mode MC does not call glfwSwapBuffers, so the FPS counter never increments;
    // CADisplayLink is used as a fallback: the counter is incremented on every frame trigger.
    //
    // Key fix (Vulkan FPS display not working):
    //   Previously [CADisplayLink displayLinkWithTarget:tickInput selector:@selector(invoke)] was used
    //   to pass a block, but the block's invoke method signature is -(void)invoke, while the selector
    //   signature CADisplayLink expects is -(void)selector:(CADisplayLink*)link. The mismatch meant the callback never fired,
    //   so the FPS counter never incremented and always displayed 0.
    //   Fix: use a dedicated target class, PLDisplayLinkTarget, that provides a callback method with the correct signature.
    //
    //   Another problem: currentRenderer is read from PLProfiles at viewDidLoad time, but JavaLauncher.m
    //   may modify the AMETHYST_RENDERER environment variable at launch (e.g. auto → ANGLE).
    //   Therefore both PLProfiles and the AMETHYST_RENDERER environment variable are checked, and the fallback is enabled if either is Vulkan.
    //
    //   Key fix (FPS counting for the Vulkan renderer + OpenGL path):
    //   When renderer=libMoltenVK.dylib but MC 26.2+ chooses prefer_opengl, MC takes the GL path
    //   (glfwWindowHint(GLFW_OPENGL_API)) and pojavSwapBuffers is called (via eglSwapBuffers).
    //   In that case the CADisplayLink fallback must not be enabled, otherwise it would double count with pojavSwapBuffers' FPS counting.
    //   Only a genuine Vulkan path (graphicsApi=prefer_vulkan and renderer=libMoltenVK.dylib)
    //   needs the CADisplayLink fallback, because the Vulkan path does not call pojavSwapBuffers.
    //
    //   Note (phase 2 fix): configuredVulkanExpected here is only used for diagnostic logs (PLDisplayLinkTarget.isVulkanMode);
    //   whether the fallback is actually enabled is decided inside displayLinkTick: by dynamically querying pojavIsActualVulkanPath() every frame
    //   (reading clientAPI == GLFW_NO_API), which matches MC's real rendering path.
    NSString *currentRenderer = [PLProfiles resolveKeyForCurrentProfile:@"renderer"];
    NSString *envRenderer = NSProcessInfo.processInfo.environment[@"AMETHYST_RENDERER"];
    NSString *graphicsApi = NSProcessInfo.processInfo.environment[@"AMETHYST_GRAPHICS_API"];
    BOOL isVulkanRenderer = [currentRenderer isEqualToString:@ RENDERER_NAME_VULKAN] ||
                            [envRenderer isEqualToString:@ RENDERER_NAME_VULKAN];
    // Configured expected Vulkan path: used only for diagnostic logs, to compare the "configured expectation" with "what MC actually chose"
    BOOL configuredVulkanExpected = isVulkanRenderer &&
        ![graphicsApi isEqualToString:@"prefer_opengl"] &&
        ![graphicsApi isEqualToString:@"opengl"];
    NSLog(@"[SurfaceViewController] FPS counter setup: profileRenderer=%@, envRenderer=%@, graphicsApi=%@, isVulkan=%d, configuredVulkanExpected=%d (actual path decided at runtime via pojavIsActualVulkanPath)",
          currentRenderer, envRenderer, graphicsApi, isVulkanRenderer, configuredVulkanExpected);

    PLDisplayLinkTarget *linkTarget = [[PLDisplayLinkTarget alloc] initWithVulkanMode:configuredVulkanExpected];
    CADisplayLink *displayLink = [CADisplayLink displayLinkWithTarget:linkTarget
                                                            selector:@selector(displayLinkTick:)];
    if (@available(iOS 15.0, tvOS 15.0, *)) {
        // The max_framerate option has been removed: an adaptive 30-120Hz range is always used.
        // The screen hardware determines the actual frame rate (a 60Hz device still runs at 60, a 120Hz ProMotion device can reach 120),
        // rather than artificially capping at 60 FPS. Combined with disable_game_vsync to fully unlock VSync, the frame rate can exceed the screen refresh rate.
        displayLink.preferredFrameRateRange = CAFrameRateRangeMake(30, 120, 120);
    }
    [displayLink addToRunLoop:NSRunLoop.currentRunLoop forMode:NSRunLoopCommonModes];
    self.statsDisplayLink = displayLink;
    self.statsDisplayLinkTarget = linkTarget;  // Strong reference to prevent deallocation

    // Low-frequency sampling timer: reads the native FPS counter and memory usage once per second
    // Modeled on the FCL/ZL2 1Hz sampling strategy (FCL_GameMenu.java Thread.sleep(1000))
    // pojavGetAndResetFps() reads and resets the counter, so with a 1 second interval it returns the FPS value directly
    self.statsTimer = [NSTimer scheduledTimerWithTimeInterval:1.0
                                                      target:self
                                                    selector:@selector(updateGameStats)
                                                    userInfo:nil
                                                     repeats:YES];
    [[NSRunLoop currentRunLoop] addTimer:self.statsTimer forMode:NSRunLoopCommonModes];

    CGFloat screenScale = UIScreen.mainScreen.scale;
    [self updateSavedResolution];

    self.rootView = [[UIView alloc] initWithFrame:CGRectMake(0, 0, self.view.frame.size.width + 30.0, self.view.frame.size.height)];
    [self.view addSubview:self.rootView];

    self.ctrlView = [[ControlLayout alloc] initWithFrame:getSafeArea(self.view.frame)];
    [self performSelector:@selector(initCategory_Navigation)];

    self.surfaceView = [[GameSurfaceView alloc] initWithFrame:self.view.frame];
    self.surfaceView.layer.contentsScale = screenScale * resolutionScale;
    self.surfaceView.layer.magnificationFilter = self.surfaceView.layer.minificationFilter = kCAFilterNearest;
    self.surfaceView.multipleTouchEnabled = YES;
    pojavWindow = self.surfaceView;

    self.touchView = [[UIView alloc] initWithFrame:self.view.frame];
    self.touchView.backgroundColor = [UIColor colorWithRed:0.05 green:0.06 blue:0.09 alpha:1.0];
    self.touchView.multipleTouchEnabled = YES;
    [self.touchView addSubview:self.surfaceView];

    [self.rootView addSubview:self.touchView];
    [self.rootView addSubview:self.ctrlView];

    [self performSelector:@selector(setupCategory_Navigation)];

    UIHoverGestureRecognizer *hoverGesture = [[NSClassFromString(@"UIHoverGestureRecognizer") alloc] initWithTarget:self action:@selector(surfaceOnHover:)];
    [self.touchView addGestureRecognizer:hoverGesture];

    self.tapGesture = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(surfaceOnClick:)];
    self.tapGesture.allowedTouchTypes = @[@(UITouchTypeDirect)];
    self.tapGesture.delegate = self;
    self.tapGesture.numberOfTapsRequired = 1;
    self.tapGesture.numberOfTouchesRequired = 1;
    self.tapGesture.cancelsTouchesInView = NO;
    self.tapGesture.delaysTouchesBegan = NO;
    self.tapGesture.delaysTouchesEnded = NO;
    [self.touchView addGestureRecognizer:self.tapGesture];

    self.doubleTapGesture = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(surfaceOnDoubleClick:)];
    self.doubleTapGesture.allowedTouchTypes = @[@(UITouchTypeDirect)];
    self.doubleTapGesture.delegate = self;
    self.doubleTapGesture.numberOfTapsRequired = 2;
    self.doubleTapGesture.numberOfTouchesRequired = 1;
    self.doubleTapGesture.cancelsTouchesInView = NO;
    self.doubleTapGesture.delaysTouchesBegan = NO;
    self.doubleTapGesture.delaysTouchesEnded = NO;
    [self.touchView addGestureRecognizer:self.doubleTapGesture];

    self.longPressGesture = [[UILongPressGestureRecognizer alloc] initWithTarget:self action:@selector(surfaceOnLongpress:)];
    self.longPressGesture.allowedTouchTypes = @[@(UITouchTypeDirect)];
    self.longPressGesture.cancelsTouchesInView = NO;
    self.longPressGesture.delaysTouchesBegan = NO;
    self.longPressGesture.delaysTouchesEnded = NO;
    self.longPressGesture.delegate = self;
    [self.touchView addGestureRecognizer:self.longPressGesture];

    self.longPressTwoGesture = [[UILongPressGestureRecognizer alloc]initWithTarget:self action:@selector(keyboardGesture:)];
    self.longPressTwoGesture.numberOfTouchesRequired = 2;
    self.longPressTwoGesture.allowedTouchTypes = @[@(UITouchTypeDirect)];
    self.longPressTwoGesture.cancelsTouchesInView = NO;
    self.longPressTwoGesture.delaysTouchesBegan = NO;
    self.longPressTwoGesture.delaysTouchesEnded = NO;
    self.longPressTwoGesture.delegate = self;
    [self.touchView addGestureRecognizer:self.longPressTwoGesture];

    self.scrollPanGesture = [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(surfaceOnTouchesScroll:)];
    self.scrollPanGesture.allowedTouchTypes = @[@(UITouchTypeDirect)];
    self.scrollPanGesture.delegate = self;
    self.scrollPanGesture.minimumNumberOfTouches = 2;
    self.scrollPanGesture.maximumNumberOfTouches = 2;
    self.scrollPanGesture.cancelsTouchesInView = NO;
    self.scrollPanGesture.delaysTouchesBegan = NO;
    self.scrollPanGesture.delaysTouchesEnded = NO;
    [self.touchView addGestureRecognizer:self.scrollPanGesture];

    // TouchController look-around gesture: single-finger swipe on the right half
    self.moveViewPanGesture = [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(handleMoveViewPanGesture:)];
    self.moveViewPanGesture.allowedTouchTypes = @[@(UITouchTypeDirect)];
    self.moveViewPanGesture.delegate = self;
    self.moveViewPanGesture.maximumNumberOfTouches = 1;
    self.moveViewPanGesture.minimumNumberOfTouches = 1;
    // Do not cancel touches events, so touchesMoved can still fire (coexisting with TC AddPointer)
    self.moveViewPanGesture.cancelsTouchesInView = NO;
    self.moveViewPanGesture.delaysTouchesBegan = NO;
    self.moveViewPanGesture.delaysTouchesEnded = NO;
    [self.touchView addGestureRecognizer:self.moveViewPanGesture];

    virtualMouseEnabled = getPrefBool(@"control.virtmouse_enable");
    virtualMouseFrame = CGRectMake(self.view.frame.size.width / 2, self.view.frame.size.height / 2, 18, 27);
    self.mousePointerView = [[UIImageView alloc] initWithFrame:virtualMouseFrame];
    self.mousePointerView.autoresizingMask = UIViewAutoresizingFlexibleLeftMargin | UIViewAutoresizingFlexibleTopMargin | UIViewAutoresizingFlexibleRightMargin |UIViewAutoresizingFlexibleBottomMargin;
    self.mousePointerView.hidden = !virtualMouseEnabled;
    [self reloadMousePointerImage];
    self.mousePointerView.userInteractionEnabled = NO;
    [self.touchView addSubview:self.mousePointerView];

    // Key fix (accumulating UI anomaly): store the block observer as a property and remove it in dealloc.
    // Previously the return value was not stored, so every new SurfaceViewController leaked an observer plus a strong reference to self.
    self.mousePointerUpdatedCallback = [[NSNotificationCenter defaultCenter] addObserverForName:@"MousePointerUpdated" object:nil queue:[NSOperationQueue mainQueue] usingBlock:^(NSNotification * _Nonnull note) {
        [self reloadMousePointerImage];
    }];

    self.inputTextField = [[TrackedTextField alloc] initWithFrame:CGRectMake(0, -32.0, self.view.frame.size.width, 30.0)];
    self.inputTextField.backgroundColor = UIColor.secondarySystemBackgroundColor;
    self.inputTextField.delegate = self;
    self.inputTextField.font = [UIFont fontWithName:@"Menlo-Regular" size:20];
    self.inputTextField.clearsOnBeginEditing = YES;
    self.inputTextField.textAlignment = NSTextAlignmentCenter;
    self.inputTextField.sendChar = ^(jchar keychar){ CallbackBridge_nativeSendChar(keychar); };
    self.inputTextField.sendCharMods = ^(jchar keychar, int mods){ CallbackBridge_nativeSendCharMods(keychar, mods); };
    self.inputTextField.sendKey = ^(int key, int scancode, int action, int mods) { CallbackBridge_nativeSendKey(key, scancode, action, mods); };

    self.swipeableButtons = [[NSMutableArray alloc] init];

    [KeyboardInput initKeycodeTable];
    self.mouseConnectCallback = [[NSNotificationCenter defaultCenter] addObserverForName:GCMouseDidConnectNotification object:nil queue:[NSOperationQueue mainQueue] usingBlock:^(NSNotification *note) {
        GCMouse* mouse = note.object;
        [self registerMouseCallbacks:mouse];
        self.mousePointerView.hidden = isGrabbing || !virtualMouseEnabled;
        [self setNeedsUpdateOfPrefersPointerLocked];
    }];
    self.mouseDisconnectCallback = [[NSNotificationCenter defaultCenter] addObserverForName:GCMouseDidDisconnectNotification object:nil queue:[NSOperationQueue mainQueue] usingBlock:^(NSNotification *note) {
        GCMouse* mouse = note.object;
        mouse.mouseInput.mouseMovedHandler = nil;
        [mouse.mouseInput.auxiliaryButtons makeObjectsPerformSelector:@selector(setPressedChangedHandler:) withObject:nil];
        [self setNeedsUpdateOfPrefersPointerLocked];
        if (getPrefBool(@"controll.hardware_hide")) { self.ctrlView.hidden = NO; }
    }];
    if (GCMouse.current != nil) { [self registerMouseCallbacks:GCMouse.current]; }

    self.controllerConnectCallback = [[NSNotificationCenter defaultCenter] addObserverForName:GCControllerDidConnectNotification object:nil queue:[NSOperationQueue mainQueue] usingBlock:^(NSNotification *note) {
        GCController* controller = note.object;
        [ControllerInput initKeycodeTable];
        [ControllerInput registerControllerCallbacks:controller];
        self.mousePointerView.hidden = isGrabbing;
        virtualMouseEnabled = YES;
        if (getPrefBool(@"control.hardware_hide")) { self.ctrlView.hidden = YES; }
    }];
    self.controllerDisconnectCallback = [[NSNotificationCenter defaultCenter] addObserverForName:GCControllerDidDisconnectNotification object:nil queue:[NSOperationQueue mainQueue] usingBlock:^(NSNotification *note) {
        GCController* controller = note.object;
        [ControllerInput unregisterControllerCallbacks:controller];
        if (getPrefBool(@"control.hardware_hide")) { self.ctrlView.hidden = NO; }
    }];
    if (GCController.controllers.count == 1) {
        [ControllerInput initKeycodeTable];
        [ControllerInput registerControllerCallbacks:GCController.controllers.firstObject];
    }

    [self.rootView addSubview:self.inputTextField];
    [self performSelector:@selector(initCategory_LogView)];
    [self updateJetsamControl];
    [self updatePreferenceChanges];
    [self loadCustomControls];

    if (UIApplication.sharedApplication.connectedScenes.count > 1 && getPrefBool(@"video.fullscreen_airplay")) {
        [self switchToExternalDisplay];
    }
    
    self.touchSender = [[TouchSender alloc] init];

    // åå§å TouchController éæåº Transport
    if (getPrefBool(@"control.mod_touch_enable")) {
        NSInteger mode = [getPrefObject(@"control.mod_touch_mode") integerValue];
        if (mode == 2 && [TouchControllerBridge isTouchControllerAvailable]) {
            // éæåºæ¨¡å¼ï¼åå»º Transport
            self.touchControllerTransportHandle = [TouchControllerBridge createTransportWithName:@"/tmp/touchcontroller.sock"];
            if (self.touchControllerTransportHandle < 0) {
                NSLog(@"[TouchController] Failed to create transport for static library mode");
            } else {
                NSLog(@"[TouchController] Transport created successfully (handle: %lld)", self.touchControllerTransportHandle);
            }
        } else {
            self.touchControllerTransportHandle = -1;
        }
    } else {
        self.touchControllerTransportHandle = -1;
    }

    // åå§å TouchController ææ¬è¾å¥æ¯æ
    if (self.touchControllerTransportHandle >= 0) {
        self.touchControllerTextInputEnabled = YES;
        [self setupTouchControllerTextInput];
        NSLog(@"[TouchController] Text input support initialized");

        // å¯å¨æ¶æ¯æ¥æ¶å®æ¶å¨
        [self startTouchControllerMessageLoop];
    }

    // Phase 13: show the launch overlay layer (shown before launchMinecraft, removed automatically after the first frame is rendered)
    [self setupLaunchOverlay];

    [self launchMinecraft];
}

- (void)reloadMousePointerImage {
    NSString *path = [NSString stringWithFormat:@"%s/controlmap/mouse_pointer.png", getenv("POJAV_HOME")];
    UIImage *img = [UIImage imageWithContentsOfFile:path];
    if (img) {
        self.mousePointerView.image = img;
    } else {
        self.mousePointerView.image = [UIImage imageNamed:@"MousePointer"];
    }
}

- (void)viewDidAppear:(BOOL)animated {
    [super viewDidAppear:animated];
    [self setNeedsUpdateOfPrefersPointerLocked];

    // The LAN port detector has been switched to manual input mode (see LanPortDetector.h),
    // and automatic detection (startDetecting/stopDetecting) has been removed, so nothing needs to be started here.
}

- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    // Update the frame of the launch overlay layer's gradient background (on rotation/size changes)
    if (self.launchGradientLayer && self.launchOverlayView) {
        self.launchGradientLayer.frame = self.launchOverlayView.bounds;
    }
}

- (void)updateAudioSettings {
    NSError *sessionError = nil;
    AVAudioSessionCategory category;
    AVAudioSessionCategoryOptions options = 0;
    if(getPrefBool(@"video.allow_microphone")) {
        category = AVAudioSessionCategoryPlayAndRecord;
        options |= AVAudioSessionCategoryOptionAllowAirPlay | AVAudioSessionCategoryOptionAllowBluetoothA2DP | AVAudioSessionCategoryOptionDefaultToSpeaker;
    } else if(getPrefBool(@"video.silence_with_switch")) {
        category = AVAudioSessionCategorySoloAmbient;
    } else {
        category = AVAudioSessionCategoryPlayback;
    }
    if(!getPrefBool(@"video.silence_other_audio")) {
        options |= AVAudioSessionCategoryOptionMixWithOthers;
    }
    AVAudioSession *session = AVAudioSession.sharedInstance;
    [session setCategory:category withOptions:options error:&sessionError];
    [session setActive:YES error:&sessionError];
}

- (void)updateJetsamControl {
    if (!getEntitlementValue(@"com.apple.private.memorystatus")) {
        return;
    }
    // This must stay consistent with the allocmem calculation in launchJVM in JavaLauncher.m,
    // otherwise the Jetsam limit can end up below JVM Xmx + native overhead,
    // causing the system to SIGKILL the process during JVM startup (which shows up in the log as "XPC connection interrupted").
    int allocmem;
    if (getPrefBool(@"java.auto_ram")) {
        CGFloat autoRatio = getEntitlementValue(@"com.apple.private.memorystatus") ? 0.4 : 0.25;
        allocmem = roundf((NSProcessInfo.processInfo.physicalMemory >> 20) * autoRatio);
    } else {
        allocmem = (int)getPrefInt(@"java.allocated_memory");
    }
    // 1024 MB is reserved for the JVM native heap plus non-Java-heap overhead such as UIKit/Metal/EGL.
    int limit = allocmem + 1024;
    if (memorystatus_control(MEMORYSTATUS_CMD_SET_JETSAM_TASK_LIMIT, getpid(), limit, NULL, 0) == -1) {
        NSLog(@"Failed to set Jetsam task limit: error: %s", strerror(errno));
    } else {
        NSLog(@"Successfully set Jetsam task limit (allocmem=%d MB, limit=%d MB)", allocmem, limit);
    }
}

- (void)updatePreferenceChanges {
    if (getPrefBool(@"debug.debug_auto_correction")) {
        self.inputTextField.autocorrectionType = UITextAutocorrectionTypeDefault;
    } else {
        self.inputTextField.autocorrectionType = UITextAutocorrectionTypeNo;
    }

    BOOL gyroEnabled = getPrefBool(@"control.gyroscope_enable");
    BOOL gyroInvertX = getPrefBool(@"control.gyroscope_invert_x_axis");
    int gyroSensitivity = getPrefInt(@"control.gyroscope_sensitivity");
    [GyroInput updateSensitivity:gyroEnabled?gyroSensitivity:0 invertXAxis:gyroInvertX];

    self.mouseSpeed = getPrefFloat(@"control.mouse_speed") / 100.0;
    virtualMouseEnabled = getPrefBool(@"control.virtmouse_enable");
    self.mousePointerView.hidden = isGrabbing || !virtualMouseEnabled;

    CGFloat mouseScale = getPrefFloat(@"control.mouse_scale") / 100.0;
    virtualMouseFrame = CGRectMake(self.view.frame.size.width / 2, self.view.frame.size.height / 2, 18.0 * mouseScale, 27 * mouseScale);
    self.mousePointerView.frame = virtualMouseFrame;

    self.shouldHideControlsFromRecording = getPrefFloat(@"control.recording_hide");
    [self.ctrlView hideViewFromCapture:self.shouldHideControlsFromRecording];
    self.ctrlView.frame = getSafeArea(self.view.frame);

    self.slideableHotbar = getPrefBool(@"control.slideable_hotbar");
    self.enableMouseGestures = getPrefBool(@"control.gesture_mouse");
    self.enableHotbarGestures = getPrefBool(@"control.gesture_hotbar");
    self.shouldTriggerHaptic = !getPrefBool(@"control.disable_haptics");

    self.scrollPanGesture.enabled = self.enableMouseGestures;
    self.doubleTapGesture.enabled = self.enableHotbarGestures;
    self.longPressGesture.minimumPressDuration = getPrefFloat(@"control.press_duration") / 1000.0;

    [self updateAudioSettings];
    [self updateSavedResolution];
    if (@available(iOS 16, tvOS 16, *)) {
        if ([self.surfaceView.layer isKindOfClass:CAMetalLayer.class]) {
            BOOL perfHUDEnabled = getPrefBool(@"video.performance_hud");
            ((CAMetalLayer *)self.surfaceView.layer).developerHUDProperties = perfHUDEnabled ? @{@"mode": @"default"} : nil;
        }
    }
    [self setNeedsUpdateOfPrefersPointerLocked];
}

- (void)updateSavedResolution {
    for (UIWindowScene *scene in UIApplication.sharedApplication.connectedScenes.allObjects) {
        self.screenScale = scene.screen.scale;
        if (scene.session.role != UIWindowSceneSessionRoleApplication) {
            break;
        }
    }

    if (self.surfaceView.superview != nil) {
        self.surfaceView.frame = self.surfaceView.superview.frame;
    }

    resolutionScale = getPrefFloat(@"video.resolution") / 100.0;
    self.surfaceView.layer.contentsScale = self.screenScale * resolutionScale;

    physicalWidth = roundf(self.surfaceView.frame.size.width * self.screenScale);
    physicalHeight = roundf(self.surfaceView.frame.size.height * self.screenScale);
    windowWidth = roundf(physicalWidth * resolutionScale);
    windowHeight = roundf(physicalHeight * resolutionScale);
    if ((windowWidth % 2) != 0) { --windowWidth; }
    if ((windowHeight % 2) != 0) { --windowHeight; }
    if ([self.surfaceView.layer isKindOfClass:CAMetalLayer.class]) {
        CAMetalLayer *metalLayer = (CAMetalLayer *)self.surfaceView.layer;
        metalLayer.drawableSize = CGSizeMake(MAX(windowWidth, 1), MAX(windowHeight, 1));
        // Unlock the frame rate (disable vertical sync): triple buffering.
        // With the default maximumDrawableCount (usually 2), when both drawables are waiting to be presented,
        // nextDrawable blocks until vblank releases one, indirectly locking the render thread to the refresh rate.
        // Setting it to 3 (triple buffering) means there is almost always a free drawable, so the render thread no longer stalls waiting for one,
        // and combined with VSync off the frame rate can exceed the screen refresh rate. This value is the standard setting for low-latency/high-throughput Metal rendering.
        // Note: this optimization matters most for GL-family renderers (presented via CAMetalLayer); Vulkan/MoltenVK manages its own swapchain.
        metalLayer.maximumDrawableCount = 3;

        // Explicitly set presentsWithTransaction=NO (the default value).
        // presentsWithTransaction=YES makes presentDrawable wait synchronously for the Core Animation transaction to commit,
        // which increases latency without improving the frame rate. Setting it to NO lets presentDrawable submit to Core Animation asynchronously,
        // so the render thread can immediately continue rendering the next frame, which together with eglSwapInterval(0) unlocks the frame rate.
        // This is the standard configuration for high-throughput Metal rendering.
        metalLayer.presentsWithTransaction = NO;

        // Make sure asynchronous drawing is enabled (GameSurfaceView.initWithFrame already sets it; this is a second confirmation)
        metalLayer.drawsAsynchronously = YES;

        // Log the Metal layer configuration (first time only), to help diagnose frame rate problems
        static BOOL s_loggedMetalConfig = NO;
        if (!s_loggedMetalConfig) {
            s_loggedMetalConfig = YES;
            NSLog(@"[SurfaceVC] CAMetalLayer configured: drawableSize=%.0fx%.0f, maximumDrawableCount=%ld, presentsWithTransaction=%d, drawsAsynchronously=%d, contentsScale=%.2f",
                  metalLayer.drawableSize.width, metalLayer.drawableSize.height,
                  (long)metalLayer.maximumDrawableCount,
                  metalLayer.presentsWithTransaction,
                  metalLayer.drawsAsynchronously,
                  metalLayer.contentsScale);
        }
    }
    CallbackBridge_nativeSendScreenSize(windowWidth, windowHeight);
}

- (void)updateControlHiddenState:(BOOL)hide {
    for (UIView *view in self.ctrlView.subviews) {
        ControlButton *button = (ControlButton *)view;
        if (!button.canBeHidden) continue;
        BOOL hidden = hide || !(
            (isGrabbing && [button.properties[@"displayInGame"] boolValue]) ||
            (!isGrabbing && [button.properties[@"displayInMenu"] boolValue]));
        if (!hidden && ![button isKindOfClass:ControlSubButton.class]) {
            button.hidden = hidden;
            if ([button isKindOfClass:ControlDrawer.class]) {
                [(ControlDrawer *)button restoreButtonVisibility];
            }
        } else if (hidden) {
            button.hidden = hidden;
        }
    }
}

- (void)updateGrabState {
    if (isGrabbing == JNI_TRUE) {
        CGFloat screenScale = self.surfaceView.layer.contentsScale;
        CallbackBridge_nativeSendCursorPos(ACTION_DOWN, lastVirtualMousePoint.x * screenScale, lastVirtualMousePoint.y * screenScale);
        virtualMouseFrame.origin.x = self.view.frame.size.width / 2;
        virtualMouseFrame.origin.y = self.view.frame.size.height / 2;
        self.mousePointerView.frame = virtualMouseFrame;
    }
    self.scrollPanGesture.enabled = !isGrabbing;
    self.mousePointerView.hidden = isGrabbing || !virtualMouseEnabled;
    [self setNeedsUpdateOfPrefersPointerLocked];
    [self updateControlHiddenState:NO];
}

- (void)launchMinecraft {
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        // Validate metadata first
        if (!self.metadata) {
            NSLog(@"[SurfaceViewController] Error: metadata is nil");
            dispatch_async(dispatch_get_main_queue(), ^{
                [self dismissLaunchOverlayOnError];
                showDialog(localize(@"Error", nil), @"æ¸¸æçæ®å è½½å¤±è´¥ï¼è¯·éæ°éæ©çæ¬");
            });
            return;
        }

        // Validate window dimensions
        if (windowWidth <= 0 || windowHeight <= 0) {
            NSLog(@"[SurfaceViewController] Error: invalid window size %dx%d", windowWidth, windowHeight);
            windowWidth = 1280;
            windowHeight = 720;
        }
        
        // Get Java version
        int minVersion = [self.metadata[@"javaVersion"][@"majorVersion"] intValue];
        if (minVersion == 0) {
            minVersion = [self.metadata[@"javaVersion"][@"version"] intValue];
        }
        if (minVersion == 0) {
            minVersion = 8; // Default to Java 8
        }
        
        // Validate authenticator
        BaseAuthenticator *currentAuth = BaseAuthenticator.current;
        if (!currentAuth) {
            NSLog(@"[SurfaceViewController] Error: no authenticator available");
            dispatch_async(dispatch_get_main_queue(), ^{
                [self dismissLaunchOverlayOnError];
                showDialog(localize(@"Error", nil), @"è¯·åç»å½è´¦æ·");
            });
            return;
        }
        
        // Validate accountId (used as the account file name, passed to the Java side to load the corresponding account)
        NSString *accountId = currentAuth.authData[@"accountId"];
        if (!accountId || accountId.length == 0) {
            // Fallback: in very rare cases accountId is missing (e.g. an old account that was not migrated), so fall back to username
            accountId = currentAuth.authData[@"username"];
            if (!accountId || accountId.length == 0) {
                accountId = @"Player";
            }
        }

        NSLog(@"[SurfaceViewController] Launching Minecraft with accountId: %@, version: %d, size: %dx%d",
              accountId, minVersion, windowWidth, windowHeight);

        // Launch JVM (args[0] carries accountId; the Java side loads the account with MinecraftAccount.load(accountId))
        int launchResult = launchJVM(accountId, self.metadata, windowWidth, windowHeight, minVersion);

        // JVM launch failed (non-zero return): remove the launch overlay so the user can see the error dialog
        // launchJVM calls showDialog internally to display the error on failure, so here we only clean up the overlay
        if (launchResult != 0) {
            NSLog(@"[SurfaceViewController] JVM launch failed with code %d", launchResult);
            dispatch_async(dispatch_get_main_queue(), ^{
                [self dismissLaunchOverlayOnError];
            });
        }
    });
}

#pragma mark - Phase 13/16: the launch overlay (modeled on the full-screen launch progress display of FCL/ZL2)

/// Create and show the launch overlay layer (refactored in the FCL/ZL2 style):
///
/// Design philosophy (modeled on FCL/ZalithLauncher2):
///   - The launch overlay is a purely visual layer and intercepts no touch events
///   - userInteractionEnabled = NO, so the gameMenuOverlay underneath (floating ball/FPS) stays interactive
///   - A dark gradient background plus a frosted glass effect creates an immersive launch experience
///   - A centered info card shows launch progress, stage, Java version, memory and renderer
///   - The cancel button at the bottom lets the user abort a stuck launch
///
/// Visual layout (top to bottom):
///   ┌─────────────────────────────────┐
///   │         Game icon (72pt)         │
///   │      Spinning indicator (Medium) │
///   │     "Launching Minecraft"        │
///   │      Current stage text          │
///   │   ━━━━━━━━━━━━━━━━ 45%          │
///   │         Elapsed 12s              │
///   │  ┌─────────────────────────┐    │
///   │  │ Java 17 │ 2048MB │ gl4es │    │
///   │  └─────────────────────────┘    │
///   │        [ Cancel launch ]         │
///   └─────────────────────────────────┘
- (void)setupLaunchOverlay {
    // ============================================================
    // FCL style launch screen: a spinner in the middle over the custom launcher background
    // ============================================================
    // Modeled on the launch/loading screen of FCL (FoldCraftLauncher):
    //   - The background shows the launcher's custom wallpaper (if any)
    //   - A large spinning loading indicator is shown in the exact center of the screen
    //   - A short title line is shown under the indicator (e.g. "Launching Minecraft")
    //   - No progress bar, percentage, stage text, info card or other superfluous elements are shown
    //   - A small "Cancel launch" button remains at the bottom
    //
    // The previous implementation included the icon, a progress bar, a percentage, elapsed time, an info card,
    // rotating stage text and many other elements, which was far too complex. FCL's design philosophy is simplicity:
    // the user only needs to know that "it is loading", not the detailed stage and progress.
    self.launchStartTime = [NSDate timeIntervalSinceReferenceDate];
    self.launchOverlayDismissed = NO;

    // ========================================================================
    // Full-screen overlay container
    // ========================================================================
    // userInteractionEnabled = NO: lets touches pass through to the gameMenuOverlay below,
    // so the user can drag the floating ball and check the FPS during launch.
    // The cancel button is added to self.view separately (so this setting does not affect it).
    self.launchOverlayView = [[UIView alloc] initWithFrame:self.view.bounds];
    self.launchOverlayView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    self.launchOverlayView.userInteractionEnabled = NO;
    [self.view addSubview:self.launchOverlayView];

    // ========================================================================
    // Background layer: shows the custom launcher background
    // ========================================================================
    // When a custom wallpaper exists: transparent overlay + a slight darkening mask (to improve text readability)
    // When there is no custom wallpaper: fall back to a dark gradient
    if ([[BackgroundManager sharedManager] hasBackground]) {
        // Custom background present: transparent overlay + a slight darkening mask
        self.launchOverlayView.backgroundColor = [UIColor clearColor];
        UIView *dimOverlay = [[UIView alloc] initWithFrame:self.launchOverlayView.bounds];
        dimOverlay.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        dimOverlay.backgroundColor = [[UIColor blackColor] colorWithAlphaComponent:0.3];
        dimOverlay.userInteractionEnabled = NO;
        [self.launchOverlayView addSubview:dimOverlay];
    } else {
        // No custom background: use a dark gradient
        CAGradientLayer *gradient = [CAGradientLayer layer];
        gradient.frame = self.launchOverlayView.bounds;
        gradient.colors = @[
            (__bridge id)[UIColor colorWithRed:0.08 green:0.09 blue:0.13 alpha:1.0].CGColor,
            (__bridge id)[UIColor colorWithRed:0.03 green:0.03 blue:0.05 alpha:1.0].CGColor,
        ];
        gradient.locations = @[@0.0, @1.0];
        gradient.startPoint = CGPointMake(0.5, 0.0);
        gradient.endPoint = CGPointMake(0.5, 1.0);
        [self.launchOverlayView.layer insertSublayer:gradient atIndex:0];
        self.launchGradientLayer = gradient;
    }

    // ========================================================================
    // Center content container (shows the spinner + title in the middle)
    // ========================================================================
    UIView *centerContainer = [[UIView alloc] init];
    centerContainer.translatesAutoresizingMaskIntoConstraints = NO;
    centerContainer.userInteractionEnabled = NO;
    [self.launchOverlayView addSubview:centerContainer];

    // Large spinning indicator (FCL style: a big spinner in the exact center of the screen)
    self.launchSpinner = [[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleLarge];
    self.launchSpinner.translatesAutoresizingMaskIntoConstraints = NO;
    self.launchSpinner.color = [UIColor whiteColor];
    [self.launchSpinner startAnimating];
    [centerContainer addSubview:self.launchSpinner];

    // Title text (under the spinner, a short hint)
    self.launchTitleLabel = [[UILabel alloc] init];
    self.launchTitleLabel.translatesAutoresizingMaskIntoConstraints = NO;
    self.launchTitleLabel.text = localize(@"launch.title", @"Starting Minecraft");
    self.launchTitleLabel.font = [UIFont systemFontOfSize:16 weight:UIFontWeightMedium];
    self.launchTitleLabel.textColor = [UIColor colorWithWhite:0.9 alpha:1.0];
    self.launchTitleLabel.textAlignment = NSTextAlignmentCenter;
    [centerContainer addSubview:self.launchTitleLabel];

    // ========================================================================
    // Cancel launch button (at the bottom, added to self.view separately so the overlay pass-through does not affect it)
    // ========================================================================
    self.launchCancelButton = [UIButton buttonWithType:UIButtonTypeSystem];
    self.launchCancelButton.translatesAutoresizingMaskIntoConstraints = NO;
    [self.launchCancelButton setTitle:localize(@"launch.cancel", @"Cancel launch") forState:UIControlStateNormal];
    [self.launchCancelButton setTitleColor:[UIColor colorWithWhite:0.7 alpha:1.0] forState:UIControlStateNormal];
    self.launchCancelButton.titleLabel.font = [UIFont systemFontOfSize:14];
    self.launchCancelButton.backgroundColor = [[UIColor whiteColor] colorWithAlphaComponent:0.1];
    self.launchCancelButton.layer.cornerRadius = 8;
    self.launchCancelButton.layer.cornerCurve = kCACornerCurveContinuous;
    [self.launchCancelButton addTarget:self action:@selector(cancelLaunch) forControlEvents:UIControlEventTouchUpInside];
    [self.view addSubview:self.launchCancelButton];

    // ========================================================================
    // Layout constraints
    // ========================================================================
    [NSLayoutConstraint activateConstraints:@[
        // Center container: horizontally and vertically centered
        [centerContainer.centerXAnchor constraintEqualToAnchor:self.launchOverlayView.centerXAnchor],
        [centerContainer.centerYAnchor constraintEqualToAnchor:self.launchOverlayView.centerYAnchor],

        // Spinning indicator: centered at the top of the container
        [self.launchSpinner.topAnchor constraintEqualToAnchor:centerContainer.topAnchor],
        [self.launchSpinner.centerXAnchor constraintEqualToAnchor:centerContainer.centerXAnchor],

        // Title: under the spinner
        [self.launchTitleLabel.topAnchor constraintEqualToAnchor:self.launchSpinner.bottomAnchor constant:16],
        [self.launchTitleLabel.leadingAnchor constraintEqualToAnchor:centerContainer.leadingAnchor],
        [self.launchTitleLabel.trailingAnchor constraintEqualToAnchor:centerContainer.trailingAnchor],
        [self.launchTitleLabel.bottomAnchor constraintEqualToAnchor:centerContainer.bottomAnchor],

        // Cancel button: above the bottom safe area
        [self.launchCancelButton.bottomAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.bottomAnchor constant:-24],
        [self.launchCancelButton.centerXAnchor constraintEqualToAnchor:self.view.centerXAnchor],
        [self.launchCancelButton.widthAnchor constraintEqualToConstant:120],
        [self.launchCancelButton.heightAnchor constraintEqualToConstant:36],
    ]];

    // Register for the first-frame-rendered notification (sent by pojavSwapBuffers in egl_bridge.m on its first call)
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(onFirstFrameRendered)
                                                 name:@"PojavFirstFrameRendered"
                                               object:nil];
}

/// Cancel launch: called when the user taps the "Cancel launch" button.
/// Terminates the JVM launch flow, removes the overlay and returns to the launcher main screen.
- (void)cancelLaunch {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:localize(@"launch.cancel_confirm_title", @"Cancel launch?")
                                                                   message:localize(@"launch.cancel_confirm_message", @"Cancelling will stop the game from loading and return you to the launcher.")
                                                            preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:localize(@"launch.cancel_confirm_yes", @"Yes, cancel")
                                              style:UIAlertActionStyleDestructive
                                            handler:^(UIAlertAction *action) {
        NSLog(@"[SurfaceViewController] User cancelled launch");
        // Remove the overlay layer
        [self dismissLaunchOverlayOnError];
        // Return to the launcher
        [[SurfaceViewController currentInstance].logOutputView dismissAndReturnToLauncher];
    }]];
    [alert addAction:[UIAlertAction actionWithTitle:localize(@"launch.cancel_confirm_no", @"Keep waiting")
                                              style:UIAlertActionStyleCancel
                                            handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
}

/// Timer callback (every 0.5 seconds):
/// 1. Compute the current stage index from the elapsed time (one stage every 2.5 seconds, avoiding static variables that would not reset between launches)
/// 2. Advance the progress bar (based on elapsed time, capped at 95%)
/// 3. Update the elapsed time display
- (void)updateLaunchStage {
    // The FCL style launch screen no longer needs stage rotation or progress advancement.
    // This method is kept as an empty implementation only for compatibility with possible old call sites (in fact setupLaunchOverlay
    // no longer creates launchStageTimer, so this method is never called).
}

/// First-frame-rendered notification callback: fade out and remove the launch overlay
- (void)onFirstFrameRendered {
    dispatch_async(dispatch_get_main_queue(), ^{
        if (self.launchOverlayDismissed) return;
        self.launchOverlayDismissed = YES;

        [self.launchSpinner stopAnimating];

        NSTimeInterval elapsed = [NSDate timeIntervalSinceReferenceDate] - self.launchStartTime;

        // Hide the cancel button (its fade-out animates together with the overlay)
        [self.launchCancelButton setHidden:YES];

        // Fade out and remove the overlay (FCL style: a simple fade transition)
        [UIView animateWithDuration:0.4
                              delay:0.1
                            options:UIViewAnimationOptionCurveEaseOut
                         animations:^{
            self.launchOverlayView.alpha = 0.0;
            self.launchCancelButton.alpha = 0.0;
        }
                         completion:^(BOOL finished) {
            [self.launchOverlayView removeFromSuperview];
            self.launchOverlayView = nil;
            self.launchGradientLayer = nil;
            [self.launchCancelButton removeFromSuperview];
            self.launchCancelButton = nil;
            [[NSNotificationCenter defaultCenter] removeObserver:self name:@"PojavFirstFrameRendered" object:nil];
            NSLog(@"[SurfaceViewController] Launch overlay dismissed after %.1f seconds", elapsed);
        }];
    });
}

/// Remove the overlay when launch fails (called from error paths such as JVM launch failure or empty metadata)
- (void)dismissLaunchOverlayOnError {
    dispatch_async(dispatch_get_main_queue(), ^{
        if (self.launchOverlayDismissed) return;
        self.launchOverlayDismissed = YES;

        [self.launchSpinner stopAnimating];
        [[NSNotificationCenter defaultCenter] removeObserver:self name:@"PojavFirstFrameRendered" object:nil];

        [self.launchOverlayView removeFromSuperview];
        self.launchOverlayView = nil;
        self.launchGradientLayer = nil;
        [self.launchCancelButton removeFromSuperview];
        self.launchCancelButton = nil;
        NSLog(@"[SurfaceViewController] Launch overlay dismissed due to launch error");
    });
}

- (void)loadCustomControls {
    self.edgeGesture.enabled = YES;
    [self.swipeableButtons removeAllObjects];
    NSString *controlFile = [PLProfiles resolveKeyForCurrentProfile:@"defaultTouchCtrl"];
    [self.ctrlView loadControlFile:controlFile];

    ControlButton *menuButton;
    for (ControlButton *button in self.ctrlView.subviews) {
        BOOL isSwipeable = [button.properties[@"isSwipeable"] boolValue];

        button.canBeHidden = YES;
        BOOL isMenuButton = NO;
        for (int i = 0; i < 4; i++) {
            int keycodeInt = [button.properties[@"keycodes"][i] intValue];
            button.canBeHidden &= keycodeInt != SPECIALBTN_TOGGLECTRL && keycodeInt != SPECIALBTN_VIRTUALMOUSE;
            if (keycodeInt == SPECIALBTN_MENU) {
                menuButton = button;
            }
        }

        [button addTarget:self action:@selector(executebtn_down:) forControlEvents:UIControlEventTouchDown];
        [button addTarget:self action:@selector(executebtn_up_inside:) forControlEvents:UIControlEventTouchUpInside];
        [button addTarget:self action:@selector(executebtn_up_outside:) forControlEvents:UIControlEventTouchUpOutside];

        if (isSwipeable) {
            UIPanGestureRecognizer *panRecognizerButton = [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(executebtn_swipe:)];
            panRecognizerButton.delegate = self;
            [button addGestureRecognizer:panRecognizerButton];
            [self.swipeableButtons addObject:button];
        }
    }

    [self updateControlHiddenState:self.toggleHidden];

    if (menuButton) {
        NSMutableArray *items = [NSMutableArray new];
        for (int i = 0; i < self.menuArray.count; i++) {
            UIAction *item = [UIAction actionWithTitle:localize(self.menuArray[i], nil) image:nil identifier:nil
                handler:^(id action) {[self didSelectMenuItem:i];}];
            [items addObject:item];
        }
        menuButton.menu = [UIMenu menuWithTitle:@"" image:nil identifier:nil
            options:UIMenuOptionsDisplayInline children:items];
        menuButton.showsMenuAsPrimaryAction = YES;
        self.edgeGesture.enabled = NO;
    }
}

- (void)viewWillTransitionToSize:(CGSize)size withTransitionCoordinator:(id<UIViewControllerTransitionCoordinator>)coordinator
{
    [coordinator animateAlongsideTransition:^(id<UIViewControllerTransitionCoordinatorContext>  _Nonnull context) {
        self.rootView.bounds = CGRectMake(0, 0, size.width + 30.0, size.height);

        CGRect frame = self.view.frame;
        frame.size = size;
        self.touchView.frame = frame;
        self.inputTextField.frame = CGRectMake(0, -32.0, size.width, 30.0);
        [self viewWillTransitionToSize_LogView:frame];
        [self viewWillTransitionToSize_Navigation:frame];
        self.ctrlView.frame = getSafeArea(self.view.frame);
        [self.ctrlView.subviews makeObjectsPerformSelector:@selector(update)];
        [self updateSavedResolution];
        [GyroInput updateOrientation];
    } completion:^(id<UIViewControllerTransitionCoordinatorContext>  _Nonnull context) {
        virtualMouseFrame = self.mousePointerView.frame;
    }];
    [super viewWillTransitionToSize:size withTransitionCoordinator:coordinator];
}

#pragma mark - Input: send touch utilities

- (BOOL)isTouchInactive:(UITouch *)touch {
    return touch == nil || touch.phase == UITouchPhaseEnded || touch.phase == UITouchPhaseCancelled;
}

- (void)sendTouchPoint:(CGPoint)location withEvent:(int)event
{
    CGFloat screenScale = self.screenScale;
    if (!isGrabbing) {
        screenScale *= resolutionScale;
        if (virtualMouseEnabled) {
            if (event == ACTION_MOVE) {
                virtualMouseFrame.origin.x += (location.x - lastVirtualMousePoint.x) * self.mouseSpeed;
                virtualMouseFrame.origin.y += (location.y - lastVirtualMousePoint.y) * self.mouseSpeed;
            } else if (event == ACTION_MOVE_MOTION) {
                event = ACTION_MOVE;
                virtualMouseFrame.origin.x += location.x * self.mouseSpeed;
                virtualMouseFrame.origin.y += location.y * self.mouseSpeed;
            }
            virtualMouseFrame.origin.x = clamp(virtualMouseFrame.origin.x, 0, self.surfaceView.frame.size.width);
            virtualMouseFrame.origin.y = clamp(virtualMouseFrame.origin.y, 0, self.surfaceView.frame.size.height);
            lastVirtualMousePoint = location;
            self.mousePointerView.frame = virtualMouseFrame;
            CallbackBridge_nativeSendCursorPos(event, virtualMouseFrame.origin.x * screenScale, virtualMouseFrame.origin.y * screenScale);
            return;
        }
        lastVirtualMousePoint = location;
    }
    CallbackBridge_nativeSendCursorPos(event, location.x * screenScale, location.y * screenScale);
}

#pragma mark - Input: on-surface functions

- (BOOL)gestureRecognizer:(UIGestureRecognizer *)gestureRecognizer shouldRecognizeSimultaneouslyWithGestureRecognizer:(UIGestureRecognizer *)otherGestureRecognizer {
    return YES;
}

- (void)keyboardGesture:(UIGestureRecognizer*)gestureRecognizer {
    // [ä¿®æ­£] æ·»å äºå¯¹è®¾ç½®é¡¹ control.two_finger_keyboard çæ£æ¥
    if (!getPrefBool(@"control.two_finger_keyboard")) {
        return;
    }

    if (gestureRecognizer.state == UIGestureRecognizerStateBegan) {
        if (self.inputTextField.isFirstResponder) {
            [self.inputTextField resignFirstResponder];
            self.inputTextField.alpha = 1.0f;
        } else {
            [self.inputTextField becomeFirstResponder];
            self.inputTextField.text = @" ";
        }
    }
}

- (void)sendTouchEvent:(UITouch *)touchEvent withUIEvent:(UIEvent *)uievent withEvent:(int)event
{
    CGPoint locationInView = [touchEvent locationInView:self.rootView];
    switch (event) {
        case ACTION_DOWN:
            self.clickRange = CGRectMake(locationInView.x - 2, locationInView.y - 2, 5, 5);
            self.shouldTriggerClick = YES;
            break;
        case ACTION_MOVE:
            if (self.shouldTriggerClick && !CGRectContainsPoint(self.clickRange, locationInView)) {
                self.shouldTriggerClick = NO;
            }
            break;
    }

    if (touchEvent == self.hotbarTouch && self.slideableHotbar && ![self isTouchInactive:self.hotbarTouch]) {
        CGFloat screenScale = [[UIScreen mainScreen] scale];
        int slot = self.enableHotbarGestures ?
        callback_SurfaceViewController_touchHotbar(locationInView.x * screenScale, locationInView.y * screenScale) : -1;
        if (slot != -1 && currentHotbarSlot != slot && (event == ACTION_DOWN || currentHotbarSlot != -1)) {
            currentHotbarSlot = slot;
            CallbackBridge_nativeSendKey(slot, 0, 1, 0);
            CallbackBridge_nativeSendKey(slot, 0, 0, 0);
            return;
        }
        if (event == ACTION_DOWN && slot == -1) {
            currentHotbarSlot = -1;
        }
        return;
    }

    if (touchEvent == self.primaryTouch) {
        if ([self isTouchInactive:self.primaryTouch] && event != ACTION_UP) return; 
        if (event == ACTION_MOVE && isGrabbing) {
            event = ACTION_MOVE_MOTION;
            CGPoint prevLocationInView = [touchEvent previousLocationInView:self.rootView];
            locationInView.x -= prevLocationInView.x;
            locationInView.y -= prevLocationInView.y;
        }
        [self sendTouchPoint:locationInView withEvent:event];
    }
}

- (void)pressesBegan:(NSSet<UIPress *> *)presses withEvent:(UIPressesEvent *)event {
    for (UIPress *press in presses) {
        if (press.key != nil) {
            [KeyboardInput sendKeyEvent:press.key down:YES];
        }
    }
    // Always call super so that inputTextField (UITextInput) can receive
    // key events for text input (e.g., Minecraft chat).
    [super pressesBegan:presses withEvent:event];
}

- (void)pressesEnded:(NSSet<UIPress *> *)presses withEvent:(UIPressesEvent *)event {
    for (UIPress *press in presses) {
        if (press.key != nil) {
            [KeyboardInput sendKeyEvent:press.key down:NO];
        }
    }
    // Always call super so that inputTextField (UITextInput) can receive
    // key-up events properly.
    [super pressesEnded:presses withEvent:event];
}

- (BOOL)prefersPointerLocked {
    return GCMouse.mice.count > 0 && (isGrabbing || virtualMouseEnabled);
}

- (void)registerMouseCallbacks:(GCMouse *)mouse {
    NSLog(@"Input: Got mouse %@", mouse);
    mouse.mouseInput.mouseMovedHandler = ^(GCMouseInput * _Nonnull mouse, float deltaX, float deltaY) {
        // Always forward mouse movement to the game.
        // When pointer is locked (in-game grabbing), deltaX/deltaY are true deltas.
        // When pointer is NOT locked (menu, or Bluetooth mouse before lock activates),
        // we still send the delta so the virtual mouse or cursor can move.
        [self sendTouchPoint:CGPointMake(deltaX, -deltaY) withEvent:ACTION_MOVE_MOTION];
    };

    mouse.mouseInput.leftButton.pressedChangedHandler = ^(GCControllerButtonInput * _Nonnull button, float value, BOOL pressed) {
        CallbackBridge_nativeSendMouseButton(GLFW_MOUSE_BUTTON_LEFT, pressed, 0);
    };
    mouse.mouseInput.middleButton.pressedChangedHandler = ^(GCControllerButtonInput * _Nonnull button, float value, BOOL pressed) {
        CallbackBridge_nativeSendMouseButton(GLFW_MOUSE_BUTTON_MIDDLE, pressed, 0);
    };
    mouse.mouseInput.rightButton.pressedChangedHandler = ^(GCControllerButtonInput * _Nonnull button, float value, BOOL pressed) {
        CallbackBridge_nativeSendMouseButton(GLFW_MOUSE_BUTTON_RIGHT, pressed, 0);
    };
    for (int i = 0; i < MIN(mouse.mouseInput.auxiliaryButtons.count, 5); i++) {
        mouse.mouseInput.auxiliaryButtons[i].pressedChangedHandler = ^(GCControllerButtonInput * _Nonnull button, float value, BOOL pressed) {
            CallbackBridge_nativeSendMouseButton(GLFW_MOUSE_BUTTON_4 + i, pressed, 0);
        };
    }

    mouse.mouseInput.scroll.xAxis.valueChangedHandler = ^(GCControllerAxisInput * _Nonnull axis, float value) {
        CallbackBridge_nativeSendScroll(value, value);
    };
    mouse.mouseInput.scroll.yAxis.valueChangedHandler = ^(GCControllerAxisInput * _Nonnull axis, float value) {
        CallbackBridge_nativeSendScroll(-value, -value);
    };

    if (getPrefBool(@"control.hardware_hide")) {
        self.ctrlView.hidden = YES;
    }
}

- (void)surfaceOnClick:(UITapGestureRecognizer *)sender {
    if (sender.state == UIGestureRecognizerStateBegan || sender.state == UIGestureRecognizerStateEnded){
        if(self.shouldTriggerHaptic) {
            [self.lightHaptic impactOccurred];
        }
    }
    if (!self.shouldTriggerClick) return;

    if (sender.state == UIGestureRecognizerStateRecognized) {
        if (currentHotbarSlot == -1) {
            if (!self.enableMouseGestures) return;
            CallbackBridge_nativeSendMouseButton(isGrabbing == JNI_TRUE ?
                GLFW_MOUSE_BUTTON_RIGHT : GLFW_MOUSE_BUTTON_LEFT, 1, 0);
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 33 * NSEC_PER_MSEC), dispatch_get_main_queue(), ^{
                CallbackBridge_nativeSendMouseButton(isGrabbing == JNI_TRUE ?
                    GLFW_MOUSE_BUTTON_RIGHT : GLFW_MOUSE_BUTTON_LEFT, 0, 0);
            });
        } else {
            CallbackBridge_nativeSendKey(currentHotbarSlot, 0, 1, 0);
            CallbackBridge_nativeSendKey(currentHotbarSlot, 0, 0, 0);
        }
    }
}

- (void)surfaceOnDoubleClick:(UITapGestureRecognizer *)sender {
    if (sender.state == UIGestureRecognizerStateBegan || sender.state == UIGestureRecognizerStateEnded){
        if(self.shouldTriggerHaptic) {
            [self.lightHaptic impactOccurred];
        }
    }
    if (sender.state == UIGestureRecognizerStateRecognized && isGrabbing) {
        CGFloat screenScale = [[UIScreen mainScreen] scale];
        CGPoint point = [sender locationInView:self.rootView];
        int hotbarSlot = self.enableHotbarGestures ?
            callback_SurfaceViewController_touchHotbar(point.x * screenScale, point.y * screenScale) : -1;
        if (hotbarSlot != -1 && currentHotbarSlot == hotbarSlot) {
            CallbackBridge_nativeSendKey(GLFW_KEY_F, 0, 1, 0);
            CallbackBridge_nativeSendKey(GLFW_KEY_F, 0, 0, 0);
        }
    }
}

- (void)surfaceOnHover:(UIGestureRecognizer *)sender {
    if (isGrabbing) return;
    CGPoint point = [sender locationInView:self.rootView];
    switch (sender.state) {
        case UIGestureRecognizerStateBegan:
            [self sendTouchPoint:point withEvent:ACTION_DOWN];
            break;
        case UIGestureRecognizerStateChanged:
            [self sendTouchPoint:point withEvent:ACTION_MOVE];
            break;
        case UIGestureRecognizerStateEnded:
        case UIGestureRecognizerStateCancelled:
            [self sendTouchPoint:point withEvent:ACTION_UP];
            break;
        default:
            break;
    }
}

-(void)surfaceOnLongpress:(UILongPressGestureRecognizer *)sender
{
    if (sender.state == UIGestureRecognizerStateBegan || sender.state == UIGestureRecognizerStateEnded){
        if(self.shouldTriggerHaptic) {
            [self.mediumHaptic impactOccurred];
        }
    }

    if (!self.slideableHotbar) {
        CGPoint location = [sender locationInView:self.rootView];
        CGFloat screenScale = UIScreen.mainScreen.scale;
        currentHotbarSlot = self.enableHotbarGestures ?
            callback_SurfaceViewController_touchHotbar(location.x * screenScale, location.y * screenScale) : -1;
    }
    if (sender.state == UIGestureRecognizerStateBegan) {
        self.shouldTriggerClick = NO;
        if (currentHotbarSlot == -1) {

            if (self.enableMouseGestures)
                CallbackBridge_nativeSendMouseButton(GLFW_MOUSE_BUTTON_LEFT, 1, 0);
        } else {
            CallbackBridge_nativeSendKey(GLFW_KEY_Q, 0, 1, 0);
        }
    } else if (sender.state == UIGestureRecognizerStateChanged) {
    } else if (sender.state == UIGestureRecognizerStateCancelled
        || sender.state == UIGestureRecognizerStateFailed
            || sender.state == UIGestureRecognizerStateEnded)
    {
        if (currentHotbarSlot == -1) {
            if (self.enableMouseGestures)
                CallbackBridge_nativeSendMouseButton(GLFW_MOUSE_BUTTON_LEFT, 0, 0);
        } else {
            CallbackBridge_nativeSendKey(GLFW_KEY_Q, 0, 0, 0);
        }
    }
}

- (void)surfaceOnTouchesScroll:(UIPanGestureRecognizer *)sender {
    if (sender.state == UIGestureRecognizerStateBegan || sender.state == UIGestureRecognizerStateEnded){
        if(self.shouldTriggerHaptic) {
            [self.lightHaptic impactOccurred];
        }
    }

    if (isGrabbing) return;
    if (sender.state == UIGestureRecognizerStateBegan ||
        sender.state == UIGestureRecognizerStateChanged ||
        sender.state == UIGestureRecognizerStateEnded) {
        CGPoint velocity = [sender velocityInView:self.rootView];
        if (velocity.x != 0.0f || velocity.y != 0.0f) {
            CallbackBridge_nativeSendScroll(velocity.x/self.view.frame.size.width, velocity.y/self.view.frame.size.height);
        }
    }
}

#pragma mark - Input view stuff

-(BOOL)textFieldShouldReturn:(UITextField *)textField {
    CallbackBridge_nativeSendKey(GLFW_KEY_ENTER, 0, 1, 0);
    CallbackBridge_nativeSendKey(GLFW_KEY_ENTER, 0, 0, 0);
    textField.text = @" ";
    return YES;
}

#pragma mark - On-screen button functions

- (void)executebtn:(ControlButton *)sender withAction:(int)action {
    int held = action == ACTION_DOWN;
    for (int i = 0; i < 4; i++) {
        int keycode = ((NSNumber *)sender.properties[@"keycodes"][i]).intValue;
        if (keycode < 0) {
            switch (keycode) {
                case SPECIALBTN_KEYBOARD:
                    if (held == 0) {
                        if (self.inputTextField.isFirstResponder) {
                            [self.inputTextField resignFirstResponder];
                            self.inputTextField.alpha = 1.0f;
                        } else {
                            [self.inputTextField becomeFirstResponder];
                            self.inputTextField.text = @" ";
                        }
                    }
                    break;
                case SPECIALBTN_MOUSEPRI:
                    CallbackBridge_nativeSendMouseButton(GLFW_MOUSE_BUTTON_LEFT, held, 0);
                    break;
                case SPECIALBTN_MOUSESEC:
                    CallbackBridge_nativeSendMouseButton(GLFW_MOUSE_BUTTON_RIGHT, held, 0);
                    break;
                case SPECIALBTN_MOUSEMID:
                    CallbackBridge_nativeSendMouseButton(GLFW_MOUSE_BUTTON_MIDDLE, held, 0);
                    break;
                case SPECIALBTN_TOGGLECTRL:
                    [self executebtn_special_togglebtn:held];
                    break;
                case SPECIALBTN_SCROLLDOWN:
                    if (!held) { CallbackBridge_nativeSendScroll(0.0, 1.0); }
                    break;
                case SPECIALBTN_SCROLLUP:
                    if (!held) { CallbackBridge_nativeSendScroll(0.0, -1.0); }
                    break;
                case SPECIALBTN_VIRTUALMOUSE:
                    if (!isGrabbing && !held) {
                        virtualMouseEnabled = !virtualMouseEnabled;
                        self.mousePointerView.hidden = !virtualMouseEnabled;
                        setPrefBool(@"control.virtmouse_enable", virtualMouseEnabled);
                        [self setNeedsUpdateOfPrefersPointerLocked];
                    }
                    break;
                case SPECIALBTN_MENU:
                    if (!held) { [self actionOpenNavigationMenu]; }
                    break;
                default:
                    NSLog(@"Warning: button %@ sent unknown special keycode: %d", sender.titleLabel.text, keycode);
                    break;
            }
        } else if (keycode > 0) {
            CallbackBridge_nativeSendKey(keycode, 0, held, 0);
        }
    }
}

- (void)executebtn_down:(ControlButton *)sender
{
    if(self.shouldTriggerHaptic) { [self.lightHaptic impactOccurred]; }
    if (sender.savedBackgroundColor == nil) { [self executebtn:sender withAction:ACTION_DOWN]; }
    if ([self.swipeableButtons containsObject:sender]) { self.swipingButton = sender; }
}

- (void)executebtn_swipe:(UIPanGestureRecognizer *)sender
{
    if (sender.state == UIGestureRecognizerStateCancelled || sender.state == UIGestureRecognizerStateEnded) {
        [self executebtn_up:self.swipingButton isOutside:NO];
        return;
    }
    CGPoint location = [sender locationInView:self.ctrlView];
    for (ControlButton *button in self.swipeableButtons) {
        if (CGRectContainsPoint(button.frame, location) && (ControlButton *)self.swipingButton != button) {
            [self executebtn_up:self.swipingButton isOutside:NO];
            self.swipingButton = (ControlButton *)button;
            [self executebtn:self.swipingButton withAction:ACTION_DOWN];
            break;
        }
    }
}

- (void)executebtn_up:(ControlButton *)sender isOutside:(BOOL)isOutside
{
    if (self.swipingButton == sender) {
        [self executebtn:self.swipingButton withAction:ACTION_UP];
        self.swipingButton = nil;
    } else if (sender.savedBackgroundColor == nil) {
        [self executebtn:sender withAction:ACTION_UP];
        return;
    }

    if (isOutside || sender.savedBackgroundColor == nil) { return; }

    sender.isToggleOn = !sender.isToggleOn;
    if (sender.isToggleOn) {
        sender.backgroundColor = [self.view.tintColor colorWithAlphaComponent:CGColorGetAlpha(sender.savedBackgroundColor.CGColor)];
        [self executebtn:sender withAction:ACTION_DOWN];
    } else {
        sender.backgroundColor = sender.savedBackgroundColor;
        [self executebtn:sender withAction:ACTION_UP];
    }

    if(self.shouldTriggerHaptic) { [self.lightHaptic impactOccurred]; }
}

- (void)executebtn_up_inside:(ControlButton *)sender { [self executebtn_up:sender isOutside:NO]; }
- (void)executebtn_up_outside:(ControlButton *)sender { [self executebtn_up:sender isOutside:YES]; }

- (void)executebtn_special_togglebtn:(int)held {
    if (held) return;
    self.toggleHidden = !self.toggleHidden;
    [self updateControlHiddenState:self.toggleHidden];
}

#pragma mark - Input: On-screen touch events (TouchController Mod Integration)

static int32_t s_fingerIdCounter = 0;
static NSMutableDictionary *s_touchToFingerIdMap = nil;

- (int32_t)getFingerId:(UITouch *)touch {
    // Lazy initialize the map
    if (!s_touchToFingerIdMap) {
        s_touchToFingerIdMap = [NSMutableDictionary dictionary];
    }
    
    // Use touch pointer address as key (UITouch doesn't support NSCopying)
    NSString *touchKey = [NSString stringWithFormat:@"%p", touch];
    
    // Check if we already have a finger ID for this touch
    NSNumber *fingerIdNum = [s_touchToFingerIdMap objectForKey:touchKey];
    if (fingerIdNum) {
        return [fingerIdNum intValue];
    }
    
    // Generate a new unique finger ID
    s_fingerIdCounter = (s_fingerIdCounter + 1) % 100000;
    int32_t newFingerId = s_fingerIdCounter;
    
    // Store the mapping
    [s_touchToFingerIdMap setObject:@(newFingerId) forKey:touchKey];
    
    return newFingerId;
}

// Clear the touch to finger ID map when touches end
- (void)clearTouchToFingerIdMapForTouches:(NSSet *)touches {
    if (!s_touchToFingerIdMap) return;
    
    for (UITouch *touch in touches) {
        NSString *touchKey = [NSString stringWithFormat:@"%p", touch];
        [s_touchToFingerIdMap removeObjectForKey:touchKey];
    }
}

// Clear all touch to finger ID mappings
- (void)clearAllTouchToFingerIdMappings {
    if (s_touchToFingerIdMap) {
        [s_touchToFingerIdMap removeAllObjects];
    }
}

- (void)touchesBegan:(NSSet *)touches withEvent:(UIEvent *)event
{

    [super touchesBegan:touches withEvent:event];

    if (getPrefBool(@"control.mod_touch_enable")) {
        NSInteger mode = [getPrefObject(@"control.mod_touch_mode") integerValue];

        if (mode == 1) {  // UDP æ¨¡å¼
            for (UITouch *touch in touches) {
                if (touch.view != self.surfaceView) continue;

                CGPoint p = [touch locationInView:self.surfaceView];
                float x = p.x / self.surfaceView.frame.size.width;
                float y = p.y / self.surfaceView.frame.size.height;
                // Send Type 1 (Add Pointer)
                [self.touchSender sendType:1 id:[self getFingerId:touch] x:x y:y];
            }
        } else if (mode == 2) {  // éæåºæ¨¡å¼
            for (UITouch *touch in touches) {
                if (touch.view != self.surfaceView) continue;

                CGPoint p = [touch locationInView:self.surfaceView];
                float x = p.x / self.surfaceView.frame.size.width;
                float y = p.y / self.surfaceView.frame.size.height;
                // Send ProxyMessage: AddPointerMessage
                [self sendTouchControllerProxyMessage:[self getFingerId:touch] x:x y:y isRemove:NO];
            }
        }

        if (isGrabbing == JNI_TRUE) return;
    }


    for (UITouch *touch in touches) {
        if (touch.type == UITouchTypeIndirectPointer) continue;
        CGPoint locationInView = [touch locationInView:self.rootView];
        CGFloat screenScale = [[UIScreen mainScreen] scale];
        currentHotbarSlot = self.enableHotbarGestures ?
            callback_SurfaceViewController_touchHotbar(locationInView.x * screenScale, locationInView.y * screenScale) : -1;
        if ([self isTouchInactive:self.hotbarTouch] && currentHotbarSlot != -1) {
            self.hotbarTouch = touch;
        }
        if ([self isTouchInactive:self.primaryTouch] && currentHotbarSlot == -1) {
            self.primaryTouch = touch;
        }
        [self sendTouchEvent:touch withUIEvent:event withEvent:ACTION_DOWN];
    }
}

- (void)touchesMoved:(NSSet *)touches withEvent:(UIEvent *)event
{
    if (getPrefBool(@"control.mod_touch_enable")) {
        NSInteger mode = [getPrefObject(@"control.mod_touch_mode") integerValue];

        if (mode == 1) {  // UDP æ¨¡å¼
            for (UITouch *touch in touches) {
                if (touch.view != self.surfaceView) continue;

                CGPoint p = [touch locationInView:self.surfaceView];
                float x = p.x / self.surfaceView.frame.size.width;
                float y = p.y / self.surfaceView.frame.size.height;
                // Send Type 1 (Move Pointer)
                [self.touchSender sendType:1 id:[self getFingerId:touch] x:x y:y];
            }
        } else if (mode == 2) {  // éæåºæ¨¡å¼
            for (UITouch *touch in touches) {
                if (touch.view != self.surfaceView) continue;

                CGPoint p = [touch locationInView:self.surfaceView];
                float x = p.x / self.surfaceView.frame.size.width;
                float y = p.y / self.surfaceView.frame.size.height;
                // Send ProxyMessage: AddPointerMessage (Move is also Add with new position)
                [self sendTouchControllerProxyMessage:[self getFingerId:touch] x:x y:y isRemove:NO];
            }
        }

        if (isGrabbing == JNI_TRUE) return;
    }

    [super touchesMoved:touches withEvent:event];

    for (UITouch *touch in touches) {
        if (touch.type == UITouchTypeIndirectPointer) {
            if (!isGrabbing && !virtualMouseEnabled) {
                CGPoint point = [touch locationInView:self.rootView];
                [self sendTouchPoint:point withEvent:ACTION_MOVE];
            }
            continue;
        }
        if (self.hotbarTouch != touch && [self isTouchInactive:self.primaryTouch]) {
            self.primaryTouch = touch;
            [self sendTouchEvent:touch withUIEvent:event withEvent:ACTION_DOWN];
        }
        [self sendTouchEvent:touch withUIEvent:event withEvent:ACTION_MOVE];
    }
}

- (void)touchesEnded:(NSSet *)touches withEvent:(UIEvent *)event
{
    if (getPrefBool(@"control.mod_touch_enable")) {
        NSInteger mode = [getPrefObject(@"control.mod_touch_mode") integerValue];

        if (mode == 1) {  // UDP æ¨¡å¼
            for (UITouch *touch in touches) {
                if (touch.view != self.surfaceView) continue;
                // Send Type 2 (Remove Pointer) for surfaceView touch ending
                [self.touchSender sendType:2 id:[self getFingerId:touch] x:0 y:0];
            }
        } else if (mode == 2) {  // éæåºæ¨¡å¼
            for (UITouch *touch in touches) {
                if (touch.view != self.surfaceView) continue;
                // Send ProxyMessage: RemovePointerMessage
                [self sendTouchControllerProxyMessage:[self getFingerId:touch] x:0 y:0 isRemove:YES];
            }
        }

        // Clear the touch to finger ID map for ended touches
        [self clearTouchToFingerIdMapForTouches:touches];

        if (isGrabbing == JNI_TRUE) return;
    }

    [super touchesEnded:touches withEvent:event];
    [self touchesEndedGlobal:touches withEvent:event];
}

- (void)touchesCancelled:(NSSet *)touches withEvent:(UIEvent *)event
{
    if (getPrefBool(@"control.mod_touch_enable")) {
        NSInteger mode = [getPrefObject(@"control.mod_touch_mode") integerValue];

        if (mode == 1) {  // UDP æ¨¡å¼
            for (UITouch *touch in touches) {
                if (touch.view != self.surfaceView) continue;
                [self.touchSender sendType:2 id:[self getFingerId:touch] x:0 y:0];
            }
        } else if (mode == 2) {  // éæåºæ¨¡å¼
            for (UITouch *touch in touches) {
                if (touch.view != self.surfaceView) continue;
                [self sendTouchControllerProxyMessage:[self getFingerId:touch] x:0 y:0 isRemove:YES];
            }
        }

        // Clear the touch to finger ID map for cancelled touches
        [self clearTouchToFingerIdMapForTouches:touches];

        if (isGrabbing == JNI_TRUE) return;
    }

    [super touchesCancelled:touches withEvent:event];
    [self touchesEndedGlobal:touches withEvent:event];
}

- (void)touchesEndedGlobal:(NSSet *)touches withEvent:(UIEvent *)event
{
    for (UITouch *touch in touches) {
        if (touch.type == UITouchTypeIndirectPointer) {
            continue;
        }
        [self sendTouchEvent:touch withUIEvent:event withEvent:ACTION_UP];
    }
}

+ (BOOL)isRunning {
    return [self currentInstance] != nil;
}

+ (instancetype)currentInstance {
    UIViewController *rootVC = UIWindow.mainWindow.rootViewController;
    // Case 1: the rootViewController is the SurfaceViewController itself
    if ([rootVC isKindOfClass:[SurfaceViewController class]]) {
        return (SurfaceViewController *)rootVC;
    }
    // Case 2: the SurfaceViewController is presented modally
    UIViewController *presentedVC = rootVC.presentedViewController;
    if ([presentedVC isKindOfClass:[SurfaceViewController class]]) {
        return (SurfaceViewController *)presentedVC;
    }
    return nil;
}

+ (GameSurfaceView *)surface {
    return pojavWindow;
}

#pragma mark - FPS/memory monitoring (modeled on FCL egl_bridge.c and ZL2 MemoryUtils.kt)

- (void)updateGameStats {
    // 1. Read and reset the native swap buffer counter (modeled on FCL CallbackBridge.getFps())
    // pojavGetAndResetFps() returns the number of frames rendered since the last call
    // The sampling interval is 1 second (statsTimer has been changed to 1s), so the return value is the FPS
    NSInteger fps = (NSInteger)pojavGetAndResetFps();

    // 2. Get the memory usage (phys_footprint)
    // Uses the phys_footprint field of task_vm_info, the most accurate process memory usage metric on iOS
    // It includes resident memory, compressed memory and GPU memory (on the UMA architecture), matching the Xcode memory gauge
    // Modeled on the system-level memory statistics idea of ZL2 MemoryUtils.kt, with phys_footprint as the iOS equivalent
    double memoryMB = [self currentPhysFootprintMB];

    // 3. Update the UI (GameMenuOverlayView dispatches to the main thread internally)
    if ([self.gameMenuOverlay isKindOfClass:[GameMenuOverlayView class]]) {
        [(GameMenuOverlayView *)self.gameMenuOverlay updateFPS:fps memoryUsageMB:memoryMB];
    }
}

- (double)currentPhysFootprintMB {
    // Read phys_footprint using the TASK_VM_INFO flavor
    // phys_footprint is Apple's recommended process memory usage metric, and includes:
    // - Resident physical memory (resident_size)
    // - Compressed memory
    // - GPU memory (on the iOS UMA architecture, Metal buffers are mapped into the process address space)
    // minus the portion shared via mmap, which matches the value shown by Xcode/Memory Graph
    task_vm_info_data_t vmInfo;
    mach_msg_type_number_t count = TASK_VM_INFO_COUNT;
    kern_return_t kr = task_info(mach_task_self(), TASK_VM_INFO,
                                 (task_info_t)&vmInfo, &count);
    if (kr != KERN_SUCCESS) {
        return 0.0;
    }
    // phys_footprint is measured in bytes
    return (double)vmInfo.phys_footprint / (1024.0 * 1024.0);
}

- (void)dealloc {
    // Stop the FPS/memory sampling timer and the render loop
    [self.statsTimer invalidate];
    self.statsTimer = nil;
    [self.statsDisplayLink invalidate];
    self.statsDisplayLink = nil;
    self.statsDisplayLinkTarget = nil;  // Release the CADisplayLink target

    // Clean up launch overlay resources
    [[NSNotificationCenter defaultCenter] removeObserver:self name:@"PojavFirstFrameRendered" object:nil];
    self.launchOverlayView = nil;
    self.launchGradientLayer = nil;

    // Key fix (accumulating UI anomaly): remove the 5 block-based notification observers.
    // Previously only PojavFirstFrameRendered was removed and the following 5 block observers were not,
    // which leaked 5 observers plus 5 strong references to self every time the game was entered and exited;
    // after several rounds, multiple "deallocated" view controllers would all receive the notification and manipulate the UI, causing erratic UI behavior.
    // Block observers must be removed explicitly via removeObserver: (removeObserver:self does not work).
    id defaultCenter = [NSNotificationCenter defaultCenter];
    if (self.mousePointerUpdatedCallback) {
        [defaultCenter removeObserver:self.mousePointerUpdatedCallback];
        self.mousePointerUpdatedCallback = nil;
    }
    if (self.mouseConnectCallback) {
        [defaultCenter removeObserver:self.mouseConnectCallback];
        self.mouseConnectCallback = nil;
    }
    if (self.mouseDisconnectCallback) {
        [defaultCenter removeObserver:self.mouseDisconnectCallback];
        self.mouseDisconnectCallback = nil;
    }
    if (self.controllerConnectCallback) {
        [defaultCenter removeObserver:self.controllerConnectCallback];
        self.controllerConnectCallback = nil;
    }
    if (self.controllerDisconnectCallback) {
        [defaultCenter removeObserver:self.controllerDisconnectCallback];
        self.controllerDisconnectCallback = nil;
    }

    // The LAN port detector has been switched to manual input mode and stopDetecting has been removed, so there is nothing to call.
    // ZeroTier/Terracotta multiplayer temporarily removed: the original stopAllMultiplayerServices call is commented out
    // [[MultiplayerManager sharedManager] stopAllMultiplayerServices];

    //æ¸ç TouchController èµæº
    if (self.touchControllerTransportHandle >= 0) {
        [TouchControllerBridge destroyTransport:self.touchControllerTransportHandle];
        self.touchControllerTransportHandle = -1;
    }
}

@end
