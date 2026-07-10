// VersionCardCell.m
// 参照 FCL (item_remote_version.xml) 与 ZL2 (VersionItemLayout) 的单列横向列表行设计：
// - 左侧：类型图标容器（40x40 圆角方块，类型色背景 + 白色 SF Symbol）
// - 中间：版本号（16pt semibold）+ 类型小标签（pill） 在同一行 / 发布日期（12pt secondary）在下一行
// - 右侧：chevron 指示可点击
// - 已安装标记：图标容器右上角的绿色小圆点徽章（ZL2 风格，不遮挡右侧 chevron）
// 替代原 100x120 纵向网格卡片，信息密度更高、更接近 FCL/ZL2 视觉。

#import "VersionCardCell.h"
#import <CoreGraphics/CoreGraphics.h>

// 修复问题3：带内边距的 UILabel 子类，让"正式版/测试版"等类型标签文字
// 在背景块内完美居中，不再与背景边缘重叠。
// 通过重写 textRectForBounds: 和 drawTextInRect: 注入左右 8pt / 上下 0pt 内边距，
// 同时保持 UILabel 接口不变，VersionCardCell.h 中的 typeLabel 声明无需修改。
@interface InsetTypeLabel : UILabel
@property (nonatomic, assign) UIEdgeInsets textInsets;
@end

@implementation InsetTypeLabel
- (instancetype)init {
    self = [super init];
    if (self) {
        // 默认内边距：左右 8pt，上下 1pt，让文字在 pill 背景块内居中
        _textInsets = UIEdgeInsetsMake(1, 8, 1, 8);
    }
    return self;
}
- (CGRect)textRectForBounds:(CGRect)bounds limitedToNumberOfLines:(NSInteger)numberOfLines {
    CGRect insetRect = UIEdgeInsetsInsetRect(bounds, self.textInsets);
    CGRect textRect = [super textRectForBounds:insetRect limitedToNumberOfLines:numberOfLines];
    textRect.origin.x -= self.textInsets.left;
    textRect.origin.y -= self.textInsets.top;
    return textRect;
}
- (void)drawTextInRect:(CGRect)rect {
    [super drawTextInRect:UIEdgeInsetsInsetRect(rect, self.textInsets)];
}
@end

// 修复问题4：程序化绘制标准原版草方块图标（俯视图），与 FCL/ZL2/HMCL 视觉一致。
// 采用 16x16 像素网格绘制（每像素 4pt，总 64x64），还原 Minecraft grass_block_top 的视觉特征：
// - 草绿色主调，深浅交替的像素块
// - 零星分布的亮色高光像素
// - 底部一行土壤色（草方块侧边的泥土边缘在俯视图中的投影）
// 程序化绘制确保开箱即用，无需导入任何外部 PNG 资源，也不依赖 Mojang 版权素材。
// 绘制结果用 static 变量缓存，整个 App 生命周期只绘制一次。
@interface VersionCardCell (VanillaIcon)
+ (UIImage *)vanillaGrassBlockIcon;
@end

@implementation VersionCardCell (VanillaIcon)

