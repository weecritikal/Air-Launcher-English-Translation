// VersionCardCell.m
// 参照 FCL (item_remote_version.xml) 与 ZL2 (VersionItemLayout) 的单列横向列表行设计：
// - 左侧：类型图标容器（40x40 圆角方块，类型色背景 + 白色 SF Symbol）
// - 中间：版本号（16pt semibold）+ 类型小标签（pill） 在同一行 / 发布日期（12pt secondary）在下一行
// - 右侧：chevron 指示可点击
// - 已安装标记：图标容器右上角的绿色小圆点徽章（ZL2 风格，不遮挡右侧 chevron）
// 替代原 100x120 纵向网格卡片，信息密度更高、更接近 FCL/ZL2 视觉。

#import "VersionCardCell.h"

@interface VersionCardCell ()
// 容器视图：整张卡片的圆角背景（毛玻璃 + 半透明）
@property (nonatomic, strong) UIView *cardContainer;
// 左侧类型图标容器（带圆角与类型色背景）
@property (nonatomic, strong) UIView *iconContainer;
// 顶行水平 stack：装 versionLabel + typeLabel，自动处理间距与裁剪
@property (nonatomic, strong) UIStackView *topRowStack;
// 右侧 chevron 指示
@property (nonatomic, strong) UIImageView *chevronView;
@end

