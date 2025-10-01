//
//  ModTableViewCell.m
//  AmethystMods
//
//  Created by Copilot on 2025-08-22.
//  Updated: multi-badge support, original rendering, fixed layout & hit areas.
//

#import "ModTableViewCell.h"
#import "ModItem.h"
#import "ModService.h"

@interface ModTableViewCell ()
@property (nonatomic, strong) ModItem *currentMod;
@end

@implementation ModTableViewCell

- (instancetype)initWithStyle:(UITableViewCellStyle)style reuseIdentifier:(NSString *)reuseIdentifier {
    if (self = [super initWithStyle:style reuseIdentifier:reuseIdentifier]) {
        _modIconView = [[UIImageView alloc] initWithFrame:CGRectZero];
        _modIconView.layer.cornerRadius = 6;
        _modIconView.clipsToBounds = YES;
        _modIconView.contentMode = UIViewContentModeScaleAspectFill;
        [self.contentView addSubview:_modIconView];

        _loaderBadgeView1 = [[UIImageView alloc] initWithFrame:CGRectZero];
        _loaderBadgeView1.contentMode = UIViewContentModeScaleAspectFit;
        _loaderBadgeView1.hidden = YES;
        [self.contentView addSubview:_loaderBadgeView1];

        _loaderBadgeView2 = [[UIImageView alloc] initWithFrame:CGRectZero];
        _loaderBadgeView2.contentMode = UIViewContentModeScaleAspectFit;
        _loaderBadgeView2.hidden = YES;
        [self.contentView addSubview:_loaderBadgeView2];

        _loaderBadgeView3 = [[UIImageView alloc] initWithFrame:CGRectZero];
        _loaderBadgeView3.contentMode = UIViewContentModeScaleAspectFit;
        _loaderBadgeView3.hidden = YES;
        [self.contentView addSubview:_loaderBadgeView3];

        _nameLabel = [[UILabel alloc] initWithFrame:CGRectZero];
        _nameLabel.font = [UIFont boldSystemFontOfSize:15];
        _nameLabel.numberOfLines = 1;
        [self.contentView addSubview:_nameLabel];

        _descLabel = [[UILabel alloc] initWithFrame:CGRectZero];
        _descLabel.font = [UIFont systemFontOfSize:12];
        _descLabel.textColor = [UIColor darkGrayColor];
        _descLabel.numberOfLines = 2;
        [self.contentView addSubview:_descLabel];

        _toggleButton = [UIButton buttonWithType:UIButtonTypeSystem];
        _toggleButton.titleLabel.font = [UIFont systemFontOfSize:14];
        [_toggleButton addTarget:self action:@selector(toggleTapped) forControlEvents:UIControlEventTouchUpInside];
        _toggleButton.contentEdgeInsets = UIEdgeInsetsMake(4, 8, 4, 8);
        [self.contentView addSubview:_toggleButton];

        _openLinkButton = [UIButton buttonWithType:UIButtonTypeSystem];
        _openLinkButton.tintColor = [UIColor systemBlueColor];
        _openLinkButton.titleLabel.font = [UIFont systemFontOfSize:14];
        [_openLinkButton addTarget:self action:@selector(openLinkTapped) forControlEvents:UIControlEventTouchUpInside];
        _openLinkButton.contentEdgeInsets = UIEdgeInsetsMake(6, 6, 6, 6);
        _openLinkButton.hidden = YES;
        _openLinkButton.contentHorizontalAlignment = UIControlContentHorizontalAlignmentCenter;
        _openLinkButton.imageView.contentMode = UIViewContentModeScaleAspectFit;
        [self.contentView addSubview:_openLinkButton];

        _deleteButton = [UIButton buttonWithType:UIButtonTypeSystem];
        [_deleteButton setTitleColor:[UIColor systemRedColor] forState:UIControlStateNormal];
        _deleteButton.titleLabel.font = [UIFont systemFontOfSize:14];
        [_deleteButton setTitle:@"删除" forState:UIControlStateNormal];
        [_deleteButton addTarget:self action:@selector(deleteTapped) forControlEvents:UIControlEventTouchUpInside];
        _deleteButton.contentEdgeInsets = UIEdgeInsetsMake(4, 8, 4, 8);
        [self.contentView addSubview:_deleteButton];

        self.selectionStyle = UITableViewCellSelectionStyleNone;
    }
    return self;
}

