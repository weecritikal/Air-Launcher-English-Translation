// VersionCardCell.h
#ifndef VERSION_CARD_CELL_H
#define VERSION_CARD_CELL_H

#import <UIKit/UIKit.h>

@interface VersionCardCell : UICollectionViewCell

@property (nonatomic, strong) UIImageView *iconImageView;
@property (nonatomic, strong) UILabel *versionLabel;
@property (nonatomic, strong) UILabel *dateLabel;
@property (nonatomic, strong) UILabel *typeLabel;
// FCL style: installed marker (a green ✓ badge, meaning the version is installed locally)
@property (nonatomic, strong) UIView *installedBadge;

- (void)configureWithVersionId:(NSString *)versionId
                          date:(NSString *)date
                          type:(NSString *)type;

/// Set the visibility of the installed marker (YES = show the green ✓ badge)
- (void)setInstalled:(BOOL)installed;

@end

#endif /* VERSION_CARD_CELL_H */
