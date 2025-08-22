//
//  ModTableViewCell.h
//  AmethystMods
//
//  Created by Copilot on 2025-08-22.
//

#import <UIKit/UIKit.h>
@class ModItem;

NS_ASSUME_NONNULL_BEGIN

@protocol ModTableViewCellDelegate <NSObject>
- (void)modCellDidTapToggle:(UITableViewCell *)cell;
- (void)modCellDidTapDelete:(UITableViewCell *)cell;
@end

@interface ModTableViewCell : UITableViewCell

@property (nonatomic, strong) UIImageView *modIconView;
@property (nonatomic, strong) UILabel *nameLabel;
@property (nonatomic, strong) UILabel *descLabel;
@property (nonatomic, strong) UIButton *toggleButton;
@property (nonatomic, strong) UIButton *deleteButton;

@property (nonatomic, weak) id<ModTableViewCellDelegate> delegate;

- (void)configureWithMod:(ModItem *)mod;

@end

NS_ASSUME_NONNULL_END