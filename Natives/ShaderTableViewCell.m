//
//  ShaderTableViewCell.m
//  Amethyst
//
//  Shader table view cell implementation
//

#import "ShaderTableViewCell.h"
#import "ShaderItem.h"
#import "ShaderService.h"
#import <QuartzCore/QuartzCore.h>

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wunguarded-availability-new"
#import "UIKit+AFNetworking.h"
#pragma clang diagnostic pop

@interface ShaderTableViewCell ()
@property (nonatomic, strong) ShaderItem *currentShader;
@end

@implementation ShaderTableViewCell

- (instancetype)initWithStyle:(UITableViewCellStyle)style reuseIdentifier:(NSString *)reuseIdentifier {
    if (self = [super initWithStyle:style reuseIdentifier:reuseIdentifier]) {
        self.selectionStyle = UITableViewCellSelectionStyleNone;
        self.backgroundColor = [UIColor clearColor];
        self.contentView.backgroundColor = [UIColor systemBackgroundColor];

        // --- Initialization of UI Elements ---
        _shaderIconView = [self createImageViewWithCornerRadius:4];
        _nameLabel = [self createLabelWithFont:[UIFont boldSystemFontOfSize:13] textColor:[UIColor labelColor] numberOfLines:1];

        // Version Labels
        _shaderVersionLabel = [self createLabelWithFont:[UIFont systemFontOfSize:10 weight:UIFontWeightMedium] textColor:[UIColor secondaryLabelColor] numberOfLines:1];
        _gameVersionLabel = [self createLabelWithFont:[UIFont systemFontOfSize:10 weight:UIFontWeightMedium] textColor:[UIColor systemGreenColor] numberOfLines:1];

        _authorLabel = [self createLabelWithFont:[UIFont systemFontOfSize:9] textColor:[UIColor secondaryLabelColor] numberOfLines:1];
        _descLabel = [self createLabelWithFont:[UIFont systemFontOfSize:9] textColor:[UIColor secondaryLabelColor] numberOfLines:2];
        _statsLabel = [self createLabelWithFont:[UIFont systemFontOfSize:9] textColor:[UIColor secondaryLabelColor] numberOfLines:1];
        _categoryLabel = [self createLabelWithFont:[UIFont systemFontOfSize:9] textColor:[UIColor systemBlueColor] numberOfLines:1];

        _enableSwitch = [[UISwitch alloc] init];
        _enableSwitch.transform = CGAffineTransformMakeScale(0.75, 0.75);
        _enableSwitch.translatesAutoresizingMaskIntoConstraints = NO;
        [_enableSwitch addTarget:self action:@selector(toggleTapped) forControlEvents:UIControlEventValueChanged];

        _downloadButton = [self createButtonWithTitle:@"下载" titleColor:[UIColor whiteColor] action:@selector(downloadTapped)];
        _downloadButton.backgroundColor = [UIColor systemGreenColor];
        _downloadButton.layer.cornerRadius = 10;
        _downloadButton.titleLabel.font = [UIFont boldSystemFontOfSize:10];
        _downloadButton.contentEdgeInsets = UIEdgeInsetsMake(4, 8, 4, 8);

        _openLinkButton = [self createButtonWithImage:[UIImage systemImageNamed:@"globe"] action:@selector(openLinkTapped)];

        // Add subviews
        [self.contentView addSubview:_shaderIconView];
        [self.contentView addSubview:_nameLabel];
        [self.contentView addSubview:_shaderVersionLabel];
        [self.contentView addSubview:_gameVersionLabel];
        [self.contentView addSubview:_authorLabel];
        [self.contentView addSubview:_descLabel];
        [self.contentView addSubview:_statsLabel];
        [self.contentView addSubview:_categoryLabel];
        [self.contentView addSubview:_enableSwitch];
        [self.contentView addSubview:_downloadButton];
        [self.contentView addSubview:_openLinkButton];

        [self setupConstraints];
    }
    return self;
}

#pragma mark - UI Element Factory Methods

- (UIImageView *)createImageViewWithCornerRadius:(CGFloat)radius {
    UIImageView *imageView = [[UIImageView alloc] init];
    imageView.translatesAutoresizingMaskIntoConstraints = NO;
    imageView.layer.cornerRadius = radius;
    imageView.clipsToBounds = YES;
    imageView.contentMode = UIViewContentModeScaleAspectFill;
    imageView.backgroundColor = [UIColor secondarySystemBackgroundColor];
    return imageView;
}

