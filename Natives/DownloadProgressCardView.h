//
//  DownloadProgressCardView.h
//  Flux
//
//  Download progress card view (modelled on the download progress UI of FCL/ZL2/HMCL)
//

#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

/// Download progress card view (modelled on the download progress UI of FCL/ZL2/HMCL)
///
/// FCL style: a floating card at the bottom with progress bar + percentage + speed + ETA + file name
/// ZL2 style: rounded frosted-glass background + colored progress bar + animation
/// HMCL style: a clean information layout + status icon
///
/// How to use:
/// 1. Create an instance and addSubview it to the current view
/// 2. Call startDownloadWithTitle:subtitle: to begin
/// 3. Call updateProgress:downloaded:total:speed:eta:currentFile: to update the progress
/// 4. Call completeWithTitle: or failWithError: to finish
/// 5. Call dismiss to remove it
@interface DownloadProgressCardView : UIView

/// Progress from 0.0 to 1.0; -1 means indeterminate mode (a spinner)
@property (nonatomic, assign) double progress;

/// Start the download
/// @param title Title (e.g. "Downloading 1.20.1")
/// @param subtitle Subtitle (e.g. "Vanilla Minecraft")
- (void)startDownloadWithTitle:(NSString *)title subtitle:(nullable NSString *)subtitle;

/// Update the progress
/// @param progress Progress from 0.0 to 1.0
/// @param downloadedBytes Bytes downloaded so far
/// @param totalBytes Total byte count (-1 if unknown)
/// @param speedBytesPerSec Download speed (bytes per second)
/// @param etaSeconds Time remaining (in seconds, -1 if unknown)
/// @param currentFile Name of the file currently downloading
- (void)updateProgress:(double)progress
            downloaded:(long long)downloadedBytes
                  total:(long long)totalBytes
                 speed:(long long)speedBytesPerSec
                   eta:(NSInteger)etaSeconds
           currentFile:(nullable NSString *)currentFile;

/// Download finished
/// @param title Completion title (e.g. "Download complete")
- (void)completeWithTitle:(NSString *)title;

/// Download failed
/// @param error Error information
- (void)failWithError:(NSError *)error;

/// Cancel the download
- (void)cancel;

/// Remove from the superview (animated)
- (void)dismiss;

/// Show a download progress card in the given view (class method, for convenience)
/// @param parentView Parent view
/// @param title Title
+ (instancetype)showInParentView:(UIView *)parentView title:(NSString *)title;

@end

NS_ASSUME_NONNULL_END