- (void)layoutSubviews {
    [super layoutSubviews];
    CGFloat padding = 10;
    CGFloat iconSize = 48;
    self.modIconView.frame = CGRectMake(padding, padding, iconSize, iconSize);

    CGFloat x = CGRectGetMaxX(self.modIconView.frame) + 10;
    CGFloat rightButtonsWidth = 170;
    CGFloat contentWidth = self.contentView.bounds.size.width - x - padding - rightButtonsWidth;

    // badges: up to three small icons horizontally
    CGFloat badgeSize = 18;
    CGFloat badgeY = padding + 2;
    CGFloat badgeX = x;
    UIImageView *badges[3] = {self.loaderBadgeView1, self.loaderBadgeView2, self.loaderBadgeView3};
    for (int i = 0; i < 3; i++) {
        UIImageView *bv = badges[i];
        bv.frame = CGRectMake(badgeX, badgeY, badgeSize, badgeSize);
        badgeX += badgeSize + 6;
    }

    CGFloat nameX = x;
    // if first badge visible, shift nameX to after badges area for alignment
    if (!self.loaderBadgeView1.hidden) {
        // compute width used by visible badges
        CGFloat used = 0;
        for (int i = 0; i < 3; i++) {
            UIImageView *bv = badges[i];
            if (!bv.hidden) used += badgeSize + 6;
        }
        nameX += used;
    }
    self.nameLabel.frame = CGRectMake(nameX, padding, contentWidth - (nameX - x), 20);
    self.descLabel.frame = CGRectMake(x, CGRectGetMaxY(self.nameLabel.frame) + 4, contentWidth, 36);

    // buttons on right: delete | toggle | openLink
    CGFloat btnW = 60;
    CGFloat spacing = 8;
    CGFloat right = self.contentView.bounds.size.width - padding;
    self.deleteButton.frame = CGRectMake(right - btnW, 12, btnW, 28);
    right = CGRectGetMinX(self.deleteButton.frame) - spacing;
    self.toggleButton.frame = CGRectMake(right - btnW, 12, btnW, 28);
    right = CGRectGetMinX(self.toggleButton.frame) - spacing;
    CGFloat openW = 44;
    self.openLinkButton.frame = CGRectMake(right - openW, 12, openW, 28);

    // Bring interactive controls to front
    [self.contentView bringSubviewToFront:self.deleteButton];
    [self.contentView bringSubviewToFront:self.toggleButton];
    [self.contentView bringSubviewToFront:self.openLinkButton];
}

- (void)prepareForReuse {
    [super prepareForReuse];
    self.modIconView.image = nil;
    self.loaderBadgeView1.image = nil; self.loaderBadgeView1.hidden = YES;
    self.loaderBadgeView2.image = nil; self.loaderBadgeView2.hidden = YES;
    self.loaderBadgeView3.image = nil; self.loaderBadgeView3.hidden = YES;
    self.openLinkButton.hidden = YES;
    [self.openLinkButton setImage:nil forState:UIControlStateNormal];
    self.nameLabel.attributedText = nil;
    self.nameLabel.text = nil;
    self.descLabel.text = nil;
    self.currentMod = nil;
}

