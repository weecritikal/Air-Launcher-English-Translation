//
//  ModTableViewCell.h
//  AmethystMods
//
//  Created by Copilot on 2025-08-22.
//  Updated: supports multiple loader badges (fabric/forge/neoforge).
//

#import <UIKit/UIKit.h>
@class ModItem;

NS_ASSUME_NONNULL_BEGIN

@protocol ModTableViewCellDelegate <NSObject>
- (void)modCellDidTapToggle:(UITableViewCell *)cell;
- (void)modCellDidTapDelete:(UITableViewCell *)cell;
- (void)modCellDidTapOpenLink:(UITableViewCell *)cell; // 打开 homepage / sources
@end

@interface ModTableViewCell : UITableViewCell

@property (nonatomic, strong) UIImageView *modIconView;
// Up to three loader badges (fabric, forge, neoforge) shown left-to-right
@property (nonatomic, strong) UIImageView *loaderBadgeView1;
@property (nonatomic, strong) UIImageView *loaderBadgeView2;
@property (nonatomic, strong) UIImageView *loaderBadgeView3;

@property (nonatomic, strong) UILabel *nameLabel;
@property (nonatomic, strong) UILabel *descLabel;
@property (nonatomic, strong) UIButton *toggleButton;
@property (nonatomic, strong) UIButton *deleteButton;
@property (nonatomic, strong) UIButton *openLinkButton; // 地球图标

@property (nonatomic, weak) id<ModTableViewCellDelegate> delegate;

- (void)configureWithMod:(ModItem *)mod;

@end

NS_ASSUME_NONNULL_END