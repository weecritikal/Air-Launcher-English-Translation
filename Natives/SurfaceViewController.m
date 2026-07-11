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
#import "GameMenuOverlayView.h"
#import "TrackedTextField.h"
#import "TouchControllerBridge.h"
#import "UIKit+hook.h"
#import "ios_uikit_bridge.h"
#import "LanPortDetector.h"
#import "BackgroundManager.h"

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

// --- [START] TouchController Static Library Support ---
// ProxyMessage ç±»åå®ä¹ (åè TouchController-iOSTest)
#define PROXY_MESSAGE_TYPE_ADD_POINTER 1
#define PROXY_MESSAGE_TYPE_REMOVE_POINTER 2
#define PROXY_MESSAGE_TYPE_CLEAR_POINTER 3
#define PROXY_MESSAGE_TYPE_VIBRATE 4
#define PROXY_MESSAGE_TYPE_INPUT_STATUS 7
#define PROXY_MESSAGE_TYPE_INPUT_CURSOR 9
#define PROXY_MESSAGE_TYPE_INPUT_AREA 11
#define PROXY_MESSAGE_TYPE_MOVE_VIEW 12

// Vibrate ç±»å
#define VIBRATE_KIND_BLOCK_BROKEN 0

// --- [END] TouchController Static Library Support ---

int memorystatus_control(uint32_t command, int32_t pid, uint32_t flags, void *buffer, size_t buffersize);
#define MEMORYSTATUS_CMD_SET_JETSAM_TASK_LIMIT        6

static int currentHotbarSlot = -1;
static GameSurfaceView* pojavWindow;

@interface SurfaceViewController ()<UITextFieldDelegate, UIGestureRecognizerDelegate> {
}

// FPS/内存监控相关（FPS 在 native pojavSwapBuffers 中计数，参照 FCL/ZL2）
@property(nonatomic) NSTimer *statsTimer;                 // 低频定时器，1s 一次
@property(nonatomic) CADisplayLink *statsDisplayLink;     // 渲染循环引用（用于 Gyro/Controller tick 和失效）

@property(nonatomic) NSDictionary* metadata;
@property(nonatomic) TrackedTextField *inputTextField;
@property(nonatomic) NSMutableArray* swipeableButtons;
@property(nonatomic) ControlButton* swipingButton;
@property(nonatomic) UITouch *primaryTouch, *hotbarTouch;

@property(nonatomic) UILongPressGestureRecognizer* longPressGesture, *longPressTwoGesture;
@property(nonatomic) UITapGestureRecognizer *tapGesture, *doubleTapGesture;

@property(nonatomic) id mouseConnectCallback, mouseDisconnectCallback;
@property(nonatomic) id controllerConnectCallback, controllerDisconnectCallback;

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

// 阶段13/16：启动遮罩层（参照 FCL/ZL2 的启动进度显示，JVM 启动到首帧渲染期间显示）
@property(nonatomic, strong) UIView *launchOverlayView;
@property(nonatomic, strong) CAGradientLayer *launchGradientLayer;
@property(nonatomic, strong) UIImageView *launchIconView;
@property(nonatomic, strong) UIActivityIndicatorView *launchSpinner;
@property(nonatomic, strong) UILabel *launchTitleLabel;
@property(nonatomic, strong) UILabel *launchStageLabel;
@property(nonatomic, strong) UIProgressView *launchProgressBar;
@property(nonatomic, strong) UILabel *launchElapsedTimeLabel;
@property(nonatomic, strong) NSTimer *launchStageTimer;
@property(nonatomic, assign) NSTimeInterval launchStartTime;
@property(nonatomic, strong) NSArray<NSString *> *launchStages;
@property(nonatomic, assign) NSInteger currentStageIndex;
@property(nonatomic, assign) BOOL launchOverlayDismissed;

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
        default:
            NSLog(@"[TouchController] Unknown message type: %d", type);
            break;
    }
}