- (UILabel *)createLabelWithFont:(UIFont *)font textColor:(UIColor *)color numberOfLines:(NSInteger)lines {
    UILabel *label = [[UILabel alloc] init];
    label.translatesAutoresizingMaskIntoConstraints = NO;
    label.font = font;
    label.textColor = color;
    label.numberOfLines = lines;
    [label setContentCompressionResistancePriority:UILayoutPriorityDefaultLow forAxis:UILayoutConstraintAxisHorizontal];
    [label setContentHuggingPriority:UILayoutPriorityDefaultLow forAxis:UILayoutConstraintAxisHorizontal];
    return label;
}

- (UIButton *)createButtonWithAction:(SEL)action {
    UIButton *button = [UIButton buttonWithType:UIButtonTypeSystem];
    button.translatesAutoresizingMaskIntoConstraints = NO;
    [button addTarget:self action:action forControlEvents:UIControlEventTouchUpInside];
    return button;
}

- (UIButton *)createButtonWithTitle:(NSString *)title titleColor:(UIColor *)color action:(SEL)action {
    UIButton *button = [self createButtonWithAction:action];
    [button setTitle:title forState:UIControlStateNormal];
    [button setTitleColor:color forState:UIControlStateNormal];
    button.titleLabel.font = [UIFont boldSystemFontOfSize:15];
    return button;
}

- (UIButton *)createButtonWithImage:(UIImage *)image action:(SEL)action {
    UIButton *button = [self createButtonWithAction:action];
    [button setImage:image forState:UIControlStateNormal];
    return button;
}

#pragma mark - Auto Layout Constraints

- (void)setupConstraints {
    CGFloat padding = 7.0;
    CGFloat iconSize = 36.0;

    // --- Common Left-aligned Elements ---
    [NSLayoutConstraint activateConstraints:@[
        [_shaderIconView.leadingAnchor constraintEqualToAnchor:self.contentView.leadingAnchor constant:padding],
        [_shaderIconView.centerYAnchor constraintEqualToAnchor:self.contentView.centerYAnchor],
        [_shaderIconView.widthAnchor constraintEqualToConstant:iconSize],
        [_shaderIconView.heightAnchor constraintEqualToConstant:iconSize],

        [_nameLabel.leadingAnchor constraintEqualToAnchor:_shaderIconView.trailingAnchor constant:8],
        [_nameLabel.topAnchor constraintEqualToAnchor:_shaderIconView.topAnchor constant:-2],

        // Version Label Constraints
        [_shaderVersionLabel.leadingAnchor constraintEqualToAnchor:_nameLabel.leadingAnchor],
        [_shaderVersionLabel.topAnchor constraintEqualToAnchor:_nameLabel.bottomAnchor constant:2],
        [_gameVersionLabel.leadingAnchor constraintEqualToAnchor:_shaderVersionLabel.trailingAnchor constant:5],
        [_gameVersionLabel.centerYAnchor constraintEqualToAnchor:_shaderVersionLabel.centerYAnchor],

        [_descLabel.leadingAnchor constraintEqualToAnchor:_nameLabel.leadingAnchor],
        [_descLabel.topAnchor constraintEqualToAnchor:_shaderVersionLabel.bottomAnchor constant:2],

        [_authorLabel.leadingAnchor constraintEqualToAnchor:_nameLabel.leadingAnchor],
        [_authorLabel.topAnchor constraintEqualToAnchor:_nameLabel.bottomAnchor constant:1],
        [_statsLabel.leadingAnchor constraintEqualToAnchor:_authorLabel.trailingAnchor constant:4],
        [_statsLabel.centerYAnchor constraintEqualToAnchor:_authorLabel.centerYAnchor],

        // --- Right-aligned Action Buttons ---
        [_downloadButton.trailingAnchor constraintEqualToAnchor:self.contentView.trailingAnchor constant:-padding],
        [_downloadButton.centerYAnchor constraintEqualToAnchor:self.contentView.centerYAnchor],
        [_enableSwitch.trailingAnchor constraintEqualToAnchor:self.contentView.trailingAnchor constant:-padding],
        [_enableSwitch.centerYAnchor constraintEqualToAnchor:self.contentView.centerYAnchor],

        [_openLinkButton.trailingAnchor constraintEqualToAnchor:_enableSwitch.leadingAnchor constant:-4],
        [_openLinkButton.centerYAnchor constraintEqualToAnchor:self.contentView.centerYAnchor],
        [_openLinkButton.widthAnchor constraintEqualToConstant:28],
        [_openLinkButton.heightAnchor constraintEqualToConstant:28],

        // --- Text Content Trailing Constraints ---
        [_nameLabel.trailingAnchor constraintEqualToAnchor:_openLinkButton.leadingAnchor constant:-padding],
        [_shaderVersionLabel.trailingAnchor constraintLessThanOrEqualToAnchor:_openLinkButton.leadingAnchor constant:-padding],
        [_descLabel.trailingAnchor constraintEqualToAnchor:_openLinkButton.leadingAnchor constant:-padding],
        [_statsLabel.trailingAnchor constraintLessThanOrEqualToAnchor:_openLinkButton.leadingAnchor constant:-padding],
    ]];
}

