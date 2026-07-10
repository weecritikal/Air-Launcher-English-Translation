// ShaderVersionTableViewCell.m
// 参照 FCL/ZL2 的版本列表行设计，增强视觉层次（与 ModVersionTableViewCell 统一）：
// - 圆角卡片容器（16pt 圆角 + 浅阴影 + 半透明背景）
// - 左侧：版本名(16pt semibold) + 版本号(14pt secondary)
// - 加载器徽章行：fabric/iris/optifine 等彩色 pill 标签（参照 ZL2 LittleTextLabel）
// - 右侧：发布日期 + 文件大小 + 游戏版本（垂直右对齐）
// - chevron 指示可点击进入下载

#import "ShaderVersionTableViewCell.h"
#import "BackgroundManager.h"
#import "ModLoaderIconHelper.h"

@interface ShaderVersionTableViewCell ()
// 卡片容器：圆角 + 阴影 + 半透明背景（统一视觉规范）
@property (nonatomic, strong) UIView *cardContainer;
// 左侧信息区（版本名 + 版本号 + 加载器徽章行）
@property (nonatomic, strong) UIStackView *leftStackView;
// 加载器徽章容器（水平排列的彩色 pill 标签）
@property (nonatomic, strong) UIStackView *loaderBadgeStack;
// 右侧信息区（日期 + 大小 + 游戏版本）
@property (nonatomic, strong) UIStackView *rightStackView;
// 子视图
@property (nonatomic, strong) UILabel *nameLabel;
@property (nonatomic, strong) UILabel *versionNumberLabel;
@property (nonatomic, strong) UILabel *datePublishedLabel;
@property (nonatomic, strong) UILabel *fileSizeLabel;
@property (nonatomic, strong) UILabel *gameVersionsLabel;
@end

@implementation ShaderVersionTableViewCell

- (instancetype)initWithStyle:(UITableViewCellStyle)style reuseIdentifier:(NSString *)reuseIdentifier {
    self = [super initWithStyle:style reuseIdentifier:reuseIdentifier];
    if (self) {
        [self setupUI];
    }
    return self;
}

