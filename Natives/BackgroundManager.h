//
//  BackgroundManager.h
//  Amethyst
//
//  Background wallpaper manager - Global support for all view controllers
//

#import <UIKit/UIKit.h>
#import <AVFoundation/AVFoundation.h>
#import <AVKit/AVKit.h>

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSInteger, BackgroundType) {
    BackgroundTypeNone = 0,
    BackgroundTypeImage,
    BackgroundTypeVideo
};

typedef NS_ENUM(NSInteger, BackgroundUIEffect) {
    BackgroundUIEffectTranslucent = 0,  // 半透明
    BackgroundUIEffectBlur              // 毛玻璃效果
};

@interface BackgroundManager : NSObject

+ (instancetype)sharedManager;

// Background type
@property (nonatomic, readonly) BackgroundType currentType;
@property (nonatomic, readonly, nullable) NSString *currentBackgroundPath;

// UI effect settings (for custom background)
@property (nonatomic, assign) BackgroundUIEffect uiEffect;
@property (nonatomic, assign) CGFloat uiOpacity;  // 0.0 ~ 1.0

// Global background container
@property (nonatomic, strong, readonly, nullable) UIView *globalBackgroundContainer;

// Apply background globally
- (void)applyBackgroundToWindow:(UIWindow *)window;
- (void)applyBackgroundToSplitViewController:(UISplitViewController *)splitVC;
- (void)removeGlobalBackground;

// Legacy compatibility
- (void)applyBackgroundToView:(UIView *)view;
- (void)removeBackgroundFromView:(UIView *)view;

// Set background
- (void)setImageBackground:(UIImage *)image completion:(void (^)(BOOL success, NSError * _Nullable error))completion;
- (void)setVideoBackgroundWithURL:(NSURL *)videoURL completion:(void (^)(BOOL success, NSError * _Nullable error))completion;
- (void)clearBackground;

// Check if has background
- (BOOL)hasBackground;
- (BOOL)hasImageBackground;
- (BOOL)hasVideoBackground;

// Get background preview
- (nullable UIImage *)backgroundPreview;

// Pause/Resume video (for app lifecycle)
- (void)pauseVideo;
- (void)resumeVideo;

// Update background frame (call on rotation)
- (void)updateBackgroundFrame;

// Make view controllers transparent (for global background visibility)
- (void)makeViewControllerTransparent:(UIViewController *)viewController;
- (void)makeSplitViewControllerTransparent:(UISplitViewController *)splitVC;

// Apply UI effect settings to current split view controller
- (void)refreshUIEffect;

@end

NS_ASSUME_NONNULL_END