- (void)configureWithMod:(ModItem *)mod {
    self.currentMod = mod;

    // name + version
    NSString *name = mod.displayName ?: mod.fileName;
    NSString *version = mod.version ?: @"";
    if (version.length > 0) {
        NSMutableAttributedString *att = [[NSMutableAttributedString alloc] initWithString:name attributes:@{NSFontAttributeName: [UIFont boldSystemFontOfSize:15], NSForegroundColorAttributeName: [UIColor labelColor]}];
        NSAttributedString *verAttr = [[NSAttributedString alloc] initWithString:[NSString stringWithFormat:@"  %@", version] attributes:@{NSFontAttributeName: [UIFont systemFontOfSize:13], NSForegroundColorAttributeName: [UIColor systemGrayColor]}];
        [att appendAttributedString:verAttr];
        self.nameLabel.attributedText = att;
    } else {
        self.nameLabel.text = name;
    }

    // description
    self.descLabel.text = mod.modDescription ?: @"";

    // toggle text
    NSString *toggleTitle = mod.disabled ? @"启用" : @"禁用";
    [self.toggleButton setTitle:toggleTitle forState:UIControlStateNormal];

    // mod icon (as before)
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

    // loader badges: try to show up to three icons: Fabric, Forge, NeoForge (in that order)
    NSArray<UIImage *> *badgeImgs = [self loaderIconsForMod:mod traitCollection:self.traitCollection];
    // assign to available badge views
    NSArray<UIImageView *> *badgeViews = @[self.loaderBadgeView1, self.loaderBadgeView2, self.loaderBadgeView3];
    for (NSUInteger i = 0; i < badgeViews.count; i++) {
        UIImageView *bv = badgeViews[i];
        if (i < badgeImgs.count && badgeImgs[i]) {
            UIImage *orig = [badgeImgs[i] imageWithRenderingMode:UIImageRenderingModeAlwaysOriginal];
            bv.image = orig;
            bv.hidden = NO;
        } else {
            bv.image = nil;
            bv.hidden = YES;
        }
    }

    // open link button
    if (mod.homepage.length > 0 || mod.sources.length > 0) {
        self.openLinkButton.hidden = NO;
        UIImage *globe = [UIImage systemImageNamed:@"globe"];
        if (globe) {
            globe = [globe imageWithRenderingMode:UIImageRenderingModeAlwaysOriginal];
            [self.openLinkButton setImage:globe forState:UIControlStateNormal];
            [self.openLinkButton setTitle:@"" forState:UIControlStateNormal];
        } else {
            [self.openLinkButton setTitle:@"🌐" forState:UIControlStateNormal];
        }
        self.openLinkButton.userInteractionEnabled = YES;
    } else {
        self.openLinkButton.hidden = YES;
    }
}

#pragma mark - loader icon loader

- (NSArray<UIImage *> *)loaderIconsForMod:(ModItem *)mod traitCollection:(UITraitCollection *)traits {
    if (!mod) return @[];

    NSMutableArray<UIImage *> *out = [NSMutableArray array];

    // Helper to load image by base name (fabric/forge/neoforge)
    __weak typeof(self) wself = self;
    UIImage *(^loadImage)(NSString *) = ^UIImage *(NSString *base) {
        if (!base) return nil;
        NSString *suffix = @"light";
        if (@available(iOS 12.0, *)) {
            if (traits) suffix = (traits.userInterfaceStyle == UIUserInterfaceStyleDark) ? @"dark" : @"light";
            else suffix = ([UIScreen mainScreen].traitCollection.userInterfaceStyle == UIUserInterfaceStyleDark) ? @"dark":@"light";
        }
        NSString *resourceName = [NSString stringWithFormat:@"%@_%@", base, suffix];
        UIImage *img = nil;
        NSArray<NSString *> *resourceDirCandidates = @[@"ModLoaderIcons", @"Natives/ModLoaderIcons", @"Natives/ModLoaderIcons/Resources"];
        for (NSString *dir in resourceDirCandidates) {
            NSString *filePath = [[[NSBundle mainBundle] resourcePath] stringByAppendingPathComponent:dir];
            filePath = [filePath stringByAppendingPathComponent:[resourceName stringByAppendingPathExtension:@"png"]];
            if ([[NSFileManager defaultManager] fileExistsAtPath:filePath]) {
                img = [UIImage imageWithContentsOfFile:filePath];
                if (img) break;
            }
        }
        if (!img) {
            NSString *fileInBundle = [[NSBundle mainBundle] pathForResource:resourceName ofType:@"png"];
            if (fileInBundle) img = [UIImage imageWithContentsOfFile:fileInBundle];
        }
        if (!img) img = [UIImage imageNamed:resourceName];
        return img;
    };

    // Always try to add in order Fabric, Forge, NeoForge if the mod supports them
    if (mod.isFabric) {
        UIImage *i = loadImage(@"fabric");
        if (i) [out addObject:i];
    }
    if (mod.isForge) {
        UIImage *i = loadImage(@"forge");
        if (i) [out addObject:i];
    }
    if (mod.isNeoForge) {
        UIImage *i = loadImage(@"neoforge");
        if (i) [out addObject:i];
    }

    return out;
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

- (void)openLinkTapped {
    if (!self.currentMod) return;
    if (!(self.currentMod.homepage.length || self.currentMod.sources.length)) return;
    if ([self.delegate respondsToSelector:@selector(modCellDidTapOpenLink:)]) {
        [self.delegate modCellDidTapOpenLink:self];
    }
}

@end