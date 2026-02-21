//
//  BackgroundManager.m
//  Amethyst
//
//  Background wallpaper manager implementation
//

#import "BackgroundManager.h"
#import <Photos/Photos.h>

static NSString * const kBackgroundTypeKey = @"background_type";
static NSString * const kBackgroundPathKey = @"background_path";
static NSString * const kBackgroundsFolder = @"backgrounds";

@interface BackgroundManager ()
@property (nonatomic, strong) AVPlayer *videoPlayer;
@property (nonatomic, strong) AVPlayerLayer *videoPlayerLayer;
@property (nonatomic, weak) UIView *currentBackgroundView;
@property (nonatomic, readwrite) BackgroundType currentType;
@property (nonatomic, readwrite, nullable) NSString *currentBackgroundPath;
@end

@implementation BackgroundManager

+ (instancetype)sharedManager {
    static BackgroundManager *shared = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        shared = [[self alloc] init];
    });
    return shared;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        [self loadSavedBackground];
        [self setupNotifications];
    }
    return self;
}

- (void)setupNotifications {
    // Handle app lifecycle for video background
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(appDidEnterBackground)
                                                 name:UIApplicationDidEnterBackgroundNotification
                                               object:nil];
    
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(appWillEnterForeground)
                                                 name:UIApplicationWillEnterForegroundNotification
                                               object:nil];
    
    // Handle video loop
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(playerItemDidReachEnd:)
                                                 name:AVPlayerItemDidPlayToEndTimeNotification
                                               object:nil];
}

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
    [self cleanupVideoPlayer];
}

#pragma mark - Backgrounds Folder

- (NSString *)backgroundsFolderPath {
    NSString *docsDir = [NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES) firstObject];
    NSString *folder = [docsDir stringByAppendingPathComponent:kBackgroundsFolder];
    
    NSFileManager *fm = [NSFileManager defaultManager];
    if (![fm fileExistsAtPath:folder]) {
        [fm createDirectoryAtPath:folder withIntermediateDirectories:YES attributes:nil error:nil];
    }
    
    return folder;
}

#pragma mark - Load/Save Background

- (void)loadSavedBackground {
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    self.currentType = [defaults integerForKey:kBackgroundTypeKey];
    self.currentBackgroundPath = [defaults stringForKey:kBackgroundPathKey];
    
    // Validate path exists
    if (self.currentBackgroundPath && ![[NSFileManager defaultManager] fileExistsAtPath:self.currentBackgroundPath]) {
        self.currentBackgroundPath = nil;
        self.currentType = BackgroundTypeNone;
        [self saveBackgroundSettings];
    }
}

- (void)saveBackgroundSettings {
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    [defaults setInteger:self.currentType forKey:kBackgroundTypeKey];
    [defaults setObject:self.currentBackgroundPath forKey:kBackgroundPathKey];
    [defaults synchronize];
}

#pragma mark - Apply Background

- (void)applyBackgroundToView:(UIView *)view {
    if (!view) return;
    
    // Remove existing background
    [self removeBackgroundFromView:view];
    
    self.currentBackgroundView = view;
    
    switch (self.currentType) {
        case BackgroundTypeImage:
            [self applyImageBackgroundToView:view];
            break;
        case BackgroundTypeVideo:
            [self applyVideoBackgroundToView:view];
            break;
        default:
            break;
    }
}

- (void)removeBackgroundFromView:(UIView *)view {
    // Remove image background
    UIView *existingImageView = [view viewWithTag:9998];
    if (existingImageView) {
        [existingImageView removeFromSuperview];
    }
    
    // Remove video background
    UIView *existingVideoView = [view viewWithTag:9999];
    if (existingVideoView) {
        [existingVideoView removeFromSuperview];
    }
    
    [self cleanupVideoPlayer];
}

