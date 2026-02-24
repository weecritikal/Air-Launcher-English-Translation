// VersionCardCell.h
#ifndef VERSION_CARD_CELL_H
#define VERSION_CARD_CELL_H

#import <UIKit/UIKit.h>

@interface VersionCardCell : UITableViewCell

@property (nonatomic, strong) UIImageView *iconImageView;
@property (nonatomic, strong) UILabel *dateLabel;
@property (nonatomic, strong) UILabel *typeLabel;
@property (nonatomic, strong) UILabel *versionLabel;

- (void)configureWithIcon:(UIImage *)icon
                     date:(NSString *)date
                     type:(NSString *)type
                  version:(NSString *)version;

@end

#endif /* VERSION_CARD_CELL_H */
