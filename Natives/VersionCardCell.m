// VersionCardCell.m
#import "VersionCardCell.h"

@implementation VersionCardCell

- (instancetype)initWithStyle:(UITableViewCellStyle)style reuseIdentifier:(NSString *)reuseIdentifier {
    self = [super initWithStyle:style reuseIdentifier:reuseIdentifier];
    if (self) {
        [self setupUI];
    }
    return self;
}

- (void)setupUI {
    // 图标
    _iconImageView = [[UIImageView alloc] init];
    _iconImageView.translatesAutoresizingMaskIntoConstraints = NO;
    _iconImageView.contentMode = UIViewContentModeScaleAspectFit;
    [self.contentView addSubview:_iconImageView];
    
    // 版本标签
    _versionLabel = [[UILabel alloc] init];
    _versionLabel.translatesAutoresizingMaskIntoConstraints = NO;
    _versionLabel.font = [UIFont boldSystemFontOfSize:16];
    _versionLabel.textColor = [UIColor labelColor];
    [self.contentView addSubview:_versionLabel];
    
    // 类型标签
    _typeLabel = [[UILabel alloc] init];
    _typeLabel.translatesAutoresizingMaskIntoConstraints = NO;
    _typeLabel.font = [UIFont systemFontOfSize:12];
    _typeLabel.textColor = [UIColor secondaryLabelColor];
    _typeLabel.layer.cornerRadius = 4;
    _typeLabel.layer.masksToBounds = YES;
    [self.contentView addSubview:_typeLabel];
    
    // 日期标签
    _dateLabel = [[UILabel alloc] init];
    _dateLabel.translatesAutoresizingMaskIntoConstraints = NO;
    _dateLabel.font = [UIFont systemFontOfSize:12];
    _dateLabel.textColor = [UIColor tertiaryLabelColor];
    [self.contentView addSubview:_dateLabel];
    
    [self setupConstraints];
}

- (void)setupConstraints {
    CGFloat margin = 12;
    
    [NSLayoutConstraint activateConstraints:@[
        // 图标
        [_iconImageView.leadingAnchor constraintEqualToAnchor:self.contentView.leadingAnchor constant:margin],
        [_iconImageView.centerYAnchor constraintEqualToAnchor:self.contentView.centerYAnchor],
        [_iconImageView.widthAnchor constraintEqualToConstant:40],
        [_iconImageView.heightAnchor constraintEqualToConstant:40],
        
        // 版本标签
        [_versionLabel.leadingAnchor constraintEqualToAnchor:_iconImageView.trailingAnchor constant:margin],
        [_versionLabel.topAnchor constraintEqualToAnchor:self.contentView.topAnchor constant:margin],
        [_versionLabel.trailingAnchor constraintLessThanOrEqualToAnchor:self.contentView.trailingAnchor constant:-margin],
        
        // 类型标签
        [_typeLabel.leadingAnchor constraintEqualToAnchor:_versionLabel.leadingAnchor],
        [_typeLabel.topAnchor constraintEqualToAnchor:_versionLabel.bottomAnchor constant:4],
        [_typeLabel.heightAnchor constraintEqualToConstant:18],
        
        // 日期标签
        [_dateLabel.leadingAnchor constraintEqualToAnchor:_typeLabel.trailingAnchor constant:8],
        [_dateLabel.centerYAnchor constraintEqualToAnchor:_typeLabel.centerYAnchor],
        [_dateLabel.trailingAnchor constraintLessThanOrEqualToAnchor:self.contentView.trailingAnchor constant:-margin],
        [_dateLabel.bottomAnchor constraintEqualToAnchor:self.contentView.bottomAnchor constant:-margin]
    ]];
}

- (void)configureWithIcon:(UIImage *)icon
                     date:(NSString *)date
                     type:(NSString *)type
                  version:(NSString *)version {
    self.iconImageView.image = icon;
    self.dateLabel.text = date;
    self.typeLabel.text = type;
    self.versionLabel.text = version;
    
    // 根据类型设置背景色
    if ([type isEqualToString:@"Release"]) {
        self.typeLabel.backgroundColor = [UIColor systemGreenColor];
        self.typeLabel.textColor = [UIColor whiteColor];
    } else if ([type isEqualToString:@"Beta"]) {
        self.typeLabel.backgroundColor = [UIColor systemOrangeColor];
        self.typeLabel.textColor = [UIColor whiteColor];
    } else if ([type isEqualToString:@"Alpha"]) {
        self.typeLabel.backgroundColor = [UIColor systemRedColor];
        self.typeLabel.textColor = [UIColor whiteColor];
    } else {
        self.typeLabel.backgroundColor = [UIColor systemGrayColor];
        self.typeLabel.textColor = [UIColor whiteColor];
    }
}

- (void)prepareForReuse {
    [super prepareForReuse];
    self.iconImageView.image = nil;
    self.dateLabel.text = nil;
    self.typeLabel.text = nil;
    self.versionLabel.text = nil;
}

@end