- (void)applyImageBackgroundToView:(UIView *)view {
    if (!self.currentBackgroundPath) return;
    
    UIImage *image = [UIImage imageWithContentsOfFile:self.currentBackgroundPath];
    if (!image) return;
    
    UIImageView *imageView = [[UIImageView alloc] initWithImage:image];
    imageView.tag = 9998;
    imageView.contentMode = UIViewContentModeScaleAspectFill;
    imageView.clipsToBounds = YES;
    imageView.translatesAutoresizingMaskIntoConstraints = NO;
    imageView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    
    // Add blur effect for better readability
    UIBlurEffect *blurEffect = [UIBlurEffect effectWithStyle:UIBlurEffectStyleDark];
    UIVisualEffectView *blurView = [[UIVisualEffectView alloc] initWithEffect:blurEffect];
    blurView.alpha = 0.3;
    blurView.translatesAutoresizingMaskIntoConstraints = NO;
    blurView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    
    [view insertSubview:imageView atIndex:0];
    [imageView addSubview:blurView];
    
    // Set frame
    imageView.frame = view.bounds;
    blurView.frame = imageView.bounds;
}

- (void)applyVideoBackgroundToView:(UIView *)view {
    if (!self.currentBackgroundPath) return;
    
    NSURL *videoURL = [NSURL fileURLWithPath:self.currentBackgroundPath];
    if (![[NSFileManager defaultManager] fileExistsAtPath:self.currentBackgroundPath]) return;
    
    // Create player
    self.videoPlayer = [AVPlayer playerWithURL:videoURL];
    self.videoPlayer.actionAtItemEnd = AVPlayerActionAtItemEndNone;
    
    // Create player layer
    self.videoPlayerLayer = [AVPlayerLayer playerLayerWithPlayer:self.videoPlayer];
    self.videoPlayerLayer.videoGravity = AVLayerVideoGravityResizeAspectFill;
    self.videoPlayerLayer.frame = view.bounds;
    
    // Create container view
    UIView *videoContainer = [[UIView alloc] initWithFrame:view.bounds];
    videoContainer.tag = 9999;
    videoContainer.translatesAutoresizingMaskIntoConstraints = NO;
    videoContainer.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    [videoContainer.layer addSublayer:self.videoPlayerLayer];
    
    // Add blur effect for better readability
    UIBlurEffect *blurEffect = [UIBlurEffect effectWithStyle:UIBlurEffectStyleDark];
    UIVisualEffectView *blurView = [[UIVisualEffectView alloc] initWithEffect:blurEffect];
    blurView.alpha = 0.3;
    blurView.translatesAutoresizingMaskIntoConstraints = NO;
    blurView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    [videoContainer addSubview:blurView];
    
    [view insertSubview:videoContainer atIndex:0];
    
    // Start playing
    [self.videoPlayer play];
    
    // Update layer frame when view layout changes
    [videoContainer layoutIfNeeded];
    self.videoPlayerLayer.frame = videoContainer.bounds;
    blurView.frame = videoContainer.bounds;
}

- (void)cleanupVideoPlayer {
    if (self.videoPlayer) {
        [self.videoPlayer pause];
        self.videoPlayer = nil;
    }
    self.videoPlayerLayer = nil;
}

#pragma mark - Video Loop

- (void)playerItemDidReachEnd:(NSNotification *)notification {
    AVPlayerItem *playerItem = notification.object;
    [playerItem seekToTime:kCMTimeZero completionHandler:nil];
}

#pragma mark - App Lifecycle

- (void)appDidEnterBackground {
    [self pauseVideo];
}

- (void)appWillEnterForeground {
    [self resumeVideo];
}

- (void)pauseVideo {
    if (self.videoPlayer) {
        [self.videoPlayer pause];
    }
}

- (void)resumeVideo {
    if (self.videoPlayer && self.currentType == BackgroundTypeVideo) {
        [self.videoPlayer play];
    }
}

#pragma mark - Set Background