/// 绘制 64x64 的草方块图标并缓存。调用线程安全（dispatch_once）。
+ (UIImage *)vanillaGrassBlockIcon {
    static UIImage *cachedIcon = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        const CGFloat pixelSize = 4.0;  // 每个像素块 4pt
        const NSInteger gridSize = 16;  // 16x16 网格
        const CGFloat totalSize = pixelSize * gridSize; // 64pt

        UIGraphicsBeginImageContextWithOptions(CGSizeMake(totalSize, totalSize), NO, [UIScreen mainScreen].scale);
        CGContextRef ctx = UIGraphicsGetCurrentContext();

        // 草方块颜色调色板（还原 Minecraft grass_block_top.png 的像素色彩）
        // 主草色
        UIColor *grassMain   = [UIColor colorWithRed:0.486 green:0.741 blue:0.337 alpha:1.0]; // #7CBD56
        // 暗草色（阴影）
        UIColor *grassDark   = [UIColor colorWithRed:0.365 green:0.612 blue:0.239 alpha:1.0]; // #5D9C3D
        // 亮草色（高光）
        UIColor *grassLight  = [UIColor colorWithRed:0.549 green:0.686 blue:0.290 alpha:1.0]; // #8CB04A
        // 最亮草色（零星高光像素）
        UIColor *grassBright = [UIColor colorWithRed:0.620 green:0.800 blue:0.400 alpha:1.0]; // #9ECC66
        // 土壤色（底部边缘）
        UIColor *dirtColor   = [UIColor colorWithRed:0.525 green:0.376 blue:0.263 alpha:1.0]; // #866043
        // 暗土壤色
        UIColor *dirtDark    = [UIColor colorWithRed:0.404 green:0.290 blue:0.196 alpha:1.0]; // #674A32

        // 16x16 像素布局（0=主色, 1=暗色, 2=亮色, 3=最亮, 4=土壤, 5=暗土壤）
        // 参照原版 grass_block_top 纹理的像素分布特征：随机感但均匀的绿色 + 底部土壤带
        // 第 0-14 行：草色区域；第 15 行：土壤边缘
        static const int layout[16][16] = {
            // y=0  (顶行)
            {0,1,0,2,0,0,1,0,2,0,0,1,0,2,0,0},
            {1,0,2,0,1,0,0,2,0,1,3,0,1,0,2,0},
            {0,2,0,1,0,3,0,1,0,0,2,0,0,1,0,2},
            {2,0,0,1,0,0,2,0,1,0,0,1,3,0,0,1},
            {0,1,3,0,1,0,0,1,0,2,0,0,1,0,2,0},
            {0,0,1,0,2,0,1,0,0,1,3,0,0,1,0,0},
            {1,0,0,2,0,1,0,0,3,0,1,0,2,0,0,1},
            {0,2,0,0,1,0,3,0,1,0,0,2,0,1,3,0},
            {0,0,1,0,0,2,0,1,0,0,1,0,0,2,0,1},
            {2,0,0,1,3,0,0,1,0,2,0,1,0,0,1,0},
            {0,1,0,0,2,0,1,0,0,0,1,0,3,0,0,2},
            {0,0,2,0,0,1,0,0,3,1,0,0,2,0,1,0},
            {1,0,0,1,0,0,2,0,1,0,0,1,0,3,0,0},
            {0,2,0,0,1,3,0,1,0,2,0,0,1,0,0,1},
            {0,0,1,0,0,2,0,0,1,0,3,0,0,1,2,0},
            // y=15 (底行，土壤边缘)
            {4,5,4,4,5,4,4,5,4,4,5,4,4,5,4,4}
        };

        // 按像素绘制
        for (NSInteger y = 0; y < gridSize; y++) {
            for (NSInteger x = 0; x < gridSize; x++) {
                int code = layout[y][x];
                UIColor *color;
                switch (code) {
                    case 1:  color = grassDark;   break;
                    case 2:  color = grassLight;  break;
                    case 3:  color = grassBright; break;
                    case 4:  color = dirtColor;   break;
                    case 5:  color = dirtDark;    break;
                    default: color = grassMain;   break;
                }
                CGContextSetFillColorWithColor(ctx, color.CGColor);
                CGRect pixelRect = CGRectMake(x * pixelSize, y * pixelSize, pixelSize, pixelSize);
                CGContextFillRect(ctx, pixelRect);
            }
        }

        cachedIcon = UIGraphicsGetImageFromCurrentImageContext();
        UIGraphicsEndImageContext();
    });
    return cachedIcon;
}

@end

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

        // ----- 类型标签（pill 样式，修复问题3：使用带内边距的 InsetTypeLabel） -----
        self.typeLabel = [[InsetTypeLabel alloc] init];
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

    // 修复问题4：使用程序化绘制的标准草方块图标（俯视图），与 FCL/ZL2/HMCL 视觉一致。
    // 图标在 App 首次调用时用 Core Graphics 绘制 16x16 像素网格并缓存，开箱即用，无需导入任何外部资源。
    // 铺满图标容器（AspectFill），背景透明以保留草方块纹理本色。
    UIImage *grassIcon = [VersionCardCell vanillaGrassBlockIcon];
    if (grassIcon) {
        self.iconImageView.image = grassIcon;
        self.iconImageView.contentMode = UIViewContentModeScaleAspectFill;
        self.iconImageView.tintColor = nil; // 取消着色，显示草方块原色
        // 草方块图标自带色彩，图标容器背景设为透明
        self.iconContainer.backgroundColor = [UIColor clearColor];
    } else {
        // 极端兜底：程序化绘制失败时回退 SF Symbol + 类型色背景
        self.iconImageView.contentMode = UIViewContentModeScaleAspectFit;
        self.iconImageView.tintColor = [UIColor whiteColor];
        self.iconContainer.backgroundColor = [typeColor colorWithAlphaComponent:0.85];
    }

    // 类型标签：类型色背景 + 白字
    self.typeLabel.text = typeText;
    self.typeLabel.backgroundColor = typeColor;
}

- (void)setInstalled:(BOOL)installed {
    self.installedBadge.hidden = !installed;
}

- (void)prepareForReuse {
    [super prepareForReuse];
    // 重置为 SF Symbol 默认状态（configureWithVersionId 会再次绘制草方块图标覆盖）
    self.iconImageView.image = [UIImage systemImageNamed:@"cube.fill"];
    self.iconImageView.tintColor = [UIColor whiteColor];
    self.iconImageView.contentMode = UIViewContentModeScaleAspectFit;
    self.iconContainer.backgroundColor = [UIColor systemGreenColor];
    self.versionLabel.text = nil;
    self.dateLabel.text = nil;
    self.typeLabel.text = nil;
    self.typeLabel.backgroundColor = [UIColor systemBlueColor];
    self.installedBadge.hidden = YES;
    self.chevronView.tintColor = [UIColor tertiaryLabelColor];
}

@end