- (void)setupUI {
    self.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
    self.selectionStyle = UITableViewCellSelectionStyleNone;
    self.backgroundColor = [UIColor clearColor];
    self.contentView.backgroundColor = [UIColor clearColor];

    // ===== 卡片容器：圆角 + 半透明背景 + 浅阴影（与 ModVersionTableViewCell 统一）=====
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

    // ===== 左侧：版本名 + 版本号 =====
    self.nameLabel = [[UILabel alloc] init];
    self.nameLabel.font = [UIFont systemFontOfSize:16 weight:UIFontWeightSemibold];
    self.nameLabel.textColor = [UIColor labelColor];
    self.nameLabel.numberOfLines = 1;
    self.nameLabel.adjustsFontSizeToFitWidth = YES;
    self.nameLabel.minimumScaleFactor = 0.7;
    self.nameLabel.lineBreakMode = NSLineBreakByTruncatingTail;

    self.versionNumberLabel = [[UILabel alloc] init];
    self.versionNumberLabel.font = [UIFont systemFontOfSize:13];
    self.versionNumberLabel.textColor = [UIColor secondaryLabelColor];
    self.versionNumberLabel.numberOfLines = 1;
    self.versionNumberLabel.adjustsFontSizeToFitWidth = YES;
    self.versionNumberLabel.minimumScaleFactor = 0.7;
    self.versionNumberLabel.lineBreakMode = NSLineBreakByTruncatingTail;

    // 加载器徽章 stack（水平排列，configureWithVersion 时动态填充）
    self.loaderBadgeStack = [[UIStackView alloc] init];
    self.loaderBadgeStack.axis = UILayoutConstraintAxisHorizontal;
    self.loaderBadgeStack.spacing = 6;
    self.loaderBadgeStack.alignment = UIStackViewAlignmentCenter;
    self.loaderBadgeStack.distribution = UIStackViewDistributionFill;
    self.loaderBadgeStack.translatesAutoresizingMaskIntoConstraints = NO;

    // 左侧主 stack（垂直：版本名 → 版本号 → 加载器徽章行）
    self.leftStackView = [[UIStackView alloc] initWithArrangedSubviews:@[self.nameLabel, self.versionNumberLabel, self.loaderBadgeStack]];
    self.leftStackView.axis = UILayoutConstraintAxisVertical;
    self.leftStackView.spacing = 4;
    self.leftStackView.alignment = UIStackViewAlignmentLeading;
    self.leftStackView.translatesAutoresizingMaskIntoConstraints = NO;
    [self.cardContainer addSubview:self.leftStackView];

    // ===== 右侧：日期 + 文件大小 + 游戏版本 =====
    self.datePublishedLabel = [[UILabel alloc] init];
    self.datePublishedLabel.font = [UIFont systemFontOfSize:12];
    self.datePublishedLabel.textColor = [UIColor tertiaryLabelColor];
    self.datePublishedLabel.textAlignment = NSTextAlignmentRight;

    self.fileSizeLabel = [[UILabel alloc] init];
    self.fileSizeLabel.font = [UIFont systemFontOfSize:12];
    self.fileSizeLabel.textColor = [UIColor tertiaryLabelColor];
    self.fileSizeLabel.textAlignment = NSTextAlignmentRight;

    self.gameVersionsLabel = [[UILabel alloc] init];
    self.gameVersionsLabel.font = [UIFont systemFontOfSize:12];
    self.gameVersionsLabel.textColor = [UIColor tertiaryLabelColor];
    self.gameVersionsLabel.textAlignment = NSTextAlignmentRight;
    self.gameVersionsLabel.numberOfLines = 2;
    self.gameVersionsLabel.lineBreakMode = NSLineBreakByTruncatingTail;
    self.gameVersionsLabel.adjustsFontSizeToFitWidth = YES;
    self.gameVersionsLabel.minimumScaleFactor = 0.7;

    self.rightStackView = [[UIStackView alloc] initWithArrangedSubviews:@[self.datePublishedLabel, self.fileSizeLabel, self.gameVersionsLabel]];
    self.rightStackView.axis = UILayoutConstraintAxisVertical;
    self.rightStackView.spacing = 4;
    self.rightStackView.alignment = UIStackViewAlignmentTrailing;
    self.rightStackView.translatesAutoresizingMaskIntoConstraints = NO;
    [self.cardContainer addSubview:self.rightStackView];

    // ===== 布局约束 =====
    [NSLayoutConstraint activateConstraints:@[
        // 卡片容器充满 contentView，上下留 6pt 间距
        [self.cardContainer.topAnchor constraintEqualToAnchor:self.contentView.topAnchor constant:6],
        [self.cardContainer.leadingAnchor constraintEqualToAnchor:self.contentView.leadingAnchor constant:16],
        [self.cardContainer.trailingAnchor constraintEqualToAnchor:self.contentView.trailingAnchor constant:-16],
        [self.cardContainer.bottomAnchor constraintEqualToAnchor:self.contentView.bottomAnchor constant:-6],

        // 左侧 stack：左 14，上下 12
        [self.leftStackView.leadingAnchor constraintEqualToAnchor:self.cardContainer.leadingAnchor constant:14],
        [self.leftStackView.topAnchor constraintEqualToAnchor:self.cardContainer.topAnchor constant:12],
        [self.leftStackView.bottomAnchor constraintEqualToAnchor:self.cardContainer.bottomAnchor constant:-12],
        [self.leftStackView.trailingAnchor constraintLessThanOrEqualToAnchor:self.rightStackView.leadingAnchor constant:-12],

        // 右侧 stack：右 -30（留出 chevron 空间），垂直居中
        [self.rightStackView.trailingAnchor constraintEqualToAnchor:self.cardContainer.trailingAnchor constant:-30],
        [self.rightStackView.centerYAnchor constraintEqualToAnchor:self.cardContainer.centerYAnchor]
    ]];

    // 应用毛玻璃背景效果
    [[BackgroundManager sharedManager] applyEffectToView:self.cardContainer];
}

- (void)prepareForReuse {
    [super prepareForReuse];
    // 清除加载器徽章，防止复用时残留
    [self.loaderBadgeStack.arrangedSubviews makeObjectsPerformSelector:@selector(removeFromSuperview)];
}

#pragma mark - 加载器徽章