- (void)setImageBackground:(UIImage *)image completion:(void (^)(BOOL success, NSError * _Nullable error))completion {
    if (!image) {
        if (completion) {
            completion(NO, [NSError errorWithDomain:@"BackgroundManager" code:1 userInfo:@{NSLocalizedDescriptionKey: @"å¾çä¸ºç©º"}]);
        }
        return;
    }
    
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        // Clear existing background
        [self clearBackground];
        
        // Save image
        NSString *fileName = [NSString stringWithFormat:@"background_image_%ld.jpg", (long)[[NSDate date] timeIntervalSince1970]];
        NSString *filePath = [[self backgroundsFolderPath] stringByAppendingPathComponent:fileName];
        
        // Compress and save
        NSData *imageData = UIImageJPEGRepresentation(image, 0.8);
        if (!imageData) {
            dispatch_async(dispatch_get_main_queue(), ^{
                if (completion) {
                    completion(NO, [NSError errorWithDomain:@"BackgroundManager" code:2 userInfo:@{NSLocalizedDescriptionKey: @"å¾çåç¼©å¤±è´¥"}]);
                }
            });
            return;
        }
        
        BOOL saved = [imageData writeToFile:filePath atomically:YES];
        
        if (saved) {
            self.currentType = BackgroundTypeImage;
            self.currentBackgroundPath = filePath;
            [self saveBackgroundSettings];
            
            dispatch_async(dispatch_get_main_queue(), ^{
                if (completion) {
                    completion(YES, nil);
                }
            });
        } else {
            dispatch_async(dispatch_get_main_queue(), ^{
                if (completion) {
                    completion(NO, [NSError errorWithDomain:@"BackgroundManager" code:3 userInfo:@{NSLocalizedDescriptionKey: @"ä¿å­å¾çå¤±è´¥"}]);
                }
            });
        }
    });
}

- (void)setVideoBackgroundWithURL:(NSURL *)videoURL completion:(void (^)(BOOL success, NSError * _Nullable error))completion {
    if (!videoURL || ![[NSFileManager defaultManager] fileExistsAtPath:videoURL.path]) {
        if (completion) {
            completion(NO, [NSError errorWithDomain:@"BackgroundManager" code:4 userInfo:@{NSLocalizedDescriptionKey: @"è§é¢æä»¶ä¸å­å¨"}]);
        }
        return;
    }
    
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        // Clear existing background
        [self clearBackground];
        
        // Copy video to backgrounds folder
        NSString *fileName = [NSString stringWithFormat:@"background_video_%ld.mp4", (long)[[NSDate date] timeIntervalSince1970]];
        NSString *filePath = [[self backgroundsFolderPath] stringByAppendingPathComponent:fileName];
        
        NSError *copyError = nil;
        BOOL copied = [[NSFileManager defaultManager] copyItemAtURL:videoURL toURL:[NSURL fileURLWithPath:filePath] error:&copyError];
        
        if (copied) {
            self.currentType = BackgroundTypeVideo;
            self.currentBackgroundPath = filePath;
            [self saveBackgroundSettings];
            
            dispatch_async(dispatch_get_main_queue(), ^{
                if (completion) {
                    completion(YES, nil);
                }
            });
        } else {
            dispatch_async(dispatch_get_main_queue(), ^{
                if (completion) {
                    completion(NO, copyError ?: [NSError errorWithDomain:@"BackgroundManager" code:5 userInfo:@{NSLocalizedDescriptionKey: @"å¤å¶è§é¢å¤±è´¥"}]);
                }
            });
        }
    });
}

- (void)clearBackground {
    // Stop video
    [self cleanupVideoPlayer];
    
    // Remove old files
    if (self.currentBackgroundPath) {
        [[NSFileManager defaultManager] removeItemAtPath:self.currentBackgroundPath error:nil];
    }
    
    // Clear settings
    self.currentType = BackgroundTypeNone;
    self.currentBackgroundPath = nil;
    [self saveBackgroundSettings];
}

#pragma mark - Check Background

- (BOOL)hasBackground {
    return self.currentType != BackgroundTypeNone && self.currentBackgroundPath != nil;
}

- (BOOL)hasImageBackground {
    return self.currentType == BackgroundTypeImage && self.currentBackgroundPath != nil;
}

- (BOOL)hasVideoBackground {
    return self.currentType == BackgroundTypeVideo && self.currentBackgroundPath != nil;
}

#pragma mark - Preview

- (nullable UIImage *)backgroundPreview {
    if (self.currentType == BackgroundTypeImage && self.currentBackgroundPath) {
        return [UIImage imageWithContentsOfFile:self.currentBackgroundPath];
    }
    return nil;
}

@end
