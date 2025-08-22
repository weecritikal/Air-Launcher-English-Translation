//
//  ModTableViewCell.m
//  AmethystMods
//
//  Created by Copilot on 2025-08-22.
//

#import "ModTableViewCell.h"
#import "ModItem.h"
#import "ModService.h"

@implementation ModTableViewCell

- (instancetype)initWithStyle:(UITableViewCellStyle)style reuseIdentifier:(NSString *)reuseIdentifier {
    if (self = [super initWithStyle:style reuseIdentifier:reuseIdentifier]) {
        _modIconView = [[UIImageView alloc] initWithFrame:CGRectZero];
        _modIconView.layer.cornerRadius = 6;
        _modIconView.clipsToBounds = YES;
        _modIconView.contentMode = UIViewContentModeScaleAspectFill;
        [self.contentView addSubview:_modIconView];

        _nameLabel = [[UILabel alloc] initWithFrame:CGRectZero];
        _nameLabel.font = [UIFont boldSystemFontOfSize:15];
        [self.contentView addSubview:_nameLabel];

        _descLabel = [[UILabel alloc] initWithFrame:CGRectZero];
        _descLabel.font = [UIFont systemFontOfSize:12];
        _descLabel.textColor = [UIColor darkGrayColor];
        _descLabel.numberOfLines = 2;
        [self.contentView addSubview:_descLabel];

        _toggleButton = [UIButton buttonWithType:UIButtonTypeSystem];
        [_toggleButton addTarget:self action:@selector(toggleTapped) forControlEvents:UIControlEventTouchUpInside];
        [self.contentView addSubview:_toggleButton];

        _deleteButton = [UIButton buttonWithType:UIButtonTypeSystem];
        [_deleteButton setTitleColor:[UIColor systemRedColor] forState:UIControlStateNormal];
        [_deleteButton setTitle:@"删除" forState:UIControlStateNormal];
        [_deleteButton addTarget:self action:@selector(deleteTapped) forControlEvents:UIControlEventTouchUpInside];
        [self.contentView addSubview:_deleteButton];
    }
    return self;
}

- (void)layoutSubviews {
    [super layoutSubviews];
    CGFloat padding = 10;
    CGFloat iconSize = 48;
    self.modIconView.frame = CGRectMake(padding, padding, iconSize, iconSize);
    CGFloat x = CGRectGetMaxX(self.modIconView.frame) + 10;
    CGFloat rightButtonsWidth = 140;
    CGFloat contentWidth = self.contentView.bounds.size.width - x - padding - rightButtonsWidth;
    self.nameLabel.frame = CGRectMake(x, padding, contentWidth, 20);
    self.descLabel.frame = CGRectMake(x, CGRectGetMaxY(self.nameLabel.frame) + 4, contentWidth, 36);
    self.toggleButton.frame = CGRectMake(self.contentView.bounds.size.width - rightButtonsWidth + 10, 12, 60, 28);
    self.deleteButton.frame = CGRectMake(self.contentView.bounds.size.width - 60 - 12, 12, 60, 28);
}

- (void)configureWithMod:(ModItem *)mod {
    self.nameLabel.text = mod.displayName ?: mod.fileName;
    self.descLabel.text = mod.modDescription ?: @"";
    NSString *toggleTitle = mod.disabled ? @"启用" : @"禁用";
    [self.toggleButton setTitle:toggleTitle forState:UIControlStateNormal];

    UIImage *placeholder = [UIImage systemImageNamed:@"cube.box"];
    self.modIconView.image = placeholder;
    if (mod.iconURL.length > 0) {
        NSString *cachePath = [[ModService sharedService] iconCachePathForURL:mod.iconURL];
        if ([[NSFileManager defaultManager] fileExistsAtPath:cachePath]) {
            NSData *d = [NSData dataWithContentsOfFile:cachePath];
            UIImage *img = [UIImage imageWithData:d];
            if (img) self.modIconView.image = img;
        } else {
            NSURL *url = [NSURL URLWithString:mod.iconURL];
            if (url) {
                dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
                    NSData *d = [NSData dataWithContentsOfURL:url];
                    if (d) {
                        [d writeToFile:cachePath atomically:YES];
                        dispatch_async(dispatch_get_main_queue(), ^{
                            UIImage *img = [UIImage imageWithData:d];
                            if (img) self.modIconView.image = img;
                        });
                    }
                });
            }
        }
    }
}

#pragma mark - Actions

- (void)toggleTapped {
    if ([self.delegate respondsToSelector:@selector(modCellDidTapToggle:)]) {
        [self.delegate modCellDidTapToggle:self];
    }
}

- (void)deleteTapped {
    if ([self.delegate respondsToSelector:@selector(modCellDidTapDelete:)]) {
        [self.delegate modCellDidTapDelete:self];
    }
}

@end