// åå§åææ¬è¾å¥å­æ®µ
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

    // 渲染循环 tick：Gyro/Controller 输入采样（FPS 计数已移至 native pojavSwapBuffers）
    __weak typeof(self) weakSelf = self;
    id tickInput = ^{
        [GyroInput tick];
        [ControllerInput tick];
    };
    CADisplayLink *displayLink = [CADisplayLink displayLinkWithTarget:tickInput selector:@selector(invoke)];
    if (@available(iOS 15.0, tvOS 15.0, *)) {
        if(getPrefBool(@"video.max_framerate")) {
            displayLink.preferredFrameRateRange = CAFrameRateRangeMake(30, 120, 120);
        } else {
            displayLink.preferredFrameRateRange = CAFrameRateRangeMake(30, 60, 60);
        }
    }
    [displayLink addToRunLoop:NSRunLoop.currentRunLoop forMode:NSRunLoopCommonModes];
    self.statsDisplayLink = displayLink;

    // 低频采样定时器：每 1 秒读取一次 native FPS 计数器和内存占用
    // 参照 FCL/ZL2 的 1Hz 采样策略（FCL_GameMenu.java Thread.sleep(1000)）
    // pojavGetAndResetFps() 读取并重置计数器，1 秒间隔直接返回 FPS 值
    self.statsTimer = [NSTimer scheduledTimerWithTimeInterval:1.0
                                                      target:self
                                                    selector:@selector(updateGameStats)
                                                    userInfo:nil
                                                     repeats:YES];
    [[NSRunLoop currentRunLoop] addTimer:self.statsTimer forMode:NSRunLoopCommonModes];

    CGFloat screenScale = UIScreen.mainScreen.scale;
    [self updateSavedResolution];

    self.rootView = [[UIView alloc] initWithFrame:CGRectMake(0, 0, self.view.frame.size.width, self.view.frame.size.height)];
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
    [self.touchView addGestureRecognizer:self.tapGesture];

    self.doubleTapGesture = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(surfaceOnDoubleClick:)];
    self.doubleTapGesture.allowedTouchTypes = @[@(UITouchTypeDirect)];
    self.doubleTapGesture.delegate = self;
    self.doubleTapGesture.numberOfTapsRequired = 2;
    self.doubleTapGesture.numberOfTouchesRequired = 1;
    self.doubleTapGesture.cancelsTouchesInView = NO;
    [self.touchView addGestureRecognizer:self.doubleTapGesture];

    self.longPressGesture = [[UILongPressGestureRecognizer alloc] initWithTarget:self action:@selector(surfaceOnLongpress:)];
    self.longPressGesture.allowedTouchTypes = @[@(UITouchTypeDirect)];
    self.longPressGesture.cancelsTouchesInView = NO;
    self.longPressGesture.delegate = self;
    // è®¾ç½®æå¿ä¾èµå³ç³»ï¼åªæå½åå»ååå»æå¿å¤±è´¥æ¶ï¼é¿ææå¿æä¼è¢«è¯å«
    [self.longPressGesture requireGestureRecognizerToFail:self.tapGesture];
    [self.longPressGesture requireGestureRecognizerToFail:self.doubleTapGesture];
    [self.touchView addGestureRecognizer:self.longPressGesture];

    self.longPressTwoGesture = [[UILongPressGestureRecognizer alloc]initWithTarget:self action:@selector(keyboardGesture:)];
    self.longPressTwoGesture.numberOfTouchesRequired = 2;
    self.longPressTwoGesture.allowedTouchTypes = @[@(UITouchTypeDirect)];
    self.longPressTwoGesture.cancelsTouchesInView = NO;
    self.longPressTwoGesture.delegate = self;
    [self.touchView addGestureRecognizer:self.longPressTwoGesture];

    self.scrollPanGesture = [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(surfaceOnTouchesScroll:)];
    self.scrollPanGesture.allowedTouchTypes = @[@(UITouchTypeDirect)];
    self.scrollPanGesture.delegate = self;
    self.scrollPanGesture.minimumNumberOfTouches = 2;
    self.scrollPanGesture.maximumNumberOfTouches = 2;
    [self.touchView addGestureRecognizer:self.scrollPanGesture];

    virtualMouseEnabled = getPrefBool(@"control.virtmouse_enable");
    virtualMouseFrame = CGRectMake(self.view.frame.size.width / 2, self.view.frame.size.height / 2, 18, 27);
    self.mousePointerView = [[UIImageView alloc] initWithFrame:virtualMouseFrame];
    self.mousePointerView.autoresizingMask = UIViewAutoresizingFlexibleLeftMargin | UIViewAutoresizingFlexibleTopMargin | UIViewAutoresizingFlexibleRightMargin |UIViewAutoresizingFlexibleBottomMargin;
    self.mousePointerView.hidden = !virtualMouseEnabled;
    [self reloadMousePointerImage];
    self.mousePointerView.userInteractionEnabled = NO;
    [self.touchView addSubview:self.mousePointerView];

    [[NSNotificationCenter defaultCenter] addObserverForName:@"MousePointerUpdated" object:nil queue:[NSOperationQueue mainQueue] usingBlock:^(NSNotification * _Nonnull note) {
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

    // 阶段13：显示启动遮罩层（在 launchMinecraft 之前显示，首帧渲染后自动移除）
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

    // 启动 LAN 端口检测器（用于联机功能自动检测 MC "对局域网开放"端口）
    // 检测器通过监听 MC 日志输出识别端口，检测到后通过通知 LanPortDetectorDidDetectPort 通知 UI
    [[LanPortDetector sharedDetector] startDetecting];
}

- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    // 更新启动遮罩层渐变背景的 frame（旋转/尺寸变化时）
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
    int limit = getPrefInt(@"java.allocated_memory") + 1024;
    if (memorystatus_control(MEMORYSTATUS_CMD_SET_JETSAM_TASK_LIMIT, getpid(), limit, NULL, 0) == -1) {
        NSLog(@"Failed to set Jetsam task limit: error: %s", strerror(errno));
    } else {
        NSLog(@"Successfully set Jetsam task limit");
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
        // 解锁帧率（关闭垂直同步）：三缓冲。
        // 默认 maximumDrawableCount（通常为 2）下，当两个 drawable 都在等待呈现时，
        // nextDrawable 会阻塞到 vblank 释放一个 drawable，间接把渲染线程锁在刷新率。
        // 设为 3（三缓冲）后几乎总有空闲 drawable，渲染线程不再因等待 drawable 而 stall，
        // 配合 VSync 关闭可让帧率超过屏幕刷新率。该值是 Metal 低延迟/高吞吐渲染的标准设置。
        // 注：此优化对 GL 类渲染器（经 CAMetalLayer 呈现）最有意义；Vulkan/MoltenVK 自管 swapchain。
        metalLayer.maximumDrawableCount = 3;
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
        // Validate metadata
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
        
        // Validate accountId（用作账户文件名，传给 Java 端加载对应账户）
        NSString *accountId = currentAuth.authData[@"accountId"];
        if (!accountId || accountId.length == 0) {
            // 兜底：极少数情况下 accountId 缺失（如旧账户未迁移），回退到 username
            accountId = currentAuth.authData[@"username"];
            if (!accountId || accountId.length == 0) {
                accountId = @"Player";
            }
        }

        NSLog(@"[SurfaceViewController] Launching Minecraft with accountId: %@, version: %d, size: %dx%d",
              accountId, minVersion, windowWidth, windowHeight);

        // Launch JVM（args[0] 传 accountId，Java 端 MinecraftAccount.load(accountId) 据此加载账户）
        int launchResult = launchJVM(accountId, self.metadata, windowWidth, windowHeight, minVersion);

        // JVM 启动失败（返回非 0）：移除启动遮罩层，让用户看到错误对话框
        // launchJVM 内部失败时会调用 showDialog 显示错误，此处仅负责清理遮罩层
        if (launchResult != 0) {
            NSLog(@"[SurfaceViewController] JVM launch failed with code %d", launchResult);
            dispatch_async(dispatch_get_main_queue(), ^{
                [self dismissLaunchOverlayOnError];
            });
        }
    });
}

