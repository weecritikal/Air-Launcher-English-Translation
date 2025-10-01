//
// ModsManagerViewController.h
// AmethystMods
//
// Created by Copilot (adjusted) on 2025-08-22.
//

#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

@interface ModsManagerViewController : UIViewController

// Which profile's mods to show; if nil, module will default to @"default"
@property (nonatomic, copy, nullable) NSString *profileName;

@end

NS_ASSUME_NONNULL_END
