//
//  InlineMessageView.h
//  Amethyst
//
//  Modelled on the inline messages of FCL/ZL2, replacing UIAlertController popups
//  Shows a loading/error/success/info state in the middle of the content area without blocking the user
//

#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSInteger, InlineMessageType) {
    InlineMessageTypeLoading,  // Loading (with a spinner; does not dismiss on its own)
    InlineMessageTypeError,    // Error (red; does not dismiss on its own and must be closed manually)
    InlineMessageTypeSuccess,  // Success (green; dismisses after 1.5s)
    InlineMessageTypeInfo,     // Info (blue; dismisses after 1.5s)
};

@interface InlineMessageView : UIView

/// The message type currently displayed
@property (nonatomic, assign, readonly) InlineMessageType messageType;
/// Callback for tapping the message view (optional, e.g. a "View details" entry point on the loading type)
@property (nonatomic, copy, nullable) void (^onTap)(void);
/// Callback for tapping the close button (optional; when set it replaces the default dismiss behavior, e.g. to cancel a download)
@property (nonatomic, copy, nullable) void (^onClose)(void);
/// Whether the close button is shown (only on the error type by default)
@property (nonatomic, assign) BOOL showsCloseButton;

/// Show a message in the given parent view (laid out automatically in the middle of the content area)
+ (instancetype)showInViewController:(UIViewController *)vc
                             title:(NSString *)title
                          message:(nullable NSString *)message
                             type:(InlineMessageType)type;

/// Show a message in the given parent view (with a close button option)
+ (instancetype)showInViewController:(UIViewController *)vc
                             title:(NSString *)title
                          message:(nullable NSString *)message
                             type:(InlineMessageType)type
                  showsCloseButton:(BOOL)showsCloseButton;

/// Update the current message content and type
- (void)updateWithMessage:(NSString *)message type:(InlineMessageType)type;

/// Update only the message text (keeping the current type)
- (void)updateMessage:(NSString *)message;

/// Dismiss the message view (animated)
- (void)dismiss;

/// Dismiss the message view (unanimated, removing it immediately)
- (void)dismissImmediately;

@end

NS_ASSUME_NONNULL_END
