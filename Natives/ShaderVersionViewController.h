//
//  ShaderVersionViewController.h
//  Flux
//
//  View controller for selecting shader versions
//

#import <UIKit/UIKit.h>
#import "ShaderItem.h"
#import "ShaderVersion.h"

NS_ASSUME_NONNULL_BEGIN

@class ShaderVersionViewController;

@protocol ShaderVersionViewControllerDelegate <NSObject>
- (void)shaderVersionViewController:(ShaderVersionViewController *)viewController didSelectVersion:(ShaderVersion *)version;
@end

@interface ShaderVersionViewController : UIViewController

@property (nonatomic, strong) UIActivityIndicatorView *activityIndicator;
@property (nonatomic, strong) ShaderItem *shaderItem;
@property (nonatomic, weak) id<ShaderVersionViewControllerDelegate> delegate;

// FCL style: pass in the preferred version and loader of the current profile
// ShaderVersionViewController will preselect the matching chip and move matching versions to the top
// Without them it keeps the original "All" default
// Fill in the preferred property that was asymmetric with ModVersionViewController (phase 3 unification)
@property (nonatomic, copy, nullable) NSString *preferredGameVersion;
@property (nonatomic, copy, nullable) NSString *preferredLoader;

@end

NS_ASSUME_NONNULL_END
