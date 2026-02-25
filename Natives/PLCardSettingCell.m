//
//  PLCardSettingCell.m
//  Amethyst
//
//  Card style setting cell for PLPrefTableViewController
//

#import "PLCardSettingCell.h"

static const CGFloat kCardCornerRadius = 12.0;
static const CGFloat kCardSpacing = 2.0;
static const CGFloat kCardPadding = 16.0;
static const CGFloat kIconSize = 28.0;

@interface PLCardSettingCell ()
@property (nonatomic, strong, readwrite) UIView *cardContentView;
@property (nonatomic, strong, readwrite) UILabel *titleLabel;
@property (nonatomic, strong, readwrite) UILabel *subtitleLabel;
@property (nonatomic, strong, readwrite) UILabel *detailLabel;
@property (nonatomic, strong, readwrite) UIImageView *iconImageView;
@property (nonatomic, strong) UIView *accessoryContainerView;
@property (nonatomic, assign) PLCardPosition cardPosition;
@end

@implementation PLCardSettingCell

- (instancetype)initWithStyle:(UITableViewCellStyle)style reuseIdentifier:(NSString *)reuseIdentifier {
    self = [super initWithStyle:style reuseIdentifier:reuseIdentifier];
    if (self) {
        [self setupUI];
    }
    return self;
}

- (void)setupUI {
    // 隐藏默认的选中背景
    self.selectionStyle = UITableViewCellSelectionStyleNone;
    self.backgroundColor = [UIColor clearColor];
    self.contentView.backgroundColor = [UIColor clearColor];
    
    // 卡片容器
    _cardContentView = [[UIView alloc] init];
    _cardContentView.backgroundColor = [UIColor secondarySystemBackgroundColor];
    _cardContentView.layer.cornerRadius = kCardCornerRadius;
    _cardContentView.layer.masksToBounds = YES;
    _cardContentView.translatesAutoresizingMaskIntoConstraints = NO;
    [self.contentView addSubview:_cardContentView];
    
    // 图标
    _iconImageView = [[UIImageView alloc] init];
    _iconImageView.contentMode = UIViewContentModeScaleAspectFit;
    _iconImageView.tintColor = [UIColor systemBlueColor];
    _iconImageView.translatesAutoresizingMaskIntoConstraints = NO;
    [_cardContentView addSubview:_iconImageView];
    
    // 标题
    _titleLabel = [[UILabel alloc] init];
    _titleLabel.font = [UIFont systemFontOfSize:16 weight:UIFontWeightMedium];
    _titleLabel.textColor = [UIColor labelColor];
    _titleLabel.translatesAutoresizingMaskIntoConstraints = NO;
    [_cardContentView addSubview:_titleLabel];
    
    // 副标题
    _subtitleLabel = [[UILabel alloc] init];
    _subtitleLabel.font = [UIFont systemFontOfSize:12 weight:UIFontWeightRegular];
    _subtitleLabel.textColor = [UIColor secondaryLabelColor];
    _subtitleLabel.numberOfLines = 2;
    _subtitleLabel.translatesAutoresizingMaskIntoConstraints = NO;
    [_cardContentView addSubview:_subtitleLabel];
    
    // 详情标签（用于显示当前值）
    _detailLabel = [[UILabel alloc] init];
    _detailLabel.font = [UIFont systemFontOfSize:14 weight:UIFontWeightRegular];
    _detailLabel.textColor = [UIColor secondaryLabelColor];
    _detailLabel.textAlignment = NSTextAlignmentRight;
    _detailLabel.translatesAutoresizingMaskIntoConstraints = NO;
    [_cardContentView addSubview:_detailLabel];
    
    // 附件容器
    _accessoryContainerView = [[UIView alloc] init];
    _accessoryContainerView.translatesAutoresizingMaskIntoConstraints = NO;
    [_cardContentView addSubview:_accessoryContainerView];
    
    // 设置约束
    [self setupConstraints];
}

