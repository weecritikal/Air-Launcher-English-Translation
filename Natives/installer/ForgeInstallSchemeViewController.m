#import "ForgeInstallSchemeViewController.h"

@interface ForgeInstallSchemeViewController ()

@property (nonatomic, strong) UIVisualEffectView *backgroundView;
@property (nonatomic, strong) UIView *contentContainer;
@property (nonatomic, strong) UILabel *titleLabel;
@property (nonatomic, strong) UIStackView *stackView;
@property (nonatomic, strong) UIView *originalCard;
@property (nonatomic, strong) UIView *directCard;
@property (nonatomic, strong) UIButton *closeButton;

@end

@implementation ForgeInstallSchemeViewController

- (void)viewDidLoad {
    [super viewDidLoad];

    self.view.backgroundColor = [UIColor colorWithWhite:0 alpha:0.4];

    [self setupBackgroundView];
    [self setupContentContainer];
    [self setupTitleLabel];
    [self setupCloseButton];
    [self setupStackView];
    [self setupCards];
    [self setupConstraints];
}

- (void)setupBackgroundView {
    UIBlurEffect *blurEffect = [UIBlurEffect effectWithStyle:UIBlurEffectStyleSystemMaterialDark];
    self.backgroundView = [[UIVisualEffectView alloc] initWithEffect:blurEffect];
    self.backgroundView.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:self.backgroundView];
}

- (void)setupContentContainer {
    self.contentContainer = [[UIView alloc] init];
    self.contentContainer.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:self.contentContainer];
}

- (void)setupTitleLabel {
    self.titleLabel = [[UILabel alloc] init];
    self.titleLabel.text = @"选择安装方案";
    self.titleLabel.font = [UIFont boldSystemFontOfSize:20];
    self.titleLabel.textColor = [UIColor labelColor];
    self.titleLabel.textAlignment = NSTextAlignmentCenter;
    self.titleLabel.translatesAutoresizingMaskIntoConstraints = NO;
    [self.contentContainer addSubview:self.titleLabel];
}

- (void)setupCloseButton {
    self.closeButton = [UIButton buttonWithType:UIButtonTypeSystem];
    [self.closeButton setImage:[UIImage systemImageNamed:@"xmark.circle.fill"] forState:UIControlStateNormal];
    self.closeButton.tintColor = [UIColor secondaryLabelColor];
    self.closeButton.translatesAutoresizingMaskIntoConstraints = NO;
    [self.closeButton addTarget:self action:@selector(actionClose:) forControlEvents:UIControlEventTouchUpInside];
    [self.contentContainer addSubview:self.closeButton];
}

- (void)setupStackView {
    self.stackView = [[UIStackView alloc] init];
    self.stackView.axis = UILayoutConstraintAxisVertical;
    self.stackView.spacing = 16;
    self.stackView.distribution = UIStackViewDistributionFillEqually;
    self.stackView.translatesAutoresizingMaskIntoConstraints = NO;
    [self.contentContainer addSubview:self.stackView];
}

- (void)setupCards {
    self.originalCard = [self createCardWithTitle:@"原版方案"
                                         subtitle:@"运行 Forge 安装器 (AWT GUI)"
                                             icon:@"gearshape"
                                            color:[UIColor systemBlueColor]
                                           scheme:0];

    self.directCard = [self createCardWithTitle:@"直装方案"
                                       subtitle:@"直接解析安装，无需启动安装器"
                                           icon:@"bolt"
                                          color:[UIColor systemGreenColor]
                                         scheme:1];

    [self.stackView addArrangedSubview:self.originalCard];
    [self.stackView addArrangedSubview:self.directCard];
}

