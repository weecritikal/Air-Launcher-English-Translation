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

// FCL style: pass in the preferred version and loader of the current profile
// ShaderVersionViewController 会优先选中匹配的 chip，并把匹配的版本置顶
// Without them it keeps the original "All" default
// 补齐与 ModVersionViewController 不对称的 preferred 属性（阶段3统一）
@property (nonatomic, copy, nullable) NSString *preferredGameVersion;
@property (nonatomic, copy, nullable) NSString *preferredLoader;

@end

NS_ASSUME_NONNULL_END
