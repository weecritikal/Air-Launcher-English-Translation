//
//  PLCardSettingCell.h
//  Amethyst
//
//  Card style setting cell for PLPrefTableViewController
//

#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSInteger, PLCardPosition) {
    PLCardPositionTop = 0,      // 顶部圆角
    PLCardPositionMiddle = 1,   // 中间无圆角
    PLCardPositionBottom = 2,   // 底部圆角
    PLCardPositionSingle = 3    // 单独卡片（四个圆角）
};

@interface PLCardSettingCell : UITableViewCell

@property (nonatomic, strong, readonly) UILabel *titleLabel;
@property (nonatomic, strong, readonly) UILabel *subtitleLabel;
@property (nonatomic, strong, readonly) UILabel *detailLabel;
@property (nonatomic, strong, readonly) UIImageView *iconImageView;
@property (nonatomic, strong, readonly) UIView *cardContentView;

- (void)configureWithTitle:(NSString *)title 
                   subtitle:(nullable NSString *)subtitle 
                       icon:(nullable NSString *)iconName 
                     detail:(nullable NSString *)detail 
                destructive:(BOOL)destructive;

- (void)setCardPosition:(PLCardPosition)position;

- (void)setAccessoryView:(UIView *)view;

@end

NS_ASSUME_NONNULL_END
