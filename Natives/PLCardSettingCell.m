//
//  PLCardSettingCell.m
//  Amethyst
//
//  Card style setting cell for PLPrefTableViewController
//  Modern design with blur effect, shadow and spring animations
//

#import "PLCardSettingCell.h"
#import <QuartzCore/QuartzCore.h>

static const CGFloat kCardCornerRadius = 16.0;
static const CGFloat kCardSpacing = 6.0;
static const CGFloat kCardPadding = 16.0;
static const CGFloat kIconSize = 28.0;
static const CGFloat kCardHeight = 64.0;

@interface PLCardSettingCell ()
@property (nonatomic, strong, readwrite) UIView *cardContentView;
@property (nonatomic, strong, readwrite) UILabel *titleLabel;
@property (nonatomic, strong, readwrite) UILabel *subtitleLabel;
@property (nonatomic, strong, readwrite) UILabel *detailLabel;
@property (nonatomic, strong, readwrite) UIImageView *iconImageView;
@property (nonatomic, strong) UIView *accessoryContainerView;
@property (nonatomic, strong) UIVisualEffectView *blurView;
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
    
    // 卡片容器 - 用于阴影
    _cardContentView = [[UIView alloc] init];
    _cardContentView.backgroundColor = [UIColor clearColor];
    _cardContentView.layer.cornerRadius = kCardCornerRadius;
    _cardContentView.layer.shadowColor = [UIColor blackColor].CGColor;
    _cardContentView.layer.shadowOffset = CGSizeMake(0, 4);
    _cardContentView.layer.shadowOpacity = 0.08;
    _cardContentView.layer.shadowRadius = 12;
    _cardContentView.layer.masksToBounds = NO;
    _cardContentView.translatesAutoresizingMaskIntoConstraints = NO;
    [self.contentView addSubview:_cardContentView];
    
    // 模糊背景
    UIBlurEffect *blurEffect = [UIBlurEffect effectWithStyle:UIBlurEffectStyleSystemMaterial];
    _blurView = [[UIVisualEffectView alloc] initWithEffect:blurEffect];
    _blurView.layer.cornerRadius = kCardCornerRadius;
    _blurView.layer.masksToBounds = YES;
    _blurView.layer.borderWidth = 0.5;
    _blurView.layer.borderColor = [UIColor separatorColor].CGColor;
    _blurView.translatesAutoresizingMaskIntoConstraints = NO;
    [_cardContentView addSubview:_blurView];
    
    // 内容容器
    UIView *contentContainer = [[UIView alloc] init];
    contentContainer.translatesAutoresizingMaskIntoConstraints = NO;
    [_blurView.contentView addSubview:contentContainer];
    
    // 图标背景
    UIView *iconBg = [[UIView alloc] init];
    iconBg.backgroundColor = [UIColor tertiarySystemBackgroundColor];
    iconBg.layer.cornerRadius = 10;
    iconBg.translatesAutoresizingMaskIntoConstraints = NO;
    [contentContainer addSubview:iconBg];
    
    // 图标
    _iconImageView = [[UIImageView alloc] init];
    _iconImageView.contentMode = UIViewContentModeScaleAspectFit;
    _iconImageView.tintColor = [UIColor systemBlueColor];
    _iconImageView.translatesAutoresizingMaskIntoConstraints = NO;
    [iconBg addSubview:_iconImageView];
    
    // 标题
    _titleLabel = [[UILabel alloc] init];
    _titleLabel.font = [UIFont systemFontOfSize:16 weight:UIFontWeightSemibold];
    _titleLabel.textColor = [UIColor labelColor];
    _titleLabel.translatesAutoresizingMaskIntoConstraints = NO;
    [contentContainer addSubview:_titleLabel];
    
    // 副标题
    _subtitleLabel = [[UILabel alloc] init];
    _subtitleLabel.font = [UIFont systemFontOfSize:12 weight:UIFontWeightRegular];
    _subtitleLabel.textColor = [UIColor secondaryLabelColor];
    _subtitleLabel.numberOfLines = 2;
    _subtitleLabel.translatesAutoresizingMaskIntoConstraints = NO;
    [contentContainer addSubview:_subtitleLabel];
    
    // 详情标签（用于显示当前值）
    _detailLabel = [[UILabel alloc] init];
    _detailLabel.font = [UIFont systemFontOfSize:14 weight:UIFontWeightMedium];
    _detailLabel.textColor = [UIColor tertiaryLabelColor];
    _detailLabel.textAlignment = NSTextAlignmentRight;
    _detailLabel.translatesAutoresizingMaskIntoConstraints = NO;
    [contentContainer addSubview:_detailLabel];
    
    // 附件容器
    _accessoryContainerView = [[UIView alloc] init];
    _accessoryContainerView.translatesAutoresizingMaskIntoConstraints = NO;
    [contentContainer addSubview:_accessoryContainerView];
    
    // 设置约束
    [self setupConstraints:contentContainer iconBg:iconBg];
}

