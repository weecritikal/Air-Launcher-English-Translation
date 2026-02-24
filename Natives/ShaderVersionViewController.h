//
//  ShaderVersionViewController.h
//  Amethyst
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

@end

NS_ASSUME_NONNULL_END