- (void)setupConstraints {
    UILayoutGuide *safeArea = self.contentView.safeAreaLayoutGuide;
    
    [NSLayoutConstraint activateConstraints:@[
        // 卡片容器约束
        [_cardContentView.topAnchor constraintEqualToAnchor:self.contentView.topAnchor constant:kCardSpacing],
        [_cardContentView.leadingAnchor constraintEqualToAnchor:self.contentView.leadingAnchor],
        [_cardContentView.trailingAnchor constraintEqualToAnchor:self.contentView.trailingAnchor],
        [_cardContentView.bottomAnchor constraintEqualToAnchor:self.contentView.bottomAnchor constant:-kCardSpacing],
        
        // 图标约束
        [_iconImageView.leadingAnchor constraintEqualToAnchor:_cardContentView.leadingAnchor constant:kCardPadding],
        [_iconImageView.centerYAnchor constraintEqualToAnchor:_cardContentView.centerYAnchor],
        [_iconImageView.widthAnchor constraintEqualToConstant:kIconSize],
        [_iconImageView.heightAnchor constraintEqualToConstant:kIconSize],
        
        // 标题约束
        [_titleLabel.leadingAnchor constraintEqualToAnchor:_iconImageView.trailingAnchor constant:12],
        [_titleLabel.topAnchor constraintEqualToAnchor:_cardContentView.topAnchor constant:12],
        [_titleLabel.trailingAnchor constraintLessThanOrEqualToAnchor:_accessoryContainerView.leadingAnchor constant:-8],
        
        // 副标题约束
        [_subtitleLabel.leadingAnchor constraintEqualToAnchor:_titleLabel.leadingAnchor],
        [_subtitleLabel.topAnchor constraintEqualToAnchor:_titleLabel.bottomAnchor constant:2],
        [_subtitleLabel.trailingAnchor constraintLessThanOrEqualToAnchor:_accessoryContainerView.leadingAnchor constant:-8],
        [_subtitleLabel.bottomAnchor constraintLessThanOrEqualToAnchor:_cardContentView.bottomAnchor constant:-12],
        
        // 详情标签约束（与标题同行）
        [_detailLabel.centerYAnchor constraintEqualToAnchor:_titleLabel.centerYAnchor],
        [_detailLabel.trailingAnchor constraintEqualToAnchor:_accessoryContainerView.leadingAnchor constant:-8],
        
        // 附件容器约束
        [_accessoryContainerView.trailingAnchor constraintEqualToAnchor:_cardContentView.trailingAnchor constant:-kCardPadding],
        [_accessoryContainerView.centerYAnchor constraintEqualToAnchor:_cardContentView.centerYAnchor],
        [_accessoryContainerView.widthAnchor constraintGreaterThanOrEqualToConstant:60],
        [_accessoryContainerView.heightAnchor constraintEqualToConstant:32]
    ]];
}

- (void)configureWithTitle:(NSString *)title 
                   subtitle:(NSString *)subtitle 
                       icon:(NSString *)iconName 
                     detail:(NSString *)detail 
                destructive:(BOOL)destructive {
    
    _titleLabel.text = title;
    _titleLabel.textColor = destructive ? [UIColor systemRedColor] : [UIColor labelColor];
    
    _subtitleLabel.text = subtitle;
    _subtitleLabel.hidden = !subtitle || subtitle.length == 0;
    
    _detailLabel.text = detail;
    _detailLabel.hidden = !detail || detail.length == 0;
    
    if (iconName && iconName.length > 0) {
        if (@available(iOS 13.0, *)) {
            UIImageSymbolConfiguration *config = [UIImageSymbolConfiguration configurationWithPointSize:18 weight:UIImageSymbolWeightMedium];
            _iconImageView.image = [UIImage systemImageNamed:iconName withConfiguration:config];
        } else {
            _iconImageView.image = [UIImage imageNamed:iconName];
        }
        _iconImageView.hidden = NO;
    } else {
        _iconImageView.hidden = YES;
    }
    
    if (destructive) {
        _iconImageView.tintColor = [UIColor systemRedColor];
    } else {
        _iconImageView.tintColor = [UIColor systemBlueColor];
    }
}