- (void)setupConstraints:(UIView *)contentContainer iconBg:(UIView *)iconBg {
    [NSLayoutConstraint activateConstraints:@[
        // 卡片容器约束
        [_cardContentView.topAnchor constraintEqualToAnchor:self.contentView.topAnchor constant:kCardSpacing],
        [_cardContentView.leadingAnchor constraintEqualToAnchor:self.contentView.leadingAnchor],
        [_cardContentView.trailingAnchor constraintEqualToAnchor:self.contentView.trailingAnchor],
        [_cardContentView.bottomAnchor constraintEqualToAnchor:self.contentView.bottomAnchor constant:-kCardSpacing],
        
        // 模糊背景约束
        [_blurView.topAnchor constraintEqualToAnchor:_cardContentView.topAnchor],
        [_blurView.leadingAnchor constraintEqualToAnchor:_cardContentView.leadingAnchor],
        [_blurView.trailingAnchor constraintEqualToAnchor:_cardContentView.trailingAnchor],
        [_blurView.bottomAnchor constraintEqualToAnchor:_cardContentView.bottomAnchor],
        
        // 内容容器约束
        [contentContainer.topAnchor constraintEqualToAnchor:_blurView.contentView.topAnchor],
        [contentContainer.leadingAnchor constraintEqualToAnchor:_blurView.contentView.leadingAnchor],
        [contentContainer.trailingAnchor constraintEqualToAnchor:_blurView.contentView.trailingAnchor],
        [contentContainer.bottomAnchor constraintEqualToAnchor:_blurView.contentView.bottomAnchor],
        [contentContainer.heightAnchor constraintEqualToConstant:kCardHeight],
        
        // 图标背景约束
        [iconBg.leadingAnchor constraintEqualToAnchor:contentContainer.leadingAnchor constant:kCardPadding],
        [iconBg.centerYAnchor constraintEqualToAnchor:contentContainer.centerYAnchor],
        [iconBg.widthAnchor constraintEqualToConstant:36],
        [iconBg.heightAnchor constraintEqualToConstant:36],
        
        // 图标约束
        [_iconImageView.centerXAnchor constraintEqualToAnchor:iconBg.centerXAnchor],
        [_iconImageView.centerYAnchor constraintEqualToAnchor:iconBg.centerYAnchor],
        [_iconImageView.widthAnchor constraintEqualToConstant:kIconSize],
        [_iconImageView.heightAnchor constraintEqualToConstant:kIconSize],
        
        // 标题约束
        [_titleLabel.leadingAnchor constraintEqualToAnchor:iconBg.trailingAnchor constant:12],
        [_titleLabel.topAnchor constraintEqualToAnchor:contentContainer.topAnchor constant:14],
        [_titleLabel.trailingAnchor constraintLessThanOrEqualToAnchor:_detailLabel.leadingAnchor constant:-8],
        
        // 副标题约束
        [_subtitleLabel.leadingAnchor constraintEqualToAnchor:_titleLabel.leadingAnchor],
        [_subtitleLabel.topAnchor constraintEqualToAnchor:_titleLabel.bottomAnchor constant:2],
        [_subtitleLabel.trailingAnchor constraintLessThanOrEqualToAnchor:_accessoryContainerView.leadingAnchor constant:-8],
        
        // 详情标签约束
        [_detailLabel.centerYAnchor constraintEqualToAnchor:_titleLabel.centerYAnchor],
        [_detailLabel.trailingAnchor constraintEqualToAnchor:_accessoryContainerView.leadingAnchor constant:-8],
        
        // 附件容器约束
        [_accessoryContainerView.trailingAnchor constraintEqualToAnchor:contentContainer.trailingAnchor constant:-kCardPadding],
        [_accessoryContainerView.centerYAnchor constraintEqualToAnchor:contentContainer.centerYAnchor],
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
    CGRect bounds = _blurView.bounds;
    
    switch (position) {
        case PLCardPositionTop:
            maskPath = [UIBezierPath bezierPathWithRoundedRect:bounds 
                                             byRoundingCorners:UIRectCornerTopLeft | UIRectCornerTopRight 
                                                   cornerRadii:CGSizeMake(kCardCornerRadius, kCardCornerRadius)];
            break;
        case PLCardPositionMiddle:
            maskPath = [UIBezierPath bezierPathWithRect:bounds];
            break;
        case PLCardPositionBottom:
            maskPath = [UIBezierPath bezierPathWithRoundedRect:bounds 
                                             byRoundingCorners:UIRectCornerBottomLeft | UIRectCornerBottomRight 
                                                   cornerRadii:CGSizeMake(kCardCornerRadius, kCardCornerRadius)];
            break;
        case PLCardPositionSingle:
            maskPath = [UIBezierPath bezierPathWithRoundedRect:bounds cornerRadius:kCardCornerRadius];
            break;
    }
    
    CAShapeLayer *maskLayer = [CAShapeLayer layer];
    maskLayer.path = maskPath.CGPath;
    _blurView.layer.mask = maskLayer;
    
    // 根据位置调整阴影
    switch (position) {
        case PLCardPositionSingle:
            _cardContentView.layer.shadowOpacity = 0.08;
            break;
        case PLCardPositionTop:
        case PLCardPositionBottom:
            _cardContentView.layer.shadowOpacity = 0.04;
            break;
        case PLCardPositionMiddle:
            _cardContentView.layer.shadowOpacity = 0;
            break;
    }
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
    
    // 重置阴影
    _cardContentView.layer.shadowOpacity = 0.08;
}

// 非线性按压动画
- (void)touchesBegan:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    [super touchesBegan:touches withEvent:event];
    [UIView animateWithDuration:0.4 delay:0 usingSpringWithDamping:0.5 initialSpringVelocity:0.5 options:UIViewAnimationOptionAllowUserInteraction animations:^{
        self.transform = CGAffineTransformMakeScale(0.97, 0.97);
        self.cardContentView.layer.shadowOpacity = 0.02;
    } completion:nil];
}

- (void)touchesEnded:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    [super touchesEnded:touches withEvent:event];
    [UIView animateWithDuration:0.4 delay:0 usingSpringWithDamping:0.5 initialSpringVelocity:0.5 options:UIViewAnimationOptionAllowUserInteraction animations:^{
        self.transform = CGAffineTransformIdentity;
        self.cardContentView.layer.shadowOpacity = 0.08;
    } completion:nil];
}

- (void)touchesCancelled:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    [super touchesCancelled:touches withEvent:event];
    [UIView animateWithDuration:0.4 delay:0 usingSpringWithDamping:0.5 initialSpringVelocity:0.5 options:UIViewAnimationOptionAllowUserInteraction animations:^{
        self.transform = CGAffineTransformIdentity;
        self.cardContentView.layer.shadowOpacity = 0.08;
    } completion:nil];
}

- (void)setSelected:(BOOL)selected animated:(BOOL)animated {
    [super setSelected:selected animated:animated];
    // 不改变背景色，使用按压动画代替
}

- (void)setHighlighted:(BOOL)highlighted animated:(BOOL)animated {
    [super setHighlighted:highlighted animated:animated];
    // 不改变背景色，使用按压动画代替
}

@end