@implementation VersionCardCell

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        // 外层 cell 透明，由 cardContainer 提供视觉
        self.backgroundColor = [UIColor clearColor];
        self.contentView.backgroundColor = [UIColor clearColor];
        self.layer.masksToBounds = NO;

        // ----- 卡片容器：圆角 + 半透明背景 + 浅阴影（与 VMTileBaseCell 阴影标准一致）-----
        self.cardContainer = [[UIView alloc] init];
        self.cardContainer.translatesAutoresizingMaskIntoConstraints = NO;
        self.cardContainer.backgroundColor = [[UIColor whiteColor] colorWithAlphaComponent:0.08];
        self.cardContainer.layer.cornerRadius = 16;
        self.cardContainer.layer.cornerCurve = kCACornerCurveContinuous;
        self.cardContainer.layer.borderWidth = 0.5;
        self.cardContainer.layer.borderColor = [[UIColor whiteColor] colorWithAlphaComponent:0.10].CGColor;
        self.cardContainer.layer.shadowColor = [UIColor blackColor].CGColor;
        self.cardContainer.layer.shadowOffset = CGSizeMake(0, 4);
        self.cardContainer.layer.shadowOpacity = 0.12;
        self.cardContainer.layer.shadowRadius = 8;
        [self.contentView addSubview:self.cardContainer];

        // ----- 左侧图标容器：40x40 圆角方块，类型色背景 -----
        self.iconContainer = [[UIView alloc] init];
        self.iconContainer.translatesAutoresizingMaskIntoConstraints = NO;
        self.iconContainer.layer.cornerRadius = 10;
        self.iconContainer.layer.cornerCurve = kCACornerCurveContinuous;
        self.iconContainer.layer.masksToBounds = YES;
        self.iconContainer.backgroundColor = [UIColor systemGreenColor];
        [self.cardContainer addSubview:self.iconContainer];

        // 图标本体：白色 SF Symbol，居中
        self.iconImageView = [[UIImageView alloc] init];
        self.iconImageView.translatesAutoresizingMaskIntoConstraints = NO;
        self.iconImageView.contentMode = UIViewContentModeScaleAspectFit;
        self.iconImageView.tintColor = [UIColor whiteColor];
        self.iconImageView.image = [UIImage systemImageNamed:@"cube.fill"];
        [self.iconContainer addSubview:self.iconImageView];

        // ----- 版本号 -----
        self.versionLabel = [[UILabel alloc] init];
        self.versionLabel.translatesAutoresizingMaskIntoConstraints = NO;
        self.versionLabel.font = [UIFont systemFontOfSize:16 weight:UIFontWeightSemibold];
        self.versionLabel.textColor = [UIColor labelColor];
        self.versionLabel.adjustsFontSizeToFitWidth = YES;
        self.versionLabel.minimumScaleFactor = 0.7;
        self.versionLabel.lineBreakMode = NSLineBreakByTruncatingTail;
        // 版本号 hugging 高（不主动拉伸），compression 低（空间不足时优先被压缩→触发字号缩小）
        [self.versionLabel setContentHuggingPriority:UILayoutPriorityDefaultHigh forAxis:UILayoutConstraintAxisHorizontal];
        [self.versionLabel setContentCompressionResistancePriority:UILayoutPriorityDefaultLow forAxis:UILayoutConstraintAxisHorizontal];

        // ----- 类型标签（pill 样式） -----
        self.typeLabel = [[UILabel alloc] init];
        self.typeLabel.translatesAutoresizingMaskIntoConstraints = NO;
        self.typeLabel.font = [UIFont systemFontOfSize:10 weight:UIFontWeightBold];
        self.typeLabel.textColor = [UIColor whiteColor];
        self.typeLabel.textAlignment = NSTextAlignmentCenter;
        self.typeLabel.layer.cornerRadius = 8;
        self.typeLabel.layer.cornerCurve = kCACornerCurveContinuous;
        self.typeLabel.layer.masksToBounds = YES;
        // 类型标签 hugging 高、compression 也高（保持完整 pill 形状，不被压缩）
        [self.typeLabel setContentHuggingPriority:UILayoutPriorityDefaultHigh forAxis:UILayoutConstraintAxisHorizontal];
        [self.typeLabel setContentCompressionResistancePriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisHorizontal];

        // ----- 顶行 stack：版本号 + 类型标签 水平排列 -----
        // 用 UIStackView 自动处理两者间距与裁剪优先级，避免手写约束出现 typeLabel 撞 chevron 的问题
        self.topRowStack = [[UIStackView alloc] initWithArrangedSubviews:@[self.versionLabel, self.typeLabel]];
        self.topRowStack.translatesAutoresizingMaskIntoConstraints = NO;
        self.topRowStack.axis = UILayoutConstraintAxisHorizontal;
        self.topRowStack.alignment = UIStackViewAlignmentFirstBaseline;
        self.topRowStack.distribution = UIStackViewDistributionFill;
        self.topRowStack.spacing = 8;
        [self.cardContainer addSubview:self.topRowStack];

        // ----- 日期 -----
        self.dateLabel = [[UILabel alloc] init];
        self.dateLabel.translatesAutoresizingMaskIntoConstraints = NO;
        self.dateLabel.font = [UIFont systemFontOfSize:12];
        self.dateLabel.textColor = [UIColor secondaryLabelColor];
        self.dateLabel.adjustsFontSizeToFitWidth = YES;
        self.dateLabel.minimumScaleFactor = 0.7;
        self.dateLabel.lineBreakMode = NSLineBreakByTruncatingTail;
        [self.cardContainer addSubview:self.dateLabel];

        // ----- 右侧 chevron：提示可点击进入加载器选择 -----
        self.chevronView = [[UIImageView alloc] initWithImage:[UIImage systemImageNamed:@"chevron.right"]];
        self.chevronView.translatesAutoresizingMaskIntoConstraints = NO;
        self.chevronView.tintColor = [UIColor tertiaryLabelColor];
        self.chevronView.contentMode = UIViewContentModeScaleAspectFit;
        // chevron 固定尺寸，不被拉伸
        [self.chevronView setContentHuggingPriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisHorizontal];
        [self.chevronView setContentCompressionResistancePriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisHorizontal];
        [self.cardContainer addSubview:self.chevronView];

        // ----- 已安装徽章：图标容器右上角的绿色小圆点（ZL2 风格）-----
        // 不再用大块绿色 ✓ 占据卡片右上角，改用 14pt 小圆点贴在 iconContainer 右上角，
        // 既保留"已安装"指示，又不遮挡右侧 chevron 与版本号。
        self.installedBadge = [[UIView alloc] init];
        self.installedBadge.translatesAutoresizingMaskIntoConstraints = NO;
        self.installedBadge.backgroundColor = [UIColor systemGreenColor];
        self.installedBadge.layer.cornerRadius = 7;
        self.installedBadge.layer.masksToBounds = YES;
        self.installedBadge.layer.borderColor = [UIColor systemBackgroundColor].CGColor;
        self.installedBadge.layer.borderWidth = 1.5;
        self.installedBadge.hidden = YES;
        [self.cardContainer addSubview:self.installedBadge];

        // 内部小 ✓（白色，居中）
        UIImageView *checkmark = [[UIImageView alloc] init];
        checkmark.translatesAutoresizingMaskIntoConstraints = NO;
        checkmark.image = [UIImage systemImageNamed:@"checkmark"
                                  withConfiguration:[UIImageSymbolConfiguration configurationWithPointSize:7 weight:UIFontWeightBold]];
        checkmark.tintColor = [UIColor whiteColor];
        [self.installedBadge addSubview:checkmark];

        // ----- 布局约束 -----
        [NSLayoutConstraint activateConstraints:@[
            // cardContainer 充满 contentView（留 0 外边距，间距由 collection layout 的 sectionInset 控制）
            [self.cardContainer.topAnchor constraintEqualToAnchor:self.contentView.topAnchor constant:4],
            [self.cardContainer.leadingAnchor constraintEqualToAnchor:self.contentView.leadingAnchor constant:0],
            [self.cardContainer.trailingAnchor constraintEqualToAnchor:self.contentView.trailingAnchor constant:0],
            [self.cardContainer.bottomAnchor constraintEqualToAnchor:self.contentView.bottomAnchor constant:-4],

            // 图标容器：左 14，垂直居中，40x40
            [self.iconContainer.leadingAnchor constraintEqualToAnchor:self.cardContainer.leadingAnchor constant:14],
            [self.iconContainer.centerYAnchor constraintEqualToAnchor:self.cardContainer.centerYAnchor],
            [self.iconContainer.widthAnchor constraintEqualToConstant:40],
            [self.iconContainer.heightAnchor constraintEqualToConstant:40],

            // 图标在容器内居中，22x22
            [self.iconImageView.centerXAnchor constraintEqualToAnchor:self.iconContainer.centerXAnchor],
            [self.iconImageView.centerYAnchor constraintEqualToAnchor:self.iconContainer.centerYAnchor],
            [self.iconImageView.widthAnchor constraintEqualToConstant:22],
            [self.iconImageView.heightAnchor constraintEqualToConstant:22],

            // 顶行 stack：紧跟图标容器右侧 +14，顶部对齐 cardContainer 顶部 +14
            // 右侧到 chevron 之间留 8pt，stack 内部自动分配 versionLabel/typeLabel 宽度
            [self.topRowStack.leadingAnchor constraintEqualToAnchor:self.iconContainer.trailingAnchor constant:14],
            [self.topRowStack.topAnchor constraintEqualToAnchor:self.cardContainer.topAnchor constant:14],
            [self.topRowStack.trailingAnchor constraintEqualToAnchor:self.chevronView.leadingAnchor constant:-8],

            // 日期：与顶行 stack 左对齐，紧跟顶行下方 +3
            [self.dateLabel.leadingAnchor constraintEqualToAnchor:self.topRowStack.leadingAnchor],
            [self.dateLabel.topAnchor constraintEqualToAnchor:self.topRowStack.bottomAnchor constant:3],
            [self.dateLabel.trailingAnchor constraintEqualToAnchor:self.topRowStack.trailingAnchor],
            [self.dateLabel.bottomAnchor constraintLessThanOrEqualToAnchor:self.cardContainer.bottomAnchor constant:-12],

            // chevron：右侧 -14，垂直居中，14x14
            [self.chevronView.trailingAnchor constraintEqualToAnchor:self.cardContainer.trailingAnchor constant:-14],
            [self.chevronView.centerYAnchor constraintEqualToAnchor:self.cardContainer.centerYAnchor],
            [self.chevronView.widthAnchor constraintEqualToConstant:14],
            [self.chevronView.heightAnchor constraintEqualToConstant:14],

            // 已安装徽章：贴在 iconContainer 右上角，14x14
            [self.installedBadge.topAnchor constraintEqualToAnchor:self.iconContainer.topAnchor constant:-4],
            [self.installedBadge.trailingAnchor constraintEqualToAnchor:self.iconContainer.trailingAnchor constant:4],
            [self.installedBadge.widthAnchor constraintEqualToConstant:14],
            [self.installedBadge.heightAnchor constraintEqualToConstant:14],
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

    // 类型 → 图标 + 配色映射（参照 ZL2 的 VersionIconPreview 按版本类型切换图标）：
    // release → cube.fill + systemGreen（稳定版）
    // snapshot → hammer.fill + systemOrange（测试版/开发中）
    // old_alpha → clock.fill + systemPurple（远古 alpha）
    // old_beta  → clock.fill + systemPurple（远古 beta）
    NSString *iconName = @"cube.fill";
    UIColor *typeColor = [UIColor systemGreenColor];
    NSString *typeText = @"正式版";

    if ([type isEqualToString:@"正式版"] || [type isEqualToString:@"release"]) {
        iconName = @"cube.fill";
        typeColor = [UIColor systemGreenColor];
        typeText = @"正式版";
    } else if ([type isEqualToString:@"测试版"] || [type isEqualToString:@"snapshot"]) {
        iconName = @"hammer.fill";
        typeColor = [UIColor systemOrangeColor];
        typeText = @"测试版";
    } else if ([type isEqualToString:@"old_alpha"]) {
        iconName = @"clock.fill";
        typeColor = [UIColor systemPurpleColor];
        typeText = @"Alpha";
    } else if ([type isEqualToString:@"old_beta"]) {
        iconName = @"clock.fill";
        typeColor = [UIColor systemPurpleColor];
        typeText = @"Beta";
    } else {
        // 兜底：远古版（合并 old_alpha + old_beta 时使用）
        iconName = @"clock.fill";
        typeColor = [UIColor systemPurpleColor];
        typeText = @"远古版";
    }

    UIImage *symbol = [UIImage systemImageNamed:iconName];
    if (symbol) {
        self.iconImageView.image = symbol;
    }
    self.iconImageView.tintColor = [UIColor whiteColor];

    // 图标容器背景：类型色 + 半透明（柔和感），与 ZL2 Surface cardColor 风格一致
    self.iconContainer.backgroundColor = [typeColor colorWithAlphaComponent:0.85];

    // 类型标签：类型色背景 + 白字
    self.typeLabel.text = typeText;
    self.typeLabel.backgroundColor = typeColor;
}

- (void)setInstalled:(BOOL)installed {
    self.installedBadge.hidden = !installed;
}

- (void)prepareForReuse {
    [super prepareForReuse];
    self.iconImageView.image = [UIImage systemImageNamed:@"cube.fill"];
    self.iconImageView.tintColor = [UIColor whiteColor];
    self.iconContainer.backgroundColor = [UIColor systemGreenColor];
    self.versionLabel.text = nil;
    self.dateLabel.text = nil;
    self.typeLabel.text = nil;
    self.typeLabel.backgroundColor = [UIColor systemBlueColor];
    self.installedBadge.hidden = YES;
    self.chevronView.tintColor = [UIColor tertiaryLabelColor];
}

@end
