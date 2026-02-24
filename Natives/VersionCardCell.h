// VersionCardCell.h
#ifndef VERSION_CARD_CELL_H
#define VERSION_CARD_CELL_H

#import <UIKit/UIKit.h>

@interface VersionCardCell : UICollectionViewCell

@property (nonatomic, strong) UIImageView *iconImageView;
@property (nonatomic, strong) UILabel *versionLabel;
@property (nonatomic, strong) UILabel *dateLabel;
@property (nonatomic, strong) UILabel *typeLabel;

- (void)configureWithVersionId:(NSString *)versionId
                          date:(NSString *)date
                          type:(NSString *)type;

@end

#endif /* VERSION_CARD_CELL_H */