- (UIView *)createCardWithTitle:(NSString *)title
                       subtitle:(NSString *)subtitle
                           icon:(NSString *)iconName
                          color:(UIColor *)color
                         scheme:(NSInteger)scheme {
    UIView *card = [[UIView alloc] init];
    card.backgroundColor = [UIColor secondarySystemGroupedBackgroundColor];
    card.layer.cornerRadius = 16;
    card.layer.masksToBounds = YES;
    card.translatesAutoresizingMaskIntoConstraints = NO;

    UIImageView *iconImageView = [[UIImageView alloc] init];
    UIImage *iconImage = [UIImage systemImageNamed:iconName];
    iconImageView.image = iconImage;
    iconImageView.tintColor = color;
    iconImageView.contentMode = UIViewContentModeScaleAspectFit;
    iconImageView.translatesAutoresizingMaskIntoConstraints = NO;
    [card addSubview:iconImageView];

    UILabel *titleLabel = [[UILabel alloc] init];
    titleLabel.text = title;
    titleLabel.font = [UIFont boldSystemFontOfSize:18];
    titleLabel.textColor = [UIColor labelColor];
    titleLabel.translatesAutoresizingMaskIntoConstraints = NO;
    [card addSubview:titleLabel];

    UILabel *subtitleLabel = [[UILabel alloc] init];
    subtitleLabel.text = subtitle;
    subtitleLabel.font = [UIFont systemFontOfSize:14];
    subtitleLabel.textColor = [UIColor secondaryLabelColor];
    subtitleLabel.translatesAutoresizingMaskIntoConstraints = NO;
    [card addSubview:subtitleLabel];

    [NSLayoutConstraint activateConstraints:@[
        [iconImageView.leadingAnchor constraintEqualToAnchor:card.leadingAnchor constant:20],
        [iconImageView.centerYAnchor constraintEqualToAnchor:card.centerYAnchor],
        [iconImageView.widthAnchor constraintEqualToConstant:32],
        [iconImageView.heightAnchor constraintEqualToConstant:32]
    ]];

    [NSLayoutConstraint activateConstraints:@[
        [titleLabel.leadingAnchor constraintEqualToAnchor:iconImageView.trailingAnchor constant:16],
        [titleLabel.topAnchor constraintEqualToAnchor:card.topAnchor constant:20],
        [titleLabel.trailingAnchor constraintEqualToAnchor:card.trailingAnchor constant:-20]
    ]];

    [NSLayoutConstraint activateConstraints:@[
        [subtitleLabel.leadingAnchor constraintEqualToAnchor:titleLabel.leadingAnchor],
        [subtitleLabel.topAnchor constraintEqualToAnchor:titleLabel.bottomAnchor constant:4],
        [subtitleLabel.trailingAnchor constraintEqualToAnchor:titleLabel.trailingAnchor],
        [subtitleLabel.bottomAnchor constraintEqualToAnchor:card.bottomAnchor constant:-20]
    ]];

    UITapGestureRecognizer *tap = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(cardTapped:)];
    [card addGestureRecognizer:tap];
    card.tag = scheme;

    return card;
}

- (void)setupConstraints {
    [NSLayoutConstraint activateConstraints:@[
        [self.backgroundView.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [self.backgroundView.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [self.backgroundView.topAnchor constraintEqualToAnchor:self.view.topAnchor],
        [self.backgroundView.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor]
    ]];

    [NSLayoutConstraint activateConstraints:@[
        [self.contentContainer.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor constant:24],
        [self.contentContainer.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor constant:-24],
        [self.contentContainer.centerYAnchor constraintEqualToAnchor:self.view.centerYAnchor]
    ]];

    [NSLayoutConstraint activateConstraints:@[
        [self.closeButton.topAnchor constraintEqualToAnchor:self.contentContainer.topAnchor],
        [self.closeButton.trailingAnchor constraintEqualToAnchor:self.contentContainer.trailingAnchor],
        [self.closeButton.widthAnchor constraintEqualToConstant:32],
        [self.closeButton.heightAnchor constraintEqualToConstant:32]
    ]];

    [NSLayoutConstraint activateConstraints:@[
        [self.titleLabel.topAnchor constraintEqualToAnchor:self.contentContainer.topAnchor constant:8],
        [self.titleLabel.leadingAnchor constraintEqualToAnchor:self.contentContainer.leadingAnchor],
        [self.titleLabel.trailingAnchor constraintEqualToAnchor:self.closeButton.leadingAnchor constant:-8]
    ]];

    [NSLayoutConstraint activateConstraints:@[
        [self.stackView.topAnchor constraintEqualToAnchor:self.titleLabel.bottomAnchor constant:24],
        [self.stackView.leadingAnchor constraintEqualToAnchor:self.contentContainer.leadingAnchor],
        [self.stackView.trailingAnchor constraintEqualToAnchor:self.contentContainer.trailingAnchor],
        [self.stackView.bottomAnchor constraintEqualToAnchor:self.contentContainer.bottomAnchor]
    ]];

    [NSLayoutConstraint activateConstraints:@[
        [self.originalCard.heightAnchor constraintEqualToConstant:100],
        [self.directCard.heightAnchor constraintEqualToConstant:100]
    ]];
}

- (void)cardTapped:(UITapGestureRecognizer *)gesture {
    UIView *card = gesture.view;
    NSInteger scheme = card.tag;

    [UIView animateWithDuration:0.1 animations:^{
        card.transform = CGAffineTransformMakeScale(0.96, 0.96);
    } completion:^(BOOL finished) {
        [UIView animateWithDuration:0.1 animations:^{
            card.transform = CGAffineTransformIdentity;
        } completion:^(BOOL finished) {
            if ([self.delegate respondsToSelector:@selector(schemeViewController:didSelectScheme:)]) {
                [self.delegate schemeViewController:self didSelectScheme:scheme];
            }
            [self dismissViewControllerAnimated:YES completion:nil];
        }];
    }];
}

- (void)actionClose:(UIButton *)sender {
    [self dismissViewControllerAnimated:YES completion:nil];
}

@end