#pragma mark - 阶段13/16：启动遮罩层（仿 FCL/ZL2 全屏启动进度显示）

/// 创建并显示启动遮罩层（仿 FCL/ZL2 风格）：
/// - 全屏深色渐变背景（非卡片式，更沉浸）
/// - 顶部游戏图标 + 标题
/// - 中部水平进度条（随时间推进，首帧渲染前封顶 95%）
/// - 进度条下方阶段文案 + 已耗时
/// - 适配 iPhone/iPad 屏幕
- (void)setupLaunchOverlay {
    // 启动阶段列表（参照 FCL/ZL2 启动流程，含完整性检查阶段）
    // 仿 FCL/HMCL：启动前先校验游戏文件完整性
    self.launchStages = @[
        localize(@"launch.stage.init_env", @"正在初始化运行环境..."),
        localize(@"launch.stage.verify_files", @"正在校验游戏文件完整性..."),
        localize(@"launch.stage.load_jre", @"正在加载 Java 运行时..."),
        localize(@"launch.stage.config_jvm", @"正在配置 JVM 参数..."),
        localize(@"launch.stage.start_jvm", @"正在启动 Java 虚拟机..."),
        localize(@"launch.stage.load_libs", @"正在加载游戏库..."),
        localize(@"launch.stage.init_mc", @"正在初始化 Minecraft..."),
        localize(@"launch.stage.load_assets", @"正在加载资源文件..."),
        localize(@"launch.stage.entering", @"即将进入游戏..."),
    ];
    self.currentStageIndex = 0;
    self.launchStartTime = [NSDate timeIntervalSinceReferenceDate];
    self.launchOverlayDismissed = NO;

    // 全屏遮罩容器
    self.launchOverlayView = [[UIView alloc] initWithFrame:self.view.bounds];
    self.launchOverlayView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    self.launchOverlayView.userInteractionEnabled = YES;
    [self.view addSubview:self.launchOverlayView];

    // 背景层：有自定义壁纸时透明让壁纸透出（加半透明蒙层增强文字可读性），
    // 无自定义壁纸时使用深色渐变作为回退（仿 FCL 启动页的深色渐变）
    if ([[BackgroundManager sharedManager] hasBackground]) {
        // 有自定义背景：透明遮罩 + 半透明蒙层
        self.launchOverlayView.backgroundColor = [UIColor clearColor];
        UIView *dimOverlay = [[UIView alloc] initWithFrame:self.launchOverlayView.bounds];
        dimOverlay.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        dimOverlay.backgroundColor = [[UIColor blackColor] colorWithAlphaComponent:0.4];
        dimOverlay.userInteractionEnabled = NO;
        [self.launchOverlayView addSubview:dimOverlay];
    } else {
        // 无自定义背景：使用深色渐变
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

    // 游戏图标（顶部，仿 FCL 启动页的 Minecraft 图标）
    self.launchIconView = [[UIImageView alloc] init];
    self.launchIconView.translatesAutoresizingMaskIntoConstraints = NO;
    self.launchIconView.contentMode = UIViewContentModeScaleAspectFit;
    self.launchIconView.image = [UIImage systemImageNamed:@"cube.transparent.fill"];
    self.launchIconView.tintColor = [UIColor systemGreenColor];
    [self.launchOverlayView addSubview:self.launchIconView];

    // 旋转指示器（图标下方小转圈，仿 FCL 的加载动画）
    self.launchSpinner = [[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleMedium];
    self.launchSpinner.translatesAutoresizingMaskIntoConstraints = NO;
    self.launchSpinner.color = [UIColor colorWithWhite:0.85 alpha:1.0];
    [self.launchSpinner startAnimating];
    [self.launchOverlayView addSubview:self.launchSpinner];

    // 标题
    self.launchTitleLabel = [[UILabel alloc] init];
    self.launchTitleLabel.translatesAutoresizingMaskIntoConstraints = NO;
    self.launchTitleLabel.text = localize(@"launch.title", @"正在启动 Minecraft");
    self.launchTitleLabel.font = [UIFont systemFontOfSize:22 weight:UIFontWeightBold];
    self.launchTitleLabel.textColor = [UIColor whiteColor];
    self.launchTitleLabel.textAlignment = NSTextAlignmentCenter;
    [self.launchOverlayView addSubview:self.launchTitleLabel];

    // 阶段文案
    self.launchStageLabel = [[UILabel alloc] init];
    self.launchStageLabel.translatesAutoresizingMaskIntoConstraints = NO;
    self.launchStageLabel.text = self.launchStages.firstObject ?: localize(@"launch.stage.preparing", @"正在准备...");
    self.launchStageLabel.font = [UIFont systemFontOfSize:14];
    self.launchStageLabel.textColor = [UIColor colorWithWhite:0.65 alpha:1.0];
    self.launchStageLabel.textAlignment = NSTextAlignmentCenter;
    self.launchStageLabel.numberOfLines = 0;
    [self.launchOverlayView addSubview:self.launchStageLabel];

    // 水平进度条（仿 FCL/ZL2 的启动进度条）
    self.launchProgressBar = [[UIProgressView alloc] initWithProgressViewStyle:UIProgressViewStyleBar];
    self.launchProgressBar.translatesAutoresizingMaskIntoConstraints = NO;
    self.launchProgressBar.progressTintColor = [UIColor systemGreenColor];
    self.launchProgressBar.trackTintColor = [[UIColor whiteColor] colorWithAlphaComponent:0.15];
    self.launchProgressBar.progress = 0.02;
    [self.launchOverlayView addSubview:self.launchProgressBar];

    // 已耗时标签
    self.launchElapsedTimeLabel = [[UILabel alloc] init];
    self.launchElapsedTimeLabel.translatesAutoresizingMaskIntoConstraints = NO;
    self.launchElapsedTimeLabel.text = localize(@"launch.elapsed", @"已耗时 0秒");
    self.launchElapsedTimeLabel.font = [UIFont monospacedDigitSystemFontOfSize:12 weight:UIFontWeightRegular];
    self.launchElapsedTimeLabel.textColor = [UIColor colorWithWhite:0.5 alpha:1.0];
    self.launchElapsedTimeLabel.textAlignment = NSTextAlignmentCenter;
    [self.launchOverlayView addSubview:self.launchElapsedTimeLabel];

    // 布局约束（全屏沉浸式，内容垂直居中偏上）
    CGFloat sidePadding = self.traitCollection.userInterfaceIdiom == UIUserInterfaceIdiomPad ? 80.0 : 32.0;

    [NSLayoutConstraint activateConstraints:@[
        // 图标：距顶部约 20% 屏幕高度，水平居中
        [self.launchIconView.topAnchor constraintEqualToAnchor:self.launchOverlayView.safeAreaLayoutGuide.topAnchor constant:0],
        [self.launchIconView.centerXAnchor constraintEqualToAnchor:self.launchOverlayView.centerXAnchor],
        [self.launchIconView.widthAnchor constraintEqualToConstant:72],
        [self.launchIconView.heightAnchor constraintEqualToConstant:72],

        // 旋转指示器：图标下方
        [self.launchSpinner.topAnchor constraintEqualToAnchor:self.launchIconView.bottomAnchor constant:12],
        [self.launchSpinner.centerXAnchor constraintEqualToAnchor:self.launchOverlayView.centerXAnchor],

        // 标题：旋转指示器下方
        [self.launchTitleLabel.topAnchor constraintEqualToAnchor:self.launchSpinner.bottomAnchor constant:10],
        [self.launchTitleLabel.leadingAnchor constraintEqualToAnchor:self.launchOverlayView.leadingAnchor constant:sidePadding],
        [self.launchTitleLabel.trailingAnchor constraintEqualToAnchor:self.launchOverlayView.trailingAnchor constant:-sidePadding],

        // 阶段文案：标题下方
        [self.launchStageLabel.topAnchor constraintEqualToAnchor:self.launchTitleLabel.bottomAnchor constant:8],
        [self.launchStageLabel.leadingAnchor constraintEqualToAnchor:self.launchOverlayView.leadingAnchor constant:sidePadding],
        [self.launchStageLabel.trailingAnchor constraintEqualToAnchor:self.launchOverlayView.trailingAnchor constant:-sidePadding],

        // 进度条：阶段文案下方
        [self.launchProgressBar.topAnchor constraintEqualToAnchor:self.launchStageLabel.bottomAnchor constant:20],
        [self.launchProgressBar.leadingAnchor constraintEqualToAnchor:self.launchOverlayView.leadingAnchor constant:sidePadding],
        [self.launchProgressBar.trailingAnchor constraintEqualToAnchor:self.launchOverlayView.trailingAnchor constant:-sidePadding],
        [self.launchProgressBar.heightAnchor constraintEqualToConstant:6],

        // 已耗时：进度条下方
        [self.launchElapsedTimeLabel.topAnchor constraintEqualToAnchor:self.launchProgressBar.bottomAnchor constant:8],
        [self.launchElapsedTimeLabel.leadingAnchor constraintEqualToAnchor:self.launchOverlayView.leadingAnchor constant:sidePadding],
        [self.launchElapsedTimeLabel.trailingAnchor constraintEqualToAnchor:self.launchOverlayView.trailingAnchor constant:-sidePadding],
    ]];

    // 注册首帧渲染通知（egl_bridge.m 中 pojavSwapBuffers 首次调用时发送）
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(onFirstFrameRendered)
                                                 name:@"PojavFirstFrameRendered"
                                               object:nil];

    // 启动阶段轮转定时器（每 2.5 秒切换一次阶段文案，同时推进进度条）
    self.launchStageTimer = [NSTimer scheduledTimerWithTimeInterval:0.5
                                                             target:self
                                                           selector:@selector(updateLaunchStage)
                                                           userInfo:nil
                                                            repeats:YES];
    [[NSRunLoop mainRunLoop] addTimer:self.launchStageTimer forMode:NSRunLoopCommonModes];
}

/// 定时器回调（每 0.5 秒）：
/// 1. 基于已耗时计算当前阶段索引（每 2.5 秒一个阶段，避免 static 变量在多次启动间不重置）
/// 2. 推进进度条（基于已耗时，封顶 95%）
/// 3. 更新已耗时显示
- (void)updateLaunchStage {
    if (self.launchOverlayDismissed || !self.launchOverlayView) return;

    NSTimeInterval elapsed = [NSDate timeIntervalSinceReferenceDate] - self.launchStartTime;

    // 阶段切换：基于已耗时计算（每 2.5 秒一个阶段），避免 static 变量在多次启动间不重置
    NSInteger stageIndex = (NSInteger)(elapsed / 2.5);
    if (stageIndex >= self.launchStages.count) {
        stageIndex = self.launchStages.count - 1;
    }
    if (stageIndex != self.currentStageIndex) {
        self.currentStageIndex = stageIndex;
        self.launchStageLabel.text = self.launchStages[stageIndex];
    }

    // 进度条推进：基于已耗时，前 3 秒快速到 20%，之后缓慢推进，封顶 95%
    CGFloat targetProgress;
    if (elapsed < 3.0) {
        targetProgress = 0.02 + (elapsed / 3.0) * 0.18; // 2% → 20%
    } else if (elapsed < 30.0) {
        targetProgress = 0.20 + ((elapsed - 3.0) / 27.0) * 0.55; // 20% → 75%
    } else if (elapsed < 60.0) {
        targetProgress = 0.75 + ((elapsed - 30.0) / 30.0) * 0.15; // 75% → 90%
    } else {
        targetProgress = MIN(0.95, 0.90 + ((elapsed - 60.0) / 60.0) * 0.05); // 90% → 95%（封顶）
    }
    // 仅当目标进度大于当前进度时更新（避免回退）
    if (targetProgress > self.launchProgressBar.progress) {
        [self.launchProgressBar setProgress:targetProgress animated:YES];
    }

    // 更新已耗时显示
    NSString *timeStr;
    if (elapsed > 60) {
        timeStr = [NSString stringWithFormat:localize(@"launch.elapsed_minutes", @"已耗时 %.0f分%.0f秒"), elapsed / 60, (double)((int)elapsed % 60)];
    } else {
        timeStr = [NSString stringWithFormat:localize(@"launch.elapsed_seconds", @"已耗时 %.0f秒"), elapsed];
    }
    self.launchElapsedTimeLabel.text = timeStr;
}

/// 首帧渲染通知回调：进度条跳到 100%，淡出并移除启动遮罩层
- (void)onFirstFrameRendered {
    dispatch_async(dispatch_get_main_queue(), ^{
        if (self.launchOverlayDismissed) return;
        self.launchOverlayDismissed = YES;

        [self.launchStageTimer invalidate];
        self.launchStageTimer = nil;
        [self.launchSpinner stopAnimating];

        // 进度条跳到 100%
        [self.launchProgressBar setProgress:1.0 animated:YES];

        // 更新最终文案
        NSTimeInterval elapsed = [NSDate timeIntervalSinceReferenceDate] - self.launchStartTime;
        self.launchStageLabel.text = localize(@"launch.complete", @"启动完成！");
        NSString *timeStr;
        if (elapsed > 60) {
            timeStr = [NSString stringWithFormat:localize(@"launch.total_minutes", @"总耗时 %.0f分%.0f秒"), elapsed / 60, (double)((int)elapsed % 60)];
        } else {
            timeStr = [NSString stringWithFormat:localize(@"launch.total_seconds", @"总耗时 %.1f秒"), elapsed];
        }
        self.launchElapsedTimeLabel.text = timeStr;

        // 延迟 0.4 秒后淡出移除（让用户看到 100% 进度和"启动完成"提示）
        [UIView animateWithDuration:0.4
                              delay:0.4
                            options:UIViewAnimationOptionCurveEaseOut
                         animations:^{
            self.launchOverlayView.alpha = 0.0;
        }
                         completion:^(BOOL finished) {
            [self.launchOverlayView removeFromSuperview];
            self.launchOverlayView = nil;
            self.launchGradientLayer = nil;
            [[NSNotificationCenter defaultCenter] removeObserver:self name:@"PojavFirstFrameRendered" object:nil];
            NSLog(@"[SurfaceViewController] Launch overlay dismissed after %.1f seconds", elapsed);
        }];
    });
}

/// 启动失败时移除遮罩层（JVM 启动失败、metadata 为空等错误路径调用）
- (void)dismissLaunchOverlayOnError {
    dispatch_async(dispatch_get_main_queue(), ^{
        if (self.launchOverlayDismissed) return;
        self.launchOverlayDismissed = YES;

        [self.launchStageTimer invalidate];
        self.launchStageTimer = nil;
        [self.launchSpinner stopAnimating];
        [[NSNotificationCenter defaultCenter] removeObserver:self name:@"PojavFirstFrameRendered" object:nil];

        [self.launchOverlayView removeFromSuperview];
        self.launchOverlayView = nil;
        self.launchGradientLayer = nil;
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
        self.rootView.bounds = CGRectMake(0, 0, size.width, size.height);

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
    BOOL handled = NO;
    for (UIPress *press in presses) {
        if (press.key != nil && [KeyboardInput sendKeyEvent:press.key down:YES]) {
            handled = YES;
        }
    }
    if (!handled) {
        [super pressesBegan:presses withEvent:event];
    }
}

- (void)pressesEnded:(NSSet<UIPress *> *)presses withEvent:(UIPressesEvent *)event {
    BOOL handled = NO;
    for (UIPress *press in presses) {
        if (press.key != nil && [KeyboardInput sendKeyEvent:press.key down:NO]) {
            handled = YES;
        }
    }
    if (!handled) {
        [super pressesEnded:presses withEvent:event];
    }
}

- (BOOL)prefersPointerLocked {
    return GCMouse.mice.count > 0 && (isGrabbing || virtualMouseEnabled);
}

- (void)registerMouseCallbacks:(GCMouse *)mouse {
    NSLog(@"Input: Got mouse %@", mouse);
    mouse.mouseInput.mouseMovedHandler = ^(GCMouseInput * _Nonnull mouse, float deltaX, float deltaY) {
        if (!self.view.window.windowScene.pointerLockState.locked) {
            return;
        }
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
    // 情况1：rootViewController 就是 SurfaceViewController
    if ([rootVC isKindOfClass:[SurfaceViewController class]]) {
        return (SurfaceViewController *)rootVC;
    }
    // 情况2：SurfaceViewController 以模态方式呈现
    UIViewController *presentedVC = rootVC.presentedViewController;
    if ([presentedVC isKindOfClass:[SurfaceViewController class]]) {
        return (SurfaceViewController *)presentedVC;
    }
    return nil;
}

+ (GameSurfaceView *)surface {
    return pojavWindow;
}

#pragma mark - FPS/内存监控（参照 FCL egl_bridge.c 与 ZL2 MemoryUtils.kt）

- (void)updateGameStats {
    // 1. 读取 native swap buffer 计数器并重置（参照 FCL CallbackBridge.getFps()）
    // pojavGetAndResetFps() 返回自上次调用以来的渲染帧数
    // 采样间隔 1 秒（statsTimer 已改为 1s），所以返回值即为 FPS
    NSInteger fps = (NSInteger)pojavGetAndResetFps();

    // 2. 获取内存占用（phys_footprint）
    // 使用 task_vm_info 的 phys_footprint 字段，这是 iOS 上最准确的进程内存占用指标
    // 包含常驻内存、压缩内存、GPU 内存（UMA 架构下），与 Xcode 内存表盘一致
    // 参照 ZL2 MemoryUtils.kt 的系统级内存统计理念，在 iOS 上用 phys_footprint 等价
    double memoryMB = [self currentPhysFootprintMB];

    // 3. 更新 UI（GameMenuOverlayView 内部会 dispatch 到主线程）
    if ([self.gameMenuOverlay isKindOfClass:[GameMenuOverlayView class]]) {
        [(GameMenuOverlayView *)self.gameMenuOverlay updateFPS:fps memoryUsageMB:memoryMB];
    }
}

- (double)currentPhysFootprintMB {
    // 使用 TASK_VM_INFO flavor 读取 phys_footprint
    // phys_footprint 是 Apple 推荐的进程内存占用指标，包含：
    // - 常驻物理内存（resident_size）
    // - 压缩内存
    // - GPU 内存（iOS UMA 架构下 Metal 缓冲区映射到进程地址空间）
    // 减去通过 mmap 共享的部分，与 Xcode/Memory Graph 显示的值一致
    task_vm_info_data_t vmInfo;
    mach_msg_type_number_t count = TASK_VM_INFO_COUNT;
    kern_return_t kr = task_info(mach_task_self(), TASK_VM_INFO,
                                 (task_info_t)&vmInfo, &count);
    if (kr != KERN_SUCCESS) {
        return 0.0;
    }
    // phys_footprint 单位是字节
    return (double)vmInfo.phys_footprint / (1024.0 * 1024.0);
}

- (void)dealloc {
    // 停止 FPS/内存采样定时器与渲染循环
    [self.statsTimer invalidate];
    self.statsTimer = nil;
    [self.statsDisplayLink invalidate];
    self.statsDisplayLink = nil;

    // 阶段13/16：清理启动遮罩层资源
    [self.launchStageTimer invalidate];
    self.launchStageTimer = nil;
    [[NSNotificationCenter defaultCenter] removeObserver:self name:@"PojavFirstFrameRendered" object:nil];
    self.launchOverlayView = nil;
    self.launchGradientLayer = nil;

    // 停止 LAN 端口检测器（游戏退出时清理）
    [[LanPortDetector sharedDetector] stopDetecting];

    //æ¸ç TouchController èµæº
    if (self.touchControllerTransportHandle >= 0) {
        [TouchControllerBridge destroyTransport:self.touchControllerTransportHandle];
        self.touchControllerTransportHandle = -1;
    }
}

@end