- (void)setCardPosition:(PLCardPosition)position {
    _cardPosition = position;
    
    // 根据位置调整圆角
    UIBezierPath *maskPath = nil;
    CGRect bounds = _cardContentView.bounds;
    
    switch (position) {
        case PLCardPositionTop:
            // 只有顶部圆角
            maskPath = [UIBezierPath bezierPathWithRoundedRect:bounds 
                                             byRoundingCorners:UIRectCornerTopLeft | UIRectCornerTopRight 
                                                   cornerRadii:CGSizeMake(kCardCornerRadius, kCardCornerRadius)];
            break;
        case PLCardPositionMiddle:
            // 无圆角
            maskPath = [UIBezierPath bezierPathWithRect:bounds];
            break;
        case PLCardPositionBottom:
            // 只有底部圆角
            maskPath = [UIBezierPath bezierPathWithRoundedRect:bounds 
                                             byRoundingCorners:UIRectCornerBottomLeft | UIRectCornerBottomRight 
                                                   cornerRadii:CGSizeMake(kCardCornerRadius, kCardCornerRadius)];
            break;
        case PLCardPositionSingle:
            // 四个角都圆角
            maskPath = [UIBezierPath bezierPathWithRoundedRect:bounds cornerRadius:kCardCornerRadius];
            break;
    }
    
    CAShapeLayer *maskLayer = [CAShapeLayer layer];
    maskLayer.path = maskPath.CGPath;
    _cardContentView.layer.mask = maskLayer;
}

- (void)setCustomAccessoryView:(UIView *)view {
    // 清除旧的附件视图
    for (UIView *subview in _accessoryContainerView.subviews) {
        [subview removeFromSuperview];
    }
    
    if (view) {
        view.translatesAutoresizingMaskIntoConstraints = NO;
        [_accessoryContainerView addSubview:view];
        
        [NSLayoutConstraint activateConstraints:@[
            [view.centerXAnchor constraintEqualToAnchor:_accessoryContainerView.centerXAnchor],
            [view.centerYAnchor constraintEqualToAnchor:_accessoryContainerView.centerYAnchor],
            [view.widthAnchor constraintLessThanOrEqualToAnchor:_accessoryContainerView.widthAnchor],
            [view.heightAnchor constraintLessThanOrEqualToAnchor:_accessoryContainerView.heightAnchor]
        ]];
    }
}

- (void)prepareForReuse {
    [super prepareForReuse];
    _titleLabel.text = nil;
    _subtitleLabel.text = nil;
    _detailLabel.text = nil;
    _iconImageView.image = nil;
    _iconImageView.hidden = NO;
    self.accessoryType = UITableViewCellAccessoryNone;
    
    // 清除附件视图
    for (UIView *subview in _accessoryContainerView.subviews) {
        [subview removeFromSuperview];
    }
    
    // 重置背景色
    _cardContentView.backgroundColor = [UIColor secondarySystemBackgroundColor];
}

- (void)setSelected:(BOOL)selected animated:(BOOL)animated {
    [super setSelected:selected animated:animated];
    
    if (selected) {
        _cardContentView.backgroundColor = [UIColor tertiarySystemBackgroundColor];
    } else {
        _cardContentView.backgroundColor = [UIColor secondarySystemBackgroundColor];
    }
}

- (void)setHighlighted:(BOOL)highlighted animated:(BOOL)animated {
    [super setHighlighted:highlighted animated:animated];
    
    if (highlighted) {
        _cardContentView.backgroundColor = [UIColor tertiarySystemBackgroundColor];
    } else {
        _cardContentView.backgroundColor = [UIColor secondarySystemBackgroundColor];
    }
}

@end