#pragma mark - Configuration

- (void)configureWithShader:(ShaderItem *)shader displayMode:(ShaderTableViewCellDisplayMode)mode {
    self.currentShader = shader;

    _nameLabel.text = shader.displayName ?: shader.fileName;

    if (shader.icon) {
        _shaderIconView.image = shader.icon;
    } else if (shader.iconURL) {
        [_shaderIconView setImageWithURL:[NSURL URLWithString:shader.iconURL] placeholderImage:[UIImage systemImageNamed:@"photo"]];
    } else {
        _shaderIconView.image = [UIImage systemImageNamed:@"photo"];
    }

    if (mode == ShaderTableViewCellDisplayModeLocal) {
        [self configureForLocalMode:shader];
    } else {
        [self configureForOnlineMode:shader];
    }
}

- (void)configureForLocalMode:(ShaderItem *)shader {
    // Hide online/unused elements
    _authorLabel.hidden = YES;
    _statsLabel.hidden = YES;
    _categoryLabel.hidden = YES;
    _downloadButton.hidden = YES;
    _descLabel.hidden = NO;

    // Show local elements
    _openLinkButton.hidden = NO;
    _enableSwitch.hidden = NO;
    _shaderVersionLabel.hidden = NO;
    _gameVersionLabel.hidden = NO;

    // Populate version labels
    if (shader.version && shader.version.length > 0) {
        _shaderVersionLabel.text = [NSString stringWithFormat:@"v%@", shader.version];
        _shaderVersionLabel.hidden = NO;
    } else {
        _shaderVersionLabel.text = nil;
        _shaderVersionLabel.hidden = YES;
    }

    if (shader.gameVersion && shader.gameVersion.length > 0) {
        _gameVersionLabel.text = [NSString stringWithFormat:@"MC %@", shader.gameVersion];
        _gameVersionLabel.hidden = NO;
    } else {
        _gameVersionLabel.text = nil;
        _gameVersionLabel.hidden = YES;
    }

    [self updateToggleState:shader.disabled];

    if (shader.shaderDescription && shader.shaderDescription.length > 0) {
        _descLabel.text = shader.shaderDescription;
        _descLabel.hidden = NO;
    } else {
        _descLabel.text = nil;
        _descLabel.hidden = YES;
    }
}

- (void)configureForOnlineMode:(ShaderItem *)shader {
    // Hide local/unused elements
    _enableSwitch.hidden = YES;
    _descLabel.hidden = YES;
    _shaderVersionLabel.hidden = YES;
    _gameVersionLabel.hidden = YES;

    // Show online elements
    _authorLabel.hidden = NO;
    _statsLabel.hidden = NO;
    _downloadButton.hidden = NO;
    _openLinkButton.hidden = NO;

    _authorLabel.text = [NSString stringWithFormat:@"by %@", shader.author ?: @"Unknown"];

    NSNumberFormatter *formatter = [[NSNumberFormatter alloc] init];
    formatter.numberStyle = NSNumberFormatterDecimalStyle;
    NSString *downloadsStr = [formatter stringFromNumber:shader.downloads ?: @0];

    _statsLabel.text = [NSString stringWithFormat:@"%@ 下载", downloadsStr];
}

#pragma mark - State Updates

- (void)updateToggleState:(BOOL)disabled {
    [_enableSwitch setOn:!disabled animated:YES];
    self.contentView.alpha = disabled ? 0.6 : 1.0;
}

#pragma mark - Actions

- (void)toggleTapped {
    if ([self.delegate respondsToSelector:@selector(shaderCellDidTapToggle:)]) {
        [self.delegate shaderCellDidTapToggle:self];
    }
}

- (void)downloadTapped {
    if ([self.delegate respondsToSelector:@selector(shaderCellDidTapDownload:)]) {
        [self.delegate shaderCellDidTapDownload:self];
    }
}

- (void)openLinkTapped {
    if ([self.delegate respondsToSelector:@selector(shaderCellDidTapOpenLink:)]) {
        [self.delegate shaderCellDidTapOpenLink:self];
    }
}

@end
#pragma clang diagnostic pop
