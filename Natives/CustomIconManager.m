#import "CustomIconManager.h"

@interface CustomIconManager()
@property (nonatomic, strong) NSFileManager *fileManager;
@property (nonatomic, strong) NSString *documentsDirectory;
@property (nonatomic, strong) NSString *customIconPath;
@end

@implementation CustomIconManager

+ (instancetype)sharedManager {
    static CustomIconManager *sharedInstance = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        sharedInstance = [[CustomIconManager alloc] init];
    });
    return sharedInstance;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        self.fileManager = [NSFileManager defaultManager];
        NSArray *paths = [self.fileManager URLsForDirectory:NSDocumentDirectory inDomains:NSUserDomainMask];
        self.documentsDirectory = [paths.firstObject path];
        self.customIconPath = [self.documentsDirectory stringByAppendingPathComponent:@"custom_icon.png"];
    }
    return self;
}

- (void)saveCustomIcon:(UIImage *)image withCompletion:(void (^)(BOOL success, NSError * _Nullable error))completion {
    // Save the image into the documents directory
    NSData *imageData = UIImagePNGRepresentation(image);
    if (!imageData) {
        if (completion) {
            completion(NO, [NSError errorWithDomain:@"CustomIconError" code:1001 userInfo:@{NSLocalizedDescriptionKey: @"Could not convert the image to PNG data"}]);
        }
        return;
    }
    
    NSError *error;
    BOOL success = [imageData writeToURL:[NSURL fileURLWithPath:self.customIconPath] options:NSDataWritingAtomic error:&error];
    
    if (completion) {
        completion(success, error);
    }
}

- (void)setCustomIconWithCompletion:(void (^)(BOOL success, NSError * _Nullable error))completion {
    // Check whether changing the icon is supported
    if (!UIApplication.sharedApplication.supportsAlternateIcons) {
        if (completion) {
            completion(NO, [NSError errorWithDomain:@"CustomIconError" code:1002 userInfo:@{NSLocalizedDescriptionKey: @"This device does not support changing the app icon"}]);
        }
        return;
    }
    
    // Check whether a custom icon exists
    if (![self.fileManager fileExistsAtPath:self.customIconPath]) {
        if (completion) {
            completion(NO, [NSError errorWithDomain:@"CustomIconError" code:1003 userInfo:@{NSLocalizedDescriptionKey: @"The custom icon file does not exist"}]);
        }
        return;
    }
    
    // Read the custom icon
    NSData *imageData = [NSData dataWithContentsOfFile:self.customIconPath];
    if (!imageData) {
        if (completion) {
            completion(NO, [NSError errorWithDomain:@"CustomIconError" code:1004 userInfo:@{NSLocalizedDescriptionKey: @"Could not read the custom icon file"}]);
        }
        return;
    }
    
    // Create a temporary directory
    NSString *tempDirectory = [self.documentsDirectory stringByAppendingPathComponent:@"temp_icons"];
    if (![self.fileManager fileExistsAtPath:tempDirectory]) {
        [self.fileManager createDirectoryAtPath:tempDirectory withIntermediateDirectories:YES attributes:nil error:nil];
    }
    
    // Save the icon into the temporary directory using the correct file name format
    NSString *tempIconPath = [tempDirectory stringByAppendingPathComponent:@"CustomIcon@2x.png"];
    [imageData writeToURL:[NSURL fileURLWithPath:tempIconPath] options:NSDataWritingAtomic error:nil];
    
    // Copy the icon files in other sizes (if needed)
    NSString *tempIconPath3x = [tempDirectory stringByAppendingPathComponent:@"CustomIcon@3x.png"];
    [imageData writeToURL:[NSURL fileURLWithPath:tempIconPath3x] options:NSDataWritingAtomic error:nil];
    
    // Set the custom icon
    [UIApplication.sharedApplication setAlternateIconName:@"CustomIcon" completionHandler:^(NSError * _Nullable error) {
        // Clean up the temporary files after a delay so the system has time to read them
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            [self.fileManager removeItemAtPath:tempDirectory error:nil];
        });
        
        if (completion) {
            completion(error == nil, error);
        }
    }];
}

- (BOOL)hasCustomIcon {
    return [self.fileManager fileExistsAtPath:self.customIconPath];
}

- (void)removeCustomIcon {
    if ([self.fileManager fileExistsAtPath:self.customIconPath]) {
        [self.fileManager removeItemAtPath:self.customIconPath error:nil];
    }
    
    // If the custom icon is currently in use, restore the default icon
    if ([UIApplication.sharedApplication.alternateIconName isEqualToString:@"CustomIcon"]) {
        [UIApplication.sharedApplication setAlternateIconName:nil completionHandler:nil];
    }
}

@end