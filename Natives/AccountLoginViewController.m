//
//  AccountLoginViewController.m
//  Amethyst
//
//  参照 FCL 安卓版：卡片式登录方式选择页面
//

#import "AccountLoginViewController.h"
#import "BackgroundManager.h"
#import "utils.h"

@interface AccountLoginViewController ()
@property (nonatomic, strong) UIScrollView *scrollView;
@property (nonatomic, strong) UIStackView *cardStack;
@end

@implementation AccountLoginViewController

#pragma mark - Lifecycle

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"添加账户";
    self.view.backgroundColor = [UIColor clearColor];

    [self setupUI];
    [[BackgroundManager sharedManager] applyBackgroundToView:self.view];
}

#pragma mark - Setup

- (void)setupUI {
    self.scrollView = [[UIScrollView alloc] init];
    self.scrollView.translatesAutoresizingMaskIntoConstraints = NO;
    self.scrollView.alwaysBounceVertical = YES;
    self.scrollView.backgroundColor = [UIColor clearColor];
    [self.view addSubview:self.scrollView];

    self.cardStack = [[UIStackView alloc] init];
    self.cardStack.translatesAutoresizingMaskIntoConstraints = NO;
    self.cardStack.axis = UILayoutConstraintAxisVertical;
    self.cardStack.spacing = 16;
    self.cardStack.alignment = UIStackViewAlignmentFill;
    [self.scrollView addSubview:self.cardStack];

    [NSLayoutConstraint activateConstraints:@[
        [self.scrollView.topAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.topAnchor],
        [self.scrollView.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [self.scrollView.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [self.scrollView.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor],

        [self.cardStack.topAnchor constraintEqualToAnchor:self.scrollView.contentLayoutGuide.topAnchor constant:20],
        [self.cardStack.leadingAnchor constraintEqualToAnchor:self.scrollView.contentLayoutGuide.leadingAnchor constant:20],
        [self.cardStack.trailingAnchor constraintEqualToAnchor:self.scrollView.contentLayoutGuide.trailingAnchor constant:-20],
        [self.cardStack.bottomAnchor constraintEqualToAnchor:self.scrollView.contentLayoutGuide.bottomAnchor constant:-20],
        [self.cardStack.widthAnchor constraintEqualToAnchor:self.scrollView.frameLayoutGuide.widthAnchor constant:-40],
    ]];

    // 标题区
    UILabel *headerLabel = [[UILabel alloc] init];
    headerLabel.text = @"选择登录方式";
    headerLabel.font = [UIFont systemFontOfSize:24 weight:UIFontWeightBold];
    headerLabel.textColor = [UIColor labelColor];
    [self.cardStack addArrangedSubview:headerLabel];

    UILabel *subtitleLabel = [[UILabel alloc] init];
    subtitleLabel.text = @"选择一种方式登录你的 Minecraft 账户";
    subtitleLabel.font = [UIFont systemFontOfSize:14];
    subtitleLabel.textColor = [UIColor secondaryLabelColor];
    subtitleLabel.numberOfLines = 0;
    [self.cardStack addArrangedSubview:subtitleLabel];

    // 间距
    [self.cardStack addArrangedSubview:[self spacerViewWithHeight:8]];

    // 四张登录卡片
    [self.cardStack addArrangedSubview:[self createLoginCardWithType:AccountLoginTypeMicrosoft
                                                                title:@"微软账户"
                                                          description:@"使用 Microsoft 账户登录（正版）"
                                                           iconName:@"xbox.logo" // iOS 14+ 有 xbox.logo；失败 fallback
                                                       fallbackIcon:@"person.crop.circle.fill"
                                                          accentColor:[UIColor systemBlueColor]]];
    [self.cardStack addArrangedSubview:[self createLoginCardWithType:AccountLoginTypeLittleSkin
                                                                title:@"LittleSkin"
                                                          description:@"使用 LittleSkin 皮肤站账户登录（需先注册）"
                                                           iconName:@"person.fill.viewfinder"
                                                       fallbackIcon:@"person.crop.circle.fill"
                                                          accentColor:[UIColor systemPurpleColor]]];
    [self.cardStack addArrangedSubview:[self createLoginCardWithType:AccountLoginTypeThirdParty
                                                                title:@"自定义第三方"
                                                          description:@"支持任意 Yggdrasil 兼容的 authlib-injector 服务器"
                                                           iconName:@"globe"
                                                       fallbackIcon:@"globe"
                                                          accentColor:[UIColor systemOrangeColor]]];
    [self.cardStack addArrangedSubview:[self createLoginCardWithType:AccountLoginTypeLocal
                                                                title:@"本地账户"
                                                          description:@"离线模式，仅输入用户名即可（无法加入正版服务器）"
                                                           iconName:@"person.fill"
                                                       fallbackIcon:@"person.fill"
                                                          accentColor:[UIColor systemGrayColor]]];
}

/// 创建一张登录方式卡片
- (UIView *)createLoginCardWithType:(AccountLoginType)type
                              title:(NSString *)title
                        description:(NSString *)description
                         iconName:(NSString *)iconName
                     fallbackIcon:(NSString *)fallbackIcon
                        accentColor:(UIColor *)accentColor {
    // 容器
    UIControl *card = [[UIControl alloc] init];
    card.translatesAutoresizingMaskIntoConstraints = NO;
    card.backgroundColor = [UIColor secondarySystemBackgroundColor];
    card.layer.cornerRadius = 16;
    card.layer.borderWidth = 1;
    card.layer.borderColor = [UIColor separatorColor].CGColor;
    [card addTarget:self action:@selector(cardTapped:) forControlEvents:UIControlEventTouchUpInside];
    card.tag = type;

    // 毛玻璃背景
    [[BackgroundManager sharedManager] applyEffectToView:card];

    // 左侧图标圆
    UIView *iconCircle = [[UIView alloc] init];
    iconCircle.translatesAutoresizingMaskIntoConstraints = NO;
    iconCircle.backgroundColor = [accentColor colorWithAlphaComponent:0.15];
    iconCircle.layer.cornerRadius = 24;
    [card addSubview:iconCircle];

    UIImageView *iconView = [[UIImageView alloc] init];
    iconView.translatesAutoresizingMaskIntoConstraints = NO;
    UIImage *icon = [UIImage systemImageNamed:iconName] ?: [UIImage systemImageNamed:fallbackIcon];
    iconView.image = icon;
    iconView.tintColor = accentColor;
    iconView.contentMode = UIViewContentModeScaleAspectFit;
    [iconCircle addSubview:iconView];

    // 中间文字
    UILabel *titleLabel = [[UILabel alloc] init];
    titleLabel.translatesAutoresizingMaskIntoConstraints = NO;
    titleLabel.text = title;
    titleLabel.font = [UIFont systemFontOfSize:17 weight:UIFontWeightSemibold];
    titleLabel.textColor = [UIColor labelColor];
    [card addSubview:titleLabel];

    UILabel *descLabel = [[UILabel alloc] init];
    descLabel.translatesAutoresizingMaskIntoConstraints = NO;
    descLabel.text = description;
    descLabel.font = [UIFont systemFontOfSize:13];
    descLabel.textColor = [UIColor secondaryLabelColor];
    descLabel.numberOfLines = 0;
    [card addSubview:descLabel];

    // 右侧箭头
    UIImageView *chevron = [[UIImageView alloc] init];
    chevron.translatesAutoresizingMaskIntoConstraints = NO;
    chevron.image = [UIImage systemImageNamed:@"chevron.right"];
    chevron.tintColor = [UIColor tertiaryLabelColor];
    [card addSubview:chevron];

    [NSLayoutConstraint activateConstraints:@[
        [iconCircle.leadingAnchor constraintEqualToAnchor:card.leadingAnchor constant:16],
        [iconCircle.centerYAnchor constraintEqualToAnchor:card.centerYAnchor],
        [iconCircle.widthAnchor constraintEqualToConstant:48],
        [iconCircle.heightAnchor constraintEqualToConstant:48],

        [iconView.centerXAnchor constraintEqualToAnchor:iconCircle.centerXAnchor],
        [iconView.centerYAnchor constraintEqualToAnchor:iconCircle.centerYAnchor],
        [iconView.widthAnchor constraintEqualToConstant:26],
        [iconView.heightAnchor constraintEqualToConstant:26],

        [titleLabel.leadingAnchor constraintEqualToAnchor:iconCircle.trailingAnchor constant:14],
        [titleLabel.topAnchor constraintEqualToAnchor:card.topAnchor constant:18],
        [titleLabel.trailingAnchor constraintEqualToAnchor:chevron.leadingAnchor constant:-8],

        [descLabel.leadingAnchor constraintEqualToAnchor:titleLabel.leadingAnchor],
        [descLabel.topAnchor constraintEqualToAnchor:titleLabel.bottomAnchor constant:4],
        [descLabel.trailingAnchor constraintEqualToAnchor:titleLabel.trailingAnchor],
        [descLabel.bottomAnchor constraintEqualToAnchor:card.bottomAnchor constant:-18],

        [chevron.trailingAnchor constraintEqualToAnchor:card.trailingAnchor constant:-16],
        [chevron.centerYAnchor constraintEqualToAnchor:card.centerYAnchor],
        [chevron.widthAnchor constraintEqualToConstant:14],
        [chevron.heightAnchor constraintEqualToConstant:20],
    ]];

    return card;
}

- (UIView *)spacerViewWithHeight:(CGFloat)height {
    UIView *spacer = [[UIView alloc] init];
    spacer.translatesAutoresizingMaskIntoConstraints = NO;
    [spacer.heightAnchor constraintEqualToConstant:height].active = YES;
    return spacer;
}

#pragma mark - Actions

- (void)cardTapped:(UIControl *)sender {
    AccountLoginType type = (AccountLoginType)sender.tag;
    // 轻微高亮反馈
    [UIView animateWithDuration:0.1 animations:^{
        sender.alpha = 0.7;
    } completion:^(BOOL finished) {
        sender.alpha = 1.0;
        if (self.onSelectLoginType) {
            self.onSelectLoginType(type);
        }
    }];
}

@end