/// 创建单个加载器徽章 label（pill 样式，按加载器类型配色）
/// 光影包常见加载器：iris/optifine/vanilla，参照 ZL2 LittleTextLabel 配色
- (UILabel *)createLoaderBadge:(NSString *)loaderName {
    UILabel *badge = [[UILabel alloc] init];
    badge.text = loaderName;
    badge.font = [UIFont systemFontOfSize:10 weight:UIFontWeightBold];
    badge.textColor = [UIColor whiteColor];
    badge.textAlignment = NSTextAlignmentCenter;
    badge.backgroundColor = [self colorForLoader:loaderName];
    badge.layer.cornerRadius = 8;
    badge.layer.cornerCurve = kCACornerCurveContinuous;
    badge.layer.masksToBounds = YES;
    badge.translatesAutoresizingMaskIntoConstraints = NO;
    [badge setContentHuggingPriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisHorizontal];
    [badge setContentCompressionResistancePriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisHorizontal];
    // 高度固定 18pt
    [NSLayoutConstraint activateConstraints:@[
        [badge.heightAnchor constraintEqualToConstant:18]
    ]];
    // 宽度 = 文字宽度 + 左右 padding 12pt
    [badge sizeToFit];
    CGFloat textWidth = badge.frame.size.width;
    [badge.widthAnchor constraintEqualToConstant:textWidth + 12].active = YES;
    return badge;
}

/// 加载器名称 → 品牌色映射（统一委托 ModLoaderIconHelper，消除多文件配色不一致）
- (UIColor *)colorForLoader:(NSString *)loader {
    return [ModLoaderIconHelper brandColorForLoader:loader];
}

/// 根据版本数据填充加载器徽章（最多显示 4 个，避免徽章过多溢出）
- (void)configureLoaderBadges:(NSArray<NSString *> *)loaders {
    [self.loaderBadgeStack.arrangedSubviews makeObjectsPerformSelector:@selector(removeFromSuperview)];
    if (![loaders isKindOfClass:[NSArray class]] || loaders.count == 0) return;

    NSInteger maxBadges = MIN(4, loaders.count);
    for (NSInteger i = 0; i < maxBadges; i++) {
        NSString *loader = loaders[i];
        if (![loader isKindOfClass:[NSString class]] || loader.length == 0) continue;
        UILabel *badge = [self createLoaderBadge:loader];
        [self.loaderBadgeStack addArrangedSubview:badge];
    }

    // 如果超过 4 个，添加 "+N" 徽章
    if (loaders.count > 4) {
        UILabel *moreBadge = [[UILabel alloc] init];
        moreBadge.text = [NSString stringWithFormat:@"+%ld", (long)(loaders.count - 4)];
        moreBadge.font = [UIFont systemFontOfSize:10 weight:UIFontWeightBold];
        moreBadge.textColor = [UIColor whiteColor];
        moreBadge.textAlignment = NSTextAlignmentCenter;
        moreBadge.backgroundColor = [UIColor tertiaryLabelColor];
        moreBadge.layer.cornerRadius = 8;
        moreBadge.layer.masksToBounds = YES;
        moreBadge.translatesAutoresizingMaskIntoConstraints = NO;
        [moreBadge setContentHuggingPriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisHorizontal];
        [moreBadge setContentCompressionResistancePriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisHorizontal];
        [NSLayoutConstraint activateConstraints:@[
            [moreBadge.heightAnchor constraintEqualToConstant:18],
            [moreBadge.widthAnchor constraintEqualToConstant:28]
        ]];
        [self.loaderBadgeStack addArrangedSubview:moreBadge];
    }
}

#pragma mark - 配置

- (void)configureWithVersion:(ShaderVersion *)version {
    self.nameLabel.text = version.name;
    self.versionNumberLabel.text = version.versionNumber;

    // 发布日期：ISO 8601 → 短日期格式
    NSISO8601DateFormatter *dateFormatter = [[NSISO8601DateFormatter alloc] init];
    NSDate *date = [dateFormatter dateFromString:version.datePublished];
    if (date) {
        NSDateFormatter *displayFormatter = [[NSDateFormatter alloc] init];
        displayFormatter.dateStyle = NSDateFormatterShortStyle;
        displayFormatter.timeStyle = NSDateFormatterNoStyle;
        self.datePublishedLabel.text = [displayFormatter stringFromDate:date];
    } else {
        self.datePublishedLabel.text = @"未知日期";
    }

    // 文件大小
    if (version.primaryFile) {
        self.fileSizeLabel.text = [NSByteCountFormatter stringFromByteCount:[version.primaryFile[@"size"] longValue] countStyle:NSByteCountFormatterCountStyleFile];
    } else {
        self.fileSizeLabel.text = @"未知大小";
    }

    // 游戏版本兼容
    self.gameVersionsLabel.text = [version.gameVersions componentsJoinedByString:@", "];

    // 加载器徽章（新增：参照 ZL2 的加载器 pill 标签）
    [self configureLoaderBadges:version.loaders];
}

@end
