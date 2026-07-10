// VersionCardCell.m
#import "VersionCardCell.h"

@implementation VersionCardCell

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        self.backgroundColor = [UIColor colorWithWhite:0.15 alpha:0.8];
        self.layer.cornerRadius = 12;
        self.layer.masksToBounds = YES;

        // 图标
        self.iconImageView = [[UIImageView alloc] init];
        self.iconImageView.translatesAutoresizingMaskIntoConstraints = NO;
        self.iconImageView.contentMode = UIViewContentModeScaleAspectFit;
        self.iconImageView.image = [UIImage systemImageNamed:@"cube.fill"];
        self.iconImageView.tintColor = [UIColor systemGreenColor];
        [self.contentView addSubview:self.iconImageView];

        // 版本号
        self.versionLabel = [[UILabel alloc] init];
        self.versionLabel.translatesAutoresizingMaskIntoConstraints = NO;
        self.versionLabel.font = [UIFont boldSystemFontOfSize:14];
        self.versionLabel.textAlignment = NSTextAlignmentCenter;
        self.versionLabel.textColor = [UIColor labelColor];
        self.versionLabel.adjustsFontSizeToFitWidth = YES;
        self.versionLabel.minimumScaleFactor = 0.7;
        [self.contentView addSubview:self.versionLabel];

        // 日期
        self.dateLabel = [[UILabel alloc] init];
        self.dateLabel.translatesAutoresizingMaskIntoConstraints = NO;
        self.dateLabel.font = [UIFont systemFontOfSize:10];
        self.dateLabel.textColor = [UIColor secondaryLabelColor];
        self.dateLabel.textAlignment = NSTextAlignmentCenter;
        [self.contentView addSubview:self.dateLabel];

        // 类型标签
        self.typeLabel = [[UILabel alloc] init];
        self.typeLabel.translatesAutoresizingMaskIntoConstraints = NO;
        self.typeLabel.font = [UIFont systemFontOfSize:9];
        self.typeLabel.textColor = [UIColor whiteColor];
        self.typeLabel.backgroundColor = [UIColor systemBlueColor];
        self.typeLabel.textAlignment = NSTextAlignmentCenter;
        self.typeLabel.layer.cornerRadius = 8;
        self.typeLabel.layer.masksToBounds = YES;
        [self.contentView addSubview:self.typeLabel];

        // FCL 风格：已安装标记（右上角绿色 ✓ 圆形徽章）
        self.installedBadge = [[UIView alloc] init];
        self.installedBadge.translatesAutoresizingMaskIntoConstraints = NO;
        self.installedBadge.backgroundColor = [UIColor systemGreenColor];
        self.installedBadge.layer.cornerRadius = 10;
        self.installedBadge.layer.masksToBounds = YES;
        self.installedBadge.hidden = YES;
        [self.contentView addSubview:self.installedBadge];

        UIImageView *checkmark = [[UIImageView alloc] init];
        checkmark.translatesAutoresizingMaskIntoConstraints = NO;
        checkmark.image = [UIImage systemImageNamed:@"checkmark" withConfiguration:[UIImageSymbolConfiguration configurationWithPointSize:9 weight:UIFontWeightBold]];
        checkmark.tintColor = [UIColor whiteColor];
        [self.installedBadge addSubview:checkmark];

        [NSLayoutConstraint activateConstraints:@[
            [self.iconImageView.topAnchor constraintEqualToAnchor:self.contentView.topAnchor constant:10],
            [self.iconImageView.centerXAnchor constraintEqualToAnchor:self.contentView.centerXAnchor],
            [self.iconImageView.widthAnchor constraintEqualToConstant:40],
            [self.iconImageView.heightAnchor constraintEqualToConstant:40],

            [self.versionLabel.topAnchor constraintEqualToAnchor:self.iconImageView.bottomAnchor constant:6],
            [self.versionLabel.leadingAnchor constraintEqualToAnchor:self.contentView.leadingAnchor constant:4],
            [self.versionLabel.trailingAnchor constraintEqualToAnchor:self.contentView.trailingAnchor constant:-4],

            [self.dateLabel.topAnchor constraintEqualToAnchor:self.versionLabel.bottomAnchor constant:2],
            [self.dateLabel.leadingAnchor constraintEqualToAnchor:self.contentView.leadingAnchor constant:4],
            [self.dateLabel.trailingAnchor constraintEqualToAnchor:self.contentView.trailingAnchor constant:-4],

            [self.typeLabel.bottomAnchor constraintEqualToAnchor:self.contentView.bottomAnchor constant:-6],
            [self.typeLabel.centerXAnchor constraintEqualToAnchor:self.contentView.centerXAnchor],
            [self.typeLabel.widthAnchor constraintEqualToConstant:45],
            [self.typeLabel.heightAnchor constraintEqualToConstant:16],

            // 已安装徽章：右上角
            [self.installedBadge.topAnchor constraintEqualToAnchor:self.contentView.topAnchor constant:6],
            [self.installedBadge.trailingAnchor constraintEqualToAnchor:self.contentView.trailingAnchor constant:-6],
            [self.installedBadge.widthAnchor constraintEqualToConstant:20],
            [self.installedBadge.heightAnchor constraintEqualToConstant:20],
            [checkmark.centerXAnchor constraintEqualToAnchor:self.installedBadge.centerXAnchor],
            [checkmark.centerYAnchor constraintEqualToAnchor:self.installedBadge.centerYAnchor]
        ]];
    }
    return self;
}

- (void)configureWithVersionId:(NSString *)versionId
                          date:(NSString *)date
                          type:(NSString *)type {
    self.versionLabel.text = versionId;
    self.dateLabel.text = date;
    self.typeLabel.text = type;

    // 根据类型设置颜色
    if ([type isEqualToString:@"正式版"] || [type isEqualToString:@"release"]) {
        self.typeLabel.backgroundColor = [UIColor systemGreenColor];
        self.typeLabel.text = @"正式版";
    } else if ([type isEqualToString:@"测试版"] || [type isEqualToString:@"snapshot"]) {
        self.typeLabel.backgroundColor = [UIColor systemOrangeColor];
        self.typeLabel.text = @"测试版";
    } else {
        self.typeLabel.backgroundColor = [UIColor systemPurpleColor];
        self.typeLabel.text = @"远古版";
    }
}

- (void)setInstalled:(BOOL)installed {
    self.installedBadge.hidden = !installed;
}

- (void)prepareForReuse {
    [super prepareForReuse];
    self.iconImageView.image = [UIImage systemImageNamed:@"cube.fill"];
    self.versionLabel.text = nil;
    self.dateLabel.text = nil;
    self.typeLabel.text = nil;
    self.typeLabel.backgroundColor = [UIColor systemBlueColor];
    self.installedBadge.hidden = YES;
}

@end
